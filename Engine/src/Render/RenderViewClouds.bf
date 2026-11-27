using System;
using Bgfx;

namespace Tallow;

/// Volumetric clouds (C2, tallowengine.com/docs/clouds): the cloud slab between the scene's `cloudHeight` and
/// `cloudHeight + cloudThickness` is raymarched per pixel of a half-resolution target (cs_clouds.sc, the density model
/// in include/clouds.sh), and the sky shader composites the result over the sky and its bodies. The pass shares the
/// camera's fog-inject compute view (all 28 per-camera views are taken), submitted before the fog's own inject.
///
/// Vulkan, Direct3D 11/12 and Metal run it; OpenGL, the web and `--gpu-driven-caps-off` fall back to the 2D layer,
/// as does a scene in 2D mode or a coverage of 0 (which draws the sky exactly as clouds off). Lighting here is the
/// placeholder C2a uses; C2b adds self-shadowing, the Henyey-Greenstein phase, powder and multiple scattering.
extension RenderView
{
	/// Raymarch steps through the slab (the quality setting in C3a; 48 is High).
	public static int32 CloudSteps = 48;
	/// Steps of the march towards the sun for self-shadowing (C2b).
	public static int32 CloudShadowSteps = 4;
	/// The pixels the last cloud pass marched (0 when it did not run).
	public static int32 VolumetricCloudPixels { get; private set; }

	/// The cloud target this frame drew, or an invalid handle (the sky then draws the 2D layer).
	bgfx.TextureHandle mCloudTexture = .() { idx = uint16.MaxValue };
	int32 mCloudWidth, mCloudHeight;
	Vector4 mCloudSize, mCloudSteps;
	/// Whether this view raymarches its clouds this frame (the check the sky draws ask).
	bool mCloudsActive;

	/// Whether the volumetric path can run here: Vulkan, Direct3D 11/12 or Metal, with compute shaders and cs_clouds
	/// built for that backend. OpenGL and the web draw the 2D layer instead.
	static bool VolumetricCloudsSupported()
	{
		if (GpuDriven.ForceUnavailable || !Compute.Supported || !RenderResources.CloudsReady)
			return false;
		switch (bgfx.get_renderer_type())
		{
		case .Vulkan, .Metal, .Direct3D11, .Direct3D12:
			return true;
		default:
			return false;
		}
	}

	/// Whether the volumetric path may run in this view at all (what the test checks before it expects a raymarch).
	public static bool CloudsRunnable => VolumetricCloudsSupported();

	/// Whether this view raymarches its clouds this frame: the scene asks for volumetric clouds with some cover and
	/// density, a Physical or Custom sky draws them, and the device can.
	bool UsesVolumetricClouds(CameraData camera, SceneEnvironment env)
	{
		return env.clouds && env.cloudMode == .Volumetric && env.cloudCoverage > 0 && env.cloudDensity > 0
			&& env.skyMode != .Gradient && !camera.orthographic && !Capture && shading == .Rendered
			&& VolumetricCloudsSupported();
	}

	void ReleaseCloudTargets()
	{
		if (!Gfx.Initialized)
			return;
		if (mCloudTexture.Valid)
			bgfx.destroy_texture(mCloudTexture);
		mCloudTexture.idx = uint16.MaxValue;
		mCloudWidth = mCloudHeight = 0;
		mCloudsActive = false;
		VolumetricCloudPixels = 0;
	}

	/// Makes the cloud target (the scene's cloudResolution share of the picture, at least 16 px a side) if its size
	/// changed.
	void EnsureCloudTargets(SceneEnvironment env)
	{
		let scale = Math.Clamp(env.cloudResolution, 0.25f, 1.0f);
		let width = Math.Max((int32)(mWidth * scale + 0.5f), 16);
		let height = Math.Max((int32)(mHeight * scale + 0.5f), 16);
		if (mCloudTexture.Valid && width == mCloudWidth && height == mCloudHeight)
			return;
		ReleaseCloudTargets();
		mCloudTexture = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA16F, Gfx.TextureComputeWrite | Gfx.SamplerClamp, null, 0);
		if (!mCloudTexture.Valid)
		{
			Log.Warning(scope $"Volumetric clouds: off (could not make a {width}x{height} target)");
			return;
		}
		mCloudWidth = width;
		mCloudHeight = height;
	}

	/// Marches the slab into the cloud target (see cs_clouds.sc): the camera's ray per pixel, the shared cloud block
	/// (PhysicalSky's uniforms, the same the sky draw uses), the steps and the frame's jitter. Submitted in the
	/// fog-inject view, before the fog's inject (bgfx runs a view's dispatches in submission order).
	void DispatchClouds(Scene scene, CameraData camera, SceneEnvironment env)
	{
		EnsureCloudTargets(env);
		if (!mCloudTexture.Valid)
		{
			mCloudsActive = false;
			return;
		}
		// The cloud block and the sun/moon colours exactly as the sky's draw will set them.
		PhysicalSky.SetUniforms(scene, env, mSunDir, mSunColor);
		SetPostCamera(camera);
		SetPostUniforms();
		mCloudSteps = .(Math.Max(CloudSteps, 1), Math.Max(CloudShadowSteps, 0), (float)(Time.FrameCount % 1024), 0);
		mCloudSize = .(mCloudWidth, mCloudHeight, 0, 0);
		bgfx.set_uniform(RenderResources.uCloudSteps, &mCloudSteps, 1);
		bgfx.set_uniform(RenderResources.uCloudSize, &mCloudSize, 1);
		let view = (uint16)(ViewBase + VFogInjectView);
		let name = "Volumetric clouds";
		bgfx.set_view_name(view, name.Ptr, (int32)name.Length);
		bgfx.set_view_mode(view, .Sequential);
		bgfx.set_image(0, mCloudTexture, 0, .Write, .RGBA16F);
		bgfx.dispatch(view, RenderResources.CloudsProgram, (uint32)((mCloudWidth + 7) / 8), (uint32)((mCloudHeight + 7) / 8), 1, 0xff);
		VolumetricCloudPixels = mCloudWidth * mCloudHeight;
	}

	/// Binds the raymarched layer for the main camera's sky draw (a no-op with the 2D fallback, which SetUniforms
	/// already set up).
	void BindCloudSky()
	{
		if (mCloudsActive)
			PhysicalSky.BindCloudLayer(mCloudTexture, true);
	}
}
