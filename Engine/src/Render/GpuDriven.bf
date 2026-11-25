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
	/// What the GPU-driven draw shows in place of the lit picture (`--gpu-debug-view <name>`, the viewport's menu).
	public enum DebugView : int32
	{
		/// The normal picture.
		Off,
		/// A colour per cluster.
		Clusters,
		/// A colour per level of the hierarchy (blue: the mesh's own triangles, red: the coarsest).
		LodLevel,
		/// A colour per triangle, so the density of the triangles shows.
		Triangles,
		/// One level of the occlusion pyramid (DebugMip), over the whole screen.
		Hzb,
		/// Green: clusters at the detail they ask for; orange: clusters whose finer group is not in memory yet (virtual geometry).
		Residency,
		/// The mip level of the virtual texture each pixel shows: green is the level it needs, orange to red a coarser one.
		VtPages
	}

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
	public const int GroupWords = 8;
	public const int VertexWords = 11;
	/// Triangles in a draw's index range: what a cluster has at most, times three corners.
	public const int ClusterIndices = 384;

	/// The quality setting (Quality.Apply).
	public static bool QualitySetting = true;
	/// `--gpu-driven on|off`: -1 follows the setting.
	public static int32 Override = -1;
	/// How many pixels of error a cluster may have on screen before a finer one is drawn (the quality setting).
	public static float PixelError = 1.0f;
	/// `--gpu-pixel-error` was given: the quality preset must not overwrite it.
	public static bool PixelErrorFromArgs;
	/// The shadow cascades are drawn this many times coarser.
	public const float ShadowErrorScale = 2.0f;
	/// Meshes with fewer triangles than this are drawn the usual way.
	public static int32 MinTriangles = 2000;
	/// Whether the clusters that face away from the camera are left out (off, to compare).
	public static bool ConeCulling = true;
	/// Whether what is hidden behind other things is left out (the camera's occlusion culling setting must be on too);
	/// `--gpu-occlusion on|off`.
	public static bool Occlusion = true;
	/// `--gpu-occlusion` was given: the quality preset must not overwrite it.
	public static bool OcclusionFromArgs;
	/// Whether big meshes' geometry streams in pages (virtual geometry); off: every page is loaded when the mesh is
	/// (`--no-geometry-streaming`).
	public static bool StreamGeometry = true;
	/// `--no-geometry-streaming` was given: the quality preset must not overwrite it.
	public static bool StreamGeometryFromArgs;
	/// The debug view in use, and which level of the occlusion pyramid the Hzb view shows.
	public static DebugView View = .Off;
	public static int32 DebugMip = 0;
	/// Highest level the LodLevel view's colours go to.
	public const float DebugMaxLevel = 12;

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
	/// The debug views' programs (the clusters' and the virtual textures' colours, the pyramid); optional.
	public static bgfx.ProgramHandle DebugProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DebugVtProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle DebugHzbProgram = .() { idx = uint16.MaxValue };
	public static bgfx.UniformHandle uDebug, uHzbShow;
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
		DebugProgram = Gfx.LoadProgram("vs_cluster_debug", "fs_cluster_debug");
		DebugVtProgram = Gfx.LoadProgram("vs_cluster_debug", "fs_cluster_debug_vt");
		DebugHzbProgram = Gfx.LoadProgram("vs_fullscreen", "fs_hzb_debug");
		uDebug = bgfx.create_uniform("u_clodDebug", .Vec4, 1);
		uHzbShow = bgfx.create_uniform("u_hzbShow", .Vec4, 1);
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

	/// A mesh's place in the pool: its table of clusters and groups (resident for good), and its pages of vertices and triangles
	/// (ClusterPages), which are in the pool while they are resident.
	public class MeshEntry : IStreamConsumer
	{
		/// The first cluster's position in the pool (in words) and how many clusters the mesh has.
		public uint32 clusterBase, clusterCount;
		public int32 triangles;
		/// Where the mesh's table of clusters and groups starts and how long it is (in words), for giving it back.
		public int32 poolStart, poolWords;
		/// The first group's position in the pool and the first of its feedback numbers (a group's number is firstId + its index).
		public uint32 groupBase, firstId;
		public int32 groupCount;
		public ClusterPages pages ~ delete _;
		/// Null when every page is loaded whole.
		public StreamResource resource;
		/// Pages below this are loaded whole and never evicted (the root page, or all of them for a small mesh).
		public int32 firstStreamed;
		/// For each page: where its data is in the pool (-1: not there), how long it is, and whether its groups are drawable
		/// (data there and every parent page's groups drawable too).
		public int32[] pageStart ~ delete _;
		public int32[] pageWords ~ delete _;
		public bool[] pageLive ~ delete _;
		public int[] pageTouched ~ delete _;
		public int32 residentPages;

		public bool IsResident(int page) => pageStart[page] >= 0;

		/// The page's data arrived (the core's, on the main thread): puts it in the pool and makes what can be drawn drawable.
		public bool Upload(StreamResource resource, int page, Span<uint8> data)
		{
			return UploadPage(page, data);
		}

		public bool UploadPage(int page, Span<uint8> data)
		{
			if (pageStart[page] >= 0)
				return true;
			if (!ClusterPages.ReadHeader(data, let groupCountInPage, let clusterCountInPage, let vertexCount, let refCount, let triangleBytes))
				return false;
			let head = (uint32*)data.Ptr;
			let vertexWords = (int)vertexCount * VertexWords;
			let refWords = (int)refCount;
			let triWords = ((int)triangleBytes + 3) / 4;
			let total = Pad4(vertexWords) + Pad4(refWords) + Pad4(triWords);
			let start = GpuDriven.Allocate(total);
			if (start < 0)
				return false;
			let words = sWords.Ptr + start;
			let descriptors = head + ClusterPages.HeaderWords;
			let groupList = descriptors + clusterCountInPage * 4;
			let vertexSource = groupList + (groupCountInPage + 3) / 4 * 4;
			let refSource = vertexSource + Pad4(vertexWords);
			let triSource = (uint8*)(refSource + Pad4(refWords));
			let vertexBase = (uint32)start;
			let refsBase = (uint32)(start + Pad4(vertexWords));
			let trianglesBase = (uint32)(start + Pad4(vertexWords) + Pad4(refWords));
			Internal.MemCpy(words, vertexSource, vertexWords * 4);
			for (int i < refWords)
				words[Pad4(vertexWords) + i] = vertexBase + refSource[i] * VertexWords;
			words[Pad4(vertexWords) + Pad4(refWords) + triWords - 1] = 0;
			Internal.MemCpy(words + Pad4(vertexWords) + Pad4(refWords), triSource, (int)triangleBytes);
			var low = int.MaxValue;
			var high = 0;
			for (int c < (int)clusterCountInPage)
			{
				let index = (int)descriptors[c * 4];
				let record = sWords.Ptr + clusterBase + index * ClusterWords;
				record[0] = refsBase + descriptors[c * 4 + 1];
				record[2] = trianglesBase * 4 + descriptors[c * 4 + 2];
				low = Math.Min(low, (int)clusterBase + index * ClusterWords);
				high = Math.Max(high, (int)clusterBase + (index + 1) * ClusterWords);
			}
			pageStart[page] = (int32)start;
			pageWords[page] = (int32)total;
			residentPages++;
			GpuDriven.MarkDirty(start, start + total);
			if (high > low)
				GpuDriven.MarkDirty(low, high);
			Publish();
			return true;
		}

		/// Makes the groups of every page drawable whose data and parents' data are in the pool. Parent pages come first
		/// in page order, so one pass does it.
		public void Publish()
		{
			for (int page < pages.PageCount)
			{
				if (pageLive[page] || pageStart[page] < 0)
					continue;
				var ready = true;
				for (let parent in pages.ParentPages[page])
				{
					if (!pageLive[parent])
					{
						ready = false;
						break;
					}
				}
				if (!ready)
					continue;
				pageLive[page] = true;
				SetGroups(page, 1);
			}
		}

		void SetGroups(int page, uint32 value)
		{
			var low = int.MaxValue;
			var high = 0;
			for (let group in pages.GroupsOfPage[page])
			{
				let at = (int)groupBase + group * GroupWords;
				sWords[at + 4] = value;
				low = Math.Min(low, at);
				high = Math.Max(high, at + GroupWords);
			}
			if (high > low)
				GpuDriven.MarkDirty(low, high);
		}

		/// Takes a page out of the pool, and with it every page that needs it (finer pages the coarser clusters stand in for).
		public void EvictPage(int page, StreamPool pool)
		{
			if (page < firstStreamed || pageStart[page] < 0)
				return;
			for (let child in pages.ChildPages[page])
			{
				if (pageStart[child] >= 0)
				{
					pool.Remove(resource.Id, child, StreamingCore.Frame);
					EvictPage(child, pool);
				}
			}
			if (pageLive[page])
			{
				pageLive[page] = false;
				SetGroups(page, 0);
			}
			GpuDriven.Free(pageStart[page], pageWords[page]);
			pageStart[page] = -1;
			residentPages--;
		}

		/// Gives everything back (the mesh is gone).
		public void Release()
		{
			if (resource != null)
			{
				GpuDriven.sByResource.Remove(resource.Id);
				if (StreamingCore.Started)
					StreamingCore.Unregister(resource, pages.PageCount);
				GpuDriven.sStreamed--;
				delete resource.File;
				DeleteAndNullify!(resource);
			}
			for (int page < pages.PageCount)
			{
				if (pageStart[page] >= 0)
					GpuDriven.Free(pageStart[page], pageWords[page]);
				pageStart[page] = -1;
			}
			GpuDriven.Free(poolStart, poolWords);
			GpuDriven.ReleaseIds(firstId, groupCount);
			poolWords = 0;
		}
	}

	class BuildJob
	{
		public int64 id;
		public Mesh copy ~ delete _;
		public String cachePath = new .() ~ delete _;
		public ClusterMesh result ~ delete _;
		/// The pages: their layout, the data of the pages that load whole, and the file the rest are read from.
		public ClusterPages pages;
		public List<(int page, List<uint8> data)> loaded = new .() ~ { for (let l in _) delete l.data; delete _; };
		public String pageFile = new .() ~ delete _;
		public bool whole;
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
	public static MeshEntry Lookup(Mesh mesh, bool force = false)
	{
		if (mesh.GpuEntry != null)
			return mesh.GpuEntry;
		if (mesh.GpuJob != 0 || mesh.GpuFailed)
			return null;
		if ((!force && mesh.Indices.Count / 3 < MinTriangles) || mesh.Indices.Count < 3 || mesh.Vertices.Count == 0 || mesh.VertexSource != null || mesh.IsDynamic)
			return null;
		let job = new BuildJob();
		job.whole = !StreamGeometry || !StreamingCore.Started;
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
			mesh.GpuEntry.Release();
		DeleteAndNullify!(mesh.GpuEntry);
		mesh.GpuFailed = false;
	}

	/// Cuts a built hierarchy into pages: a small mesh keeps every page in memory to load whole, a big one writes its pages
	/// to a file (beside the .tclod, or in the temporary folder) and keeps the root page.
	static void CookPages(BuildJob job)
	{
		let clusters = job.result;
		job.pages = ClusterPages.Layout(clusters);
		let pages = job.pages;
		if (pages.PageCount <= ClusterPages.WholeMeshPages || job.whole)
		{
			for (int page < pages.PageCount)
				job.loaded.Add((page, pages.Build(clusters, job.copy, page)));
			return;
		}
		if (!job.cachePath.IsEmpty)
			job.pageFile.Set(job.cachePath..Append('p'));
		else
			job.pageFile.AppendF("{}tallow-clod/{:x}.tclodp", Path.GetTempPath(.. scope .()), clusters.ContentHash);
		var cook = !clusters.FromCache || !File.Exists(job.pageFile);
		if (!cook)
		{
			let existing = scope PageFile();
			cook = existing.Open(job.pageFile) case .Err || existing.PageCount != pages.PageCount;
		}
		if (cook && pages.Cook(clusters, job.copy, job.pageFile) case .Err)
		{
			// No file to stream from: load whole.
			job.pageFile.Clear();
			for (int page < pages.PageCount)
				job.loaded.Add((page, pages.Build(clusters, job.copy, page)));
			return;
		}
		job.loaded.Add((0, pages.Build(clusters, job.copy, 0)));
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
			if (job.result != null)
				CookPages(job);
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
				let entry = AddToPool(mesh, job);
				if (entry == null)
				{
					mesh.GpuFailed = true;
					continue;
				}
				mesh.GpuEntry = entry;
				MeshesBuilt++;
			}
		}
		PollFeedback();
		if (sDirty.Count > 0 || sWords.Count > sPoolCapacity)
			Send();
	}

	/// The words a mesh's table takes in the pool: its clusters and groups, each part padded to whole vec4s. (Its vertices and
	/// triangles are in pages.)
	static int WordsFor(ClusterMesh clusters)
	{
		return Pad4(clusters.Clusters.Count * ClusterWords) + Pad4(clusters.Groups.Count * GroupWords);
	}

	static int Pad4(int words) => (words + 3) / 4 * 4;

	/// Finds `words` words of room: a stretch given back long enough ago, or the end of the pool. -1: no room.
	internal static int Allocate(int words)
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
	internal static void Free(int start, int words)
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

	/// Puts a mesh's table of clusters and groups in the pool, with every offset in it turned into a position in the pool, and
	/// its root pages (all of them for a small mesh); the other pages are asked for as the culling wants them. Null when there
	/// is no room.
	static MeshEntry AddToPool(Mesh mesh, BuildJob job)
	{
		let clusters = job.result;
		let total = WordsFor(clusters);
		let start = Allocate(total);
		if (start < 0)
			return null;
		let words = sWords.Ptr + start;
		let clusterBase = (uint32)start;
		let groupBase = clusterBase + (uint32)(clusters.Clusters.Count * ClusterWords);
		let firstId = AllocateIds(clusters.Groups.Count);
		var at = 0;
		for (var cluster in clusters.Clusters)
		{
			cluster.vertexOffset = 0;
			cluster.triangleOffset = 0;
			cluster.groupIndex = (int32)(groupBase + (uint32)cluster.groupIndex * GroupWords);
			cluster.refinedGroup = cluster.refinedGroup < 0 ? -1 : (int32)(groupBase + (uint32)cluster.refinedGroup * GroupWords);
			Internal.MemCpy(words + at, &cluster, ClusterWords * 4);
			at += ClusterWords;
		}
		var groupIndex = 0;
		for (var group in clusters.Groups)
		{
			words[at++] = *(uint32*)&group.center.x;
			words[at++] = *(uint32*)&group.center.y;
			words[at++] = *(uint32*)&group.center.z;
			words[at++] = *(uint32*)&group.radius;
			words[at++] = 0;
			words[at++] = firstId + (uint32)groupIndex;
			words[at++] = (uint32)group.depth;
			words[at++] = 0;
			groupIndex++;
		}
		MarkDirty(start, start + total);
		let entry = new MeshEntry();
		entry.clusterBase = clusterBase;
		entry.clusterCount = (uint32)clusters.Clusters.Count;
		entry.triangles = (int32)clusters.SourceTriangleCount;
		entry.poolStart = (int32)start;
		entry.poolWords = (int32)total;
		entry.groupBase = groupBase;
		entry.groupCount = (int32)clusters.Groups.Count;
		entry.firstId = firstId;
		entry.pages = job.pages;
		job.pages = null;
		let pageCount = entry.pages.PageCount;
		entry.pageStart = new int32[pageCount];
		entry.pageWords = new int32[pageCount];
		entry.pageLive = new bool[pageCount];
		entry.pageTouched = new int[pageCount];
		for (int i < pageCount)
			entry.pageStart[i] = -1;
		for (let i < entry.groupCount)
			sGroupOwner[(int)firstId + i] = entry;
		entry.firstStreamed = (int32)pageCount;
		if (!job.pageFile.IsEmpty)
		{
			let file = new PageFile();
			if (file.Open(job.pageFile) case .Ok)
			{
				entry.firstStreamed = 1;
				entry.resource = new StreamResource();
				entry.resource.Id = (uint64)sNextResource++;
				entry.resource.Kind = .GeoPage;
				entry.resource.File = file;
				entry.resource.Consumer = entry;
				StreamingCore.Register(entry.resource);
				sByResource[entry.resource.Id] = entry;
				sStreamed++;
				if (StreamingCore.Pool(.GeoPage).OnEvict == null)
					StreamingCore.Pool(.GeoPage).OnEvict = new => OnEvicted;
			}
			else
				delete file;
		}
		for (let loaded in job.loaded)
		{
			if (!entry.UploadPage(loaded.page, .(loaded.data.Ptr, loaded.data.Count)))
				Log.Warning("GPU-driven drawing: a page of a mesh did not fit in the pool");
		}
		return entry;
	}

	// ---- virtual geometry: group numbers, feedback and the streamed pages

	static Dictionary<uint64, MeshEntry> sByResource = new .() ~ delete _;
	static List<MeshEntry> sGroupOwner = new .() ~ delete _;
	static List<(uint32 first, int count)> sFreeIds = new .() ~ delete _;
	static int64 sNextResource = 1;
	/// How many meshes stream their pages.
	static int sStreamed;
	public static int StreamedMeshes => sStreamed;
	/// Geometry pages' counters: asked for by the culling in the last feedback, and the groups it wanted that were missing.
	public static int64 PagesRequested, GroupsMissing, FeedbackReads;

	static uint32 AllocateIds(int count)
	{
		for (int i < sFreeIds.Count)
		{
			let free = sFreeIds[i];
			if (free.count >= count)
			{
				if (free.count == count)
					sFreeIds.RemoveAt(i);
				else
					sFreeIds[i] = (free.first + (uint32)count, free.count - count);
				return free.first;
			}
		}
		let first = (uint32)sGroupOwner.Count;
		for (int i < count)
			sGroupOwner.Add(null);
		return first;
	}

	static void ReleaseIds(uint32 first, int count)
	{
		for (int i < count)
			sGroupOwner[(int)first + i] = null;
		sFreeIds.Add((first, count));
	}

	static void OnEvicted(uint64 resource, int page)
	{
		if (sByResource.TryGetValue(resource, let entry))
			entry.EvictPage(page, StreamingCore.Pool(.GeoPage));
	}

	static bgfx.DynamicVertexBufferHandle sFeedback = .() { idx = uint16.MaxValue };
	/// Words in each of the feedback's two bitmaps (a multiple of four).
	static int sFeedbackWords = 64;
	static uint32[] sFeedbackData ~ delete _;
	/// 0: nothing asked; 1: the read was asked for (frame in sFeedbackFrame).
	static int sFeedbackState;
	static int64 sFeedbackFrame;
	static int64 sFeedbackLast = -1000;
	/// How often the feedback is read back, in frames.
	public static int32 FeedbackInterval = 3;

	/// The feedback buffer the culling writes: a bitmap of the groups drawn, then a bitmap of the groups wanted but missing.
	/// Always valid once drawing is available (the culling binds it).
	public static bgfx.DynamicVertexBufferHandle Feedback { get { EnsureFeedback(); return sFeedback; } }
	public static int FeedbackBitmapWords => sFeedbackWords;

	static void EnsureFeedback()
	{
		let needWords = Pad4(((sGroupOwner.Count + 31) / 32));
		if (sFeedback.Valid && needWords <= sFeedbackWords)
			return;
		if (sFeedbackState != 0)
			return;
		if (sFeedback.Valid)
			bgfx.destroy_dynamic_vertex_buffer(sFeedback);
		while (sFeedbackWords < needWords)
			sFeedbackWords *= 2;
		sFeedback = bgfx.create_dynamic_vertex_buffer((uint32)(sFeedbackWords * 2 / 4), &WordLayout, (uint16)bgfx.BufferFlags.ComputeReadWrite);
		ClearFeedback();
		delete sFeedbackData;
		sFeedbackData = new uint32[sFeedbackWords * 2];
	}

	static void ClearFeedback()
	{
		let zeros = new uint32[sFeedbackWords * 2];
		defer delete zeros;
		bgfx.update_dynamic_vertex_buffer(sFeedback, 0, bgfx.copy(zeros.CArray(), (uint32)(zeros.Count * 4)));
	}

	/// Every few frames reads back what the culling drew and wanted (a few frames late: the read never waits for this
	/// frame), keeps the pages in use warm and asks for the pages that are missing, parents first.
	static void PollFeedback()
	{
		if (!sAvailable)
			return;
		EnsureFeedback();
		if (sStreamed == 0 || !sFeedback.Valid || sFeedbackData == null)
			return;
		let frame = Time.FrameCount;
		if (sFeedbackState == 0)
		{
			if (frame - sFeedbackLast < FeedbackInterval)
				return;
			bgfx.BufferRegion region = default;
			bgfx.BufferHandle handle = .() { idx = sFeedback.idx, type = 1 };
			bgfx.buffer_region_init_buffer(&region, handle, 0, (uint32)(sFeedbackWords * 2 * 4));
			bgfx.read_buffer(&region, sFeedbackData.CArray());
			sFeedbackState = 1;
			sFeedbackFrame = frame;
		}
		else if (frame - sFeedbackFrame >= 3)
		{
			sFeedbackState = 0;
			sFeedbackLast = frame;
			FeedbackReads++;
			UseFeedback((int)frame);
			ClearFeedback();
		}
	}

	static void UseFeedback(int frame)
	{
		let pool = StreamingCore.Pool(.GeoPage);
		if (pool == null)
			return;
		let limit = Math.Min(sFeedbackWords, (sGroupOwner.Count + 31) / 32);
		GroupsMissing = 0;
		for (int w < limit)
		{
			let used = sFeedbackData[w];
			if (used != 0)
			{
				for (int bit < 32)
				{
					if ((used & (1u << bit)) != 0)
					{
						let id = w * 32 + bit;
						if (id < sGroupOwner.Count && sGroupOwner[id] != null)
							TouchGroup(sGroupOwner[id], id, frame, pool);
					}
				}
			}
			let wanted = sFeedbackData[sFeedbackWords + w];
			if (wanted != 0)
			{
				for (int bit < 32)
				{
					if ((wanted & (1u << bit)) != 0)
					{
						let id = w * 32 + bit;
						if (id < sGroupOwner.Count && sGroupOwner[id] != null)
						{
							GroupsMissing++;
							RequestGroup(sGroupOwner[id], id, frame, pool);
						}
					}
				}
			}
		}
	}

	static void TouchGroup(MeshEntry entry, int id, int frame, StreamPool pool)
	{
		if (entry.resource == null)
			return;
		TouchPage(entry, entry.pages.PageOfGroup[id - (int)entry.firstId], frame, pool);
	}

	/// Marks a page used this frame, and the pages it needs (they must not be evicted while it is drawn).
	static void TouchPage(MeshEntry entry, int page, int frame, StreamPool pool)
	{
		if (page < entry.firstStreamed || entry.pageTouched[page] == frame)
			return;
		entry.pageTouched[page] = frame;
		pool.Touch(entry.resource.Id, page, frame);
		for (let parent in entry.pages.ParentPages[page])
			TouchPage(entry, parent, frame, pool);
	}

	static void RequestGroup(MeshEntry entry, int id, int frame, StreamPool pool)
	{
		if (entry.resource == null)
			return;
		let group = id - (int)entry.firstId;
		RequestPage(entry, entry.pages.PageOfGroup[group], 100.0f, pool);
	}

	/// Asks for a page and, before it, the pages it needs (their priority is higher).
	static void RequestPage(MeshEntry entry, int page, float priority, StreamPool pool)
	{
		if (page < entry.firstStreamed || entry.pageLive[page])
			return;
		if (!entry.IsResident(page) && StreamingCore.Request(entry.resource, page, priority))
			PagesRequested++;
		for (let parent in entry.pages.ParentPages[page])
			RequestPage(entry, parent, priority + 50.0f, pool);
	}

	internal static void MarkDirty(int firstWord, int endWord)
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
