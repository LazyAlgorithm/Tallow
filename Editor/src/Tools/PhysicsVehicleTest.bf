using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless check of the backend vehicle extension: a Jolt wheeled vehicle is built on a chassis body, driven forward
/// and reports wheel and engine state. Run with: TallowLauncher --test-physics-vehicle
static class PhysicsVehicleTest
{
	public static int Run()
	{
		int failures = 0;
		let scene = scope Scene();

		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(200, 1, 200);
		failures += Check("ground body created", scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null) != uint32.MaxValue);

		let chassis = scene.CreateGameObject("Chassis");
		chassis.Transform.Position = Vector3(0, 1.5f, 0);
		let chassisCollider = chassis.AddComponent<BoxCollider>();
		chassisCollider.size = Vector3(1.8f, 0.6f, 4);
		RigidbodyData chassisData = .();
		chassisData.mass = 1200;
		chassisData.linearDamping = 0.1f;
		chassisData.angularDamping = 0.3f;
		let chassisBody = scene.Physics.CreateBody(chassis.Transform, chassisCollider.GetShape(), &chassisData);
		failures += Check("chassis body created", chassisBody != uint32.MaxValue);

		let vehicles = scene.Physics.Vehicles;
		failures += Check("Jolt advertises vehicles", scene.Physics.Supports(.Vehicles));
		failures += Check("vehicle extension is present", vehicles != null);
		if (vehicles == null || chassisBody == uint32.MaxValue)
		{
			Console.WriteLine("PHYSICS VEHICLE FAIL");
			return 1;
		}

		PhysicsWheelDesc[] wheels = new .[4];
		defer delete wheels;
		for (int i = 0; i < 4; i++)
		{
			bool front = i < 2;
			wheels[i] = default;
			wheels[i].position = Vector3((i & 1) == 0 ? -0.9f : 0.9f, -0.6f, front ? 1.4f : -1.4f);
			wheels[i].radius = 0.4f;
			wheels[i].width = 0.3f;
			wheels[i].suspensionMinLength = 0.1f;
			wheels[i].suspensionMaxLength = 0.5f;
			wheels[i].suspensionFrequency = 1.5f;
			wheels[i].suspensionDamping = 0.5f;
			wheels[i].maxSteerAngleRadians = front ? Mathf.Deg2Rad * 30 : 0;
			wheels[i].maxBrakeTorque = 1500;
			wheels[i].maxHandBrakeTorque = 3000;
			wheels[i].inertia = 0.5f;
			wheels[i].angularDamping = 0.5f;
			wheels[i].driven = !front;
		}
		PhysicsVehicleDesc desc = default;
		desc.wheels = wheels.Ptr;
		desc.wheelCount = 4;
		desc.up = Vector3.Up;
		desc.forward = Vector3.Forward;
		desc.maxPitchRollAngle = Mathf.Deg2Rad * 45;
		desc.maxTorque = 3000;
		desc.minRPM = 1000;
		desc.maxRPM = 6000;
		desc.engineInertia = 0.5f;
		desc.engineAngularDamping = 0.5f;
		desc.gearCount = 5;
		desc.gearRatios = .(3.5f, 2.5f, 1.8f, 1.3f, 1.0f);
		desc.reverseRatio = 3;
		desc.antiRollBars = true;
		desc.objectCode = PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, 0);

		let vehicle = vehicles.Create(chassisBody, desc);
		failures += Check("vehicle created", vehicle != null);
		if (vehicle == null)
		{
			Console.WriteLine("PHYSICS VEHICLE FAIL");
			return 1;
		}
		vehicles.AddToWorld(vehicle);
		vehicles.SetDriverInput(vehicle, 1, 0, 0, 0);
		for (int i < 180)
			scene.Physics.Step(1.0f / 60.0f);

		failures += Check("vehicle has four wheels", vehicles.WheelCount(vehicle) == 4);
		Vector3 point, normal;
		let contact = vehicles.WheelContact(vehicle, 2, out point, out normal, let contactBody);
		failures += Check("a wheel touches the ground", contact);
		failures += Check("vehicle moved", Math.Abs(chassis.Transform.Position.z) > 1.0f);
		failures += Check("engine is turning", vehicles.EngineRPM(vehicle) > 0);
		failures += Check("wheel suspension is working", vehicles.WheelSuspensionLength(vehicle, 2) > 0);
		vehicles.Destroy(vehicle);

		// The engine-facing Vehicle component on a normal Rigidbody.
		let componentChassis = scene.CreateGameObject("Component Chassis");
		componentChassis.Transform.Position = Vector3(0, 1.5f, -5);
		let componentCollider = componentChassis.AddComponent<BoxCollider>();
		componentCollider.size = Vector3(1.8f, 0.6f, 4);
		let componentBody = componentChassis.AddComponent<Rigidbody>();
		componentBody.mass = 1200;
		componentBody.EnsureBody();
		let component = componentChassis.AddComponent<Vehicle>();
		failures += Check("Vehicle component begins", component.Begin());
		component.SetDriverInput(1, 0, 0, 0);
		for (int i < 60)
			scene.Physics.Step(1.0f / 60.0f);
		failures += Check("Vehicle component has four wheels", component.WheelCount == 4);
		failures += Check("Vehicle component moves", component.Speed > 1.0f);
		component.Release();

		Console.WriteLine(failures == 0 ? "PHYSICS VEHICLE PASS" : scope $"PHYSICS VEHICLE FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}

	static int Check(StringView what, bool ok)
	{
		let line = scope String();
		line.AppendF("[{}] {}", ok ? "PASS" : "FAIL", what);
		Console.WriteLine(line);
		return ok ? 0 : 1;
	}
}
