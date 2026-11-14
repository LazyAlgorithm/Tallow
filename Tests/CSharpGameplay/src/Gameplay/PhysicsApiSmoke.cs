using System.Numerics;
using Tallow;

namespace Gameplay;

/// Compile-time gameplay sample. Native physics requires a real Jolt world;
/// the managed-only smoke host must never simulate a fake SoftBody.
[Component]
public sealed class PhysicsApiSmoke : Script
{
    public override void OnLocalUpdate()
    {
        // Use the existing ECS-backed native Rigidbody when present.
        if (GetRigidbody() is { } rigidbody && rigidbody.HasBody)
            rigidbody.AddForce(Vector3.UnitY * 5f);

        // Jelly, cloth and shell all use the same native SoftBody component.
        if (GetSoftBody() is { } soft && soft.CanApplyForces)
            soft.AddImpulse(Vector3.UnitZ);

        float distance = Scene.RaycastDistance(
            Transform.Position, Transform.Forward, 50f);
        if (distance >= 0)
            Log.Info("Physics ray hit");
    }
}
