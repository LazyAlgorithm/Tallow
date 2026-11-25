using System;
using System.Collections;
using System.IO;
using System.Threading;
using Bgfx;

namespace Tallow;

/// GPU-driven drawing of big meshes: a mesh cut into clusters of up to 128 triangles (ClusterMesh) is kept on the graphics
/// card, and a compute shader picks, for every instance and every frame, which clusters to draw (the level of detail
/// that is as coarse as the pixel error allows, in view and not turned away). One indirect draw per bin of instances
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
	/// Bins (kinds of material) a view draws this way; renderers beyond that use the usual path.
	public const int MaxBins = 256;
	/// 32-bit words in an instance's record, a cluster's and a group's (see include/clod.sh).
	public const int InstanceWords = 40;
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

	/// Where the counters are in a pass's control buffer (include/clod.sh) and how often they are read back, in frames.
	public const int CtrlNodesLost = 1, CtrlClusters = 2, CtrlClustersLost = 3, CtrlTriangles = 4;
	public static int32 StatsInterval = 30;
	public static int64 StatsReads;

	/// Statistics of the culling, read back from the graphics card a few frames late (the last values).
	public static int64 Clusters, Triangles, ClustersLost, NodesLost;
	/// Frames in which the GPU path drew something, and draws and instances it was given (since the start).
	public static int64 FramesDrawn;
	public static int32 FrameBins, FrameInstances;

	static bgfx.ProgramHandle sSetup = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sInstances = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sClusters = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle LitProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthVelProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthAlbedoProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DepthAlbedoVelProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle ShadowProgram = .() { idx = uint16.MaxValue };
	static bgfx.IndexBufferHandle sIndices = .() { idx = uint16.MaxValue };
	static bgfx.VertexBufferHandle sNoVertices = .() { idx = uint16.MaxValue };
	public static bgfx.UniformHandle uMode, uPlanes, uCounts, uCam, uLod;
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
		LitProgram = Gfx.LoadProgram("vs_cluster", "fs_cluster");
		DepthProgram = Gfx.LoadProgram("vs_cluster_depth", "fs_depth");
		DepthVelProgram = Gfx.LoadProgram("vs_cluster_depth_vel", "fs_depth_vel");
		DepthAlbedoProgram = Gfx.LoadProgram("vs_cluster_depth_albedo", "fs_depth_albedo");
		DepthAlbedoVelProgram = Gfx.LoadProgram("vs_cluster_depth_albedo_vel", "fs_depth_albedo_vel");
		ShadowProgram = Gfx.LoadProgram("vs_cluster_shadow", "fs_shadow");
		if (!sSetup.Valid || !sInstances.Valid || !sClusters.Valid || !LitProgram.Valid || !DepthProgram.Valid || !DepthVelProgram.Valid || !DepthAlbedoProgram.Valid || !DepthAlbedoVelProgram.Valid || !ShadowProgram.Valid)
		{
			Log.Warning(scope $"GPU-driven drawing: off (the shaders did not load: setup {sSetup.Valid}, instances {sInstances.Valid}, clusters {sClusters.Valid}, lit {LitProgram.Valid}, depth {DepthProgram.Valid}, shadow {ShadowProgram.Valid})");
			return;
		}
		uMode = bgfx.create_uniform("u_clodMode", .Vec4, 1);
		uPlanes = bgfx.create_uniform("u_clodPlanes", .Vec4, 6);
		uCounts = bgfx.create_uniform("u_clodCounts", .Vec4, 1);
		uCam = bgfx.create_uniform("u_clodCam", .Vec4, 1);
		uLod = bgfx.create_uniform("u_clodLod", .Vec4, 1);
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
		bgfx.set_view_mode(CullView, .Sequential);
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
	public static bgfx.IndexBufferHandle IndexBuffer => sIndices;
	public static bgfx.VertexBufferHandle NoVertices => sNoVertices;

	// ---- the meshes' clusters

	/// A mesh's place in the pool.
	public class MeshEntry
	{
		/// The first cluster's position in the pool (in words) and how many clusters the mesh has.
		public uint32 clusterBase, clusterCount;
		public int32 triangles;
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
	/// in the pool is not reused.
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

	/// The words of every mesh's vertices, clusters and groups, in the order they were added. A copy is kept on the CPU
	/// so that the pool can be sent again when it outgrows its buffer.
	static List<uint32> sWords = new .() ~ delete _;
	static bgfx.DynamicVertexBufferHandle sPool = .() { idx = uint16.MaxValue };
	static int sPoolCapacity;
	static int sPoolSent;
	/// The most words the pool takes (512 MB).
	const int MaxPoolWords = 1 << 27;

	/// The pool's buffer on the graphics card (valid once a mesh is in it).
	public static bgfx.DynamicVertexBufferHandle Pool => sPool;
	public static int PoolWords => sWords.Count;

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
				if (job.result == null || sWords.Count + EstimatedWords(mesh, job.result) > MaxPoolWords || mesh.Vertices.Count != (int)job.result.SourceVertexCount)
				{
					mesh.GpuFailed = true;
					continue;
				}
				mesh.GpuEntry = AddToPool(mesh, job.result);
				MeshesBuilt++;
			}
		}
		if (sWords.Count > sPoolSent)
			Send();
	}

	static int EstimatedWords(Mesh mesh, ClusterMesh clusters)
	{
		return mesh.Vertices.Count * VertexWords + clusters.Vertices.Count + clusters.TriangleBytes.Count / 4 + clusters.Clusters.Count * ClusterWords + clusters.Groups.Count * GroupWords + 16;
	}

	static void Align()
	{
		while (sWords.Count % 4 != 0)
			sWords.Add(0);
	}

	/// Appends a mesh's vertices and clusters to the pool, with every offset in them turned into a position in the pool.
	static MeshEntry AddToPool(Mesh mesh, ClusterMesh clusters)
	{
		Align();
		let vertexBase = (uint32)sWords.Count;
		sWords.AddRange(Span<uint32>((uint32*)mesh.Vertices.Ptr, mesh.Vertices.Count * VertexWords));
		let refsBase = (uint32)sWords.Count;
		for (let v in clusters.Vertices)
			sWords.Add(vertexBase + v * VertexWords);
		Align();
		let trianglesBase = (uint32)sWords.Count;
		let triangleWords = (clusters.TriangleBytes.Count + 3) / 4;
		let at = sWords.Count;
		sWords.Count = at + triangleWords;
		sWords[at + triangleWords - 1] = 0;
		Internal.MemCpy(&sWords[at], clusters.TriangleBytes.CArray(), clusters.TriangleBytes.Count);
		Align();
		let clusterBase = (uint32)sWords.Count;
		let groupBase = clusterBase + (uint32)(clusters.Clusters.Count * ClusterWords);
		for (var cluster in clusters.Clusters)
		{
			cluster.vertexOffset += refsBase;
			cluster.triangleOffset += trianglesBase * 4;
			cluster.groupIndex = (int32)(groupBase + (uint32)cluster.groupIndex * GroupWords);
			cluster.refinedGroup = cluster.refinedGroup < 0 ? -1 : (int32)(groupBase + (uint32)cluster.refinedGroup * GroupWords);
			sWords.AddRange(Span<uint32>((uint32*)&cluster, ClusterWords));
		}
		for (var group in clusters.Groups)
		{
			sWords.Add(*(uint32*)&group.center.x);
			sWords.Add(*(uint32*)&group.center.y);
			sWords.Add(*(uint32*)&group.center.z);
			sWords.Add(*(uint32*)&group.radius);
		}
		Align();
		let entry = new MeshEntry();
		entry.clusterBase = clusterBase;
		entry.clusterCount = (uint32)clusters.Clusters.Count;
		entry.triangles = (int32)clusters.SourceTriangleCount;
		return entry;
	}

	/// Sends the words added since the last time (all of them, to a bigger buffer, when it was too small).
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
			sPoolSent = 0;
		}
		// Whole vec4s: the words are kept aligned to four.
		let first = sPoolSent / 4 * 4;
		let last = need / 4 * 4;
		if (last > first)
		{
			bgfx.update_dynamic_vertex_buffer(sPool, (uint32)(first / 4), bgfx.copy(&sWords[first], (uint32)((last - first) * 4)));
			sPoolSent = last;
		}
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
		sPoolSent = 0;
		sWords.Clear();
		if (sAvailable && Gfx.Initialized)
		{
			bgfx.destroy_program(sSetup);
			bgfx.destroy_program(sInstances);
			bgfx.destroy_program(sClusters);
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
