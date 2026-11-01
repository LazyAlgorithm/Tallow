using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Every modelling tool by name, with its shortcut (docs/modeling.md). The table drives the keys in edit mode, the
/// right-click menu, the Space search, the Model window's hints and the F1 sheet, so they all agree.
extension EditorApp
{
	enum ModelCommand
	{
		Grab,
		Rotate,
		Scale,
		Extrude,
		ExtrudeEach,
		Inset,
		Bevel,
		LoopCut,
		Knife,
		Slide,
		VertexSlide,
		Subdivide,
		SmoothSubdivide,
		Poke,
		Solidify,
		Duplicate,
		MakeFace,
		Connect,
		Bridge,
		Merge,
		Collapse,
		Dissolve,
		SplitEdges,
		SmoothVertices,
		Weld,
		Triangulate,
		TrianglesToQuads,
		Flip,
		Detach,
		Separate,
		Delete,
		SmoothShading,
		FlatShading,
		MarkSeam,
		ClearSeam,
		MarkHard,
		ClearHard,
		SelectAll,
		SelectNone,
		Invert,
		Grow,
		Shrink,
		Linked,
		SelectLoop,
		SelectRing,
		SelectSharp,
		SelectOpen,
		SelectSameSlot,
		Hide,
		HideOthers,
		Reveal,
		FixNormals,
		MirrorX,
		MirrorY,
		MirrorZ,
		WeldAll,
		CleanUp,
		OriginToCentre,
		OriginToBase,
		OriginHere,
		OriginToGeometry,
		OriginToVolumeMass,
		OriginToSurfaceMass,
		OriginToObject,
		GeometryToOrigin,
		AddShape,
		Frame,
		Proportional,
		SymmetryX,
		SymmetryY,
		SymmetryZ,
		XRay,
		Help
	}

	/// Which modes a command is offered in: vertices, edges, faces.
	const int32 InVerts = 1;
	const int32 InEdges = 2;
	const int32 InFaces = 4;
	const int32 InAll = 7;

