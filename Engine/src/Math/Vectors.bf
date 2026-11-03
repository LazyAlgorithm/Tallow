using System;

namespace Tallow;

/// Two numbers: a point or direction on a plane, a screen position, a size.
[CRepr]
struct Vector2
{
	public float x;
	public float y;

	[Inline]
	public this()
	{
		x = 0;
		y = 0;
	}

	[Inline]
	public this(float x, float y)
	{
		this.x = x;
		this.y = y;
	}

	public static Vector2 Zero { [Inline] get => .(0, 0); }
	public static Vector2 One { [Inline] get => .(1, 1); }

	public float Length { [Inline] get => Math.Sqrt(x * x + y * y); }
	public float LengthSquared { [Inline] get => x * x + y * y; }
	/// The same direction one unit long (zero stays zero).
	public Vector2 Normalized
	{
		get
		{
			let length = Length;
			return length > 1.0e-6f ? Vector2(x / length, y / length) : Vector2(0, 0);
		}
	}

	/// The dot product: how much two directions point the same way, times their lengths.
	[Inline] public static float Dot(Vector2 a, Vector2 b) => a.x * b.x + a.y * b.y;
	[Inline] public static Vector2 Lerp(Vector2 a, Vector2 b, float t) => .(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
	[Inline] public static bool operator ==(Vector2 a, Vector2 b) => a.x == b.x && a.y == b.y;
	[Inline] public static bool operator !=(Vector2 a, Vector2 b) => a.x != b.x || a.y != b.y;

	[Inline] public static Vector2 operator +(Vector2 a, Vector2 b) => .(a.x + b.x, a.y + b.y);
	[Inline] public static Vector2 operator -(Vector2 a, Vector2 b) => .(a.x - b.x, a.y - b.y);
	[Inline] public static Vector2 operator *(Vector2 a, float s) => .(a.x * s, a.y * s);
	[Inline] public static Vector2 operator /(Vector2 a, float s) => .(a.x / s, a.y / s);
}

/// A point, direction or size in 3D. Tallow is left-handed: +X right, +Y up, +Z forward.
[CRepr]
struct Vector3
{
	public float x;
	public float y;
	public float z;

	[Inline]
	public this()
	{
		x = 0;
		y = 0;
		z = 0;
	}

	[Inline]
	public this(float x, float y, float z)
	{
		this.x = x;
		this.y = y;
		this.z = z;
	}

	/// The same number on all three axes.
	[Inline]
	public this(float v)
	{
		x = v;
		y = v;
		z = v;
	}

	public static Vector3 Zero { [Inline] get => .(0, 0, 0); }
	public static Vector3 One { [Inline] get => .(1, 1, 1); }
	public static Vector3 Up { [Inline] get => .(0, 1, 0); }
	public static Vector3 Down { [Inline] get => .(0, -1, 0); }
	public static Vector3 Right { [Inline] get => .(1, 0, 0); }
	public static Vector3 Left { [Inline] get => .(-1, 0, 0); }
	public static Vector3 Forward { [Inline] get => .(0, 0, 1); }
	public static Vector3 Back { [Inline] get => .(0, 0, -1); }

	public float LengthSquared { [Inline] get => x * x + y * y + z * z; }
	public float Length { [Inline] get => Math.Sqrt(x * x + y * y + z * z); }

	/// The same direction one unit long (zero stays zero).
	public Vector3 Normalized
	{
		get
		{
			let len = Length;
			if (len < 1.0e-12f)
				return .(0, 0, 0);
			let inv = 1.0f / len;
			return .(x * inv, y * inv, z * inv);
		}
	}

	/// The axis by number: 0 x, 1 y, 2 z.
	public float this[int index]
	{
		get => index == 0 ? x : (index == 1 ? y : z);
		set mut
		{
			if (index == 0)
				x = value;
			else if (index == 1)
				y = value;
			else
				z = value;
		}
	}

