using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Worker threads for spreading a frame's work over the machine's cores (docs/jobs.md). `Jobs.For(count, body)`
/// runs body(i) for every i below count, on the workers and the calling thread together, and returns when all are
/// done. Each body must only touch its own item's data. The workers sleep between batches; they start the first time
/// a batch is big enough to share.
///
/// Called while another For is running (from a body, or a second thread), the work runs on the calling thread.
/// A machine with one core has no workers and runs everything on the calling thread. Web builds spread work over
/// the page's cores too, when the build has threads and the page allows shared memory (see WebPlatform.ThreadsAvailable).
public static class Jobs
{
	static List<Thread> sThreads = new .() ~ delete _;
	static List<WaitEvent> sWake = new .() ~ DeleteContainerAndItems!(_);
	static bool sStarted;
	static bool sQuit;
	/// 1 while a batch is running (taken by compare-exchange, so only one caller hands out work at a time).
	static int32 sBusy;
	// The running batch.
	static delegate void(int) sBody;
	static int32 sCount;
	static int32 sChunk;
	static int32 sNext;
	static int32 sFinished;
	/// How many workers have begun running (a page that allows no more threads leaves one unstarted: see Start).
	static int32 sStartedWorkers;
	[ThreadStatic]
	static int32 sThreadIndex;
	/// The marker the workers' time is shown under in the Profiler: the one open where For was called, or -1.
	static int32 sLabel = -1;
	static ProfilerMarker sForMarker = .("Jobs.For", .Jobs);

	/// Which thread a body is running on: 0 for the calling thread (or any thread that is not a worker), 1 and up for
	/// the workers. Below ThreadCount, so a body can use scratch kept per thread.
	public static int32 ThreadIndex => sThreadIndex;

	/// How many threads share a batch, the calling one included.
	public static int32 ThreadCount
	{
		get
		{
			Start();
			return (int32)sThreads.Count + 1;
		}
	}

	static void Start()
	{
		if (sStarted)
			return;
		sStarted = true;
		// Web builds share the page's cores only when the build has threads and the page allows them (see
		// WebPlatform.ThreadsAvailable); otherwise everything runs on the calling thread.
		if (!WebPlatform.ThreadsAvailable)
			return;
		var cores = WebPlatform.HardwareThreads;
		// One core is the calling thread's; a few are left for the physics and audio threads.
		var workers = Math.Clamp(cores - 2, 0, 15);
#if !BF_PLATFORM_WASM
		// TALLOW_JOB_THREADS=N caps the threads sharing a batch (the calling one included): a server sharing its machine,
		// or a test showing that results do not depend on the thread count.
		let limit = scope String();
		if (Environment.GetEnvironmentVariable("TALLOW_JOB_THREADS", limit) case .Ok && int32.Parse(limit) case .Ok(let threads) && threads >= 1)
			workers = Math.Min(workers, threads - 1);
#endif
		for (int i < workers)
		{
			let wake = new WaitEvent();
			let index = (int32)i + 1;
			sWake.Add(wake);
			let thread = new Thread(new () => Work(wake, index));
			thread.IsBackground = true;
			thread.SetName(scope $"Tallow Job {i}");
			thread.Start(false);
			// A web page allows only so many threads at once (its pool of workers): when it refuses this one, the
			// thread never runs. Wait for it to report in, and drop it if it never does, so that a batch is never
			// shared with a worker that cannot take its part.
			if (!WorkerStarted((int32)i + 1))
			{
				// Not deleted: a thread the runtime never started is left to the page (it is small, and once).
				sWake.Remove(wake);
				delete wake;
				break;
			}
			sThreads.Add(thread);
		}
	}

	/// Waits, briefly, for a just-started worker to report in (Work counts them). A thread the runtime never started
	/// (the page's workers are all in use) never does, and the caller goes on without it.
	static bool WorkerStarted(int32 expected)
	{
		for (int spins = 0; spins < 200; spins++)
		{
			if (Interlocked.Load(ref sStartedWorkers) >= expected)
				return true;
			Thread.Sleep(1);
		}
		return Interlocked.Load(ref sStartedWorkers) >= expected;
	}

	/// Programs that never call Application.Shutdown (tools, tests) stop the workers on the way out.
	static ~this()
	{
		Shutdown();
	}

	/// Stops the workers (when the application quits).
	public static void Shutdown()
	{
		if (sThreads.IsEmpty)
			return;
		sQuit = true;
		for (let wake in sWake)
			wake.Set();
		for (let thread in sThreads)
		{
			thread.Join();
			delete thread;
		}
		sThreads.Clear();
	}

	static void Work(WaitEvent wake, int32 index)
	{
		sThreadIndex = index;
		Interlocked.Increment(ref sStartedWorkers);
		Profiler.NameThread(scope $"Job {index}");
		while (true)
		{
			wake.WaitFor();
			if (sQuit)
				return;
			let label = sLabel;
			if (label >= 0)
				Profiler.Begin(label);
			RunChunks();
			if (label >= 0)
				Profiler.End();
			Interlocked.Increment(ref sFinished);
		}
	}

	static void RunChunks()
	{
		let count = sCount;
		let chunk = sChunk;
		let body = sBody;
		while (true)
		{
			let end = Interlocked.Add(ref sNext, chunk);
			let first = end - chunk;
			if (first >= count)
				return;
			for (int index = first; index < Math.Min(end, count); index++)
				body(index);
		}
	}

	/// Runs body(i) for every i in 0 ..< count, spread over the workers, and returns when every one has run. Items
	/// are handed out `chunk` at a time (more for cheap items, so threads take turns less often). Fewer than
	/// `minimum` items run on the calling thread alone: below that, waking the workers costs more than it saves.
	public static void For(int count, delegate void(int) body, int chunk = 1, int minimum = 2)
	{
		if (count <= 0)
			return;
		Start();
		if (count < minimum || sThreads.IsEmpty || Interlocked.CompareExchange(ref sBusy, 0, 1) != 0)
		{
			for (int index < count)
				body(index);
			return;
		}
		// The workers' time shows under the caller's marker (Find Paths, CPU Skinning...), and the caller's own as Jobs.For.
		sLabel = Profiler.Enabled ? Profiler.Current : -1;
		if (sLabel < 0 && Profiler.Enabled)
			sLabel = sForMarker.Id;
		sForMarker.Begin();
		defer Profiler.End();
		sBody = body;
		sCount = (int32)count;
		sChunk = (int32)Math.Max(chunk, 1);
		sNext = 0;
		sFinished = 0;
		// Only as many workers as there are chunks for, beside this thread.
		let chunks = (count + sChunk - 1) / sChunk;
		let helpers = (int32)Math.Min(sThreads.Count, chunks - 1);
		for (int i < helpers)
			sWake[i].Set();
		RunChunks();
		while (Interlocked.Load(ref sFinished) < helpers)
			Thread.SpinWait(32);
		sBody = null;
		Interlocked.Store(ref sBusy, 0);
	}
}