	static (ModelCommand command, StringView name, StringView keys, int32 modes, StringView group)[?] sModelCommands = .(
		(.Grab, "Grab", "G", InAll, "Transform"),
		(.Rotate, "Rotate", "R", InAll, "Transform"),
		(.Scale, "Scale", "S", InAll, "Transform"),
		(.Extrude, "Extrude", "E", InAll, "Build"),
		(.ExtrudeEach, "Extrude Each Face", "Alt+E", InFaces, "Build"),
		(.Inset, "Inset", "I", InFaces, "Build"),
		(.Bevel, "Bevel", "Ctrl+B", InAll, "Build"),
		(.LoopCut, "Loop Cut and Slide", "Ctrl+R", InAll, "Build"),
		(.Knife, "Knife", "K", InAll, "Build"),
		(.Slide, "Slide Edges", "G G", InEdges | InFaces, "Transform"),
		(.VertexSlide, "Slide Vertices", "Shift+V", InVerts, "Transform"),
		(.Subdivide, "Subdivide", "", InFaces, "Build"),
		(.SmoothSubdivide, "Smooth Subdivide", "", InFaces, "Build"),
		(.Poke, "Poke (fan from the middle)", "", InFaces, "Build"),
		(.Solidify, "Solidify (give thickness)", "", InFaces, "Build"),
		(.Duplicate, "Duplicate and Move", "Shift+D", InFaces, "Build"),
		(.MakeFace, "Make Face / Fill", "F", InVerts | InEdges, "Build"),
		(.Connect, "Connect Vertices", "J", InVerts, "Build"),
		(.Bridge, "Bridge Edges", "", InEdges, "Build"),
		(.Merge, "Merge at Centre", "M", InVerts, "Change"),
		(.Collapse, "Collapse", "M", InEdges | InFaces, "Change"),
		(.Dissolve, "Dissolve Edges", "", InEdges, "Change"),
		(.SplitEdges, "Split Edges in Middle", "", InEdges, "Change"),
		(.SmoothVertices, "Smooth Vertices", "", InAll, "Change"),
		(.Weld, "Weld by Distance", "", InVerts, "Change"),
		(.Triangulate, "Triangulate", "Ctrl+T", InFaces, "Change"),
		(.TrianglesToQuads, "Triangles to Quads", "Alt+J", InFaces, "Change"),
		(.Flip, "Flip Faces", "Alt+N", InFaces, "Change"),
		(.Detach, "Detach", "", InFaces, "Change"),
		(.Separate, "Separate into Object", "P", InFaces, "Change"),
		(.Delete, "Delete", "X", InAll, "Change"),
		(.SmoothShading, "Smooth Shading", "", InFaces, "Shading and marks"),
		(.FlatShading, "Flat Shading", "", InFaces, "Shading and marks"),
		(.MarkSeam, "Mark Seam", "", InEdges, "Shading and marks"),
		(.ClearSeam, "Clear Seam", "", InEdges, "Shading and marks"),
		(.MarkHard, "Mark Hard Edge", "", InEdges, "Shading and marks"),
		(.ClearHard, "Clear Hard Edge", "", InEdges, "Shading and marks"),
		(.SelectAll, "Select All", "A", InAll, "Select"),
		(.SelectNone, "Select None", "Alt+A", InAll, "Select"),
		(.Invert, "Invert Selection", "Ctrl+I", InAll, "Select"),
		(.Grow, "Grow Selection", "Ctrl+=", InAll, "Select"),
		(.Shrink, "Shrink Selection", "Ctrl+-", InAll, "Select"),
		(.Linked, "Select Linked", "L", InAll, "Select"),
		(.SelectLoop, "Select Edge Loop", "Alt+click", InEdges, "Select"),
		(.SelectRing, "Select Edge Ring", "", InEdges, "Select"),
		(.SelectSharp, "Select Sharp Edges", "", InAll, "Select"),
		(.SelectOpen, "Select Open Edges", "", InAll, "Select"),
		(.SelectSameSlot, "Select Same Material", "", InFaces, "Select"),
		(.Hide, "Hide", "H", InAll, "Show"),
		(.HideOthers, "Hide Unselected", "Shift+H", InAll, "Show"),
		(.Reveal, "Reveal Hidden", "Alt+H", InAll, "Show"),
		(.FixNormals, "Fix Normals", "Ctrl+N", InAll, "Model"),
		(.MirrorX, "Mirror X", "", InAll, "Model"),
		(.MirrorY, "Mirror Y", "", InAll, "Model"),
		(.MirrorZ, "Mirror Z", "", InAll, "Model"),
		(.WeldAll, "Weld All", "", InAll, "Model"),
		(.CleanUp, "Clean Up", "", InAll, "Model"),
		(.OriginToGeometry, "Origin to Geometry", "", InAll, "Model"),
		(.OriginToCentre, "Origin to Bounds Centre", "", InAll, "Model"),
		(.OriginToVolumeMass, "Origin to Centre of Mass (Volume)", "", InAll, "Model"),
		(.OriginToSurfaceMass, "Origin to Centre of Mass (Surface)", "", InAll, "Model"),
		(.OriginToBase, "Origin to Base", "", InAll, "Model"),
		(.OriginHere, "Origin to Selection", "", InAll, "Model"),
		(.OriginToObject, "Origin to Object", "", InAll, "Model"),
		(.GeometryToOrigin, "Geometry to Origin", "", InAll, "Model"),
		(.AddShape, "Add Shape...", "Shift+A", InAll, "Model"),
		(.Frame, "Frame Selection", "Home", InAll, "Options"),
		(.Proportional, "Proportional Editing", "O", InAll, "Options"),
		(.SymmetryX, "Mirror Edits X", "", InAll, "Options"),
		(.SymmetryY, "Mirror Edits Y", "", InAll, "Options"),
		(.SymmetryZ, "Mirror Edits Z", "", InAll, "Options"),
		(.XRay, "Pick Hidden Too (x-ray)", "", InAll, "Options"),
		(.Help, "Shortcut Sheet", "F1", InAll, "Options"));

