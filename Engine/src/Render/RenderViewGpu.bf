using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// GPU-driven drawing in the render path (GpuDriven.bf, GpuDrivenView.bf): the gathered items that qualify are taken out
/// of the usual lists and handed to the graphics card as instance records; the scene pass, the depth pass and the sun's
/// shadow cascades then draw clusters picked by compute shaders instead of whole meshes.
extension RenderView
{
	/// An item routed to the graphics card, with its mesh's clusters and its bin (the kind of surface it is drawn with).
	struct GpuItem
	{
		public RenderItem item;
		public GpuDriven.MeshEntry entry;
		public int32 bin;
	}

	GpuDrivenView mGpu ~ delete _;
	List<GpuItem> mGpuScene = new .() ~ delete _;
	List<GpuItem> mGpuShadow = new .() ~ delete _;
	/// One item of each bin, which supplies its surface: material, reflection probe and light grid.
	List<RenderItem> mGpuBins = new .() ~ delete _;
	Dictionary<uint64, int32> mGpuBinIndex = new .() ~ delete _;
	/// Shadow casters drawn this way in the sun's cascades that the point and spot lights' tiles still draw the usual way.
	List<RenderItem> mLocalShadowItems = new .() ~ delete _;
	bool mGpuActive;

	/// Whether this view may draw GPU-driven: the setting is on, the view is a plain one (not a reflection capture or
	/// a planar reflection, which render more than once in a frame, nor an editor shading mode) and has not done so
	/// already this frame.
	bool GpuAllowed()
	{
		if (!GpuDriven.Enabled || shading != .Rendered || Capture || PlanarPass)
			return false;
		return mGpu == null || mGpu.Frame != Time.FrameCount;
	}

	/// Whether an item can be drawn from clusters: a plain solid surface of a mesh whose clusters are in the pool.
	bool GpuEligible(RenderItem item)
	{
		let renderer = item.renderer;
		if (renderer.GameObject == null || item.prevSlot != 0 || renderer.windSway > 0 || renderer.HasLightmap || renderer.screenReflections || renderer.planarReflection)
			return false;
		let material = item.material;
		if (material != null)
		{
			if (material.IsPalette)
				return false;
			let custom = material.Shader?.Program;
			if (custom != null && custom.Value.idx != uint16.MaxValue)
				return false;
		}
		let mesh = item.mesh;
		return !mesh.IsDynamic && mesh.VertexSource == null && GpuDriven.Lookup(mesh) != null;
	}

	/// The kind of surface an item is drawn with (everything MakeKey tells apart except the mesh), or -1 when this view has
	/// no room for another.
	int32 GpuBinFor(RenderItem item)
	{
		let key = ProbeKey(MakeKey(item.renderer, null, item.material), item.probe, item.lightGrid) * 2 + (Mirrored(item.world) ? 1u : 0u);
		if (mGpuBinIndex.TryGetValue(key, let bin))
			return bin;
		if (mGpuBins.Count >= GpuDriven.MaxBins)
			return -1;
		mGpuBins.Add(item);
		mGpuBinIndex[key] = (int32)mGpuBins.Count - 1;
		return (int32)mGpuBins.Count - 1;
	}

