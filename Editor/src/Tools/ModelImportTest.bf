using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// Test switch --model-import-test [--model-import-fbx <rigged .fbx>]: writes an OBJ, an STL and a DAE (and a .blend
/// when Blender is installed) into the project, converts them, and checks the settings (scale, Z up, clips,
/// materials), a Mesh Renderer showing one, and that a changed file is converted again in the background. Removes
/// what it made and logs MODEL-IMPORT-TEST PASS or FAIL.
extension EditorApp
{
	const String TestFolder = "ModelImportTest";

	void RunModelImportTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		let folder = scope $"{Assets.ProjectPath}/{TestFolder}";
		Directory.CreateDirectory(folder).IgnoreError();

		// A 1 x 1 x 4 boxModel, tall along Z.
		File.WriteAllText(scope $"{folder}/box.obj" ,
			"""
			v -0.5 -0.5 0
			v 0.5 -0.5 0
			v 0.5 0.5 0
			v -0.5 0.5 0
			v -0.5 -0.5 4
			v 0.5 -0.5 4
			v 0.5 0.5 4
			v -0.5 0.5 4
			f 1 2 3 4
			f 5 8 7 6
			f 1 5 6 2
			f 2 6 7 3
			f 3 7 8 4
			f 4 8 5 1

			""").IgnoreError();
		File.WriteAllText(scope $"{folder}/wedge.stl" ,
			"""
			solid wedge
			facet normal 0 0 1
			outer loop
			vertex 0 0 0
			vertex 3 0 0
			vertex 0 1 0
			endloop
			endfacet
			facet normal 0 -1 0
			outer loop
			vertex 0 0 0
			vertex 0 0 1
			vertex 3 0 0
			endloop
			endfacet
			endsolid wedge

			""").IgnoreError();
		File.WriteAllText(scope $"{folder}/triangle.dae" ,
			"""
			<?xml version="1.0" encoding="utf-8"?>
			<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
			<asset><unit name="meter" meter="1"/><up_axis>Y_UP</up_axis></asset>
			<library_geometries><geometry id="tri" name="tri"><mesh>
			<source id="pos"><float_array id="pos-a" count="9">0 0 0 1 0 0 0 2 0</float_array>
			<technique_common><accessor source="#pos-a" count="3" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
			<vertices id="verts"><input semantic="POSITION" source="#pos"/></vertices>
			<triangles count="1"><input semantic="VERTEX" source="#verts" offset="0"/><p>0 1 2</p></triangles>
			</mesh></geometry></library_geometries>
			<library_visual_scenes><visual_scene id="scene"><node id="n" name="n"><instance_geometry url="#tri"/></node></visual_scene></library_visual_scenes>
			<scene><instance_visual_scene url="#scene"/></scene>
			</COLLADA>

			""").IgnoreError();

		Vector3 Size(StringView relative)
		{
			SkinnedModel.Forget(relative);
			Assets.Forget(relative);
			let mesh = Assets.GetMesh(relative);
			return mesh != null ? mesh.Bounds.max - mesh.Bounds.min : .Zero;
		}
		bool Near(float a, float b) => Math.Abs(a - b) < 0.02f;
		bool Convert(StringView relative)
		{
			let error = scope String();
			let ok = ModelImport.Convert(relative, error);
			if (!ok)
				Log.Warning(scope $"{relative}: {error}");
			return ok;
		}
		void Settings(StringView relative, delegate void(ModelImportSettings) change)
		{
			let full = scope $"{Assets.ProjectPath}/{relative}";
			let settings = scope ModelImportSettings();
			settings.Read(full);
			change(settings);
			settings.Write(full);
		}

