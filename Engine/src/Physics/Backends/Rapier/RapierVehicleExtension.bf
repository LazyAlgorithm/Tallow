using System;
using System.Collections;

namespace Tallow;

/// Rapier's ray-cast wheeled vehicle, behind the neutral PhysicsVehicleExtension. Rapier has no engine or gearbox of
/// its own, so a small automatic gearbox over the declared ratios turns the throttle into wheel forces. Motorcycles
/// and tracked vehicles are not implemented (the provider does not advertise them).
class RapierVehicleExtension : PhysicsVehicleExtension
{
	class Handle
	{
		public void* vehicle;
		public PhysicsVehicleKind kind;
		public bool inWorld = true;
	}

	RapierPhysicsBackendWorld mBackend;
	Dictionary<void*, Handle> mByVehicle = new .() ~
		{
			for (let (id, handle) in _)
			{
				if (mBackend != null && mBackend.NativeWorld != null && handle.vehicle != null)
					Rapier.tn_rapier_vehicle_destroy(mBackend.NativeWorld, handle.vehicle);
				delete handle;
			}
			delete _;
		};

	public this(RapierPhysicsBackendWorld backend)
	{
		mBackend = backend;
	}

	public override bool SupportsKind(PhysicsVehicleKind kind) => kind == .Wheeled;

	public override void WorldDestroyed()
	{
		if (mBackend != null && mBackend.NativeWorld != null)
		{
			for (let (id, handle) in mByVehicle)
			{
				if (handle.vehicle != null)
					Rapier.tn_rapier_vehicle_destroy(mBackend.NativeWorld, handle.vehicle);
				handle.vehicle = null;
			}
		}
		mByVehicle.Clear();
	}

	Handle From(void* vehicle)
	{
		Handle handle = null;
		if (vehicle != null)
			mByVehicle.TryGetValue(vehicle, out handle);
		return handle;
	}

	public override void* Create(uint32 chassisBodyId, PhysicsVehicleDesc desc)
	{
		if (mBackend == null || mBackend.NativeWorld == null || desc.wheels == null || desc.wheelCount <= 0)
			return null;
		if (desc.kind != .Wheeled)
			return null;

		RapierWheel[] wheels = new .[desc.wheelCount];
		defer delete wheels;
		let wheelMass = Math.Max(Rapier.tn_rapier_body_mass(mBackend.NativeWorld, chassisBodyId), 1.0f) / desc.wheelCount;
		for (int i < desc.wheelCount)
		{
			let source = desc.wheels[i];
			RapierWheel wheel = default;
			wheel.position = .(source.position.x, source.position.y, source.position.z);
			wheel.radius = source.radius;
			wheel.width = source.width;
			wheel.restLength = Math.Max(source.suspensionMaxLength, 0.05f);
			wheel.minLength = Math.Max(source.suspensionMinLength, 0.0f);
			// Rapier's ray-cast suspension uses normalized stiffness/damping (its defaults are tuned for a normal
			// car), not a newton-per-metre spring. Scale the defaults by the wheel's ride frequency and damping
			// ratio, and cap the force well above the weight each wheel carries.
			let frequency = Math.Max(source.suspensionFrequency, 0.1f);
			// Rapier's normalized spring is calibrated to its travel: a shorter suspension needs a stiffer number.
			let travel = Math.Max(source.suspensionMaxLength - source.suspensionMinLength, 0.05f);
			let stiffness = Math.Clamp(0.13f / (travel * travel) * Math.Clamp(frequency / 1.5f, 0.6f, 2.0f), 0.2f, 8.0f);
			wheel.stiffness = stiffness;
			wheel.compression = 0.83f;
			wheel.damping = Math.Clamp(0.88f + (Math.Max(source.suspensionDamping, 0.0f) - 0.5f) * 1.2f, 0.6f, 2.5f);
			wheel.maxForce = Math.Max(8000.0f, wheelMass * 9.81f * 2.5f);
			wheel.maxSteerRadians = Math.Max(source.maxSteerAngleRadians, 0);
			wheel.maxBrakeTorque = Math.Max(source.maxBrakeTorque, 0);
			wheel.maxHandBrakeTorque = Math.Max(source.maxHandBrakeTorque, 0);
			wheel.driven = source.driven ? 1 : 0;
			wheel.steers = source.maxSteerAngleRadians > 0.0001f ? 1 : 0;
			wheels[i] = wheel;
		}
		float[3] up = .(desc.up.x, desc.up.y, desc.up.z);
		float[3] forward = .(desc.forward.x, desc.forward.y, desc.forward.z);
		float[5] gears = desc.gearRatios;
		let vehicle = Rapier.tn_rapier_vehicle_create(mBackend.NativeWorld, chassisBodyId, wheels.Ptr, desc.wheelCount,
			&up, &forward, desc.maxTorque, desc.minRPM, desc.maxRPM, &gears, desc.gearCount, desc.reverseRatio);
		if (vehicle == null)
			return null;
		let handle = new Handle();
		handle.vehicle = vehicle;
		handle.kind = desc.kind;
		mByVehicle[vehicle] = handle;
		return vehicle;
	}

