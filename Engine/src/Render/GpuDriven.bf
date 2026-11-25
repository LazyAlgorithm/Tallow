using System;
using System.Collections;
using System.IO;
using System.Threading;
using Bgfx;

namespace Tallow;

/// GPU-driven drawing of big meshes: a mesh cut into clusters of up to 128 triangles (ClusterMesh) is kept on the graphics
/// card, and a compute shader picks, for every instance and every frame, which clusters to draw (the level of detail
/// that is as coarse as the pixel error allows, in view, not turned away and not hidden behind other things: the hiding
/// is found in two phases, see GpuDrivenView.bf). One indirect draw per bin of instances
/// that share a material draws what was picked, from buffers the vertex shader reads (vs_cluster.sc). The picture matches
/// the usual path's, with the level of detail of each surface chosen per cluster.
///
/// It is on where the graphics card can do it (compute shaders, indirect draws and buffers in vertex shaders: Vulkan and
/// Metal) and the quality setting asks for it; `--gpu-driven on|off` overrides the setting. A mesh is drawn this way
/// once its clusters are built (on a worker thread, cached in <project>/.cache/clod) and its renderer qualifies
/// (GpuDrivenView.bf has the rules); until then, and for everything else, the usual path draws it.
static class GpuDriven
{
	/// The bgfx view the culling dispatches go in: after the skinning's (Compute.View) and before every camera's.
	public const uint16 CullView = 2;
	/// The views of the occlusion test (views 3 to 9 are free; every camera's start at 10): each of the two cameras that
	/// may use it (OcclusionSlots) draws its first phase's occluders in FirstDrawView + slot, then the computing of the first
	/// picture and the second phase's culling go in HzbView (shared, so it runs after every camera's first draw), the
	/// second phase's occluders are drawn in SecondDrawView + slot and the picture that the next frame starts from is
	/// computed in FinalHzbView.
	public const uint16 FirstDrawView = 3;
	public const uint16 HzbView = 5;
	public const uint16 SecondDrawView = 6;
	public const uint16 FinalHzbView = 8;
	public const int OcclusionSlots = 2;
	/// Bins (kinds of material) a view draws this way; renderers beyond that use the usual path.
	public const int MaxBins = 256;
	/// 32-bit words in an instance's record, a cluster's and a group's (see include/clod.sh).
	public const int InstanceWords = 44;
	public const int ClusterWords = 16;
	public const int GroupWords = 4;
	public const int VertexWords = 11;
	/// Triangles in a draw's index range: what a cluster has at most, times three corners.
	public const int ClusterIndices = 384;

	/// The quality setting (Quality.Apply).
	public static bool QualitySetting = true;
	/// `--gpu-driven on|off`: -1 follows the setting.
	public static int32 Override = -1;
	/// How many pixels of error a cluster may have on screen before a finer one is drawn (the quality setting).
	public static float PixelError = 1.5f;
	/// The shadow cascades are drawn this many times coarser.
	public const float ShadowErrorScale = 2.0f;
	/// Meshes with fewer triangles than this are drawn the usual way.
	public static int32 MinTriangles = 2000;
	/// Whether the clusters that face away from the camera are left out (off, to compare).
	public static bool ConeCulling = true;
	/// Whether what is hidden behind other things is left out (the camera's occlusion culling setting must be on too);
	/// `--gpu-occlusion on|off`.
	public static bool Occlusion = true;
	/// Whether the point and spot lights' shadow tiles are drawn from clusters picked for each tile (off: the usual way).
	public static bool LocalShadows = true;

	/// How often the counters are read back from the graphics card, in frames (GpuDrivenView.PollStats: the read waits for
	/// the card to finish what it has been given, so it is rare).
	public static int32 StatsInterval = 60;
	public static int64 StatsReads;

