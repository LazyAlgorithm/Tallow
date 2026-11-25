using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Volumetric fog (tallowengine.com/docs/day-night): fog lit by the sun, with light shafts where shadows cut it, and by
/// the scene's point and spot lights. A grid of cells over the view (froxels) is filled with the fog's density and the
/// light it scatters towards the camera (the sun's, shadowed by the cascades, the ambient sky's, and the point and spot
/// lights' by cluster with their shadow tiles), summed outwards from the camera in each column, then laid over the
/// picture at each pixel's depth from the depth pass. The distance fog (fogDensity) is off while it is on.
///
/// Passes (compute, plus a fullscreen apply): cs_vfog_inject.sc fills the cells, cs_vfog_integrate.sc sums them and
/// fs_vfog_apply.sc draws the result; the shared maths is Engine/shaders/include/vfog.sh, and the local lights' are in
/// vfog_local.sh. Vulkan, Direct3D 11/12 and Metal draw it; OpenGL and the web keep the distance fog.
///
/// The phase function, ambient term and shadow lookup follow Bevy's volumetric_fog (bevy_pbr, MIT; the notice is in
/// Engine/shaders/licenses/Bevy-LICENSE-MIT.txt); the cell grid and its sums are the published froxel method (Wronski
/// 2014, Hillaire 2015).
extension RenderView
{
	/// How many pixels of the picture one froxel cell covers (the grid is that much coarser than the screen).
	const int VFogTileSize = 16;
	/// How many cells deep the grid is (spaced exponentially from VFogNear to the scene's vfDistance).
	const int VFogSlices = 48;
	/// The nearest slice boundary, in metres in front of the camera.
	const float VFogNear = 0.5f;
	/// How far away the sky is taken to be for the fog, in metres along the view ray.
	const float VFogSkyDistance = 400;

