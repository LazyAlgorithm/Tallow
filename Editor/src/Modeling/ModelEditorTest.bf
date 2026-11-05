using System;
using System.Collections;
using System.IO;
using Bgfx;
using Tallow;

namespace Tallow.Editor;

/// Test switch --model-test: builds models the way the Model window does, checks the results, undo and redo and
/// picking in the Scene view, then logs MODEL-TEST PASS or FAIL and leaves a model in edit mode for a screenshot.
/// --model-window opens the Model window and --uv-editor the UV Editor; with --model-test, --model-help shows the
/// shortcut sheet and --model-menu opens the right-click menu for the screenshot.
extension EditorApp
{
	int32 mModelTestFrames;
	bool mModelMenuRequest;

	void ApplyModelSwitches()
	{
		if (HasArg("--model-window"))
			mShowModel = true;
		if (HasArg("--uv-editor"))
			mShowUVEditor = true;
		// Waits for the Scene view to be laid out, since the test picks faces on screen.
		if (HasArg("--model-test"))
			mModelTestFrames = 20;
	}

	void TickModelTest()
	{
		if (mModelTestFrames > 0 && --mModelTestFrames == 0)
			RunModelTest();
	}

	void RunModelTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		mShowModel = true;
		// Settle any changes made while loading into the undo history first.
		mUndoPending = false;
		CommitSceneStep();
		mCamPosition = .(0, 4, -9);
		mCamYaw = 0;
		mCamPitch = 20;
		UpdateSceneCamera(mSceneSize.x / Math.Max(mSceneSize.y, 1));

		// A block drawn as the Scene view's shape tool makes it: base dragged from (-1, 0, -1) to (1, 0, 1), 1 high.
		mModelDrawKind = (int32)MeshShapes.Kind.Box;
		mModelDraw = .Height;
		mModelDrawFrom = .(-1, 0, -1);
		mModelDrawTo = .(1, 0, 1);
		mModelDrawHeight = 1;
		FinishShape();
		let block = Selected;
		let model = GameObject.ComponentOn<ModelMesh>(block);
		Expect(model.IsValid && model.Edit.faces.Count == 6 && block.GetComponent<MeshRenderer>().ActiveMesh?.Indices.Count == 36, "drawing a box makes a 6-faced model the renderer draws");
		if (!model.IsValid)
		{
			Log.Info(scope $"MODEL-TEST FAIL: {report}");
			return;
		}
		mUndoPending = false;
		CommitSceneStep();

