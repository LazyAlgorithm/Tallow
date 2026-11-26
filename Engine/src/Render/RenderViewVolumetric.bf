using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Volumetric fog (tallowengine.com/docs/day-night): fog lit by the sun, with light shafts where shadows cut it, and by
/// the scene's point and spot lights. A grid of cells over the view (froxels) is filled with the fog's density and the
/// light it scatters towards the camera (the sun's, shadowed by the cascades, the ambient sky's, and the point and spot
/// lights' by cluster with their shadow tiles), summed outwards from the camera in each column, then laid over the
/// picture at each pixel's depth from the depth pass. The distance fog (fogDensity) is off while it is on. Fog Volumes
/// (FogVolume) add their own denser or coloured fog to the cells they cover. Each frame samples the cells at a
/// different depth within their slices and blends the result with last frame's cells (found again by reprojection),
/// which averages the banding between slices away.
///
/// Passes (compute, plus a fullscreen apply): cs_vfog_inject.sc fills the cells (and blends in the reprojected
/// history), cs_vfog_integrate.sc sums them, fs_vfog_apply.sc draws the result. See-through things and the water,
/// which are drawn after the apply, ask the same sums for their own depths in their shaders (the TW_VFOG variants of
/// fs_mesh and fs_water); the shared maths is Engine/shaders/include/vfog.sh, and the local lights' is in
/// vfog_local.sh. Vulkan, Direct3D 11/12 and Metal draw it; OpenGL and the web keep the distance fog.
///
/// The phase function, ambient term and shadow lookup follow Bevy's volumetric_fog (bevy_pbr, MIT; the notice is in
/// Engine/shaders/licenses/Bevy-LICENSE-MIT.txt); the cell grid, its sums and the reprojection are the published froxel
/// method (Wronski 2014, Hillaire 2015).
extension RenderView
{
	/// How many pixels of the picture one froxel cell covers (the grid is that much coarser than the screen).
	const int32 VFogTileSize = 16;
	/// How many cells deep the grid is (spaced exponentially from VFogNear to the scene's vfDistance).
	const int32 VFogSlices = 48;
	/// The nearest slice boundary, in metres in front of the camera.
	const float VFogNear = 0.5f;
	/// How far away the sky is taken to be for the fog, in metres along the view ray.
	const float VFogSkyDistance = 400;
	/// How much of last frame's cells the temporal blend keeps: 0.9 smooths the jitter's banding away without a visible
	/// trail behind a moving camera.
	const float VFogHistoryBlend = 0.9f;
	/// How far the camera may move between frames and still reuse last frame's cells: further is a cut.
	const float VFogHistoryCut = 5.0f;

	/// The Fog Volumes the fog takes density and colour from this frame.
	List<FogVolume> mFogVolumes = new .() ~ delete _;
	int32 mFogVolumeCount;
	/// Each volume's rows of its world-to-local matrix, its edge fade and density, and its colour and shape
	/// (RenderResources.FogVolumeMax volumes of vfog.sh's five vectors).
	Vector4[RenderResources.FogVolumeMax * 5] mFogVolumeData;
	Vector4 mFogMedium, mFogLight, mFogGrid, mFogSize, mFogTemporal;
	/// Last frame's camera and its projection, for reprojecting this frame's cells into last frame's grid.
	Matrix4 mFogLastViewProj, mFogPrevViewProj;
	Vector3 mFogLastEye;
	int64 mFogLastFrame = -1000;
	bool mFogHistoryValid;

	/// Whether this view draws volumetric fog this frame: the scene asks (the height fog or a Fog Volume has fog in
	/// it), the device can run it, and the camera sees it in perspective (the grid's slices are view depths).
	bool UsesVolumetricFog(CameraData camera, SceneEnvironment env)
	{
		return env.volumetricFog && (env.vfDensity > 0 || mFogVolumeCount > 0) && !camera.orthographic && !Capture && shading == .Rendered
			&& VolumetricFogSupported();
	}

	/// Whether volumetric fog can run here at all: Vulkan, Direct3D 11/12 or Metal, with compute shaders and the fog
	/// shaders built for that backend. OpenGL and the web draw the distance fog instead.
	static bool VolumetricFogSupported()
	{
		if (!Compute.Supported || !RenderResources.VFogReady)
			return false;
		switch (bgfx.get_renderer_type())
		{
		case .Vulkan, .Metal, .Direct3D11, .Direct3D12:
			return true;
		default:
			return false;
		}
	}

