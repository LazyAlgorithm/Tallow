using System;

namespace Tallow;

/// A stable 48-byte native/managed value record. Fields use primitive numeric
/// types, never a native object pointer or a platform-dependent Vector3
/// packing. C# declares the same sequential layout in PhysicsQueryHit.
[CRepr]
struct PhysicsQueryHit
{
    public uint64 entityId;
    public float pointX, pointY, pointZ;
    public float normalX, normalY, normalZ;
    public float distance, penetrationDepth;
    public uint32 bodyId, flags;
}

/// The C# ABI exposes *existing* scene, Flecs-backed Rigidbody and Jolt-backed
/// SoftBody operations. Sessions and entity IDs are validated on every call.
/// No native object pointer or Jolt body ID crosses the managed boundary.
/// All public methods here require [CSharpExpose] explicitly.
[CSharpExpose]
static class Physics
{
    /// The active physics scene; rejects handles from old Play sessions.
    static Scene LiveScene(uint64 session) => CSharpRuntime.PhysicsScene(session);

    static GameObject LiveObject(uint64 session, uint64 entity) =>
        CSharpRuntime.PhysicsObject(session, entity);

    [CSharpExpose]
    public static bool HasRigidbody(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        return obj != null && obj.HasComponent<Rigidbody>();
    }

    [CSharpExpose]
    public static bool HasRigidbodyBody(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        return obj != null && obj.GetComponent<Rigidbody>().HasBody;
    }

    [CSharpExpose]
    public static Vector3 GetRigidbodyVelocity(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        if (obj == null)
            return .Zero;
        let body = obj.GetComponent<Rigidbody>();
        return body.HasBody ? body.Velocity : .Zero;
    }

    [CSharpExpose]
    public static bool SetRigidbodyVelocity(uint64 session, uint64 entity, Vector3 velocity)
    {
        let obj = LiveObject(session, entity);
        if (obj == null)
            return false;
        let body = obj.GetComponent<Rigidbody>();
        if (!body.HasBody)
            return false;
        body.Velocity = velocity;
        return true;
    }

    [CSharpExpose]
    public static bool AddRigidbodyForce(uint64 session, uint64 entity, Vector3 force)
    {
        let obj = LiveObject(session, entity);
        if (obj == null)
            return false;
        let body = obj.GetComponent<Rigidbody>();
        if (!body.HasBody)
            return false;
        body.AddForce(force);
        return true;
    }

    [CSharpExpose]
    public static bool AddRigidbodyImpulse(uint64 session, uint64 entity, Vector3 impulse)
    {
        let obj = LiveObject(session, entity);
        if (obj == null)
            return false;
        let body = obj.GetComponent<Rigidbody>();
        if (!body.HasBody)
            return false;
        body.AddImpulse(impulse);
        return true;
    }

    [CSharpExpose]
    public static bool HasSoftBody(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        return obj != null && obj.GetComponent<SoftBody>() != null;
    }

    [CSharpExpose]
    public static bool HasSoftBodySimulation(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null && soft.HasBody;
    }

    /// Shell and DrivenJelly are driven by a Rigidbody: do not misreport
    /// successful forces which the existing native SoftBody would ignore.
    [CSharpExpose]
    public static bool CanForceSoftBody(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null && soft.HasBody && soft.kind != .Shell && soft.kind != .DrivenJelly;
    }

