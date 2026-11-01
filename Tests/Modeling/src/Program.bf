using System;
using System.Collections;
using Tallow;

namespace ModelingTests;

class Program
{
	static int sFailures;

	static bool Check(bool condition, StringView name)
	{
		Console.WriteLine(scope $"{condition ? "PASS" : "FAIL"}: {name}");
		if (!condition)
			sFailures++;
		return condition;
	}

	static bool Near(float a, float b, float tolerance = 0.001f) => Math.Abs(a - b) <= tolerance;

	static EditMesh Box(Vector3 size)
	{
		var settings = MeshShapes.Settings();
		settings.size = size;
		return MeshShapes.Create(.Box, settings);
	}

	/// The face whose normal points most along a direction.
	static int32 FaceFacing(EditMesh mesh, Vector3 direction)
	{
		int32 best = -1;
		float bestDot = -2;
		for (int32 f < (int32)mesh.faces.Count)
		{
			let d = Vector3.Dot(mesh.FaceNormal(mesh.faces[f]), direction);
			if (d > bestDot)
			{
				bestDot = d;
				best = f;
			}
		}
		return best;
	}

	static void Shapes()
	{
		for (int k < MeshShapes.Names.Count)
		{
			var settings = MeshShapes.Settings();
			settings.size = .(2, 3, 1.5f);
			let kind = (MeshShapes.Kind)k;
			let mesh = MeshShapes.Create(kind, settings);
			defer delete mesh;
			let bounds = mesh.Bounds;
			let name = MeshShapes.Names[k];
			if (kind == .Plane)
			{
				Check(mesh.faces.Count == 1 && mesh.FaceNormal(mesh.faces[0]).y > 0.99f, "a plane is one face looking up");
				continue;
			}
			Check(mesh.IsClosed(), scope $"{name}: closed");
			Check(mesh.Volume() > 0, scope $"{name}: faces point outwards (volume {mesh.Volume():0.###})");
			// A torus's rings only reach its full height where a ring point lands at the top.
			Check(Near(bounds.min.y, 0, kind == .Torus ? 0.5f : 0.001f) && bounds.max.y <= 3.001f && bounds.max.y > (kind == .Torus ? 2.5f : 2.99f), scope $"{name}: stands on the ground, 3 high");
		}
		let shape = Box(.(2, 3, 4));
		defer delete shape;
		Check(shape.faces.Count == 6 && shape.positions.Count == 8 && Near(shape.Volume(), 24), "a 2x3x4 shape: 6 faces, 8 corners, volume 24");
		var stairs = MeshShapes.Settings();
		stairs.size = .(1, 1, 1);
		stairs.steps = 4;
		let steps = MeshShapes.Create(.Stairs, stairs);
		defer delete steps;
		// Four steps of a unit staircase: 1/4 + 2/4 + 3/4 + 4/4 of a quarter-deep slice each.
		Check(Near(steps.Volume(), (1 + 2 + 3 + 4) / 16.0f), "stairs: the volume of four solid steps");
		var arch = MeshShapes.Settings();
		arch.size = .(2, 3, 0.5f);
		arch.thickness = 0.4f;
		let opening = MeshShapes.Create(.Arch, arch);
		defer delete opening;
		Check(opening.Volume() < 2 * 3 * 0.5f * 0.8f && opening.Volume() > 0.5f, "arch: the opening is cut out of the wall");
	}

	static void TextAndTriangles()
	{
		let shape = Box(.(1, 1, 1));
		defer delete shape;
		shape.faces[0].uvMode = .Manual;
		shape.faces[0].uvs[2] = .(0.25f, 0.75f);
		shape.faces[1].colors[0] = .(1, 0, 0, 1);
		shape.faces[2].material = 2;
		shape.faces[3].smooth = true;
		shape.seams.Add(EditMesh.EdgeKey(0, 1));
		shape.hardEdges.Add(EditMesh.EdgeKey(2, 3));
		let text = scope String();
		shape.Write(text);
		let back = scope EditMesh();
		Check(back.Read(text), "text reads back");
		let again = scope String();
		back.Write(again);
		Check(text == again && back.faces[0].uvs[2] == Vector2(0.25f, 0.75f) && back.faces[1].colors[0].g == 0 && back.faces[2].material == 2 && back.faces[3].smooth && back.seams.Count == 1 && back.hardEdges.Count == 1, "everything survives the text: corners, colours, slots, smooth, seams, hard edges");
		Check(!scope EditMesh().Read("not a mesh"), "other text is refused");

		// An L-shaped (concave) face triangulates to its own area.
		let l = scope EditMesh();
		for (let p in Vector3[6](.(0, 0, 0), .(0, 0, 2), .(1, 0, 2), .(1, 0, 1), .(2, 0, 1), .(2, 0, 0)))
			l.AddVertex(p);
		let face = l.AddFace(0, 1, 2, 3, 4, 5);
		let corners = scope List<int32>();
		l.Triangulate(face, corners);
		float area = 0;
		for (int i = 0; i + 2 < corners.Count; i += 3)
		{
			let a = l.positions[face.verts[corners[i]]], b = l.positions[face.verts[corners[i + 1]]], c = l.positions[face.verts[corners[i + 2]]];
			area += Vector3.Cross(b - a, c - a).Length * 0.5f;
		}
		Check(corners.Count == 12 && Near(area, 3), "a concave L face: four triangles covering its area");

		let mesh = scope Mesh();
		shape.Build(mesh, .One);
		Check(mesh.Indices.Count == 36 && mesh.Vertices.Count == 24, "a shape builds 12 triangles, 4 corners a face");
		// Built triangles face the way the faces do.
		bool facing = true;
		for (int i = 0; i + 2 < mesh.Indices.Count; i += 3)
		{
			let a = mesh.Vertices[(int)mesh.Indices[i]], b = mesh.Vertices[(int)mesh.Indices[i + 1]], c = mesh.Vertices[(int)mesh.Indices[i + 2]];
			facing &= Vector3.Dot(Vector3.Cross(b.position - a.position, c.position - a.position), a.normal) > 0 || shape.faces[3].smooth;
		}
		Check(facing, "built triangles wind the way their normals point");

		// Back from a drawn mesh: the cube primitive becomes six faces again.
		let cube = Primitives.CreateCube();
		defer delete cube;
		let edit = EditMesh.FromMesh(cube);
		defer delete edit;
		Check(edit.faces.Count == 6 && edit.positions.Count == 8 && edit.IsClosed() && Near(edit.Volume(), 1), "a drawn cube comes back as 6 faces on 8 corners");
	}

