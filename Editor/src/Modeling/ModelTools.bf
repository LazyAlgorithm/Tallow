using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// The modeller's tools that follow the pointer (docs/modeling.md): grab, rotate and scale (G, R, S), extrude (E),
/// inset (I), bevel (Ctrl+B), loop cut and slide (Ctrl+R) and the knife (K). Each starts from the model as it was
/// and is worked out again as the pointer moves, so Escape or a right-click puts it back; a click or Enter keeps it.
/// X, Y and Z hold a move to an axis (Shift+X to the plane across it, again for the model's own axes), and a number
/// typed gives the amount exactly. Moves also follow proportional editing (O) and live mirroring.
extension EditorApp
{
	enum ModelTool
	{
		None,
		Grab,
		Rotate,
		Scale,
		Extrude,
		Inset,
		Bevel,
		LoopCut,
		Knife,
		Slide,
		VertexSlide
	}

	ModelTool mModelTool;
	/// The model as the tool started, to work from again each frame and to go back to.
	EditMesh mModelToolStart = new .() ~ delete _;
	HashSet<int32> mModelToolVerts = new .() ~ delete _;
	HashSet<uint64> mModelToolEdges = new .() ~ delete _;
	HashSet<int32> mModelToolFaces = new .() ~ delete _;
	List<uint64> mModelBevelEdges = new .() ~ delete _;
	/// Bevel segments: more than one rounds the cut (the wheel changes it while bevelling).
	int32 mModelBevelSegments = 1;
	// Sliding: edges along their rails, or each vertex along the edge nearest the pointer's way.
	List<SlideRail> mModelSlideRails = new .() ~ delete _;
	List<(int32 vertex, Vector3 start, List<int32> neighbours)> mModelVertexSlides = new .() ~ { for (let entry in _) delete entry.neighbours; delete _; };
	ImGui.Vec2 mModelToolMouse;
	Vector3 mModelToolPivot;
	Vector3 mModelToolNormal;
	int32 mModelAxis = -1;
	bool mModelAxisPlane;
	bool mModelAxisLocal;
	String mModelTyped = new .() ~ delete _;
	float mModelToolAmount;
	bool mModelToolEach;
	/// Saved even when cancelled: the tool followed a change that stays (copies being moved).
	bool mModelToolKeep;
	float mModelTurnLast;
	float mModelTurnTotal;
	/// The frame the tool started on: its own key is still down then, so "the key again" waits for a later frame.
	int64 mModelToolFrame = -1;

	// Loop cut: the edge under the pointer, how many cuts, and sliding a single cut along.
	bool mModelLoopFound;
	uint64 mModelLoopEdge;
	int32 mModelLoopCuts = 1;
	bool mModelLoopSliding;
	float mModelLoopT = 0.5f;
	List<Vector3> mModelLoopPreview = new .() ~ delete _;

	// Knife: the points clicked (in the model's space) and where the next one would go.
	List<Vector3> mModelKnifePoints = new .() ~ delete _;
	bool mModelKnifeHit;
	Vector3 mModelKnifeHover;

	// Proportional editing (unpicked vertices nearby follow, less the further they are) and live mirroring.
	bool mModelProportional;
	float mModelPropRadius = 1;
	bool[3] mModelSymmetry;
	Dictionary<int32, float> mModelDragWeight = new .() ~ delete _;
	Dictionary<int32, (int32 source, int32 axis)> mModelMirrorOf = new .() ~ delete _;
	Dictionary<int32, int32> mModelOnMirror = new .() ~ delete _;

	bool ModelToolActive => mModelTool != .None;

	/// The wheel sets the number of loop cuts, or the proportional radius, instead of moving the camera.
	bool ModelOwnsWheel => mModelTool == .LoopCut || mModelTool == .Bevel || (mModelProportional && (mModelTool == .Grab || mModelTool == .Rotate || mModelTool == .Scale));

	Vector3 ModelViewForward => Quaternion.Euler(mCamPitch, mCamYaw, 0) * Vector3.Forward;

	/// How far one pixel of the Scene view is at a point, in metres.
	float ModelWorldPerPixel(Vector3 point) => mSceneCamera.orthographic ? 2 * mSceneCamera.orthographicSize / Math.Max(mSceneSize.y, 1)
		: (point - mCamPosition).Length * 2 * Math.Tan(30 * Mathf.Deg2Rad) / Math.Max(mSceneSize.y, 1);

	/// Model units in a metre (the inverse of the object's average scale).
	static float ModelLocalPerWorld(ModelMesh model)
	{
		let m = model.Transform.LocalToWorld;
		let scale = (Vector3(m.m[0], m.m[1], m.m[2]).Length + Vector3(m.m[4], m.m[5], m.m[6]).Length + Vector3(m.m[8], m.m[9], m.m[10]).Length) / 3;
		return scale > 1.0e-6f ? 1 / scale : 1;
	}

	Vector3 ModelAxisVector(ModelMesh model, int axis)
	{
		let direction = axis == 0 ? Vector3.Right : (axis == 1 ? Vector3.Up : Vector3.Forward);
		return mModelAxisLocal ? (model.Transform.Rotation * direction).Normalized : direction;
	}

	static void SetComponent(ref Vector3 v, int axis, float value)
	{
		if (axis == 0)
			v.x = value;
		else if (axis == 1)
			v.y = value;
		else
			v.z = value;
	}

