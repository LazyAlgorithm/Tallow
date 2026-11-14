using System;

namespace Tallow;

/// Optional bulk ECS data API. Existing scene and Jolt components remain
/// owned by native Flecs; no native pointer leaves a generated wrapper.
[CSharpExpose]
static class Ecs
{
    /// Flecs entity IDs are NOT GameObject.Id values.
    [CSharpExpose]
    public static bool IsAlive(uint64 session, uint64 entity)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && entity != 0 && scene.World.IsAlive(.(entity));
    }

    [CSharpExpose]
    public static int32 CountRigidbodies(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null ? scene.World.EntitiesWith<RigidbodyData>().Count : 0;
    }

    /// Copy a stable query page with one native call. Output buffers are
    /// caller-owned; only the first returned-count elements are written.
    /// Query order can change with structural ECS mutations between pages.
    [CSharpExpose]
    public static int32 CopyRigidbodyMasses(uint64 session, int32 offset,
        Span<uint64> entityIds, Span<float> masses)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || offset < 0)
            return 0;
        int32 capacity = (int32)(entityIds.Length < masses.Length ?
            entityIds.Length : masses.Length);
        if (capacity <= 0)
            return 0;

        int32 visited = 0;
        int32 copied = 0;
        let query = scene.World.EntitiesWith<RigidbodyData>();
        for (var chunk in query)
        {
            let ids = chunk.Entities;
            let bodies = chunk.Read<RigidbodyData>();
            for (int i < chunk.Count)
            {
                if (visited++ < offset)
                    continue;
                if (copied == capacity)
                    return copied;
                entityIds[copied] = ids[i].id;
                masses[copied] = bodies[i].mass;
                copied++;
            }
        }
        return copied;
    }
}
