using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Test switch --palette-test: writes two palette images and reads them back exactly, saves and reads a palette
/// material (with a palette for a second world state), splits a mesh's faces into palette sections by their flags,
/// and saves PaletteTest/Palette.tscene: a camera facing an unlit palette box (entry 5: red in the first palette,
/// blue in the second), for a screenshot in each world state (`--scene PaletteTest/Palette.tscene --world-state 1`).
/// Logs PALETTE-TEST PASS or FAIL.
extension EditorApp
{
	void RunPaletteTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		let stash = SceneSerializer.Save(mScene, .. scope .());
		let stashPath = scope String(mScene.Path);

		// Two palettes: the starter colours with entry 5 red (first) or blue (second), entry 6 green.
		Color[Palettes.Size] colors = default;
		Palettes.Starter(ref colors);
		colors[5] = .(1, 0, 0, 1);
		colors[6] = .(0, 1, 0, 1);
		Expect(Palettes.Save("PaletteTest/first.png", colors), "a palette is written");
		colors[5] = .(0, 0, 1, 1);
		Expect(Palettes.Save("PaletteTest/second.png", colors), "a second palette is written");
		Color[Palettes.Size] read = default;
		Expect(Palettes.Colors("PaletteTest/first.png", ref read) && read[5].ToABGR() == Color(1, 0, 0, 1).ToABGR() && read[6].ToABGR() == Color(0, 1, 0, 1).ToABGR(), "a palette reads back exactly");
		bool same = true;
		for (int i < Palettes.Size)
			same &= i == 5 || read[i].ToABGR() == colors[i].ToABGR();
		Expect(same, "every entry round-trips");

		// The material: palette, a second state's palette, glow and dissolve survive saving.
		let material = scope Material();
		material.palette.Set("PaletteTest/first.png");
		material.statePalettes.Add(new .());
		material.statePalettes.Add(new .("PaletteTest/second.png"));
		material.paletteEmission = 6;
		material.dissolve = 0.25f;
		let text = material.Write(.. scope .());
		let back = scope Material();
		back.Read(text);
		Expect(back.IsPalette && back.palette == "PaletteTest/first.png" && back.PaletteFor(1) == "PaletteTest/second.png" && back.PaletteFor(0) == "PaletteTest/first.png" && back.paletteEmission == 6 && back.dissolve == 0.25f, "a palette material saves and reads");
		let plain = scope Material();
		Expect(!plain.IsPalette && !plain.Write(.. scope .()).Contains("palette"), "an ordinary material is unchanged");
		let seeThrough = back.PaletteVariant(2);
		let both = back.PaletteVariant(3);
		Expect(seeThrough.IsTransparent && !seeThrough.doubleSided && both.IsTransparent && both.doubleSided && back.PaletteVariant(0) == back, "variants for see-through and double-sided faces");

		// A box with one face see-through and one double sided: three sections.
		let edit = scope EditMesh();
		MeshShapes.AddBox(edit, .(-1, -1, -1), .(1, 1, 1));
		let opaque = Color.FromBytes(5, 0, 31 << 3, Mesh.PaletteUnlit);
		for (let face in edit.faces)
		{
			for (var c in ref face.colors)
				c = opaque;
		}
		let faceCount = edit.faces.Count;
		for (var c in ref edit.faces[0].colors)
			c = .FromBytes(6, 0, 128, Mesh.PaletteTransparent);
		for (var c in ref edit.faces[1].colors)
			c = .FromBytes(6, 0, 0, Mesh.PaletteDoubleSided);
		let mesh = scope Mesh();
		edit.Build(mesh, .One);
		mesh.Upload();
		Expect(mesh.HasPaletteSections, "flagged faces split the mesh");
		let one = mesh.PaletteSection(0), two = mesh.PaletteSection(1), three = mesh.PaletteSection(2);
		Expect(one != null && two != null && three != null && mesh.PaletteSection(3) == null, "one section for each kind of face used");
		Expect(one != null && two != null && three != null && one.Indices.Count + two.Indices.Count + three.Indices.Count == mesh.Indices.Count && three.Indices.Count == two.Indices.Count, scope $"every triangle is in one section ({faceCount} faces)");
		let unflagged = scope Mesh();
		let simple = scope EditMesh();
		MeshShapes.AddBox(simple, .(-1, -1, -1), .(1, 1, 1));
		simple.Build(unflagged, .One);
		unflagged.Upload();
		Expect(!unflagged.HasPaletteSections, "a mesh without such faces is drawn whole");

