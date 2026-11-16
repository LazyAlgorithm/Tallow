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

    /// Bare Flecs entities C# owns. On a server, one with [Sync] data is sent to clients (NetworkManagerEcs.bf);
    /// a client's stay its own. Generated C# bindings never expose Flecs pointers or GameObjects.
    [CSharpExpose]
    public static uint64 CreateLocalEntity(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying)
            return 0;
        return scene.World.CreateManagedLocalEntity().id;
    }

    /// Fill an existing managed buffer with bare entity IDs in one ABI call.
    /// Callers can batch in groups of up to 65536 to avoid unbounded work.
    [CSharpExpose]
    public static int32 CreateLocalEntities(uint64 session, Span<uint64> entityIds)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying ||
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
        if (scene == null || !scene.IsPlaying ||
            entity == 0 || !scene.World.IsManagedLocalEntity(.(entity)))
            return false;
        scene.World.Delete(.(entity));
        return true;
    }

    /// Register an opaque schema for C# ECS data in a scene. The schema
    /// hash must come from the compiled source-generated field description.
    /// Runtime layout size/alignment are checked by World before Flecs owns
    /// the memory. Its [Sync] fields were told by DescribeData.
    /// A game assembly's [Component] struct, when it loads: its name, layout and [Sync] fields
    /// ("name:offset:size;" each), so that the network can send them. False when the description is bad.
    [CSharpExpose]
    public static bool DescribeData(uint64 schemaId, StringView fullName, int32 size, int32 alignment,
        StringView syncFields)
    {
        return DataComponents.DescribeManaged(schemaId, fullName, size, alignment, syncFields) >= 0;
    }

    /// A game assembly's EcsSystem<T> (index in its EcsSystems list), when it loads: run each tick like a Beef
    /// NativeSystem<T> (NetworkManagerEcsPrediction.bf), on bare entities with schemaId's data.
    [CSharpExpose]
    public static bool DescribeSystem(int32 index, StringView name, int32 order, uint64 schemaId)
    {
        if (index < 0 || name.IsEmpty || schemaId == 0)
            return false;
        CSharpEcsSystem.Add(index, name, order, schemaId);
        return true;
    }

    /// Server: gives a bare synced entity to a client (0: back to the server); its systems then run on that client,
    /// which predicts it, and on the server with that client's controls.
    [CSharpExpose]
    public static bool SetOwner(uint64 session, uint64 entity, int32 clientId)
    {
        let scene = Playing(session);
        let network = scene?.World.NativeNetwork;
        if (network == null || !network.IsServer || entity == 0 || !scene.World.IsManagedLocalEntity(.(entity)))
            return false;
        network.NativeSetOwner(.(entity), clientId);
        return network.NativeOwner(.(entity)) == clientId;
    }

    /// The client whose controls run a bare synced entity, 0 for the server's (or offline).
    [CSharpExpose]
    public static int32 OwnerOf(uint64 session, uint64 entity)
    {
        let scene = Playing(session);
        let network = scene?.World.NativeNetwork;
        return network != null && entity != 0 ? network.NativeOwner(.(entity)) : 0;
    }

    /// Server: the bare entities clients own (systems' server runs pass over them: their owners' controls run them).
    /// How many there are; ids gets as many as fit.
    [CSharpExpose]
    public static int32 ClientOwned(uint64 session, Span<uint64> ids)
    {
        let scene = Playing(session);
        let network = scene?.World.NativeNetwork;
        return network != null ? network.NativeClientOwned(ids) : 0;
    }

    [CSharpExpose]
    public static uint64 RegisterLocalData(uint64 session, uint64 schemaId,
        int32 size, int32 alignment)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying)
            return 0;
        return scene.World.RegisterManagedLocalSchema(schemaId, size, alignment);
    }

    [CSharpExpose]
    public static bool SetLocalData(uint64 session, uint64 entity, uint64 schemaId,
        Span<uint8> bytes)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && scene.IsPlaying &&
            scene.World.SetManagedLocalData(.(entity), schemaId, bytes);
    }

    /// Read is false for missing components; caller-owned bytes are unchanged
    /// until a successful read, preventing use of uninitialized native memory.
    [CSharpExpose]
    public static bool CopyLocalData(uint64 session, uint64 entity, uint64 schemaId,
        Span<uint8> bytes)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && scene.IsPlaying &&
            scene.World.CopyManagedLocalData(.(entity), schemaId, bytes);
    }

    [CSharpExpose]
    public static bool HasLocalData(uint64 session, uint64 entity, uint64 schemaId)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && scene.IsPlaying &&
            scene.World.HasManagedLocalData(.(entity), schemaId);
    }

    /// Cached Flecs query count for a registered offline C# data schema.
    [CSharpExpose]
    public static int32 CountLocalData(uint64 session, uint64 schemaId)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !scene.IsPlaying)
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
        if (scene == null || !scene.IsPlaying)
            return 0;
        return scene.World.CopyManagedLocalDataPage(schemaId, offset, entityIds, bytes);
    }

    static Scene Playing(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return (scene != null && scene.IsPlaying) ? scene : null;
    }

    [CSharpExpose]
    public static bool RemoveLocalData(uint64 session, uint64 entity, uint64 schemaId)
    {
        let scene = Playing(session);
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
    /// Entities with every one of schemaIds and of with, and none of without (C# schemas).
    public static int32 CountData(uint64 session, Span<uint64> schemaIds, Span<uint64> with, Span<uint64> without)
    {
        let scene = Playing(session);
        return scene != null ? scene.World.CountManagedData(schemaIds, with, without) : 0;
    }

    /// Starts a ForEach that works on the data in place (see World.BeginManagedIteration): a handle, 0 when it
    /// cannot. Always pair it with EndDataIteration.
    [CSharpExpose]
    /// flags 1: bare entities only (no GameObject's), as systems run.
    public static int32 BeginDataIteration(uint64 session, Span<uint64> schemaIds, Span<uint64> with,
        Span<uint64> without, int32 flags)
    {
        let scene = Playing(session);
        return scene != null ? scene.World.BeginManagedIteration(schemaIds, with, without, (flags & 1) != 0) : 0;
    }

    /// The next matching table: its columns' addresses, its entity ids' address and its version counter's address;
    /// how many rows (0 at the end).
    /// The addresses hold until the next call or EndDataIteration.
    [CSharpExpose]
    public static int32 NextDataTable(uint64 session, int32 handle, Span<uint64> addresses)
    {
        let scene = Playing(session);
        return scene != null ? scene.World.NextManagedTable(handle, addresses) : 0;
    }

    /// The current table again, after its version changed while being walked (rows moved); how many rows now.
    [CSharpExpose]
    public static int32 RefreshDataTable(uint64 session, int32 handle, Span<uint64> addresses)
    {
        let scene = Playing(session);
        return scene != null ? scene.World.RefreshManagedTable(handle, addresses) : 0;
    }

    /// Ends the ForEach and applies the changes made during it.
    [CSharpExpose]
    public static void EndDataIteration(uint64 session, int32 handle)
    {
        // Not Playing: a ForEach whose action stopped play must still end, or changes stay queued.
        CSharpRuntime.PhysicsScene(session)?.World.EndManagedIteration(handle);
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
