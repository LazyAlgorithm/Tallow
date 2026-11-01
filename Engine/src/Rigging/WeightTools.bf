using System;
using System.Collections;

namespace Tallow;

/// Changing a rig's weights (docs/rigging.md): the weight brush (add, subtract, smooth, set), smoothing everything,
/// keeping each vertex to a few bones, and mirroring from one side of the model to the other.
static class WeightTools
{
	/// Scales a vertex's weights to add up to 1 (all to `fallback` when they are all 0).
	public static void Normalize(Rig rig, int vertex, int fallback = -1)
	{
		let count = rig.bones.Count;
		let row = rig.weights.Ptr + vertex * count;
		var sum = 0.0f;
		for (int b < count)
		{
			row[b] = Math.Max(row[b], 0);
			sum += row[b];
		}
		if (sum > 1e-6f)
		{
			for (int b < count)
				row[b] /= sum;
		}
		else if (fallback >= 0)
			row[fallback] = 1;
	}

	/// Keeps each vertex's strongest `most` bones (dropping weights under 1%), adding up to 1, as a rigged file holds
	/// them.
	public static void Limit(Rig rig, int most)
	{
		let count = rig.bones.Count;
		let order = scope List<int>();
		for (int v < rig.positions.Count)
		{
			let row = rig.weights.Ptr + v * count;
			order.Clear();
			var strongest = 0;
			for (int b < count)
			{
				if (row[b] > row[strongest])
					strongest = b;
				if (row[b] > 0)
					order.Add(b);
			}
			order.Sort(scope (a, b) => row[b] <=> row[a]);
			var sum = 0.0f;
			for (int i < order.Count)
			{
				if (i >= most || row[order[i]] < 0.01f)
					row[order[i]] = 0;
				sum += row[order[i]];
			}
			if (sum <= 0)
				row[strongest] = 1;
			Normalize(rig, v, strongest);
		}
	}

	/// What the brush does.
	public enum Brush
	{
		/// More of the bone.
		Add,
		/// Less of the bone (it goes to the others).
		Subtract,
		/// Each vertex's weights towards its neighbours' (all bones).
		Smooth,
		/// The bone's weight towards the brush's Value.
		Set
	}
}

/// What the weight brush needs to know about a rig's model, made once: which vertices are next to which, and which
/// vertex and bone are the mirror of each.
class WeightPainter
{
	public Rig rig;
	/// Each place's neighbours (places: vertices in the same spot are one).
	public List<int32> placeOf = new .() ~ delete _;
	public List<Vector3> places = new .() ~ delete _;
	public List<List<int32>> neighbours = new .() ~ DeleteContainerAndItems!(_);
	/// The vertices at each place.
	public List<List<int32>> verticesAt = new .() ~ DeleteContainerAndItems!(_);
	/// Each place's mirror (across the middle of the model, left to right), or -1.
	public List<int32> mirrorPlace = new .() ~ delete _;
	/// Each bone's mirror (LeftArm's RightArm), or itself.
	public List<int32> mirrorBone = new .() ~ delete _;
	/// The middle of the model across: the plane mirrored about.
	public float middle;
	public Vector3 right;

	public this(Rig rig)
	{
		this.rig = rig;
		Refresh();
	}

	/// Works it all out again (after the model, bones or facing changed).
	public void Refresh()
	{
		AutoWeights.Weld(rig, placeOf, places);
		ClearAndDeleteItems!(neighbours);
		ClearAndDeleteItems!(verticesAt);
		for (int p < places.Count)
		{
			neighbours.Add(new .());
			verticesAt.Add(new .());
		}
		for (int v < placeOf.Count)
			verticesAt[placeOf[v]].Add((int32)v);
		void Join(int32 a, int32 b)
		{
			if (a == b)
				return;
			if (!neighbours[a].Contains(b))
				neighbours[a].Add(b);
			if (!neighbours[b].Contains(a))
				neighbours[b].Add(a);
		}
		for (let part in rig.parts)
		{
			for (int i = 0; i + 2 < part.indices.Count; i += 3)
			{
				let a = placeOf[part.indices[i]], b = placeOf[part.indices[i + 1]], c = placeOf[part.indices[i + 2]];
				Join(a, b);
				Join(b, c);
				Join(c, a);
			}
		}
		RefreshMirror();
	}