		// Edit mode: click the top face in the Scene view.
		StartModelEditing(block);
		SetModelMode(.Face, model.Edit);
		// Show only this model: on unless turned off, hiding the rest in the Scene view only, and remembered.
		{
			let showOnlyFile = ModelShowOnlyFile(.. scope .());
			let savedShowOnly = scope String();
			let hadShowOnly = File.ReadAllText(showOnlyFile, savedShowOnly) case .Ok;
			File.Delete(showOnlyFile).IgnoreError();
			mModelShowOnlyLoaded = false;
			mModelShowOnly = false;
			UpdateModelShowOnly();
			Expect(mModelShowOnly && mSceneView.onlyObject == block.Id, "edit mode shows only the model by default");
			SetModelShowOnly(false);
			UpdateModelShowOnly();
			Expect(mSceneView.onlyObject == 0, "turned off, everything shows");
			mModelShowOnlyLoaded = false;
			mModelShowOnly = true;
			LoadModelShowOnly();
			Expect(!mModelShowOnly, "the choice is remembered");
			if (hadShowOnly)
				File.WriteAllText(showOnlyFile, savedShowOnly).IgnoreError();
			else
				File.Delete(showOnlyFile).IgnoreError();
			mModelShowOnlyLoaded = false;
			LoadModelShowOnly();
			UpdateModelShowOnly();
		}
		// Shortcuts: the defaults, a changed one written and read back, and names round the way they are written.
		{
			let shortcutsFile = ModelShortcutsFile(.. scope .());
			let savedShortcuts = scope String();
			let hadShortcuts = File.ReadAllText(shortcutsFile, savedShortcuts) case .Ok;
			File.Delete(shortcutsFile).IgnoreError();
			DeleteAndNullify!(mModelShortcuts);
			DeleteAndNullify!(mModelShortcutText);
			Expect(ModelKeys(.Bevel) == "Ctrl+B" && ModelKeys(.Delete) == "X, Delete, Shift+Delete" && ModelShortcutText(ShortcutShowOnly) == "/", scope $"the default shortcuts ({ModelKeys(.Bevel)}; {ModelKeys(.Delete)})");
			Expect(ShortcutParseChord("Ctrl+Shift+Keypad +") == (ChordCtrl | ChordShift | 626) && ShortcutParseChord("Alt+F5") == (ChordAlt | ImGui.Key.F5) && ShortcutParseChord("Nope") == 0, "shortcuts are read as written");
			let bevel = ModelCommandShortcut(.Bevel);
			mModelShortcuts[bevel].Clear();
			mModelShortcuts[bevel].Add(ChordCtrl | ChordShift | ImGui.Key.B);
			RefreshModelShortcutText();
			SaveModelShortcuts();
			DeleteAndNullify!(mModelShortcuts);
			DeleteAndNullify!(mModelShortcutText);
			Expect(ModelKeys(.Bevel) == "Ctrl+Shift+B" && ModelKeys(.Grab) == "G", scope $"a changed shortcut is kept ({ModelKeys(.Bevel)})");
			let written = scope String();
			File.ReadAllText(shortcutsFile, written).IgnoreError();
			written.Trim();
			Expect(written == "Bevel=Ctrl+Shift+B", scope $"only changes are written ({written})");
			if (hadShortcuts)
				File.WriteAllText(shortcutsFile, savedShortcuts).IgnoreError();
			else
				File.Delete(shortcutsFile).IgnoreError();
			DeleteAndNullify!(mModelShortcuts);
			DeleteAndNullify!(mModelShortcutText);
		}
		let mesh = model.Edit;
		int32 top = -1;
		for (int32 f < (int32)mesh.faces.Count)
		{
			if (mesh.FaceNormal(mesh.faces[f]).y > 0.9f)
				top = f;
		}
		let world = model.Transform.LocalToWorld;
		let topCenter = world.TransformPoint(mesh.FaceCenter(mesh.faces[top]));
		bool picked = false;
		if (SceneToScreen(topCenter, mSceneOrigin, mSceneSize, let screen))
		{
			PickModelElement(mesh, world, model.Transform.WorldToLocal, mSceneOrigin, mSceneSize, screen, false);
			picked = mModelFaces.Count == 1 && mModelFaces.Contains(top);
		}
		Expect(picked, "clicking the top face picks it");
		mModelFaces.Clear();
		mModelFaces.Add(top);

		// Extrude up 1, inset, extrude the inset face down into a dish.
		mModelExtrude = 1;
		ModelFaceAction(model, mesh, .Extrude);
		Expect(model.Edit.IsClosed() && Math.Abs(model.Edit.Volume() - 8) < 0.01f && Math.Abs(model.Edit.Bounds.max.y - 2) < 0.001f, "extruding the top 1 m makes a 2x2x2 block");
		mModelInset = 0.25f;
		ModelFaceAction(model, model.Edit, .Inset);
		mModelExtrude = -0.5f;
		ModelFaceAction(model, model.Edit, .Extrude);
		Expect(model.Edit.IsClosed() && Math.Abs(model.Edit.Volume() - (8 - 1.5f * 1.5f * 0.5f)) < 0.01f, scope $"inset and pushing in makes a dish ({model.Edit.Volume():0.###})");
		mUndoPending = false;
		CommitSceneStep();
		let facesBefore = model.Edit.faces.Count;

		// Bevel the block's four upright edges.
		SetModelMode(.Edge, model.Edit);
		mModelEdges.Clear();
		let all = scope List<uint64>();
		model.Edit.Edges(all);
		for (let e in all)
		{
			EditMesh.EdgeEnds(e, let a, let b);
			let pa = model.Edit.positions[a], pb = model.Edit.positions[b];
			if (Math.Abs(pa.x - pb.x) < 0.001f && Math.Abs(pa.z - pb.z) < 0.001f && Math.Abs(Math.Abs(pa.x) - 1) < 0.001f && Math.Abs(Math.Abs(pa.z) - 1) < 0.001f)
				mModelEdges.Add(e);
		}
		mModelBevel = 0.2f;
		ModelEdgeAction(model, model.Edit, .Bevel);
		Expect(model.Edit.IsClosed() && model.Edit.faces.Count > facesBefore, scope $"bevelling the upright edges keeps it closed ({model.Edit.faces.Count} faces)");
		mUndoPending = false;
		CommitSceneStep();

