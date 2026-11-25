using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Receives pages on the main thread, inside the frame's upload budget.
interface IStreamConsumer
{
	/// Puts a decoded page where it lives (a GPU buffer, a texture mip). False if it could not be (the page is dropped).
	bool Upload(StreamResource resource, int page, Span<uint8> data);
}

/// One thing that is streamed in pages: a mesh's geometry, a texture's mips, a virtual texture. Made by its owner,
/// registered with StreamingCore.Register, and unregistered before it is deleted.
class StreamResource
{
	/// Unique within its kind, below 2^40.
	public uint64 Id;
	public StreamKind Kind;
	public PageFile File;
	public IStreamConsumer Consumer;
	/// The page is never evicted (a geometry root page).
	public bool PinPages;
	/// For the owner's own use.
	public int64 UserData;
	public int mInFlight;
	public bool mDead;
}

/// The one streaming system everything shares (tallowengine.com plan M4): geometry pages, texture mips and virtual
/// texture tiles all go through it. A request names (resource, page, priority); IO threads read and inflate the page;
/// the main thread uploads finished pages in Update within UploadBudgetMB a frame and tracks them in a StreamPool per
/// kind, which evicts the coldest page to make room. The main thread never reads or inflates anything.
///
/// Main thread: Register, Unregister, Request, Update, pools, counters. Worker threads touch only the queues.
static class StreamingCore
{
	class Request
	{
		public StreamResource resource;
		public int page;
		public float priority;
		public uint64 queuedNs;
	}

	class Ready
	{
		public Request request;
		public List<uint8> data ~ delete _;
		public bool ok;
	}

	public const int Kinds = 3;
	/// Megabytes a frame may spend uploading finished pages. AssetLoader's main-thread work should count against the
	/// same number (RemainingUploadBytes).
	public static float UploadBudgetMB = 4;
	/// Logs requests, uploads and evictions (--streaming-log).
	public static bool Log;

	static Monitor sMonitor = new .() ~ delete _;
	static WaitEvent sWake = new .() ~ delete _;
	static Dictionary<uint64, Request>[Kinds] sQueued;
	static HashSet<uint64>[Kinds] sInFlight;
	static List<Ready> sReady = new .() ~ delete _;
	static List<Thread> sThreads = new .() ~ delete _;
	static StreamPool[Kinds] sPools;
	static bool sQuit;
	static bool sStarted;
	static int sFrame;
	static int64 sFrameUploaded;

	// Counters (main thread).
	public static int64 Requests;
	public static int64 Misses;
	public static int64 Uploads;
	public static int64 UploadedBytes;
	public static int64 Failures;
	public static float LastFrameUploadMB;
	public static float RequestsPerSecond;
	/// Average milliseconds from request to resident.
	public static float AverageLatencyMs;
	static int64 sLatencyCount;
	static double sLatencyTotalMs;
	static int64 sRequestsAtWindow;
	static uint64 sWindowNs;

	public static int Frame => sFrame;
	public static bool Started => sStarted;
	public static StreamPool Pool(StreamKind kind) => sPools[(int)kind];

	/// Requests waiting for an IO thread, plus those being read.
	public static int QueueDepth
	{
		get
		{
			int n = 0;
			using (sMonitor.Enter())
			{
				for (int k < Kinds)
					n += sQueued[k].Count + sInFlight[k].Count;
			}
			return n;
		}
	}

	/// Bytes left in this frame's upload budget.
	public static int64 RemainingUploadBytes => Math.Max(0, (int64)(UploadBudgetMB * 1000000) - sFrameUploaded);

	/// Default pool budgets in megabytes (geometry, textures, virtual textures) for a quality level.
	public static void DefaultBudgetsMB(QualityLevel level, out int64 geo, out int64 tex, out int64 vt)
	{
		switch (level)
		{
		case .Low: geo = 256; tex = 512; vt = 256;
		case .Ultra: geo = 1024; tex = 2048; vt = 1024;
		default: geo = 512; tex = 1024; vt = 512;
		}
	}

