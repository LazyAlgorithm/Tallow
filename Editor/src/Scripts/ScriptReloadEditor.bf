using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

extension EditorApp
{
	ScriptReload mScriptReload = new .() ~ delete _;
	ProjectFolderMonitor mScriptMonitor = new .() { ScriptsOnly = true } ~ delete _;
	Stopwatch mScriptPollClock = new .(true) ~ delete _;
	Stopwatch mScriptDebounce = new .(true) ~ delete _;
	String mReloadBaseline = new .() ~ delete _;
	String mReloadManifest = new .() ~ delete _;
	bool mReloadReady;
	bool mReloadQueued;
	bool mReloadForceConservative;
	bool mScriptsNeedReload;
	bool mPlayAfterCompile;
	bool mCheckWasReload;
	bool mWantFullRestart;

	void InitializeScriptReload()
	{
#if (BF_PLATFORM_LINUX || BF_PLATFORM_WINDOWS) && BF_64_BIT
		let project = Project.Current;
		let session = scope $"{project.Path}/.tallow-reload/session-{DateTime.UtcNow.Ticks}";
		mReloadBaseline.Set(scope $"{session}.json");
		mReloadManifest.Set(scope $"{session}.manifest");
		// On Windows the script library is linked for an exact place beside this program: say where that is.
		Directory.CreateDirectory(scope $"{project.Path}/.tallow-reload").IgnoreError();
		if (!ScriptReload.WriteHostInfo(scope $"{session}.host"))
		{
			Log.Warning("No address space near the program for script libraries. Full rebuild remains available.");
			return;
		}
		let command = scope String(Terminal.Python)..Append(' ');
		Terminal.Quote(scope $"{project.EngineRoot}/tools/reload_scripts.py" , command);
		command.Append(' ');
		Terminal.Quote(project.Path, command);
		command.Append(" --snapshot --baseline ");
		Terminal.Quote(mReloadBaseline, command);
		Directory.CreateDirectory(scope $"{project.Path}/build").IgnoreError();
		command.Append(" > ");
		Terminal.Quote(scope $"{project.Path}/build/script-reload.log" , command);
		command.Append(" 2>&1");
		mReloadReady = Terminal.Run(command) == 0;
		if (!mReloadReady)
		{
			let why = scope String();
			File.ReadAllText(scope $"{project.Path}/build/script-reload.log" , why).IgnoreError();
			why.Trim();
			if (!why.IsEmpty)
				Log.Warning(why);
		}
		if (mReloadReady)
			Log.Info("Automatic script library reload enabled, including new scripts and supported field changes.");
		else
			Log.Warning("Could not initialize script library reload. Full rebuild remains available.");
		mScriptMonitor.Poll(Assets.ProjectPath);
#endif
	}

	/// Compare the saved source against the last activated library, without compiling it.
	/// Exit codes: 0 unchanged, 10 methods only, 11 declarations, 3 incompatible host.
	int CheckScriptChanges()
	{
		if (!mReloadReady)
			return 3;
		let project = Project.Current;
		let command = scope String(Terminal.Python)..Append(' ');
		Terminal.Quote(scope $"{project.EngineRoot}/tools/reload_scripts.py", command);
		command.Append(' ');
		Terminal.Quote(project.Path, command);
		command.Append(" --classify --baseline ");
		Terminal.Quote(mReloadBaseline, command);
		command.Append(" > ");
		command.Append(Terminal.Null);
		command.Append(" 2>&1");
		let status = Terminal.Run(command);
#if BF_PLATFORM_LINUX
		// system() returns the wait status, not the process exit code.
		if (status >= 0)
			return (status >> 8) & 0xFF;
#endif
		return status;
	}

	/// A save already tells us which files changed. The script mode decides
	/// whether to reload in Edit mode or defer method changes until Play.
	void QueueScriptReload(bool fromEditorSave = false, bool explicitRequest = false, bool conservative = false)
	{
		if (fromEditorSave)
			mScriptMonitor.Poll(Assets.ProjectPath);
		if (!explicitRequest && Project.Current.ReloadMode == .Manual)
		{
			mScriptsNeedReload = true;
			return;
		}
		if (!explicitRequest && mPlay == .Edit && Project.Current.ReloadMode == .Automatic &&
			!Project.Current.ReloadMethodsInEdit)
		{
			let change = CheckScriptChanges();
			if (change == 0)
			{
				if (!mCheckRunning && !mReloadQueued)
					mScriptsNeedReload = false;
				return;
			}
			mScriptsNeedReload = true;
			if (change == 10)
			{
				mStatus.Set("Script methods changed. Reload on Play or use File > Reload Scripts.");
				return;
			}
			if (change != 11)
			{
				mStatus.Set("Script dependencies changed. Full Rebuild & Restart may be required.");
				return;
			}
			// New fields and components must be reflected in the Inspector in Edit mode.
			conservative = true;
		}
		mScriptsNeedReload = true;
		mReloadQueued = true;
		if (conservative)
			mReloadForceConservative = true;
		mScriptDebounce.Restart();
	}