		// OBJ: converted as it is, then made half size, then stood up (Z up).
		let boxModel = scope $"{TestFolder}/box.obj";
		Expect(Convert(boxModel) && ModelImport.UpToDate(boxModel), "an OBJ converts");
		var size = Size(boxModel);
		Expect(Near(size.x, 1) && Near(size.z, 4), scope $"the OBJ keeps its size ({size})");
		Settings(boxModel, scope (s) =>
			{
				s.scale = 0.5f;
			}
			);
		Expect(!ModelImport.UpToDate(boxModel), "changed settings make it out of date");
		Convert(boxModel);
		size = Size(boxModel);
		Expect(Near(size.x, 0.5f) && Near(size.z, 2), scope $"Scale 0.5 halves it ({size})");
		Settings(boxModel, scope (s) =>
			{
				s.scale = 1;
				s.zUp = true;
			}
			);
		Convert(boxModel);
		size = Size(boxModel);
		Expect(Near(size.y, 4) && Near(size.z, 1), scope $"Z up stands it upright ({size})");

		// A Mesh Renderer names the OBJ itself.
		let holder = mScene.CreateGameObject("ModelImportTestObject");
		let renderer = holder.AddComponent<MeshRenderer>();
		renderer.mesh.Set(boxModel);
		Expect(renderer.ActiveMesh != null, "a Mesh Renderer shows the converted OBJ");

		// Two materials, one with a picture: a Mesh Renderer draws each with its own (useModelMaterials).
		uint8[?] png = .(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A, 0x73, 0x00, 0x00, 0x00, 0x13, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xC0, 0xF0, 0x1F, 0x8C, 0x18, 0xFE, 0x33, 0x00, 0x00, 0x1D, 0xF0, 0x03, 0xFD, 0xA6, 0x89, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82);
		File.WriteAll(scope $"{folder}/checker.png" , .(&png[0], png.Count)).IgnoreError();
		File.WriteAllText(scope $"{folder}/two.mtl" , "newmtl Painted\nKd 1 1 1\nmap_Kd checker.png\nnewmtl Plain\nKd 0.2 0.4 0.8\n").IgnoreError();
		File.WriteAllText(scope $"{folder}/two.obj" ,
			"""
			mtllib two.mtl
			v 0 0 0
			v 1 0 0
			v 1 1 0
			v 0 1 0
			v 2 0 0
			v 2 1 0
			vt 0 0
			vt 1 0
			vt 1 1
			vt 0 1
			usemtl Painted
			f 1/1 2/2 3/3 4/4
			usemtl Plain
			f 2/1 5/2 6/3 3/4

			""").IgnoreError();
		let two = scope $"{TestFolder}/two.obj";
		Expect(Convert(two), "an OBJ with two materials converts");
		Assets.Forget(two);
		let painted = mScene.CreateGameObject("ModelImportTestMaterials");
		let paintedRenderer = painted.AddComponent<MeshRenderer>();
		paintedRenderer.mesh.Set(two);
		let parts = paintedRenderer.DrawnParts;
		Expect(parts != null && parts.Count == 2, scope $"a Mesh Renderer draws each of its materials ({parts?.Count ?? 0} parts)");
		bool textured = false;
		if (parts != null)
		{
			for (let part in parts)
				textured |= part.material != null && !part.material.texture.IsEmpty && Assets.HasTexture(part.material.texture);
		}
		Expect(textured, "with the model's own picture");
		paintedRenderer.useModelMaterials = false;
		Expect(paintedRenderer.DrawnParts == null, "Use Model Materials off draws it as one mesh");
		paintedRenderer.useModelMaterials = true;
		paintedRenderer.texture.Set("builtin:white");
		Expect(paintedRenderer.DrawnParts == null, "a Texture set on the renderer takes over");
		mScene.Destroy(painted);

		// STL and DAE.
		let wedge = scope $"{TestFolder}/wedge.stl";
		Expect(Convert(wedge) && Near(Size(wedge).x, 3), "an STL converts");
		let triangle = scope $"{TestFolder}/triangle.dae";
		Expect(Convert(triangle) && Near(Size(triangle).y, 2), "a DAE converts");

