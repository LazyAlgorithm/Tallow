using System;
using System.Collections;
using System.IO;
using Tallow;

namespace BakingTests;

/// Baked lighting (docs/baked-lighting.md), without a graphics card: lightmap coordinates (every triangle a place of
/// its own, the same every time), the baker's light against the shader's sums (the sky on an open floor, a Baked Only
/// light, its shadow, a corner's darkness, colour bounced off a wall, a light drawn live left out but its bounce kept),
/// light probes (open air, beside a coloured wall, inside a solid box), RGBM and half floats, the probe file, writing
/// a bake into a project and clearing it. The pictures in the editor are checked by `run.py`.
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

	static bool Near(float a, float b, float tolerance) => Math.Abs(a - b) <= tolerance;
	static float Grey(Vector3 v) => (v.x + v.y + v.z) / 3;
	static Vector3 Linear(Color c, float scale = 1) => .(Math.Pow(c.r, 2.2f) * scale, Math.Pow(c.g, 2.2f) * scale, Math.Pow(c.b, 2.2f) * scale);

	/// How many triangles cover each point of a fine grid over the unit square (more than one: overlap), and whether
	/// every coordinate is inside it.
	static void Coverage(Span<Mesh> meshes, out int overlaps, out bool inside)
	{
		const int N = 256;
		let count = scope uint8[N * N];
		inside = true;
		for (let mesh in meshes)
		{
			for (let v in mesh.Vertices)
				inside &= v.uv2.x >= 0 && v.uv2.y >= 0 && v.uv2.x <= 1 && v.uv2.y <= 1;
			for (int t < mesh.Indices.Count / 3)
			{
				let a = mesh.Vertices[mesh.Indices[t * 3]].uv2 * N, b = mesh.Vertices[mesh.Indices[t * 3 + 1]].uv2 * N, c = mesh.Vertices[mesh.Indices[t * 3 + 2]].uv2 * N;
				for (int y < N)
				{
					for (int x < N)
					{
						// Inside, not on an edge two triangles share.
						let w = LightBaker.Closest(.(x + 0.5f, y + 0.5f), a, b, c, let distance);
						if (distance == 0 && Math.Min(w.x, Math.Min(w.y, w.z)) > 1e-4f && count[y * N + x] < 255)
							count[y * N + x]++;
					}
				}
			}
		}
		overlaps = 0;
		for (let c in count)
		{
			if (c > 1)
				overlaps++;
		}
	}

	static Mesh Copy(Mesh mesh)
	{
		let copy = new Mesh();
		for (let v in mesh.Vertices)
			copy.Vertices.Add(v);
		for (let i in mesh.Indices)
			copy.Indices.Add(i);
		return copy;
	}

	static void Coordinates()
	{
		for (let make in StringView[?]("cube", "sphere", "cylinder", "plane", "capsule"))
		{
			Mesh mesh;
			switch (make)
			{
			case "cube": mesh = Primitives.CreateCube();
			case "sphere": mesh = Primitives.CreateSphere();
			case "cylinder": mesh = Primitives.CreateCylinder();
			case "capsule": mesh = Primitives.CreateCapsule();
			default: mesh = Primitives.CreatePlane();
			}
			defer delete mesh;
			let triangles = mesh.Indices.Count;
			let other = Copy(mesh);
			defer delete other;
			Check(LightmapUV.Ensure(mesh) && mesh.LightmapUVs && mesh.Indices.Count == triangles, scope $"{make}: lightmap coordinates made, triangles kept");
			var one = mesh;
			Coverage(.(&one, 1), let overlaps, let inside);
			Check(inside && overlaps == 0, scope $"{make}: every triangle has a place of its own in the square ({overlaps} points covered twice)");
			LightmapUV.Ensure(other);
			var same = other.Vertices.Count == mesh.Vertices.Count;
			for (int i = 0; same && i < mesh.Vertices.Count; i++)
				same &= mesh.Vertices[i].uv2 == other.Vertices[i].uv2 && mesh.Vertices[i].position == other.Vertices[i].position;
			Check(same, scope $"{make}: the same mesh gets exactly the same coordinates again (the game makes them as the editor did)");
		}

		let cube = Primitives.CreateCube();
		defer delete cube;
		LightmapUV.Ensure(cube);
		// Six faces at right angles: six charts, so each face's four corners are its own.
		Check(cube.Vertices.Count == 24 && Near(cube.LightmapUVScale, cube.LightmapUVScale, 0) && cube.LightmapUVScale > 0.1f, scope $"a cube's faces are charts of their own ({cube.Vertices.Count} vertices)");
		let before = cube.Vertices[3].uv2;
		LightmapUV.Ensure(cube);
		Check(cube.Vertices[3].uv2 == before, "coordinates already made are kept");

		// Two parts of one model share the square.
		let a = Primitives.CreateCube(), b = Primitives.CreateSphere();
		defer
		{
			delete a;
			delete b;
		}
		Mesh[2] parts = .(a, b);
		LightmapUV.Ensure(parts);
		Coverage(parts, let partOverlaps, let partsInside);
		Check(partsInside && partOverlaps == 0 && a.LightmapUVScale == b.LightmapUVScale, "a model's parts are laid out together without overlapping");

		// A cube stretched into a slab: a copy laid out for the stretch, its broad faces taking most of the square.
		let scene = scope Scene();
		let slab = Add(scene, "builtin:cube", .(0, 0, 0), .(10, 0.2f, 10)).GetComponent<MeshRenderer>();
		let slabMeshes = scope List<Mesh>();
		Check(LightmapUV.MeshesFor(slab, slabMeshes) && slabMeshes[0] != slab.ActiveMesh && slabMeshes[0].LightmapUVs, "a stretched object gets a copy of its mesh laid out for the stretch");
		var topArea = 0.0f;
		let copy = slabMeshes[0];
		for (int t < copy.Indices.Count / 3)
		{
			let va = copy.Vertices[copy.Indices[t * 3]], vb = copy.Vertices[copy.Indices[t * 3 + 1]], vc = copy.Vertices[copy.Indices[t * 3 + 2]];
			if (va.normal.y > 0.9f)
			{
				let du = vb.uv2 - va.uv2, dv = vc.uv2 - va.uv2;
				topArea += Math.Abs(du.x * dv.y - du.y * dv.x) * 0.5f;
			}
		}
		// Top and bottom are the same size, so together they fill under half the square.
		Check(topArea > 0.18f, scope $"its broad top takes {topArea * 100:0}% of the square, its thin sides little");
		Coverage(slabMeshes, let slabOverlaps, let slabInside);
		Check(slabInside && slabOverlaps == 0, "and nothing overlaps");
		let other = Add(scene, "builtin:cube", .(5, 0, 0), .(20, 0.4f, 20)).GetComponent<MeshRenderer>();
		let otherMeshes = scope List<Mesh>();
		LightmapUV.MeshesFor(other, otherMeshes);
		Check(otherMeshes[0] == slabMeshes[0], "objects stretched alike share the copy");
		let even = Add(scene, "builtin:cube", .(9, 0, 0), .(3, 3, 3)).GetComponent<MeshRenderer>();
		let evenMeshes = scope List<Mesh>();
		LightmapUV.MeshesFor(even, evenMeshes);
		Check(evenMeshes[0] == even.ActiveMesh, "an evenly scaled object uses the mesh itself");
		Check(LightmapUV.Stretch(Matrix4.TRS(.Zero, Quaternion.Euler(0, 37, 0), .(4, 1, 2))) == Vector3(1, 0.25f, 0.5f), "the stretch is in steps the game repeats exactly");

		let dynamic = Primitives.CreateCube();
		defer delete dynamic;
		dynamic.VertexSource = a;
		Check(!LightmapUV.Ensure(dynamic), "a mesh drawing another's vertices gets none");
		dynamic.VertexSource = null;

		let w = LightBaker.Closest(.(0.25f, 0.25f), .(0, 0), .(1, 0), .(0, 1), let inner);
		LightBaker.Closest(.(2, 0), .(0, 0), .(1, 0), .(0, 1), let outer);
		Check(inner == 0 && Near(w.x, 0.5f, 1e-5f) && Near(w.y, 0.25f, 1e-5f) && Near(outer, 1, 1e-5f), "a point's weights in a triangle, and its distance outside one");
	}

	static GameObject Add(Scene scene, StringView mesh, Vector3 position, Vector3 scale, Color color = .White, bool baked = true)
	{
		let go = scene.CreateGameObject(mesh);
		go.Transform.Position = position;
		go.Transform.LocalScale = scale;
		let renderer = go.AddComponent<MeshRenderer>();
		renderer.mesh.Set(mesh);
		renderer.color = color;
		renderer.bakedLighting = baked;
		return go;
	}

	static Light AddLight(Scene scene, Vector3 position, float range, Color color, float intensity, bool bakedOnly)
	{
		let go = scene.CreateGameObject("Light");
		go.Transform.Position = position;
		let light = go.AddComponent<Light>();
		light.type = .Point;
		light.range = range;
		light.color = color;
		light.intensity = intensity;
		light.bakedOnly = bakedOnly;
		light.castShadows = true;
		return light;
	}

	static BakeSettings Quick()
	{
		let settings = new BakeSettings();
		settings.texelsPerMetre = 4;
		settings.samples = 64;
		settings.bounces = 2;
		settings.probeSpacing = 2;
		settings.probeSamples = 128;
		return settings;
	}

	/// The floor's light at a point, by its lightmap coordinates (the plane's are a square laid on x and z).
	static Vector3 FloorAt(LightBaker baker, MeshRenderer floor, Vector3 world)
	{
		let meshes = scope List<Mesh>();
		LightmapUV.MeshesFor(floor, meshes);
		let mesh = meshes[0];
		let local = floor.Transform.Position;
		let scale = floor.Transform.LocalScale;
		let p = Vector3((world.x - local.x) / scale.x, 0, (world.z - local.z) / scale.z);
		// The vertex nearest in each direction: the plane is a single chart, so uv2 is linear in position.
		let v0 = mesh.Vertices[0], v1 = mesh.Vertices[1], v2 = mesh.Vertices[2];
		let e1 = v1.position - v0.position, e2 = v2.position - v0.position, d = p - v0.position;
		let det = e1.x * e2.z - e1.z * e2.x;
		let s = (d.x * e2.z - d.z * e2.x) / det, t = (e1.x * d.z - e1.z * d.x) / det;
		let uv = v0.uv2 + (v1.uv2 - v0.uv2) * s + (v2.uv2 - v0.uv2) * t;
		return baker.LightAt(floor, uv);
	}

	static void Sky()
	{
		let scene = scope Scene();
		// Grey, so that the floor gives back less than the sky.
		let floor = Add(scene, "builtin:plane", .(0, 0, 0), .(2, 1, 2), .(0.5f, 0.5f, 0.5f)).GetComponent<MeshRenderer>();
		let settings = Quick();
		defer delete settings;
		let baker = scope LightBaker(scene, settings);
		baker.Run();
		let sky = Linear(scene.Environment.ambientSky, scene.Environment.ambientIntensity);
		let middle = FloorAt(baker, floor, .(0, 0, 0));
		Check(baker.Objects.Count == 1 && baker.Atlases.Count == 1 && baker.TexelCount > 0, scope $"one floor, one lightmap ({baker.TexelCount} texels)");
		Check(Near(Grey(middle), Grey(sky), Grey(sky) * 0.04f), scope $"an open floor gets the sky as the scene's ambient colours give it ({Grey(middle):0.000} against {Grey(sky):0.000})");
		Check(baker.Probes != null && baker.Probes.Count > 8, "light probes are baked too");
		let probe = baker.Probes.Sample(.(0, 1, 0), .(0, 1, 0));
		Check(Near(Grey(probe), Grey(sky), Grey(sky) * 0.08f), scope $"a probe above the floor lights an upward surface like the sky ({Grey(probe):0.000})");
		let below = baker.Probes.Sample(.(0, 1, 0), .(0, -1, 0));
		Check(Grey(below) < Grey(probe) * 0.8f, "and a downward one by the floor's own light, darker");

		// A mirrored floor still faces up.
		let mirrored = scope Scene();
		let flipped = Add(mirrored, "builtin:plane", .(0, 0, 0), .(-2, 1, 2)).GetComponent<MeshRenderer>();
		let mirrorBaker = scope LightBaker(mirrored, settings);
		mirrorBaker.Run();
		Check(Near(Grey(FloorAt(mirrorBaker, flipped, .(0, 0, 0))), Grey(middle), Grey(middle) * 0.05f), "a mirrored object is baked the same");
	}

	static void Lights()
	{
		let settings = Quick();
		defer delete settings;
		let scene = scope Scene();
		scene.Environment.ambientIntensity = 0;
		let floor = Add(scene, "builtin:plane", .(0, 0, 0), .(2, 1, 2)).GetComponent<MeshRenderer>();
		AddLight(scene, .(0, 2, 0), 10, .White, 3, true);
		// A box between the light and one spot on the floor.
		Add(scene, "builtin:cube", .(3, 1, 0), .(0.6f, 0.6f, 0.6f));
		let baker = scope LightBaker(scene, settings);
		baker.Run();
		// The shader's sum for a point light: colour * falloff^2 / (1 + 0.1 d^2) * n.l.
		float Expected(Vector3 at)
		{
			let offset = Vector3(0, 2, 0) - at;
			let d = offset.Length;
			let falloff = 1 - d / 10;
			return 3 * falloff * falloff / (1 + d * d * 0.1f) * (offset.y / d);
		}
		let under = Grey(FloorAt(baker, floor, .(0.5f, 0, 0.5f)));
		let open = Grey(FloorAt(baker, floor, .(-4, 0, 0)));
		let shaded = Grey(FloorAt(baker, floor, .(4.5f, 0, 0)));
		Check(Near(under, Expected(.(0.5f, 0, 0.5f)), Expected(.(0.5f, 0, 0.5f)) * 0.06f), scope $"a Baked Only light lights the floor as the shader would ({under:0.000} against {Expected(.(0.5f, 0, 0.5f)):0.000})");
		Check(Near(open, Expected(.(-4, 0, 0)), Expected(.(-4, 0, 0)) * 0.1f + 0.002f), scope $"further away, less ({open:0.000})");
		Check(shaded < Expected(.(4.5f, 0, 0)) * 0.35f, scope $"the box's shadow falls behind it ({shaded:0.000} where {Expected(.(4.5f, 0, 0)):0.000} would be lit)");

		// Drawn live: not in the lightmap, but what it bounces is.
		let live = scope Scene();
		live.Environment.ambientIntensity = 0;
		let liveFloor = Add(live, "builtin:plane", .(0, 0, 0), .(2, 1, 2)).GetComponent<MeshRenderer>();
		// A red wall beside a light that is not Baked Only.
		Add(live, "builtin:cube", .(2, 1.5f, 0), .(0.2f, 3, 6), .(1, 0.1f, 0.1f));
		AddLight(live, .(1, 2, 0), 8, .White, 4, false);
		let liveBaker = scope LightBaker(live, settings);
		liveBaker.Run();
		let nearWall = FloorAt(liveBaker, liveFloor, .(1.6f, 0, 0));
		let farAway = FloorAt(liveBaker, liveFloor, .(-4.5f, 0, 0));
		Check(Grey(nearWall) < Expected(.(1.6f, 0, 0)) * 0.5f, scope $"a light drawn live is left out of the lightmap ({Grey(nearWall):0.000})");
		Check(nearWall.x > nearWall.y * 1.5f && nearWall.x > 0.01f, scope $"but the red wall's bounce of it reaches the floor, red ({nearWall.x:0.000}, {nearWall.y:0.000}, {nearWall.z:0.000})");
		Check(Grey(farAway) < Grey(nearWall), "less of it further from the wall");
		let probe = liveBaker.Probes.Sample(.(1, 1, 0), .(1, 0, 0));
		Check(probe.x > probe.y * 1.5f, "a probe beside the wall gives a surface facing it red light");

		// More bounces, more light.
		let none = scope Scene();
		none.Environment.ambientIntensity = 0;
		let noneFloor = Add(none, "builtin:plane", .(0, 0, 0), .(2, 1, 2)).GetComponent<MeshRenderer>();
		Add(none, "builtin:cube", .(2, 1.5f, 0), .(0.2f, 3, 6), .(1, 0.1f, 0.1f));
		AddLight(none, .(1, 2, 0), 8, .White, 4, false);
		settings.bounces = 0;
		let noBounce = scope LightBaker(none, settings);
		noBounce.Run();
		Check(Grey(FloorAt(noBounce, noneFloor, .(1.6f, 0, 0))) <= Grey(nearWall), "bounces add light");
		settings.bounces = 2;
	}

	static void Corners()
	{
		let settings = Quick();
		defer delete settings;
		settings.texelsPerMetre = 6;
		let scene = scope Scene();
		let floor = Add(scene, "builtin:plane", .(0, 0, 0), .(2, 1, 2)).GetComponent<MeshRenderer>();
		Add(scene, "builtin:cube", .(0, 1, 0), .(2, 2, 2), .(0.4f, 0.4f, 0.4f));
		let baker = scope LightBaker(scene, settings);
		baker.Run();
		let byBox = Grey(FloorAt(baker, floor, .(1.15f, 0, 0)));
		let open = Grey(FloorAt(baker, floor, .(-8, 0, -8)));
		Check(byBox < open * 0.85f, scope $"the floor is darker where a box stands beside it ({byBox:0.000} against {open:0.000})");
		// Texels just under the box's edge are inside it (they see its back faces): filled from the texels beside them,
		// so the floor's filtering never pulls black in at the foot of the box.
		let underEdge = Grey(FloorAt(baker, floor, .(0.96f, 0, 0)));
		Check(underEdge > byBox * 0.5f, scope $"texels hidden just under the box's edge take their neighbours' light, not black ({underEdge:0.000})");
		// A probe inside the solid box is filled from those round it.
		let inside = baker.Probes.Sample(.(0, 1, 0), .(0, 1, 0));
		Check(Grey(inside) > 0.01f, scope $"a probe inside a solid box takes its neighbours' light ({Grey(inside):0.000})");

		// Not ticked: neither lit nor in the way.
		let skipped = scope Scene();
		let skippedFloor = Add(skipped, "builtin:plane", .(0, 0, 0), .(2, 1, 2)).GetComponent<MeshRenderer>();
		Add(skipped, "builtin:cube", .(0, 1, 0), .(2, 2, 2), .(0.4f, 0.4f, 0.4f), false);
		let skippedBaker = scope LightBaker(skipped, settings);
		skippedBaker.Run();
		Check(skippedBaker.Objects.Count == 1 && Near(Grey(FloorAt(skippedBaker, skippedFloor, .(1.15f, 0, 0))), open, open * 0.05f), "objects without Baked Lighting are left out");

		// The same bake twice is the same, whatever the threads did.
		settings.threads = 1;
		let again = scope LightBaker(scene, settings);
		again.Run();
		var same = again.Atlases.Count == baker.Atlases.Count;
		for (int i = 0; same && i < baker.Atlases.Count; i++)
		{
			for (int p = 0; same && p < baker.Atlases[i].pixels.Count; p++)
				same &= baker.Atlases[i].pixels[p] == again.Atlases[i].pixels[p];
		}
		Check(same, "baking again gives the same lightmaps");
	}

	static void Encoding()
	{
		var worst = 0.0f;
		for (let value in Vector3[?](.(0.02f, 0.05f, 0.01f), .(0.4f, 0.5f, 0.6f), .(1, 1, 1), .(3.5f, 1.2f, 0.2f), .(7.9f, 7.9f, 7.9f)))
		{
			uint8[4] rgba = default;
			LightBaker.Encode(value, &rgba[0]);
			let back = LightBaker.Decode(&rgba[0]);
			// Against the brightest channel: RGBM's steps are a share of it.
			let brightest = Math.Max(value.x, Math.Max(value.y, value.z));
			for (int c < 3)
				worst = Math.Max(worst, Math.Abs(back[c] - value[c]) / brightest);
		}
		Check(worst < 0.01f, scope $"RGBM keeps light from dim to 8 within 1% of its brightest channel ({worst * 100:0.00}%)");
		Check(LightProbeGrid.Half(1) == 0x3c00 && LightProbeGrid.Half(-2) == 0xc000 && LightProbeGrid.Half(0.5f) == 0x3800 && LightProbeGrid.Half(0) == 0 && LightProbeGrid.Half(1e9f) == 0x7bff, "half floats");

		let grid = scope LightProbeGrid();
		grid.min = .(0, 0, 0);
		grid.max = .(2, 2, 2);
		grid.countX = 2;
		grid.countY = 2;
		grid.countZ = 2;
		for (int p < 8)
		{
			for (int c < LightProbeGrid.Coefficients)
				grid.values.Add((c % 4 == 0) ? (float)(p & 1) : ((c == 2) ? 0.5f : 0));
		}
		let set = scope LightProbeSet();
		set.grids.Add(grid);
		defer set.grids.Remove(grid);
		// A volume's grid: brighter, fading in over half a metre inside its box.
		let volume = new LightProbeGrid();
		volume.min = .(0.5f, 0.5f, 0.5f);
		volume.max = .(1.5f, 1.5f, 1.5f);
		volume.countX = volume.countY = volume.countZ = 2;
		volume.fade = 0.5f;
		for (int p < 8)
		{
			for (int c < LightProbeGrid.Coefficients)
				volume.values.Add((c % 4 == 0) ? 4.0f : 0);
		}
		set.grids.Add(volume);
		let text = scope String();
		set.Write(text);
		let read = scope LightProbeSet();
		Check(read.Parse(text) && read.Count == 16 && read.grids.Count == 2 && read.grids[0].max == grid.max && read.grids[1].fade == 0.5f, "a probe file reads back, with its volume");
		let middle = read.Sample(.(1, 1, 1), .(0, 0, 1), 0);
		let side = read.Sample(.(2, 0, 0), .(0, 1, 0));
		Check(Near(middle.x, 0.5f, 1e-4f) && Near(side.x, 1.5f, 1e-4f) && Near(side.y, 1, 1e-4f), "probes blend between their neighbours, with a direction term");
		Check(read.Pick(.(1, 1, 1)) == 1 && read.Pick(.(0.2f, 1, 1)) == 0, "a thing in the volume's box is lit by the volume, one outside it by the scene's grid");
		let deep = read.Sample(.(1, 1, 1), .(0, 0, 1));
		let edge = read.Sample(.(0.75f, 1, 1), .(0, 0, 1));
		Check(Near(deep.x, 4, 1e-4f) && Near(edge.x, 0.375f + (4 - 0.375f) * 0.5f, 1e-3f), scope $"the volume's light fades in from the scene's over its blend distance ({deep.x:0.000}, {edge.x:0.000})");
		read.Layout();
		Check(read.grids[0].offsetX == 0 && read.grids[1].offsetX == 2 && read.grids[1].offsetZ == 0 && read.TextureSize == .(4, 2, 6), "the grids share one texture, side by side");
		let old = scope LightProbeSet();
		let first = scope String("tprobes 1\n");
		grid.Write(first);
		Check(old.Parse(first) && old.grids.Count == 1 && old.Count == 8, "a probe file from before volumes still reads");
		Check(!read.Parse("tprobes 1\nmin 0 0 0\nmax 1 1 1\ncount 2 2 2\n1 2 3\n"), "a cut-short probe file is refused");
	}

	static void Writing()
	{
		let folder = scope $"{Path.GetTempPath(.. scope .())}/tallow-bake-test";
		if (Directory.Exists(folder))
			Directory.DelTree(folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		let oldProject = scope String(Assets.ProjectPath);
		Assets.ProjectPath.Set(folder);
		defer
		{
			Assets.ProjectPath.Set(oldProject);
			Directory.DelTree(folder).IgnoreError();
		}

		let scene = scope Scene();
		scene.Path.Set("Scenes/Yard.tscene");
		let floor = Add(scene, "builtin:plane", .(0, 0, 0), .(2, 1, 2)).GetComponent<MeshRenderer>();
		let boxRenderer = Add(scene, "builtin:cube", .(0, 1, 0), .(2, 2, 2)).GetComponent<MeshRenderer>();
		let loose = Add(scene, "builtin:sphere", .(4, 1, 0), .(1, 1, 1), .White, false).GetComponent<MeshRenderer>();
		let target = LightBaker.FolderFor(scene, .. scope .());
		Check(target == "Scenes/Yard_Baked", scope $"a scene's bake goes beside it ({target})");
		let held = scope Scene();
		held.Path.Set(scope $"{folder}/Scenes/Yard.tscene");
		let fromFull = LightBaker.FolderFor(held, .. scope .());
		Check(fromFull == "Scenes/Yard_Baked", scope $"named relative to the project when the scene's path is a full one ({fromFull})");
		let settings = Quick();
		defer delete settings;
		let baker = scope LightBaker(scene, settings);
		baker.Run();
		let report = scope String();
		Check(baker.Apply(scene, target, report), scope $"applied: {report}");
		Check(File.Exists(scope $"{folder}/Scenes/Yard_Baked/Lightmap-0.png") && File.Exists(scope $"{folder}/Scenes/Yard_Baked/Probes.tprobes"), "the lightmap and the probes are written beside the scene");
		Check(floor.lightmap == "Scenes/Yard_Baked/Lightmap-0.png" && boxRenderer.lightmap == floor.lightmap && loose.lightmap.IsEmpty && floor.lightmapDecode.x == LightBaker.Range && floor.lightmapScaleOffset != boxRenderer.lightmapScaleOffset, "baked renderers point at their part of the lightmap");
		Check(scene.Environment.lightProbes == "Scenes/Yard_Baked/Probes.tprobes" && LightProbes.Get(scene.Environment.lightProbes)?.Count == baker.Probes.Count, "the scene points at its probes, which load");
		int32 w = 0, h = 0;
		let pixels = Native.tn_image_load(scope $"{folder}/Scenes/Yard_Baked/Lightmap-0.png" .CStr(), &w, &h);
		Check(pixels != null && w == baker.Atlases[0].width && h == baker.Atlases[0].height, scope $"the picture is the lightmap ({w} x {h})");
		if (pixels != null)
			Native.tn_image_free(pixels);
		// The scene file keeps it.
		let saved = scope String();
		SceneSerializer.Save(scene, saved);
		Check(saved.Contains("lightProbes") && saved.Contains("Yard_Baked/Lightmap-0.png"), "the scene file keeps the baked lighting");
		boxRenderer.bakedLighting = false;
		let second = scope LightBaker(scene, settings);
		second.Run();
		second.Apply(scene, target, report..Clear());
		Check(boxRenderer.lightmap.IsEmpty && !floor.lightmap.IsEmpty, "baking again takes the lightmap from objects no longer baked");
		LightBaker.Clear(scene);
		Check(floor.lightmap.IsEmpty && scene.Environment.lightProbes.IsEmpty, "Clear takes the baked lighting away");
	}

	public static int Main(String[] args)
	{
		Coordinates();
		Sky();
		Lights();
		Corners();
		Encoding();
		Writing();
		Console.WriteLine(sFailures == 0 ? "All baking checks passed." : scope $"{sFailures} baking check(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
