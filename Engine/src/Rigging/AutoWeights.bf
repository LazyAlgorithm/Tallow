using System;
using System.Collections;

namespace Tallow;

/// Makes a rig's weights from its bones (docs/rigging.md): "bone heat", as Mixamo and Blender's automatic weights do.
/// Each bone warms the vertices it is the nearest bone to and can see (no part of the model between), and the warmth
/// spreads over the surface, so that weights fall off smoothly across joints and an arm does not move the side it
/// hangs beside. The spreading is solved in the native library (native/tessera_rig.cpp).
///
/// Vertices in the same place (a seam where a model's texture is cut) are solved as one, so seams never tear. Each
/// vertex keeps its four strongest bones (what a rigged file holds), adding up to 1.
static class AutoWeights
{
	/// A position by its exact bits.
	struct PlaceKey : IHashable
	{
		public uint32 x, y, z;

		public this(uint32 x, uint32 y, uint32 z)
		{
			this.x = x;
			this.y = y;
			this.z = z;
		}

		public int GetHashCode() => (int)(x * 73856093 ^ y * 19349663 ^ z * 83492791);

		public static bool operator ==(PlaceKey a, PlaceKey b) => a.x == b.x && a.y == b.y && a.z == b.z;
	}

	[CLink] static extern int32 tn_rig_heat_weights(float* positions, int32 vertexCount, int32* triangles, int32 triangleCount, float* heat, int32* nearest, float* shares,
		int32 perVertex, int32 boneCount, int32 iterations, float* weights);

	public const int MaxInfluences = 4;

	/// One place on the model: the rig's vertices that are there (by their exact position).
	public static void Weld(Rig rig, List<int32> placeOf, List<Vector3> places)
	{
		placeOf.Clear();
		places.Clear();
		let found = scope Dictionary<PlaceKey, int32>();
		for (let p in rig.positions)
		{
			var x = p.x, y = p.y, z = p.z;
			// -0 and 0 are the same place.
			if (x == 0)
				x = 0;
			if (y == 0)
				y = 0;
			if (z == 0)
				z = 0;
			let key = PlaceKey(*(uint32*)&x, *(uint32*)&y, *(uint32*)&z);
			if (found.TryGetValue(key, let index))
				placeOf.Add(index);
			else
			{
				let added = (int32)places.Count;
				found[key] = added;
				places.Add(p);
				placeOf.Add(added);
			}
		}
	}

	/// The bone segments a bone owns: one to each child's joint, or to its tail when it has none.
	public static void Segments(Rig rig, int bone, List<(Vector3 a, Vector3 b)> output)
	{
		output.Clear();
		for (let other in rig.bones)
		{
			if (other.parent == bone)
				output.Add((rig.bones[bone].head, other.head));
		}
		if (output.IsEmpty)
			output.Add((rig.bones[bone].head, rig.bones[bone].tail));
	}

	/// The point of a segment nearest a point.
	public static Vector3 Closest(Vector3 p, Vector3 a, Vector3 b)
	{
		let ab = b - a;
		let lengthSq = Vector3.Dot(ab, ab);
		if (lengthSq < 1e-12f)
			return a;
		let t = Math.Clamp(Vector3.Dot(p - a, ab) / lengthSq, 0, 1);
		return a + ab * t;
	}

