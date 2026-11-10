using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using IDE;
using Beefy.utils;

namespace BeefBuild;

/// BeefBuild that stays loaded between builds, as the Beef IDE does: the compiler keeps what it parsed and built,
/// so a build after an edit recompiles only what the edit touched (well under a second instead of seconds).
/// tools/beef_compile_server.py builds it from the Beef install's own BeefBuild and IDE sources and talks to it:
///
///     BeefCompileServer -workspace=<dir> -config=Debug -serve-dir=<dir> [-serve-parent=<pid>]
///
/// It builds once as it starts. After each build it writes "<id> ok|failed <seconds>" to <serve-dir>/done, then
/// waits for <serve-dir>/request: a line with an id builds again (only sources whose time stamp changed, plus
/// sources added to or removed from auto-included folders); "quit" exits. It also exits when the parent process
/// (the editor) has gone, or after an hour without a request. What BeefBuild prints goes to its standard output.
class CompileServerApp : BuildApp
{
	const int IdleSeconds = 3600;
	const double RacyMilliseconds = 50;

	String mServeDir ~ delete _;
	int32 mParent;
	bool mBuildFinished;
	Stopwatch mClock = new .() ~ delete _;
	/// Time stamps of the sources as they were when their last build started.
	Dictionary<String, DateTime> mStamps = new .() ~ DeleteDictionaryAndKeys!(_);
	/// When the first build started: a source first seen with a later time stamp was written after it read it.
	DateTime mFirstBuildAt;
	String mRequest = new .("start") ~ delete _;

#if BF_PLATFORM_WINDOWS
	static bool ParentAlive(int32 pid) => true;
#else
	[CLink] static extern int32 kill(int32 pid, int32 signal);
	static bool ParentAlive(int32 pid) => pid <= 0 || kill(pid, 0) == 0;
#endif

	public override bool HandleCommandLineParam(String key, String value)
	{
		if (key == "-serve-dir" && value != null)
		{
			mServeDir = new .(value);
			return true;
		}
		if (key == "-serve-parent" && value != null)
		{
			mParent = int32.Parse(value).GetValueOrDefault();
			return true;
		}
		return base.HandleCommandLineParam(key, value);
	}

	public override void Init()
	{
		mFirstBuildAt = DateTime.UtcNow - TimeSpan(0, 0, 1);
		mClock.Start();
		base.Init();
	}

	public override void Stop()
	{
		if (mServeDir == null)
		{
			base.Stop();
			return;
		}
		mBuildFinished = true;
	}

	public override void Update(bool batchStart)
	{
		if (mServeDir != null && mBuildFinished)
		{
			mBuildFinished = false;
			Console.Out.Flush();
			WriteDone();
			if (!WaitForRequest())
			{
				DeleteAndNullify!(mServeDir);
				base.Stop();
				return;
			}
			mClock.Restart();
			let changed = Rescan();
			if (mVerbosity >= .Normal)
				Console.WriteLine(scope $"Compile server: {changed} sources changed ({mClock.Elapsed.TotalSeconds:F3} s to look)");
			mFailed = false;
			mHandledVerb = false;
		}
		base.Update(batchStart);
	}

	void WriteDone()
	{
		let temporary = scope $"{mServeDir}/done.tmp";
		if (File.WriteAllText(temporary, scope $"{mRequest} {(mFailed ? "failed" : "ok")} {mClock.Elapsed.TotalSeconds:F3}\n") case .Ok)
			File.Move(temporary, scope $"{mServeDir}/done").IgnoreError();
	}

	/// Waits for the next request; false to exit.
	bool WaitForRequest()
	{
		let path = scope $"{mServeDir}/request";
		let idle = scope Stopwatch()..Start();
		int polls = 0;
		while (true)
		{
			if (File.Exists(path))
			{
				let text = scope String();
				if (File.ReadAllText(path, text) case .Ok)
				{
					File.Delete(path).IgnoreError();
					text.Trim();
					if (text.IsEmpty || text == "quit")
						return false;
					mRequest.Set(text);
					return true;
				}
			}
			if (++polls % 100 == 0 && (!ParentAlive(mParent) || idle.Elapsed.TotalSeconds > IdleSeconds || !Directory.Exists(mServeDir)))
				return false;
			Thread.Sleep(2);
		}
	}

