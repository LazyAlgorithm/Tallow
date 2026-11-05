using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Picking in the modeller's edit mode (docs/modeling.md): what is under the pointer, loops (Alt+click), paths
/// (Ctrl+click), growing, shrinking, inverting and hiding, and how the selection is drawn in the Scene view.
extension EditorApp
{
	// The vertex, face or edge (its key) under the pointer and the one picked last, in the current mode; -1 for none.
	int64 mModelHover = -1;
	int64 mModelActive = -1;
	float mModelSharpAngle = 30;

	// Faces hidden with H (EditFace.hidden): the vertices and edges still shown, worked out each frame.
	bool mModelAnyHidden;
	HashSet<int32> mModelShownVerts = new .() ~ delete _;
	HashSet<uint64> mModelShownEdges = new .() ~ delete _;
	/// The object whose faces are hidden, shown again when edit mode ends.
	uint32 mModelHiddenObject;

	static readonly Color ModelSelectColor = .(1, 0.58f, 0.12f, 1);
	static readonly Color ModelActiveColor = .(1, 0.9f, 0.62f, 1);
	static readonly Color ModelHoverColor = .(0.45f, 0.82f, 1, 1);

	void UpdateModelShown(EditMesh mesh)
	{
		mModelAnyHidden = mesh.AnyHidden;
		mModelShownVerts.Clear();
		mModelShownEdges.Clear();
		if (!mModelAnyHidden)
			return;
		for (let face in mesh.faces)
		{
			if (face.hidden)
				continue;
			for (int i < face.Count)
			{
				mModelShownVerts.Add(face.verts[i]);
				mModelShownEdges.Add(EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]));
			}
		}
	}

	bool ModelVertShown(int32 v) => !mModelAnyHidden || mModelShownVerts.Contains(v);
	bool ModelEdgeShown(uint64 e) => !mModelAnyHidden || mModelShownEdges.Contains(e);

	/// Shows faces hidden on a model that is no longer being edited.
	void RevealLeftModel()
	{
		if (mModelHiddenObject == 0 || (mModelEditing && mModelObject == mModelHiddenObject))
			return;
		let model = GameObject.ComponentOn<ModelMesh>(mScene.FindById(mModelHiddenObject));
		mModelHiddenObject = 0;
		if (!model.IsValid)
			return;
		for (let face in model.Edit.faces)
			face.hidden = false;
		model.Save();
	}

	Ray ModelMouseRay(ImGui.Vec2 mouse) => mSceneCamera.ViewportPointToRay((mouse.x - mSceneOrigin.x) / mSceneSize.x, (mouse.y - mSceneOrigin.y) / mSceneSize.y);

	/// The vertex, edge (its key) or face under a point of the Scene view in a mode, or -1. Only what can be seen
	/// counts, unless x-ray is on.
	int64 ModelElementAt(EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 mouse, ModelSelectMode mode)
	{
		let origin = mSceneOrigin, size = mSceneSize;
		switch (mode)
		{
		case .Vertex:
			int32 best = -1;
			float bestDistance = 12;
			for (int32 v < (int32)mesh.positions.Count)
			{
				if (!ModelVertShown(v))
					continue;
				let p = world.TransformPoint(mesh.positions[v]);
				if (!SceneToScreen(p, origin, size, let screen))
					continue;
				let d = Math.Sqrt((screen.x - mouse.x) * (screen.x - mouse.x) + (screen.y - mouse.y) * (screen.y - mouse.y));
				if (d < bestDistance && ModelPointVisible(mesh, toLocal, p))
				{
					bestDistance = d;
					best = v;
				}
			}
			return best;
		case .Edge:
			let edges = scope List<uint64>();
			mesh.Edges(edges);
			int64 best = -1;
			float bestDistance = 9;
			for (let e in edges)
			{
				if (!ModelEdgeShown(e))
					continue;
				EditMesh.EdgeEnds(e, let a, let b);
				let pa = world.TransformPoint(mesh.positions[a]);
				let pb = world.TransformPoint(mesh.positions[b]);
				if (!SceneToScreen(pa, origin, size, let sa))
					continue;
				if (!SceneToScreen(pb, origin, size, let sb))
					continue;
				let d = SegmentDistance(mouse, sa, sb);
				if (d < bestDistance && ModelPointVisible(mesh, toLocal, (pa + pb) * 0.5f))
				{
					bestDistance = d;
					best = (int64)e;
				}
			}
			return best;
		case .Face:
			let ray = ModelMouseRay(mouse);
			let localOrigin = toLocal.TransformPoint(ray.origin);
			let localEnd = toLocal.TransformPoint(ray.origin + ray.direction);
			return mesh.Raycast(Ray(localOrigin, (localEnd - localOrigin).Normalized), ?, ?, true);
		}
	}

	/// Picks (or with `add`, adds or takes away) the element under the pointer.
	void PickModelElement(EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 origin, ImGui.Vec2 size, ImGui.Vec2 mouse, bool add)
	{
		let hit = ModelElementAt(mesh, world, toLocal, mouse, mModelMode);
		if (!add)
			ClearModelSelection();
		if (hit < 0)
			return;
		let added = ToggleModelElement(hit);
		mModelActive = added ? hit : -1;
	}

	/// Adds an element to the selection, or takes it away if it is in it; true when added.
	bool ToggleModelElement(int64 element)
	{
		switch (mModelMode)
		{
		case .Vertex:
			if (mModelVerts.Remove((int32)element))
				return false;
			mModelVerts.Add((int32)element);
		case .Edge:
			if (mModelEdges.Remove((uint64)element))
				return false;
			mModelEdges.Add((uint64)element);
		case .Face:
			if (mModelFaces.Remove((int32)element))
				return false;
			mModelFaces.Add((int32)element);
		}
		return true;
	}

	bool ModelIsSelected(int64 element)
	{
		switch (mModelMode)
		{
		case .Vertex: return mModelVerts.Contains((int32)element);
		case .Edge: return mModelEdges.Contains((uint64)element);
		case .Face: return mModelFaces.Contains((int32)element);
		}
	}

	static float SegmentDistance(ImGui.Vec2 p, ImGui.Vec2 a, ImGui.Vec2 b)
	{
		let dx = b.x - a.x, dy = b.y - a.y;
		let length = dx * dx + dy * dy;
		var t = length > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / length : 0;
		t = Math.Clamp(t, 0, 1);
		let x = a.x + dx * t - p.x, y = a.y + dy * t - p.y;
		return Math.Sqrt(x * x + y * y);
	}

	/// Whether a point of the model can be seen from the camera (nothing of the model in front of it).
	bool ModelPointVisible(EditMesh mesh, Matrix4 toLocal, Vector3 worldPoint)
	{
		if (mModelXRay)
			return true;
		let localCamera = toLocal.TransformPoint(mCamPosition);
		let localPoint = toLocal.TransformPoint(worldPoint);
		let along = localPoint - localCamera;
		let length = along.Length;
		if (length < 1.0e-4f)
			return true;
		let hit = mesh.Raycast(Ray(localCamera, along / length), let distance, ?, true);
		return hit < 0 || distance >= length * 0.995f - 0.002f;
	}

	/// Box selection: everything with its points inside the box (only what can be seen, unless x-ray is on).
	/// Shift adds to the selection, Ctrl takes away from it.
	void BoxSelectModel(EditMesh mesh, Matrix4 world, ImGui.Vec2 origin, ImGui.Vec2 size, ImGui.Vec2 from, ImGui.Vec2 to, bool add, bool subtract = false)
	{
		let min = ImGui.Vec2(Math.Min(from.x, to.x), Math.Min(from.y, to.y));
		let max = ImGui.Vec2(Math.Max(from.x, to.x), Math.Max(from.y, to.y));
		let toLocal = world.Inverse;
		bool Inside(Vector3 local)
		{
			let p = world.TransformPoint(local);
			if (!SceneToScreen(p, origin, size, let screen))
				return false;
			return screen.x >= min.x && screen.x <= max.x && screen.y >= min.y && screen.y <= max.y && ModelPointVisible(mesh, toLocal, p);
		}
		if (!add && !subtract)
			ClearModelSelection();
		switch (mModelMode)
		{
		case .Vertex:
			for (int32 v < (int32)mesh.positions.Count)
			{
				if (!ModelVertShown(v) || !Inside(mesh.positions[v]))
					continue;
				if (subtract)
					mModelVerts.Remove(v);
				else
					mModelVerts.Add(v);
			}
		case .Edge:
			let edges = scope List<uint64>();
			mesh.Edges(edges);
			for (let e in edges)
			{
				EditMesh.EdgeEnds(e, let a, let b);
				if (!ModelEdgeShown(e) || !Inside(mesh.positions[a]) || !Inside(mesh.positions[b]))
					continue;
				if (subtract)
					mModelEdges.Remove(e);
				else
					mModelEdges.Add(e);
			}
		case .Face:
			for (int32 f < (int32)mesh.faces.Count)
			{
				if (mesh.faces[f].hidden || !Inside(mesh.FaceCenter(mesh.faces[f])))
					continue;
				if (subtract)
					mModelFaces.Remove(f);
				else
					mModelFaces.Add(f);
			}
		}
	}

	// ------------------------------------------------------------------ selecting more

	void SelectAllModel(EditMesh mesh, bool toggle = true)
	{
		let anything = ModelHasSelection;
		ClearModelSelection();
		if (anything && toggle)
			return;
		switch (mModelMode)
		{
		case .Vertex:
			for (int32 v < (int32)mesh.positions.Count)
			{
				if (ModelVertShown(v))
					mModelVerts.Add(v);
			}
		case .Edge:
			let all = scope List<uint64>();
			mesh.Edges(all);
			for (let e in all)
			{
				if (ModelEdgeShown(e))
					mModelEdges.Add(e);
			}
		case .Face:
			for (int32 f < (int32)mesh.faces.Count)
			{
				if (!mesh.faces[f].hidden)
					mModelFaces.Add(f);
			}
		}
	}

	void InvertModelSelection(EditMesh mesh)
	{
		switch (mModelMode)
		{
		case .Vertex:
			let was = scope HashSet<int32>();
			for (let v in mModelVerts)
				was.Add(v);
			mModelVerts.Clear();
			for (int32 v < (int32)mesh.positions.Count)
			{
				if (!was.Contains(v) && ModelVertShown(v))
					mModelVerts.Add(v);
			}
		case .Edge:
			let was = scope HashSet<uint64>();
			for (let e in mModelEdges)
				was.Add(e);
			mModelEdges.Clear();
			let all = scope List<uint64>();
			mesh.Edges(all);
			for (let e in all)
			{
				if (!was.Contains(e) && ModelEdgeShown(e))
					mModelEdges.Add(e);
			}
		case .Face:
			for (int32 f < (int32)mesh.faces.Count)
			{
				if (mesh.faces[f].hidden)
					continue;
				if (!mModelFaces.Remove(f))
					mModelFaces.Add(f);
			}
		}
		mModelActive = -1;
	}

	/// The vertices joined to each vertex by an edge of a face that is shown.
	void ModelNeighbours(EditMesh mesh, Dictionary<int32, List<int32>> into)
	{
		for (let face in mesh.faces)
		{
			if (face.hidden)
				continue;
			for (int i < face.Count)
			{
				let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
				for (int side < 2)
				{
					let from = side == 0 ? a : b, to = side == 0 ? b : a;
					if (into.TryAdd(from, ?, let list))
						*list = new List<int32>();
					if (!into[from].Contains(to))
						into[from].Add(to);
				}
			}
		}
	}

	/// Grows the selection by one ring of neighbours, or shrinks it by its border.
	void GrowModelSelection(EditMesh mesh, bool grow)
	{
		if (mModelMode == .Face)
		{
			if (grow)
			{
				MeshOps.Grow(mesh, mModelFaces);
				mModelFaces.RemoveWhere(scope (f) => mesh.faces[f].hidden);
				return;
			}
			// Faces touching a vertex of an unselected face are on the border.
			let border = scope HashSet<int32>();
			for (int32 f < (int32)mesh.faces.Count)
			{
				if (mModelFaces.Contains(f))
					continue;
				for (let v in mesh.faces[f].verts)
					border.Add(v);
			}
			mModelFaces.RemoveWhere(scope (f) =>
				{
					for (let v in mesh.faces[f].verts)
					{
						if (border.Contains(v))
							return true;
					}
					return false;
				});
			return;
		}
		let neighbours = scope Dictionary<int32, List<int32>>();
		defer
		{
			for (let list in neighbours.Values)
				delete list;
		}
		ModelNeighbours(mesh, neighbours);
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		let result = scope HashSet<int32>();
		for (let v in verts)
		{
			if (!neighbours.TryGetValue(v, let list))
				continue;
			if (grow)
			{
				result.Add(v);
				for (let n in list)
					result.Add(n);
			}
			else
			{
				bool inside = true;
				for (let n in list)
					inside &= verts.Contains(n);
				if (inside)
					result.Add(v);
			}
		}
		if (mModelMode == .Vertex)
		{
			mModelVerts.Clear();
			for (let v in result)
				mModelVerts.Add(v);
			return;
		}
		mModelEdges.Clear();
		let all = scope List<uint64>();
		mesh.Edges(all);
		for (let e in all)
		{
			EditMesh.EdgeEnds(e, let a, let b);
			if (result.Contains(a) && result.Contains(b) && ModelEdgeShown(e))
				mModelEdges.Add(e);
		}
	}

	void SelectModelLinked(EditMesh mesh)
	{
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		let start = scope List<int32>();
		for (int32 f < (int32)mesh.faces.Count)
		{
			for (let v in mesh.faces[f].verts)
			{
				if (verts.Contains(v))
				{
					start.Add(f);
					break;
				}
			}
		}
		let linked = scope HashSet<int32>();
		MeshOps.Linked(mesh, start, linked);
		let mode = mModelMode;
		mModelMode = .Face;
		ClearModelSelection();
		for (let f in linked)
		{
			if (!mesh.faces[f].hidden)
				mModelFaces.Add(f);
		}
		SetModelMode(mode, mesh);
	}

	/// Alt+click: the loop through the edge under the pointer (vertices or edges along it, or the faces across it).
	void SelectModelLoop(EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 mouse, bool add)
	{
		let hit = ModelElementAt(mesh, world, toLocal, mouse, .Edge);
		if (!add)
			ClearModelSelection();
		if (hit < 0)
			return;
		let edge = (uint64)hit;
		switch (mModelMode)
		{
		case .Vertex,.Edge:
			let loop = scope List<uint64>();
			MeshOps.EdgeLoop(mesh, edge, loop);
			for (let e in loop)
			{
				if (mModelMode == .Edge)
					mModelEdges.Add(e);
				else
				{
					EditMesh.EdgeEnds(e, let a, let b);
					mModelVerts.Add(a);
					mModelVerts.Add(b);
				}
			}
		case .Face:
			let ring = scope List<uint64>();
			MeshOps.EdgeRing(mesh, edge, ring);
			let inRing = scope HashSet<uint64>();
			for (let e in ring)
				inRing.Add(e);
			for (int32 f < (int32)mesh.faces.Count)
			{
				let face = mesh.faces[f];
				if (face.hidden)
					continue;
				int crossing = 0;
				for (int i < face.Count)
				{
					if (inRing.Contains(EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count])))
						crossing++;
				}
				if (crossing >= 2)
					mModelFaces.Add(f);
			}
		}
		mModelActive = -1;
	}

	/// Ctrl+click: the shortest way from the element picked last to the one under the pointer.
	void SelectModelPath(EditMesh mesh, Matrix4 world, Matrix4 toLocal, ImGui.Vec2 mouse)
	{
		let target = ModelElementAt(mesh, world, toLocal, mouse, mModelMode);
		if (target < 0)
			return;
		if (mModelActive < 0 || !ModelIsSelected(mModelActive))
		{
			ToggleModelElement(target);
			mModelActive = target;
			return;
		}
		if (mModelMode == .Face)
		{
			// Faces next to each other across an edge, by the distance between their centres.
			let edgeFaces = scope Dictionary<uint64, List<int32>>();
			defer
			{
				for (let list in edgeFaces.Values)
					delete list;
			}
			mesh.EdgeFaces(edgeFaces);
			let path = scope List<int32>();
			ShortestPath((int32)mModelActive, (int32)target, mesh.faces.Count, scope (f, visit) =>
				{
					let face = mesh.faces[f];
					let center = mesh.FaceCenter(face);
					for (int i < face.Count)
					{
						for (let g in edgeFaces[EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count])])
						{
							if (g != f && !mesh.faces[g].hidden)
								visit(g, (mesh.FaceCenter(mesh.faces[g]) - center).Length);
						}
					}
				}, path);
			for (let f in path)
				mModelFaces.Add(f);
		}
		else
		{
			let neighbours = scope Dictionary<int32, List<int32>>();
			defer
			{
				for (let list in neighbours.Values)
					delete list;
			}
			ModelNeighbours(mesh, neighbours);
			int32 from, to;
			if (mModelMode == .Vertex)
			{
				from = (int32)mModelActive;
				to = (int32)target;
			}
			else
			{
				// From the nearer ends of the two edges.
				EditMesh.EdgeEnds((uint64)mModelActive, let a0, let a1);
				EditMesh.EdgeEnds((uint64)target, let b0, let b1);
				let p = scope Vector3[4](mesh.positions[a0], mesh.positions[a1], mesh.positions[b0], mesh.positions[b1]);
				var best = float.MaxValue;
				from = a0;
				to = b0;
				for (int i < 2)
				{
					for (int j < 2)
					{
						let d = (p[i] - p[2 + j]).LengthSquared;
						if (d < best)
						{
							best = d;
							from = i == 0 ? a0 : a1;
							to = j == 0 ? b0 : b1;
						}
					}
				}
				mModelEdges.Add((uint64)target);
			}
			let path = scope List<int32>();
			ShortestPath(from, to, mesh.positions.Count, scope (v, visit) =>
				{
					if (neighbours.TryGetValue(v, let list))
					{
						for (let n in list)
							visit(n, (mesh.positions[n] - mesh.positions[v]).Length);
					}
				}, path);
			for (int i < path.Count)
			{
				if (mModelMode == .Vertex)
					mModelVerts.Add(path[i]);
				else if (i > 0)
					mModelEdges.Add(EditMesh.EdgeKey(path[i - 1], path[i]));
			}
		}
		mModelActive = target;
	}

	/// Dijkstra's shortest path over `count` nodes; `neighbours` calls its visitor with each neighbour and the
	/// step's length. The path (both ends included) goes into `path`, empty when there is none.
	static void ShortestPath(int32 from, int32 to, int count, delegate void(int32 node, delegate void(int32 next, float length) visit) neighbours, List<int32> path)
	{
		let distance = scope float[count];
		let previous = scope int32[count];
		let done = scope bool[count];
		for (int i < count)
		{
			distance[i] = float.MaxValue;
			previous[i] = -1;
		}
		distance[from] = 0;
		let open = scope List<int32>() { from };
		while (!open.IsEmpty)
		{
			var bestIndex = 0;
			for (int i = 1; i < open.Count; i++)
			{
				if (distance[open[i]] < distance[open[bestIndex]])
					bestIndex = i;
			}
			let node = open[bestIndex];
			open.RemoveAtFast(bestIndex);
			if (done[node])
				continue;
			done[node] = true;
			if (node == to)
				break;
			neighbours(node, scope (next, length) =>
				{
					if (done[next] || distance[node] + length >= distance[next])
						return;
					distance[next] = distance[node] + length;
					previous[next] = node;
					open.Add(next);
				});
		}
		if (from != to && previous[to] < 0)
			return;
		for (var node = to; node >= 0; node = previous[node])
		{
			path.Insert(0, node);
			if (node == from)
				break;
		}
	}

	/// Edges where the faces either side turn by more than the angle.
	void SelectModelSharp(EditMesh mesh)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let limit = Math.Cos(mModelSharpAngle * Mathf.Deg2Rad);
		SetModelMode(.Edge, mesh);
		mModelEdges.Clear();
		for (let pair in edgeFaces)
		{
			if (pair.value.Count == 2 && ModelEdgeShown(pair.key) && Vector3.Dot(mesh.FaceNormal(mesh.faces[pair.value[0]]), mesh.FaceNormal(mesh.faces[pair.value[1]])) < limit)
				mModelEdges.Add(pair.key);
		}
	}

	/// The faces in the same material slots as the selected ones.
	void SelectModelSameSlot(EditMesh mesh)
	{
		let slots = scope HashSet<int32>();
		for (let f in mModelFaces)
			slots.Add(mesh.faces[f].material);
		for (int32 f < (int32)mesh.faces.Count)
		{
			if (!mesh.faces[f].hidden && slots.Contains(mesh.faces[f].material))
				mModelFaces.Add(f);
		}
	}

	// ------------------------------------------------------------------ hiding

	/// Hides the selected faces (or those touching the selected vertices or edges); with `others`, every face
	/// but those.
	void HideModelFaces(ModelMesh model, EditMesh mesh, bool others)
	{
		let verts = scope HashSet<int32>();
		ModelSelectedVerts(mesh, verts);
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			bool picked;
			if (mModelMode == .Face)
				picked = mModelFaces.Contains(f);
			else
			{
				// Hiding: any corner picked. Keeping (others): every corner picked.
				picked = others;
				for (let v in face.verts)
				{
					if (others)
						picked &= verts.Contains(v);
					else
						picked |= verts.Contains(v);
				}
			}
			if (picked != others)
				face.hidden = true;
		}
		ClearModelSelection();
		mModelHiddenObject = model.GameObject.Id;
		model.Preview();
	}

	void RevealModelFaces(ModelMesh model, EditMesh mesh)
	{
		for (let face in mesh.faces)
			face.hidden = false;
		model.Save();
	}

	// ------------------------------------------------------------------ drawing

	/// Over the Scene view: the vertices, the selected and active elements drawn thick, and the one under the
	/// pointer. Elements behind the model are drawn faint (all of them with x-ray).
	void DrawModelSelection(EditMesh mesh, Matrix4 world, Matrix4 toLocal)
	{
		let origin = mSceneOrigin, size = mSceneSize;
		bool OnScreen(ImGui.Vec2 p) => p.x >= origin.x && p.y >= origin.y && p.x <= origin.x + size.x && p.y <= origin.y + size.y;
		// Big selections skip the test of what can be seen, to stay quick.
		let checkSight = ModelSelectionCount < 600;
		bool Seen(Vector3 worldPoint) => !checkSight || ModelPointVisible(mesh, toLocal, worldPoint);
		let shadow = Color(0, 0, 0, 0.6f);
		void Line(Vector3 a, Vector3 b, Color color, float thickness, bool seen)
		{
			if (!SceneToScreen(a, origin, size, let sa))
				return;
			if (!SceneToScreen(b, origin, size, let sb))
				return;
			if (!seen)
			{
				ImGui.DrawLine(sa, sb, .(color.r, color.g, color.b, 0.35f), 1);
				return;
			}
			ImGui.DrawLine(sa, sb, shadow, thickness + 2);
			ImGui.DrawLine(sa, sb, color, thickness);
		}

		switch (mModelMode)
		{
		case .Vertex:
			for (int32 v < (int32)mesh.positions.Count)
			{
				if (!ModelVertShown(v))
					continue;
				let p = world.TransformPoint(mesh.positions[v]);
				if (!SceneToScreen(p, origin, size, let screen) || !OnScreen(screen))
					continue;
				let selected = mModelVerts.Contains(v);
				let visible = mesh.positions.Count > 4000 || ModelPointVisible(mesh, toLocal, p);
				if (!visible && !selected)
					continue;
				let alpha = visible ? 1.0f : 0.4f;
				if (v == mModelActive && selected)
				{
					ImGui.DrawCircleFilled(screen, 6, .(0, 0, 0, 0.7f * alpha));
					ImGui.DrawCircleFilled(screen, 4.5f, .(ModelActiveColor.r, ModelActiveColor.g, ModelActiveColor.b, alpha));
					ImGui.DrawCircle(screen, 6, .(ModelSelectColor.r, ModelSelectColor.g, ModelSelectColor.b, alpha), 1.5f);
				}
				else if (selected)
				{
					ImGui.DrawCircleFilled(screen, 5.5f, .(0, 0, 0, 0.7f * alpha));
					ImGui.DrawCircleFilled(screen, 4.5f, .(ModelSelectColor.r, ModelSelectColor.g, ModelSelectColor.b, alpha));
				}
				else
				{
					ImGui.DrawCircleFilled(screen, 3.5f, .(0.9f, 0.92f, 1, 0.9f));
					ImGui.DrawCircleFilled(screen, 2.2f, .(0.08f, 0.09f, 0.12f, 1));
				}
			}
			if (mModelHover >= 0 && mModelHover < mesh.positions.Count && SceneToScreen(world.TransformPoint(mesh.positions[(int32)mModelHover]), origin, size, let hover))
				ImGui.DrawCircle(hover, 8, ModelHoverColor, 2);
		case .Edge:
			for (let e in mModelEdges)
			{
				EditMesh.EdgeEnds(e, let a, let b);
				let pa = world.TransformPoint(mesh.positions[a]), pb = world.TransformPoint(mesh.positions[b]);
				Line(pa, pb, (int64)e == mModelActive ? ModelActiveColor : ModelSelectColor, 3, Seen((pa + pb) * 0.5f));
			}
			if (mModelHover >= 0)
			{
				EditMesh.EdgeEnds((uint64)mModelHover, let a, let b);
				if (a < mesh.positions.Count && b < mesh.positions.Count)
					Line(world.TransformPoint(mesh.positions[a]), world.TransformPoint(mesh.positions[b]), ModelHoverColor, 2.5f, true);
			}
		case .Face:
			for (let f in mModelFaces)
			{
				let face = mesh.faces[f];
				let seen = Seen(world.TransformPoint(mesh.FaceCenter(face)));
				let color = f == mModelActive ? ModelActiveColor : ModelSelectColor;
				for (int i < face.Count)
					Line(world.TransformPoint(mesh.positions[face.verts[i]]), world.TransformPoint(mesh.positions[face.verts[(i + 1) % face.Count]]), color, 2, seen);
				// A dot in the middle, as a handle to see small faces by.
				if (seen && SceneToScreen(world.TransformPoint(mesh.FaceCenter(face)), origin, size, let center))
				{
					ImGui.DrawRectFilled(.(center.x - 3.5f, center.y - 3.5f), .(center.x + 3.5f, center.y + 3.5f), shadow);
					ImGui.DrawRectFilled(.(center.x - 2.5f, center.y - 2.5f), .(center.x + 2.5f, center.y + 2.5f), color);
				}
			}
			if (mModelHover >= 0 && mModelHover < mesh.faces.Count)
			{
				let face = mesh.faces[(int32)mModelHover];
				for (int i < face.Count)
					Line(world.TransformPoint(mesh.positions[face.verts[i]]), world.TransformPoint(mesh.positions[face.verts[(i + 1) % face.Count]]), ModelHoverColor, 1.5f, true);
			}
		}
	}

	int ModelSelectionCount => mModelMode == .Vertex ? mModelVerts.Count : (mModelMode == .Edge ? mModelEdges.Count : mModelFaces.Count);
}
