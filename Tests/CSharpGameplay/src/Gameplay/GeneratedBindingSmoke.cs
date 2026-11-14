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

        float average = CSharpBindingFixture.Average(4f, 6f);
        if (MathF.Abs(average - 5f) > 0.0001f)
            throw new InvalidOperationException("Generated [CSharpExpose] binding returned the wrong value.");
        Transform.Position = new Vector3(average, 0f, 0f);
    }
}