	/// Marks sources whose time stamp changed since their last build started, adds new files and drops deleted ones.
	int Rescan()
	{
		int changed = 0;
		for (let project in mWorkspace.mProjects)
			changed += Rescan(project.mRootFolder);
		if (changed > 0)
			mWorkspace.mForceNextCompile = true;
		return changed;
	}

	int Rescan(ProjectFolder folder)
	{
		int changed = 0;
		let folderPath = folder.GetFullImportPath(.. scope .());
		if (folder.IsAutoInclude() && Directory.Exists(folderPath))
		{
			for (let entry in Directory.EnumerateFiles(folderPath))
			{
				let path = entry.GetFilePath(.. scope .());
				let name = entry.GetFileName(.. scope .());
				if (IsBeefFile(path) && !folder.mChildMap.ContainsKey(name))
				{
					OnWatchedFileChanged(folder, .FileCreated, path);
					if (folder.mChildMap.TryGetValue(name, let item))
					{
						if (let source = item as ProjectSource)
						{
							source.HasChangedSinceLastCompile = true;
							RecordStamp(path);
						}
						changed++;
					}
				}
			}
			for (let entry in Directory.EnumerateDirectories(folderPath))
			{
				let name = entry.GetFileName(.. scope .());
				if (!folder.mChildMap.ContainsKey(name))
				{
					OnWatchedFileChanged(folder, .DirectoryCreated, entry.GetFilePath(.. scope .()));
					if (folder.mChildMap.TryGetValue(name, let item) && item is ProjectFolder)
						changed += Rescan((ProjectFolder)item);
				}
			}
		}
		for (int i = folder.mChildItems.Count - 1; i >= 0; i--)
		{
			let item = folder.mChildItems[i];
			if (let inner = item as ProjectFolder)
			{
				changed += Rescan(inner);
				continue;
			}
			let source = item as ProjectSource;
			if (source == null || !IsBeefFile(source.mPath))
				continue;
			let path = source.GetFullImportPath(.. scope .());
			if (!File.Exists(path))
			{
				// As the compiler's ProjectSourceRemovedCommand and the IDE's Project panel remove a file deleted on
				// disk. That command also clears the file's errors in the IDE's Errors panel, which BeefBuild does not
				// have, so it is done here, between builds, with the compiler idle.
				if (item.mIncludeKind == .Auto)
				{
					let system = mBfBuildCompiler.mBfSystem;
					system.Lock(0);
					let parser = system.FileRemoved(source);
					if (parser != null)
					{
						parser.RemoveDefs();
						delete parser;
						mBfBuildCompiler.[Friend]mWantsRemoveOldData = true;
					}
					system.Unlock();
					folder.RemoveChild(source, false);
					using (mMonitor.Enter())
						source.Dispose();
					source.Detach();
					changed++;
				}
				continue;
			}
			var stamp = File.GetLastWriteTimeUtc(path).GetValueOrDefault();
			let racy = (DateTime.UtcNow - stamp).TotalMilliseconds < RacyMilliseconds;
			if (mStamps.TryGetValue(path, let last))
			{
				if (last == stamp)
					continue;
			}
			else if (stamp < mFirstBuildAt)
			{
				mStamps[new .(path)] = stamp;
				continue;
			}
			// A file saved again within the file system's time stamp resolution could keep this stamp: such a file
			// is built again next time rather than trusted.
			if (racy)
				stamp = default;
			if (mStamps.TryGetAlt(path, let key, ?))
				mStamps[key] = stamp;
			else
				mStamps[new .(path)] = stamp;
			source.mEditData?.SetSavedData(null, IdSpan());
			source.HasChangedSinceLastCompile = true;
			mHaveSourcesChangedExternallySinceLastCompile = true;
			changed++;
		}
		return changed;
	}

	void RecordStamp(StringView path)
	{
		var stamp = File.GetLastWriteTimeUtc(path).GetValueOrDefault();
		if ((DateTime.UtcNow - stamp).TotalMilliseconds < RacyMilliseconds)
			stamp = default;
		if (mStamps.TryGetAlt(path, let key, ?))
			mStamps[key] = stamp;
		else
			mStamps[new .(path)] = stamp;
	}
}

class CompileServerProgram : BeefBuild.Program
{
	public override BuildApp CreateApp() => new CompileServerApp();

	public new static int32 Main(String[] args)
	{
		CompileServerProgram program = scope .();
		return program.DoMain(args);
	}
}