		// A changed file is converted again on the importer's thread, and the renderer picks up the new mesh.
		Thread.Sleep(1100);
		let text = scope String();
		File.ReadAllText(scope $"{folder}/box.obj" , text).IgnoreError();
		text.Replace(" 4\n", " 6\n");
		File.WriteAllText(scope $"{folder}/box.obj" , text).IgnoreError();
		Expect(!ModelImport.UpToDate(boxModel), "an edited file is out of date");
		let meshVersion = Assets.MeshVersion;
		ModelImport.Scan();
		for (int i < 600)
		{
			if (!ModelImport.Busy)
				break;
			Thread.Sleep(100);
		}
		ModelImport.Update();
		Expect(ModelImport.UpToDate(boxModel) && Assets.MeshVersion != meshVersion, "it is converted again in the background");
		let shown = renderer.ActiveMesh;
		Expect(shown != null && Near(shown.Bounds.max.y - shown.Bounds.min.y, 6), "the renderer shows the new shape");
		mScene.Destroy(holder);

		// .blend, through Blender (its start-up scene: a 2 m cube).
		if (!ModelImport.Blender.IsEmpty)
		{
			let blend = scope $"{folder}/cube.blend";
			let command = scope String();
			Terminal.Quote(ModelImport.Blender, command);
			command.Append(" -b --factory-startup --python-expr ");
			Terminal.Quote(scope $"import bpy; bpy.ops.wm.save_as_mainfile(filepath=r'{blend}')" , command);
			command.AppendF(" > {} 2>&1", Terminal.Null);
			Terminal.Run(command);
			let relative = scope $"{TestFolder}/cube.blend";
			Expect(Convert(relative) && Near(Size(relative).y, 2), scope $"a .blend converts through Blender");
		}
		else
			report.Append("; Blender not found, .blend skipped");

		// A rigged FBX: bones and clips come through; clips and materials can be left out.
		let fbxSource = scope String();
		if (GetArg("--model-import-fbx", fbxSource) && File.Exists(fbxSource))
		{
			let relative = scope $"{TestFolder}/rig.fbx";
			File.Copy(fbxSource, scope $"{folder}/rig.fbx" , true).IgnoreError();
			Expect(Convert(relative), "a rigged FBX converts");
			// FBX files are often in centimetres: a character (all its meshes) should come in metres, not 100 times that.
			let height = Size(relative).y;
			Expect(height > 1 && height < 2.5f, scope $"it comes in at its real size ({height} m tall)");
			SkinnedModel.Forget(relative);
			var model = SkinnedModel.Load(relative);
			let clips = model?.Clips.Count ?? 0;
			Expect(model != null && model.Joints.Count > 0, scope $"its bones come through ({model?.Joints.Count ?? 0})");
			let names = scope List<String>();
			ModelImport.ClipNames(relative, names);
			Expect(names.Count == clips, scope $"its clips are listed ({clips})");
			bool hadMaterial = model != null && model.Parts.Count > 0 && model.Parts[0].fileMaterial >= 0;
			Settings(relative, scope (s) =>
				{
					s.animations = false;
					s.materials = false;
				}
				);
			Convert(relative);
			SkinnedModel.Forget(relative);
			model = SkinnedModel.Load(relative);
			Expect(model != null && model.Clips.Count == 0, "Animations off leaves the clips out");
			Expect(!hadMaterial || (model != null && model.Parts[0].fileMaterial < 0), "Materials off leaves the materials out");
			if (names.Count > 0)
			{
				Settings(relative, scope (s) =>
					{
						s.animations = true;
						s.materials = true;
						s.clips.Set(names[0]);
					}
					);
				Convert(relative);
				SkinnedModel.Forget(relative);
				model = SkinnedModel.Load(relative);
				Expect(model != null && model.Clips.Count == 1, "a clip chosen by name is the one kept");
			}
			ClearAndDeleteItems!(names);
			SkinnedModel.Forget(relative);
		}

		Assets.Forget(TestFolder);
		Directory.DelTree(folder).IgnoreError();
		let cache = Assets.ConvertedModelCache(TestFolder, .. scope .());
		cache.RemoveFromEnd(4);
		Directory.DelTree(cache).IgnoreError();
		Log.Info(scope $"MODEL-IMPORT-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}
}
