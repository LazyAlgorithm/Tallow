using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// Measures ordinary script dispatch and Transform writes without creating a graphics device.
/// This isolates CPU work; it is not a rendering benchmark or a game frame-rate prediction.
static class ScriptCpuBench
{
	const int WarmupFrames = 120;

	public static int Run(int count, int frames)
	{
		if (count <= 0 || frames <= 0) return 1;
		let previous = Scene.Active;
		defer
		{
			Scene.Active = previous;
		}
		let scene = scope Scene();
		let samples = scope List<double>(frames);
		let halfSize = Workload.HalfSize(count);
		let memoryBefore = ProfilerModules.ProcessMemory();
		let spawnStart = SDL.SDL_GetTicksNS();
		for (int i < count)
		{
			Workload.Start(i, halfSize, let position, let velocity, let spin);
			let gameObject = scene.CreateGameObject("Mover");
			gameObject.Transform.LocalPosition = position;
			let mover = gameObject.AddComponent<Mover>();
			mover.velocity = velocity;
			mover.spin = spin;
			mover.halfSize = halfSize;
		}
		let spawnMs = (SDL.SDL_GetTicksNS() - spawnStart) / 1e6;
		scene.StartPlay();
		Time.DeltaTime = Time.FixedDeltaTime;
		Time.UnscaledDeltaTime = Time.FixedDeltaTime;
		double checksum = 0;
		for (int frame < WarmupFrames + frames)
		{
			let start = SDL.SDL_GetTicksNS();
			scene.Update();
			let elapsed = (SDL.SDL_GetTicksNS() - start) / 1e6;
			// Resolve the poses as render extraction would, so the next update starts with clean transforms.
			// Extraction is deliberately outside the reported Scene.Update interval.
			checksum = 0;
			for (let gameObject in scene.Objects)
				checksum += gameObject.Transform.LocalToWorld.Translation.x;
			if (frame >= WarmupFrames)
				samples.Add(elapsed);
		}
		let memoryAfter = ProfilerModules.ProcessMemory();
		let output = scope String();
		output.AppendF("{{\"mode\":\"script-cpu\",\"count\":{},\"frames\":{},", count, frames);
		output.AppendF("\"scene_update_avg_ms\":{:F6},\"scene_update_p99_ms\":{:F6},", Bench.[Friend]Average(samples), Bench.[Friend]Percentile(samples, 0.99));
		output.AppendF("\"checksum\":{:F6},", checksum);
		output.AppendF("\"spawn_ms\":{:F3},\"memory_before\":{},\"memory_after\":{}}}", spawnMs, memoryBefore, memoryAfter);
		Console.WriteLine(output);
		scene.StopPlay();
		return 0;
	}
}
