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
        return scene.World.CreateManagedLocalEntity().id;
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
            entityIds[i] = scene.World.CreateManagedLocalEntity().id;
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
            entity == 0 || !scene.World.IsManagedLocalEntity(.(entity)))
            return false;
        scene.World.Delete(.(entity));
        return true;
    }

    /// Register an opaque schema for *offline only* C# ECS data. The schema
    /// hash must come from the compiled source-generated field description.
    /// Runtime layout size/alignment are checked by World before Flecs owns
    /// the memory. This is not networked [Sync] registration.
    [CSharpExpose]
    public static uint64 RegisterLocalData(uint64 session, uint64 schemaId,
        int32 size, int32 alignment)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying || scene.World.NativeNetwork != null)
            return 0;
        return scene.World.RegisterManagedLocalSchema(schemaId, size, alignment);
    }

    [CSharpExpose]
    public static bool SetLocalData(uint64 session, uint64 entity, uint64 schemaId,
        Span<uint8> bytes)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && scene.IsPlaying && scene.World.NativeNetwork == null &&
            scene.World.SetManagedLocalData(.(entity), schemaId, bytes);
    }

    /// Read is false for missing components; caller-owned bytes are unchanged
    /// until a successful read, preventing use of uninitialized native memory.
    [CSharpExpose]
    public static bool CopyLocalData(uint64 session, uint64 entity, uint64 schemaId,
        Span<uint8> bytes)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && scene.IsPlaying && scene.World.NativeNetwork == null &&
            scene.World.CopyManagedLocalData(.(entity), schemaId, bytes);
    }

    [CSharpExpose]
    public static bool HasLocalData(uint64 session, uint64 entity, uint64 schemaId)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && scene.IsPlaying && scene.World.NativeNetwork == null &&
            scene.World.HasManagedLocalData(.(entity), schemaId);
    }

    /// Cached Flecs query count for a registered offline C# data schema.
    [CSharpExpose]
    public static int32 CountLocalData(uint64 session, uint64 schemaId)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying || scene.World.NativeNetwork != null)
            return 0;
        return scene.World.CountManagedLocalData(schemaId);
    }

    /// Bounded native ECS query page. The bytes span is a sequence of
    /// registered-size records. Entity order can change after mutations.
    [CSharpExpose]
    public static int32 CopyLocalDataPage(uint64 session, uint64 schemaId, int32 offset,
        Span<uint64> entityIds, Span<uint8> bytes)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying || scene.World.NativeNetwork != null)
            return 0;
        return scene.World.CopyManagedLocalDataPage(schemaId, offset, entityIds, bytes);
    }

    static Scene OfflinePlaying(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return (scene != null && scene.IsPlaying && scene.World.NativeNetwork == null) ? scene : null;
    }

    [CSharpExpose]
    public static bool RemoveLocalData(uint64 session, uint64 entity, uint64 schemaId)
    {
        let scene = OfflinePlaying(session);
        return scene != null && scene.World.RemoveManagedLocalData(.(entity), schemaId);
    }

    /// The Flecs entity of a GameObject (C# data components can go on it), 0 when there is none.
    [CSharpExpose]
    public static uint64 EntityOfObject(uint64 session, uint64 objectId)
    {
        let gameObject = CSharpRuntime.PhysicsObject(session, objectId);
        return gameObject != null ? gameObject.Entity.id : 0;
    }

    /// The GameObject an entity belongs to (its id), 0 for a bare entity.
    [CSharpExpose]
    public static uint64 ObjectOfEntity(uint64 session, uint64 entity)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || entity == 0 || !scene.World.IsAlive(.(entity)) || !scene.World.IsSceneObject(.(entity)))
            return 0;
        let link = scene.World.Get<ObjectLink>(.(entity));
        return (link != null && link.gameObject != null && !link.gameObject.IsDestroyed) ? link.gameObject.Id : 0;
    }

    /// How many entities have every one of the C# data schemas (at most 4).
    [CSharpExpose]
    public static int32 CountData(uint64 session, Span<uint64> schemaIds)
    {
        let scene = OfflinePlaying(session);
        return scene != null ? scene.World.CountManagedData(schemaIds) : 0;
    }

    /// A page of the entities with every one of the C# data schemas: ids, and rows of their records in order.
    [CSharpExpose]
    public static int32 CopyDataPage(uint64 session, Span<uint64> schemaIds, int32 offset,
        Span<uint64> entityIds, Span<uint8> bytes)
    {
        let scene = OfflinePlaying(session);
        return scene != null ? scene.World.CopyManagedDataPage(schemaIds, offset, entityIds, bytes) : 0;
    }

    /// Writes rows (as CopyDataPage gives them) back; entities that have gone or lost a schema are skipped.
    [CSharpExpose]
    public static int32 WriteDataPage(uint64 session, Span<uint64> schemaIds, Span<uint64> entityIds, Span<uint8> bytes)
    {
        let scene = OfflinePlaying(session);
        return scene != null ? scene.World.WriteManagedDataPage(schemaIds, entityIds, bytes) : 0;
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
