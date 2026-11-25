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
}

/// One RenderView's part of GPU-driven drawing: the instances it hands the graphics card each frame, and for every
/// pass that draws them (the scene and the sun's four shadow cascades; the depth pass reuses the scene's) the buffers
/// the culling fills and the draw reads.
///
/// Buffers (all words of 32 bits, see include/clod.sh):
///   instances  GpuDriven.InstanceWords per instance (the scene's instances first, then the shadow casters')
///   nodes      per pass: 4 words per node of up to 64 clusters of one instance (instance, first cluster, count)
///   control    per pass: counters, then each bin's cluster count and how many were written
///   visible    per pass: each bin's first place, then (instance, cluster) pairs bin after bin
///   indirect   per pass: the cluster culling's dispatch size, then each bin's draw command
///
/// A renderer is drawn this way when its mesh's clusters are in the pool and it is a plain solid one: no custom shader,
/// palette, wind sway, lightmap, mirror reflection (planar or screen), skinning or other moving vertices, not the viewmodel,
/// and the view shows the Rendered look and is not a reflection capture or a planar reflection. Everything else takes the
/// usual path. At most one frame of GPU-driven drawing per RenderView per frame.
class GpuDrivenView
{
	public const int PassCount = 5;
	public const int ScenePass = 0;

	public class Pass
	{
		public bgfx.DynamicVertexBufferHandle nodes = .() { idx = uint16.MaxValue };
		public bgfx.DynamicVertexBufferHandle control = .() { idx = uint16.MaxValue };
		public bgfx.DynamicVertexBufferHandle visible = .() { idx = uint16.MaxValue };
		public bgfx.IndirectBufferHandle indirect = .() { idx = uint16.MaxValue };
		public int32 nodeCapacity, visibleCapacity;
		public int32 bins;
		public bool culled;

