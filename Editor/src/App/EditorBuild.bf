using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// Script templates offered by Project > Create > Script.
enum ScriptTemplateKind
{
	case Basic;
	case Movement;
	case Timer;
	case Gui;
	case Networked;
	case EcsData;
	case EcsSynced;
	case EcsMixed;
	case EcsQuery;
	case EcsBulk;
	// Editor scripts: made in a folder named Editor, which game builds leave out.
	case EditorInspector;
	case EditorWindow;
	case EditorMenu;
	case EditorPreferences;
	case EditorComponentInspector;
	case EditorSceneOverlay;

	/// An editor script's template (the file goes in an Editor folder).
	public bool IsEditor => (int)this >= (int)ScriptTemplateKind.EditorInspector;
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
			{
				// During Play the running game moves to the new code once it compiles, as after a save.
				if (mPlay != .Edit)
					mHotReloadAfterCompile = true;
				StartManagedErrorCheck();
			}
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
			// Built once the check is done (DrawBuildWindow), rather than asking for another click.
			mStatus.Set("The build starts when the script error check finishes.");
			mBuildNowPending = true;
			return;
		}
		SaveAllScripts();
		if (mPlay == .Edit)
			SaveScene(false);
		// The game only loads compiled shaders, so they must be current before it is packaged.
		CompileStaleShaders();
		let output = scope String();
		BuildOutputFolder(output);
		Log.Info(scope $"Building the game for {(mBuildTarget == .Web ? "the web" : mBuildTarget.ToString(.. scope .()))}...");
		mBuildSucceeded = project.BuildPlayer(output, mBuildTarget);
		if (mBuildSucceeded)
		{
			Log.Info(scope $"Game packaged at {output}");
			mBuildMessage.Set(scope $"Built. The game is in {output}");
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
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Script names use letters, digits and underscores, and start with a letter.");
			return;
		}
		// An editor script goes in an Editor folder (made here when the folder shown is not in one).
		let folder = scope String(mBrowsePath);
		if (template.IsEditor && !InEditorFolder(folder))
		{
			folder.Append("/Editor");
			Directory.CreateDirectory(folder).IgnoreError();
		}
		let path = scope $"{folder}/{name}.cs";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		// The namespace of the assembly the folder belongs to (its .tasmdef root namespace), else the project's.
		let scriptNamespace = scope String();
		ScriptNamespaceFor(folder, scriptNamespace);
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

	/// Whether a folder is, or is inside, one named Editor (where Tallow.Build takes editor scripts from).
	static bool InEditorFolder(StringView folder)
	{
		for (let part in folder.Split('/', '\\'))
			if (part == "Editor")
				return true;
		return false;
	}

	/// The text of a new C# script made from a template (the Project panel's Create > C# Script menu). target: the
	/// script class a custom Inspector draws (default: its name without "Inspector").
	public static void ScriptTemplateText(ScriptTemplateKind template, StringView scriptNamespace, StringView name, String text, StringView target = default)
	{
		switch (template)
		{
		case .EditorInspector:
			var script = target;
			if (script.IsEmpty)
				script = name.EndsWith("Inspector") && name.Length > "Inspector".Length ? name.Substring(0, name.Length - "Inspector".Length) : name;
			text.AppendF("""
			using Tallow;
			using Tallow.Editor;

			namespace {0};

			/// <summary>Draws {2}'s part of the Inspector, in place of its plain field list. Editor scripts (any
			/// folder named Editor) run only in the editor: a game build leaves them out.</summary>
			[CustomInspector(typeof({2}))]
			public class {1} : Inspector
			{{
			    public override void OnInspectorGUI()
			    {{
			        EditorGUI.HelpBox($"{{Target.ScriptName}} on {{Target.ObjectName}}");

			        // Every field, as the Inspector draws them. Or draw some by name: Field("Speed");
			        DrawDefaultInspector();

			        // Saved values can be read and set by field name; undo, saving and Play are taken care of:
			        // if (EditorGUI.Button("Double the speed"))
			        //     Target.SetFloat("Speed", Target.GetFloat("Speed") * 2);
			    }}
			}}
			""", scriptNamespace, name, script);
		case .EditorWindow:
			text.AppendF("""
			using Tallow;
			using Tallow.Editor;

			namespace {0};

			/// <summary>A window of the editor: Tools > {1} opens it, and it docks like the others. Editor scripts (any
			/// folder named Editor) run only in the editor: a game build leaves them out.</summary>
			[EditorWindow("{1}")]
			public class {1} : EditorWindow
			{{
			    private int _clicks;

			    public override void OnGUI()
			    {{
			        EditorGUI.Heading("{1}");
			        string selected = EditorApplication.SelectedObjectName;
			        EditorGUI.Label(selected.Length > 0 ? $"Selected: {{selected}}" : "Nothing is selected.");

			        if (EditorGUI.Button("Click me"))
			            _clicks++;
			        EditorGUI.Label($"Clicked {{_clicks}} times");
			    }}
			}}
			""", scriptNamespace, name);
		case .EditorMenu:
			text.AppendF("""
			using Tallow;
			using Tallow.Editor;

			namespace {0};

			/// <summary>Commands in the editor's Tools menu: each static method with [MenuItem] runs when it is chosen.
			/// Editor scripts (any folder named Editor) run only in the editor: a game build leaves them out.</summary>
			public static class {1}
			{{
			    [MenuItem("{1}/Say Hello")]
			    private static void SayHello()
			    {{
			        EditorApplication.Log($"Hello from {{EditorApplication.ProjectPath}}");
			    }}
			}}
			""", scriptNamespace, name);
		case .EditorPreferences:
			text.AppendF("""
			using Tallow;
			using Tallow.Editor;

			namespace {0};

			/// <summary>Settings with their own tab in Edit > Preferences: the tab shows these public fields, and every
			/// change is saved for this user. Read them from any editor script:
			/// <c>float grid = EditorPrefs.Get&lt;{1}&gt;().GridSize;</c>
			/// (ProjectPrefs keeps settings in the project instead, for everybody working on it.) Editor scripts (any
			/// folder named Editor) run only in the editor: a game build leaves them out.</summary>
			[PreferencesPage("{1}")]
			public class {1}
			{{
			    public float GridSize = 1;
			    public bool SnapToGrid = true;
			    public string Author = "";
			}}
			""", scriptNamespace, name);
		case .EditorComponentInspector:
			text.AppendF("""
			using Tallow;
			using Tallow.Editor;

			namespace {0};

			/// <summary>Draws the Inspector of a built-in component (here Light) in place of its plain field list, for
			/// every object with one. Name any built-in component's handle type: Light, MeshRenderer, BoxCollider... For
			/// a C# script's Inspector, derive from Inspector instead. Editor scripts (any folder named Editor) run only
			/// in the editor: a game build leaves them out.</summary>
			[CustomInspector(typeof(Light))]
			public class {1} : ComponentInspector
			{{
			    public override void OnInspectorGUI()
			    {{
			        EditorGUI.HelpBox($"Light on {{Target.Object.Name}}");

			        // Every field, as the Inspector draws them. Or draw some by name: Field("intensity");
			        DrawDefaultInspector();

			        // The component's fields read and write as scene files do; undo and saving are taken care of:
			        // if (EditorGUI.Button("Dim"))
			        //     Target.SetFloat("intensity", Target.GetFloat("intensity") * 0.5f);
			    }}
			}}
			""", scriptNamespace, name);
		case .EditorSceneOverlay:
			text.AppendF("""
			using System.Numerics;
			using Tallow;
			using Tallow.Editor;

			namespace {0};

			/// <summary>Draws in the Scene view every frame it is open, and turns clicks into a tool. Any concrete
			/// SceneViewOverlay subclass is called; it runs while the editor renders, so it draws gizmos rather than
			/// widgets (an editor window is for those). OnSceneViewGUI is also where a Scene view tool reads the mouse:
			/// SceneView.IsMouseOver, IsClicked, MousePoint, Ray, Pick and PickUnderMouse. Editor scripts (any folder
			/// named Editor) run only in the editor: a game build leaves them out.</summary>
			public class {1} : SceneViewOverlay
			{{
			    public override void OnSceneViewGUI()
			    {{
			        Vector3 center = EditorScene.Selection is {{ }} selected ? selected.Position : Vector3.Zero;
			        SceneView.Sphere(center, 1.5f, Color.Yellow);
			        SceneView.Line(center, center + Vector3.UnitY * 3, Color.Red);

			        if (SceneView.IsMouseOver && SceneView.IsClicked)
			        {{
			            EditorObject picked = SceneView.PickUnderMouse();
			            if (picked.Exists)
			                EditorScene.Selection = picked;
			        }}
			    }}
			}}
			""", scriptNamespace, name);
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

			    public override void LocalUpdate(float deltaTime)
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
			using System.Numerics;
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
			    public override void Start()
			    {{
			        // Data on this object's ECS entity: Scene.Query<{1}Data>() finds it with all the others.
			        GameObject.Entity.Set(new {1}Data {{ Speed = 1f }});
			    }}

			    public override void Update(TickInput input, float deltaTime)
			    {{
			        if (GameObject.Entity.TryGet(out {1}Data data))
			            Transform.Position += Vector3.UnitY * data.Speed * deltaTime;
			    }}
			}}
			""", scriptNamespace, name);
		case .EcsQuery:
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
			    public override void Start()
			    {{
			        // Any GameObject's entity (or a bare one from Scene.CreateLocalEcsEntity) can have the data.
			        GameObject.Entity.Set(new {1}Data());
			    }}

			    public override void Update(TickInput input, float deltaTime)
			    {{
			        // Every entity with the data. What the action changes through the ref is written back.
			        Scene.Query<{1}Data>().ForEach((EcsEntity entity, ref {1}Data data) => data.Elapsed += deltaTime);
			    }}
			}}
			""", scriptNamespace, name);
		case .EcsBulk:
			text.AppendF("""
			using System.Numerics;
			using Tallow;

			namespace {0};

			[Component]
			public struct {1}Data
			{{
			    public Vector3 Position;
			    public Vector3 Velocity;
			}}

			[Component]
			public class {1} : Script
			{{
			    public int Count = 1000;

			    public override void Start()
			    {{
			        // Bare entities: just data, no GameObject or Transform. They go when Play stops.
			        for (int i = 0; i < Count; i++)
			            Scene.CreateLocalEcsEntity().Set(new {1}Data {{ Velocity = new Vector3(i % 10, 0f, i / 10) * 0.1f }});
			    }}

			    public override void Update(TickInput input, float deltaTime)
			    {{
			        // One query moves them all; the data is copied out and back in pages, not one call per entity.
			        Scene.Query<{1}Data>().ForEach((EcsEntity entity, ref {1}Data data) =>
			            data.Position += data.Velocity * deltaTime);
			    }}
			}}
			""", scriptNamespace, name);
		}
	}

	/// --write-script-templates <folder> (launcher): writes a script from every template there (namespace TemplateTest).
	public static int WriteScriptTemplates(StringView folder)
	{
		Directory.CreateDirectory(folder).IgnoreError();
		int written = 0;
		for (let template in Enum.GetValues<ScriptTemplateKind>())
		{
			let name = scope String();
			template.ToString(name);
			name.Append("Template");
			let text = scope String();
			// Editor scripts in an Editor folder, as Create makes them; the Inspector draws the Basic template's script.
			ScriptTemplateText(template, "TemplateTest", name, text, "BasicTemplate");
			let into = template.IsEditor ? scope $"{folder}/Editor" : scope String(folder);
			Directory.CreateDirectory(into).IgnoreError();
			if (File.WriteAllText(scope $"{into}/{name}.cs", text) case .Ok)
				written++;
		}
		Console.WriteLine(scope $"SCRIPT TEMPLATES WRITTEN {written}");
		return written;
	}
}