	static bool RayPlane(Ray ray, Vector3 point, Vector3 normal, out Vector3 hit)
	{
		hit = .Zero;
		let denominator = Vector3.Dot(ray.direction, normal);
		if (Math.Abs(denominator) < 1.0e-6f)
			return false;
		hit = ray.GetPoint(Vector3.Dot(point - ray.origin, normal) / denominator);
		return true;
	}

	/// How far along a line (through `point`, unit `axis`) the place nearest a ray is.
	static float RayLineParam(Ray ray, Vector3 point, Vector3 axis)
	{
		let w = point - ray.origin;
		let b = Vector3.Dot(axis, ray.direction);
		let d = Vector3.Dot(axis, w);
		let e = Vector3.Dot(ray.direction, w);
		let denominator = 1 - b * b;
		if (Math.Abs(denominator) < 1.0e-6f)
			return 0;
		return (b * e - d) / denominator;
	}

	// ------------------------------------------------------------------ moving vertices

	/// Records where the vertices to move start (in the world), the vertices proportional editing moves with them
	/// (with how much), and the vertices mirroring them.
	void BeginModelMove(EditMesh mesh, Matrix4 world, HashSet<int32> verts)
	{
		mModelDragFrom.Clear();
		mModelDragWeight.Clear();
		mModelMirrorOf.Clear();
		mModelOnMirror.Clear();
		for (let v in verts)
		{
			mModelDragFrom[v] = world.TransformPoint(mesh.positions[v]);
			mModelDragWeight[v] = 1;
		}
		if (mModelProportional && mModelPropRadius > 0)
		{
			let picked = scope List<Vector3>();
			for (let p in mModelDragFrom.Values)
				picked.Add(p);
			for (int32 v < (int32)mesh.positions.Count)
			{
				if (verts.Contains(v) || !ModelVertShown(v))
					continue;
				let p = world.TransformPoint(mesh.positions[v]);
				var nearest = float.MaxValue;
				for (let s in picked)
					nearest = Math.Min(nearest, (p - s).LengthSquared);
				let distance = Math.Sqrt(nearest);
				if (distance >= mModelPropRadius)
					continue;
				let t = 1 - distance / mModelPropRadius;
				mModelDragFrom[v] = p;
				mModelDragWeight[v] = t * t * (3 - 2 * t);
			}
		}
		if (!mModelSymmetry[0] && !mModelSymmetry[1] && !mModelSymmetry[2])
			return;
		let tolerance = Math.Max(mesh.Bounds.Extents.Length * 1.0e-4f, 1.0e-5f);
		for (int32 axis < 3)
		{
			if (!mModelSymmetry[axis])
				continue;
			for (let v in mModelDragFrom.Keys)
			{
				let p = mesh.positions[v];
				// On the mirror: it stays on it.
				if (Math.Abs(MeshOps.Component(p, axis)) <= tolerance)
				{
					mModelOnMirror[v] = (mModelOnMirror.TryGetValue(v, let mask) ? mask : 0) | (1 << axis);
					continue;
				}
				var mirrored = p;
				SetComponent(ref mirrored, axis, -MeshOps.Component(p, axis));
				for (int32 w < (int32)mesh.positions.Count)
				{
					if (w != v && !mModelDragFrom.ContainsKey(w) && (mesh.positions[w] - mirrored).LengthSquared <= tolerance * tolerance)
					{
						mModelMirrorOf[w] = (v, axis);
						break;
					}
				}
			}
		}
	}

	/// Moves the recorded vertices by a change made in the world, and their mirror images, and redraws the model.
	void ApplyModelMove(ModelMesh model, EditMesh mesh, Matrix4 delta)
	{
		let toLocal = model.Transform.WorldToLocal;
		for (let pair in mModelDragFrom)
		{
			var moved = delta.TransformPoint(pair.value);
			let weight = mModelDragWeight.TryGetValue(pair.key, let w) ? w : 1;
			if (weight < 1)
				moved = Vector3.Lerp(pair.value, moved, weight);
			var local = toLocal.TransformPoint(moved);
			if (mModelOnMirror.TryGetValue(pair.key, let mask))
			{
				for (int axis < 3)
				{
					if ((mask & (1 << axis)) != 0)
						SetComponent(ref local, axis, 0);
				}
			}
			mesh.positions[pair.key] = local;
		}
		for (let pair in mModelMirrorOf)
		{
			var p = mesh.positions[pair.value.source];
			SetComponent(ref p, pair.value.axis, -MeshOps.Component(p, pair.value.axis));
			mesh.positions[pair.key] = p;
		}
		model.Preview();
	}

	// ------------------------------------------------------------------ starting and ending

