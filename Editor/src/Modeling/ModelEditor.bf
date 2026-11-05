using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The modeller (docs/modeling.md): shapes drawn straight into the Scene view, and an edit mode (Tab on a selected
/// model) where vertices, edges and faces are picked and moved with the gizmo and changed with the Model window's
/// tools. Edits go into the Model Mesh component's text, so the scene's undo covers them.
extension EditorApp
{
	enum ModelSelectMode
	{
		Vertex,
		Edge,
		Face
	}

	enum ModelDrawState
	{
		Off,
		Waiting,
		Base,
		Height
	}

	bool mShowModel;
	bool mDockModel = true;
	bool mModelFocus;
	bool mModelEditing;
	uint32 mModelObject;
	ModelSelectMode mModelMode = .Face;
	HashSet<int32> mModelVerts = new .() ~ delete _;
	HashSet<uint64> mModelEdges = new .() ~ delete _;
	HashSet<int32> mModelFaces = new .() ~ delete _;
	/// Hidden elements (behind the model) can be picked and boxed too.
	bool mModelXRay;
	/// Edit mode shows only the edited model (others' renderers hidden), as rigging does. On unless turned off;
	/// remembered between sessions.
	bool mModelShowOnly = true;
	bool mModelShowOnlyLoaded;

	// Moving elements with the gizmo.
	bool mModelDragging;
	Matrix4 mModelDragStart;
	Dictionary<int32, Vector3> mModelDragFrom = new .() ~ delete _;
	Vector3 mModelPivot;

	// Box selection.
	bool mModelBoxing;
	ImGui.Vec2 mModelBoxFrom;

	// Tool settings.
	float mModelExtrude = 0.5f;
	float mModelInset = 0.1f;
	float mModelBevel = 0.1f;
	int32 mModelCuts = 1;
	int32 mModelArrayCount = 3;
	Vector3 mModelArrayOffset = .(2, 0, 0);
	float mModelWeld = 0.01f;
	int32 mModelSlot = 0;
	Color mModelColor = .White;
	float mModelSmartAngle = 66;
	int32 mModelBooleanOp = 1;
	uint32 mModelBooleanOther;
	/// The object Origin to Object moves the origin to.
	uint32 mModelOriginObject;
	bool mModelBooleanKeep;
	String mModelExportPath = new .() ~ delete _;

	// Painting vertex colours.
	bool mModelPainting;
	float mModelPaintRadius = 0.5f;
	float mModelPaintStrength = 1;
	bool mModelPaintStroke;
	bool mModelPaintHit;
	Vector3 mModelPaintPoint;
	Vector3 mModelPaintNormal;

	// Drawing new shapes.
	ModelDrawState mModelDraw = .Off;
	int32 mModelDrawKind;
	MeshShapes.Settings mModelShape = .();
	Vector3 mModelDrawFrom;
	Vector3 mModelDrawTo;
	float mModelDrawHeight = 1;
	bool mModelDrawHit;

	/// The model being edited, if edit mode is on and it still exists.
	ModelMesh EditedModel
	{
		get
		{
			if (!mModelEditing)
				return null;
			let selected = Selected;
			if (selected == null || selected.Id != mModelObject)
			{
				mModelEditing = false;
				return null;
			}
			let model = selected.GetComponent<ModelMesh>();
			if (model == null)
				mModelEditing = false;
			return model;
		}
	}

	static void ModelShowOnlyFile(String file)
	{
		RecentProjects.GetConfigFolder(file);
		file.Append("model_show_only.txt");
	}

	void LoadModelShowOnly()
	{
		if (mModelShowOnlyLoaded)
			return;
		mModelShowOnlyLoaded = true;
		// On unless it was turned off.
		let saved = scope String();
		mModelShowOnly = !(File.ReadAllText(ModelShowOnlyFile(.. scope .()), saved) case .Ok) || !saved.StartsWith("0");
	}

	void SetModelShowOnly(bool on)
	{
		mModelShowOnly = on;
		mModelShowOnlyLoaded = true;
		File.WriteAllText(ModelShowOnlyFile(.. scope .()), on ? "1" : "0").IgnoreError();
	}

	/// Hides every other object's mesh while a model is edited with Show Only on; shows them again after.
	void UpdateModelShowOnly()
	{
		LoadModelShowOnly();
		let hide = mModelShowOnly && mModelEditing && mPlay == .Edit && mRig == null;
		mSceneView.onlyObject = hide ? mModelObject : 0;
	}

	void ClearModelSelection()
	{
		mModelVerts.Clear();
		mModelEdges.Clear();
		mModelFaces.Clear();
	}

	void StartModelEditing(GameObject target)
	{
		if (target == null || target.GetComponent<ModelMesh>() == null)
			return;
		mModelEditing = true;
		mModelObject = target.Id;
		mModelPainting = false;
		mModelDraw = .Off;
		mModelTool = .None;
		mModelHover = -1;
		mModelActive = -1;
		ClearModelSelection();
	}

	/// Drops selected elements that no longer exist (after an undo, say).
	void ValidateModelSelection(EditMesh mesh)
	{
		mModelVerts.RemoveWhere(scope (v) => v < 0 || v >= mesh.positions.Count);
		mModelFaces.RemoveWhere(scope (f) => f < 0 || f >= mesh.faces.Count);
		if (!mModelEdges.IsEmpty)
		{
			let edges = scope HashSet<uint64>();
			let all = scope List<uint64>();
			mesh.Edges(all);
			for (let e in all)
				edges.Add(e);
			mModelEdges.RemoveWhere(scope (e) => !edges.Contains(e));
		}
	}

	/// The vertices the selection moves: those of the selected elements in the current mode.
	void ModelSelectedVerts(EditMesh mesh, HashSet<int32> into)
	{
		switch (mModelMode)
		{
		case .Vertex:
			for (let v in mModelVerts)
				into.Add(v);
		case .Edge:
			for (let e in mModelEdges)
			{
				EditMesh.EdgeEnds(e, let a, let b);
				into.Add(a);
				into.Add(b);
			}
		case .Face:
			for (let f in mModelFaces)
			{
				for (let v in mesh.faces[f].verts)
					into.Add(v);
			}
		}
	}

	bool ModelHasSelection => mModelMode == .Vertex ? !mModelVerts.IsEmpty : (mModelMode == .Edge ? !mModelEdges.IsEmpty : !mModelFaces.IsEmpty);

	/// Saves the model and records an undo step for the change.
	void CommitModel(ModelMesh model)
	{
		RefreshModel(model, model.Edit);
		MarkDirty();
	}

	// ------------------------------------------------------------------ the Scene view

	/// Runs the modeller in the Scene view. True when it owns the mouse (edit mode, painting or drawing a shape),
	/// so object picking and the object gizmo stay out.
	bool UpdateModelTools(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		RevealLeftModel();
		UpdateModelShowOnly();
		if (mPlay != .Edit)
		{
			mModelEditing = false;
			mModelDraw = .Off;
			mModelTool = .None;
			return false;
		}
		if (mModelDraw != .Off)
			return UpdateShapeDrawing(origin, size);
		let typing = (ImGui.tn_imgui_capture_flags() & 4) != 0;
		let keysFree = mSceneHovered && !typing && !mFlying;
		// Tab over the Scene view goes in and out of edit mode on a selected model.
		if (keysFree && !ModelToolActive && ModelShortcutPressed(ShortcutEditMode))
		{
			if (mModelEditing)
				mModelEditing = false;
			else if (selected != null && selected.GetComponent<ModelMesh>() != null)
				StartModelEditing(selected);
		}
		let model = EditedModel;
		if (model == null)
		{
			mModelTool = .None;
			// Shift+A (Add Shape's keys) adds a shape.
			if (keysFree && ModelShortcutPressed(ModelCommandShortcut(.AddShape)))
				ImGui.OpenPopup("##modeladd");
			DrawModelAddPopup(null, null);
			return false;
		}
		let mesh = model.Edit;
		ValidateModelSelection(mesh);
		UpdateModelShown(mesh);
		let world = model.Transform.LocalToWorld;
		let toLocal = model.Transform.WorldToLocal;
		WatchModelMenuClick();
		if (mModelMenuRequest)
		{
			mModelMenuRequest = false;
			ImGui.OpenPopup("##modelmenu");
		}
		if (keysFree && !ModelToolActive && !mModelDragging && !mModelPainting)
		{
			HandleModelKeys(model, mesh);
			if (!mModelEditing)
				return false;
		}
		DrawModelPopups(model, mesh);
		if (!mModelEditing || EditedModel == null)
			return false;
		ValidateModelSelection(mesh);
		DrawModelSelection(mesh, world, toLocal);
		DrawModelKnife(world);
		DrawModelHud(mesh);
		if (ModelToolActive)
		{
			mModelHover = -1;
			UpdateModelTool(model, mesh, world, toLocal);
			return true;
		}
		if (mModelPainting)
		{
			UpdateVertexPaint(model, mesh, world, toLocal, origin, size);
			return true;
		}

		// The gizmo moves the selected elements.
		bool overGizmo = false;
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		if (!verts.IsEmpty && !mModelBoxing)
		{
			if (!mModelDragging)
			{
				var center = Vector3.Zero;
				for (let v in verts)
					center = center + mesh.positions[v];
				mModelPivot = world.TransformPoint(center / verts.Count);
			}
			var rotation = Quaternion.Identity;
			if (mGizmoLocal)
				rotation = model.Transform.Rotation;
			var matrix = mModelDragging ? mModelCurrent : Matrix4.TRS(mModelPivot, rotation, .One);
			var view = mSceneCamera.view;
			var projection = mSceneCamera.projection;
			float[3] snap = .(mSnapMove, mSnapMove, mSnapMove);
			if (mGizmoOperation == 1)
				snap = .(mSnapRotate, mSnapRotate, mSnapRotate);
			else if (mGizmoOperation == 2)
				snap = .(mSnapScale, mSnapScale, mSnapScale);
			ImGui.tn_gizmo_begin(origin.x, origin.y, size.x, size.y, false);
			// Universal (3) is the object tool's own; elements move, turn and scale with the first three.
			let operation = Math.Min(mGizmoOperation, 2);
			let changed = ImGui.tn_gizmo_manipulate(&view.m, &projection.m, operation, mGizmoLocal, &matrix.m, SnapActive ? &snap : null);
			let gizmoUsing = ImGui.tn_gizmo_is_using();
			if (gizmoUsing && !mModelDragging)
			{
				mModelDragging = true;
				mModelDragStart = Matrix4.TRS(mModelPivot, rotation, .One);
				// Shift as a face move starts pulls the faces out first, as an extrusion.
				if (ImGui.IsKeyDown(ImGui.Key.LeftShift) && mModelMode == .Face && operation == 0)
				{
					let faces = scope List<int32>();
					for (let f in mModelFaces)
						faces.Add(f);
					MeshOps.ExtrudeFaces(mesh, faces, 0);
					verts.Clear();
					ModelSelectedVerts(mesh, verts);
				}
				else if (ImGui.IsKeyDown(ImGui.Key.LeftShift) && mModelMode == .Edge && operation == 0)
				{
					let edges = scope List<uint64>();
					for (let e in mModelEdges)
						edges.Add(e);
					let newEdges = scope List<uint64>();
					MeshOps.ExtrudeEdges(mesh, edges, .Zero, null, newEdges);
					if (!newEdges.IsEmpty)
					{
						mModelEdges.Clear();
						for (let e in newEdges)
							mModelEdges.Add(e);
					}
					verts.Clear();
					ModelSelectedVerts(mesh, verts);
				}
				BeginModelMove(mesh, world, verts);
			}
			if (mModelDragging && changed)
			{
				mModelCurrent = matrix;
				ApplyModelMove(model, mesh, matrix * mModelDragStart.Inverse);
			}
			if (mModelDragging && !gizmoUsing)
			{
				mModelDragging = false;
				CommitModel(model);
			}
			overGizmo = gizmoUsing || ImGui.tn_gizmo_is_over();
		}
		if (mModelDragging)
			return true;
		mModelCurrent = Matrix4.TRS(mModelPivot, mGizmoLocal ? model.Transform.Rotation : .Identity, .One);

		// What is under the pointer is drawn lit up; clicking picks it, dragging boxes.
		let mouse = ImGui.GetMousePos();
		mModelHover = (mSceneHovered && !mFlying && !overGizmo && !mModelBoxing) ? ModelElementAt(mesh, world, toLocal, mouse, mModelMode) : -1;
		if (mSceneHovered && !mFlying && !overGizmo && ImGui.IsMouseClicked(0))
		{
			mModelBoxing = true;
			mModelBoxFrom = mouse;
		}
		if (mModelBoxing)
		{
			let subtract = ImGui.IsKeyDown(ImGui.Key.LeftCtrl);
			let dragged = Math.Abs(mouse.x - mModelBoxFrom.x) + Math.Abs(mouse.y - mModelBoxFrom.y) > 5;
			if (dragged)
			{
				let min = ImGui.Vec2(Math.Min(mouse.x, mModelBoxFrom.x), Math.Min(mouse.y, mModelBoxFrom.y));
				let max = ImGui.Vec2(Math.Max(mouse.x, mModelBoxFrom.x), Math.Max(mouse.y, mModelBoxFrom.y));
				let tint = subtract ? Color(1, 0.35f, 0.3f, 1) : ModelSelectColor;
				ImGui.DrawRectFilled(min, max, .(tint.r, tint.g, tint.b, 0.1f));
				ImGui.DrawRect(min, max, .(tint.r, tint.g, tint.b, 0.85f), 0, 1.5f);
			}
			if (!ImGui.IsMouseDown(0))
			{
				mModelBoxing = false;
				let shift = ImGui.IsKeyDown(ImGui.Key.LeftShift);
				if (dragged)
					BoxSelectModel(mesh, world, origin, size, mModelBoxFrom, mouse, shift, subtract);
				else if (ImGui.IsKeyDown(ImGui.Key.LeftAlt))
					SelectModelLoop(mesh, world, toLocal, mouse, shift);
				else if (subtract)
					SelectModelPath(mesh, world, toLocal, mouse);
				else
					PickModelElement(mesh, world, toLocal, origin, size, mouse, shift);
			}
		}
		return true;
	}

	Matrix4 mModelCurrent;

	/// Changes what is picked, carrying the selection over (faces to their edges or vertices, and back where whole).
	void SetModelMode(ModelSelectMode mode, EditMesh mesh)
	{
		if (mode == mModelMode)
			return;
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		mModelMode = mode;
		mModelHover = -1;
		mModelActive = -1;
		ClearModelSelection();
		switch (mode)
		{
		case .Vertex:
			for (let v in verts)
				mModelVerts.Add(v);
		case .Edge:
			let all = scope List<uint64>();
			mesh.Edges(all);
			for (let e in all)
			{
				EditMesh.EdgeEnds(e, let a, let b);
				if (verts.Contains(a) && verts.Contains(b))
					mModelEdges.Add(e);
			}
		case .Face:
			for (int32 f < (int32)mesh.faces.Count)
			{
				bool all = true;
				for (let v in mesh.faces[f].verts)
					all &= verts.Contains(v);
				if (all && !mesh.faces[f].hidden)
					mModelFaces.Add(f);
			}
		}
	}

	/// Lines and fills for the model being edited: its edges (seams red, hard edges blue), the selected faces and
	/// the face under the pointer, the cut a loop cut would make, and the shape being drawn. They are pulled a little
	/// towards the camera so they sit on the faces without flickering, and are hidden behind the model; a faint
	/// copy shows through it.
	void BuildModelGizmos()
	{
		if (mModelDraw == .Base || mModelDraw == .Height)
		{
			let bounds = DrawnShapeBounds;
			Gizmos.OnTopLines.Box(bounds, .Identity, .(1, 0.75f, 0.2f, 1));
		}
		else if (mModelDraw == .Waiting && mModelDrawHit)
			Gizmos.OnTopLines.Circle(mModelDrawFrom, .Up, 0.25f, .(1, 0.75f, 0.2f, 1));
		let model = EditedModel;
		if (model == null)
			return;
		let mesh = model.Edit;
		let world = model.Transform.LocalToWorld;
		let camera = mCamPosition;
		Vector3 Lift(Vector3 local)
		{
			let p = world.TransformPoint(local);
			return p + (camera - p) * 0.002f;
		}
		let all = scope List<uint64>();
		mesh.Edges(all);
		let wire = Color(0.85f, 0.9f, 1, 0.6f);
		let hidden = Color(0.85f, 0.9f, 1, 0.1f);
		for (let e in all)
		{
			if (!ModelEdgeShown(e))
				continue;
			EditMesh.EdgeEnds(e, let a, let b);
			let pa = Lift(mesh.positions[a]);
			let pb = Lift(mesh.positions[b]);
			var color = wire;
			if (mesh.seams.Contains(e))
				color = .(1, 0.3f, 0.3f, 0.95f);
			else if (mesh.hardEdges.Contains(e))
				color = .(0.3f, 0.75f, 1, 0.95f);
			Gizmos.Lines.Line(pa, pb, color);
			Gizmos.OnTopLines.Line(pa, pb, hidden);
		}
		let corners = scope List<int32>();
		void Fill(int32 f, Color color, bool throughToo)
		{
			let face = mesh.faces[f];
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int i = 0; i + 2 < corners.Count; i += 3)
			{
				let a = Lift(mesh.positions[face.verts[corners[i]]]);
				let b = Lift(mesh.positions[face.verts[corners[i + 1]]]);
				let c = Lift(mesh.positions[face.verts[corners[i + 2]]]);
				Gizmos.Triangles.Triangle(a, b, c, color);
				if (throughToo)
					Gizmos.OnTopTriangles.Triangle(a, b, c, .(color.r, color.g, color.b, 0.07f));
			}
		}
		if (mModelMode == .Face)
		{
			for (let f in mModelFaces)
				Fill(f, .(ModelSelectColor.r, ModelSelectColor.g, ModelSelectColor.b, 0.32f), true);
			if (mModelHover >= 0 && mModelHover < mesh.faces.Count && !mModelFaces.Contains((int32)mModelHover))
				Fill((int32)mModelHover, .(ModelHoverColor.r, ModelHoverColor.g, ModelHoverColor.b, 0.2f), false);
		}
		if (mModelTool == .LoopCut && !mModelLoopSliding)
		{
			for (int i = 0; i + 1 < mModelLoopPreview.Count; i += 2)
				Gizmos.OnTopLines.Line(world.TransformPoint(mModelLoopPreview[i]), world.TransformPoint(mModelLoopPreview[i + 1]), .(1, 0.85f, 0.25f, 1));
		}
		if (mModelPainting && mModelPaintHit)
			Gizmos.OnTopLines.Circle(mModelPaintPoint, mModelPaintNormal, mModelPaintRadius, Color(mModelColor.r, mModelColor.g, mModelColor.b, 1));
	}

	// ------------------------------------------------------------------ painting vertex colours

	void UpdateVertexPaint(ModelMesh model, EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		mModelPaintHit = false;
		if (!mSceneHovered || mFlying)
		{
			EndPaintStroke(model);
			return;
		}
		let mouse = ImGui.GetMousePos();
		let ray = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);
		let localOrigin = toLocal.TransformPoint(ray.origin);
		let localEnd = toLocal.TransformPoint(ray.origin + ray.direction);
		let face = mesh.Raycast(Ray(localOrigin, (localEnd - localOrigin).Normalized), ?, let localPoint);
		if (face < 0)
		{
			EndPaintStroke(model);
			return;
		}
		mModelPaintHit = true;
		mModelPaintPoint = world.TransformPoint(localPoint);
		mModelPaintNormal = world.TransformDirection(mesh.FaceNormal(mesh.faces[face])).Normalized;
		if (!ImGui.IsMouseDown(0))
		{
			EndPaintStroke(model);
			return;
		}
		mModelPaintStroke = true;
		if (mModelPaintTexture)
		{
			UpdateTexturePaint(model, mesh, face, localPoint);
			return;
		}
		// Shift paints only the face under the pointer, flat.
		if (ImGui.IsKeyDown(ImGui.Key.LeftShift))
		{
			for (var c in ref mesh.faces[face].colors)
				c = mModelColor;
		}
		else
		{
			let strength = Math.Clamp(mModelPaintStrength * Time.UnscaledDeltaTime * 8, 0, 1);
			for (let f in mesh.faces)
			{
				for (int i < f.Count)
				{
					let distance = (world.TransformPoint(mesh.positions[f.verts[i]]) - mModelPaintPoint).Length;
					if (distance > mModelPaintRadius)
						continue;
					let falloff = 1 - distance / mModelPaintRadius;
					f.colors[i] = Color.Lerp(f.colors[i], mModelColor, mModelPaintStrength >= 1 ? Math.Min(1, falloff * 2) : strength * falloff);
				}
			}
		}
		model.Preview();
	}

	void EndPaintStroke(ModelMesh model)
	{
		if (!mModelPaintStroke)
			return;
		mModelPaintStroke = false;
		if (mModelPaintTexture)
		{
			EndTexturePaintStroke();
			return;
		}
		CommitModel(model);
	}

	// ------------------------------------------------------------------ drawing shapes

	Bounds DrawnShapeBounds
	{
		get
		{
			var bounds = Bounds.Empty;
			bounds.Encapsulate(mModelDrawFrom);
			bounds.Encapsulate(mModelDrawTo);
			let height = mModelDraw == .Height ? mModelDrawHeight : 0;
			bounds.Encapsulate(mModelDrawFrom + Vector3(0, height, 0));
			return bounds;
		}
	}

	/// Click and drag out the base, then move the pointer up for the height and click again. Escape stops.
	bool UpdateShapeDrawing(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (ImGui.IsKeyPressed(ImGui.Key.Escape))
		{
			mModelDraw = .Off;
			return false;
		}
		if (!mSceneHovered && mModelDraw == .Waiting)
			return true;
		if (mFlying)
			return true;
		let mouse = ImGui.GetMousePos();
		let ray = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);
		let flat = (MeshShapes.Kind)mModelDrawKind == .Plane;
		switch (mModelDraw)
		{
		case .Waiting:
			mModelDrawHit = RaycastScene(ray, var point, ?);
			if (mModelDrawHit)
			{
				if (SnapActive)
				{
					point.x = SnapValue(point.x, mSnapMove);
					point.z = SnapValue(point.z, mSnapMove);
				}
				mModelDrawFrom = point;
				mModelDrawTo = point;
				if (ImGui.IsMouseClicked(0))
					mModelDraw = .Base;
			}
			ImGui.DrawText(.(mouse.x + 16, mouse.y + 12), .(1, 0.85f, 0.4f, 0.95f), scope $"Drag out the base of a {MeshShapes.Names[mModelDrawKind]}" .CStr());
		case .Base:
			// The base lies flat at the height it was started at.
			if (Math.Abs(ray.direction.y) > 1.0e-5f)
			{
				let t = (mModelDrawFrom.y - ray.origin.y) / ray.direction.y;
				if (t > 0)
				{
					var point = ray.GetPoint(t);
					if (SnapActive)
					{
						point.x = SnapValue(point.x, mSnapMove);
						point.z = SnapValue(point.z, mSnapMove);
					}
					mModelDrawTo = point;
				}
			}
			let extent = mModelDrawTo - mModelDrawFrom;
			ImGui.DrawText(.(mouse.x + 16, mouse.y + 12), .(1, 0.85f, 0.4f, 0.95f), scope $"{Math.Abs(extent.x):0.00} x {Math.Abs(extent.z):0.00} m" .CStr());
			if (!ImGui.IsMouseDown(0))
			{
				// A click without a drag: a shape of the size in the Model window.
				if (Math.Abs(extent.x) < 0.05f && Math.Abs(extent.z) < 0.05f)
				{
					mModelDrawFrom = mModelDrawFrom - Vector3(mModelShape.size.x / 2, 0, mModelShape.size.z / 2);
					mModelDrawTo = mModelDrawFrom + Vector3(mModelShape.size.x, 0, mModelShape.size.z);
					mModelDrawHeight = mModelShape.size.y;
					FinishShape();
				}
				else if (flat)
					FinishShape();
				else
				{
					mModelDraw = .Height;
					mModelDrawHeight = 0;
				}
			}
		case .Height:
			// Height along a wall through the base's middle, facing the camera.
			let center = (mModelDrawFrom + mModelDrawTo) * 0.5f;
			var facing = Vector3(ray.direction.x, 0, ray.direction.z);
			if (facing.LengthSquared > 1.0e-6f)
			{
				facing = facing.Normalized;
				let denominator = Vector3.Dot(ray.direction, facing);
				if (Math.Abs(denominator) > 1.0e-5f)
				{
					let t = Vector3.Dot(center - ray.origin, facing) / denominator;
					if (t > 0)
					{
						var height = ray.GetPoint(t).y - mModelDrawFrom.y;
						if (SnapActive)
							height = SnapValue(height, mSnapMove);
						mModelDrawHeight = height;
					}
				}
			}
			ImGui.DrawText(.(mouse.x + 16, mouse.y + 12), .(1, 0.85f, 0.4f, 0.95f), scope $"{mModelDrawHeight:0.00} m high (click to finish)" .CStr());
			if (ImGui.IsMouseClicked(0))
				FinishShape();
		default:
		}
		return true;
	}

	void FinishShape()
	{
		let kind = (MeshShapes.Kind)mModelDrawKind;
		var settings = mModelShape;
		let low = Vector3.Min(mModelDrawFrom, mModelDrawTo);
		let high = Vector3.Max(mModelDrawFrom, mModelDrawTo);
		let height = kind == .Plane ? 0 : Math.Abs(mModelDrawHeight);
		settings.size = .(Math.Max(high.x - low.x, 0.01f), Math.Max(height, 0.01f), Math.Max(high.z - low.z, 0.01f));
		var basePoint = Vector3((low.x + high.x) * 0.5f, mModelDrawFrom.y, (low.z + high.z) * 0.5f);
		// Drawn downwards: the shape hangs below the base instead.
		if (mModelDrawHeight < 0 && kind != .Plane)
			basePoint.y -= height;
		mModelDraw = ImGui.IsKeyDown(ImGui.Key.LeftShift) ? .Waiting : .Off;
		let shape = MeshShapes.Create(kind, settings);
		defer delete shape;
		CreateModelObject(MeshShapes.Names[mModelDrawKind], shape, basePoint);
	}

	/// A new object holding a model, placed with its origin at a point.
	GameObject CreateModelObject(StringView name, EditMesh shape, Vector3 position)
	{
		let made = mScene.CreateGameObject(name, null);
		made.Transform.Position = position;
		let renderer = made.AddComponent<MeshRenderer>();
		renderer.mesh.Clear();
		renderer.flatShading = false;
		renderer.roughness = 0.9f;
		let model = made.AddComponent<ModelMesh>();
		model.Set(shape);
		made.AddComponent<MeshCollider>();
		mSelectedId = made.Id;
		MarkDirty();
		return made;
	}

	// ------------------------------------------------------------------ operations

	enum ModelFaceOp
	{
		Extrude,
		ExtrudeEach,
		Inset,
		InsetRegion,
		Subdivide,
		SmoothSubdivide,
		Flip,
		Detach,
		Duplicate,
		Delete,
		Slot,
		Smooth,
		Flat,
		Color,
		/// Palette mode: the packed palette colour (ModelPaletteFaces).
		Palette,
		NewObject,
		Poke,
		Triangulate,
		TrianglesToQuads,
		Solidify
	}

	void ModelFaceAction(ModelMesh model, EditMesh mesh, ModelFaceOp op)
	{
		let faces = scope List<int32>();
		for (let f in mModelFaces)
			faces.Add(f);
		faces.Sort();
		if (faces.IsEmpty)
			return;
		let added = scope List<int32>();
		switch (op)
		{
		case .Extrude: MeshOps.ExtrudeFaces(mesh, faces, mModelExtrude, false, added);
		case .ExtrudeEach: MeshOps.ExtrudeFaces(mesh, faces, mModelExtrude, true, added);
		case .Inset: MeshOps.InsetFaces(mesh, faces, mModelInset, true, added);
		case .InsetRegion: MeshOps.InsetFaces(mesh, faces, mModelInset, false, added);
		case .Subdivide,.SmoothSubdivide:
			MeshOps.Subdivide(mesh, faces, op == .SmoothSubdivide, added);
			for (let f in added)
				mModelFaces.Add(f);
		case .Flip: MeshOps.FlipFaces(mesh, faces);
		case .Detach: MeshOps.Detach(mesh, faces);
		case .Poke,.Triangulate:
			if (op == .Poke)
				MeshOps.Poke(mesh, faces, added);
			else
				MeshOps.Triangulate(mesh, faces, added);
			for (let f in added)
				mModelFaces.Add(f);
		case .TrianglesToQuads:
			let joined = MeshOps.TrianglesToQuads(mesh, faces);
			Log.Info(scope $"Joined {joined} pairs of triangles.");
			mModelFaces.Clear();
		case .Solidify:
			MeshOps.Solidify(mesh, faces, mModelSolidify, added);
		case .Duplicate:
			MeshOps.Duplicate(mesh, faces, added);
			mModelFaces.Clear();
			for (let f in added)
				mModelFaces.Add(f);
		case .Delete:
			MeshOps.DeleteFaces(mesh, faces);
			mModelFaces.Clear();
		case .Slot:
			for (let f in faces)
				mesh.faces[f].material = mModelSlot;
		case .Smooth,.Flat:
			for (let f in faces)
				mesh.faces[f].smooth = op == .Smooth;
		case .Color:
			for (let f in faces)
			{
				for (var c in ref mesh.faces[f].colors)
					c = mModelColor;
			}
		case .Palette:
			let packed = PaletteFaceColor;
			for (let f in faces)
			{
				for (var c in ref mesh.faces[f].colors)
					c = packed;
			}
		case .NewObject:
			// The faces become an object of their own, in the same place.
			let part = scope EditMesh();
			let keep = scope HashSet<int32>();
			for (let f in faces)
				keep.Add(f);
			part.CopyFrom(mesh);
			let others = scope List<int32>();
			for (int32 f < (int32)part.faces.Count)
			{
				if (!keep.Contains(f))
					others.Add(f);
			}
			MeshOps.DeleteFaces(part, others);
			MeshOps.DeleteFaces(mesh, faces);
			mModelFaces.Clear();
			model.Save();
			let original = model.GameObject;
			let made = CreateModelObject(scope $"{original.Name} Part" , part, original.Transform.Position);
			made.Transform.Rotation = original.Transform.Rotation;
			made.Transform.LocalScale = original.Transform.LocalScale;
			let originalRenderer = original.GetComponent<MeshRenderer>();
			made.GetComponent<MeshRenderer>().material = originalRenderer ? originalRenderer.material : default;
			mSelectedId = original.Id;
			return;
		}
		mesh.Clean();
		CommitModel(model);
	}

	enum ModelEdgeOp
	{
		Bevel,
		LoopCut,
		SelectLoop,
		SelectRing,
		Bridge,
		Fill,
		Dissolve,
		Delete,
		Seam,
		ClearSeam,
		Hard,
		Soft,
		Split
	}

	void ModelEdgeAction(ModelMesh model, EditMesh mesh, ModelEdgeOp op)
	{
		let edges = scope List<uint64>();
		for (let e in mModelEdges)
			edges.Add(e);
		if (edges.IsEmpty)
			return;
		switch (op)
		{
		case .Bevel:
			MeshOps.Bevel(mesh, edges, mModelBevel, null, mModelBevelSegments);
			mModelEdges.Clear();
		case .LoopCut:
			let made = scope List<uint64>();
			MeshOps.LoopCut(mesh, edges[0], mModelCuts, 0.5f, made);
			mModelEdges.Clear();
			for (let e in made)
				mModelEdges.Add(e);
		case .SelectLoop,.SelectRing:
			for (let e in edges)
			{
				let found = scope List<uint64>();
				if (op == .SelectLoop)
					MeshOps.EdgeLoop(mesh, e, found);
				else
					MeshOps.EdgeRing(mesh, e, found);
				for (let f in found)
					mModelEdges.Add(f);
			}
			return;
		case .Bridge:
			if (!MeshOps.Bridge(mesh, edges))
			{
				Log.Warning("Bridge needs two open chains of edges with the same number of edges.");
				return;
			}
		case .Fill:
			MeshOps.Fill(mesh, edges);
		case .Dissolve:
			MeshOps.DissolveEdges(mesh, edges);
			mModelEdges.Clear();
		case .Delete:
			MeshOps.DeleteEdges(mesh, edges);
			mModelEdges.Clear();
		case .Seam,.ClearSeam:
			for (let e in edges)
			{
				if (op == .Seam)
					mesh.seams.Add(e);
				else
					mesh.seams.Remove(e);
			}
		case .Hard,.Soft:
			for (let e in edges)
			{
				if (op == .Hard)
					mesh.hardEdges.Add(e);
				else
					mesh.hardEdges.Remove(e);
			}
		case .Split:
			mModelEdges.Clear();
			mModelMode = .Vertex;
			mModelVerts.Clear();
			for (let e in edges)
			{
				EditMesh.EdgeEnds(e, let a, let b);
				mModelVerts.Add(MeshOps.SplitEdge(mesh, a, b, 0.5f));
			}
		}
		ValidateModelSelection(mesh);
		CommitModel(model);
	}

	enum ModelVertexOp
	{
		Merge,
		Weld,
		Connect,
		MakeFace,
		Delete
	}

	void ModelVertexAction(ModelMesh model, EditMesh mesh, ModelVertexOp op)
	{
		let verts = scope List<int32>();
		for (let v in mModelVerts)
			verts.Add(v);
		if (verts.IsEmpty)
			return;
		switch (op)
		{
		case .Merge:
			let kept = MeshOps.MergeVertices(mesh, verts);
			mModelVerts.Clear();
			if (kept >= 0)
				mModelVerts.Add(kept);
		case .Weld:
			let merged = MeshOps.MergeByDistance(mesh, verts, mModelWeld);
			Log.Info(scope $"Welded {merged} vertices.");
			mModelVerts.Clear();
		case .Connect:
			// Two vertices on the same face: cut it between them.
			if (verts.Count != 2)
			{
				Log.Warning("Connect needs exactly two vertices of one face.");
				return;
			}
			bool done = false;
			for (int32 f < (int32)mesh.faces.Count)
			{
				if (mesh.faces[f].IndexOf(verts[0]) >= 0 && mesh.faces[f].IndexOf(verts[1]) >= 0 && MeshOps.Connect(mesh, f, verts[0], verts[1]) >= 0)
				{
					done = true;
					break;
				}
			}
			if (!done)
			{
				Log.Warning("Those vertices are not two corners of one face that can be cut between them.");
				return;
			}
		case .MakeFace:
			let facing = model.Transform.WorldToLocal.TransformDirection(-ModelViewForward);
			if (MeshOps.MakeFace(mesh, verts, facing) < 0)
			{
				Log.Warning("Make Face needs three or more vertices that are not in a line.");
				return;
			}
		case .Delete:
			MeshOps.DeleteVertices(mesh, verts);
			mModelVerts.Clear();
		}
		ValidateModelSelection(mesh);
		CommitModel(model);
	}

	void DeleteModelSelection(ModelMesh model, EditMesh mesh)
	{
		switch (mModelMode)
		{
		case .Vertex: ModelVertexAction(model, mesh, .Delete);
		case .Edge: ModelEdgeAction(model, mesh, .Delete);
		case .Face: ModelFaceAction(model, mesh, .Delete);
		}
	}

	/// The faces UV tools work on: the selected ones, or every face with none selected.
	void ModelUVFaces(EditMesh mesh, List<int32> into)
	{
		if (mModelEditing && mModelMode == .Face && !mModelFaces.IsEmpty)
		{
			for (let f in mModelFaces)
				into.Add(f);
			into.Sort();
			return;
		}
		for (int32 f < (int32)mesh.faces.Count)
			into.Add(f);
	}

	/// The Model window's Origin section: where the object's origin (the point it turns and scales about) is.
	void DrawModelOrigin(ModelMesh model, EditMesh mesh)
	{
		ImGui.SeparatorText("Origin (what it turns about)");
		if (HalfButton("To Geometry"))
			RunModelCommand(model, mesh, .OriginToGeometry);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The middle of its vertices.");
		if (HalfButton("To Bounds Centre", true))
			RunModelCommand(model, mesh, .OriginToCentre);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The middle of the box round it.");
		if (HalfButton("To Mass (Volume)"))
			RunModelCommand(model, mesh, .OriginToVolumeMass);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Its centre of mass as a solid, filled evenly (where it would balance).\nA model with holes uses its surface's.");
		if (HalfButton("To Mass (Surface)", true))
			RunModelCommand(model, mesh, .OriginToSurfaceMass);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Its centre of mass as a thin shell: each part of its surface counted by its area.");
		if (HalfButton("To Base"))
			RunModelCommand(model, mesh, .OriginToBase);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The middle of its bottom, so it stands on what it is put on.");
		ImGui.BeginDisabled(!mModelEditing);
		if (HalfButton("To Selection", true))
			RunModelCommand(model, mesh, .OriginHere);
		ImGui.EndDisabled();
		if (ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
			ImGui.SetTooltip("The middle of the selected vertices, edges or faces (in edit mode).");
		let other = mModelOriginObject != 0 ? mScene.FindById(mModelOriginObject) : null;
		ImGui.SetNextItemWidth(ImGui.GetContentRegionAvail().x * 0.5f - 4);
		if (ImGui.BeginCombo("##originobject", other != null ? other.Name.CStr() : "Pick an object"))
		{
			for (let go in mScene.Objects)
			{
				if (go == model.GameObject || go.Transient || go.IsFolder)
					continue;
				if (ImGui.Selectable(scope $"{go.Name}##{go.Id}" .CStr(), go.Id == mModelOriginObject))
					mModelOriginObject = go.Id;
			}
			ImGui.EndCombo();
		}
		ImGui.BeginDisabled(other == null);
		if (HalfButton("To Object", true))
			RunModelCommand(model, mesh, .OriginToObject);
		ImGui.EndDisabled();
		if (ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
			ImGui.SetTooltip("Where the picked object is.");
		if (ImGui.Button("Geometry to Origin", .(-1, 0)))
			RunModelCommand(model, mesh, .GeometryToOrigin);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Moves the model so it stands round its origin (the object stays where it is).");
	}

	/// Moves the object's origin to a point of the model (in its own space), without moving the model in the world.
	void SetModelOrigin(ModelMesh model, Vector3 local)
	{
		let mesh = model.Edit;
		let worldPoint = model.Transform.TransformPoint(local);
		MeshOps.MoveOrigin(mesh, local);
		model.Transform.Position = worldPoint;
		CommitModel(model);
	}

	/// Cuts, joins or intersects the model with another model object.
	void ModelBoolean(ModelMesh model, GameObject other)
	{
		let otherModel = other.GetComponent<ModelMesh>();
		EditMesh otherMesh = null;
		bool ownOther = false;
		if (otherModel != null)
			otherMesh = otherModel.Edit;
		else
		{
			let renderer = other.GetComponent<MeshRenderer>();
			if (!renderer || renderer.ActiveMesh == null)
				return;
			otherMesh = EditMesh.FromMesh(renderer.ActiveMesh);
			ownOther = true;
		}
		defer
		{
			if (ownOther)
				delete otherMesh;
		}
		let op = (MeshCsg.Op)mModelBooleanOp;
		let result = MeshCsg.Combine(model.Edit, model.Transform.LocalToWorld, otherMesh, other.Transform.LocalToWorld, op, model.Transform.WorldToLocal);
		defer delete result;
		if (result.faces.IsEmpty && op != .Subtract)
		{
			Log.Warning("The two objects do not overlap: nothing is left.");
			return;
		}
		if (!result.IsClosed())
			Log.Warning("The result is not closed: the shapes may not have been closed solids.");
		model.Set(result);
		ClearModelSelection();
		if (!mModelBooleanKeep)
		{
			mScene.Destroy(other);
			mModelBooleanOther = 0;
		}
		MarkDirty();
	}

	/// Gives a selected object with an ordinary mesh a model made from it, to edit.
	void ConvertToModel(GameObject target)
	{
		let renderer = target.GetComponent<MeshRenderer>();
		if (!renderer || renderer.ActiveMesh == null)
			return;
		let mesh = EditMesh.FromMesh(renderer.ActiveMesh);
		defer delete mesh;
		mesh.MergeFlatNeighbours();
		renderer.mesh.Clear();
		renderer.flatShading = false;
		let model = target.AddComponent<ModelMesh>();
		model.Set(mesh);
		MarkDirty();
	}

	// ------------------------------------------------------------------ the Model window

	void DrawModelWindow()
	{
		TickModelTest();
		DrawModelHelp();
		if (!mShowModel)
		{
			if (mModelDraw != .Off)
				mModelDraw = .Off;
			return;
		}
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + viewport.workSize.x - 700, viewport.workPos.y + 80), 4);
		ImGui.SetNextWindowSize(.(330, 720), 4);
		// A tab beside the Inspector the first time; it can be moved from there.
		if (mDockModel && mInspectorDock != 0)
		{
			ImGui.SetNextWindowDockID(mInspectorDock);
			mDockModel = false;
			mModelFocus = true;
		}
		else if (mModelFocus)
		{
			ImGui.SetNextWindowFocus();
			mModelFocus = false;
		}
		if (ImGui.Begin("Model", &mShowModel))
		{
			DrawModelShapes();
			let selected = Selected;
			let model = selected?.GetComponent<ModelMesh>();
			if (selected != null && model == null && selected.HasComponent<MeshRenderer>() && mPlay == .Edit)
			{
				ImGui.SeparatorText("Selected object");
				if (ImGui.Button("Make Editable Model", .(-1, 0)))
					ConvertToModel(selected);
				ImGui.TextDisabled("Turns its mesh into faces the model tools can change.");
			}
			if (model != null && mPlay == .Edit)
				DrawModelTools(model);
			if (mPlay == .Edit)
			{
				ImGui.Spacing();
				DrawModelReferences();
				if (ImGui.Button(mShowModelViews ? "Close Model Views" : "Open Model Views (four views)", .(-1, 0)))
					mShowModelViews = mFocusModelViews = !mShowModelViews;
			}
		}
		ImGui.End();
		DrawUVEditor();
	}

	void DrawModelShapes()
	{
		ImGui.SeparatorText("New shape");
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##shape", scope String(MeshShapes.Names[mModelDrawKind]).CStr()))
		{
			for (int32 k < (int32)MeshShapes.Names.Count)
			{
				if (ImGui.Selectable(scope String(MeshShapes.Names[k]).CStr(), k == mModelDrawKind))
					mModelDrawKind = k;
			}
			ImGui.EndCombo();
		}
		let kind = (MeshShapes.Kind)mModelDrawKind;
		ModelVector3("Size", ref mModelShape.size);
		if (kind == .Cylinder || kind == .Cone || kind == .Sphere || kind == .Torus || kind == .Arch || kind == .Pipe)
		{
			ImGui.SetNextItemWidth(-90);
			ImGui.DragInt("Sides", ref mModelShape.sides, 0.2f, 3, 64);
		}
		if (kind == .Stairs || kind == .Sphere || kind == .Torus)
		{
			ImGui.SetNextItemWidth(-90);
			ImGui.DragInt(kind == .Stairs ? "Steps" : "Rings", ref mModelShape.steps, 0.2f, 1, 64);
		}
		if (kind == .Torus || kind == .Arch || kind == .Pipe || kind == .Corner)
		{
			ImGui.SetNextItemWidth(-90);
			ImGui.DragFloat("Thickness", ref mModelShape.thickness, 0.01f, 0.01f, 100);
		}
		if (kind == .Cylinder || kind == .Cone || kind == .Sphere || kind == .Torus || kind == .Pipe)
			ImGui.Checkbox("Smooth", ref mModelShape.smooth);
		let drawing = mModelDraw != .Off;
		if (ImGui.Button(drawing ? "Stop Drawing (Esc)" : "Draw in Scene", .(ImGui.GetContentRegionAvail().x * 0.5f - 4, 0)))
		{
			mModelDraw = drawing ? .Off : .Waiting;
			mModelEditing = false;
		}
		ImGui.SameLine();
		if (ImGui.Button("Add in View", .(-1, 0)))
			AddShapeInView(kind);
		if (drawing)
			ImGui.TextDisabled("Drag the base, move up for height, click. Shift-click keeps drawing.");
	}

	void DrawModelTools(ModelMesh model)
	{
		let mesh = model.Edit;
		ImGui.SeparatorText("Edit");
		if (ImGui.Checkbox(ModelLabel("Edit Model", ShortcutEditMode), ref mModelEditing))
		{
			if (mModelEditing)
				StartModelEditing(model.GameObject);
		}
		ImGui.SameLine();
		ImGui.TextDisabled(scope $"{mesh.faces.Count} faces, {mesh.positions.Count} vertices" .CStr());
		LoadModelShowOnly();
		var showOnly = mModelShowOnly;
		let showOnlyLabel = scope String()..AppendF("Show only this model while editing ({})###showonly", ModelShortcutText(ShortcutShowOnly));
		if (ImGui.Checkbox(showOnlyLabel.CStr(), ref showOnly))
			SetModelShowOnly(showOnly);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("In edit mode, hide every other object's mesh so this one is easy to see and pick.\nRemembered; the key is in Edit > Preferences > Modelling.");
		if (!mModelEditing)
		{
			DrawModelObjectTools(model, mesh);
			return;
		}
		ImGui.Checkbox("Paint", ref mModelPainting);
		ImGui.SameLine();
		if (ImGui.RadioButton("Vertex colours", !mModelPaintTexture))
			mModelPaintTexture = false;
		ImGui.SameLine();
		if (ImGui.RadioButton("Texture", mModelPaintTexture))
		{
			mModelPaintTexture = true;
			mModelPainting = true;
		}
		if (mModelPainting)
		{
			ImGui.ColorEdit4("Colour", ref mModelColor);
			ImGui.SetNextItemWidth(-90);
			ImGui.DragFloat("Radius", ref mModelPaintRadius, 0.01f, 0.01f, 50);
			ImGui.SetNextItemWidth(-90);
			ImGui.SliderFloat("Strength", ref mModelPaintStrength, 0.05f, 1);
			if (mModelPaintTexture)
				DrawTexturePaintSettings(model, mesh);
			else
				ImGui.TextDisabled("Drag to paint. Shift paints whole faces flat.");
			return;
		}
		for (let mode in ModelSelectMode[3](.Vertex, .Edge, .Face))
		{
			let label = mode == .Vertex ? ModelLabel("Vertices", ShortcutVertexMode) : (mode == .Edge ? ModelLabel("Edges", ShortcutEdgeMode) : ModelLabel("Faces", ShortcutFaceMode));
			if (ImGui.RadioButton(label, mModelMode == mode))
				SetModelMode(mode, mesh);
			if (mode != .Face)
				ImGui.SameLine();
		}
		ImGui.Checkbox("Pick hidden too (x-ray)", ref mModelXRay);
		ImGui.Checkbox(ModelLabel("Proportional", ModelCommandShortcut(.Proportional)), ref mModelProportional);
		if (mModelProportional)
		{
			ImGui.SameLine();
			ImGui.SetNextItemWidth(-1);
			ImGui.DragFloat("##propradius", ref mModelPropRadius, 0.01f, 0.01f, 1000, "radius %.2f m");
		}
		ImGui.TextDisabled("Mirror edits");
		for (int axis < 3)
		{
			ImGui.SameLine();
			ImGui.Checkbox(axis == 0 ? "X##sym" : (axis == 1 ? "Y##sym" : "Z##sym"), ref mModelSymmetry[axis]);
		}
		ImGui.TextDisabled("Click, Shift-click, drag a box (Ctrl takes away).");
		ImGui.TextDisabled("Alt+click a loop, Ctrl+click a path.");
		ImGui.TextDisabled("Right-click in the Scene view for every tool.");
		if (ImGui.Button(mModelShowHelp ? "Hide Shortcuts (F1)" : "Show Shortcuts (F1)", .(-1, 0)))
			mModelShowHelp = !mModelShowHelp;
		ImGui.SeparatorText("Drag tools (start in the Scene view)");
		if (HalfButton(ModelLabel("Grab", ModelCommandShortcut(.Grab))))
			RunModelCommand(model, mesh, .Grab);
		if (HalfButton(ModelLabel("Rotate", ModelCommandShortcut(.Rotate)), true))
			RunModelCommand(model, mesh, .Rotate);
		if (HalfButton(ModelLabel("Scale", ModelCommandShortcut(.Scale))))
			RunModelCommand(model, mesh, .Scale);
		if (HalfButton(ModelLabel("Knife", ModelCommandShortcut(.Knife)), true))
			RunModelCommand(model, mesh, .Knife);
		if (HalfButton(ModelLabel("Loop Cut", ModelCommandShortcut(.LoopCut))))
			RunModelCommand(model, mesh, .LoopCut);
		if (HalfButton(ModelLabel("Bevel", ModelCommandShortcut(.Bevel)), true))
			RunModelCommand(model, mesh, .Bevel);
		ImGui.TextDisabled("Move the pointer, then click or Enter; Esc cancels.");
		switch (mModelMode)
		{
		case .Face: DrawFaceTools(model, mesh);
		case .Edge: DrawEdgeTools(model, mesh);
		case .Vertex: DrawVertexTools(model, mesh);
		}
		DrawModelObjectTools(model, mesh);
	}

	/// A labelled row of three numbers.
	static bool ModelVector3(char8* label, ref Vector3 value)
	{
		ImGui.PushID(label);
		let width = (ImGui.GetContentRegionAvail().x - 90) / 3 - 4;
		bool changed = false;
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##x", ref value.x, 0.01f);
		ImGui.SameLine();
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##y", ref value.y, 0.01f);
		ImGui.SameLine();
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##z", ref value.z, 0.01f);
		ImGui.SameLine();
		ImGui.TextDisabled(label);
		ImGui.PopID();
		return changed;
	}

	/// A labelled row of two numbers.
	static bool ModelVector2(char8* label, ref Vector2 value)
	{
		ImGui.PushID(label);
		let width = (ImGui.GetContentRegionAvail().x - 110) / 2 - 4;
		bool changed = false;
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##x", ref value.x, 0.01f);
		ImGui.SameLine();
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##y", ref value.y, 0.01f);
		ImGui.SameLine();
		ImGui.TextDisabled(label);
		ImGui.PopID();
		return changed;
	}

	bool HalfButton(char8* label, bool right = false)
	{
		if (right)
			ImGui.SameLine();
		return ImGui.Button(label, .(right ? -1 : ImGui.GetContentRegionAvail().x * 0.5f - 4, 0));
	}

	void DrawFaceTools(ModelMesh model, EditMesh mesh)
	{
		ImGui.SeparatorText(scope $"Faces ({mModelFaces.Count} selected)" .CStr());
		ImGui.TextDisabled("E extrudes and I insets with the pointer; Shift-drag the move arrows to extrude.");
		ImGui.SetNextItemWidth(-90);
		ImGui.DragFloat("Distance", ref mModelExtrude, 0.01f, -100, 100);
		if (HalfButton("Extrude"))
			ModelFaceAction(model, mesh, .Extrude);
		if (HalfButton("Extrude Each", true))
			ModelFaceAction(model, mesh, .ExtrudeEach);
		ImGui.SetNextItemWidth(-90);
		ImGui.DragFloat("Inset", ref mModelInset, 0.005f, 0.001f, 100);
		if (HalfButton("Inset Each"))
			ModelFaceAction(model, mesh, .Inset);
		if (HalfButton("Inset Together", true))
			ModelFaceAction(model, mesh, .InsetRegion);
		if (HalfButton("Subdivide"))
			ModelFaceAction(model, mesh, .Subdivide);
		if (HalfButton("Smooth Subdivide", true))
			ModelFaceAction(model, mesh, .SmoothSubdivide);
		if (HalfButton("Poke"))
			ModelFaceAction(model, mesh, .Poke);
		if (HalfButton(ModelLabel("Triangulate", ModelCommandShortcut(.Triangulate)), true))
			ModelFaceAction(model, mesh, .Triangulate);
		if (HalfButton(ModelLabel("Tris to Quads", ModelCommandShortcut(.TrianglesToQuads))))
			ModelFaceAction(model, mesh, .TrianglesToQuads);
		if (HalfButton(ModelLabel("Flip", ModelCommandShortcut(.Flip)), true))
			ModelFaceAction(model, mesh, .Flip);
		ImGui.SetNextItemWidth(-140);
		ImGui.DragFloat("Thickness", ref mModelSolidify, 0.005f, -100, 100);
		ImGui.SameLine();
		if (ImGui.Button("Solidify", .(-1, 0)))
			ModelFaceAction(model, mesh, .Solidify);
		if (HalfButton("Detach"))
			ModelFaceAction(model, mesh, .Detach);
		if (HalfButton(ModelLabel("Collapse", ModelCommandShortcut(.Collapse)), true))
			RunModelCommand(model, mesh, .Collapse);
		if (HalfButton(ModelLabel("Duplicate", ModelCommandShortcut(.Duplicate))))
			RunModelCommand(model, mesh, .Duplicate);
		if (HalfButton(ModelLabel("Delete", ModelCommandShortcut(.Delete)), true))
			ModelFaceAction(model, mesh, .Delete);
		if (HalfButton("Smooth Shading"))
			ModelFaceAction(model, mesh, .Smooth);
		if (HalfButton("Flat Shading", true))
			ModelFaceAction(model, mesh, .Flat);
		if (ImGui.Button(ModelLabel("Make Separate Object", ModelCommandShortcut(.Separate)), .(-1, 0)))
			ModelFaceAction(model, mesh, .NewObject);
		if (HalfButton(ModelLabel("Grow", ModelCommandShortcut(.Grow))))
			GrowModelSelection(mesh, true);
		if (HalfButton(ModelLabel("Shrink", ModelCommandShortcut(.Shrink)), true))
			GrowModelSelection(mesh, false);
		if (HalfButton(ModelLabel("Select Linked", ModelCommandShortcut(.Linked))))
			SelectModelLinked(mesh);
		if (HalfButton("Same Material", true))
			SelectModelSameSlot(mesh);
		ImGui.SeparatorText("Look");
		ImGui.SetNextItemWidth(-140);
		ImGui.DragInt("Material slot", ref mModelSlot, 0.1f, 0, 15);
		ImGui.SameLine();
		if (ImGui.Button("Set##slot", .(-1, 0)))
			ModelFaceAction(model, mesh, .Slot);
		ImGui.TextDisabled("Slot 0 uses the Mesh Renderer's material; 1 and up use Model Mesh > Materials.");
		ImGui.ColorEdit4("##facecolour", ref mModelColor);
		ImGui.SameLine();
		if (ImGui.Button("Colour Faces", .(-1, 0)))
			ModelFaceAction(model, mesh, .Color);
		DrawPaletteFaces(model, mesh);
		DrawFaceUVSettings(model, mesh);
	}

	/// Auto texture settings of the selected faces (scale, offset, turn), taken from the first and given to all.
	void DrawFaceUVSettings(ModelMesh model, EditMesh mesh)
	{
		if (mModelFaces.IsEmpty)
			return;
		var first = -1;
		for (let f in mModelFaces)
		{
			first = f;
			break;
		}
		let face = mesh.faces[first];
		ImGui.SeparatorText("Texture on these faces");
		var scale = face.uvScale;
		var offset = face.uvOffset;
		var rotation = face.uvRotation;
		bool changed = false;
		changed |= ModelVector2("Metres a repeat", ref scale);
		changed |= ModelVector2("Offset", ref offset);
		ImGui.SetNextItemWidth(-110);
		changed |= ImGui.DragFloat("Turn", ref rotation, 1, -360, 360);
		if (changed)
		{
			for (let f in mModelFaces)
			{
				let target = mesh.faces[f];
				target.uvScale = .(Math.Max(scale.x, 0.001f), Math.Max(scale.y, 0.001f));
				target.uvOffset = offset;
				target.uvRotation = rotation;
				target.uvMode = .Auto;
			}
			model.Preview();
			MarkDirty();
			mModelUVPending = true;
		}
		if (mModelUVPending && !ImGui.IsAnyItemActive())
		{
			mModelUVPending = false;
			CommitModel(model);
		}
		if (face.uvMode == .Manual)
		{
			ImGui.TextDisabled("These faces have unwrapped coordinates.");
			if (ImGui.Button("Back to Auto", .(-1, 0)))
			{
				for (let f in mModelFaces)
					mesh.faces[f].uvMode = .Auto;
				CommitModel(model);
			}
		}
	}

	bool mModelUVPending;

	void DrawEdgeTools(ModelMesh model, EditMesh mesh)
	{
		ImGui.SeparatorText(scope $"Edges ({mModelEdges.Count} selected)" .CStr());
		ImGui.TextDisabled("E pulls edges out with the pointer, as Shift-dragging the move arrows does.");
		ImGui.SetNextItemWidth(-90);
		ImGui.DragFloat("Width", ref mModelBevel, 0.005f, 0.001f, 100);
		ImGui.SetNextItemWidth(-90);
		ImGui.DragInt("Segments", ref mModelBevelSegments, 0.1f, 1, 32);
		if (ImGui.Button("Bevel", .(-1, 0)))
			ModelEdgeAction(model, mesh, .Bevel);
		if (ImGui.Button("Slide (G G)", .(-1, 0)))
			RunModelCommand(model, mesh, .Slide);
		ImGui.SetNextItemWidth(-90);
		ImGui.DragInt("Cuts", ref mModelCuts, 0.1f, 1, 32);
		if (ImGui.Button("Loop Cut", .(-1, 0)))
			ModelEdgeAction(model, mesh, .LoopCut);
		if (HalfButton("Select Loop"))
			ModelEdgeAction(model, mesh, .SelectLoop);
		if (HalfButton("Select Ring", true))
			ModelEdgeAction(model, mesh, .SelectRing);
		if (HalfButton("Bridge"))
			ModelEdgeAction(model, mesh, .Bridge);
		if (HalfButton(ModelLabel("Fill Hole", ModelCommandShortcut(.MakeFace)), true))
			ModelEdgeAction(model, mesh, .Fill);
		if (HalfButton("Split in Middle"))
			ModelEdgeAction(model, mesh, .Split);
		if (HalfButton("Dissolve", true))
			ModelEdgeAction(model, mesh, .Dissolve);
		if (HalfButton(ModelLabel("Collapse", ModelCommandShortcut(.Collapse))))
			RunModelCommand(model, mesh, .Collapse);
		if (HalfButton("Smooth", true))
			RunModelCommand(model, mesh, .SmoothVertices);
		if (HalfButton("Mark Seam"))
			ModelEdgeAction(model, mesh, .Seam);
		if (HalfButton("Clear Seam", true))
			ModelEdgeAction(model, mesh, .ClearSeam);
		if (HalfButton("Hard Edge"))
			ModelEdgeAction(model, mesh, .Hard);
		if (HalfButton("Soft Edge", true))
			ModelEdgeAction(model, mesh, .Soft);
		if (ImGui.Button(ModelLabel("Delete", ModelCommandShortcut(.Delete)), .(-1, 0)))
			ModelEdgeAction(model, mesh, .Delete);
		if (HalfButton("Select Open Edges"))
			RunModelCommand(model, mesh, .SelectOpen);
		if (HalfButton("Select Sharp", true))
			SelectModelSharp(mesh);
		ImGui.SetNextItemWidth(-90);
		ImGui.DragFloat("Sharp angle", ref mModelSharpAngle, 0.5f, 1, 179);
	}

	void DrawVertexTools(ModelMesh model, EditMesh mesh)
	{
		ImGui.SeparatorText(scope $"Vertices ({mModelVerts.Count} selected)" .CStr());
		if (HalfButton(ModelLabel("Merge at Centre", ModelCommandShortcut(.Merge))))
			ModelVertexAction(model, mesh, .Merge);
		if (HalfButton(ModelLabel("Connect", ModelCommandShortcut(.Connect)), true))
			ModelVertexAction(model, mesh, .Connect);
		if (HalfButton(ModelLabel("Make Face", ModelCommandShortcut(.MakeFace))))
			ModelVertexAction(model, mesh, .MakeFace);
		if (HalfButton("Smooth", true))
			RunModelCommand(model, mesh, .SmoothVertices);
		if (ImGui.Button(ModelLabel("Slide", ModelCommandShortcut(.VertexSlide)), .(-1, 0)))
			RunModelCommand(model, mesh, .VertexSlide);
		ImGui.SetNextItemWidth(-140);
		ImGui.DragFloat("Weld distance", ref mModelWeld, 0.001f, 0.0001f, 10);
		ImGui.SameLine();
		if (ImGui.Button("Weld", .(-1, 0)))
			ModelVertexAction(model, mesh, .Weld);
		if (ImGui.Button(ModelLabel("Delete", ModelCommandShortcut(.Delete)), .(-1, 0)))
			ModelVertexAction(model, mesh, .Delete);
		if (mModelVerts.Count == 1)
		{
			var only = 0;
			for (let v in mModelVerts)
				only = v;
			if (ImGui.Button("Put Object Origin Here", .(-1, 0)))
				SetModelOrigin(model, mesh.positions[only]);
		}
	}

	void DrawModelObjectTools(ModelMesh model, EditMesh mesh)
	{
		ImGui.SeparatorText("Whole model");
		if (ImGui.Button("Mirror X", .(ImGui.GetContentRegionAvail().x / 3 - 4, 0)))
			RunModelCommand(model, mesh, .MirrorX);
		ImGui.SameLine();
		if (ImGui.Button("Mirror Y", .(ImGui.GetContentRegionAvail().x / 2 - 4, 0)))
			RunModelCommand(model, mesh, .MirrorY);
		ImGui.SameLine();
		if (ImGui.Button("Mirror Z", .(-1, 0)))
			RunModelCommand(model, mesh, .MirrorZ);
		ImGui.TextDisabled("Mirror copies the model across its origin and joins the halves.");
		ImGui.SetNextItemWidth(-90);
		ImGui.DragInt("Copies", ref mModelArrayCount, 0.1f, 2, 100);
		ModelVector3("Step", ref mModelArrayOffset);
		if (ImGui.Button("Array", .(-1, 0)))
		{
			MeshOps.Array(mesh, mModelArrayCount, mModelArrayOffset);
			ClearModelSelection();
			CommitModel(model);
		}
		if (HalfButton(ModelLabel("Fix Normals", ModelCommandShortcut(.FixNormals))))
			RunModelCommand(model, mesh, .FixNormals);
		if (HalfButton("Weld All", true))
			RunModelCommand(model, mesh, .WeldAll);
		if (HalfButton("Join Flat Faces"))
		{
			let joined = mesh.MergeFlatNeighbours();
			ClearModelSelection();
			Log.Info(scope $"Joined {joined} faces.");
			CommitModel(model);
		}
		if (HalfButton("Clean Up", true))
			RunModelCommand(model, mesh, .CleanUp);
		if (!mesh.IsClosed())
			ImGui.TextColored(EditorTheme.Warning, "Not closed: it has holes (Booleans need closed models).");

		DrawModelOrigin(model, mesh);

		ImGui.SeparatorText("Boolean with another object");
		let other = mModelBooleanOther != 0 ? mScene.FindById(mModelBooleanOther) : null;
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##booleanother", other != null ? other.Name.CStr() : "Pick an object"))
		{
			for (let renderer in mScene.Renderers)
			{
				let go = renderer.GameObject;
				if (go == model.GameObject || go.Transient || renderer.ActiveMesh == null)
					continue;
				if (ImGui.Selectable(scope $"{go.Name}##{go.Id}" .CStr(), go.Id == mModelBooleanOther))
					mModelBooleanOther = go.Id;
			}
			ImGui.EndCombo();
		}
		if (ImGui.RadioButton("Join", mModelBooleanOp == 0))
			mModelBooleanOp = 0;
		ImGui.SameLine();
		if (ImGui.RadioButton("Cut out", mModelBooleanOp == 1))
			mModelBooleanOp = 1;
		ImGui.SameLine();
		if (ImGui.RadioButton("Overlap", mModelBooleanOp == 2))
			mModelBooleanOp = 2;
		ImGui.Checkbox("Keep the other object", ref mModelBooleanKeep);
		ImGui.BeginDisabled(other == null);
		if (ImGui.Button("Apply Boolean", .(-1, 0)) && other != null)
			ModelBoolean(model, other);
		ImGui.EndDisabled();

		DrawModelUVTools(model, mesh);

		ImGui.SeparatorText("Levels of detail");
		ImGui.SetNextItemWidth(-140);
		ImGui.DragInt("Levels", ref mModelLodLevels, 0.05f, 2, 4);
		for (int32 level = 1; level < mModelLodLevels; level++)
		{
			ImGui.SetNextItemWidth(-140);
			ImGui.SliderFloat(scope $"Level {level} keeps" .CStr(), ref mModelLodShares[level], 0.02f, 1, "%.2f");
		}
		if (ImGui.Button("Make Levels of Detail", .(-1, 0)))
			MakeModelLods(model);
		ImGui.TextDisabled("Simpler copies as children, picked by distance with a LOD Group. Make them again after editing.");

		ImGui.SeparatorText("Save as a file");
		if (mModelExportPath.IsEmpty)
			mModelExportPath.AppendF("Models/{}.glb", model.GameObject.Name);
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##modelexport", mModelExportPath, 0, "Models/Name.glb or .tmesh");
		if (ImGui.Button("Export", .(-1, 0)))
			ExportModel(model);
		ImGui.TextDisabled(".glb opens in Blender and other tools; .tmesh is the engine's own and keeps everything.");
	}

	int32 mModelLodLevels = 3;
	float[4] mModelLodShares = .(1, 0.5f, 0.2f, 0.08f);

	/// Makes children `<name>_LOD1` and on, each with the model decimated to its share of the triangles (replacing
	/// ones made before), and a LOD Group that draws the model itself as level 0.
	void MakeModelLods(ModelMesh model)
	{
		let owner = model.GameObject;
		let renderer = owner.GetComponent<MeshRenderer>();
		// Levels made before go first.
		let old = scope List<GameObject>();
		for (let child in owner.Transform.Children)
		{
			let level = LODGroup.LevelInName(child.GameObject.Name);
			if (level > 0 && child.GameObject.GetComponent<ModelMesh>() != null)
				old.Add(child.GameObject);
		}
		for (let go in old)
			mScene.DestroyImmediate(go);
		let full = MeshOps.TriangleCount(model.Edit);
		let report = scope String();
		for (int32 level = 1; level < mModelLodLevels; level++)
		{
			let simpler = model.Edit.Clone();
			defer delete simpler;
			simpler.pins.Clear();
			MeshOps.Decimate(simpler, mModelLodShares[level]);
			let child = mScene.CreateGameObject(scope $"{owner.Name}_LOD{level}" , owner.Transform);
			let childRenderer = child.AddComponent<MeshRenderer>();
			childRenderer.mesh.Clear();
			if (renderer)
			{
				childRenderer.material.Set(renderer.material);
				childRenderer.texture.Set(renderer.texture);
				childRenderer.flatShading = renderer.flatShading;
				childRenderer.roughness = renderer.roughness;
			}
			let childModel = child.AddComponent<ModelMesh>();
			childModel.materials.Set(model.materials);
			childModel.worldScaleUVs = model.worldScaleUVs;
			childModel.Set(simpler);
			report.AppendF("{}{}", report.IsEmpty ? "" : ", ", MeshOps.TriangleCount(simpler));
		}
		var group = owner.GetComponent<LODGroup>();
		if (group == null)
			group = owner.AddComponent<LODGroup>();
		group.source = .Children;
		group.Refresh();
		MarkDirty();
		Log.Info(scope $"Levels of detail for {owner.Name}: {full} triangles, then {report}.");
	}

	void ExportModel(ModelMesh model)
	{
		let full = Assets.ResolvePath(mModelExportPath, .. scope .());
		let folder = scope String();
		Path.GetDirectoryPath(full, folder);
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		bool ok;
		if (mModelExportPath.EndsWith(".tmesh", .OrdinalIgnoreCase))
			ok = model.Export(mModelExportPath);
		else
		{
			let names = scope List<StringView>();
			let renderer = model.GetComponent<MeshRenderer>();
			names.Add((renderer && !renderer.material.IsEmpty) ? renderer.material : "Material");
			for (let name in model.materials.Split(';'))
				names.Add(name);
			ok = GlbWriter.Write(full, model.Edit, names);
		}
		if (ok)
		{
			Log.Info(scope $"Saved {mModelExportPath}.");
			RefreshPalette();
		}
		else
			Log.Error(scope $"Could not write {mModelExportPath}.");
	}

	// ------------------------------------------------------------------ texture coordinates

	void DrawModelUVTools(ModelMesh model, EditMesh mesh)
	{
		ImGui.SeparatorText("Texture coordinates");
		let faces = scope List<int32>();
		ModelUVFaces(mesh, faces);
		ImGui.TextDisabled((mModelEditing && mModelMode == .Face && !mModelFaces.IsEmpty) ? "On the selected faces." : "On every face (select faces to do some).");
		if (HalfButton("Auto (world)"))
		{
			for (let f in faces)
				mesh.faces[f].uvMode = .Auto;
			CommitModel(model);
		}
		if (HalfButton("Box", true))
		{
			MeshUV.Box(mesh, faces);
			CommitModel(model);
		}
		if (HalfButton("Planar"))
		{
			MeshUV.Planar(mesh, faces);
			CommitModel(model);
		}
		if (HalfButton("Cylinder", true))
		{
			MeshUV.Cylinder(mesh, faces);
			CommitModel(model);
		}
		if (HalfButton("Sphere"))
		{
			MeshUV.Sphere(mesh, faces);
			CommitModel(model);
		}
		if (HalfButton("Unwrap at Seams", true))
		{
			MeshUV.Unwrap(mesh, faces);
			CommitModel(model);
		}
		ImGui.SetNextItemWidth(-140);
		ImGui.DragFloat("Angle limit", ref mModelSmartAngle, 0.5f, 1, 89);
		ImGui.SameLine();
		if (ImGui.Button("Smart Unwrap", .(-1, 0)))
		{
			MeshUV.SmartUnwrap(mesh, faces, mModelSmartAngle);
			CommitModel(model);
		}
		if (HalfButton("Pack"))
		{
			MeshUV.Pack(mesh, faces);
			CommitModel(model);
		}
		if (HalfButton("UV Editor", true))
			mShowUVEditor = true;
	}

	bool mShowUVEditor;
	bool mUVDragging;
	ImGui.Vec2 mUVDragLast;
	float mUVZoom = 1;
	/// Corners picked in the UV Editor (face << 32 | corner), and the face picked first (Stitch joins onto it).
	HashSet<int64> mUVPicked = new .() ~ delete _;
	int32 mUVFirstFace = -1;
	/// Picking single points instead of whole pieces.
	bool mUVPoints;
	bool mUVBoxing;
	ImGui.Vec2 mUVBoxFrom;
	// A palette or atlas laid over the picture as a grid of cells; Ctrl+click on one puts faces into it.
	bool mUVPalette;
	int32 mUVPaletteColumns = 8;
	int32 mUVPaletteRows = 8;
	float mUVCellFill = 0;

	static int64 UVKey(int32 face, int32 corner) => ((int64)face << 32) | corner;

	/// The faces' texture coordinates over the model's texture. Pieces (or points) are picked, moved, turned,
	/// pinned and stitched; with a palette grid, Ctrl+click puts faces into a cell.
	void DrawUVEditor()
	{
		if (!mShowUVEditor)
			return;
		ImGui.SetNextWindowSize(.(560, 660), 4);
		if (ImGui.Begin("UV Editor", &mShowUVEditor))
		{
			let model = Selected?.GetComponent<ModelMesh>();
			if (model == null)
				ImGui.TextDisabled("Select a model.");
			else
				DrawUVCanvas(model);
		}
		ImGui.End();
	}

	/// The texture a model is drawn with: its material's, or the renderer's own.
	static void ModelTexturePath(ModelMesh model, String into)
	{
		let renderer = model.GetComponent<MeshRenderer>();
		if (!renderer)
			return;
		let material = renderer.SharedMaterial;
		into.Set((material != null && !material.texture.IsEmpty) ? material.texture : renderer.texture);
	}

	/// Gives a model a texture of its own (the renderer's; a material's texture would change every model using it).
	bool SetModelTexture(ModelMesh model, StringView path)
	{
		let renderer = model.GetComponent<MeshRenderer>();
		if (!renderer)
			return false;
		let material = renderer.SharedMaterial;
		if (material != null && !material.texture.IsEmpty)
		{
			Log.Warning(scope $"The model's material draws with its own texture ({material.texture}); set that to {path}, or take the material off.");
			return false;
		}
		renderer.texture.Set(path);
		MarkDirty();
		return true;
	}

	/// The corners the UV tools work on: those picked, or every corner shown.
	void UVTargets(EditMesh mesh, List<int32> faces, List<int64> into)
	{
		if (!mUVPicked.IsEmpty)
		{
			for (let key in mUVPicked)
				into.Add(key);
			return;
		}
		for (let f in faces)
		{
			for (int32 c < (int32)mesh.faces[f].Count)
				into.Add(UVKey(f, c));
		}
	}

	/// Picks the corners of a piece, or of a point (every shown corner of that vertex at that place).
	void PickUV(EditMesh mesh, List<int32> faces, int32 face, int32 corner, bool add, bool toggle)
	{
		let keys = scope List<int64>();
		if (mUVPoints && corner >= 0)
		{
			let v = mesh.faces[face].verts[corner];
			let uv = mesh.faces[face].uvs[corner];
			for (let f in faces)
			{
				let other = mesh.faces[f];
				for (int32 c < (int32)other.Count)
				{
					if (other.verts[c] == v && (other.uvs[c] - uv).LengthSquared < 1.0e-12f)
						keys.Add(UVKey(f, c));
				}
			}
		}
		else
		{
			let islands = scope List<List<int32>>();
			defer
			{
				for (let island in islands)
					delete island;
			}
			MeshUV.Islands(mesh, faces, islands);
			for (let island in islands)
			{
				if (!island.Contains(face))
					continue;
				for (let f in island)
				{
					for (int32 c < (int32)mesh.faces[f].Count)
						keys.Add(UVKey(f, c));
				}
			}
		}
		if (!add)
			mUVPicked.Clear();
		var allPicked = !keys.IsEmpty;
		for (let key in keys)
			allPicked &= mUVPicked.Contains(key);
		for (let key in keys)
		{
			if (toggle && allPicked)
				mUVPicked.Remove(key);
			else
				mUVPicked.Add(key);
		}
		if (mUVPicked.IsEmpty || !add)
			mUVFirstFace = mUVPicked.IsEmpty ? -1 : face;
	}

	void DrawUVCanvas(ModelMesh model)
	{
		let mesh = model.Edit;
		let faces = scope List<int32>();
		ModelUVFaces(mesh, faces);
		let shown = scope HashSet<int32>();
		for (let f in faces)
			shown.Add(f);
		mUVPicked.RemoveWhere(scope (key) =>
			{
				let f = (int32)(key >> 32);
				return f < 0 || f >= mesh.faces.Count || !shown.Contains(f) || (key & 0xFFFFFFFF) >= mesh.faces[f].Count;
			});
		let selectedOnly = mModelEditing && mModelMode == .Face && !mModelFaces.IsEmpty;
		bool changed = false;
		// Tools along the top work on the picked corners, or on all those shown.
		void Transform(function Vector2(Vector2 uv, Vector2 center) f)
		{
			let targets = scope List<int64>();
			UVTargets(mesh, faces, targets);
			if (targets.IsEmpty)
				return;
			var center = Vector2.Zero;
			for (let key in targets)
				center = center + mesh.faces[(int32)(key >> 32)].uvs[(int)(key & 0xFFFFFFFF)];
			center = center * (1.0f / targets.Count);
			for (let key in targets)
			{
				let face = mesh.faces[(int32)(key >> 32)];
				face.uvMode = .Manual;
				let c = (int)(key & 0xFFFFFFFF);
				face.uvs[c] = f(face.uvs[c], center);
			}
			changed = true;
		}
		if (ImGui.RadioButton("Pieces", !mUVPoints))
			mUVPoints = false;
		ImGui.SameLine();
		if (ImGui.RadioButton("Points", mUVPoints))
			mUVPoints = true;
		ImGui.SameLine();
		if (ImGui.Button("All"))
		{
			mUVPicked.Clear();
			for (let f in faces)
			{
				for (int32 c < (int32)mesh.faces[f].Count)
					mUVPicked.Add(UVKey(f, c));
			}
			mUVFirstFace = faces.IsEmpty ? -1 : faces[0];
		}
		ImGui.SameLine();
		if (ImGui.Button("None"))
			mUVPicked.Clear();
		ImGui.SameLine();
		ImGui.SetNextItemWidth(-1);
		ImGui.SliderFloat("##uvzoom", ref mUVZoom, 0.25f, 4, "zoom %.2f");
		if (ImGui.Button("Turn 90"))
			Transform((uv, c) => Vector2(c.x - (uv.y - c.y), c.y + (uv.x - c.x)));
		ImGui.SameLine();
		if (ImGui.Button("Flip U"))
			Transform((uv, c) => Vector2(c.x * 2 - uv.x, uv.y));
		ImGui.SameLine();
		if (ImGui.Button("Flip V"))
			Transform((uv, c) => Vector2(uv.x, c.y * 2 - uv.y));
		ImGui.SameLine();
		if (ImGui.Button("Bigger"))
			Transform((uv, c) => c + (uv - c) * 1.1f);
		ImGui.SameLine();
		if (ImGui.Button("Smaller"))
			Transform((uv, c) => c + (uv - c) * (1 / 1.1f));
		ImGui.SameLine();
		if (ImGui.Button("Fit"))
		{
			let fit = scope List<int32>();
			if (mUVPicked.IsEmpty)
				fit.AddRange(faces);
			else
			{
				let set = scope HashSet<int32>();
				for (let key in mUVPicked)
					set.Add((int32)(key >> 32));
				for (let f in set)
					fit.Add(f);
			}
			for (let i in fit)
				mesh.faces[i].uvMode = .Manual;
			MeshUV.FitAll(mesh, fit, 0.01f);
			changed = true;
		}
		// Pins and stitching.
		if (ImGui.Button("Pin"))
		{
			for (let key in mUVPicked)
			{
				let face = mesh.faces[(int32)(key >> 32)];
				face.uvMode = .Manual;
				mesh.pins.Add(face.verts[(int)(key & 0xFFFFFFFF)]);
			}
			changed = !mUVPicked.IsEmpty;
		}
		ImGui.SameLine();
		if (ImGui.Button("Unpin"))
		{
			for (let key in mUVPicked)
				mesh.pins.Remove(mesh.faces[(int32)(key >> 32)].verts[(int)(key & 0xFFFFFFFF)]);
			changed = !mUVPicked.IsEmpty;
		}
		ImGui.SameLine();
		if (ImGui.Button("Stitch"))
		{
			let set = scope HashSet<int32>();
			for (let key in mUVPicked)
				set.Add((int32)(key >> 32));
			let stitch = scope List<int32>();
			for (let f in set)
				stitch.Add(f);
			stitch.Sort();
			let first = set.Contains(mUVFirstFace) ? mUVFirstFace : (stitch.IsEmpty ? -1 : stitch[0]);
			let moved = first >= 0 ? MeshUV.StitchAll(mesh, stitch, (int32)first) : 0;
			if (moved == 0)
				Log.Warning("Stitch: pick two or more pieces that meet on the model (the first picked stays put).");
			else
				changed = true;
		}
		ImGui.SameLine();
		if (ImGui.Button("Unwrap (keeps pins)"))
		{
			MeshUV.Unwrap(mesh, faces);
			changed = true;
		}
		// The palette grid.
		ImGui.Checkbox("Palette grid", ref mUVPalette);
		if (mUVPalette)
		{
			ImGui.SameLine();
			ImGui.SetNextItemWidth(70);
			ImGui.DragInt("##palcols", ref mUVPaletteColumns, 0.1f, 1, 64);
			ImGui.SameLine();
			ImGui.Text("x");
			ImGui.SameLine();
			ImGui.SetNextItemWidth(70);
			ImGui.DragInt("##palrows", ref mUVPaletteRows, 0.1f, 1, 64);
			ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			ImGui.SliderFloat("##cellfill", ref mUVCellFill, 0, 0.9f, "fill %.2f");
		}
		ImGui.SameLine();
		if (ImGui.Button("New Palette Texture"))
			MakeModelPalette(model);
		let available = ImGui.GetContentRegionAvail();
		let side = Math.Max(Math.Min(available.x, available.y - 22) - 4, 64);
		let corner = ImGui.GetCursorScreenPos();
		ImGui.InvisibleButton("##uvcanvas", .(available.x, side));
		let hovered = ImGui.IsItemHovered();
		let extent = side * mUVZoom;
		let topLeft = ImGui.Vec2(corner.x + (available.x - extent) * 0.5f, corner.y + (side - extent) * 0.5f);
		ImGui.PushClipRect(corner, .(corner.x + available.x, corner.y + side));
		ImGui.DrawRectFilled(corner, .(corner.x + available.x, corner.y + side), .(0.1f, 0.1f, 0.12f, 1));
		// The picture behind: the renderer's material's texture, or its own.
		let texturePath = ModelTexturePath(model, .. scope .());
		if (!texturePath.IsEmpty)
		{
			let texture = Assets.GetTexture(texturePath);
			if (texture.idx != uint16.MaxValue)
				ImGui.DrawImage(texture.idx, topLeft, .(topLeft.x + extent, topLeft.y + extent));
		}
		else
		{
			// A checker, to see stretching.
			let cells = 8;
			for (int y < cells)
			{
				for (int x < cells)
				{
					let shade = ((x + y) % 2 == 0) ? 0.32f : 0.24f;
					let a = ImGui.Vec2(topLeft.x + extent * x / cells, topLeft.y + extent * y / cells);
					ImGui.DrawRectFilled(a, .(a.x + extent / cells, a.y + extent / cells), .(shade, shade, shade + 0.03f, 1));
				}
			}
		}
		ImGui.DrawRect(topLeft, .(topLeft.x + extent, topLeft.y + extent), .(1, 1, 1, 0.5f));
		ImGui.Vec2 ToScreen(Vector2 uv) => .(topLeft.x + uv.x * extent, topLeft.y + uv.y * extent);
		Vector2 ToUV(ImGui.Vec2 p) => .((p.x - topLeft.x) / extent, (p.y - topLeft.y) / extent);
		if (mUVPalette)
		{
			let gridColor = Color(1, 1, 1, 0.25f);
			for (int32 c = 1; c < mUVPaletteColumns; c++)
			{
				let x = topLeft.x + extent * c / mUVPaletteColumns;
				ImGui.DrawLine(.(x, topLeft.y), .(x, topLeft.y + extent), gridColor, 1);
			}
			for (int32 r = 1; r < mUVPaletteRows; r++)
			{
				let y = topLeft.y + extent * r / mUVPaletteRows;
				ImGui.DrawLine(.(topLeft.x, y), .(topLeft.x + extent, y), gridColor, 1);
			}
		}
		let pickedFaces = scope HashSet<int32>();
		for (let key in mUVPicked)
			pickedFaces.Add((int32)(key >> 32));
		for (let i in faces)
		{
			let face = mesh.faces[i];
			let picked = pickedFaces.Contains(i);
			let color = picked ? Color(1, 0.62f, 0.15f, 1) : (selectedOnly ? Color(1, 0.8f, 0.55f, 0.8f) : Color(0.85f, 0.9f, 1, 0.8f));
			for (int k < face.Count)
				ImGui.DrawLine(ToScreen(face.uvs[k]), ToScreen(face.uvs[(k + 1) % face.Count]), color, picked ? 1.8f : 1.2f);
		}
		// Picked points, and pins.
		for (let key in mUVPicked)
		{
			let face = mesh.faces[(int32)(key >> 32)];
			ImGui.DrawCircleFilled(ToScreen(face.uvs[(int)(key & 0xFFFFFFFF)]), 2.5f, .(1, 0.75f, 0.3f, 1));
		}
		if (!mesh.pins.IsEmpty)
		{
			for (let i in faces)
			{
				let face = mesh.faces[i];
				for (int k < face.Count)
				{
					if (!mesh.pins.Contains(face.verts[k]))
						continue;
					let p = ToScreen(face.uvs[k]);
					ImGui.DrawRectFilled(.(p.x - 3, p.y - 3), .(p.x + 3, p.y + 3), .(0.95f, 0.2f, 0.2f, 1));
				}
			}
		}
		// What is under the pointer: a point within a few pixels, else a face.
		let mouse = ImGui.GetMousePos();
		int32 hitFace = -1, hitCorner = -1;
		if (hovered)
		{
			var best = 7.0f * 7.0f;
			for (let i in faces)
			{
				let face = mesh.faces[i];
				for (int32 k < (int32)face.Count)
				{
					let p = ToScreen(face.uvs[k]);
					let d = (p.x - mouse.x) * (p.x - mouse.x) + (p.y - mouse.y) * (p.y - mouse.y);
					if (d < best)
					{
						best = d;
						hitFace = i;
						hitCorner = k;
					}
				}
			}
			if (hitFace < 0)
				hitFace = UVFaceAt(mesh, faces, ToUV(mouse));
		}
		let ctrl = ImGui.IsKeyDown(ImGui.Key.LeftCtrl);
		let shift = ImGui.IsKeyDown(ImGui.Key.LeftShift);
		ImGui.PopClipRect();
		if (hovered && ImGui.IsMouseClicked(0))
		{
			if (mUVPalette && ctrl)
			{
				// Into the cell under the pointer: the picked pieces, or the faces shown.
				MeshUV.CellAt(ToUV(mouse), mUVPaletteColumns, mUVPaletteRows, let column, let row);
				let into = scope List<int32>();
				if (pickedFaces.IsEmpty)
					into.AddRange(faces);
				else
				{
					for (let f in pickedFaces)
						into.Add(f);
				}
				MeshUV.ToCell(mesh, into, column, row, mUVPaletteColumns, mUVPaletteRows, mUVCellFill);
				changed = true;
			}
			else if (hitFace >= 0)
			{
				let key = UVKey(hitFace, Math.Max(hitCorner, 0));
				let alreadyPicked = mUVPoints ? mUVPicked.Contains(key) : pickedFaces.Contains(hitFace);
				if (shift)
					PickUV(mesh, faces, hitFace, hitCorner, true, true);
				else if (!alreadyPicked)
					PickUV(mesh, faces, hitFace, hitCorner, false, false);
				// Dragging moves what is picked.
				if (!mUVPicked.IsEmpty && (alreadyPicked || !shift))
				{
					mUVDragging = true;
					mUVDragLast = mouse;
				}
			}
			else
			{
				if (!shift)
					mUVPicked.Clear();
				mUVBoxing = true;
				mUVBoxFrom = mouse;
			}
		}
		if (mUVBoxing)
		{
			ImGui.DrawRect(.(Math.Min(mUVBoxFrom.x, mouse.x), Math.Min(mUVBoxFrom.y, mouse.y)), .(Math.Max(mUVBoxFrom.x, mouse.x), Math.Max(mUVBoxFrom.y, mouse.y)), .(1, 1, 1, 0.8f));
			if (!ImGui.IsMouseDown(0))
			{
				mUVBoxing = false;
				let a = ToUV(mUVBoxFrom), b = ToUV(mouse);
				let min = Vector2(Math.Min(a.x, b.x), Math.Min(a.y, b.y)), max = Vector2(Math.Max(a.x, b.x), Math.Max(a.y, b.y));
				for (let i in faces)
				{
					let face = mesh.faces[i];
					for (int32 k < (int32)face.Count)
					{
						let uv = face.uvs[k];
						if (uv.x < min.x || uv.x > max.x || uv.y < min.y || uv.y > max.y)
							continue;
						if (mUVPoints)
							mUVPicked.Add(UVKey(i, k));
						else if (!pickedFaces.Contains(i))
						{
							PickUV(mesh, faces, i, -1, true, false);
							pickedFaces.Add(i);
						}
						if (mUVFirstFace < 0)
							mUVFirstFace = i;
					}
				}
			}
		}
		if (mUVDragging)
		{
			let delta = Vector2((mouse.x - mUVDragLast.x) / extent, (mouse.y - mUVDragLast.y) / extent);
			mUVDragLast = mouse;
			if (delta.x != 0 || delta.y != 0)
			{
				for (let key in mUVPicked)
				{
					let face = mesh.faces[(int32)(key >> 32)];
					face.uvMode = .Manual;
					let c = (int)(key & 0xFFFFFFFF);
					face.uvs[c] = face.uvs[c] + delta;
				}
				model.Preview();
			}
			if (!ImGui.IsMouseDown(0))
			{
				mUVDragging = false;
				changed = true;
			}
		}
		if (changed)
			CommitModel(model);
		let pinCount = mesh.pins.Count;
		ImGui.TextDisabled(scope $"Overlap {MeshUV.Overlap(mesh, faces, 64) * 100:0}%   Stretch {MeshUV.Stretch(mesh, faces):0.00}x   {pickedFaces.Count} picked   {pinCount} pinned   (Shift: add, drag: move or box{(mUVPalette ? ", Ctrl+click: into a cell" : "")})" .CStr());
	}

	/// The shown face whose part of the picture holds a point, or -1.
	static int32 UVFaceAt(EditMesh mesh, List<int32> faces, Vector2 uv)
	{
		let corners = scope List<int32>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int t = 0; t + 2 < corners.Count; t += 3)
			{
				let a = face.uvs[corners[t]], b = face.uvs[corners[t + 1]], c = face.uvs[corners[t + 2]];
				let d1 = (uv.x - b.x) * (a.y - b.y) - (a.x - b.x) * (uv.y - b.y);
				let d2 = (uv.x - c.x) * (b.y - c.y) - (b.x - c.x) * (uv.y - c.y);
				let d3 = (uv.x - a.x) * (c.y - a.y) - (c.x - a.x) * (uv.y - a.y);
				let negative = d1 < 0 || d2 < 0 || d3 < 0;
				let positive = d1 > 0 || d2 > 0 || d3 > 0;
				if (!(negative && positive))
					return f;
			}
		}
		return -1;
	}

	/// Writes a palette picture of 64 colours for the model (eight hues and greys in eight shades), gives the model
	/// it, and turns the palette grid on.
	void MakeModelPalette(ModelMesh model)
	{
		let colors = scope Color[64];
		for (int row < 8)
		{
			for (int column < 8)
			{
				let shade = 0.18f + row * 0.11f;
				Color color;
				if (column == 7)
					color = .(shade, shade, shade, 1);
				else
				{
					let hue = column / 7.0f;
					color = Color.FromHSV(hue, row < 4 ? 0.75f : 0.75f - (row - 4) * 0.15f, Math.Min(shade + 0.1f, 1));
				}
				colors[row * 8 + column] = color;
			}
		}
		let name = scope String(model.GameObject.Name);
		for (var c in ref name.RawChars)
		{
			if (!c.IsLetterOrDigit && c != '_' && c != '-')
				c = '_';
		}
		let path = scope $"Textures/{name}_palette.png";
		if (!TexturePaint.WritePalette(path, colors, 8, 8, 16))
		{
			Log.Error(scope $"Could not write {path}.");
			return;
		}
		Assets.Forget(path);
		if (SetModelTexture(model, path))
			Log.Info(scope $"Made {path}. Pick faces, then Ctrl+click a colour in the UV Editor.");
		mUVPalette = true;
		mUVPaletteColumns = 8;
		mUVPaletteRows = 8;
	}
}
