using System;
using Tallow;

namespace Gameplay;

/// Native-host ABI smoke; linked Jolt/Flecs behavior is verified separately.
[Component]
public sealed class EcsBatchBindingSmoke : Script
{
    public override void Awake()
    {
        if (Ecs.CountRigidbodies(GameObject.SceneId) != 3 ||
            Ecs.CountRigidbodies(999) != 0 ||
            !Ecs.IsAlive(GameObject.SceneId, 11) ||
            Ecs.IsAlive(GameObject.SceneId, 999))
            throw new InvalidOperationException("Flecs count/entity binding failed.");

        Span<ulong> ids = stackalloc ulong[2];
        Span<float> masses = stackalloc float[2];
        if (Ecs.CopyRigidbodyMasses(GameObject.SceneId, 0, ids, masses) != 2 ||
            ids[0] != 11 || ids[1] != 22 ||
            masses[0] != 1.5f || masses[1] != 2.5f)
            throw new InvalidOperationException("First batch failed.");
        if (Ecs.CopyRigidbodyMasses(GameObject.SceneId, 2, ids, masses) != 1 ||
            ids[0] != 33 || masses[0] != 3.5f)
            throw new InvalidOperationException("Partial batch failed.");

        Span<float> shortMasses = stackalloc float[1];
        if (Ecs.CopyRigidbodyMasses(GameObject.SceneId, 0, ids, shortMasses) != 1 ||
            ids[0] != 11 || shortMasses[0] != 1.5f ||
            Ecs.CopyRigidbodyMasses(GameObject.SceneId, 0, ids, Span<float>.Empty) != 0)
            throw new InvalidOperationException("Batch bounds failed.");
        if (Ecs.CopyRigidbodyMasses(999, 0, ids, masses) != 0 ||
            Ecs.CopyRigidbodyMasses(GameObject.SceneId, -1, ids, masses) != 0)
            throw new InvalidOperationException("Stale session or offset accepted.");
    }
}
