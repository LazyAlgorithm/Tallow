using System;

namespace Tallow;

/// Number helpers for floats, named as in Unity.
static class Mathf
{
	public const float PI = 3.14159265358979f;
	/// Multiplies degrees into radians.
	public const float Deg2Rad = PI / 180.0f;
	/// Multiplies radians into degrees.
	public const float Rad2Deg = 180.0f / PI;
	/// A very small number, for "close enough to zero".
	public const float Epsilon = 1.0e-6f;

	[Inline] public static float Min(float a, float b) => a < b ? a : b;
	[Inline] public static float Max(float a, float b) => a > b ? a : b;
	/// v kept between lo and hi.
	[Inline] public static float Clamp(float v, float lo, float hi) => v < lo ? lo : (v > hi ? hi : v);
	/// v kept between 0 and 1.
	[Inline] public static float Clamp01(float v) => v < 0 ? 0 : (v > 1 ? 1 : v);
	/// The number a fraction t of the way from a to b (t is not clamped).
	[Inline] public static float Lerp(float a, float b, float t) => a + (b - a) * t;
	[Inline] public static float Abs(float v) => v < 0 ? -v : v;
	/// -1 for a negative number, else 1 (0 gives 1).
	[Inline] public static float Sign(float v) => v < 0 ? -1.0f : 1.0f;
	[Inline] public static float Sqrt(float v) => Math.Sqrt(v);
	[Inline] public static float Sin(float v) => Math.Sin(v);
	[Inline] public static float Cos(float v) => Math.Cos(v);
	[Inline] public static float Tan(float v) => Math.Tan(v);
	[Inline] public static float Floor(float v) => Math.Floor(v);
	/// The whole number at or below v.
	[Inline] public static int32 FloorToInt(float v) => (int32)Math.Floor(v);

	/// Moves from current towards target by at most maxDelta, stopping there.
	public static float MoveTowards(float current, float target, float maxDelta)
	{
		if (Abs(target - current) <= maxDelta)
			return target;
		return current + Sign(target - current) * maxDelta;
	}

	/// 0 at a, 1 at b, easing in and out between (as in shaders: not Unity's SmoothStep).
	public static float SmoothStep(float a, float b, float t)
	{
		let c = Clamp01((t - a) / (b - a));
		return c * c * (3.0f - 2.0f * c);
	}

	/// Wraps an angle in degrees to -180..180.
	public static float WrapAngle(float degrees)
	{
		var d = degrees % 360.0f;
		if (d > 180.0f)
			d -= 360.0f;
		if (d < -180.0f)
			d += 360.0f;
		return d;
	}
}