	static void Extrude()
	{
		let shape = Box(.(1, 1, 1));
		defer delete shape;
		var top = FaceFacing(shape, .Up);
		let walls = scope List<int32>();
		MeshOps.ExtrudeFaces(shape, .(&top, 1), 0.5f, false, walls);
		shape.Clean();
		Check(walls.Count == 4 && shape.faces.Count == 10 && shape.IsClosed() && Near(shape.Volume(), 1.5f), "extruding the top of a shape by 0.5: 4 walls, closed, volume 1.5");
		Check(Near(shape.Bounds.max.y, 1.5f), "the top moved up");

		let two = Box(.(2, 1, 1));
		defer delete two;
		// Split the top in two, then extrude both halves as one region and as separate faces.
		let top2 = FaceFacing(two, .Up);
		let face = two.faces[top2];
		let made = MeshOps.SplitEdge(two, face.verts[0], face.verts[1], 0.5f);
		let a = two.faces[top2];
		let opposite = MeshOps.SplitEdge(two, a.verts[3], a.verts[4], 0.5f);
		let second = MeshOps.Connect(two, top2, made, opposite);
		Check(second >= 0 && two.IsClosed(), "the top is cut in two and the shape is still closed");
		let region = scope int32[2](top2, second);
		let regionCopy = two.Clone();
		defer delete regionCopy;
		let regionWalls = scope List<int32>();
		MeshOps.ExtrudeFaces(regionCopy, region, 1, false, regionWalls);
		regionCopy.Clean();
		Check(regionWalls.Count == 6 && regionCopy.IsClosed() && Near(regionCopy.Volume(), 4), "two faces side by side extrude as one block (6 walls, volume 4)");
		let separateWalls = scope List<int32>();
		MeshOps.ExtrudeFaces(two, region, 1, true, separateWalls);
		two.Clean();
		Check(separateWalls.Count == 8 && two.IsClosed(), "extruded one by one: 8 walls, a wall between them");

		// Open edges grow a strip.
		let plane = scope EditMesh();
		for (let p in Vector3[4](.(0, 0, 0), .(0, 0, 1), .(1, 0, 1), .(1, 0, 0)))
			plane.AddVertex(p);
		plane.AddFace(0, 1, 2, 3);
		let border = scope List<uint64>();
		MeshOps.OpenEdges(plane, border);
		var edge = EditMesh.EdgeKey(2, 3);
		let grown = scope List<int32>();
		MeshOps.ExtrudeEdges(plane, .(&edge, 1), .(1, 0, 0), grown);
		Check(border.Count == 4 && grown.Count == 1 && plane.faces.Count == 2 && Vector3.Dot(plane.FaceNormal(plane.faces[1]), .Up) > 0.99f, "an open edge pulled out makes a face that looks the same way");
	}

	static void InsetAndBevel()
	{
		let shape = Box(.(1, 1, 1));
		defer delete shape;
		var top = FaceFacing(shape, .Up);
		let ring = scope List<int32>();
		MeshOps.InsetFaces(shape, .(&top, 1), 0.1f, true, ring);
		shape.Clean();
		let inner = shape.faces[top];
		Check(ring.Count == 4 && shape.faces.Count == 10 && shape.IsClosed() && Near(shape.Volume(), 1), "inset: 4 ring faces, closed, same volume");
		Check(Near(shape.FaceArea(inner), 0.64f), "the inset face is 0.8 square");

		let cube = Box(.(1, 1, 1));
		defer delete cube;
		let edges = scope List<uint64>();
		cube.Edges(edges);
		let bevelFaces = scope List<int32>();
		MeshOps.Bevel(cube, edges, 0.1f, bevelFaces);
		Check(cube.faces.Count == 26 && cube.IsClosed(), scope $"bevelling every edge of a shape: 26 faces, closed ({cube.faces.Count} faces)");
		// A shape with 0.1 cut off every edge: 1 less 12 edge prisms (0.005 * 1 less corners) plus corner pieces.
		Check(Near(cube.Volume(), 0.9455f, 0.0005f), scope $"to the volume of a chamfered cube, 0.9455 ({cube.Volume():0.####})");

		let one = Box(.(1, 1, 1));
		defer delete one;
		let topFace = one.faces[FaceFacing(one, .Up)];
		var single = EditMesh.EdgeKey(topFace.verts[0], topFace.verts[1]);
		MeshOps.Bevel(one, .(&single, 1), 0.2f);
		// One edge cut off: a prism of 0.2 x 0.2 / 2 x 1 removed.
		Check(one.faces.Count == 7 && one.IsClosed() && Near(one.Volume(), 1 - 0.02f), scope $"bevelling one edge: 7 faces, closed, volume 0.98 ({one.Volume():0.####})");
	}