	/// Statistics of the culling, read back from the graphics card a few frames late (the last values): what the scene's
	/// passes drew (both phases of the occlusion test together), what the first phase put off for the second, and what ran
	/// over the budgets.
	public static int64 Clusters, Triangles, ClustersLost, NodesLost;
	public static int64 ClustersFirst, ClustersSecond, DeferredInstances, DeferredClusters;
	/// Frames in which the GPU path drew something, and draws and instances it was given (since the start).
	public static int64 FramesDrawn;
	public static int32 FrameBins, FrameInstances;

	static bgfx.ProgramHandle sSetup = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sInstances = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sClusters = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sStats = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sHzbCopy = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sHzbReduce = .() { idx = uint16.MaxValue };
	static bgfx.DynamicVertexBufferHandle sZeros = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle LitProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthVelProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthAlbedoProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthAlbedoVelProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle ShadowProgram = .() { idx = uint16.MaxValue };
	static bgfx.IndexBufferHandle sIndices = .() { idx = uint16.MaxValue };
	static bgfx.VertexBufferHandle sNoVertices = .() { idx = uint16.MaxValue };
	public static bgfx.UniformHandle uMode, uPlanes, uCounts, uCam, uLod, uOcc, uView, uProj, uHzb, uScreen, uHzbSize, uHzbLevel, uHzbLevel2, sDistance;
	public static bgfx.VertexLayout WordLayout;
	static bool sTried;
	static bool sAvailable;

	/// Whether this graphics card and backend can draw this way: compute shaders, indirect draws, buffers read by vertex
	/// shaders (Vulkan and Metal have them all) and the shaders for the backend.
	public static bool Available
	{
		get
		{
			if (!sTried && Gfx.Initialized)
			{
				sTried = true;
				Prepare();
			}
			return sAvailable;
		}
	}

	/// Whether meshes are drawn this way now: it can be, and the setting (or the command line) asks for it.
	public static bool Enabled => Available && (Override >= 0 ? Override == 1 : QualitySetting);

