using System;
using System.Collections;

namespace Tallow;

/// A drivable vehicle on this object's Rigidbody: wheeled, motorcycle or tracked, according to Kind. It builds the
/// selected backend's vehicle and exposes driver input, wheel and engine state. Another backend can implement only
/// some kinds; the Inspector offers just the kinds it advertises.
///
/// Put a Rigidbody and a Collider on the same object for the chassis, then set the wheels. Every wheel's position
/// (relative to the chassis), radius, width, suspension and steering is a saved field on this component. A motorcycle
/// uses Front Left as its front wheel and Rear Left as its rear; a tracked vehicle uses 0/2 on the left track and
/// 1/3 on the right. Drive it from a script with SetDriverInput; the Drivable Car template shows the wheeled kind.
[Component]
class Vehicle : Component
{
	// The front-left wheel. Positions are relative to the chassis body's centre.
	[HideInInspector]
	public Vector3 frontLeftPosition = .(-0.6f, -0.1f, 0.66f);
	[HideInInspector]
	public float frontLeftRadius = 0.3f;
	[HideInInspector]
	public float frontLeftWidth = 0.2f;
	[HideInInspector]
	public float frontLeftSuspensionMin = 0.05f;
	[HideInInspector]
	public float frontLeftSuspensionMax = 0.3f;
	[HideInInspector]
	public float frontLeftSuspensionFrequency = 1.7f;
	[HideInInspector]
	public float frontLeftSuspensionDamping = 0.8f;
	[HideInInspector]
	public float frontLeftSteerDegrees = 32;
	[HideInInspector]
	public float frontLeftBrakeTorque = 1800;
	[HideInInspector]
	public float frontLeftHandBrakeTorque = 0;
	[HideInInspector]
	public bool frontLeftDriven = false;

	[HideInInspector]
	public Vector3 frontRightPosition = .(0.6f, -0.1f, 0.66f);
	[HideInInspector]
	public float frontRightRadius = 0.3f;
	[HideInInspector]
	public float frontRightWidth = 0.2f;
	[HideInInspector]
	public float frontRightSuspensionMin = 0.05f;
	[HideInInspector]
	public float frontRightSuspensionMax = 0.3f;
	[HideInInspector]
	public float frontRightSuspensionFrequency = 1.7f;
	[HideInInspector]
	public float frontRightSuspensionDamping = 0.8f;
	[HideInInspector]
	public float frontRightSteerDegrees = 32;
	[HideInInspector]
	public float frontRightBrakeTorque = 1800;
	[HideInInspector]
	public float frontRightHandBrakeTorque = 0;
	[HideInInspector]
	public bool frontRightDriven = false;

	[HideInInspector]
	public Vector3 rearLeftPosition = .(-0.6f, -0.1f, -0.66f);
	[HideInInspector]
	public float rearLeftRadius = 0.3f;
	[HideInInspector]
	public float rearLeftWidth = 0.2f;
	[HideInInspector]
	public float rearLeftSuspensionMin = 0.05f;
	[HideInInspector]
	public float rearLeftSuspensionMax = 0.3f;
	[HideInInspector]
	public float rearLeftSuspensionFrequency = 1.7f;
	[HideInInspector]
	public float rearLeftSuspensionDamping = 0.8f;
	[HideInInspector]
	public float rearLeftSteerDegrees = 0;
	[HideInInspector]
	public float rearLeftBrakeTorque = 1200;
	[HideInInspector]
	public float rearLeftHandBrakeTorque = 3000;
	[HideInInspector]
	public bool rearLeftDriven = true;

	[HideInInspector]
	public Vector3 rearRightPosition = .(0.6f, -0.1f, -0.66f);
	[HideInInspector]
	public float rearRightRadius = 0.3f;
	[HideInInspector]
	public float rearRightWidth = 0.2f;
	[HideInInspector]
	public float rearRightSuspensionMin = 0.05f;
	[HideInInspector]
	public float rearRightSuspensionMax = 0.3f;
	[HideInInspector]
	public float rearRightSuspensionFrequency = 1.7f;
	[HideInInspector]
	public float rearRightSuspensionDamping = 0.8f;
	[HideInInspector]
	public float rearRightSteerDegrees = 0;
	[HideInInspector]
	public float rearRightBrakeTorque = 1200;
	[HideInInspector]
	public float rearRightHandBrakeTorque = 3000;
	[HideInInspector]
	public bool rearRightDriven = true;

