using System;
using System.Collections;
using System.Diagnostics;
using Tallow;

namespace Tallow.Editor;

/// --play-cycle-test N: once the project's first C# build is done, presses Play and Stop N times (each Play runs 10
/// frames) and checks that every Stop detaches every C# script. Logs "PLAY CYCLE READY" when the build is done (the
/// editor is usable), then "PLAY CYCLE TEST PASS: ..." or "... FAIL: ..." with Play/Stop times and memory, and quits.
/// --expect-play-blocked instead checks that Play does not start (a project whose C# does not compile).
/// tools/test_csharp_editor.py runs both on copies of test projects.
extension EditorApp
{
	int mPlayCycleTarget = -1;
	int mPlayCycleDone;
	int mPlayCycleFrame;
	int mPlayCycleWait;
	bool mPlayCycleReady;
	bool mPlayCycleExpectBlocked;
	bool mPlayCyclePass = true;
	Stopwatch mPlayCycleClock = new .() ~ delete _;
	List<double> mPlayStartMs = new .() ~ delete _;
	List<double> mPlayStopMs = new .() ~ delete _;
	List<int64> mPlayMemory = new .() ~ delete _;
	String mPlayCycleReport = new .() ~ delete _;
	int mPlayCycleScripts;

	void StartPlayCycleTest()
	{
		let text = scope String();
		GetArg("--play-cycle-test", text);
		mPlayCycleTarget = int.Parse(text) case .Ok(let count) ? count : 10;
		mPlayCycleExpectBlocked = HasArg("--expect-play-blocked");
	}

	void PlayCycleFail(StringView what)
	{
		mPlayCyclePass = false;
		mPlayCycleReport.AppendF("{}{}", mPlayCycleReport.IsEmpty ? "" : "; ", what);
	}

	/// Scripts in the scene that still have a managed instance.
	int LiveCSharpScripts()
	{
		int live = 0;
		for (let component in mScene.Components)
			if (let script = component as CSharpBehaviour)
				if (script.ManagedInstance > 0)
					live++;
		return live;
	}

	/// Called every frame from DrawUI while the test runs.
	void UpdatePlayCycleTest()
	{
		if (mPlayCycleTarget < 0)
			return;
		mPlayCycleFrame++;
		// The project's first build (started when it opened) must finish first.
		if (!mPlayCycleReady)
		{
			if (mPlayCycleFrame < 3 || mCheckRunning || mReloadQueued)
				return;
			mPlayCycleReady = true;
			Log.Info(scope $"PLAY CYCLE READY after {mPlayCycleFrame} frames (C# build ready: {mManagedBuildReady})");
			if (mPlayCycleExpectBlocked)
			{
				StartPlay();
				mPlayCycleWait = 0;
			}
			return;
		}
		if (mPlayCycleExpectBlocked)
		{
			// Play asks for a build first; once it has failed, Play must not have started.
			if (mPlayCycleWait == 0)
				mPlayCycleClock.Restart();
			// 1.5 s: past the success notice's 1 s, which must never clear a failure.
			if (mCheckRunning || mReloadQueued || ++mPlayCycleWait < 30 || mPlayCycleClock.ElapsedMilliseconds < 1500)
			{
				if (mPlay != .Edit)
					PlayCycleFail("Play started although the C# does not compile");
				return;
			}
			if (mPlay != .Edit)
				PlayCycleFail("Play started although the C# does not compile");
			if (mManagedBuildReady)
				PlayCycleFail("the build was reported ready");
			if (mStatus.IsEmpty)
				PlayCycleFail("the failure message was cleared");
			if (mPlayCyclePass)
				mPlayCycleReport.Append("Play stayed off after the failed build");
			FinishPlayCycleTest();
			return;
		}

		if (mPlayCycleDone == 0 && mPlay == .Edit && !mPlayAfterCompile && mPlayStartMs.IsEmpty)
		{
			if (mPlayCycleWait == 0)
				mPlayCycleClock.Restart();
			mPlayCycleWait++;
			if (mPlayCycleClock.ElapsedMilliseconds < 1500)
				return;
			if (mStatus == "C# assemblies compiled.")
				PlayCycleFail("the compile notice was still showing 1.5 s after the build");
		}
		if (mPlay == .Edit && !mPlayAfterCompile)
		{
			if (mPlayCycleDone >= mPlayCycleTarget)
			{
				FinishPlayCycleTest();
				return;
			}
			mPlayMemory.Add(ProfilerModules.ProcessMemory());
			mPlayCycleClock.Restart();
			StartPlay();
			mPlayCycleWait = 0;
			if (mPlay == .Edit && !mPlayAfterCompile)
			{
				PlayCycleFail(scope $"Play {mPlayCycleDone + 1} did not start ({mStatus})");
				FinishPlayCycleTest();
			}
			return;
		}
		if (mPlay == .Edit)
			return; // compiling before Play
		mPlayCycleWait++;
		if (mPlayCycleWait == 1)
		{
			// The first frame of Play has run: the scene started and its scripts attached.
			mPlayStartMs.Add(mPlayCycleClock.Elapsed.TotalMilliseconds);
			let live = LiveCSharpScripts();
			if (mPlayCycleDone == 0)
				mPlayCycleScripts = live;
			else if (live != mPlayCycleScripts)
				PlayCycleFail(scope $"Play {mPlayCycleDone + 1} has {live} C# scripts, the first had {mPlayCycleScripts}");
		}
		if (mPlayCycleWait < 10)
			return;
		mPlayCycleClock.Restart();
		StopPlay();
		mPlayStopMs.Add(mPlayCycleClock.Elapsed.TotalMilliseconds);
		let left = LiveCSharpScripts();
		if (left != 0)
			PlayCycleFail(scope $"{left} C# scripts still attached after Stop {mPlayCycleDone + 1}");
		mPlayCycleDone++;
	}

	void FinishPlayCycleTest()
	{
		if (!mPlayCycleExpectBlocked)
		{
			if (mPlayCycleDone < mPlayCycleTarget)
				PlayCycleFail(scope $"only {mPlayCycleDone} of {mPlayCycleTarget} Play/Stop cycles ran");
			double Median(List<double> values)
			{
				if (values.IsEmpty)
					return 0;
				let sorted = scope List<double>(values.GetEnumerator());
				sorted.Sort();
				return sorted[sorted.Count / 2];
			}
			let first = mPlayMemory.IsEmpty ? 0 : mPlayMemory[Math.Min(1, mPlayMemory.Count - 1)];
			let last = mPlayMemory.IsEmpty ? 0 : mPlayMemory.Back;
			mPlayCycleReport.AppendF("{}{} cycles, {} C# scripts each; Play {:F1} ms (first {:F1}), Stop {:F1} ms (medians); memory {} MB -> {} MB",
				mPlayCycleReport.IsEmpty ? "" : "; ", mPlayCycleDone, mPlayCycleScripts, Median(mPlayStartMs),
				mPlayStartMs.IsEmpty ? 0 : mPlayStartMs[0], Median(mPlayStopMs), first / (1024 * 1024), last / (1024 * 1024));
		}
		mPlayCycleTarget = -1;
		if (mPlayCyclePass)
			Log.Info(scope $"PLAY CYCLE TEST PASS: {mPlayCycleReport}");
		else
			Log.Error(scope $"PLAY CYCLE TEST FAIL: {mPlayCycleReport}");
		mDirty = false;
		Application.Quit();
	}
}
