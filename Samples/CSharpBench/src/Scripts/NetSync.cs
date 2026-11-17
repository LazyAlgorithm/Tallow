using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using Tallow;

namespace CSharpBench;

/// <summary>
/// B18, multiplayer sync (tools/run_net_bench.py): TALLOW_BENCH_MODE=netsync or nethash loads Scenes/NetSync.tscene,
/// whose session the player's switches start (--server, --connect ADDRESS, --host, --bot, --lag, --loss). Each
/// peer's player (Prefabs/NetPlayer.tprefab, NetPilot) walks by its tick controls; 200 drones (NetDrone) circle,
/// run by the server. The same rules as Samples/EcsBench's NetSync.bf, so the two languages can be compared.
///   netsync: runs TALLOW_NET_SECONDS (default 40) and quits; the engine's --netstats lines are the measurements.
///   nethash: a host alone with --bot: at tick 600 prints "NETHASH" with a hash of the player's and every drone's
///            position to the millimetre, which must equal EcsBench's.
/// </summary>
public static class NetSyncRun
{
    /// <summary>The tick the hash is taken at (TALLOW_NET_HASH_TICK, default 600).</summary>
    public static int HashTick = 600;
    public static int PilotTicks;
    public static Vector3 PilotAtHash;
    public static bool PilotHashed;
    public static readonly SortedDictionary<int, Vector3> DronesAtHash = new();
    public static int Drones;

    /// <summary>A position to the millimetre, folded into a hash (FNV-1a over the three integers).</summary>
    public static ulong Fold(ulong hash, Vector3 p)
    {
        foreach (float v in stackalloc float[] { p.X, p.Y, p.Z })
        {
            long mm = (long)MathF.Round(v * 1000);
            for (int i = 0; i < 8; i++)
            {
                hash ^= (ulong)((mm >> (i * 8)) & 0xFF);
                hash *= 1099511628211UL;
            }
        }
        return hash;
    }
}

/// <summary>A peer's player: walks along its controls' MoveDirection at 6 m/s (the server's result is the truth).</summary>
public class NetPilot : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Position += input.MoveDirection * (6 * deltaTime);
        if (!Scene.IsServer || Scene.IsClient)
            return;
        NetSyncRun.PilotTicks++;
        if (NetSyncRun.PilotTicks == NetSyncRun.HashTick)
        {
            NetSyncRun.PilotAtHash = Transform.Position;
            NetSyncRun.PilotHashed = true;
        }
    }
}

/// <summary>A drone circling where the scene put it, 2 m round, at a speed from its place.</summary>
public class NetDrone : Script
{
    private Vector3 _center;
    private float _phase;
    private int _ticks;

    public override void Start()
    {
        _center = Transform.Position;
        _phase = _center.X * 0.37f + _center.Z * 0.61f;
        NetSyncRun.Drones++;
    }

    public override void Update(TickInput input, float deltaTime)
    {
        _ticks++;
        float angle = _phase + _ticks * deltaTime * 1.3f;
        Transform.Position = _center + new Vector3(MathF.Cos(angle) * 2, 0, MathF.Sin(angle) * 2);
        if (_ticks == NetSyncRun.HashTick && Scene.IsServer)
            NetSyncRun.DronesAtHash[(int)MathF.Round(_center.X) * 1000 + (int)MathF.Round(_center.Z)] = Transform.Position;
    }
}

/// <summary>Ends the run: after TALLOW_NET_SECONDS (netsync), or once the hash is taken (nethash).</summary>
public class NetSyncProbe : Script
{
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private double _seconds = 40;
    private bool _hash;
    private bool _keep;
    private bool _hashed;
    private bool _done;
    private double _worstFrameMs;
    private readonly List<double> _frames = new();

    public override void Start()
    {
        _hash = Environment.GetEnvironmentVariable("TALLOW_BENCH_MODE") == "nethash";
        // TALLOW_NET_KEEP=1: a nethash server keeps running to TALLOW_NET_SECONDS after the hash (B20's clients).
        _keep = Environment.GetEnvironmentVariable("TALLOW_NET_KEEP") == "1";
        if (int.TryParse(Environment.GetEnvironmentVariable("TALLOW_NET_HASH_TICK"), out int tick) && tick > 0)
            NetSyncRun.HashTick = tick;
        if (double.TryParse(Environment.GetEnvironmentVariable("TALLOW_NET_SECONDS"), NumberStyles.Float, CultureInfo.InvariantCulture, out double seconds))
            _seconds = seconds;
        Quality.VSync = false;
        Console.WriteLine($"NETSYNC start csharp {(Scene.IsClient ? "client" : (Scene.IsServer ? "server" : "offline"))}");
    }

    public override void LocalUpdate(float deltaTime)
    {
        if (_done)
            return;
        // Frames after the first five seconds (joining and the first snapshot are left out): the worst is the
        // longest catch-up, a frame that replayed ticks after a correction.
        if (_clock.Elapsed.TotalSeconds > 5)
        {
            _frames.Add(deltaTime * 1000.0);
            _worstFrameMs = Math.Max(_worstFrameMs, deltaTime * 1000.0);
        }
        if (_hash && !_hashed && NetSyncRun.PilotHashed && NetSyncRun.DronesAtHash.Count >= NetSyncRun.Drones)
        {
            ulong hash = NetSyncRun.Fold(14695981039346656037UL, NetSyncRun.PilotAtHash);
            foreach (Vector3 p in NetSyncRun.DronesAtHash.Values)
                hash = NetSyncRun.Fold(hash, p);
            Vector3 at = NetSyncRun.PilotAtHash;
            Console.WriteLine(string.Create(CultureInfo.InvariantCulture,
                $"NETHASH csharp {hash:x16} pilot {at.X:F3} {at.Y:F3} {at.Z:F3} drones {NetSyncRun.DronesAtHash.Count}"));
            _hashed = true;
            if (!_keep)
            {
                _done = true;
                Application.Quit();
                return;
            }
        }
        if (_hash && !_keep)
            return;
        if (_clock.Elapsed.TotalSeconds >= _seconds)
        {
            _frames.Sort();
            double p99 = _frames.Count > 0 ? _frames[Math.Min(_frames.Count - 1, (int)(_frames.Count * 0.99))] : 0;
            Console.WriteLine(string.Create(CultureInfo.InvariantCulture, $"NETFRAME worst {_worstFrameMs:F2} p99 {p99:F2} frames {_frames.Count}"));
            foreach (string line in Network.Report(Scene).Split('\n'))
            {
                if (line.StartsWith("ROLLBACK") || line.StartsWith("LINK") || line.StartsWith("NETWORK"))
                    Console.WriteLine("NETREPORT " + line);
            }
            Console.WriteLine("NETSYNC done");
            _done = true;
            Application.Quit();
        }
    }
}
