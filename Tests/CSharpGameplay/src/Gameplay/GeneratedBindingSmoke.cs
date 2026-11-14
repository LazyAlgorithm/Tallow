using System.Numerics;
using Tallow;

namespace Gameplay;

/// <summary>
/// Native-host-only generated API integration. Standalone managed smoke host
/// deliberately skips this test, since it has no Beef/native API resolver.
/// </summary>
[Component]
public sealed class GeneratedBindingSmoke : Script
{
    public override void Awake()
    {
        // Safe read/write scalar binding generated from Beef's TimeScale
        // declaration, not a manually duplicated C# API signature.
        Log.Info("Tallow log é");
        Time.TimeScale = 0.5f;
        if (MathF.Abs(Time.TimeScale - 0.5f) > 0.0001f)
            throw new InvalidOperationException("Generated writable TimeScale property failed.");

        float clamped = Mathf.Clamp01(2.5f);
        if (MathF.Abs(clamped - 1f) > 0.0001f)
            throw new InvalidOperationException("Generated Mathf.Clamp01 native binding failed.");
        // Standard numeric operations should use .NET directly, never a native ABI thunk.
        if (MathF.Abs(Math.Clamp(2.5f, 0f, 1f) - 1f) > 0.0001f)
            throw new InvalidOperationException("Standard .NET clamp failed.");

        // Exercise both directions of the generated Quaternion ABI.
        Quaternion euler = RotationMath.EulerDegrees(Vector3.Zero);
        if (MathF.Abs(euler.W - 1f) > 0.0001f ||
            MathF.Abs(euler.X) + MathF.Abs(euler.Y) + MathF.Abs(euler.Z) > 0.0001f)
            throw new InvalidOperationException("Generated native quaternion return failed.");
        Vector3 zeroAngles = RotationMath.ToEulerDegrees(Quaternion.Identity);
        if (zeroAngles.LengthSquared() > 0.0001f)
            throw new InvalidOperationException("Generated native quaternion input failed.");
        Quaternion facing = RotationMath.LookRotation(Vector3.UnitZ, Vector3.UnitY);
        if (MathF.Abs(facing.W - 1f) > 0.0001f)
            throw new InvalidOperationException("Generated native LookRotation binding failed.");

        float average = CSharpBindingFixture.Average(4f, 6f);
        if (MathF.Abs(average - 5f) > 0.0001f)
            throw new InvalidOperationException("Generated [CSharpExpose] binding returned the wrong value.");
        Transform.Position = new Vector3(average, 0f, 0f);
    }
}
