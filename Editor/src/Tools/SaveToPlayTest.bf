using System;
using System.Collections;
using System.Diagnostics;
using Tallow;

namespace Tallow.Editor;

/// --save-to-play-test N [--save-to-play-script REL]: the editor's edit-to-Play time (benchmark B03's editor part).
/// Once the project's first C# build is done, N times: opens the script (default: the first .cs under src/Scripts),
/// adds a changed comment line at its end in the code editor, saves it, and
///   - odd rounds ("save, then Play"): presses Play in the same frame, as someone pressing Ctrl+S then Play would,
///     and times save -> Play running (the build in between included);
///   - even rounds ("save, wait"): times save -> build done (Play permitted), then presses Play and times that.
/// Each Play runs 10 frames, then Stop. The script's text is put back at the end. Logs "SAVE TO PLAY ROUND ..." per
/// round and "SAVE TO PLAY TEST PASS: ..." (medians) or "... FAIL: ...", then quits. tools/run_save_to_play_bench.py
/// runs it on a copy of a project.
extension EditorApp
{
	int mSaveToPlayTarget = -1;
	int mSaveToPlayRound;
	int mSaveToPlayStage;
	int mSaveToPlayFrame;
	int mSaveToPlayPlayFrames;
	String mSaveToPlayScript ~ delete _;
	String mSaveToPlayOriginal ~ delete _;
	Stopwatch mSaveToPlayClock = new .() ~ delete _;
	List<double> mSaveThenPlayMs = new .() ~ delete _;
	List<double> mSaveToBuiltMs = new .() ~ delete _;
	List<double> mBuiltToPlayMs = new .() ~ delete _;
	double mSaveToPlayBuiltAt;

	void StartSaveToPlayTest()
	{
		let text = scope String();
		GetArg("--save-to-play-test", text);
		mSaveToPlayTarget = int.Parse(text) case .Ok(let count) ? Math.Max(count, 2) : 10;
		mSaveToPlayScript = new .();
		let relative = scope String();
		GetArg("--save-to-play-script", relative);
		if (!relative.IsEmpty)
			mSaveToPlayScript.AppendF("{}/{}", Project.Current.Path, relative);
	}

	void FinishSaveToPlayTest(bool pass, StringView report)
	{
		if (mPlay != .Edit)
			StopPlay();
		// Put the script back as it was (saved, so the next run starts from the same source).
		if (mSaveToPlayOriginal != null)
		{
			if (let document = FindScript(mSaveToPlayScript))
			{
				tn_code_replace_text(document.handle, mSaveToPlayOriginal.CStr());
				SaveScript(document);
			}
		}
		if (pass)
			Log.Info(scope $"SAVE TO PLAY TEST PASS: {report}");
		else
			Log.Error(scope $"SAVE TO PLAY TEST FAIL: {report}");
		mSaveToPlayTarget = -1;
		mDirty = false;
		Application.Quit();
	}

	static double MedianOf(List<double> values)
	{
		if (values.IsEmpty)
			return 0;
		let sorted = scope List<double>();
		sorted.AddRange(values);
		sorted.Sort();
		return sorted[sorted.Count / 2];
	}

	/// The script edited each round: --save-to-play-script, else the first .cs in src/Scripts.
	bool FindSaveToPlayScript()
	{
		if (!mSaveToPlayScript.IsEmpty)
			return System.IO.File.Exists(mSaveToPlayScript);
		for (let entry in System.IO.Directory.EnumerateFiles(scope $"{Project.Current.Path}/src/Scripts", "*.cs"))
		{
			entry.GetFilePath(mSaveToPlayScript);
			return true;
		}
		return false;
	}

