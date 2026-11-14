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

        if (Scene.Raycast(Transform.Position, Transform.Forward, 50f) is { } contact)
        {
            // Both the contact point and distance come from a single Jolt query.
            Vector3 hitPoint = contact.Point;
            float hitDistance = contact.Distance;
        }

        if (Scene.SphereCast(Transform.Position, 0.5f,
            Transform.Forward, 30f) is { } swept)
        {
            Vector3 touchPoint = swept.Point;
        }

        if (GetSoftBody() is { } activeSoftBody)
        {
            SoftBodyKind? mode = activeSoftBody.Kind;
            int vertexCount = activeSoftBody.SimulatedVertexCount;
            bool sleeping = activeSoftBody.IsSleeping;
        }
    }
}
