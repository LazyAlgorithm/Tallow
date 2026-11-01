using System;
using System.Collections;
using System.IO;
using Tessera;

namespace Tessera.Editor;

/// Creates new projects from built-in templates.
static class ProjectGenerator
{
	public static bool IsValidName(StringView name)
	{
		if (name.IsEmpty || name.Length > 48 || name[0].IsDigit)
			return false;
		for (let c in name.RawChars)
		{
			if (!c.IsLetterOrDigit && c != '_')
				return false;
		}
		return true;
	}

	/// Finds the engine folder (the one containing Engine/ and Editor/) from the running executable.
	public static bool FindEngineRoot(String outRoot)
	{
		let env = scope String();
		if (Environment.GetEnvironmentVariable("TESSERA_ROOT", env) case .Ok && !env.IsEmpty && Directory.Exists(scope $"{env}/Engine/src"))
		{
			// Forward slashes throughout, also on Windows: the path is written into build files where a backslash
			// would start an escape.
			env.Replace('\\', '/');
			if (env.EndsWith("/."))
				env.RemoveFromEnd(2);
			outRoot.Set(env);
			return true;
		}
		// Gfx.EngineAssetPath is <root>/Engine/assets, possibly with ../ segments.
		if (!Gfx.EngineAssetPath.IsEmpty)
		{
			let candidate = scope String();
			candidate.AppendF("{}/../..", Gfx.EngineAssetPath);
			let full = scope String();
			Normalize(candidate, full);
			if (Directory.Exists(scope $"{full}/Engine/src"))
			{
				outRoot.Set(full);
				while (outRoot.EndsWith('/') && outRoot.Length > 1)
					outRoot.RemoveFromEnd(1);
				return true;
			}
		}
		return false;
	}

	/// Collapses "." and ".." segments and repeated slashes in an absolute path.
	public static void Normalize(StringView path, String outPath)
	{
		List<StringView> parts = scope .();
		let forward = scope String(path)..Replace('\\', '/');
		for (let part in forward.Split('/'))
		{
			if (part.IsEmpty || part == ".")
				continue;
			if (part == "..")
			{
				if (parts.Count > 0)
					parts.PopBack();
				continue;
			}
			parts.Add(part);
		}
		for (let part in parts)
		{
			// A Windows path starts with its drive (C:), not with a slash.
			if (!(@part.Index == 0 && part.EndsWith(':')))
				outPath.Append('/');
			outPath.Append(part);
		}
		if (outPath.IsEmpty)
			outPath.Append('/');
	}

	static void Write(StringView path, StringView text)
	{
		if (File.WriteAllText(path, text) case .Err)
			Log.Error(scope $"Could not write {path}");
	}

	/// The project's folders: src (the assets) with its usual subfolders, and Libraries.
	static bool CreateFolders(StringView folder, String error)
	{
		for (let sub in StringView[?]("", "/src", "/src/Scripts", "/src/Scenes", "/src/Models", "/src/Textures", "/src/Prefabs", "/Libraries"))
		{
			if (Directory.CreateDirectory(scope $"{folder}{sub}") case .Err)
			{
				if (!Directory.Exists(scope $"{folder}{sub}"))
				{
					error.Set(scope $"Could not create {folder}{sub}");
					return false;
				}
			}
		}
		return true;
	}