	/// The Fog Volumes in view, into uniforms: at most RenderResources.FogVolumeMax of them, in the order Flecs gives
	/// (the fog sums them all, so their order does not matter).
	void GatherFogVolumes(Scene scene, CameraData camera, Frustum frustum, SceneEnvironment env)
	{
		mFogVolumeCount = 0;
		if (!env.volumetricFog)
			return;
		mFogVolumes.Clear();
		scene.Components(mFogVolumes);
		for (let volume in mFogVolumes)
		{
			if (!volume.GameObject.ActiveInHierarchy || !volume.GameObject.InActiveWorld || HidesHere(volume.GameObject))
				continue;
			let area = volume.WorldBounds;
			if (!frustum.Intersects(area))
				continue;
			let reach = (area.max - area.min).Length * 0.5f;
			// Past the grid's far end the fog is plain height fog, which knows no volumes: leave it out.
			if ((area.Center - camera.position).Length - reach > env.vfDistance)
				continue;
			if (mFogVolumeCount >= RenderResources.FogVolumeMax)
				break;
			let toLocal = volume.ToLocal;
			let color = Linear(volume.color);
			let at = mFogVolumeCount * 5;
			mFogVolumeData[at] = .(toLocal.m[0], toLocal.m[4], toLocal.m[8], toLocal.m[12]);
			mFogVolumeData[at + 1] = .(toLocal.m[1], toLocal.m[5], toLocal.m[9], toLocal.m[13]);
			mFogVolumeData[at + 2] = .(toLocal.m[2], toLocal.m[6], toLocal.m[10], toLocal.m[14]);
			mFogVolumeData[at + 3] = .(Math.Clamp(volume.edgeFade, 0, 1), Math.Max(volume.density, 0), 0, 0);
			mFogVolumeData[at + 4] = .(color.x, color.y, color.z, volume.shape == .Sphere ? 1 : 0);
			mFogVolumeCount++;
		}
	}

	/// Frees the grid's textures (the next frame that needs them makes them again).
	void ReleaseVolumetricTargets()
	{
		if (!Gfx.Initialized)
			return;
		for (int i < 2)
		{
			if (mFogScatter[i].Valid)
				bgfx.destroy_texture(mFogScatter[i]);
			mFogScatter[i].idx = uint16.MaxValue;
		}
		if (mFogIntegrated.Valid)
			bgfx.destroy_texture(mFogIntegrated);
		mFogIntegrated.idx = uint16.MaxValue;
		mFogSums.idx = uint16.MaxValue;
		mFogCellsX = mFogCellsY = mFogSlices = 0;
		mFogHistoryValid = false;
		mFogLastFrame = -1000;
	}

	/// Makes the grid's 3D textures (the cells' light and density, this frame and last, then their sums), at the
	/// scene's size.
	void EnsureVolumetricTargets()
	{
		let cellsX = Math.Max((mWidth + VFogTileSize - 1) / VFogTileSize, 1);
		let cellsY = Math.Max((mHeight + VFogTileSize - 1) / VFogTileSize, 1);
		if (mFogScatter[0].Valid && mFogIntegrated.Valid && cellsX == mFogCellsX && cellsY == mFogCellsY && VFogSlices == mFogSlices)
			return;
		ReleaseVolumetricTargets();
		let flags = Gfx.TextureComputeWrite | Gfx.SamplerClamp;
		for (int i < 2)
			mFogScatter[i] = bgfx.create_texture_3d((uint16)cellsX, (uint16)cellsY, (uint16)VFogSlices, false, .RGBA16F, flags, null, 0);
		mFogIntegrated = bgfx.create_texture_3d((uint16)cellsX, (uint16)cellsY, (uint16)VFogSlices, false, .RGBA16F, flags, null, 0);
		if (!mFogScatter[0].Valid || !mFogScatter[1].Valid || !mFogIntegrated.Valid)
		{
			Log.Warning(scope $"Volumetric fog: off (could not make a {cellsX}x{cellsY}x{VFogSlices} 3D texture)");
			ReleaseVolumetricTargets();
			return;
		}
		mFogCellsX = cellsX;
		mFogCellsY = cellsY;
		mFogSlices = VFogSlices;
		mFogScatterIndex = 0;
	}