	static void Prepare()
	{
		let caps = bgfx.get_caps();
		let renderer = bgfx.get_renderer_type();
		let needed = (uint64)bgfx.CapsFlags.Compute | (uint64)bgfx.CapsFlags.DrawIndirect;
		if ((caps.supported & needed) != needed || (renderer != .Vulkan && renderer != .Metal))
		{
			Log.Info("GPU-driven drawing: off (needs compute shaders and indirect draws on Vulkan or Metal)");
			return;
		}
		let path = scope String()..AppendF("{}/shaders/{}/cs_clod_clusters.bin", Gfx.EngineAssetPath, Gfx.ShaderFolder);
		if (!AssetPack.Exists(path))
		{
			Log.Info("GPU-driven drawing: off (no culling shaders for this backend)");
			return;
		}
		sSetup = LoadCompute("cs_clod_setup");
		sInstances = LoadCompute("cs_clod_instances");
		sClusters = LoadCompute("cs_clod_clusters");
		sStats = LoadCompute("cs_clod_stats");
		sHzbCopy = LoadCompute("cs_hzb_copy");
		sHzbReduce = LoadCompute("cs_hzb_reduce");
		LitProgram = Gfx.LoadProgram("vs_cluster", "fs_cluster");
		DepthProgram = Gfx.LoadProgram("vs_cluster_depth", "fs_depth");
		DepthVelProgram = Gfx.LoadProgram("vs_cluster_depth_vel", "fs_depth_vel");
		DepthAlbedoProgram = Gfx.LoadProgram("vs_cluster_depth_albedo", "fs_depth_albedo");
		DepthAlbedoVelProgram = Gfx.LoadProgram("vs_cluster_depth_albedo_vel", "fs_depth_albedo_vel");
		ShadowProgram = Gfx.LoadProgram("vs_cluster_shadow", "fs_shadow");
		if (!sSetup.Valid || !sInstances.Valid || !sClusters.Valid || !sStats.Valid || !sHzbCopy.Valid || !sHzbReduce.Valid || !LitProgram.Valid || !DepthProgram.Valid || !DepthVelProgram.Valid || !DepthAlbedoProgram.Valid || !DepthAlbedoVelProgram.Valid || !ShadowProgram.Valid)
		{
			Log.Warning(scope $"GPU-driven drawing: off (the shaders did not load: setup {sSetup.Valid}, instances {sInstances.Valid}, clusters {sClusters.Valid}, lit {LitProgram.Valid}, depth {DepthProgram.Valid}, shadow {ShadowProgram.Valid})");
			return;
		}
		uMode = bgfx.create_uniform("u_clodMode", .Vec4, 1);
		uPlanes = bgfx.create_uniform("u_clodPlanes", .Vec4, 6);
		uCounts = bgfx.create_uniform("u_clodCounts", .Vec4, 1);
		uCam = bgfx.create_uniform("u_clodCam", .Vec4, 1);
		uLod = bgfx.create_uniform("u_clodLod", .Vec4, 1);
		uOcc = bgfx.create_uniform("u_clodOcc", .Vec4, 1);
		uView = bgfx.create_uniform("u_clodView", .Mat4, 1);
		uProj = bgfx.create_uniform("u_clodProj", .Mat4, 1);
		uHzb = bgfx.create_uniform("u_clodHzb", .Vec4, 1);
		uScreen = bgfx.create_uniform("u_clodScreen", .Vec4, 1);
		uHzbSize = bgfx.create_uniform("u_hzbSize", .Vec4, 1);
		uHzbLevel = bgfx.create_uniform("u_hzbLevel", .Vec4, 1);
		uHzbLevel2 = bgfx.create_uniform("u_hzbLevel2", .Vec4, 1);
		sDistance = bgfx.create_uniform("s_distance", .Sampler, 1);
		bgfx.vertex_layout_begin(&WordLayout, .Noop);
		bgfx.vertex_layout_add(&WordLayout, .TexCoord0, 4, .Float, false, false);
		bgfx.vertex_layout_end(&WordLayout);
		// What a draw needs for its index range: the corner numbers, which the vertex shader turns into triangles.
		// Bin b's draw starts at index b * 384, so the vertex shader finds the bin in the numbers it is given: a uniform
		// per draw did not reach every draw reliably.
		let corners = new uint32[MaxBins * ClusterIndices];
		defer delete corners;
		for (int i < corners.Count)
			corners[i] = (uint32)i;
		sIndices = bgfx.create_index_buffer(bgfx.copy(corners.CArray(), (uint32)(corners.Count * 4)), 0x1000);
		// bgfx skips a draw that has no vertex stream, though the vertex shader reads none: one vertex stands in.
		float[4] nothing = default;
		sNoVertices = bgfx.create_vertex_buffer(bgfx.copy(&nothing, 16), &WordLayout, 0);
		// What the occlusion test reads where there is no picture yet, and what a pass that was not culled counts.
		uint32[16] zeros = default;
		sZeros = bgfx.create_dynamic_vertex_buffer(4, &WordLayout, (uint16)bgfx.BufferFlags.ComputeRead);
		bgfx.update_dynamic_vertex_buffer(sZeros, 0, bgfx.copy(&zeros, 64));
		bgfx.set_view_mode(CullView, .Sequential);
		bgfx.set_view_mode(HzbView, .Sequential);
		bgfx.set_view_mode(FinalHzbView, .Sequential);
		sAvailable = true;
		Log.Info(scope $"GPU-driven drawing: available ({renderer}), {(Enabled ? "on" : "off")}");
	}

	static bgfx.ProgramHandle LoadCompute(StringView name)
	{
		let path = scope String()..AppendF("{}/shaders/{}/{}.bin", Gfx.EngineAssetPath, Gfx.ShaderFolder, name);
		let shader = Gfx.LoadShaderFile(path);
		if (!shader.Valid)
			return .() { idx = uint16.MaxValue };
		return bgfx.create_compute_program(shader, true);
	}

