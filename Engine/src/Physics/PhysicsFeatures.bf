using System;
using System.Collections;

namespace Tallow;

/// What a physics integration supports. These describe the integration, not the raw library: a feature is set only
/// when Tallow's component semantics for it work and have passed conformance.
///
/// 2D has its own enum when the 2D front end lands; do not pack 2D features into this bit space.
enum PhysicsFeature : uint64
{
	None = 0,
	RigidBodies = (uint64)1 << 0,
	KinematicBodies = (uint64)1 << 1,
	Sensors = (uint64)1 << 2,
	ContinuousCollision = (uint64)1 << 3,
	Sleeping = (uint64)1 << 4,
	FreezeRotation = (uint64)1 << 5,
	Debris = (uint64)1 << 6,
	BoxShape = (uint64)1 << 7,
	SphereShape = (uint64)1 << 8,
	CapsuleShape = (uint64)1 << 9,
	CylinderShape = (uint64)1 << 10,
	ConvexHullShape = (uint64)1 << 11,
	MeshShape = (uint64)1 << 12,
	CompoundShape = (uint64)1 << 13,
	BallJoint = (uint64)1 << 14,
	SwingLimit = (uint64)1 << 15,
	HingeJoint = (uint64)1 << 16,
	HingeMotor = (uint64)1 << 17,
	SliderJoint = (uint64)1 << 18,
	SliderSpring = (uint64)1 << 19,
	CharacterController = (uint64)1 << 20,
	CharacterPush = (uint64)1 << 21,
	Raycast = (uint64)1 << 22,
	RaycastAll = (uint64)1 << 23,
	ShapeCast = (uint64)1 << 24,
	Overlap = (uint64)1 << 25,
	Check = (uint64)1 << 26,
	ContactEvents = (uint64)1 << 27,
	ContactStay = (uint64)1 << 28,
	TriggerEvents = (uint64)1 << 29,
	SoftBodies = (uint64)1 << 30,
	SoftBodyDents = (uint64)1 << 31,
	SoftBodyPressure = (uint64)1 << 32,
	SoftBodySkin = (uint64)1 << 33,
	Ropes = (uint64)1 << 34,
	RopePulleys = (uint64)1 << 35,
	RopeKnots = (uint64)1 << 36,
	BuoyancyRigidBodies = (uint64)1 << 37,
	BuoyancySoftBodies = (uint64)1 << 38,
	WorldStatesSeparated = (uint64)1 << 39,
	NavigationGeometry = (uint64)1 << 40,
	SaveRestoreExact = (uint64)1 << 41,
	SharedPhysicsState = (uint64)1 << 42,
	CrossPlatformDeterminism = (uint64)1 << 43,
	FixedBodyIds = (uint64)1 << 44,
	MultipleWorlds = (uint64)1 << 45,
	/// A backend-provided ragdoll (Jolt's built-in, or another engine's articulation/joint ragdoll).
	Ragdolls = (uint64)1 << 46,
	/// Any vehicles driven through the backend.
	Vehicles = (uint64)1 << 47,
	/// A conventional wheeled vehicle.
	WheeledVehicles = (uint64)1 << 48,
	/// A motorcycle (a wheeled vehicle with lean control).
	MotorcycleVehicles = (uint64)1 << 49,
	/// A tracked vehicle (two tracks, no steering wheels).
	TrackedVehicles = (uint64)1 << 50,
	// 51..63 reserved for future 3D features
}

/// A set of PhysicsFeature bits.
[CRepr]
struct PhysicsFeatures
{
	public uint64 bits;

	public this(uint64 bits)
	{
		this.bits = bits;
	}

	public this(PhysicsFeature feature)
	{
		bits = (uint64)feature;
	}

	public bool Has(PhysicsFeature feature) => (bits & (uint64)feature) != 0;
	public bool HasAll(PhysicsFeatures other) => (bits & other.bits) == other.bits;
	public bool IsEmpty => bits == 0;