	/// Takes the items that qualify out of the lists of solid things and shadow casters (when the sun's cascades are
	/// drawn), and sends them to the graphics card as instances. Called once the gather is done.
	void GpuRoute(bool castShadows)
	{
		mGpuActive = false;
		if (mGpu != null)
			mGpu.EndFrame();
		mGpuScene.Clear();
		mGpuShadow.Clear();
		mGpuBins.Clear();
		mGpuBinIndex.Clear();
		mLocalShadowItems.Clear();
		if (!GpuAllowed())
			return;
		// Clusters that finished building go into the pool (and some more are started, by the lookups below).
		GpuDriven.Update();

		var kept = 0;
		let items = mItems.Ptr;
		for (int i < mItems.Count)
		{
			let item = items[i];
			if (GpuEligible(item))
			{
				let bin = GpuBinFor(item);
				if (bin >= 0)
				{
					mGpuScene.Add(.() { item = item, entry = item.mesh.GpuEntry, bin = bin });
					continue;
				}
			}
			items[kept++] = item;
		}
		mItems.Count = kept;

		if (castShadows)
		{
			kept = 0;
			let casters = mShadowItems.Ptr;
			for (int i < mShadowItems.Count)
			{
				let item = casters[i];
				if (GpuEligible(item))
				{
					mGpuShadow.Add(.() { item = item, entry = item.mesh.GpuEntry, bin = 0 });
					if (mHasLocalShadows)
						mLocalShadowItems.Add(item);
					continue;
				}
				casters[kept++] = item;
			}
			mShadowItems.Count = kept;
		}
		if (mGpuScene.Count == 0 && mGpuShadow.Count == 0)
			return;

		if (mGpu == null)
			mGpu = new .();
		let words = mGpu.Reserve((int32)mGpuScene.Count, (int32)mGpuShadow.Count);
		for (int i < mGpuScene.Count)
			WriteGpuInstance(words + i * GpuDriven.InstanceWords, ref mGpuScene[i]);
		let shadowWords = words + mGpuScene.Count * GpuDriven.InstanceWords;
		for (int i < mGpuShadow.Count)
			WriteGpuInstance(shadowWords + i * GpuDriven.InstanceWords, ref mGpuShadow[i]);
		mGpu.Upload();
		mGpu.Frame = Time.FrameCount;
		mGpuActive = true;
		GpuDriven.FramesDrawn++;
		GpuDriven.FrameBins += (int32)mGpuBins.Count;
		GpuDriven.FrameInstances += (int32)mGpuScene.Count;
	}

	/// One instance's record (include/clod.sh): the world matrix and colour as an InstanceData holds them, last
	/// frame's matrix for the motion vectors, the sphere round it, the mesh's clusters, its bin and its largest scale.
	void WriteGpuInstance(uint32* words, ref GpuItem gpu)
	{
		let item = &gpu.item;
		InstanceData data = default;
		FillInstance(&data, item);
		Internal.MemCpy(words, &data, sizeof(InstanceData));
		let previous = mTemporalOn ? PreviousWorld(item.renderer, item.world) : item.world;
		float* prev = (float*)(words + 20);
		prev[0] = previous.m[0]; prev[1] = previous.m[4]; prev[2] = previous.m[8]; prev[3] = previous.m[12];
		prev[4] = previous.m[1]; prev[5] = previous.m[5]; prev[6] = previous.m[9]; prev[7] = previous.m[13];
		prev[8] = previous.m[2]; prev[9] = previous.m[6]; prev[10] = previous.m[10]; prev[11] = previous.m[14];
		float* sphere = (float*)(words + 32);
		sphere[0] = item.center.x; sphere[1] = item.center.y; sphere[2] = item.center.z; sphere[3] = item.radius;
		let world = item.world;
		let x = Vector3(world.m[0], world.m[1], world.m[2]).Length;
		let y = Vector3(world.m[4], world.m[5], world.m[6]).Length;
		let z = Vector3(world.m[8], world.m[9], world.m[10]).Length;
		let largest = Math.Max(x, Math.Max(y, z));
		let smallest = Math.Min(x, Math.Min(y, z));
		// Clusters are turned away by their cones: not through a surface seen from both sides or stretched unevenly.
		let material = item.material;
		let twoSided = !item.renderer.backFaceCulling || (material != null && material.doubleSided);
		let noCone = twoSided || largest > smallest * 1.02f;
		words[36] = gpu.entry.clusterBase;
		words[37] = gpu.entry.clusterCount;
		words[38] = (uint32)gpu.bin | (noCone ? 0x10000u : 0u);
		*(float*)(words + 39) = largest;
	}

	/// The scene's pass of clusters to draw: the instances in view, from the camera.
	void GpuCullScene(CameraData camera)
	{
		if (!mGpuActive || mGpu.SceneCount == 0)
			return;
		GpuCullParams p = default;
		let frustum = Frustum(camera.projection * camera.view, Gfx.HomogeneousDepth);
		p.planes = frustum.planes;
		p.eye = camera.position;
		p.ortho = camera.orthographic;
		p.pixelScale = camera.projection.m[5] * 0.5f * mHeight;
		p.near = Math.Max(camera.near, 0.001f);
		p.threshold = GpuDriven.PixelError;
		p.cone = GpuDriven.ConeCulling;
		mGpu.Cull(GpuDrivenView.ScenePass, 0, mGpu.SceneCount, (int32)mGpuBins.Count, p);
		mGpu.PollStats();
	}