	/// The mirror of each place and bone. The middle is the root bone's joint (or the model's middle).
	public void RefreshMirror()
	{
		right = rig.Right;
		middle = Vector3.Dot(rig.bones.IsEmpty ? rig.bounds.Center : rig.bones[0].head, right);
		mirrorPlace.Clear();
		// Places by where they are, in cells, to find each one's mirror quickly.
		let cell = Math.Max(rig.bounds.Size.Length, 1e-4f) / 64;
		let grid = scope Dictionary<int64, List<int32>>();
		defer
		{
			for (let list in grid.Values)
				delete list;
		}
		// A cell's three numbers packed into one (the model is under 2^20 cells across).
		int64 Pack(int64 x, int64 y, int64 z) => ((x & 0xFFFFF) << 40) | ((y & 0xFFFFF) << 20) | (z & 0xFFFFF);
		(int64, int64, int64) Cell(Vector3 p) => ((int64)Math.Floor(p.x / cell), (int64)Math.Floor(p.y / cell), (int64)Math.Floor(p.z / cell));
		for (int32 p < (int32)places.Count)
		{
			let c = Cell(places[p]);
			let key = Pack(c.0, c.1, c.2);
			if (!grid.TryGetValue(key, var list))
			{
				list = new .();
				grid[key] = list;
			}
			list.Add(p);
		}
		let tolerance = cell * 0.5f;
		for (int p < places.Count)
		{
			let point = places[p];
			let lateral = Vector3.Dot(point, right) - middle;
			let mirrored = point - right * (2 * lateral);
			let key = Cell(mirrored);
			var best = -1;
			var bestDistance = tolerance;
			for (int64 dx = -1; dx <= 1; dx++)
			{
				for (int64 dy = -1; dy <= 1; dy++)
				{
					for (int64 dz = -1; dz <= 1; dz++)
					{
						if (!grid.TryGetValue(Pack(key.0 + dx, key.1 + dy, key.2 + dz), let list))
							continue;
						for (let other in list)
						{
							let d = (places[other] - mirrored).Length;
							if (d < bestDistance)
							{
								bestDistance = d;
								best = other;
							}
						}
					}
				}
			}
			mirrorPlace.Add((int32)best);
		}
		mirrorBone.Clear();
		for (int b < rig.bones.Count)
		{
			let other = rig.MirrorBone(b);
			mirrorBone.Add((int32)(other >= 0 ? other : b));
		}
	}

	/// How many places have a mirror (a share: 1 when the model is the same on both sides).
	public float Symmetry
	{
		get
		{
			var found = 0;
			for (let m in mirrorPlace)
			{
				if (m >= 0)
					found++;
			}
			return places.IsEmpty ? 0 : (float)found / places.Count;
		}
	}

	/// One dab of the brush, centred on a point, on the places within `radius` of it (where they are drawn:
	/// `shown`, one position a vertex, as posed). `amount` is how far each goes (0 to 1) at the middle of the brush.
	/// With `mirror`, the same is done to the mirrored places with the mirrored bone. Returns how many vertices changed.
	public int Dab(WeightTools.Brush brush, int bone, Vector3 centre, float radius, float amount, float value, bool mirror, Span<Vector3> shown)
	{
		let changed = scope HashSet<int32>();
		let mirrored = scope List<(int32 place, float falloff)>();
		for (int32 p < (int32)places.Count)
		{
			let at = shown.Length == placeOf.Count ? shown[verticesAt[p][0]] : places[p];
			let d = (at - centre).Length;
			if (d > radius)
				continue;
			// Smooth falloff: full in the middle, nothing at the edge.
			let t = d / radius;
			let falloff = 1 - t * t * (3 - 2 * t);
			Apply(brush, bone, p, falloff * amount, value);
			changed.Add(p);
			if (mirror && mirrorPlace[p] >= 0 && mirrorPlace[p] != p)
			{
				let strength = amount * falloff;
				mirrored.Add((mirrorPlace[p], strength));
			}
		}
		for (let entry in mirrored)
		{
			if (changed.Contains(entry.place))
				continue;
			Apply(brush, mirrorBone[bone], entry.place, entry.falloff, value);
			changed.Add(entry.place);
		}
		var vertices = 0;
		for (let p in changed)
			vertices += verticesAt[p].Count;
		return vertices;
	}

