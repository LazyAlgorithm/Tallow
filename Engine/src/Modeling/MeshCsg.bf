using System;
using System.Collections;

namespace Tallow;

/// Boolean operations between two solids: join them, cut one out of the other (a doorway out of a wall), or keep
/// only where they overlap. Built on BSP trees (as in Evan Wallace's csg.js). Both meshes should be closed; the
/// result is welded, its cracks mended and its flat pieces joined back into whole faces.
static class MeshCsg
{
	public enum Op
	{
		Union,
		Subtract,
		Intersect
	}

	const float Epsilon = 1.0e-5f;

	struct CsgVertex
	{
		public Vector3 position;
		public Vector2 uv;
		public Color color;

		public this(Vector3 position, Vector2 uv, Color color)
		{
			this.position = position;
			this.uv = uv;
			this.color = color;
		}

		public CsgVertex Lerp(CsgVertex other, float t) => .(Vector3.Lerp(position, other.position, t), Vector2.Lerp(uv, other.uv, t), .(color.r + (other.color.r - color.r) * t, color.g + (other.color.g - color.g) * t, color.b + (other.color.b - color.b) * t, color.a + (other.color.a - color.a) * t));
	}

	struct CsgPlane
	{
		public Vector3 normal;
		public float w;

		public CsgPlane Flipped => .() { normal = -normal, w = -w };
	}

	class CsgPolygon
	{
		public List<CsgVertex> vertices = new .() ~ delete _;
		public CsgPlane plane;
		/// The face it came from (material, smooth, texture settings).
		public EditFace settings;

		public void Flip()
		{
			for (int i = 0, j = vertices.Count - 1; i < j; i++,j--)
			{
				let keep = vertices[i];
				vertices[i] = vertices[j];
				vertices[j] = keep;
			}
			plane = plane.Flipped;
		}
	}

	/// Holds every polygon and node made during one operation, freed together at the end.
	class Context
	{
		public List<CsgPolygon> polygons = new .() ~ DeleteContainerAndItems!(_);
		public List<Node> nodes = new .() ~ DeleteContainerAndItems!(_);

		public CsgPolygon Polygon(EditFace settings, CsgPlane plane)
		{
			let polygon = new CsgPolygon();
			polygon.settings = settings;
			polygon.plane = plane;
			polygons.Add(polygon);
			return polygon;
		}

		public CsgPolygon Clone(CsgPolygon from)
		{
			let polygon = Polygon(from.settings, from.plane);
			polygon.vertices.AddRange(from.vertices);
			return polygon;
		}

		public Node Node()
		{
			let node = new Node();
			nodes.Add(node);
			return node;
		}
	}

	enum Side
	{
		Coplanar = 0,
		Front = 1,
		Back = 2,
		Spanning = 3
	}

	static void Split(Context context, CsgPlane plane, CsgPolygon polygon, List<CsgPolygon> coplanarFront, List<CsgPolygon> coplanarBack, List<CsgPolygon> front, List<CsgPolygon> back)
	{
		int kind = 0;
		let n = polygon.vertices.Count;
		let types = scope int[n];
		for (int i < n)
		{
			let t = Vector3.Dot(plane.normal, polygon.vertices[i].position) - plane.w;
			let type = t < -Epsilon ? (int)Side.Back : (t > Epsilon ? (int)Side.Front : (int)Side.Coplanar);
			kind |= type;
			types[i] = type;
		}
		switch ((Side)kind)
		{
		case .Coplanar:
			(Vector3.Dot(plane.normal, polygon.plane.normal) > 0 ? coplanarFront : coplanarBack).Add(polygon);
		case .Front:
			front.Add(polygon);
		case .Back:
			back.Add(polygon);
		case .Spanning:
			let f = context.Polygon(polygon.settings, polygon.plane);
			let b = context.Polygon(polygon.settings, polygon.plane);
			for (int i < n)
			{
				let j = (i + 1) % n;
				let ti = types[i], tj = types[j];
				let vi = polygon.vertices[i], vj = polygon.vertices[j];
				if (ti != (int)Side.Back)
					f.vertices.Add(vi);
				if (ti != (int)Side.Front)
					b.vertices.Add(vi);
				if ((ti | tj) == (int)Side.Spanning)
				{
					let t = (plane.w - Vector3.Dot(plane.normal, vi.position)) / Vector3.Dot(plane.normal, vj.position - vi.position);
					let v = vi.Lerp(vj, t);
					f.vertices.Add(v);
					b.vertices.Add(v);
				}
			}
			if (f.vertices.Count >= 3)
				front.Add(f);
			if (b.vertices.Count >= 3)
				back.Add(b);
		}
	}

	class Node
	{
		public CsgPlane plane;
		public bool hasPlane;
		public Node front;
		public Node back;
		public List<CsgPolygon> polygons = new .() ~ delete _;

