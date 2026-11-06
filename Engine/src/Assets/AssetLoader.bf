using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Loads models and textures in the background, so that a level or a new weapon can be got ready while the game
/// keeps running. Reading and decoding files is done on loading threads; what must happen on the main thread (sending
/// meshes and textures to the graphics card) is done a little each frame, within Upload Budget, so that the frame
/// rate holds while it loads. Once something is loaded the ordinary calls (Assets.GetMesh, GetTexture, a Mesh
/// Renderer naming it) find it at once.
///
///   let batch = AssetLoader.Preload("Models/tank.glb", "Textures/camo.png");
///   ... later: if (batch.IsDone) ...   batch.Progress goes from 0 to 1
///
/// In a browser, which has no threads here, the same work is done on the main thread, within the same budget.
static class AssetLoader
{
	public enum Kind
	{
		Mesh,
		SkinnedModel,
		Texture
	}

	/// One thing to load. Jobs are shared between batches that ask for the same thing.
	public class Job
	{
		public String path = new .() ~ delete _;
		public Kind kind;
		public bool finished;
		public bool adopted;
		public Mesh mesh;
		public SkinnedModel model;
		public List<SkinnedModel.PendingImage> images ~ DeleteContainerAndItems!(_);
		public uint8* pixels;
		public int32 width, height;
		public int32 waiting;
		/// A texture with a compressed copy, which is read when it is made rather than decoded here.
		public bool compressed;
	}

	/// Several things to load, followed together.
	public class Batch
	{
		List<Job> mJobs = new .() ~ delete _;
		public int32 Total => (int32)mJobs.Count;
		/// How many are loaded and ready to use.
		public int32 Loaded
		{
			get
			{
				int32 count = 0;
				for (let job in mJobs)
				{
					if (job.adopted)
						count++;
				}
				return count;
			}
		}
		/// 0 to 1.
		public float Progress => Total == 0 ? 1 : (float)Loaded / Total;
		public bool IsDone => Loaded == Total;

		public ~this()
		{
			for (let job in mJobs)
				Release(job);
		}

		public void AddJob(Job job) => mJobs.Add(job);
	}

	/// Milliseconds a frame may spend on the main thread's share of loading.
	public static float UploadBudget = 4;
	/// How many things have been loaded on loading threads, for tests and statistics.
	public static int32 LoadedInBackground;

	static Monitor sMonitor = new .() ~ delete _;
	static WaitEvent sWake = new .() ~ delete _;
	static List<Job> sQueue = new .() ~ delete _;
	static List<Job> sFinished = new .() ~ delete _;
	static Dictionary<String, Job> sJobs = new .() ~ delete _;
	static List<Thread> sThreads = new .() ~ delete _;
	static bool sQuit;

	/// The kind of thing a path is, by its extension, or false for something this loader does not handle.
	public static bool KindOf(StringView path, out Kind kind)
	{
		kind = .Texture;
		let lower = scope String(path)..ToLower();
		let hash = lower.IndexOf('#');
		if (hash >= 0)
			lower.RemoveToEnd(hash);
		if (Assets.IsModelPath(lower))
		{
			kind = .Mesh;
			return true;
		}
		return lower.EndsWith(".png") || lower.EndsWith(".jpg") || lower.EndsWith(".jpeg") || lower.EndsWith(".tga") || lower.EndsWith(".bmp");
	}

	static bool AlreadyLoaded(StringView path, Kind kind)
	{
		switch (kind)
		{
		case .Mesh: return Assets.HasMesh(path);
		case .SkinnedModel: return SkinnedModel.IsLoaded(path);
		case .Texture: return Assets.HasTexture(path);
		}
	}

	/// Starts loading things (paths relative to the project, as everywhere) and returns a batch to follow them by.
	/// Models are loaded as meshes; give them to PreloadSkinned instead for Skinned Mesh Renderers. Things already
	/// loaded count as done at once. Yours to delete when you no longer need it (the loaded things stay loaded).
	public static Batch Preload(params StringView[] paths)
	{
		let batch = new Batch();
		for (let path in paths)
		{
			if (KindOf(path, let kind))
				Add(batch, path, kind);
		}
		return batch;
	}

	/// Starts an owner-bound preload. The batch is released automatically with the component; loaded assets
	/// remain in their shared caches. Do not delete the returned batch or use it after owner cleanup.
	public static Batch Preload(Component owner, params StringView[] paths)
	{
		Runtime.Assert(owner != null, "An owner-bound preload needs a component.");
		return owner.Own(Preload(params paths));
	}

	/// Starts loading one thing of a given kind into a batch.
	public static void Add(Batch batch, StringView path, Kind kind)
	{
		if (path.IsEmpty || path.StartsWith("builtin:"))
			return;
		let key = scope String()..AppendF("{}|{}", (int)kind, path);
		Job job;
		using (sMonitor.Enter())
		{
			if (!sJobs.TryGetValue(key, out job))
			{
				job = new Job();
				job.path.Set(path);
				job.kind = kind;
				sJobs[new String(key)] = job;
				if (AlreadyLoaded(path, kind))
				{
					job.finished = true;
					job.adopted = true;
				}
				else
					sQueue.Add(job);
			}
			job.waiting++;
		}
		batch.AddJob(job);
		StartThreads();
		sWake.Set(false);
	}

