using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless checks of the Jolt vehicle kinds: wheeled, motorcycle and tracked. Run with:
///   TallowLauncher --test-physics-vehicle-kinds
static class PhysicsVehicleKindsTest
{
	public static int Run()
	{
		int failures = 0;
		let scene = scope Scene();

		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(200, 1, 200);
		failures += Check("ground body created", scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null) != uint32.MaxValue);

		let vehicles = scene.Physics.Vehicles;
		failures += Check("Jolt advertises motorcycle vehicles", scene.Physics.Supports(.MotorcycleVehicles));
		failures += Check("Jolt advertises tracked vehicles", scene.Physics.Supports(.TrackedVehicles));
		if (vehicles == null)
		{
			Console.WriteLine("PHYSICS VEHICLE KINDS FAIL");
			return 1;
		}

		failures += RunKind(scene, vehicles, .Wheeled);
		failures += RunKind(scene, vehicles, .Motorcycle);
		failures += RunKind(scene, vehicles, .Tracked);

		Console.WriteLine(failures == 0 ? "PHYSICS VEHICLE KINDS PASS" : scope $"PHYSICS VEHICLE KINDS FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}

	static int RunKind(Scene scene, PhysicsVehicleExtension vehicles, PhysicsVehicleKind kind)
	{
		int failures = 0;
		bool motorcycle = kind == .Motorcycle;
		bool tracked = kind == .Tracked;
		int32 wheelCount = motorcycle ? 2 : 4;
		let chassis = scene.CreateGameObject(scope $"Chassis {kind}");
		chassis.Transform.Position = Vector3(0, 1.2f, 0);
		let collider = chassis.AddComponent<BoxCollider>();
		collider.size = motorcycle ? Vector3(0.4f, 0.6f, 1.6f) : Vector3(2, 0.8f, 3);
		RigidbodyData body = .();
		body.mass = motorcycle ? 250 : (tracked ? 4000 : 1300);
		let bodyId = scene.Physics.CreateBody(chassis.Transform, collider.GetShape(), &body);
		if (bodyId == uint32.MaxValue)
		{
			Console.WriteLine(scope $"[FAIL] {kind}: chassis body");
			return 1;
		}

		PhysicsWheelDesc[4] wheels = default;
		for (int32 i = 0; i < 4; i++)
		{
			wheels[i] = default;
			wheels[i].radius = motorcycle ? 0.32f : (tracked ? 0.35f : 0.3f);
			wheels[i].width = motorcycle ? 0.12f : 0.25f;
			wheels[i].suspensionMinLength = 0.08f;
			wheels[i].suspensionMaxLength = 0.3f;
			wheels[i].suspensionFrequency = 1.6f;
			wheels[i].suspensionDamping = 0.8f;
			wheels[i].inertia = 0.5f;
			wheels[i].angularDamping = 0.5f;
		}
		if (motorcycle)
		{
			wheels[0].position = Vector3(0, -0.4f, 0.75f);
			wheels[0].maxSteerAngleRadians = Mathf.Deg2Rad * 30;
			wheels[0].maxBrakeTorque = 700;
			wheels[1].position = Vector3(0, -0.4f, -0.75f);
			wheels[1].driven = true;
			wheels[1].maxBrakeTorque = 500;
		}
		else
		{
			float x = tracked ? 0.9f : 0.6f;
			float z = tracked ? 1.0f : 0.66f;
			wheels[0].position = Vector3(-x, -0.4f, z);
			wheels[1].position = Vector3(x, -0.4f, z);
			wheels[2].position = Vector3(-x, -0.4f, -z);
			wheels[3].position = Vector3(x, -0.4f, -z);
			if (!tracked)
			{
				wheels[0].maxSteerAngleRadians = Mathf.Deg2Rad * 30;
				wheels[1].maxSteerAngleRadians = Mathf.Deg2Rad * 30;
				wheels[2].driven = true;
				wheels[3].driven = true;
			}
			for (int32 i = 0; i < 4; i++)
				wheels[i].maxBrakeTorque = 1500;
		}

		PhysicsVehicleDesc desc = default;
		desc.kind = kind;
		desc.wheels = &wheels;
		desc.wheelCount = wheelCount;
		desc.up = Vector3.Up;
		desc.forward = Vector3.Forward;
		desc.maxPitchRollAngle = Mathf.Deg2Rad * 60;
		desc.maxTorque = motorcycle ? 150 : (tracked ? 1200 : 320);
		desc.minRPM = 900;
		desc.maxRPM = motorcycle ? 10000 : 6500;
		desc.engineInertia = 0.5f;
		desc.engineAngularDamping = 0.5f;
		desc.gearCount = 5;
		desc.gearRatios = .(3.4f, 2.2f, 1.6f, 1.2f, 0.95f);
		desc.reverseRatio = 3;
		desc.antiRollBars = !tracked;
		desc.objectCode = PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, 0);
		desc.maxLeanAngleRadians = Mathf.Deg2Rad * 45;
		desc.leftTrackDrivenWheel = 2;
		desc.rightTrackDrivenWheel = 3;
		desc.trackInertia = 10;
		desc.trackAngularDamping = 0.5f;
		desc.trackMaxBrakeTorque = 3000;
		desc.trackDifferentialRatio = 2;

		let vehicle = vehicles.Create(bodyId, desc);
		failures += Check(scope $"{PhysicsVehicleKinds.Name(kind)}: created", vehicle != null);
		if (vehicle == null)
			return failures;
		failures += Check(scope $"{PhysicsVehicleKinds.Name(kind)}: has {wheelCount} wheels", vehicles.WheelCount(vehicle) == wheelCount);
		vehicles.AddToWorld(vehicle);
		vehicles.SetDriverInput(vehicle, 1, 0.35f, 0, 0);
		for (int i < 120)
			scene.Physics.Step(1.0f / 60.0f);
		failures += Check(scope $"{PhysicsVehicleKinds.Name(kind)}: moves", Math.Abs(chassis.Transform.Position.z) > 0.5f);
		vehicles.Destroy(vehicle);
		return failures;
	}

	static int Check(StringView what, bool ok)
	{
		let line = scope String();
		line.AppendF("[{}] {}", ok ? "PASS" : "FAIL", what);
		Console.WriteLine(line);
		return ok ? 0 : 1;
	}
}
