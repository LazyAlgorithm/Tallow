using System;
using System.Collections;

namespace Tallow;

/// Where one vertex of an edge slide may go: along the edges leaving it on each side of the picked edges.
public struct SlideRail
{
	public int32 vertex;
	public Vector3 start;
	/// The ends of the rails on the side where the picked edges run forwards in their faces (left), and the other.
	public Vector3 left;
	public Vector3 right;
	public bool hasLeft;
	public bool hasRight;
}

/// Sliding (docs/modeling.md): edges along the faces either side of them, and vertices along their own edges, so
/// that a cut or a loop can be moved without changing the shape of the model.
extension MeshOps
{
	/// The rails for sliding edges: for every vertex of the edges, where it would end up at each side. Where two
	/// edges give a vertex different rails on one side, it goes to their average.
	public static void EdgeSlideRails(EditMesh mesh, Span<uint64> edges, List<SlideRail> rails)
	{
		rails.Clear();
		let picked = scope HashSet<uint64>();
		let pickedVerts = scope HashSet<int32>();
		for (let key in edges)
		{
			picked.Add(key);
			EditMesh.EdgeEnds(key, let a, let b);
			pickedVerts.Add(a);
			pickedVerts.Add(b);
		}
		// Which way each edge runs along its chain, so that "left" is the same side all along a loop.
		let chains = scope List<List<int32>>();
		defer
		{
			for (let chain in chains)
				delete chain;
		}
		let closed = scope List<bool>();
		Chains(edges, chains, closed);
		let runsFrom = scope Dictionary<uint64, int32>();
		for (int c < chains.Count)
		{
			let chain = chains[c];
			let count = closed[c] ? chain.Count : chain.Count - 1;
			for (int i < count)
				runsFrom[EditMesh.EdgeKey(chain[i], chain[(i + 1) % chain.Count])] = chain[i];
		}
		// Each vertex's rail ends on each side, without repeats.
		let leftEnds = scope Dictionary<int32, List<int32>>();
		let rightEnds = scope Dictionary<int32, List<int32>>();
		defer
		{
			for (let list in leftEnds.Values)
				delete list;
			for (let list in rightEnds.Values)
				delete list;
		}
		void AddEnd(Dictionary<int32, List<int32>> ends, int32 v, int32 end)
		{
			// A rail to another picked vertex would fold the faces between them.
			if (pickedVerts.Contains(end))
				return;
			if (!ends.TryGetValue(v, var list))
			{
				list = new List<int32>();
				ends[v] = list;
			}
			if (!list.Contains(end))
				list.Add(end);
		}
		for (let face in mesh.faces)
		{
			let n = face.Count;
			for (int i < n)
			{
				let a = face.verts[i], b = face.verts[(i + 1) % n];
				if (!picked.Contains(EditMesh.EdgeKey(a, b)))
					continue;
				// This face is on the edge's left when the edge runs a -> b in it the way its chain does.
				let key = EditMesh.EdgeKey(a, b);
				let forward = runsFrom.TryGetValue(key, let from) ? from == a : a < b;
				let ends = forward ? leftEnds : rightEnds;
				AddEnd(ends, a, face.verts[(i + n - 1) % n]);
				AddEnd(ends, b, face.verts[(i + 2) % n]);
			}
		}
		for (let v in pickedVerts)
		{
			var rail = SlideRail() { vertex = v, start = mesh.positions[v] };
			if (leftEnds.TryGetValue(v, let left))
			{
				rail.left = Average(mesh, left);
				rail.hasLeft = true;
			}
			if (rightEnds.TryGetValue(v, let right))
			{
				rail.right = Average(mesh, right);
				rail.hasRight = true;
			}
			if (rail.hasLeft || rail.hasRight)
				rails.Add(rail);
		}
	}

	static Vector3 Average(EditMesh mesh, List<int32> verts)
	{
		var sum = Vector3.Zero;
		for (let v in verts)
			sum = sum + mesh.positions[v];
		return sum / Math.Max(verts.Count, 1);
	}

	/// Slides the vertices along their rails: amount 0 leaves them, 1 takes them to the left ends and -1 to the
	/// right ones (a vertex without a rail on that side stays).
	public static void ApplySlide(EditMesh mesh, Span<SlideRail> rails, float amount)
	{
		let t = Math.Clamp(amount, -1.0f, 1.0f);
		for (let rail in rails)
		{
			var p = rail.start;
			if (t > 0 && rail.hasLeft)
				p = Vector3.Lerp(rail.start, rail.left, t);
			else if (t < 0 && rail.hasRight)
				p = Vector3.Lerp(rail.start, rail.right, -t);
			mesh.positions[rail.vertex] = p;
		}
	}

	/// The vertices joined to a vertex by an edge.
	public static void Neighbours(EditMesh mesh, int32 vertex, List<int32> into)
	{
		into.Clear();
		for (let face in mesh.faces)
		{
			let i = face.IndexOf(vertex);
			if (i < 0)
				continue;
			let n = face.Count;
			for (let other in int32[2](face.verts[(i + n - 1) % n], face.verts[(i + 1) % n]))
			{
				if (other != vertex && !into.Contains(other))
					into.Add(other);
			}
		}
	}
}
