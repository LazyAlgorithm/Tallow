using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// Ordinary prefab instances: every cube renders and moves; one in 100 has a kinematic collider, one in 50
/// ticks a behaviour tree and one in 20 uses Network Identity's offline fixed-tick Update. Live packet/replay
/// correctness is checked separately by the network suites, so this mode needs no session setup or networking code.
extension Bench
{
	List<GameObject> mSpawned = new .() ~ delete _;
	List<double> mDrawCounts = new .() ~ delete _;
	int mBodies, mTrees, mNetworked;
	double mCpuStart;
	int64 mAllocationsStart;

#if BF_PLATFORM_LINUX
	[CLink] static extern int64 clock();
	[CLink] static extern void* dlsym(void* handle, char8* symbol);
	static function uint64() sAllocationCount;
	static bool sAllocationChecked;
#endif

	static int64 AllocationCount()
	{
#if BF_PLATFORM_LINUX
		if (!sAllocationChecked)
		{
			sAllocationChecked = true;
			sAllocationCount = (.)dlsym(null, "tallow_bench_allocations");
		}
		if (sAllocationCount != null)
			return (int64)sAllocationCount();
#endif
		return -1;
	}

	static double CpuMilliseconds()
	{
#if BF_PLATFORM_LINUX
		// POSIX clock counts process CPU time in millionths of a second, including its worker threads.
		return clock() / 1000.0;
#else
		return -1;
#endif
	}

	void SpawnMixed()
	{
		for (int i < mCount)
		{
			Workload.Start(i, mHalfSize, let position, let velocity, let spin);
			let cube = Prefab.Instantiate(Scene, "Prefabs/MovingCube.tprefab", position, .Identity);
			Runtime.Assert(cube != null, "The mixed benchmark's MovingCube prefab is missing");
			mSpawned.Add(cube);
			let mover = cube.GetComponent<Mover>();
			mover.velocity = velocity;
			mover.spin = spin;
			mover.halfSize = mHalfSize;
			if (i % 100 == 0)
			{
				cube.AddComponent<BoxCollider>();
				var body = cube.AddComponent<Rigidbody>();
				body.isKinematic = true;
				body.useGravity = false;
				mBodies++;
			}
			if (i % 50 == 0)
			{
				var tree = cube.AddComponent<BehaviorTreeRunner>();
				tree.tree.Set("BehaviorTrees/Think.tbt");
				tree.tickInterval = 0.1f;
				mTrees++;
			}
			if (i % 20 == 0)
			{
				var identity = cube.AddComponent<NetworkIdentity>();
				identity.playerControlled = false;
				mNetworked++;
			}
		}
	}

	void FinishCounters(String line)
	{
		int64 aiTicks = 0;
		if (mMode == "ai")
		{
			// Capture how many decisions actually ran, not just that the AI
			// components existed. A broken scheduler must not benchmark as fast.
			for (let gameObject in mSpawned)
			{
				let runner = gameObject.GetComponent<BehaviorTreeRunner>();
				if (runner.IsValid)
					aiTicks += runner.TickCount;
			}
		}
		let allocations = AllocationCount();
		let cpu = CpuMilliseconds();
		let cpuPerFrame = cpu >= 0 ? (cpu - mCpuStart) / Math.Max(mFrameTimes.Count, 1) : -1;
		let destroyStart = Profiler.Now;
		if (mWorld != null)
		{
			// Drop queries before their owning world. Drawing has finished for the measured frames.
			RenderView.InstancedSources.Remove(mSource);
			DeleteAndNullify!(mSource);
			DeleteAndNullify!(mMove);
			DeleteAndNullify!(mDraw);
			DeleteAndNullify!(mWorld);
		}
		else
			Scene.DestroyImmediate(mSpawned);
		let destroyMs = (Profiler.Now - destroyStart) / 1e6;
		mSpawned.Clear();
		line.AppendF("\"process_cpu_ms_per_frame\": {:F3}, \"draw_calls_avg\": {:F1}, \"despawn_ms\": {:F3}, ", cpuPerFrame, Average(mDrawCounts), destroyMs);
		if (allocations >= 0)
			line.AppendF("\"allocation_count\": {}, ", allocations - mAllocationsStart);
		else
			line.Append("\"allocation_count\": null, ");
		line.AppendF("\"physics_bodies\": {}, \"behavior_trees\": {}, \"network_identities\": {}, ", mBodies, mTrees, mNetworked);
		line.AppendF("\"ai_agents\": {}, \"ai_targets\": {}, \"ai_tree_ticks\": {}, \"navigation_bake_ms\": {:F3}, ",
			mAiAgents, mAiTargets, aiTicks, mNavBakeMs);
		if (mMode == "ai")
		{
			let spatial = Scene.AISpatial;
			line.AppendF("\"ai_broadphase_builds\": {}, \"ai_object_queries\": {}, \"ai_object_candidates\": {}, ",
				spatial.Rebuilds, spatial.ObjectQueries, spatial.ObjectCandidates);
			line.AppendF("\"ai_obstacle_queries\": {}, \"ai_obstacle_candidates\": {}, ",
				spatial.ObstacleQueries, spatial.ObstacleCandidates);
		}
	}
}
