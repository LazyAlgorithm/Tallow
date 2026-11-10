using System;
using System.Collections;
using System.IO;
using Tallow;

namespace EcsBench;

/// Runs one benchmark and quits (docs/ecs-plan.md, Phase 1; tools/run_ecs_bench.py runs the whole set). Set by
/// environment variables:
///   TALLOW_BENCH_MODE   gameobject (Mover components), mixed (prefabs with physics/AI/network identities), ai (a crowd
///                       with a behaviour tree and navigation agent on every object, BenchAI.bf), ecs (one thread),
///                       ecs-mt (every Jobs thread), or check
///                       (runs EcsChecks and exits with 1 if any fail)
///   TALLOW_BENCH_COUNT  how many cubes (default 10000)
///   TALLOW_BENCH_FRAMES frames measured after a 120 frame warm-up (default 600)
///   TALLOW_BENCH_OUT    file a JSON line of results is added to (default: printed only)
///   TALLOW_BENCH_EXPLORER 1 serves the scene to the Flecs Explorer (port 27750) while it runs
/// Frame time is from one Update to the next, so it includes the render extract and submitting the frame. Update
/// time is from this component's Update to its LateUpdate: every Mover's Update, or the ECS system.
[Component]
class Bench : Component
{
	const int WarmupFrames = 120;

	String mMode = new .("ecs") ~ delete _;
	int mCount = 10000;
	int mFrames = 600;
	String mOutput = new .() ~ delete _;
	float mHalfSize;

	World mWorld ~ delete _;
	Query<Pose, Motion, RenderMatrix> mMove ~ delete _;
	Query<RenderMatrix> mDraw ~ delete _;
	RenderProxy mProxy ~ delete _;
	delegate void(Scene scene, List<RenderView.InstancedDraws> output) mSource ~ delete _;

	List<double> mFrameTimes = new .() ~ delete _;
	List<double> mUpdateTimes = new .() ~ delete _;
	List<double> mScriptTimes = new .() ~ delete _;
	uint64 mLastFrame;
	uint64 mUpdateStart;
	int mFrame;
	double mSpawnMs;
	int64 mMemoryBefore;
	int64 mMemoryAfter;

	public override void Start()
	{
		ReadSetting("TALLOW_BENCH_MODE", mMode);
		let text = scope String();
		if (ReadSetting("TALLOW_BENCH_COUNT", text) && int.Parse(text) case .Ok(let count))
			mCount = count;
		if (ReadSetting("TALLOW_BENCH_FRAMES", text..Clear()) && int.Parse(text) case .Ok(let frames))
			mFrames = frames;
		ReadSetting("TALLOW_BENCH_OUT", mOutput);
		// TALLOW_BENCH_EXPLORER=1: serve the scene to the Flecs Explorer while the benchmark runs.
		if (ReadSetting("TALLOW_BENCH_EXPLORER", text..Clear()) && text == "1")
			Console.WriteLine(Scene.World.StartExplorer() ? "EcsBench: Flecs Explorer on port 27750" : "EcsBench: Flecs Explorer unavailable");
		Gfx.SetVsync(false);
		mHalfSize = Workload.HalfSize(mCount);
		// Far enough back to see the whole box.
		Transform.Position = .(0, mHalfSize * 0.6f, -mHalfSize * 3.2f);
		Transform.LookAt(.Zero);

		if (mMode == "check")
		{
			let failures = EcsChecks.Run();
			Console.WriteLine(failures == 0 ? "EcsBench checks: all passed" : scope $"EcsBench checks: {failures} FAILED");
			Environment.Exit(failures == 0 ? 0 : 1);
		}
		mMemoryBefore = ProfilerModules.ProcessMemory();
		let start = SDL.SDL_GetTicksNS();
		if (mMode == "gameobject")
			SpawnGameObjects();
		else if (mMode == "mixed")
			SpawnMixed();
		else if (mMode == "ai")
			SpawnAICrowd();
		else
			SpawnEntities();
		mSpawnMs = (SDL.SDL_GetTicksNS() - start) / 1e6;
		// Last in the registration list: measure callbacks separately from engine systems before LateUpdate.
		GameObject.AddComponent<BenchEndUpdate>().owner = this;
		Console.WriteLine($"EcsBench: {mMode}, {mCount} cubes, {Jobs.ThreadCount} threads, spawned in {mSpawnMs:F1} ms");
	}

	static bool ReadSetting(StringView name, String output)
	{
		let value = scope String();
		if (Environment.GetEnvironmentVariable(name, value) case .Ok && !value.IsEmpty)
		{
			output.Set(value);
			return true;
		}
		return false;
	}

	void SpawnGameObjects()
	{
		for (int i < mCount)
		{
			Workload.Start(i, mHalfSize, let position, let velocity, let spin);
			let cube = Scene.CreateGameObject("Cube");
			mSpawned.Add(cube);
			cube.Transform.LocalPosition = position;
			cube.Transform.LocalScale = .(Workload.CubeScale, Workload.CubeScale, Workload.CubeScale);
			cube.AddComponent<MeshRenderer>();
			let mover = cube.AddComponent<Mover>();
			mover.velocity = velocity;
			mover.spin = spin;
			mover.halfSize = mHalfSize;
		}
	}

