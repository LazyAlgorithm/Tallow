using System;
using System.Collections;
using Tallow;

namespace FoliageTests;

class Program
{
	static bool Check(bool condition, StringView name)
	{
		Console.WriteLine(scope $"{condition ? "PASS" : "FAIL"}: {name}");
		return condition;
	}

	public static int Main(String[] args)
	{
		Console.WriteLine("Foliage and wind tests (placing, saving and culling; drawing needs a graphics card)");
		bool ok = true;
		let scene = scope Scene();
		Scene.Active = scene;

		// ---- painting on level ground (no terrain, game not playing) ----
		let field = scene.CreateGameObject("Field");
		field.Transform.Position = .(0, 2, 0);
		let grass = field.AddComponent<Foliage>();
		grass.density = 4;
		let added = grass.Paint(.(10, 2, 10), 5);
		let full = 4 * Mathf.PI * 25;
		ok &= Check(added > full * 0.5f && added <= full + 1 && grass.Count == added, scope $"a brush stroke scatters about Density plants to the square metre ({added} of at most {(int)full})");
		bool inside = true, level = true;
		float nearest = float.MaxValue;
		for (int i < grass.Count)
		{
			let p = grass.PositionOf(i);
			inside &= (Vector3(p.x - 10, 0, p.z - 10)).Length <= 5.001f;
			level &= Math.Abs(p.y - 2) < 0.001f;
			for (int j = i + 1; j < Math.Min(grass.Count, i + 400); j++)
				nearest = Math.Min(nearest, (grass.PositionOf(j) - p).Length);
		}
		ok &= Check(inside && level, "every plant is inside the brush, on the ground");
		ok &= Check(nearest > 0.2f, scope $"plants keep apart ({nearest:0.00} m at the closest)");
		let again = grass.Paint(.(10, 2, 10), 5);
		ok &= Check(again < added * 0.6f, scope $"painting the same ground again adds few more ({again})");
		let small = grass.Paint(.(40, 2, 40), 5, 0.1f);
		ok &= Check(small > 5 && small < full * 0.2f, scope $"a brush held for a moment paints a little ({small})");

		// ---- erasing ----
		let before = grass.Count;
		let gone = grass.Erase(.(10, 2, 10), 2);
		bool hole = true;
		for (int i < grass.Count)
		{
			let p = grass.PositionOf(i);
			hole &= Vector3(p.x - 10, 0, p.z - 10).Length > 2;
		}
		ok &= Check(gone > 10 && grass.Count == before - gone && hole, scope $"erasing clears a circle ({gone} plants) and nothing else");

		// ---- one at a time, from code ----
		let trees = field.AddComponent<Foliage>();
		trees.mesh.Set("builtin:pine");
		trees.Add(.(100, 2, 100), 90, 2);
		trees.Add(.(104, 2, 100));
		ok &= Check(trees.Count == 2 && (trees.PositionOf(0) - Vector3(100, 2, 100)).Length < 0.001f, "plants can be placed one at a time");
		Color tint;
		float scale;
		let world = trees.WorldOf(0, out tint, out scale);
		ok &= Check(Math.Abs(scale - 2) < 0.001f && Math.Abs(world.m[12] - 100) < 0.001f && Math.Abs(world.m[13] - 2) < 0.001f, "a plant's matrix puts it where it was placed, at its size");
		trees.WorldOf(1, out tint, out scale);
		ok &= Check(scale >= trees.minScale && scale <= trees.maxScale, "a plant with no size given gets one between Min Scale and Max Scale");

		// ---- what a camera is given to draw ----
		let view = Matrix4.LookAt(.(10, 4, -20), .(10, 2, 10), .Up);
		let proj = Matrix4.Perspective(60, 16.0f / 9, 0.1f, 500, false);
		let frustum = Frustum(proj * view, false);
		List<int32> seen = scope .();
		grass.viewDistance = 200;
		grass.Visible(.(10, 4, -20), frustum, seen);
		let allNear = seen.Count;
		ok &= Check(allNear > grass.Count / 3, scope $"plants in front of the camera are drawn ({allNear} of {grass.Count})");
		seen.Clear();
		grass.viewDistance = 25;
		grass.Visible(.(10, 4, -20), frustum, seen);
		ok &= Check(seen.Count < allNear && seen.Count < grass.Count / 2, scope $"View Distance leaves the far ones out ({seen.Count})");
		seen.Clear();
		let behind = Frustum(proj * Matrix4.LookAt(.(10, 4, -20), .(10, 2, -60), .Up), false);
		grass.viewDistance = 200;
		grass.Visible(.(10, 4, -20), behind, seen);
		ok &= Check(seen.Count == 0, "plants behind the camera are not");

		// ---- saved with the scene and read back ----
		grass.OnBeforeSave();
		ok &= Check(grass.plants.Length > grass.Count * 20, "saving packs the plants into the component");
		let copy = scene.CreateGameObject("Copy");
		copy.Transform.Position = .(0, 2, 0);
		let read = copy.AddComponent<Foliage>();
		read.plants.Set(grass.plants);
		read.OnValidate();
		bool same = read.Count == grass.Count;
		for (int i = 0; same && i < grass.Count; i += 7)
			same &= (read.PositionOf(i) - grass.PositionOf(i)).Length < 0.0001f;
		ok &= Check(same, scope $"and reading them back gives every plant its place ({read.Count})");
		read.Clear();
		read.OnBeforeSave();
		ok &= Check(read.Count == 0 && read.plants.IsEmpty, "clearing empties it");

		// ---- wind ----
		let breeze = scene.CreateGameObject("Breeze").AddComponent<WindZone>();
		breeze.strength = 2;
		breeze.gusts = 0.8f;
		breeze.Transform.Rotation = Quaternion.Euler(0, 90, 0);
		let fan = scene.CreateGameObject("Fan").AddComponent<WindZone>();
		fan.shape = .Sphere;
		fan.radius = 10;
		fan.strength = 4;
		fan.Transform.Position = .(50, 0, 0);
		let far = Wind.At(scene, .(500, 0, 0));
		ok &= Check((far - breeze.Transform.Forward * 2).Length < 0.001f && Math.Abs(far.x - 2) < 0.01f, "a global zone blows everywhere, the way it faces");
		let middle = Wind.At(scene, .(50, 0, 0)), halfway = Wind.At(scene, .(50, 0, 5)), edge = Wind.At(scene, .(50, 0, 10.5f));
		ok &= Check((middle - far - Vector3(0, 0, 4)).Length < 0.01f && (halfway - far - Vector3(0, 0, 2)).Length < 0.01f && (edge - far).Length < 0.001f, "a sphere zone adds its wind inside its radius, fading to the edge");
		Vector4 global;
		Vector4[4] zones = default, push = default;
		Wind.Gather(scene, .(0, 0, 0), out global, ref zones, ref push);
		ok &= Check(Math.Abs(global.x - 2) < 0.01f && Math.Abs(global.w - 0.8f) < 0.001f && Math.Abs(zones[0].x - 50) < 0.001f && zones[0].w == 10 && Math.Abs(push[0].z - 4) < 0.001f && zones[1].w == 0, "the renderer is given the global wind and the zones near the camera");
		for (int i < 5)
		{
			let more = scene.CreateGameObject("More").AddComponent<WindZone>();
			more.shape = .Sphere;
			more.radius = 3;
			more.Transform.Position = .(5 + i * 8, 0, 0);
		}
		Wind.Gather(scene, .(0, 0, 0), out global, ref zones, ref push);
		ok &= Check(zones[0].x == 5 && zones[1].x == 13 && zones[2].x == 21 && zones[3].x == 29, "of many sphere zones the four nearest the camera are used, nearest first");
		breeze.Enabled = false;
		ok &= Check(Wind.At(scene, .(500, 0, 0)).Length < 0.001f, "a disabled zone blows nothing");

		// ---- things that push plants aside ----
		Vector4[8] places = default, pushes = default;
		FoliageBender.Gather(scene, .(0, 0, 0), ref places, ref pushes);
		ok &= Check(places[0].w == 0, "with nothing walking about, nothing pushes");
		let walker = scene.CreateGameObject("Walker");
		walker.Transform.Position = .(3, 1, 0);
		let controller = walker.AddComponent<CharacterController>();
		controller.center = .(0, 0.9f, 0);
		FoliageBender.Gather(scene, .(0, 0, 0), ref places, ref pushes);
		ok &= Check(Math.Abs(places[0].x - 3) < 0.001f && Math.Abs(places[0].y - 1) < 0.001f && places[0].w > 0.5f && pushes[0].x == 1 && places[1].w == 0, "a character pushes plants aside at its feet, with nothing added to it");
		let boulder = scene.CreateGameObject("Boulder");
		boulder.Transform.Position = .(1, 0, 0);
		let bender = boulder.AddComponent<FoliageBender>();
		bender.radius = 2;
		bender.strength = 0.5f;
		FoliageBender.Gather(scene, .(0, 0, 0), ref places, ref pushes);
		ok &= Check(places[0].x == 1 && places[0].w == 2 && pushes[0].x == 0.5f && places[1].x == 3, "a Foliage Bender pushes with its own reach and strength, and the nearest comes first");
		let tuned = walker.AddComponent<FoliageBender>();
		tuned.strength = 0;
		FoliageBender.Gather(scene, .(0, 0, 0), ref places, ref pushes);
		ok &= Check(places[0].x == 1 && places[1].w == 0, "a character with a Foliage Bender of strength 0 pushes nothing");
		tuned.strength = 1;
		for (int i < 10)
		{
			let more = scene.CreateGameObject("More").AddComponent<FoliageBender>();
			more.Transform.Position = .(10 + i * 2, 0, 0);
		}
		FoliageBender.Gather(scene, .(0, 0, 0), ref places, ref pushes);
		ok &= Check(places[7].w > 0 && places[7].x <= 20 && places[0].x == 1, "of many, the eight nearest the camera are used");

		Console.WriteLine(ok ? "ALL PASSED" : "SOME FAILED");
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
