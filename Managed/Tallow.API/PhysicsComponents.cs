using System.Numerics;

namespace Tallow;

/// <summary>
/// Value handle to the existing native ECS-backed Rigidbody. No managed Jolt
/// simulation or native pointer is stored. Scene sessions are checked in Beef.
/// </summary>
public readonly record struct Rigidbody(GameObject GameObject) : IComponent
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

    /// <summary>World-space angular velocity in radians per second.</summary>
    public Vector3 AngularVelocity
    {
        get => Physics.GetRigidbodyAngularVelocity(GameObject.SceneId, GameObject.Id);
        set
        {
            if (!Physics.SetRigidbodyAngularVelocity(GameObject.SceneId, GameObject.Id, value))
                throw new InvalidOperationException("Cannot set angular velocity on an inactive Rigidbody or with invalid values.");
        }
    }

    /// <summary>Apply torque over the next native Jolt physics step.</summary>
    public bool AddTorque(Vector3 torque) =>
        Physics.AddRigidbodyTorque(GameObject.SceneId, GameObject.Id, torque);

    /// <summary>Apply force at a world point, producing linear and angular motion.</summary>
    public bool AddForceAtPosition(Vector3 force, Vector3 worldPoint) =>
        Physics.AddRigidbodyForceAtPosition(GameObject.SceneId, GameObject.Id, force, worldPoint);

    /// <summary>World-space velocity at a point, including rotational motion.</summary>
    public Vector3 GetPointVelocity(Vector3 worldPoint) =>
        Physics.GetRigidbodyPointVelocity(GameObject.SceneId, GameObject.Id, worldPoint);

    /// <summary>Put a simulated Rigidbody to sleep until native physics wakes it.</summary>
    public bool Sleep() => Physics.SleepRigidbody(GameObject.SceneId, GameObject.Id);
}

/// <summary>
/// Session-safe value handle to Tallow's ECS-backed, native Jolt virtual
/// character. Native physics performs all shape movement and collision.
/// Use from Update(TickInput, deltaTime) for predicted network controls.
/// </summary>
public readonly record struct CharacterController(GameObject GameObject) : IComponent
{
    public bool IsValid =>
        Physics.HasCharacterController(GameObject.SceneId, GameObject.Id);
    public bool HasCharacter =>
        Physics.HasCharacterSimulation(GameObject.SceneId, GameObject.Id);
    public bool IsGrounded =>
        Physics.IsCharacterGrounded(GameObject.SceneId, GameObject.Id);
    public bool CanJump =>
        Physics.CanCharacterJump(GameObject.SceneId, GameObject.Id);
    public Vector3 Velocity =>
        Physics.GetCharacterVelocity(GameObject.SceneId, GameObject.Id);

    /// <summary>Move at the specified velocity, without automatic gravity.</summary>
    public bool Move(Vector3 velocity, float deltaTime) =>
        Physics.MoveCharacter(GameObject.SceneId, GameObject.Id, velocity, deltaTime);

    /// <summary>Walk with native gravity, slopes, steps and optional jump.</summary>
    public bool SimpleMove(Vector3 horizontalVelocity, float deltaTime,
        float jumpSpeed = 0) =>
        Physics.SimpleMoveCharacter(GameObject.SceneId, GameObject.Id,
            horizontalVelocity, deltaTime, jumpSpeed);

    /// <summary>Reset the native character pose and velocity, e.g. on respawn.</summary>
    public bool Teleport(Vector3 position, Vector3 velocity = default) =>
        Physics.TeleportCharacter(GameObject.SceneId, GameObject.Id, position, velocity);
}

public enum ColliderKind { Box, Sphere, Capsule, Mesh, Compound, Convex }

/// <summary>
/// Indexed handle to an existing native *class* collider. Multiple colliders
/// of the same type may exist on one GameObject. No native pointer is held;
/// all reads are validated against the active scene session and object ID.
/// </summary>
public readonly record struct ColliderHandle(GameObject GameObject, int Index) : IComponent
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
/// A value handle for Tallow's existing ECS-backed JointData and Jolt
/// constraint. A joint created during gameplay is local to this machine
/// unless the game explicitly coordinates its creation over networking.
/// </summary>
public readonly record struct Joint(GameObject GameObject) : IComponent
{
    public bool IsValid => Physics.HasJoint(GameObject.SceneId, GameObject.Id);
    public bool IsConnected => Physics.IsJointConnected(GameObject.SceneId, GameObject.Id);
    public Rigidbody? ConnectedTo
    {
        get
        {
            ulong entity = Physics.GetJointConnectedEntity(GameObject.SceneId, GameObject.Id);
            return entity == 0 ? null : new Rigidbody(new GameObject(GameObject.SceneId, entity));
        }
    }
    public float SwingLimit
    {
        get => Physics.GetJointSwingLimit(GameObject.SceneId, GameObject.Id);
        set
        {
            if (!Physics.SetJointSwingLimit(GameObject.SceneId, GameObject.Id, value))
                throw new ArgumentOutOfRangeException(nameof(value));
        }
    }

    /// <summary>
    /// Create one local Jolt constraint. Both rigidbodies must belong to the
    /// same active scene. Runtime-created joints are not auto-replicated.
    /// </summary>
    public static Joint? Connect(Rigidbody a, Rigidbody b, Vector3 anchor,
        Vector3 axis, float swingLimit = 0)
    {
        if (a.GameObject.SceneId == 0 ||
            a.GameObject.SceneId != b.GameObject.SceneId ||
            a.GameObject.Id == b.GameObject.Id)
            return null;
        return Physics.ConnectJoint(a.GameObject.SceneId,
            a.GameObject.Id, b.GameObject.Id, anchor, axis, swingLimit) ?
            new Joint(a.GameObject) : null;
    }
}

/// <summary>
/// Value handle to native SoftBody, including free cloth/jelly, dentable shells,
/// and rigidbody-driven jelly. No soft-body vertex buffer crosses into .NET.
/// </summary>
/// <summary>Matches the native SoftBodyKind modes, including Jelly Golf.</summary>
public enum SoftBodyKind { Cloth, Jelly, Shell, DrivenJelly }

public readonly record struct SoftBody(GameObject GameObject) : IComponent
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