	/// Starts the IO threads (`threads` 0 reads in Update, for tests and pages with no threads) and makes the pools.
	/// Budgets in bytes; 0 takes the quality default.
	public static void Start(int threads = 2, int64 geoBytes = 0, int64 texBytes = 0, int64 vtBytes = 0)
	{
		if (sStarted)
			return;
		let geo = (int64)Quality.Current.geometryBudgetMB, tex = (int64)Quality.Current.textureBudgetMB, vt = (int64)Quality.Current.vtBudgetMB;
		let budgets = int64[3](geoBytes > 0 ? geoBytes : geo * 1048576, texBytes > 0 ? texBytes : tex * 1048576, vtBytes > 0 ? vtBytes : vt * 1048576);
		for (int k < Kinds)
		{
			sQueued[k] = new .();
			sInFlight[k] = new .();
			sPools[k] = new StreamPool((StreamKind)k, budgets[k]);
		}
		sQuit = false;
		sStarted = true;
		sFrame = 0;
		Requests = Misses = Uploads = UploadedBytes = Failures = 0;
		sLatencyCount = 0;
		sLatencyTotalMs = 0;
		for (int i < threads)
		{
			let thread = new Thread(new => IoMain);
			thread.SetName("Streaming IO");
			thread.Start(false);
			sThreads.Add(thread);
		}
	}

	public static void Stop()
	{
		if (!sStarted)
			return;
		using (sMonitor.Enter())
			sQuit = true;
		sWake.Set(true);
		for (let thread in sThreads)
		{
			thread.Join();
			delete thread;
		}
		sThreads.Clear();
		for (int k < Kinds)
		{
			for (let request in sQueued[k].Values)
				delete request;
			delete sQueued[k];
			delete sInFlight[k];
			delete sPools[k];
			sPools[k] = null;
		}
		for (let ready in sReady)
		{
			delete ready.request;
			delete ready;
		}
		sReady.Clear();
		sStarted = false;
	}

	/// A `--streaming-budget` was given: the quality presets must not overwrite it.
	public static bool BudgetsFromArgs;

	/// Sets the three pool budgets from the quality values (megabytes), unless the command line chose them.
	public static void ApplyBudgetsMB(int64 geo, int64 tex, int64 vt)
	{
		if (!sStarted || BudgetsFromArgs)
			return;
		SetBudget(.GeoPage, geo << 20);
		SetBudget(.TextureMip, tex << 20);
		SetBudget(.VtTile, vt << 20);
	}

	public static void SetBudget(StreamKind kind, int64 bytes) => sPools[(int)kind].Budget = bytes;

	/// Makes a resource known to the core. It stays the owner's to delete after Unregister.
	public static void Register(StreamResource resource) => resource.mDead = false;

	/// Forgets a resource's queued requests and waits for reads of it already running, so the owner can delete it.
	/// Its resident pages are released (their bytes retire like evictions).
	public static void Unregister(StreamResource resource, int pageCount)
	{
		using (sMonitor.Enter())
		{
			resource.mDead = true;
			let queued = sQueued[(int)resource.Kind];
			let doomed = scope List<uint64>();
			for (let (key, request) in queued)
			{
				if (request.resource == resource)
					doomed.Add(key);
			}
			for (let key in doomed)
			{
				delete queued[key];
				queued.Remove(key);
			}
		}
		while (true)
		{
			using (sMonitor.Enter())
			{
				if (resource.mInFlight == 0)
					break;
			}
			Thread.Sleep(1);
		}
		using (sMonitor.Enter())
		{
			for (var i = sReady.Count - 1; i >= 0; i--)
			{
				if (sReady[i].request.resource == resource)
				{
					delete sReady[i].request;
					delete sReady[i];
					sReady.RemoveAt(i);
				}
			}
		}
		let pool = sPools[(int)resource.Kind];
		for (int page < pageCount)
			pool.Remove(resource.Id, page, sFrame);
	}

	/// Asks for a page. Resident pages are just marked used; others queue (a repeat only raises the priority).
	/// True when the page was newly queued.
	public static bool Request(StreamResource resource, int page, float priority)
	{
		let kind = (int)resource.Kind;
		let pool = sPools[kind];
		if (pool.Contains(resource.Id, page))
		{
			pool.Touch(resource.Id, page, sFrame);
			return false;
		}
		let key = StreamPool.Key(resource.Id, page);
		Misses++;
		using (sMonitor.Enter())
		{
			if (sInFlight[kind].Contains(key))
				return false;
			if (sQueued[kind].TryGetValue(key, let queued))
			{
				if (priority > queued.priority)
					queued.priority = priority;
				return false;
			}
			let request = new Request();
			request.resource = resource;
			request.page = page;
			request.priority = priority;
			request.queuedNs = SDL.SDL_GetTicksNS();
			sQueued[kind][key] = request;
		}
		Requests++;
		if (Log)
			Console.WriteLine(scope $"streaming: request {resource.Kind} {resource.Id}:{page} priority {priority}");
		sWake.Set(false);
		return true;
	}

