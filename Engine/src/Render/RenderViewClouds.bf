using System;
using Bgfx;

namespace Tallow;

/// Volumetric clouds (C2, tallowengine.com/docs/clouds): the cloud slab between the scene's `cloudHeight` and
/// `cloudHeight + cloudThickness` is raymarched per pixel of a half-resolution target (cs_clouds.sc, the density model
/// in include/clouds.sh), and the sky shader composites the result over the sky and its bodies. The pass shares the
/// camera's fog-inject compute view (all 28 per-camera views are taken), submitted before the fog's own inject.
///
/// Vulkan, Direct3D 11/12 and Metal run it; OpenGL, the web and `--gpu-driven-caps-off` fall back to the 2D layer,
/// as does a scene in 2D mode or a coverage of 0 (which draws the sky exactly as clouds off). The lighting (C2b) is
/// self-shadowing by an optical depth towards the sun (or the moon at night), a two-lobe Henyey-Greenstein phase, the
/// powder term, a near-isotropic multiple-scattering term and the desaturated sky/ground ambient (include/clouds.sh).
///
/// Renderer integration (C2d): the sky pass draws everything before the solid scene (depth LEQUAL), so terrain and
/// buildings hide the clouds with no extra work, and `skyColor` composites the layer over the sun, moon and stars, so a
/// thick cloud hides them. The reflection cube, reflection-probe captures and planar views keep the 2D layer (their
/// `u_cloudView.w` is 0), so reflections have cloud cover without a second march; the Custom skybox's Skybox Blend
/// path samples this screen layer. `--gpu-driven-caps-off` turns the pass off (`CloudsRunnable` false) and the sky
/// draws the 2D backup instead.
///
/// Temporal and performance (C2c): two targets swap each frame. The march's start is jittered by a 32x32 blue-noise
/// tile that shifts by a low-discrepancy offset every frame, and the finished layer is blended with last frame's layer
/// reprojected by the slab's midpoint (minus the wind that carried the weather) into last frame's view-projection, as
/// the fog's cells are (RenderViewVolumetric.bf). The history is dropped on a camera cut (over 5 m or 30 degrees a
/// frame), a skipped frame, a resize and when the quality setting turns it off; with TAA on it keeps less of it (0.6
/// against 0.85), since the engine's own history is a second filter that would ghost over it. The step count, the
/// resolution and the distance are the quality setting's (Quality.Apply).
extension RenderView
{
	/// Raymarch steps through the slab (the quality setting in Quality.bf; 48 is High).
	public static int32 CloudSteps = 48;
	/// Steps of the march towards the sun for self-shadowing (C2b; the quality setting).
	public static int32 CloudShadowSteps = 4;
	/// Whether the quality setting allows the volumetric path at all (Low draws the 2D backup).
	public static bool CloudsAllowed = true;
	/// Whether frames blend with last frame's layer (the quality setting).
	public static bool CloudTemporalAllowed = true;
	/// The largest share of the picture's resolution the scene may ask for (the quality setting).
	public static float CloudMaxResolution = 0.75f;
	/// The farthest the march goes, in metres (the quality setting; the scene's cloudDistance is capped by it).
	public static float CloudMaxDistance = 12000;
	/// How far the camera may move in a frame and still reuse last frame's layer: further is a cut.
	const float CloudHistoryCut = 5.0f;
	/// How far the camera may turn in a frame and still reuse last frame's layer: about 30 degrees, then a cut.
	const float CloudHistoryCos = 0.8660254f;
	/// The pixels the last cloud pass marched, and the rays it cast (pixels x the step budget); 0 when it did not run.
	public static int32 VolumetricCloudPixels { get; private set; }
	public static int32 VolumetricCloudRays { get; private set; }

