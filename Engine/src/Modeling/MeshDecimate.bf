using System;
using System.Collections;

namespace Tallow;

/// Fewer faces for levels of detail (docs/modeling.md): short edges across flat parts of a model are collapsed
/// first, edges at sharp corners last, and the model's open borders are left where they are.
extension MeshOps
{
	/// How many triangles the faces draw as.
	public static int TriangleCount(EditMesh mesh)
	{
		int count = 0;
		for (let face in mesh.faces)
			count += Math.Max(face.Count - 2, 0);
		return count;
	}

	/// Collapses edges until about `share` of the triangles are left (or nothing more can go without folding a face
	/// over). Returns how many edges were collapsed.
	public static int Decimate(EditMesh mesh, float share)
	{
		let target = Math.Max((int)(TriangleCount(mesh) * Math.Clamp(share, 0, 1)), 4);
		int collapsed = 0;
		let edgeFaces = scope Dictionary<uint64, List<int32>>();
		defer
		{
			for (let list in edgeFaces.Values)
				delete list;
		}
		let neighbours = scope Dictionary<int32, HashSet<int32>>();
		defer
		{
			for (let set in neighbours.Values)
				delete set;
		}
		let facesOf = scope Dictionary<int32, List<int32>>();
		defer
		{
			for (let list in facesOf.Values)
				delete list;
		}
		for (int pass < 200)
		{
			var triangles = TriangleCount(mesh);
			if (triangles <= target)
				break;
			for (let list in edgeFaces.Values)
				delete list;
			edgeFaces.Clear();
			mesh.EdgeFaces(edgeFaces);
			for (let set in neighbours.Values)
				delete set;
			neighbours.Clear();
			for (let list in facesOf.Values)
				delete list;
			facesOf.Clear();
			for (int32 f < (int32)mesh.faces.Count)
			{
				let face = mesh.faces[f];
				for (int i < face.Count)
				{
					let v = face.verts[i];
					if (!facesOf.TryGetValue(v, var list))
					{
						list = new List<int32>();
						facesOf[v] = list;
					}
					list.Add(f);
					if (!neighbours.TryGetValue(v, var set))
					{
						set = new HashSet<int32>();
						neighbours[v] = set;
					}
					set.Add(face.verts[(i + 1) % face.Count]);
					set.Add(face.verts[(i + face.Count - 1) % face.Count]);
				}
			}
			// Vertices on open borders stay.
			let border = scope HashSet<int32>();
			for (let pair in edgeFaces)
			{
				if (pair.value.Count != 2)
				{
					EditMesh.EdgeEnds(pair.key, let a, let b);
					border.Add(a);
					border.Add(b);
				}
			}
			// Cheapest first: short, and between faces lying flat together.
			let costs = scope List<(float cost, uint64 key)>();
			for (let pair in edgeFaces)
			{
				if (pair.value.Count != 2)
					continue;
				EditMesh.EdgeEnds(pair.key, let a, let b);
				if (border.Contains(a) || border.Contains(b))
					continue;
				let bend = 1 - Vector3.Dot(mesh.FaceNormal(mesh.faces[pair.value[0]]), mesh.FaceNormal(mesh.faces[pair.value[1]]));
				var cost = (mesh.positions[a] - mesh.positions[b]).Length * (1 + bend * 8);
				if (mesh.hardEdges.Contains(pair.key) || mesh.seams.Contains(pair.key))
					cost *= 4;
				costs.Add((cost, pair.key));
			}
			costs.Sort((x, y) => x.cost <=> y.cost);
			// Collapses that do not touch each other, so each can be checked against the model as it is.
			let locked = scope HashSet<int32>();
			let remap = scope int32[mesh.positions.Count];
			for (int32 i < (int32)remap.Count)
				remap[i] = i;
			int made = 0;
			for (let entry in costs)
			{
				if (triangles <= target)
					break;
				EditMesh.EdgeEnds(entry.key, let a, let b);
				if (locked.Contains(a) || locked.Contains(b))
					continue;
				let shared = edgeFaces[entry.key];
				// The link condition: a and b may only share the neighbours of triangles on the edge, or the
				// collapse pinches the surface.
				int triangleTips = 0;
				for (let f in shared)
				{
					if (mesh.faces[f].Count == 3)
						triangleTips++;
				}
				int common = 0;
				for (let n in neighbours[a])
				{
					if (n != b && neighbours[b].Contains(n))
						common++;
				}
				if (common != triangleTips)
					continue;
				// No face round either end may turn over.
				let middle = (mesh.positions[a] + mesh.positions[b]) * 0.5f;
				if (!CollapseKeepsFacing(mesh, a, b, middle, facesOf))
					continue;
				// Corners at both ends meet with the average texture coordinates of the two.
				for (let f in shared)
				{
					let face = mesh.faces[f];
					let ia = face.IndexOf(a), ib = face.IndexOf(b);
					let uv = (face.uvs[ia] + face.uvs[ib]) * 0.5f;
					face.uvs[ia] = uv;
					face.uvs[ib] = uv;
				}
				mesh.positions[a] = middle;
				mesh.positions[b] = middle;
				remap[b] = a;
				locked.Add(a);
				locked.Add(b);
				for (let n in neighbours[a])
					locked.Add(n);
				for (let n in neighbours[b])
					locked.Add(n);
				triangles -= shared.Count;
				made++;
			}
			if (made == 0)
				break;
			collapsed += made;
			mesh.Renumber(remap);
			mesh.Clean();
		}
		return collapsed;
	}

	/// Whether moving a and b to one point leaves every face round them looking much the way it did.
	static bool CollapseKeepsFacing(EditMesh mesh, int32 a, int32 b, Vector3 point, Dictionary<int32, List<int32>> facesOf)
	{
		let oldA = mesh.positions[a], oldB = mesh.positions[b];
		let before = scope List<(int32 face, Vector3 normal)>();
		for (let v in int32[2](a, b))
		{
			for (let f in facesOf[v])
			{
				let face = mesh.faces[f];
				// Faces on the edge itself lose a corner rather than turning.
				if (face.IndexOf(a) >= 0 && face.IndexOf(b) >= 0)
					continue;
				before.Add((f, mesh.FaceNormal(face)));
			}
		}
		mesh.positions[a] = point;
		mesh.positions[b] = point;
		var keeps = true;
		for (let entry in before)
		{
			let face = mesh.faces[entry.face];
			if (mesh.FaceArea(face) < 1.0e-10f || Vector3.Dot(mesh.FaceNormal(face), entry.normal) < 0.3f)
			{
				keeps = false;
				break;
			}
		}
		mesh.positions[a] = oldA;
		mesh.positions[b] = oldB;
		return keeps;
	}
}
