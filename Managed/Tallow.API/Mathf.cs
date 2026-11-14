namespace Tallow;

/// <summary>
/// Float helpers with the same names and behavior as native Beef Mathf.
/// Keeps common gameplay calculations portable between C# and Beef.
/// </summary>
public static class Mathf
{
    public const float PI = 3.14159265358979f;
    public const float Deg2Rad = PI / 180f;
    public const float Rad2Deg = 180f / PI;
    public const float Epsilon = 1.0e-6f;

    public static float Min(float a, float b) => a < b ? a : b;
    public static float Max(float a, float b) => a > b ? a : b;
    public static float Clamp(float value, float min, float max) =>
        value < min ? min : value > max ? max : value;
    public static float Clamp01(float value) => Clamp(value, 0, 1);

    /// <summary>Unclamped interpolation, just like native Mathf.Lerp.</summary>
    public static float Lerp(float a, float b, float t) => a + (b - a) * t;
    public static float Abs(float value) => value < 0 ? -value : value;
    /// <summary>Returns +1 for zero, matching Beef rather than MathF.Sign.</summary>
    public static float Sign(float value) => value < 0 ? -1f : 1f;
    public static float Sqrt(float value) => MathF.Sqrt(value);
    public static float Sin(float value) => MathF.Sin(value);
    public static float Cos(float value) => MathF.Cos(value);
    public static float Tan(float value) => MathF.Tan(value);
    public static float Floor(float value) => MathF.Floor(value);
    public static int FloorToInt(float value) => (int)MathF.Floor(value);

    public static float MoveTowards(float current, float target, float maxDelta)
    {
        if (Abs(target - current) <= maxDelta)
            return target;
        return current + Sign(target - current) * maxDelta;
    }

    /// <summary>0 at a and 1 at b, cubic easing in between.</summary>
    public static float SmoothStep(float a, float b, float t)
    {
        float c = Clamp01((t - a) / (b - a));
        return c * c * (3f - 2f * c);
    }

    /// <summary>Wrap degrees to the -180..180 range, matching native Tallow.</summary>
    public static float WrapAngle(float degrees)
    {
        float wrapped = degrees % 360f;
        if (wrapped > 180f) wrapped -= 360f;
        if (wrapped < -180f) wrapped += 360f;
        return wrapped;
    }
}