	/// Which kind of vehicle this is. The Inspector only offers kinds the selected backend implements.
	[HideInInspector]
	public PhysicsVehicleKind kind = .Wheeled;
	/// Motorcycle: how far it may lean, in degrees.
	[Range(1, 89)]
	public float maxLeanDegrees = 45;
	/// Tracked: the wheel index driven by each track (the left track uses wheels 0 and 2, the right 1 and 3).
	public int32 leftTrackDrivenWheel = 2;
	public int32 rightTrackDrivenWheel = 3;
	public float trackInertia = 10;
	public float trackAngularDamping = 0.5f;
	public float trackMaxBrakeTorque = 3000;
	public float trackDifferentialRatio = 2;

	/// The engine's peak torque in newton metres.
	public float maxTorque = 320;
	public float minRPM = 900;
	public float maxRPM = 6500;
	public float engineInertia = 0.4f;
	public float engineAngularDamping = 0.4f;
	/// The steepest pitch/roll the vehicle may reach, in degrees.
	[Range(1, 89)]
	public float maxPitchRollDegrees = 45;
	public List<float> gearRatios = new .() ~ delete _;
	public float reverseRatio = 3;
	public bool antiRollBars = true;

	public this()
	{
		gearRatios.Add(3.4f);
		gearRatios.Add(2.2f);
		gearRatios.Add(1.6f);
		gearRatios.Add(1.2f);
		gearRatios.Add(0.95f);
	}

	PhysicsVehicleExtension mVehicles;
	void* mHandle;
	bool mReady;

	/// Whether the backend vehicle is in the world.
	public bool IsReady => mHandle != null;

	public override void Start()
	{
		mReady = true;
		if (Scene != null && Scene.IsPlaying)
			CreateVehicle();
	}

	public override void OnEnable()
	{
		if (mReady && Scene != null && Scene.IsPlaying)
			CreateVehicle();
	}

	/// Builds the vehicle now, for a script that adds it after play has started. False when it cannot.
	public bool Begin()
	{
		CreateVehicle();
		return mHandle != null;
	}

	public override void OnDisable() => Release();
	public override void OnDestroy() => Release();