	void SpawnEntities()
	{
		mWorld = new World();
		let entities = scope List<Entity>(mCount);
		mWorld.CreateMany<Pose>(mCount, entities);
		for (int i < mCount)
		{
			Workload.Start(i, mHalfSize, let position, let velocity, let spin);
			mWorld.Set<Pose>(entities[i], .() { position = position, rotation = .Identity });
			mWorld.Set<Motion>(entities[i], .() { velocity = velocity, spin = spin });
			mWorld.Add<RenderMatrix>(entities[i]);
		}
		mMove = new .(mWorld);
		mDraw = new .(mWorld, .Read);
		mProxy = new RenderProxy();
		mSource = new => GatherDraws;
		RenderView.InstancedSources.Add(mSource);
	}

	/// The render extract: one run of instances per chunk, straight from the RenderMatrix column.
	void GatherDraws(Scene scene, List<RenderView.InstancedDraws> output)
	{
		if (scene != Scene)
			return;
		let mesh = mProxy.ActiveMesh;
		for (var chunk in mDraw)
		{
			let matrices = chunk.Read<RenderMatrix>();
			output.Add(.() { proxy = mProxy, mesh = mesh, material = null, matrices = .((Matrix4*)matrices.Ptr, matrices.Length) });
		}
	}

	public override void OnDestroy()
	{
		if (mSource != null)
			RenderView.InstancedSources.Remove(mSource);
	}

	public override void Update(TickInput input, float deltaTime)
	{
		let now = SDL.SDL_GetTicksNS();
		if (mLastFrame != 0 && mFrame > WarmupFrames)
			mFrameTimes.Add((now - mLastFrame) / 1e6);
		mLastFrame = now;
		mFrame++;
		if (mFrame == WarmupFrames)
		{
			mMemoryAfter = ProfilerModules.ProcessMemory();
			mCpuStart = CpuMilliseconds();
			mAllocationsStart = AllocationCount();
		}
		if (mFrame > WarmupFrames)
			mDrawCounts.Add(RenderView.FrameDrawCalls);
		// ProfilerModules clears this only while recording; benchmark runs leave recording off.
		RenderView.FrameDrawCalls = 0;
		mUpdateStart = SDL.SDL_GetTicksNS();
		if (mMode == "ai")
			MoveAIObstacles(deltaTime);
		if (mWorld != null)
		{
			let halfSize = mHalfSize;
			if (mMode == "ecs-mt")
				mMove.ParallelFor(scope (chunk) => MoveSystem.Run(chunk, halfSize, deltaTime));
			else
			{
				for (var chunk in mMove)
					MoveSystem.Run(chunk, halfSize, deltaTime);
			}
		}
	}

	public override void LateUpdate()
	{
		if (mFrame > WarmupFrames)
			mUpdateTimes.Add((SDL.SDL_GetTicksNS() - mUpdateStart) / 1e6);
		if (mFrameTimes.Count >= mFrames)
			Finish();
	}

	public void EndScriptUpdates()
	{
		if (mFrame > WarmupFrames)
			mScriptTimes.Add((SDL.SDL_GetTicksNS() - mUpdateStart) / 1e6);
	}

	void Finish()
	{
		let line = scope String();
		line.AppendF("{{\"mode\": \"{}\", \"count\": {}, \"threads\": {}, \"frames\": {}, ", mMode, mCount, mMode == "ecs-mt" ? Jobs.ThreadCount : 1, mFrameTimes.Count);
		line.AppendF("\"frame_avg_ms\": {:F3}, \"frame_p99_ms\": {:F3}, ", Average(mFrameTimes), Percentile(mFrameTimes, 0.99));
		line.AppendF("\"update_avg_ms\": {:F3}, \"update_p99_ms\": {:F3}, ", Average(mUpdateTimes), Percentile(mUpdateTimes, 0.99));
		line.AppendF("\"script_only_avg_ms\": {:F3}, \"script_only_p99_ms\": {:F3}, ", Average(mScriptTimes), Percentile(mScriptTimes, 0.99));
		line.AppendF("\"ref_slow_per_frame\": {}, ", ComponentRefStats.SlowPath / Math.Max(mFrame, 1));
		FinishCounters(line);
		if (mMode == "ai")
			FinishAI(line);
		line.AppendF("\"spawn_ms\": {:F1}, \"memory_before\": {}, \"memory_after\": {}}}", mSpawnMs, mMemoryBefore, mMemoryAfter);
		Console.WriteLine(line);
		if (!mOutput.IsEmpty)
		{
			let existing = scope String();
			File.ReadAllText(mOutput, existing).IgnoreError();
			existing.Append(line, "\n");
			File.WriteAllText(mOutput, existing).IgnoreError();
		}
		mFrameTimes.Clear();
		Application.Quit();
	}

	static double Average(List<double> values)
	{
		if (values.IsEmpty)
			return 0;
		double total = 0;
		for (let value in values)
			total += value;
		return total / values.Count;
	}

	static double Percentile(List<double> values, double fraction)
	{
		if (values.IsEmpty)
			return 0;
		let sorted = scope List<double>(values.GetEnumerator());
		sorted.Sort();
		return sorted[Math.Min((int)(fraction * sorted.Count), sorted.Count - 1)];
	}
}

/// Timestamp after the last ordinary script callback, before the engine's following frame systems.
[Component]
class BenchEndUpdate : Component
{
	public Bench owner;
	public override void Update(TickInput input, float deltaTime) => owner.EndScriptUpdates();
}
