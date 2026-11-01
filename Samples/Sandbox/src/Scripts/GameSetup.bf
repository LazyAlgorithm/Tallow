using System;
using Tallow;

namespace Sandbox;

/// Runs once when the game or editor starts, before any scene loads.
/// Keep this class and its Register method; put one-time setup here.
static class GameSetup
{
	public static void Register()
	{
		// Network prefabs must be registered identically on the server and every client.
		NetworkManager.RegisterPrefab("Player", new => CreatePlayer);
	}

	static GameObject CreatePlayer(Scene scene)
	{
		let player = scene.CreateGameObject("Player");
		// The visible body is the sample animated character; a plain capsule stands in if it is missing.
		let model = Prefab.Instantiate(scene, "Prefabs/character.tprefab");
		if (model != null)
		{
			model.Transform.SetParent(player.Transform, false);
			model.Transform.LocalPosition = .(0, -1, 0);
		}
		else
		{
			let renderer = player.AddComponent<MeshRenderer>();
			renderer.mesh.Set("builtin:capsule");
			renderer.color = .FromBytes(235, 140, 60);
		}
		// A character controller walks up steps and stays on slopes, which a capsule rigid body cannot.
		let controller = player.AddComponent<CharacterController>();
		controller.radius = 0.5f;
		controller.height = 2;
		player.AddComponent<NetworkIdentity>();
		player.AddComponent<CharacterMotor>();
		player.AddComponent<FollowCamera>();
		player.AddComponent<CharacterAnimation>();
		// F shoots heavy balls where the screen's middle points.
		player.AddComponent<BallLauncher>();
		return player;
	}
}