	public static PhysicsFeatures operator |(PhysicsFeatures a, PhysicsFeatures b) => .(a.bits | b.bits);
	public static PhysicsFeatures operator &(PhysicsFeatures a, PhysicsFeatures b) => .(a.bits & b.bits);
	public static PhysicsFeatures operator ~(PhysicsFeatures a) => .(~a.bits);
	public static implicit operator PhysicsFeatures(PhysicsFeature feature) => .(feature);

	public static PhysicsFeatures None => .(0);
	public static PhysicsFeatures All => .(~(uint64)0);

	/// The name used in editor capability lists and diagnostics.
	public static StringView Name(PhysicsFeature feature)
	{
		switch (feature)
		{
		case .RigidBodies: return "Rigid bodies";
		case .KinematicBodies: return "Kinematic bodies";
		case .Sensors: return "Sensors";
		case .ContinuousCollision: return "Continuous collision";
		case .Sleeping: return "Sleeping";
		case .FreezeRotation: return "Freeze rotation";
		case .Debris: return "Debris filtering";
		case .BoxShape: return "Box shapes";
		case .SphereShape: return "Sphere shapes";
		case .CapsuleShape: return "Capsule shapes";
		case .CylinderShape: return "Cylinder shapes";
		case .ConvexHullShape: return "Convex hull shapes";
		case .MeshShape: return "Mesh shapes";
		case .CompoundShape: return "Compound shapes";
		case .BallJoint: return "Ball joints";
		case .SwingLimit: return "Swing limits";
		case .HingeJoint: return "Hinges";
		case .HingeMotor: return "Hinge motors";
		case .SliderJoint: return "Sliders";
		case .SliderSpring: return "Slider springs";
		case .CharacterController: return "Character controllers";
		case .CharacterPush: return "Characters push bodies";
		case .Raycast: return "Raycasts";
		case .RaycastAll: return "All-hits raycasts";
		case .ShapeCast: return "Shape casts";
		case .Overlap: return "Overlaps";
		case .Check: return "Overlap checks";
		case .ContactEvents: return "Contact events";
		case .ContactStay: return "Contact stay events";
		case .TriggerEvents: return "Trigger events";
		case .SoftBodies: return "Soft bodies";
		case .SoftBodyDents: return "Soft body dents";
		case .SoftBodyPressure: return "Soft body pressure";
		case .SoftBodySkin: return "Soft body skinning";
		case .Ropes: return "Ropes";
		case .RopePulleys: return "Rope pulleys";
		case .RopeKnots: return "Rope knots";
		case .BuoyancyRigidBodies: return "Rigid body buoyancy";
		case .BuoyancySoftBodies: return "Soft body buoyancy";
		case .WorldStatesSeparated: return "Separated world states";
		case .NavigationGeometry: return "Navigation geometry";
		case .SaveRestoreExact: return "Exact save/restore";
		case .SharedPhysicsState: return "Shared physics state";
		case .CrossPlatformDeterminism: return "Cross-platform determinism";
		case .FixedBodyIds: return "Fixed body ids";
		case .MultipleWorlds: return "Multiple worlds";
		case .Ragdolls: return "Ragdolls";
		case .Vehicles: return "Vehicles";
		case .WheeledVehicles: return "Wheeled vehicles";
		case .MotorcycleVehicles: return "Motorcycles";
		case .TrackedVehicles: return "Tracked vehicles";
		default: break;
		}
		return "Unknown";
	}

	/// Appends a readable list of the set features, for editor and log output.
	public void AppendNames(String text)
	{
		bool first = true;
		for (int32 i = 0; i < 64; i++)
		{
			let bit = (PhysicsFeature)((uint64)1 << i);
			if (!Has(bit))
				continue;
			if (!first)
				text.Append(", ");
			text.Append(Name(bit));
			first = false;
		}
	}
}
