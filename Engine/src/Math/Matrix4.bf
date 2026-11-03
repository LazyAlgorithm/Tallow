using System;

namespace Tallow;

/// 4x4 matrix, column-major storage with column vectors (clip = Projection * View * Model * v).
/// Element (row, column) lives at m[column * 4 + row]; translation is m[12..14].
/// The engine is left-handed with +Y up and +Z forward.
[CRepr]
struct Matrix4
{
	/// The sixteen numbers, column by column: element (row, column) is m[column * 4 + row].
	public float[16] m;

	/// The matrix that changes nothing.
	public static Matrix4 Identity
	{
		get
		{
			Matrix4 r = default;
			r.m[0] = 1;
			r.m[5] = 1;
			r.m[10] = 1;
			r.m[15] = 1;
			return r;
		}
	}

	/// The move the matrix makes.
	public Vector3 Translation { [Inline] get => .(m[12], m[13], m[14]); }
	/// Where the matrix puts +X (its first column).
	public Vector3 Right { [Inline] get => .(m[0], m[1], m[2]); }
	/// Where the matrix puts +Y.
	public Vector3 Up { [Inline] get => .(m[4], m[5], m[6]); }
	/// Where the matrix puts +Z.
	public Vector3 Forward { [Inline] get => .(m[8], m[9], m[10]); }

	/// b, then a.
	public static Matrix4 operator *(Matrix4 a, Matrix4 b)
	{
		Matrix4 r = default;
		for (int c < 4)
		{
			for (int row < 4)
			{
				r.m[c * 4 + row] =
					a.m[0 * 4 + row] * b.m[c * 4 + 0] +
					a.m[1 * 4 + row] * b.m[c * 4 + 1] +
					a.m[2 * 4 + row] * b.m[c * 4 + 2] +
					a.m[3 * 4 + row] * b.m[c * 4 + 3];
			}
		}
		return r;
	}

	/// A move.
	public static Matrix4 Translate(Vector3 t)
	{
		var r = Identity;
		r.m[12] = t.x;
		r.m[13] = t.y;
		r.m[14] = t.z;
		return r;
	}

	/// A scaling on each axis.
	public static Matrix4 Scale(Vector3 s)
	{
		Matrix4 r = default;
		r.m[0] = s.x;
		r.m[5] = s.y;
		r.m[10] = s.z;
		r.m[15] = 1;
		return r;
	}

	/// A rotation.
	public static Matrix4 Rotation(Quaternion q)
	{
		let xx = q.x * q.x;
		let yy = q.y * q.y;
		let zz = q.z * q.z;
		let xy = q.x * q.y;
		let xz = q.x * q.z;
		let yz = q.y * q.z;
		let wx = q.w * q.x;
		let wy = q.w * q.y;
		let wz = q.w * q.z;
		Matrix4 r = default;
		r.m[0] = 1 - 2 * (yy + zz);
		r.m[1] = 2 * (xy + wz);
		r.m[2] = 2 * (xz - wy);
		r.m[4] = 2 * (xy - wz);
		r.m[5] = 1 - 2 * (xx + zz);
		r.m[6] = 2 * (yz + wx);
		r.m[8] = 2 * (xz + wy);
		r.m[9] = 2 * (yz - wx);
		r.m[10] = 1 - 2 * (xx + yy);
		r.m[15] = 1;
		return r;
	}

	/// Scale, then rotate, then move: an object's local matrix.
	public static Matrix4 TRS(Vector3 t, Quaternion q, Vector3 s)
	{
		var r = Rotation(q);
		r.m[0] *= s.x;
		r.m[1] *= s.x;
		r.m[2] *= s.x;
		r.m[4] *= s.y;
		r.m[5] *= s.y;
		r.m[6] *= s.y;
		r.m[8] *= s.z;
		r.m[9] *= s.z;
		r.m[10] *= s.z;
		r.m[12] = t.x;
		r.m[13] = t.y;
		r.m[14] = t.z;
		return r;
	}

	/// Splits an affine matrix without shear into translation, rotation and scale.
	public void Decompose(out Vector3 t, out Quaternion q, out Vector3 s)
	{
		t = .(m[12], m[13], m[14]);
		var r = Vector3(m[0], m[1], m[2]);
		var u = Vector3(m[4], m[5], m[6]);
		var f = Vector3(m[8], m[9], m[10]);
		s = .(r.Length, u.Length, f.Length);
		if (Vector3.Dot(Vector3.Cross(r, u), f) < 0)
		{
			s.x = -s.x;
		}
		r = s.x != 0 ? r / s.x : .(1, 0, 0);
		u = s.y != 0 ? u / s.y : .(0, 1, 0);
		f = s.z != 0 ? f / s.z : .(0, 0, 1);
		q = Quaternion.FromBasis(r, u, f);
	}

