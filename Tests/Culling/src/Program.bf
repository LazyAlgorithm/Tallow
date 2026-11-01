using System;
using System.Collections;
using Tallow;

namespace CullingTests;

/// Drawing less (docs/lod.md, docs/occlusion-culling.md): LOD Groups (levels from names, picking a level from the
/// screen height, the bias, forcing a level, finding renderers again, simplified meshes). Drawing itself needs the
/// graphics card, which this fixture does not have; the Sandbox's Culling scene is checked by eye. Occlusion culling
/// (the CPU depth picture: what a wall hides, what it does not, the edges, the camera's back; picking occluders).
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

	static CameraData Camera(Vector3 position, float fieldOfView = 60)
	{
		CameraData camera = default;
		camera.position = position;
		camera.forward = .Forward;
		camera.fieldOfView = fieldOfView;
		camera.near = 0.1f;
		camera.far = 1000;
		camera.aspect = 16 / 9.0f;
		camera.view = Matrix4.LookAt(position, position + .Forward, .Up);
		camera.projection = Matrix4.Perspective(fieldOfView, camera.aspect, camera.near, camera.far, Gfx.HomogeneousDepth);
		return camera;
	}

	/// Two grids of quads a hair apart, one facing up and one down: a test of keeping faces that point apart.
	static Mesh Slab(int cells)
	{
		let mesh = new Mesh();
		for (int side < 2)
		{
			let y = side == 0 ? 0.01f : -0.01f;
			let normal = side == 0 ? Vector3.Up : Vector3.Down;
			for (int x < cells)
			{
				for (int z < cells)
				{
					let a = Vector3(x, y, z) / cells;
					let b = Vector3(x + 1, y, z) / cells;
					let c = Vector3(x + 1, y, z + 1) / cells;
					let d = Vector3(x, y, z + 1) / cells;
					if (side == 0)
						mesh.AddQuad(a, d, c, b, .White);
					else
						mesh.AddQuad(a, b, c, d, .White);
					for (int k < 4)
						mesh.Vertices[mesh.Vertices.Count - 1 - k].normal = normal;
				}
			}
		}
		mesh.RecalculateBounds();
		return mesh;
	}

	static void Lod()
	{
		// ---- names ----
		Check(LODGroup.LevelInName("Rock_LOD2") == 2 && LODGroup.LevelInName("rock_lod0") == 0 && LODGroup.LevelInName("Rock") == -1 && LODGroup.LevelInName("Rock_LOD") == -1 && LODGroup.LevelInName("LOD3") == -1 && LODGroup.LevelInName("RockLOD1") == -1, "_LOD<n> names give the level");

		// ---- a group of named children ----
		let scene = scope Scene();
		let rock = scene.CreateGameObject("Rock");
		let group = rock.AddComponent<LODGroup>();
		MeshRenderer Child(StringView name, StringView mesh)
		{
			let go = scene.CreateGameObject(name);
			go.Transform.SetParent(rock.Transform, false);
			let renderer = go.AddComponent<MeshRenderer>();
			renderer.mesh.Set(mesh);
			return renderer;
		}
		let lod0 = Child("Rock_LOD0", "builtin:sphere");
		let lod1 = Child("Rock_LOD1", "builtin:cube");
		let lod2 = Child("Rock_LOD2", "builtin:cube");
		let blob = Child("Shadow Blob", "builtin:cube");
		group.Refresh();
		Check(group.LevelCount == 3 && lod0.LodGroup == group && lod1.LodLevel == 1 && lod2.LodLevel == 2 && blob.LodLevel == -1, "the group finds its levels from its children's names");
		let mesh0 = lod0.ActiveMesh;
		let mesh1 = lod1.ActiveMesh;
		Check(group.MeshAt(lod0, mesh0, 0) == mesh0 && group.MeshAt(lod0, mesh0, 1) == null && group.MeshAt(lod1, mesh1, 1) == mesh1 && group.MeshAt(blob, blob.ActiveMesh, 2) != null && group.MeshAt(lod0, mesh0, -1) == null, "each renderer is drawn at its level; one without a level at all of them");

		// ---- picking a level ----
		group.level1Below = 0.4f;
		group.level2Below = 0.15f;
		group.level3Below = 0.05f;
		group.cullBelow = 0.01f;
		Check(group.LevelForHeight(0.9f) == 0 && group.LevelForHeight(0.3f) == 1 && group.LevelForHeight(0.1f) == 2 && group.LevelForHeight(0.03f) == 2 && group.LevelForHeight(0.005f) == -1, "the screen height picks the level (never past the last) and culls specks");
		// The sphere is a unit across: radius 0.866 (its box's half-diagonal).
		let radius = Math.Sqrt(3.0f) * 0.5f;
		let height = group.ScreenHeight(Camera(.(0, 0, -10)));
		Check(Near(height, radius / (10 * Math.Tan(30 * Mathf.Deg2Rad)), 0.001f), "screen height is the bounding sphere over the view's height at its distance");
		Check(group.LevelFor(Camera(.(0, 0, -1.5f))) == 0 && group.LevelFor(Camera(.(0, 0, -10))) == 1 && group.LevelFor(Camera(.(0, 0, -30))) == 2 && group.LevelFor(Camera(.(0, 0, -400))) == -1, "near cameras see level 0, far ones lower levels, very far ones nothing");
		LODGroup.Bias = 3;
		let biased = group.LevelFor(Camera(.(0, 0, -10.5f)));
		LODGroup.Bias = 1;
		Check(biased == 0, "a bias above 1 keeps detail farther away");
		LODGroup.ForceLevel = 2;
		let forced = group.LevelFor(Camera(.(0, 0, -1.5f)));
		LODGroup.ForceLevel = 7;
		let clamped = group.LevelFor(Camera(.(0, 0, -1.5f)));
		LODGroup.ForceLevel = -1;
		Check(forced == 2 && clamped == 2, "ForceLevel draws a level whatever the distance (at most the last)");

		// ---- the objects under it change ----
		let lod3 = Child("Rock_LOD3", "builtin:cube");
		group.OnFrame();
		Check(group.LevelCount == 4 && lod3.LodGroup == group && lod3.LodLevel == 3, "a new level child is found by itself");
		let inner = scene.CreateGameObject("Pebble");
		inner.Transform.SetParent(rock.Transform, false);
		let innerGroup = inner.AddComponent<LODGroup>();
		let pebble = scene.CreateGameObject("Pebble_LOD1");
		pebble.Transform.SetParent(inner.Transform, false);
		let pebbleRenderer = pebble.AddComponent<MeshRenderer>();
		innerGroup.Refresh();
		group.OnFrame();
		bool outerHasPebble = false;
		for (let r in group.Renderers)
			outerHasPebble |= r == pebbleRenderer;
		Check(pebbleRenderer.LodGroup == innerGroup && !outerHasPebble, "a group inside a group keeps its own renderers");
		rock.RemoveComponent(group);
		Check(lod0.LodGroup == null && lod1.LodGroup == null, "removing the group lets its renderers go");

		// ---- the group object's own renderer as level 0 ----
		let crate = scene.CreateGameObject("Crate");
		let own = crate.AddComponent<MeshRenderer>();
		own.mesh.Set("builtin:cube");
		let crateLow = scene.CreateGameObject("Crate_LOD1");
		crateLow.Transform.SetParent(crate.Transform, false);
		let low = crateLow.AddComponent<MeshRenderer>();
		low.mesh.Set("builtin:cube");
		let crateGroup = crate.AddComponent<LODGroup>();
		crateGroup.Refresh();
		Check(crateGroup.LevelCount == 2 && own.LodLevel == 0 && low.LodLevel == 1, "without a _LOD0, the group's own renderer is level 0");

		// ---- generated levels ----
		let slab = Slab(16);
		let full = slab.Indices.Count / 3;
		let half = MeshSimplifier.Simplify(slab, 0.25f);
		let kept = half.Indices.Count / 3;
		bool up = false, down = false;
		for (let v in half.Vertices)
		{
			up |= v.normal.y > 0.9f;
			down |= v.normal.y < -0.9f;
		}
		Check(kept < full / 2 && kept >= full / 8, scope $"simplifying keeps about the share of triangles asked for ({kept} of {full} for 25%)");
		Check(up && down, "faces turned apart are not merged, so hard edges and thin parts stay");
		Check(Near(half.Bounds.max.x - half.Bounds.min.x, 1, 0.15f) && Near(half.Bounds.max.z - half.Bounds.min.z, 1, 0.15f), "the simplified mesh keeps the same size");
		let cachedA = MeshSimplifier.Simplified(slab, 0.25f);
		let cachedB = MeshSimplifier.Simplified(slab, 0.25f);
		Check(cachedA == cachedB && cachedA != MeshSimplifier.Simplified(slab, 0.5f), "simplified meshes are made once and kept");
		MeshSimplifier.Forget(slab);
		delete half;
		delete slab;

		let scene2 = scope Scene();
		let tree = scene2.CreateGameObject("Tree");
		let renderer = tree.AddComponent<MeshRenderer>();
		renderer.mesh.Set("builtin:sphere");
		let generated = tree.AddComponent<LODGroup>();
		generated.source = .Generated;
		generated.generatedLevels = 3;
		generated.Refresh();
		let sphere = renderer.ActiveMesh;
		let level1 = generated.MeshAt(renderer, sphere, 1);
		let level2 = generated.MeshAt(renderer, sphere, 2);
		Check(generated.LevelCount == 3 && generated.MeshAt(renderer, sphere, 0) == sphere && level1 != null && level1 != sphere && level2.Indices.Count < level1.Indices.Count && level1.Indices.Count < sphere.Indices.Count, "Generated makes fewer triangles at each lower level");
		MeshSimplifier.Forget(sphere);
	}

	static Bounds Box(Vector3 center, Vector3 size) => .(center - size * 0.5f, center + size * 0.5f);

	static void Occlusion()
	{
		let camera = Camera(.Zero);
		let frustum = Frustum(camera.projection * camera.view, Gfx.HomogeneousDepth);
		let cube = Primitives.CreateCube();
		defer delete cube;
		cube.RecalculateBounds();
		let buffer = scope OcclusionBuffer();
		// A wall 10 m wide and high, 10 m ahead (it reaches 0.5 of the way to the view's edge either side).
		let wall = Matrix4.TRS(.(0, 0, 10), .Identity, .(10, 10, 0.5f));
		buffer.Begin(camera);
		buffer.AddOccluder(cube, wall);
		buffer.Finish();
		Check(buffer.OccluderTriangles == 12, "the wall's triangles are drawn into the picture");
		Check(!buffer.IsVisible(Box(.(0, 0, 20), .(1, 1, 1))), "a box behind the wall is hidden");
		Check(!buffer.IsVisible(Box(.(3, -3, 30), .(2, 2, 2))), "so is one farther behind, off centre");
		Check(buffer.IsVisible(Box(.(0, 0, 5), .(1, 1, 1))), "a box in front of the wall is not");
		Check(buffer.IsVisible(Box(.(15, 0, 20), .(1, 1, 1))), "nor one beside it, out from behind");
		Check(buffer.IsVisible(Box(.(0, 0, 10), .(10, 10, 0.5f))), "the wall does not hide itself");
		// Behind the wall's edge: half of it shows past the edge.
		Check(buffer.IsVisible(Box(.(10, 0, 20), .(1, 1, 1))), "a box showing past the wall's edge is drawn");
		// Peeking out past the edge by a fraction of one of the picture's pixels: the edge is not trusted. (The wall's
		// outline is its near face's edge, x 5 at z 9.75, which is x 10.26 at z 20.)
		let edge = 5 * 20 / 9.75f;
		Check(buffer.IsVisible(Box(.(edge, 0, 20), .(0.1f, 0.1f, 0.1f))), "a box peeking past the edge by less than a pixel is still drawn");
		Check(!buffer.IsVisible(Box(.(edge - 0.3f, 0, 20), .(0.1f, 0.1f, 0.1f))), "a box just inside the edge is hidden");
		Check(buffer.IsVisible(Box(.(0, 0, -5), .(1, 1, 1))) && buffer.IsVisible(Box(.(0, 0, 0), .(4, 4, 4))), "boxes behind or round the camera are drawn");
		Check(buffer.Culled == 3, "the picture counts what it hid");

		// A side wall running from behind the camera to far ahead: its long triangles cannot be drawn, so it is left
		// out (it hides less than it could, never more).
		buffer.Begin(camera);
		buffer.AddOccluder(cube, Matrix4.TRS(.(1, 0, 0), .Identity, .(0.2f, 10, 40)));
		buffer.Finish();
		Check(buffer.OccluderTriangles < 12 && buffer.IsVisible(Box(.(3, 0, 10), .(1, 1, 1))), "triangles reaching behind the camera are left out");

		// ---- picking occluders from a scene ----
		let scene = scope Scene();
		MeshRenderer Solid(StringView name, Vector3 position, Vector3 scale)
		{
			let go = scene.CreateGameObject(name);
			go.Transform.Position = position;
			go.Transform.LocalScale = scale;
			let renderer = go.AddComponent<MeshRenderer>();
			renderer.mesh.Set("builtin:cube");
			return renderer;
		}
		let bigWall = Solid("Wall", .(0, 0, 10), .(10, 10, 0.5f));
		let pebble = Solid("Pebble", .(1, 0, 6), .(0.1f, 0.1f, 0.1f));
		let glass = Solid("Glass", .(-2, 0, 8), .(4, 4, 0.1f));
		glass.color.a = 0.4f;
		let fence = Solid("Fence", .(2, 0, 8), .(4, 4, 0.1f));
		fence.occluder = .Never;
		let crate = Solid("Crate", .(0, 0, 9), .(3, 3, 3));
		crate.GameObject.AddComponent<Rigidbody>();
		let behind = Solid("Behind", .(0, 0, -10), .(10, 10, 1));
		buffer.Build(scene, camera, frustum);
		Check(buffer.Occluders == 1, "Auto picks the big solid wall, not a pebble, glass, a Never fence, a moving crate or what is behind the camera");
		pebble.occluder = .Always;
		crate.occluder = .Always;
		buffer.Build(scene, camera, frustum);
		Check(buffer.Occluders == 3, "Always makes small and moving things occluders too");
		OcclusionBuffer.TriangleBudget = 20;
		buffer.Build(scene, camera, frustum);
		OcclusionBuffer.TriangleBudget = 30000;
		Check(buffer.Occluders == 1, "the triangle budget stops after the biggest occluders on screen");
		Check(!buffer.IsVisible(Box(.(0, 0, 25), .(1, 1, 1))) && bigWall != null && behind != null, "and what they hide is still hidden");
	}

	public static int Main(String[] args)
	{
		Lod();
		Occlusion();
		Console.WriteLine(sFailures == 0 ? "All culling checks passed." : scope $"{sFailures} culling check(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
