using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Headless check of the project templates' first scenes. Run with:
///   TallowLauncher --test-template-scenes <a third-person project folder>
static class TemplateScenesTest
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
			Console.WriteLine(scope $"Template scenes test: {assets} is missing.");
			return 1;
		}
		Assets.ProjectPath.Set(assets);

		{
			let scene = scope Scene();
			SceneTemplates.BuildDefault(scene, false);
			failures += Check("empty template has no player", scene.Find("Player") == null);
			failures += Check("empty template has a camera", scene.Find("Main Camera") != null);
			failures += Check("empty template has a floor", scene.Find("Ground") != null);
		}

		{
			let scene = scope Scene();
			SceneTemplates.BuildThirdPerson(scene, "");
			let player = scene.Find("Player");
			failures += Check("third-person template has a player", player != null);
			if (player != null)
			{
				let p = player;
				failures += Check("third-person player has a CharacterController", p.GetComponent<CharacterController>().IsValid);
				failures += Check("third-person player has a CharacterMotor", p.GetComponent<CharacterMotor>() != null);
				failures += Check("third-person player has a NetworkIdentity", p.GetComponent<NetworkIdentity>() != null);
			}
		}

		{
			let scene = scope Scene();
			SceneTemplates.BuildVehicle(scene, "");
			let car = scene.Find("Car");
			failures += Check("car template has a Car", car != null);
			if (car != null)
			{
				let c = car;
				failures += Check("car template has a Vehicle", c.GetComponent<Vehicle>() != null);
				failures += Check("car template has a Rigidbody", c.GetComponent<Rigidbody>().IsValid);
			}
		}

		Console.WriteLine(failures == 0 ? "PHYSICS TEMPLATE SCENES PASS" : scope $"PHYSICS TEMPLATE SCENES FAIL ({failures})");
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
