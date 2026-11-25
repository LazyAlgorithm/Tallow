using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// What one cull needs to know about the view it picks clusters for.
struct GpuCullParams
{
	/// The planes round what is in view (facing in); a shadow cascade has only its four sides.
	public Vector4[6] planes;
	public Vector3 eye;
	/// A view without perspective (an orthographic camera, a shadow cascade).
	public bool ortho;
	/// Pixels one unit of error spans at distance 1 (perspective) or at any distance (ortho).
	public float pixelScale;
	public float near;
	/// The error, in pixels, that is small enough.
	public float threshold;
	/// Leave out the clusters that turn away from the eye.
	public bool cone;
	/// The occlusion test: 0 none, 1 the first phase (against last frame's picture), 2 the second (against this frame's first).
	public int32 occlusion;
	public GpuOccluder occluder;
	/// The software raster mode of GpuDriven (0 off, 1 classify, 2 on); only the scene camera sets it.
	public int32 swMode;
}

/// One RenderView's part of GPU-driven drawing: the instances it hands the graphics card each frame, and for every
/// pass that draws them (the scene's two phases, the sun's four shadow cascades and the point and spot lights' tiles; the
/// depth pass reuses the scene's) the buffers the culling fills and the draw reads.
///
/// Buffers (all words of 32 bits, see include/clod.sh):
///   instances  GpuDriven.InstanceWords per instance (the scene's instances first, then the shadow casters')
///   nodes      per pass: 4 words per node of up to 64 clusters of one instance (instance, first cluster, count)
///   control    per pass: counters, then each bin's cluster count and how many were written
///   visible    per pass: each bin's first place, then (instance, cluster) pairs bin after bin
///   indirect   per pass: the cluster culling's dispatch size, then each bin's draw command, then the second phase's sizes
///   defer      per pass: what the scene's first phase put off for the second
///
/// Occlusion, in two phases (after Niagara and Nanite; no frame waits for the card): the scene's culling runs twice. The
/// first phase tests every instance and cluster against the picture last frame's occluders made, where they were then;
/// what that picture hides it does not draw but lists (deferred), what it does not hide goes in the first pass. Those
/// are drawn first, as occluders, into a target of their own, and a picture of distances is made of them (GpuOcclusion.bf).
/// The second phase tests the deferred instances and clusters against that fresh picture, and what it does not hide goes
/// in the second pass. Both passes are drawn in the scene; the second pass's are drawn as occluders too, and the picture
/// made of both is what the next frame starts from. Nothing is lost when last frame's picture is wrong (a thing that
/// moved, a camera cut): it only makes the first phase draw too much or leaves more to the second. The shadow passes
/// have one phase and no occlusion.
///
/// A renderer is drawn this way when its mesh's clusters are in the pool and it is a plain solid one: no custom shader,
/// palette, wind sway, lightmap, mirror reflection (planar or screen), skinning or other moving vertices, not the viewmodel,
/// and the view shows the Rendered look and is not a reflection capture or a planar reflection. Everything else takes the
/// usual path. At most one frame of GPU-driven drawing per RenderView per frame.
class GpuDrivenView
{
	/// The scene's first (or only) pass, the four cascades' (1 to 4), the scene's second pass, then one pass per shadow tile
	/// of a point or spot light (the tiles after MaxTilePasses draw the usual way).
	public const int ScenePass = 0;
	public const int SecondPass = 5;
	public const int TilePass = 6;
	public const int MaxTilePasses = 24;
	public const int PassCount = TilePass + MaxTilePasses;

	public class Pass
	{
		public bgfx.DynamicVertexBufferHandle nodes = .() { idx = uint16.MaxValue };
		public bgfx.DynamicVertexBufferHandle control = .() { idx = uint16.MaxValue };
		public bgfx.DynamicVertexBufferHandle visible = .() { idx = uint16.MaxValue };
		public bgfx.DynamicVertexBufferHandle deferred = .() { idx = uint16.MaxValue };
		public bgfx.IndirectBufferHandle indirect = .() { idx = uint16.MaxValue };
		public int32 nodeCapacity, visibleCapacity;
		/// Room in the deferred lists: instances, and clusters (pairs).
		public int32 deferInstances, deferClusters;
		public int32 bins;
		public bool culled;