	/// The two cloud targets (this frame's and last frame's), which swap each frame: the history is read by the temporal
	/// blend as a sampler. mCloudIndex is the target this frame drew (what the sky samples).
	bgfx.TextureHandle[2] mCloudTextures = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	int mCloudIndex = 1;
	int32 mCloudWidth, mCloudHeight;
	Vector4 mCloudSize, mCloudSteps, mCloudWindDelta, mCloudDebug;
	/// Last frame's camera and weather (the reprojection), its world offset and whether it may be reused this frame.
	Matrix4 mCloudLastViewProj, mCloudPrevViewProj;
	Vector3 mCloudLastEye, mCloudLastForward;
	Vector2 mCloudLastWind;
	int64 mCloudLastFrame = -1000;
	bool mCloudHistoryValid;
	/// Whether this view raymarches its clouds this frame (the check the sky draws ask).
	bool mCloudsActive;

	/// Whether last frame's cloud layer was blended into this frame's (what `--cloud-test temporal` checks: false on a
	/// camera cut means no ghost).
	public bool CloudHistoryValid => mCloudHistoryValid;

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
	/// density, the quality setting allows it, a Physical or Custom sky draws them, and the device can.
	bool UsesVolumetricClouds(CameraData camera, SceneEnvironment env)
	{
		return CloudsAllowed && env.clouds && env.cloudMode == .Volumetric && env.cloudCoverage > 0 && env.cloudDensity > 0
			&& env.skyMode != .Gradient && !camera.orthographic && !Capture && shading == .Rendered
			&& VolumetricCloudsSupported();
	}

	/// Drops the temporal history (a frame the pass did not run, or the test's cut check).
	void InvalidateCloudHistory()
	{
		mCloudHistoryValid = false;
		mCloudLastFrame = -1000;
		VolumetricCloudPixels = 0;
		VolumetricCloudRays = 0;
	}

	void ReleaseCloudTargets()
	{
		if (!Gfx.Initialized)
			return;
		for (int i < 2)
		{
			if (mCloudTextures[i].Valid)
				bgfx.destroy_texture(mCloudTextures[i]);
			mCloudTextures[i].idx = uint16.MaxValue;
		}
		mCloudWidth = mCloudHeight = 0;
		mCloudIndex = 1;
		mCloudsActive = false;
		InvalidateCloudHistory();
	}