	/// The fog's settings (SceneEnvironment) and the camera, the sun, the sky ambient and the shadow cascades, which
	/// the inject and apply shaders share.
	void SetVolumetricFogUniforms(CameraData camera, SceneEnvironment env)
	{
		mFogMedium = .(env.vfDensity, env.vfHeight, Math.Max(env.vfFalloff, 0), Math.Clamp(env.vfAnisotropy, -0.9f, 0.9f));
		let albedo = Linear(env.vfAlbedo);
		mFogLight = .(albedo.x, albedo.y, albedo.z, Math.Max(env.vfSunScattering, 0));
		let far = Math.Max(env.vfDistance, VFogNear * 2);
		mFogGrid = .(VFogNear, far, mFogSlices, Math.Max(env.vfAmbient, 0));
		mFogSize = .(mFogCellsX, mFogCellsY, VFogSkyDistance, 1);
		SetPostCamera(camera);
		ResendVolumetricFogSampling();
		bgfx.set_uniform(RenderResources.uSunDir, &mSunDir, 1);
		bgfx.set_uniform(RenderResources.uSunColor, &mSunColor, 1);
		bgfx.set_uniform(RenderResources.uAmbientSky, &mAmbientSky, 1);
		bgfx.set_uniform(RenderResources.uShadowMtx, &mShadowMtx, RenderResources.CascadeCount);
		bgfx.set_uniform(RenderResources.uCascadeSplits, &mCascadeSplits, 1);
		bgfx.set_uniform(RenderResources.uShadowParams, &mShadowParams, 1);
		// The view's lights and the clusters their lists were sorted into (the point and spot lights' scattering).
		bgfx.set_uniform(RenderResources.uLightCount, &mLightCount, 1);
		bgfx.set_uniform(RenderResources.uClusterViewProj, &mClusterViewProj, 1);
		bgfx.set_uniform(RenderResources.uClusterForward, &mClusterForward, 1);
		bgfx.set_uniform(RenderResources.uClusterParams, &mClusterParams, 1);
		// The Fog Volumes, the temporal blend and last frame's camera.
		if (mFogVolumeCount > 0)
			bgfx.set_uniform(RenderResources.uFogVolumes, &mFogVolumeData[0], (uint16)(mFogVolumeCount * 5));
		Vector4 volumeCount = .(mFogVolumeCount, 0, 0, 0);
		bgfx.set_uniform(RenderResources.uFogVolumeCount, &volumeCount, 1);
		bgfx.set_uniform(RenderResources.uVFogTemporal, &mFogTemporal, 1);
		bgfx.set_uniform(RenderResources.uVFogPrevViewProj, &mFogPrevViewProj, 1);
	}

	/// The fog's own settings and the camera, for the see-through things and the water, which sample the sums
	/// themselves instead of being laid over by the apply pass (bgfx clears a draw's uniforms after it is submitted).
	void ResendVolumetricFogSampling()
	{
		bgfx.set_uniform(RenderResources.uVFogMedium, &mFogMedium, 1);
		bgfx.set_uniform(RenderResources.uVFogLight, &mFogLight, 1);
		bgfx.set_uniform(RenderResources.uVFogGrid, &mFogGrid, 1);
		bgfx.set_uniform(RenderResources.uVFogSize, &mFogSize, 1);
		SetPostUniforms();
	}