	/// The brush at one place (all its vertices), by `strength` (0 to 1).
	void Apply(WeightTools.Brush brush, int bone, int32 place, float strength, float value)
	{
		let count = rig.bones.Count;
		let first = verticesAt[place][0];
		let row = rig.weights.Ptr + first * count;
		switch (brush)
		{
		case .Add,.Subtract,.Set:
			let old = row[bone];
			let target = brush == .Add ? 1 : (brush == .Subtract ? 0 : Math.Clamp(value, 0, 1));
			let now = old + (target - old) * Math.Clamp(strength, 0, 1);
			SetWeight(row, count, bone, now);
		case .Smooth:
			let around = neighbours[place];
			if (around.IsEmpty)
				return;
			let average = scope float[count];
			for (let other in around)
			{
				let otherRow = rig.weights.Ptr + verticesAt[other][0] * count;
				for (int b < count)
					average[b] += otherRow[b];
			}
			var sum = 0.0f;
			for (int b < count)
			{
				row[b] += (average[b] / around.Count - row[b]) * Math.Clamp(strength, 0, 1);
				sum += row[b];
			}
			if (sum > 0)
			{
				for (int b < count)
					row[b] /= sum;
			}
		}
		// The other vertices in the same place take the same weights.
		for (int i = 1; i < verticesAt[place].Count; i++)
			Internal.MemCpy(rig.weights.Ptr + verticesAt[place][i] * count, row, count * sizeof(float));
	}

	/// Sets one bone's weight in a vertex's row, scaling the others so that they all still add up to 1. Weight taken
	/// from a vertex that only had this bone goes to the bone's parent.
	void SetWeight(float* row, int count, int bone, float weight)
	{
		let w = Math.Clamp(weight, 0, 1);
		var others = 0.0f;
		for (int b < count)
		{
			if (b != bone)
				others += row[b];
		}
		row[bone] = w;
		if (others > 1e-6f)
		{
			let scale = (1 - w) / others;
			for (int b < count)
			{
				if (b != bone)
					row[b] *= scale;
			}
		}
		else if (w < 1)
		{
			var parent = rig.bones[bone].parent;
			while (parent >= 0 && !rig.bones[parent].deform)
				parent = rig.bones[parent].parent;
			if (parent >= 0)
				row[parent] = 1 - w;
			else
				row[bone] = 1;
		}
	}

	/// Smooths every vertex's weights with its neighbours', `passes` times.
	public void SmoothAll(int passes, float strength)
	{
		for (int pass < passes)
		{
			for (int32 p < (int32)places.Count)
				Apply(.Smooth, 0, p, strength, 0);
		}
	}

	/// Copies the weights of one side of the model to the other, mirrored (bones swapped). `fromRight`: the right
	/// side's weights are kept and the left made from them. Returns how many places were changed.
	public int MirrorWeights(bool fromRight)
	{
		let count = rig.bones.Count;
		var done = 0;
		for (int32 p < (int32)places.Count)
		{
			let m = mirrorPlace[p];
			if (m < 0 || m == p)
				continue;
			let lateral = Vector3.Dot(places[p], right) - middle;
			// Only the side being made.
			if ((fromRight && lateral >= 0) || (!fromRight && lateral <= 0))
				continue;
			let source = rig.weights.Ptr + verticesAt[m][0] * count;
			for (let v in verticesAt[p])
			{
				let row = rig.weights.Ptr + v * count;
				for (int b < count)
					row[b] = 0;
				for (int b < count)
					row[mirrorBone[b]] += source[b];
			}
			done++;
		}
		return done;
	}

	/// The place nearest a point (as drawn), or -1.
	public int32 Nearest(Vector3 point, Span<Vector3> shown)
	{
		var best = (int32) - 1;
		var bestDistance = float.MaxValue;
		for (int32 p < (int32)places.Count)
		{
			let at = shown.Length == placeOf.Count ? shown[verticesAt[p][0]] : places[p];
			let d = (at - point).LengthSquared;
			if (d < bestDistance)
			{
				bestDistance = d;
				best = p;
			}
		}
		return best;
	}
}
