namespace Tallow;

/// <summary>
/// Tallow-specific helpers are generated from Beef [CSharpExpose] declarations.
/// Use System.MathF and System.Math.Clamp for standard numeric operations.
/// This partial declaration holds compile-time constants only; no handwritten
/// method implementations or native-call bindings are permitted here.
/// </summary>
public static partial class Mathf
{
    /// <summary>Pi, 3.14159...</summary>
    public const float PI = MathF.PI;
    /// <summary>Multiplies degrees into radians.</summary>
    public const float Deg2Rad = MathF.PI / 180f;
    /// <summary>Multiplies radians into degrees.</summary>
    public const float Rad2Deg = 180f / MathF.PI;
    /// <summary>A very small number, for comparing floats.</summary>
    public const float Epsilon = 1.0e-6f;
}
