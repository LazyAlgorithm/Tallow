using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --editor-extensions-test: the game's editor scripts, in the open project (tools/test_csharp_editor_extensions.py's
/// copy of Tests/CSharpInGame with Tests/CSharpEditorExtensions/Editor added to src/): after the first build, the
/// custom Inspector of InGame.ApiChecks, the windows (one of them throws inside a Disabled scope it never ends), the
/// Tools menu command and the Preferences tab are drawn for a few frames; the scripts write what they saw to
/// ProjectPrefs. Then a script is added and the editor scripts are rebuilt and reloaded. Logs
/// "EDITOR EXTENSIONS TEST PASS: ..." or "... FAIL: ..." and quits. With --test-screenshot PNG, a picture first.
extension EditorApp
{
	int mExtensionsTestStep = -1;
	int mExtensionsTestFrames;
	Stopwatch mExtensionsTestClock = new .() ~ delete _;
	String mExtensionsTestReport = new .() ~ delete _;
	bool mExtensionsTestPass = true;

	void StartEditorExtensionsTest()
	{
		mExtensionsTestStep = 0;
		mExtensionsTestClock.Restart();
	}

	void ExtensionsCheck(bool ok, StringView what)
	{
		mExtensionsTestReport.AppendF("{}{}: {}", mExtensionsTestReport.IsEmpty ? "" : "; ", what, ok);
		mExtensionsTestPass &= ok;
	}

	bool ExtensionsBuildIdle => !mCheckRunning && !mReloadQueued && mPlay == .Edit;

	/// The project's ProjectPrefs file, where the test's editor scripts report.
	void ExtensionsProjectPrefs(String text)
	{
		File.ReadAllText(scope $"{Project.Current.Path}/ProjectSettings/EditorPrefs.json", text).IgnoreError();
	}

	int ExtensionWindowIndex(StringView menuPath)
	{
		for (int i < mExtensionWindows.Count)
			if (mExtensionWindows[i].menuPath == menuPath)
				return i;
		return -1;
	}