	static void Cuts()
	{
		let shape = Box(.(1, 1, 1));
		defer delete shape;
		// A loop round the shape through the vertical edges' ring.
		let side = shape.faces[FaceFacing(shape, .Forward)];
		uint64 vertical = 0;
		for (int i < 4)
		{
			let a = shape.positions[side.verts[i]], b = shape.positions[side.verts[(i + 1) % 4]];
			if (Math.Abs(a.y - b.y) > 0.5f)
				vertical = EditMesh.EdgeKey(side.verts[i], side.verts[(i + 1) % 4]);
		}
		let ring = scope List<uint64>();
		MeshOps.EdgeRing(shape, vertical, ring);
		Check(ring.Count == 4, "the ring through a vertical edge of a shape has the 4 vertical edges");
		let newEdges = scope List<uint64>();
		MeshOps.LoopCut(shape, vertical, 1, 0.5f, newEdges);
		Check(shape.faces.Count == 10 && shape.IsClosed() && Near(shape.Volume(), 1) && newEdges.Count == 4, scope $"one loop cut: 10 faces, closed ({shape.faces.Count} faces, {newEdges.Count} new edges)");
		let three = Box(.(1, 1, 1));
		defer delete three;
		let side3 = three.faces[FaceFacing(three, .Forward)];
		uint64 vertical3 = 0;
		for (int i < 4)
		{
			if (Math.Abs(three.positions[side3.verts[i]].y - three.positions[side3.verts[(i + 1) % 4]].y) > 0.5f)
				vertical3 = EditMesh.EdgeKey(side3.verts[i], side3.verts[(i + 1) % 4]);
		}
		MeshOps.LoopCut(three, vertical3, 3);
		Check(three.faces.Count == 18 && three.IsClosed(), scope $"three loop cuts: 18 faces ({three.faces.Count})");
		// The edge loop through one of the new edges goes round the shape.
		let loop = scope List<uint64>();
		MeshOps.EdgeLoop(shape, newEdges[0], loop);
		Check(loop.Count == 4, scope $"the edge loop through a cut edge goes round the shape ({loop.Count} edges)");

		let sub = Box(.(1, 1, 1));
		defer delete sub;
		let all = scope List<int32>();
		for (int32 f < (int32)sub.faces.Count)
			all.Add(f);
		MeshOps.Subdivide(sub, all);
		Check(sub.faces.Count == 24 && sub.IsClosed() && Near(sub.Volume(), 1), "subdividing a shape: 24 faces, same shape");
		let round = Box(.(1, 1, 1));
		defer delete round;
		MeshOps.Subdivide(round, all, true);
		Check(round.faces.Count == 24 && round.IsClosed() && round.Volume() < 0.9f && round.Volume() > 0.2f, scope $"smooth subdivision rounds the shape off (volume {round.Volume():0.###})");

		let half = scope EditMesh();
		// Half a shape from x 0 to 1, open at x 0.
		let b = Box(.(1, 1, 1));
		defer delete b;
		for (var p in ref b.positions)
			p.x += 0.5f;
		half.CopyFrom(b);
		let mirrored = half.Clone();
		defer delete mirrored;
		MeshOps.Mirror(mirrored, 0);
		Check(mirrored.IsClosed() && Near(mirrored.Volume(), 2) && mirrored.faces.Count == 10, scope $"mirroring a shape on x: one solid of volume 2 ({mirrored.faces.Count} faces, {mirrored.Volume():0.###})");

		let arr = Box(.(1, 1, 1));
		defer delete arr;
		MeshOps.Array(arr, 3, .(1.5f, 0, 0));
		Check(arr.faces.Count == 18 && Near(arr.Volume(), 3), "an array of 3 boxes");

		// Bridge two facing open squares into a tube.
		let tube = scope EditMesh();
		for (int ring2 < 2)
		{
			for (let p in Vector3[4](.(0, 0, 0), .(0, 1, 0), .(1, 1, 0), .(1, 0, 0)))
				tube.AddVertex(.(p.x, p.y, ring2 * 2.0f));
		}
		let squareEdges = scope List<uint64>();
		for (int32 r < 2)
		{
			for (int32 i < 4)
				squareEdges.Add(EditMesh.EdgeKey(r * 4 + i, r * 4 + (i + 1) % 4));
		}
		let bridged = scope List<int32>();
		Check(MeshOps.Bridge(tube, squareEdges, bridged) && bridged.Count == 4, "bridging two squares makes four faces");
		let ends = scope List<uint64>();
		MeshOps.OpenEdges(tube, ends);
		MeshOps.Fill(tube, ends);
		MeshOps.ConformNormals(tube);
		Check(tube.IsClosed() && Near(tube.Volume(), 2), "filling the ends closes it into a 1x1x2 block");

		let weld = Box(.(1, 1, 1));
		defer delete weld;
		var detachFace = FaceFacing(weld, .Up);
		MeshOps.Detach(weld, .(&detachFace, 1));
		Check(!weld.IsClosed() && weld.positions.Count == 12, "detaching the top gives it corners of its own");
		weld.Weld();
		Check(weld.IsClosed() && weld.positions.Count == 8, "welding joins them again");

		let dissolve = Box(.(1, 1, 1));
		defer delete dissolve;
		let topD = dissolve.faces[FaceFacing(dissolve, .Up)];
		let cutA = MeshOps.SplitEdge(dissolve, topD.verts[0], topD.verts[1], 0.5f);
		let cutB = MeshOps.SplitEdge(dissolve, topD.verts[3], topD.verts[4], 0.5f);
		MeshOps.Connect(dissolve, FaceFacing(dissolve, .Up), cutA, cutB);
		var middle = EditMesh.EdgeKey(cutA, cutB);
		Check(MeshOps.DissolveEdges(dissolve, .(&middle, 1)) == 1 && dissolve.faces.Count == 6 && dissolve.IsClosed(), "dissolving the cut joins the top again");
	}