		public void Release()
		{
			if (nodes.Valid) bgfx.destroy_dynamic_vertex_buffer(nodes);
			if (control.Valid) bgfx.destroy_dynamic_vertex_buffer(control);
			if (visible.Valid) bgfx.destroy_dynamic_vertex_buffer(visible);
			if (deferred.Valid) bgfx.destroy_dynamic_vertex_buffer(deferred);
			if (indirect.Valid) bgfx.destroy_indirect_buffer(indirect);
			nodes.idx = control.idx = visible.idx = deferred.idx = indirect.idx = uint16.MaxValue;
		}
	}

	/// The most clusters a pass may have room for (a pass with more is cut short, and grows for the next frames).
	const int MaxVisible = 1 << 23;
	const int MaxNodes = 1 << 22;

	/// The buffers the frames in flight use: the graphics card may still be drawing from last frame's while this frame's are
	/// filled (nothing in between makes the later frame wait), so frames take turns.
	const int Slots = 3;
	Pass[Slots * PassCount] mPasses;
	bgfx.DynamicVertexBufferHandle[Slots] mInstanceBuffers = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	int[Slots] mInstanceCapacities;
	int mSlot;
	bgfx.DynamicVertexBufferHandle mInstances => mInstanceBuffers[mSlot];
	List<uint32> mWords = new .() ~ delete _;
	/// How many instances the scene pass has and how many casters the shadow cascades have (this frame).
	public int32 SceneCount, ShadowCount;
	/// How many work nodes the scene's instances and the casters need at most (each takes a node per 64 clusters).
	public int64 SceneNodes, ShadowNodes;
	/// The frame the instances were last handed over in (a view draws this way once a frame).
	public int64 Frame = -1;

	/// Room for clusters in the passes, grown when the culling counts clusters it had no room for.
	int32 mSceneVisible = 1 << 20;
	int32 mCascadeVisible = 1 << 18;
	int32 mTileVisible = 1 << 16;

	public ~this()
	{
		for (let pass in mPasses)
		{
			if (pass != null && Gfx.Initialized)
				pass.Release();
			delete pass;
		}
		if (Gfx.Initialized)
		{
			for (let buffer in mInstanceBuffers)
			{
				if (buffer.Valid)
					bgfx.destroy_dynamic_vertex_buffer(buffer);
			}
			if (mStats.Valid)
				bgfx.destroy_dynamic_vertex_buffer(mStats);
		}
	}

	/// Room for this frame's instances: returns where to write the scene's (SceneCount records) followed by the
	/// shadow casters' (ShadowCount records).
	public uint32* Reserve(int32 scene, int32 shadow)
	{
		mSlot = (int)(Time.FrameCount % Slots);
		SceneCount = scene;
		ShadowCount = shadow;
		SceneNodes = ShadowNodes = 0;
		mWords.Count = (scene + shadow) * GpuDriven.InstanceWords;
		return mWords.Ptr;
	}

	/// Sends the instances written since Reserve to the graphics card.
	public void Upload()
	{
		let words = mWords.Count;
		if (words == 0)
			return;
		let need = words / 4;
		if (need > mInstanceCapacities[mSlot])
		{
			if (mInstanceBuffers[mSlot].Valid)
				bgfx.destroy_dynamic_vertex_buffer(mInstanceBuffers[mSlot]);
			var capacity = Math.Max(mInstanceCapacities[mSlot] * 2, 4096);
			while (capacity < need)
				capacity *= 2;
			mInstanceBuffers[mSlot] = bgfx.create_dynamic_vertex_buffer((uint32)capacity, &GpuDriven.WordLayout, (uint16)bgfx.BufferFlags.ComputeRead);
			mInstanceCapacities[mSlot] = capacity;
		}
		bgfx.update_dynamic_vertex_buffer(mInstanceBuffers[mSlot], 0, bgfx.copy(mWords.Ptr, (uint32)(words * 4)));
	}

