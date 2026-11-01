using System;
using System.Collections;

namespace Tallow;

/// How a face gets its texture coordinates.
enum FaceUV : uint8
{
	/// Projected from the face's place, at one texture repeat a metre (Scale, Offset and Rotation adjust it). The
	/// coordinates follow every edit, so a wall keeps its bricks the same size however it is stretched.
	Auto,
	/// Kept as they are: unwrapped, projected or placed by hand in the UV editor.
	Manual
}

/// One face of an EditMesh: a polygon of three or more corners, each a vertex with its own texture coordinates and
/// colour. Corners run clockwise seen from the front (as Mesh.AddTriangle), so Cross(b - a, c - a) points outwards.
class EditFace
{
	public List<int32> verts = new .() ~ delete _;
	public List<Vector2> uvs = new .() ~ delete _;
	public List<Color> colors = new .() ~ delete _;
	/// Which material slot draws it: 0 is the Mesh Renderer's own material, 1 and up the Model Mesh's Materials.
	public int32 material;
	/// Shares normals with the smooth faces around it (across edges not marked hard) instead of looking flat.
	public bool smooth;
	public FaceUV uvMode = .Auto;
	/// Auto texture coordinates: metres a repeat covers, shift, and turn in degrees.
	public Vector2 uvScale = .(1, 1);
	public Vector2 uvOffset = .Zero;
	public float uvRotation;
	/// Hidden in the editor's edit mode (not saved): not drawn while editing, and not picked.
	public bool hidden;

	public int Count => verts.Count;

	public void Add(int32 vertex, Vector2 uv = .Zero, Color color = .White)
	{
		verts.Add(vertex);
		uvs.Add(uv);
		colors.Add(color);
	}

	public void Insert(int corner, int32 vertex, Vector2 uv, Color color)
	{
		verts.Insert(corner, vertex);
		uvs.Insert(corner, uv);
		colors.Insert(corner, color);
	}

	public void RemoveCorner(int corner)
	{
		verts.RemoveAt(corner);
		uvs.RemoveAt(corner);
		colors.RemoveAt(corner);
	}

	/// Turns the face to look the other way.
	public void Reverse()
	{
		Flip(verts);
		Flip(uvs);
		Flip(colors);
	}

	static void Flip<T>(List<T> list)
	{
		for (int i = 0, j = list.Count - 1; i < j; i++,j--)
		{
			let keep = list[i];
			list[i] = list[j];
			list[j] = keep;
		}
	}

	/// The corner holding a vertex, or -1.
	public int IndexOf(int32 vertex) => verts.IndexOf(vertex);

	/// Everything but the corners.
	public void CopySettings(EditFace from)
	{
		material = from.material;
		smooth = from.smooth;
		uvMode = from.uvMode;
		uvScale = from.uvScale;
		uvOffset = from.uvOffset;
		uvRotation = from.uvRotation;
		hidden = from.hidden;
	}

	public void CopyFrom(EditFace from)
	{
		CopySettings(from);
		verts.Set(from.verts);
		uvs.Set(from.uvs);
		colors.Set(from.colors);
	}

	/// The average colour of the corners.
	public Color AverageColor
	{
		get
		{
			var sum = Color(0, 0, 0, 0);
			for (let c in colors)
			{
				sum.r += c.r;
				sum.g += c.g;
				sum.b += c.b;
				sum.a += c.a;
			}
			let n = Math.Max(colors.Count, 1);
			return .(sum.r / n, sum.g / n, sum.b / n, sum.a / n);
		}
	}
}

/// A mesh made to be edited: shared vertices, polygon faces, seams for unwrapping and hard edges for smoothing.
/// The Model Mesh component keeps one in a scene as text, and Build turns it into a Mesh to draw. The modelling
/// operations are in MeshOps, the ready-made shapes in MeshShapes, unwrapping in MeshUV and booleans in MeshCsg.
/// Positions are in the object's own space.
class EditMesh
{
	public List<Vector3> positions = new .() ~ delete _;
	public List<EditFace> faces = new .() ~ DeleteContainerAndItems!(_);
	/// Edges (EdgeKey) the texture is cut along when unwrapping.
	public HashSet<uint64> seams = new .() ~ delete _;
	/// Edges (EdgeKey) smooth faces do not share normals across.
	public HashSet<uint64> hardEdges = new .() ~ delete _;
	/// Vertices whose texture coordinates stay where they are when unwrapping (pinned in the UV editor).
	public HashSet<int32> pins = new .() ~ delete _;

	public const int32 FormatVersion = 1;

	public static uint64 EdgeKey(int32 a, int32 b) => a < b ? ((uint64)(uint32)a << 32) | (uint32)b : ((uint64)(uint32)b << 32) | (uint32)a;

	public static void EdgeEnds(uint64 key, out int32 a, out int32 b)
	{
		a = (int32)(uint32)(key >> 32);
		b = (int32)(uint32)(key & 0xFFFFFFFF);
	}

