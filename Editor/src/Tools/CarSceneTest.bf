using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Loads a saved car scene, starts play, drives the Vehicle component directly for three seconds and checks the car
/// travelled forward. This is the path a project made from the Drivable Car template takes. Run with:
///   TallowLauncher --test-car-scene <project>/src/Scenes/Main.tscene [--physics3d Rapier]
static class CarSceneTest
{
	public static int Run(StringView scenePath)
	{
		let project = scope String(scenePath);
		let scenesAt = project.IndexOf("/Scenes/");
		if (scenesAt > 0)
			project.RemoveFromEnd(project.Length - scenesAt);
		Assets.ProjectPath.Set(scope $"{project}/src");
		let scene = scope Scene();
		if (!SceneSerializer.LoadFromFile(scene, scenePath))
		{
			Console.WriteLine("load failed");
			return 1;
		}
		let car = scene.Find("Car");
		Console.WriteLine(scope $"car {car != null}");
		if (car == null)
			return 1;
		scene.StartPlay();
		scene.FixedUpdate();
		let vehicle = car.GetComponent<Vehicle>();
		bool ready = vehicle != null && vehicle.IsReady;
		int32 wheels = vehicle != null ? vehicle.WheelCount : 0;
		Console.WriteLine(scope $"vehicle {vehicle != null} ready {ready} wheels {wheels}");
		if (vehicle == null || !vehicle.IsReady)
			return 1;
		vehicle.SetDriverInput(1, 0, 0, 0);
		for (int i < 180)
			scene.FixedUpdate();
		let position = car.Transform.Position;
		Console.WriteLine(scope $"car pos {position} speed {vehicle.Speed} rpm {vehicle.EngineRPM} gear {vehicle.Gear}");
		Console.WriteLine(position.z > 1.0f ? "CAR MOVED" : "CAR DID NOT MOVE");
		scene.StopPlay();
		return position.z > 1.0f ? 0 : 1;
	}
}
