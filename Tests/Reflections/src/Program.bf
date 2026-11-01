using System;
using Tallow;

namespace ReflectionsTests;

/// Reflections (docs/reflections.md): which probe lights what (boxes, blend distance, importance, the smaller box),
/// how much of it a point gets, when a probe captures again, the cubes' sizes and levels, the quality settings and
/// the scene's reflection intensity in its file. Drawing needs a graphics card: `python3 run.py`.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	static ReflectionProbe Probe(Scene scene, StringView name, Vector3 position, Vector3 size, float blend = 1)
	{
		let probe = scene.CreateGameObject(name).AddComponent<ReflectionProbe>();
		probe.Transform.Position = position;
		probe.size = size;
		probe.blendDistance = blend;
		return probe;
	}

	public static int Main(String[] args)
	{
		let scene = scope Scene();

		// ---- the box ----
		let room = Probe(scene, "Room", .(0, 2, 0), .(8, 4, 8), 1);
		let area = room.WorldBox;
		Check(area.min == Vector3(-4, 0, -4) && area.max == Vector3(4, 4, 4), "a probe's box is its size around the object");
		room.Transform.LocalScale = .(2, 1, 1);
		Check(room.WorldBox.max.x == 8, "and scales with the object");
		room.Transform.LocalScale = .(1, 1, 1);
		Check(room.Weight(.(0, 1, 0)) == 1 && room.Weight(.(3.9f, 0.1f, 3.9f)) == 1, "inside the box a point gets all of the probe, up to its walls");
		Check(Math.Abs(room.Weight(.(4.5f, 2, 0)) - 0.5f) < 0.001f && room.Weight(.(5.5f, 2, 0)) == 0, "outside, it fades over the blend distance");
		Check(Math.Abs(room.Outside(.(7, 6, 0)) - Math.Sqrt(9.0f + 4.0f)) < 0.001f, "distance outside is to the nearest point of the box");
		room.captureOffset = .(0, -0.5f, 0);
		Check(room.CapturePoint == Vector3(0, 1.5f, 0), "it sees from its position plus the capture offset");

		// ---- choosing ----
		let cupboard = Probe(scene, "Cupboard", .(2, 1, 2), .(1, 2, 1), 0.2f);
		let hall = Probe(scene, "Hall", .(20, 2, 0), .(30, 4, 6), 1);
		Reflections.Ready.Clear();
		Reflections.Ready.Add(room);
		Reflections.Ready.Add(cupboard);
		Reflections.Ready.Add(hall);
		Check(Reflections.Pick(.(-2, 1, -2), 0.3f) == 0, "a thing in the room gets the room");
		Check(Reflections.Pick(.(2, 1, 2), 0.3f) == 1, "where boxes overlap, the smaller one wins");
		cupboard.importance = -1;
		Check(Reflections.Pick(.(2, 1, 2), 0.3f) == 0, "unless the bigger one is more important");
		cupboard.importance = 0;
		Check(Reflections.Pick(.(10, 1, 0), 0.3f) == 2, "in the hall, the hall");
		Check(Reflections.Pick(.(0, 1, 40), 0.5f) == -1, "far from every probe, the sky alone (-1)");
		Check(Reflections.Pick(.(0, 1, 5.5f), 0.2f) == -1 && Reflections.Pick(.(0, 1, 5.5f), 1.0f) == 0, "a big thing reaching into a box's blend distance gets it, a small one beside it does not");
		cupboard.importance = 2;
		Check(Reflections.Pick(.(-2, 1, -2), 6) == 0, "a big thing in the room keeps the room's probe, though it reaches a more important one beside it");
		cupboard.importance = 0;
		Reflections.Ready.Clear();

		// ---- capturing again ----
		Check(room.WantsCapture(0), "a new probe wants capturing");
		room.CaptureStarted(0);
		room.CaptureFinished(5);
		Check(!room.WantsCapture(0) && room.Captured && room.LastLevel == 5, "once captured it does not");
		room.Transform.Position = .(0, 2, 1);
		Check(room.WantsCapture(0), "moved in the editor, it captures again");
		room.CaptureStarted(0);
		room.CaptureFinished(5);
		room.size = .(8, 5, 8);
		Check(room.WantsCapture(0), "and when its box changes");
		room.CaptureStarted(0);
		room.CaptureFinished(5);
		Check(room.WantsCapture(1), "and when the quality's cube size changes (a new generation)");
		room.CaptureStarted(1);
		room.CaptureFinished(5);
		room.Capture();
		Check(room.WantsCapture(1), "and when asked to");

		// ---- sizes ----
		Check(Reflections.LastLevelFor(128) == 5 && Reflections.LastLevelFor(64) == 4 && Reflections.LastLevelFor(32) == 3, "a cube's levels halve down to 4 x 4: 128 has six (128 to 4)");
		let probeSize = Reflections.Resolution;
		room.resolution = 0;
		Check(Reflections.SizeOf(room) == probeSize, scope $"a probe without a size of its own uses the quality's ({probeSize})");
		room.resolution = 100;
		Check(Reflections.SizeOf(room) == 128, "its own size is rounded up to a power of two");
		room.resolution = 5000;
		Check(Reflections.SizeOf(room) == 512, "and kept to 512 at most");

		// ---- quality ----
		Quality.Set(.Low);
		Check(!Reflections.ProbesEnabled && Reflections.Resolution == 64, "Low leaves probes out (the sky is still mirrored)");
		Quality.Set(.Ultra);
		Check(Reflections.ProbesEnabled && Reflections.Resolution == 256, "Ultra uses 256 x 256 cubes");
		Quality.Set(.High);
		Check(Reflections.ProbesEnabled && Reflections.Resolution == 128, "High, 128 x 128");
		var custom = Quality.Preset(.High);
		custom.reflectionProbes = false;
		custom.reflectionSize = 32;
		let text = scope String();
		Quality.Write(custom, text);
		Check(Quality.Read(text, .()) == custom, "the reflection settings are saved with the others");

		// ---- the scene file ----
		let saved = scope String();
		scene.Environment.reflectionIntensity = 0.4f;
		SceneSerializer.Save(scene, saved);
		Check(saved.Contains("env reflectionIntensity 0.4"), "a scene's reflection intensity is saved");
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, saved);
		Check(Math.Abs(loaded.Environment.reflectionIntensity - 0.4f) < 0.001f, "and read back");
		let plain = scope Scene();
		let plainText = scope String();
		SceneSerializer.Save(plain, plainText);
		Check(!plainText.Contains("reflectionIntensity"), "a scene left at 1 does not write it (older scenes read as 1)");
		Check(saved.Contains("component Tallow.ReflectionProbe") && loaded.ComponentsOfType(typeof(ReflectionProbe)).Count == 3, "probes are saved and loaded with the scene");

		Console.WriteLine(scope $"\n{sFailures} failure(s)");
		return sFailures == 0 ? 0 : 1;
	}
}