	public int32 AddVertex(Vector3 position)
	{
		positions.Add(position);
		return (int32)positions.Count - 1;
	}

	/// Adds a face through the vertices given, clockwise from the front, with zero texture coordinates and white.
	public EditFace AddFace(params Span<int32> verts)
	{
		let face = new EditFace();
		for (let v in verts)
			face.Add(v);
		faces.Add(face);
		return face;
	}

	public void Clear()
	{
		positions.Clear();
		ClearAndDeleteItems!(faces);
		seams.Clear();
		hardEdges.Clear();
		pins.Clear();
	}

	public void CopyFrom(EditMesh from)
	{
		Clear();
		positions.AddRange(from.positions);
		for (let face in from.faces)
		{
			let copy = new EditFace();
			copy.CopyFrom(face);
			faces.Add(copy);
		}
		for (let key in from.seams)
			seams.Add(key);
		for (let key in from.hardEdges)
			hardEdges.Add(key);
		for (let v in from.pins)
			pins.Add(v);
	}

	public EditMesh Clone()
	{
		let copy = new EditMesh();
		copy.CopyFrom(this);
		return copy;
	}

	/// Adds every face of another mesh, its vertices moved by a matrix (faces turned when it mirrors).
	public void Append(EditMesh other, Matrix4 transform)
	{
		let baseVertex = (int32)positions.Count;
		for (let p in other.positions)
			positions.Add(transform.TransformPoint(p));
		let mirrored = Vector3.Dot(Vector3.Cross(transform.TransformDirection(.Right), transform.TransformDirection(.Up)), transform.TransformDirection(.Forward)) < 0;
		for (let face in other.faces)
		{
			let copy = new EditFace();
			copy.CopyFrom(face);
			for (var v in ref copy.verts)
				v += baseVertex;
			if (mirrored)
				copy.Reverse();
			faces.Add(copy);
		}
		for (let key in other.seams)
		{
			EdgeEnds(key, let a, let b);
			seams.Add(EdgeKey(a + baseVertex, b + baseVertex));
		}
		for (let key in other.hardEdges)
		{
			EdgeEnds(key, let a, let b);
			hardEdges.Add(EdgeKey(a + baseVertex, b + baseVertex));
		}
		for (let v in other.pins)
			pins.Add(v + baseVertex);
	}

	// ---- measuring ----

	/// The face's outward direction (Newell's method, so bent and concave faces work too).
	public Vector3 FaceNormal(EditFace face)
	{
		var normal = Vector3.Zero;
		let n = face.Count;
		if (n < 3)
			return .Up;
		let origin = positions[face.verts[0]];
		for (int i = 1; i + 1 < n; i++)
			normal = normal + Vector3.Cross(positions[face.verts[i]] - origin, positions[face.verts[i + 1]] - origin);
		return normal.LengthSquared > 1.0e-20f ? normal.Normalized : .Up;
	}

	public Vector3 FaceCenter(EditFace face)
	{
		var sum = Vector3.Zero;
		for (let v in face.verts)
			sum = sum + positions[v];
		return face.Count > 0 ? sum / face.Count : .Zero;
	}

	public float FaceArea(EditFace face)
	{
		var normal = Vector3.Zero;
		let origin = positions[face.verts[0]];
		for (int i = 1; i + 1 < face.Count; i++)
			normal = normal + Vector3.Cross(positions[face.verts[i]] - origin, positions[face.verts[i + 1]] - origin);
		return normal.Length * 0.5f;
	}

	/// The space enclosed, positive when the faces point outwards. Only meaningful for a closed mesh.
	public float Volume()
	{
		double sum = 0;
		let corners = scope List<int32>();
		for (let face in faces)
		{
			corners.Clear();
			Triangulate(face, corners);
			for (int i = 0; i + 2 < corners.Count; i += 3)
			{
				let a = positions[face.verts[corners[i]]], b = positions[face.verts[corners[i + 1]]], c = positions[face.verts[corners[i + 2]]];
				sum += Vector3.Dot(a, Vector3.Cross(b, c));
			}
		}
		// Faces whose Cross(b - a, c - a) points outwards enclose positive volume (divergence theorem).
		return (float)(sum / 6.0);
	}

	public Bounds Bounds
	{
		get
		{
			var bounds = Tallow.Bounds.Empty;
			for (let p in positions)
				bounds.Encapsulate(p);
			return positions.IsEmpty ? .(.Zero, .Zero) : bounds;
		}
	}

	public int32 MaterialCount
	{
		get
		{
			int32 count = 1;
			for (let face in faces)
				count = Math.Max(count, face.material + 1);
			return count;
		}
	}

	/// Whether any face is hidden in the editor.
	public bool AnyHidden
	{
		get
		{
			for (let face in faces)
			{
				if (face.hidden)
					return true;
			}
			return false;
		}
	}

	public bool AnySmooth
	{
		get
		{
			for (let face in faces)
			{
				if (face.smooth)
					return true;
			}
			return false;
		}
	}