	/// The scripts every new project starts with: Program.bf (plumbing, hidden in the editor), GameSetup.bf where
	/// the game's start-up code goes, and the sample's Spinner, FollowCamera, Digger and Hud.
	static void WriteStarterScripts(StringView folder, StringView name)
	{
		Write(scope $"{folder}/src/Program.bf" , scope String()..AppendF("""
			using System;
			using Tessera.Editor;

			namespace {0};

			class Program
			{{
				public static int Main(String[] args)
				{{
					GameSetup.Register();
					// Opens the editor when started with --editor, otherwise runs the game.
					return EditorMain.Run(args);
				}}
			}}

			""", name));

		Write(scope $"{folder}/src/Scripts/GameSetup.bf" , scope String()..AppendF("""
			using System;
			using Tessera;

			namespace {0};

			/// Runs once when the game or editor starts, before any scene loads.
			/// Keep this class and its Register method; put one-time setup here.
			static class GameSetup
			{{
				public static void Register()
				{{
					// Network prefabs must be registered identically on the server and every client.
					NetworkManager.RegisterPrefab("Player", new => CreatePlayer);
				}}

				static GameObject CreatePlayer(Scene scene)
				{{
					let player = scene.CreateGameObject("Player");
					// The visible body is the sample animated character; a plain capsule stands in if it is missing.
					let model = Prefab.Instantiate(scene, "Prefabs/character.tprefab");
					if (model != null)
					{{
						model.Transform.SetParent(player.Transform, false);
						model.Transform.LocalPosition = .(0, -1, 0);
					}}
					else
					{{
						let renderer = player.AddComponent<MeshRenderer>();
						renderer.mesh.Set("builtin:capsule");
						renderer.color = .FromBytes(235, 140, 60);
					}}
					// A character controller walks up steps and stays on slopes, which a capsule rigid body cannot.
					let controller = player.AddComponent<CharacterController>();
					controller.radius = 0.5f;
					controller.height = 2;
					player.AddComponent<NetworkIdentity>();
					player.AddComponent<CharacterMotor>();
					player.AddComponent<FollowCamera>();
					player.AddComponent<CharacterAnimation>();
					return player;
				}}
			}}

			""", name));

		Write(scope $"{folder}/src/Scripts/Spinner.bf" , scope String()..AppendF("""
			using System;
			using Tessera;

			namespace {0};

			/// Example component: rotates its object. Public fields show up in the Inspector.
			[Component]
			class Spinner : Component
			{{
				public Vector3 degreesPerSecond = .(0, 45, 0);

				public override void Update()
				{{
					Transform.Rotate(degreesPerSecond * Time.DeltaTime);
				}}
			}}

			""", name));

		Write(scope $"{folder}/src/Scripts/FollowCamera.bf" , scope String()..AppendF("""
			using System;
			using Tessera;

			namespace {0};

			/// Third-person camera for the object this client controls.
			[Component]
			class FollowCamera : Component
			{{
				public float distance = 7.0f;
				public float height = 2.5f;

				public override void LateUpdate()
				{{
					let identity = GetComponent<NetworkIdentity>();
					if (identity != null && Scene.Network != null && !identity.IsOwner)
						return;
					let camera = Scene.FindComponent<Camera>();
					let motor = GetComponent<CharacterMotor>();
					if (camera == null)
						return;
					let yaw = motor != null ? motor.Yaw : 0;
					let pitch = motor != null ? motor.Pitch : 0;
					let rotation = Quaternion.Euler(pitch + 15, yaw, 0);
					let target = Transform.Position + Vector3(0, height * 0.5f, 0);
					camera.Transform.Position = target - rotation * Vector3.Forward * distance;
					camera.Transform.Rotation = rotation;
				}}
			}}

			""", name));

		Write(scope $"{folder}/src/Scripts/Digger.bf" , scope String()..AppendF("""
			using System;
			using Tessera;

			namespace {0};

			/// Left click digs, middle click builds, aimed with the main camera. Works on voxel terrain
			/// and on destructible VoxelObjects (which break apart when cut through).
			[Component]
			class Digger : Component
			{{
				public float radius = 3.0f;
				public float strength = 1.5f;

				public override void Update()
				{{
					let dig = Input.GetMouseButton(0);
					let build = Input.GetMouseButton(2);
					if (!dig && !build)
						return;
					let camera = Scene.FindComponent<Camera>();
					if (camera == null)
						return;
					RaycastHit hit;
					if (!Scene.Physics.Raycast(camera.Transform.Position, camera.Transform.Forward, 200, out hit))
						return;
					let voxels = hit.gameObject != null ? hit.gameObject.GetComponent<VoxelObject>() : null;
					if (voxels != null)
					{{
						if (dig)
							voxels.Carve(hit.point, radius * 0.3f);
						return;
					}}
					let terrain = Scene.FindComponent<VoxelTerrain>();
					if (terrain != null)
						terrain.ModifySphere(hit.point, radius, (dig ? -strength : strength) * Time.DeltaTime * 4);
				}}
			}}

			""", name));

		Write(scope $"{folder}/src/Scripts/Hud.bf" , scope String()..AppendF("""
			using System;
			using Tessera;

			namespace {0};

			/// Example in-game interface drawn with the GUI class.
			[Component]
			class Hud : Component
			{{
				bool mShowHelp = true;

				public override void OnGUI()
				{{
					GUI.Box(12, 12, 250, mShowHelp ? 118 : 34, .(0, 0, 0, 0.45f));
					GUI.Label(22, 20, scope $"{{(int)Time.SmoothedFps}} fps");
					if (GUI.Button(170, 16, 82, 24, mShowHelp ? "Hide help" : "Help"))
						mShowHelp = !mShowHelp;
					if (mShowHelp)
					{{
						GUI.Label(22, 48, "WASD move, Space jump");
						GUI.Label(22, 66, "Hold right mouse to look");
						GUI.Label(22, 84, "Left mouse digs, middle builds");
						GUI.Label(22, 102, "Dig through the boulder to break it");
					}}
					let network = Scene.Network;
					if (network != null && network.Mode != .Offline)
						GUI.Label(GUI.Width - 220, 20, scope $"{{network.Mode}}  tick {{network.Tick}}");
				}}
			}}

			""", name));
	}

