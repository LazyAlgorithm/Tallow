using System;
using System.Collections;

namespace Tallow;

/// The modelling operations on an EditMesh: extrude, inset, bevel, cut, join, delete, subdivide, mirror and the
/// selection helpers the editor uses. Faces are passed by index, edges by EditMesh.EdgeKey, vertices by index.
/// Operations that add faces return them in a list given by the caller, so the editor can select the result.
static class MeshOps
{
	// ---- facing ----

	/// Makes every face agree with its neighbours (each shared edge used once each way) and, for each closed piece,
	/// point outwards. Returns how many faces were turned.
	public static int ConformNormals(EditMesh mesh)
	{
		let count = mesh.faces.Count;
		if (count == 0)
			return 0;
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let piece = scope int32[count];
		for (int i < count)
			piece[i] = -1;
		int flipped = 0;
		int32 pieces = 0;
		let stack = scope List<int32>();
		let members = scope List<int32>();
		for (int32 start < (int32)count)
		{
			if (piece[start] >= 0)
				continue;
			members.Clear();
			piece[start] = pieces;
			stack.Add(start);
			while (!stack.IsEmpty)
			{
				let f = stack.PopBack();
				members.Add(f);
				let face = mesh.faces[f];
				for (int i < face.Count)
				{
					let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
					for (let other in edgeFaces[EditMesh.EdgeKey(a, b)])
					{
						if (other == f || piece[other] >= 0)
							continue;
						// A neighbour that also runs a -> b faces the other way: turn it.
						if (RunsForward(mesh.faces[other], a, b))
						{
							mesh.faces[other].Reverse();
							flipped++;
						}
						piece[other] = pieces;
						stack.Add(other);
					}
				}
			}
			// A closed piece enclosing negative space is inside out.
			if (PieceClosed(mesh, members, edgeFaces) && PieceVolume(mesh, members) < 0)
			{
				for (let f in members)
					mesh.faces[f].Reverse();
				flipped += members.Count;
			}
			pieces++;
		}
		return flipped;
	}

	static bool RunsForward(EditFace face, int32 a, int32 b)
	{
		let i = face.IndexOf(a);
		return i >= 0 && face.verts[(i + 1) % face.Count] == b;
	}

