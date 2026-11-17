using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// B18, multiplayer sync, Beef side (tools/run_net_bench.py): the same rules as Samples/CSharpBench's NetSync.cs.
/// TALLOW_BENCH_MODE=netsync or nethash loads Scenes/NetSync.tscene, whose session the player's switches start.
/// netsync runs TALLOW_NET_SECONDS (default 40); nethash (a host alone with --bot) prints "NETHASH" at tick 600
/// with a hash of the player's and every drone's position to the millimetre, which must equal CSharpBench's.
static class NetSyncRun
{
	/// The tick the hash is taken at (TALLOW_NET_HASH_TICK, default 600).
	public static int HashTick = 600;
	public static int PilotTicks;
	public static Vector3 PilotAtHash;
	public static bool PilotHashed;
	public static Dictionary<int, Vector3> DronesAtHash = new .() ~ delete _;
	public static int Drones;

	/// A position to the millimetre, folded into a hash (FNV-1a over the three integers).
	public static uint64 Fold(uint64 hash, Vector3 p)
	{
		var hash;
		for (let v in float[3](p.x, p.y, p.z))
		{
			let mm = (int64)Math.Round(v * 1000);
			for (int i < 8)
			{
				hash ^= (uint64)((mm >> (i * 8)) & 0xFF);
				hash *= 1099511628211UL;
			}
		}
		return hash;
	}

	public static bool IsServer(Scene scene) => scene.Network != null && scene.Network.IsServer;
}

/// A peer's player: walks along its controls' MoveDirection at 6 m/s (the server's result is the truth).
[Component]
class NetPilot : Script
{
	public override void Update(TickInput input, float deltaTime)
	{
		Transform.Position = Transform.Position + input.MoveDirection * (6 * deltaTime);
		if (!NetSyncRun.IsServer(Scene))
			return;
		NetSyncRun.PilotTicks++;
		if (NetSyncRun.PilotTicks == NetSyncRun.HashTick)
		{
			NetSyncRun.PilotAtHash = Transform.Position;
			NetSyncRun.PilotHashed = true;
		}
	}
}

/// A drone circling where the scene put it, 2 m round, at a speed from its place.
[Component]
class NetDrone : Script
{
	Vector3 mCenter;
	float mPhase;
	int mTicks;

	public override void Start()
	{
		mCenter = Transform.Position;
		mPhase = mCenter.x * 0.37f + mCenter.z * 0.61f;
		NetSyncRun.Drones++;
	}

	public override void Update(TickInput input, float deltaTime)
	{
		mTicks++;
		let angle = mPhase + mTicks * deltaTime * 1.3f;
		Transform.Position = mCenter + Vector3(Math.Cos(angle) * 2, 0, Math.Sin(angle) * 2);
		if (mTicks == NetSyncRun.HashTick && NetSyncRun.IsServer(Scene))
			NetSyncRun.DronesAtHash[(int)Math.Round(mCenter.x) * 1000 + (int)Math.Round(mCenter.z)] = Transform.Position;
	}
}

/// Ends the run: after TALLOW_NET_SECONDS (netsync), or once the hash is taken (nethash).
[Component]
class NetSyncProbe : Script
{
	uint64 mStart;
	double mSeconds = 40;
	bool mHash;
	bool mKeep;
	bool mHashed;
	bool mDone;
	uint64 mLastFrame;
	double mWorstFrameMs;
	List<double> mFrames = new .() ~ delete _;

	public override void Start()
	{
		let text = scope String();
		mHash = Environment.GetEnvironmentVariable("TALLOW_BENCH_MODE", text) case .Ok && text == "nethash";
		if (Environment.GetEnvironmentVariable("TALLOW_NET_SECONDS", text..Clear()) case .Ok && double.Parse(text) case .Ok(let seconds))
			mSeconds = seconds;
		// TALLOW_NET_KEEP=1: a nethash server keeps running to TALLOW_NET_SECONDS after the hash (B20's clients).
		mKeep = Environment.GetEnvironmentVariable("TALLOW_NET_KEEP", text..Clear()) case .Ok && text == "1";
		if (Environment.GetEnvironmentVariable("TALLOW_NET_HASH_TICK", text..Clear()) case .Ok && int.Parse(text) case .Ok(let tick) && tick > 0)
			NetSyncRun.HashTick = tick;
		mStart = SDL.SDL_GetTicksNS();
		Gfx.SetVsync(false);
		let network = Scene.Network;
		Console.WriteLine(scope $"NETSYNC start beef {(network != null && network.IsClient ? "client" : (NetSyncRun.IsServer(Scene) ? "server" : "offline"))}");
	}

	public override void LocalUpdate()
	{
		if (mDone)
			return;
		// Frames after the first five seconds (joining and the first snapshot are left out): the worst is the
		// longest catch-up, a frame that replayed ticks after a correction.
		let now = SDL.SDL_GetTicksNS();
		if (mLastFrame != 0 && (now - mStart) / 1e9 > 5)
		{
			let ms = (now - mLastFrame) / 1e6;
			mFrames.Add(ms);
			mWorstFrameMs = Math.Max(mWorstFrameMs, ms);
		}
		mLastFrame = now;
		if (mHash && !mHashed && NetSyncRun.PilotHashed && NetSyncRun.DronesAtHash.Count >= NetSyncRun.Drones)
		{
			var hash = NetSyncRun.Fold(14695981039346656037UL, NetSyncRun.PilotAtHash);
			let keys = scope List<int>(NetSyncRun.DronesAtHash.Keys);
			keys.Sort();
			for (let key in keys)
				hash = NetSyncRun.Fold(hash, NetSyncRun.DronesAtHash[key]);
			let at = NetSyncRun.PilotAtHash;
			Console.WriteLine(scope $"NETHASH beef {hash:x16} pilot {at.x:F3} {at.y:F3} {at.z:F3} drones {NetSyncRun.DronesAtHash.Count}");
			mHashed = true;
			if (!mKeep)
			{
				mDone = true;
				Application.Quit();
				return;
			}
		}
		if (mHash && !mKeep)
			return;
		if ((SDL.SDL_GetTicksNS() - mStart) / 1e9 >= mSeconds)
		{
			mFrames.Sort();
			let p99 = mFrames.Count > 0 ? mFrames[Math.Min(mFrames.Count - 1, (int)(mFrames.Count * 0.99))] : 0;
			Console.WriteLine(scope $"NETFRAME worst {mWorstFrameMs:F2} p99 {p99:F2} frames {mFrames.Count}");
			if (Scene.Network != null)
			{
				let report = scope String();
				Scene.Network.Describe(report);
				for (let line in report.Split('\n'))
				{
					if (line.StartsWith("ROLLBACK") || line.StartsWith("LINK") || line.StartsWith("NETWORK"))
						Console.WriteLine(scope $"NETREPORT {line}");
				}
			}
			Console.WriteLine("NETSYNC done");
			mDone = true;
			Application.Quit();
		}
	}
}