		// Undo takes the bevel off; redo puts it back. The model is rebuilt from the scene's text each way.
		let bevelled = model.Edit.faces.Count;
		Undo();
		let undone = GameObject.ComponentOn<ModelMesh>(mScene.FindById(block.Id));
		Expect(undone.IsValid && undone.Edit.faces.Count == facesBefore && undone.DrawnMesh != null, scope $"undo takes the bevel off ({undone?.Edit.faces.Count} faces)");
		Redo();
		let redone = GameObject.ComponentOn<ModelMesh>(mScene.FindById(block.Id));
		Expect(redone.IsValid && redone.Edit.faces.Count == bevelled, "redo puts it back");

		// A doorway: a box cut out of a wall.
		mModelEditing = false;
		let wallShape = MeshShapes.Create(.Box, .() { size = .(4, 3, 0.3f) });
		defer delete wallShape;
		let wall = CreateModelObject("Wall", wallShape, .(4, 0, 0));
		let doorShape = MeshShapes.Create(.Box, .() { size = .(1, 2.2f, 1) });
		defer delete doorShape;
		let door = CreateModelObject("Door Cutter", doorShape, .(4, -0.2f, 0));
		mModelBooleanOp = 1;
		mModelBooleanKeep = false;
		let wallModel = wall.GetComponent<ModelMesh>();
		ModelBoolean(wallModel, door);
		let expected = 4 * 3 * 0.3f - 1 * 2 * 0.3f;
		Expect(Math.Abs(wallModel.Edit.Volume() - expected) < 0.01f, scope $"cutting a doorway out of a wall ({wallModel.Edit.Volume():0.###}, {wallModel.Edit.faces.Count} faces)");
		Expect(wallModel.Edit.IsClosed(), "the wall is still closed");
		let cutter = mScene.FindById(door.Id);
		Expect(cutter == null || cutter.IsDestroyed, "the cutting box is removed");
		// What it draws (and its Mesh Collider takes) has the doorway: a ray through it goes through.
		let drawn = wall.GetComponent<MeshRenderer>().ActiveMesh;
		let toWall = wall.Transform.WorldToLocal;
		let throughDoor = drawn.Raycast(Ray(toWall.TransformPoint(.(4, 1, -3)), .(0, 0, 1)));
		let besideDoor = drawn.Raycast(Ray(toWall.TransformPoint(.(5.5f, 1, -3)), .(0, 0, 1)));
		Expect(throughDoor < 0 && besideDoor > 0, scope $"the drawn wall has the doorway (through it {throughDoor:0.##}, beside it {besideDoor:0.##})");

		// Unwrap: the wall's faces go into the picture without overlapping.
		let faces = scope List<int32>();
		for (int32 f < (int32)wallModel.Edit.faces.Count)
			faces.Add(f);
		MeshUV.SmartUnwrap(wallModel.Edit, faces);
		CommitModel(wallModel);
		Expect(MeshUV.Overlap(wallModel.Edit, faces) < 0.01f, "smart unwrap of the wall has no overlap");

		// Export and read back.
		mModelExportPath.Set("Models/model_test.glb");
		ExportModel(wallModel);
		let exported = Assets.BuildModel("Models/model_test.glb");
		Expect(exported != null && exported.Indices.Count == wallModel.DrawnMesh.Indices.Count, "the wall exports to a .glb that reads back");
		delete exported;
		System.IO.File.Delete(Assets.ResolvePath("Models/model_test.glb", .. scope .())).IgnoreError();

		RunModelToolTests(scope [&] (condition, what) => Expect(condition, what));

