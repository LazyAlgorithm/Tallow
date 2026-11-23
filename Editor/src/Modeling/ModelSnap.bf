using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Snapping to other objects while a shape is drawn (tallowengine.com/docs/modeling): the pointer near a corner, an edge or the
/// middle of an edge of any object's mesh takes that point, so a ramp's top can be put exactly on the edge of the
/// platform it leads to. Corners win over middles, middles over edges. Alt held turns it off for the moment.
extension EditorApp
{
	enum ModelSnapKind
	{
		None,
		Vertex,
		Middle,
		Edge
	}

	struct ModelSnapHit
	{
		public ModelSnapKind kind;
		public Vector3 point;
		/// The edge's ends (a corner: the corner twice).
		public Vector3 a;
		public Vector3 b;
		/// How good it is: pixels from the pointer, with corners ahead of middles ahead of edges.
		public float rank;
	}

	/// Shapes being drawn snap to other objects' corners and edges. Remembered (model_window.txt).
	bool mModelSnapObjects = true;

	const float SnapVertexPixels = 11;
	const float SnapEdgePixels = 8;

	/// The corner, edge middle or edge point of an object nearest the pointer, within a few pixels of it.
	bool FindObjectSnap(ImGui.Vec2 mouse, ImGui.Vec2 origin, ImGui.Vec2 size, out ModelSnapHit hit)
	{
		var best = ModelSnapHit();
		best.rank = float.MaxValue;
		let ray = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);

		void Corner(Vector3 point, ImGui.Vec2 screen, ModelSnapKind kind, Vector3 a, Vector3 b)
		{
			let dx = screen.x - mouse.x;
			let dy = screen.y - mouse.y;
			let pixels = Math.Sqrt(dx * dx + dy * dy);
			if (pixels > SnapVertexPixels)
				return;
			let rank = pixels + (kind == .Middle ? SnapVertexPixels : 0);
			if (rank < best.rank)
				best = .() { kind = kind, point = point, a = a, b = b, rank = rank };
		}

		void Edge(Vector3 a, Vector3 b)
		{
			ImGui.Vec2 sa = default, sb = default;
			if (!SceneToScreen(a, origin, size, out sa) || !SceneToScreen(b, origin, size, out sb))
				return;
			// Far from the pointer: most edges go here.
			if (Math.Min(sa.x, sb.x) > mouse.x + SnapVertexPixels || Math.Max(sa.x, sb.x) < mouse.x - SnapVertexPixels || Math.Min(sa.y, sb.y) > mouse.y + SnapVertexPixels || Math.Max(sa.y, sb.y) < mouse.y - SnapVertexPixels)
				return;
			Corner(a, sa, .Vertex, a, a);
			Corner(b, sb, .Vertex, b, b);
			let middle = (a + b) * 0.5f;
			ImGui.Vec2 sm = default;
			if (SceneToScreen(middle, origin, size, out sm))
				Corner(middle, sm, .Middle, a, b);
			let pixels = SegmentDistance(mouse, sa, sb);
			let rank = pixels + 2 * SnapVertexPixels;
			if (pixels > SnapEdgePixels || rank >= best.rank)
				return;
			// The point of the edge nearest the pointer's ray.
			let along = b - a;
			let from = a - ray.origin;
			let aa = Vector3.Dot(along, along);
			let ab = Vector3.Dot(along, ray.direction);
			let bb = Vector3.Dot(ray.direction, ray.direction);
			let af = Vector3.Dot(along, from);
			let bf = Vector3.Dot(ray.direction, from);
			let denominator = aa * bb - ab * ab;
			let s = Math.Abs(denominator) > 1.0e-9f ? Math.Clamp((ab * bf - af * bb) / denominator, 0, 1) : 0.5f;
			best = .() { kind = .Edge, point = a + along * s, a = a, b = b, rank = rank };
		}

		let edges = scope List<uint64>();
		for (let renderer in mScene.Renderers)
		{
			let go = renderer.GameObject;
			if (!renderer.IsActiveAndEnabled || !go.InActiveWorld || go.Transient || go == mDropPreview)
				continue;
			// Only objects the pointer's ray passes near.
			let bounds = renderer.WorldBounds;
			let toCentre = bounds.Center - ray.origin;
			let distance = (toCentre - ray.direction * Vector3.Dot(toCentre, ray.direction)).Length;
			let radius = bounds.Extents.Length;
			if (distance > radius * 1.1f + ModelWorldPerPixel(bounds.Center) * 16)
				continue;
			let world = renderer.Transform.LocalToWorld;
			let model = go.GetComponent<ModelMesh>();
			if (model.IsValid)
			{
				// A model's own edges: no diagonals across its faces.
				let mesh = model.Edit;
				edges.Clear();
				mesh.Edges(edges);
				for (let e in edges)
				{
					EditMesh.EdgeEnds(e, let a, let b);
					Edge(world.TransformPoint(mesh.positions[a]), world.TransformPoint(mesh.positions[b]));
				}
				continue;
			}
			let mesh = renderer.ActiveMesh;
			if (mesh == null || mesh.Indices.Count < 3 || mesh.Indices.Count > 150000)
				continue;
			for (int i = 0; i + 2 < mesh.Indices.Count; i += 3)
			{
				let a = world.TransformPoint(mesh.Vertices[(int)mesh.Indices[i]].position);
				let b = world.TransformPoint(mesh.Vertices[(int)mesh.Indices[i + 1]].position);
				let c = world.TransformPoint(mesh.Vertices[(int)mesh.Indices[i + 2]].position);
				Edge(a, b);
				Edge(b, c);
				Edge(c, a);
			}
		}
		hit = best;
		return best.kind != .None;
	}

	/// Shows what the pointer snapped to: the edge lit, a ring on the point and what it is.
	void DrawObjectSnap(ModelSnapHit hit, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		ImGui.Vec2 at = default;
		if (hit.kind == .None || !SceneToScreen(hit.point, origin, size, out at))
			return;
		let color = ModelHoverColor;
		ImGui.Vec2 sa = default, sb = default;
		if (hit.kind != .Vertex && SceneToScreen(hit.a, origin, size, out sa) && SceneToScreen(hit.b, origin, size, out sb))
			ImGui.DrawLine(sa, sb, color, 2.5f);
		ImGui.DrawCircleFilled(at, 3, color);
		ImGui.DrawCircle(at, 8, color, 2);
		let name = hit.kind == .Vertex ? "corner" : (hit.kind == .Middle ? "middle" : "edge");
		ImGui.DrawText(.(at.x + 13, at.y - 21), .(0, 0, 0, 0.75f), name);
		ImGui.DrawText(.(at.x + 12, at.y - 22), color, name);
	}
}