	/// A sun cascade's pass: the casters inside its box (as the usual path picks them), at a coarser error.
	void GpuCullCascade(int cascade)
	{
		if (!mGpuActive || mGpu.ShadowCount == 0)
			return;
		GpuCullParams p = default;
		let center = mCascadeCenter[cascade];
		let radius = mCascadeRadius[cascade];
		for (int i < 6)
			p.planes[i] = .(0, 0, 0, 1.0e9f);
		p.planes[0] = .(mLightRight, radius - Vector3.Dot(mLightRight, center));
		p.planes[1] = .(-mLightRight, radius + Vector3.Dot(mLightRight, center));
		p.planes[2] = .(mLightUp, radius - Vector3.Dot(mLightUp, center));
		p.planes[3] = .(-mLightUp, radius + Vector3.Dot(mLightUp, center));
		p.ortho = true;
		p.pixelScale = RenderResources.ShadowTileSize / (2.0f * radius);
		p.near = 0.001f;
		p.threshold = GpuDriven.PixelError * GpuDriven.ShadowErrorScale;
		p.cone = false;
		mGpu.Cull(1 + cascade, mGpu.SceneCount, mGpu.ShadowCount, 1, p);
	}

	/// Draws the scene's bins, each with its own surface.
	void GpuDrawScene(uint16 view)
	{
		if (!mGpuActive || !mGpu.HasPass(GpuDrivenView.ScenePass))
			return;
		for (int bin < mGpuBins.Count)
		{
			let first = mGpuBins[bin];
			SetFrameUniforms();
			Reflections.Bind(first.probe, mReflectionIntensity, mCubeAmbient);
			if (first.lightGrid > 0)
				LightProbes.Bind(mProbeGrid, first.lightGrid);
			var surface = ResolveSurface(first.renderer, first.material, first.world);
			surface.cull = FacingCull(surface.cull);
			SetSurfaceUniforms(first.renderer, ref surface);
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | surface.cull | Gfx.StateMsaa, 0);
			mGpu.SubmitBin(view, GpuDriven.LitProgram, GpuDrivenView.ScenePass, bin);
			DrawCalls++;
		}
		Instances += mGpu.SceneCount;
	}

	/// Draws the scene's bins into the depth pass (and its motion vectors and colours when it makes them).
	void GpuDrawDepth(uint16 view, Matrix4 viewProj)
	{
		if (!mGpuActive || !mGpu.HasPass(GpuDrivenView.ScenePass))
			return;
		for (int bin < mGpuBins.Count)
		{
			let first = mGpuBins[bin];
			var matrix = viewProj;
			var depthParams = Vector4(0, 0, 0, 0);
			if (mDepthAlbedo)
			{
				var uvTransform = Vector4(1, 1, 0, 0);
				if (first.material != null)
					uvTransform = .(first.material.tiling.x, first.material.tiling.y, first.material.offset.x, first.material.offset.y);
				bgfx.set_uniform(RenderResources.uUvTransform, &uvTransform, 1);
				bgfx.set_texture(0, RenderResources.sAlbedo, AlbedoTexture(first), uint32.MaxValue);
			}
			if (mTemporalOn)
				SetVelocityUniforms(false, false);
			bgfx.set_uniform(RenderResources.uDepthViewProj, &matrix, 1);
			bgfx.set_uniform(RenderResources.uDepthParams, &depthParams, 1);
			uint64 cull = FacingCull(Mirrored(first.world) ? Gfx.StateCullCw : Gfx.StateCullCcw);
			if ((first.material != null && first.material.doubleSided) || !first.renderer.backFaceCulling)
				cull = 0;
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | cull, 0);
			let program = mTemporalOn ? (mDepthAlbedo ? GpuDriven.DepthAlbedoVelProgram : GpuDriven.DepthVelProgram) : (mDepthAlbedo ? GpuDriven.DepthAlbedoProgram : GpuDriven.DepthProgram);
			mGpu.SubmitBin(view, program, GpuDrivenView.ScenePass, bin);
			DrawCalls++;
		}
	}

	/// Draws a sun cascade's casters.
	void GpuDrawShadow(uint16 view, int cascade)
	{
		if (!mGpuActive || !mGpu.HasPass(1 + cascade))
			return;
		bgfx.set_uniform(RenderResources.uShadowViewProj, &mShadowPassViewProj, 1);
		bgfx.set_state(Gfx.StateWriteZ | Gfx.StateDepthLess, 0);
		mGpu.SubmitBin(view, GpuDriven.ShadowProgram, 1 + cascade, 0);
		DrawCalls++;
	}
}