	public override void Destroy(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle == null)
			return;
		if (mBackend != null && mBackend.NativeWorld != null && handle.vehicle != null)
			Rapier.tn_rapier_vehicle_destroy(mBackend.NativeWorld, handle.vehicle);
		mByVehicle.Remove(vehicle);
		delete handle;
	}

	public override void AddToWorld(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle != null)
			handle.inWorld = true;
	}

	public override void RemoveFromWorld(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle != null)
			handle.inWorld = false;
	}

	public override void SetDriverInput(void* vehicle, float forward, float right, float brake, float handBrake)
	{
		let handle = From(vehicle);
		if (handle != null && mBackend != null && mBackend.NativeWorld != null && handle.vehicle != null)
			Rapier.tn_rapier_vehicle_set_input(mBackend.NativeWorld, handle.vehicle, forward, right, brake, handBrake);
	}

	public override int32 WheelCount(void* vehicle)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_wheel_count(mBackend.NativeWorld, handle.vehicle) : 0;
	}

	public override bool WheelContact(void* vehicle, int32 wheel, out Vector3 point, out Vector3 normal, out uint32 bodyId)
	{
		point = default;
		normal = default;
		bodyId = uint32.MaxValue;
		let handle = From(vehicle);
		if (handle == null || handle.vehicle == null)
			return false;
		float[3] p = default;
		float[3] n = default;
		if (Rapier.tn_rapier_vehicle_wheel_contact(mBackend.NativeWorld, handle.vehicle, wheel, &p, &n, &bodyId) == 0)
			return false;
		point = .(p[0], p[1], p[2]);
		normal = .(n[0], n[1], n[2]);
		return true;
	}

	public override float WheelSuspensionLength(void* vehicle, int32 wheel)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_suspension(mBackend.NativeWorld, handle.vehicle, wheel) : 0;
	}

	public override float WheelRotationAngle(void* vehicle, int32 wheel)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_wheel_rotation(mBackend.NativeWorld, handle.vehicle, wheel) : 0;
	}

	public override float WheelSteerAngle(void* vehicle, int32 wheel)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_wheel_steer(mBackend.NativeWorld, handle.vehicle, wheel) : 0;
	}

	public override Matrix4 WheelWorldTransform(void* vehicle, int32 wheel)
	{
		let handle = From(vehicle);
		if (handle == null || handle.vehicle == null)
			return .Identity;
		float[16] matrix = default;
		float spin = 0;
		Rapier.tn_rapier_vehicle_wheel_transform(mBackend.NativeWorld, handle.vehicle, wheel, &matrix, &spin);
		Matrix4 result = default;
		for (int i < 16)
			result.m[i] = matrix[i];
		return result;
	}

	public override float EngineRPM(void* vehicle)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_engine_rpm(mBackend.NativeWorld, handle.vehicle) : 0;
	}

	public override int32 CurrentGear(void* vehicle)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_gear(mBackend.NativeWorld, handle.vehicle) : 0;
	}

	public override float CurrentRatio(void* vehicle)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_ratio(mBackend.NativeWorld, handle.vehicle) : 0;
	}

	public override float WheelAngularVelocity(void* vehicle, int32 wheel)
	{
		let handle = From(vehicle);
		return handle != null && handle.vehicle != null ? Rapier.tn_rapier_vehicle_wheel_speed(mBackend.NativeWorld, handle.vehicle, wheel) : 0;
	}
}
