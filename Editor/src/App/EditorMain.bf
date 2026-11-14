using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Entry point shared by every project executable: the editor with --editor, otherwise the game.
/// The start-up class of a project with no Program.bf of its own (a new project starts with none): opens the editor
/// when started with --editor, otherwise runs the game. A project that needs start-up code adds src/Program.bf
/// with its own Main (see ProjectGenerator) and the build uses that instead.
class DefaultProgram
{
	public static int Main(String[] args) => EditorMain.Run(args);
}

static class EditorMain
{
	public static int Run(String[] args)
	{
		// The compiler and Python that Tallow installed for itself, if it did (Toolchain).
		Toolchain.Apply();
		bool editor = false;
		bool server = false;
		String projectPath = scope .();
		for (int i < args.Count)
		{
			let arg = args[i];
			if (arg == "--editor")
				editor = true;
			else if (arg == "--server")
			{
				server = true;
				NetworkSession.ModeOverride = .Server;
			}
			else if (arg == "--host")
				NetworkSession.ModeOverride = .Host;
			else if (arg == "--bot")
				NetworkSession.BotOverride = true;
			else if (arg == "--connect" && i + 1 < args.Count)
			{
				NetworkSession.ModeOverride = .Client;
				NetworkSession.AddressOverride.Set(args[i + 1]);
			}
			else if (arg == "--port" && i + 1 < args.Count)
				NetworkSession.PortOverride = SceneSerializer.ParseInt(args[i + 1]);
			else if (arg == "--jitter" && i + 1 < args.Count)
				NetworkManager.SimulatedJitterMs = Math.Max(0, SceneSerializer.ParseInt(args[i + 1]));
			else if (arg == "--netstats")
				NetworkManager.LogStats = true;
			else if (arg == "--net-describe" && i + 1 < args.Count)
				NetworkManager.DescribeAtTick = (int32)SceneSerializer.ParseInt(args[i + 1]);
			else if (arg == "--lag" && i + 1 < args.Count)
				NetworkManager.SimulatedLagMs = Math.Max(0, SceneSerializer.ParseInt(args[i + 1]));
			else if (arg == "--loss" && i + 1 < args.Count)
				NetworkManager.SimulatedLossPercent = Mathf.Clamp(SceneSerializer.ParseFloat(args[i + 1]), 0, 100);
			else if (arg == "--project" && i + 1 < args.Count)
				projectPath.Set(args[i + 1]);
		}

		if (projectPath.IsEmpty)
			FindProjectFromExecutable(projectPath);
		let project = new Project();
		if (!project.Load(projectPath))
		{
			delete project;
			Console.WriteLine("No project.tallow found. Pass --project <folder>.");
			return 1;
		}
		Project.Current = project;
		project.GetAssetPath(Assets.ProjectPath);
		GamePaths.SetGameFolder(project.Path);
		// A built game takes its name from its manifest; here it is the project's from the start, so that a map
		// exported before Play was ever pressed says which game it is for.
		GamePaths.Game.Set(project.Name);
		if (!project.EngineRoot.IsEmpty)
			Environment.SetEnvironmentVariable("TALLOW_ROOT", project.EngineRoot);

		Steam.AppId = (uint32)project.SteamAppId;
		Audio.Hrtf = project.AudioHrtf;
		project.ApplyVoice();
		ApiIndex.SetRoots(project.EngineRoot, project.Path);
		Achievements.SaveName.Set(project.Name);
		if (editor)
		{
			let app = scope EditorApp();
			return app.Run(args);
		}
		let app = scope PlayerApp();
		app.GameName.Set(project.Name);
		app.StartScene.Set(project.StartScene);
		app.Headless = server;
		return app.Run(args);
	}

	/// Walks up from the executable looking for project.tallow (it lives in <project>/build/<config>/<name>/).
	static void FindProjectFromExecutable(String outPath)
	{
		let basePath = SDL.SDL_GetBasePath();
		if (basePath == null)
			return;
		let dir = scope String(basePath);
		for (int i < 6)
		{
			if (File.Exists(scope $"{dir}project.tallow"))
			{
				let full = scope String();
				ProjectGenerator.Normalize(dir, full);
				outPath.Set(full);
				return;
			}
			dir.Append("../");
		}
	}

	/// Loads the project's start scene, building it from the project template on first use.
	public static void LoadStartScene(Scene scene, StringView overridePath = default)
	{
		let project = Project.Current;
		let path = scope String();
		if (!overridePath.IsEmpty)
			Assets.ResolvePath(overridePath, path);
		else
			path.AppendF("{}/{}", Assets.ProjectPath, project.StartScene);
		if (File.Exists(path))
		{
			SceneSerializer.LoadFromFile(scene, path);
			return;
		}
		let template = scope String();
		File.ReadAllText(scope $"{project.Path}/.template" , template).IgnoreError();
		template.Trim();
		if (template == "sample")
			SceneTemplates.BuildSample(scene, project.Name);
		else
			SceneTemplates.BuildDefault(scene, true);
		scene.Name.Set("Main");
		let sceneFolder = scope String();
		if (Path.GetDirectoryPath(path, sceneFolder) case .Ok)
			Directory.CreateDirectory(sceneFolder).IgnoreError();
		SceneSerializer.SaveToFile(scene, path);
	}
}

/// The game run on its own from a development build (no --editor): it keeps the editor's first-run scene
/// templates, which built games do not have.
class PlayerApp : GameApp
{
	Scene mManagedScene;

	protected override bool LoadScene(Scene scene, StringView overridePath)
	{
		EditorMain.LoadStartScene(scene, overridePath);
		let project = Project.Current;
		let game = scope $"{project.Path}/.tallow-csharp/bin/Tallow.Game/Tallow.Game.dll";
		if (File.Exists(game))
		{
			if (!CSharpRuntime.StartTrustedGame(scene, project.EngineRoot, project.Path))
				return false;
			mManagedScene = scene;
		}
		else
		{
			// Do not silently run a C# scene with all its managed behaviours
			// disabled when the game DLL has not yet been built.
			for (let component in scene.Components)
			{
				if (component as CSharpBehaviour != null)
				{
					Log.Error("This scene contains C# scripts, but the gameplay assembly is missing. Compile C# in the editor first.");
					return false;
				}
			}
		}
		return true;
	}

	protected override void OnShutdown()
	{
		base.OnShutdown();
		if (mManagedScene != null)
		{
			CSharpRuntime.EndTrustedGame(mManagedScene);
			mManagedScene = null;
		}
	}
}
