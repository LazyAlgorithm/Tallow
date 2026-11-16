using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --hot-reload-test FOLDER: the editor's own hot reload path. Once the project's first C# build is done it presses
/// Play, lets the game run 2 s, then deletes the scripts in src/Scripts that FOLDER does not have, puts each of
/// FOLDER's files into the code editor (as if typed) and saves them with Save All; the save compiles and reloads the
/// running game. Logs "HOT RELOAD TEST PASS: ..." once the reload happened and the game stopped Play itself (or
/// "... FAIL: ..."), then quits. tools/test_csharp_editor.py runs it on Tests/CSharpReload with v2/Scripts. With
/// --hot-reload-manual the project's reload mode is Manual for the run, so the save does not reload, and
/// File > Reload Scripts (RequestRebuild) is what reloads.
extension EditorApp
{
	String mHotReloadTestFolder ~ delete _;
	int mHotReloadTestStage;
	int mHotReloadTestFrame;
	int mHotReloadsDone;
	Stopwatch mHotReloadTestClock = new .() ~ delete _;
	double mHotReloadSavedAt;

	void StartHotReloadTest()
	{
		mHotReloadTestFolder = new .();
		GetArg("--hot-reload-test", mHotReloadTestFolder);
	}

	void FinishHotReloadTest(bool pass, StringView report)
	{
		if (pass)
			Log.Info(scope $"HOT RELOAD TEST PASS: {report}");
		else
			Log.Error(scope $"HOT RELOAD TEST FAIL: {report}");
		DeleteAndNullify!(mHotReloadTestFolder);
		if (mPlay != .Edit)
			StopPlay();
		mDirty = false;
		Application.Quit();
	}

	/// Called every frame from DrawUI while the test runs.
	void UpdateHotReloadTest()
	{
		if (mHotReloadTestFolder == null)
			return;
		mHotReloadTestFrame++;
		switch (mHotReloadTestStage)
		{
		case 0:
			if (mHotReloadTestFrame < 3 || mCheckRunning || mReloadQueued)
				return;
			StartPlay();
			mHotReloadTestClock.Restart();
			mHotReloadTestStage = 1;
		case 1:
			if (mPlay == .Edit)
			{
				if (!mPlayAfterCompile && mHotReloadTestClock.ElapsedMilliseconds > 60000)
					FinishHotReloadTest(false, "Play did not start");
				return;
			}
			if (mHotReloadTestClock.ElapsedMilliseconds < 2000)
				return;
			let scripts = scope $"{Project.Current.Path}/src/Scripts";
			// Scripts the new version does not have.
			for (let entry in Directory.EnumerateFiles(scripts, "*.cs"))
			{
				let name = scope String();
				entry.GetFileName(name);
				if (!File.Exists(scope $"{mHotReloadTestFolder}/{name}"))
					File.Delete(scope $"{scripts}/{name}").IgnoreError();
			}
			int edited = 0;
			for (let entry in Directory.EnumerateFiles(mHotReloadTestFolder, "*.cs"))
			{
				let name = scope String();
				entry.GetFileName(name);
				let text = scope String();
				if (File.ReadAllText(scope $"{mHotReloadTestFolder}/{name}", text) case .Err)
					continue;
				let target = scope $"{scripts}/{name}";
				if (!File.Exists(target))
					File.WriteAllText(target, "").IgnoreError();
				OpenScript(target);
				let document = FindScript(target);
				if (document == null || document.readOnly)
				{
					FinishHotReloadTest(false, scope $"{name} did not open for editing");
					return;
				}
				tn_code_replace_text(document.handle, text.CStr());
				edited++;
			}
			mHotReloadsDone = 0;
			let manual = HasArg("--hot-reload-manual");
			if (manual)
				Project.Current.ReloadMode = .Manual;
			SaveAllScripts();
			if (manual)
			{
				if (mHotReloadAfterCompile)
				{
					FinishHotReloadTest(false, "a save in Manual reload mode asked for a reload");
					return;
				}
				// File > Reload Scripts (Ctrl+R).
				RequestRebuild();
			}
			mHotReloadSavedAt = mHotReloadTestClock.Elapsed.TotalSeconds;
			Log.Info(scope $"HOT RELOAD TEST saved {edited} scripts during Play");
			mHotReloadTestStage = 2;
		case 2:
			let waited = mHotReloadTestClock.Elapsed.TotalSeconds - mHotReloadSavedAt;
			if (mHotReloadsDone == 0)
			{
				if (mPlay == .Edit)
					FinishHotReloadTest(false, "Play stopped before the reload");
				else if (waited > 120)
					FinishHotReloadTest(false, scope $"no reload 120 s after saving ({mStatus})");
				else if (!mCheckRunning && !mHotReloadAfterCompile && !mManagedRecheckQueued && mStatus.Contains("did not compile"))
					FinishHotReloadTest(false, scope $"the saved code did not compile ({mStatus})");
				return;
			}
			Log.Info(scope $"HOT RELOAD TEST reloaded {waited:F2} s after saving");
			mHotReloadTestStage = 3;
			mHotReloadSavedAt = mHotReloadTestClock.Elapsed.TotalSeconds;
		case 3:
			// The new code stops Play itself (Application.Quit) once its checks ran.
			let since = mHotReloadTestClock.Elapsed.TotalSeconds - mHotReloadSavedAt;
			if (mPlay == .Edit)
				FinishHotReloadTest(mHotReloadsDone == 1, scope $"{mHotReloadsDone} reload(s); the new code ran and stopped Play");
			else if (since > 60)
				FinishHotReloadTest(false, "the new code never stopped Play");
		}
	}
}
