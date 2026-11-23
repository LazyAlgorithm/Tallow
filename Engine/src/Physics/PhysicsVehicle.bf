using System;
using System.Collections;

namespace Tallow;

/// The kinds of vehicle a backend can provide. A backend advertises only the kinds it implements.
[Reflect(.All)]
enum PhysicsVehicleKind : int32
{
	Wheeled,
	Motorcycle,
	Tracked
}

static class PhysicsVehicleKinds
{
	public static PhysicsFeature Feature(PhysicsVehicleKind kind)
	{
		switch (kind)
		{
		case .Wheeled: return .WheeledVehicles;
		case .Motorcycle: return .MotorcycleVehicles;
		case .Tracked: return .TrackedVehicles;
		}
	}

	public static StringView Name(PhysicsVehicleKind kind)
	{
		switch (kind)
		{
		case .Wheeled: return "Wheeled";
		case .Motorcycle: return "Motorcycle";
		case .Tracked: return "Tracked";
		}
	}
}

/// One wheel of a backend vehicle, in the chassis body's local space.
[CRepr]
struct PhysicsWheelDesc
{
	public Vector3 position;
	public float radius, width;
	public float suspensionMinLength, suspensionMaxLength, suspensionPreloadLength;
	public float suspensionFrequency, suspensionDamping;
	/// 0 for a wheel that does not steer.
	public float maxSteerAngleRadians;
	public float maxBrakeTorque, maxHandBrakeTorque;
	public float inertia, angularDamping;
	/// Whether the engine may drive this wheel. Driven wheels are paired into differentials.
	public bool driven;
}

/// What a backend needs to make a vehicle on a chassis body. Wheeled and motorcycle use every wheel; tracked reads
/// leftTrackDrivenWheel/rightTrackDrivenWheel and the track settings.
[CRepr]
struct PhysicsVehicleDesc
{
	public PhysicsVehicleKind kind;
	public PhysicsWheelDesc* wheels;
	public int32 wheelCount;
	public Vector3 up;
	public Vector3 forward;
	public float maxPitchRollAngle;
	public float maxTorque, minRPM, maxRPM, engineInertia, engineAngularDamping;
	public float[5] gearRatios;
	public int32 gearCount;
	public float reverseRatio;
	public bool antiRollBars;
	public uint32 objectCode;
	// Motorcycle.
	public float maxLeanAngleRadians;
	// Tracked: index of the driven wheel in each track, and the track's own settings.
	public int32 leftTrackDrivenWheel, rightTrackDrivenWheel;
	public float trackInertia, trackAngularDamping, trackMaxBrakeTorque, trackDifferentialRatio;
}

/// The optional vehicle half of a physics backend. Jolt's VehicleConstraint (wheeled/motorcycle/tracked) is the first
/// implementation; another backend can build vehicles from its own wheel joints and suspension.
abstract class PhysicsVehicleExtension
{
	/// Whether this integration implements a kind. The engine also checks the backend's feature bits; this lets a
	/// backend opt in to only some kinds without implementing all three.
	public virtual bool SupportsKind(PhysicsVehicleKind kind) => kind == .Wheeled;

	public abstract void WorldDestroyed();
	public abstract void* Create(uint32 chassisBodyId, PhysicsVehicleDesc desc);
	public abstract void Destroy(void* vehicle);
	public abstract void AddToWorld(void* vehicle);
	public abstract void RemoveFromWorld(void* vehicle);
	/// forward: -1..1, right: -1..1, brake: 0..1, handBrake: 0..1.
	public abstract void SetDriverInput(void* vehicle, float forward, float right, float brake, float handBrake);
	public abstract int32 WheelCount(void* vehicle);
	public abstract bool WheelContact(void* vehicle, int32 wheel, out Vector3 point, out Vector3 normal, out uint32 bodyId);
	public abstract float WheelSuspensionLength(void* vehicle, int32 wheel);
	public abstract float WheelRotationAngle(void* vehicle, int32 wheel);
	public abstract float WheelSteerAngle(void* vehicle, int32 wheel);
	public abstract Matrix4 WheelWorldTransform(void* vehicle, int32 wheel);
	public abstract float EngineRPM(void* vehicle);
	public abstract int32 CurrentGear(void* vehicle);
	public abstract float CurrentRatio(void* vehicle);
	public abstract float WheelAngularVelocity(void* vehicle, int32 wheel);
}
