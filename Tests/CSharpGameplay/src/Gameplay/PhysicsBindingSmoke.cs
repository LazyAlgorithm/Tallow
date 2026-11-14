using System.Numerics;
using Tallow;

namespace Gameplay;

/// Native-host only. No fake Jolt solver; verifies that generated C# wrappers
/// send exact session/entity handles, vector values and scalar parameters.
[Component]
public sealed class PhysicsBindingSmoke : Script
{
    public override void Awake()
    {
        if (GetRigidbody() is not { } rigid ||
            !rigid.AddForce(new Vector3(1, 2, 3)))
            throw new InvalidOperationException("Generated native Rigidbody force binding failed.");
        if (GetSoftBody() is not { } soft ||
            !soft.AddImpulse(new Vector3(4, 5, 6)))
            throw new InvalidOperationException("Generated native SoftBody impulse binding failed.");

        float hit = Scene.RaycastDistance(Vector3.Zero, Vector3.UnitZ, 10f);
        if (MathF.Abs(hit - 2.5f) > 0.0001f)
            throw new InvalidOperationException("Generated native raycast distance binding failed.");

        if (MathF.Abs(soft.Pressure - 10.0f) > 0.0001f)
            throw new InvalidOperationException("Native SoftBody pressure getter failed.");
        soft.Pressure = 12f;
        if (MathF.Abs(soft.Pressure - 12.0f) > 0.0001f)
            throw new InvalidOperationException("Native SoftBody pressure setter failed.");
    }
}