	/// Whether this view draws volumetric fog this frame: the scene asks, the device can run it, and the camera sees it
	/// in perspective (the grid's slices are view depths).
	bool UsesVolumetricFog(CameraData camera, SceneEnvironment env)
	{
		return env.volumetricFog && env.vfDensity > 0 && !camera.orthographic && !Capture && shading == .Rendered
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

	/// Frees the grid's textures (the next frame that needs them makes them again).
	void ReleaseVolumetricTargets()
	{
		if (!Gfx.Initialized)
			return;
		if (mFogScatter.Valid)
			bgfx.destroy_texture(mFogScatter);
		if (mFogIntegrated.Valid)
			bgfx.destroy_texture(mFogIntegrated);
		mFogScatter.idx = uint16.MaxValue;
		mFogIntegrated.idx = uint16.MaxValue;
		mFogCellsX = mFogCellsY = mFogSlices = 0;
	}

	/// Makes the grid's two 3D textures (scattered light and density, then the sums), at the scene's size.
	void EnsureVolumetricTargets()
	{
		let cellsX = Math.Max((mWidth + VFogTileSize - 1) / VFogTileSize, 1);
		let cellsY = Math.Max((mHeight + VFogTileSize - 1) / VFogTileSize, 1);
		if (mFogScatter.Valid && cellsX == mFogCellsX && cellsY == mFogCellsY && VFogSlices == mFogSlices)
			return;
		ReleaseVolumetricTargets();
		let flags = Gfx.TextureComputeWrite | Gfx.SamplerClamp;
		mFogScatter = bgfx.create_texture_3d((uint16)cellsX, (uint16)cellsY, (uint16)VFogSlices, false, .RGBA16F, flags, null, 0);
		mFogIntegrated = bgfx.create_texture_3d((uint16)cellsX, (uint16)cellsY, (uint16)VFogSlices, false, .RGBA16F, flags, null, 0);
		if (!mFogScatter.Valid || !mFogIntegrated.Valid)
		{
			Log.Warning(scope $"Volumetric fog: off (could not make a {cellsX}x{cellsY}x{VFogSlices} 3D texture)");
			ReleaseVolumetricTargets();
			return;
		}
		mFogCellsX = cellsX;
		mFogCellsY = cellsY;
		mFogSlices = VFogSlices;
	}

	/// The fog's settings (SceneEnvironment) and the camera, the sun, the sky ambient and the shadow cascades, which
	/// the inject and apply shaders share.
	void SetVolumetricFogUniforms(CameraData camera, SceneEnvironment env)
	{
		Vector4 medium = .(env.vfDensity, env.vfHeight, Math.Max(env.vfFalloff, 0), Math.Clamp(env.vfAnisotropy, -0.9f, 0.9f));
		let albedo = Linear(env.vfAlbedo);
		Vector4 light = .(albedo.x, albedo.y, albedo.z, Math.Max(env.vfSunScattering, 0));
		let far = Math.Max(env.vfDistance, VFogNear * 2);
		Vector4 grid = .(VFogNear, far, mFogSlices, Math.Max(env.vfAmbient, 0));
		Vector4 size = .(mFogCellsX, mFogCellsY, VFogSkyDistance, 1);
		bgfx.set_uniform(RenderResources.uVFogMedium, &medium, 1);
		bgfx.set_uniform(RenderResources.uVFogLight, &light, 1);
		bgfx.set_uniform(RenderResources.uVFogGrid, &grid, 1);
		bgfx.set_uniform(RenderResources.uVFogSize, &size, 1);
		SetPostCamera(camera);
		SetPostUniforms();
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
	}

	/// Fills and sums the froxel grid (two compute views), after the shadow cascades are drawn and before the scene.
	void DispatchVolumetricFog(CameraData camera, SceneEnvironment env)
	{
		EnsureVolumetricTargets();
		if (!mFogScatter.Valid || !mFogIntegrated.Valid)
			return;
		let injectView = (uint16)(ViewBase + VFogInjectView);
		let integrateView = (uint16)(ViewBase + VFogIntegrateView);
		let injectName = "Volumetric fog inject";
		let integrateName = "Volumetric fog integrate";
		bgfx.set_view_name(injectView, injectName.Ptr, (int32)injectName.Length);
		bgfx.set_view_name(integrateView, integrateName.Ptr, (int32)integrateName.Length);
		bgfx.set_view_mode(injectView, .Sequential);
		bgfx.set_view_mode(integrateView, .Sequential);

		SetVolumetricFogUniforms(camera, env);
		bgfx.set_image(0, mFogScatter, 0, .Write, .RGBA16F);
		// The cascades as plain depths (the compute shader compares itself): the atlas is a comparison sampler for the
		// lit pass, but a normal sample still reads the stored depth.
		bgfx.set_texture(1, RenderResources.sShadowMap, RenderResources.ShadowMap, uint32.MaxValue);
		// The view's point and spot lights and their shadow tiles, read the same way (vfog_local.sh).
		bgfx.set_texture(2, RenderResources.sLightData, mLights.Texture, uint32.MaxValue);
		bgfx.set_texture(3, RenderResources.sLocalShadowMap, RenderResources.LocalShadowTexture, uint32.MaxValue);
		bgfx.dispatch(injectView, RenderResources.VFogInjectProgram, (uint32)((mFogCellsX + 3) / 4), (uint32)((mFogCellsY + 3) / 4), (uint32)((mFogSlices + 3) / 4), 0xff);

		SetVolumetricFogUniforms(camera, env);
		bgfx.set_image(0, mFogScatter, 0, .Read, .RGBA16F);
		bgfx.set_image(1, mFogIntegrated, 0, .Write, .RGBA16F);
		bgfx.dispatch(integrateView, RenderResources.VFogIntegrateProgram, (uint32)((mFogCellsX + 7) / 8), (uint32)((mFogCellsY + 7) / 8), 1, 0xff);
	}

	/// Lays the summed fog over the solid scene and the sky (after the decals, before the water), at each pixel's depth
	/// from the depth pass.
	void ApplyVolumetricFog(CameraData camera, SceneEnvironment env)
	{
		VolumetricFogDrawn = false;
		if (!mFogIntegrated.Valid)
			return;
		EnsureDepthPass(camera);
		SetVolumetricFogUniforms(camera, env);
		let view = (uint16)(ViewBase + VFogApplyView);
		let name = "Volumetric fog apply";
		SetUpView(view, name, mSceneFb, 0, 0, mWidth, mHeight);
		bgfx.set_view_mode(view, .Sequential);
		bgfx.set_texture(0, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sVFog, mFogIntegrated, uint32.MaxValue);
		// picture x transmittance + scattered light.
		SubmitFullscreen(view, RenderResources.VFogApplyProgram, Gfx.StateWriteRGB | Gfx.StateBlendOneSrcAlpha);
		VolumetricFogDrawn = true;
	}
}
