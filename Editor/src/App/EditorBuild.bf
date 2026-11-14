using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// Script templates offered by Project > Create > Script.
enum ScriptTemplateKind
{
	Basic,
	Movement,
	Timer,
	Gui,
	Networked,
	EcsData,
	EcsSynced,
	EcsMixed,
	EcsQuery,
	EcsBulk
}

/// Building: script rebuilds, restarts and game builds.
extension EditorApp
{
	void RebuildAndReload()
	{
		if (mManagedGameplay)
		{
			SaveAllScripts();
			if (HasCSharpSources(scope $"{Project.Current.Path}/src"))
				StartManagedErrorCheck();
			else
				mStatus.Set("No C# gameplay scripts to compile.");
			return;
		}
		if (mReloadReady)
		{
			SaveAllScripts();
			QueueScriptReload(true, true);
			return;
		}
		FullRebuildAndRestart();
	}

	/// Explicitly bypass method patching without rebuilding/restarting the whole editor.
	void ForceConservativeScriptReload()
	{
		if (!mReloadReady)
		{
			SaveAllScripts();
			mWantFullRestart = true;
			mBusyFrames = 3;
			return;
		}
		SaveAllScripts();
		QueueScriptReload(true, true, true);
	}

	void FullRebuildAndRestart()
	{
		// Managed gameplay uses the already-compiled engine. Even an explicit
		// rebuild in a C# project must not recompile the editor with Beef.
		if (mManagedGameplay)
		{
			RebuildAndReload();
			return;
		}
		if (mCheckRunning)
		{
			mStatus.Set("Wait for script compilation to finish before a full rebuild.");
			return;
		}
		let project = Project.Current;
		if (mPlay != .Edit)
			StopPlay();
		if (!mScene.Path.IsEmpty)
			SceneSerializer.SaveToFile(mScene, mScene.Path);
		Log.Info("Compiling scripts...");
		if (!project.Build(false))
		{
			let log = scope String();
			project.ReadBuildLog(log);
			ClearAndDeleteItems!(mProblems);
			ParseCompilerDiagnostics(log);
			AddDeterminismWarnings(scope $"{project.Path}/src", 0);
			PublishScriptDiagnostics();
			Log.Error("Compile failed. Fix the underlined script errors and choose File > Rebuild & Reload again.");
			return;
		}
		let command = scope String();
		let exe = scope String();
		project.GetExecutablePath(exe, false);
		Terminal.Quote(exe, command);
		command.Append(" --editor --project ");
		Terminal.Quote(project.Path, command);
		if (!mScene.Path.IsEmpty)
		{
			command.Append(" --scene ");
			Terminal.Quote(mScene.Path, command);
		}
		Terminal.RunDetached(command);
		Close();
	}

	void BuildGame()
	{
		let project = Project.Current;
		if (mCheckRunning)
		{
			mStatus.Set("Wait for the script error check to finish, then build again.");
			return;
		}
		SaveAllScripts();
		if (mPlay == .Edit)
			SaveScene(false);
		// The game only loads compiled shaders, so they must be current before it is packaged.
		CompileStaleShaders();
		let output = scope String();
		BuildOutputFolder(output);
		Log.Info(scope $"Building the {(mBuildEditor ? "editor" : "game")} for {(mBuildTarget == .Web ? "the web" : mBuildTarget.ToString(.. scope .()))}...");
		mBuildSucceeded = mBuildEditor ? project.PackageEngine(output, mBuildTarget) : project.BuildPlayer(output, mBuildTarget);
		if (mBuildSucceeded)
		{
			Log.Info(scope $"{(mBuildEditor ? "Editor" : "Game")} packaged at {output}");
			mBuildMessage.Set(scope $"Built. The {(mBuildEditor ? "editor" : "game")} is in {output}");
		}
		else
		{
			let log = scope String();
			project.ReadBuildLog(log);
			Log.Error(log);
			// The last line of the log is the reason; the whole log is in the Console.
			let lines = scope List<StringView>(log.Split('\n', .RemoveEmptyEntries));
			mBuildMessage.Set(scope $"The build failed: {(lines.IsEmpty ? "see the Console." : lines.Back)}");
		}
	}

