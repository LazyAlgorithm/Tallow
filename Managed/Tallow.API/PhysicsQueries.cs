using System.Numerics;
using System.Runtime.InteropServices;

namespace Tallow;

/// <summary>A ray for <see cref="Scene.RaycastBatch"/>.</summary>
public readonly record struct RayQuery(Vector3 Origin, Vector3 Direction, float MaxDistance);

/// <summary>A sphere sweep for <see cref="Scene.SphereCastBatch"/>.</summary>
public readonly record struct SphereQuery(Vector3 Origin, float Radius, Vector3 Direction, float MaxDistance);

/// <summary>Physics queries with many results: every hit along a ray or sweep, every contact of an overlap, and many
/// rays or sweeps in one call (docs/physics-queries.md).</summary>
public readonly partial record struct Scene
{
    private static readonly int HitSize = Marshal.SizeOf<PhysicsQueryHit>();

    /// <summary>Runs a query that writes hit records, growing the buffer until they all fit.</summary>
    private PhysicsHit[] ReadHits(Func<byte[], int> query)
    {
        byte[] buffer = new byte[HitSize * 16];
        int count = query(buffer);
        if (count * HitSize > buffer.Length)
        {
            buffer = new byte[HitSize * count];
            count = Math.Min(count, query(buffer));
        }
        ReadOnlySpan<PhysicsQueryHit> records = MemoryMarshal.Cast<byte, PhysicsQueryHit>(buffer.AsSpan(0, count * HitSize));
        var hits = new List<PhysicsHit>(count);
        foreach (PhysicsQueryHit record in records)
            if (PhysicsHit.FromNative(SessionId, record) is PhysicsHit hit)
                hits.Add(hit);
        return [.. hits];
    }

    private PhysicsHit[] CastAll(int kind, Vector3 point1, Vector3 point2, float radius, Vector3 size, Quaternion orientation,
        Vector3 direction, float maxDistance, uint layerMask, uint ignoreBody)
    {
        ulong session = SessionId;
        var turn = new Vector4(orientation.X, orientation.Y, orientation.Z, orientation.W);
        return ReadHits(buffer => CSharpPhysicsQueries.CastAll(session, kind, point1, point2, radius, size, turn, direction,
            maxDistance, layerMask, ignoreBody, buffer));
    }

    /// <summary>Every object a ray passes through within maxDistance, nearest first, each once (where the ray enters
    /// it), with normals: a bullet that goes through thin walls, a line of sight past glass.</summary>
    public PhysicsHit[] RaycastAll(Vector3 origin, Vector3 direction, float maxDistance, uint layerMask = uint.MaxValue,
        uint ignoreBody = uint.MaxValue) =>
        CastAll(0, origin, default, 0, default, Quaternion.Identity, direction, maxDistance, layerMask, ignoreBody);

    /// <summary>Every object a sphere sweep touches, nearest first, each once.</summary>
    public PhysicsHit[] SphereCastAll(Vector3 origin, float radius, Vector3 direction, float maxDistance,
        uint layerMask = uint.MaxValue, uint ignoreBody = uint.MaxValue) =>
        CastAll(1, origin, default, radius, default, Quaternion.Identity, direction, maxDistance, layerMask, ignoreBody);

    /// <summary>Every object a capsule sweep touches (point1 and point2 the centres of its ends), nearest first.</summary>
    public PhysicsHit[] CapsuleCastAll(Vector3 point1, Vector3 point2, float radius, Vector3 direction, float maxDistance,
        uint layerMask = uint.MaxValue, uint ignoreBody = uint.MaxValue) =>
        CastAll(2, point1, point2, radius, default, Quaternion.Identity, direction, maxDistance, layerMask, ignoreBody);

    /// <summary>Every object a box sweep (size: full width, height and depth) touches, nearest first.</summary>
    public PhysicsHit[] BoxCastAll(Vector3 center, Vector3 size, Quaternion orientation, Vector3 direction, float maxDistance,
        uint layerMask = uint.MaxValue, uint ignoreBody = uint.MaxValue) =>
        CastAll(3, center, default, 0, size, orientation, direction, maxDistance, layerMask, ignoreBody);

    private PhysicsHit[] Contacts(int shape, Vector3 point1, Vector3 point2, float radius, Vector3 size, Quaternion orientation,
        uint layerMask, uint ignoreBody)
    {
        ulong session = SessionId;
        var turn = new Vector4(orientation.X, orientation.Y, orientation.Z, orientation.W);
        return ReadHits(buffer => CSharpPhysicsQueries.OverlapContacts(session, shape, point1, point2, radius, size, turn,
            layerMask, ignoreBody, buffer));
    }

    /// <summary>Every contact of a sphere: where it touches, the surface's normal, how deep it goes (PenetrationDepth),
    /// the object, part and triangle. An object touched in several places gives several. OverlapSphere gives only the
    /// objects, and is quicker.</summary>
    public PhysicsHit[] OverlapSphereContacts(Vector3 center, float radius, uint layerMask = uint.MaxValue,
        uint ignoreBody = uint.MaxValue) => Contacts(0, center, default, radius, default, Quaternion.Identity, layerMask, ignoreBody);

    /// <summary>Every contact of a capsule from point1 to point2.</summary>
    public PhysicsHit[] OverlapCapsuleContacts(Vector3 point1, Vector3 point2, float radius, uint layerMask = uint.MaxValue,
        uint ignoreBody = uint.MaxValue) => Contacts(1, point1, point2, radius, default, Quaternion.Identity, layerMask, ignoreBody);

    /// <summary>Every contact of a box (size: full width, height and depth).</summary>
    public PhysicsHit[] OverlapBoxContacts(Vector3 center, Vector3 size, Quaternion orientation, uint layerMask = uint.MaxValue,
        uint ignoreBody = uint.MaxValue) => Contacts(2, center, default, 0, size, orientation, layerMask, ignoreBody);

    /// <summary>Casts many rays in one call (a shotgun's pellets, an AI's sight lines, sensors), each giving its
    /// closest hit or null in results, in order. results must be at least as long as rays.</summary>
    public void RaycastBatch(ReadOnlySpan<RayQuery> rays, Span<PhysicsHit?> results, uint layerMask = uint.MaxValue)
    {
        var values = new float[rays.Length * 7];
        for (int i = 0; i < rays.Length; i++)
        {
            RayQuery ray = rays[i];
            int at = i * 7;
            (values[at], values[at + 1], values[at + 2]) = (ray.Origin.X, ray.Origin.Y, ray.Origin.Z);
            (values[at + 3], values[at + 4], values[at + 5]) = (ray.Direction.X, ray.Direction.Y, ray.Direction.Z);
            values[at + 6] = ray.MaxDistance;
        }
        Batch(0, values, rays.Length, results, layerMask, uint.MaxValue);
    }

    /// <summary>Sweeps many spheres in one call, each giving its closest hit or null in results, in order.</summary>
    public void SphereCastBatch(ReadOnlySpan<SphereQuery> spheres, Span<PhysicsHit?> results, uint layerMask = uint.MaxValue,
        uint ignoreBody = uint.MaxValue)
    {
        var values = new float[spheres.Length * 8];
        for (int i = 0; i < spheres.Length; i++)
        {
            SphereQuery sphere = spheres[i];
            int at = i * 8;
            (values[at], values[at + 1], values[at + 2], values[at + 3]) = (sphere.Origin.X, sphere.Origin.Y, sphere.Origin.Z, sphere.Radius);
            (values[at + 4], values[at + 5], values[at + 6]) = (sphere.Direction.X, sphere.Direction.Y, sphere.Direction.Z);
            values[at + 7] = sphere.MaxDistance;
        }
        Batch(1, values, spheres.Length, results, layerMask, ignoreBody);
    }

    private void Batch(int kind, float[] values, int count, Span<PhysicsHit?> results, uint layerMask, uint ignoreBody)
    {
        if (results.Length < count)
            throw new ArgumentException("results is shorter than the queries.", nameof(results));
        byte[] buffer = new byte[HitSize * count];
        CSharpPhysicsQueries.CastBatch(SessionId, kind, values, layerMask, ignoreBody, buffer);
        ReadOnlySpan<PhysicsQueryHit> records = MemoryMarshal.Cast<byte, PhysicsQueryHit>(buffer);
        for (int i = 0; i < count; i++)
            results[i] = PhysicsHit.FromNative(SessionId, records[i]);
    }
}

public readonly partial record struct GameObject
{
    /// <summary>Builds the object's collision again after its shape changed (a Mesh Collider's mesh edited or
    /// replaced, a collider resized from code): its colliders, and its Rigidbody's body if it has one.</summary>
    public void RefreshColliders()
    {
        if (!CSharpPhysicsQueries.RefreshColliders(SceneId, Id))
            throw ActionText.Missing(this, "collider");
    }
}

public readonly partial record struct MeshCollider
{
    /// <summary>Builds the collision again from the mesh after it changed (a re-meshed voxel chunk, an edited or
    /// replaced mesh).</summary>
    public void Refresh() => GameObject.RefreshColliders();
}
