using System.Numerics;

namespace Tallow;

/// <summary>
/// Value handle to the existing native ECS-backed Rigidbody. No managed Jolt
/// simulation or native pointer is stored. Scene sessions are checked in Beef.
/// </summary>
[NativeComponent("Tallow.Rigidbody")]
public readonly partial record struct Rigidbody(GameObject GameObject) : IComponent
{
    /// <summary>Whether the object still has a Rigidbody.</summary>
    public bool IsValid => Physics.HasRigidbody(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether its physics body has been made (in the first physics step after it is added).</summary>
    public bool HasBody => Physics.HasRigidbodyBody(GameObject.SceneId, GameObject.Id);

    /// <summary>The body's id in the physics world (for a cast to ignore); uint.MaxValue when it has none.</summary>
    public uint BodyId => Physics.RigidbodyBodyId(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether it lies still and is not being simulated until something touches it.</summary>
    public bool IsSleeping => Physics.IsRigidbodySleeping(GameObject.SceneId, GameObject.Id);
    /// <summary>Its speed and direction in metres a second. Setting it on a new body makes the body at once.</summary>
    public Vector3 Velocity
    {
        get => Physics.GetRigidbodyVelocity(GameObject.SceneId, GameObject.Id);
        set => Physics.SetRigidbodyVelocity(GameObject.SceneId, GameObject.Id, value);
    }
    /// <summary>Pushes it for this step (newtons, world space): call it every tick to keep pushing. False with no
    /// body.</summary>
    public bool AddForce(Vector3 force) =>
        Physics.AddRigidbodyForce(GameObject.SceneId, GameObject.Id, force);
    /// <summary>Gives it a sudden push (newton-seconds, world space): a hit, an explosion, a jump. False with no
    /// body.</summary>
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
[NativeComponent("Tallow.CharacterController")]
public readonly partial record struct CharacterController(GameObject GameObject) : IComponent
{
    /// <summary>Whether the object still has a CharacterController.</summary>
    public bool IsValid =>
        Physics.HasCharacterController(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether its physics character has been made (in the first physics step after it is added).</summary>
    public bool HasCharacter =>
        Physics.HasCharacterSimulation(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether it stands on walkable ground.</summary>
    public bool IsGrounded =>
        Physics.IsCharacterGrounded(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether a jump would start now: on the ground, or just left it (the coyote time).</summary>
    public bool CanJump =>
        Physics.CanCharacterJump(GameObject.SceneId, GameObject.Id);
    /// <summary>Seconds since it was last on the ground (0 while it is).</summary>
    public float AirTime => Physics.CharacterAirTime(GameObject.SceneId, GameObject.Id);
    /// <summary>On ground too steep to walk up: it slides down.</summary>
    public bool IsOnSteepGround => Physics.IsCharacterOnSteepGround(GameObject.SceneId, GameObject.Id);
    /// <summary>The surface normal of the ground it stands on; zero in the air.</summary>
    public Vector3 GroundNormal => Physics.CharacterGround(GameObject.SceneId, GameObject.Id, true);
    /// <summary>How the ground under it moves (a moving platform); zero in the air or on still ground.</summary>
    public Vector3 GroundVelocity => Physics.CharacterGround(GameObject.SceneId, GameObject.Id, false);
    /// <summary>How it is moving, in metres a second.</summary>
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

    /// <summary>A capsule shape. False when there is no room for it where the character is.</summary>
    public bool SetCapsule(float radius, float height, Vector3 center = default) =>
        Physics.SetCharacterShape(GameObject.SceneId, GameObject.Id, false, radius, height, default, 0, center);

    /// <summary>A box shape of this full size (rounded by <paramref name="edgeRadius"/>). False when it does not fit.</summary>
    public bool SetBox(Vector3 size, float edgeRadius = 0.1f, Vector3 center = default) =>
        Physics.SetCharacterShape(GameObject.SceneId, GameObject.Id, true, 0, 0, size, edgeRadius, center);

    /// <summary>Reset the native character pose and velocity, e.g. on respawn.</summary>
    /// <summary>
    /// Moves the character as a swimmer this tick: no gravity, velocity in any direction; jumpSpeed (above 0) lifts it
    /// out of the water at the surface. Use instead of Move while it is in water.
    /// </summary>
    public void Swim(Vector3 velocity, float deltaTime, float jumpSpeed = 0)
    {
        if (!CSharpComponentActions.CharacterSwim(GameObject.SceneId, GameObject.Id, velocity, deltaTime, jumpSpeed))
            throw new InvalidOperationException($"{GameObject} has no CharacterController.");
    }

    /// <summary>Puts it at position at once, with velocity, without sweeping through what is in between. False with
    /// no character.</summary>
    public bool Teleport(Vector3 position, Vector3 velocity = default) =>
        Physics.TeleportCharacter(GameObject.SceneId, GameObject.Id, position, velocity);

    /// <summary>The capsule height now; 0 when the component is missing.</summary>
    public float Height =>
        Physics.GetCharacterHeight(GameObject.SceneId, GameObject.Id);

    /// <summary>
    /// Crouch or stand: resizes the capsule to <paramref name="height"/>,
    /// keeping the feet of a <paramref name="standingHeight"/> capsule. In
    /// the air the head stays still instead. Standing up is refused while
    /// something is in the way, so check <see cref="Height"/> afterwards.
    /// </summary>
    public bool SetHeight(float height, float standingHeight) =>
        Physics.SetCharacterHeight(GameObject.SceneId, GameObject.Id, height, standingHeight);

    /// <summary>
    /// How far <see cref="SetHeight"/> moved the character this frame to keep
    /// its head still in the air. Subtract it from a smoothed camera height.
    /// </summary>
    public float CrouchLift =>
        Physics.GetCharacterCrouchLift(GameObject.SceneId, GameObject.Id);
}

/// <summary>A collider's shape.</summary>
public enum ColliderKind { Box, Sphere, Capsule, Mesh, Compound, Convex }

/// <summary>
/// Indexed handle to an existing native *class* collider. Multiple colliders
/// of the same type may exist on one GameObject. No native pointer is held;
/// all reads are validated against the active scene session and object ID.
/// </summary>
public readonly record struct ColliderHandle(GameObject GameObject, int Index) : IComponent
{
/// <summary>The collider's shape; null when the collider is gone.</summary>
    public ColliderKind? Kind
    {
        get
        {
            int type = Physics.GetColliderKind(GameObject.SceneId, GameObject.Id, Index);
            return type is >= 0 and <= 5 ? (ColliderKind)type : null;
        }
    }

    /// <summary>Whether the collider still exists.</summary>
    public bool IsValid => Kind.HasValue;

    /// <summary>
    /// A trigger stops nothing and reports <see cref="Script.OnTriggerEnter"/>/Stay/Exit instead of collisions.
    /// Changing it rebuilds the object's physics body (a Rigidbody keeps its position and velocity). It is a local
    /// change: on a networked object, set it on every machine (for example from an <see cref="RpcAttribute"/>).
    /// </summary>
    public bool IsTrigger
    {
        get
        {
            int value = Physics.GetColliderIsTrigger(GameObject.SceneId, GameObject.Id, Index);
            return value >= 0 ? value == 1 : throw new InvalidOperationException("The collider is gone.");
        }
        set
        {
            if (!Physics.SetColliderIsTrigger(GameObject.SceneId, GameObject.Id, Index, value))
                throw new InvalidOperationException("The collider is gone.");
        }
    }

    /// <summary>Where the collider is, relative to its object.</summary>
    public Vector3 Center => Physics.GetColliderCenter(GameObject.SceneId, GameObject.Id, Index);
    /// <summary>A box's full size; null for other shapes.</summary>
    public Vector3? BoxSize => Kind == ColliderKind.Box ?
        Physics.GetColliderBoxSize(GameObject.SceneId, GameObject.Id, Index) : null;
/// <summary>A sphere's radius; null for other shapes.</summary>
    public float? SphereRadius
    {
        get
        {
            float r = Physics.GetColliderSphereRadius(GameObject.SceneId, GameObject.Id, Index);
            return r >= 0 ? r : null;
        }
    }
/// <summary>A capsule's radius; null for other shapes.</summary>
    public float? CapsuleRadius
    {
        get
        {
            float r = Physics.GetColliderCapsuleRadius(GameObject.SceneId, GameObject.Id, Index);
            return r >= 0 ? r : null;
        }
    }
/// <summary>A capsule's height from end to end, its rounded ends included; null for other shapes.</summary>
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
    /// <summary>Whether the object still has a joint.</summary>
    public bool IsValid => Physics.HasJoint(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether the joint is attached to another body (and holding).</summary>
    public bool IsConnected => Physics.IsJointConnected(GameObject.SceneId, GameObject.Id);

    /// <summary>Builds the joint again after its fields were changed while playing.</summary>
    public void Rebuild()
    {
        if (!Physics.RebuildJoint(GameObject.SceneId, GameObject.Id))
            throw ActionText.Missing(GameObject, "Joint");
    }
/// <summary>The other body the joint holds this one to; null when it is held to the world.</summary>
    public Rigidbody? ConnectedTo
    {
        get
        {
            ulong entity = Physics.GetJointConnectedEntity(GameObject.SceneId, GameObject.Id);
            return entity == 0 ? null : new Rigidbody(new GameObject(GameObject.SceneId, entity));
        }
    }
/// <summary>How far, in degrees (0 to 179), the bodies may swing from the joint's axis; 0 for no limit.</summary>
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

/// <summary>A soft body: cloth, jelly, a dentable shell or jelly driven by a skeleton, simulated with Jolt.</summary>
[NativeComponent("Tallow.SoftBody")]
public readonly partial record struct SoftBody(GameObject GameObject) : IComponent
{
    /// <summary>Whether the object still has a SoftBody.</summary>
    public bool IsValid => Physics.HasSoftBody(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether its simulation has been made (in the first physics step after it is added).</summary>
    public bool HasBody => Physics.HasSoftBodySimulation(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether it lies still and is not being simulated until something touches it.</summary>
    public bool IsSleeping => Physics.IsSoftBodySleeping(GameObject.SceneId, GameObject.Id);
    /// <summary>Cloth, jelly, shell or driven jelly; null when there is no soft body. Like its other settings
    /// (Mass, Iterations...), set it in the frame the SoftBody is added: the simulation is made from them.</summary>
    public SoftBodyKind? Kind
    {
        get
        {
            int value = Physics.GetSoftBodyMode(GameObject.SceneId, GameObject.Id);
            return value is >= 0 and <= 3 ? (SoftBodyKind)value : null;
        }
        set => new NativeComponent(GameObject, "Tallow.SoftBody").Set("kind",
            value ?? throw new ArgumentNullException(nameof(value)));
    }
    /// <summary>How many vertices the simulation moves.</summary>
    public int SimulatedVertexCount =>
        Physics.GetSoftBodyVertexCount(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether AddForce and AddImpulse work on it: cloth and jelly once simulated. A shell or driven
    /// jelly is moved by its Rigidbody, so push that instead.</summary>
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
    /// <summary>The soft body's average velocity in metres a second; setting it moves every point at that speed.</summary>
    public Vector3 Velocity
    {
        get => Physics.GetSoftBodyVelocity(GameObject.SceneId, GameObject.Id);
        set => Physics.SetSoftBodyVelocity(GameObject.SceneId, GameObject.Id, value);
    }
/// <summary>Jelly: how hard the air inside pushes out, in pascals above the air outside (0 keeps its shape by its edges alone, 10 a jelly cube, 200 and more blows it up into a ball).</summary>
    public float Pressure
    {
        get => Physics.GetSoftBodyPressure(GameObject.SceneId, GameObject.Id);
        set
        {
            if (!Physics.SetSoftBodyPressure(GameObject.SceneId, GameObject.Id, value))
                throw new InvalidOperationException("Cannot set soft-body pressure on this object.");
        }
    }
    /// <summary>Pushes every vertex for this step (newtons in all, world space). False when it cannot be pushed.</summary>
    public bool AddForce(Vector3 force) =>
        Physics.AddSoftBodyForce(GameObject.SceneId, GameObject.Id, force);
    /// <summary>Gives every vertex a sudden push (newton-seconds in all, world space). False when it cannot be
    /// pushed.</summary>
    public bool AddImpulse(Vector3 impulse) =>
        Physics.AddSoftBodyImpulse(GameObject.SceneId, GameObject.Id, impulse);
    /// <summary>A shell's deepest dent now, in metres (0 for other kinds or when undented).</summary>
    public float DeepestDent => Physics.DeepestSoftBodyDent(GameObject.SceneId, GameObject.Id);
    /// <summary>Takes the shell's dents out, back to its made shape. False when it is not a shell.</summary>
    public bool Repair() => Physics.RepairSoftBody(GameObject.SceneId, GameObject.Id);
}

/// <summary>
/// A hinge between two rigidbodies, made with <see cref="Scene.CreateHinge"/>: a door, a wheel, an arm. It goes
/// when either body does. Local to this machine: make the same one on every machine.
/// </summary>
public readonly record struct Hinge(ulong SessionId, ulong Id)
{
    /// <summary>Whether the hinge still exists.</summary>
    public bool IsValid => Id != 0 && CSharpJoints.IsAlive(SessionId, Id, true);

    /// <summary>Spins the hinge at <paramref name="speed"/> radians a second with up to <paramref name="torque"/> N·m.</summary>
    public void SetMotorSpeed(float speed, float torque) => CSharpJoints.SetHingeMotor(SessionId, Id, speed, torque, 0, 1, 8, 3);

    /// <summary>Turns the hinge to <paramref name="angle"/> radians, at up to <paramref name="maximumSpeed"/>,
    /// faster the larger <paramref name="response"/> is.</summary>
    public void SetMotorAngle(float angle, float torque, float response = 8f, float maximumSpeed = 3f) =>
        CSharpJoints.SetHingeMotor(SessionId, Id, 0, torque, angle, 2, response, maximumSpeed);

    /// <summary>Switches the motor off; the hinge swings freely.</summary>
    public void StopMotor() => CSharpJoints.SetHingeMotor(SessionId, Id, 0, 0, 0, 0, 8, 3);

    /// <summary>How far it has turned, in radians.</summary>
    public float Angle => CSharpJoints.HingeAngle(SessionId, Id);

    /// <summary>Removes it; nothing when it has already gone.</summary>
    public void Destroy() => CSharpJoints.Destroy(SessionId, Id, true);
}

/// <summary>A slider with a spring between two rigidbodies, made with <see cref="Scene.CreateSuspension"/>: a wheel's suspension.</summary>
public readonly record struct Suspension(ulong SessionId, ulong Id)
{
    /// <summary>Whether the suspension still exists.</summary>
    public bool IsValid => Id != 0 && CSharpJoints.IsAlive(SessionId, Id, false);

    /// <summary>Its spring, in newtons a metre and newton-seconds a metre.</summary>
    public void SetSpring(float stiffness, float damping) => CSharpJoints.SetSuspensionSpring(SessionId, Id, stiffness, damping);

    /// <summary>How far along its travel it is, in metres.</summary>
    public float Position => CSharpJoints.SuspensionPosition(SessionId, Id);

    /// <summary>Removes it; nothing when it has already gone.</summary>
    public void Destroy() => CSharpJoints.Destroy(SessionId, Id, false);
}

public readonly partial record struct Scene
{
    /// <summary>
    /// A hinge turning about <paramref name="axis"/> through <paramref name="anchor"/> (world space);
    /// <paramref name="childAxis"/> and <paramref name="childNormal"/> fix how the second body sits on it. The two
    /// bodies stop colliding with each other. Null when either has no body.
    /// </summary>
    public Hinge? CreateHinge(Rigidbody a, Rigidbody b, Vector3 anchor, Vector3 axis, Vector3 childAxis, Vector3 childNormal)
    {
        if (!a.HasBody || !b.HasBody)
            return null;
        ulong id = CSharpJoints.CreateHinge(SessionId, a.BodyId, b.BodyId, anchor, axis, childAxis, childNormal);
        return id == 0 ? null : new Hinge(SessionId, id);
    }

    /// <summary>A slider along <paramref name="axis"/>, <paramref name="travel"/> metres either way. Give it a spring
    /// with <see cref="Suspension.SetSpring"/>. Null when either has no body.</summary>
    public Suspension? CreateSuspension(Rigidbody a, Rigidbody b, Vector3 anchor, Vector3 childAnchor, Vector3 axis,
        Vector3 childAxis, Vector3 childNormal, float travel)
    {
        if (!a.HasBody || !b.HasBody)
            return null;
        ulong id = CSharpJoints.CreateSuspension(SessionId, a.BodyId, b.BodyId, anchor, childAnchor, axis, childAxis,
            childNormal, travel);
        return id == 0 ? null : new Suspension(SessionId, id);
    }
}

public readonly partial record struct Rigidbody
{
    /// <summary>Builds the body again from the object's colliders (after their size changed, or parts were added to
    /// a Compound Collider), keeping its position and velocity.</summary>
    public void RebuildBody()
    {
        if (!Physics.RebuildRigidbody(GameObject.SceneId, GameObject.Id))
            throw ActionText.Missing(GameObject, "Rigidbody");
    }

    /// <summary>Makes the physics body now, rather than at the next physics step: for reading its state or setting
    /// its velocity as soon as the object is made.</summary>
    public void EnsureBody() => Physics.EnsureRigidbody(GameObject.SceneId, GameObject.Id);

    /// <summary>Where the body is, how it is turned and how it moves: what a reset or a network correction puts
    /// back.</summary>
    public bool TryGetState(out RigidBodyState state)
    {
        Span<float> values = stackalloc float[13];
        if (Physics.CopyRigidbodyState(GameObject.SceneId, GameObject.Id, values) != 13)
        {
            state = default;
            return false;
        }
        state = new RigidBodyState(
            new Vector3(values[0], values[1], values[2]),
            new Quaternion(values[3], values[4], values[5], values[6]),
            new Vector3(values[7], values[8], values[9]),
            new Vector3(values[10], values[11], values[12]));
        return true;
    }

    /// <summary>Puts the body back at a saved state.</summary>
    public bool SetState(RigidBodyState state)
    {
        Span<float> values = stackalloc float[13]
        {
            state.Position.X, state.Position.Y, state.Position.Z,
            state.Rotation.X, state.Rotation.Y, state.Rotation.Z, state.Rotation.W,
            state.LinearVelocity.X, state.LinearVelocity.Y, state.LinearVelocity.Z,
            state.AngularVelocity.X, state.AngularVelocity.Y, state.AngularVelocity.Z
        };
        return Physics.SetRigidbodyState(GameObject.SceneId, GameObject.Id, values);
    }
}

/// <summary>A Rigidbody's whole pose and motion, as a reset or a network correction keeps it.</summary>
public readonly record struct RigidBodyState(
    Vector3 Position, Quaternion Rotation, Vector3 LinearVelocity, Vector3 AngularVelocity);

/// <summary>The scene's physics settings for a game whose units are not metres (the aircraft game's 500 units per
/// metre): gravity, the smallest shape taken seriously and the game-unit length scale.</summary>
public static class PhysicsSettings
{
    /// <summary>The scene's gravity.</summary>
    public static Vector3 Gravity(Scene scene) => Physics.GetGravity(scene.SessionId);
    /// <summary>Sets the scene's gravity.</summary>
    public static void SetGravity(Scene scene, Vector3 gravity) => Physics.SetGravity(scene.SessionId, gravity);
    /// <summary>How much smaller than a metre the game's unit is.</summary>
    public static void SetLengthScale(Scene scene, float scale) => Physics.SetLengthScale(scene.SessionId, scale);
    /// <summary>The smallest collider extent the physics world keeps, in the game's units.</summary>
    public static void SetMinimumShapeExtent(Scene scene, float extent) =>
        Physics.SetMinimumShapeExtent(scene.SessionId, extent);
}

public readonly partial record struct CompoundCollider
{
    /// <summary>Adds a box part in the object's own space. Call <see cref="Rigidbody.RebuildBody"/> afterwards.</summary>
    public void AddBox(Vector3 center, Vector3 size) => Add(0, center, size, Quaternion.Identity, []);

    /// <summary>Adds a cylinder part (along its local Y) in the object's own space.</summary>
    public void AddCylinder(Vector3 center, float radius, float halfHeight, Quaternion rotation) =>
        Add(1, center, new Vector3(radius, halfHeight, 0), rotation, []);

    /// <summary>Adds a convex part: the hull round four or more points, placed at center.</summary>
    public void AddHull(Vector3 center, ReadOnlySpan<Vector3> points, Quaternion rotation)
    {
        if (points.Length < 4)
            throw new ArgumentException("A hull needs four or more points.", nameof(points));
        var values = new float[points.Length * 3];
        for (int i = 0; i < points.Length; i++)
            (values[i * 3], values[i * 3 + 1], values[i * 3 + 2]) = (points[i].X, points[i].Y, points[i].Z);
        Add(2, center, default, rotation, values);
    }

    private void Add(int kind, Vector3 center, Vector3 a, Quaternion rotation, float[] points)
    {
        if (!Physics.AddCompoundPart(GameObject.SceneId, GameObject.Id, kind, center, a,
                new Vector4(rotation.X, rotation.Y, rotation.Z, rotation.W), points))
            throw ActionText.Missing(GameObject, "Compound Collider");
    }
}

internal static class PointBuffer
{
    /// <summary>Reads a soft body's points (what: 0 dents, 1 positions), which the engine writes as floats (x, y, z after
    /// one another), growing the buffer when needed.</summary>
    internal static Vector3[] Read(GameObject owner, string component, int what)
    {
        int copy(float[] values) => CSharpRopes.SoftPoints(owner.SceneId, owner.Id, what, values);
        float[] buffer = new float[96];
        int count = copy(buffer);
        if (count < 0)
            throw ActionText.Missing(owner, component);
        if (count > buffer.Length)
        {
            buffer = new float[count];
            count = copy(buffer);
        }
        var points = new Vector3[count / 3];
        for (int i = 0; i < points.Length; i++)
            points[i] = new Vector3(buffer[i * 3], buffer[i * 3 + 1], buffer[i * 3 + 2]);
        return points;
    }

    internal static float[] Flatten(ReadOnlySpan<Vector3> points)
    {
        var values = new float[points.Length * 3];
        for (int i = 0; i < points.Length; i++)
            (values[i * 3], values[i * 3 + 1], values[i * 3 + 2]) = (points[i].X, points[i].Y, points[i].Z);
        return values;
    }
}

public readonly partial record struct SoftBody
{
    /// <summary>A shell's dents: for each simulated vertex, how far it has been pushed from where it was made, in the
    /// object's own space (empty for other kinds). Save or send these and give them back with <see cref="SetDents"/>.</summary>
    public Vector3[] GetDents() =>
        PointBuffer.Read(GameObject, "Soft Body", 0);

    /// <summary>Dents a shell as <see cref="GetDents"/> gave them. In a session the server's dents are everyone's.</summary>
    public void SetDents(ReadOnlySpan<Vector3> dents)
    {
        if (!CSharpRopes.SetSoftPoints(GameObject.SceneId, GameObject.Id, 0, PointBuffer.Flatten(dents)))
            throw ActionText.Missing(GameObject, "Soft Body");
    }

    /// <summary>Where its simulated vertices are now, in the world.</summary>
    public Vector3[] Positions =>
        PointBuffer.Read(GameObject, "Soft Body", 1);

    /// <summary>Puts the simulated vertices at places in the world, still (as many as SimulatedVertexCount).</summary>
    public void SetPositions(ReadOnlySpan<Vector3> positions)
    {
        if (!CSharpRopes.SetSoftPoints(GameObject.SceneId, GameObject.Id, 1, PointBuffer.Flatten(positions)))
            throw ActionText.Missing(GameObject, "Soft Body");
    }

    /// <summary>Builds it again after its fields were changed while playing.</summary>
    public void Rebuild()
    {
        if (!CSharpRopes.Rebuild(GameObject.SceneId, GameObject.Id, 0))
            throw ActionText.Missing(GameObject, "Soft Body");
    }

    /// <summary>The physics bodies (<see cref="Rigidbody.BodyId"/>) its vertices touched since this was last asked.</summary>
    public uint[] TouchingBodies()
    {
        ulong[] buffer = new ulong[32];
        int count = CSharpRopes.Touching(GameObject.SceneId, GameObject.Id, buffer);
        if (count < 0)
            throw ActionText.Missing(GameObject, "Soft Body");
        if (count > buffer.Length)
        {
            buffer = new ulong[count];
            count = CSharpRopes.Touching(GameObject.SceneId, GameObject.Id, buffer);
        }
        var bodies = new uint[Math.Min(count, buffer.Length)];
        for (int i = 0; i < bodies.Length; i++)
            bodies[i] = (uint)buffer[i];
        return bodies;
    }
}

public readonly partial record struct Rope
{
    /// <summary>Ties a new rope between two objects (towing, lifting); the offsets are where on each it is tied,
    /// relative to it. Length below zero: as far apart as they are now, plus a little slack. Null on a client of a
    /// session: the server ties it, on every machine, when this player controls one of the two.</summary>
    public static Rope? Attach(GameObject from, GameObject to, Vector3 fromOffset = default, Vector3 toOffset = default,
        float length = -1, float thickness = 0.04f)
    {
        ulong id = CSharpRopes.Attach(from.SceneId, from.Id, to.Id, fromOffset, toOffset, length, thickness);
        return id == 0 ? null : new Rope(new GameObject(from.SceneId, id));
    }

    /// <summary>Whether it is pulled tight between its two ends.</summary>
    public bool IsTaut => State(0) != 0;

    /// <summary>How hard it pulls, in newtons.</summary>
    public float Pull => State(1);

    /// <summary>Ties its first end to an object (null: that end lets go and hangs free). Keeps its length.</summary>
    public void AttachStart(GameObject? to, Vector3 offset = default) => Tie(0, to, offset);

    /// <summary>Ties its other end to an object (null: it lets go). Keeps its length.</summary>
    public void AttachEnd(GameObject? to, Vector3 offset = default) => Tie(1, to, offset);

    /// <summary>Lets go of what its other end holds.</summary>
    public void Release() => Tie(1, null, default);

    /// <summary>Lays it along a path of world points from its start to its end (over a beam, round a post), as long
    /// as the path is.</summary>
    public void LayAlong(ReadOnlySpan<Vector3> path)
    {
        if (path.Length < 2)
            throw new ArgumentException("A path needs two or more points.", nameof(path));
        if (!CSharpRopes.RopeLayAlong(GameObject.SceneId, GameObject.Id, PointBuffer.Flatten(path)))
            throw ActionText.Missing(GameObject, "Rope");
    }

    /// <summary>Snaps it in two in the middle, as Break Force does: this rope keeps its first end, and the half
    /// returned keeps the other. Null on a client (the server snaps it everywhere).</summary>
    public Rope? Snap()
    {
        ulong id = CSharpRopes.RopeSnap(GameObject.SceneId, GameObject.Id);
        return id == 0 ? null : new Rope(new GameObject(GameObject.SceneId, id));
    }

    /// <summary>Makes the rope again from its fields, after changing them while it runs.</summary>
    public void Rebuild()
    {
        if (!CSharpRopes.Rebuild(GameObject.SceneId, GameObject.Id, 1))
            throw ActionText.Missing(GameObject, "Rope");
    }

    private float State(int what)
    {
        float value = CSharpRopes.RopeState(GameObject.SceneId, GameObject.Id, what);
        return float.IsNaN(value) ? throw ActionText.Missing(GameObject, "Rope") : value;
    }

    private void Tie(int end, GameObject? to, Vector3 offset)
    {
        if (!CSharpRopes.RopeTie(GameObject.SceneId, GameObject.Id, end, to?.Id ?? 0, offset))
            throw ActionText.Missing(GameObject, "Rope");
    }
}