	void UpdateEditorExtensionsTest()
	{
		if (mExtensionsTestStep < 0)
			return;
		mExtensionsTestFrames++;
		if (mExtensionsTestClock.ElapsedMilliseconds > 120000)
		{
			ExtensionsCheck(false, scope $"step {mExtensionsTestStep} timed out ({mStatus})");
			FinishEditorExtensionsTest();
			return;
		}
		switch (mExtensionsTestStep)
		{
		case 0: // the first build, which loads the editor scripts
			if (mExtensionsTestFrames > 3 && ExtensionsBuildIdle && mManagedBuildReady)
			{
				ExtensionsCheck(mExtensionsLoaded, "the editor scripts loaded after the build");
				ExtensionsCheck(ExtensionWindowIndex("Test/Probe Window") >= 0 && ExtensionWindowIndex("Test/Broken Window") >= 0,
					scope $"the windows are in the Tools menu ({mExtensionWindows.Count})");
				bool hasProbeCommand = false;
				bool hasSceneCommand = false;
				for (let command in mExtensionMenus)
				{
					hasProbeCommand |= command == "Test/Run Probe";
					hasSceneCommand |= command == "Test/Scene Probe";
				}
				ExtensionsCheck(mExtensionMenus.Count == 2 && hasProbeCommand && hasSceneCommand,
					scope $"the menu commands are listed ({mExtensionMenus.Count})");
				ExtensionsCheck(mExtensionPages.Count == 2 && mExtensionPages[0] == "Probe Drawn" && mExtensionPages[1] == "Probe Settings",
					"the Preferences tabs are listed, by title");
				ExtensionsCheck(FindExtensionInspector("InGame.ApiChecks") >= 0 && FindExtensionInspector("InGame.FirstPersonCharacter") < 0,
					"ApiChecks has a custom Inspector, another script has none");
				ExtensionsCheck(!File.Exists(scope $"{Project.Current.Path}/.tallow-csharp/bin/Tallow.Game/Tallow.Game.Editor.dll") &&
					File.Exists(scope $"{Project.Current.Path}/.tallow-csharp/bin/Tallow.Game.Editor/Tallow.Game.Editor.dll"),
					"the editor scripts are an assembly of their own");
				// Show everything: the Inspector of the object with ApiChecks, both windows, the settings tab.
				for (let component in mScene.Components)
					if (let script = component as CSharpBehaviour)
						if (script.scriptType == "InGame.ApiChecks")
							mSelectedId = script.GameObject.Id;
				for (let window in mExtensionWindows)
					window.open = true;
				mShowPreferences = true;
				mPreferencesPage = 101;
				sExtensions.runMenu(0);
				mExtensionsTestStep = 1;
				mExtensionsTestFrames = 0;
			}
		case 1: // drawn for a while
			if (mExtensionsTestFrames == 20)
			{
				let prefs = scope String();
				ExtensionsProjectPrefs(prefs);
				ExtensionsCheck(prefs.Contains("\"inspectorTarget\": \"InGame.ApiChecks on "), "the Inspector drew with its target");
				ExtensionsCheck(prefs.Contains("\"windowSelection\": \""), "the window drew and read the selection");
				ExtensionsCheck(prefs.Contains("\"menuRan\": true"), "the menu command ran");
				ExtensionsCheck(prefs.Contains("\"pageDrawn\": true") == false, "the drawn tab is only drawn when shown");
				let value = scope String();
				for (let component in mScene.Components)
					if (let script = component as CSharpBehaviour)
						if (script.scriptType == "InGame.ApiChecks")
							script.ReadEditorField("Speed", value);
				ExtensionsCheck(value == "6", scope $"the Inspector's Target.SetFloat reached the scene (Speed {value})");
				let userPrefs = scope String();
				File.ReadAllText(scope $"{RecentProjects.GetConfigFolder(.. scope .())}editor-prefs.json", userPrefs).IgnoreError();
				ExtensionsCheck(userPrefs.Contains("\"type:InGame.Editor.ProbeSettings\"") && userPrefs.Contains("\"GridSize\": 3"),
					"EditorPrefs saved a settings object");
				ExtensionsCheck(mExtensionWindows[ExtensionWindowIndex("Test/Probe Window")].open, "the probe window stays open");
				mPreferencesPage = 100;
			}
			if (mExtensionsTestFrames == 30)
			{
				let prefs = scope String();
				ExtensionsProjectPrefs(prefs);
				ExtensionsCheck(prefs.Contains("\"pageDrawn\": true"), "the drawn Preferences tab drew");
				// 2. A new editor script: built and loaded again, the open window still open.
				File.WriteAllText(scope $"{Project.Current.Path}/src/Editor/Added.cs", """
					using Tallow.Editor;

					namespace InGame.Editor;

					public static class Added
					{
					    [MenuItem("Test/Added Later")]
					    private static void Run() => ProjectPrefs.SetBool("addedRan", true);
					}

					""").IgnoreError();
				StartManagedErrorCheck();
				mExtensionsTestStep = 2;
				mExtensionsTestFrames = 0;
			}
		case 2:
			if (mExtensionsTestFrames > 3 && ExtensionsBuildIdle)
			{
				ExtensionsCheck(mManagedBuildReady, "the project built again");
				ExtensionsCheck(mExtensionMenus.Count == 3, scope $"the new menu command is listed after the reload ({mExtensionMenus.Count})");
				let probe = ExtensionWindowIndex("Test/Probe Window");
				ExtensionsCheck(probe >= 0 && mExtensionWindows[probe].open, "an open window is open again after the reload");
				for (int i < mExtensionMenus.Count)
					if (mExtensionMenus[i] == "Test/Added Later")
						sExtensions.runMenu((int32)i);
				mPreferencesPage = 101;
				mExtensionsTestStep = 3;
				mExtensionsTestFrames = 0;
			}
		case 3:
			if (mExtensionsTestFrames == 10)
			{
				let prefs = scope String();
				ExtensionsProjectPrefs(prefs);
				ExtensionsCheck(prefs.Contains("\"addedRan\": true"), "the new command ran");
				let picture = scope String();
				if (GetArg("--test-screenshot", picture))
					Native.tn_gfx_screenshot(picture.CStr());
				// The editor's scene API, from a Tools command (Tests/CSharpEditorExtensions/Editor/SceneProbe.cs).
				for (int i < mExtensionMenus.Count)
					if (mExtensionMenus[i] == "Test/Scene Probe")
						sExtensions.runMenu((int32)i);
			}
			if (mExtensionsTestFrames == 14)
			{
				mExtensionsTestStep = 4;
				mExtensionsTestFrames = 0;
			}
		case 4: // what the scene probe made, and undo
			if (mExtensionsTestFrames == 5)
			{
				let prefs = scope String();
				ExtensionsProjectPrefs(prefs);
				ExtensionsCheck(prefs.Contains("\"sceneProbeOk\": true"), "the scene API checks passed");
				if (!prefs.Contains("\"sceneProbeOk\": true"))
				{
					let at = prefs.IndexOf("\"sceneProbe\"");
					if (at >= 0)
						Log.Error(scope String("Scene probe: ", prefs.Substring(at, Math.Min(1500, prefs.Length - at))));
				}
				let kept = mScene.Find("Probe Kept");
				bool hasLight = false;
				float intensity = 0;
				if (kept != null)
				{
					if (let handle = HandleComponents.Find("Tallow.Light"))
					{
						if (kept.Scene.World.Has(kept.Entity, handle.index))
						{
							hasLight = true;
							intensity = kept.GetComponent<Light>().intensity;
						}
					}
				}
				ExtensionsCheck(kept != null && Math.Abs(kept.Transform.Position.x - 4) < 0.001f,
					"the scene has the object the script made, where it put it");
				ExtensionsCheck(hasLight && Math.Abs(intensity - 2.5f) < 0.001f,
					scope $"the field the script wrote reached the scene (intensity {intensity})");
				Undo();
				mExtensionsTestStep = 5;
				mExtensionsTestFrames = 0;
			}
		case 5:
			if (mExtensionsTestFrames == 3)
			{
				ExtensionsCheck(mScene.Find("Probe Kept") == null, "undo took the script's changes back");
				FinishEditorExtensionsTest();
			}
		}
	}

	void FinishEditorExtensionsTest()
	{
		mExtensionsTestStep = -1;
		if (mExtensionsTestPass)
			Log.Info(scope $"EDITOR EXTENSIONS TEST PASS: {mExtensionsTestReport}");
		else
			Log.Error(scope $"EDITOR EXTENSIONS TEST FAIL: {mExtensionsTestReport}");
		mDirty = false;
		Application.Quit();
	}
}
