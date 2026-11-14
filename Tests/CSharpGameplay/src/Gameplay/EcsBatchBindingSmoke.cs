using System;
using Tallow;
using Tallow.Generated;

namespace Gameplay;

/// Native-host ABI smoke; linked Jolt/Flecs behavior is verified separately.
[Component]
public sealed class EcsBatchBindingSmoke : Script
{
    public override void Awake()
    {
        var scene = GameObject.Scene;
        if (scene.RigidbodyEntityCount != 3 ||
            new Scene(999).RigidbodyEntityCount != 0 ||
            !scene.GetEcsEntity(11).IsAlive ||
            scene.GetEcsEntity(999).IsAlive ||
            new Scene(999).GetEcsEntity(11).IsAlive)
            throw new InvalidOperationException("Flecs count/entity binding failed.");

        Span<ulong> ids = stackalloc ulong[2];
        Span<float> masses = stackalloc float[2];
        if (scene.CopyRigidbodyMasses(0, ids, masses) != 2 ||
            ids[0] != 11 || ids[1] != 22 ||
            masses[0] != 1.5f || masses[1] != 2.5f)
            throw new InvalidOperationException("First batch failed.");
        if (scene.CopyRigidbodyMasses(2, ids, masses) != 1 ||
            ids[0] != 33 || masses[0] != 3.5f)
            throw new InvalidOperationException("Partial batch failed.");

        Span<float> shortMasses = stackalloc float[1];
        if (scene.CopyRigidbodyMasses(0, ids, shortMasses) != 1 ||
            ids[0] != 11 || shortMasses[0] != 1.5f ||
            scene.CopyRigidbodyMasses(0, ids, Span<float>.Empty) != 0)
            throw new InvalidOperationException("Batch bounds failed.");
        if (new Scene(999).CopyRigidbodyMasses(0, ids, masses) != 0 ||
            scene.CopyRigidbodyMasses(-1, ids, masses) != 0)
            throw new InvalidOperationException("Stale session or offset accepted.");

        // Bare local ECS entity lifetime is managed by the same native
        // Flecs World, not by creating a shadow C# entity dictionary.
        var created = scene.CreateLocalEcsEntity();
        if (!created.IsAlive || created.Id == 0 ||
            created.SessionId != scene.SessionId ||
            !created.DestroyLocal() || created.IsAlive || created.DestroyLocal())
            throw new InvalidOperationException("Local Flecs entity lifetime failed.");

        Span<ulong> batch = stackalloc ulong[3];
        if (scene.CreateLocalEcsEntities(batch) != batch.Length ||
            batch[0] == 0 || batch[0] == batch[1] || batch[1] == batch[2] ||
            !scene.GetEcsEntity(batch[2]).IsAlive)
            throw new InvalidOperationException("Bulk local Flecs creation failed.");
        foreach (ulong id in batch)
            if (!scene.GetEcsEntity(id).DestroyLocal())
                throw new InvalidOperationException("Bulk local Flecs cleanup failed.");

        // Exact-size, opaque local data round trip across the real generated
        // byte-span ABI. No C# references, pointers or unmanaged ownership
        // are passed across the bridge.
        const ulong validSchema = 0xBEEF1234UL;
        if (!scene.RegisterLocalEcsData(validSchema, 8, 4) ||
            !scene.RegisterLocalEcsData(validSchema, 8, 4) ||
            scene.RegisterLocalEcsData(validSchema, 16, 4) ||
            scene.RegisterLocalEcsData(validSchema, 8, 3) ||
            scene.RegisterLocalEcsData(0, 8, 4) ||
            new Scene(999).RegisterLocalEcsData(validSchema, 8, 4))
            throw new InvalidOperationException("Local Flecs layout guards failed.");

        var blob = scene.CreateLocalEcsEntity();
        Span<byte> data = stackalloc byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };
        Span<byte> readback = stackalloc byte[8];
        readback.Fill(0x7f);
        if (blob.HasLocalData(validSchema) ||
            blob.TryCopyLocalData(validSchema, readback) ||
            !blob.SetLocalData(validSchema, data) ||
            !blob.HasLocalData(validSchema) ||
            !blob.TryCopyLocalData(validSchema, readback) ||
            !data.SequenceEqual(readback) ||
            blob.SetLocalData(validSchema, data[..7]) ||
            blob.TryCopyLocalData(validSchema, readback[..7]) ||
            scene.GetEcsEntity(11).SetLocalData(validSchema, data) ||
            new Scene(999).GetEcsEntity(blob.Id).HasLocalData(validSchema) ||
            new Scene(999).GetEcsEntity(blob.Id).TryCopyLocalData(validSchema, readback))
            throw new InvalidOperationException("Local Flecs data transfer/ownership failed.");
        if (!blob.DestroyLocal() || blob.HasLocalData(validSchema) ||
            blob.TryCopyLocalData(validSchema, readback) ||
            blob.SetLocalData(validSchema, data))
            throw new InvalidOperationException("Flecs data survived entity deletion.");

        // The build tool generates these strongly typed overloads directly
        // from marked unmanaged C# structs. No manual schema IDs, raw
        // buffers or runtime reflection are needed in gameplay code.
        var typed = scene.CreateLocalEcsEntity();
        VelocityData velocity = new()
        {
            Velocity = new System.Numerics.Vector3(3, 4, 5),
            Drag = 0.25f,
            Owner = 17
        };
        if (!typed.SetLocalData(in velocity) ||
            !typed.TryGetLocalData(out VelocityData restored) ||
            restored.Velocity != velocity.Velocity ||
            restored.Drag != velocity.Drag ||
            restored.Owner != velocity.Owner ||
            !typed.DestroyLocal() ||
            typed.TryGetLocalData(out restored))
            throw new InvalidOperationException("Generated typed ECS data bridge failed.");

        if (scene.CreateLocalEcsEntities(Span<ulong>.Empty) != 0 ||
            new Scene(999).CreateLocalEcsEntities(batch) != 0 ||
            scene.GetEcsEntity(11).DestroyLocal() ||
            new Scene(999).GetEcsEntity(12).DestroyLocal())
            throw new InvalidOperationException("Local ECS lifetime/authority checks failed.");
    }
}
