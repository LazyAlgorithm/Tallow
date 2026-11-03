using System;

namespace Tallow;

/// A box lined up with the axes, from min to max.
struct Bounds
{
	public Vector3 min;
	public Vector3 max;

	[Inline]
	public this(Vector3 min, Vector3 max)
	{
		this.min = min;
		this.max = max;
	}

	/// A box that holds nothing, ready to Encapsulate points into.
	public static Bounds Empty { [Inline] get => .(.(float.MaxValue), .(-float.MaxValue)); }

	/// The middle of the box.
	public Vector3 Center { [Inline] get => (min + max) * 0.5f; }
	/// Half the box's size on each axis.
	public Vector3 Extents { [Inline] get => (max - min) * 0.5f; }
	/// The box's size on each axis.
	public Vector3 Size { [Inline] get => max - min; }
	/// Whether the box holds anything (an Empty one does not).
	public bool IsValid { [Inline] get => max.x >= min.x && max.y >= min.y && max.z >= min.z; }

	/// Grows the box to take in a point.
	public void Encapsulate(Vector3 p) mut
	{
		min = Vector3.Min(min, p);
		max = Vector3.Max(max, p);
	}

	/// Grows the box to take in another (an Empty one adds nothing). (Not an Encapsulate overload, which would make
	/// `Encapsulate(.(x, y, z))` ambiguous in existing code.)
	public void EncapsulateBounds(Bounds other) mut
	{
		if (!other.IsValid)
			return;
		min = Vector3.Min(min, other.min);
		max = Vector3.Max(max, other.max);
	}

	/// Axis-aligned bounds of this box after an affine transform.
	public Bounds Transformed(Matrix4 mtx)
	{
		let c = mtx.TransformPoint(Center);
		let e = Extents;
		let ex = Mathf.Abs(mtx.m[0]) * e.x + Mathf.Abs(mtx.m[4]) * e.y + Mathf.Abs(mtx.m[8]) * e.z;
		let ey = Mathf.Abs(mtx.m[1]) * e.x + Mathf.Abs(mtx.m[5]) * e.y + Mathf.Abs(mtx.m[9]) * e.z;
		let ez = Mathf.Abs(mtx.m[2]) * e.x + Mathf.Abs(mtx.m[6]) * e.y + Mathf.Abs(mtx.m[10]) * e.z;
		return .(c - Vector3(ex, ey, ez), c + Vector3(ex, ey, ez));
	}

	/// Ray/box slab test. Returns the entry distance, or a negative value on a miss.
	public float IntersectRay(Ray ray)
	{
		float tMin = 0.0f;
		float tMax = float.MaxValue;
		for (int axis < 3)
		{
			let o = ray.origin[axis];
			let d = ray.direction[axis];
			let lo = min[axis];
			let hi = max[axis];
			if (Mathf.Abs(d) < 1.0e-9f)
			{
				if (o < lo || o > hi)
					return -1.0f;
			}
			else
			{
				var t1 = (lo - o) / d;
				var t2 = (hi - o) / d;
				if (t1 > t2)
					Swap!(t1, t2);
				tMin = Mathf.Max(tMin, t1);
				tMax = Mathf.Min(tMax, t2);
				if (tMin > tMax)
					return -1.0f;
			}
		}
		return tMin;
	}
}

/// A line from a point, going one way.
struct Ray
{
	public Vector3 origin;
	public Vector3 direction;

	[Inline]
	public this(Vector3 origin, Vector3 direction)
	{
		this.origin = origin;
		this.direction = direction;
	}

	/// The point some distance along the ray.
	[Inline] public Vector3 GetPoint(float distance) => origin + direction * distance;
}

/// Six inward-facing planes extracted from a view-projection matrix.
struct Frustum
{
	/// The six planes round the view (left, right, bottom, top, near, far), facing in.
	public Vector4[6] planes;

	/// The view of a view-projection matrix.
	[Inline]
	public this(Matrix4 viewProj, bool homogeneousDepth)
	{
		planes = default;
		let m = viewProj.m;
		// Row i of the matrix is (m[i], m[4 + i], m[8 + i], m[12 + i]).
		Vector4 row0 = .(m[0], m[4], m[8], m[12]);
		Vector4 row1 = .(m[1], m[5], m[9], m[13]);
		Vector4 row2 = .(m[2], m[6], m[10], m[14]);
		Vector4 row3 = .(m[3], m[7], m[11], m[15]);
		planes[0] = Add(row3, row0);
		planes[1] = Sub(row3, row0);
		planes[2] = Add(row3, row1);
		planes[3] = Sub(row3, row1);
		planes[4] = homogeneousDepth ? Add(row3, row2) : row2;
		planes[5] = Sub(row3, row2);
		for (int i < 6)
		{
			let p = planes[i];
			let len = Math.Sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
			if (len > 1.0e-12f)
				planes[i] = .(p.x / len, p.y / len, p.z / len, p.w / len);
		}
	}

	static Vector4 Add(Vector4 a, Vector4 b) => .(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w);
	static Vector4 Sub(Vector4 a, Vector4 b) => .(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w);

	/// Whether any of a box might be in view (a box near a corner can be counted in when it is not).
	public bool Intersects(Bounds b)
	{
		let c = b.Center;
		let e = b.Extents;
		for (int i < 6)
		{
			let p = planes[i];
			let r = e.x * Mathf.Abs(p.x) + e.y * Mathf.Abs(p.y) + e.z * Mathf.Abs(p.z);
			if (p.x * c.x + p.y * c.y + p.z * c.z + p.w < -r)
				return false;
		}
		return true;
	}

	/// Whether any of a sphere might be in view.
	public bool IntersectsSphere(Vector3 center, float radius)
	{
		for (int i < 6)
		{
			let p = planes[i];
			if (p.x * center.x + p.y * center.y + p.z * center.z + p.w < -radius)
				return false;
		}
		return true;
	}
}
