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
		// The namespace of the assembly the folder belongs to (its .tasmdef root namespace), else the project's.
		let scriptNamespace = scope String();
		ScriptNamespaceFor(mBrowsePath, scriptNamespace);
		let text = scope String();
		ScriptTemplateText(template, scriptNamespace, name, text);
		if (File.WriteAllText(path, text) case .Ok)
		{
			Log.Info(scope $"Created C# script {path}.");
			OpenScript(path);
			mManagedBuildReady = false;
			if (mCheckRunning)
				mManagedRecheckQueued = true;
			else if (mPlay == .Edit && Project.Current.ReloadMode != .Manual)
				StartManagedErrorCheck();
		}
		else
			Log.Error(scope $"Could not create C# script {path}.");
	}

	/// The text of a new C# script made from a template (the Project panel's Create > C# Script menu).
	public static void ScriptTemplateText(ScriptTemplateKind template, StringView scriptNamespace, StringView name, String text)
	{
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
			""", scriptNamespace, name);
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
			""", scriptNamespace, name);
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
			""", scriptNamespace, name);
		case .Gui:
			text.AppendF("""
			using Tallow;

			namespace {0};

			/// <summary>A heads-up display drawn every frame: pixels from the game view's top-left.</summary>
			public class {1} : Script
			{{
			    public float Health = 75;
			    public float MaxHealth = 100;

			    public override void OnGUI()
			    {{
			        GUI.Box(12, 12, 220, 52, new Color(0, 0, 0, 0.45f));
			        GUI.Label(22, 18, $"Health {{Health:0}} / {{MaxHealth:0}}");
			        GUI.Bar(22, 40, 200, 14, Health / MaxHealth, new Color(0.85f, 0.2f, 0.2f));
			        if (GUI.Button(GUI.Width - 132, 12, 120, 28, "Heal"))
			            Health = MathF.Min(Health + 10, MaxHealth);
			    }}
			}}
			""", scriptNamespace, name);
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
			""", scriptNamespace, name);
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
			""", scriptNamespace, name, template == .EcsSynced ? "[Sync] " : "");
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
			        // {1}Data is registered as ECS data. Typed C# queries over it come with the managed ECS
			        // bridge (docs/csharp-gameplay-roadmap.md); until then, keep per-object state in this script.
			    }}
			}}
			""", scriptNamespace, name);
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
			        // {1}Data is registered as ECS data. Typed C# queries over it come with the managed ECS
			        // bridge (docs/csharp-gameplay-roadmap.md); for many objects today, one script updating an
			        // array of structs (as the Gallery's crowd does) is the fast path.
			    }}
			}}
			""", scriptNamespace, name);
		}
	}

	/// --script-templates-test <folder>: writes a script from every template there (namespace TemplateTest), for
	/// tools/test_csharp_sample.py to compile.
	void RunScriptTemplatesTest(StringView folder)
	{
		Directory.CreateDirectory(folder).IgnoreError();
		int written = 0;
		for (let template in Enum.GetValues<ScriptTemplateKind>())
		{
			let name = scope String();
			template.ToString(name);
			name.Append("Template");
			let text = scope String();
			ScriptTemplateText(template, "TemplateTest", name, text);
			if (File.WriteAllText(scope $"{folder}/{name}.cs", text) case .Ok)
				written++;
		}
		Console.WriteLine(scope $"SCRIPT TEMPLATES WRITTEN {written}");
	}
}