	static void Csg()
	{
		let a = Box(.(2, 2, 2));
		defer delete a;
		let b = Box(.(1, 4, 1));
		defer delete b;
		// b stands through the middle of a, sticking out top (and bottom, moved down).
		let bPlace = Matrix4.Translate(.(0, -1, 0));
		let union = MeshCsg.Combine(a, .Identity, b, bPlace, .Union, .Identity);
		defer delete union;
		Check(union.IsClosed() && Near(union.Volume(), 8 + 2, 0.01f), scope $"union of a box and a post through it: closed, volume 10 ({union.Volume():0.###}, {union.faces.Count} faces)");
		let cut = MeshCsg.Combine(a, .Identity, b, bPlace, .Subtract, .Identity);
		defer delete cut;
		Check(cut.IsClosed() && Near(cut.Volume(), 8 - 2, 0.01f), scope $"a hole through a box: closed, volume 6 ({cut.Volume():0.###}, {cut.faces.Count} faces)");
		let both = MeshCsg.Combine(a, .Identity, b, bPlace, .Intersect, .Identity);
		defer delete both;
		Check(both.IsClosed() && Near(both.Volume(), 2, 0.01f) && both.faces.Count == 6, scope $"where they overlap: a 1x2x1 block of 6 faces ({both.Volume():0.###}, {both.faces.Count} faces)");
		// A doorway: a notch out of the bottom edge of a wall.
		let wall = Box(.(4, 3, 0.2f));
		defer delete wall;
		let door = Box(.(1, 2, 1));
		defer delete door;
		let doorway = MeshCsg.Combine(wall, .Identity, door, Matrix4.Translate(.(0, -0.5f, 0)), .Subtract, .Identity);
		defer delete doorway;
		Check(doorway.IsClosed() && Near(doorway.Volume(), 4 * 3 * 0.2f - 1.5f * 0.2f, 0.01f), scope $"a doorway out of a wall ({doorway.Volume():0.###}, {doorway.faces.Count} faces)");
	}