	/// Called every frame from DrawUI while the test runs.
	void UpdateSaveToPlayTest()
	{
		if (mSaveToPlayTarget < 0)
			return;
		mSaveToPlayFrame++;
		let now = mSaveToPlayClock.Elapsed.TotalMilliseconds;
		switch (mSaveToPlayStage)
		{
		case 0: // the project's first build
			if (mSaveToPlayFrame < 3 || mCheckRunning || mReloadQueued)
				return;
			if (!FindSaveToPlayScript())
			{
				FinishSaveToPlayTest(false, "no C# script to edit");
				return;
			}
			OpenScript(mSaveToPlayScript);
			let document = FindScript(mSaveToPlayScript);
			if (document == null || document.readOnly)
			{
				FinishSaveToPlayTest(false, scope $"{mSaveToPlayScript} did not open for editing");
				return;
			}
			mSaveToPlayOriginal = new .(tn_code_get_text(document.handle));
			Log.Info(scope $"SAVE TO PLAY READY after {mSaveToPlayFrame} frames, editing {mSaveToPlayScript}");
			mSaveToPlayStage = 1;
		case 1: // edit and save
			if (mPlay != .Edit || mCheckRunning || mReloadQueued)
				return;
			if (mSaveToPlayRound >= mSaveToPlayTarget)
			{
				let report = scope String();
				report.AppendF("{} rounds; save then Play: median {:F0} ms; save to build done: median {:F0} ms; " +
					"build done to Play: median {:F0} ms", mSaveToPlayRound, MedianOf(mSaveThenPlayMs),
					MedianOf(mSaveToBuiltMs), MedianOf(mBuiltToPlayMs));
				FinishSaveToPlayTest(true, report);
				return;
			}
			OpenScript(mSaveToPlayScript);
			let document = FindScript(mSaveToPlayScript);
			if (document == null)
			{
				FinishSaveToPlayTest(false, "the script closed");
				return;
			}
			let text = scope String(mSaveToPlayOriginal);
			text.AppendF("\n// save-to-play round {}\n", mSaveToPlayRound);
			tn_code_replace_text(document.handle, text.CStr());
			mSaveToPlayClock.Restart();
			SaveScript(document);
			if (mManagedBuildReady)
			{
				FinishSaveToPlayTest(false, "saving a C# script left the build marked ready");
				return;
			}
			if (mSaveToPlayRound % 2 == 0)
			{
				StartPlay();
				mSaveToPlayStage = 2;
			}
			else
				mSaveToPlayStage = 3;
		case 2: // save, then Play: wait for Play
			if (mPlay == .Edit)
			{
				if (!mPlayAfterCompile && !mCheckRunning && !mManagedBuildReady)
					FinishSaveToPlayTest(false, scope $"Play did not start after the save ({mStatus})");
				else if (now > 120000)
					FinishSaveToPlayTest(false, "Play did not start within 120 s of the save");
				return;
			}
			mSaveThenPlayMs.Add(now);
			Log.Info(scope $"SAVE TO PLAY ROUND {mSaveToPlayRound} save then Play {now:F0} ms");
			mSaveToPlayPlayFrames = 0;
			mSaveToPlayStage = 4;
		case 3: // save, wait for the build, then Play
			if (!mManagedBuildReady)
			{
				if (!mCheckRunning && !mManagedRecheckQueued && mStatus.Contains("did not compile"))
					FinishSaveToPlayTest(false, scope $"the saved script did not compile ({mStatus})");
				else if (now > 120000)
					FinishSaveToPlayTest(false, "no build within 120 s of the save");
				return;
			}
			mSaveToBuiltMs.Add(now);
			mSaveToPlayBuiltAt = now;
			StartPlay();
			if (mPlay == .Edit)
			{
				FinishSaveToPlayTest(false, scope $"Play did not start once the build was ready ({mStatus})");
				return;
			}
			let play = mSaveToPlayClock.Elapsed.TotalMilliseconds - mSaveToPlayBuiltAt;
			mBuiltToPlayMs.Add(play);
			Log.Info(scope $"SAVE TO PLAY ROUND {mSaveToPlayRound} save to build done {mSaveToPlayBuiltAt:F0} ms, then Play {play:F0} ms");
			mSaveToPlayPlayFrames = 0;
			mSaveToPlayStage = 4;
		case 4: // run 10 frames, Stop
			if (++mSaveToPlayPlayFrames < 10)
				return;
			StopPlay();
			mSaveToPlayRound++;
			mSaveToPlayStage = 1;
		}
	}
}
