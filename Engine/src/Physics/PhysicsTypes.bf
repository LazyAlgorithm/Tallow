using System;
using System.Collections;

namespace Tallow;

/// How a body takes part in the simulation.
[Reflect(.All)]
enum PhysicsMotion : int32
{
	Static,
	Kinematic,
	Dynamic
}

/// One raw ray hit a backend reports. Engine-facing RaycastHit adds the object, normal and part details.
[CRepr]
struct PhysicsRayHit
{
	public uint32 bodyId;
	public float fraction;
	public uint32 subShapeId;
}

/// One raw shape hit a backend reports. Engine-facing ShapeCastHit adds the object and distance.
[CRepr]
struct PhysicsShapeHit
{
	public uint32 bodyId;
	public float fraction;
	public Vector3 point;
	public Vector3 normal;
	public float penetrationDepth;
	public uint32 subShapeId;
}

/// What a backend's body id and sub-shape id mean for a compound or mesh shape.
[CRepr]
struct PhysicsHitDetail
{
	public Vector3 normal;
	public int32 part;
	public int32 triangle;
}

/// One body a character's last move touched. Engine-facing CharacterHits copies these into its own span.
[CRepr]
struct CharacterHit
{
	public uint32 body;
	public uint32 reserved;
	public uint64 userData;
	public Vector3 point;
	public Vector3 normal;
}

/// Where a character is, how it moves and what it stands on.
[CRepr]
struct CharacterState
{
	public Vector3 position;
	public Vector3 velocity;
	public Vector3 groundNormal;
	public Vector3 groundVelocity;
	/// 0 on ground, 1 on ground too steep to stand on, 2 touching but not supported, 3 in the air.
	public int32 groundState;
	public uint32 groundBody;
}

/// One contact beginning, staying or ending, in engine-neutral terms.
[CRepr]
struct PhysicsContactEvent
{
	public uint32 bodyA, bodyB;
	public uint64 objectA, objectB;
	/// 0: began touching; 1: stopped; 2: still touching.
	public int32 kind;
	/// 1 when one of the two is a trigger.
	public int32 sensor;
	public Vector3 point;
	/// From A towards B.
	public Vector3 normal;
	public float speed;
	public float reserved;
}

/// Everything a backend needs to make a body, independent of its library.
[CRepr]
struct PhysicsBodyDesc
{
	public PhysicsMotion motion;
	public Vector3 position;
	public Quaternion rotation;
	/// The backend's object/layer code (motion class, project layer and world group packed together).
	public uint32 objectCode;
	public bool sensor;
	public bool debris;
	public bool continuousCollision;
	public bool freezeRotation;
	public bool allowSleeping;
	public float friction;
	public float restitution;
	public float linearDamping;
	public float angularDamping;
	/// 0 when gravity is off for this body.
	public float gravityFactor;
	/// Whether mass overrides the shape's own; false leaves the backend's default.
	public bool overrideMass;
	public float mass;
	public uint64 userData;
	/// uint32.MaxValue to let the backend choose; otherwise the body id to use (lockstep).
	public uint32 wantedId;
}

/// Which joint to make.
[Reflect(.All)]
enum PhysicsJointKind : int32
{
	Ball, Hinge, Slider }

/// Which joint to make and the points it connects.
[CRepr]
struct PhysicsJointDesc
{
	public PhysicsJointKind kind;
	public uint32 bodyA, bodyB;
	public Vector3 anchor;
	public Vector3 axis;
	public Vector3 childAnchor;
	public Vector3 childAxis;
	public Vector3 childNormal;
	/// Ball: how far the second body may swing from axis. Zero is a free ball joint.
	public float swingLimitRadians;
	/// Slider: travel either way.
	public float travel;
}

/// Everything a backend needs to make a character.
[CRepr]
struct PhysicsCharacterDesc
{
	public Vector3 position;
	public Quaternion rotation;
	public float maxSlopeRadians;
	public float mass;
	public float pushStrength;
	public float supportHeight;
	public uint32 objectCode;
	public uint64 userData;
	public bool innerBody;
	public bool soft;
}

/// Capacity, gravity and quality settings a backend world is made with.
[CRepr]
struct PhysicsWorldSettings
{
	public int32 bodyCapacity;
	public int32 bodyPairCapacity;
	public int32 contactCapacity;
	public Vector3 gravity;
	public float lengthScale;
	public float minimumShapeExtent;
	public bool contactEvents;
	/// How many world states are kept apart (0 when they are not).
	public int32 separateWorldStates;
}
