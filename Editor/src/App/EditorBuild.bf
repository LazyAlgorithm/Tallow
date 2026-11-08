using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// Building: script rebuilds, restarts and game builds.
extension EditorApp
{
	void RebuildAndReload()
	{
		if (mReloadReady)
		{
			SaveAllScripts();
			QueueScriptReload();
			return;
		}
		FullRebuildAndRestart();
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

	void CreateScript(StringView name)
	{
		let project = Project.Current;
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Script names use letters, digits and underscores, and start with a letter.");
			return;
		}
		// Scripts are created in the folder currently shown in the Project window.
		let path = scope $"{mBrowsePath}/{name}.bf";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		let text = scope String();
		text.AppendF("""
			using System;
			using Tallow;

			namespace {0};

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
		if (File.WriteAllText(path, text) case .Ok)
			Log.Info(scope $"Created {path}. Choose File > Rebuild & Reload to use it.");
	}
}
