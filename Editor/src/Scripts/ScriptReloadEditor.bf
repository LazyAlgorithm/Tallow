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

	void QueueScriptReload()
	{
		mReloadQueued = true;
		mScriptDebounce.Restart();
	}

	void PollScriptReload()
	{
		CollectCheckResults();
		if (!mReloadReady) return;
		if (mScriptPollClock.ElapsedMilliseconds >= 500)
		{
			mScriptPollClock.Restart();
			if (mScriptMonitor.Poll(Assets.ProjectPath))
				QueueScriptReload();
		}
		if (!mReloadQueued || mCheckRunning || mScriptDebounce.ElapsedMilliseconds < 350) return;
		mReloadQueued = false;
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
			Log.Error(mCheckLog);
			mStatus.Set("Script build failed; previous code remains active. See Console.");
			return;
		}
		let error = scope String();
		if (!mScriptReload.Apply(mReloadManifest, error, mScene))
		{
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
		mScriptCatalog.Refresh(Assets.ProjectPath, project.Name);
		NodeLibrary.RefreshCodeNodes();
		RefreshAssetList();
		Log.Info("Script library reloaded; scene, supported fields and Play state preserved.");
		mStatus.Set("Scripts reloaded.");
	}
}