		public void Invert()
		{
			for (let p in polygons)
				p.Flip();
			plane = plane.Flipped;
			front?.Invert();
			back?.Invert();
			Swap!(front, back);
		}

		/// The parts of the polygons outside this tree's solid.
		public void ClipPolygons(Context context, List<CsgPolygon> list, List<CsgPolygon> into)
		{
			if (!hasPlane)
			{
				into.AddRange(list);
				return;
			}
			let f = scope List<CsgPolygon>();
			let b = scope List<CsgPolygon>();
			for (let p in list)
				Split(context, plane, p, f, b, f, b);
			if (front != null)
			{
				let clipped = scope List<CsgPolygon>();
				front.ClipPolygons(context, f, clipped);
				into.AddRange(clipped);
			}
			else
				into.AddRange(f);
			if (back != null)
			{
				let clipped = scope List<CsgPolygon>();
				back.ClipPolygons(context, b, clipped);
				into.AddRange(clipped);
			}
		}

		/// Removes the parts of this tree's polygons inside another tree's solid.
		public void ClipTo(Context context, Node other)
		{
			let kept = scope List<CsgPolygon>();
			other.ClipPolygons(context, polygons, kept);
			polygons.Set(kept);
			front?.ClipTo(context, other);
			back?.ClipTo(context, other);
		}

		public void AllPolygons(List<CsgPolygon> into)
		{
			into.AddRange(polygons);
			front?.AllPolygons(into);
			back?.AllPolygons(into);
		}

		public void Build(Context context, List<CsgPolygon> list)
		{
			if (list.IsEmpty)
				return;
			if (!hasPlane)
			{
				plane = list[0].plane;
				hasPlane = true;
			}
			let f = scope List<CsgPolygon>();
			let b = scope List<CsgPolygon>();
			for (let p in list)
				Split(context, plane, p, polygons, polygons, f, b);
			if (!f.IsEmpty)
			{
				if (front == null)
					front = context.Node();
				front.Build(context, f);
			}
			if (!b.IsEmpty)
			{
				if (back == null)
					back = context.Node();
				back.Build(context, b);
			}
		}
	}

	static void ToPolygons(Context context, EditMesh mesh, Matrix4 transform, List<CsgPolygon> into)
	{
		mesh.UpdateAutoUVs(.One);
		let mirrored = Vector3.Dot(Vector3.Cross(transform.TransformDirection(.Right), transform.TransformDirection(.Up)), transform.TransformDirection(.Forward)) < 0;
		for (let face in mesh.faces)
		{
			// Bent faces are cut into triangles, which are flat.
			let corners = scope List<int32>();
			let flat = IsFlat(mesh, face);
			if (flat)
			{
				for (int32 i < (int32)face.Count)
					corners.Add(i);
			}
			else
				mesh.Triangulate(face, corners);
			let step = flat ? face.Count : 3;
			for (int start = 0; start + step <= corners.Count; start += step)
			{
				let polygon = context.Polygon(face, default);
				for (int k < step)
				{
					let i = corners[start + k];
					polygon.vertices.Add(.(transform.TransformPoint(mesh.positions[face.verts[i]]), face.uvs[i], face.colors[i]));
				}
				if (mirrored)
				{
					for (int i = 0, j = polygon.vertices.Count - 1; i < j; i++,j--)
						Swap!(polygon.vertices[i], polygon.vertices[j]);
				}
				// The plane from Newell's normal of the polygon.
				var normal = Vector3.Zero;
				let origin = polygon.vertices[0].position;
				for (int i = 1; i + 1 < polygon.vertices.Count; i++)
					normal = normal + Vector3.Cross(polygon.vertices[i].position - origin, polygon.vertices[i + 1].position - origin);
				if (normal.LengthSquared < 1.0e-20f)
					continue;
				normal = normal.Normalized;
				polygon.plane = .() { normal = normal, w = Vector3.Dot(normal, origin) };
				into.Add(polygon);
			}
		}
	}

	static bool IsFlat(EditMesh mesh, EditFace face)
	{
		if (face.Count == 3)
			return true;
		let normal = mesh.FaceNormal(face);
		let origin = mesh.positions[face.verts[0]];
		for (let v in face.verts)
		{
			if (Math.Abs(Vector3.Dot(mesh.positions[v] - origin, normal)) > Epsilon * 10)
				return false;
		}
		return true;
	}

