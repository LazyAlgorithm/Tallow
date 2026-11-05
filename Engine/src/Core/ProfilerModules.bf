using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

/// The Profiler's modules (docs/profiler.md): counters for each part of the engine, set at the end of every recorded
/// frame from what the systems already know, and the GPU's times read from bgfx.
static class ProfilerModules
{
	// Rendering.
	static ProfilerCounter sDraws = .("Draw Calls", .Rendering);
	static ProfilerCounter sInstances = .("Instances", .Rendering);
	static ProfilerCounter sTriangles = .("Triangles", .Rendering);
	static ProfilerCounter sVisible = .("Visible Renderers", .Rendering);
	static ProfilerCounter sViews = .("Camera Views Drawn", .Rendering);
	static ProfilerCounter sShadowTiles = .("Shadowed Lights", .Rendering);
	static ProfilerCounter sGpuDraws = .("GPU Draws (all passes)", .Rendering);
	static ProfilerCounter sGpuComputes = .("GPU Compute Dispatches", .Rendering);
	static ProfilerCounter sGpuBlits = .("GPU Copies", .Rendering);
	static ProfilerCounter sGpuPrimitives = .("GPU Primitives (all passes)", .Rendering);
	static ProfilerCounter sGpuTime = .("GPU Frame", .Rendering, "ms");
	static ProfilerCounter sPasses = .("Render Passes", .Rendering);
	// Memory.
	static ProfilerCounter sProcess = .("Process Memory", .Memory, "bytes");
	static ProfilerCounter sTextureMemory = .("Texture Memory (GPU)", .Memory, "bytes");
	static ProfilerCounter sTargetMemory = .("Render Target Memory (GPU)", .Memory, "bytes");
	static ProfilerCounter sGpuMemory = .("GPU Memory Used", .Memory, "bytes");
	static ProfilerCounter sEngineTextures = .("Engine Textures", .Memory, "bytes");
	static ProfilerCounter sMeshMemory = .("Mesh Memory (CPU copies)", .Memory, "bytes");
	static ProfilerCounter sTextureCount = .("Textures", .Memory);
	static ProfilerCounter sMeshCount = .("Meshes", .Memory);
	// Physics.
	static ProfilerCounter sBodies = .("Bodies", .Physics);
	static ProfilerCounter sJoints = .("Joints", .Physics);
	// Animation.
	static ProfilerCounter sAnimators = .("Animators", .Animation);
	static ProfilerCounter sSkinned = .("Skinned Mesh Renderers", .Animation);
	// Audio.
	static ProfilerCounter sSources = .("Playing Audio Sources", .Audio);
	static ProfilerCounter sOneShots = .("One-Shot Sounds", .Audio);
	// Networking.
	static ProfilerCounter sSent = .("Sent", .Networking, "bytes/s");
	static ProfilerCounter sReceived = .("Received", .Networking, "bytes/s");
	static ProfilerCounter sRollbacks = .("Rollbacks", .Networking);
	static ProfilerCounter sPhysicsRollbacks = .("Physics Rollbacks", .Networking);
	static ProfilerCounter sPredicted = .("Predicted Bodies", .Networking);
	static ProfilerCounter sPendingInputs = .("Inputs Not Yet Used", .Networking);
	static ProfilerCounter sCorrection = .("Last Correction", .Networking, "m");
	// AI.
	static ProfilerCounter sAgents = .("Navigation Agents", .AI);
	static ProfilerCounter sTrees = .("Behaviour Trees", .AI);
	public static ProfilerCounter Paths = .("Paths Found", .AI);
	public static ProfilerCounter PathVisits = .("Path Search Visits", .AI);
	// UI.
	static ProfilerCounter sDocuments = .("UI Documents", .UI);
	// Particles.
	static ProfilerCounter sSystems = .("Particle Systems", .Particles);
	static ProfilerCounter sParticles = .("Particles", .Particles);
	// Assets.
	static ProfilerCounter sLoaded = .("Loaded in the Background", .Assets);
	static ProfilerCounter sLoading = .("Loader Busy", .Assets);
	// Scripts.
	static ProfilerCounter sObjects = .("Game Objects", .Scripts);
	static ProfilerCounter sComponents = .("Components", .Scripts);
	// Jobs.
	static ProfilerCounter sThreads = .("Job Threads", .Jobs);

