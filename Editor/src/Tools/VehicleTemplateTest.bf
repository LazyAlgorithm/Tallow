using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Headless check of a created Drivable Car project: the template scene builds, its model and sound files load, and
/// the car drives. Run with: TallowLauncher --test-vehicle-template <project folder>
static class VehicleTemplateTest
{
	public static int Run(StringView folderIn)
	{
		int failures = 0;
		let folder = scope String(folderIn);
		while (folder.EndsWith('/') || folder.EndsWith('\\'))
			folder.RemoveFromEnd(1);
		let assets = scope $"{folder}/src";
		if (!Directory.Exists(assets))
		{
			Console.WriteLine(scope $"Vehicle template test: {assets} is missing.");
			return 1;
		}
		Assets.ProjectPath.Set(assets);

		// The wheel and engine settings are ordinary fields, so they survive a scene save and load.
		{
			let saved = scope Scene();
			SceneTemplates.BuildVehicle(saved, "");
			let savePath = scope $"{assets}/Scenes/TemplateCheck.tscene";
			failures += Check("template scene saves", SceneSerializer.SaveToFile(saved, savePath));
			let loaded = scope Scene();
			failures += Check("template scene loads", SceneSerializer.LoadFromFile(loaded, savePath));
			let loadedCar = loaded.Find("Car");
			let loadedVehicle = loadedCar != null ? loadedCar.GetComponent<Vehicle>() : null;
			failures += Check("Vehicle settings survive save/load", loadedVehicle != null &&
				Math.Abs(loadedVehicle.frontLeftRadius - 0.3f) < 0.001f &&
				Math.Abs(loadedVehicle.frontLeftPosition.z - 0.66f) < 0.001f &&
				Math.Abs(loadedVehicle.maxTorque - 320) < 0.001f);
		}

		let scene = scope Scene();
		SceneTemplates.BuildVehicle(scene, "");
		let car = scene.Find("Car");
		failures += Check("template built the Car", car != null);
		if (car == null)
		{
			Console.WriteLine("PHYSICS VEHICLE TEMPLATE FAIL");
			return 1;
		}
		scene.StartPlay();
		// One real tick: pending Starts create the collider bodies and the Vehicle's backend vehicle.
		scene.FixedUpdate();
		let vehicle = car.GetComponent<Vehicle>();
		failures += Check("Vehicle component created its backend vehicle", vehicle != null && vehicle.IsReady);
		if (vehicle != null)
		{
			int32 before = (int32)Gizmos.Lines.Vertices.Count;
			vehicle.OnDrawGizmos(true);
			failures += Check("wheel gizmos draw", Gizmos.Lines.Vertices.Count > before);
			Gizmos.Lines.Clear();
		}
		if (vehicle == null || !vehicle.IsReady)
		{
			Console.WriteLine("PHYSICS VEHICLE TEMPLATE FAIL");
			return 1;
		}
		vehicle.SetDriverInput(1, 0, 0, 0);
		for (int i < 120)
			scene.FixedUpdate();
		failures += Check("template car moves", car.Transform.Position.z > 1.0f);
		failures += Check("template car has four wheels", vehicle.WheelCount == 4);

		let bodyMesh = Assets.GetMesh("Models/sedan-body.glb");
		failures += Check("sedan body model loads", bodyMesh != null && bodyMesh.Vertices.Count > 0);
		let wheelMesh = Assets.GetMesh("Models/wheel-default.glb");
		failures += Check("wheel model loads", wheelMesh != null && wheelMesh.Vertices.Count > 0);
		failures += Check("engine loop is present", File.Exists(scope $"{assets}/Sounds/Car_Engine_Loop.ogg"));

		scene.StopPlay();
		Console.WriteLine(failures == 0 ? "PHYSICS VEHICLE TEMPLATE PASS" : scope $"PHYSICS VEHICLE TEMPLATE FAIL ({failures})");
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