	/// Makes the two cloud targets (the scene's cloudResolution share of the picture, capped by the quality setting,
	/// at least 16 px a side) if their size changed. A new size drops the history.
	void EnsureCloudTargets(SceneEnvironment env)
	{
		let scale = Math.Clamp(Math.Min(env.cloudResolution, CloudMaxResolution), 0.25f, 1.0f);
		let width = Math.Max((int32)(mWidth * scale + 0.5f), 16);
		let height = Math.Max((int32)(mHeight * scale + 0.5f), 16);
		if (mCloudTextures[0].Valid && mCloudTextures[1].Valid && width == mCloudWidth && height == mCloudHeight)
			return;
		ReleaseCloudTargets();
		for (int i < 2)
			mCloudTextures[i] = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA16F, Gfx.TextureComputeWrite | Gfx.SamplerClamp, null, 0);
		if (!mCloudTextures[0].Valid || !mCloudTextures[1].Valid)
		{
			Log.Warning(scope $"Volumetric clouds: off (could not make a {width}x{height} target)");
			ReleaseCloudTargets();
			return;
		}
		mCloudWidth = width;
		mCloudHeight = height;
	}

	/// Marches the slab into this frame's cloud target (see cs_clouds.sc): the camera's ray per pixel, the shared cloud
	/// block (PhysicalSky's uniforms, the same the sky draw uses), the steps and the frame's blue-noise jitter, then the
	/// temporal blend with last frame's target. Submitted in the fog-inject view, before the fog's inject (bgfx runs a
	/// view's dispatches in submission order).
	void DispatchClouds(Scene scene, CameraData camera, SceneEnvironment env)
	{
		EnsureCloudTargets(env);
		if (!mCloudTextures[0].Valid || !mCloudTextures[1].Valid)
		{
			mCloudsActive = false;
			InvalidateCloudHistory();
			return;
		}
		// The cloud block and the sun/moon colours exactly as the sky's draw will set them.
		PhysicalSky.SetUniforms(scene, env, mSunDir, mSunColor);
		SetPostCamera(camera);
		SetPostUniforms();
		let frame = Time.FrameCount;
		let viewProj = camera.projection * camera.view;
		let forward = Vector3(camera.view.m[2], camera.view.m[6], camera.view.m[10]);
		let wind = Clouds.Offset(env, Clouds.Seconds(scene));
		let debug = GpuDriven.View == .Clouds;
		// Last frame's layer is reused only when this frame follows it directly, the camera stayed put and faced the
		// same way, the quality setting allows the blend (mirroring the fog's mFogHistoryValid) and the debug view is
		// off (its density/light values are not a layer, and would smear into the history).
		mCloudHistoryValid = CloudTemporalAllowed && !debug && mCloudLastFrame == frame - 1
			&& (camera.position - mCloudLastEye).Length < CloudHistoryCut
			&& Vector3.Dot(forward, mCloudLastForward) > CloudHistoryCos;
		mCloudPrevViewProj = mCloudLastViewProj;
		let keep = mCloudHistoryValid ? (mTaaOn ? 0.6f : 0.85f) : 0.0f;
		var windDelta = Vector2.Zero;
		if (mCloudHistoryValid)
			windDelta = wind - mCloudLastWind;
		mCloudSteps = .(Math.Max(CloudSteps, 1), Math.Max(CloudShadowSteps, 0), (float)(frame % 1024), keep);
		mCloudWindDelta = .(windDelta.x, windDelta.y, 0, 0);
		mCloudDebug = .(debug ? 1 : 0, 0, 0, 0);
		mCloudSize = .(mCloudWidth, mCloudHeight, 0, 0);
		bgfx.set_uniform(RenderResources.uCloudSteps, &mCloudSteps, 1);
		bgfx.set_uniform(RenderResources.uCloudSize, &mCloudSize, 1);
		bgfx.set_uniform(RenderResources.uCloudPrevViewProj, &mCloudPrevViewProj, 1);
		bgfx.set_uniform(RenderResources.uCloudWindDelta, &mCloudWindDelta, 1);
		bgfx.set_uniform(RenderResources.uCloudDebug, &mCloudDebug, 1);
		// This frame's target is written while last frame's is read as the history, then they swap.
		let write = 1 - mCloudIndex;
		let read = mCloudIndex;
		let view = (uint16)(ViewBase + VFogInjectView);
		let name = "Volumetric clouds";
		bgfx.set_view_name(view, name.Ptr, (int32)name.Length);
		bgfx.set_view_mode(view, .Sequential);
		bgfx.set_image(0, mCloudTextures[write], 0, .Write, .RGBA16F);
		bgfx.set_texture(4, RenderResources.sCloudNoise, RenderResources.BlueNoise, uint32.MaxValue);
		bgfx.set_texture(5, RenderResources.sCloudHistory, mCloudTextures[read], uint32.MaxValue);
		bgfx.dispatch(view, RenderResources.CloudsProgram, (uint32)((mCloudWidth + 7) / 8), (uint32)((mCloudHeight + 7) / 8), 1, 0xff);
		mCloudIndex = write;
		mCloudLastViewProj = viewProj;
		mCloudLastEye = camera.position;
		mCloudLastForward = forward;
		mCloudLastWind = wind;
		mCloudLastFrame = frame;
		VolumetricCloudPixels = mCloudWidth * mCloudHeight;
		VolumetricCloudRays = VolumetricCloudPixels * Math.Max(CloudSteps, 1);
	}

	/// Binds the raymarched layer for the main camera's sky draw (a no-op with the 2D fallback, which SetUniforms
	/// already set up).
	void BindCloudSky()
	{
		if (mCloudsActive && mCloudTextures[mCloudIndex].Valid)
			PhysicalSky.BindCloudLayer(mCloudTextures[mCloudIndex], true);
	}
}
