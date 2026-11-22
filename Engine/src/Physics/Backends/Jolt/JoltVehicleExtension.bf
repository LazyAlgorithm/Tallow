using System;
using System.Collections;

namespace Tallow;

/// Jolt's VehicleConstraint (wheeled vehicle controller), behind the neutral PhysicsVehicleExtension. Only the
/// wheeled controller is exposed here; the same structure can grow motorcycle/tracked variants.
class JoltVehicleExtension : PhysicsVehicleExtension
{
	[CRepr]
	struct JPH_ConstraintSettings
	{
		public uint8 enabled;
		public uint32 constraintPriority;
		public uint32 numVelocityStepsOverride;
		public uint32 numPositionStepsOverride;
		public float drawConstraintSize;
		public uint64 userData;
	}

	[CRepr]
	struct JPH_SpringSettings
	{
		public int32 mode;
		public float frequencyOrStiffness;
		public float damping;
	}

	[CRepr]
	struct JPH_VehicleAntiRollBar
	{
		public int32 leftWheel;
		public int32 rightWheel;
		public float stiffness;
	}

	[CRepr]
	struct JPH_VehicleConstraintSettings
	{
		public JPH_ConstraintSettings common;
		public Vector3 up;
		public Vector3 forward;
		public float maxPitchRollAngle;
		public uint32 wheelsCount;
		public void** wheels;
		public uint32 antiRollBarsCount;
		public JPH_VehicleAntiRollBar* antiRollBars;
		public void* controller;
	}

	[CRepr]
	struct JPH_VehicleEngineSettings
	{
		public float maxTorque;
		public float minRPM;
		public float maxRPM;
		public void* normalizedTorque;
		public float inertia;
		public float angularDamping;
	}

	[CRepr]
	struct JPH_VehicleTrackSettings
	{
		public uint32 drivenWheel;
		public uint32* wheels;
		public uint32 wheelsCount;
		public float inertia;
		public float angularDamping;
		public float maxBrakeTorque;
		public float differentialRatio;
	}