	static void Release(Job job)
	{
		using (sMonitor.Enter())
		{
			if (--job.waiting > 0 || !job.adopted)
				return;
			// Nobody is waiting and it has been handed over: the job can go.
			for (let entry in sJobs)
			{
				if (entry.value == job)
				{
					let key = entry.key;
					sJobs.Remove(key);
					delete key;
					break;
				}
			}
		}
		delete job;
	}

	static void StartThreads()
	{
#if !BF_PLATFORM_WASM
		if (sThreads.Count > 0)
			return;
		for (int i < 2)
		{
			let thread = new Thread(new => WorkerMain);
			thread.SetName("Asset loading");
			thread.Start(false);
			sThreads.Add(thread);
		}
#endif
	}

	/// The loading threads' part: read and decode, touching nothing the main thread uses.
	static void Work(Job job)
	{
		let full = scope String();
		var filePart = StringView(job.path);
		let hash = filePart.LastIndexOf('#');
		switch (job.kind)
		{
		case .Mesh:
			job.mesh = Assets.BuildModel(job.path);
		case .SkinnedModel:
			job.images = new .();
			job.model = SkinnedModel.Build(job.path, job.images);
		case .Texture:
			if (hash >= 0)
				filePart = filePart.Substring(0, hash);
			Assets.ResolvePath(filePart, full);
			// A built game's compressed copy is read as it is (no decoding), when the texture is made.
			if (hash < 0 && Textures.UseCompressed && AssetPack.Exists(scope String(full)..Append(".ktx")))
				job.compressed = true;
			else
				job.pixels = Native.tn_image_load(full.CStr(), &job.width, &job.height);
		}
	}

	static void WorkerMain()
	{
		while (true)
		{
			Job job = null;
			using (sMonitor.Enter())
			{
				if (sQuit)
					return;
				if (sQueue.Count > 0)
				{
					job = sQueue[0];
					sQueue.RemoveAt(0);
				}
			}
			if (job == null)
			{
				sWake.WaitFor(50);
				continue;
			}
			Work(job);
			using (sMonitor.Enter())
			{
				job.finished = true;
				sFinished.Add(job);
				LoadedInBackground++;
			}
		}
	}

	/// The main thread's part. The application calls it once a frame (through SceneManager.Update).
	public static void Update()
	{
		let start = SDL.SDL_GetTicksNS();
		let budget = (uint64)(Math.Max(UploadBudget, 0.5f) * 1000000);
#if BF_PLATFORM_WASM
		// No loading threads: do their part here too, within the budget.
		while (SDL.SDL_GetTicksNS() - start < budget)
		{
			Job job = null;
			using (sMonitor.Enter())
			{
				if (sQueue.Count == 0)
					break;
				job = sQueue[0];
				sQueue.RemoveAt(0);
			}
			Work(job);
			job.finished = true;
			using (sMonitor.Enter())
				sFinished.Add(job);
		}
#endif
		while (true)
		{
			Job job = null;
			using (sMonitor.Enter())
			{
				if (sFinished.Count == 0)
					break;
				job = sFinished[0];
				sFinished.RemoveAt(0);
			}
			switch (job.kind)
			{
			case .Mesh:
				if (job.mesh == null)
					Log.Warning(scope $"Mesh not found: {job.path}");
				Assets.AdoptMesh(job.path, job.mesh);
				job.mesh = null;
			case .SkinnedModel:
				if (job.model == null)
					Log.Warning(scope $"'{job.path}' has no skeleton (or could not be read).");
				SkinnedModel.Adopt(job.path, job.model, job.images);
				job.model = null;
			case .Texture:
				if (job.compressed)
					Assets.GetTexture(job.path);
				else if (job.pixels != null)
				{
					Assets.AddTexture(job.path, job.pixels, job.width, job.height);
					Native.tn_image_free(job.pixels);
					job.pixels = null;
				}
				else
					Log.Warning(scope $"Could not load texture {job.path}");
			}
			using (sMonitor.Enter())
				job.adopted = true;
			if (SDL.SDL_GetTicksNS() - start > budget)
				break;
		}
	}

	/// True while anything is still loading.
	public static bool Busy
	{
		get
		{
			using (sMonitor.Enter())
				return sQueue.Count > 0 || sFinished.Count > 0;
		}
	}

	/// Stops the loading threads (the application calls it when it closes).
	public static void Shutdown()
	{
		using (sMonitor.Enter())
			sQuit = true;
		sWake.Set(true);
		for (let thread in sThreads)
		{
			thread.Join();
			delete thread;
		}
		sThreads.Clear();
	}
}
