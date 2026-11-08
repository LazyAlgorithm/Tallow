using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// CPU-only Flecs microbenchmarks. No renderer, scene updates, Jolt or asset loading.
/// The same data/query is reused for each pass, and results are verified after measuring.
/// These are explicitly advanced ECS-path numbers, not normal GameObject-script throughput.
static class EcsMicroProfile
{
	const int Passes = 100;
	static double sSink;

	static void Measure(StringView label, int count, int touched, delegate void() body)
	{
		for (int i < 10)
			body();
		let start = Profiler.Now;
		for (int i < Passes)
			body();
		let elapsed = (Profiler.Now - start) / (double)Passes;
		Console.WriteLine(scope $"PROFILE {label} count={count} touched={touched} pass_ms={elapsed / 1e6:0.000000} ns_per_object={elapsed / Math.Max(touched, 1):0.000}");
	}

	public static int Run(int count)
	{
		if (count < 1)
			return 1;
		let initialMemory = ProfilerModules.ProcessMemory();
		let world = scope World();
		let entities = scope List<Entity>(count);
		let spawnStart = Profiler.Now;
		world.CreateMany<Pose>(count, entities);
		for (int i < count)
			world.Set<Motion>(entities[i], .() { velocity = .(1, 2, 3) });
		let spawnNs = Profiler.Now - spawnStart;
		Console.WriteLine(scope $"PROFILE ecs-spawn count={count} touched={count} pass_ms={spawnNs / 1e6:0.000000} ns_per_object={spawnNs / (double)count:0.000} memory_bytes={ProfilerModules.ProcessMemory() - initialMemory}");

		let query = scope Query<Pose, Motion>(world);
		Measure("ecs-packed-update", count, count, scope [&] () =>
			{
				for (var chunk in query)
				{
					let poses = chunk.Write<Pose>();
					let motions = chunk.Read<Motion>();
					for (int i < chunk.Count)
						poses[i].position += motions[i].velocity * 0.016f;
				}
			});
		Measure("ecs-packed-read", count, count, scope [&] () =>
			{
				double sum = 0;
				for (var chunk in query)
				{
					let poses = chunk.Read<Pose>();
					for (let pose in poses)
						sum += pose.position.x;
				}
				sSink = sum;
			});
		Measure("ecs-handle-get", count, count, scope [&] () =>
			{
				double sum = 0;
				for (let entity in entities)
					sum += world.Get<Pose>(entity).position.x;
				sSink = sum;
			});
		Measure("ecs-parallel-update", count, count, scope [&] () =>
			{
				query.ParallelFor(scope (chunk) =>
					{
						let poses = chunk.Write<Pose>();
						let motions = chunk.Read<Motion>();
						for (int i < chunk.Count)
							poses[i].position += motions[i].velocity * 0.016f;
					});
			});
		let touched = Math.Max(1, count / 10);
		Measure("ecs-structural-churn-10pct", count, touched, scope [&] () =>
			{
				for (int i < touched)
				{
					let entity = entities[i];
					if (world.Has<Marked>(entity))
						world.Remove<Marked>(entity);
					else
						world.Add<Marked>(entity);
				}
			});
		let position = world.Get<Pose>(entities[count - 1]).position;
		if (position.x <= 0 || position.y <= 0 || position.z <= 0)
		{
			Console.WriteLine("EcsMicroProfile: invalid final state");
			return 1;
		}
		Console.WriteLine(scope $"VERIFY ecs-state count={count} x={position.x:0.000} y={position.y:0.000} z={position.z:0.000} checksum={sSink:0.000}");
		return 0;
	}
}