	static int32 PowerOfTwo(int64 n, int32 least, int32 most)
	{
		var p = (int64)least;
		while (p < n && p < most)
			p *= 2;
		return (int32)Math.Min(p, (int64)most);
	}

	/// The pass's buffers for this frame's slot, made (or made bigger) as the budgets ask. Nodes are budgeted for the most the
	/// instances can make, so a pass never runs out of them.
	Pass PassFor(int index, int32 instances)
	{
		let isScene = index == ScenePass || index == SecondPass;
		let isCascade = index > ScenePass && index < SecondPass;
		let nodesNeeded = (isScene ? SceneNodes : ShadowNodes) + 1;
		let nodes = PowerOfTwo(nodesNeeded, 1 << 12, MaxNodes);
		let visible = isScene ? mSceneVisible : (isCascade ? mCascadeVisible : mTileVisible);
		// Only the scene's first pass lists what it defers; the other passes have the header's room and nothing else.
		let deferInstances = index == ScenePass ? PowerOfTwo(instances, 1 << 10, 1 << 24) : 0;
		let deferClusters = index == ScenePass ? visible : 0;
		var pass = mPasses[mSlot * PassCount + index];
		if (pass != null)
		{
			if (pass.nodeCapacity >= nodes && pass.visibleCapacity >= visible && pass.deferInstances >= deferInstances && pass.deferClusters >= deferClusters)
				return pass;
			pass.Release();
		}
		else
		{
			pass = new Pass();
			mPasses[mSlot * PassCount + index] = pass;
		}
		pass.nodeCapacity = Math.Max(pass.nodeCapacity, nodes);
		pass.visibleCapacity = Math.Max(pass.visibleCapacity, visible);
		pass.deferInstances = Math.Max(pass.deferInstances, deferInstances);
		pass.deferClusters = Math.Max(pass.deferClusters, deferClusters);
		let flags = (uint16)bgfx.BufferFlags.ComputeReadWrite;
		pass.nodes = bgfx.create_dynamic_vertex_buffer((uint32)pass.nodeCapacity, &GpuDriven.WordLayout, flags);
		pass.control = bgfx.create_dynamic_vertex_buffer((uint32)((GpuDriven.MaxBins * 2 + 8) / 4), &GpuDriven.WordLayout, flags);
		pass.visible = bgfx.create_dynamic_vertex_buffer((uint32)((GpuDriven.MaxBins + pass.visibleCapacity * 2) / 4), &GpuDriven.WordLayout, flags);
		let deferWords = 8 + pass.deferInstances + pass.deferClusters * 2;
		pass.deferred = bgfx.create_dynamic_vertex_buffer((uint32)((deferWords + 3) / 4), &GpuDriven.WordLayout, flags);
		pass.indirect = bgfx.create_indirect_buffer((uint32)(3 + GpuDriven.MaxBins));
		return pass;
	}

	Pass Existing(int index) => mPasses[mSlot * PassCount + index];