	static class Native
	{
		[CLink] public static extern void* JPH_PhysicsSystem_GetBodyPtr(void* system, uint32 bodyId);
		[CLink] public static extern void JPH_PhysicsSystem_AddConstraint(void* system, void* constraint);
		[CLink] public static extern void JPH_PhysicsSystem_RemoveConstraint(void* system, void* constraint);
		[CLink] public static extern void JPH_PhysicsSystem_AddStepListener(void* system, void* listener);
		[CLink] public static extern void JPH_PhysicsSystem_RemoveStepListener(void* system, void* listener);
		[CLink] public static extern void JPH_Constraint_Destroy(void* constraint);
		[CLink] public static extern void JPH_VehicleConstraintSettings_Init(JPH_VehicleConstraintSettings* settings);
		[CLink] public static extern void* JPH_VehicleConstraint_Create(void* body, JPH_VehicleConstraintSettings* settings);
		[CLink] public static extern void* JPH_VehicleConstraint_AsPhysicsStepListener(void* constraint);
		[CLink] public static extern void* JPH_VehicleConstraint_GetController(void* constraint);
		[CLink] public static extern uint32 JPH_VehicleConstraint_GetWheelsCount(void* constraint);
		[CLink] public static extern void* JPH_VehicleConstraint_GetWheel(void* constraint, uint32 index);
		[CLink] public static extern void JPH_VehicleConstraint_GetWheelWorldTransform(void* constraint, uint32 index, Vector3* wheelRight, Vector3* wheelUp, Matrix4* result);
		[CLink] public static extern void* JPH_VehicleCollisionTesterCastSphere_Create(uint32 layer, float radius, Vector3* up, float maxSlopeAngle);
		[CLink] public static extern void JPH_VehicleCollisionTester_Destroy(void* tester);
		[CLink] public static extern void JPH_VehicleConstraint_SetVehicleCollisionTester(void* constraint, void* tester);
		[CLink] public static extern void* JPH_WheelSettingsWV_Create();
		[CLink] public static extern void* JPH_WheelSettingsTV_Create();
		[CLink] public static extern void JPH_WheelSettingsTV_SetLongitudinalFriction(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettingsTV_SetLateralFriction(void* settings, float value);
		[CLink] public static extern void* JPH_MotorcycleControllerSettings_Create();
		[CLink] public static extern void JPH_MotorcycleControllerSettings_SetMaxLeanAngle(void* settings, float value);
		[CLink] public static extern void JPH_MotorcycleControllerSettings_SetLeanSpringConstant(void* settings, float value);
		[CLink] public static extern void JPH_MotorcycleControllerSettings_SetLeanSpringDamping(void* settings, float value);
		[CLink] public static extern void JPH_MotorcycleControllerSettings_SetLeanSpringIntegrationCoefficient(void* settings, float value);
		[CLink] public static extern void JPH_MotorcycleControllerSettings_SetLeanSpringIntegrationCoefficientDecay(void* settings, float value);
		[CLink] public static extern void JPH_MotorcycleControllerSettings_SetLeanSmoothingFactor(void* settings, float value);
		[CLink] public static extern void* JPH_TrackedVehicleControllerSettings_Create();
		[CLink] public static extern void JPH_TrackedVehicleControllerSettings_SetEngine(void* settings, JPH_VehicleEngineSettings* value);
		[CLink] public static extern void JPH_TrackedVehicleControllerSettings_SetTransmission(void* settings, void* transmission);
		[CLink] public static extern void JPH_TrackedVehicleControllerSettings_SetTrack(void* settings, uint32 index, JPH_VehicleTrackSettings* track);
		[CLink] public static extern void JPH_VehicleTrackSettings_Init(JPH_VehicleTrackSettings* settings);
		[CLink] public static extern void JPH_TrackedVehicleController_SetDriverInput(void* controller, float forward, float leftRatio, float rightRatio, float brake);
		[CLink] public static extern void* JPH_TrackedVehicleController_GetEngine(void* controller);
		[CLink] public static extern void* JPH_TrackedVehicleController_GetTransmission(void* controller);
		[CLink] public static extern void JPH_WheelSettings_Destroy(void* settings);
		[CLink] public static extern void JPH_WheelSettings_SetPosition(void* settings, Vector3* value);
		[CLink] public static extern void JPH_WheelSettings_SetSuspensionMinLength(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettings_SetSuspensionMaxLength(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettings_SetSuspensionPreloadLength(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettings_SetSuspensionSpring(void* settings, JPH_SpringSettings* value);
		[CLink] public static extern void JPH_WheelSettings_SetRadius(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettings_SetWidth(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettingsWV_SetInertia(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettingsWV_SetAngularDamping(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettingsWV_SetMaxSteerAngle(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettingsWV_SetMaxBrakeTorque(void* settings, float value);
		[CLink] public static extern void JPH_WheelSettingsWV_SetMaxHandBrakeTorque(void* settings, float value);
		[CLink] public static extern void* JPH_WheelSettingsWV_GetLongitudinalFriction(void* settings);
		[CLink] public static extern uint32 JPH_LinearCurve_GetPointCount(void* curve);
		[CLink] public static extern float JPH_LinearCurve_GetValue(void* curve, float x);
		[CLink] public static extern void* JPH_WheeledVehicleControllerSettings_Create();
		[CLink] public static extern void JPH_VehicleControllerSettings_Destroy(void* settings);
		[CLink] public static extern void JPH_WheeledVehicleControllerSettings_SetEngine(void* settings, JPH_VehicleEngineSettings* value);
		[CLink] public static extern void JPH_WheeledVehicleControllerSettings_SetTransmission(void* settings, void* transmission);
		[CLink] public static extern void JPH_WheeledVehicleControllerSettings_AddDifferential(void* settings, int32 left, int32 right);
		[CLink] public static extern void* JPH_VehicleTransmissionSettings_Create();
		[CLink] public static extern void JPH_VehicleTransmissionSettings_Destroy(void* settings);
		[CLink] public static extern void JPH_VehicleTransmissionSettings_SetGearRatios(void* settings, float* values, uint32 count);
		[CLink] public static extern void JPH_VehicleTransmissionSettings_SetReverseGearRatios(void* settings, float* values, uint32 count);
		[CLink] public static extern void JPH_VehicleTransmissionSettings_SetShiftUpRPM(void* settings, float value);
		[CLink] public static extern void JPH_VehicleTransmissionSettings_SetShiftDownRPM(void* settings, float value);
		[CLink] public static extern void JPH_VehicleTransmissionSettings_SetClutchStrength(void* settings, float value);
		[CLink] public static extern void JPH_VehicleEngineSettings_Init(JPH_VehicleEngineSettings* settings);
		[CLink] public static extern void JPH_VehicleAntiRollBar_Init(JPH_VehicleAntiRollBar* bar);
		[CLink] public static extern void JPH_WheeledVehicleController_SetDriverInput(void* controller, float forward, float right, float brake, float handBrake);
		[CLink] public static extern void JPH_WheeledVehicleController_SetTireMaxImpulseCallback(void* controller, function void(void*, uint32, float*, float*, float, float, float, float, float, float) callback, void* user);
		[CLink] public static extern bool JPH_Wheel_HasContact(void* wheel);
		[CLink] public static extern uint32 JPH_Wheel_GetContactBodyID(void* wheel);
		[CLink] public static extern void JPH_Wheel_GetContactPosition(void* wheel, Vector3* result);
		[CLink] public static extern void JPH_Wheel_GetContactNormal(void* wheel, Vector3* result);
		[CLink] public static extern float JPH_Wheel_GetSuspensionLength(void* wheel);
		[CLink] public static extern float JPH_Wheel_GetRotationAngle(void* wheel);
		[CLink] public static extern float JPH_Wheel_GetSteerAngle(void* wheel);
		[CLink] public static extern void* JPH_WheeledVehicleController_GetEngine(void* controller);
		[CLink] public static extern float JPH_VehicleEngine_GetCurrentRPM(void* engine);
		[CLink] public static extern void* JPH_WheeledVehicleController_GetTransmission(void* controller);
		[CLink] public static extern int32 JPH_VehicleTransmission_GetCurrentGear(void* transmission);
		[CLink] public static extern float JPH_VehicleTransmission_GetCurrentRatio(void* transmission);
		[CLink] public static extern float JPH_Wheel_GetAngularVelocity(void* wheel);
	}

	class Handle
	{
		public void* constraint;
		public void* collisionTester;
		public PhysicsVehicleKind kind;
		public bool inWorld;
	}

	JoltPhysicsBackendWorld mWorld;
	void* mSystem;
	Dictionary<void*, Handle> mByConstraint = new .() ~ delete _;

	public this(JoltPhysicsBackendWorld world, void* system)
	{
		mWorld = world;
		mSystem = system;
	}

	static void TireImpulse(void* user, uint32 wheel, float* outLongitudinal, float* outLateral, float suspensionImpulse,
		float longitudinalFriction, float lateralFriction, float longitudinalSlip, float lateralSlip, float deltaTime)
	{
		*outLongitudinal = 10.0f * longitudinalFriction * suspensionImpulse;
		*outLateral = lateralFriction * suspensionImpulse;
	}

	Handle From(void* vehicle)
	{
		if (vehicle == null)
			return null;
		Handle handle;
		return mByConstraint.TryGetValue(vehicle, out handle) ? handle : null;
	}

	public override bool SupportsKind(PhysicsVehicleKind kind) => true;

	public override void WorldDestroyed()
	{
		List<Handle> live = scope .();
		live.AddRange(mByConstraint.Values);
		for (let handle in live)
			DestroyHandle(handle);
	}

	public override void* Create(uint32 chassisBodyId, PhysicsVehicleDesc desc)
	{
		if (mSystem == null || desc.wheels == null || desc.wheelCount <= 0)
			return null;
		let body = Native.JPH_PhysicsSystem_GetBodyPtr(mSystem, chassisBodyId);
		if (body == null)
			return null;

		JPH_VehicleConstraintSettings settings = default;
		Native.JPH_VehicleConstraintSettings_Init(&settings);
		settings.up = desc.up.LengthSquared > 0 ? desc.up.Normalized : Vector3.Up;
		settings.forward = desc.forward.LengthSquared > 0 ? desc.forward.Normalized : Vector3.Forward;
		settings.maxPitchRollAngle = desc.maxPitchRollAngle > 0 ? desc.maxPitchRollAngle : Mathf.Deg2Rad * 45;

		bool tracked = desc.kind == .Tracked;
		void*[] wheels = new .[desc.wheelCount];
		defer
		{
			for (let wheel in wheels)
			{
				if (wheel != null)
					Native.JPH_WheelSettings_Destroy(wheel);
			}
			delete wheels;
		}
		for (int32 i = 0; i < desc.wheelCount; i++)
		{
			let source = desc.wheels[i];
			let wheel = tracked ? Native.JPH_WheelSettingsTV_Create() : Native.JPH_WheelSettingsWV_Create();
			wheels[i] = wheel;
			var position = source.position;
			JPH_SpringSettings spring = default;
			spring.mode = 0;
			spring.frequencyOrStiffness = source.suspensionFrequency > 0 ? source.suspensionFrequency : 1.5f;
			spring.damping = source.suspensionDamping > 0 ? source.suspensionDamping : 0.5f;
			Native.JPH_WheelSettings_SetPosition(wheel, &position);
			Native.JPH_WheelSettings_SetRadius(wheel, Math.Max(source.radius, 0.05f));
			Native.JPH_WheelSettings_SetWidth(wheel, Math.Max(source.width, 0.02f));
			Native.JPH_WheelSettings_SetSuspensionMinLength(wheel, Math.Max(source.suspensionMinLength, 0.01f));
			Native.JPH_WheelSettings_SetSuspensionMaxLength(wheel, Math.Max(source.suspensionMaxLength, source.suspensionMinLength + 0.01f));
			Native.JPH_WheelSettings_SetSuspensionPreloadLength(wheel, Math.Max(source.suspensionPreloadLength, 0));
			Native.JPH_WheelSettings_SetSuspensionSpring(wheel, &spring);
			if (!tracked)
			{
				Native.JPH_WheelSettingsWV_SetInertia(wheel, source.inertia > 0 ? source.inertia : 0.5f);
				Native.JPH_WheelSettingsWV_SetAngularDamping(wheel, source.angularDamping > 0 ? source.angularDamping : 0.5f);
				Native.JPH_WheelSettingsWV_SetMaxSteerAngle(wheel, Math.Max(source.maxSteerAngleRadians, 0));
				Native.JPH_WheelSettingsWV_SetMaxBrakeTorque(wheel, Math.Max(source.maxBrakeTorque, 0));
				Native.JPH_WheelSettingsWV_SetMaxHandBrakeTorque(wheel, Math.Max(source.maxHandBrakeTorque, 0));
			}
		}
		settings.wheels = wheels.Ptr;
		settings.wheelsCount = (uint32)desc.wheelCount;

		JPH_VehicleAntiRollBar[2] bars = default;
		if (!tracked && desc.antiRollBars && desc.wheelCount >= 4)
		{
			Native.JPH_VehicleAntiRollBar_Init(&bars[0]);
			bars[0].leftWheel = 0;
			bars[0].rightWheel = 1;
			bars[0].stiffness = 1000;
			Native.JPH_VehicleAntiRollBar_Init(&bars[1]);
			bars[1].leftWheel = 2;
			bars[1].rightWheel = 3;
			bars[1].stiffness = 1000;
			settings.antiRollBars = &bars;
			settings.antiRollBarsCount = 2;
		}

		void* controller;
		JPH_VehicleEngineSettings engine = default;
		Native.JPH_VehicleEngineSettings_Init(&engine);
		engine.maxTorque = desc.maxTorque > 0 ? desc.maxTorque : 2000;
		engine.minRPM = desc.minRPM > 0 ? desc.minRPM : 1000;
		engine.maxRPM = desc.maxRPM > engine.minRPM ? desc.maxRPM : 6000;
		engine.inertia = desc.engineInertia > 0 ? desc.engineInertia : 0.5f;
		engine.angularDamping = desc.engineAngularDamping > 0 ? desc.engineAngularDamping : 0.5f;

		let transmission = Native.JPH_VehicleTransmissionSettings_Create();
		defer Native.JPH_VehicleTransmissionSettings_Destroy(transmission);
		int32 gearCount = Math.Clamp(desc.gearCount, 1, 5);
		float[5] ratios = .(3.5f, 2.5f, 1.8f, 1.3f, 1.0f);
		for (int32 i = 0; i < gearCount; i++)
			ratios[i] = desc.gearRatios[i] > 0 ? desc.gearRatios[i] : ratios[i];
		Native.JPH_VehicleTransmissionSettings_SetGearRatios(transmission, &ratios, (uint32)gearCount);
		float[1] reverse = .(desc.reverseRatio > 0 ? desc.reverseRatio : 3.0f);
		Native.JPH_VehicleTransmissionSettings_SetReverseGearRatios(transmission, &reverse, 1);
		Native.JPH_VehicleTransmissionSettings_SetShiftUpRPM(transmission, engine.maxRPM * 0.9f);
		Native.JPH_VehicleTransmissionSettings_SetShiftDownRPM(transmission, engine.minRPM + (engine.maxRPM - engine.minRPM) * 0.25f);
		Native.JPH_VehicleTransmissionSettings_SetClutchStrength(transmission, 10);

		if (tracked)
		{
			controller = Native.JPH_TrackedVehicleControllerSettings_Create();
			Native.JPH_TrackedVehicleControllerSettings_SetEngine(controller, &engine);
			Native.JPH_TrackedVehicleControllerSettings_SetTransmission(controller, transmission);
			uint32[2] leftWheels = .(0, 2);
			uint32[2] rightWheels = .(1, 3);
			if (desc.wheelCount >= 4)
			{
				JPH_VehicleTrackSettings left = default;
				Native.JPH_VehicleTrackSettings_Init(&left);
				left.drivenWheel = (uint32)Math.Clamp(desc.leftTrackDrivenWheel, 0, desc.wheelCount - 1);
				left.wheels = &leftWheels;
				left.wheelsCount = 2;
				left.inertia = desc.trackInertia > 0 ? desc.trackInertia : 10;
				left.angularDamping = desc.trackAngularDamping >= 0 ? desc.trackAngularDamping : 0.5f;
				left.maxBrakeTorque = desc.trackMaxBrakeTorque > 0 ? desc.trackMaxBrakeTorque : 3000;
				left.differentialRatio = desc.trackDifferentialRatio > 0 ? desc.trackDifferentialRatio : 2;
				Native.JPH_TrackedVehicleControllerSettings_SetTrack(controller, 0, &left);
				JPH_VehicleTrackSettings right = default;
				Native.JPH_VehicleTrackSettings_Init(&right);
				right.drivenWheel = (uint32)Math.Clamp(desc.rightTrackDrivenWheel, 0, desc.wheelCount - 1);
				right.wheels = &rightWheels;
				right.wheelsCount = 2;
				right.inertia = left.inertia;
				right.angularDamping = left.angularDamping;
				right.maxBrakeTorque = left.maxBrakeTorque;
				right.differentialRatio = left.differentialRatio;
				Native.JPH_TrackedVehicleControllerSettings_SetTrack(controller, 1, &right);
			}
		}
		else if (desc.kind == .Motorcycle)
		{
			controller = Native.JPH_MotorcycleControllerSettings_Create();
			Native.JPH_WheeledVehicleControllerSettings_SetEngine(controller, &engine);
			Native.JPH_WheeledVehicleControllerSettings_SetTransmission(controller, transmission);
			Native.JPH_MotorcycleControllerSettings_SetMaxLeanAngle(controller, desc.maxLeanAngleRadians > 0 ? desc.maxLeanAngleRadians : Mathf.Deg2Rad * 45);
			Native.JPH_MotorcycleControllerSettings_SetLeanSpringConstant(controller, 10);
			Native.JPH_MotorcycleControllerSettings_SetLeanSpringDamping(controller, 1);
			Native.JPH_MotorcycleControllerSettings_SetLeanSpringIntegrationCoefficient(controller, 1);
			Native.JPH_MotorcycleControllerSettings_SetLeanSpringIntegrationCoefficientDecay(controller, 1);
			Native.JPH_MotorcycleControllerSettings_SetLeanSmoothingFactor(controller, 0.05f);
			// One differential driving the rear wheel (index 1); -1 for no left wheel.
			Native.JPH_WheeledVehicleControllerSettings_AddDifferential(controller, -1, 1);
		}
		else
		{
			controller = Native.JPH_WheeledVehicleControllerSettings_Create();
			Native.JPH_WheeledVehicleControllerSettings_SetEngine(controller, &engine);
			Native.JPH_WheeledVehicleControllerSettings_SetTransmission(controller, transmission);
			// Pair driven wheels into differentials (front pair, then rear pair).
			bool anyDriven = false;
			for (int32 i = 0; i < desc.wheelCount; i++)
			{
				if (desc.wheels[i].driven)
					anyDriven = true;
			}
			for (int32 i = 0; i + 1 < desc.wheelCount; i += 2)
			{
				if (!anyDriven || desc.wheels[i].driven || desc.wheels[i + 1].driven)
					Native.JPH_WheeledVehicleControllerSettings_AddDifferential(controller, i, i + 1);
			}
		}
		settings.controller = controller;
		defer Native.JPH_VehicleControllerSettings_Destroy(controller);
		let constraint = Native.JPH_VehicleConstraint_Create(body, &settings);
		if (constraint == null)
			return null;
		var up = settings.up;
		let tester = Native.JPH_VehicleCollisionTesterCastSphere_Create(desc.objectCode, Math.Max(desc.wheels[0].radius * 0.5f, 0.05f), &up, Mathf.Deg2Rad * 45);
		if (tester != null)
			Native.JPH_VehicleConstraint_SetVehicleCollisionTester(constraint, tester);
		if (!tracked)
		{
			let controllerForTires = Native.JPH_VehicleConstraint_GetController(constraint);
			Native.JPH_WheeledVehicleController_SetTireMaxImpulseCallback(controllerForTires, => TireImpulse, null);
		}
		let handle = new Handle();
		handle.constraint = constraint;
		handle.collisionTester = tester;
		handle.kind = desc.kind;
		mByConstraint[constraint] = handle;
		return constraint;
	}

	void DestroyHandle(Handle handle)
	{
		if (handle == null)
			return;
		if (handle.inWorld)
		{
			Native.JPH_PhysicsSystem_RemoveStepListener(mSystem, Native.JPH_VehicleConstraint_AsPhysicsStepListener(handle.constraint));
			Native.JPH_PhysicsSystem_RemoveConstraint(mSystem, handle.constraint);
		}
		Native.JPH_Constraint_Destroy(handle.constraint);
		if (handle.collisionTester != null)
			Native.JPH_VehicleCollisionTester_Destroy(handle.collisionTester);
		mByConstraint.Remove(handle.constraint);
		delete handle;
	}

	public override void Destroy(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle != null)
			DestroyHandle(handle);
	}

	public override void AddToWorld(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle == null || handle.inWorld) return;
		Native.JPH_PhysicsSystem_AddConstraint(mSystem, handle.constraint);
		Native.JPH_PhysicsSystem_AddStepListener(mSystem, Native.JPH_VehicleConstraint_AsPhysicsStepListener(handle.constraint));
		handle.inWorld = true;
	}

	public override void RemoveFromWorld(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle == null || !handle.inWorld) return;
		Native.JPH_PhysicsSystem_RemoveStepListener(mSystem, Native.JPH_VehicleConstraint_AsPhysicsStepListener(handle.constraint));
		Native.JPH_PhysicsSystem_RemoveConstraint(mSystem, handle.constraint);
		handle.inWorld = false;
	}

	public override void SetDriverInput(void* vehicle, float forward, float right, float brake, float handBrake)
	{
		let handle = From(vehicle);
		if (handle == null) return;
		let controller = Native.JPH_VehicleConstraint_GetController(handle.constraint);
		if (handle.kind == .Tracked)
		{
			// Tracked vehicles steer by making one track faster than the other.
			float leftRatio = Math.Clamp(1 - right * 0.75f, 0, 2);
			float rightRatio = Math.Clamp(1 + right * 0.75f, 0, 2);
			Native.JPH_TrackedVehicleController_SetDriverInput(controller, forward, leftRatio, rightRatio, Math.Max(brake, handBrake));
		}
		else
			Native.JPH_WheeledVehicleController_SetDriverInput(controller, forward, right, brake, handBrake);
	}

	public override int32 WheelCount(void* vehicle)
	{
		let handle = From(vehicle);
		return handle != null ? (int32)Native.JPH_VehicleConstraint_GetWheelsCount(handle.constraint) : 0;
	}

	void* Wheel(void* vehicle, int32 index)
	{
		let handle = From(vehicle);
		if (handle == null || index < 0 || index >= WheelCount(vehicle)) return null;
		return Native.JPH_VehicleConstraint_GetWheel(handle.constraint, (uint32)index);
	}

	public override bool WheelContact(void* vehicle, int32 wheel, out Vector3 point, out Vector3 normal, out uint32 bodyId)
	{
		point = default;
		normal = default;
		bodyId = uint32.MaxValue;
		let native = Wheel(vehicle, wheel);
		if (native == null) return false;
		if (!Native.JPH_Wheel_HasContact(native))
			return false;
		bodyId = Native.JPH_Wheel_GetContactBodyID(native);
		Native.JPH_Wheel_GetContactPosition(native, &point);
		Native.JPH_Wheel_GetContactNormal(native, &normal);
		return true;
	}

	public override float WheelSuspensionLength(void* vehicle, int32 wheel)
	{
		let native = Wheel(vehicle, wheel);
		return native != null ? Native.JPH_Wheel_GetSuspensionLength(native) : 0;
	}

	public override float WheelRotationAngle(void* vehicle, int32 wheel)
	{
		let native = Wheel(vehicle, wheel);
		return native != null ? Native.JPH_Wheel_GetRotationAngle(native) : 0;
	}

	public override float WheelSteerAngle(void* vehicle, int32 wheel)
	{
		let native = Wheel(vehicle, wheel);
		return native != null ? Native.JPH_Wheel_GetSteerAngle(native) : 0;
	}

	public override Matrix4 WheelWorldTransform(void* vehicle, int32 wheel)
	{
		let handle = From(vehicle);
		if (handle == null || wheel < 0 || wheel >= WheelCount(vehicle))
			return .Identity;
		var right = Vector3.Up;
		var up = Vector3.Right;
		PhysicsRagdollMatrix result = default;
		Native.JPH_VehicleConstraint_GetWheelWorldTransform(handle.constraint, (uint32)wheel, &right, &up, (Matrix4*)&result);
		return result.ToMatrix();
	}

	public override float EngineRPM(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle == null) return 0;
		let controller = Native.JPH_VehicleConstraint_GetController(handle.constraint);
		let engine = handle.kind == .Tracked ? Native.JPH_TrackedVehicleController_GetEngine(controller) : Native.JPH_WheeledVehicleController_GetEngine(controller);
		return engine != null ? Native.JPH_VehicleEngine_GetCurrentRPM(engine) : 0;
	}

	public override int32 CurrentGear(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle == null) return 0;
		let controller = Native.JPH_VehicleConstraint_GetController(handle.constraint);
		let transmission = handle.kind == .Tracked ? Native.JPH_TrackedVehicleController_GetTransmission(controller) : Native.JPH_WheeledVehicleController_GetTransmission(controller);
		return transmission != null ? Native.JPH_VehicleTransmission_GetCurrentGear(transmission) : 0;
	}

	public override float CurrentRatio(void* vehicle)
	{
		let handle = From(vehicle);
		if (handle == null) return 0;
		let controller = Native.JPH_VehicleConstraint_GetController(handle.constraint);
		let transmission = handle.kind == .Tracked ? Native.JPH_TrackedVehicleController_GetTransmission(controller) : Native.JPH_WheeledVehicleController_GetTransmission(controller);
		return transmission != null ? Native.JPH_VehicleTransmission_GetCurrentRatio(transmission) : 0;
	}

	public override float WheelAngularVelocity(void* vehicle, int32 wheel)
	{
		let native = Wheel(vehicle, wheel);
		return native != null ? Native.JPH_Wheel_GetAngularVelocity(native) : 0;
	}
}
