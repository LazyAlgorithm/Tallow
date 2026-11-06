using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Text;
using Tallow;

namespace Tallow.Editor;

/// Owns the isolated compiler process. All pipe I/O is on this worker, never the rendering thread.
class BeefAnalysisClient
{
	Monitor mLock = new .() ~ delete _;
	WaitEvent mWake = new .() ~ delete _;
	Thread mThread;
	SpawnedProcess mProcess;
	String mProject = new .() ~ delete _;
	String mService = new .() ~ delete _;
	String mHelper = new .() ~ delete _;
	String mPending = new .() ~ delete _;
	String mResult = new .() ~ delete _;
	bool mStopping;
	bool mReady;
	bool mFailed;

	public this(StringView project, StringView service, StringView helper)
	{
		mProject.Set(project);
		mService.Set(service);
		mHelper.Set(helper);
		mThread = new Thread(new => Run);
		mThread.Start(false);
	}

	public ~this()
	{
		Stop();
		delete mThread;
	}

	public bool Ready
	{
		get
		{
			using (mLock.Enter()) return mReady;
		}
	}

	public bool Failed
	{
		get
		{
			using (mLock.Enter()) return mFailed;
		}
	}

	public void Stop()
	{
		using (mLock.Enter())
		{
			mStopping = true;
			mProcess?.Kill(1, .KillChildren);
		}
		mWake.Set(true);
		mThread?.Join();
	}

	public void Submit(StringView request)
	{
		using (mLock.Enter())
			mPending.Set(request); // Supersede queued work; never build a backlog while typing.
		mWake.Set();
	}

	public bool TakeResult(String output)
	{
		using (mLock.Enter())
		{
			if (mResult.IsEmpty) return false;
			output.Set(mResult);
			mResult.Clear();
			return true;
		}
	}

	void Run()
	{
		let start = scope ProcessStartInfo();
		let python = scope String();
		if (!Toolchain.[Friend]FindOnPath(Terminal.Python, python))
		{
			using (mLock.Enter()) mFailed = true;
			return;
		}
		start.SetFileName(python);
		let arguments = scope String();
		Terminal.Quote(mService, arguments);
		arguments.Append(" --project ");
		Terminal.Quote(mProject, arguments);
		arguments.Append(" --helper ");
		Terminal.Quote(mHelper, arguments);
		start.SetArguments(arguments);
		start.UseShellExecute = false;
		start.CreateNoWindow = true;
		start.RedirectStandardInput = true;
		start.RedirectStandardOutput = true;
		let process = scope SpawnedProcess();
		defer
		{
			using (mLock.Enter())
			{
				mProcess = null;
				mReady = false;
				mFailed = !mStopping;
			}
			process.Kill(1, .KillChildren);
			process.WaitFor();
		}
		using (mLock.Enter())
		{
			if (mStopping) return;
			if (process.Start(start) case .Err) return;
			mProcess = process;
		}
		let input = scope FileStream();
		let output = scope FileStream();
		if (process.AttachStandardInput(input) case .Err) return;
		if (process.AttachStandardOutput(output) case .Err) return;
		let writer = scope StreamWriter(input, Encoding.UTF8, 4096, false);
		writer.AutoFlush = true;
		let reader = scope StreamReader(output, null, false, 4096);
		let line = scope String();
		if (reader.ReadLine(line) case .Err) return;
		let hello = SaveNode.FromText(line);
		defer delete hello;
		if (hello == null || hello["ready"]?.AsInteger != 1) return;
		using (mLock.Enter()) mReady = true;
		let request = scope String();
		while (true)
		{
			using (mLock.Enter())
			{
				if (mStopping) return;
				request.Set(mPending);
				mPending.Clear();
			}
			if (request.IsEmpty)
			{
				mWake.WaitFor(100);
				continue;
			}
			if (writer.WriteLine(request) case .Err) return;
			line.Clear();
			if (reader.ReadLine(line) case .Err) return;
			using (mLock.Enter()) mResult.Set(line);
		}
	}
}