	static bool sInstalled;
	static bool sGpuProfiling;
	static int32 sLastLoaded;
	static Dictionary<String, int32> sPassIds = new .() ~ DeleteDictionaryAndKeys!(_);

	/// Adds the modules' collector to the Profiler (once; Application.Run does it).
	public static void Install()
	{
		if (sInstalled)
			return;
		sInstalled = true;
		Profiler.Collectors.Add( => Collect);
	}

	/// The process's resident memory in bytes, or -1 where it cannot be read.
	public static int64 ProcessMemory()
	{
#if BF_PLATFORM_LINUX
		let text = scope String();
		if (File.ReadAllText("/proc/self/statm", text) case .Err)
			return -1;
		var parts = text.Split(' ');
		parts.GetNext();
		if (parts.GetNext() case .Ok(let resident) && int64.Parse(resident) case .Ok(let pages))
			return pages * 4096;
		return -1;
		#elif BF_PLATFORM_WINDOWS
		ProcessMemoryCounters counters = default;
		counters.size = sizeof(ProcessMemoryCounters);
		if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof(ProcessMemoryCounters)) != 0)
			return (int64)counters.workingSetSize;
		return -1;
	#else
		return -1;
#endif
	}

#if BF_PLATFORM_WINDOWS
	[CRepr]
	struct ProcessMemoryCounters
	{
		public uint32 size;
		public uint32 pageFaults;
		public uint peakWorkingSetSize, workingSetSize, quotaPeakPagedPool, quotaPagedPool, quotaPeakNonPaged, quotaNonPaged, pagefile, peakPagefile;
	}

	[CLink, CallingConvention(.Stdcall)]
	static extern int32 K32GetProcessMemoryInfo(void* process, ProcessMemoryCounters* counters, uint32 size);
	[CLink, CallingConvention(.Stdcall)]
	static extern void* GetCurrentProcess();
