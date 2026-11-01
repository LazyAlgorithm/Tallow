using System;
using System.Collections;

namespace Tallow;

/// Texture coordinates for an EditMesh: projections, unwrapping along seams, a smart unwrap that finds its own
/// pieces, and packing pieces into the picture. Everything here sets faces to Manual coordinates.
static class MeshUV
{
	// ---- projections ----

	/// Projects faces flat from the way they face on average, fitted into the picture keeping their shape.
	public static void Planar(EditMesh mesh, Span<int32> faces)
	{
		var normal = Vector3.Zero;
		for (let f in faces)
			normal = normal + mesh.FaceNormal(mesh.faces[f]) * mesh.FaceArea(mesh.faces[f]);
		if (normal.LengthSquared < 1.0e-12f)
			normal = .Up;
		normal = normal.Normalized;
		Basis(normal, let axisU, let axisV);
		for (let f in faces)
		{
			let face = mesh.faces[f];
			face.uvMode = .Manual;
			for (int i < face.Count)
			{
				let p = mesh.positions[face.verts[i]];
				face.uvs[i] = .(Vector3.Dot(p, axisU), -Vector3.Dot(p, axisV));
			}
		}
		FitAll(mesh, faces);
	}

	/// Each face from the side of a box it looks at most, at one repeat a metre (as Auto, but kept).
	public static void Box(EditMesh mesh, Span<int32> faces, float metresPerRepeat = 1)
	{
		for (let f in faces)
		{
			let face = mesh.faces[f];
			let normal = mesh.FaceNormal(face);
			let probe = scope EditFace();
			probe.uvScale = .(metresPerRepeat, metresPerRepeat);
			for (int i < face.Count)
				face.uvs[i] = EditMesh.AutoUV(mesh.positions[face.verts[i]], normal, probe, .One);
			face.uvMode = .Manual;
		}
	}

	/// Round an axis (0 x, 1 y, 2 z) through the faces' centre: across is the angle, up the height.
	public static void Cylinder(EditMesh mesh, Span<int32> faces, int axis = 1)
	{
		let bounds = FacesBounds(mesh, faces);
		let center = bounds.Center;
		let height = Math.Max(MeshOps.Component(bounds.max - bounds.min, axis), 1.0e-5f);
		for (let f in faces)
		{
			let face = mesh.faces[f];
			face.uvMode = .Manual;
			for (int i < face.Count)
			{
				let p = mesh.positions[face.verts[i]] - center;
				let a = axis == 0 ? p.y : p.x, b = axis == 2 ? p.y : p.z;
				let angle = Math.Atan2(b, a) / (Math.PI_f * 2) + 0.5f;
				face.uvs[i] = .(angle, 1 - (MeshOps.Component(p, axis) / height + 0.5f));
			}
			FixWrap(face);
		}
	}

	/// Round the faces' centre: across is the angle round Y, up the angle from the bottom.
	public static void Sphere(EditMesh mesh, Span<int32> faces)
	{
		let center = FacesBounds(mesh, faces).Center;
		for (let f in faces)
		{
			let face = mesh.faces[f];
			face.uvMode = .Manual;
			for (int i < face.Count)
			{
				let p = (mesh.positions[face.verts[i]] - center).Normalized;
				face.uvs[i] = .(Math.Atan2(p.z, p.x) / (Math.PI_f * 2) + 0.5f, Math.Acos(Mathf.Clamp(p.y, -1, 1)) / Math.PI_f);
			}
			FixWrap(face);
		}
	}

	/// A face crossing the join of an angle-based projection would stretch across the whole picture: move its low
	/// corners round by one.
	static void FixWrap(EditFace face)
	{
		float min = float.MaxValue, max = -float.MaxValue;
		for (let uv in face.uvs)
		{
			min = Math.Min(min, uv.x);
			max = Math.Max(max, uv.x);
		}
		if (max - min <= 0.5f)
			return;
		for (var uv in ref face.uvs)
		{
			if (uv.x < 0.5f)
				uv.x += 1;
		}
	}

	static Bounds FacesBounds(EditMesh mesh, Span<int32> faces)
	{
		var bounds = Bounds.Empty;
		for (let f in faces)
		{
			for (let v in mesh.faces[f].verts)
				bounds.Encapsulate(mesh.positions[v]);
		}
		return bounds;
	}

	static void Basis(Vector3 normal, out Vector3 axisU, out Vector3 axisV)
	{
		// Up stays up on walls; on floors and ceilings X goes across.
		if (Math.Abs(normal.y) < 0.9f)
		{
			axisV = Vector3.Up;
			axisU = Vector3.Cross(Vector3.Up, normal).Normalized;
			axisV = Vector3.Cross(normal, axisU).Normalized;
		}
		else
		{
			axisU = Vector3.Right;
			axisV = Vector3.Cross(normal, axisU).Normalized;
			axisU = Vector3.Cross(axisV, normal).Normalized;
		}
		// Keep pictures the right way round as seen from in front of the face.
		if (Vector3.Dot(Vector3.Cross(axisU, axisV), normal) > 0)
			axisU = -axisU;
	}