	void CreateVehicle()
	{
		if (mHandle != null)
			return;
		let body = GetComponent<Rigidbody>();
		if (!body.IsValid)
		{
			Log.Warning(scope $"Vehicle on '{GameObject.Name}' needs a Rigidbody with a Collider on the same object.");
			return;
		}
		// Starts run before the tick's Rigidbody.SyncAll: make the chassis now so the vehicle has a body to attach to.
		body.EnsureBody();
		if (!body.HasBody)
		{
			Log.Warning(scope $"Vehicle on '{GameObject.Name}' needs a Collider on the same object as its Rigidbody.");
			return;
		}
		let world = Scene.Physics;
		if (world.Vehicles == null || !world.SupportsVehicleKind(kind))
		{
			Log.Warning(scope $"Vehicle on '{GameObject.Name}' needs {PhysicsVehicleKinds.Name(kind)} vehicles; the selected physics backend does not provide them.");
			return;
		}
		mVehicles = world.Vehicles;
		bool motorcycle = kind == .Motorcycle;
		PhysicsWheelDesc[4] wheels = default;
		if (motorcycle)
		{
			// A motorcycle uses the frontLeft slot as its front wheel and rearLeft as its rear wheel.
			FillWheel(ref wheels[0], frontLeftPosition, frontLeftRadius, frontLeftWidth, frontLeftSuspensionMin, frontLeftSuspensionMax,
				frontLeftSuspensionFrequency, frontLeftSuspensionDamping, frontLeftSteerDegrees, frontLeftBrakeTorque, frontLeftHandBrakeTorque, false);
			FillWheel(ref wheels[1], rearLeftPosition, rearLeftRadius, rearLeftWidth, rearLeftSuspensionMin, rearLeftSuspensionMax,
				rearLeftSuspensionFrequency, rearLeftSuspensionDamping, 0, rearLeftBrakeTorque, rearLeftHandBrakeTorque, true);
		}
		else
		{
			FillWheel(ref wheels[0], frontLeftPosition, frontLeftRadius, frontLeftWidth, frontLeftSuspensionMin, frontLeftSuspensionMax,
				frontLeftSuspensionFrequency, frontLeftSuspensionDamping, frontLeftSteerDegrees, frontLeftBrakeTorque, frontLeftHandBrakeTorque, frontLeftDriven);
			FillWheel(ref wheels[1], frontRightPosition, frontRightRadius, frontRightWidth, frontRightSuspensionMin, frontRightSuspensionMax,
				frontRightSuspensionFrequency, frontRightSuspensionDamping, frontRightSteerDegrees, frontRightBrakeTorque, frontRightHandBrakeTorque, frontRightDriven);
			FillWheel(ref wheels[2], rearLeftPosition, rearLeftRadius, rearLeftWidth, rearLeftSuspensionMin, rearLeftSuspensionMax,
				rearLeftSuspensionFrequency, rearLeftSuspensionDamping, rearLeftSteerDegrees, rearLeftBrakeTorque, rearLeftHandBrakeTorque, rearLeftDriven);
			FillWheel(ref wheels[3], rearRightPosition, rearRightRadius, rearRightWidth, rearRightSuspensionMin, rearRightSuspensionMax,
				rearRightSuspensionFrequency, rearRightSuspensionDamping, rearRightSteerDegrees, rearRightBrakeTorque, rearRightHandBrakeTorque, rearRightDriven);
		}
		PhysicsVehicleDesc desc = default;
		desc.kind = kind;
		desc.wheels = &wheels;
		desc.wheelCount = motorcycle ? 2 : 4;
		desc.maxLeanAngleRadians = maxLeanDegrees * Mathf.Deg2Rad;
		desc.leftTrackDrivenWheel = leftTrackDrivenWheel;
		desc.rightTrackDrivenWheel = rightTrackDrivenWheel;
		desc.trackInertia = trackInertia;
		desc.trackAngularDamping = trackAngularDamping;
		desc.trackMaxBrakeTorque = trackMaxBrakeTorque;
		desc.trackDifferentialRatio = trackDifferentialRatio;
		desc.up = Vector3.Up;
		desc.forward = Vector3.Forward;
		desc.maxPitchRollAngle = maxPitchRollDegrees * Mathf.Deg2Rad;
		desc.maxTorque = maxTorque;
		desc.minRPM = minRPM;
		desc.maxRPM = maxRPM;
		desc.engineInertia = engineInertia;
		desc.engineAngularDamping = engineAngularDamping;
		desc.gearCount = Math.Clamp((int32)gearRatios.Count, 1, 5);
		for (int32 i = 0; i < desc.gearCount; i++)
			desc.gearRatios[i] = i < gearRatios.Count ? gearRatios[i] : 3.4f;
		desc.reverseRatio = reverseRatio;
		desc.antiRollBars = antiRollBars;
		desc.objectCode = PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, GameObject.Layer);
		mHandle = mVehicles.Create(body.BodyId, desc);
		if (mHandle == null)
		{
			Log.Warning(scope $"Vehicle on '{GameObject.Name}' could not be built.");
			return;
		}
		mVehicles.AddToWorld(mHandle);
	}

	static void FillWheel(ref PhysicsWheelDesc into, Vector3 position, float radius, float width, float suspensionMin,
		float suspensionMax, float frequency, float damping, float steerDegrees, float brakeTorque, float handBrakeTorque, bool driven)
	{
		into.position = position;
		into.radius = radius;
		into.width = width;
		into.suspensionMinLength = suspensionMin;
		into.suspensionMaxLength = suspensionMax;
		into.suspensionFrequency = frequency;
		into.suspensionDamping = damping;
		into.maxSteerAngleRadians = steerDegrees * Mathf.Deg2Rad;
		into.maxBrakeTorque = brakeTorque;
		into.maxHandBrakeTorque = handBrakeTorque;
		into.inertia = 0.5f;
		into.angularDamping = 0.5f;
		into.driven = driven;
	}

	/// forward: -1..1 (throttle/brake), right: -1..1 (steering), brake: 0..1, handBrake: 0..1.
	public void SetDriverInput(float forward, float right, float brake, float handBrake)
	{
		if (mHandle != null && mVehicles != null)
			mVehicles.SetDriverInput(mHandle, forward, right, brake, handBrake);
	}

	public void Release()
	{
		if (mHandle != null && mVehicles != null)
			mVehicles.Destroy(mHandle);
		mHandle = null;
		mVehicles = null;
	}

	public int32 WheelCount => mHandle != null ? mVehicles.WheelCount(mHandle) : 0;

	public bool WheelOnGround(int32 wheel)
	{
		if (mHandle == null)
			return false;
		return mVehicles.WheelContact(mHandle, wheel, let point, let normal, let body);
	}

	public float WheelRotationAngle(int32 wheel) => mHandle != null ? mVehicles.WheelRotationAngle(mHandle, wheel) : 0;
	public float WheelSuspensionLength(int32 wheel) => mHandle != null ? mVehicles.WheelSuspensionLength(mHandle, wheel) : 0;
	public float WheelSteerAngle(int32 wheel) => mHandle != null ? mVehicles.WheelSteerAngle(mHandle, wheel) : 0;
	/// Wheel gizmos in the Scene view when this object is selected: the suspension attachment, travel, the wheel
	/// at full compression and full droop, its axle, and the steering direction.
	public override void OnDrawGizmos(bool selected)
	{
		if (!selected || GameObject == null)
			return;
		let transform = Transform;
		let front = Color(0.2f, 0.8f, 1.0f, 1);
		let rear = Color(1.0f, 0.6f, 0.2f, 1);
		DrawWheelGizmo(transform, frontLeftPosition, frontLeftRadius, frontLeftSuspensionMin, frontLeftSuspensionMax, frontLeftSteerDegrees, frontLeftDriven, front);
		DrawWheelGizmo(transform, frontRightPosition, frontRightRadius, frontRightSuspensionMin, frontRightSuspensionMax, frontRightSteerDegrees, frontRightDriven, front);
		DrawWheelGizmo(transform, rearLeftPosition, rearLeftRadius, rearLeftSuspensionMin, rearLeftSuspensionMax, rearLeftSteerDegrees, rearLeftDriven, rear);
		DrawWheelGizmo(transform, rearRightPosition, rearRightRadius, rearRightSuspensionMin, rearRightSuspensionMax, rearRightSteerDegrees, rearRightDriven, rear);
	}

	static void DrawWheelGizmo(Transform transform, Vector3 position, float radius, float suspensionMin,
		float suspensionMax, float steerDegrees, bool driven, Color color)
	{
		let attachment = transform.TransformPoint(position);
		let down = -transform.Up;
		let compressed = attachment + down * suspensionMin;
		let drooped = attachment + down * suspensionMax;
		let faint = Color(color.r, color.g, color.b, 0.35f);
		// Suspension attachment and travel.
		Gizmos.Lines.Sphere(attachment, Math.Max(radius * 0.08f, 0.02f), color);
		Gizmos.Lines.Line(attachment, drooped, color);
		Gizmos.Lines.Line(compressed, drooped, faint);
		// The wheel at full compression (faint) and full droop.
		Gizmos.Lines.Circle(compressed, transform.Right, radius, faint);
		Gizmos.Lines.Circle(drooped, transform.Right, radius, color);
		// The axle.
		Gizmos.Lines.Line(drooped - transform.Right * (radius * 0.5f), drooped + transform.Right * (radius * 0.5f), color);
		// Where it points when steered.
		let steered = Quaternion.AngleAxis(steerDegrees, transform.Up) * transform.Forward;
		Gizmos.Lines.Line(drooped, drooped + steered * (radius + 0.15f), color);
		// Driven wheels get a second, smaller ring at the attachment.
		if (driven)
			Gizmos.Lines.Circle(attachment, transform.Up, Math.Max(radius * 0.25f, 0.03f), color);
	}

	public float EngineRPM => mHandle != null ? mVehicles.EngineRPM(mHandle) : 0;
	public int32 Gear => mHandle != null ? mVehicles.CurrentGear(mHandle) : 0;
	/// How fast the chassis is moving, in metres a second.
	public float Speed => GetComponent<Rigidbody>().Velocity.Length;
}
