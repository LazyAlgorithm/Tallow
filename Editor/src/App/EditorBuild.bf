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
			class {1} : Script
			{{
			    public float speed = 1.0f;
			
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
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Example motion script; the engine already stores Transform data in ECS.
			[Component]
			class {1} : Script
			{{
			    public Vector3 degreesPerSecond = .(0, 45, 0);
			
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        Transform.Rotate(degreesPerSecond * deltaTime);
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
			class {1} : Script
			{{
			    public float interval = 2.0f;
			    private float mElapsed;
			
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        mElapsed += deltaTime;
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
			class {1} : Script
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
			
			/// Add NetworkIdentity to this GameObject to enable ownership and prediction.
			[Component]
			class {1} : Script
			{{
			    [Sync] public float degreesPerSecond = 45.0f;
			
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        // Runs as a network simulation tick when this object has NetworkIdentity.
			        // Use TickInput for predicted player controls; avoid direct Input reads here.
			        Transform.Rotate(.(0, degreesPerSecond * deltaTime, 0));
			    }}
			
			    public override void OnLocalUpdate()
			    {{
			        if (!IsMine)
			            return;
			        // Client-only presentation belongs here.
			    }}
			}}
			""", project.Name, name);
		case .EcsData:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Packed ECS data. Attach to a GameObject or add to a World entity.
			[Component]
			struct {1}
			{{
			    public float speed;
			    public Vector3 velocity;
			}}
			""", project.Name, name);
		case .EcsSynced:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Synced data for a GameObject with NetworkIdentity.
			/// Standalone World entities are not automatically network replicated.
			[Component]
			struct {1}
			{{
			    [Sync] public float speed;
			    [Sync] public Vector3 velocity;
			    public int32 localEffectId;
			}}
			""", project.Name, name);
		case .EcsMixed:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Data and behavior share the same ECS-backed GameObject.
			[Component]
			struct {1}Data
			{{
			    public float speed;
			}}
			
			[Component]
			class {1} : Script
			{{
			    public override void Start()
			    {{
			        if (GetComponent<{1}Data>() == null)
			            GameObject.AddComponent<{1}Data>();
			    }}
			
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        let data = GetComponent<{1}Data>();
			        if (data != null)
			            Transform.Rotate(.(0, data.speed * deltaTime, 0));
			    }}
			}}
			""", project.Name, name);
		case .EcsQuery:
			text.AppendF("""
			using System;
			using Tallow;
			
			namespace {0};
			
			/// Put {1}Data on scene GameObjects to process them as one packed query.
			[Component]
			struct {1}Data
			{{
			    public float elapsed;
			    public float speed;
			}}
			
			/// One controller updates all matching scene GameObjects.
			/// ObjectsWith caches the query; do not delete it.
			[Component]
			class {1} : Script
			{{
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        let query = Scene.World.ObjectsWith<{1}Data>();
			        for (var chunk in query)
			        {{
			            let data = chunk.Write<{1}Data>();
			            let objects = chunk.Read<ObjectLink>();
			            for (int i < chunk.Count)
			            {{
			                let gameObject = objects[i].gameObject;
			                if (!gameObject.ActiveInHierarchy)
			                    continue;
			                data[i].elapsed += deltaTime;
			                gameObject.Transform.Rotate(.(0, data[i].speed * deltaTime, 0));
			            }}
			        }}
			    }}
			}}
			""", project.Name, name);
		case .EcsBulk:
			text.AppendF("""
			using System;
			using System.Collections;
			using Tallow;
			
			namespace {0};
			
			/// Pure ECS entities: no GameObject, Transform or NetworkIdentity is created.
			[Component]
			struct {1}Data
			{{
			    public float age;
			}}
			
			/// Demonstrates World.CreateMany and a packed query for large workloads.
			[Component]
			class {1} : Script
			{{
			    public int32 entityCount = 1000;
			
			    List<Entity> mEntities = new .() ~ delete _;
			    Query<{1}Data> mQuery ~ delete _;
			
			    public override void Start()
			    {{
			        Scene.World.CreateMany<{1}Data>(entityCount, mEntities);
			        mQuery = new .(Scene.World);
			    }}
			
			    public override void Update(TickInput input, float deltaTime)
			    {{
			        if (mQuery == null)
			            return;
			        for (var chunk in mQuery)
			        {{
			            let data = chunk.Write<{1}Data>();
			            for (int i < chunk.Count)
			                data[i].age += deltaTime;
			        }}
			    }}
			
			    public override void OnDestroy()
			    {{
			        for (let entity in mEntities)
			            if (Scene.World.IsAlive(entity))
			                Scene.World.Delete(entity);
			        mEntities.Clear();
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