	/// The main thread's part, once a frame: uploads finished pages within the budget, retires evicted bytes, updates
	/// the counters. `frame` is the application's frame number.
	public static void Update(int frame)
	{
		if (!sStarted)
			return;
		sFrame = frame;
		sFrameUploaded = 0;
		for (int k < Kinds)
			sPools[k].Retire(frame);
		if (sThreads.IsEmpty)
		{
			// No IO threads: do some of their work here, a little each frame.
			let start = SDL.SDL_GetTicksNS();
			while (SDL.SDL_GetTicksNS() - start < 2000000 && ReadOne()) {}
		}
		let budget = (int64)(UploadBudgetMB * 1000000);
		var i = 0;
		while (true)
		{
			Ready ready = null;
			using (sMonitor.Enter())
			{
				if (i >= sReady.Count)
					break;
				ready = sReady[i];
			}
			let request = ready.request;
			let resource = request.resource;
			let pool = sPools[(int)resource.Kind];
			if (!ready.ok || resource.mDead)
			{
				if (!ready.ok)
					Failures++;
				Remove(ready);
				continue;
			}
			let bytes = ready.data.Count;
			// One page may always go through, so a page bigger than the budget is not stuck forever.
			if (sFrameUploaded > 0 && sFrameUploaded + bytes > budget)
				break;
			if (!pool.CanAdmit(bytes, frame))
			{
				// Room comes as evicted pages retire or pages go cold: keep it, try next frame. Later pages of a
				// smaller size may still fit.
				i++;
				continue;
			}
			if (resource.Consumer == null || resource.Consumer.Upload(resource, request.page, .(ready.data.Ptr, ready.data.Count)))
			{
				pool.Add(resource.Id, request.page, bytes, frame, resource.PinPages);
				sFrameUploaded += bytes;
				Uploads++;
				UploadedBytes += bytes;
				let ms = (double)(SDL.SDL_GetTicksNS() - request.queuedNs) / 1.0e6;
				sLatencyCount++;
				sLatencyTotalMs += ms;
				if (Log)
					Console.WriteLine(scope $"streaming: resident {resource.Kind} {resource.Id}:{request.page} ({bytes} bytes, {ms:F1} ms)");
			}
			else
				Failures++;
			Remove(ready);
		}
		LastFrameUploadMB = (float)sFrameUploaded / 1.0e6f;
		AverageLatencyMs = sLatencyCount > 0 ? (float)(sLatencyTotalMs / sLatencyCount) : 0;
		let now = SDL.SDL_GetTicksNS();
		if (sWindowNs == 0)
			sWindowNs = now;
		if (now - sWindowNs >= 1000000000)
		{
			RequestsPerSecond = (float)(Requests - sRequestsAtWindow) * 1.0e9f / (float)(now - sWindowNs);
			sRequestsAtWindow = Requests;
			sWindowNs = now;
		}
	}

	static void Remove(Ready ready)
	{
		using (sMonitor.Enter())
			sReady.Remove(ready);
		delete ready.request;
		delete ready;
	}

	/// Takes the best queued request, reads and inflates it, queues the result. False if nothing was queued.
	static bool ReadOne()
	{
		Request request = null;
		using (sMonitor.Enter())
		{
			int bestKind = -1;
			uint64 bestKey = 0;
			float best = float.MinValue;
			for (int k < Kinds)
			{
				for (let (key, queued) in sQueued[k])
				{
					if (queued.priority > best)
					{
						best = queued.priority;
						bestKind = k;
						bestKey = key;
					}
				}
			}
			if (bestKind < 0)
				return false;
			request = sQueued[bestKind][bestKey];
			sQueued[bestKind].Remove(bestKey);
			sInFlight[bestKind].Add(bestKey);
			request.resource.mInFlight++;
		}
		let ready = new Ready();
		ready.request = request;
		ready.data = new .();
		let stored = scope List<uint8>();
		ready.ok = request.resource.File.ReadRaw(request.page, stored) case .Ok && request.resource.File.Decode(request.page, stored, ready.data) case .Ok;
		using (sMonitor.Enter())
		{
			sInFlight[(int)request.resource.Kind].Remove(StreamPool.Key(request.resource.Id, request.page));
			sReady.Add(ready);
			request.resource.mInFlight--;
		}
		return true;
	}

	static void IoMain()
	{
		while (true)
		{
			using (sMonitor.Enter())
			{
				if (sQuit)
					return;
			}
			if (!ReadOne())
				sWake.WaitFor(20);
		}
	}
}