	/// Creates the folder structure and source files. sample adds a voxel world with a networked player.
	public static bool Create(StringView folder, StringView name, StringView engineRoot, bool sample, String error)
	{
		if (!IsValidName(name))
		{
			error.Set("Project names use letters, digits and underscores, and start with a letter.");
			return false;
		}
		if (Directory.Exists(folder) && File.Exists(scope $"{folder}/project.tessera"))
		{
			error.Set("A project already exists in that folder.");
			return false;
		}
		if (!CreateFolders(folder, error))
			return false;

		let project = scope Project();
		project.Name.Set(name);
		project.Path.Set(folder);
		project.EngineRoot.Set(engineRoot);
		project.Save();

		// Packaged engines carry immutable identity. New projects are pinned
		// before the first build; source checkouts without a manifest stay legacy.
		if (File.Exists(scope $"{engineRoot}/tessera-version.json"))
		{
			let command = scope String("python3 ");
			Terminal.Quote(scope $"{engineRoot}/tools/engine_versions.py", command);
			command.Append(" pin-new ");
			Terminal.Quote(folder, command);
			command.Append(" ");
			Terminal.Quote(engineRoot, command);
			if (Terminal.Run(command) != 0)
			{
				error.Set("Could not pin the new project to this Tessera engine build.");
				return false;
			}
		}

		project.WriteBuildFiles();

		Write(scope $"{folder}/.gitignore" , "build/\nrecovery/\n.cache/\nBeefSpace.toml\nBeefProj.toml\n");

		WriteStarterScripts(folder, name);

		// The first scene is built by the editor the first time the project opens.
		// Shared sample content: the animated character, its clips and the script that drives them.
		let common = scope $"{engineRoot}/Editor/templates/common";
		for (let sub in StringView[?]("Scripts", "Prefabs", "Animations", "Models", "UI", "Materials", "Shaders", "Textures"))
		{
			Directory.CreateDirectory(scope $"{folder}/src/{sub}").IgnoreError();
			if (!Directory.Exists(scope $"{common}/{sub}"))
				continue;
			for (let entry in Directory.EnumerateFiles(scope $"{common}/{sub}"))
			{
				let fileName = scope String();
				entry.GetFileName(fileName);
				if (fileName.EndsWith(".txt"))
				{
					let text = scope String();
					if (File.ReadAllText(scope $"{common}/{sub}/{fileName}" , text, true) case .Err)
						continue;
					text.Replace("{NAMESPACE}", name);
					fileName.Replace(".txt", "");
					Write(scope $"{folder}/src/{sub}/{fileName}" , text);
				}
				else
					File.Copy(scope $"{common}/{sub}/{fileName}" , scope $"{folder}/src/{sub}/{fileName}").IgnoreError();
			}
		}
		Write(scope $"{folder}/.template" , sample ? "sample" : "empty");
		return true;
	}
}
