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
        // Native colliders are class components. Their indexes preserve
        // stacked colliders on the same object, including repeated types.
        for (int i = 0; i < ColliderCount; i++)
        {
            if (GetCollider(i) is { Kind: ColliderKind.Sphere } sphere)
            {
                float? radius = sphere.SphereRadius;
            }
        }
        // Use the existing ECS-backed native Rigidbody when present.
        if (GetRigidbody() is { } rigidbody && rigidbody.HasBody)
        {
            rigidbody.AddForce(Vector3.UnitY * 5f);
            rigidbody.AddTorque(Vector3.UnitY * 0.5f);
            rigidbody.AddForceAtPosition(Vector3.UnitZ, Transform.Position + Vector3.UnitX);
            Vector3 angularVelocity = rigidbody.AngularVelocity;
            Vector3 pointVelocity = rigidbody.GetPointVelocity(Transform.Position);
        }

        // Jelly, cloth and shell all use the same native SoftBody component.
        if (GetSoftBody() is { } soft && soft.CanApplyForces)
            soft.AddImpulse(Vector3.UnitZ);

        if (Scene.Raycast(Transform.Position, Transform.Forward, 50f) is { } contact)
        {
            // Both the contact point and distance come from a single Jolt query.
            Vector3 hitPoint = contact.Point;
            float hitDistance = contact.Distance;
        }

        if (Scene.RaycastHit(Transform.Position, Transform.Forward, 60f) is { } rayHit)
        {
            GameObject? struckObject = rayHit.HitObject;
            Vector3 worldPoint = rayHit.Point;
        }

        if (Scene.SphereCastHit(Transform.Position, 0.5f,
            Transform.Forward, 30f) is { } sphereHit)
        {
            Vector3? surfaceNormal = sphereHit.Normal;
            float penetration = sphereHit.PenetrationDepth;
        }

        if (Scene.SphereCast(Transform.Position, 0.5f,
            Transform.Forward, 30f) is { } swept)
        {
            Vector3 touchPoint = swept.Point;
        }

        // A native Joint remains an ECS handle rather than a managed Jolt object.
        if (GetJoint() is { } existingJoint)
        {
            bool connected = existingJoint.IsConnected;
            float swingLimit = existingJoint.SwingLimit;
            Rigidbody? other = existingJoint.ConnectedTo;
        }

        if (GetSoftBody() is { } activeSoftBody)
        {
            SoftBodyKind? mode = activeSoftBody.Kind;
            int vertexCount = activeSoftBody.SimulatedVertexCount;
            bool sleeping = activeSoftBody.IsSleeping;
        }
    }
}