#endif

	/// The bytes a mesh's CPU copy takes.
	public static int64 MeshBytes(Mesh mesh) => (int64)mesh.Vertices.Count * sizeof(MeshVertex) + (int64)mesh.Indices.Count * 4;

	static void Collect()
	{
		sDraws.Set(RenderView.FrameDrawCalls);
		sInstances.Set(RenderView.FrameInstances);
		sTriangles.Set(RenderView.FrameTriangles);
		sVisible.Set(RenderView.FrameVisible);
		sViews.Set(RenderView.FrameViews);
		sShadowTiles.Set(RenderView.FrameShadowTiles);
		RenderView.FrameDrawCalls = RenderView.FrameInstances = RenderView.FrameTriangles = 0;
		RenderView.FrameVisible = RenderView.FrameViews = RenderView.FrameShadowTiles = 0;

		sProcess.Set(ProcessMemory());
		sEngineTextures.Set(Textures.Bytes);
		sTextureCount.Set(Assets.TextureCount);
		sMeshCount.Set(Assets.MeshCount);
		int64 meshBytes = 0;
		Assets.ForEachMesh(scope [&] (path, mesh) =>
			{
				meshBytes += MeshBytes(mesh);
			}
			);
		sMeshMemory.Set(meshBytes);

		let loaded = AssetLoader.LoadedInBackground;
		sLoaded.Set(Math.Max(loaded - sLastLoaded, 0));
		sLastLoaded = loaded;
		sLoading.Set(AssetLoader.Busy ? 1 : 0);
		sThreads.Set(Jobs.ThreadCount);
		sOneShots.Set(Audio.ActiveOneShots);

		let scene = Scene.Active;
		if (scene == null)
			return;
		if (scene.Physics != null)
		{
			sBodies.Set(scene.Physics.BodyCount);
			sJoints.Set(scene.Physics.JointCount);
		}
		if (let network = scene.Network)
		{
			sSent.Set(network.BytesSentPerSecond);
			sReceived.Set(network.BytesReceivedPerSecond);
			sRollbacks.Set(network.Rollbacks);
			sPhysicsRollbacks.Set(network.PhysicsRollbacks);
			sPredicted.Set(network.PredictedBodies);
			sPendingInputs.Set(network.PendingInputs);
			sCorrection.Set(network.LastCorrection);
		}
		// One look over the scene's components for the counts by kind.
		int32 animators = 0, skinned = 0, sources = 0, agents = 0, trees = 0, documents = 0, systems = 0, particles = 0;
		animators = (int32)scene.Components<Animator>(.. scope .()).Count;
		agents = (int32)scene.Components<NavigationAgent>(.. scope .()).Count;
		for (let component in scene.Components)
		{
			if (component is BehaviorTreeRunner)
				trees++;
			else if (component is UIDocument)
				documents++;
		}
		for (let system in scene.Particles)
		{
			systems++;
			particles += system.AliveCount;
		}
		sAnimators.Set(animators);
		skinned = (int32)scene.Components<SkinnedMeshRenderer>(.. scope .()).Count;
		sSkinned.Set(skinned);
		for (let source in scene.Components<AudioSource>(.. scope .()))
		{
			if (source.IsPlaying)
				sources++;
		}
		sSources.Set(sources);
		sAgents.Set(agents);
		sTrees.Set(trees);
		sDocuments.Set(documents);
		sSystems.Set(systems);
		sParticles.Set(particles);
		sComponents.Set(scene.Components.Count);
		sObjects.Set(scene.Objects.Count);
	}

	/// After bgfx.frame: turns bgfx's own timing on while recording, sets the GPU and memory counters from its latest
	/// finished frame, records each pass's GPU time, and returns the GPU frame time in nanoseconds (0 without them).
	public static int64 ReadGpu()
	{
		if (!Gfx.Initialized)
			return 0;
		if (Profiler.Enabled != sGpuProfiling)
		{
			sGpuProfiling = Profiler.Enabled;
			bgfx.FrameBufferHandle window = .() { idx = uint16.MaxValue };
			bgfx.set_debug(sGpuProfiling ? (uint32)bgfx.DebugFlags.Profiler : 0, window, 0);
		}
		if (!Profiler.Enabled)
			return 0;
		let stats = bgfx.get_stats();
		if (stats == null)
			return 0;
		sGpuDraws.Set(stats.numDraw);
		sGpuComputes.Set(stats.numCompute);
		sGpuBlits.Set(stats.numBlit);
		double primitives = 0;
		for (let count in stats.numPrims)
			primitives += count;
		sGpuPrimitives.Set(primitives);
		sTextureMemory.Set(stats.textureMemoryUsed);
		sTargetMemory.Set(stats.rtMemoryUsed);
		if (stats.gpuMemoryUsed > 0)
			sGpuMemory.Set(stats.gpuMemoryUsed);
		int64 gpu = 0;
		if (stats.gpuTimerFreq > 0 && stats.gpuTimeEnd > stats.gpuTimeBegin)
		{
			gpu = (int64)((double)(stats.gpuTimeEnd - stats.gpuTimeBegin) * 1.0e9 / stats.gpuTimerFreq);
			sGpuTime.Set(gpu / 1.0e6);
		}
		if (stats.viewStats != null && stats.gpuTimerFreq > 0)
		{
			int32 passes = 0;
			let name = scope String();
			for (int i < stats.numViews)
			{
				var view = ref stats.viewStats[i];
				let time = view.gpuTimeEnd - view.gpuTimeBegin;
				if (time <= 0)
					continue;
				name.Clear();
				name.Append(&view.name[0]);
				if (name.IsEmpty)
					name.AppendF("View {}", view.view);
				int32 id;
				if (!sPassIds.TryGetValue(name, out id))
				{
					id = Profiler.Pass(name);
					sPassIds[new String(name)] = id;
				}
				Profiler.AddPass(id, (int64)((double)time * 1.0e9 / stats.gpuTimerFreq));
				passes++;
			}
			sPasses.Set(passes);
		}
		return gpu;
	}
}