	[Inline] public static Vector3 operator +(Vector3 a, Vector3 b) => .(a.x + b.x, a.y + b.y, a.z + b.z);
	[Inline] public static Vector3 operator -(Vector3 a, Vector3 b) => .(a.x - b.x, a.y - b.y, a.z - b.z);
	[Inline] public static Vector3 operator -(Vector3 a) => .(-a.x, -a.y, -a.z);
	/// Multiplies axis by axis (to scale by different amounts on each).
	[Inline] public static Vector3 operator *(Vector3 a, Vector3 b) => .(a.x * b.x, a.y * b.y, a.z * b.z);
	/// Divides axis by axis.
	[Inline] public static Vector3 operator /(Vector3 a, Vector3 b) => .(a.x / b.x, a.y / b.y, a.z / b.z);
	[Inline] public static Vector3 operator *(Vector3 a, float s) => .(a.x * s, a.y * s, a.z * s);
	[Inline] public static Vector3 operator *(float s, Vector3 a) => .(a.x * s, a.y * s, a.z * s);
	[Inline] public static Vector3 operator /(Vector3 a, float s) => .(a.x / s, a.y / s, a.z / s);
	[Inline] public static bool operator ==(Vector3 a, Vector3 b) => a.x == b.x && a.y == b.y && a.z == b.z;
	[Inline] public static bool operator !=(Vector3 a, Vector3 b) => a.x != b.x || a.y != b.y || a.z != b.z;

	/// The dot product: how much two directions point the same way, times their lengths.
	[Inline] public static float Dot(Vector3 a, Vector3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

	/// The cross product: a direction at right angles to both, as long as the area they span.
	[Inline] public static Vector3 Cross(Vector3 a, Vector3 b) =>
		.(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);

	/// How far apart two points are.
	[Inline] public static float Distance(Vector3 a, Vector3 b) => (a - b).Length;
	/// The point a fraction t of the way from a to b (t is not clamped).
	[Inline] public static Vector3 Lerp(Vector3 a, Vector3 b, float t) => a + (b - a) * t;
	/// The smaller of the two on each axis.
	[Inline] public static Vector3 Min(Vector3 a, Vector3 b) => .(Mathf.Min(a.x, b.x), Mathf.Min(a.y, b.y), Mathf.Min(a.z, b.z));
	/// The larger of the two on each axis.
	[Inline] public static Vector3 Max(Vector3 a, Vector3 b) => .(Mathf.Max(a.x, b.x), Mathf.Max(a.y, b.y), Mathf.Max(a.z, b.z));
	/// Each axis made positive.
	[Inline] public static Vector3 Abs(Vector3 a) => .(Mathf.Abs(a.x), Mathf.Abs(a.y), Mathf.Abs(a.z));

	/// Moves from current towards target by at most maxDelta, stopping there.
	public static Vector3 MoveTowards(Vector3 current, Vector3 target, float maxDelta)
	{
		let delta = target - current;
		let dist = delta.Length;
		if (dist <= maxDelta || dist < 1.0e-9f)
			return target;
		return current + delta * (maxDelta / dist);
	}

	public override void ToString(String str)
	{
		str.AppendF("({0:0.###}, {1:0.###}, {2:0.###})", x, y, z);
	}
}

/// Four numbers: a shader value, a plane, or a point with a w.
[CRepr]
struct Vector4
{
	public float x;
	public float y;
	public float z;
	public float w;

	[Inline]
	public this()
	{
		x = 0;
		y = 0;
		z = 0;
		w = 0;
	}

	[Inline]
	public this(float x, float y, float z, float w)
	{
		this.x = x;
		this.y = y;
		this.z = z;
		this.w = w;
	}

	/// A Vector3 with a w.
	[Inline]
	public this(Vector3 v, float w)
	{
		x = v.x;
		y = v.y;
		z = v.z;
		this.w = w;
	}

	[Inline] public static bool operator ==(Vector4 a, Vector4 b) => a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w;
	[Inline] public static bool operator !=(Vector4 a, Vector4 b) => a.x != b.x || a.y != b.y || a.z != b.z || a.w != b.w;

	/// The first three numbers.
	public Vector3 XYZ { [Inline] get => .(x, y, z); }
}

/// Integer lattice coordinate, used for voxel chunks and cells.
struct Int3 : IHashable
{
	public int32 x;
	public int32 y;
	public int32 z;

	[Inline]
	public this(int32 x, int32 y, int32 z)
	{
		this.x = x;
		this.y = y;
		this.z = z;
	}

	[Inline] public static Int3 operator +(Int3 a, Int3 b) => .(a.x + b.x, a.y + b.y, a.z + b.z);
	[Inline] public static Int3 operator -(Int3 a, Int3 b) => .(a.x - b.x, a.y - b.y, a.z - b.z);
	[Inline] public static bool operator ==(Int3 a, Int3 b) => a.x == b.x && a.y == b.y && a.z == b.z;
	[Inline] public static bool operator !=(Int3 a, Int3 b) => a.x != b.x || a.y != b.y || a.z != b.z;

	public int GetHashCode()
	{
		return (int)(((uint32)x * 73856093) ^ ((uint32)y * 19349663) ^ ((uint32)z * 83492791));
	}
}