	// ---- topology ----

	/// For every edge, the faces using it.
	public void EdgeFaces(Dictionary<uint64, List<int32>> into)
	{
		for (let list in into.Values)
			delete list;
		into.Clear();
		for (int32 f < (int32)faces.Count)
		{
			let face = faces[f];
			for (int i < face.Count)
			{
				let key = EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
				if (into.TryAdd(key, ?, let value))
					*value = new List<int32>();
				into[key].Add(f);
			}
		}
	}

	/// Every edge once.
	public void Edges(List<uint64> into)
	{
		let seen = scope HashSet<uint64>();
		for (let face in faces)
		{
			for (int i < face.Count)
			{
				let key = EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
				if (seen.Add(key))
					into.Add(key);
			}
		}
	}

	/// True when every edge has exactly two faces, each using it once in each direction: a watertight solid.
	public bool IsClosed()
	{
		let directed = scope Dictionary<uint64, int32>();
		for (let face in faces)
		{
			for (int i < face.Count)
			{
				let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
				let key = EdgeKey(a, b);
				let step = a < b ? 1 : 1000;
				if (directed.TryAdd(key, ?, let value))
					*value = 0;
				directed[key] += (int32)step;
			}
		}
		for (let count in directed.Values)
		{
			if (count != 1001)
				return false;
		}
		return !faces.IsEmpty;
	}

	/// The faces using a vertex.
	public void FacesOfVertex(int32 vertex, List<int32> into)
	{
		for (int32 f < (int32)faces.Count)
		{
			if (faces[f].IndexOf(vertex) >= 0)
				into.Add(f);
		}
	}

	/// Drops corners that repeat the one before them, faces left with fewer than three, and vertices no face uses.
	public void Clean()
	{
		for (int f = faces.Count - 1; f >= 0; f--)
		{
			let face = faces[f];
			for (int i = face.Count - 1; i >= 0 && face.Count > 0; i--)
			{
				let next = (i + 1) % face.Count;
				if (next != i && face.verts[i] == face.verts[next])
					face.RemoveCorner(i);
			}
			if (face.Count < 3 || HasRepeat(face))
			{
				delete face;
				faces.RemoveAt(f);
			}
		}
		RemoveUnusedVertices();
	}

	static bool HasRepeat(EditFace face)
	{
		for (int i < face.Count)
		{
			for (int j = i + 1; j < face.Count; j++)
			{
				if (face.verts[i] == face.verts[j])
					return true;
			}
		}
		return false;
	}

	/// Removes vertices no face uses, renumbering the rest (and the seams and hard edges with them).
	public void RemoveUnusedVertices()
	{
		let used = scope bool[positions.Count];
		for (let face in faces)
		{
			for (let v in face.verts)
				used[v] = true;
		}
		let remap = scope int32[positions.Count];
		let kept = scope List<Vector3>();
		for (int i < positions.Count)
		{
			remap[i] = used[i] ? (int32)kept.Count : -1;
			if (used[i])
				kept.Add(positions[i]);
		}
		if (kept.Count == positions.Count)
			return;
		positions.Set(kept);
		Renumber(remap);
	}

	/// Moves every vertex reference through a table (old number to new; -1 drops seams and hard edges using it).
	public void Renumber(Span<int32> remap)
	{
		for (let face in faces)
		{
			for (var v in ref face.verts)
				v = remap[v];
		}
		RemapEdgeSet(seams, remap);
		RemapEdgeSet(hardEdges, remap);
		if (!pins.IsEmpty)
		{
			let old = scope List<int32>();
			for (let v in pins)
				old.Add(v);
			pins.Clear();
			for (let v in old)
			{
				if (v < remap.Length && remap[v] >= 0)
					pins.Add(remap[v]);
			}
		}
	}

	static void RemapEdgeSet(HashSet<uint64> edges, Span<int32> remap)
	{
		if (edges.IsEmpty)
			return;
		let old = scope List<uint64>();
		for (let key in edges)
			old.Add(key);
		edges.Clear();
		for (let key in old)
		{
			EdgeEnds(key, let a, let b);
			if (a >= remap.Length || b >= remap.Length)
				continue;
			let na = remap[a], nb = remap[b];
			if (na >= 0 && nb >= 0 && na != nb)
				edges.Add(EdgeKey(na, nb));
		}
	}

