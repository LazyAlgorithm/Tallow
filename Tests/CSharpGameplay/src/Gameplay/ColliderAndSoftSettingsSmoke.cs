using System;
using System.Numerics;
using Tallow;

namespace Gameplay;

/// Native-host regression for stacked class colliders and on-demand native
/// SoftBody parameter rebuilding. No fake physics simulation is involved.
[Component]
public sealed class ColliderAndSoftSettingsSmoke : Script
{
    public override void Awake()
    {
        if (ColliderCount != 3 || GetCollider(-1) is not null || GetCollider(3) is not null)
            throw new InvalidOperationException("Native collider count/index validation failed.");

        if (GetCollider(0) is not { Kind: ColliderKind.Box } box ||
            box.BoxSize != new Vector3(1, 2, 3) ||
            box.Center != Vector3.UnitY)
            throw new InvalidOperationException("Native box collider fields lost their index.");

        if (GetCollider(1) is not { Kind: ColliderKind.Sphere } sphere ||
            sphere.SphereRadius != 0.5f ||
            sphere.Center != Vector3.UnitY * 2)
            throw new InvalidOperationException("Native sphere collider shape read failed.");

        if (GetCollider(2) is not { Kind: ColliderKind.Capsule } capsule ||
            capsule.CapsuleRadius != 0.4f || capsule.CapsuleHeight != 1.8f)
            throw new InvalidOperationException("Native capsule collider shape read failed.");

        if (GetSoftBody() is not { } soft ||
            MathF.Abs(soft.Stiffness - 0.9f) > 0.0001f ||
            MathF.Abs(soft.WobbleDamping - 3f) > 0.0001f)
            throw new InvalidOperationException("Native SoftBody stiffness/damping getter failed.");

        soft.Stiffness = 0.75f;
        soft.WobbleDamping = 4f;
        if (MathF.Abs(soft.Stiffness - 0.75f) > 0.0001f ||
            MathF.Abs(soft.WobbleDamping - 4f) > 0.0001f)
            throw new InvalidOperationException("Native SoftBody parameter setter failed.");

        try
        {
            soft.Stiffness = -1f;
            throw new InvalidOperationException("Invalid stiffness was accepted.");
        }
        catch (ArgumentOutOfRangeException)
        {
            // Rejected as intended by native physics.
        }
    }
}