	public static bgfx.ProgramHandle SetupProgram => sSetup;
	public static bgfx.ProgramHandle InstanceProgram => sInstances;
	public static bgfx.ProgramHandle ClusterProgram => sClusters;
	public static bgfx.ProgramHandle StatsProgram => sStats;
	public static bgfx.ProgramHandle HzbCopyProgram => sHzbCopy;
	public static bgfx.ProgramHandle HzbReduceProgram => sHzbReduce;
	/// A small buffer of zeros.
	public static bgfx.DynamicVertexBufferHandle Zeros => sZeros;
	public static bgfx.IndexBufferHandle IndexBuffer => sIndices;
	public static bgfx.VertexBufferHandle NoVertices => sNoVertices;

	// ---- the meshes' clusters

	/// A mesh's place in the pool.
	public class MeshEntry
	{
		/// The first cluster's position in the pool (in words) and how many clusters the mesh has.
		public uint32 clusterBase, clusterCount;
		public int32 triangles;
		/// Where the mesh's whole stretch of the pool starts and how long it is (in words), for giving it back.
		public int32 poolStart, poolWords;
	}

	class BuildJob
	{
		public int64 id;
		public Mesh copy ~ delete _;
		public String cachePath = new .() ~ delete _;
		public ClusterMesh result ~ delete _;
	}

	static Monitor sLock = new .() ~ delete _;
	static WaitEvent sWake = new .() ~ delete _;
	static List<BuildJob> sQueue = new .() ~ DeleteContainerAndItems!(_);
	static List<BuildJob> sFinished = new .() ~ DeleteContainerAndItems!(_);
	static Dictionary<int64, Mesh> sPending = new .() ~ delete _;
	static Thread sThread;
	static bool sQuit;
	static int64 sNextJob = 1;
	/// Meshes whose clusters were built and put in the pool, and how long the worker spent on them (milliseconds).
	public static int32 MeshesBuilt;
	public static int64 BuildMilliseconds;

	/// The mesh's clusters when they are in the pool; otherwise null, having started building them (on a worker thread,
	/// not stalling the frame) when the mesh is big enough and has its vertices on the CPU.
	public static MeshEntry Lookup(Mesh mesh)
	{
		if (mesh.GpuEntry != null)
			return mesh.GpuEntry;
		if (mesh.GpuJob != 0 || mesh.GpuFailed)
			return null;
		if (mesh.Indices.Count / 3 < MinTriangles || mesh.Vertices.Count == 0 || mesh.VertexSource != null || mesh.IsDynamic)
			return null;
		let job = new BuildJob();
		job.copy = new Mesh();
		job.copy.Vertices.AddRange(mesh.Vertices);
		job.copy.Indices.AddRange(mesh.Indices);
		if (!mesh.Name.IsEmpty)
		{
			let name = scope String();
			for (let c in mesh.Name.RawChars)
				name.Append((c.IsLetterOrDigit || c == '.' || c == '-' || c == '_') ? c : '_');
			let cache = scope String();
			ClusterMesh.CachePath(scope $"{name}.{mesh.Indices.Count / 3}", cache);
			job.cachePath.Set(cache);
		}
		using (sLock.Enter())
		{
			job.id = sNextJob++;
			mesh.GpuJob = job.id;
			sPending[job.id] = mesh;
			sQueue.Add(job);
			if (sThread == null)
			{
				sThread = new Thread(new => BuildMain);
				sThread.SetName("Cluster LOD");
				sThread.Start(false);
			}
		}
		sWake.Set(false);
		return null;
	}