	/// Fills and sums the froxel grid (two compute views), after the shadow cascades are drawn and before the scene.
	void DispatchVolumetricFog(CameraData camera, SceneEnvironment env)
	{
		EnsureVolumetricTargets();
		if (!mFogScatter[0].Valid || !mFogScatter[1].Valid || !mFogIntegrated.Valid)
			return;
		// The temporal blend reads last frame's cells when the camera is where it was last frame (and the grid is the
		// same size); each frame samples the cells at a different depth so that averaging them smooths the banding.
		let frame = Time.FrameCount;
		let viewProj = camera.projection * camera.view;
		mFogHistoryValid = FogTemporalEnabled && mFogLastFrame == frame - 1 && (camera.position - mFogLastEye).Length < VFogHistoryCut;
		mFogPrevViewProj = mFogLastViewProj;
		let jitter = mFogHistoryValid ? Halton((int32)(frame % 8) + 1, 2) : 0.5f;
		mFogTemporal = .(jitter, mFogHistoryValid ? VFogHistoryBlend : 0, mFogHistoryValid ? 1 : 0, 0);

		// This frame's cells are written while last frame's are read, then they swap.
		let write = mFogScatter[mFogScatterIndex];
		let read = mFogScatter[1 - mFogScatterIndex];
		let injectView = (uint16)(ViewBase + VFogInjectView);
		let integrateView = (uint16)(ViewBase + VFogIntegrateView);
		let injectName = "Volumetric fog inject";
		let integrateName = "Volumetric fog integrate";
		bgfx.set_view_name(injectView, injectName.Ptr, (int32)injectName.Length);
		bgfx.set_view_name(integrateView, integrateName.Ptr, (int32)integrateName.Length);
		bgfx.set_view_mode(injectView, .Sequential);
		bgfx.set_view_mode(integrateView, .Sequential);

		SetVolumetricFogUniforms(camera, env);
		bgfx.set_image(0, write, 0, .Write, .RGBA16F);
		bgfx.set_image(4, read, 0, .Read, .RGBA16F);
		// The cascades as plain depths (the compute shader compares itself): the atlas is a comparison sampler for the
		// lit pass, but a normal sample still reads the stored depth.
		bgfx.set_texture(1, RenderResources.sShadowMap, RenderResources.ShadowMap, uint32.MaxValue);
		// The view's point and spot lights and their shadow tiles, read the same way (vfog_local.sh).
		bgfx.set_texture(2, RenderResources.sLightData, mLights.Texture, uint32.MaxValue);
		bgfx.set_texture(3, RenderResources.sLocalShadowMap, RenderResources.LocalShadowTexture, uint32.MaxValue);
		bgfx.dispatch(injectView, RenderResources.VFogInjectProgram, (uint32)((mFogCellsX + 3) / 4), (uint32)((mFogCellsY + 3) / 4), (uint32)((mFogSlices + 3) / 4), 0xff);

		SetVolumetricFogUniforms(camera, env);
		bgfx.set_image(0, write, 0, .Read, .RGBA16F);
		bgfx.set_image(1, mFogIntegrated, 0, .Write, .RGBA16F);
		bgfx.dispatch(integrateView, RenderResources.VFogIntegrateProgram, (uint32)((mFogCellsX + 7) / 8), (uint32)((mFogCellsY + 7) / 8), 1, 0xff);

		// This frame's cells and sums are what the apply and the see-through things read; next frame the other cells
		// are written while these are read as the history.
		mFogScatterIndex = 1 - mFogScatterIndex;
		mFogSums = mFogIntegrated;
		mFogLastViewProj = viewProj;
		mFogLastEye = camera.position;
		mFogLastFrame = frame;
	}

	/// Lays the summed fog over the solid scene and the sky (after the decals, before the water), at each pixel's depth
	/// from the depth pass.
	void ApplyVolumetricFog(CameraData camera, SceneEnvironment env)
	{
		VolumetricFogDrawn = false;
		if (!mFogSums.Valid)
			return;
		EnsureDepthPass(camera);
		SetVolumetricFogUniforms(camera, env);
		let view = (uint16)(ViewBase + VFogApplyView);
		let name = "Volumetric fog apply";
		SetUpView(view, name, mSceneFb, 0, 0, mWidth, mHeight);
		bgfx.set_view_mode(view, .Sequential);
		bgfx.set_texture(0, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sVFog, mFogSums, uint32.MaxValue);
		// picture x transmittance + scattered light.
		SubmitFullscreen(view, RenderResources.VFogApplyProgram, Gfx.StateWriteRGB | Gfx.StateBlendOneSrcAlpha);
		VolumetricFogDrawn = true;
	}

	/// A see-through thing drawn after the apply: its own fog (TW_VFOG) at its own depth instead of the apply's at the
	/// depth behind it. Returns false when the sums are not there, to draw it the ordinary way.
	bool BindVolumetricFogSampling()
	{
		if (!mVolumetricFogActive || !mFogSums.Valid)
			return false;
		ResendVolumetricFogSampling();
		bgfx.set_texture(10, RenderResources.sVFog, mFogSums, uint32.MaxValue);
		return true;
	}
}
