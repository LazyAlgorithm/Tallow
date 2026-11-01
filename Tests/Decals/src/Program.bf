using System;
using System.Collections;
using Tallow;

namespace DecalTests;

/// Decals (docs/decals.md): the Decal component's box and saving, the spawned-decal pool (spawning, lifetimes,
/// fading, the size limit, clearing) and the view the renderer sets aside for them. The drawing itself needs the
/// graphics card, which this fixture does not have; it is checked by eye in the Sandbox sample's Main scene.
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

	static bool Near(float a, float b, float tolerance = 0.0001f) => Math.Abs(a - b) <= tolerance;
	static bool Near(Vector3 a, Vector3 b, float tolerance = 0.0001f) => (a - b).Length <= tolerance;

	public static int Main(String[] args)
	{
		// ---- the component ----
		let scene = scope Scene();
		let poster = scene.CreateGameObject("Poster");
		let decal = poster.AddComponent<Decal>();
		Check(decal.size == Vector3(1, 1, 0.5f) && decal.opacity == 1 && decal.angleLimit == 70 && decal.texture.IsEmpty, "a new decal is a metre square and half a metre deep");
		poster.Transform.Position = .(2, 1, -3);
		poster.Transform.EulerAngles = .(0, 90, 0);
		poster.Transform.LocalScale = .(2, 2, 2);
		decal.size = .(1.5f, 0.5f, 0.25f);
		let volume = decal.BoxMatrix;
		Check(Near(volume.TransformPoint(.Zero), .(2, 1, -3)), "the box is centred on the object");
		let across = volume.TransformPoint(.(0.5f, 0, 0)) - volume.TransformPoint(.(-0.5f, 0, 0));
		let deep = volume.TransformPoint(.(0, 0, 0.5f)) - volume.TransformPoint(.(0, 0, -0.5f));
		Check(Near(across.Length, 3) && Near(deep.Length, 0.5f), "size is scaled by the object's scale");
		Check(Near(deep.Normalized, poster.Transform.Forward), "the picture is pressed along the object's forward axis");

		// ---- saving ----
		decal.texture.Set("Textures/poster.png");
		decal.color = .(1, 0.5f, 0.25f, 0.75f);
		decal.opacity = 0.6f;
		decal.metallic = 0.3f;
		decal.roughness = 0.4f;
		decal.angleLimit = 45;
		decal.unlit = true;
		decal.order = 3;
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let back = loaded.FindComponent<Decal>();
		Check(back != null && back.texture == "Textures/poster.png" && back.size == Vector3(1.5f, 0.5f, 0.25f) && back.color == Color(1, 0.5f, 0.25f, 0.75f), "a saved decal keeps its picture, size and colour");
		Check(back != null && Near(back.opacity, 0.6f) && Near(back.metallic, 0.3f) && Near(back.roughness, 0.4f) && back.angleLimit == 45 && back.unlit && back.order == 3, "and its surface, angle limit, lighting and order");
		let older = scope Scene();
		SceneSerializer.Load(older, "object \"Crate\"\n");
		Check(older.FindComponent<Decal>() == null && older.SpawnedDecals.IsEmpty, "a scene from before decals loads with none");

		// ---- spawned decals ----
		Time.Time = 10;
		Decals.Spawn(scene, .(0, 0, 0), .(0, 1, 0), "Textures/hole.png", 0.2f, 5);
		Check(scene.SpawnedDecals.Count == 1, "Decals.Spawn adds a decal to the scene");
		let hole = scene.SpawnedDecals[0];
		let holeDepth = hole.volume.TransformDirection(.(0, 0, 1));
		Check(Near(holeDepth.Normalized, .(0, -1, 0)) && Near(holeDepth.Length, 0.1f), "it is pressed into the surface, half as deep as it is wide");
		Check(Near(hole.volume.TransformDirection(.(1, 0, 0)).Length, 0.2f) && Near(hole.volume.TransformPoint(.Zero), .Zero), "it is centred on the point, as wide as asked");
		Check(hole.texture == "Textures/hole.png", "it keeps its own copy of the picture's path");
		Decals.Spawn(scene, .(1, 0, 0), .(1, 0, 0), "Textures/hole.png", 0.2f, 0, .White, 45);
		let wall = scene.SpawnedDecals[1];
		Check(Near(wall.volume.TransformDirection(.(0, 0, 1)).Normalized, .(-1, 0, 0)), "a mark on a wall faces out of the wall");
		let up = wall.volume.TransformDirection(.(0, 1, 0)).Normalized;
		Check(Near(Math.Abs(up.y), Math.Cos(45 * Mathf.Deg2Rad), 0.001f), "spin turns the picture about the normal");
		Decals.Spawn(scene, .Zero, .Zero, "x.png", 1);
		Decals.Spawn(scene, .Zero, .Up, "x.png", 0);
		Check(scene.SpawnedDecals.Count == 2, "no decal is made without a facing or a size");

		Time.Time = 14.5f;
		Check(Near(Decals.Fade(scene.SpawnedDecals[0]), 0.5f), "a decal fades over the last second of its life");
		Check(Decals.Fade(scene.SpawnedDecals[1]) == 1, "one with no lifetime does not fade");
		Time.Time = 15.01f;
		Decals.Expire(scene);
		Check(scene.SpawnedDecals.Count == 1 && scene.SpawnedDecals[0].lifetime == 0, "it is gone when its time is up, and the lasting one stays");
		Time.Time = 1;
		Decals.Expire(scene);
		Check(scene.SpawnedDecals.IsEmpty, "time going back (the scene restarted) clears the old marks");

		let oldLimit = Decals.MaxSpawned;
		Decals.MaxSpawned = 4;
		for (int i < 6)
			Decals.Spawn(scene, .(i, 0, 0), .Up, scope $"Textures/{i}.png" , 0.5f);
		Check(scene.SpawnedDecals.Count == 4 && scene.SpawnedDecals[0].texture == "Textures/2.png" && scene.SpawnedDecals[3].texture == "Textures/5.png", "a full pool makes way for new decals, oldest first");
		Decals.MaxSpawned = oldLimit;
		Decals.Clear(scene);
		Check(scene.SpawnedDecals.IsEmpty, "Decals.Clear removes them all");
		Decals.Spawn(scene, .Zero, .Up, "Textures/hole.png", 0.5f);
		scene.Clear();
		Check(scene.SpawnedDecals.IsEmpty, "clearing the scene clears its spawned decals");
		Decals.Spawn(null, .Zero, .Up, "Textures/hole.png", 0.5f);
		Check(true, "spawning into no scene is ignored");

		// ---- the renderer ----
		Check(RenderView.ViewCount == 23, "each RenderView sets a view aside for decals (and four for water)");

		Console.WriteLine(sFailures == 0 ? "All decal tests passed." : scope $"{sFailures} decal test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