	/// Starts a tool on the selection, from where the pointer is now.
	void StartModelTool(ModelMesh model, EditMesh mesh, ModelTool tool, bool each = false)
	{
		var tool;
		if (tool == .Slide && mModelMode == .Vertex)
			tool = .VertexSlide;
		if (tool != .LoopCut && tool != .Knife && !ModelHasSelection)
		{
			Log.Warning("Pick some vertices, edges or faces first.");
			return;
		}
		if (tool == .Inset && mModelMode != .Face)
		{
			Log.Warning("Inset works on faces (3).");
			return;
		}
		// Extruding vertices extrudes the edges between them.
		if (tool == .Extrude && mModelMode == .Vertex)
		{
			SetModelMode(.Edge, mesh);
			if (mModelEdges.IsEmpty)
			{
				Log.Warning("Extrude needs faces, or edges (two picked vertices next to each other).");
				return;
			}
		}
		let world = model.Transform.LocalToWorld;
		mModelTool = tool;
		mModelToolStart.CopyFrom(mesh);
		CopySet(mModelVerts, mModelToolVerts);
		CopySet(mModelEdges, mModelToolEdges);
		CopySet(mModelFaces, mModelToolFaces);
		mModelToolMouse = ImGui.GetMousePos();
		mModelToolFrame = Time.FrameCount;
		mModelAxis = -1;
		mModelAxisPlane = false;
		mModelAxisLocal = false;
		mModelTyped.Clear();
		mModelToolAmount = 0;
		mModelToolEach = each;
		mModelToolKeep = false;
		mModelTurnLast = 0;
		mModelTurnTotal = 0;
		mModelLoopFound = false;
		mModelLoopSliding = false;
		mModelLoopT = 0.5f;
		mModelKnifePoints.Clear();
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		var center = Vector3.Zero;
		for (let v in verts)
			center = center + mesh.positions[v];
		mModelToolPivot = world.TransformPoint(verts.IsEmpty ? Vector3.Zero : center / verts.Count);
		switch (tool)
		{
		case .Grab,.Rotate,.Scale:
			BeginModelMove(mesh, world, verts);
			// Turning starts from where the pointer is round the middle.
			mModelTurnLast = 0;
		case .Extrude:
			var normal = Vector3.Zero;
			for (let f in mModelFaces)
				normal = normal + mesh.FaceNormal(mesh.faces[f]) * mesh.FaceArea(mesh.faces[f]);
			normal = world.TransformDirection(normal);
			mModelToolNormal = normal.LengthSquared > 1.0e-12f ? normal.Normalized : -ModelViewForward;
		case .Slide:
			let edges = scope List<uint64>();
			ModelSlideEdges(mesh, edges);
			MeshOps.EdgeSlideRails(mesh, edges, mModelSlideRails);
			if (mModelSlideRails.IsEmpty)
			{
				Log.Warning("Nothing to slide along: pick edges with faces beside them.");
				mModelTool = .None;
			}
		case .VertexSlide:
			ClearVertexSlides();
			for (let v in verts)
			{
				let neighbours = new List<int32>();
				MeshOps.Neighbours(mesh, v, neighbours);
				neighbours.RemoveAll(scope (n) => verts.Contains(n));
				mModelVertexSlides.Add((v, mesh.positions[v], neighbours));
			}
		case .Bevel:
			mModelBevelEdges.Clear();
			let all = scope List<uint64>();
			mesh.Edges(all);
			for (let e in all)
			{
				EditMesh.EdgeEnds(e, let a, let b);
				bool take;
				switch (mModelMode)
				{
				case .Edge: take = mModelEdges.Contains(e);
				default: take = verts.Contains(a) && verts.Contains(b);
				}
				if (take)
					mModelBevelEdges.Add(e);
			}
		default:
		}
	}

	void ClearVertexSlides()
	{
		for (let entry in mModelVertexSlides)
			delete entry.neighbours;
		mModelVertexSlides.Clear();
	}