	/// Combines two meshes, each placed by its own matrix (object to world). The result is in the space `toResult`
	/// maps world into (usually the first object's world-to-local), as a new mesh the caller owns.
	public static EditMesh Combine(EditMesh a, Matrix4 aToWorld, EditMesh b, Matrix4 bToWorld, Op op, Matrix4 toResult)
	{
		let context = scope Context();
		let pa = scope List<CsgPolygon>();
		let pb = scope List<CsgPolygon>();
		ToPolygons(context, a, aToWorld, pa);
		ToPolygons(context, b, bToWorld, pb);
		let na = context.Node();
		let nb = context.Node();
		na.Build(context, pa);
		nb.Build(context, pb);
		switch (op)
		{
		case .Union:
			na.ClipTo(context, nb);
			nb.ClipTo(context, na);
			nb.Invert();
			nb.ClipTo(context, na);
			nb.Invert();
		case .Subtract:
			na.Invert();
			na.ClipTo(context, nb);
			nb.ClipTo(context, na);
			nb.Invert();
			nb.ClipTo(context, na);
			nb.Invert();
		case .Intersect:
			na.Invert();
			nb.ClipTo(context, na);
			nb.Invert();
			na.ClipTo(context, nb);
			nb.ClipTo(context, na);
		}
		let fromB = scope List<CsgPolygon>();
		nb.AllPolygons(fromB);
		na.Build(context, fromB);
		if (op != .Union)
			na.Invert();
		let result = scope List<CsgPolygon>();
		na.AllPolygons(result);
		return ToMesh(result, toResult);
	}

	static EditMesh ToMesh(List<CsgPolygon> polygons, Matrix4 transform)
	{
		let mesh = new EditMesh();
		let mirrored = Vector3.Dot(Vector3.Cross(transform.TransformDirection(.Right), transform.TransformDirection(.Up)), transform.TransformDirection(.Forward)) < 0;
		for (let polygon in polygons)
		{
			if (polygon.vertices.Count < 3)
				continue;
			let face = new EditFace();
			face.CopySettings(polygon.settings);
			for (let v in polygon.vertices)
				face.Add(mesh.AddVertex(transform.TransformPoint(v.position)), v.uv, v.color);
			if (mirrored)
				face.Reverse();
			mesh.faces.Add(face);
		}
		mesh.Weld(0.0002f);
		MendCracks(mesh);
		mesh.UpdateAutoUVs(.One);
		mesh.MergeFlatNeighbours();
		RemoveStraightCorners(mesh);
		return mesh;
	}

	/// Where a vertex lies on another face's edge without being one of its corners (cutting leaves these), adds it
	/// to that face, so the faces meet edge to edge and the mesh is closed again.
	public static int MendCracks(EditMesh mesh, float tolerance = 0.0002f)
	{
		int added = 0;
		for (let face in mesh.faces)
		{
			for (int i = 0; i < face.Count; i++)
			{
				let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
				let pa = mesh.positions[a], pb = mesh.positions[b];
				let along = pb - pa;
				let length = along.Length;
				if (length < tolerance)
					continue;
				let dir = along / length;
				// The vertex nearest to a along the edge, if any lies on it.
				int32 best = -1;
				float bestT = length;
				for (int32 v < (int32)mesh.positions.Count)
				{
					if (v == a || v == b)
						continue;
					let offset = mesh.positions[v] - pa;
					let t = Vector3.Dot(offset, dir);
					if (t <= tolerance || t >= length - tolerance || t >= bestT)
						continue;
					if ((offset - dir * t).Length > tolerance)
						continue;
					best = v;
					bestT = t;
				}
				if (best < 0)
					continue;
				let s = bestT / length;
				let j = (i + 1) % face.Count;
				face.Insert(i + 1, best, Vector2.Lerp(face.uvs[i], face.uvs[j], s), Color.Lerp(face.colors[i], face.colors[j], s));
				added++;
				// Look at the shorter edge from a again: there may be more points along it.
				i--;
			}
		}
		return added;
	}

	/// Drops vertices that sit in a straight line in every face using them (cutting and joining leave these along
	/// edges), so faces keep only real corners.
	public static void RemoveStraightCorners(EditMesh mesh)
	{
		let straight = scope bool[mesh.positions.Count];
		let used = scope bool[mesh.positions.Count];
		for (int i < straight.Count)
			straight[i] = true;
		for (let face in mesh.faces)
		{
			for (int i < face.Count)
			{
				let v = face.verts[i];
				used[v] = true;
				let prev = mesh.positions[face.verts[(i + face.Count - 1) % face.Count]];
				let next = mesh.positions[face.verts[(i + 1) % face.Count]];
				let p = mesh.positions[v];
				if (Vector3.Dot((p - prev).Normalized, (next - p).Normalized) < 0.99999f)
					straight[v] = false;
			}
		}
		for (let face in mesh.faces)
		{
			for (int i = face.Count - 1; i >= 0 && face.Count > 3; i--)
			{
				if (used[face.verts[i]] && straight[face.verts[i]])
					face.RemoveCorner(i);
			}
		}
		mesh.RemoveUnusedVertices();
	}
}