	static bool PieceClosed(EditMesh mesh, List<int32> members, Dictionary<uint64, List<int32>> edgeFaces)
	{
		for (let f in members)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				if (edgeFaces[EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count])].Count != 2)
					return false;
			}
		}
		return true;
	}

	static float PieceVolume(EditMesh mesh, List<int32> members)
	{
		double sum = 0;
		let corners = scope List<int32>();
		for (let f in members)
		{
			let face = mesh.faces[f];
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int i = 0; i + 2 < corners.Count; i += 3)
			{
				let a = mesh.positions[face.verts[corners[i]]], b = mesh.positions[face.verts[corners[i + 1]]], c = mesh.positions[face.verts[corners[i + 2]]];
				sum += Vector3.Dot(a, Vector3.Cross(b, c));
			}
		}
		return (float)(sum / 6.0);
	}

	public static void FlipFaces(EditMesh mesh, Span<int32> faces)
	{
		for (let f in faces)
			mesh.faces[f].Reverse();
	}

	// ---- in-face interpolation ----

	/// The texture coordinate and colour a face has at a point on it (from the triangle the point is in, or the
	/// nearest one).
	public static void Sample(EditMesh mesh, EditFace face, Vector3 point, out Vector2 uv, out Color color)
	{
		let corners = scope List<int32>();
		mesh.Triangulate(face, corners);
		uv = face.uvs.IsEmpty ? .Zero : face.uvs[0];
		color = face.colors.IsEmpty ? .White : face.colors[0];
		float best = float.MaxValue;
		for (int i = 0; i + 2 < corners.Count; i += 3)
		{
			let ia = corners[i], ib = corners[i + 1], ic = corners[i + 2];
			let a = mesh.positions[face.verts[ia]], b = mesh.positions[face.verts[ib]], c = mesh.positions[face.verts[ic]];
			Barycentric(point, a, b, c, let u, let v, let w);
			// How far outside the triangle the point is (0 inside).
			let outside = Math.Max(0, -u) + Math.Max(0, -v) + Math.Max(0, -w);
			if (outside < best)
			{
				best = outside;
				uv = face.uvs[ia] * u + face.uvs[ib] * v + face.uvs[ic] * w;
				let ca = face.colors[ia], cb = face.colors[ib], cc = face.colors[ic];
				color = .(ca.r * u + cb.r * v + cc.r * w, ca.g * u + cb.g * v + cc.g * w, ca.b * u + cb.b * v + cc.b * w, ca.a * u + cb.a * v + cc.a * w);
			}
		}
	}

	public static void Barycentric(Vector3 p, Vector3 a, Vector3 b, Vector3 c, out float u, out float v, out float w)
	{
		let v0 = b - a, v1 = c - a, v2 = p - a;
		let d00 = Vector3.Dot(v0, v0), d01 = Vector3.Dot(v0, v1), d11 = Vector3.Dot(v1, v1);
		let d20 = Vector3.Dot(v2, v0), d21 = Vector3.Dot(v2, v1);
		let denom = d00 * d11 - d01 * d01;
		if (Math.Abs(denom) < 1.0e-20f)
		{
			u = 1;
			v = w = 0;
			return;
		}
		v = (d11 * d20 - d01 * d21) / denom;
		w = (d00 * d21 - d01 * d20) / denom;
		u = 1 - v - w;
	}

	static Color LerpColor(Color a, Color b, float t) => .(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);

	// ---- extrude ----

	/// Pushes faces out along their normals by a distance, building walls from where they were. Faces next to each
	/// other move together (one region) unless individual is set. The moved faces stay the same faces; the new walls
	/// are added to `added` when given.
	public static void ExtrudeFaces(EditMesh mesh, Span<int32> faces, float distance, bool individual = false, List<int32> added = null)
	{
		if (individual)
		{
			for (let f in faces)
			{
				var single = f;
				ExtrudeRegion(mesh, .(&single, 1), distance, added);
			}
			return;
		}
		ExtrudeRegion(mesh, faces, distance, added);
	}

	static void ExtrudeRegion(EditMesh mesh, Span<int32> faces, float distance, List<int32> added)
	{
		if (faces.IsEmpty)
			return;
		let selected = scope HashSet<int32>();
		for (let f in faces)
			selected.Add(f);
		// Edges used once inside the region are its border; each is walled in the direction its face runs it.
		let directed = scope Dictionary<uint64, int32>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let key = EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
				if (directed.TryAdd(key, ?, let value))
					*value = 0;
				directed[key]++;
			}
		}
		// Each vertex of the region gets a copy that moves; the old one stays for the faces around.
		let copies = scope Dictionary<int32, int32>();
		let normals = scope Dictionary<int32, Vector3>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			let normal = mesh.FaceNormal(face);
			for (let v in face.verts)
			{
				if (copies.TryAdd(v, ?, let value))
				{
					*value = mesh.AddVertex(mesh.positions[v]);
					normals[v] = .Zero;
				}
				normals[v] = normals[v] + normal;
			}
		}
		let walls = scope List<EditFace>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let j = (i + 1) % face.Count;
				let a = face.verts[i], b = face.verts[j];
				if (directed[EditMesh.EdgeKey(a, b)] != 1)
					continue;
				let wall = new EditFace();
				wall.CopySettings(face);
				wall.uvMode = .Auto;
				wall.Add(a, face.uvs[i], face.colors[i]);
				wall.Add(b, face.uvs[j], face.colors[j]);
				wall.Add(copies[b], face.uvs[j], face.colors[j]);
				wall.Add(copies[a], face.uvs[i], face.colors[i]);
				walls.Add(wall);
			}
		}
		for (let f in faces)
		{
			for (var v in ref mesh.faces[f].verts)
				v = copies[v];
		}
		for (let pair in copies)
		{
			var direction = normals[pair.key];
			if (direction.LengthSquared > 1.0e-12f)
				direction = direction.Normalized;
			mesh.positions[pair.value] = mesh.positions[pair.value] + direction * distance;
		}
		for (let wall in walls)
		{
			added?.Add((int32)mesh.faces.Count);
			mesh.faces.Add(wall);
		}
		// Old inside vertices no face uses any more are left for Clean; the indices of faces stay valid.
	}

	/// Pulls open edges (edges with one face) out by an offset into new faces, as when growing a floor or a fence.
	/// New faces go into `added`; the new outer edges into `newEdges`.
	public static void ExtrudeEdges(EditMesh mesh, Span<uint64> edges, Vector3 offset, List<int32> added = null, List<uint64> newEdges = null)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let copies = scope Dictionary<int32, int32>();
		int32 Copy(int32 v)
		{
			if (copies.TryGetValue(v, let existing))
				return existing;
			let made = mesh.AddVertex(mesh.positions[v] + offset);
			copies[v] = made;
			return made;
		}
		for (let key in edges)
		{
			if (!edgeFaces.TryGetValue(key, let list) || list.Count != 1)
				continue;
			let face = mesh.faces[list[0]];
			EditMesh.EdgeEnds(key, var a, var b);
			// The new face runs the edge the other way from its face.
			var i = face.IndexOf(a);
			if (face.verts[(i + 1) % face.Count] != b)
			{
				Swap!(a, b);
				i = face.IndexOf(a);
			}
			let j = (i + 1) % face.Count;
			let wall = new EditFace();
			wall.CopySettings(face);
			wall.uvMode = .Auto;
			wall.Add(b, face.uvs[j], face.colors[j]);
			wall.Add(a, face.uvs[i], face.colors[i]);
			wall.Add(Copy(a), face.uvs[i], face.colors[i]);
			wall.Add(Copy(b), face.uvs[j], face.colors[j]);
			added?.Add((int32)mesh.faces.Count);
			mesh.faces.Add(wall);
			newEdges?.Add(EditMesh.EdgeKey(copies[a], copies[b]));
		}
	}

	// ---- inset ----

	/// Shrinks faces inwards by a distance, keeping a ring of new faces round each. Faces next to each other inset
	/// as one region unless individual is set. The inset faces stay the same faces; the rings go into `added`.
	public static void InsetFaces(EditMesh mesh, Span<int32> faces, float amount, bool individual = true, List<int32> added = null)
	{
		if (individual)
		{
			for (let f in faces)
				InsetOne(mesh, f, amount, added);
			return;
		}
		// A region: extrude by nothing, then slide the new border inwards across the faces.
		let before = mesh.faces.Count;
		let walls = scope List<int32>();
		ExtrudeRegion(mesh, faces, 0, walls);
		added?.AddRange(walls);
		// For each new border vertex, the inward direction is the average of the inward directions of its border
		// edges, within the region's faces.
		let moves = scope Dictionary<int32, Vector3>();
		let counts = scope Dictionary<int32, int32>();
		for (let w in walls)
		{
			let wall = mesh.faces[w];
			// wall: a, b, b', a' (a' and b' are on the region).
			let a2 = wall.verts[3], b2 = wall.verts[2];
			let along = mesh.positions[b2] - mesh.positions[a2];
			// The region face holding this edge decides which side is in.
			var normal = Vector3.Zero;
			for (let f in faces)
			{
				let face = mesh.faces[f];
				let i = face.IndexOf(a2);
				if (i >= 0 && face.verts[(i + 1) % face.Count] == b2)
				{
					normal = mesh.FaceNormal(face);
					break;
				}
			}
			var inward = Vector3.Cross(normal, along);
			if (inward.LengthSquared < 1.0e-12f)
				continue;
			inward = inward.Normalized;
			for (let v in int32[2](a2, b2))
			{
				if (moves.TryAdd(v, ?, let value))
				{
					*value = .Zero;
					counts[v] = 0;
				}
				moves[v] = moves[v] + inward;
				counts[v]++;
			}
		}
		for (let pair in moves)
		{
			var direction = pair.value;
			if (direction.LengthSquared < 1.0e-12f)
				continue;
			// Two edges meeting at an angle: go further so each edge moves by the amount.
			let length = direction.Length / counts[pair.key];
			direction = direction.Normalized * (amount / Math.Max(length, 0.25f));
			mesh.positions[pair.key] = mesh.positions[pair.key] + direction;
		}
		// The rings' faces were made with the old corners' coordinates; Auto works them out anyway.
		for (int i = before; i < mesh.faces.Count; i++)
			mesh.faces[i].uvMode = .Auto;
	}

	static void InsetOne(EditMesh mesh, int32 f, float amount, List<int32> added)
	{
		let face = mesh.faces[f];
		let n = face.Count;
		let normal = mesh.FaceNormal(face);
		let inner = scope int32[n];
		let innerUV = scope Vector2[n];
		let innerColor = scope Color[n];
		for (int i < n)
		{
			let p = mesh.positions[face.verts[i]];
			let prev = mesh.positions[face.verts[(i + n - 1) % n]];
			let next = mesh.positions[face.verts[(i + 1) % n]];
			// Inward across each of the two edges at this corner (the face runs clockwise from the front).
			let in1 = Vector3.Cross(normal, p - prev).Normalized;
			let in2 = Vector3.Cross(normal, next - p).Normalized;
			var direction = in1 + in2;
			var reach = amount;
			if (direction.LengthSquared > 1.0e-10f)
			{
				direction = direction.Normalized;
				let cosine = Vector3.Dot(direction, in1);
				reach = amount / Math.Max(cosine, 0.2f);
			}
			let point = p + direction * reach;
			inner[i] = mesh.AddVertex(point);
			Sample(mesh, face, point, out innerUV[i], out innerColor[i]);
		}
		for (int i < n)
		{
			let j = (i + 1) % n;
			let ring = new EditFace();
			ring.CopySettings(face);
			ring.Add(face.verts[i], face.uvs[i], face.colors[i]);
			ring.Add(face.verts[j], face.uvs[j], face.colors[j]);
			ring.Add(inner[j], innerUV[j], innerColor[j]);
			ring.Add(inner[i], innerUV[i], innerColor[i]);
			added?.Add((int32)mesh.faces.Count);
			mesh.faces.Add(ring);
		}
		for (int i < n)
		{
			face.verts[i] = inner[i];
			face.uvs[i] = innerUV[i];
			face.colors[i] = innerColor[i];
		}
	}

	// ---- bevel ----

	/// Cuts selected edges off with a flat face the width given (measured across each face from the edge). Where
	/// several bevelled edges meet, the corner is filled with a face of its own. Edges at the mesh's border are
	/// left alone. With more than one segment the cut is rounded: each strip is split along its length into that
	/// many smooth faces on a curve towards the old edge. The new faces go into `added`.
	public static void Bevel(EditMesh mesh, Span<uint64> edges, float width, List<int32> added = null, int segments = 1)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let bevelled = scope HashSet<uint64>();
		for (let key in edges)
		{
			if (edgeFaces.TryGetValue(key, let list) && list.Count == 2)
				bevelled.Add(key);
		}
		if (bevelled.IsEmpty)
			return;
		let touched = scope HashSet<int32>();
		for (let key in bevelled)
		{
			EditMesh.EdgeEnds(key, let a, let b);
			touched.Add(a);
			touched.Add(b);
		}
		// Vertices from here on are the bevel's own.
		let firstNew = (int32)mesh.positions.Count;
		// A point slid along an unbevelled edge (v, other) away from v, shared by the faces either side of it.
		let slides = scope Dictionary<uint64, int32>();
		// How far: enough to clear the bevelled edge it is measured from, in each face that has one at v.
		int32 SlidePoint(int32 v, int32 other, Vector3 fromEdgeDir)
		{
			let key = (uint64)(uint32)v << 32 | (uint32)other;
			let p = mesh.positions[v];
			let along = mesh.positions[other] - p;
			let length = along.Length;
			let dir = along / Math.Max(length, 1.0e-8f);
			let sine = Vector3.Cross(dir, fromEdgeDir).Length;
			let distance = Math.Min(width / Math.Max(sine, 0.1f), length * 0.45f);
			if (slides.TryGetValue(key, let existing))
			{
				// Two faces asking for different distances: keep the further, so both bevels fit.
				if ((mesh.positions[existing] - p).Length < distance)
					mesh.positions[existing] = p + dir * distance;
				return existing;
			}
			let made = mesh.AddVertex(p + dir * distance);
			slides[key] = made;
			return made;
		}
		// Each face's corners at touched vertices become one or two new points.
		let cornerLists = scope Dictionary<int64, List<int32>>(); // (face << 32 | corner) -> points
		defer
		{
			for (let list in cornerLists.Values)
				delete list;
		}
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			let n = face.Count;
			for (int i < n)
			{
				let v = face.verts[i];
				if (!touched.Contains(v))
					continue;
				let prev = face.verts[(i + n - 1) % n], next = face.verts[(i + 1) % n];
				let prevBevelled = bevelled.Contains(EditMesh.EdgeKey(prev, v));
				let nextBevelled = bevelled.Contains(EditMesh.EdgeKey(v, next));
				let p = mesh.positions[v];
				let points = new List<int32>();
				cornerLists[((int64)f << 32) | i] = points;
				if (prevBevelled && nextBevelled)
				{
					// Inside the face, the width from both edges.
					let normal = mesh.FaceNormal(face);
					let in1 = Vector3.Cross(normal, p - mesh.positions[prev]).Normalized;
					let in2 = Vector3.Cross(normal, mesh.positions[next] - p).Normalized;
					var direction = in1 + in2;
					var reach = width;
					if (direction.LengthSquared > 1.0e-10f)
					{
						direction = direction.Normalized;
						reach = width / Math.Max(Vector3.Dot(direction, in1), 0.2f);
					}
					points.Add(mesh.AddVertex(p + direction * reach));
				}
				else if (prevBevelled)
					points.Add(SlidePoint(v, next, (mesh.positions[prev] - p).Normalized));
				else if (nextBevelled)
					points.Add(SlidePoint(v, prev, (mesh.positions[next] - p).Normalized));
				else
					points.Add(v);
			}
		}
		// Corners with neither edge bevelled still lose the vertex (the bevel cuts the corner away): each of their two
		// edges gets a point where the cut crosses it, unless a neighbour already made one.
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			let n = face.Count;
			for (int i < n)
			{
				if (!cornerLists.TryGetValue(((int64)f << 32) | i, let points) || points.Count != 1 || points[0] != face.verts[i])
					continue;
				let v = face.verts[i];
				let prev = face.verts[(i + n - 1) % n], next = face.verts[(i + 1) % n];
				points.Clear();
				points.Add(CutPoint(mesh, v, prev, bevelled, cornerLists, slides, width, firstNew));
				points.Add(CutPoint(mesh, v, next, bevelled, cornerLists, slides, width, firstNew));
			}
		}
		// Rebuild every face from its corner lists, sampling texture coordinates at the new points.
		let rebuilt = scope List<EditFace>();
		defer
		{
			for (let face in rebuilt)
				delete face;
		}
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			let copy = new EditFace();
			copy.CopySettings(face);
			for (int i < face.Count)
			{
				if (cornerLists.TryGetValue(((int64)f << 32) | i, let points))
				{
					for (let point in points)
					{
						if (point == face.verts[i])
							copy.Add(point, face.uvs[i], face.colors[i]);
						else
						{
							Sample(mesh, face, mesh.positions[point], let uv, let color);
							copy.Add(point, uv, color);
						}
					}
				}
				else
					copy.Add(face.verts[i], face.uvs[i], face.colors[i]);
			}
			rebuilt.Add(copy);
		}
		// The strip along each bevelled edge: from face 1's points to face 2's.
		let strips = scope List<EditFace>();
		// Rounded bevels: the points made across each end, from one corner point to the other, shared by the strips
		// and the faces that meet them there.
		let profiles = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in profiles.Values)
				delete list;
		}
		for (let key in bevelled)
		{
			let list = edgeFaces[key];
			EditMesh.EdgeEnds(key, var a, var b);
			// Face 1 runs a -> b.
			var f1 = list[0], f2 = list[1];
			if (!RunsForward(mesh.faces[f1], a, b))
				Swap!(f1, f2);
			if (!RunsForward(mesh.faces[f1], a, b))
				continue;
			let ia1 = mesh.faces[f1].IndexOf(a), ib1 = mesh.faces[f1].IndexOf(b);
			let ia2 = mesh.faces[f2].IndexOf(a), ib2 = mesh.faces[f2].IndexOf(b);
			let pa1 = cornerLists[((int64)f1 << 32) | ia1], pb1 = cornerLists[((int64)f1 << 32) | ib1];
			let pa2 = cornerLists[((int64)f2 << 32) | ia2], pb2 = cornerLists[((int64)f2 << 32) | ib2];
			// In face 1 the edge became last(a) -> first(b); in face 2 last(b) -> first(a).
			if (segments > 1)
			{
				// Rounded: the points across the strip at each end, on a curve bending towards the old corner.
				let acrossA = scope List<int32>(), acrossB = scope List<int32>();
				BevelProfile(mesh, pa1.Back, pa2[0], mesh.positions[a], segments, profiles, acrossA);
				BevelProfile(mesh, pb1[0], pb2.Back, mesh.positions[b], segments, profiles, acrossB);
				for (int k < segments)
				{
					let strip = new EditFace();
					strip.CopySettings(mesh.faces[f1]);
					strip.uvMode = .Auto;
					strip.smooth = true;
					for (let v in int32[4](acrossB[k], acrossA[k], acrossA[k + 1], acrossB[k + 1]))
					{
						if (strip.IndexOf(v) < 0)
							strip.Add(v, .Zero, mesh.faces[f1].colors[0]);
					}
					if (strip.Count >= 3)
						strips.Add(strip);
					else
						delete strip;
				}
				continue;
			}
			let strip = new EditFace();
			strip.CopySettings(mesh.faces[f1]);
			strip.uvMode = .Auto;
			strip.smooth = false;
			for (let v in int32[4](pb1[0], pa1.Back, pa2[0], pb2.Back))
			{
				if (strip.IndexOf(v) < 0)
					strip.Add(v, .Zero, mesh.faces[f1].colors[0]);
			}
			if (strip.Count >= 3)
				strips.Add(strip);
			else
				delete strip;
		}
		// Swap in the rebuilt faces, then the strips.
		for (int f < mesh.faces.Count)
			mesh.faces[f].CopyFrom(rebuilt[f]);
		// Faces meeting a rounded end across one edge (the end of a bevel that stops) take its points too.
		if (!profiles.IsEmpty)
		{
			for (let face in mesh.faces)
			{
				for (int i = 0; i < face.Count; i++)
				{
					let j = (i + 1) % face.Count;
					let key = (uint64)(uint32)face.verts[i] << 32 | (uint32)face.verts[j];
					if (!profiles.TryGetValue(key, let profile))
						continue;
					for (int k = profile.Count - 2; k >= 1; k--)
					{
						let s = (float)k / (profile.Count - 1);
						face.Insert(i + 1, profile[k], Vector2.Lerp(face.uvs[i], face.uvs[j], s), LerpColor(face.colors[i], face.colors[j], s));
					}
					i += profile.Count - 2;
				}
			}
		}
		let firstStrip = mesh.faces.Count;
		for (let face in strips)
		{
			added?.Add((int32)mesh.faces.Count);
			mesh.faces.Add(face);
		}
		// Points other faces put along a strip's edge become its corners too, so the faces meet edge to edge.
		for (int f = firstStrip; f < mesh.faces.Count; f++)
			InsertPointsOnEdges(mesh, mesh.faces[f], firstNew);
		// What is left open round each corner is closed with a face of its own.
		let open = scope List<uint64>();
		OpenEdges(mesh, open);
		open.RemoveAll(scope (key) =>
			{
				EditMesh.EdgeEnds(key, let a, let b);
				return a < firstNew || b < firstNew;
			});
		let chains = scope List<List<int32>>();
		defer
		{
			for (let chain in chains)
				delete chain;
		}
		let closed = scope List<bool>();
		Chains(open, chains, closed);
		for (int c < chains.Count)
		{
			if (!closed[c] || chains[c].Count < 3)
				continue;
			let patch = new EditFace();
			let color = mesh.faces[firstStrip < mesh.faces.Count ? firstStrip : 0].colors[0];
			for (let v in chains[c])
				patch.Add(v, .Zero, color);
			patch.uvMode = .Auto;
			mesh.faces.Add(patch);
			OrientAgainstNeighbours(mesh, mesh.faces.Count - 1);
			if (segments < 2 || patch.Count < 4)
			{
				added?.Add((int32)mesh.faces.Count - 1);
				continue;
			}
			// Rounded: a smooth fan round a point between the patch's middle and the corner it replaces.
			var centroid = Vector3.Zero;
			for (let v in patch.verts)
				centroid = centroid + mesh.positions[v];
			centroid = centroid / patch.Count;
			var corner = centroid;
			var nearest = float.MaxValue;
			for (let v in touched)
			{
				let d = (mesh.positions[v] - centroid).LengthSquared;
				if (d < nearest)
				{
					nearest = d;
					corner = mesh.positions[v];
				}
			}
			let middle = mesh.AddVertex(centroid + (corner - centroid) * 0.5f);
			let ring = scope List<int32>();
			ring.AddRange(patch.verts);
			mesh.faces.PopBack();
			delete patch;
			for (int k < ring.Count)
			{
				let fan = new EditFace();
				fan.Add(ring[k], .Zero, color);
				fan.Add(ring[(k + 1) % ring.Count], .Zero, color);
				fan.Add(middle, .Zero, color);
				fan.uvMode = .Auto;
				fan.smooth = true;
				added?.Add((int32)mesh.faces.Count);
				mesh.faces.Add(fan);
			}
		}
		mesh.seams.Clear();
		for (let key in bevelled)
			mesh.hardEdges.Remove(key);
		Tidy(mesh, added);
	}

	/// The points across one end of a rounded bevel strip, `from` to `to` inclusive, on a curve (a quadratic Bezier
	/// with the old corner as its middle point). Made once for each pair and kept both ways round.
	static void BevelProfile(EditMesh mesh, int32 from, int32 to, Vector3 corner, int segments, Dictionary<uint64, List<int32>> profiles, List<int32> into)
	{
		into.Clear();
		if (profiles.TryGetValue((uint64)(uint32)from << 32 | (uint32)to, let existing))
		{
			into.AddRange(existing);
			return;
		}
		if (from == to)
		{
			for (int k <= segments)
				into.Add(from);
			return;
		}
		let p0 = mesh.positions[from], p2 = mesh.positions[to];
		into.Add(from);
		for (int k = 1; k < segments; k++)
		{
			let t = (float)k / segments;
			into.Add(mesh.AddVertex(p0 * ((1 - t) * (1 - t)) + corner * (2 * t * (1 - t)) + p2 * (t * t)));
		}
		into.Add(to);
		let forward = new List<int32>();
		forward.AddRange(into);
		let backward = new List<int32>();
		for (int k = into.Count - 1; k >= 0; k--)
			backward.Add(into[k]);
		profiles[(uint64)(uint32)from << 32 | (uint32)to] = forward;
		profiles[(uint64)(uint32)to << 32 | (uint32)from] = backward;
	}

	/// Where a bevel's cut at a vertex crosses one of its unbevelled edges (v, other): the point already made there,
	/// or a new one. The cut is the plane through the points the bevel made round v (along the bevelled edge, when
	/// only one meets v), so the new corners lie flat with the rest of the cut.
	static int32 CutPoint(EditMesh mesh, int32 v, int32 other, HashSet<uint64> bevelled, Dictionary<int64, List<int32>> cornerLists, Dictionary<uint64, int32> slides, float width, int32 firstNew)
	{
		let key = (uint64)(uint32)v << 32 | (uint32)other;
		if (slides.TryGetValue(key, let existing))
			return existing;
		let p = mesh.positions[v];
		// The bevel's points round v so far.
		var centroid = Vector3.Zero;
		int count = 0;
		for (let list in cornerLists.Values)
		{
			for (let point in list)
			{
				if (point >= firstNew && (mesh.positions[point] - p).Length < width * 4 + 1.0e-4f && IsPointOf(mesh, v, point, cornerLists))
				{
					centroid = centroid + mesh.positions[point];
					count++;
				}
			}
		}
		let along = mesh.positions[other] - p;
		let length = along.Length;
		var t = Math.Min(width / Math.Max(length, 1.0e-6f), 0.45f);
		if (count > 0)
		{
			centroid = centroid / count;
			var normal = p - centroid;
			// With one bevelled edge the cut runs along it.
			int32 bevelledCount = 0;
			Vector3 edgeDir = .Zero;
			for (let edge in bevelled)
			{
				EditMesh.EdgeEnds(edge, let a, let b);
				if (a == v || b == v)
				{
					bevelledCount++;
					edgeDir = (mesh.positions[a == v ? b : a] - p).Normalized;
				}
			}
			if (bevelledCount == 1)
				normal = normal - edgeDir * Vector3.Dot(normal, edgeDir);
			let denominator = Vector3.Dot(along, normal);
			if (normal.LengthSquared > 1.0e-12f && Math.Abs(denominator) > 1.0e-9f)
				t = Math.Clamp(Vector3.Dot(centroid - p, normal) / denominator, 0.01f, 0.45f);
		}
		let made = mesh.AddVertex(p + along * t);
		slides[key] = made;
		return made;
	}

	/// Whether a bevel point was made for vertex v (it is in a corner list of a face corner at v).
	static bool IsPointOf(EditMesh mesh, int32 v, int32 point, Dictionary<int64, List<int32>> cornerLists)
	{
		for (let pair in cornerLists)
		{
			let f = (int32)(pair.key >> 32);
			let i = (int)(pair.key & 0xFFFFFFFF);
			if (mesh.faces[f].verts[i] == v && pair.value.Contains(point))
				return true;
		}
		return false;
	}

	/// Adds as corners any vertices from `firstNew` on that lie along the face's edges.
	static void InsertPointsOnEdges(EditMesh mesh, EditFace face, int32 firstNew, float tolerance = 1.0e-4f)
	{
		for (int i = 0; i < face.Count; i++)
		{
			let j = (i + 1) % face.Count;
			let pa = mesh.positions[face.verts[i]], pb = mesh.positions[face.verts[j]];
			let along = pb - pa;
			let length = along.Length;
			if (length < tolerance)
				continue;
			let dir = along / length;
			int32 best = -1;
			float bestT = length;
			for (int32 v = firstNew; v < (int32)mesh.positions.Count; v++)
			{
				if (face.IndexOf(v) >= 0)
					continue;
				let offset = mesh.positions[v] - pa;
				let t = Vector3.Dot(offset, dir);
				if (t <= tolerance || t >= length - tolerance || t >= bestT || (offset - dir * t).Length > tolerance)
					continue;
				best = v;
				bestT = t;
			}
			if (best < 0)
				continue;
			let s = bestT / length;
			face.Insert(i + 1, best, Vector2.Lerp(face.uvs[i], face.uvs[j], s), LerpColor(face.colors[i], face.colors[j], s));
			i--;
		}
	}

	/// Clean that keeps face numbers in `added` meaningful: corners that repeat are dropped, unused vertices removed.
	static void Tidy(EditMesh mesh, List<int32> added)
	{
		for (let face in mesh.faces)
		{
			for (int i = face.Count - 1; i >= 0 && face.Count > 0; i--)
			{
				let next = (i + 1) % face.Count;
				if (next != i && face.verts[i] == face.verts[next])
					face.RemoveCorner(i);
			}
		}
		// Faces that collapsed are removed, renumbering `added`.
		for (int f = mesh.faces.Count - 1; f >= 0; f--)
		{
			if (mesh.faces[f].Count >= 3)
				continue;
			delete mesh.faces[f];
			mesh.faces.RemoveAt(f);
			if (added != null)
			{
				for (int k = added.Count - 1; k >= 0; k--)
				{
					if (added[k] == f)
						added.RemoveAt(k);
					else if (added[k] > f)
						added[k]--;
				}
			}
		}
		mesh.RemoveUnusedVertices();
	}

	// ---- cutting ----

	/// Puts a new vertex part way along an edge (t from a to b), in every face using the edge. Returns it.
	public static int32 SplitEdge(EditMesh mesh, int32 a, int32 b, float t)
	{
		let point = Vector3.Lerp(mesh.positions[a], mesh.positions[b], t);
		let made = mesh.AddVertex(point);
		for (let face in mesh.faces)
		{
			let n = face.Count;
			for (int i < n)
			{
				let j = (i + 1) % n;
				let fa = face.verts[i], fb = face.verts[j];
				if ((fa == a && fb == b) || (fa == b && fb == a))
				{
					let s = fa == a ? t : 1 - t;
					face.Insert(i + 1, made, Vector2.Lerp(face.uvs[i], face.uvs[j], s), LerpColor(face.colors[i], face.colors[j], s));
					break;
				}
			}
		}
		let key = EditMesh.EdgeKey(a, b);
		for (let set in HashSet<uint64>[2] (mesh.seams, mesh.hardEdges))
		{
			if (set.Remove(key))
			{
				set.Add(EditMesh.EdgeKey(a, made));
				set.Add(EditMesh.EdgeKey(made, b));
			}
		}
		return made;
	}

	/// Splits a face in two along a new edge between two of its vertices that are not next to each other. Returns
	/// the new face (the part from b round to a), or -1.
	public static int32 Connect(EditMesh mesh, int32 faceIndex, int32 a, int32 b)
	{
		let face = mesh.faces[faceIndex];
		let ia = face.IndexOf(a), ib = face.IndexOf(b);
		let n = face.Count;
		if (ia < 0 || ib < 0 || ia == ib || (ia + 1) % n == ib || (ib + 1) % n == ia)
			return -1;
		let first = new EditFace();
		let second = new EditFace();
		first.CopySettings(face);
		second.CopySettings(face);
		for (int k = 0;; k++)
		{
			let i = (ia + k) % n;
			first.Add(face.verts[i], face.uvs[i], face.colors[i]);
			if (i == ib)
				break;
		}
		for (int k = 0;; k++)
		{
			let i = (ib + k) % n;
			second.Add(face.verts[i], face.uvs[i], face.colors[i]);
			if (i == ia)
				break;
		}
		face.CopyFrom(first);
		delete first;
		mesh.faces.Add(second);
		return (int32)mesh.faces.Count - 1;
	}

	/// The edges across from an edge through four-sided faces, both ways, as far as quads go (a closed ring ends
	/// where it started). Used by Loop Cut and Select Ring.
	public static void EdgeRing(EditMesh mesh, uint64 start, List<uint64> ring)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		ring.Add(start);
		let visitedFaces = scope HashSet<int32>();
		for (int direction < 2)
		{
			var current = start;
			var cameFrom = -1;
			if (!edgeFaces.TryGetValue(start, let startFaces) || startFaces.Count <= direction)
				continue;
			var face = startFaces[direction];
			while (true)
			{
				if (face == cameFrom || visitedFaces.Contains(face) || mesh.faces[face].Count != 4)
					break;
				visitedFaces.Add(face);
				let f = mesh.faces[face];
				EditMesh.EdgeEnds(current, let a, let b);
				// The opposite edge of the quad.
				let i = f.IndexOf(a);
				let j = f.IndexOf(b);
				int32 c, d;
				if ((i + 1) % 4 == j)
				{
					c = f.verts[(j + 1) % 4];
					d = f.verts[(j + 2) % 4];
				}
				else
				{
					c = f.verts[(i + 1) % 4];
					d = f.verts[(i + 2) % 4];
				}
				let opposite = EditMesh.EdgeKey(c, d);
				if (opposite == start)
					return;
				if (ring.Contains(opposite))
					break;
				ring.Add(opposite);
				cameFrom = face;
				current = opposite;
				let next = edgeFaces[opposite];
				if (next.Count != 2)
					break;
				face = next[0] == face ? next[1] : next[0];
			}
		}
	}

	/// Cuts loops round a strip of quads through an edge: `cuts` evenly spaced (at `t` for a single cut). The new
	/// edges go into `newEdges`.
	public static void LoopCut(EditMesh mesh, uint64 edge, int cuts = 1, float t = 0.5f, List<uint64> newEdges = null)
	{
		let ring = scope List<uint64>();
		EdgeRing(mesh, edge, ring);
		if (ring.IsEmpty || cuts < 1)
			return;
		// Split every ring edge, keeping the points' order consistent across each quad: a cut point near a vertex
		// on one side of the strip is matched with the point near the vertex on the same side of the next edge.
		let splits = scope Dictionary<uint64, List<int32>>(); // edge -> points from its lower to higher vertex
		defer
		{
			for (let list in splits.Values)
				delete list;
		}
		// Which end of each ring edge is "side A": walk the quads to keep sides consistent.
		let sideA = scope Dictionary<uint64, int32>();
		EditMesh.EdgeEnds(ring[0], let s0, let s1);
		sideA[ring[0]] = s0;
		bool changed = true;
		while (changed)
		{
			changed = false;
			for (let face in mesh.faces)
			{
				if (face.Count != 4)
					continue;
				for (int i < 4)
				{
					let e1 = EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % 4]);
					let e2 = EditMesh.EdgeKey(face.verts[(i + 2) % 4], face.verts[(i + 3) % 4]);
					if (!ring.Contains(e1) || !ring.Contains(e2) || !sideA.ContainsKey(e1) || sideA.ContainsKey(e2))
						continue;
					let a1 = sideA[e1];
					// Across the quad, i joins i+3 and i+1 joins i+2.
					let partner = a1 == face.verts[i] ? face.verts[(i + 3) % 4] : face.verts[(i + 2) % 4];
					sideA[e2] = partner;
					changed = true;
				}
			}
		}
		for (let key in ring)
		{
			EditMesh.EdgeEnds(key, var a, var b);
			if (sideA.TryGetValue(key, let first) && first != a)
				Swap!(a, b);
			let points = new List<int32>();
			splits[key] = points;
			var from = a;
			for (int k < cuts)
			{
				let fraction = cuts == 1 ? t : (float)(k + 1) / (cuts + 1);
				// Splitting the remaining piece from `from` to b.
				let done = k == 0 ? 0 : (cuts == 1 ? 0 : (float)k / (cuts + 1));
				let local = (fraction - done) / (1 - done);
				let made = SplitEdge(mesh, from, b, local);
				points.Add(made);
				from = made;
			}
		}
		// Connect matching points across each quad of the strip (now with extra corners).
		for (int32 f < (int32)mesh.faces.Count)
		{
			for (int k < cuts)
			{
				let face = mesh.faces[f];
				// Find two split points of different ring edges in this face, k-th of each.
				int32 p = -1, q = -1;
				for (let pair in splits)
				{
					let point = pair.value[k];
					if (face.IndexOf(point) < 0)
						continue;
					if (p < 0)
						p = point;
					else if (q < 0)
						q = point;
				}
				if (p < 0 || q < 0)
					continue;
				let made = Connect(mesh, f, p, q);
				if (made >= 0)
					newEdges?.Add(EditMesh.EdgeKey(p, q));
				// The part holding the remaining cuts may be either; the loop over faces reaches the new one too.
			}
		}
	}

	// ---- joining ----

	/// Joins vertices into one at a point (their centre when none is given). Returns the vertex kept.
	public static int32 MergeVertices(EditMesh mesh, Span<int32> verts, Vector3? at = null)
	{
		if (verts.IsEmpty)
			return -1;
		var center = Vector3.Zero;
		for (let v in verts)
			center = center + mesh.positions[v];
		center = center / verts.Length;
		let keep = verts[0];
		mesh.positions[keep] = at ?? center;
		let remap = scope int32[mesh.positions.Count];
		for (int32 i < (int32)remap.Count)
			remap[i] = i;
		for (let v in verts)
			remap[v] = keep;
		mesh.Renumber(remap);
		mesh.Clean();
		// Clean renumbers: find the kept vertex again by its place.
		for (int32 i < (int32)mesh.positions.Count)
		{
			if ((mesh.positions[i] - (at ?? center)).LengthSquared < 1.0e-12f)
				return i;
		}
		return -1;
	}

	/// Joins the selected vertices that are within a distance of each other. Returns how many went.
	public static int MergeByDistance(EditMesh mesh, Span<int32> verts, float distance)
	{
		let selected = scope HashSet<int32>();
		for (let v in verts)
			selected.Add(v);
		let remap = scope int32[mesh.positions.Count];
		for (int32 i < (int32)remap.Count)
			remap[i] = i;
		int merged = 0;
		let list = scope List<int32>(verts.Length);
		for (let v in verts)
			list.Add(v);
		for (int i < list.Count)
		{
			let v = list[i];
			if (remap[v] != v)
				continue;
			for (int j = i + 1; j < list.Count; j++)
			{
				let w = list[j];
				if (remap[w] == w && (mesh.positions[v] - mesh.positions[w]).Length <= distance)
				{
					remap[w] = v;
					merged++;
				}
			}
		}
		if (merged > 0)
		{
			mesh.Renumber(remap);
			mesh.Clean();
		}
		return merged;
	}

	/// Orders edges into chains: each chain a list of vertices in order (closed chains do not repeat the first).
	public static void Chains(Span<uint64> edges, List<List<int32>> chains, List<bool> closed)
	{
		let neighbours = scope Dictionary<int32, List<int32>>();
		defer
		{
			for (let list in neighbours.Values)
				delete list;
		}
		for (let key in edges)
		{
			EditMesh.EdgeEnds(key, let a, let b);
			if (neighbours.TryAdd(a, ?, let first))
				*first = new List<int32>();
			neighbours[a].Add(b);
			if (neighbours.TryAdd(b, ?, let second))
				*second = new List<int32>();
			neighbours[b].Add(a);
		}
		let used = scope HashSet<uint64>();
		// Start chains at ends (one neighbour) first, then loops.
		for (int pass < 2)
		{
			for (let pair in neighbours)
			{
				let v = pair.key;
				if (pass == 0 && pair.value.Count != 1)
					continue;
				for (let first in pair.value)
				{
					if (used.Contains(EditMesh.EdgeKey(v, first)))
						continue;
					let chain = new List<int32>();
					chain.Add(v);
					var current = v;
					var next = first;
					bool isClosed = false;
					while (true)
					{
						used.Add(EditMesh.EdgeKey(current, next));
						if (next == chain[0])
						{
							isClosed = true;
							break;
						}
						chain.Add(next);
						current = next;
						int32 step = -1;
						for (let candidate in neighbours[current])
						{
							if (!used.Contains(EditMesh.EdgeKey(current, candidate)))
							{
								step = candidate;
								break;
							}
						}
						if (step < 0)
							break;
						next = step;
					}
					chains.Add(chain);
					closed.Add(isClosed);
				}
			}
		}
	}

	/// Joins two chains of edges (two open borders, say, or two loops) with a band of faces. The edges must form
	/// exactly two chains of the same length. New faces go into `added`. False when they do not.
	public static bool Bridge(EditMesh mesh, Span<uint64> edges, List<int32> added = null)
	{
		let chains = scope List<List<int32>>();
		defer
		{
			for (let chain in chains)
				delete chain;
		}
		let closed = scope List<bool>();
		Chains(edges, chains, closed);
		if (chains.Count != 2 || chains[0].Count != chains[1].Count || closed[0] != closed[1] || chains[0].Count < 2)
			return false;
		let a = chains[0], b = chains[1];
		let n = a.Count;
		// Line the second chain up with the first: the start and direction that put matching points closest.
		float best = float.MaxValue;
		int bestShift = 0;
		bool bestReversed = false;
		for (int reversed < 2)
		{
			for (int shift < (closed[0] ? n : 1))
			{
				float sum = 0;
				for (int i < n)
				{
					let j = reversed == 1 ? (shift - i + n * 2) % n : (shift + i) % n;
					let bj = (reversed == 1 && !closed[0]) ? n - 1 - i : j;
					sum += (mesh.positions[a[i]] - mesh.positions[b[bj]]).LengthSquared;
				}
				if (sum < best)
				{
					best = sum;
					bestShift = shift;
					bestReversed = reversed == 1;
				}
			}
		}
		let matched = scope List<int32>();
		for (int i < n)
		{
			let j = bestReversed ? (bestShift - i + n * 2) % n : (bestShift + i) % n;
			matched.Add(b[(bestReversed && !closed[0]) ? n - 1 - i : j]);
		}
		let first = mesh.faces.Count;
		let count = closed[0] ? n : n - 1;
		for (int i < count)
		{
			let i2 = (i + 1) % n;
			let face = mesh.AddFace(a[i], a[i2], matched[i2], matched[i]);
			face.uvMode = .Auto;
			added?.Add((int32)mesh.faces.Count - 1);
		}
		OrientNewFaces(mesh, first);
		return true;
	}

	/// Turns one face round if more of its edges run the same way as a neighbour's than the opposite way.
	static void OrientAgainstNeighbours(EditMesh mesh, int f)
	{
		let face = mesh.faces[f];
		int agree = 0, disagree = 0;
		for (int i < face.Count)
		{
			let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
			for (int g < mesh.faces.Count)
			{
				if (g == f)
					continue;
				if (RunsForward(mesh.faces[g], b, a))
					agree++;
				else if (RunsForward(mesh.faces[g], a, b))
					disagree++;
			}
		}
		if (disagree > agree)
			face.Reverse();
	}

	/// Turns faces from `first` on to agree with the faces they share edges with (or each other).
	static void OrientNewFaces(EditMesh mesh, int first)
	{
		for (int pass < 2)
		{
			for (int f = first; f < mesh.faces.Count; f++)
			{
				let face = mesh.faces[f];
				int agree = 0, disagree = 0;
				for (int i < face.Count)
				{
					let a = face.verts[i], b = face.verts[(i + 1) % face.Count];
					for (int g < mesh.faces.Count)
					{
						if (g == f || (pass == 0 && g >= first))
							continue;
						if (RunsForward(mesh.faces[g], b, a))
							agree++;
						else if (RunsForward(mesh.faces[g], a, b))
							disagree++;
					}
				}
				if (disagree > agree)
					face.Reverse();
			}
		}
	}

	/// Closes holes: each chain of selected open edges that loops round becomes a face. New faces go into `added`.
	public static int Fill(EditMesh mesh, Span<uint64> edges, List<int32> added = null)
	{
		let chains = scope List<List<int32>>();
		defer
		{
			for (let chain in chains)
				delete chain;
		}
		let closed = scope List<bool>();
		Chains(edges, chains, closed);
		int made = 0;
		for (int c < chains.Count)
		{
			let chain = chains[c];
			if (chain.Count < 3)
				continue;
			let first = mesh.faces.Count;
			let face = new EditFace();
			for (let v in chain)
				face.Add(v);
			mesh.faces.Add(face);
			OrientNewFaces(mesh, first);
			added?.Add((int32)first);
			made++;
		}
		return made;
	}

	// ---- removing ----

	public static void DeleteFaces(EditMesh mesh, Span<int32> faces)
	{
		let ordered = scope List<int32>();
		for (let f in faces)
		{
			if (!ordered.Contains(f))
				ordered.Add(f);
		}
		ordered.Sort((a, b) => b <=> a);
		for (let f in ordered)
		{
			delete mesh.faces[f];
			mesh.faces.RemoveAt(f);
		}
		mesh.RemoveUnusedVertices();
	}

	/// Removes vertices and every face using them.
	public static void DeleteVertices(EditMesh mesh, Span<int32> verts)
	{
		let gone = scope HashSet<int32>();
		for (let v in verts)
			gone.Add(v);
		let faces = scope List<int32>();
		for (int32 f < (int32)mesh.faces.Count)
		{
			for (let v in mesh.faces[f].verts)
			{
				if (gone.Contains(v))
				{
					faces.Add(f);
					break;
				}
			}
		}
		DeleteFaces(mesh, faces);
	}

	/// Removes edges and the faces using them.
	public static void DeleteEdges(EditMesh mesh, Span<uint64> edges)
	{
		let gone = scope HashSet<uint64>();
		for (let key in edges)
			gone.Add(key);
		let faces = scope List<int32>();
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				if (gone.Contains(EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count])))
				{
					faces.Add(f);
					break;
				}
			}
		}
		DeleteFaces(mesh, faces);
	}

	/// Takes edges out, joining the two faces either side of each into one. Returns how many went.
	public static int DissolveEdges(EditMesh mesh, Span<uint64> edges)
	{
		int done = 0;
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let faces in edgeFaces.Values)
				delete faces;
		}
		for (let key in edges)
		{
			// Faces change number as they go: look again each time.
			for (let faces in edgeFaces.Values)
				delete faces;
			edgeFaces.Clear();
			mesh.EdgeFaces(edgeFaces);
			if (!edgeFaces.TryGetValue(key, let list) || list.Count != 2 || list[0] == list[1])
				continue;
			EditMesh.EdgeEnds(key, let a, let b);
			let fa = mesh.faces[list[0]], fb = mesh.faces[list[1]];
			if (!JoinAcross(fa, fb, a, b))
				continue;
			delete fb;
			mesh.faces.RemoveAt(list[1]);
			done++;
		}
		// Corners left sitting in a straight line with nothing else using them are not needed.
		mesh.Clean();
		return done;
	}

	/// Like EditMesh's own join, without the checks that the faces lie flat or match texture coordinates.
	static bool JoinAcross(EditFace fa, EditFace fb, int32 va, int32 vb)
	{
		var ia = fa.IndexOf(va);
		var ja = fa.IndexOf(vb);
		if (ia < 0 || ja < 0)
			return false;
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
		let joined = scope EditFace();
		joined.CopySettings(fa);
		for (int k < fa.Count)
		{
			let i = (ja + k) % fa.Count;
			joined.Add(fa.verts[i], fa.uvs[i], fa.colors[i]);
		}
		for (int k = 1; k < fb.Count - 1; k++)
		{
			let i = (jb + k) % fb.Count;
			if (joined.IndexOf(fb.verts[i]) >= 0)
				return false;
			joined.Add(fb.verts[i], fb.uvs[i], fb.colors[i]);
		}
		fa.CopyFrom(joined);
		return true;
	}

	/// Gives the faces vertices of their own where they meet faces outside the selection, so they come apart.
	public static void Detach(EditMesh mesh, Span<int32> faces)
	{
		let selected = scope HashSet<int32>();
		for (let f in faces)
			selected.Add(f);
		let usedOutside = scope HashSet<int32>();
		for (int32 f < (int32)mesh.faces.Count)
		{
			if (selected.Contains(f))
				continue;
			for (let v in mesh.faces[f].verts)
				usedOutside.Add(v);
		}
		let copies = scope Dictionary<int32, int32>();
		for (let f in faces)
		{
			for (var v in ref mesh.faces[f].verts)
			{
				if (!usedOutside.Contains(v))
					continue;
				if (!copies.TryGetValue(v, let copy))
				{
					let made = mesh.AddVertex(mesh.positions[v]);
					copies[v] = made;
					v = made;
				}
				else
					v = copy;
			}
		}
	}

	/// Copies faces (with vertices of their own). The copies go into `added`.
	public static void Duplicate(EditMesh mesh, Span<int32> faces, List<int32> added = null)
	{
		let copies = scope Dictionary<int32, int32>();
		for (let f in faces)
		{
			let copy = new EditFace();
			copy.CopyFrom(mesh.faces[f]);
			for (var v in ref copy.verts)
			{
				if (!copies.TryGetValue(v, let existing))
				{
					let made = mesh.AddVertex(mesh.positions[v]);
					copies[v] = made;
					v = made;
				}
				else
					v = existing;
			}
			added?.Add((int32)mesh.faces.Count);
			mesh.faces.Add(copy);
		}
	}

	// ---- building out ----

	/// Cuts each face into four-sided faces round its centre, through the middle of each edge (neighbouring faces
	/// outside the selection get the new edge points as corners, so nothing comes apart). With smooth, the new
	/// points are moved to round the shape off (Catmull-Clark) where the whole neighbourhood is selected.
	public static void Subdivide(EditMesh mesh, Span<int32> faces, bool smooth = false, List<int32> added = null)
	{
		let selected = scope HashSet<int32>();
		for (let f in faces)
			selected.Add(f);
		let originalPositions = scope List<Vector3>();
		originalPositions.AddRange(mesh.positions);
		// Middle of each edge of a selected face, made once.
		let middles = scope Dictionary<uint64, int32>();
		// Every edge of the selected faces as they were: splitting adds corners to faces as it goes.
		let original = scope List<uint64>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				let key = EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count]);
				if (!original.Contains(key))
					original.Add(key);
			}
		}
		for (let key in original)
		{
			EditMesh.EdgeEnds(key, let a, let b);
			middles[key] = SplitEdge(mesh, a, b, 0.5f);
		}
		let middleVerts = scope HashSet<int32>();
		for (let v in middles.Values)
			middleVerts.Add(v);
		// SplitEdge put each middle into every face along the edge. Now fan each selected face from its centre.
		let centers = scope Dictionary<int32, int32>();
		// For smoothing: the face points either side of each original edge (by its middle vertex).
		let facePointsOfMiddle = scope Dictionary<int32, List<Vector3>>();
		defer
		{
			for (let list in facePointsOfMiddle.Values)
				delete list;
		}
		let originalFaceCount = mesh.faces.Count;
		for (let f in faces)
		{
			let face = mesh.faces[f];
			let center = mesh.FaceCenter(face);
			Sample(mesh, face, center, let centerUV, let centerColor);
			let c = mesh.AddVertex(center);
			centers[f] = c;
			// Corners alternate: original vertex, middle, original, middle...
			let n = face.Count;
			let quads = scope List<EditFace>();
			for (int i < n)
			{
				let v = face.verts[i];
				if (middleVerts.Contains(v))
				{
					if (facePointsOfMiddle.TryAdd(v, ?, let value))
						*value = new List<Vector3>();
					facePointsOfMiddle[v].Add(center);
					continue;
				}
				let prev = (i + n - 1) % n, next = (i + 1) % n;
				let quad = new EditFace();
				quad.CopySettings(face);
				quad.Add(face.verts[prev], face.uvs[prev], face.colors[prev]);
				quad.Add(v, face.uvs[i], face.colors[i]);
				quad.Add(face.verts[next], face.uvs[next], face.colors[next]);
				quad.Add(c, centerUV, centerColor);
				quads.Add(quad);
			}
			if (quads.IsEmpty)
				continue;
			face.CopyFrom(quads[0]);
			delete quads[0];
			for (int q = 1; q < quads.Count; q++)
			{
				added?.Add((int32)mesh.faces.Count);
				mesh.faces.Add(quads[q]);
			}
		}
		if (!smooth)
			return;
		// Catmull-Clark: edge points average the edge's ends and the two face points; original vertices move to
		// (F + 2R + (n - 3)P) / n where every face round them was subdivided.
		let edgePoints = scope Dictionary<int32, Vector3>();
		for (let pair in middles)
		{
			EditMesh.EdgeEnds(pair.key, let a, let b);
			if (facePointsOfMiddle.TryGetValue(pair.value, let list) && list.Count == 2)
				edgePoints[pair.value] = (originalPositions[a] + originalPositions[b] + list[0] + list[1]) * 0.25f;
		}
		let faceSums = scope Dictionary<int32, (Vector3 sum, int count)>();
		let edgeSums = scope Dictionary<int32, (Vector3 sum, int count)>();
		let blocked = scope HashSet<int32>();
		for (int32 f < (int32)originalFaceCount)
		{
			// Faces not subdivided keep their original corners; those vertices stay put.
			if (centers.ContainsKey(f))
				continue;
			for (let v in mesh.faces[f].verts)
				blocked.Add(v);
		}
		// Each new quad holds one original vertex (corner 1), its face point (corner 3).
		for (int32 g < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[g];
			if (face.Count != 4 || !middleVerts.Contains(face.verts[0]) || !middleVerts.Contains(face.verts[2]))
				continue;
			let v = face.verts[1];
			if (v >= originalPositions.Count)
				continue;
			if (faceSums.TryAdd(v, ?, let value))
				*value = (.Zero, 0);
			faceSums[v] = (faceSums[v].sum + mesh.positions[face.verts[3]], faceSums[v].count + 1);
		}
		for (let pair in middles)
		{
			EditMesh.EdgeEnds(pair.key, let a, let b);
			let midpoint = (originalPositions[a] + originalPositions[b]) * 0.5f;
			for (let v in int32[2](a, b))
			{
				if (edgeSums.TryAdd(v, ?, let value))
					*value = (.Zero, 0);
				edgeSums[v] = (edgeSums[v].sum + midpoint, edgeSums[v].count + 1);
			}
		}
		for (let pair in faceSums)
		{
			let v = pair.key;
			if (blocked.Contains(v) || pair.value.count < 3 || !edgeSums.ContainsKey(v))
				continue;
			let edges = edgeSums[v];
			if (edges.count != pair.value.count)
				continue;
			let n = (float)pair.value.count;
			mesh.positions[v] = (pair.value.sum / n + edges.sum / n * 2 + originalPositions[v] * (n - 3)) / n;
		}
		for (let pair in edgePoints)
			mesh.positions[pair.key] = pair.value;
	}

	/// Adds a mirror copy across the plane through the origin square to an axis (0 x, 1 y, 2 z), joined to the
	/// original where they meet. Faces lying in the plane are dropped first, since the halves join there.
	public static void Mirror(EditMesh mesh, int axis, float weld = 0.0001f)
	{
		let inPlane = scope List<int32>();
		for (int32 f < (int32)mesh.faces.Count)
		{
			bool all = true;
			for (let v in mesh.faces[f].verts)
				all &= Math.Abs(Component(mesh.positions[v], axis)) <= weld;
			if (all)
				inPlane.Add(f);
		}
		DeleteFaces(mesh, inPlane);
		let copy = scope EditMesh();
		copy.CopyFrom(mesh);
		var scale = Vector3.One;
		if (axis == 0)
			scale.x = -1;
		else if (axis == 1)
			scale.y = -1;
		else
			scale.z = -1;
		mesh.Append(copy, Matrix4.Scale(scale));
		// Snap points near the plane onto it so the halves meet exactly.
		for (var p in ref mesh.positions)
		{
			if (Math.Abs(Component(p, axis)) <= weld)
			{
				if (axis == 0)
					p.x = 0;
				else if (axis == 1)
					p.y = 0;
				else
					p.z = 0;
			}
		}
		mesh.Weld(weld);
	}

	public static float Component(Vector3 v, int axis) => axis == 0 ? v.x : (axis == 1 ? v.y : v.z);

	/// Repeats the whole mesh `count` times in all, each copy moved by `offset` (and turned by `turn`) from the last.
	public static void Array(EditMesh mesh, int count, Vector3 offset, Quaternion turn = .Identity, bool weld = true)
	{
		let copy = scope EditMesh();
		copy.CopyFrom(mesh);
		var transform = Matrix4.Identity;
		let step = Matrix4.TRS(offset, turn, .One);
		for (int i = 1; i < count; i++)
		{
			transform = step * transform;
			mesh.Append(copy, transform);
		}
		if (weld)
			mesh.Weld();
	}

	/// Moves every vertex so that a point becomes the origin. The editor moves the object the other way, so
	/// nothing moves in the world.
	public static void MoveOrigin(EditMesh mesh, Vector3 newOrigin)
	{
		for (var p in ref mesh.positions)
			p = p - newOrigin;
	}

	/// The average of the vertices the faces use (Blender's Origin to Geometry).
	public static Vector3 GeometryCentre(EditMesh mesh)
	{
		let used = scope HashSet<int32>();
		var sum = Vector3.Zero;
		for (let face in mesh.faces)
		{
			for (let v in face.verts)
			{
				if (used.Add(v))
					sum = sum + mesh.positions[v];
			}
		}
		return used.Count > 0 ? sum / used.Count : Vector3.Zero;
	}

	/// The middle of the surface, each part counted by its area: the centre of mass of a thin shell.
	public static Vector3 SurfaceCentre(EditMesh mesh)
	{
		var sum = Vector3.Zero;
		float area = 0;
		for (let face in mesh.faces)
		{
			for (int i = 1; i + 1 < face.verts.Count; i++)
			{
				let a = mesh.positions[face.verts[0]];
				let b = mesh.positions[face.verts[i]];
				let c = mesh.positions[face.verts[i + 1]];
				let part = Vector3.Cross(b - a, c - a).Length * 0.5f;
				sum = sum + (a + b + c) * (part / 3);
				area += part;
			}
		}
		return area > 1e-12f ? sum / area : GeometryCentre(mesh);
	}

	/// The centre of mass of the solid the faces close round, as if filled evenly. A model that is open or holds no
	/// room gets its surface's centre instead.
	public static Vector3 VolumeCentre(EditMesh mesh)
	{
		// Tetrahedra from a point inside to each triangle, signed by which way the triangle faces.
		let middle = GeometryCentre(mesh);
		var sum = Vector3.Zero;
		float volume = 0;
		float area = 0;
		for (let face in mesh.faces)
		{
			for (int i = 1; i + 1 < face.verts.Count; i++)
			{
				let a = mesh.positions[face.verts[0]] - middle;
				let b = mesh.positions[face.verts[i]] - middle;
				let c = mesh.positions[face.verts[i + 1]] - middle;
				let part = Vector3.Dot(a, Vector3.Cross(b, c)) / 6;
				sum = sum + (a + b + c) * (part / 4);
				volume += part;
				area += Vector3.Cross(b - a, c - a).Length * 0.5f;
			}
		}
		if (!mesh.IsClosed() || Math.Abs(volume) <= 1e-6f * Math.Pow(Math.Max(area, 1e-12f), 1.5f))
			return SurfaceCentre(mesh);
		return middle + sum / volume;
	}

	// ---- selection helpers ----

	/// The loop of edges through an edge: on through each vertex where four edges meet, to the edge straight
	/// across, until it closes or reaches a vertex where it cannot go straight on.
	public static void EdgeLoop(EditMesh mesh, uint64 start, List<uint64> loop)
	{
		loop.Add(start);
		EditMesh.EdgeEnds(start, let s0, let s1);
		for (int direction < 2)
		{
			var from = direction == 0 ? s0 : s1;
			var at = direction == 0 ? s1 : s0;
			for (int guard < 10000)
			{
				// The faces round `at`; with exactly four edges, the next edge is the one not sharing a face with
				// the edge we came along.
				let faces = scope List<int32>();
				mesh.FacesOfVertex(at, faces);
				let neighbours = scope List<int32>();
				for (let f in faces)
				{
					let face = mesh.faces[f];
					let i = face.IndexOf(at);
					let prev = face.verts[(i + face.Count - 1) % face.Count], next = face.verts[(i + 1) % face.Count];
					if (!neighbours.Contains(prev))
						neighbours.Add(prev);
					if (!neighbours.Contains(next))
						neighbours.Add(next);
				}
				if (neighbours.Count != 4 || faces.Count != 4)
					break;
				int32 onward = -1;
				for (let candidate in neighbours)
				{
					if (candidate == from)
						continue;
					bool sharesFace = false;
					for (let f in faces)
					{
						let face = mesh.faces[f];
						if (face.IndexOf(candidate) >= 0 && face.IndexOf(from) >= 0)
						{
							sharesFace = true;
							break;
						}
					}
					if (!sharesFace)
					{
						onward = candidate;
						break;
					}
				}
				if (onward < 0)
					break;
				let key = EditMesh.EdgeKey(at, onward);
				if (key == start || loop.Contains(key))
					return;
				loop.Add(key);
				from = at;
				at = onward;
			}
		}
	}

	/// The faces joined to some faces through shared edges.
	public static void Linked(EditMesh mesh, Span<int32> faces, HashSet<int32> into)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		let stack = scope List<int32>();
		for (let f in faces)
		{
			if (into.Add(f))
				stack.Add(f);
		}
		while (!stack.IsEmpty)
		{
			let f = stack.PopBack();
			let face = mesh.faces[f];
			for (int i < face.Count)
			{
				for (let other in edgeFaces[EditMesh.EdgeKey(face.verts[i], face.verts[(i + 1) % face.Count])])
				{
					if (into.Add(other))
						stack.Add(other);
				}
			}
		}
	}

	/// Adds the faces that share a vertex with the selected ones.
	public static void Grow(EditMesh mesh, HashSet<int32> faces)
	{
		let verts = scope HashSet<int32>();
		for (let f in faces)
		{
			for (let v in mesh.faces[f].verts)
				verts.Add(v);
		}
		for (int32 f < (int32)mesh.faces.Count)
		{
			for (let v in mesh.faces[f].verts)
			{
				if (verts.Contains(v))
				{
					faces.Add(f);
					break;
				}
			}
		}
	}

	/// The vertices of some faces.
	public static void VerticesOf(EditMesh mesh, Span<int32> faces, HashSet<int32> into)
	{
		for (let f in faces)
		{
			for (let v in mesh.faces[f].verts)
				into.Add(v);
		}
	}

	/// The edges with only one face: the mesh's open borders.
	public static void OpenEdges(EditMesh mesh, List<uint64> into)
	{
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		mesh.EdgeFaces(edgeFaces);
		for (let pair in edgeFaces)
		{
			if (pair.value.Count == 1)
				into.Add(pair.key);
		}
	}
}
