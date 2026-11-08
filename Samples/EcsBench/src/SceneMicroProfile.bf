using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// Headless GameObject creation, transform/hierarchy and scene serialization.
/// The saved scene is reused for the load measurement; no file I/O is included.
static class SceneMicroProfile
{
	static int sLoadedCount;

	static void Measure(StringView label, int count, int passes, delegate void() body)
	{
		for (int i < 2)
			body();
		let start = Profiler.Now;
		for (int i < passes)
			body();
		double ns = (Profiler.Now - start) / (double)passes;
		Console.WriteLine(scope $"PROFILE {label} count={count} pass_ms={ns / 1e6:0.000000} ns_per_object={ns / count:0.000}");
	}

	public static int Run(int count)
	{
		if (count < 1)
			return 1;
		let scene = scope Scene();
		let objects = scope List<GameObject>(count);
		let memory = ProfilerModules.ProcessMemory();
		let start = Profiler.Now;
		for (int i < count)
		{
			let obj = scene.CreateGameObject("SaveProbe");
			obj.Transform.LocalPosition = .(i % 101, i / 101, i % 37);
			objects.Add(obj);
		}
		double ns = Profiler.Now - start;
		Console.WriteLine(scope $"PROFILE scene-create count={count} pass_ms={ns / 1e6:0.000000} ns_per_object={ns / count:0.000} memory_bytes={ProfilerModules.ProcessMemory() - memory}");

		Measure("scene-transform-read", count, 40, scope [&] () =>
			{
				double sum = 0;
				for (let obj in objects)
					sum += obj.Transform.Position.x;
				sLoadedCount = (int32)sum;
			});
		let serialized = scope String();
		SceneSerializer.Save(scene, serialized);
		Console.WriteLine(scope $"PROFILE scene-serialized-size count={count} bytes={serialized.Length}");
		Measure("scene-save", count, 15, scope [&] () =>
			{
				let output = scope String();
				SceneSerializer.Save(scene, output);
				sLoadedCount = (int32)output.Length;
			});
		Measure("scene-load", count, 10, scope [&] () =>
			{
				let loaded = scope Scene();
				SceneSerializer.Load(loaded, serialized);
				sLoadedCount = (int32)loaded.Objects.Count;
			});
		if (sLoadedCount != count)
		{
			Console.WriteLine(scope $"SceneMicroProfile: load mismatch {sLoadedCount} != {count}");
			return 1;
		}
		Console.WriteLine(scope $"VERIFY scene-load count={count} restored={sLoadedCount}");
		return 0;
	}
}