	/// Forgets a mesh's clusters (it was deleted, or its vertices were sent to the graphics card again). The room it had
	/// in the pool is given back (and used again for another mesh a few frames later, when no frame in flight reads it).
	public static void Forget(Mesh mesh)
	{
		if (mesh.GpuEntry == null && mesh.GpuJob == 0 && !mesh.GpuFailed)
			return;
		using (sLock.Enter())
		{
			if (mesh.GpuJob != 0)
				sPending.Remove(mesh.GpuJob);
			mesh.GpuJob = 0;
		}
		if (mesh.GpuEntry != null)
			Free(mesh.GpuEntry.poolStart, mesh.GpuEntry.poolWords);
		DeleteAndNullify!(mesh.GpuEntry);
		mesh.GpuFailed = false;
	}

	static void BuildMain()
	{
		Profiler.NameThread("Cluster LOD");
		while (true)
		{
			BuildJob job = null;
			using (sLock.Enter())
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
				sWake.WaitFor(100);
				continue;
			}
			let start = Internal.GetTickCountMicro();
			job.result = ClusterMesh.BuildCached(job.copy, job.cachePath);
			delete job.copy;
			job.copy = null;
			using (sLock.Enter())
			{
				BuildMilliseconds += (Internal.GetTickCountMicro() - (int64)start) / 1000;
				sFinished.Add(job);
			}
		}
	}

	/// The words of every mesh's vertices, clusters and groups, each mesh's stretch of its own. A copy is kept on the CPU
	/// so that the pool can be sent again when it outgrows its buffer.
	static List<uint32> sWords = new .() ~ delete _;
	static bgfx.DynamicVertexBufferHandle sPool = .() { idx = uint16.MaxValue };
	static int sPoolCapacity;
	/// The stretches of the pool written since they were sent to the graphics card, as (first word, end).
	static List<(int first, int end)> sDirty = new .() ~ delete _;
	/// The most words the pool takes (512 MB).
	const int MaxPoolWords = 1 << 27;

	/// A stretch of the pool nobody uses. It is only given out again a few frames after it was freed: frames the card is
	/// still drawing may read it.
	struct FreeStretch
	{
		public int start, words;
		public int64 frame;
	}
	static List<FreeStretch> sFree = new .() ~ delete _;
	const int FramesBeforeReuse = 4;
	/// Words in stretches given back (counted in the pool's size) and stretches reused since the start.
	public static int FreeWords;
	public static int32 StretchesReused;

	/// The pool's buffer on the graphics card (valid once a mesh is in it).
	public static bgfx.DynamicVertexBufferHandle Pool => sPool;
	/// The pool's size in words, and the part of it in use.
	public static int PoolWords => sWords.Count;
	public static int PoolWordsInUse => sWords.Count - FreeWords;

	/// Takes the finished builds into the pool and sends what is new to the graphics card. Once a frame, on the main thread.
	public static void Update()
	{
		if (sFinished.Count > 0)
		{
			List<BuildJob> done = scope .();
			using (sLock.Enter())
			{
				done.AddRange(sFinished);
				sFinished.Clear();
			}
			for (let job in done)
			{
				defer delete job;
				Mesh mesh = null;
				using (sLock.Enter())
				{
					if (sPending.TryGetValue(job.id, out mesh))
						sPending.Remove(job.id);
				}
				if (mesh == null)
					continue;
				mesh.GpuJob = 0;
				if (job.result == null || mesh.Vertices.Count != (int)job.result.SourceVertexCount)
				{
					mesh.GpuFailed = true;
					continue;
				}
				let entry = AddToPool(mesh, job.result);
				if (entry == null)
				{
					mesh.GpuFailed = true;
					continue;
				}
				mesh.GpuEntry = entry;
				MeshesBuilt++;
			}
		}
		if (sDirty.Count > 0 || sWords.Count > sPoolCapacity)
			Send();
	}

	/// The words a mesh takes in the pool: its vertices, the cluster's vertex numbers, triangle bytes, clusters and groups,
	/// each part padded to whole vec4s.
	static int WordsFor(Mesh mesh, ClusterMesh clusters)
	{
		return Pad4(mesh.Vertices.Count * VertexWords) + Pad4(clusters.Vertices.Count) + Pad4((clusters.TriangleBytes.Count + 3) / 4)
			+ clusters.Clusters.Count * ClusterWords + clusters.Groups.Count * GroupWords;
	}

	static int Pad4(int words) => (words + 3) / 4 * 4;

	/// Finds `words` words of room: a stretch given back long enough ago, or the end of the pool. -1: no room.
	static int Allocate(int words)
	{
		let now = Time.FrameCount;
		var best = -1;
		for (int i < sFree.Count)
		{
			let free = sFree[i];
			if (free.words >= words && now - free.frame >= FramesBeforeReuse && (best < 0 || free.words < sFree[best].words))
				best = i;
		}
		if (best >= 0)
		{
			let free = sFree[best];
			if (free.words == words)
				sFree.RemoveAt(best);
			else
			{
				sFree[best].start += words;
				sFree[best].words -= words;
			}
			FreeWords -= words;
			StretchesReused++;
			return free.start;
		}
		if (sWords.Count + words > MaxPoolWords)
			return -1;
		let at = sWords.Count;
		sWords.Count = at + words;
		return at;
	}

	/// Gives a stretch back, joining it to the free ones next to it. A stretch at the end of the pool shortens the pool.
	static void Free(int start, int words)
	{
		if (words <= 0)
			return;
		FreeWords += words;
		FreeStretch stretch = .() { start = start, words = words, frame = Time.FrameCount };
		var i = 0;
		while (i < sFree.Count)
		{
			let other = sFree[i];
			if (other.start + other.words == stretch.start || stretch.start + stretch.words == other.start)
			{
				stretch.start = Math.Min(stretch.start, other.start);
				stretch.words += other.words;
				stretch.frame = Math.Max(stretch.frame, other.frame);
				sFree.RemoveAt(i);
				i = 0;
				continue;
			}
			i++;
		}
		sFree.Add(stretch);
	}

	/// Puts a mesh's vertices and clusters in the pool, with every offset in them turned into a position in the pool.
	/// Null when there is no room.
	static MeshEntry AddToPool(Mesh mesh, ClusterMesh clusters)
	{
		let total = WordsFor(mesh, clusters);
		let start = Allocate(total);
		if (start < 0)
			return null;
		let words = sWords.Ptr + start;
		var at = 0;
		let vertexBase = (uint32)(start + at);
		Internal.MemCpy(words + at, mesh.Vertices.Ptr, mesh.Vertices.Count * VertexWords * 4);
		at += Pad4(mesh.Vertices.Count * VertexWords);
		let refsBase = (uint32)(start + at);
		for (let v in clusters.Vertices)
			words[at++] = vertexBase + v * VertexWords;
		at = Pad4(at);
		let trianglesBase = (uint32)(start + at);
		let triangleWords = (clusters.TriangleBytes.Count + 3) / 4;
		words[at + triangleWords - 1] = 0;
		Internal.MemCpy(words + at, clusters.TriangleBytes.CArray(), clusters.TriangleBytes.Count);
		at += triangleWords;
		at = Pad4(at);
		let clusterBase = (uint32)(start + at);
		let groupBase = clusterBase + (uint32)(clusters.Clusters.Count * ClusterWords);
		for (var cluster in clusters.Clusters)
		{
			cluster.vertexOffset += refsBase;
			cluster.triangleOffset += trianglesBase * 4;
			cluster.groupIndex = (int32)(groupBase + (uint32)cluster.groupIndex * GroupWords);
			cluster.refinedGroup = cluster.refinedGroup < 0 ? -1 : (int32)(groupBase + (uint32)cluster.refinedGroup * GroupWords);
			Internal.MemCpy(words + at, &cluster, ClusterWords * 4);
			at += ClusterWords;
		}
		for (var group in clusters.Groups)
		{
			words[at++] = *(uint32*)&group.center.x;
			words[at++] = *(uint32*)&group.center.y;
			words[at++] = *(uint32*)&group.center.z;
			words[at++] = *(uint32*)&group.radius;
		}
		Runtime.Assert(at == total);
		MarkDirty(start, start + total);
		let entry = new MeshEntry();
		entry.clusterBase = clusterBase;
		entry.clusterCount = (uint32)clusters.Clusters.Count;
		entry.triangles = (int32)clusters.SourceTriangleCount;
		entry.poolStart = (int32)start;
		entry.poolWords = (int32)total;
		return entry;
	}

	static void MarkDirty(int firstWord, int endWord)
	{
		var first = firstWord;
		var end = endWord;
		for (var i = 0; i < sDirty.Count; i++)
		{
			if (first <= sDirty[i].end && end >= sDirty[i].first)
			{
				first = Math.Min(first, sDirty[i].first);
				end = Math.Max(end, sDirty[i].end);
				sDirty.RemoveAt(i);
				i = -1;
			}
		}
		sDirty.Add((first, end));
	}

	/// Sends what is new to the graphics card (all of it, to a bigger buffer, when the pool outgrew its buffer).
	static void Send()
	{
		let need = sWords.Count;
		if (need > sPoolCapacity)
		{
			if (sPool.Valid)
				bgfx.destroy_dynamic_vertex_buffer(sPool);
			var capacity = Math.Max(sPoolCapacity * 2, 1 << 20);
			while (capacity < need)
				capacity *= 2;
			sPool = bgfx.create_dynamic_vertex_buffer((uint32)(capacity / 4), &WordLayout, (uint16)bgfx.BufferFlags.ComputeRead);
			sPoolCapacity = capacity;
			sDirty.Clear();
			sDirty.Add((0, need));
		}
		// Whole vec4s: the stretches are padded to four.
		for (let dirty in sDirty)
		{
			let first = dirty.first / 4 * 4;
			let last = Math.Min(Pad4(dirty.end), need);
			if (last > first)
				bgfx.update_dynamic_vertex_buffer(sPool, (uint32)(first / 4), bgfx.copy(&sWords[first], (uint32)((last - first) * 4)));
		}
		sDirty.Clear();
	}

	/// Whether a whole build is still waiting or running (for tests that wait for the meshes).
	public static int PendingBuilds
	{
		get
		{
			using (sLock.Enter())
				return sPending.Count;
		}
	}

	public static void Shutdown()
	{
		if (sThread != null)
		{
			using (sLock.Enter())
				sQuit = true;
			sWake.Set(true);
			sThread.Join();
			DeleteAndNullify!(sThread);
			sQuit = false;
		}
		if (sPool.Valid && Gfx.Initialized)
			bgfx.destroy_dynamic_vertex_buffer(sPool);
		sPool.idx = uint16.MaxValue;
		sPoolCapacity = 0;
		sDirty.Clear();
		sFree.Clear();
		FreeWords = 0;
		sWords.Clear();
		if (sAvailable && Gfx.Initialized)
		{
			bgfx.destroy_program(sSetup);
			bgfx.destroy_program(sInstances);
			bgfx.destroy_program(sClusters);
			bgfx.destroy_program(sStats);
			bgfx.destroy_program(sHzbCopy);
			bgfx.destroy_program(sHzbReduce);
			bgfx.destroy_dynamic_vertex_buffer(sZeros);
			bgfx.destroy_program(LitProgram);
			bgfx.destroy_program(DepthProgram);
			bgfx.destroy_program(DepthVelProgram);
			bgfx.destroy_program(DepthAlbedoProgram);
			bgfx.destroy_program(DepthAlbedoVelProgram);
			bgfx.destroy_program(ShadowProgram);
			bgfx.destroy_index_buffer(sIndices);
			bgfx.destroy_vertex_buffer(sNoVertices);
		}
		sAvailable = false;
		sTried = false;
	}
}