	float mModelSolidify = 0.1f;
	bool mModelShowHelp;
	String mModelSearch = new .() ~ delete _;
	bool mModelSearchFocus;
	// A right-click that does not turn the camera opens the tool menu.
	bool mModelMenuArmed;
	float mModelMenuTravel;
	double mModelMenuTime;

	bool ModelCommandApplies(int32 modes) => (modes & (1 << (int32)mModelMode)) != 0;

	bool ModelCommandChecked(ModelCommand command)
	{
		switch (command)
		{
		case .Proportional: return mModelProportional;
		case .SymmetryX: return mModelSymmetry[0];
		case .SymmetryY: return mModelSymmetry[1];
		case .SymmetryZ: return mModelSymmetry[2];
		case .XRay: return mModelXRay;
		case .Help: return mModelShowHelp;
		default: return false;
		}
	}

	void RunModelCommand(ModelMesh model, EditMesh mesh, ModelCommand command)
	{
		switch (command)
		{
		case .Grab: StartModelTool(model, mesh, .Grab);
		case .Rotate: StartModelTool(model, mesh, .Rotate);
		case .Scale: StartModelTool(model, mesh, .Scale);
		case .Extrude: StartModelTool(model, mesh, .Extrude);
		case .ExtrudeEach: StartModelTool(model, mesh, .Extrude, true);
		case .Inset: StartModelTool(model, mesh, .Inset);
		case .Bevel: StartModelTool(model, mesh, .Bevel);
		case .LoopCut: StartModelTool(model, mesh, .LoopCut);
		case .Knife: StartModelTool(model, mesh, .Knife);
		case .Slide: StartModelTool(model, mesh, mModelMode == .Vertex ? .VertexSlide : .Slide);
		case .VertexSlide: StartModelTool(model, mesh, .VertexSlide);
		case .Subdivide: ModelFaceAction(model, mesh, .Subdivide);
		case .SmoothSubdivide: ModelFaceAction(model, mesh, .SmoothSubdivide);
		case .Poke: ModelFaceAction(model, mesh, .Poke);
		case .Solidify: ModelFaceAction(model, mesh, .Solidify);
		case .Duplicate:
			if (mModelMode != .Face || mModelFaces.IsEmpty)
				return;
			ModelFaceAction(model, mesh, .Duplicate);
			StartModelTool(model, mesh, .Grab);
		case .MakeFace:
			if (mModelMode == .Edge)
				ModelEdgeAction(model, mesh, .Fill);
			else if (mModelMode == .Vertex)
				ModelVertexAction(model, mesh, .MakeFace);
		case .Connect: ModelVertexAction(model, mesh, .Connect);
		case .Bridge: ModelEdgeAction(model, mesh, .Bridge);
		case .Merge: ModelVertexAction(model, mesh, .Merge);
		case .Collapse:
			let edges = scope List<uint64>();
			if (mModelMode == .Edge)
			{
				for (let e in mModelEdges)
					edges.Add(e);
			}
			else
			{
				for (let f in mModelFaces)
				{
					let face = mesh.faces[f];
					for (int i < face.Count)
						edges.Add(EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]));
				}
			}
			if (edges.IsEmpty)
				return;
			MeshOps.CollapseEdges(mesh, edges);
			ClearModelSelection();
			CommitModel(model);
		case .Dissolve: ModelEdgeAction(model, mesh, .Dissolve);
		case .SplitEdges: ModelEdgeAction(model, mesh, .Split);
		case .SmoothVertices:
			let verts = scope HashSet<int32>();
			ModelSelectedVerts(mesh, verts);
			let list = scope List<int32>();
			for (let v in verts)
				list.Add(v);
			if (list.IsEmpty)
				return;
			MeshOps.SmoothVertices(mesh, list, 0.5f, 1);
			CommitModel(model);
		case .Weld: ModelVertexAction(model, mesh, .Weld);
		case .Triangulate: ModelFaceAction(model, mesh, .Triangulate);
		case .TrianglesToQuads: ModelFaceAction(model, mesh, .TrianglesToQuads);
		case .Flip: ModelFaceAction(model, mesh, .Flip);
		case .Detach: ModelFaceAction(model, mesh, .Detach);
		case .Separate: ModelFaceAction(model, mesh, .NewObject);
		case .Delete: DeleteModelSelection(model, mesh);
		case .SmoothShading: ModelFaceAction(model, mesh, .Smooth);
		case .FlatShading: ModelFaceAction(model, mesh, .Flat);
		case .MarkSeam: ModelEdgeAction(model, mesh, .Seam);
		case .ClearSeam: ModelEdgeAction(model, mesh, .ClearSeam);
		case .MarkHard: ModelEdgeAction(model, mesh, .Hard);
		case .ClearHard: ModelEdgeAction(model, mesh, .Soft);
		case .SelectAll: SelectAllModel(mesh, false);
		case .SelectNone: ClearModelSelection();
		case .Invert: InvertModelSelection(mesh);
		case .Grow: GrowModelSelection(mesh, true);
		case .Shrink: GrowModelSelection(mesh, false);
		case .Linked: SelectModelLinked(mesh);
		case .SelectLoop: ModelEdgeAction(model, mesh, .SelectLoop);
		case .SelectRing: ModelEdgeAction(model, mesh, .SelectRing);
		case .SelectSharp: SelectModelSharp(mesh);
		case .SelectOpen:
			let open = scope List<uint64>();
			MeshOps.OpenEdges(mesh, open);
			SetModelMode(.Edge, mesh);
			mModelEdges.Clear();
			for (let e in open)
				mModelEdges.Add(e);
		case .SelectSameSlot: SelectModelSameSlot(mesh);
		case .Hide: HideModelFaces(model, mesh, false);
		case .HideOthers: HideModelFaces(model, mesh, true);
		case .Reveal: RevealModelFaces(model, mesh);
		case .FixNormals:
			let turned = MeshOps.ConformNormals(mesh);
			Log.Info(scope $"Turned {turned} faces.");
			CommitModel(model);
		case .MirrorX,.MirrorY,.MirrorZ:
			MeshOps.Mirror(mesh, command == .MirrorX ? 0 : (command == .MirrorY ? 1 : 2));
			ClearModelSelection();
			CommitModel(model);
		case .WeldAll:
			let welded = mesh.Weld(mModelWeld);
			mesh.Clean();
			ClearModelSelection();
			Log.Info(scope $"Welded {welded} vertices.");
			CommitModel(model);
		case .CleanUp:
			mesh.Clean();
			MeshCsg.MendCracks(mesh);
			MeshCsg.RemoveStraightCorners(mesh);
			ClearModelSelection();
			CommitModel(model);
		case .OriginToCentre: SetModelOrigin(model, mesh.Bounds.Center);
		case .OriginToGeometry: SetModelOrigin(model, MeshOps.GeometryCentre(mesh));
		case .OriginToVolumeMass: SetModelOrigin(model, MeshOps.VolumeCentre(mesh));
		case .OriginToSurfaceMass: SetModelOrigin(model, MeshOps.SurfaceCentre(mesh));
		case .OriginToObject:
			let other = mModelOriginObject != 0 ? mScene.FindById(mModelOriginObject) : null;
			if (other == null || other == model.GameObject)
			{
				Log.Warning("Pick the object to move the origin to (Origin in the Model window).");
				return;
			}
			SetModelOrigin(model, model.Transform.InverseTransformPoint(other.Transform.Position));
		case .GeometryToOrigin:
			// The model moves to stand round its origin; the object stays where it is.
			MeshOps.MoveOrigin(mesh, mesh.Bounds.Center);
			CommitModel(model);
		case .OriginToBase:
			let bounds = mesh.Bounds;
			SetModelOrigin(model, .(bounds.Center.x, bounds.min.y, bounds.Center.z));
		case .OriginHere:
			let verts = scope HashSet<int32>();
			ModelSelectedVerts(mesh, verts);
			if (verts.IsEmpty)
				return;
			var center = Vector3.Zero;
			for (let v in verts)
				center = center + mesh.positions[v];
			SetModelOrigin(model, center / verts.Count);
		case .AddShape: ImGui.OpenPopup("##modeladd");
		case .Frame: FrameModelSelection(model, mesh);
		case .Proportional: mModelProportional = !mModelProportional;
		case .SymmetryX: mModelSymmetry[0] = !mModelSymmetry[0];
		case .SymmetryY: mModelSymmetry[1] = !mModelSymmetry[1];
		case .SymmetryZ: mModelSymmetry[2] = !mModelSymmetry[2];
		case .XRay: mModelXRay = !mModelXRay;
		case .Help: mModelShowHelp = !mModelShowHelp;
		}
	}

	/// The keys of edit mode, over the Scene view, when no tool is running (changed in Preferences: ModelShortcuts).
	void HandleModelKeys(ModelMesh model, EditMesh mesh)
	{
		if (ImGui.IsKeyPressed(ImGui.Key.Escape))
		{
			if (ModelHasSelection)
				ClearModelSelection();
			else
				mModelEditing = false;
			return;
		}
		let action = PressedModelShortcut();
		if (action < 0)
			return;
		if (action == ShortcutVertexMode)
			SetModelMode(.Vertex, mesh);
		else if (action == ShortcutEdgeMode)
			SetModelMode(.Edge, mesh);
		else if (action == ShortcutFaceMode)
			SetModelMode(.Face, mesh);
		else if (action == ShortcutSearch)
		{
			mModelSearch.Clear();
			mModelSearchFocus = true;
			ImGui.OpenPopup("##modelsearch");
		}
		else if (action == ShortcutMenu)
			ImGui.OpenPopup("##modelmenu");
		else if (action == ShortcutShowOnly)
			SetModelShowOnly(!mModelShowOnly);
		else if (action >= ShortcutCommands)
		{
			var command = (ModelCommand)(action - ShortcutCommands);
			// One key for both: merge picked vertices, collapse picked edges or faces.
			if (command == .Merge && mModelMode != .Vertex)
				command = .Collapse;
			else if (command == .Collapse && mModelMode == .Vertex)
				command = .Merge;
			RunModelCommand(model, mesh, command);
		}
	}

	/// Points the camera at the selection (or the whole model).
	void FrameModelSelection(ModelMesh model, EditMesh mesh)
	{
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		if (verts.IsEmpty)
		{
			for (int32 v < (int32)mesh.positions.Count)
				verts.Add(v);
		}
		if (verts.IsEmpty)
			return;
		let world = model.Transform.LocalToWorld;
		var bounds = Bounds.Empty;
		for (let v in verts)
			bounds.Encapsulate(world.TransformPoint(mesh.positions[v]));
		let radius = Math.Max(bounds.Extents.Length, 0.25f);
		if (mSceneCamera.orthographic)
		{
			// An orthographic view (a Model View, or the Scene view's): framed by its size, seen from far back.
			mCamPosition = bounds.Center - ModelViewForward * OrthoBack;
			mSceneCamera.orthographicSize = radius * 1.25f;
			if (mModelViewActive < 0)
				mSceneOrthoSize = mSceneCamera.orthographicSize;
			return;
		}
		mCamPosition = bounds.Center - ModelViewForward * (radius * 2.8f + 0.5f);
	}

	// ------------------------------------------------------------------ menus

	/// Watches the right mouse button: a click that does not turn the camera opens the tool menu.
	void WatchModelMenuClick()
	{
		if (mSceneHovered && ImGui.IsMouseClicked(1))
		{
			mModelMenuArmed = !ModelToolActive;
			mModelMenuTravel = 0;
			mModelMenuTime = ImGui.GetTime();
		}
		if (ImGui.IsMouseDown(1))
		{
			let delta = Input.MouseDelta;
			mModelMenuTravel += Math.Abs(delta.x) + Math.Abs(delta.y);
		}
		if (mModelMenuArmed && ImGui.IsMouseReleased(1))
		{
			mModelMenuArmed = false;
			if (mModelMenuTravel < 6 && ImGui.GetTime() - mModelMenuTime < 0.4)
				ImGui.OpenPopup("##modelmenu");
		}
	}

	/// The right-click menu, the Space search and the Add Shape menu.
	void DrawModelPopups(ModelMesh model, EditMesh mesh)
	{
		ModelCommand? run = null;
		void Items(StringView group)
		{
			for (let entry in sModelCommands)
			{
				if (entry.group != group || !ModelCommandApplies(entry.modes))
					continue;
				if (ImGui.MenuItem(scope String(entry.name).CStr(), ModelKeys(entry.command).IsEmpty ? null : scope:: String(ModelKeys(entry.command)).CStr(), ModelCommandChecked(entry.command)))
					run = entry.command;
			}
		}
		if (ImGui.BeginPopup("##modelmenu"))
		{
			let modeName = mModelMode == .Vertex ? "Vertices" : (mModelMode == .Edge ? "Edges" : "Faces");
			ImGui.TextDisabled(scope $"{modeName}: {ModelSelectionCount} selected" .CStr());
			ImGui.Separator();
			Items("Transform");
			ImGui.Separator();
			Items("Build");
			ImGui.Separator();
			Items("Change");
			ImGui.Separator();
			for (let group in StringView[?]("Shading and marks", "Select", "Show", "Model", "Options"))
			{
				bool any = false;
				for (let entry in sModelCommands)
					any |= entry.group == group && ModelCommandApplies(entry.modes);
				if (any && ImGui.BeginMenu(scope String(group).CStr()))
				{
					Items(group);
					ImGui.EndMenu();
				}
			}
			ImGui.EndPopup();
		}
		if (ImGui.BeginPopup("##modelsearch"))
		{
			ImGui.SetNextItemWidth(300);
			if (mModelSearchFocus)
			{
				ImGui.SetKeyboardFocusHere();
				mModelSearchFocus = false;
			}
			ImGui.InputText("##modelfind", mModelSearch, 0, "Find a model tool...");
			let pickFirst = ImGui.IsKeyPressed(ImGui.Key.Enter);
			ImGui.BeginChild("##modelfound", .(300, 320));
			bool first = true;
			for (let entry in sModelCommands)
			{
				if (!ModelCommandApplies(entry.modes) || (!mModelSearch.IsEmpty && !entry.name.Contains(mModelSearch, true)))
					continue;
				if (ImGui.MenuItem(scope String(entry.name).CStr(), ModelKeys(entry.command).IsEmpty ? null : scope:: String(ModelKeys(entry.command)).CStr(), ModelCommandChecked(entry.command)) || (pickFirst && first))
				{
					run = entry.command;
					ImGui.CloseCurrentPopup();
				}
				first = false;
			}
			ImGui.EndChild();
			ImGui.EndPopup();
		}
		DrawModelAddPopup(model, mesh);
		if (run.HasValue)
			RunModelCommand(model, mesh, run.Value);
	}

	/// Shift+A: a shape added into the model being edited (where the selection is), or as a new object.
	void DrawModelAddPopup(ModelMesh model, EditMesh mesh)
	{
		if (!ImGui.BeginPopup("##modeladd"))
			return;
		ImGui.TextDisabled(model != null ? "Add into this model" : "Add a shape");
		ImGui.Separator();
		int32 chosen = -1;
		for (int32 k < (int32)MeshShapes.Names.Count)
		{
			if (ImGui.MenuItem(scope String(MeshShapes.Names[k]).CStr()))
				chosen = k;
		}
		if (model == null)
		{
			ImGui.Separator();
			if (ImGui.MenuItem("Draw a Shape in the Scene..."))
			{
				mShowModel = true;
				mModelDraw = .Waiting;
			}
		}
		ImGui.EndPopup();
		if (chosen < 0)
			return;
		mModelDrawKind = chosen;
		if (model == null)
		{
			AddShapeInView((MeshShapes.Kind)chosen);
			return;
		}
		// Into the model, standing on the middle of the selection (or on the model's origin).
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		var at = Vector3.Zero;
		for (let v in verts)
			at = at + mesh.positions[v];
		if (!verts.IsEmpty)
			at = at / verts.Count;
		let shape = MeshShapes.Create((MeshShapes.Kind)chosen, mModelShape);
		defer delete shape;
		let first = (int32)mesh.faces.Count;
		mesh.Append(shape, Matrix4.Translate(at));
		mModelMode = .Face;
		ClearModelSelection();
		for (int32 f = first; f < (int32)mesh.faces.Count; f++)
			mModelFaces.Add(f);
		CommitModel(model);
	}

	/// A shape of the Model window's size where the Scene view is looking, as a new object.
	void AddShapeInView(MeshShapes.Kind kind)
	{
		if (mPlay != .Edit)
			return;
		let shape = MeshShapes.Create(kind, mModelShape);
		defer delete shape;
		let made = CreateObject(MeshShapes.Names[(int)kind]);
		let position = made.Transform.Position;
		mScene.Destroy(made);
		CreateModelObject(MeshShapes.Names[(int)kind], shape, position);
	}

	// ------------------------------------------------------------------ the Scene view's notes

	static void ShadowText(ImGui.Vec2 at, Color color, StringView text)
	{
		let s = scope String(text);
		ImGui.DrawText(.(at.x + 1, at.y + 1), .(0, 0, 0, 0.75f), s.CStr());
		ImGui.DrawText(at, color, s.CStr());
	}

	/// Top left of the Scene view: the mode, what is selected, the tool running and the options on.
	void DrawModelHud(EditMesh mesh)
	{
		let origin = mSceneOrigin;
		var y = origin.y + 30;
		let x = origin.x + 10;
		let modeName = mModelMode == .Vertex ? "Vertices" : (mModelMode == .Edge ? "Edges" : "Faces");
		let line = scope String();
		line.AppendF("EDIT MODE  {}  {} selected   ({} faces, {} vertices)", modeName, ModelSelectionCount, mesh.faces.Count, mesh.positions.Count);
		if (mModelAnyHidden)
			line.Append("  some hidden (Alt+H)");
		let chipWidth = ImGui.CalcTextSize("EDIT MODE").x + 10;
		ImGui.DrawRectFilled(.(x - 4, y - 2), .(x - 4 + chipWidth, y + 16), .(ModelSelectColor.r, ModelSelectColor.g, ModelSelectColor.b, 0.85f), 3);
		ShadowText(.(x, y), .(1, 1, 1, 0.92f), line);
		y += 20;
		if (ModelToolActive)
		{
			let status = scope String();
			ModelToolStatus(status);
			ShadowText(.(x, y), .(1, 0.86f, 0.4f, 1), status);
			y += 18;
			let help = mModelTool == .LoopCut || mModelTool == .Knife ? "Esc or right-click: stop" : "Click or Enter: keep   Esc or right-click: cancel   X Y Z: axis (Shift: plane)   type a number";
			ShadowText(.(x, y), .(1, 1, 1, 0.6f), help);
			y += 18;
		}
		else
		{
			ShadowText(.(x, y), .(1, 1, 1, 0.55f), scope String()..AppendF("Right-click: tools   {}: find a tool   {}: shortcuts   {}: leave   {}: show others", ModelShortcutText(ShortcutSearch), ModelKeys(.Help), ModelShortcutText(ShortcutEditMode), ModelShortcutText(ShortcutShowOnly)));
			y += 18;
		}
		let options = scope String();
		if (mModelProportional)
			options.AppendF("Proportional {:0.##} m   ", mModelPropRadius);
		if (mModelSymmetry[0] || mModelSymmetry[1] || mModelSymmetry[2])
			options.AppendF("Mirror edits {}{}{}   ", mModelSymmetry[0] ? "X" : "", mModelSymmetry[1] ? "Y" : "", mModelSymmetry[2] ? "Z" : "");
		if (mModelXRay)
			options.Append("X-ray");
		if (!options.IsEmpty)
			ShadowText(.(x, y), .(0.45f, 0.82f, 1, 0.9f), options);
	}

	/// F1: every shortcut, in a window of its own (it can be moved off the Scene view).
	void DrawModelHelp()
	{
		if (!mModelShowHelp || !mModelEditing)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + 360, viewport.workPos.y + 120), 4);
		ImGui.SetNextWindowSize(.(560, 560), 4);
		if (ImGui.Begin("Modelling Shortcuts", &mModelShowHelp))
		{
			void Group(StringView title, Span<(StringView keys, StringView name)> rows)
			{
				ImGui.SeparatorText(scope String(title).CStr());
				if (!ImGui.BeginTable(scope String(title).CStr(), 2))
					return;
				ImGui.TableSetupColumn("keys", 16, 120);
				ImGui.TableSetupColumn("what");
				for (let row in rows)
				{
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.TextColored(ModelSelectColor, scope String(row.keys).CStr());
					ImGui.TableNextColumn();
					ImGui.Text(row.name);
				}
				ImGui.EndTable();
			}
			let editKeys = ModelShortcutText(ShortcutEditMode);
			let searchKeys = ModelShortcutText(ShortcutSearch);
			let showOnlyKeys = ModelShortcutText(ShortcutShowOnly);
			let modeKeys = scope String()..AppendF("{}  {}  {}", ModelShortcutText(ShortcutVertexMode), ModelShortcutText(ShortcutEdgeMode), ModelShortcutText(ShortcutFaceMode));
			// The keys that can be changed are read at run time; a list, as the compiler cannot mix them into a constant array.
			let picking = scope List<(StringView keys, StringView name)>();
			picking.Add((editKeys, "Leave edit mode"));
			picking.Add((modeKeys, "Vertices, edges, faces"));
			picking.Add(("Click, Shift+click", "Pick, add or take away"));
			picking.Add(("Drag, Ctrl+drag", "Box adds, box takes away"));
			picking.Add(("Alt+click", "Loop (faces: the strip across the edge)"));
			picking.Add(("Ctrl+click", "Shortest path from the last pick"));
			picking.Add(("Right-click", "Every tool, for what is picked"));
			picking.Add((searchKeys, "Find a tool by name"));
			picking.Add((showOnlyKeys, "Show only this model, or everything"));
			picking.Add(("Ctrl+Z, Ctrl+Y", "Undo, redo"));
			Group("Picking", picking);
			ImGui.TextDisabled("Change these in Edit > Preferences > Modelling.");
			(StringView keys, StringView name)[?] during = .(
				("Click, Enter", "Keep"),
				("Esc, right-click", "Cancel"),
				("X  Y  Z", "Along an axis (again: the model's own)"),
				("Shift+X  Y  Z", "Across the plane of the other two"),
				("0-9  .  -", "Type the amount exactly"),
				("Ctrl", "Snap to the toolbar's steps"),
				("O, wheel", "Proportional editing, its radius"));
			Group("While a tool follows the pointer", during);
			for (let group in StringView[?]("Transform", "Build", "Change", "Select", "Show", "Model", "Options"))
			{
				let rows = scope List<(StringView keys, StringView name)>();
				for (let entry in sModelCommands)
				{
					let keys = ModelKeys(entry.command);
					if (entry.group == group && !keys.IsEmpty && keys != "Alt+click")
						rows.Add((keys, entry.name));
				}
				if (!rows.IsEmpty)
					Group(group, rows);
			}
		}
		ImGui.End();
	}
}
