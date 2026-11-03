using System;

namespace Tallow;

/// Rotation quaternion. Euler angles follow Unity: degrees, applied Z (roll), then X (pitch), then Y (yaw).
[CRepr]
struct Quaternion
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
		w = 1;
	}

	[Inline]
	public this(float x, float y, float z, float w)
	{
		this.x = x;
		this.y = y;
		this.z = z;
		this.w = w;
	}

	/// No rotation.
	public static Quaternion Identity { [Inline] get => .(0, 0, 0, 1); }

	/// A turn of some degrees about an axis.
	public static Quaternion AngleAxis(float degrees, Vector3 axis)
	{
		let half = degrees * Mathf.Deg2Rad * 0.5f;
		let s = Math.Sin(half);
		let n = axis.Normalized;
		return .(n.x * s, n.y * s, n.z * s, Math.Cos(half));
	}

	/// A rotation from angles in degrees about X, Y and Z.
	[Inline] public static Quaternion Euler(Vector3 degrees) => Euler(degrees.x, degrees.y, degrees.z);

	/// A rotation from angles in degrees: Z (roll) first, then X (pitch), then Y (yaw).
	public static Quaternion Euler(float xDeg, float yDeg, float zDeg)
	{
		let qx = AngleAxis(xDeg, .(1, 0, 0));
		let qy = AngleAxis(yDeg, .(0, 1, 0));
		let qz = AngleAxis(zDeg, .(0, 0, 1));
		return qy * qx * qz;
	}

	/// The rotation as angles in degrees about X, Y and Z (the inverse of Euler).
	public Vector3 EulerAngles
	{
		get
		{
			// Inverse of Euler(): rotation matrix R = Ry * Rx * Rz.
			let m = Matrix4.Rotation(this);
			let sinPitch = Mathf.Clamp(-m.m[9], -1.0f, 1.0f);
			float pitch = Math.Asin(sinPitch);
			float yaw;
			float roll;
			if (Mathf.Abs(sinPitch) < 0.9999f)
			{
				yaw = Math.Atan2(m.m[8], m.m[10]);
				roll = Math.Atan2(m.m[1], m.m[5]);
			}
			else
			{
				yaw = Math.Atan2(-m.m[2], m.m[0]);
				roll = 0;
			}
			return .(pitch * Mathf.Rad2Deg, yaw * Mathf.Rad2Deg, roll * Mathf.Rad2Deg);
		}
	}

	/// The same rotation, its length made exactly one (rotations combined many times drift).
	public Quaternion Normalized
	{
		get
		{
			let len = Math.Sqrt(x * x + y * y + z * z + w * w);
			if (len < 1.0e-12f)
				return Identity;
			let inv = 1.0f / len;
			return .(x * inv, y * inv, z * inv, w * inv);
		}
	}

	/// The opposite rotation (for a normalized quaternion).
	public Quaternion Conjugate { [Inline] get => .(-x, -y, -z, w); }

	/// Rotation b, then a.
	public static Quaternion operator *(Quaternion a, Quaternion b)
	{
		return .(
			a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
			a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
			a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
			a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z);
	}

	/// A vector turned by the rotation.
	public static Vector3 operator *(Quaternion q, Vector3 v)
	{
		let u = Vector3(q.x, q.y, q.z);
		let t = Vector3.Cross(u, v) * 2.0f;
		return v + t * q.w + Vector3.Cross(u, t);
	}

	/// How alike two rotations are: 1 or -1 when the same.
	[Inline] public static float Dot(Quaternion a, Quaternion b) => a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;

	/// The rotation a fraction t of the way from a to b, turning evenly, the short way round.
	public static Quaternion Slerp(Quaternion a, Quaternion bIn, float t)
	{
		var b = bIn;
		var cosTheta = Dot(a, b);
		if (cosTheta < 0)
		{
			b = .(-b.x, -b.y, -b.z, -b.w);
			cosTheta = -cosTheta;
		}
		if (cosTheta > 0.9995f)
		{
			return Quaternion(
				a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
				a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t).Normalized;
		}
		let theta = Math.Acos(cosTheta);
		let sinTheta = Math.Sin(theta);
		let wa = Math.Sin((1.0f - t) * theta) / sinTheta;
		let wb = Math.Sin(t * theta) / sinTheta;
		return .(a.x * wa + b.x * wb, a.y * wa + b.y * wb, a.z * wa + b.z * wb, a.w * wa + b.w * wb);
	}

	/// Rotation that looks along forward with the given up hint.
	public static Quaternion LookRotation(Vector3 forward, Vector3 up)
	{
		let f = forward.Normalized;
		if (f.LengthSquared < 1.0e-12f)
			return Identity;
		var r = Vector3.Cross(up, f);
		if (r.LengthSquared < 1.0e-8f)
			r = Vector3.Cross(.(1, 0, 0), f);
		r = r.Normalized;
		let u = Vector3.Cross(f, r);
		return FromBasis(r, u, f);
	}

	/// The rotation that turns the axes onto right, up and forward directions (at right angles to each other).
	public static Quaternion FromBasis(Vector3 r, Vector3 u, Vector3 f)
	{
		// Columns of the rotation matrix are r, u, f.
		let m00 = r.x;
		let m11 = u.y;
		let m22 = f.z;
		let trace = m00 + m11 + m22;
		Quaternion q;
		if (trace > 0)
		{
			let s = Math.Sqrt(trace + 1.0f) * 2.0f;
			q = .((u.z - f.y) / s, (f.x - r.z) / s, (r.y - u.x) / s, 0.25f * s);
		}
		else if (m00 > m11 && m00 > m22)
		{
			let s = Math.Sqrt(1.0f + m00 - m11 - m22) * 2.0f;
			q = .(0.25f * s, (u.x + r.y) / s, (f.x + r.z) / s, (u.z - f.y) / s);
		}
		else if (m11 > m22)
		{
			let s = Math.Sqrt(1.0f + m11 - m00 - m22) * 2.0f;
			q = .((u.x + r.y) / s, 0.25f * s, (f.y + u.z) / s, (f.x - r.z) / s);
		}
		else
		{
			let s = Math.Sqrt(1.0f + m22 - m00 - m11) * 2.0f;
			q = .((f.x + r.z) / s, (f.y + u.z) / s, 0.25f * s, (r.y - u.x) / s);
		}
		return q.Normalized;
	}
}
