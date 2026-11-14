namespace Tallow;

/// <summary>
/// Native engine constants shared by Beef and C# gameplay. All Mathf methods
/// are generated from Beef [CSharpExpose] declarations at engine build time.
/// This partial declaration holds compile-time constants only; no handwritten
/// method implementations or native-call bindings are permitted here.
/// </summary>
public static partial class Mathf
{
    public const float PI = 3.14159265358979f;
    public const float Deg2Rad = PI / 180f;
    public const float Rad2Deg = 180f / PI;
    public const float Epsilon = 1.0e-6f;
}
