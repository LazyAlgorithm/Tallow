using System;
using System.Collections;

namespace Tallow;

/// More modelling operations (docs/modeling.md): cutting faces into triangles or a fan, joining triangles into
/// quads, giving a surface thickness, smoothing, collapsing, making a face from corners and the knife.
extension MeshOps
{
	// ---- splitting faces ----

	/// Cuts faces of more than three corners into triangles. The new triangles go into `added`.
	public static void Triangulate(EditMesh mesh, Span<int32> faces, List<int32> added = null)
	{
		let corners = scope List<int32>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			if (face.Count <= 3)
				continue;
			corners.Clear();
			mesh.Triangulate(face, corners);
			let original = scope EditFace();
			original.CopyFrom(face);
			for (int i = 0; i + 2 < corners.Count; i += 3)
			{
				let triangle = i == 0 ? face : new EditFace();
				triangle.verts.Clear();
				triangle.uvs.Clear();
				triangle.colors.Clear();
				triangle.CopySettings(original);
				for (int k < 3)
				{
					let c = corners[i + k];
					triangle.Add(original.verts[c], original.uvs[c], original.colors[c]);
				}
				if (i > 0)
				{
					added?.Add((int32)mesh.faces.Count);
					mesh.faces.Add(triangle);
				}
			}
		}
	}

	/// Puts a vertex in the middle of each face and cuts the face into a fan of triangles round it. The new
	/// triangles (all but the first of each face, which keeps its number) go into `added`.
	public static void Poke(EditMesh mesh, Span<int32> faces, List<int32> added = null)
	{
		for (let f in faces)
		{
			let face = mesh.faces[f];
			let n = face.Count;
			if (n < 3)
				continue;
			let original = scope EditFace();
			original.CopyFrom(face);
			let center = mesh.AddVertex(mesh.FaceCenter(original));
			var uv = Vector2.Zero;
			for (let c in original.uvs)
				uv = uv + c;
			uv = uv * (1.0f / n);
			let color = original.AverageColor;
			for (int i < n)
			{
				let j = (i + 1) % n;
				let triangle = i == 0 ? face : new EditFace();
				triangle.verts.Clear();
				triangle.uvs.Clear();
				triangle.colors.Clear();
				triangle.CopySettings(original);
				triangle.Add(original.verts[i], original.uvs[i], original.colors[i]);
				triangle.Add(original.verts[j], original.uvs[j], original.colors[j]);
				triangle.Add(center, uv, color);
				if (i > 0)
				{
					added?.Add((int32)mesh.faces.Count);
					mesh.faces.Add(triangle);
				}
			}
		}
	}

	/// Joins pairs of neighbouring triangles into four-sided faces where they lie nearly flat together (within
	/// `angle` degrees) and make a convex quad, flattest pairs first. Returns how many quads were made.
	public static int TrianglesToQuads(EditMesh mesh, Span<int32> faces, float angle = 40)
	{
		let selected = scope HashSet<int32>();
		for (let f in faces)
		{
			if (mesh.faces[f].Count == 3)
				selected.Add(f);
		}
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let limit = Math.Cos(angle * Mathf.Deg2Rad);
		let pairs = scope List<(float score, uint64 edge, int32 a, int32 b)>();
		for (let pair in edgeFaces)
		{
			if (pair.value.Count != 2)
				continue;
			let a = pair.value[0], b = pair.value[1];
			if (a == b || !selected.Contains(a) || !selected.Contains(b))
				continue;
			let fa = mesh.faces[a], fb = mesh.faces[b];
			if (fa.material != fb.material)
				continue;
			let score = Vector3.Dot(mesh.FaceNormal(fa), mesh.FaceNormal(fb));
			if (score < limit)
				continue;
			pairs.Add((score, pair.key, a, b));
		}
		pairs.Sort((x, y) => y.score <=> x.score);
		let used = scope HashSet<int32>();
		let gone = scope List<int32>();
		let trial = scope EditFace();
		for (let pair in pairs)
		{
			if (used.Contains(pair.a) || used.Contains(pair.b))
				continue;
			EditMesh.EdgeEnds(pair.edge, let va, let vb);
			trial.CopyFrom(mesh.faces[pair.a]);
			if (!JoinAcross(trial, mesh.faces[pair.b], va, vb) || trial.Count != 4 || !Convex(mesh, trial))
				continue;
			mesh.faces[pair.a].CopyFrom(trial);
			used.Add(pair.a);
			used.Add(pair.b);
			gone.Add(pair.b);
		}
		gone.Sort((x, y) => y <=> x);
		for (let f in gone)
		{
			delete mesh.faces[f];
			mesh.faces.RemoveAt(f);
		}
		return gone.Count;
	}

	/// Whether every corner of a face turns the same way.
	static bool Convex(EditMesh mesh, EditFace face)
	{
		let normal = mesh.FaceNormal(face);
		let n = face.Count;
		for (int i < n)
		{
			let a = mesh.positions[face.verts[(i + n - 1) % n]];
			let b = mesh.positions[face.verts[i]];
			let c = mesh.positions[face.verts[(i + 1) % n]];
			if (Vector3.Dot(Vector3.Cross(b - a, c - b), normal) <= 1.0e-8f)
				return false;
		}
		return true;
	}

	// ---- thickness and smoothing ----

	/// Gives faces a thickness: a copy of them turned round, moved back along the normals by `thickness`, joined
	/// to them round the open border, so a plane becomes a slab and an open shell a solid one. New faces go into
	/// `added`.
	public static void Solidify(EditMesh mesh, Span<int32> faces, float thickness, List<int32> added = null)
	{
		if (faces.IsEmpty)
			return;
		// Each vertex moves back along the average normal of the faces round it, further at sharp corners so the
		// walls keep the same thickness.
		let normals = scope Dictionary<int32, Vector3>();
		for (let f in faces)
		{
			let normal = mesh.FaceNormal(mesh.faces[f]);
			for (let v in mesh.faces[f].verts)
			{
				if (normals.TryAdd(v, ?, let value))
					*value = .Zero;
				normals[v] = normals[v] + normal;
			}
		}
		let copies = scope Dictionary<int32, int32>();
		for (let pair in normals)
		{
			var normal = pair.value.LengthSquared > 1.0e-12f ? pair.value.Normalized : Vector3.Up;
			// The deepest the faces round it would need: 1 / cos of the angle to each face's normal.
			var stretch = 1.0f;
			for (let f in faces)
			{
				let face = mesh.faces[f];
				if (face.IndexOf(pair.key) < 0)
					continue;
				let d = Vector3.Dot(mesh.FaceNormal(face), normal);
				if (d > 0.2f)
					stretch = Math.Max(stretch, 1 / d);
			}
			copies[pair.key] = mesh.AddVertex(mesh.positions[pair.key] - normal * (thickness * stretch));
		}
		// The border: edges of the faces used by only one of them.
		let border = scope Dictionary<uint64, int>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let key = EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
				if (border.TryAdd(key, ?, let count))
					*count = 0;
				border[key] = border[key] + 1;
			}
		}
		let count = faces.Length;
		for (int k < count)
		{
			let face = mesh.faces[faces[k]];
			let back = new EditFace();
			back.CopyFrom(face);
			for (var v in ref back.verts)
				v = copies[v];
			back.Reverse();
			added?.Add((int32)mesh.faces.Count);
			mesh.faces.Add(back);
			for (int i < face.Count)
			{
				let j = (i + 1) % face.Count;
				let a = face.verts[i], b = face.verts[j];
				if (border[EditMesh.EdgeKey(a, b)] != 1)
					continue;
				// The face runs a to b, so the side runs b to a, down and back.
				let side = new EditFace();
				side.CopySettings(face);
				side.smooth = false;
				side.Add(b, face.uvs[j], face.colors[j]);
				side.Add(a, face.uvs[i], face.colors[i]);
				side.Add(copies[a], face.uvs[i], face.colors[i]);
				side.Add(copies[b], face.uvs[j], face.colors[j]);
				added?.Add((int32)mesh.faces.Count);
				mesh.faces.Add(side);
			}
		}
	}

	/// Moves vertices towards the average of their neighbours (Laplacian smoothing), `factor` of the way, a number
	/// of times. Vertices on an open border only follow their neighbours along the border, so it does not shrink in.
	public static void SmoothVertices(EditMesh mesh, Span<int32> verts, float factor = 0.5f, int iterations = 1)
	{
		let neighbours = scope Dictionary<int32, List<int32>>();
		defer
		{
			for (let list in neighbours.Values)
				delete list;
		}
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let onBorder = scope HashSet<int32>();
		for (let pair in edgeFaces)
		{
			EditMesh.EdgeEnds(pair.key, let a, let b);
			if (pair.value.Count == 1)
			{
				onBorder.Add(a);
				onBorder.Add(b);
			}
		}
		for (let v in verts)
		{
			if (!neighbours.ContainsKey(v))
				neighbours[v] = new .();
		}
		for (let pair in edgeFaces)
		{
			EditMesh.EdgeEnds(pair.key, let a, let b);
			let border = pair.value.Count == 1;
			for (int side < 2)
			{
				let from = side == 0 ? a : b, to = side == 0 ? b : a;
				if (!neighbours.TryGetValue(from, let list))
					continue;
				// A border vertex keeps to the border.
				if (onBorder.Contains(from) && !border)
					continue;
				list.Add(to);
			}
		}
		let moved = scope Vector3[verts.Length];
		for (int pass < iterations)
		{
			for (int i < verts.Length)
			{
				let v = verts[i];
				let list = neighbours[v];
				moved[i] = mesh.positions[v];
				if (list.IsEmpty)
					continue;
				var average = Vector3.Zero;
				for (let other in list)
					average = average + mesh.positions[other];
				average = average / list.Count;
				moved[i] = Vector3.Lerp(mesh.positions[v], average, factor);
			}
			for (int i < verts.Length)
				mesh.positions[verts[i]] = moved[i];
		}
	}

	// ---- joining ----

	/// Joins the ends of every group of connected edges into one vertex at the group's centre. Returns how many
	/// vertices went.
	public static int CollapseEdges(EditMesh mesh, Span<uint64> edges)
	{
		let parent = scope int32[mesh.positions.Count];
		for (int32 i < (int32)parent.Count)
			parent[i] = i;
		int32 Root(int32 v)
		{
			var v;
			while (parent[v] != v)
			{
				parent[v] = parent[parent[v]];
				v = parent[v];
			}
			return v;
		}
		for (let key in edges)
		{
			EditMesh.EdgeEnds(key, let a, let b);
			let ra = Root(a), rb = Root(b);
			if (ra != rb)
				parent[Math.Max(ra, rb)] = Math.Min(ra, rb);
		}
		let sums = scope Vector3[mesh.positions.Count];
		let counts = scope int[mesh.positions.Count];
		let remap = scope int32[mesh.positions.Count];
		int gone = 0;
		for (int32 v < (int32)remap.Count)
		{
			let root = Root(v);
			remap[v] = root;
			sums[root] = sums[root] + mesh.positions[v];
			counts[root]++;
			if (root != v)
				gone++;
		}
		for (int v < counts.Count)
		{
			if (counts[v] > 1)
				mesh.positions[v] = sums[v] / counts[v];
		}
		mesh.Renumber(remap);
		mesh.Clean();
		return gone;
	}

	/// Makes a face from vertices (three or more), going round them in order of angle about their centre, turned
	/// to agree with the faces next to it (or to look towards `facing` when it has none). Returns it, or -1.
	public static int32 MakeFace(EditMesh mesh, Span<int32> verts, Vector3 facing = .Zero)
	{
		if (verts.Length < 3)
			return -1;
		var center = Vector3.Zero;
		for (let v in verts)
			center = center + mesh.positions[v];
		center = center / verts.Length;
		// The plane they lie in: the largest cross product of two spokes.
		var normal = Vector3.Zero;
		for (int i < verts.Length)
		{
			for (int j = i + 1; j < verts.Length; j++)
			{
				let cross = Vector3.Cross(mesh.positions[verts[i]] - center, mesh.positions[verts[j]] - center);
				if (cross.LengthSquared > normal.LengthSquared)
					normal = Vector3.Dot(cross, normal) < 0 ? -cross : cross;
			}
		}
		if (normal.LengthSquared < 1.0e-14f)
			return -1;
		normal = normal.Normalized;
		var axisU = mesh.positions[verts[0]] - center;
		axisU = (axisU - normal * Vector3.Dot(axisU, normal)).Normalized;
		let axisV = Vector3.Cross(normal, axisU);
		let ordered = scope List<(float angle, int32 vertex)>();
		for (let v in verts)
		{
			let d = mesh.positions[v] - center;
			ordered.Add((Math.Atan2(Vector3.Dot(d, axisV), Vector3.Dot(d, axisU)), v));
		}
		ordered.Sort((a, b) => a.angle <=> b.angle);
		let face = new EditFace();
		for (let entry in ordered)
			face.Add(entry.vertex);
		mesh.faces.Add(face);
		let index = (int32)mesh.faces.Count - 1;
		bool touches = false;
		for (int i < face.Count)
		{
			let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
			for (int g < index)
			{
				if (RunsForward(mesh.faces[g], a, b) || RunsForward(mesh.faces[g], b, a))
				{
					touches = true;
					break;
				}
			}
		}
		if (touches)
			OrientAgainstNeighbours(mesh, index);
		else if (facing.LengthSquared > 0 && Vector3.Dot(mesh.FaceNormal(face), facing) < 0)
			face.Reverse();
		return index;
	}

	// ---- the knife ----

	/// Cuts the faces along a line through points on the model (in its own space), as seen from `eye`: points on
	/// edges or corners split there, and points inside a face become corners of the cut through it (between where
	/// the cut comes into the face and where it leaves; points inside a face at the very start or end of the line
	/// are left out). Between two points that do not share a face, the cut also goes through every edge the line
	/// crosses on the way (on faces looking towards the eye). Points closer than `tolerance` to a corner use the
	/// corner. Returns how many cuts were made.
	public static int Knife(EditMesh mesh, Span<Vector3> points, Vector3 eye, float tolerance = 0.0005f)
	{
		int cuts = 0;
		// The last vertex the cut reached, and points inside a face since then.
		int32 previous = -1;
		let inside = scope List<Vector3>();
		void Reach(int32 v)
		{
			if (v < 0 || v == previous)
				return;
			if (previous >= 0)
			{
				if (inside.IsEmpty ? CutBetween(mesh, previous, v) : CutThrough(mesh, previous, v, inside))
					cuts++;
			}
			inside.Clear();
			previous = v;
		}
		for (int p < points.Length)
		{
			if (p > 0)
			{
				// The edges crossed between the last point and this one, in order.
				let crossings = scope List<(float along, Vector3 point)>();
				KnifeCrossings(mesh, points[p - 1], points[p], eye, tolerance, crossings);
				for (let crossing in crossings)
					Reach(KnifePoint(mesh, crossing.point, tolerance));
			}
			let v = KnifePoint(mesh, points[p], tolerance);
			if (v >= 0)
				Reach(v);
			else if (previous >= 0)
				inside.Add(points[p]);
		}
		return cuts;
	}

	/// Splits the face holding both vertices along a path through points inside it (new corners). False when no
	/// face holds both vertices with the points inside it.
	static bool CutThrough(EditMesh mesh, int32 a, int32 b, Span<Vector3> through)
	{
		int32 best = -1;
		float bestDistance = float.MaxValue;
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			if (face.IndexOf(a) < 0 || face.IndexOf(b) < 0)
				continue;
			let distance = DistanceToFace(mesh, face, through[0]);
			if (distance < bestDistance)
			{
				best = f;
				bestDistance = distance;
			}
		}
		if (best < 0)
			return false;
		return ConnectPath(mesh, best, a, b, through) >= 0;
	}

	/// How far a point is from a face's triangles.
	static float DistanceToFace(EditMesh mesh, EditFace face, Vector3 point)
	{
		let corners = scope List<int32>();
		mesh.Triangulate(face, corners);
		var best = float.MaxValue;
		for (int t = 0; t + 2 < corners.Count; t += 3)
		{
			let closest = ClosestOnTriangle(point, mesh.positions[face.verts[corners[t]]], mesh.positions[face.verts[corners[t + 1]]], mesh.positions[face.verts[corners[t + 2]]]);
			best = Math.Min(best, (closest - point).Length);
		}
		return best;
	}

	/// The point of a triangle nearest a point (Ericson, Real-Time Collision Detection 5.1.5).
	public static Vector3 ClosestOnTriangle(Vector3 p, Vector3 a, Vector3 b, Vector3 c)
	{
		let ab = b - a, ac = c - a, ap = p - a;
		let d1 = Vector3.Dot(ab, ap), d2 = Vector3.Dot(ac, ap);
		if (d1 <= 0 && d2 <= 0)
			return a;
		let bp = p - b;
		let d3 = Vector3.Dot(ab, bp), d4 = Vector3.Dot(ac, bp);
		if (d3 >= 0 && d4 <= d3)
			return b;
		let vc = d1 * d4 - d3 * d2;
		if (vc <= 0 && d1 >= 0 && d3 <= 0)
			return a + ab * (d1 / (d1 - d3));
		let cp = p - c;
		let d5 = Vector3.Dot(ab, cp), d6 = Vector3.Dot(ac, cp);
		if (d6 >= 0 && d5 <= d6)
			return c;
		let vb = d5 * d2 - d1 * d6;
		if (vb <= 0 && d2 >= 0 && d6 <= 0)
			return a + ac * (d2 / (d2 - d6));
		let va = d3 * d6 - d5 * d4;
		if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
			return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
		let denominator = 1 / (va + vb + vc);
		return a + ab * (vb * denominator) + ac * (vc * denominator);
	}

	/// Splits a face in two along a path from vertex a through new corners at `through` to vertex b (a and b may
	/// be next to each other when there are points between). Returns the new face (the part from b round to a), or
	/// -1. The new corners take texture coordinates and colours from where they lie in the face.
	public static int32 ConnectPath(EditMesh mesh, int32 faceIndex, int32 a, int32 b, Span<Vector3> through)
	{
		if (through.IsEmpty)
			return Connect(mesh, faceIndex, a, b);
		let face = mesh.faces[faceIndex];
		let ia = face.IndexOf(a), ib = face.IndexOf(b);
		let n = face.Count;
		if (ia < 0 || ib < 0 || ia == ib)
			return -1;
		let made = scope List<int32>();
		let uvs = scope List<Vector2>();
		let colors = scope List<Color>();
		for (let point in through)
		{
			Sample(mesh, face, point, let uv, let color);
			made.Add(mesh.AddVertex(point));
			uvs.Add(uv);
			colors.Add(color);
		}
		let first = new EditFace();
		let second = new EditFace();
		first.CopySettings(face);
		second.CopySettings(face);
		// First: a round to b, then back along the path. Second: b round to a, then along the path.
		for (int k = 0;; k++)
		{
			let i = (ia + k) % n;
			first.Add(face.verts[i], face.uvs[i], face.colors[i]);
			if (i == ib)
				break;
		}
		for (int k = made.Count - 1; k >= 0; k--)
			first.Add(made[k], uvs[k], colors[k]);
		for (int k = 0;; k++)
		{
			let i = (ib + k) % n;
			second.Add(face.verts[i], face.uvs[i], face.colors[i]);
			if (i == ia)
				break;
		}
		for (int k < made.Count)
			second.Add(made[k], uvs[k], colors[k]);
		face.CopyFrom(first);
		delete first;
		mesh.faces.Add(second);
		return (int32)mesh.faces.Count - 1;
	}

	/// The vertex at a point: a corner there, or a new one splitting the edge the point lies on; -1 if neither.
	static int32 KnifePoint(EditMesh mesh, Vector3 point, float tolerance)
	{
		for (int32 v < (int32)mesh.positions.Count)
		{
			if ((mesh.positions[v] - point).LengthSquared <= tolerance * tolerance)
				return v;
		}
		for (let face in mesh.faces)
		{
			for (int i < face.Count)
			{
				let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
				let pa = mesh.positions[a], pb = mesh.positions[b];
				let along = pb - pa;
				let length = along.LengthSquared;
				if (length < 1.0e-12f)
					continue;
				let t = Vector3.Dot(point - pa, along) / length;
				if (t <= 0 || t >= 1)
					continue;
				if ((pa + along * t - point).LengthSquared <= tolerance * tolerance)
					return SplitEdge(mesh, a, b, t);
			}
		}
		return -1;
	}

	/// Splits the face holding both vertices between them. False when no face holds both, or they are already
	/// joined by an edge.
	static bool CutBetween(EditMesh mesh, int32 a, int32 b)
	{
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			if (face.IndexOf(a) >= 0 && face.IndexOf(b) >= 0 && Connect(mesh, f, a, b) >= 0)
				return true;
		}
		return false;
	}

	/// Where the line from `from` to `to` (seen from the eye) crosses edges of faces looking towards the eye,
	/// sorted from `from`.
	static void KnifeCrossings(EditMesh mesh, Vector3 from, Vector3 to, Vector3 eye, float tolerance, List<(float along, Vector3 point)> into)
	{
		let planeNormal = Vector3.Cross(from - eye, to - eye);
		if (planeNormal.LengthSquared < 1.0e-14f)
			return;
		let n = planeNormal.Normalized;
		let span = to - from;
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		for (let pair in edgeFaces)
		{
			bool facing = false;
			for (let f in pair.value)
			{
				let face = mesh.faces[f];
				if (Vector3.Dot(mesh.FaceNormal(face), mesh.FaceCenter(face) - eye) < 0)
					facing = true;
			}
			if (!facing)
				continue;
			EditMesh.EdgeEnds(pair.key, let a, let b);
			let pa = mesh.positions[a], pb = mesh.positions[b];
			let da = Vector3.Dot(pa - eye, n), db = Vector3.Dot(pb - eye, n);
			if ((da > 0) == (db > 0) || Math.Abs(da - db) < 1.0e-12f)
				continue;
			let point = Vector3.Lerp(pa, pb, da / (da - db));
			// How far along from -> to the point is, seen from the eye.
			let d = point - eye;
			let cross = Vector3.Cross(span, d);
			if (cross.LengthSquared < 1.0e-14f)
				continue;
			let along = Vector3.Dot(Vector3.Cross(eye - from, d), cross) / cross.LengthSquared;
			if (along <= 0.0001f || along >= 0.9999f)
				continue;
			// In front of the eye, and not far behind the line itself (the back of the model).
			let onLine = from + span * along;
			if (Vector3.Dot(d, onLine - eye) <= 0)
				continue;
			if (d.Length > (onLine - eye).Length + Math.Max(span.Length, tolerance * 10))
				continue;
			into.Add((along, point));
		}
		into.Sort((x, y) => x.along <=> y.along);
	}
}
