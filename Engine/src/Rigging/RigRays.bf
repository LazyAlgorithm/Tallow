using System;
using System.Collections;

namespace Tallow;

/// Rays against a rig's model (the light baker's native ray tracer): what a ray hits first, and where a line goes in
/// and out of the model, for putting markers and joints in the middle of a limb.
class RigRays
{
	void* mBvh;

	[CLink] static extern void* tn_bake_create(float* positions, int32 vertexCount, uint32* indices, int32 triangleCount);
	[CLink] static extern void tn_bake_destroy(void* bvh);
	[CLink] static extern void tn_bake_intersect(void* bvh, float* rays, int32 count, int32* triangles, float* hits);
	[CLink] static extern void tn_bake_occluded(void* bvh, float* rays, int32 count, uint8* blocked);

	public this(Span<Vector3> positions, Span<uint32> indices)
	{
		if (positions.Length > 0 && indices.Length >= 3)
			mBvh = tn_bake_create((float*)positions.Ptr, (int32)positions.Length, indices.Ptr, (int32)(indices.Length / 3));
	}

	public ~this()
	{
		if (mBvh != null)
			tn_bake_destroy(mBvh);
	}

	/// How far along a ray (direction of length 1) it first hits the model, or -1.
	public float Hit(Vector3 origin, Vector3 direction, float distance = 1e6f)
	{
		if (mBvh == null)
			return -1;
		float[7] ray = .(origin.x, origin.y, origin.z, direction.x, direction.y, direction.z, distance);
		int32 triangle = -1;
		float[4] hit = default;
		tn_bake_intersect(mBvh, &ray, 1, &triangle, &hit);
		return triangle >= 0 ? hit[0] : -1;
	}

	/// Whether anything is between two points, for many pairs at once.
	public void Blocked(Span<Vector3> from, Span<Vector3> to, Span<bool> blocked)
	{
		if (mBvh == null)
		{
			for (int i < from.Length)
				blocked[i] = false;
			return;
		}
		let rays = scope float[from.Length * 7];
		for (int i < from.Length)
		{
			let d = to[i] - from[i];
			let length = d.Length;
			let dir = length > 1e-9f ? d / length : Vector3(0, 1, 0);
			rays[i * 7] = from[i].x;
			rays[i * 7 + 1] = from[i].y;
			rays[i * 7 + 2] = from[i].z;
			rays[i * 7 + 3] = dir.x;
			rays[i * 7 + 4] = dir.y;
			rays[i * 7 + 5] = dir.z;
			rays[i * 7 + 6] = length;
		}
		let result = scope uint8[from.Length];
		tn_bake_occluded(mBvh, rays.Ptr, (int32)from.Length, result.Ptr);
		for (int i < from.Length)
			blocked[i] = result[i] != 0;
	}

	/// The point halfway through the model along a line through `point`: where the line goes in and out of the
	/// part of the model the point is in (or nearest to). The point itself when the line misses the model.
	public Vector3 Centre(Vector3 point, Vector3 direction, float reach)
	{
		let dir = direction.Normalized;
		let start = point - dir * reach;
		// Every crossing along the line, in order.
		let crossings = scope List<float>();
		var t = 0.0f;
		for (int i < 32)
		{
			let hit = Hit(start + dir * t, dir, reach * 2 - t);
			if (hit < 0)
				break;
			t += hit;
			crossings.Add(t);
			t += reach * 1e-5f;
		}
		if (crossings.Count < 2)
			return point;
		// The stretch inside that holds the point, or the nearest one.
		var best = -1;
		var bestGap = float.MaxValue;
		for (int i = 0; i + 1 < crossings.Count; i += 2)
		{
			let a = crossings[i], b = crossings[i + 1];
			let gap = (reach >= a && reach <= b) ? 0 : Math.Min(Math.Abs(reach - a), Math.Abs(reach - b));
			if (gap < bestGap)
			{
				bestGap = gap;
				best = i;
			}
		}
		let middle = (crossings[best] + crossings[best + 1]) * 0.5f;
		return start + dir * middle;
	}
}