	/// Joins vertices closer than a distance into one (the first of them), then cleans up what collapsed.
	public int Weld(float distance = 0.0001f)
	{
		let cell = Math.Max(distance, 1.0e-6f) * 2;
		let grid = scope Dictionary<int64, List<int32>>();
		defer
		{
			for (let list in grid.Values)
				delete list;
		}
		let remap = scope int32[positions.Count];
		int merged = 0;
		for (int32 i < (int32)positions.Count)
		{
			let p = positions[i];
			let cx = (int64)Math.Floor(p.x / cell), cy = (int64)Math.Floor(p.y / cell), cz = (int64)Math.Floor(p.z / cell);
			int32 found = -1;
			for (int64 dx = -1; dx <= 1 && found < 0; dx++)
			{
				for (int64 dy = -1; dy <= 1 && found < 0; dy++)
				{
					for (int64 dz = -1; dz <= 1 && found < 0; dz++)
					{
						if (grid.TryGetValue(CellKey(cx + dx, cy + dy, cz + dz), let list))
						{
							for (let other in list)
							{
								if ((positions[other] - p).Length <= distance)
								{
									found = other;
									break;
								}
							}
						}
					}
				}
			}
			if (found >= 0)
			{
				remap[i] = found;
				merged++;
				continue;
			}
			remap[i] = i;
			let key = CellKey(cx, cy, cz);
			if (grid.TryAdd(key, ?, let value))
				*value = new List<int32>();
			grid[key].Add(i);
		}
		if (merged > 0)
		{
			Renumber(remap);
			Clean();
		}
		return merged;
	}

	static int64 CellKey(int64 x, int64 y, int64 z) => ((x & 0x1FFFFF) << 42) | ((y & 0x1FFFFF) << 21) | (z & 0x1FFFFF);

	// ---- triangles ----

	/// Splits a face into triangles: three corner numbers a triangle, appended to the list. Works for concave faces.
	public void Triangulate(EditFace face, List<int32> corners)
	{
		let n = face.Count;
		if (n < 3)
			return;
		if (n == 3)
		{
			corners.Add(0);
			corners.Add(1);
			corners.Add(2);
			return;
		}
		// Flatten the face onto its own plane.
		let normal = FaceNormal(face);
		let axisU = (Math.Abs(normal.y) < 0.9f ? Vector3.Cross(normal, .Up) : Vector3.Cross(normal, .Right)).Normalized;
		let axisV = Vector3.Cross(normal, axisU);
		let points = scope Vector2[n];
		for (int i < n)
		{
			let p = positions[face.verts[i]];
			points[i] = .(Vector3.Dot(p, axisU), Vector3.Dot(p, axisV));
		}
		float area = 0;
		for (int i < n)
		{
			let a = points[i], b = points[(i + 1) % n];
			area += a.x * b.y - b.x * a.y;
		}
		let sign = area >= 0 ? 1.0f : -1.0f;
		if (n == 4 && Convex2D(points, sign))
		{
			// A quad: cut along the shorter diagonal, which keeps bent quads closer to their shape.
			let d02 = (positions[face.verts[0]] - positions[face.verts[2]]).LengthSquared;
			let d13 = (positions[face.verts[1]] - positions[face.verts[3]]).LengthSquared;
			if (d02 <= d13)
			{
				corners.Add(0);
				corners.Add(1);
				corners.Add(2);
				corners.Add(0);
				corners.Add(2);
				corners.Add(3);
			}
			else
			{
				corners.Add(0);
				corners.Add(1);
				corners.Add(3);
				corners.Add(1);
				corners.Add(2);
				corners.Add(3);
			}
			return;
		}
		// Ear clipping.
		let remaining = scope List<int32>();
		for (int32 i < (int32)n)
			remaining.Add(i);
		int guard = n * n + 8;
		while (remaining.Count > 3 && guard-- > 0)
		{
			bool clipped = false;
			for (int i < remaining.Count)
			{
				let ia = remaining[(i + remaining.Count - 1) % remaining.Count], ib = remaining[i], ic = remaining[(i + 1) % remaining.Count];
				let a = points[ia], b = points[ib], c = points[ic];
				let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
				if (cross * sign <= 1.0e-12f)
					continue;
				bool inside = false;
				for (let other in remaining)
				{
					if (other == ia || other == ib || other == ic)
						continue;
					if (InTriangle(points[other], a, b, c, sign))
					{
						inside = true;
						break;
					}
				}
				if (inside)
					continue;
				corners.Add(ia);
				corners.Add(ib);
				corners.Add(ic);
				remaining.RemoveAt(i);
				clipped = true;
				break;
			}
			if (!clipped)
				break;
		}
		// What is left (a triangle, or a degenerate scrap) is fanned.
		for (int i = 1; i + 1 < remaining.Count; i++)
		{
			corners.Add(remaining[0]);
			corners.Add(remaining[i]);
			corners.Add(remaining[i + 1]);
		}
	}

	static bool Convex2D(Span<Vector2> points, float sign)
	{
		let n = points.Length;
		for (int i < n)
		{
			let a = points[i], b = points[(i + 1) % n], c = points[(i + 2) % n];
			if (((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)) * sign < 0)
				return false;
		}
		return true;
	}