		// The scene for screenshots: an unlit palette box filling the middle of the view.
		material.statePalettes[1].Set("PaletteTest/second.png");
		material.dissolve = 0;
		Expect(material.Save(scope $"{Assets.ProjectPath}/PaletteTest/box.tmat"), "the material is written");
		// A plain material that draws as the palette box in the second state (State Materials).
		let swap = scope Material();
		swap.color = .(0, 1, 0, 1);
		swap.stateMaterials.Add(new .());
		swap.stateMaterials.Add(new .("PaletteTest/box.tmat"));
		let swapBack = scope Material();
		swapBack.Read(swap.Write(.. scope .()));
		Expect(swapBack.stateMaterials.Count == 2 && swapBack.stateMaterials[1] == "PaletteTest/box.tmat" && swapBack.ForState(0) == swapBack && swapBack.ForState(1)?.IsPalette == true && swapBack.ForState(5) == swapBack, "a material names another for a world state");
		Expect(swap.Save(scope $"{Assets.ProjectPath}/PaletteTest/swap.tmat"), "the state-swapping material is written");
		SceneSerializer.Load(mScene, "scene \"Palette\"\n");
		let camera = mScene.CreateGameObject("Camera");
		camera.Transform.Position = .(0, 0, -4);
		camera.AddComponent<Camera>();
		let boxObject = mScene.CreateGameObject("Box");
		let renderer = boxObject.AddComponent<MeshRenderer>();
		renderer.material.Set("PaletteTest/box.tmat");
		let model = boxObject.AddComponent<ModelMesh>();
		let solid = scope EditMesh();
		MeshShapes.AddBox(solid, .(-1, -1, -1), .(1, 1, 1));
		for (let face in solid.faces)
		{
			for (var c in ref face.colors)
				c = opaque;
		}
		model.Set(solid);
		// Above the box: a plain green strip that is the palette material (red, then blue) in the second state.
		let strip = mScene.CreateGameObject("Strip");
		strip.AddComponent<MeshRenderer>().material.Set("PaletteTest/swap.tmat");
		let stripMesh = scope EditMesh();
		MeshShapes.AddBox(stripMesh, .(-2, 1.4f, -1), .(2, 1.9f, 1));
		for (let face in stripMesh.faces)
		{
			for (var c in ref face.colors)
				c = opaque;
		}
		strip.AddComponent<ModelMesh>().Set(stripMesh);
		// A thin pane in front of the left half: green, half see-through, so the box shows through it.
		let pane = mScene.CreateGameObject("Pane");
		pane.AddComponent<MeshRenderer>().material.Set("PaletteTest/box.tmat");
		let glass = scope EditMesh();
		MeshShapes.AddBox(glass, .(-2, -2, -1.6f), .(0, 2, -1.5f));
		for (let face in glass.faces)
		{
			for (var c in ref face.colors)
				c = .FromBytes(6, 0, 128, Mesh.PaletteTransparent | Mesh.PaletteUnlit);
		}
		pane.AddComponent<ModelMesh>().Set(glass);
		Expect(SceneSerializer.SaveToFile(mScene, scope $"{Assets.ProjectPath}/PaletteTest/Palette.tscene"), "the scene is written");

		// A palette voxel wall: after a carve every triangle is wholly the outside's entry or the inside's.
		SceneSerializer.Load(mScene, "scene \"Voxels\"\n");
		let wall = mScene.CreateGameObject("Wall");
		wall.AddComponent<MeshRenderer>().material.Set("PaletteTest/box.tmat");
		let voxels = wall.AddComponent<VoxelObject>();
		voxels.shape = .Box;
		voxels.size = 2;
		voxels.resolution = 16;
		voxels.paletteEntry = 5;
		voxels.interiorPaletteEntry = 6;
		voxels.anchored = true;
		voxels.Rebuild();
		voxels.Carve(wall.Transform.Position + .(0, 0, -1), 0.6f);
		let voxelMesh = voxels.Runtime.[Friend]mMesh;
		let outerColor = Color.FromBytes(5, 0, 24 << 3, 0).ToABGR(), innerColor = Color.FromBytes(6, 0, 28 << 3, 0).ToABGR();
		int outsideTriangles = 0, insideTriangles = 0, mixed = 0;
		for (int i = 0; i + 2 < voxelMesh.Indices.Count; i += 3)
		{
			let c0 = voxelMesh.Vertices[(int)voxelMesh.Indices[i]].color, c1 = voxelMesh.Vertices[(int)voxelMesh.Indices[i + 1]].color, c2 = voxelMesh.Vertices[(int)voxelMesh.Indices[i + 2]].color;
			if (c0 != c1 || c1 != c2 || (c0 != outerColor && c0 != innerColor))
				mixed++;
			else if (c0 == outerColor)
				outsideTriangles++;
			else
				insideTriangles++;
		}
		Expect(mixed == 0 && outsideTriangles > 0 && insideTriangles > 0, scope $"a carved palette voxel wall has one entry per triangle ({outsideTriangles} outside, {insideTriangles} inside, {mixed} mixed)");

		SceneSerializer.Load(mScene, stash);
		mScene.Path.Set(stashPath);
		Log.Info(scope $"PALETTE-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}
}