		// Leave the dish in edit mode with its top faces selected, for the screenshot.
		mSelectedId = block.Id;
		StartModelEditing(block);
		let shown = block.GetComponent<ModelMesh>();
		mModelMode = .Face;
		for (int32 f < (int32)shown.Edit.faces.Count)
		{
			if (shown.Edit.FaceNormal(shown.Edit.faces[f]).y > 0.9f && shown.Edit.FaceCenter(shown.Edit.faces[f]).y > 1.9f)
				mModelFaces.Add(f);
		}
		mModelActive = mModelFaces.IsEmpty ? -1 : 0;
		for (let f in mModelFaces)
		{
			mModelActive = f;
			break;
		}
		if (HasArg("--model-round"))
		{
			// A box with every edge bevelled round, beside the dish, to look at.
			let round = MeshShapes.Create(.Box, .() { size = .(1.5f, 1.5f, 1.5f) });
			defer delete round;
			let roundEdges = scope List<uint64>();
			round.Edges(roundEdges);
			MeshOps.Bevel(round, roundEdges, 0.3f, null, 4);
			CreateModelObject("Round Box", round, .(2.6f, 0, -0.5f));
			mSelectedId = block.Id;
		}
		// A reference image behind the model, from the front: drawn only in the editor's views, never picked, not saved.
		{
			LoadModelReferences();
			let reference = new ModelReference();
			reference.view = .Front;
			reference.image.Set("Textures/checker.png");
			Vector3 at;
			float radius;
			ModelViewTarget(out at, out radius);
			reference.centre = at;
			reference.width = radius * 2;
			reference.behind = radius + 0.05f;
			mModelReferences.Add(reference);
			SyncModelReferences();
			let object = mScene.FindById(reference.objectId);
			Expect(object != null && object.Transient && RenderView.EditorOnlyObjects.Contains(object.Id) && !mGameView.drawEditorOnly && mSceneView.drawEditorOnly, "a reference image is an editor-only object, not saved");
			Expect(object != null && Vector3.Dot(object.Transform.Position - at, .(0, 0, 1)) > radius * 0.9f, "it stands behind the model, away from the front view");
			if (!HasArg("--model-reference"))
			{
				mModelReferences.Remove(reference);
				if (object != null)
					mScene.Destroy(object);
				delete reference;
			}
		}
		// The Model Views look at the model.
		if (mShowModelViews)
		{
			EnsureModelViews();
			Vector3 at;
			float radius;
			ModelViewTarget(out at, out radius);
			for (let viewport in mModelViewports)
				FrameModelView(viewport, at, radius);
			mFocusModelViews = true;
			// --view-shading wireframe,solid,unlit,rendered: each view's shading, in order (a fifth for the Scene view).
			let shadingArg = scope String();
			GetArg("--view-shading", shadingArg);
			int index = 0;
			for (let part in shadingArg.Split(','))
			{
				for (int k < sShadingNames.Count)
				{
					if (sShadingNames[k].StartsWith(part, .OrdinalIgnoreCase))
					{
						if (index < mModelViewports.Count)
							mModelViewports[index].shading = (ViewShading)k;
						else
							mSceneShading = (ViewShading)k;
					}
				}
				index++;
			}
		}
		// Origins: the model stays where it is in the world while its origin moves.
		{
			let shape = MeshShapes.Create(.Box, .() { size = .(2, 1, 4) });
			defer delete shape;
			let editedId = mSelectedId;
			let made = CreateModelObject("Origin Box", shape, .(20, 3, 7));
			let originModel = made.GetComponent<ModelMesh>();
			let originMesh = originModel.Edit;
			let corner = made.Transform.TransformPoint(originMesh.positions[0]);
			let middle = made.Transform.TransformPoint(originMesh.Bounds.Center);
			let bottom = made.Transform.TransformPoint(originMesh.Bounds.min).y;
			RunModelCommand(originModel, originMesh, .OriginToBase);
			Expect(Math.Abs(made.Transform.Position.y - bottom) < 0.001f, "origin to base");
			RunModelCommand(originModel, originMesh, .OriginToVolumeMass);
			Expect((made.Transform.Position - middle).Length < 0.001f, "origin to centre of mass (volume)");
			RunModelCommand(originModel, originMesh, .OriginToBase);
			RunModelCommand(originModel, originMesh, .OriginToSurfaceMass);
			Expect((made.Transform.Position - middle).Length < 0.001f, "origin to centre of mass (surface)");
			RunModelCommand(originModel, originMesh, .OriginToBase);
			RunModelCommand(originModel, originMesh, .OriginToGeometry);
			Expect((made.Transform.Position - middle).Length < 0.001f, "origin to geometry");
			mModelOriginObject = block.Id;
			RunModelCommand(originModel, originMesh, .OriginToObject);
			Expect((made.Transform.Position - block.Transform.Position).Length < 0.001f, "origin to another object");
			Expect((made.Transform.TransformPoint(originModel.Edit.positions[0]) - corner).Length < 0.001f, "the model stays where it was");
			RunModelCommand(originModel, originModel.Edit, .GeometryToOrigin);
			Expect(originModel.Edit.Bounds.Center.Length < 0.001f, "geometry to origin");
			// A half-filled shape: its solid's centre of mass is not its box's middle.
			let wedge = new EditMesh();
			defer delete wedge;
			Vector3[6] points = .(.(0, 0, 0), .(2, 0, 0), .(0, 2, 0), .(0, 0, 1), .(2, 0, 1), .(0, 2, 1));
			for (let p in points)
				wedge.positions.Add(p);
			int32[5][4] quads = .(.(0, 2, 1, -1), .(3, 4, 5, -1), .(0, 1, 4, 3), .(0, 3, 5, 2), .(1, 2, 5, 4));
			for (let quad in quads)
			{
				let face = new EditFace();
				for (let v in quad)
				{
					if (v >= 0)
					{
						face.verts.Add(v);
						face.uvs.Add(.(0, 0));
						face.colors.Add(.White);
					}
				}
				wedge.faces.Add(face);
			}
			let mass = MeshOps.VolumeCentre(wedge);
			Expect(wedge.IsClosed() && (mass - Vector3(2 / 3.0f, 2 / 3.0f, 0.5f)).Length < 0.001f, "a wedge's centre of mass");
			mScene.Destroy(made);
			mSelectedId = editedId;
			let edgeMesh = block.GetComponent<MeshRenderer>().ActiveMesh;
			bgfx.IndexBufferHandle edges;
			int32 edgeCount = 0;
			Expect(edgeMesh != null && edgeMesh.EdgeLines(out edges, out edgeCount) && edgeCount > 0 && edgeCount % 2 == 0, "a mesh's edges for wireframe");
		}
		// Gizmos: with Show Only, only the edited model's are drawn.
		Expect(IsolatedObject == block.Id || !mModelShowOnly, "only the edited model's gizmos are drawn");
		mModelShowHelp = HasArg("--model-help");
		mModelMenuRequest = HasArg("--model-menu");
		mCamPosition = .(1.6f, 4.2f, -3.6f);
		mCamYaw = -22;
		mCamPitch = 38;
		Log.Info(scope $"MODEL-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}

	/// The tools that follow the pointer, driven with typed amounts (as a user would type them after the key), and
	/// the commands behind the shortcuts.
	void RunModelToolTests(delegate void(bool condition, StringView what) expect)
	{
		let shape = MeshShapes.Create(.Box, .() { size = .(2, 2, 2) });
		defer delete shape;
		let made = CreateModelObject("Tool Box", shape, .(-5, 0, 0));
		let model = made.GetComponent<ModelMesh>();
		StartModelEditing(made);
		SetModelMode(.Face, model.Edit);
		int32 FaceFacing(Vector3 direction)
		{
			let mesh = model.Edit;
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
		// Runs a tool as if a key started it and a number was typed, then Enter.
		void Typed(ModelTool tool, StringView number, int32 axis = -1, bool cancel = false)
		{
			StartModelTool(model, model.Edit, tool);
			mModelAxis = axis;
			mModelTyped.Set(number);
			ApplyModelTool(model, model.Edit, model.Transform.WorldToLocal, mModelToolMouse);
			if (cancel)
				CancelModelTool(model, model.Edit);
			else
				FinishModelTool(model, model.Edit);
		}
		let top = FaceFacing(.Up);
		mModelFaces.Clear();
		mModelFaces.Add(top);
		Typed(.Grab, "0.5", 1);
		expect(Math.Abs(model.Edit.Bounds.max.y - 2.5f) < 0.001f && Math.Abs(model.Edit.Volume() - 10) < 0.01f, "G, Y, 0.5 lifts the top face half a metre");
		Typed(.Grab, "3", 1, true);
		expect(Math.Abs(model.Edit.Bounds.max.y - 2.5f) < 0.001f, "cancelling a grab puts it back");
		Typed(.Extrude, "1");
		expect(model.Edit.IsClosed() && Math.Abs(model.Edit.Volume() - 14) < 0.01f && model.Edit.faces.Count == 10, scope $"E, 1 extrudes the top a metre ({model.Edit.Volume():0.###})");
		Typed(.Inset, "0.25");
		Typed(.Extrude, "-0.5");
		expect(model.Edit.IsClosed() && Math.Abs(model.Edit.Volume() - (14 - 1.5f * 1.5f * 0.5f)) < 0.01f, scope $"I, 0.25 then E, -0.5 sinks a dish ({model.Edit.Volume():0.###})");

		// The whole model: rotate a quarter turn about Y, scale by 2.
		SelectAllModel(model.Edit, false);
		let before = model.Edit.Bounds;
		Typed(.Rotate, "90", 1);
		let turned = model.Edit.Bounds;
		expect(Math.Abs(turned.Extents.y - before.Extents.y) < 0.001f && model.Edit.IsClosed(), "R, Y, 90 turns it about the up axis");
		let volume = model.Edit.Volume();
		Typed(.Scale, "2");
		expect(Math.Abs(model.Edit.Volume() - volume * 8) < 0.05f, scope $"S, 2 doubles its size ({model.Edit.Volume():0.###})");
		Typed(.Scale, "0.5");

		// Live mirroring: moving the +X side out moves the -X side out too.
		let mirror = MeshShapes.Create(.Box, .() { size = .(2, 2, 2) });
		defer delete mirror;
		model.Set(mirror);
		ClearModelSelection();
		mModelFaces.Add(FaceFacing(.Right));
		mModelSymmetry[0] = true;
		Typed(.Grab, "0.5", 0);
		mModelSymmetry[0] = false;
		let mirrored = model.Edit.Bounds;
		expect(Math.Abs(mirrored.max.x - 1.5f) < 0.001f && Math.Abs(mirrored.min.x + 1.5f) < 0.001f, scope $"with Mirror Edits X both sides move ({mirrored.min.x:0.##} to {mirrored.max.x:0.##})");

		// Proportional editing: the top's neighbours follow part way.
		let subdivided = MeshShapes.Create(.Box, .() { size = .(2, 2, 2) });
		defer delete subdivided;
		let all = scope List<int32>();
		for (int32 f < (int32)subdivided.faces.Count)
			all.Add(f);
		MeshOps.Subdivide(subdivided, all);
		model.Set(subdivided);
		SetModelMode(.Vertex, model.Edit);
		ClearModelSelection();
		int32 topMiddle = -1;
		for (int32 v < (int32)model.Edit.positions.Count)
		{
			let p = model.Edit.positions[v];
			if (Math.Abs(p.x) < 0.001f && Math.Abs(p.z) < 0.001f && p.y > 1.9f)
				topMiddle = v;
		}
		mModelVerts.Add(topMiddle);
		mModelProportional = true;
		mModelPropRadius = 1.5f;
		Typed(.Grab, "1", 1);
		mModelProportional = false;
		int raised = 0;
		for (let p in model.Edit.positions)
		{
			if (p.y > 2.01f && p.y < 2.99f)
				raised++;
		}
		expect(Math.Abs(model.Edit.positions[topMiddle].y - 3) < 0.001f && raised > 0, scope $"proportional editing pulls the neighbours part way ({raised} followed)");

		// Commands behind the shortcuts.
		model.Set(shape);
		SetModelMode(.Face, model.Edit);
		SelectAllModel(model.Edit, false);
		RunModelCommand(model, model.Edit, .Triangulate);
		expect(model.Edit.faces.Count == 12, "Ctrl+T triangulates");
		SelectAllModel(model.Edit, false);
		RunModelCommand(model, model.Edit, .TrianglesToQuads);
		expect(model.Edit.faces.Count == 6 && model.Edit.IsClosed(), "Alt+J joins them back into quads");
		ClearModelSelection();
		mModelFaces.Add(FaceFacing(.Up));
		RunModelCommand(model, model.Edit, .Poke);
		expect(model.Edit.faces.Count == 9 && model.Edit.IsClosed(), "Poke fans the top");
		ClearModelSelection();
		mModelFaces.Add(FaceFacing(.Forward));
		GrowModelSelection(model.Edit, true);
		let grown = mModelFaces.Count;
		GrowModelSelection(model.Edit, false);
		expect(grown > 1 && mModelFaces.Count < grown, scope $"Ctrl+= grows and Ctrl+- shrinks the selection ({grown}, then {mModelFaces.Count})");
		let shrunk = mModelFaces.Count;
		InvertModelSelection(model.Edit);
		expect(mModelFaces.Count == model.Edit.faces.Count - shrunk, "Ctrl+I inverts it");

		// Hiding leaves faces out of what is drawn, and Alt+H brings them back.
		ClearModelSelection();
		mModelFaces.Add(FaceFacing(.Up));
		let drawnBefore = model.DrawnMesh.Indices.Count;
		RunModelCommand(model, model.Edit, .Hide);
		let drawnHidden = model.DrawnMesh.Indices.Count;
		RunModelCommand(model, model.Edit, .Reveal);
		expect(drawnHidden < drawnBefore && model.DrawnMesh.Indices.Count == drawnBefore, scope $"H hides faces and Alt+H shows them ({drawnBefore}, {drawnHidden}, {model.DrawnMesh.Indices.Count} indices)");

		// Make Face closes a hole from its corners.
		SetModelMode(.Face, model.Edit);
		ClearModelSelection();
		let lid = FaceFacing(.Down);
		mModelFaces.Add(lid);
		ModelFaceAction(model, model.Edit, .Delete);
		SetModelMode(.Vertex, model.Edit);
		ClearModelSelection();
		let open = scope List<uint64>();
		MeshOps.OpenEdges(model.Edit, open);
		for (let e in open)
		{
			EditMesh.EdgeEnds(e, let a, let b);
			mModelVerts.Add(a);
			mModelVerts.Add(b);
		}
		let holeCorners = mModelVerts.Count;
		RunModelCommand(model, model.Edit, .MakeFace);
		expect(holeCorners == 4 && model.Edit.IsClosed() && model.Edit.Volume() > 0, scope $"F makes a face from the hole's corners, facing out ({model.Edit.Volume():0.###})");

		RunModelThirdPassTests(model, expect);
		mModelEditing = false;
		mScene.Destroy(made);
	}

	/// Round bevels, sliding, the knife inside a face, UV picking, texture painting and levels of detail.
	void RunModelThirdPassTests(ModelMesh model, delegate void(bool condition, StringView what) expect)
	{
		void Reset()
		{
			let fresh = MeshShapes.Create(.Box, .() { size = .(2, 2, 2) });
			model.Set(fresh);
			delete fresh;
			ClearModelSelection();
		}
		void Typed(ModelTool tool, StringView number)
		{
			StartModelTool(model, model.Edit, tool);
			mModelTyped.Set(number);
			ApplyModelTool(model, model.Edit, model.Transform.WorldToLocal, mModelToolMouse);
			FinishModelTool(model, model.Edit);
		}
		// Ctrl+B with three segments rounds the top's four edges.
		Reset();
		SetModelMode(.Edge, model.Edit);
		ClearModelSelection();
		let edges = scope List<uint64>();
		model.Edit.Edges(edges);
		for (let e in edges)
		{
			EditMesh.EdgeEnds(e, let a, let b);
			if (model.Edit.positions[a].y > 1.9f && model.Edit.positions[b].y > 1.9f)
				mModelEdges.Add(e);
		}
		mModelBevelSegments = 3;
		Typed(.Bevel, "0.3");
		mModelBevelSegments = 1;
		var smooth = 0;
		for (let face in model.Edit.faces)
		{
			if (face.smooth)
				smooth++;
		}
		expect(model.Edit.IsClosed() && smooth == 12 && model.Edit.Volume() < 8 && model.Edit.Volume() > 8 - 4 * 2 * 0.045f, scope $"Ctrl+B with 3 segments rounds the top edges ({smooth} smooth faces, {model.Edit.Volume():0.###})");

		// G G slides a loop half way up towards the top.
		Reset();
		uint64 upright = 0;
		for (let face in model.Edit.faces)
		{
			for (int i < face.Count)
			{
				let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
				if (Math.Abs(model.Edit.positions[a].y - model.Edit.positions[b].y) > 1)
					upright = EditMesh.EdgeKey(a, b);
			}
		}
		let loop = scope List<uint64>();
		MeshOps.LoopCut(model.Edit, upright, 1, 0.5f, loop);
		CommitModel(model);
		SetModelMode(.Edge, model.Edit);
		ClearModelSelection();
		for (let e in loop)
			mModelEdges.Add(e);
		Typed(.Slide, "0.5");
		EditMesh.EdgeEnds(loop[0], let loopVertex, ?);
		let slidY = model.Edit.positions[loopVertex].y;
		expect(model.Edit.IsClosed() && Math.Abs(model.Edit.Volume() - 8) < 0.01f && (Math.Abs(slidY - 1.5f) < 0.001f || Math.Abs(slidY - 0.5f) < 0.001f), scope $"sliding the loop half way keeps the shape ({slidY:0.###})");

		// Shift+V slides a corner half way along one of its edges.
		Reset();
		SetModelMode(.Vertex, model.Edit);
		ClearModelSelection();
		mModelVerts.Add(0);
		let corner = model.Edit.positions[0];
		Typed(.VertexSlide, "0.5");
		expect(Math.Abs((model.Edit.positions[0] - corner).Length - 1) < 0.001f, "Shift+V slides a corner half way along an edge");

		// The knife snaps to a point inside a face and cuts through it.
		Reset();
		let world = model.Transform.LocalToWorld;
		let toLocal = model.Transform.WorldToLocal;
		let inside = Vector3(0.2f, 1.4f, -1);
		var snapped = Vector3.Zero;
		var snappedOk = false;
		if (SceneToScreen(world.TransformPoint(inside), mSceneOrigin, mSceneSize, let screen))
			snappedOk = ModelKnifeSnap(model.Edit, world, toLocal, screen, out snapped);
		expect(snappedOk && (snapped - inside).Length < 0.05f, scope $"the knife finds a point inside a face ({snapped.x:0.##} {snapped.y:0.##} {snapped.z:0.##})");
		let knifePoints = scope List<Vector3>() { .(-1, 1, -1), snapped, .(1, 1, -1) };
		let cuts = MeshOps.Knife(model.Edit, knifePoints, toLocal.TransformPoint(mCamPosition));
		CommitModel(model);
		expect(cuts == 1 && model.Edit.faces.Count == 7 && model.Edit.IsClosed(), scope $"and cuts the face through it ({cuts} cuts, {model.Edit.faces.Count} faces)");

		// The UV Editor picks whole pieces, or points.
		Reset();
		let all = scope List<int32>();
		for (int32 f < (int32)model.Edit.faces.Count)
			all.Add(f);
		MeshUV.SmartUnwrap(model.Edit, all);
		CommitModel(model);
		mModelEditing = false;
		mUVPoints = false;
		PickUV(model.Edit, all, 0, -1, false, false);
		let pieceCorners = mUVPicked.Count;
		mUVPoints = true;
		PickUV(model.Edit, all, 0, 0, false, false);
		let pointCorners = mUVPicked.Count;
		mUVPicked.Clear();
		mModelEditing = true;
		expect(pieceCorners == 4 && pointCorners == 1, scope $"the UV Editor picks a piece ({pieceCorners} corners) or a point ({pointCorners})");

		// Texture painting: a new picture, a dab on the top, written to its file.
		mModelPaintSize = 64;
		NewModelPaintTexture(model, model.Edit);
		let renderer = model.GameObject.GetComponent<MeshRenderer>();
		let paintPath = scope String(renderer.texture);
		let painted = ModelPaintReady(model);
		let changed = painted ? mModelPaint.Dab(model.Edit, .(0, 2, 0), 0.4f, .(1, 0, 0, 1), 1, 1) : 0;
		EndTexturePaintStroke();
		let reread = scope TexturePaint();
		let saved = !paintPath.IsEmpty && reread.Load(paintPath);
		var red = 0;
		if (saved)
		{
			for (int32 y < reread.height)
			{
				for (int32 x < reread.width)
				{
					let c = reread.GetPixel(x, y);
					if (c.r > 0.9f && c.g < 0.1f)
						red++;
				}
			}
		}
		expect(painted && changed > 0 && saved && red > 0 && renderer.ActiveTexture.idx != Gfx.WhiteTexture.idx, scope $"painting the texture shows and saves the stroke ({changed} pixels, {red} red in the file)");
		System.IO.File.Delete(Assets.ResolvePath(paintPath, .. scope .())).IgnoreError();
		renderer.texture.Clear();

		// Levels of detail from a round model.
		let sphere = MeshShapes.Create(.Sphere, .() { size = .(2, 2, 2), sides = 24, steps = 12, smooth = true });
		model.Set(sphere);
		delete sphere;
		mModelLodLevels = 3;
		MakeModelLods(model);
		let group = model.GameObject.GetComponent<LODGroup>();
		int32 levels = 0;
		var smaller = true;
		var previous = MeshOps.TriangleCount(model.Edit);
		for (let child in model.Transform.Children)
		{
			let level = LODGroup.LevelInName(child.GameObject.Name);
			let childModel = child.GameObject.GetComponent<ModelMesh>();
			if (level <= 0 || !childModel.IsValid)
				continue;
			levels++;
			let count = MeshOps.TriangleCount(childModel.Edit);
			smaller &= count < previous && childModel.Edit.IsClosed();
			previous = count;
		}
		expect(group != null && levels == 2 && smaller && group.LevelCount == 3 && model.GameObject.GetComponent<MeshRenderer>().LodLevel == 0, scope $"Make Levels of Detail adds 2 simpler closed levels and a LOD Group ({levels} levels)");
		MakeModelLods(model);
		int32 again = 0;
		for (let child in model.Transform.Children)
		{
			if (LODGroup.LevelInName(child.GameObject.Name) > 0 && !child.GameObject.IsDestroyed)
				again++;
		}
		expect(again == 2, scope $"making them again replaces the old ones ({again})");
		Reset();
	}
}