	/// The edges an edge slide moves: the picked edges, or the edges round the picked faces.
	void ModelSlideEdges(EditMesh mesh, List<uint64> into)
	{
		if (mModelMode == .Edge)
		{
			for (let e in mModelEdges)
				into.Add(e);
			return;
		}
		// Faces: their outline (edges with only one picked face beside them).
		let count = scope Dictionary<uint64, int32>();
		for (let f in mModelFaces)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let key = EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
				if (count.TryGetValue(key, let n))
					count[key] = n + 1;
				else
					count[key] = 1;
			}
		}
		for (let pair in count)
		{
			if (pair.value == 1)
				into.Add(pair.key);
		}
	}

	static void CopySet<T>(HashSet<T> from, HashSet<T> to) where T : IHashable
	{
		to.Clear();
		for (let item in from)
			to.Add(item);
	}

	void FinishModelTool(ModelMesh model, EditMesh mesh)
	{
		mModelTool = .None;
		mModelTyped.Clear();
		ValidateModelSelection(mesh);
		CommitModel(model);
	}

	/// Puts the model back as it was when the tool started.
	void CancelModelTool(ModelMesh model, EditMesh mesh)
	{
		mModelTool = .None;
		mModelTyped.Clear();
		mesh.CopyFrom(mModelToolStart);
		CopySet(mModelToolVerts, mModelVerts);
		CopySet(mModelToolEdges, mModelEdges);
		CopySet(mModelToolFaces, mModelFaces);
		if (mModelToolKeep)
			CommitModel(model);
		else
			RefreshModel(model, mesh);
	}

	/// Draws the model as saved (keeping hidden faces hidden), without a new undo step.
	void RefreshModel(ModelMesh model, EditMesh mesh)
	{
		model.Save();
		if (mesh.AnyHidden)
			model.Preview();
	}

	// ------------------------------------------------------------------ each frame

	void UpdateModelTool(ModelMesh model, EditMesh mesh, Matrix4 world, Matrix4 toLocal)
	{
		let mouse = ImGui.GetMousePos();
		let cancel = ImGui.IsKeyPressed(ImGui.Key.Escape) || (mSceneHovered && ImGui.IsMouseClicked(1));
		let confirm = ImGui.IsKeyPressed(ImGui.Key.Enter) || ImGui.IsKeyPressed(ImGui.Key.KeypadEnter);
		switch (mModelTool)
		{
		case .LoopCut:
			UpdateLoopCut(model, mesh, world, toLocal, mouse, cancel, confirm);
			return;
		case .Knife:
			UpdateKnife(model, mesh, world, toLocal, mouse, cancel, confirm || ImGui.IsKeyPressed(ImGui.Key.Space));
			return;
		default:
		}
		if (cancel)
		{
			CancelModelTool(model, mesh);
			return;
		}
		ReadModelToolKeys(model, mesh, world);
		ApplyModelTool(model, mesh, toLocal, mouse);
		if (confirm || (mSceneHovered && ImGui.IsMouseClicked(0)))
			FinishModelTool(model, mesh);
	}

	void ReadModelToolKeys(ModelMesh model, EditMesh mesh, Matrix4 world)
	{
		let tool = mModelTool;
		let moving = tool == .Grab || tool == .Rotate || tool == .Scale;
		let again = Time.FrameCount != mModelToolFrame;
		if (moving || (tool == .Extrude && mModelMode == .Edge))
		{
			let shift = ImGui.IsKeyDown(ImGui.Key.LeftShift);
			for (int32 axis < 3)
			{
				if (!ImGui.IsKeyPressed(ImGui.Key.X + axis))
					continue;
				// The same axis again: the model's own axis, then free again.
				if (mModelAxis == axis && mModelAxisPlane == shift)
				{
					if (!mModelAxisLocal)
						mModelAxisLocal = true;
					else
					{
						mModelAxis = -1;
						mModelAxisLocal = false;
					}
				}
				else
				{
					mModelAxis = axis;
					mModelAxisPlane = shift && tool != .Rotate;
					mModelAxisLocal = false;
				}
			}
		}
		// G again while grabbing slides instead (edges along their faces, vertices along their edges).
		if (again && tool == .Grab && ImGui.IsKeyPressed(ImGui.Key.G) && !ImGui.IsKeyDown(ImGui.Key.LeftShift))
		{
			mesh.CopyFrom(mModelToolStart);
			StartModelTool(model, mesh, mModelMode == .Vertex ? .VertexSlide : .Slide);
			return;
		}
		if (tool == .Bevel)
		{
			let wheel = Input.MouseWheel;
			if (wheel != 0)
				mModelBevelSegments = (int32)Math.Clamp(mModelBevelSegments + Math.Sign(wheel), 1, 32);
		}
		if (again && ((tool == .Inset && ImGui.IsKeyPressed(ImGui.Key.I)) || (tool == .Extrude && mModelMode == .Face && ImGui.IsKeyPressed(ImGui.Key.E))))
			mModelToolEach = !mModelToolEach;
		if (moving)
		{
			var restart = false;
			if (ImGui.IsKeyPressed(ImGui.Key.O))
			{
				mModelProportional = !mModelProportional;
				restart = true;
			}
			let wheel = Input.MouseWheel;
			if (mModelProportional && wheel != 0)
			{
				mModelPropRadius = Math.Clamp(mModelPropRadius * Math.Pow(1.15f, wheel), 0.01f, 1000);
				restart = true;
			}
			if (restart)
			{
				// The falloff is worked out from where everything started.
				mesh.CopyFrom(mModelToolStart);
				let verts = scope HashSet<int32>();
				ModelSelectedVerts(mesh, verts);
				BeginModelMove(mesh, world, verts);
			}
		}
		ModelTypeNumber();
	}

	/// Digits, a point, minus (turns the sign) and backspace typed while a tool runs.
	void ModelTypeNumber()
	{
		for (int32 k < 10)
		{
			if (ImGui.IsKeyPressed(ImGui.Key.Zero + k) || ImGui.IsKeyPressed(ImGui.Key.Keypad0 + k))
				mModelTyped.Append((char8)('0' + k));
		}
		if ((ImGui.IsKeyPressed(ImGui.Key.Period) || ImGui.IsKeyPressed(ImGui.Key.KeypadDecimal)) && !mModelTyped.Contains('.'))
			mModelTyped.Append('.');
		if (ImGui.IsKeyPressed(ImGui.Key.Minus) || ImGui.IsKeyPressed(ImGui.Key.KeypadSubtract))
		{
			if (mModelTyped.StartsWith('-'))
				mModelTyped.Remove(0, 1);
			else
				mModelTyped.Insert(0, '-');
		}
		if (ImGui.IsKeyPressed(ImGui.Key.Backspace, true) && !mModelTyped.IsEmpty)
			mModelTyped.RemoveFromEnd(1);
	}

	bool ModelTypedValue(out float value)
	{
		value = 0;
		if (mModelTyped.IsEmpty || mModelTyped == "-" || mModelTyped == "." || mModelTyped == "-.")
			return false;
		if (float.Parse(mModelTyped) case .Ok(let parsed))
		{
			value = parsed;
			return true;
		}
		return false;
	}

	/// How far the pointer has moved things, in the world: along the axis held, across the plane held, or in the
	/// plane facing the camera.
	Vector3 ModelGrabOffset(ModelMesh model, ImGui.Vec2 mouse, bool hasTyped, float typed)
	{
		let start = ModelMouseRay(mModelToolMouse);
		let now = ModelMouseRay(mouse);
		let pivot = mModelToolPivot;
		if (mModelAxis >= 0 && !mModelAxisPlane)
		{
			let axis = ModelAxisVector(model, mModelAxis);
			var along = hasTyped ? typed : RayLineParam(now, pivot, axis) - RayLineParam(start, pivot, axis);
			if (!hasTyped && SnapActive)
				along = SnapValue(along, mSnapMove);
			return axis * along;
		}
		if (hasTyped)
			return ModelAxisVector(model, mModelAxis == 0 ? 1 : 0) * typed;
		let normal = mModelAxis >= 0 ? ModelAxisVector(model, mModelAxis) : ModelViewForward;
		if (!RayPlane(start, pivot, normal, let a))
			return .Zero;
		if (!RayPlane(now, pivot, normal, let b))
			return .Zero;
		var offset = b - a;
		if (SnapActive)
			offset = .(SnapValue(offset.x, mSnapMove), SnapValue(offset.y, mSnapMove), SnapValue(offset.z, mSnapMove));
		return offset;
	}

	/// The turn in degrees the pointer has made round the middle of the selection, seen from the camera, added up
	/// so it can go past half a turn.
	float ModelTurnDegrees(ImGui.Vec2 mouse)
	{
		let forward = ModelViewForward;
		let pivot = mModelToolPivot;
		if (!RayPlane(ModelMouseRay(mModelToolMouse), pivot, forward, let a))
			return mModelTurnTotal;
		if (!RayPlane(ModelMouseRay(mouse), pivot, forward, let b))
			return mModelTurnTotal;
		let v0 = a - pivot, v1 = b - pivot;
		if (v0.LengthSquared < 1.0e-12f || v1.LengthSquared < 1.0e-12f)
			return mModelTurnTotal;
		let raw = Math.Atan2(Vector3.Dot(forward, Vector3.Cross(v0, v1)), Vector3.Dot(v0, v1)) * Mathf.Rad2Deg;
		var step = raw - mModelTurnLast;
		while (step > 180)
			step -= 360;
		while (step < -180)
			step += 360;
		mModelTurnTotal += step;
		mModelTurnLast = raw;
		return mModelTurnTotal;
	}

	/// The pointer's distance from the middle of the selection on screen, in pixels.
	float ModelPointerReach(ImGui.Vec2 mouse)
	{
		if (!SceneToScreen(mModelToolPivot, mSceneOrigin, mSceneSize, let center))
			return 0;
		return Math.Sqrt((mouse.x - center.x) * (mouse.x - center.x) + (mouse.y - center.y) * (mouse.y - center.y));
	}

	/// A scale by `factor` round a point: along one axis, across the plane of the other two, or all ways.
	static Matrix4 ScaleAbout(Vector3 pivot, float factor, Vector3? axis, bool plane)
	{
		var s = Matrix4.Identity;
		for (int c < 3)
		{
			for (int r < 3)
			{
				let identity = r == c ? 1.0f : 0.0f;
				float amount;
				if (!axis.HasValue)
					amount = identity;
				else
				{
					let a = axis.Value;
					let outer = MeshOps.Component(a, r) * MeshOps.Component(a, c);
					amount = plane ? identity - outer : outer;
				}
				s.m[c * 4 + r] = identity + (factor - 1) * amount;
			}
		}
		return Matrix4.Translate(pivot) * s * Matrix4.Translate(-pivot);
	}

	void ApplyModelTool(ModelMesh model, EditMesh mesh, Matrix4 toLocal, ImGui.Vec2 mouse)
	{
		let hasTyped = ModelTypedValue(let typed);
		let pivot = mModelToolPivot;
		switch (mModelTool)
		{
		case .Grab:
			let offset = ModelGrabOffset(model, mouse, hasTyped, typed);
			mModelToolAmount = offset.Length;
			ApplyModelMove(model, mesh, Matrix4.Translate(offset));
		case .Rotate:
			var degrees = ModelTurnDegrees(mouse);
			let forward = ModelViewForward;
			var axis = forward;
			if (mModelAxis >= 0)
			{
				axis = ModelAxisVector(model, mModelAxis);
				if (Vector3.Dot(axis, forward) < 0)
					degrees = -degrees;
			}
			if (hasTyped)
				degrees = typed;
			else if (SnapActive)
				degrees = SnapValue(degrees, mSnapRotate);
			mModelToolAmount = degrees;
			ApplyModelMove(model, mesh, Matrix4.Translate(pivot) * Matrix4.Rotation(Quaternion.AngleAxis(degrees, axis)) * Matrix4.Translate(-pivot));
		case .Scale:
			var factor = ModelPointerReach(mouse) / Math.Max(ModelPointerReach(mModelToolMouse), 1);
			if (hasTyped)
				factor = typed;
			else if (SnapActive)
				factor = SnapValue(factor, mSnapScale);
			mModelToolAmount = factor;
			Vector3? axis = null;
			if (mModelAxis >= 0)
				axis = ModelAxisVector(model, mModelAxis);
			ApplyModelMove(model, mesh, ScaleAbout(pivot, factor, axis, mModelAxisPlane));
		case .Extrude:
			mesh.CopyFrom(mModelToolStart);
			if (mModelMode == .Face)
			{
				let normal = mModelToolNormal;
				var distance = hasTyped ? typed : RayLineParam(ModelMouseRay(mouse), pivot, normal) - RayLineParam(ModelMouseRay(mModelToolMouse), pivot, normal);
				if (!hasTyped && SnapActive)
					distance = SnapValue(distance, mSnapMove);
				mModelToolAmount = distance;
				let faces = scope List<int32>();
				for (let f in mModelToolFaces)
					faces.Add(f);
				faces.Sort();
				MeshOps.ExtrudeFaces(mesh, faces, distance * toLocal.TransformDirection(normal).Length, mModelToolEach);
			}
			else
			{
				let offset = ModelGrabOffset(model, mouse, hasTyped, typed);
				mModelToolAmount = offset.Length;
				let edges = scope List<uint64>();
				for (let e in mModelToolEdges)
					edges.Add(e);
				let made = scope List<uint64>();
				MeshOps.ExtrudeEdges(mesh, edges, toLocal.TransformDirection(offset), null, made);
				if (!made.IsEmpty)
				{
					mModelEdges.Clear();
					for (let e in made)
						mModelEdges.Add(e);
				}
			}
			model.Preview();
		case .Slide:
			let world = model.Transform.LocalToWorld;
			// The way the left rails run on screen, on average.
			float dirX = 0, dirY = 0;
			int count = 0;
			for (let rail in mModelSlideRails)
			{
				let target = rail.hasLeft ? rail.left : rail.start * 2 - rail.right;
				if (SceneToScreen(world.TransformPoint(rail.start), mSceneOrigin, mSceneSize, let a) && SceneToScreen(world.TransformPoint(target), mSceneOrigin, mSceneSize, let b))
				{
					dirX += b.x - a.x;
					dirY += b.y - a.y;
					count++;
				}
			}
			var t = 0.0f;
			if (count > 0)
			{
				dirX /= count;
				dirY /= count;
				let length = dirX * dirX + dirY * dirY;
				if (length > 1)
					t = ((mouse.x - mModelToolMouse.x) * dirX + (mouse.y - mModelToolMouse.y) * dirY) / length;
			}
			if (hasTyped)
				t = typed;
			t = Math.Clamp(t, -1.0f, 1.0f);
			mModelToolAmount = t;
			MeshOps.ApplySlide(mesh, mModelSlideRails, t);
			model.Preview();
		case .VertexSlide:
			let world = model.Transform.LocalToWorld;
			let dx = mouse.x - mModelToolMouse.x, dy = mouse.y - mModelToolMouse.y;
			var shown = 0.0f;
			for (let entry in mModelVertexSlides)
			{
				if (entry.neighbours.IsEmpty)
					continue;
				if (!SceneToScreen(world.TransformPoint(entry.start), mSceneOrigin, mSceneSize, let from))
					continue;
				// The edge leaving the vertex most the way the pointer went.
				int32 best = entry.neighbours[0];
				var bestDot = -float.MaxValue;
				var bestX = 0.0f;
				var bestY = 0.0f;
				for (let n in entry.neighbours)
				{
					if (!SceneToScreen(world.TransformPoint(mModelToolStart.positions[n]), mSceneOrigin, mSceneSize, let to))
						continue;
					let ex = to.x - from.x, ey = to.y - from.y;
					let length = Math.Max(Math.Sqrt(ex * ex + ey * ey), 1.0e-3f);
					let dot = (ex * dx + ey * dy) / length;
					if (dot > bestDot)
					{
						best = n;
						bestDot = dot;
						bestX = ex;
						bestY = ey;
					}
				}
				let length = bestX * bestX + bestY * bestY;
				var t = length > 1 ? (dx * bestX + dy * bestY) / length : 0;
				if (hasTyped)
					t = typed;
				t = Math.Clamp(t, 0.0f, 1.0f);
				shown = t;
				mesh.positions[entry.vertex] = Vector3.Lerp(entry.start, mModelToolStart.positions[best], t);
			}
			mModelToolAmount = shown;
			model.Preview();
		case .Inset,.Bevel:
			var amount = Math.Abs(ModelPointerReach(mouse) - ModelPointerReach(mModelToolMouse)) * ModelWorldPerPixel(pivot);
			if (hasTyped)
				amount = Math.Abs(typed);
			else if (SnapActive)
				amount = SnapValue(amount, mSnapMove * 0.1f);
			mModelToolAmount = amount;
			let local = amount * ModelLocalPerWorld(model);
			mesh.CopyFrom(mModelToolStart);
			if (mModelTool == .Inset)
			{
				let faces = scope List<int32>();
				for (let f in mModelToolFaces)
					faces.Add(f);
				faces.Sort();
				if (local > 1.0e-5f)
					MeshOps.InsetFaces(mesh, faces, local, mModelToolEach);
			}
			else
			{
				ClearModelSelection();
				if (local > 1.0e-5f)
					MeshOps.Bevel(mesh, mModelBevelEdges, local, null, mModelBevelSegments);
			}
			model.Preview();
		default:
		}
	}

	// ------------------------------------------------------------------ loop cut

	void UpdateLoopCut(ModelMesh model, EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 mouse, bool cancel, bool confirm)
	{
		if (mModelLoopSliding)
		{
			ModelTypeNumber();
			EditMesh.EdgeEnds(mModelLoopEdge, let a, let b);
			let pa = world.TransformPoint(mModelToolStart.positions[a]), pb = world.TransformPoint(mModelToolStart.positions[b]);
			if (SceneToScreen(pa, mSceneOrigin, mSceneSize, let sa) && SceneToScreen(pb, mSceneOrigin, mSceneSize, let sb))
			{
				let dx = sb.x - sa.x, dy = sb.y - sa.y;
				let length = dx * dx + dy * dy;
				if (length > 1)
					mModelLoopT = Math.Clamp(((mouse.x - sa.x) * dx + (mouse.y - sa.y) * dy) / length, 0.02f, 0.98f);
			}
			if (ModelTypedValue(let typed))
				mModelLoopT = Math.Clamp(typed, 0.01f, 0.99f);
			// Escape or a right-click leaves the cut in the middle.
			if (cancel)
				mModelLoopT = 0.5f;
			mModelToolAmount = mModelLoopT;
			mesh.CopyFrom(mModelToolStart);
			let made = scope List<uint64>();
			MeshOps.LoopCut(mesh, mModelLoopEdge, 1, mModelLoopT, made);
			model.Preview();
			if (cancel || confirm || (mSceneHovered && ImGui.IsMouseClicked(0)))
			{
				mModelMode = .Edge;
				ClearModelSelection();
				for (let e in made)
					mModelEdges.Add(e);
				FinishModelTool(model, mesh);
			}
			return;
		}
		if (cancel)
		{
			mModelTool = .None;
			return;
		}
		let wheel = Input.MouseWheel;
		if (wheel != 0)
			mModelLoopCuts = (int32)Math.Clamp(mModelLoopCuts + Math.Sign(wheel), 1, 64);
		if (ImGui.IsKeyPressed(ImGui.Key.Equal, true) || ImGui.IsKeyPressed(ImGui.Key.KeypadAdd, true))
			mModelLoopCuts = Math.Min(mModelLoopCuts + 1, 64);
		if (ImGui.IsKeyPressed(ImGui.Key.Minus, true) || ImGui.IsKeyPressed(ImGui.Key.KeypadSubtract, true))
			mModelLoopCuts = Math.Max(mModelLoopCuts - 1, 1);
		let hit = mSceneHovered ? ModelElementAt(mesh, world, toLocal, mouse, .Edge) : -1;
		mModelLoopFound = hit >= 0;
		if (mModelLoopFound)
		{
			mModelLoopEdge = (uint64)hit;
			ModelLoopPreview(mesh, mModelLoopEdge, mModelLoopCuts);
		}
		else
			mModelLoopPreview.Clear();
		if (!mModelLoopFound || !mSceneHovered || !ImGui.IsMouseClicked(0))
			return;
		mModelToolStart.CopyFrom(mesh);
		CopySet(mModelVerts, mModelToolVerts);
		CopySet(mModelEdges, mModelToolEdges);
		CopySet(mModelFaces, mModelToolFaces);
		mModelLoopPreview.Clear();
		if (mModelLoopCuts == 1)
		{
			// One cut slides along the strip until the next click.
			mModelLoopSliding = true;
			mModelLoopT = 0.5f;
			mModelTyped.Clear();
			return;
		}
		let made = scope List<uint64>();
		MeshOps.LoopCut(mesh, mModelLoopEdge, mModelLoopCuts, 0.5f, made);
		mModelMode = .Edge;
		ClearModelSelection();
		for (let e in made)
			mModelEdges.Add(e);
		FinishModelTool(model, mesh);
	}

	/// The lines the loop cut through an edge would make, as pairs of points in the model's space.
	void ModelLoopPreview(EditMesh mesh, uint64 edge, int32 cuts)
	{
		mModelLoopPreview.Clear();
		let ring = scope List<uint64>();
		MeshOps.EdgeRing(mesh, edge, ring);
		let inRing = scope HashSet<uint64>();
		for (let e in ring)
			inRing.Add(e);
		for (let face in mesh.faces)
		{
			if (face.Count != 4 || face.hidden)
				continue;
			for (int i < 2)
			{
				let v0 = face.verts[i], v1 = face.verts[(i + 1) % 4], v2 = face.verts[(i + 2) % 4], v3 = face.verts[(i + 3) % 4];
				if (!inRing.Contains(EditMesh.EdgeKey(v0, v1)) || !inRing.Contains(EditMesh.EdgeKey(v2, v3)))
					continue;
				// Across the quad, v0 faces v3 and v1 faces v2.
				for (int k < cuts)
				{
					let f = (float)(k + 1) / (cuts + 1);
					mModelLoopPreview.Add(Vector3.Lerp(mesh.positions[v0], mesh.positions[v1], f));
					mModelLoopPreview.Add(Vector3.Lerp(mesh.positions[v3], mesh.positions[v2], f));
				}
			}
		}
	}

	// ------------------------------------------------------------------ knife

	void UpdateKnife(ModelMesh model, EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 mouse, bool cancel, bool confirm)
	{
		if (cancel)
		{
			mModelTool = .None;
			mModelKnifePoints.Clear();
			return;
		}
		if (ImGui.IsKeyPressed(ImGui.Key.Backspace, true) && !mModelKnifePoints.IsEmpty)
			mModelKnifePoints.PopBack();
		mModelKnifeHit = mSceneHovered && ModelKnifeSnap(mesh, world, toLocal, mouse, out mModelKnifeHover);
		if (mModelKnifeHit && ImGui.IsMouseClicked(0))
		{
			if (mModelKnifePoints.IsEmpty || (mModelKnifePoints.Back - mModelKnifeHover).LengthSquared > 1.0e-10f)
				mModelKnifePoints.Add(mModelKnifeHover);
		}
		if (!confirm)
			return;
		mModelTool = .None;
		if (mModelKnifePoints.Count < 2)
		{
			mModelKnifePoints.Clear();
			return;
		}
		let tolerance = Math.Max(mesh.Bounds.Extents.Length * 1.0e-4f, 1.0e-5f);
		let cuts = MeshOps.Knife(mesh, mModelKnifePoints, toLocal.TransformPoint(mCamPosition), tolerance);
		mModelKnifePoints.Clear();
		if (cuts == 0)
		{
			Log.Warning("The knife cut nothing: a cut has to start and end on edges or corners (points inside faces go between).");
			return;
		}
		ClearModelSelection();
		CommitModel(model);
	}

	/// Where a knife point would go: the corner under the pointer, the place on the edge under it, or the place on
	/// the face under it.
	bool ModelKnifeSnap(EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 mouse, out Vector3 point)
	{
		point = .Zero;
		let vertex = ModelElementAt(mesh, world, toLocal, mouse, .Vertex);
		if (vertex >= 0)
		{
			point = mesh.positions[(int32)vertex];
			return true;
		}
		let ray = ModelMouseRay(mouse);
		let localOrigin = toLocal.TransformPoint(ray.origin);
		let localRay = Ray(localOrigin, (toLocal.TransformPoint(ray.origin + ray.direction) - localOrigin).Normalized);
		let edge = ModelElementAt(mesh, world, toLocal, mouse, .Edge);
		if (edge < 0)
		{
			// Inside a face: the point on it under the pointer.
			if (mesh.Raycast(localRay, ?, let hit, true) < 0)
				return false;
			point = hit;
			return true;
		}
		EditMesh.EdgeEnds((uint64)edge, let a, let b);
		let pa = mesh.positions[a], pb = mesh.positions[b];
		let length = (pb - pa).Length;
		if (length < 1.0e-8f)
			return false;
		let t = Math.Clamp(RayLineParam(localRay, pa, (pb - pa) / length) / length, 0.0f, 1.0f);
		point = Vector3.Lerp(pa, pb, t);
		return true;
	}

	// ------------------------------------------------------------------ what the tool shows

	/// A line about the tool running, for the Scene view.
	void ModelToolStatus(String into)
	{
		let axisNames = "XYZ";
		let axis = scope String();
		if (mModelAxis >= 0)
			axis.AppendF(mModelAxisPlane ? "  across {}{}" : "  along {}{}", axisNames[mModelAxis], mModelAxisLocal ? " (own)" : "");
		let typed = scope String();
		if (!mModelTyped.IsEmpty)
			typed.AppendF("  [{}]", mModelTyped);
		switch (mModelTool)
		{
		case .Grab: into.AppendF("Move {:0.###} m{}{}", mModelToolAmount, axis, typed);
		case .Rotate: into.AppendF("Rotate {:0.#}°{}{}", mModelToolAmount, axis, typed);
		case .Scale: into.AppendF("Scale {:0.###}{}{}", mModelToolAmount, axis, typed);
		case .Extrude: into.AppendF("Extrude {:0.###} m{}{}{}", mModelToolAmount, mModelToolEach ? "  each face (E)" : "", axis, typed);
		case .Inset: into.AppendF("Inset {:0.###} m  {} (I){}", mModelToolAmount, mModelToolEach ? "each face" : "together", typed);
		case .Bevel: into.AppendF("Bevel {:0.###} m  {} edges  {} segment{} (wheel){}", mModelToolAmount, mModelBevelEdges.Count, mModelBevelSegments, mModelBevelSegments == 1 ? "" : "s", typed);
		case .Slide: into.AppendF("Slide edges {:0.##}{}  (G from Grab; type -1 to 1)", mModelToolAmount, typed);
		case .VertexSlide: into.AppendF("Slide vertices {:0.##}{}  (along the edge nearest the pointer's way)", mModelToolAmount, typed);
		case .LoopCut:
			if (mModelLoopSliding)
				into.AppendF("Slide the cut: {:0.##} along{}  (click to keep, Esc for the middle)", mModelLoopT, typed);
			else
				into.AppendF("Loop cut: {} cut{}  (wheel or +/- for more; click an edge)", mModelLoopCuts, mModelLoopCuts == 1 ? "" : "s");
		case .Knife: into.AppendF("Knife: {} point{}  (click edges, corners or inside faces; Enter or Space cuts, Backspace undoes a point)", mModelKnifePoints.Count, mModelKnifePoints.Count == 1 ? "" : "s");
		default:
		}
		if (mModelProportional && (mModelTool == .Grab || mModelTool == .Rotate || mModelTool == .Scale))
			into.AppendF("  proportional {:0.##} m (wheel)", mModelPropRadius);
	}

	/// The knife's line, drawn over the Scene view.
	void DrawModelKnife(Matrix4 world)
	{
		if (mModelTool != .Knife)
			return;
		let color = Color(1, 0.85f, 0.25f, 1);
		var previous = ImGui.Vec2(0, 0);
		var havePrevious = false;
		for (let p in mModelKnifePoints)
		{
			if (!SceneToScreen(world.TransformPoint(p), mSceneOrigin, mSceneSize, let screen))
				continue;
			if (havePrevious)
				ImGui.DrawLine(previous, screen, color, 2);
			ImGui.DrawCircleFilled(screen, 4, color);
			previous = screen;
			havePrevious = true;
		}
		let mouse = ImGui.GetMousePos();
		if (mModelKnifeHit && SceneToScreen(world.TransformPoint(mModelKnifeHover), mSceneOrigin, mSceneSize, let hover))
		{
			if (havePrevious)
				ImGui.DrawLine(previous, hover, .(color.r, color.g, color.b, 0.6f), 1.5f);
			ImGui.DrawCircle(hover, 6, color, 2);
		}
		else if (mSceneHovered)
		{
			ImGui.DrawLine(.(mouse.x - 5, mouse.y - 5), .(mouse.x + 5, mouse.y + 5), .(1, 0.35f, 0.3f, 0.9f), 2);
			ImGui.DrawLine(.(mouse.x - 5, mouse.y + 5), .(mouse.x + 5, mouse.y - 5), .(1, 0.35f, 0.3f, 0.9f), 2);
		}
	}
}