	static void UVs()
	{
		var settings = MeshShapes.Settings();
		settings.size = .(1, 1, 1);
		settings.sides = 16;
		let cylinder = MeshShapes.Create(.Cylinder, settings);
		defer delete cylinder;
		let all = scope List<int32>();
		for (int32 f < (int32)cylinder.faces.Count)
			all.Add(f);
		// Seams: round the top and bottom, and one line down the side.
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		cylinder.EdgeFaces(edgeFaces);
		bool sideSeam = false;
		for (let pair in edgeFaces)
		{
			let n0 = cylinder.FaceNormal(cylinder.faces[pair.value[0]]), n1 = cylinder.FaceNormal(cylinder.faces[pair.value[1]]);
			if (Math.Abs(n0.y) > 0.9f != Math.Abs(n1.y) > 0.9f)
				cylinder.seams.Add(pair.key);
			else if (!sideSeam && Math.Abs(n0.y) < 0.1f)
			{
				EditMesh.EdgeEnds(pair.key, let ea, let eb);
				if (Math.Abs(cylinder.positions[ea].y - cylinder.positions[eb].y) > 0.5f)
				{
					cylinder.seams.Add(pair.key);
					sideSeam = true;
				}
			}
		}
		for (let list in edgeFaces.Values)
			delete list;
		MeshUV.Unwrap(cylinder, all);
		let islands = scope List<List<int32>>();
		MeshUV.Islands(cylinder, all, islands);
		Check(islands.Count == 3, scope $"a cylinder cut at its rims and down one side unwraps to 3 pieces ({islands.Count})");
		for (let island in islands)
			delete island;
		bool inside = true;
		for (let face in cylinder.faces)
		{
			for (let uv in face.uvs)
				inside &= uv.x >= -0.0001f && uv.x <= 1.0001f && uv.y >= -0.0001f && uv.y <= 1.0001f;
		}
		Check(inside, "the pieces are packed inside the picture");
		Check(MeshUV.Overlap(cylinder, all) < 0.01f, scope $"without overlapping ({MeshUV.Overlap(cylinder, all):0.####})");
		Check(MeshUV.Stretch(cylinder, all) < 1.3f, scope $"and without much stretch ({MeshUV.Stretch(cylinder, all):0.###})");

		var sphereSettings = MeshShapes.Settings();
		sphereSettings.size = .(1, 1, 1);
		let sphere = MeshShapes.Create(.Sphere, sphereSettings);
		defer delete sphere;
		let sphereFaces = scope List<int32>();
		for (int32 f < (int32)sphere.faces.Count)
			sphereFaces.Add(f);
		MeshUV.SmartUnwrap(sphere, sphereFaces);
		Check(MeshUV.Overlap(sphere, sphereFaces) < 0.01f, scope $"smart unwrap of a sphere: no overlap ({MeshUV.Overlap(sphere, sphereFaces):0.####})");

		let shape = Box(.(2, 1, 1));
		defer delete shape;
		let boxFaces = scope List<int32>();
		for (int32 f < (int32)shape.faces.Count)
			boxFaces.Add(f);
		MeshUV.SmartUnwrap(shape, boxFaces);
		Check(MeshUV.Overlap(shape, boxFaces) < 0.01f && MeshUV.Stretch(shape, boxFaces) < 1.01f, "smart unwrap of a box: six pieces, same density, no overlap");
	}

	static void Files()
	{
		let folder = scope String();
		System.IO.Directory.GetCurrentDirectory(folder);
		let model = Box(.(1, 2, 3));
		defer delete model;
		model.faces[0].material = 1;
		let glb = scope $"{folder}/build/export_test.glb";
		Check(GlbWriter.Write(glb, model, StringView[2]("Walls", "Trim")), "a model exports as .glb");
		let back = Assets.BuildModel(glb);
		defer delete back;
		Check(back != null && back.Indices.Count == 36 && Near(back.Bounds.max.y - back.Bounds.min.y, 2) && Near(back.Bounds.max.z - back.Bounds.min.z, 3), "the .glb reads back with the same size and 12 triangles");
		if (back != null)
		{
			let edit = EditMesh.FromMesh(back);
			defer delete edit;
			Check(edit.IsClosed() && Near(edit.Volume(), 6), scope $"and still faces outwards after the trip through glTF's other hand ({edit.Volume():0.###})");
		}
		let tmesh = scope $"{folder}/build/export_test.tmesh";
		let text = scope String();
		model.Write(text);
		System.IO.File.WriteAllText(tmesh, text);
		let whole = Assets.BuildModel(tmesh);
		defer delete whole;
		let slot = Assets.BuildModel(scope $"{tmesh}#1");
		defer delete slot;
		Check(whole != null && whole.Indices.Count == 36 && slot != null && slot.Indices.Count == 6, "a .tmesh is a mesh a renderer can name, and #1 picks material slot 1");
	}

	static void BevelDish()
	{
		let dish = Box(.(2, 1, 2));
		defer delete dish;
		var top = FaceFacing(dish, .Up);
		MeshOps.ExtrudeFaces(dish, .(&top, 1), 1);
		dish.Clean();
		top = FaceFacing(dish, .Up);
		MeshOps.InsetFaces(dish, .(&top, 1), 0.25f);
		MeshOps.ExtrudeFaces(dish, .(&top, 1), -0.5f);
		dish.Clean();
		Check(dish.IsClosed() && Near(dish.Volume(), 6.875f), "the dish is closed");
		let upright = scope List<uint64>();
		let all = scope List<uint64>();
		dish.Edges(all);
		for (let e in all)
		{
			EditMesh.EdgeEnds(e, let a, let b);
			let pa = dish.positions[a], pb = dish.positions[b];
			if (Near(pa.x, pb.x) && Near(pa.z, pb.z) && Near(Math.Abs(pa.x), 1) && Near(Math.Abs(pa.z), 1))
				upright.Add(e);
		}
		MeshOps.Bevel(dish, upright, 0.2f);
		let ef = scope Dictionary<uint64, List<int32>>();
		dish.EdgeFaces(ef);
		let open = scope String();
		for (let pair in ef)
		{
			if (pair.value.Count != 2)
			{
				EditMesh.EdgeEnds(pair.key, let a, let b);
				open.AppendF(" [{} {}]x{}", dish.positions[a], dish.positions[b], pair.value.Count);
			}
			delete pair.value;
		}
		Check(dish.IsClosed(), scope $"bevelling the {upright.Count} upright edges of the dish keeps it closed:{open}");
	}

	static List<int32> AllFaces(EditMesh mesh, List<int32> into)
	{
		for (int32 f < (int32)mesh.faces.Count)
			into.Add(f);
		return into;
	}