	/// Create a managed C# gameplay source file in the current project folder.
	/// Game scripts live in Tallow.Game or the containing assembly definition.
	void CreateScript(StringView name) => CreateScript(name, .Basic);

	void CreateScript(StringView name, ScriptTemplateKind template)
	{
		let project = Project.Current;
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Script names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.cs";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		let text = scope String();
		switch (template)
		{
		case .Basic:
			text.AppendF("""
			using System.Numerics;
			using Tallow;

			namespace {0};

			[Component]
			public class {1} : Script
			{{
			    public float Speed = 1.0f;

			    public override void Start()
			    {{
			    }}

			    public override void Update(TickInput input, float deltaTime)
			    {{
			    }}
			}}
			""", project.Name, name);
		case .Movement:
			text.AppendF("""
			using System.Numerics;
			using Tallow;

			namespace {0};

			[Component]
			public class {1} : Script
			{{
			    public Vector3 Velocity = new(0, 0, 1);

			    public override void Update(TickInput input, float deltaTime)
			    {{
			        Transform.Position += Velocity * deltaTime;
			    }}
			}}
			""", project.Name, name);
		case .Timer:
			text.AppendF("""
			using Tallow;

			namespace {0};

			[Component]
			public class {1} : Script
			{{
			    public float Interval = 2.0f;
			    private float _elapsed;

			    public override void Update(TickInput input, float deltaTime)
			    {{
			        _elapsed += deltaTime;
			        if (_elapsed < Interval)
			            return;
			        _elapsed = 0;
			        OnTimer();
			    }}

			    private void OnTimer()
			    {{
			        // Repeated gameplay action.
			    }}
			}}
			""", project.Name, name);
		case .Gui:
			text.AppendF("""
			using Tallow;

			namespace {0};

			[Component]
			public class {1} : Script
			{{
			    public override void OnGUI()
			    {{
			        // Managed HUD APIs are being integrated.
			    }}
			}}
			""", project.Name, name);
		case .Networked:
			text.AppendF("""
			using Tallow;

			namespace {0};

			[Component]
			public class {1} : Script
			{{
			    [Sync] public float Speed = 1.0f;

			    public override void Update(TickInput input, float deltaTime)
			    {{
			        // Predicted gameplay. Use TickInput for controls.
			    }}

			    public override void OnLocalUpdate()
			    {{
			        if (!IsMine)
			            return;
			    }}
			}}
			""", project.Name, name);
		case .EcsData, .EcsSynced:
			text.AppendF("""
			using System.Numerics;
			using Tallow;

			namespace {0};

			[Component]
			public struct {1}
			{{
			    {2}public float Speed;
			    public Vector3 Velocity;
			}}
			""", project.Name, name, template == .EcsSynced ? "[Sync] " : "");
		case .EcsMixed:
			text.AppendF("""
			using Tallow;

			namespace {0};

			[Component]
			public struct {1}Data
			{{
			    public float Speed;
			}}

			[Component]
			public class {1} : Script
			{{
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        // ECS query/handle bindings are being implemented.
			    }}
			}}
			""", project.Name, name);
		case .EcsQuery, .EcsBulk:
			text.AppendF("""
			using Tallow;

			namespace {0};

			[Component]
			public struct {1}Data
			{{
			    public float Elapsed;
			}}

			[Component]
			public class {1} : Script
			{{
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        // Native packed ECS query bridge is not available yet.
			    }}
			}}
			""", project.Name, name);
		}
		if (File.WriteAllText(path, text) case .Ok)
		{
			Log.Info(scope $"Created C# script {path}.");
			OpenScript(path);
		}
		else
			Log.Error(scope $"Could not create C# script {path}.");
	}
}