/// A memory snapshot (docs/profiler.md): every texture and mesh the engine holds, by name and size, and the totals
/// bgfx and the system give, taken to compare one moment with another.
public class ProfilerMemorySnapshot
{
	public struct Entry
	{
		public String kind;
		public String name;
		public int64 bytes;
	}

	public String label = new .() ~ delete _;
	public int64 frame;
	public List<Entry> entries = new .() ~
		{
			for (let entry in _)
			{
				delete entry.kind;
				delete entry.name;
			}
			delete _;
		};

	public void Add(StringView kind, StringView name, int64 bytes)
	{
		entries.Add(.() { kind = new .(kind), name = new .(name), bytes = bytes });
	}

	public int64 Total(StringView kind = "")
	{
		int64 total = 0;
		for (let entry in entries)
		{
			if (kind.IsEmpty || entry.kind == kind)
				total += entry.bytes;
		}
		return total;
	}

	/// Takes one now.
	public static ProfilerMemorySnapshot Take(StringView label)
	{
		let snapshot = new ProfilerMemorySnapshot();
		snapshot.label.Set(label);
		snapshot.frame = Time.FrameCount;
		Assets.ForEachTexture(scope [&] (path, handle) =>
			{
				if (Textures.Sizes.TryGetValue(handle, let bytes))
					snapshot.Add("Texture", path, bytes);
			});
		Assets.ForEachMesh(scope [&] (path, mesh) =>
			{
				snapshot.Add("Mesh", path, ProfilerModules.MeshBytes(mesh));
			}
			);
		let process = ProfilerModules.ProcessMemory();
		if (process >= 0)
			snapshot.Add("Totals", "Process memory (resident)", process);
		if (Gfx.Initialized)
		{
			if (let stats = bgfx.get_stats())
			{
				snapshot.Add("Totals", "Textures on the GPU (bgfx)", stats.textureMemoryUsed);
				snapshot.Add("Totals", "Render targets on the GPU (bgfx)", stats.rtMemoryUsed);
			}
		}
		snapshot.entries.Sort(scope (a, b) => a.bytes != b.bytes ? b.bytes <=> a.bytes : a.name.CompareTo(b.name));
		return snapshot;
	}

	/// What changed from `before` to this one: each name's size here minus there (new ones in full, gone ones
	/// negative), largest changes first.
	public void Compare(ProfilerMemorySnapshot before, List<(String kind, String name, int64 change)> changes)
	{
		changes.Clear();
		let old = scope Dictionary<String, int64>();
		let keys = scope List<String>();
		defer
		{
			ClearAndDeleteItems!(keys);
		}
		for (let entry in before.entries)
		{
			let key = new String()..AppendF("{}\n{}", entry.kind, entry.name);
			keys.Add(key);
			old[key] = entry.bytes;
		}
		let key = scope String();
		for (let entry in entries)
		{
			key.Clear();
			key.AppendF("{}\n{}", entry.kind, entry.name);
			var was = 0L;
			if (old.TryGetValue(key, out was))
				old.Remove(key);
			if (entry.bytes != was)
				changes.Add((entry.kind, entry.name, entry.bytes - was));
		}
		for (let (gone, bytes) in old)
		{
			let split = gone.IndexOf('\n');
			for (let entry in before.entries)
			{
				if (entry.kind == gone.Substring(0, split) && entry.name == gone.Substring(split + 1))
				{
					changes.Add((entry.kind, entry.name, -bytes));
					break;
				}
			}
		}
		changes.Sort(scope (a, b) => Math.Abs(b.change) <=> Math.Abs(a.change));
	}
}
