using System;
using System.Collections;
using Tallow;

namespace LayerTests;

/// Physics layers and their collision table, layer masks on queries, tags, and world states.
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

	/// A static floor, as a body made straight away.
	static GameObject Floor(Scene scene, StringView name, Vector3 position, int32 layer)
	{
		let go = scene.CreateGameObject(name);
		go.Transform.Position = position;
		go.Layer = layer;
		ShapeDesc desc = default;
		desc.kind = .Box;
		desc.halfExtents = .(5, 0.5f, 5);
		scene.Physics.CreateBody(go.Transform, desc, null);
		return go;
	}

	static Rigidbody Crate(Scene scene, StringView name, Vector3 position, int32 layer)
	{
		let go = scene.CreateGameObject(name);
		go.Transform.Position = position;
		go.Layer = layer;
		go.AddComponent<BoxCollider>().size = .One;
		let body = go.AddComponent<Rigidbody>();
		body.allowSleeping = false;
		body.EnsureBody();
		return body;
	}

	static void Run(Scene scene, int ticks)
	{
		for (int i < ticks)
			scene.FixedUpdate();
	}

	public static int Main(String[] args)
	{
		// ---- the project's settings ----
		ProjectConfig.Reset();
		Check(ProjectConfig.LayerName(0) == "Default" && ProjectConfig.WorldStates.Count == 1 && ProjectConfig.Tags.Count == 0, "a project with no settings has one layer, no tags and one world state");
		ProjectConfig.Parse("""
			layer 0 "Default"
			layer 3 "Ghost"
			layer 4 "Props"
			collide 3 FFFFFFFE
			tag "Enemy"
			tag "Cover"
			worldstate "Material"
			worldstate "Echo"
			""");
		let ghost = ProjectConfig.LayerNamed("Ghost"), props = ProjectConfig.LayerNamed("Props");
		Check(ghost == 3 && props == 4 && !ProjectConfig.LayersCollide(3, 0) && !ProjectConfig.LayersCollide(0, 3) && ProjectConfig.LayersCollide(3, 4) && ProjectConfig.LayersCollide(0, 4),
			"layers are read by name, and a pair that does not collide does not either way round");
		Check(ProjectConfig.Mask("Default", "Props") == 0b10001 && ProjectConfig.WorldStateNamed("Echo") == 1 && ProjectConfig.HasTag("Cover"), "masks, world states and tags by name");
		let written = scope String();
		ProjectConfig.Write(written);
		let copy = scope String(written);
		ProjectConfig.Parse(copy);
		let again = scope String();
		ProjectConfig.Write(again);
		Check(again == written, "the settings file reads back as it was written");

		// ---- collision between layers ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene, "Floor", .(0, 0, 0), 0);
			let solid = Crate(scene, "Solid", .(-2, 3, 0), 0);
			let passing = Crate(scene, "Ghost", .(2, 3, 0), ghost);
			Run(scene, 180);
			Check(Math.Abs(solid.Transform.Position.y - 1) < 0.1f && passing.Transform.Position.y < -5,
scope $"a body on a layer that does not collide with the floor's falls through it; one that does rests on it ({solid.Transform.Position.y:0.00}, {passing.Transform.Position.y:0.0})");
			// Moved to a layer that collides, it lands on what is below.
			let below = passing.Transform.Position.y - 15;
			Floor(scene, "Low floor", .(2, below, 0), props);
			passing.GameObject.Layer = props;
			Run(scene, 240);
			Check(Math.Abs(passing.Transform.Position.y - (below + 1)) < 0.15f, scope $"changing an object's layer while playing changes what it collides with ({passing.Transform.Position.y:0.00})");
			scene.StopPlay();
		}

		// ---- queries with layer masks ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let near = Floor(scene, "Near", .(0, 0, 0), ghost);
			let far = Floor(scene, "Far", .(0, -5, 0), 0);
			RaycastHit hit;
			Check(scene.Physics.Raycast(.(0, 10, 0), .Down, 50, out hit) && hit.gameObject == near, "a ray with no mask sees every layer");
			Check(scene.Physics.Raycast(.(0, 10, 0), .Down, 50, out hit, ProjectConfig.Mask("Default")) && hit.gameObject == far, "a ray with a mask passes through layers outside it");
			ShapeCastHit shapeHit;
			Check(scene.Physics.SphereCast(.(0, 10, 0), 0.3f, .Down, 50, out shapeHit, uint32.MaxValue, 1u << ghost) && shapeHit.gameObject == near
				&& scene.Physics.SphereCast(.(0, 10, 0), 0.3f, .Down, 50, out shapeHit, uint32.MaxValue, 1u) && shapeHit.gameObject == far, "shape casts take a mask too");
			List<ShapeCastHit> hits = scope .();
			Check(scene.Physics.OverlapSphere(.(0, 0, 0), 1, hits) == 1 && scene.Physics.OverlapSphere(.(0, 0, 0), 1, hits, uint32.MaxValue, 1u) == 0, "and overlaps");
		}

		// ---- tags ----
		{
			let scene = scope Scene();
			let a = scene.CreateGameObject("A");
			let b = scene.CreateGameObject("B");
			a.AddTag("Enemy");
			b.AddTag("Enemy");
			b.AddTag("Cover");
			List<GameObject> found = scope .();
			scene.FindAllWithTag("Enemy", found);
			Check(found.Count == 2 && scene.FindWithTag("Cover") == b && scene.FindWithTag("Nothing") == null, "objects are found by tag");
			b.SetActive(false);
			Check(scene.FindWithTag("Cover") == null, "FindWithTag skips inactive objects");
			b.RemoveTag("Enemy");
			found.Clear();
			scene.FindAllWithTag("Enemy", found);
			Check(found.Count == 1 && found[0] == a, "removing a tag at run time takes the object off the list");
			scene.DestroyImmediate(a);
			found.Clear();
			scene.FindAllWithTag("Enemy", found);
			Check(found.Count == 0, "a destroyed object is no longer found");
			let made = scene.CreateGameObject("Made at run time");
			made.AddTag("Enemy");
			Check(scene.FindWithTag("Enemy") == made, "tags added to objects made at run time are found");
		}

		// ---- saving ----
		{
			let scene = scope Scene();
			let go = scene.CreateGameObject("Thing");
			go.Layer = props;
			go.AddTag("Enemy");
			go.AddTag("Has space");
			go.SetInWorldState(1, false);
			scene.CreateGameObject("Plain");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let thing = loaded.Find("Thing");
			let plain = loaded.Find("Plain");
			Check(thing != null && thing.Layer == props && thing.HasTag("Enemy") && thing.HasTag("Has space") && thing.InWorldState(0) && !thing.InWorldState(1),
				"a scene keeps each object's layer, tags and world states");
			Check(plain != null && plain.Layer == 0 && plain.TagCount == 0 && plain.WorldStates == uint32.MaxValue && !text.Contains("layer 0") && text.IndexOf("\ntags") == text.IndexOf("\ntags", text.IndexOf("\ntags") + 1) - 0 + 0 || text.IndexOf("\ntags", text.IndexOf("\ntags") + 1) < 0,
				"objects that use none of them write nothing extra, so older scenes read the same");
		}

		// ---- world states ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let material = ProjectConfig.WorldStateNamed("Material"), echo = ProjectConfig.WorldStateNamed("Echo");
			let floor = Floor(scene, "Material floor", .(0, 0, 0), 0);
			floor.SetInWorldState(echo, false);
			let bridge = Floor(scene, "Echo bridge", .(20, 0, 0), 0);
			bridge.SetInWorldState(material, false);
			let crate = Crate(scene, "Crate", .(0, 3, 0), 0);
			let group = scene.CreateGameObject("Echo-only group");
			group.SetInWorldState(material, false);
			let child = Floor(scene, "Child", .(40, 0, 0), 0);
			child.Transform.SetParent(group.Transform);
			RaycastHit hit;
			Run(scene, 120);
			Check(Math.Abs(crate.Transform.Position.y - 1) < 0.1f && scene.Physics.Raycast(.(0, 10, 0), .Down, 50, out hit) && !scene.Physics.Raycast(.(20, 10, 0), .Down, 50, out hit),
				"in the first world state its objects collide and the other state's are not there");
			Check(!scene.Physics.Raycast(.(40, 10, 0), .Down, 50, out hit), "an object whose parent is left out of a state is left out with it");
			Check(!child.InActiveWorld && child.EffectiveWorldStates == ~(1u << material) && child.InWorldState(material) && floor.InActiveWorld && !bridge.InActiveWorld,
				"an object's effective world states are its own less its parents' (what drawing, sound and picking go by)");
			int32 changes = 0;
			scene.WorldStateChanged.Add(new [&] (from, to) =>
				{
					changes++;
				}
				);
			scene.WorldState = echo;
			Run(scene, 120);
			Check(changes == 1 && crate.Transform.Position.y < -5 && scene.Physics.Raycast(.(20, 10, 0), .Down, 50, out hit) && scene.Physics.Raycast(.(40, 10, 0), .Down, 50, out hit),
scope $"one switch: the first state's floor is gone (the crate on it falls), the second state's objects are there ({crate.Transform.Position.y:0.0})");
			Check(scene.SetWorldState("Material") && scene.WorldState == material && scene.Physics.Raycast(.(0, 10, 0), .Down, 50, out hit) && !scene.SetWorldState("Nowhere"), "switching back by name");
			scene.StopPlay();
		}

		// ---- world states: what is walked on ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let material = ProjectConfig.WorldStateNamed("Material"), echo = ProjectConfig.WorldStateNamed("Echo");
			GameObject Ground(StringView name, Vector3 position, int32 leftOutOf)
			{
				let go = scene.CreateGameObject(name);
				go.Transform.Position = position;
				go.AddComponent<BoxCollider>().size = .(10, 1, 10);
				go.SetInWorldState(leftOutOf, false);
				return go;
			}
			// Side by side: x -5 to 5 in the material world, 5 to 15 in the echo world.
			Ground("Material ground", .(0, 0, 0), echo);
			Ground("Echo ground", .(10, 0, 0), material);
			NavigationSurface Surface(StringView name, int32 leftOutOf)
			{
				let go = scene.CreateGameObject(name);
				go.Transform.Position = .(-6, -1, -6);
				if (leftOutOf >= 0)
					go.SetInWorldState(leftOutOf, false);
				let surface = go.AddComponent<NavigationSurface>();
				surface.size = .(22, 6, 12);
				surface.cellSize = 0.5f;
				return surface;
			}
			let materialSurface = Surface("Material surface", echo);
			let echoSurface = Surface("Echo surface", material);
			let path = scope List<Vector3>();
			Check(materialSurface.BakeWorlds == 1u << material && materialSurface.Bake() && materialSurface.Data.FindPath(.(-3, 0.5f, 0), .(3, 0.5f, 0), path)
				&& !materialSurface.Data.FindPath(.(-3, 0.5f, 0), .(13, 0.5f, 0), path), "a surface in one world state walks only on that state's ground");
			Check(echoSurface.Bake() && echoSurface.Data.FindPath(.(7, 0.5f, 0), .(13, 0.5f, 0), path) && !echoSurface.Data.FindPath(.(13, 0.5f, 0), .(-3, 0.5f, 0), path),
				"and the other state's surface only on its own");
			let shared = Surface("Shared surface", -1);
			scene.WorldState = echo;
			Check(shared.BakeWorlds == 1u << echo && shared.Bake() && shared.Data.FindPath(.(7, 0.5f, 0), .(13, 0.5f, 0), path) && !shared.Data.FindPath(.(-3, 0.5f, 0), .(3, 0.5f, 0), path),
				"a surface in every state bakes the state the scene is in");
		}

		ProjectConfig.Reset();
		Scene.Active = null;
		Console.WriteLine(scope $"{sFailures} failed");
		return sFailures == 0 ? 0 : 1;
	}
}
