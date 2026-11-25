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
	GpuOcclusion mGpuOcc ~ delete _;
	/// Whether this view's GPU-driven items are tested against what hides them (GpuDrivenView.bf), and whether the
	/// scene's second pass was culled this frame.
	bool mGpuOccludes;
	bool mGpuTwoPhase;
	List<GpuItem> mGpuScene = new .() ~ delete _;
	List<GpuItem> mGpuShadow = new .() ~ delete _;
	/// One item of each bin, which supplies its surface: material, reflection probe and light grid.
	List<RenderItem> mGpuBins = new .() ~ delete _;
	Dictionary<uint64, int32> mGpuBinIndex = new .() ~ delete _;
	/// Shadow casters drawn this way in the sun's cascades that the point and spot lights' tiles still draw the usual way.
	List<RenderItem> mLocalShadowItems = new .() ~ delete _;
	bool mGpuActive;

	/// Which of the views with room for an occlusion test this one is (GpuDriven.FirstDrawView); -1: none, the view has
	/// none of its own.
	int GpuOcclusionSlot => ViewBase == 10 ? 0 : (ViewBase == 10 + ViewCount ? 1 : -1);

	/// Whether this view's GPU-driven drawing leaves out what is hidden (the camera's occlusion culling is on, it has
	/// perspective, the view is a plain one and has a slot).
	bool GpuOcclusionWanted(CameraData camera)
	{
		return GpuDriven.Enabled && GpuDriven.Occlusion && GpuOcclusionSlot >= 0 && camera.occlusionCulling && !camera.orthographic
			&& shading == .Rendered && !Capture && !PlanarPass;
	}

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
		if (renderer.GameObject == null || item.prevSlot != 0 || renderer.virtualGeometry == .Off || renderer.windSway > 0 || renderer.HasLightmap || renderer.screenReflections || renderer.planarReflection)
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
		return !mesh.IsDynamic && mesh.VertexSource == null && GpuDriven.Lookup(mesh, renderer.virtualGeometry == .On) != null;
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
		mGpuTwoPhase = false;
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

		if (castShadows || mHasLocalShadows)
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
		{
			WriteGpuInstance(words + i * GpuDriven.InstanceWords, ref mGpuScene[i]);
			mGpu.SceneNodes += (mGpuScene[i].entry.clusterCount + 63) / 64;
		}
		let shadowWords = words + mGpuScene.Count * GpuDriven.InstanceWords;
		for (int i < mGpuShadow.Count)
		{
			WriteGpuInstance(shadowWords + i * GpuDriven.InstanceWords, ref mGpuShadow[i]);
			mGpu.ShadowNodes += (mGpuShadow[i].entry.clusterCount + 63) / 64;
		}
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
		let previous = (mTemporalOn || mGpuOccludes) ? PreviousWorld(item.renderer, item.world) : item.world;
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
		// Where the sphere was last frame, which the occlusion test of the first phase asks about.
		Vector3 before = item.center;
		var moved = false;
		for (int i < 15)
		{
			if (previous.m[i] != world.m[i])
				moved = true;
		}
		if (moved)
			before = previous.TransformPoint(world.Inverse.TransformPoint(item.center));
		float* beforeCenter = (float*)(words + 40);
		beforeCenter[0] = before.x; beforeCenter[1] = before.y; beforeCenter[2] = before.z; beforeCenter[3] = 0;
		words[36] = gpu.entry.clusterBase;
		words[37] = gpu.entry.clusterCount;
		words[38] = (uint32)gpu.bin | (noCone ? 0x10000u : 0u);
		*(float*)(words + 39) = largest;
	}

	/// The scene's passes of clusters to draw: the instances in view, from the camera. With occlusion (GpuDrivenView.bf has the
	/// whole story) the first phase's pass is culled now, its clusters are drawn as occluders into a target of the occlusion
	/// test's own, a picture of distances is made of it, and the second phase's pass is culled against that; the second
	/// pass's occluders are drawn too and the finished picture is kept for the next frame's first phase.
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
		mGpuTwoPhase = false;
		if (GpuOcclusionWanted(camera))
		{
			if (mGpuOcc == null)
				mGpuOcc = new .();
			if (mGpuOcc.Ensure(mWidth, mHeight))
			{
				GpuCullOccluded(camera, p);
				mGpu.PollStats();
				return;
			}
		}
		mGpu.Cull(GpuDrivenView.ScenePass, 0, mGpu.SceneCount, (int32)mGpuBins.Count, p);
		mGpu.FinishCulling(GpuDriven.CullView);
		mGpu.PollStats();
	}

	void GpuCullOccluded(CameraData camera, GpuCullParams first)
	{
		let slot = (uint16)GpuOcclusionSlot;
		let bins = (int32)mGpuBins.Count;
		let history = mGpuOcc.CanUseHistory(camera);
		var p = first;
		if (history)
		{
			p.occlusion = 1;
			p.occluder = mGpuOcc.History(camera);
		}
		mGpu.Cull(GpuDrivenView.ScenePass, 0, mGpu.SceneCount, bins, p);
		GpuDrawOccluders((uint16)(GpuDriven.FirstDrawView + slot), camera, GpuDrivenView.ScenePass, true);
		if (history)
		{
			// The picture of the first phase's occluders, then the second phase against it.
			mGpuOcc.Build(GpuDriven.HzbView, 1);
			p.occlusion = 2;
			p.occluder = mGpuOcc.Current(camera);
			mGpu.CullSecond(bins, p);
			mGpuTwoPhase = true;
			GpuDrawOccluders((uint16)(GpuDriven.SecondDrawView + slot), camera, GpuDrivenView.SecondPass, false);
			mGpuOcc.Build(GpuDriven.FinalHzbView, 0);
			mGpu.FinishCulling(GpuDriven.HzbView);
		}
		else
		{
			mGpuOcc.Build(GpuDriven.HzbView, 0);
			mGpu.FinishCulling(GpuDriven.HzbView);
		}
		mGpuOcc.SaveCamera(camera);
	}

	/// Draws a pass's clusters as occluders: the distance in front of the camera, into the occlusion test's target.
	void GpuDrawOccluders(uint16 view, CameraData camera, int pass, bool clear)
	{
		if (!mGpu.HasPass(pass))
			return;
		var viewMatrix = camera.view;
		var projMatrix = camera.projection;
		bgfx.set_palette_color_rgba32f(DepthPalette, 60000.0f, 0, 0, 1);
		StringView name = clear ? "GPU occluders" : "GPU occluders, second phase";
		bgfx.set_view_name(view, name.Ptr, (int32)name.Length);
		bgfx.set_view_frame_buffer(view, mGpuOcc.FrameBuffer);
		bgfx.set_view_rect(view, 0, 0, (uint16)mWidth, (uint16)mHeight, 0, 1);
		if (clear)
			bgfx.set_view_clear_mrt(view, Gfx.ClearColor | Gfx.ClearDepth, 1.0f, 0, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette);
		else
			bgfx.set_view_clear(view, 0, 0, 1.0f, 0);
		bgfx.set_view_transform(view, &viewMatrix, &projMatrix);
		bgfx.touch(view);
		var viewProj = projMatrix * viewMatrix;
		var depthParams = Vector4(0, 0, 0, 0);
		for (int bin < mGpuBins.Count)
		{
			let first = mGpuBins[bin];
			bgfx.set_uniform(RenderResources.uDepthViewProj, &viewProj, 1);
			bgfx.set_uniform(RenderResources.uDepthParams, &depthParams, 1);
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | GpuDepthCull(first), 0);
			mGpu.SubmitBin(view, GpuDriven.DepthProgram, pass, bin);
		}
	}

	/// How the faces of a bin's surface are culled in a depth draw.
	uint64 GpuDepthCull(RenderItem first)
	{
		if ((first.material != null && first.material.doubleSided) || !first.renderer.backFaceCulling)
			return 0;
		return FacingCull(Mirrored(first.world) ? Gfx.StateCullCw : Gfx.StateCullCcw);
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

	/// The pass of a point or spot light's shadow tile: the casters in the tile's frustum, seen from the light at a coarse
	/// error. False when there is no pass for the tile (the usual path draws it).
	bool GpuCullTile(int index, ShadowTile tile)
	{
		if (!mGpuActive || mGpu.ShadowCount == 0 || index >= GpuDrivenView.MaxTilePasses || !GpuDriven.LocalShadows)
			return false;
		GpuCullParams p = default;
		p.planes = tile.frustum.planes;
		p.eye = tile.light.Transform.Position;
		p.ortho = false;
		p.pixelScale = tile.pixelScale;
		p.near = 0.02f;
		p.threshold = GpuDriven.PixelError * GpuDriven.ShadowErrorScale;
		p.cone = false;
		mGpu.Cull(GpuDrivenView.TilePass + index, mGpu.SceneCount, mGpu.ShadowCount, 1, p);
		return true;
	}

	/// Draws the scene's bins, each with its own surface (the first phase's clusters, then the second's).
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
			NoteStreamedTextures(first, surface);
			surface.cull = FacingCull(surface.cull);
			SetSurfaceUniforms(first.renderer, ref surface);
			let vt = GpuBinVt(first);
			var program = vt != null ? VirtualTextures.LitProgram : GpuDriven.LitProgram;
			var debugMode = 0.0f;
			if (GpuDriven.DebugProgram.Valid && GpuDriven.View != .Off && GpuDriven.View != .Hzb)
			{
				program = GpuDriven.DebugProgram;
				switch (GpuDriven.View)
				{
				case .Clusters: debugMode = 1;
				case .LodLevel: debugMode = 2;
				case .Triangles: debugMode = 3;
				case .Residency: debugMode = 6;
				case .VtPages:
					if (vt != null && GpuDriven.DebugVtProgram.Valid)
						program = GpuDriven.DebugVtProgram;
					else
						debugMode = 7;
				default:
				}
			}
			if (vt != null)
				VirtualTextures.Bind(vt);
			let state = Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | surface.cull | Gfx.StateMsaa;
			bgfx.set_state(state, 0);
			var debugValues = Vector4(debugMode, GpuDriven.DebugMaxLevel, 0, 0);
			if (debugMode > 0 || program.idx == GpuDriven.DebugVtProgram.idx)
				bgfx.set_uniform(GpuDriven.uDebug, &debugValues, 1);
			mGpu.SubmitBin(view, program, GpuDrivenView.ScenePass, bin);
			DrawCalls++;
			if (mGpuTwoPhase)
			{
				// The surface's uniforms and textures go with each draw, so they are set again for the second.
				SetFrameUniforms();
				Reflections.Bind(first.probe, mReflectionIntensity, mCubeAmbient);
				if (first.lightGrid > 0)
					LightProbes.Bind(mProbeGrid, first.lightGrid);
				SetSurfaceUniforms(first.renderer, ref surface);
				if (vt != null)
					VirtualTextures.Bind(vt);
				bgfx.set_state(state, 0);
				if (debugMode > 0 || program.idx == GpuDriven.DebugVtProgram.idx)
					bgfx.set_uniform(GpuDriven.uDebug, &debugValues, 1);
				mGpu.SubmitBin(view, program, GpuDrivenView.SecondPass, bin);
				DrawCalls++;
			}
		}
		Instances += mGpu.SceneCount;
	}

	/// The Hzb debug view: one level of the occlusion pyramid (the finished picture of this frame), over the scene.
	void GpuDrawDebugHzb(uint16 view, CameraData camera)
	{
		if (GpuDriven.View != .Hzb || !mGpuActive || !GpuDriven.DebugHzbProgram.Valid || mGpuOcc == null || !mGpuOcc.Ready)
			return;
		let o = mGpuOcc.History(camera);
		let level = Math.Clamp(GpuDriven.DebugMip, 0, o.levels - 1);
		var w = (int)o.baseWidth;
		var h = (int)o.baseHeight;
		var start = 0;
		for (int i < level)
		{
			start += w * h;
			w = Math.Max(w / 2, 1);
			h = Math.Max(h / 2, 1);
		}
		Vector4 show = .(w, h, start, 100.0f);
		bgfx.set_uniform(GpuDriven.uHzbShow, &show, 1);
		bgfx.set_compute_dynamic_vertex_buffer(4, o.buffer, .Read, 0, uint32.MaxValue);
		SubmitFullscreen(view, GpuDriven.DebugHzbProgram, Gfx.StateWriteRGB | Gfx.StateWriteA);
	}

	/// The virtual texture a bin's albedo is, when it is one and virtual textures can be drawn.
	VirtualTexture GpuBinVt(RenderItem first)
	{
		if (!VirtualTextures.Active || !VirtualTextures.Supported)
			return null;
		return VirtualTextures.ForHandle(AlbedoTexture(first).idx);
	}

	/// The feedback pass (bgfx view 9) for the main camera: draws the virtual-textured bins into a small target so
	/// VirtualTextures can read which tiles are on screen. Runs after the culling, before the cameras' views.
	void GpuDrawVtFeedback(Matrix4 viewMatrix, Matrix4 projection, int32 width, int32 height)
	{
		if (!mGpuActive || !mGpu.HasPass(GpuDrivenView.ScenePass) || !VirtualTextures.Active)
			return;
		if (!VirtualTextures.BeginFeedback(width, height, viewMatrix, projection))
			return;
		for (int bin < mGpuBins.Count)
		{
			let first = mGpuBins[bin];
			let vt = GpuBinVt(first);
			if (vt == null)
				continue;
			for (int phase < (mGpuTwoPhase ? 2 : 1))
			{
				var uvTransform = Vector4(1, 1, 0, 0);
				if (first.material != null)
					uvTransform = .(first.material.tiling.x, first.material.tiling.y, first.material.offset.x, first.material.offset.y);
				bgfx.set_uniform(RenderResources.uUvTransform, &uvTransform, 1);
				VirtualTextures.Bind(vt);
				var matrix = projection * viewMatrix;
				var depthParams = Vector4(0, 0, 0, 0);
				bgfx.set_uniform(RenderResources.uDepthViewProj, &matrix, 1);
				bgfx.set_uniform(RenderResources.uDepthParams, &depthParams, 1);
				bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | GpuDepthCull(first), 0);
				mGpu.SubmitBin(VirtualTextures.FeedbackView, VirtualTextures.FeedbackProgram, phase == 0 ? GpuDrivenView.ScenePass : GpuDrivenView.SecondPass, bin);
			}
		}
	}

	/// Draws the scene's bins into the depth pass (and its motion vectors and colours when it makes them).
	void GpuDrawDepth(uint16 view, Matrix4 viewProj)
	{
		if (!mGpuActive || !mGpu.HasPass(GpuDrivenView.ScenePass))
			return;
		for (int bin < mGpuBins.Count)
		{
			let first = mGpuBins[bin];
			let program = mTemporalOn ? (mDepthAlbedo ? GpuDriven.DepthAlbedoVelProgram : GpuDriven.DepthVelProgram) : (mDepthAlbedo ? GpuDriven.DepthAlbedoProgram : GpuDriven.DepthProgram);
			for (int phase < (mGpuTwoPhase ? 2 : 1))
			{
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
				bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | GpuDepthCull(first), 0);
				mGpu.SubmitBin(view, program, phase == 0 ? GpuDrivenView.ScenePass : GpuDrivenView.SecondPass, bin);
				DrawCalls++;
			}
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

	/// Draws a shadow tile's casters (the pass GpuCullTile made); the caller has set the tile's matrix and scissor.
	void GpuDrawTile(uint16 view, int index)
	{
		if (!mGpu.HasPass(GpuDrivenView.TilePass + index))
			return;
		bgfx.set_uniform(RenderResources.uShadowViewProj, &mShadowPassViewProj, 1);
		if (mShadowScissor[2] > 0)
			bgfx.set_scissor((uint16)mShadowScissor[0], (uint16)mShadowScissor[1], (uint16)mShadowScissor[2], (uint16)mShadowScissor[3]);
		bgfx.set_state(Gfx.StateWriteZ | Gfx.StateDepthLess, 0);
		mGpu.SubmitBin(view, GpuDriven.ShadowProgram, GpuDrivenView.TilePass + index, 0);
		DrawCalls++;
	}
}