	/// Scales and shifts the faces' coordinates together to fill the picture, keeping their shape.
	public static void FitAll(EditMesh mesh, Span<int32> faces, float margin = 0.0f)
	{
		var min = Vector2(float.MaxValue, float.MaxValue);
		var max = Vector2(-float.MaxValue, -float.MaxValue);
		for (let f in faces)
		{
			for (let uv in mesh.faces[f].uvs)
			{
				min = .(Math.Min(min.x, uv.x), Math.Min(min.y, uv.y));
				max = .(Math.Max(max.x, uv.x), Math.Max(max.y, uv.y));
			}
		}
		let size = Math.Max(Math.Max(max.x - min.x, max.y - min.y), 1.0e-6f);
		let scale = (1 - margin * 2) / size;
		for (let f in faces)
		{
			for (var uv in ref mesh.faces[f].uvs)
				uv = .((uv.x - min.x) * scale + margin, (uv.y - min.y) * scale + margin);
		}
	}

	// ---- pieces ----

	/// Groups faces into pieces: joined across shared edges that are not seams (and, with angleLimit, that do not
	/// bend more than that many degrees from the piece's first face). Each piece is a list of face numbers.
	public static void Pieces(EditMesh mesh, Span<int32> faces, List<List<int32>> pieces, float angleLimit = 180)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let inSelection = scope HashSet<int32>();
		for (let f in faces)
			inSelection.Add(f);
		let taken = scope HashSet<int32>();
		let cosLimit = Math.Cos(Math.Min(angleLimit, 180) * Mathf.Deg2Rad);
		// Biggest faces first, so pieces grow from a face that represents them well.
		let ordered = scope List<int32>();
		for (let f in faces)
			ordered.Add(f);
		ordered.Sort((a, b) => mesh.FaceArea(mesh.faces[b]) <=> mesh.FaceArea(mesh.faces[a]));
		let stack = scope List<int32>();
		for (let start in ordered)
		{
			if (taken.Contains(start))
				continue;
			let piece = new List<int32>();
			pieces.Add(piece);
			taken.Add(start);
			stack.Add(start);
			var pieceNormal = mesh.FaceNormal(mesh.faces[start]);
			while (!stack.IsEmpty)
			{
				let f = stack.PopBack();
				piece.Add(f);
				let face = mesh.faces[f];
				for (int i < face.Count)
				{
					let key = EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
					if (mesh.seams.Contains(key))
						continue;
					for (let other in edgeFaces[key])
					{
						if (taken.Contains(other) || !inSelection.Contains(other))
							continue;
						if (angleLimit < 180 && Vector3.Dot(mesh.FaceNormal(mesh.faces[other]), pieceNormal) < cosLimit)
							continue;
						taken.Add(other);
						stack.Add(other);
					}
				}
			}
		}
	}

	/// Pieces as they lie in the picture: faces joined where a shared edge has the same coordinates on both sides.
	public static void Islands(EditMesh mesh, Span<int32> faces, List<List<int32>> islands)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let inSelection = scope HashSet<int32>();
		for (let f in faces)
			inSelection.Add(f);
		let taken = scope HashSet<int32>();
		let stack = scope List<int32>();
		for (let start in faces)
		{
			if (taken.Contains(start))
				continue;
			let island = new List<int32>();
			islands.Add(island);
			taken.Add(start);
			stack.Add(start);
			while (!stack.IsEmpty)
			{
				let f = stack.PopBack();
				island.Add(f);
				let face = mesh.faces[f];
				for (int i < face.Count)
				{
					let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
					for (let other in edgeFaces[EditMesh.EdgeKey(a, b)])
					{
						if (taken.Contains(other) || !inSelection.Contains(other))
							continue;
						let o = mesh.faces[other];
						let oa = o.IndexOf(a), ob = o.IndexOf(b);
						if (oa < 0 || ob < 0)
							continue;
						if ((o.uvs[oa] - face.uvs[i]).LengthSquared > 1.0e-10f || (o.uvs[ob] - face.uvs[(i + 1) % face.Count]).LengthSquared > 1.0e-10f)
							continue;
						taken.Add(other);
						stack.Add(other);
					}
				}
			}
		}
	}

	// ---- unwrapping ----

	/// Unwraps faces along their seams: each piece is laid flat with as little stretching of angles as possible
	/// (least-squares conformal maps), then the pieces are packed into the picture.
	public static void Unwrap(EditMesh mesh, Span<int32> faces, float margin = 0.01f)
	{
		let pieces = scope List<List<int32>>();
		defer
		{
			for (let piece in pieces)
				delete piece;
		}
		Pieces(mesh, faces, pieces);
		FlattenAndPack(mesh, pieces, margin);
	}

	/// Lays each piece flat, then packs those without pins (a pinned piece stays where its pins are).
	static void FlattenAndPack(EditMesh mesh, List<List<int32>> pieces, float margin)
	{
		let loose = scope List<int32>();
		for (let piece in pieces)
		{
			Flatten(mesh, piece);
			if (!HasPins(mesh, piece))
				loose.AddRange(piece);
		}
		Pack(mesh, loose, margin);
	}

	static bool HasPins(EditMesh mesh, List<int32> piece)
	{
		if (mesh.pins.IsEmpty)
			return false;
		for (let f in piece)
		{
			for (let v in mesh.faces[f].verts)
			{
				if (mesh.pins.Contains(v))
					return true;
			}
		}
		return false;
	}

	/// The texture coordinates of the piece's pinned vertices, as they are now (the first corner found for each).
	static void PinnedUVs(EditMesh mesh, List<int32> piece, Dictionary<int32, Vector2> into)
	{
		for (let f in piece)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let v = face.verts[i];
				if (mesh.pins.Contains(v) && !into.ContainsKey(v))
					into[v] = face.uvs[i];
			}
		}
	}

	/// Finds its own pieces: faces looking within `angleLimit` degrees of a piece's first face join it, each piece is
	/// laid flat, and all are packed. Good for hard-edged low-poly models.
	public static void SmartUnwrap(EditMesh mesh, Span<int32> faces, float angleLimit = 66, float margin = 0.01f)
	{
		let pieces = scope List<List<int32>>();
		defer
		{
			for (let piece in pieces)
				delete piece;
		}
		Pieces(mesh, faces, pieces, angleLimit);
		FlattenAndPack(mesh, pieces, margin);
	}

	/// Lays one piece flat. A flat piece is projected straight; anything else is solved as a conformal map. With
	/// two or more pinned vertices the pins keep their coordinates and the rest is solved round them; with one, the
	/// piece is laid flat and moved so that the pin stays put.
	public static void Flatten(EditMesh mesh, List<int32> piece)
	{
		let pinned = scope Dictionary<int32, Vector2>();
		PinnedUVs(mesh, piece, pinned);
		if (pinned.Count >= 2 && Conformal(mesh, piece, pinned))
			return;
		FlattenFree(mesh, piece);
		if (pinned.Count == 1)
		{
			for (let pair in pinned)
			{
				// Shift the piece so the pin is back where it was.
				var now = Vector2.Zero;
				for (let f in piece)
				{
					let i = mesh.faces[f].IndexOf(pair.key);
					if (i >= 0)
					{
						now = mesh.faces[f].uvs[i];
						break;
					}
				}
				let shift = pair.value - now;
				for (let f in piece)
				{
					for (var uv in ref mesh.faces[f].uvs)
						uv = uv + shift;
				}
			}
		}
	}

	static void FlattenFree(EditMesh mesh, List<int32> piece)
	{
		var normal = Vector3.Zero;
		for (let f in piece)
			normal = normal + mesh.FaceNormal(mesh.faces[f]) * mesh.FaceArea(mesh.faces[f]);
		normal = normal.LengthSquared > 1.0e-12f ? normal.Normalized : .Up;
		bool flat = true;
		for (let f in piece)
			flat &= Vector3.Dot(mesh.FaceNormal(mesh.faces[f]), normal) > 0.9995f;
		if (flat || !Conformal(mesh, piece))
		{
			Basis(normal, let axisU, let axisV);
			for (let f in piece)
			{
				let face = mesh.faces[f];
				face.uvMode = .Manual;
				for (int i < face.Count)
				{
					let p = mesh.positions[face.verts[i]];
					face.uvs[i] = .(Vector3.Dot(p, axisU), -Vector3.Dot(p, axisV));
				}
			}
		}
	}

	/// Least-squares conformal map of a piece (Levy et al.), solved by conjugate gradients on the normal equations.
	/// Two far-apart vertices are pinned, or the vertices given with their coordinates. False if it could not be
	/// solved (then the caller projects instead).
	static bool Conformal(EditMesh mesh, List<int32> piece, Dictionary<int32, Vector2> fixedUVs = null)
	{
		// Number the piece's vertices.
		let index = scope Dictionary<int32, int32>();
		let verts = scope List<int32>();
		for (let f in piece)
		{
			for (let v in mesh.faces[f].verts)
			{
				if (!index.ContainsKey(v))
				{
					index[v] = (int32)verts.Count;
					verts.Add(v);
				}
			}
		}
		let n = verts.Count;
		if (n < 3)
			return false;
		// Pin the two vertices furthest apart along the piece's longest side.
		var bounds = Bounds.Empty;
		for (let v in verts)
			bounds.Encapsulate(mesh.positions[v]);
		let extent = bounds.max - bounds.min;
		let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2);
		int32 pinA = 0, pinB = 0;
		for (int32 i < (int32)n)
		{
			if (MeshOps.Component(mesh.positions[verts[i]], axis) < MeshOps.Component(mesh.positions[verts[pinA]], axis))
				pinA = i;
			if (MeshOps.Component(mesh.positions[verts[i]], axis) > MeshOps.Component(mesh.positions[verts[pinB]], axis))
				pinB = i;
		}
		let userPins = fixedUVs != null && fixedUVs.Count >= 2;
		if (pinA == pinB && !userPins)
			return false;
		let pinDistance = (mesh.positions[verts[pinB]] - mesh.positions[verts[pinA]]).Length;
		// Unknowns: u and v of every vertex but the pins: column 2*k and 2*k+1 for the k-th free vertex.
		let column = scope int32[n];
		let pinned = scope Vector2[n];
		int32 free = 0;
		for (int32 i < (int32)n)
		{
			var isPin = false;
			if (userPins)
			{
				if (fixedUVs.TryGetValue(verts[i], let fixedUV))
				{
					isPin = true;
					pinned[i] = fixedUV;
				}
			}
			else
				isPin = i == pinA || i == pinB;
			if (isPin)
				column[i] = -1;
			else
			{
				column[i] = free;
				free++;
			}
		}
		if (!userPins)
		{
			pinned[pinA] = .(0, 0);
			pinned[pinB] = .(pinDistance, 0);
		}
		// Rows of A: two per triangle, three vertices each (u and v).
		let rowsVertex = scope List<int32>();
		let rowsReal = scope List<float>();
		let rowsImag = scope List<float>();
		let corners = scope List<int32>();
		for (let f in piece)
		{
			let face = mesh.faces[f];
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int t = 0; t + 2 < corners.Count; t += 3)
			{
				let ia = face.verts[corners[t]], ib = face.verts[corners[t + 1]], ic = face.verts[corners[t + 2]];
				let a = mesh.positions[ia], b = mesh.positions[ib], c = mesh.positions[ic];
				let e1 = b - a, e2 = c - a;
				let tn = Vector3.Cross(e1, e2);
				let doubleArea = tn.Length;
				if (doubleArea < 1.0e-12f)
					continue;
				let x = e1.Normalized;
				let y = Vector3.Cross(tn / doubleArea, x);
				// Local 2D corners.
				let p = scope Vector2[3](.(0, 0), .(e1.Length, 0), .(Vector3.Dot(e2, x), Vector3.Dot(e2, y)));
				let scale = 1.0f / Math.Sqrt(doubleArea);
				let tri = scope int32[3](index[ia], index[ib], index[ic]);
				for (int j < 3)
				{
					// W_j = (x_{j+2} - x_{j+1}) + i (y_{j+2} - y_{j+1})
					let p1 = p[(j + 1) % 3], p2 = p[(j + 2) % 3];
					rowsVertex.Add(tri[j]);
					rowsReal.Add((p2.x - p1.x) * scale);
					rowsImag.Add((p2.y - p1.y) * scale);
				}
			}
		}
		let triangles = rowsVertex.Count / 3;
		if (triangles == 0)
			return false;
		// Each triangle gives two equations (real and imaginary parts of sum W_j U_j = 0):
		//   sum (Re W_j) u_j - (Im W_j) v_j = 0,   sum (Im W_j) u_j + (Re W_j) v_j = 0.
		let unknowns = free * 2;
		let rhs = scope double[triangles * 2];
		// Move the pinned terms to the right-hand side.
		for (int t < triangles)
		{
			for (int j < 3)
			{
				let k = t * 3 + j;
				let v = rowsVertex[k];
				if (column[v] >= 0)
					continue;
				let re = rowsReal[k], im = rowsImag[k];
				let pin = pinned[v];
				rhs[t * 2] -= re * pin.x - im * pin.y;
				rhs[t * 2 + 1] -= im * pin.x + re * pin.y;
			}
		}
		// A x as a function, and A^T y.
		void Multiply(Span<double> x, Span<double> into)
		{
			for (int t < triangles)
			{
				double r0 = 0, r1 = 0;
				for (int j < 3)
				{
					let k = t * 3 + j;
					let col = column[rowsVertex[k]];
					if (col < 0)
						continue;
					let u = x[col * 2], v = x[col * 2 + 1];
					r0 += rowsReal[k] * u - rowsImag[k] * v;
					r1 += rowsImag[k] * u + rowsReal[k] * v;
				}
				into[t * 2] = r0;
				into[t * 2 + 1] = r1;
			}
		}
		void MultiplyTransposed(Span<double> y, Span<double> into)
		{
			for (int i < into.Length)
				into[i] = 0;
			for (int t < triangles)
			{
				for (int j < 3)
				{
					let k = t * 3 + j;
					let col = column[rowsVertex[k]];
					if (col < 0)
						continue;
					into[col * 2] += rowsReal[k] * y[t * 2] + rowsImag[k] * y[t * 2 + 1];
					into[col * 2 + 1] += -rowsImag[k] * y[t * 2] + rowsReal[k] * y[t * 2 + 1];
				}
			}
		}
		// Conjugate gradients on A^T A x = A^T b, starting from a straight projection.
		let x = scope double[unknowns];
		let b = scope double[unknowns];
		MultiplyTransposed(rhs, b);
		let r = scope double[unknowns];
		let d = scope double[unknowns];
		let ad = scope double[triangles * 2];
		let atad = scope double[unknowns];
		let ax = scope double[triangles * 2];
		Multiply(x, ax);
		MultiplyTransposed(ax, atad);
		double rr = 0;
		for (int i < unknowns)
		{
			r[i] = b[i] - atad[i];
			d[i] = r[i];
			rr += r[i] * r[i];
		}
		let tolerance = Math.Max(rr, 1.0e-30) * 1.0e-16;
		for (int iteration < unknowns * 4 + 50)
		{
			if (rr <= tolerance)
				break;
			Multiply(d, ad);
			MultiplyTransposed(ad, atad);
			double dAd = 0;
			for (int i < unknowns)
				dAd += d[i] * atad[i];
			if (Math.Abs(dAd) < 1.0e-300)
				break;
			let alpha = rr / dAd;
			double next = 0;
			for (int i < unknowns)
			{
				x[i] += alpha * d[i];
				r[i] -= alpha * atad[i];
				next += r[i] * r[i];
			}
			let beta = next / rr;
			rr = next;
			for (int i < unknowns)
				d[i] = r[i] + beta * d[i];
		}
		for (let value in x)
		{
			if (value.IsNaN || value.IsInfinity)
				return false;
		}
		let uv = scope Vector2[n];
		for (int i < n)
			uv[i] = column[i] < 0 ? pinned[i] : Vector2((float)x[column[i] * 2], (float)x[column[i] * 2 + 1]);
		// The map comes out turned and possibly mirrored relative to how Auto shows a face: make the piece's
		// triangles wind in the picture the same way a face's Auto coordinates do.
		float windingSum = 0;
		for (let f in piece)
		{
			let face = mesh.faces[f];
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int t = 0; t + 2 < corners.Count; t += 3)
			{
				let ua = uv[index[face.verts[corners[t]]]], ub = uv[index[face.verts[corners[t + 1]]]], uc = uv[index[face.verts[corners[t + 2]]]];
				windingSum += (ub.x - ua.x) * (uc.y - ua.y) - (ub.y - ua.y) * (uc.x - ua.x);
			}
		}
		// Pins say which way round the piece goes.
		let mirror = !userPins && Math.Sign(windingSum) != PictureWinding;
		for (let f in piece)
		{
			let face = mesh.faces[f];
			face.uvMode = .Manual;
			for (int i < face.Count)
			{
				var value = uv[index[face.verts[i]]];
				if (mirror)
					value.x = -value.x;
				face.uvs[i] = value;
			}
		}
		return true;
	}

	/// The sign of a front-facing triangle's area in picture coordinates, worked out once from how Auto maps a face
	/// looking up.
	static int PictureWinding
	{
		get
		{
			let probe = scope EditFace();
			// A triangle whose Cross(b - a, c - a) points up.
			let a = Vector3(0, 0, 0), b = Vector3(0, 0, 1), c = Vector3(1, 0, 0);
			let ua = EditMesh.AutoUV(a, .Up, probe, .One), ub = EditMesh.AutoUV(b, .Up, probe, .One), uc = EditMesh.AutoUV(c, .Up, probe, .One);
			let area = (ub.x - ua.x) * (uc.y - ua.y) - (ub.y - ua.y) * (uc.x - ua.x);
			return Vector3.Cross(b - a, c - a).y > 0 ? Math.Sign(area) : -Math.Sign(area);
		}
	}

	// ---- stitching and palettes ----

	/// Moves the pieces of `move` (turned, scaled and shifted together as one) so that their corners at vertices they
	/// share with `keep` land on keep's coordinates there, then makes those corners the same, so the texture runs
	/// on across the edges between them (seams there are cleared). A piece lying mirrored is flipped to fit. False
	/// when they share no vertex.
	public static bool Stitch(EditMesh mesh, Span<int32> keep, Span<int32> move)
	{
		// For each shared vertex: where keep has it, and where move has it.
		let target = scope Dictionary<int32, Vector2>();
		for (let f in keep)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				if (!target.ContainsKey(face.verts[i]))
					target[face.verts[i]] = face.uvs[i];
			}
		}
		let source = scope Dictionary<int32, Vector2>();
		for (let f in move)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				if (target.ContainsKey(face.verts[i]) && !source.ContainsKey(face.verts[i]))
					source[face.verts[i]] = face.uvs[i];
			}
		}
		if (source.IsEmpty)
			return false;
		// The best turn-scale-shift (as complex numbers: t = a s + b), tried as it lies and mirrored.
		var meanS = Vector2.Zero, meanT = Vector2.Zero;
		for (let pair in source)
		{
			meanS = meanS + pair.value;
			meanT = meanT + target[pair.key];
		}
		meanS = meanS * (1.0f / source.Count);
		meanT = meanT * (1.0f / source.Count);
		Vector2 Fit(bool flip, out float residual)
		{
			double re = 0, im = 0, norm = 0;
			for (let pair in source)
			{
				var s = pair.value - meanS;
				if (flip)
					s.x = -s.x;
				let t = target[pair.key] - meanT;
				// t * conj(s)
				re += t.x * s.x + t.y * s.y;
				im += t.y * s.x - t.x * s.y;
				norm += s.x * s.x + s.y * s.y;
			}
			var a = norm > 1.0e-20 ? Vector2((float)(re / norm), (float)(im / norm)) : Vector2(1, 0);
			if (source.Count == 1)
				a = .(1, 0);
			residual = 0;
			for (let pair in source)
			{
				var s = pair.value - meanS;
				if (flip)
					s.x = -s.x;
				let mapped = Vector2(a.x * s.x - a.y * s.y, a.x * s.y + a.y * s.x);
				residual += (mapped - (target[pair.key] - meanT)).LengthSquared;
			}
			return a;
		}
		let straight = Fit(false, let straightResidual);
		let mirrored = Fit(true, let mirroredResidual);
		let flip = mirroredResidual < straightResidual - 1.0e-9f;
		let a = flip ? mirrored : straight;
		let moved = scope HashSet<int32>();
		for (let f in move)
		{
			if (!moved.Add(f))
				continue;
			let face = mesh.faces[f];
			face.uvMode = .Manual;
			for (int i < face.Count)
			{
				var s = face.uvs[i] - meanS;
				if (flip)
					s.x = -s.x;
				face.uvs[i] = target.TryGetValue(face.verts[i], let exact) ? exact : Vector2(a.x * s.x - a.y * s.y, a.x * s.y + a.y * s.x) + meanT;
			}
		}
		// Seams between the two that now meet are gone.
		let keepSet = scope HashSet<int32>();
		for (let f in keep)
			keepSet.Add(f);
		for (let f in move)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let a0 = face.verts[i], b0 = face.verts[(i + 1) % face.Count];
				if (target.ContainsKey(a0) && target.ContainsKey(b0))
				{
					for (let k in keepSet)
					{
						let other = mesh.faces[k];
						if (other.IndexOf(a0) >= 0 && other.IndexOf(b0) >= 0)
						{
							mesh.seams.Remove(EditMesh.EdgeKey(a0, b0));
							break;
						}
					}
				}
			}
		}
		return true;
	}

	/// Stitches the pieces the faces form onto the piece holding `first`, one after another wherever they share
	/// vertices with what is stitched so far. Returns how many pieces moved.
	public static int StitchAll(EditMesh mesh, Span<int32> faces, int32 first)
	{
		let islands = scope List<List<int32>>();
		defer
		{
			for (let island in islands)
				delete island;
		}
		Islands(mesh, faces, islands);
		let joined = scope List<int32>();
		let left = scope List<List<int32>>();
		for (let island in islands)
		{
			if (island.Contains(first))
				joined.AddRange(island);
			else
				left.Add(island);
		}
		if (joined.IsEmpty)
			return 0;
		int count = 0;
		bool progress = true;
		while (progress && !left.IsEmpty)
		{
			progress = false;
			for (int k < left.Count)
			{
				if (!Stitch(mesh, joined, left[k]))
					continue;
				joined.AddRange(left[k]);
				left.RemoveAt(k);
				count++;
				progress = true;
				break;
			}
		}
		return count;
	}

	/// Puts the faces' coordinates into one cell of a palette or atlas picture (a grid of `columns` by `rows`,
	/// counted from the top left), keeping their shape, shrunk into the middle `fill` share of the cell so filtering
	/// never reaches the next one. A fill of 0 puts every corner on the cell's middle, for a flat colour.
	public static void ToCell(EditMesh mesh, Span<int32> faces, int32 column, int32 row, int32 columns, int32 rows, float fill = 0.5f)
	{
		let cellSize = Vector2(1.0f / Math.Max(columns, 1), 1.0f / Math.Max(rows, 1));
		let center = Vector2((column + 0.5f) * cellSize.x, (row + 0.5f) * cellSize.y);
		var min = Vector2(float.MaxValue, float.MaxValue);
		var max = Vector2(-float.MaxValue, -float.MaxValue);
		for (let f in faces)
		{
			for (let uv in mesh.faces[f].uvs)
			{
				min = .(Math.Min(min.x, uv.x), Math.Min(min.y, uv.y));
				max = .(Math.Max(max.x, uv.x), Math.Max(max.y, uv.y));
			}
		}
		let size = Math.Max(Math.Max(max.x - min.x, max.y - min.y), 1.0e-6f);
		let scale = Math.Min(cellSize.x, cellSize.y) * Math.Clamp(fill, 0, 1) / size;
		let middle = (min + max) * 0.5f;
		for (let f in faces)
		{
			let face = mesh.faces[f];
			face.uvMode = .Manual;
			for (var uv in ref face.uvs)
				uv = center + (uv - middle) * scale;
		}
	}

	/// The palette cell (column, row) a coordinate falls in.
	public static void CellAt(Vector2 uv, int32 columns, int32 rows, out int32 column, out int32 row)
	{
		column = (int32)Math.Clamp(Math.Floor(uv.x * columns), 0, columns - 1);
		row = (int32)Math.Clamp(Math.Floor(uv.y * rows), 0, rows - 1);
	}

	// ---- packing ----

	/// Packs the pieces the faces form in the picture into the 0 to 1 square: each turned to its smallest box,
	/// scaled to the same texture density, then laid out in rows, with a margin round each.
	public static void Pack(EditMesh mesh, Span<int32> faces, float margin = 0.01f)
	{
		let islands = scope List<List<int32>>();
		defer
		{
			for (let island in islands)
				delete island;
		}
		Islands(mesh, faces, islands);
		if (islands.IsEmpty)
			return;
		// Same density: scale each island so picture area matches its area on the model.
		let mins = scope Vector2[islands.Count];
		let sizes = scope Vector2[islands.Count];
		for (int k < islands.Count)
		{
			let island = islands[k];
			float area3 = 0, area2 = 0;
			for (let f in island)
			{
				let face = mesh.faces[f];
				area3 += mesh.FaceArea(face);
				area2 += Math.Abs(PictureArea(face));
			}
			let density = area2 > 1.0e-12f ? Math.Sqrt(area3 / area2) : 1;
			// Turn to the smallest box over the directions of the island's edges.
			let angle = BestAngle(mesh, island);
			let cs = Math.Cos(angle), sn = Math.Sin(angle);
			var min = Vector2(float.MaxValue, float.MaxValue);
			var max = Vector2(-float.MaxValue, -float.MaxValue);
			for (let f in island)
			{
				for (var uv in ref mesh.faces[f].uvs)
				{
					uv = Vector2(uv.x * cs - uv.y * sn, uv.x * sn + uv.y * cs) * density;
					min = .(Math.Min(min.x, uv.x), Math.Min(min.y, uv.y));
					max = .(Math.Max(max.x, uv.x), Math.Max(max.y, uv.y));
				}
			}
			// Lie long ways across.
			if (max.y - min.y > max.x - min.x)
			{
				for (let f in island)
				{
					for (var uv in ref mesh.faces[f].uvs)
						uv = .(uv.y, -uv.x);
				}
				let oldMin = min;
				min = .(oldMin.y, -max.x);
				max = .(max.y, -oldMin.x);
			}
			mins[k] = min;
			sizes[k] = max - min;
		}
		// Rows, tallest first, in a square about the size of the total area.
		let order = scope List<int>();
		float totalArea = 0;
		for (int k < islands.Count)
		{
			order.Add(k);
			totalArea += (sizes[k].x + margin) * (sizes[k].y + margin);
		}
		order.Sort((a, b) => sizes[b].y <=> sizes[a].y);
		float widest = 0;
		for (int k < islands.Count)
			widest = Math.Max(widest, sizes[k].x);
		let rowWidth = Math.Max(Math.Sqrt(totalArea) * 1.1f, widest);
		let gap = margin * Math.Sqrt(totalArea);
		let offsets = scope Vector2[islands.Count];
		float x = gap, y = gap, rowHeight = 0, usedWidth = 0;
		for (let k in order)
		{
			if (x + sizes[k].x + gap > rowWidth + gap * 2 && x > gap)
			{
				x = gap;
				y += rowHeight + gap;
				rowHeight = 0;
			}
			offsets[k] = .(x, y);
			x += sizes[k].x + gap;
			usedWidth = Math.Max(usedWidth, x);
			rowHeight = Math.Max(rowHeight, sizes[k].y);
		}
		let usedHeight = y + rowHeight + gap;
		let scale = 1.0f / Math.Max(Math.Max(usedWidth, usedHeight), 1.0e-6f);
		for (int k < islands.Count)
		{
			for (let f in islands[k])
			{
				for (var uv in ref mesh.faces[f].uvs)
					uv = (uv - mins[k] + offsets[k]) * scale;
			}
		}
	}

	static float PictureArea(EditFace face)
	{
		float area = 0;
		for (int i < face.Count)
		{
			let a = face.uvs[i], b = face.uvs[(i + 1) % face.Count];
			area += a.x * b.y - b.x * a.y;
		}
		return area * 0.5f;
	}

	/// The turn (radians) that gives an island its smallest bounding box, trying the direction of each edge.
	static float BestAngle(EditMesh mesh, List<int32> island)
	{
		float bestArea = float.MaxValue;
		float best = 0;
		let tried = scope List<float>();
		for (let f in island)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let d = face.uvs[(i + 1) % face.Count] - face.uvs[i];
				if (d.LengthSquared < 1.0e-12f)
					continue;
				var angle = -Math.Atan2(d.y, d.x);
				// Edges a quarter turn apart give the same box.
				angle = angle - Math.Floor(angle / (Math.PI_f / 2)) * (Math.PI_f / 2);
				bool seen = false;
				for (let t in tried)
					seen |= Math.Abs(t - angle) < 0.001f;
				if (seen)
					continue;
				tried.Add(angle);
				let cs = Math.Cos(angle), sn = Math.Sin(angle);
				var min = Vector2(float.MaxValue, float.MaxValue);
				var max = Vector2(-float.MaxValue, -float.MaxValue);
				for (let g in island)
				{
					for (let uv in mesh.faces[g].uvs)
					{
						let r = Vector2(uv.x * cs - uv.y * sn, uv.x * sn + uv.y * cs);
						min = .(Math.Min(min.x, r.x), Math.Min(min.y, r.y));
						max = .(Math.Max(max.x, r.x), Math.Max(max.y, r.y));
					}
				}
				let area = (max.x - min.x) * (max.y - min.y);
				if (area < bestArea - 1.0e-9f)
				{
					bestArea = area;
					best = angle;
				}
				if (tried.Count > 64)
					return best;
			}
		}
		return best;
	}

	// ---- checking ----

	/// How much of the picture is covered more than once by the faces (0 is no overlap), measured on a grid.
	public static float Overlap(EditMesh mesh, Span<int32> faces, int resolution = 128)
	{
		let counts = scope uint8[resolution * resolution];
		let corners = scope List<int32>();
		int covered = 0, twice = 0;
		for (let f in faces)
		{
			let face = mesh.faces[f];
			corners.Clear();
			mesh.Triangulate(face, corners);
			let marked = scope HashSet<int>();
			for (int t = 0; t + 2 < corners.Count; t += 3)
			{
				let a = face.uvs[corners[t]], b = face.uvs[corners[t + 1]], c = face.uvs[corners[t + 2]];
				let minX = (int)Math.Max(0, Math.Floor(Math.Min(a.x, Math.Min(b.x, c.x)) * resolution));
				let maxX = (int)Math.Min(resolution - 1, Math.Floor(Math.Max(a.x, Math.Max(b.x, c.x)) * resolution));
				let minY = (int)Math.Max(0, Math.Floor(Math.Min(a.y, Math.Min(b.y, c.y)) * resolution));
				let maxY = (int)Math.Min(resolution - 1, Math.Floor(Math.Max(a.y, Math.Max(b.y, c.y)) * resolution));
				for (int py = minY; py <= maxY; py++)
				{
					for (int px = minX; px <= maxX; px++)
					{
						let p = Vector2((px + 0.5f) / resolution, (py + 0.5f) / resolution);
						if (!Inside(p, a, b, c))
							continue;
						let cell = py * resolution + px;
						if (!marked.Add(cell))
							continue;
						if (counts[cell] == 0)
							covered++;
						else if (counts[cell] == 1)
							twice++;
						if (counts[cell] < 255)
							counts[cell]++;
					}
				}
			}
		}
		return covered > 0 ? (float)twice / covered : 0;
	}

	static bool Inside(Vector2 p, Vector2 a, Vector2 b, Vector2 c)
	{
		let d1 = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
		let d2 = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x);
		let d3 = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x);
		let hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
		let hasPos = d1 > 0 || d2 > 0 || d3 > 0;
		return !(hasNeg && hasPos);
	}

	/// The worst stretch of any face: how far its picture area per model area strays from the average (1 is none).
	public static float Stretch(EditMesh mesh, Span<int32> faces)
	{
		float area3 = 0, area2 = 0;
		for (let f in faces)
		{
			area3 += mesh.FaceArea(mesh.faces[f]);
			area2 += Math.Abs(PictureArea(mesh.faces[f]));
		}
		if (area3 <= 0 || area2 <= 0)
			return 1;
		let average = area2 / area3;
		float worst = 1;
		for (let f in faces)
		{
			let a3 = mesh.FaceArea(mesh.faces[f]);
			if (a3 < 1.0e-9f)
				continue;
			let ratio = Math.Abs(PictureArea(mesh.faces[f])) / a3 / average;
			worst = Math.Max(worst, Math.Max(ratio, 1 / Math.Max(ratio, 1.0e-6f)));
		}
		return worst;
	}
}