	static bool InTriangle(Vector2 p, Vector2 a, Vector2 b, Vector2 c, float sign)
	{
		let d1 = ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) * sign;
		let d2 = ((c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)) * sign;
		let d3 = ((a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)) * sign;
		return d1 >= 0 && d2 >= 0 && d3 >= 0;
	}

	/// The nearest face a ray (in the mesh's space) hits from either side, or -1. distance is along the ray.
	public int32 Raycast(Ray ray, out float distance, out Vector3 point, bool skipHidden = false)
	{
		distance = float.MaxValue;
		point = .Zero;
		int32 best = -1;
		let corners = scope List<int32>();
		for (int32 f < (int32)faces.Count)
		{
			let face = faces[f];
			if (skipHidden && face.hidden)
				continue;
			corners.Clear();
			Triangulate(face, corners);
			for (int i = 0; i + 2 < corners.Count; i += 3)
			{
				let t = RayTriangle(ray, positions[face.verts[corners[i]]], positions[face.verts[corners[i + 1]]], positions[face.verts[corners[i + 2]]]);
				if (t >= 0 && t < distance)
				{
					distance = t;
					best = f;
				}
			}
		}
		if (best >= 0)
			point = ray.GetPoint(distance);
		return best;
	}

	/// Distance along a ray to a triangle, either side, or -1 (Moller-Trumbore).
	public static float RayTriangle(Ray ray, Vector3 a, Vector3 b, Vector3 c)
	{
		let e1 = b - a, e2 = c - a;
		let p = Vector3.Cross(ray.direction, e2);
		let det = Vector3.Dot(e1, p);
		if (Math.Abs(det) < 1.0e-12f)
			return -1;
		let inv = 1.0f / det;
		let s = ray.origin - a;
		let u = Vector3.Dot(s, p) * inv;
		if (u < 0 || u > 1)
			return -1;
		let q = Vector3.Cross(s, e1);
		let v = Vector3.Dot(ray.direction, q) * inv;
		if (v < 0 || u + v > 1)
			return -1;
		let t = Vector3.Dot(e2, q) * inv;
		return t >= 0 ? t : -1;
	}

	// ---- texture coordinates ----

	/// Projects a point for an Auto face: from the side the face mostly looks, in metres (times the object's scale),
	/// then turned, sized and shifted by the face's settings. V grows downwards, as in pictures.
	public static Vector2 AutoUV(Vector3 position, Vector3 normal, EditFace face, Vector3 scale)
	{
		let p = Vector3(position.x * scale.x, position.y * scale.y, position.z * scale.z);
		let ax = Math.Abs(normal.x), ay = Math.Abs(normal.y), az = Math.Abs(normal.z);
		Vector2 uv;
		if (ay >= ax && ay >= az)
			uv = .(normal.y >= 0 ? p.x : -p.x, -p.z);
		else if (ax >= az)
			uv = .(normal.x >= 0 ? p.z : -p.z, -p.y);
		else
			uv = .(normal.z >= 0 ? -p.x : p.x, -p.y);
		if (face.uvRotation != 0)
		{
			let radians = face.uvRotation * Mathf.Deg2Rad;
			let cs = Math.Cos(radians), sn = Math.Sin(radians);
			uv = .(uv.x * cs - uv.y * sn, uv.x * sn + uv.y * cs);
		}
		let size = Vector2(Math.Abs(face.uvScale.x) > 1.0e-5f ? face.uvScale.x : 1, Math.Abs(face.uvScale.y) > 1.0e-5f ? face.uvScale.y : 1);
		return .(uv.x / size.x + face.uvOffset.x, uv.y / size.y + face.uvOffset.y);
	}

	/// Works out the texture coordinates of every Auto face (scale: the object's, so repeats stay a metre).
	public void UpdateAutoUVs(Vector3 scale)
	{
		for (let face in faces)
		{
			if (face.uvMode != .Auto)
				continue;
			let normal = FaceNormal(face);
			for (int i < face.Count)
				face.uvs[i] = AutoUV(positions[face.verts[i]], normal, face, scale);
		}
	}

	// ---- drawing ----

	/// Fills a Mesh to draw: every face's triangles, with its corners' coordinates and colours, flat normals for
	/// flat faces and shared ones among smooth faces. material: only faces in that slot (-1 for all). Auto faces'
	/// coordinates are worked out first, for an object of the scale given. skipHidden leaves hidden faces out.
	public void Build(Mesh mesh, Vector3 scale, int32 material = -1, bool skipHidden = false)
	{
		mesh.Clear();
		UpdateAutoUVs(scale);
		let faceNormals = scope Vector3[faces.Count];
		for (int f < faces.Count)
			faceNormals[f] = FaceNormal(faces[f]);
		// Smooth faces share normals within groups joined by edges that are not hard.
		int32[] groups = null;
		defer delete groups;
		if (AnySmooth)
		{
			groups = new int32[faces.Count];
			SmoothGroups(groups);
		}
		Dictionary<int64, Vector3> smoothNormals = null;
		defer delete smoothNormals;
		if (groups != null)
		{
			smoothNormals = new .();
			for (int f < faces.Count)
			{
				if (groups[f] < 0)
					continue;
				let weighted = faceNormals[f] * FaceArea(faces[f]);
				for (let v in faces[f].verts)
				{
					let key = ((int64)groups[f] << 32) | v;
					if (smoothNormals.TryAdd(key, ?, let value))
						*value = .Zero;
					smoothNormals[key] = smoothNormals[key] + weighted;
				}
			}
		}
		let corners = scope List<int32>();
		for (int f < faces.Count)
		{
			let face = faces[f];
			if ((material >= 0 && face.material != material) || (skipHidden && face.hidden))
				continue;
			let first = (uint32)mesh.Vertices.Count;
			for (int i < face.Count)
			{
				var normal = faceNormals[f];
				if (groups != null && groups[f] >= 0 && smoothNormals.TryGetValue(((int64)groups[f] << 32) | face.verts[i], let summed) && summed.LengthSquared > 1.0e-20f)
					normal = summed.Normalized;
				mesh.AddVertex(positions[face.verts[i]], normal, face.colors[i], face.uvs[i]);
			}
			corners.Clear();
			Triangulate(face, corners);
			for (int i = 0; i + 2 < corners.Count; i += 3)
				mesh.AddTriangle(first + (uint32)corners[i], first + (uint32)corners[i + 1], first + (uint32)corners[i + 2]);
		}
		mesh.RecalculateBounds();
	}

	/// Numbers the groups of smooth faces joined across edges that are not hard; -1 for flat faces.
	public void SmoothGroups(Span<int32> groups)
	{
		for (int f < faces.Count)
			groups[f] = -1;
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		EdgeFaces(edgeFaces);
		int32 next = 0;
		let stack = scope List<int32>();
		for (int32 f < (int32)faces.Count)
		{
			if (!faces[f].smooth || groups[f] >= 0)
				continue;
			groups[f] = next;
			stack.Add(f);
			while (!stack.IsEmpty)
			{
				let current = stack.PopBack();
				let face = faces[current];
				for (int i < face.Count)
				{
					let key = EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
					if (hardEdges.Contains(key))
						continue;
					for (let other in edgeFaces[key])
					{
						if (groups[other] < 0 && faces[other].smooth)
						{
							groups[other] = next;
							stack.Add(other);
						}
					}
				}
			}
			next++;
		}
	}

	// ---- from a Mesh ----

	/// Makes an editable mesh from a drawn one: corners at the same place become one vertex, and neighbouring
	/// triangles lying flat together (with matching texture coordinates) become one face again.
	public static EditMesh FromMesh(Mesh mesh, float weld = 0.0001f)
	{
		let edit = new EditMesh();
		for (let v in mesh.Vertices)
			edit.positions.Add(v.position);
		for (int i = 0; i + 2 < mesh.Indices.Count; i += 3)
		{
			let face = new EditFace();
			face.uvMode = .Manual;
			for (int k < 3)
			{
				let index = mesh.Indices[i + k];
				let vertex = mesh.Vertices[(int)index];
				face.Add((int32)index, vertex.uv, ColorFromABGR(vertex.color));
			}
			// Smooth where the drawn normals lean away from the triangle's own (they were shared with neighbours).
			let normal = edit.FaceNormal(face);
			for (int k < 3)
			{
				if (Vector3.Dot(mesh.Vertices[(int)mesh.Indices[i + k]].normal, normal) < 0.999f)
					face.smooth = true;
			}
			edit.faces.Add(face);
		}
		edit.Weld(weld);
		edit.MergeFlatNeighbours();
		return edit;
	}

	public static Color ColorFromABGR(uint32 c) => .((c & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f, ((c >> 16) & 0xFF) / 255.0f, ((c >> 24) & 0xFF) / 255.0f);

	/// Joins neighbouring faces that lie in one plane, share the material and settings, and meet with the same
	/// texture coordinates and colours along the shared edge. Faces stay simple polygons.
	public int MergeFlatNeighbours(float tolerance = 0.9999f)
	{
		int merged = 0;
		bool again = true;
		while (again)
		{
			again = false;
			let edgeFaces = scope Dictionary<uint64, List<int32>>();
			EdgeFaces(edgeFaces);
			defer
			{
				for (let list in edgeFaces.Values)
					delete list;
			}
			let gone = scope HashSet<int32>();
			for (let pair in edgeFaces)
			{
				let list = pair.value;
				if (list.Count != 2 || list[0] == list[1] || gone.Contains(list[0]) || gone.Contains(list[1]))
					continue;
				let fa = faces[list[0]], fb = faces[list[1]];
				if (fa.material != fb.material || fa.smooth != fb.smooth || fa.uvMode != fb.uvMode)
					continue;
				if (Vector3.Dot(FaceNormal(fa), FaceNormal(fb)) < tolerance)
					continue;
				EdgeEnds(pair.key, let a, let b);
				if (!JoinFaces(fa, fb, a, b))
					continue;
				gone.Add(list[1]);
				merged++;
				again = true;
			}
			if (gone.IsEmpty)
				break;
			let ordered = scope List<int32>();
			for (let f in gone)
				ordered.Add(f);
			ordered.Sort((x, y) => y <=> x);
			for (let f in ordered)
			{
				delete faces[f];
				faces.RemoveAt(f);
			}
		}
		return merged;
	}

	/// Puts face b into face a across their shared edge (a-b). False (and nothing changed) if the corners do not
	/// match along it or the result would not be a simple polygon. b is left for the caller to delete.
	bool JoinFaces(EditFace fa, EditFace fb, int32 va, int32 vb)
	{
		// In fa the edge runs one way, in fb the other.
		var ia = fa.IndexOf(va);
		var ja = fa.IndexOf(vb);
		if (ia < 0 || ja < 0)
			return false;
		// Make fa run ... va -> vb ...
		if ((ia + 1) % fa.Count != ja)
		{
			if ((ja + 1) % fa.Count != ia)
				return false;
			Swap!(ia, ja);
		}
		let fromV = fa.verts[ia], toV = fa.verts[ja];
		let ib = fb.IndexOf(toV), jb = fb.IndexOf(fromV);
		if (ib < 0 || jb < 0 || (ib + 1) % fb.Count != jb)
			return false;
		// Matching texture coordinates and colours at both ends of the edge.
		if ((fa.uvs[ia] - fb.uvs[jb]).LengthSquared > 1.0e-8f || (fa.uvs[ja] - fb.uvs[ib]).LengthSquared > 1.0e-8f)
			return false;
		if (!SameColor(fa.colors[ia], fb.colors[jb]) || !SameColor(fa.colors[ja], fb.colors[ib]))
			return false;
		// The new corner list: fa from toV round to fromV, then fb's corners strictly between fromV and toV.
		let verts = scope List<int32>();
		let uvs = scope List<Vector2>();
		let colors = scope List<Color>();
		for (int k < fa.Count)
		{
			let i = (ja + k) % fa.Count;
			verts.Add(fa.verts[i]);
			uvs.Add(fa.uvs[i]);
			colors.Add(fa.colors[i]);
		}
		for (int k = 1; k < fb.Count - 1; k++)
		{
			let i = (jb + k) % fb.Count;
			verts.Add(fb.verts[i]);
			uvs.Add(fb.uvs[i]);
			colors.Add(fb.colors[i]);
		}
		for (int i < verts.Count)
		{
			for (int j = i + 1; j < verts.Count; j++)
			{
				if (verts[i] == verts[j])
					return false;
			}
		}
		fa.verts.Set(verts);
		fa.uvs.Set(uvs);
		fa.colors.Set(colors);
		return true;
	}

	static bool SameColor(Color a, Color b) => Math.Abs(a.r - b.r) + Math.Abs(a.g - b.g) + Math.Abs(a.b - b.b) + Math.Abs(a.a - b.a) < 0.004f;

	// ---- text ----

	/// Writes the mesh as .tmesh text: "v x y z" lines, then "f" lines (material, smooth, uv mode, scale, offset,
	/// rotation, then "|" corners as vertex u v rrggbbaa), then "seam a b", "hard a b" and "pin v".
	public void Write(String text)
	{
		text.AppendF("tmesh {}\n", FormatVersion);
		for (let p in positions)
		{
			text.Append("v ");
			AppendNumber(text, p.x);
			text.Append(' ');
			AppendNumber(text, p.y);
			text.Append(' ');
			AppendNumber(text, p.z);
			text.Append('\n');
		}
		for (let face in faces)
		{
			text.AppendF("f {} {} {} ", face.material, face.smooth ? 1 : 0, face.uvMode == .Manual ? 1 : 0);
			AppendNumber(text, face.uvScale.x);
			text.Append(' ');
			AppendNumber(text, face.uvScale.y);
			text.Append(' ');
			AppendNumber(text, face.uvOffset.x);
			text.Append(' ');
			AppendNumber(text, face.uvOffset.y);
			text.Append(' ');
			AppendNumber(text, face.uvRotation);
			text.Append(" |");
			for (int i < face.Count)
			{
				text.AppendF(" {}", face.verts[i]);
				if (face.uvMode == .Manual)
				{
					text.Append(' ');
					AppendNumber(text, face.uvs[i].x);
					text.Append(' ');
					AppendNumber(text, face.uvs[i].y);
				}
				let c = face.colors[i];
				text.AppendF(" {:X8}", ((uint32)ToByte(c.r) << 24) | ((uint32)ToByte(c.g) << 16) | ((uint32)ToByte(c.b) << 8) | ToByte(c.a));
			}
			text.Append('\n');
		}
		for (let key in SortedEdges(seams, .. scope .()))
		{
			EdgeEnds(key, let a, let b);
			text.AppendF("seam {} {}\n", a, b);
		}
		for (let key in SortedEdges(hardEdges, .. scope .()))
		{
			EdgeEnds(key, let a, let b);
			text.AppendF("hard {} {}\n", a, b);
		}
		let pinned = scope List<int32>();
		for (let v in pins)
			pinned.Add(v);
		pinned.Sort();
		for (let v in pinned)
			text.AppendF("pin {}\n", v);
	}

	static void SortedEdges(HashSet<uint64> edges, List<uint64> into)
	{
		for (let key in edges)
			into.Add(key);
		into.Sort();
	}

	static uint8 ToByte(float v) => (uint8)Math.Clamp((int)Math.Round(v * 255), 0, 255);

	/// A number to six decimal places, without trailing zeros ("0.5", "-2", "0.000125").
	static void AppendNumber(String text, float value)
	{
		var scaled = (int64)Math.Round((double)value * 1000000.0);
		if (scaled == 0)
		{
			text.Append('0');
			return;
		}
		if (scaled < 0)
		{
			text.Append('-');
			scaled = -scaled;
		}
		text.AppendF("{}", scaled / 1000000);
		var fraction = scaled % 1000000;
		if (fraction == 0)
			return;
		var digits = 6;
		while (fraction % 10 == 0)
		{
			fraction /= 10;
			digits--;
		}
		text.Append('.');
		let start = text.Length;
		text.AppendF("{}", fraction);
		// Leading zeros of the fraction.
		let missing = digits - (text.Length - start);
		for (int i < missing)
			text.Insert(start, '0');
	}

	static bool ParseHex(StringView token, out uint32 value)
	{
		value = 0;
		if (token.IsEmpty || token.Length > 8)
			return false;
		for (let c in token.RawChars)
		{
			uint32 digit;
			if (c >= '0' && c <= '9')
				digit = (uint32)(c - '0');
			else if (c >= 'a' && c <= 'f')
				digit = (uint32)(c - 'a' + 10);
			else if (c >= 'A' && c <= 'F')
				digit = (uint32)(c - 'A' + 10);
			else
				return false;
			value = (value << 4) | digit;
		}
		return true;
	}

	/// Reads .tmesh text. False (and the mesh left empty) when it is not one.
	public bool Read(StringView source)
	{
		Clear();
		bool header = false;
		for (var line in source.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			var parts = line.Split(' ', .RemoveEmptyEntries);
			let kind = parts.GetNext().GetValueOrDefault();
			switch (kind)
			{
			case "tmesh":
				header = true;
			case "v":
				let x = Number(parts.GetNext().GetValueOrDefault()), y = Number(parts.GetNext().GetValueOrDefault()), z = Number(parts.GetNext().GetValueOrDefault());
				positions.Add(.(x, y, z));
			case "f":
				let face = new EditFace();
				face.material = (int32)Number(parts.GetNext().GetValueOrDefault());
				face.smooth = parts.GetNext().GetValueOrDefault() == "1";
				face.uvMode = parts.GetNext().GetValueOrDefault() == "1" ? .Manual : .Auto;
				face.uvScale.x = Number(parts.GetNext().GetValueOrDefault());
				face.uvScale.y = Number(parts.GetNext().GetValueOrDefault());
				face.uvOffset.x = Number(parts.GetNext().GetValueOrDefault());
				face.uvOffset.y = Number(parts.GetNext().GetValueOrDefault());
				face.uvRotation = Number(parts.GetNext().GetValueOrDefault());
				if (parts.GetNext().GetValueOrDefault() != "|")
				{
					delete face;
					continue;
				}
				while (parts.GetNext() case .Ok(let token))
				{
					let vertex = (int32)Number(token);
					var uv = Vector2.Zero;
					if (face.uvMode == .Manual)
					{
						uv.x = Number(parts.GetNext().GetValueOrDefault());
						uv.y = Number(parts.GetNext().GetValueOrDefault());
					}
					var color = Color.White;
					if (parts.GetNext() case .Ok(let hex))
					{
						if (ParseHex(hex, let packed))
							color = .(((packed >> 24) & 0xFF) / 255.0f, ((packed >> 16) & 0xFF) / 255.0f, ((packed >> 8) & 0xFF) / 255.0f, (packed & 0xFF) / 255.0f);
					}
					face.Add(vertex, uv, color);
				}
				faces.Add(face);
			case "seam","hard":
				let a = (int32)Number(parts.GetNext().GetValueOrDefault()), b = (int32)Number(parts.GetNext().GetValueOrDefault());
				(kind == "seam" ? seams : hardEdges).Add(EdgeKey(a, b));
			case "pin":
				pins.Add((int32)Number(parts.GetNext().GetValueOrDefault()));
			default:
			}
		}
		// Faces naming vertices that are not there are dropped.
		for (int f = faces.Count - 1; f >= 0; f--)
		{
			bool bad = faces[f].Count < 3;
			for (let v in faces[f].verts)
				bad |= v < 0 || v >= positions.Count;
			if (bad)
			{
				delete faces[f];
				faces.RemoveAt(f);
			}
		}
		pins.RemoveWhere(scope (v) => v < 0 || v >= positions.Count);
		if (!header)
			Clear();
		return header;
	}

	static float Number(StringView token) => float.Parse(token) case .Ok(let value) ? value : 0;
}