	/// Makes every vertex's weights from the bones. False when there is nothing to weigh (no bones that bend the
	/// mesh). `iterations` caps each bone's solve (more is smoother on big models).
	public static bool Make(Rig rig, int iterations = 400)
	{
		let boneCount = rig.bones.Count;
		let deforming = scope List<int>();
		for (int b < boneCount)
		{
			if (rig.bones[b].deform)
				deforming.Add(b);
		}
		if (deforming.IsEmpty || rig.positions.IsEmpty)
			return false;
		let placeOf = scope List<int32>();
		let places = scope List<Vector3>();
		Weld(rig, placeOf, places);
		let triangles = scope List<int32>();
		for (let part in rig.parts)
		{
			for (let index in part.indices)
				triangles.Add(placeOf[index]);
		}
		let allIndices = scope List<uint32>();
		rig.Triangles(allIndices);
		let rays = scope RigRays(rig.positions, allIndices);

		// Each place's nearest bones, and which of them it can see.
		let size = Math.Max(rig.bounds.Size.Length, 1e-4f);
		let segments = scope List<List<(Vector3 a, Vector3 b)>>();
		defer
		{
			for (let list in segments)
				delete list;
		}
		for (let b in deforming)
		{
			let list = new List<(Vector3 a, Vector3 b)>();
			Segments(rig, b, list);
			segments.Add(list);
		}
		const int Candidates = 4;
		let n = places.Count;
		let candidate = scope int32[n * Candidates];
		let distance = scope float[n * Candidates];
		let closest = scope Vector3[n * Candidates];
		for (int p < n)
		{
			for (int k < Candidates)
			{
				candidate[p * Candidates + k] = -1;
				distance[p * Candidates + k] = float.MaxValue;
			}
			let point = places[p];
			for (int d < deforming.Count)
			{
				var best = float.MaxValue;
				var bestPoint = point;
				for (let segment in segments[d])
				{
					let q = Closest(point, segment.a, segment.b);
					let dist = (q - point).Length;
					if (dist < best)
					{
						best = dist;
						bestPoint = q;
					}
				}
				// Kept in order, nearest first.
				for (int k < Candidates)
				{
					if (best < distance[p * Candidates + k])
					{
						for (int m = Candidates - 1; m > k; m--)
						{
							candidate[p * Candidates + m] = candidate[p * Candidates + m - 1];
							distance[p * Candidates + m] = distance[p * Candidates + m - 1];
							closest[p * Candidates + m] = closest[p * Candidates + m - 1];
						}
						candidate[p * Candidates + k] = (int32)d;
						distance[p * Candidates + k] = best;
						closest[p * Candidates + k] = bestPoint;
						break;
					}
				}
			}
		}
		let froms = scope Vector3[n * Candidates];
		let tos = scope Vector3[n * Candidates];
		let skip = size * 1e-4f;
		for (int i < n * Candidates)
		{
			let p = places[i / Candidates];
			let dir = (closest[i] - p);
			let length = dir.Length;
			// Starting a little way in, off the vertex's own faces.
			let start = length > skip * 2 ? p + dir / length * skip : p;
			froms[i] = start;
			tos[i] = candidate[i] >= 0 ? closest[i] : start;
		}
		let blocked = scope bool[n * Candidates];
		rays.Blocked(froms, tos, blocked);

		// Heat: from the nearest bone it can see (or the nearest at all), shared with any as near.
		let heat = scope float[n];
		let nearest = scope int32[n * 2];
		let shares = scope float[n * 2];
		let floor = size * 1e-3f;
		for (int p < n)
		{
			var first = -1;
			for (int k < Candidates)
			{
				let i = p * Candidates + k;
				if (candidate[i] >= 0 && !blocked[i])
				{
					first = k;
					break;
				}
			}
			if (first < 0)
				first = 0;
			let d0 = Math.Max(distance[p * Candidates + first], floor);
			heat[p] = 1 / (d0 * d0);
			nearest[p * 2] = candidate[p * Candidates + first];
			shares[p * 2] = 1;
			nearest[p * 2 + 1] = -1;
			shares[p * 2 + 1] = 0;
			// Another bone just as near (and seen): half each.
			for (int k = first + 1; k < Candidates; k++)
			{
				let i = p * Candidates + k;
				if (candidate[i] >= 0 && !blocked[i] && Math.Max(distance[i], floor) <= d0 * 1.0001f)
				{
					nearest[p * 2 + 1] = candidate[i];
					shares[p * 2] = 0.5f;
					shares[p * 2 + 1] = 0.5f;
					break;
				}
			}
		}
		let solved = scope float[n * deforming.Count];
		tn_rig_heat_weights((float*)places.Ptr, (int32)n, triangles.Ptr, (int32)(triangles.Count / 3), heat.Ptr, nearest.Ptr, shares.Ptr, 2, (int32)deforming.Count,
			(int32)iterations, solved.Ptr);

		rig.weights.Clear();
		rig.weights.Count = rig.positions.Count * boneCount;
		for (int v < rig.positions.Count)
		{
			let p = placeOf[v];
			for (int d < deforming.Count)
				rig.weights[v * boneCount + deforming[d]] = solved[p * deforming.Count + d];
			// A place no bone's heat reached (shut off from everything): its nearest bone.
			var sum = 0.0f;
			for (int d < deforming.Count)
				sum += solved[p * deforming.Count + d];
			if (sum <= 1e-6f)
				rig.weights[v * boneCount + deforming[nearest[p * 2] >= 0 ? nearest[p * 2] : 0]] = 1;
		}
		WeightTools.Limit(rig, MaxInfluences);
		return true;
	}
}
