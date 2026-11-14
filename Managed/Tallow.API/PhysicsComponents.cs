using System.Numerics;

namespace Tallow;

/// <summary>
/// Value handle to the existing native ECS-backed Rigidbody. No managed Jolt
/// simulation or native pointer is stored. Scene sessions are checked in Beef.
/// </summary>
public readonly record struct Rigidbody(GameObject GameObject)
{
    public bool IsValid => Physics.HasRigidbody(GameObject.SceneId, GameObject.Id);
    public bool HasBody => Physics.HasRigidbodyBody(GameObject.SceneId, GameObject.Id);
    public bool IsSleeping => Physics.IsRigidbodySleeping(GameObject.SceneId, GameObject.Id);
    public Vector3 Velocity
    {
        get => Physics.GetRigidbodyVelocity(GameObject.SceneId, GameObject.Id);
        set => Physics.SetRigidbodyVelocity(GameObject.SceneId, GameObject.Id, value);
    }
    public bool AddForce(Vector3 force) =>
        Physics.AddRigidbodyForce(GameObject.SceneId, GameObject.Id, force);
    public bool AddImpulse(Vector3 impulse) =>
        Physics.AddRigidbodyImpulse(GameObject.SceneId, GameObject.Id, impulse);
}


public enum ColliderKind { Box, Sphere, Capsule, Mesh, Compound, Convex }

/// <summary>
/// Indexed handle to an existing native *class* collider. Multiple colliders
/// of the same type may exist on one GameObject. No native pointer is held;
/// all reads are validated against the active scene session and object ID.
/// </summary>
public readonly record struct ColliderHandle(GameObject GameObject, int Index)
{
    public ColliderKind? Kind
    {
        get
        {
            int type = Physics.GetColliderKind(GameObject.SceneId, GameObject.Id, Index);
            return type is >= 0 and <= 5 ? (ColliderKind)type : null;
        }
    }

    public bool IsValid => Kind.HasValue;
    public Vector3 Center => Physics.GetColliderCenter(GameObject.SceneId, GameObject.Id, Index);
    public Vector3? BoxSize => Kind == ColliderKind.Box ?
        Physics.GetColliderBoxSize(GameObject.SceneId, GameObject.Id, Index) : null;
    public float? SphereRadius
    {
        get
        {
            float r = Physics.GetColliderSphereRadius(GameObject.SceneId, GameObject.Id, Index);
            return r >= 0 ? r : null;
        }
    }
    public float? CapsuleRadius
    {
        get
        {
            float r = Physics.GetColliderCapsuleRadius(GameObject.SceneId, GameObject.Id, Index);
            return r >= 0 ? r : null;
        }
    }
    public float? CapsuleHeight
    {
        get
        {
            float h = Physics.GetColliderCapsuleHeight(GameObject.SceneId, GameObject.Id, Index);
            return h >= 0 ? h : null;
        }
    }
}

/// <summary>
/// Value handle to native SoftBody, including free cloth/jelly, dentable shells,
/// and rigidbody-driven jelly. No soft-body vertex buffer crosses into .NET.
/// </summary>
/// <summary>Matches the native SoftBodyKind modes, including Jelly Golf.</summary>
public enum SoftBodyKind { Cloth, Jelly, Shell, DrivenJelly }

public readonly record struct SoftBody(GameObject GameObject)
{
    public bool IsValid => Physics.HasSoftBody(GameObject.SceneId, GameObject.Id);
    public bool HasBody => Physics.HasSoftBodySimulation(GameObject.SceneId, GameObject.Id);
    public bool IsSleeping => Physics.IsSoftBodySleeping(GameObject.SceneId, GameObject.Id);
    public SoftBodyKind? Kind
    {
        get
        {
            int value = Physics.GetSoftBodyMode(GameObject.SceneId, GameObject.Id);
            return value is >= 0 and <= 3 ? (SoftBodyKind)value : null;
        }
    }
    public int SimulatedVertexCount =>
        Physics.GetSoftBodyVertexCount(GameObject.SceneId, GameObject.Id);
    public bool CanApplyForces => Physics.CanForceSoftBody(GameObject.SceneId, GameObject.Id);

    /// <summary>Stretch stiffness (0-1). Changing it rebuilds the native simulation.</summary>
    public float Stiffness
    {
        get => Physics.GetSoftBodyStiffness(GameObject.SceneId, GameObject.Id);
        set
        {
            if (!Physics.SetSoftBodyStiffness(GameObject.SceneId, GameObject.Id, value))
                throw new ArgumentOutOfRangeException(nameof(value));
        }
    }

    /// <summary>Jelly wobble decay (0-20). Changing it rebuilds the native simulation.</summary>
    public float WobbleDamping
    {
        get => Physics.GetSoftBodyWobbleDamping(GameObject.SceneId, GameObject.Id);
        set
        {
            if (!Physics.SetSoftBodyWobbleDamping(GameObject.SceneId, GameObject.Id, value))
                throw new ArgumentOutOfRangeException(nameof(value));
        }
    }
    public Vector3 Velocity
    {
        get => Physics.GetSoftBodyVelocity(GameObject.SceneId, GameObject.Id);
        set => Physics.SetSoftBodyVelocity(GameObject.SceneId, GameObject.Id, value);
    }
    public float Pressure
    {
        get => Physics.GetSoftBodyPressure(GameObject.SceneId, GameObject.Id);
        set
        {
            if (!Physics.SetSoftBodyPressure(GameObject.SceneId, GameObject.Id, value))
                throw new InvalidOperationException("Cannot set soft-body pressure on this object.");
        }
    }
    public bool AddForce(Vector3 force) =>
        Physics.AddSoftBodyForce(GameObject.SceneId, GameObject.Id, force);
    public bool AddImpulse(Vector3 impulse) =>
        Physics.AddSoftBodyImpulse(GameObject.SceneId, GameObject.Id, impulse);
    public float DeepestDent => Physics.DeepestSoftBodyDent(GameObject.SceneId, GameObject.Id);
    public bool Repair() => Physics.RepairSoftBody(GameObject.SceneId, GameObject.Id);
}