	void PollScriptReload()
	{
		CollectCheckResults();
		if (mScriptPollClock.ElapsedMilliseconds >= 500)
		{
			mScriptPollClock.Restart();
			if (mScriptMonitor.Poll(Assets.ProjectPath))
				QueueScriptReload();
		}
		if (!mReloadReady) return;
		if (!mReloadQueued || mCheckRunning || mScriptDebounce.ElapsedMilliseconds < 150) return;
		mReloadQueued = false;
		let conservative = mReloadForceConservative || Project.Current.ReloadMode == .Conservative;
		mReloadForceConservative = false;
		if (mCheckThread != null)
		{
			mCheckThread.Join();
			delete mCheckThread;
			mCheckThread = null;
		}
		mCheckWasReload = true;
		mCheckRunning = true;
		Interlocked.Store(ref mCheckFinished, false);
		mStatus.Set("Compiling script library...");
		mCheckThread = new Thread(new () =>
			{
				let project = Project.Current;
				Directory.CreateDirectory(scope $"{project.Path}/build").IgnoreError();
				let command = scope String(Terminal.Python)..Append(' ');
				Terminal.Quote(scope $"{project.EngineRoot}/tools/reload_scripts.py" , command);
				command.Append(' ');
				Terminal.Quote(project.Path, command);
				command.Append(" --baseline ");
				Terminal.Quote(mReloadBaseline, command);
				command.Append(" --manifest ");
				Terminal.Quote(mReloadManifest, command);
				command.Append(conservative ? " --mode conservative" : " --mode automatic");
				command.Append(" > ");
				Terminal.Quote(scope $"{project.Path}/build/script-reload.log" , command);
				command.Append(" 2>&1");
				mCheckSucceeded = Terminal.Run(command) == 0;
				mCheckLog.Clear();
				File.ReadAllText(scope $"{project.Path}/build/script-reload.log" , mCheckLog).IgnoreError();
				Interlocked.Store(ref mCheckFinished, true);
			});
		mCheckThread.Start(false);
	}

	void FinishScriptReload()
	{
		if (!mCheckSucceeded)
		{
			mPlayAfterCompile = false;
			Log.Error(mCheckLog);
			mStatus.Set("Script build failed; previous code remains active. See Console.");
			return;
		}
		let error = scope String();
		if (!mScriptReload.Apply(mReloadManifest, error, mScene))
		{
			// The lightweight patch path validates ABI/type compatibility before changing
			// live dispatch data. Retry with structural migration when it cannot apply.
			let manifest = scope String();
			File.ReadAllText(mReloadManifest, manifest).IgnoreError();
			if (manifest.Contains("mode methods"))
			{
				Log.Warning(scope $"Method patch unavailable ({error}); retrying structural script reload.");
				mStatus.Set("Retrying structural script reload...");
				QueueScriptReload(false, true, true);
				return;
			}
			mPlayAfterCompile = false;
			Log.Error(error);
			mStatus.Set(error);
			return;
		}
		let project = Project.Current;
		let command = scope String(Terminal.Python)..Append(' ');
		Terminal.Quote(scope $"{project.EngineRoot}/tools/reload_scripts.py" , command);
		command.Append(' ');
		Terminal.Quote(project.Path, command);
		command.Append(" --commit --baseline ");
		Terminal.Quote(mReloadBaseline, command);
		command.Append(" --manifest ");
		Terminal.Quote(mReloadManifest, command);
		if (Terminal.Run(command) != 0)
		{
			mReloadReady = false;
			Log.Warning("Scripts activated, but symbol tracking failed; restart before another reload.");
		}
		// Method-only edits leave declarations, component registration and assets intact.
		// Avoid rescanning the project when just the script dispatch table changed.
		let manifest = scope String();
		File.ReadAllText(mReloadManifest, manifest).IgnoreError();
		if (!manifest.Contains("mode methods"))
		{
			mScriptCatalog.Refresh(Assets.ProjectPath, project.Name);
			NodeLibrary.RefreshCodeNodes();
			RefreshAssetList();
		}
		mScriptsNeedReload = mReloadQueued;
		Log.Info("Script library reloaded; scene and Play state preserved.");
		if (mScriptsNeedReload)
		{
			mStatus.Set("Additional script changes pending compilation.");
			return;
		}
		if (mPlayAfterCompile && project.PlayAfterCompile && mPlay == .Edit)
		{
			mPlayAfterCompile = false;
			StartPlay();
			return;
		}
		mPlayAfterCompile = false;
		if (mPlay == .Edit)
			mStatus.Set("Scripts ready. Press Play when you want to start.");
		else
			mStatus.Set("Scripts hot reloaded.");
	}
}