	static void MoreTools()
	{
		let tris = Box(.(1, 1, 1));
		defer delete tris;
		MeshOps.Triangulate(tris, AllFaces(tris, scope .()));
		Check(tris.faces.Count == 12 && tris.IsClosed() && Near(tris.Volume(), 1), scope $"triangulating a box: 12 closed triangles ({tris.faces.Count})");
		let quads = MeshOps.TrianglesToQuads(tris, AllFaces(tris, scope .()));
		Check(quads == 6 && tris.faces.Count == 6 && tris.IsClosed() && Near(tris.Volume(), 1), scope $"triangles back to quads ({quads} joined, {tris.faces.Count} faces)");

		let poked = Box(.(1, 1, 1));
		defer delete poked;
		var top = FaceFacing(poked, .Up);
		MeshOps.Poke(poked, .(&top, 1));
		Check(poked.faces.Count == 9 && poked.IsClosed() && Near(poked.Volume(), 1), scope $"poking the top makes a fan of 4 ({poked.faces.Count} faces)");

		var settings = MeshShapes.Settings();
		settings.size = .(2, 0, 2);
		let plane = MeshShapes.Create(.Plane, settings);
		defer delete plane;
		MeshOps.Solidify(plane, AllFaces(plane, scope .()), 0.1f);
		Check(plane.IsClosed() && Near(plane.Volume(), 0.4f) && plane.faces.Count == 6, scope $"solidifying a 2 m plane 0.1 m makes a closed slab ({plane.Volume():0.###}, {plane.faces.Count} faces)");

		let smooth = Box(.(1, 1, 1));
		defer delete smooth;
		MeshOps.Subdivide(smooth, AllFaces(smooth, scope .()));
		let verts = scope List<int32>();
		for (int32 v < (int32)smooth.positions.Count)
			verts.Add(v);
		MeshOps.SmoothVertices(smooth, verts, 0.5f, 2);
		Check(smooth.IsClosed() && smooth.Volume() < 0.99f && smooth.Volume() > 0.5f, scope $"smoothing rounds a box off ({smooth.Volume():0.###})");

		let collapse = Box(.(1, 1, 1));
		defer delete collapse;
		let topFace = collapse.faces[FaceFacing(collapse, .Up)];
		var edge = EditMesh.EdgeKey(topFace.verts[0], topFace.verts[1]);
		let gone = MeshOps.CollapseEdges(collapse, .(&edge, 1));
		Check(gone == 1 && collapse.positions.Count == 7 && collapse.IsClosed(), scope $"collapsing an edge joins its ends ({collapse.positions.Count} vertices)");

		let open = Box(.(1, 1, 1));
		defer delete open;
		var lid = FaceFacing(open, .Up);
		let lidVerts = scope List<int32>();
		lidVerts.AddRange(open.faces[lid].verts);
		let lidPoints = scope List<Vector3>();
		for (let v in lidVerts)
			lidPoints.Add(open.positions[v]);
		delete open.faces[lid];
		open.faces.RemoveAt(lid);
		Check(!open.IsClosed(), "a box without its lid is open");
		// Shuffled, so MakeFace has to find the order.
		let shuffled = scope List<int32>() { lidVerts[0], lidVerts[2], lidVerts[1], lidVerts[3] };
		let made = MeshOps.MakeFace(open, shuffled);
		Check(made >= 0 && open.IsClosed() && Near(open.Volume(), 1), scope $"making a face from the lid's corners closes it the right way round ({open.Volume():0.###})");

		// The knife across one face: from the middle of one side to the middle of the other.
		let cut = Box(.(1, 1, 1));
		defer delete cut;
		let eye = Vector3(0, 0.5f, -5);
		let across = scope List<Vector3>() { .(-0.5f, 0.5f, -0.5f), .(0.5f, 0.5f, -0.5f) };
		let cuts = MeshOps.Knife(cut, across, eye);
		Check(cuts == 1 && cut.faces.Count == 7 && cut.IsClosed() && Near(cut.Volume(), 1), scope $"a knife cut across a face splits it ({cuts} cuts, {cut.faces.Count} faces)");
		// Round a corner: the cut goes through the corner edge between the two clicks.
		let corner = Box(.(1, 1, 1));
		defer delete corner;
		let round = scope List<Vector3>() { .(0.5f, 0.5f, -0.5f), .(-0.5f, 0.5f, 0.5f) };
		let cornerCuts = MeshOps.Knife(corner, round, .(-3, 0.5f, -3));
		Check(cornerCuts == 2 && corner.faces.Count == 8 && corner.IsClosed() && Near(corner.Volume(), 1), scope $"a knife cut round a corner crosses the edge between ({cornerCuts} cuts, {corner.faces.Count} faces)");
	}

