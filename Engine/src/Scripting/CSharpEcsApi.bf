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

    /// Local-only bare Flecs entities. Until the native networking authority
    /// path can register generated C# [Sync] layouts, reject creation in
    /// networked scenes rather than silently spawning unreplicated gameplay.
    /// Generated C# bindings never expose Flecs pointers or GameObjects.
    [CSharpExpose]
    public static uint64 CreateLocalEntity(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying || scene.World.NativeNetwork != null)
            return 0;
        return scene.World.Create().id;
    }

    /// Fill an existing managed buffer with bare entity IDs in one ABI call.
    /// Callers can batch in groups of up to 65536 to avoid unbounded work.
    [CSharpExpose]
    public static int32 CreateLocalEntities(uint64 session, Span<uint64> entityIds)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying || scene.World.NativeNetwork != null ||
            entityIds.IsEmpty || entityIds.Length > 65536)
            return 0;
        for (int i < entityIds.Length)
            entityIds[i] = scene.World.Create().id;
        return (int32)entityIds.Length;
    }

    /// Delete only a bare entity in the active, non-networked scene.
    /// An ECS entity that backs a GameObject must follow Scene.Destroy
    /// for normal component, physics and hierarchy cleanup.
    [CSharpExpose]
    public static bool DeleteLocalEntity(uint64 session, uint64 entity)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying || scene.World.NativeNetwork != null ||
            entity == 0 || !scene.World.IsAlive(.(entity)) ||
            scene.World.IsSceneObject(.(entity)))
            return false;
        scene.World.Delete(.(entity));
        return true;
    }

    [CSharpExpose]
    public static int32 CountRigidbodies(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null)
            return 0;
        return (int32)scene.World.EntitiesWith<RigidbodyData>().Count;
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
