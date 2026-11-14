using System;
using System.Numerics;
using Tallow;

namespace Gameplay;

/// Validates the single-call CRepr/StructLayout Jolt result ABI against the
/// in-process C++ host's explicitly typed test doubles. Only native-host test.
[Component]
public sealed class PhysicsDetailedSmoke : Script
{
    public override void Awake()
    {
        PhysicsHit? ray = Scene.RaycastHit(Vector3.Zero, Vector3.UnitZ, 10f);
        if (ray is not { } rayValue ||
            rayValue.HitObject != GameObject ||
            rayValue.Point != new Vector3(11, 12, 13) ||
            rayValue.Distance != 2.25f || rayValue.Normal is not null ||
            rayValue.BodyId != uint.MaxValue)
            throw new InvalidOperationException("Native ray hit identity/point/normal flags do not match.");

        PhysicsHit? sphere = Scene.SphereCastHit(
            Vector3.Zero, 0.5f, Vector3.UnitZ, 10f);
        if (sphere is not { } sphereValue ||
            sphereValue.HitObject != GameObject ||
            sphereValue.Point != new Vector3(21, 22, 23) ||
            sphereValue.Normal != Vector3.UnitY ||
            sphereValue.Distance != 1.25f ||
            MathF.Abs(sphereValue.PenetrationDepth - 0.15f) > 0.0001f ||
            sphereValue.BodyId != 17)
            throw new InvalidOperationException("Native sphere contact result layout/normal is incorrect.");

        if (Scene.RaycastHit(Vector3.Zero, Vector3.UnitX, 10f) is not null)
            throw new InvalidOperationException("Invalid native hit flags must map to null.");
    }
}
