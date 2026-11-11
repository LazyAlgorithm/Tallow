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
	Networked
}

/// Building: script rebuilds, restarts and game builds.
extension EditorApp
{
	void RebuildAndReload()
	{
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
			AddDeterminismWarnings(scope $"{project.Path}/src" , 0);
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

	/// The old quick-create action keeps the familiar basic Script template.
	void CreateScript(StringView name) => CreateScript(name, .Basic);

	void CreateScript(StringView name, ScriptTemplateKind template)
	{
		let project = Project.Current;
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Script names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.bf";
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
			using System;
			using Tallow;
			
			namespace {0};
			
			/// A regular gameplay component. Attach it to any GameObject.
			[Component]
			class {1} : Component
			{{
			    public float speed = 1.0f;
			
			    public override void Start()
			    {{
			    }}
			
			    public override void Update()
			    {{
			    }}
			}}
			""", project.Name, name);
		case .Movement:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Example motion script: turns its object every frame.
			[Component]
			class {1} : Component
			{{
			    public Vector3 degreesPerSecond = .(0, 45, 0);
			
			    public override void Update()
			    {{
			        Transform.Rotate(degreesPerSecond * Time.DeltaTime);
			    }}
			}}
			""", project.Name, name);
		case .Timer:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Reusable timed action using normal script state, not a coroutine.
			[Component]
			class {1} : Component
			{{
			    public float interval = 2.0f;
			    private float mElapsed;
			
			    public override void Update()
			    {{
			        mElapsed += Time.DeltaTime;
			        if (mElapsed < interval)
			            return;
			        mElapsed = 0;
			        OnTimer();
			    }}
			
			    void OnTimer()
			    {{
			        // Put the repeated action here.
			    }}
			}}
			""", project.Name, name);
		case .Gui:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Immediate-mode HUD; drawn by the engine while the game is running.
			[Component]
			class {1} : Component
			{{
			    public override void OnGUI()
			    {{
			        GUI.Label(20, 20, "Hello from {1}");
			    }}
			}}
			""", project.Name, name);
		case .Networked:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Needs a NetworkIdentity on the same GameObject. OnTick runs on the server and is predicted on the
			/// owner's machine, so take controls from TickInput, never from Input.
			[Component]
			class {1} : NetworkScript
			{{
			    [Sync] public float degreesPerSecond = 45.0f;
			
			    public override void OnTick(TickInput input, float deltaTime)
			    {{
			        Transform.Rotate(.(0, degreesPerSecond * deltaTime, 0));
			    }}
			
			    public override void Update()
			    {{
			        if (!IsOwner)
			            return;
			        // Presentation for the player who owns this object belongs here.
			    }}
			}}
			""", project.Name, name);
		}
		if (File.WriteAllText(path, text) case .Ok)
		{
			Log.Info(scope $"Created {path}. Script changes are detected automatically.");
			OpenScript(path);
		}
		else
			Log.Error(scope $"Could not create script {path}.");
	}
}
