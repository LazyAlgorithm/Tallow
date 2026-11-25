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
		// New scenes run a day / night clock (older scenes keep it off: the class default).
		scene.Environment.dayNight = true;
		scene.Environment.timeOfDay = 10;
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
		// C# projects: the template's Scripts/FirstPersonCharacter.cs, run by the
		// managed adapter component. A legacy native project has a Beef class.
		let character = ComponentRegistry.Find(scope $"{Project.Current?.Name}.{FirstPersonTemplate.GraphName}");
		let managedSource = scope $"{Project.Current?.Path}/src/Scripts/{FirstPersonTemplate.GraphName}.cs";
		let managed = character == null && Project.Current != null && System.IO.File.Exists(managedSource);
		if (character == null && !managed)
			return;
		let player = scene.CreateGameObject("Player");
		player.Transform.Position = .(0, 1.1f, -4);
		let body = player.AddComponent<MeshRenderer>();
		body.mesh.Set("builtin:capsule");
		body.color = .FromBytes(235, 140, 60);
		let controller = player.AddComponent<CharacterController>();
		controller.radius = 0.5f;
		controller.height = 2;
		if (managed)
		{
			let script = player.AddComponent<CSharpBehaviour>();
			if (script != null)
				script.scriptType.Set(scope $"{Project.Current.Name}.{FirstPersonTemplate.GraphName}");
		}
		else
			player.AddComponent(character.type);
	}

	/// A third-person character: the sample's animated character on a CharacterController, moved by CharacterMotor,
	/// with the follow camera and animation scripts. Put a Network Identity on it too, so it runs from tick input.
	public static void BuildThirdPerson(Scene scene, StringView projectName)
	{
		scene.Clear();
		AddSunAndCamera(scene, .(0, 3, -9), .(12, 0, 0));

		let ground = scene.CreateGameObject("Ground");
		let groundRenderer = ground.AddComponent<MeshRenderer>();
		groundRenderer.mesh.Set("builtin:plane");
		groundRenderer.color = .FromBytes(112, 158, 92);
		ground.Transform.LocalScale = .(6, 1, 6);
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = .(20, 0.2f, 20);
		groundCollider.center = .(0, -0.1f, 0);

		let player = scene.CreateGameObject("Player");
		player.Transform.Position = .(0, 1.1f, -4);
		let model = Prefab.Create(scene, "Prefabs/character.tprefab");
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
		let controller = player.AddComponent<CharacterController>();
		controller.radius = 0.5f;
		controller.height = 2;
		player.AddComponent<NetworkIdentity>();
		player.AddComponent<CharacterMotor>();
		AddByName(player, projectName, "FollowCamera");
		AddByName(player, projectName, "CharacterAnimation");
	}

	/// A drivable car: the Kenney sedan body on a rigid chassis, four visible wheels turned by the Vehicle component,
	/// a chase camera and a CC0 engine loop. The CarController script reads the tick input and drives it.
	public static void BuildVehicle(Scene scene, StringView projectName)
	{
		scene.Clear();
		AddSunAndCamera(scene, .(0, 3.2f, -8), .(12, 0, 0));

		let ground = scene.CreateGameObject("Ground");
		let groundRenderer = ground.AddComponent<MeshRenderer>();
		groundRenderer.mesh.Set("builtin:plane");
		groundRenderer.color = .FromBytes(112, 158, 92);
		ground.Transform.LocalScale = .(40, 1, 40);
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = .(200, 0.2f, 200);
		groundCollider.center = .(0, -0.1f, 0);

		let road = scene.CreateGameObject("Road");
		let roadRenderer = road.AddComponent<MeshRenderer>();
		roadRenderer.mesh.Set("builtin:cube");
		roadRenderer.color = .FromBytes(52, 54, 58);
		road.Transform.LocalScale = .(9, 0.02f, 200);
		road.Transform.Position = .(0, 0.02f, 0);

		let car = scene.CreateGameObject("Car");
		car.Transform.Position = .(0, 0.6f, 0);
		let chassis = car.AddComponent<BoxCollider>();
		chassis.size = .(1.5f, 0.9f, 2.6f);
		let rigidbody = car.AddComponent<Rigidbody>();
		rigidbody.mass = 1300;
		rigidbody.linearDamping = 0.1f;
		rigidbody.angularDamping = 0.3f;
		rigidbody.allowSleeping = false;
		let vehicle = car.AddComponent<Vehicle>();
		vehicle.maxTorque = 320;

		let body = scene.CreateGameObject("Car Body", car.Transform);
		body.Transform.LocalPosition = .(0, -0.6f, 0);
		// The Kenney model's nose points down -Z; the car's forward is +Z.
		body.Transform.LocalRotation = Quaternion.AngleAxis(180, Vector3.Up);
		let bodyRenderer = body.AddComponent<MeshRenderer>();
		bodyRenderer.mesh.Set("Models/sedan-body.glb");

		void Wheel(StringView name, Vector3 position, float yaw)
		{
			let wheel = scene.CreateGameObject(name, car.Transform);
			wheel.Transform.LocalPosition = position;
			// The Kenney wheel's face points the other way; mirrored wheels take opposite yaws. CarController applies
			// the same values in play.
			wheel.Transform.LocalRotation = Quaternion.AngleAxis(yaw, Vector3.Up);
			let renderer = wheel.AddComponent<MeshRenderer>();
			renderer.mesh.Set("Models/wheel-default.glb");
		}
		Wheel("Wheel FL", .(-0.6f, -0.3f, 0.66f), 180);
		Wheel("Wheel FR", .(0.6f, -0.3f, 0.66f), 0);
		Wheel("Wheel RL", .(-0.6f, -0.3f, -0.66f), 180);
		Wheel("Wheel RR", .(0.6f, -0.3f, -0.66f), 0);

		let audio = car.AddComponent<AudioSource>();
		audio.audioClip.Set("Sounds/Car_Engine_Loop.ogg");
		audio.loop = true;
		audio.playOnStart = true;
		audio.volume = 0.5f;
		audio.spatial = true;
		// The chase camera moves with the car, so Doppler would only add a second pitch shift on top of the engine.
		audio.doppler = 0;
		// The camera is right behind the car; its own body would otherwise occlude the engine and make the note
		// flicker at speed.
		audio.occlusion = false;
		audio.minDistance = 4;
		audio.maxDistance = 60;

		AddByName(car, projectName, "CarController");
		if (let camera = scene.Find("Main Camera"))
			AddByName(camera, projectName, "CarCamera");
	}

	/// Adds a template script: the project's C# Scripts/{typeName}.cs (run by the managed adapter component), or a
	/// Beef component of that name in a legacy native project.
	static void AddByName(GameObject gameObject, StringView projectName, StringView typeName)
	{
		let info = ComponentRegistry.Find(scope $"{projectName}.{typeName}");
		if (info != null)
		{
			gameObject.AddComponent(info.type);
			return;
		}
		if (Project.Current != null && System.IO.File.Exists(scope $"{Project.Current.Path}/src/Scripts/{typeName}.cs"))
		{
			let script = gameObject.AddComponent<CSharpBehaviour>();
			if (script != null)
				script.scriptType.Set(scope $"{projectName}.{typeName}");
			return;
		}
		Log.Warning(scope $"Template script {typeName} was not found in the project.");
	}

	public const StringView SamplePlayerPrefab = "Prefabs/Player.tprefab";

	/// The sample's networked player, saved as a prefab for the Network Session to spawn for each player: the
	/// animated character on a Character Controller, moved by the built-in Character Motor, with the C# follow camera
	/// and animation scripts.
	static void SaveSamplePlayer(Scene scene, StringView projectName)
	{
		let player = scene.CreateGameObject("Player");
		// The visible body is the sample animated character; a plain capsule stands in if it is missing.
		let model = Prefab.Create(scene, "Prefabs/character.tprefab");
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
		AddByName(player, projectName, "FollowCamera");
		AddByName(player, projectName, "CharacterAnimation");
		let path = scope String();
		Assets.ResolvePath(SamplePlayerPrefab, path);
		if (!Prefab.Save(player, path))
			Log.Warning(scope $"Could not write the sample player prefab {path}.");
		scene.DestroyImmediate(player);
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
			AddByName(camera, projectName, script);

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

		SaveSamplePlayer(scene, projectName);
		let session = scene.CreateGameObject("Network Session");
		let network = session.AddComponent<NetworkSession>();
		if (network != null)
			network.playerPrefab.Set(SamplePlayerPrefab);
	}
}
