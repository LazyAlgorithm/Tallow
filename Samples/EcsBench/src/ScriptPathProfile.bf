using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// An empty Update isolates the scene's dispatch and active-state checks from gameplay work.
[Component]
class EmptyUpdate : Script
{
	public override void Update(TickInput input, float deltaTime) { }
}

/// Headless breakdown of normal-script costs. Run with --profile-scripts [object count].
/// Each row is timed separately; the rows are not additive because they warm different caches.
static class ScriptPathProfile
{
	const int Passes = 120;
	static Vector3 sSink;
	static function int32(int32) sCacheStart;
	static function int64(int32) sCacheStop;
#if BF_PLATFORM_LINUX
	[CLink] static extern void* dlsym(void* handle, char8* symbol);
#endif

	static void Measure(StringView name, int count, delegate void() body)
	{
		for (int i < 10)
			body();
		let slow = ComponentRefStats.SlowPath;
		let cacheReferences = sCacheStart != null ? sCacheStart(0) : -1;
		let cacheMisses = sCacheStart != null ? sCacheStart(1) : -1;
		let start = Profiler.Now;
		for (int i < Passes)
			body();
		let elapsed = Profiler.Now - start;
		let misses = sCacheStop != null ? sCacheStop(cacheMisses) : -1;
		let references = sCacheStop != null ? sCacheStop(cacheReferences) : -1;
		Console.WriteLine(scope $"PROFILE {name} count={count} pass_ms={elapsed / (double)Passes / 1e6:0.000000} ns_per_object={elapsed / (double)Passes / count:0.000} reference_refreshes={ComponentRefStats.SlowPath - slow} cache_references={references} cache_misses={misses}");
	}

	public static int Run(int count)
	{
		if (count <= 0)
			return 1;
#if BF_PLATFORM_LINUX
		sCacheStart = (.)dlsym(null, "tallow_bench_cache_start");
		sCacheStop = (.)dlsym(null, "tallow_bench_cache_stop");
#endif
		Time.DeltaTime = Time.FixedDeltaTime;
		let scene = scope Scene();
		let transforms = scope List<Transform>();
		let empty = scope List<EmptyUpdate>();
		let movers = scope List<Mover>();
		let start = Profiler.Now;
		let memory = ProfilerModules.ProcessMemory();
		for (int i < count)
		{
			let obj = scene.CreateGameObject("Probe");
			transforms.Add(obj.Transform);
			empty.Add(obj.AddComponent<EmptyUpdate>());
			let mover = obj.AddComponent<Mover>();
			mover.Enabled = false;
			mover.velocity = .(1, 2, 3);
			mover.spin = .(5, 10, 15);
			movers.Add(mover);
		}
		Console.WriteLine(scope $"PROFILE spawn count={count} ms={(Profiler.Now - start) / 1e6:0.000} memory_bytes={ProfilerModules.ProcessMemory() - memory}");
		scene.StartPlay();
		Measure("scene_empty", count, scope () => scene.Update());
		Measure("dispatch_empty", count, scope () => scene.[Friend]RunFrameUpdates());
		Measure("local_read", count, scope [&] () =>
			{
				var sum = Vector3.Zero;
				for (let transform in transforms)
					sum += transform.LocalPosition;
				sSink = sum;
			});
		Measure("local_write_dirty", count, scope [&] () =>
			{
				for (let transform in transforms)
					transform.LocalPosition = .(1, 2, 3);
			});
		Measure("local_write_then_world", count, scope [&] () =>
			{
				var sum = Vector3.Zero;
				for (let transform in transforms)
				{
					transform.LocalPosition = .(1, 2, 3);
					sum += transform.Position;
				}
				sSink = sum;
			});
		Measure("rotate", count, scope [&] () =>
			{
				for (let transform in transforms)
					transform.Rotate(.(0, 1, 0));
			});
		Measure("component_lookup", count, scope [&] () =>
			{
				float sum = 0;
				for (let transform in transforms)
					sum += transform.GameObject.GetComponent<Mover>().halfSize;
				sSink.x = sum;
			});
		for (int i < count)
		{
			empty[i].Enabled = false;
			movers[i].Enabled = true;
		}
		Measure("scene_mover", count, scope () => scene.Update());
		Measure("dispatch_mover", count, scope () => scene.[Friend]RunFrameUpdates());
		Measure("direct_mover", count, scope [&] () =>
			{
				for (let mover in movers)
					mover.Update(default, Time.FixedDeltaTime);
			});
		// The unified data path (docs/unified-ecs-networking.md): a [Component] struct on every object, as a script
		// reaches it and as a query walks it. Last, so that the rows above stay comparable with builds without it.
		let objects = scope List<GameObject>(count);
		for (let transform in transforms)
		{
			objects.Add(transform.GameObject);
			transform.GameObject.AddComponent<SyncedEcsMotion>(.() { speed = 1 });
		}
		Measure("data_script_get_set", count, scope [&] () =>
			{
				for (let obj in objects)
					obj.GetComponent<SyncedEcsMotion>().speed += 0.5f;
			});
		Measure("data_objects_with_query", count, scope [&] () =>
			{
				for (var chunk in scene.World.ObjectsWith<SyncedEcsMotion>())
				{
					let motions = chunk.Write<SyncedEcsMotion>();
					for (int i < chunk.Count)
						motions[i].speed += 0.5f;
				}
			});
		Measure("data_query_with_object", count, scope [&] () =>
			{
				float sum = 0;
				for (var chunk in scene.World.ObjectsWith<SyncedEcsMotion>())
				{
					let motions = chunk.Read<SyncedEcsMotion>();
					let links = chunk.Read<ObjectLink>();
					for (int i < chunk.Count)
						sum += motions[i].speed + links[i].gameObject.Transform.LocalPosition.x;
				}
				sSink.x = sum;
			});
		let beforeDestroy = Profiler.Now;
		scene.Clear();
		Console.WriteLine(scope $"PROFILE despawn count={count} ms={(Profiler.Now - beforeDestroy) / 1e6:0.000} checksum={sSink}");
		return 0;
	}
}