	/// A point moved by the matrix.
	[Inline]
	public Vector3 TransformPoint(Vector3 p)
	{
		return .(
			m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
			m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
			m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]);
	}

	/// A direction turned and scaled by the matrix (without its move).
	[Inline]
	public Vector3 TransformDirection(Vector3 d)
	{
		return .(
			m[0] * d.x + m[4] * d.y + m[8] * d.z,
			m[1] * d.x + m[5] * d.y + m[9] * d.z,
			m[2] * d.x + m[6] * d.y + m[10] * d.z);
	}

	/// A Vector4 times the matrix.
	public Vector4 Transform(Vector4 v)
	{
		return .(
			m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12] * v.w,
			m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13] * v.w,
			m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14] * v.w,
			m[3] * v.x + m[7] * v.y + m[11] * v.z + m[15] * v.w);
	}

	/// Projects a point and performs the perspective divide.
	public Vector3 Project(Vector3 p)
	{
		let v = Transform(.(p, 1.0f));
		let inv = Mathf.Abs(v.w) > 1.0e-12f ? 1.0f / v.w : 1.0f;
		return .(v.x * inv, v.y * inv, v.z * inv);
	}

	/// Rows and columns swapped.
	public Matrix4 Transposed
	{
		get
		{
			Matrix4 r = default;
			for (int c < 4)
			{
				for (int row < 4)
					r.m[c * 4 + row] = m[row * 4 + c];
			}
			return r;
		}
	}

	/// The matrix that undoes this one.
	public Matrix4 Inverse
	{
		get
		{
			Matrix4 inv = default;
			inv.m[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
			inv.m[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
			inv.m[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
			inv.m[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
			inv.m[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
			inv.m[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
			inv.m[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
			inv.m[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
			inv.m[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
			inv.m[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
			inv.m[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
			inv.m[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
			inv.m[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
			inv.m[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
			inv.m[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
			inv.m[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

			let det = m[0] * inv.m[0] + m[1] * inv.m[4] + m[2] * inv.m[8] + m[3] * inv.m[12];
			if (Mathf.Abs(det) < 1.0e-20f)
				return Identity;
			let invDet = 1.0f / det;
			for (int i < 16)
				inv.m[i] *= invDet;
			return inv;
		}
	}

	/// Left-handed perspective projection. homogeneousDepth selects -1..1 clip depth (OpenGL) over 0..1.
	public static Matrix4 Perspective(float fovYDegrees, float aspect, float near, float far, bool homogeneousDepth)
	{
		let f = 1.0f / Math.Tan(fovYDegrees * Mathf.Deg2Rad * 0.5f);
		Matrix4 r = default;
		r.m[0] = f / aspect;
		r.m[5] = f;
		r.m[11] = 1.0f;
		if (homogeneousDepth)
		{
			r.m[10] = (far + near) / (far - near);
			r.m[14] = -2.0f * near * far / (far - near);
		}
		else
		{
			r.m[10] = far / (far - near);
			r.m[14] = -near * far / (far - near);
		}
		return r;
	}

	/// A projection without perspective, of a box from left to right, bottom to top and near to far. homogeneousDepth:
	/// depth from -1 to 1 (OpenGL) instead of 0 to 1.
	public static Matrix4 Ortho(float left, float right, float bottom, float top, float near, float far, bool homogeneousDepth)
	{
		Matrix4 r = default;
		r.m[0] = 2.0f / (right - left);
		r.m[5] = 2.0f / (top - bottom);
		r.m[12] = -(right + left) / (right - left);
		r.m[13] = -(top + bottom) / (top - bottom);
		if (homogeneousDepth)
		{
			r.m[10] = 2.0f / (far - near);
			r.m[14] = -(far + near) / (far - near);
		}
		else
		{
			r.m[10] = 1.0f / (far - near);
			r.m[14] = -near / (far - near);
		}
		r.m[15] = 1.0f;
		return r;
	}

	/// A view from eye towards target, with up as near up as it can be.
	public static Matrix4 LookAt(Vector3 eye, Vector3 target, Vector3 up)
	{
		let z = (target - eye).Normalized;
		var x = Vector3.Cross(up, z);
		if (x.LengthSquared < 1.0e-8f)
			x = Vector3.Cross(.(1, 0, 0), z);
		x = x.Normalized;
		let y = Vector3.Cross(z, x);
		Matrix4 r = default;
		r.m[0] = x.x;
		r.m[4] = x.y;
		r.m[8] = x.z;
		r.m[12] = -Vector3.Dot(x, eye);
		r.m[1] = y.x;
		r.m[5] = y.y;
		r.m[9] = y.z;
		r.m[13] = -Vector3.Dot(y, eye);
		r.m[2] = z.x;
		r.m[6] = z.y;
		r.m[10] = z.z;
		r.m[14] = -Vector3.Dot(z, eye);
		r.m[15] = 1.0f;
		return r;
	}
}
