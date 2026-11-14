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


    // Colliders intentionally remain *class* components. Tallow permits
    // several colliders per GameObject, including repeated shape types; each
    // index below addresses one component in its original attachment order.
    // This is not a Flecs HandleData component.
    static Collider ColliderAt(uint64 session, uint64 entity, int32 index)
    {
        if (index < 0)
            return null;
        let obj = LiveObject(session, entity);
        if (obj == null)
            return null;
        int32 current = 0;
        for (let component in obj.Components)
        {
            if (let collider = component as Collider)
            {
                if (current == index)
                    return collider;
                current++;
            }
        }
        return null;
    }

    [CSharpExpose]
    public static int32 GetColliderCount(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        if (obj == null)
            return 0;
        int32 count = 0;
        for (let component in obj.Components)
        {
            if (component as Collider != null)
                count++;
        }
        return count;
    }

    /// Returns -1 if the collider index is invalid; otherwise 0-5:
    /// Box, Sphere, Capsule, Mesh, Compound, Convex.
    [CSharpExpose]
    public static int32 GetColliderKind(uint64 session, uint64 entity, int32 index)
    {
        let collider = ColliderAt(session, entity, index);
        if (collider == null)
            return -1;
        let type = collider.GetType();
        if (type == typeof(BoxCollider)) return 0;
        if (type == typeof(SphereCollider)) return 1;
        if (type == typeof(CapsuleCollider)) return 2;
        if (type == typeof(MeshCollider)) return 3;
        if (type == typeof(CompoundCollider)) return 4;
        if (type == typeof(ConvexCollider)) return 5;
        return -1;
    }

    [CSharpExpose]
    public static Vector3 GetColliderCenter(uint64 session, uint64 entity, int32 index)
    {
        let collider = ColliderAt(session, entity, index);
        if (collider == null)
            return .Zero;
        return collider.center;
    }

    [CSharpExpose]
    public static Vector3 GetColliderBoxSize(uint64 session, uint64 entity, int32 index)
    {
        if (let box = ColliderAt(session, entity, index) as BoxCollider)
            return box.size;
        return .Zero;
    }

    [CSharpExpose]
    public static float GetColliderSphereRadius(uint64 session, uint64 entity, int32 index)
    {
        if (let sphere = ColliderAt(session, entity, index) as SphereCollider)
            return sphere.radius;
        return -1;
    }

    [CSharpExpose]
    public static float GetColliderCapsuleRadius(uint64 session, uint64 entity, int32 index)
    {
        if (let capsule = ColliderAt(session, entity, index) as CapsuleCollider)
            return capsule.radius;
        return -1;
    }

    [CSharpExpose]
    public static float GetColliderCapsuleHeight(uint64 session, uint64 entity, int32 index)
    {
        if (let capsule = ColliderAt(session, entity, index) as CapsuleCollider)
            return capsule.height;
        return -1;
    }

    // A settings change is an explicit operation, not a per-tick hot path.
    // Rebuild uses the existing SoftBody/Jolt lifecycle and preserves pose.
    [CSharpExpose]
    public static float GetSoftBodyStiffness(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null ? soft.stiffness : 0;
    }

    [CSharpExpose]
    public static bool SetSoftBodyStiffness(uint64 session, uint64 entity, float stiffness)
    {
        if (!stiffness.IsFinite || stiffness < 0 || stiffness > 1)
            return false;
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null)
            return false;
        if (soft.stiffness == stiffness)
            return true;
        soft.stiffness = stiffness;
        if (soft.HasBody)
            soft.Rebuild();
        return true;
    }

    [CSharpExpose]
    public static float GetSoftBodyWobbleDamping(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        return soft != null ? soft.wobbleDamping : 0;
    }

    [CSharpExpose]
    public static bool SetSoftBodyWobbleDamping(uint64 session, uint64 entity, float damping)
    {
        if (!damping.IsFinite || damping < 0 || damping > 20)
            return false;
        let obj = LiveObject(session, entity);
        let soft = obj?.GetComponent<SoftBody>();
        if (soft == null)
            return false;
        if (soft.wobbleDamping == damping)
            return true;
        soft.wobbleDamping = damping;
        if (soft.HasBody)
            soft.Rebuild();
        return true;
    }


    // Joint is already a Flecs ComponentHandle<JointData>. The opaque
    // session + entity pair is validated before touching its ECS data.
    [CSharpExpose]
    public static bool HasJoint(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        return obj != null && obj.HasComponent<Joint>();
    }

    [CSharpExpose]
    public static bool IsJointConnected(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        if (obj == null || !obj.HasComponent<Joint>())
            return false;
        return obj.GetComponent<Joint>().IsConnected;
    }

    [CSharpExpose]
    public static uint64 GetJointConnectedEntity(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        if (obj == null || !obj.HasComponent<Joint>())
            return 0;
        let other = obj.GetComponent<Joint>().ConnectedTo;
        if (!other.IsValid)
            return 0;
        return (uint64)other.GameObject.Id;
    }

    [CSharpExpose]
    public static float GetJointSwingLimit(uint64 session, uint64 entity)
    {
        let obj = LiveObject(session, entity);
        if (obj == null || !obj.HasComponent<Joint>())
            return -1;
        return obj.GetComponent<Joint>().swingLimit;
    }

    [CSharpExpose]
    public static bool SetJointSwingLimit(uint64 session, uint64 entity, float degrees)
    {
        if (!degrees.IsFinite || degrees < 0 || degrees > 179)
            return false;
        let obj = LiveObject(session, entity);
        if (obj == null || !obj.HasComponent<Joint>())
            return false;
        let joint = obj.GetComponent<Joint>();
        if (joint.swingLimit == degrees)
            return true;
        joint.swingLimit = degrees;
        joint.Rebuild();
        return true;
    }

    /// A native Joint.Connect uses the same ECS-backed JointData and Jolt
    /// solver as Beef. Dynamic joints are currently LOCAL ONLY: the engine
    /// requires explicitly coordinated creation for multiplayer sessions.
    [CSharpExpose]
    public static bool ConnectJoint(uint64 session, uint64 a, uint64 b,
        Vector3 anchor, Vector3 axis, float swingLimit)
    {
        if (a == b || !swingLimit.IsFinite || swingLimit < 0 || swingLimit > 179 ||
            !anchor.x.IsFinite || !anchor.y.IsFinite || !anchor.z.IsFinite ||
            !axis.x.IsFinite || !axis.y.IsFinite || !axis.z.IsFinite ||
            (axis.x == 0 && axis.y == 0 && axis.z == 0))
            return false;
        let first = LiveObject(session, a);
        let second = LiveObject(session, b);
        if (first == null || second == null || first.HasComponent<Joint>())
            return false;
        let mine = first.GetComponent<Rigidbody>();
        let other = second.GetComponent<Rigidbody>();
        if (!mine.IsValid || !other.IsValid)
            return false;
        let joint = Joint.Connect(mine, other, anchor, axis, swingLimit);
        return joint.IsValid;
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