	static void RoundingAndSliding()
	{
		// One edge bevelled round in four segments: the cut follows a curve through the old corner's side.
		let one = Box(.(1, 1, 1));
		defer delete one;
		let topFace = one.faces[FaceFacing(one, .Up)];
		var single = EditMesh.EdgeKey(topFace.verts[0], topFace.verts[1]);
		MeshOps.Bevel(one, .(&single, 1), 0.2f, null, 4);
		// The four flat pieces under a parabola: 0.02 * (1 - 2/3 * (1 - 1/16)) taken off.
		Check(one.faces.Count == 10 && one.IsClosed() && Near(one.Volume(), 0.9925f, 0.0005f), scope $"a round bevel of one edge in 4 segments: 10 faces, closed, volume 0.9925 ({one.faces.Count} faces, {one.Volume():0.####})");
		var smooth = 0;
		for (let face in one.faces)
		{
			if (face.smooth)
				smooth++;
		}
		Check(smooth == 4, "the round bevel's faces are smooth");

		let all = Box(.(1, 1, 1));
		defer delete all;
		let edges = scope List<uint64>();
		all.Edges(edges);
		MeshOps.Bevel(all, edges, 0.1f, null, 3);
		Check(all.IsClosed() && all.Volume() > 0.9455f && all.Volume() < 1, scope $"every edge bevelled round: closed, more left than a flat chamfer ({all.Volume():0.####})");

		// A loop round a shape slid halfway up towards the top.
		let looped = Box(.(1, 1, 1));
		defer delete looped;
		uint64 upright = 0;
		for (let face in looped.faces)
		{
			for (int i < face.Count)
			{
				let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
				if (Math.Abs(looped.positions[a].y - looped.positions[b].y) > 0.5f)
					upright = EditMesh.EdgeKey(a, b);
			}
		}
		let loop = scope List<uint64>();
		MeshOps.LoopCut(looped, upright, 1, 0.5f, loop);
		let rails = scope List<SlideRail>();
		MeshOps.EdgeSlideRails(looped, loop, rails);
		Check(loop.Count == 4 && rails.Count == 4, scope $"a loop of 4 edges has a rail for each of its 4 corners ({loop.Count} edges, {rails.Count} rails)");
		MeshOps.ApplySlide(looped, rails, 0.5f);
		var level = -1.0f;
		var flat = true;
		for (let rail in rails)
		{
			let y = looped.positions[rail.vertex].y;
			if (level < 0)
				level = y;
			flat = flat && Near(y, level);
		}
		Check(flat && (Near(level, 0.75f) || Near(level, 0.25f)) && looped.IsClosed() && Near(looped.Volume(), 1), scope $"sliding the loop halfway keeps it level and the shape the same ({level:0.###})");
		MeshOps.ApplySlide(looped, rails, -0.5f);
		Check(Near(looped.positions[rails[0].vertex].y, 1 - level), "sliding the other way goes to the other side");

		let neighbours = scope List<int32>();
		let corner = Box(.(1, 1, 1));
		defer delete corner;
		MeshOps.Neighbours(corner, 0, neighbours);
		Check(neighbours.Count == 3, "a shape's corner has three neighbours to slide towards");

		// The knife through a point inside a face.
		let cut = Box(.(1, 1, 1));
		defer delete cut;
		let through = scope List<Vector3>() { .(-0.5f, 0.5f, -0.5f), .(0, 0.7f, -0.5f), .(0.5f, 0.5f, -0.5f) };
		let cuts = MeshOps.Knife(cut, through, .(0, 0.5f, -5));
		var found = false;
		for (let p in cut.positions)
			found = found || (p - Vector3(0, 0.7f, -0.5f)).Length < 1.0e-4f;
		Check(cuts == 1 && found && cut.faces.Count == 7 && cut.IsClosed() && Near(cut.Volume(), 1), scope $"a knife cut through a point inside a face bends there ({cuts} cuts, {cut.faces.Count} faces)");
	}

