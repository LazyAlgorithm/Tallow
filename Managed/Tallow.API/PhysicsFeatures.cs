using System;

namespace Tallow;

/// What the scene's selected physics backend supports. Keep these bit values in sync with
/// Engine/src/Physics/PhysicsFeatures.bf (physics backends are selected per project, not per scene).
[Flags]
public enum PhysicsFeature : ulong
{
    None = 0,
    RigidBodies = 1UL << 0,
    KinematicBodies = 1UL << 1,
    Sensors = 1UL << 2,
    ContinuousCollision = 1UL << 3,
    Sleeping = 1UL << 4,
    FreezeRotation = 1UL << 5,
    Debris = 1UL << 6,
    BoxShape = 1UL << 7,
    SphereShape = 1UL << 8,
    CapsuleShape = 1UL << 9,
    CylinderShape = 1UL << 10,
    ConvexHullShape = 1UL << 11,
    MeshShape = 1UL << 12,
    CompoundShape = 1UL << 13,
    BallJoint = 1UL << 14,
    SwingLimit = 1UL << 15,
    HingeJoint = 1UL << 16,
    HingeMotor = 1UL << 17,
    SliderJoint = 1UL << 18,
    SliderSpring = 1UL << 19,
    CharacterController = 1UL << 20,
    CharacterPush = 1UL << 21,
    Raycast = 1UL << 22,
    RaycastAll = 1UL << 23,
    ShapeCast = 1UL << 24,
    Overlap = 1UL << 25,
    Check = 1UL << 26,
    ContactEvents = 1UL << 27,
    ContactStay = 1UL << 28,
    TriggerEvents = 1UL << 29,
    SoftBodies = 1UL << 30,
    SoftBodyDents = 1UL << 31,
    SoftBodyPressure = 1UL << 32,
    SoftBodySkin = 1UL << 33,
    Ropes = 1UL << 34,
    RopePulleys = 1UL << 35,
    RopeKnots = 1UL << 36,
    BuoyancyRigidBodies = 1UL << 37,
    BuoyancySoftBodies = 1UL << 38,
    WorldStatesSeparated = 1UL << 39,
    NavigationGeometry = 1UL << 40,
    SaveRestoreExact = 1UL << 41,
    SharedPhysicsState = 1UL << 42,
    CrossPlatformDeterminism = 1UL << 43,
    FixedBodyIds = 1UL << 44,
    MultipleWorlds = 1UL << 45,
    Ragdolls = 1UL << 46,
    Vehicles = 1UL << 47,
    WheeledVehicles = 1UL << 48,
    MotorcycleVehicles = 1UL << 49,
    TrackedVehicles = 1UL << 50,
    /// <summary>Soft bodies can tear when pulled too hard (Rapier only).</summary>
    SoftBodyTearing = 1UL << 51,
}

public static unsafe partial class Physics
{
    /// The features the scene's selected 3D physics backend supports.
    public static PhysicsFeature Features(ulong session) => (PhysicsFeature)FeatureBits(session);

    /// Whether every named feature is available in the scene's selected backend.
    public static bool Supports(ulong session, PhysicsFeature features) => Supports(session, (ulong)features);
}