		public void Release()
		{
			if (nodes.Valid) bgfx.destroy_dynamic_vertex_buffer(nodes);
			if (control.Valid) bgfx.destroy_dynamic_vertex_buffer(control);
			if (visible.Valid) bgfx.destroy_dynamic_vertex_buffer(visible);
			if (indirect.Valid) bgfx.destroy_indirect_buffer(indirect);
			nodes.idx = control.idx = visible.idx = indirect.idx = uint16.MaxValue;
		}
	}

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
	/// The frame the instances were last handed over in (a view draws this way once a frame).
	public int64 Frame = -1;

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
		}
	}

	/// Room for this frame's instances: returns where to write the scene's (SceneCount records) followed by the
	/// shadow casters' (ShadowCount records).
	public uint32* Reserve(int32 scene, int32 shadow)
	{
		mSlot = (int)(Time.FrameCount % Slots);
		SceneCount = scene;
		ShadowCount = shadow;
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

	Pass PassFor(int index)
	{
		var pass = mPasses[mSlot * PassCount + index];
		if (pass != null)
			return pass;
		pass = new Pass();
		mPasses[mSlot * PassCount + index] = pass;
		pass.nodeCapacity = index == ScenePass ? (1 << 18) : (1 << 17);
		pass.visibleCapacity = index == ScenePass ? (1 << 20) : (1 << 18);
		let flags = (uint16)bgfx.BufferFlags.ComputeReadWrite;
		pass.nodes = bgfx.create_dynamic_vertex_buffer((uint32)pass.nodeCapacity, &GpuDriven.WordLayout, flags);
		pass.control = bgfx.create_dynamic_vertex_buffer((uint32)((GpuDriven.MaxBins * 2 + 8) / 4), &GpuDriven.WordLayout, flags);
		pass.visible = bgfx.create_dynamic_vertex_buffer((uint32)((GpuDriven.MaxBins + pass.visibleCapacity * 2) / 4), &GpuDriven.WordLayout, flags);
		pass.indirect = bgfx.create_indirect_buffer((uint32)(1 + GpuDriven.MaxBins));
		return pass;
	}

	/// Picks the clusters of instances [first, first + count) to draw for one view into pass `index`, with `bins` kinds
	/// of material. The draws then use SubmitBin. Dispatches go in GpuDriven.CullView, so they run before any drawing.
	public void Cull(int index, int32 first, int32 count, int32 bins, GpuCullParams p)
	{
		if (count <= 0)
			return;
		let pass = PassFor(index);
		pass.bins = bins;
		pass.culled = true;
		let view = GpuDriven.CullView;
		bgfx.set_view_mode(view, .Sequential);
		let setup = GpuDriven.SetupProgram;
		Vector4[6] planes = p.planes;
		Vector4 camera = .(p.eye, p.ortho ? 1 : 0);
		Vector4 lod = .(p.pixelScale, p.near, p.threshold, p.cone ? 1 : 0);

		// 1. Clear the counters.
		SetupBuffers(pass);
		Vector4 mode = .(0, bins, pass.visibleCapacity, pass.nodeCapacity);
		bgfx.set_uniform(GpuDriven.uMode, &mode, 1);
		bgfx.dispatch(view, setup, 1, 1, 1, 0xff);

		// 2. The instances in view hand their clusters over as nodes.
		bgfx.set_compute_dynamic_vertex_buffer(0, mInstances, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(1, pass.control, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(2, pass.nodes, .ReadWrite, 0, uint32.MaxValue);
		Vector4 counts = .(first, count, pass.nodeCapacity, 0);
		bgfx.set_uniform(GpuDriven.uPlanes, &planes, 6);
		bgfx.set_uniform(GpuDriven.uCounts, &counts, 1);
		bgfx.dispatch(view, GpuDriven.InstanceProgram, (uint32)((count + 63) / 64), 1, 1, 0xff);

		// 3. The size of the next step.
		SetupBuffers(pass);
		mode.x = 1;
		bgfx.set_uniform(GpuDriven.uMode, &mode, 1);
		bgfx.dispatch(view, setup, 1, 1, 1, 0xff);

		// 4. Count what each bin gets, 5. give each bin its place, 6. write the clusters there.
		for (int step < 3)
		{
			if (step == 1)
			{
				SetupBuffers(pass);
				mode.x = 2;
				bgfx.set_uniform(GpuDriven.uMode, &mode, 1);
				bgfx.dispatch(view, setup, 1, 1, 1, 0xff);
				continue;
			}
			bgfx.set_compute_dynamic_vertex_buffer(0, GpuDriven.Pool, .Read, 0, uint32.MaxValue);
			bgfx.set_compute_dynamic_vertex_buffer(1, mInstances, .Read, 0, uint32.MaxValue);
			bgfx.set_compute_dynamic_vertex_buffer(2, pass.nodes, .Read, 0, uint32.MaxValue);
			bgfx.set_compute_dynamic_vertex_buffer(3, pass.control, .ReadWrite, 0, uint32.MaxValue);
			bgfx.set_compute_dynamic_vertex_buffer(4, pass.visible, .ReadWrite, 0, uint32.MaxValue);
			Vector4 clusterCounts = .(step == 0 ? 0 : 1, 0, pass.nodeCapacity, 0);
			bgfx.set_uniform(GpuDriven.uPlanes, &planes, 6);
			bgfx.set_uniform(GpuDriven.uCam, &camera, 1);
			bgfx.set_uniform(GpuDriven.uLod, &lod, 1);
			bgfx.set_uniform(GpuDriven.uCounts, &clusterCounts, 1);
			bgfx.dispatch_indirect(view, GpuDriven.ClusterProgram, pass.indirect, 0, 1, 0xff);
		}
	}

	void SetupBuffers(Pass pass)
	{
		bgfx.set_compute_dynamic_vertex_buffer(0, pass.control, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_compute_indirect_buffer(1, pass.indirect, .ReadWrite);
		bgfx.set_compute_dynamic_vertex_buffer(2, pass.visible, .ReadWrite, 0, uint32.MaxValue);
	}

	uint32[8] mStats;
	int64 mStatsFrame = -1000;
	bool mStatsPending;

	/// Reads the scene pass's counters back (clusters and triangles drawn, what ran over the budgets): every
	/// GpuDriven.StatsInterval frames the graphics card is asked, and the answer is taken a few frames later. This is the
	/// only read back and it waits for the graphics card to catch up with the commands before it, so it is rare.
	public void PollStats()
	{
		let pass = mPasses[mSlot * PassCount + ScenePass];
		if (pass == null)
			return;
		if (mStatsPending && Time.FrameCount - mStatsFrame >= 4)
		{
			mStatsPending = false;
			GpuDriven.Clusters = mStats[GpuDriven.CtrlClusters];
			GpuDriven.ClustersLost = mStats[GpuDriven.CtrlClustersLost];
			GpuDriven.NodesLost = mStats[GpuDriven.CtrlNodesLost];
			GpuDriven.Triangles = mStats[GpuDriven.CtrlTriangles];
			GpuDriven.StatsReads++;
		}
		else if (!mStatsPending && pass.culled && Time.FrameCount - mStatsFrame >= GpuDriven.StatsInterval)
		{
			bgfx.BufferRegion region = default;
			bgfx.BufferHandle handle = .() { idx = pass.control.idx, type = 1 };
			bgfx.buffer_region_init_buffer(&region, handle, 0, 32);
			bgfx.read_buffer(&region, &mStats);
			mStatsFrame = Time.FrameCount;
			mStatsPending = true;
		}
	}

	/// Whether pass `index` was culled this frame.
	public bool HasPass(int index) => mPasses[mSlot * PassCount + index] != null && mPasses[mSlot * PassCount + index].culled;

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
		let pass = mPasses[mSlot * PassCount + index];
		bgfx.set_vertex_buffer(0, GpuDriven.NoVertices, 0, 1);
		bgfx.set_index_buffer(GpuDriven.IndexBuffer, 0, (uint32)(GpuDriven.MaxBins * GpuDriven.ClusterIndices));
		bgfx.set_compute_dynamic_vertex_buffer(8, GpuDriven.Pool, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(9, mInstances, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(10, pass.visible, .Read, 0, uint32.MaxValue);
		bgfx.submit_indirect(view, program, pass.indirect, (uint32)(1 + bin), 1, 0, 0xff);
	}
}