	static void PinsStitchPaint()
	{
		// Pins survive the text, and an unwrap keeps pinned vertices where they are.
		var settings = MeshShapes.Settings();
		settings.size = .(1, 1, 1);
		settings.sides = 12;
		settings.steps = 6;
		let sphere = MeshShapes.Create(.Sphere, settings);
		defer delete sphere;
		let all = scope List<int32>();
		for (int32 f < (int32)sphere.faces.Count)
			all.Add(f);
		MeshUV.SmartUnwrap(sphere, all, 89);
		// Pin two corners of the first face somewhere new.
		let face0 = sphere.faces[0];
		let pinA = face0.verts[0], pinB = face0.verts[1];
		for (let face in sphere.faces)
		{
			for (int i < face.Count)
			{
				if (face.verts[i] == pinA)
					face.uvs[i] = .(0.2f, 0.2f);
				else if (face.verts[i] == pinB)
					face.uvs[i] = .(0.3f, 0.2f);
			}
		}
		sphere.pins.Add(pinA);
		sphere.pins.Add(pinB);
		let text = scope String();
		sphere.Write(text);
		let back = scope EditMesh();
		Check(back.Read(text) && back.pins.Count == 2 && back.pins.Contains(face0.verts[0]), "pins survive the text");
		let pieces = scope List<List<int32>>();
		MeshUV.Pieces(sphere, all, pieces, 89);
		List<int32> pinnedPiece = null;
		for (let piece in pieces)
		{
			if (piece.Contains(0))
				pinnedPiece = piece;
		}
		MeshUV.Flatten(sphere, pinnedPiece);
		Check(Near(sphere.faces[0].uvs[0].x, 0.2f) && Near(sphere.faces[0].uvs[0].y, 0.2f) && Near(sphere.faces[0].uvs[1].x, 0.3f), "laying a piece flat keeps its pinned vertices where they were");
		for (let piece in pieces)
			delete piece;

		// Two faces of a pair unwrapped apart, then stitched back together along their shared edge.
		let pair = Box(.(1, 1, 1));
		defer delete pair;
		var top = FaceFacing(pair, Vector3.Up);
		var front = FaceFacing(pair, Vector3(0, 0, -1));
		let both = scope List<int32>() { top, front };
		MeshUV.Planar(pair, .(&top, 1));
		MeshUV.Planar(pair, .(&front, 1));
		for (var uv in ref pair.faces[front].uvs)
			uv = uv + Vector2(3, 1);
		let islands = scope List<List<int32>>();
		MeshUV.Islands(pair, both, islands);
		Check(islands.Count == 2, "two faces with separate coordinates are two pieces");
		for (let island in islands)
			delete island;
		islands.Clear();
		let moved = MeshUV.StitchAll(pair, both, top);
		MeshUV.Islands(pair, both, islands);
		Check(moved == 1 && islands.Count == 1, scope $"stitching joins them into one piece ({islands.Count})");
		for (let island in islands)
			delete island;
		let stretch = MeshUV.Stretch(pair, both);
		Check(Near(stretch, 1, 0.05f), scope $"and the moved face keeps its shape ({stretch:0.###})");

		// Faces put into one cell of a 4 x 4 palette.
		MeshUV.ToCell(pair, both, 2, 1, 4, 4, 0.5f);
		var inCell = true;
		for (let f in both)
		{
			for (let uv in pair.faces[f].uvs)
			{
				MeshUV.CellAt(uv, 4, 4, let column, let row);
				inCell = inCell && column == 2 && row == 1 && uv.x > 0.5f + 0.0624f && uv.x < 0.75f - 0.0624f;
			}
		}
		Check(inCell, "faces put into a palette cell stay inside its middle half");

		// Painting: a red dab on the middle of the top face colours the middle of its part of the picture only.
		let painted = Box(.(1, 1, 1));
		defer delete painted;
		let faces = scope List<int32>();
		for (int32 f < (int32)painted.faces.Count)
			faces.Add(f);
		MeshUV.SmartUnwrap(painted, faces);
		let paint = scope TexturePaint();
		paint.Create("Textures/paint_test.png", 64, 64, .White);
		var topFace = FaceFacing(painted, Vector3.Up);
		let changed = paint.Dab(painted, .(0, 1, 0), 0.2f, .(1, 0, 0, 1), 1, 1);
		let middle = painted.FaceCenter(painted.faces[topFace]);
		MeshOps.Sample(painted, painted.faces[topFace], middle, let middleUV, ?);
		let atMiddle = paint.Sample(middleUV);
		let atCorner = paint.Sample(painted.faces[topFace].uvs[0]);
		Check(changed > 0 && atMiddle.r > 0.99f && atMiddle.g < 0.01f && atCorner.g > 0.99f, scope $"a dab paints where it lands and not the face's corner ({changed} pixels)");
		paint.Fill(painted, .(&topFace, 1), .(0, 0, 1, 1));
		Check(paint.Sample(painted.faces[topFace].uvs[0] * 0.98f + middleUV * 0.02f).b > 0.99f, "a fill colours the whole face");
		let palette = scope Color[3](.(1, 0, 0, 1), .(0, 1, 0, 1), .(0, 0, 1, 1));
		let file = scope $"{System.IO.Path.GetTempPath(.. scope .())}tallow_palette_test.png";
		Check(TexturePaint.WritePalette(file, palette, 2, 2, 8) && paint.Load(file) && paint.width == 16 && paint.GetPixel(12, 3).g > 0.99f && paint.GetPixel(12, 12).r > 0.99f && paint.GetPixel(12, 12).g > 0.99f && paint.GetPixel(3, 12).b > 0.99f, "a palette picture is written and read back cell by cell");
		System.IO.File.Delete(file).IgnoreError();

		// Levels of detail: a smooth sphere decimated to about half its triangles stays closed and round.
		settings.sides = 24;
		settings.steps = 12;
		let round = MeshShapes.Create(.Sphere, settings);
		defer delete round;
		let before = MeshOps.TriangleCount(round);
		let volume = round.Volume();
		MeshOps.Decimate(round, 0.5f);
		let after = MeshOps.TriangleCount(round);
		Check(after <= before * 0.55f && after >= before * 0.3f && round.IsClosed(), scope $"decimating a sphere to half: {before} -> {after} triangles, closed");
		Check(Near(round.Volume(), volume, volume * 0.08f), scope $"and nearly the same volume ({volume:0.###} -> {round.Volume():0.###})");
		MeshOps.Decimate(round, 0.25f);
		Check(round.IsClosed() && MeshOps.TriangleCount(round) < after, scope $"and again, still closed ({MeshOps.TriangleCount(round)})");
	}

	public static int Main(String[] args)
	{
		Console.WriteLine("Modelling tests");
		Shapes();
		TextAndTriangles();
		Extrude();
		InsetAndBevel();
		Cuts();
		Csg();
		UVs();
		Files();
		BevelDish();
		MoreTools();
		RoundingAndSliding();
		PinsStitchPaint();
		Console.WriteLine(sFailures == 0 ? "All modelling tests passed." : scope $"{sFailures} modelling test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