	/// The setup shader's buffers: the pass's own, and the first phase's list of what it deferred (the pass's own when it is the first).
	void SetupBuffers(Pass pass, Pass first)
	{
		bgfx.set_compute_dynamic_vertex_buffer(0, pass.control, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_indirect_buffer(1, pass.indirect, .ReadWrite);
		bgfx.set_compute_dynamic_vertex_buffer(2, pass.visible, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(3, pass.deferred, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(4, first.deferred, .Read, 0, uint32.MaxValue);
	}

	void SetupStep(uint16 view, Pass pass, Pass first, int32 step, int32 bins, Pass roomPass)
	{
		SetupBuffers(pass, first);
		Vector4 mode = .(step, bins, pass.visibleCapacity, pass.nodeCapacity);
		Vector4 occ = .(0, first.deferInstances, first.deferClusters, 0);
		bgfx.set_uniform(GpuDriven.uMode, &mode, 1);
		bgfx.set_uniform(GpuDriven.uOcc, &occ, 1);
		bgfx.dispatch(view, GpuDriven.SetupProgram, 1, 1, 1, 0xff);
	}

	/// Sets what the occlusion test of a dispatch reads: the picture's pyramid and the camera it was drawn from.
	void SetOcclusion(GpuCullParams p, Pass first)
	{
		Vector4 occ = .(p.occlusion, first.deferInstances, first.deferClusters, 0);
		bgfx.set_uniform(GpuDriven.uOcc, &occ, 1);
		if (p.occlusion != 0)
		{
			var o = p.occluder;
			Vector4 hzb = .(o.baseWidth, o.baseHeight, o.levels, Gfx.OriginBottomLeft ? 0 : 1);
			Vector4 screen = .(o.width, o.height, o.near, 0);
			bgfx.set_uniform(GpuDriven.uView, &o.view, 1);
			bgfx.set_uniform(GpuDriven.uProj, &o.projection, 1);
			bgfx.set_uniform(GpuDriven.uHzb, &hzb, 1);
			bgfx.set_uniform(GpuDriven.uScreen, &screen, 1);
		}
	}

	bgfx.DynamicVertexBufferHandle HzbOf(GpuCullParams p) => p.occlusion != 0 ? p.occluder.buffer : GpuDriven.Zeros;

	/// The cluster culling's dispatch, from the work nodes (`retest` false) or from the clusters the first phase deferred (true).
	void ClusterStep(uint16 view, Pass pass, Pass first, GpuCullParams p, int32 step, bool retest)
	{
		bgfx.set_compute_dynamic_vertex_buffer(0, GpuDriven.Pool, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(1, mInstances, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(2, pass.nodes, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(3, pass.control, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(4, pass.visible, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(5, first.deferred, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(6, HzbOf(p), .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(7, GpuDriven.Feedback, .ReadWrite, 0, uint32.MaxValue);
		Vector4 camera = .(p.eye, p.ortho ? 1 : 0);
		Vector4 lod = .(p.pixelScale, p.near, p.threshold, p.cone ? 1 : 0);
		Vector4 counts = .(step, retest ? 1 : 0, pass.nodeCapacity, (float)GpuDriven.FeedbackBitmapWords);
		Vector4[6] planes = p.planes;
		bgfx.set_uniform(GpuDriven.uPlanes, &planes, 6);
		bgfx.set_uniform(GpuDriven.uCam, &camera, 1);
		bgfx.set_uniform(GpuDriven.uLod, &lod, 1);
		bgfx.set_uniform(GpuDriven.uCounts, &counts, 1);
		Vector4 sw = .(p.swMode, GpuDriven.SwEdgePixels, p.near, 0);
		bgfx.set_uniform(GpuDriven.uSw, &sw, 1);
		SetOcclusion(p, first);
		bgfx.dispatch_indirect(view, GpuDriven.ClusterProgram, pass.indirect, retest ? 258 : 0, 1, 0xff);
	}

	/// Picks the clusters of instances [first, first + count) to draw for one view into pass `index`, with `bins` kinds
	/// of material (for the scene, p.occlusion 1 makes it the first phase, which lists what last frame's picture hides). The
	/// draws then use SubmitBin. Dispatches go in GpuDriven.CullView, so they run before any drawing.
	public void Cull(int index, int32 first, int32 count, int32 bins, GpuCullParams p)
	{
		if (count <= 0)
			return;
		let pass = PassFor(index, count);
		pass.bins = bins;
		pass.culled = true;
		let view = GpuDriven.CullView;
		bgfx.set_view_mode(view, .Sequential);

		// 1. Clear the counters.
		SetupStep(view, pass, pass, 0, bins, pass);

		// 2. The instances in view hand their clusters over as nodes.
		bgfx.set_compute_dynamic_vertex_buffer(0, mInstances, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(1, pass.control, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(2, pass.nodes, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(3, pass.deferred, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(4, HzbOf(p), .Read, 0, uint32.MaxValue);
		Vector4 counts = .(first, count, pass.nodeCapacity, 0);
		Vector4[6] planes = p.planes;
		bgfx.set_uniform(GpuDriven.uPlanes, &planes, 6);
		bgfx.set_uniform(GpuDriven.uCounts, &counts, 1);
		SetOcclusion(p, pass);
		bgfx.dispatch(view, GpuDriven.InstanceProgram, (uint32)((count + 63) / 64), 1, 1, 0xff);

		// 3. The size of the next step.
		SetupStep(view, pass, pass, 1, bins, pass);

		// 4. Count what each bin gets, 5. give each bin its place, 6. write the clusters there.
		ClusterStep(view, pass, pass, p, 0, false);
		SetupStep(view, pass, pass, 2, bins, pass);
		ClusterStep(view, pass, pass, p, 1, false);
	}

	/// The scene's second phase: the instances and clusters the first phase put off, against the picture of the first
	/// phase's occluders (p.occluder), into the second pass. Dispatches go in GpuDriven.HzbView, after the first phase's
	/// occluders are drawn and their picture is made.
	public void CullSecond(int32 bins, GpuCullParams p)
	{
		let first = Existing(ScenePass);
		if (first == null || !first.culled)
			return;
		let pass = PassFor(SecondPass, 0);
		pass.bins = bins;
		pass.culled = true;
		let view = GpuDriven.HzbView;
		bgfx.set_view_mode(view, .Sequential);

		SetupStep(view, pass, first, 0, bins, first);
		SetupStep(view, pass, first, 3, bins, first);

		// The deferred instances: those the first picture does not hide hand their clusters over as nodes.
		bgfx.set_compute_dynamic_vertex_buffer(0, mInstances, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(1, pass.control, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(2, pass.nodes, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(3, first.deferred, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(4, HzbOf(p), .Read, 0, uint32.MaxValue);
		Vector4 counts = .(0, 0, pass.nodeCapacity, 1);
		Vector4[6] planes = p.planes;
		bgfx.set_uniform(GpuDriven.uPlanes, &planes, 6);
		bgfx.set_uniform(GpuDriven.uCounts, &counts, 1);
		SetOcclusion(p, first);
		bgfx.dispatch_indirect(view, GpuDriven.InstanceProgram, pass.indirect, 257, 1, 0xff);

		SetupStep(view, pass, first, 1, bins, first);
		ClusterStep(view, pass, first, p, 0, false);
		ClusterStep(view, pass, first, p, 0, true);
		SetupStep(view, pass, first, 2, bins, first);
		ClusterStep(view, pass, first, p, 1, false);
		ClusterStep(view, pass, first, p, 1, true);
	}

	/// The sizes of the statistics: where each number is in the stats buffer (cs_clod_stats.sc).
	const int StatWords = 24;
	uint32[StatWords] mStatValues;
	bgfx.DynamicVertexBufferHandle mStats = .() { idx = uint16.MaxValue };
	int64 mStatsFrame = -1000;
	/// 0: nothing asked; 1: the numbers were gathered in a frame, not read yet; 2: the read was asked for.
	int mStatsState;
	int64 mStatsStateFrame;
	/// How many times the culling counted clusters it had no room for, and the passes it grew.
	public int32 BudgetGrows;

	/// Whether this frame's culling should gather the numbers for the profiler.
	bool StatsDue => mStatsState == 0 && Time.FrameCount - mStatsFrame >= GpuDriven.StatsInterval;

	/// Called after the frame's last culling dispatch (in the view it went in) to copy the counters into one small buffer.
	void GatherStats(uint16 view)
	{
		if (!StatsDue || Existing(ScenePass) == null || !Existing(ScenePass).culled)
			return;
		if (!mStats.Valid)
			mStats = bgfx.create_dynamic_vertex_buffer((uint32)(StatWords / 4), &GpuDriven.WordLayout, (uint16)bgfx.BufferFlags.ComputeReadWrite);
		bgfx.set_compute_dynamic_vertex_buffer(0, mStats, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(1, Existing(ScenePass).control, .Read, 0, uint32.MaxValue);
		let second = Existing(SecondPass);
		bgfx.set_compute_dynamic_vertex_buffer(2, (second != null && second.culled) ? second.control : GpuDriven.Zeros, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(3, Existing(ScenePass).deferred, .Read, 0, uint32.MaxValue);
		for (int c < 4)
		{
			let cascade = Existing(1 + c);
			bgfx.set_compute_dynamic_vertex_buffer((uint8)(4 + c), (cascade != null && cascade.culled) ? cascade.control : GpuDriven.Zeros, .Read, 0, uint32.MaxValue);
		}
		bgfx.dispatch(view, GpuDriven.StatsProgram, 1, 1, 1, 0xff);
		mStatsState = 1;
		mStatsStateFrame = Time.FrameCount;
	}

	/// Gathers the numbers when this is the last culling of the frame, in the view it went in.
	public void FinishCulling(uint16 view)
	{
		GatherStats(view);
	}

	/// Takes the statistics: a frame after they were gathered the read is asked for (bgfx's read waits for the graphics card
	/// to finish its earlier frames, so it is rare, and the frame it is asked in is one after the gathering so that the wait is
	/// for work that has been going on a whole frame), and a few frames after that the numbers are used.
	public void PollStats()
	{
		if (mStatsState == 1 && Time.FrameCount > mStatsStateFrame)
		{
			bgfx.BufferRegion region = default;
			bgfx.BufferHandle handle = .() { idx = mStats.idx, type = 1 };
			bgfx.buffer_region_init_buffer(&region, handle, 0, StatWords * 4);
			bgfx.read_buffer(&region, &mStatValues);
			mStatsState = 2;
			mStatsStateFrame = Time.FrameCount;
		}
		else if (mStatsState == 2 && Time.FrameCount - mStatsStateFrame >= 3)
		{
			mStatsState = 0;
			mStatsFrame = Time.FrameCount;
			UseStats();
		}
	}

	void UseStats()
	{
		let v = mStatValues;
		GpuDriven.ClustersFirst = v[0];
		GpuDriven.ClustersSecond = v[4];
		GpuDriven.Clusters = (int64)v[0] + v[4];
		GpuDriven.Triangles = (int64)v[1] + v[5];
		GpuDriven.ClustersLost = (int64)v[2] + v[6] + v[10];
		GpuDriven.NodesLost = (int64)v[3] + v[7];
		GpuDriven.DeferredInstances = v[8];
		GpuDriven.DeferredClusters = v[9];
		GpuDriven.SwClusters = v[20];
		GpuDriven.SwTriangles = v[21];
		GpuDriven.HwClusters = v[22];
		GpuDriven.StatsReads++;
		// A pass that had no room for clusters: its budget doubles for the next frames.
		if (v[2] + v[6] + v[10] > 0 && mSceneVisible < MaxVisible)
			Grow(ref mSceneVisible, "scene");
		var cascadeLost = 0;
		for (int c < 4)
			cascadeLost += (int)v[12 + 2 * c];
		if (cascadeLost > 0 && mCascadeVisible < MaxVisible)
			Grow(ref mCascadeVisible, "cascade");
	}

	void Grow(ref int32 budget, StringView name)
	{
		budget *= 2;
		BudgetGrows++;
		Log.Info(scope $"GPU-driven drawing: the {name} passes ran out of room for clusters, now {budget}");
	}

	/// Whether pass `index` was culled this frame.
	public bool HasPass(int index) => Existing(index) != null && Existing(index).culled;

	/// Ends the frame's use of the passes.
	public void EndFrame()
	{
		for (let pass in mPasses)
		{
			if (pass != null)
				pass.culled = false;
		}
	}

	/// Submits the draw of one bin of a pass: the caller has set the state and uniforms of the surface, this binds the
	/// buffers the vertex shader reads and draws the clusters the culling put in the bin (stages 8 to 10, which the
	/// shaders of the other draws leave to their lightmaps).
	public void SubmitBin(uint16 view, bgfx.ProgramHandle program, int index, int bin)
	{
		let pass = Existing(index);
		bgfx.set_vertex_buffer(0, GpuDriven.NoVertices, 0, 1);
		bgfx.set_index_buffer(GpuDriven.IndexBuffer, 0, (uint32)(GpuDriven.MaxBins * GpuDriven.ClusterIndices));
		bgfx.set_compute_dynamic_vertex_buffer(8, GpuDriven.Pool, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(9, mInstances, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(10, pass.visible, .Read, 0, uint32.MaxValue);
		bgfx.submit_indirect(view, program, pass.indirect, (uint32)(1 + bin), 1, 0, 0xff);
	}
}