    [CSharpExpose]
    public static Vector3 GetSoftBodyVelocity(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null || !soft.HasBody)
            return .Zero;
        return soft.Velocity;
    }

    [CSharpExpose]
    public static bool SetSoftBodyVelocity(uint64 session, uint64 entity, Vector3 velocity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null || !soft.HasBody || soft.kind == .Shell || soft.kind == .DrivenJelly)
            return false;
        soft.Velocity = velocity;
        return true;
    }

    [CSharpExpose]
    public static bool AddSoftBodyImpulse(uint64 session, uint64 entity, Vector3 impulse)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null || !soft.HasBody || soft.kind == .Shell || soft.kind == .DrivenJelly)
            return false;
        soft.AddImpulse(impulse);
        return true;
    }

    [CSharpExpose]
    public static bool AddSoftBodyForce(uint64 session, uint64 entity, Vector3 force)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null || !soft.HasBody || soft.kind == .Shell || soft.kind == .DrivenJelly)
            return false;
        soft.AddForce(force);
        return true;
    }

    [CSharpExpose]
    public static float GetSoftBodyPressure(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null ? soft.pressure : 0;
    }

    /// This is an explicit reconfiguration (not a per-tick fast path);
    /// native Rebuild preserves the object's pose during shape recreation.
    [CSharpExpose]
    public static bool SetSoftBodyPressure(uint64 session, uint64 entity, float pressure)
    {
        if (!pressure.IsFinite || pressure < 0 || pressure > 100000)
            return false;
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null)
            return false;
        if (soft.pressure == pressure)
            return true;
        soft.pressure = pressure;
        if (soft.HasBody)
            soft.Rebuild();
        return true;
    }

    [CSharpExpose]
    public static bool RepairSoftBody(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null || !soft.HasBody || soft.kind != .Shell)
            return false;
        // Retain Beef's existing server-authoritative shell dent replication.
        soft.Repair();
        return true;
    }

    [CSharpExpose]
    public static float DeepestSoftBodyDent(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null || !soft.HasBody)
            return 0;
        return soft.DeepestDent();
    }

    /// -1 means no hit or an inactive scene. Jolt owns the actual query and
    /// layer mask; a structured RaycastHit ABI follows in a later increment.

    /// Closest Jolt ray contact, packed as point.xyz and distance.w.
    /// No managed solver or additional physics query is involved.
    /// A negative distance means no hit; object/normal support is separate.
    /// Full contact data for a ray. The current native RaycastHit has no
    /// surface normal; flags bit 2 remains unset rather than inventing one.
    [CSharpExpose]
    public static PhysicsQueryHit RaycastDetails(uint64 session, Vector3 origin,
        Vector3 direction, float maxDistance, uint32 layerMask)
    {
        PhysicsQueryHit output = default;
        let scene = LiveScene(session);
        if (scene == null || scene.Physics == null || !maxDistance.IsFinite ||
            maxDistance <= 0)
            return output;
        RaycastHit hit = default;
        if (!scene.Physics.Raycast(origin, direction, maxDistance, out hit, layerMask))
            return output;
        output.flags = 1;
        output.pointX = hit.point.x;
        output.pointY = hit.point.y;
        output.pointZ = hit.point.z;
        output.distance = hit.distance;
        output.bodyId = uint32.MaxValue; // Not provided by native RaycastHit.
        if (hit.gameObject != null && !hit.gameObject.IsDestroyed)
        {
            output.entityId = (uint64)hit.gameObject.Id;
            output.flags |= 4;
        }
        return output;
    }

    /// One Jolt sweep provides the point, surface normal, penetration,
    /// collider GameObject and body id; no duplicate sweep is necessary.
    [CSharpExpose]
    public static PhysicsQueryHit SphereCastDetails(uint64 session, Vector3 origin,
        float radius, Vector3 direction, float maxDistance, uint32 layerMask)
    {
        PhysicsQueryHit output = default;
        let scene = LiveScene(session);
        if (scene == null || scene.Physics == null || !radius.IsFinite ||
            radius <= 0 || !maxDistance.IsFinite || maxDistance <= 0)
            return output;
        ShapeCastHit hit = default;
        if (!scene.Physics.SphereCast(origin, radius, direction, maxDistance,
            out hit, uint32.MaxValue, layerMask))
            return output;
        output.flags = 3;
        output.pointX = hit.point.x;
        output.pointY = hit.point.y;
        output.pointZ = hit.point.z;
        output.normalX = hit.normal.x;
        output.normalY = hit.normal.y;
        output.normalZ = hit.normal.z;
        output.distance = hit.distance;
        output.penetrationDepth = hit.penetrationDepth;
        output.bodyId = hit.bodyId;
        if (hit.gameObject != null && !hit.gameObject.IsDestroyed)
        {
            output.entityId = (uint64)hit.gameObject.Id;
            output.flags |= 4;
        }
        return output;
    }

    [CSharpExpose]
    public static Vector4 RaycastContact(uint64 session, Vector3 origin,
        Vector3 direction, float maxDistance, uint32 layerMask)
    {
        let scene = LiveScene(session);
        if (scene == null || scene.Physics == null || !maxDistance.IsFinite ||
            maxDistance <= 0)
            return .(0, 0, 0, -1);
        RaycastHit hit = default;
        if (!scene.Physics.Raycast(origin, direction, maxDistance, out hit, layerMask))
            return .(0, 0, 0, -1);
        return Vector4(hit.point, hit.distance);
    }

    /// Sphere sweep uses Jolt's native swept-volume contacts, including
    /// distance zero when starting in overlap. The normal is not in this ABI.
    [CSharpExpose]
    public static Vector4 SphereCastContact(uint64 session, Vector3 origin,
        float radius, Vector3 direction, float maxDistance, uint32 layerMask)
    {
        let scene = LiveScene(session);
        if (scene == null || scene.Physics == null || !radius.IsFinite ||
            radius <= 0 || !maxDistance.IsFinite || maxDistance <= 0)
            return .(0, 0, 0, -1);
        ShapeCastHit hit = default;
        if (!scene.Physics.SphereCast(origin, radius, direction, maxDistance,
            out hit, uint32.MaxValue, layerMask))
            return .(0, 0, 0, -1);
        return Vector4(hit.point, hit.distance);
    }

    [CSharpExpose]
    public static bool IsRigidbodySleeping(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        if (obj == null)
            return false;
        let body = obj.GetComponent<Rigidbody>();
        return body.HasBody && body.IsSleeping;
    }

    [CSharpExpose]
    public static bool IsSoftBodySleeping(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null && soft.HasBody && soft.IsSleeping;
    }

    /// Valid SoftBodyKind values: Cloth=0, Jelly=1, Shell=2, DrivenJelly=3.
    /// -1 means the session/entity or component is no longer valid.
    [CSharpExpose]
    public static int32 GetSoftBodyMode(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null ? (int32)soft.kind : -1;
    }

    [CSharpExpose]
    public static int32 GetSoftBodyVertexCount(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null ? (int32)soft.SimulatedVertexCount : 0;
    }

    [CSharpExpose]
    public static float RaycastDistance(uint64 session, Vector3 origin,
        Vector3 direction, float maxDistance, uint32 layerMask)
    {
        let scene = LiveScene(session);
        if (scene == null || scene.Physics == null || !maxDistance.IsFinite ||
            maxDistance <= 0)
            return -1;
        RaycastHit hit = default;
        return scene.Physics.Raycast(origin, direction, maxDistance, out hit, layerMask) ?
            hit.distance : -1;
    }
}
