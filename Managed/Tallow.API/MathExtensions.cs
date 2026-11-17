using System.Numerics;

namespace Tallow;

/// <summary>Tallow's vector and rotation shorthands on the System.Numerics types: +Z is forward, +Y up, +X right,
/// and angles are in degrees.</summary>
public static class TallowMathExtensions
{
    extension(Vector3)
    {
        /// <summary>(0, 1, 0).</summary>
        public static Vector3 Up => Vector3.UnitY;
        /// <summary>(0, -1, 0).</summary>
        public static Vector3 Down => -Vector3.UnitY;
        /// <summary>(1, 0, 0).</summary>
        public static Vector3 Right => Vector3.UnitX;
        /// <summary>(-1, 0, 0).</summary>
        public static Vector3 Left => -Vector3.UnitX;
        /// <summary>(0, 0, 1): Tallow's forward.</summary>
        public static Vector3 Forward => Vector3.UnitZ;
        /// <summary>(0, 0, -1).</summary>
        public static Vector3 Back => -Vector3.UnitZ;
    }

    extension(Vector3 value)
    {
        /// <summary>The same direction one unit long; a zero vector stays zero (Vector3.Normalize gives NaN).</summary>
        public Vector3 Normalized
        {
            get
            {
                float length = value.Length();
                return length < 1.0e-12f ? Vector3.Zero : value / length;
            }
        }
    }

    extension(Vector2 value)
    {
        /// <summary>The same direction one unit long; a zero vector stays zero.</summary>
        public Vector2 Normalized
        {
            get
            {
                float length = value.Length();
                return length > 1.0e-6f ? value / length : Vector2.Zero;
            }
        }
    }

    extension(Quaternion)
    {
        /// <summary>A rotation from Euler angles in degrees, as the Inspector shows them: Z (roll) first, then X
        /// (pitch), then Y (yaw), as the engine does. Computed in C#, with no native call.</summary>
        public static Quaternion Euler(float x, float y, float z) =>
            Quaternion.AngleAxis(y, Vector3.UnitY) * Quaternion.AngleAxis(x, Vector3.UnitX) * Quaternion.AngleAxis(z, Vector3.UnitZ);

        /// <summary>A rotation from Euler angles in degrees (x, y, z).</summary>
        public static Quaternion Euler(Vector3 degrees) => Quaternion.Euler(degrees.X, degrees.Y, degrees.Z);

        /// <summary>A turn of so many degrees about an axis.</summary>
        public static Quaternion AngleAxis(float degrees, Vector3 axis)
        {
            float half = degrees * Mathf.Deg2Rad * 0.5f;
            Vector3 n = axis.Normalized * MathF.Sin(half);
            return new Quaternion(n.X, n.Y, n.Z, MathF.Cos(half));
        }

        /// <summary>The rotation that faces forward with up as near to up as it can.</summary>
        public static Quaternion LookRotation(Vector3 forward, Vector3 up) => RotationMath.LookRotation(forward, up);

        /// <summary>A vector turned by a rotation.</summary>
        public static Vector3 operator *(Quaternion rotation, Vector3 vector) => Vector3.Transform(vector, rotation);
    }

    extension(Quaternion rotation)
    {
        /// <summary>The rotation as Euler angles in degrees.</summary>
        public Vector3 EulerAngles => RotationMath.ToEulerDegrees(rotation);
    }
}
