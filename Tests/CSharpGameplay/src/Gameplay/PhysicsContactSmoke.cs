using System;
using System.Numerics;
using Tallow;

namespace Gameplay;

/// Native-host ABI regression: one generated call returns contact point and
/// distance from the same Jolt query. No separately handwritten physics import.
[Component]
public sealed class PhysicsContactSmoke : Script
{
    public override void Awake()
    {
        PhysicsContact? ray = Scene.Raycast(Vector3.Zero, Vector3.UnitZ, 10f);
        if (ray is not { Point: { X: 1f, Y: 2f, Z: 3f }, Distance: 2.5f })
            throw new InvalidOperationException("Native raycast point/distance marshalling failed.");

        PhysicsContact? sphere = Scene.SphereCast(Vector3.Zero, 0.5f,
            Vector3.UnitZ, 10f);
        if (sphere is not { Point: { X: 4f, Y: 5f, Z: 6f }, Distance: 1.5f })
            throw new InvalidOperationException("Native sphere cast contact marshalling failed.");

        if (GetSoftBody() is not { Kind: SoftBodyKind.Jelly,
            SimulatedVertexCount: 128 })
            throw new InvalidOperationException("Native SoftBody simulation metadata failed.");
    }
}
