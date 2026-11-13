using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Starting content for new scenes and projects.
static class SceneTemplates
{
	static void AddSunAndCamera(Scene scene, Vector3 cameraPosition, Vector3 cameraEuler)
	{
		let camera = scene.CreateGameObject("Main Camera");
		camera.AddComponent<Camera>();
		camera.Transform.Position = cameraPosition;
		camera.Transform.EulerAngles = cameraEuler;

		let sun = scene.CreateGameObject("Directional Light");
		let light = sun.AddComponent<Light>();
		light.intensity = 1.5f;
		sun.Transform.Position = .(0, 6, 0);
		sun.Transform.EulerAngles = .(50, -30, 0);
	}

	/// Sun, camera and a floor; with withPlayer (a new project's first scene), the first-person character too if
	/// the project has it.
	public static void BuildDefault(Scene scene, bool withPlayer = false)
	{
		scene.Clear();
		AddSunAndCamera(scene, .(0, 3, -9), .(12, 0, 0));

		let ground = scene.CreateGameObject("Ground");
		let groundRenderer = ground.AddComponent<MeshRenderer>();
		groundRenderer.mesh.Set("builtin:plane");
		groundRenderer.color = .FromBytes(112, 158, 92);
		ground.Transform.LocalScale = .(4, 1, 4);
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = .(10, 0.2f, 10);
		groundCollider.center = .(0, -0.1f, 0);

		// A new empty project's first-person character (a visual script: Scripts/FirstPersonCharacter.tgraph).
		if (!withPlayer)
			return;
		let character = ComponentRegistry.Find(scope $"{Project.Current?.Name}.{FirstPersonTemplate.GraphName}");
		if (character == null)
			return;
		let player = scene.CreateGameObject("Player");
		player.Transform.Position = .(0, 1.1f, -4);
		let body = player.AddComponent<MeshRenderer>();
		body.mesh.Set("builtin:capsule");
		body.color = .FromBytes(235, 140, 60);
		let controller = player.AddComponent<CharacterController>();
		controller.radius = 0.5f;
		controller.height = 2;
		player.AddComponent(character.type);
	}

	static void AddByName(GameObject gameObject, StringView projectName, StringView typeName)
	{
		let info = ComponentRegistry.Find(scope $"{projectName}.{typeName}");
		if (info != null)
			gameObject.AddComponent(info.type);
		else
			Log.Warning(scope $"Template script {typeName} was not found in the project.");
	}

	/// Voxel world with a spawn platform, pushable networked crates and a hosted session.
	public static void BuildSample(Scene scene, StringView projectName)
	{
		scene.Clear();
		AddSunAndCamera(scene, .(0, 50, -14), .(20, 0, 0));
		scene.Environment.shadowDistance = 160;
		scene.Environment.fogDensity = 0.0035f;

		let camera = scene.Find("Main Camera");
		for (let script in StringView[?]("Digger", "Hud"))
		{
			let info = ComponentRegistry.Find(scope $"{projectName}.{script}");
			if (info != null)
				camera.AddComponent(info.type);
		}

		let terrain = scene.CreateGameObject("Terrain");
		// This sample is an open world to roam and dig in, so it uses generated terrain without end.
		let endless = terrain.AddComponent<VoxelTerrain>();
		endless.mode = .Endless;
		// An endless world is seen a long way off: coarser cells keep that affordable.
		endless.voxelSize = 1;

		let platform = scene.CreateGameObject("Spawn Platform");
		let platformRenderer = platform.AddComponent<MeshRenderer>();
		platformRenderer.color = .FromBytes(150, 150, 160);
		platform.Transform.Position = .(0, 40, 0);
		platform.Transform.LocalScale = .(16, 1, 16);
		platform.AddComponent<BoxCollider>();

		let spawn = scene.CreateGameObject("SpawnPoint");
		spawn.Transform.Position = .(0, 42, 0);
		spawn.AddComponent<SpawnPoint>();

		// A Hierarchy folder: pure organisation, it has no transform or components of its own.
		let props = scene.CreateGameObject("Props");
		props.IsFolder = true;
		for (int i < 6)
		{
			let crate = scene.CreateGameObject("Crate", props.Transform);
			let renderer = crate.AddComponent<MeshRenderer>();
			renderer.color = .FromBytes(196, 150, 92);
			crate.Transform.Position = .(-4 + (i % 3) * 1.2f, 41.1f + (i / 3) * 1.05f, 5);
			crate.AddComponent<BoxCollider>();
			crate.AddComponent<Rigidbody>();
			crate.AddComponent<NetworkIdentity>();
		}

		// A rigged, animated model (the same kind of file Blender exports) to show skinning.
		let rigged = scene.CreateGameObject("Rigged Sample");
		rigged.Transform.Position = .(-5, 40.5f, 4);
		let skinned = rigged.AddComponent<SkinnedMeshRenderer>();
		skinned.model.Set("Models/rigged_sample.glb");
		skinned.clip.Set("Wave");
		skinned.Refresh();

		let boulder = scene.CreateGameObject("Boulder");
		boulder.Transform.Position = .(4.5f, 42.4f, 1);
		let voxels = boulder.AddComponent<VoxelObject>();
		voxels.OnValidate();
		boulder.AddComponent<MeshCollider>();

		let fire = scene.CreateGameObject("Campfire");
		fire.Transform.Position = .(5, 40.6f, -4);
		let particles = fire.AddComponent<ParticleSystem>();
		particles.rate = 30;
		particles.speed = 2.2f;
		particles.lifetime = 1.6f;
		particles.gravity = .(0, 1.2f, 0);
		particles.startSize = 0.28f;

		let lamp = scene.CreateGameObject("Lamp");
		let light = lamp.AddComponent<Light>();
		light.type = .Point;
		light.color = .(1.0f, 0.55f, 0.25f);
		light.intensity = 8;
		light.range = 14;
		lamp.Transform.Position = .(5, 43, -4);

		// An example interface built from UI/sample_menu.tui. It starts switched off; tick the
		// checkbox next to its name in the Inspector to see it in play mode.
		let menu = scene.CreateGameObject("Sample Menu");
		let document = menu.AddComponent<UIDocument>();
		document.document.Set("UI/sample_menu.tui");
		AddByName(menu, projectName, "SampleMenu");
		menu.SetActive(false);

		let session = scene.CreateGameObject("Network Session");
		session.AddComponent<NetworkSession>();
	}
}
