using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --stale-build-test: Play must always run the C# as it is on disk. Writes a probe script into the open project
/// (use a copy: tools/test_csharp_editor.py) whose module initializer writes its version to a file when the game
/// loads, then checks which version each Play ran:
///   1. a new file saved by another program and Play pressed at once (before the editor's 0.5 s poll);
///   2. a second edit made while the build of the first is running, Play pressed at once;
///   3. the file moved to another folder with new text;
///   4. the file deleted (no probe runs).
/// Logs "STALE BUILD TEST PASS: ..." or "STALE BUILD TEST FAIL: ..." and quits.
extension EditorApp
{
	int mStaleStep = -1;
	int mStaleFrames;
	Stopwatch mStaleClock = new .() ~ delete _;
	String mStaleReport = new .() ~ delete _;
	bool mStalePass = true;

	void StartStaleBuildTest() { mStaleStep = 0; }

	void StaleProbePath(String path) { path.AppendF("{}/stale-probe.txt", Project.Current.Path); }

	void WriteStaleProbe(StringView relativePath, StringView version)
	{
		let path = scope $"{Project.Current.Path}/src/{relativePath}";
		let folder = scope String();
		Path.GetDirectoryPath(path, folder);
		Directory.CreateDirectory(folder).IgnoreError();
		let probeFile = scope String();
		StaleProbePath(probeFile);
		probeFile.Replace("\\", "/");
		File.WriteAllText(path, scope $"""
			namespace StaleProbe;

			internal static class Probe
			{{
			    [System.Runtime.CompilerServices.ModuleInitializer]
			    internal static void Loaded() => System.IO.File.WriteAllText("{probeFile}", "{version}");
			}}

			""").IgnoreError();
	}

	/// What the last Play's probe wrote ("" when none ran), and clears it for the next.
	void TakeStaleProbe(String output)
	{
		let path = scope String();
		StaleProbePath(path);
		if (File.Exists(path))
		{
			File.ReadAllText(path, output).IgnoreError();
			File.Delete(path).IgnoreError();
		}
	}

	void StaleExpect(StringView step, StringView expected)
	{
		let ran = scope String();
		TakeStaleProbe(ran);
		let ok = ran == expected;
		mStaleReport.AppendF("{}{}: ran \"{}\" (expected \"{}\")", mStaleReport.IsEmpty ? "" : "; ", step, ran, expected);
		mStalePass &= ok;
	}

	bool StaleBuildsIdle => !mCheckRunning && !mReloadQueued && !mPlayAfterCompile && mPlay == .Edit;

	/// Called every frame from DrawUI while the test runs.
	void UpdateStaleBuildTest()
	{
		if (mStaleStep < 0)
			return;
		mStaleFrames++;
		switch (mStaleStep)
		{
		case 0: // the project's first build
			if (mStaleFrames > 3 && StaleBuildsIdle)
			{
				let ignored = scope String();
				TakeStaleProbe(ignored);
				// 1. Saved elsewhere, Play pressed before the editor has looked.
				WriteStaleProbe("Scripts/StaleProbe.cs", "v1");
				StartPlay();
				mStaleStep = 1;
				mStaleClock.Restart();
			}
		case 1, 4, 7:
			// Wait for Play (it may first build), run a few frames, Stop.
			if (mPlay == .Playing)
			{
				if (mStaleClock.ElapsedMilliseconds > 300)
				{
					StopPlay();
					StaleExpect(mStaleStep == 1 ? "new file, Play at once" : mStaleStep == 4 ? "edit during a build" : "moved file", mStaleStep == 1 ? "v1" : mStaleStep == 4 ? "v2" : "v3");
					mStaleStep++;
					mStaleClock.Restart();
				}
			}
			else if (mStaleClock.ElapsedMilliseconds > 60000 && !mCheckRunning && !mPlayAfterCompile)
			{
				mStalePass = false;
				mStaleReport.AppendF("{}step {}: Play never started ({})", mStaleReport.IsEmpty ? "" : "; ", mStaleStep, mStatus);
				FinishStaleBuildTest();
			}
		case 2: // 2. an edit; when its build is running, another edit and Play at once
			if (StaleBuildsIdle && mStaleClock.ElapsedMilliseconds > 200)
			{
				WriteStaleProbe("Scripts/StaleProbe.cs", "v1b");
				mStaleStep = 3;
				mStaleClock.Restart();
			}
		case 3:
			if (mCheckRunning)
			{
				WriteStaleProbe("Scripts/StaleProbe.cs", "v2");
				StartPlay();
				mStaleStep = 4;
				mStaleClock.Restart();
			}
			else if (mStaleClock.ElapsedMilliseconds > 10000)
			{
				mStalePass = false;
				mStaleReport.Append("; the edit did not start a build within 10 s");
				FinishStaleBuildTest();
			}
		case 5: // 3. moved to another folder with new text
			if (StaleBuildsIdle && mStaleClock.ElapsedMilliseconds > 200)
			{
				File.Delete(scope $"{Project.Current.Path}/src/Scripts/StaleProbe.cs").IgnoreError();
				WriteStaleProbe("Moved/StaleProbeMoved.cs", "v3");
				StartPlay();
				mStaleStep = 7;
				mStaleClock.Restart();
			}
		case 8: // 4. deleted: no probe in the game
			if (StaleBuildsIdle && mStaleClock.ElapsedMilliseconds > 200)
			{
				File.Delete(scope $"{Project.Current.Path}/src/Moved/StaleProbeMoved.cs").IgnoreError();
				StartPlay();
				mStaleStep = 9;
				mStaleClock.Restart();
			}
		case 9:
			if (mPlay == .Playing && mStaleClock.ElapsedMilliseconds > 300)
			{
				StopPlay();
				StaleExpect("deleted file", "");
				FinishStaleBuildTest();
			}
			else if (mPlay != .Playing && mStaleClock.ElapsedMilliseconds > 60000 && !mCheckRunning && !mPlayAfterCompile)
			{
				mStalePass = false;
				mStaleReport.AppendF("; after the delete Play never started ({})", mStatus);
				FinishStaleBuildTest();
			}
		default:
		}
	}

	void FinishStaleBuildTest()
	{
		mStaleStep = -1;
		if (mStalePass)
			Log.Info(scope $"STALE BUILD TEST PASS: {mStaleReport}");
		else
			Log.Error(scope $"STALE BUILD TEST FAIL: {mStaleReport}");
		mDirty = false;
		Application.Quit();
	}
}
