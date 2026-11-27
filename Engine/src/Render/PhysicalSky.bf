// The physical sky's tables follow Bevy's atmosphere (MIT licence, Engine/shaders/licenses/Bevy-LICENSE-MIT.txt).
using System;
using Bgfx;

namespace Tallow;

/// The physical sky (SkyMode.Physical; tallowengine.com/docs/day-night). Three small tables are drawn on the GPU
/// (shaders fs_atmo_*.sc): how much light gets through the air (transmittance), light scattered many times
/// (multiple scattering), and the sky in every direction from the camera (sky-view). Drawn again only when the sun
/// moves more than a little, the camera climbs, or the haze or quality changes. Where half-float targets are missing,
/// or on OpenGL / GLES / WebGL, the sky is the analytic Preetham sky from the same settings instead.
static class PhysicalSky
{
	/// The bgfx views the tables are drawn in (after the cameras: a new table is seen one frame later).
	public const uint16 TransmittanceView = 227;
	public const uint16 MultiscatterView = 228;
	public const uint16 SkyViewView = 229;

	/// The sky's detail (Quality.skyQuality): 0 to 2.
	public static int32 Quality = 1;
	/// Use the Preetham sky even where the tables could be drawn (--sky-preetham).
	public static bool ForcePreetham;
	/// Goes up each time a new sky-view table is ready to be read (reflections redraw the sky then).
	public static int64 ReadyGeneration { get; private set; }

	static bool sCreated, sSupported;
	static bgfx.ProgramHandle sTransmittanceProgram, sMultiscatterProgram, sSkyViewProgram;
	static bgfx.UniformHandle uAtmoParams, uSkyMode, uSkyScale, uMoonDir, uMoonParams, uStarRot, uPreetham;
	static bgfx.UniformHandle sAtmoTransmittance, sAtmoMultiscatter, sAtmoSkyView;
	static bgfx.TextureHandle sTransmittance, sMultiscatter, sSkyView, sDummy;
	static bgfx.FrameBufferHandle sTransmittanceFb, sMultiscatterFb, sSkyViewFb;
	static int32 sBuiltQuality = -1;
	static float sBuiltTurbidity = -1;
	static Vector3 sBuiltSun;
	static float sBuiltHeight = float.MinValue;
	static int64 sSubmitFrame = -1, sUpdatedFrame = -1, sGeneration, sReadyFrom = -1;
	static Vector4 sAtmoParams;
	/// The cloud block's u_cloudView as last set, so the screen sky can turn its screen-space flag on for its draw.
	static Vector4 sCloudView;

	static bgfx.FrameBufferHandle Invalid => .() { idx = uint16.MaxValue };

	/// Whether the GPU tables can be drawn here.
	public static bool Supported
	{
		get
		{
			EnsureCreated();
			return sSupported;
		}
	}

	static void EnsureCreated()
	{
		if (sCreated || !Gfx.Initialized)
			return;
		sCreated = true;
		let renderer = (bgfx.RendererType)(uint32)Native.tn_gfx_renderer_type();
		let rt = Gfx.TextureRenderTarget | Gfx.SamplerClamp;
		sSupported = !ForcePreetham && renderer != .OpenGL && renderer != .OpenGLES && renderer != .Noop && bgfx.is_texture_valid(0, false, 1, .RGBA16F, rt);
		uAtmoParams = bgfx.create_uniform("u_atmoParams", .Vec4, 1);
		uSkyMode = bgfx.create_uniform("u_skyMode", .Vec4, 1);
		uSkyScale = bgfx.create_uniform("u_skyScale", .Vec4, 1);
		uMoonDir = bgfx.create_uniform("u_moonDir", .Vec4, 1);
		uMoonParams = bgfx.create_uniform("u_moonParams", .Vec4, 1);
		uStarRot = bgfx.create_uniform("u_starRot", .Vec4, 3);
		uPreetham = bgfx.create_uniform("u_preetham", .Vec4, 5);
		sAtmoTransmittance = bgfx.create_uniform("s_atmoTransmittance", .Sampler, 1);
		sAtmoMultiscatter = bgfx.create_uniform("s_atmoMultiscatter", .Sampler, 1);
		sAtmoSkyView = bgfx.create_uniform("s_atmoSkyView", .Sampler, 1);
		// Bound when there is no table yet (Vulkan wants every sampler bound): light passes through unchanged.
		uint8[4] white = .(255, 255, 255, 255);
		sDummy = bgfx.create_texture_2d(1, 1, false, 1, .RGBA8, Gfx.SamplerClamp, bgfx.copy(&white, 4), 0);
		sTransmittance.idx = sMultiscatter.idx = sSkyView.idx = uint16.MaxValue;
		sTransmittanceFb = sMultiscatterFb = sSkyViewFb = Invalid;
		if (sSupported)
		{
			sTransmittanceProgram = Gfx.LoadProgram("vs_fullscreen", "fs_atmo_transmittance");
			sMultiscatterProgram = Gfx.LoadProgram("vs_fullscreen", "fs_atmo_multiscatter");
			sSkyViewProgram = Gfx.LoadProgram("vs_fullscreen", "fs_atmo_skyview");
			sSupported = sTransmittanceProgram.Valid && sMultiscatterProgram.Valid && sSkyViewProgram.Valid;
		}
	}

	static void DestroyTables()
	{
		for (let fb in bgfx.FrameBufferHandle[?](sTransmittanceFb, sMultiscatterFb, sSkyViewFb))
		{
			if (fb.idx != uint16.MaxValue)
				bgfx.destroy_frame_buffer(fb);
		}
		sTransmittanceFb = sMultiscatterFb = sSkyViewFb = Invalid;
		sTransmittance.idx = sMultiscatter.idx = sSkyView.idx = uint16.MaxValue;
		sBuiltQuality = -1;
		sReadyFrom = -1;
	}

	static bgfx.TextureHandle Table(int32 width, int32 height, out bgfx.FrameBufferHandle fb)
	{
		var texture = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA16F, Gfx.TextureRenderTarget | Gfx.SamplerClamp, null, 0);
		fb = bgfx.create_frame_buffer_from_handles(1, &texture, true);
		return texture;
	}

	static void SetUpView(uint16 view, StringView name, bgfx.FrameBufferHandle fb, int32 width, int32 height)
	{
		bgfx.set_view_name(view, name.Ptr, (int32)name.Length);
		bgfx.set_view_frame_buffer(view, fb);
		bgfx.set_view_rect(view, 0, 0, (uint16)width, (uint16)height, 0, 1);
		bgfx.set_view_clear(view, 0, 0, 1.0f, 0);
		var identity = Matrix4.Identity;
		bgfx.set_view_transform(view, &identity, &identity);
		bgfx.touch(view);
	}

	static int32 SkyViewWidth => Quality <= 0 ? 128 : (Quality == 1 ? 192 : 384);
	static int32 SkyViewHeight => Quality <= 0 ? 72 : (Quality == 1 ? 108 : 216);

	/// The sky's sun direction: the real sun's with the day/night clock on (the scene's main light may be the moon then).
	static Vector3 SunDirection(SceneEnvironment env, Vector4 sunDir) => env.dayNight ? DayNight.SunDirection(env) : Vector3(sunDir.x, sunDir.y, sunDir.z).Normalized;

	/// Draws the tables again if they are out of date: once a frame, from a camera's view (not captures).
	public static void Update(SceneEnvironment env, Vector4 sunDir, float cameraHeight)
	{
		if (env.skyMode == .Gradient || !Gfx.Initialized || sUpdatedFrame == Time.FrameCount)
			return;
		EnsureCreated();
		if (!sSupported)
			return;
		sUpdatedFrame = Time.FrameCount;
		let quality = Math.Clamp(Quality, 0, 2);
		let turbidity = Math.Clamp(env.turbidity, 1, 10);
		let sun = SunDirection(env, sunDir);
		let height = Math.Clamp(cameraHeight, 0, 50000);
		let rebuildBase = quality != sBuiltQuality || turbidity != sBuiltTurbidity;
		// 0.1 degrees of sun, or 100 m of height, before the sky is drawn again.
		let rebuildView = rebuildBase || Vector3.Dot(sun, sBuiltSun) < Math.Cos(0.1f * Mathf.Deg2Rad) || Math.Abs(height - sBuiltHeight) > 100;
		if (!rebuildView)
			return;
		if (quality != sBuiltQuality)
		{
			DestroyTables();
			let small = quality == 0;
			sTransmittance = Table(small ? 128 : 256, small ? 32 : 64, out sTransmittanceFb);
			sMultiscatter = Table(32, 32, out sMultiscatterFb);
			sSkyView = Table(SkyViewWidth, SkyViewHeight, out sSkyViewFb);
		}
		sAtmoParams = .(turbidity / 2.5f, 6360.0f + (height + 200) / 1000.0f, (float)Atmosphere.GroundAlbedo, quality >= 2 ? 24 : 16);
		if (rebuildBase)
		{
			let small = quality == 0;
			SetUpView(TransmittanceView, "Sky Transmittance", sTransmittanceFb, small ? 128 : 256, small ? 32 : 64);
			bgfx.set_uniform(uAtmoParams, &sAtmoParams, 1);
			Reflections.SubmitFullscreen(TransmittanceView, sTransmittanceProgram);
			SetUpView(MultiscatterView, "Sky Multiscatter", sMultiscatterFb, 32, 32);
			bgfx.set_uniform(uAtmoParams, &sAtmoParams, 1);
			bgfx.set_texture(0, sAtmoTransmittance, sTransmittance, uint32.MaxValue);
			Reflections.SubmitFullscreen(MultiscatterView, sMultiscatterProgram);
		}
		SetUpView(SkyViewView, "Sky View", sSkyViewFb, SkyViewWidth, SkyViewHeight);
		var dir = Vector4(sun.x, sun.y, sun.z, 0);
		bgfx.set_uniform(uAtmoParams, &sAtmoParams, 1);
		bgfx.set_uniform(RenderResources.uSunDir, &dir, 1);
		bgfx.set_texture(0, sAtmoTransmittance, sTransmittance, uint32.MaxValue);
		bgfx.set_texture(1, sAtmoMultiscatter, sMultiscatter, uint32.MaxValue);
		Reflections.SubmitFullscreen(SkyViewView, sSkyViewProgram);
		sBuiltQuality = quality;
		sBuiltTurbidity = turbidity;
		sBuiltSun = sun;
		sBuiltHeight = height;
		sSubmitFrame = Time.FrameCount;
		if (sReadyFrom < 0)
			sReadyFrom = sSubmitFrame;
		sGeneration++;
	}

	/// Whether a sky-view table has been drawn (the frame after its first submit).
	static bool TablesReady => sSupported && sReadyFrom >= 0 && Time.FrameCount > sReadyFrom;

	/// What the sky shaders draw: 0 gradient, 1 tables, 2 Preetham.
	public static int32 Mode(SceneEnvironment env)
	{
		if (env.skyMode == .Gradient)
			return 0;
		return TablesReady ? 1 : 2;
	}

	/// A number that changes when the sky the shaders draw changes (the reflection sky's cache key).
	public static int64 State(SceneEnvironment env)
	{
		if (env.skyMode == .Gradient)
			return 0;
		if (Time.FrameCount > sSubmitFrame)
			ReadyGeneration = sGeneration;
		return ReadyGeneration * 4 + Mode(env);
	}

	static float Smoothstep(float a, float b, float x)
	{
		let t = Math.Clamp((x - a) / (b - a), 0, 1);
		return t * t * (3 - 2 * t);
	}

	/// Sets the sky shader's uniforms and textures for this environment, before a sky draw: the gradient sky's (fs_sky,
	/// fs_env_sky) for mode 0, else the physical sky's (fs_sky_physical, fs_env_sky_physical). scene is the cloud
	/// clock's (Clouds.Seconds); it may be null in a test with no scene.
	/// sunDir and sunColor are the scene's main light (the gradient sky's sun).
	public static void SetUniforms(Scene scene, SceneEnvironment env, Vector4 sunDir, Vector4 sunColor)
	{
		var zenith = Linear(env.skyZenith);
		var horizon = Linear(env.skyHorizon);
		var ground = Linear(env.skyGround);
		bgfx.set_uniform(RenderResources.uSkyZenith, &zenith, 1);
		bgfx.set_uniform(RenderResources.uSkyHorizon, &horizon, 1);
		bgfx.set_uniform(RenderResources.uSkyGround, &ground, 1);
		EnsureCreated();
		let mode = Mode(env);
		if (mode == 0)
		{
			var dir = sunDir;
			var color = sunColor;
			bgfx.set_uniform(RenderResources.uSunDir, &dir, 1);
			bgfx.set_uniform(RenderResources.uSunColor, &color, 1);
			return;
		}

		let sun = SunDirection(env, sunDir);
		let elevation = Math.Asin(Math.Clamp(sun.y, -1, 1)) * Mathf.Rad2Deg;
		let sunLight = env.dayNight ? env.sunIntensity : Math.Max(sunColor.x, Math.Max(sunColor.y, sunColor.z));
		let brightness = Math.Max(env.skyBrightness, 0);
		// The sun's disc: its light through the air (red at sunset), so the sky and disc agree.
		let through = Atmosphere.SunTransmittance(elevation);
		var dir = Vector4(sun.x, sun.y, sun.z, 0);
		var color = Vector4((float)through.r * sunLight, (float)through.g * sunLight, (float)through.b * sunLight, 1);
		bgfx.set_uniform(RenderResources.uSunDir, &dir, 1);
		bgfx.set_uniform(RenderResources.uSunColor, &color, 1);

		var atmo = sAtmoParams;
		if (mode != 1)
			atmo = .(Math.Clamp(env.turbidity, 1, 10) / 2.5f, 6360.2f, (float)Atmosphere.GroundAlbedo, 16);
		bgfx.set_uniform(uAtmoParams, &atmo, 1);
		let stars = (1 - Smoothstep(-12, -4, elevation)) * Math.Max(env.starBrightness, 0);
		Vector4 skyMode = .(mode, (float)(Time.Time % 1000.0), stars, brightness);
		bgfx.set_uniform(uSkyMode, &skyMode, 1);
		// The table holds light per unit of sun outside the air; calibrated so its horizon is the fog colour
		// (Atmosphere.FogScale), as the CPU sky is.
		let z = Atmosphere.Zenith;
		let k = (float)Atmosphere.FogScale * sunLight * brightness;
		Vector4 scale = .(k / (float)z.r, k / (float)z.g, k / (float)z.b, Math.Max(env.sunDiscSize, 0) * 0.5f * Mathf.Deg2Rad);
		bgfx.set_uniform(uSkyScale, &scale, 1);
		Vector4 moon = .(0, -1, 0, 0);
		if (env.dayNight && env.moonSize > 0)
		{
			let m = DayNight.MoonDirection(env);
			moon = .(m.x, m.y, m.z, env.moonSize * 0.5f * Mathf.Deg2Rad);
		}
		bgfx.set_uniform(uMoonDir, &moon, 1);
		Vector4 moonParams = .(12, 0, brightness, 0);
		bgfx.set_uniform(uMoonParams, &moonParams, 1);
		SetCloudUniforms(scene, env, sun, color, moon);
		Vector4[3] rows = default;
		if (env.dayNight)
		{
			DayNight.CelestialBasis(env, let x, let y, let zAxis);
			rows = .(.(x.x, x.y, x.z, 0), .(y.x, y.y, y.z, 0), .(zAxis.x, zAxis.y, zAxis.z, 0));
		}
		else
			rows = .(.(1, 0, 0, 0), .(0, 1, 0, 0), .(0, 0, 1, 0));
		bgfx.set_uniform(uStarRot, &rows, 3);
		if (mode == 2)
		{
			var preetham = Preetham(env, elevation, sunLight * brightness);
			bgfx.set_uniform(uPreetham, &preetham, 5);
		}
		let hasTables = mode == 1;
		bgfx.set_texture(0, sAtmoTransmittance, hasTables ? sTransmittance : sDummy, uint32.MaxValue);
		bgfx.set_texture(1, sAtmoSkyView, hasTables ? sSkyView : sDummy, uint32.MaxValue);
	}

	/// The shared cloud uniform block (include/clouds.sh) from the scene's cloud settings. The 2D sky layer reads it
	/// now; the volumetric march (C2) reads the same block. This is the only place SceneEnvironment's clouds reach a
	/// shader, so the screen sky and the reflection cube always agree.
	static void SetCloudUniforms(Scene scene, SceneEnvironment env, Vector3 sun, Vector4 sunColor, Vector4 moon)
	{
		let seconds = Clouds.Seconds(scene);
		let offset = Clouds.Offset(env, seconds);
		Vector4 shape = .(env.cloudHeight, Math.Max(env.cloudThickness, 1), Math.Clamp(env.cloudCoverage, 0, 1), Math.Max(env.cloudDensity, 0));
		// 0.12 is the weather map's soft edge (spec 2.2); w carries the time the volume's detail drift will use.
		Vector4 wind = .(offset.x, offset.y, 0.12f, (float)(seconds % 1000.0));
		// x the HG anisotropy, y the ambient share, z the powder's scale (1/m; C2b), w the sun scattering.
		Vector4 light = .(Math.Clamp(env.cloudAnisotropy, -0.9f, 0.9f), Math.Max(env.cloudAmbient, 0), 8.0f, 1);
		// The scene's distance, capped by the quality setting's (C2c): both cloud paths read it from u_cloudView.x.
		let distance = Math.Clamp(Math.Min(Math.Max(env.cloudDistance, 1), Math.Max(RenderView.CloudMaxDistance, 500)), 1, 100000);
		Vector4 view = .(distance, env.clouds ? 1.0f : 0.0f, env.cloudMode == .TwoD ? 1.0f : 2.0f, 0.0f);
		var tint = Linear(env.cloudTint);
		tint.w = 1;
		Vector4 cloudSunDir = .(sun.x, sun.y, sun.z, 1);
		// The sun's radiance on the clouds: the same colour the sky draws, scaled by the sky's brightness (C2b).
		let brightness = Math.Max(env.skyBrightness, 0);
		Vector4 cloudSun = .(sunColor.x * brightness, sunColor.y * brightness, sunColor.z * brightness, 1);
		Vector4 cloudMoonDir = .(moon.x, moon.y, moon.z, moon.w > 0 ? 1.0f : 0.0f);
		Vector4 cloudMoon = .(0, 0, 0, 0);
		if (moon.w > 0)
		{
			let intensity = DayNight.MoonLight(env, var moonTint);
			let c = Linear(moonTint);
			// The moon's disc is bright, its scene light dim; lift it a touch so a moonlit deck reads at night
			// without turning the whole overcast grey.
			let k = intensity * 1.5f;
			cloudMoon = .(c.x * k, c.y * k, c.z * k, 1);
		}
		let skyAmbient = Linear(env.ambientSky);
		let ambient = Math.Max(env.ambientIntensity, 0);
		Vector4 cloudAmbient = .(skyAmbient.x * ambient, skyAmbient.y * ambient, skyAmbient.z * ambient, 0.35f);
		sCloudView = view;
		bgfx.set_uniform(RenderResources.uCloudShape, &shape, 1);
		bgfx.set_uniform(RenderResources.uCloudWind, &wind, 1);
		bgfx.set_uniform(RenderResources.uCloudLight, &light, 1);
		bgfx.set_uniform(RenderResources.uCloudView, &view, 1);
		bgfx.set_uniform(RenderResources.uCloudTint, &tint, 1);
		bgfx.set_uniform(RenderResources.uCloudSunDir, &cloudSunDir, 1);
		bgfx.set_uniform(RenderResources.uCloudSunColor, &cloudSun, 1);
		bgfx.set_uniform(RenderResources.uCloudMoonDir, &cloudMoonDir, 1);
		bgfx.set_uniform(RenderResources.uCloudMoonColor, &cloudMoon, 1);
		bgfx.set_uniform(RenderResources.uCloudAmbient, &cloudAmbient, 1);
		// The sky shader always declares s_clouds; a transparent 1x1 stands in until a screen draw binds the real layer.
		bgfx.set_texture(2, RenderResources.sClouds, RenderResources.CloudDummy, uint32.MaxValue);
	}

	/// Binds the raymarched cloud layer (cs_clouds.sc's target) for a sky draw and marks it screen space, so the sky
	/// composites it instead of the 2D layer. Called after SetUniforms for the main camera's sky; the reflection cube,
	/// captures and planar views keep the 2D layer (SetUniforms' screen-space flag is 0).
	public static void BindCloudLayer(bgfx.TextureHandle texture, bool screenSpace)
	{
		var view = sCloudView;
		view.w = screenSpace ? 1 : 0;
		bgfx.set_uniform(RenderResources.uCloudView, &view, 1);
		bgfx.set_texture(2, RenderResources.sClouds, texture.Valid ? texture : RenderResources.CloudDummy, uint32.MaxValue);
	}

	static Vector4 Linear(Color c) => .(Math.Pow(Math.Max(c.r, 0), 2.2f), Math.Pow(Math.Max(c.g, 0), 2.2f), Math.Pow(Math.Max(c.b, 0), 2.2f), c.a);

	static float sPreethamKey = float.NaN;
	static Vector4[5] sPreetham;

	static double PerezF(double cosTheta, double gamma, double A, double B, double C, double D, double E)
	{
		let cg = Math.Cos(gamma);
		return (1 + A * Math.Exp(B / Math.Max(cosTheta, 0.02))) * (1 + C * Math.Exp(D * gamma) + E * cg * cg);
	}

	/// The Preetham sky's constants (A. J. Preetham, P. Shirley, B. Smits 1999: "A Practical Analytic Model for
	/// Daylight"), its brightness set so its horizon matches the physical sky's (and the fog's).
	static Vector4[5] Preetham(SceneEnvironment env, float elevation, float light)
	{
		let T = (double)Math.Clamp(env.turbidity, 2, 10);
		let key = elevation * 1000 + (float)T * 7 + light * 13;
		if (key == sPreethamKey)
			return sPreetham;
		sPreethamKey = key;
		double[5] Ay = .(0.1787 * T - 1.4630, -0.3554 * T + 0.4275, -0.0227 * T + 5.3251, 0.1206 * T - 2.5771, -0.0670 * T + 0.3703);
		double[5] Ax = .(-0.0193 * T - 0.2592, -0.0665 * T + 0.0008, -0.0004 * T + 0.2125, -0.0641 * T - 0.8989, -0.0033 * T + 0.0452);
		double[5] Ayy = .(-0.0167 * T - 0.2608, -0.0950 * T + 0.0092, -0.0079 * T + 0.2102, -0.0441 * T - 1.6537, -0.0109 * T + 0.0529);
		// Below the horizon the model has no answer: the sun just below it, half as bright, fading out.
		let theta = Math.Min((90.0 - elevation) * Math.PI_d / 180.0, 89.5 * Math.PI_d / 180.0);
		let chi = (4.0 / 9.0 - T / 120.0) * (Math.PI_d - 2 * theta);
		let Yz = (4.0453 * T - 4.9710) * Math.Tan(chi) - 0.2155 * T + 2.4192;
		let t2 = theta * theta;
		let t3 = t2 * theta;
		let xz = T * T * (0.00166 * t3 - 0.00375 * t2 + 0.00209 * theta) + T * (-0.02903 * t3 + 0.06377 * t2 - 0.03202 * theta + 0.00394) + (0.11693 * t3 - 0.21196 * t2 + 0.06052 * theta + 0.25886);
		let yz = T * T * (0.00275 * t3 - 0.00610 * t2 + 0.00317 * theta) + T * (-0.04214 * t3 + 0.08970 * t2 - 0.04153 * theta + 0.00516) + (0.15346 * t3 - 0.26756 * t2 + 0.06670 * theta + 0.26688);
		let normY = Yz / PerezF(1, theta, Ay[0], Ay[1], Ay[2], Ay[3], Ay[4]);
		let normX = xz / PerezF(1, theta, Ax[0], Ax[1], Ax[2], Ax[3], Ax[4]);
		let normYy = yz / PerezF(1, theta, Ayy[0], Ayy[1], Ayy[2], Ayy[3], Ayy[4]);
		// The luminance round the horizon (2 degrees up), weighted as Atmosphere.HorizonRadiance.
		double horizonY = 0;
		let up = Math.Sin(2 * Math.PI_d / 180);
		for (int i < 4)
		{
			double[4] azimuths = .(0, 90, -90, 180);
			double[4] weights = .(0.4, 0.2, 0.2, 0.2);
			let az = azimuths[i] * Math.PI_d / 180;
			// The angle between the view (2 degrees up, az from the sun) and the sun.
			let cosGamma = Math.Clamp(Math.Cos(theta) * up + Math.Sin(theta) * Math.Cos(2 * Math.PI_d / 180) * Math.Cos(az), -1, 1);
			horizonY += weights[i] * normY * PerezF(up, Math.Acos(cosGamma), Ay[0], Ay[1], Ay[2], Ay[3], Ay[4]);
		}
		let target = Atmosphere.HorizonRadiance(Math.Max(elevation, 2)).Luminance * Atmosphere.FogScale * light;
		var scale = target / Math.Max(horizonY, 1e-6);
		if (elevation < 0)
			scale *= 0.5;
		let day = Smoothstep(-6, 2, elevation);
		for (int i < 5)
			sPreetham[i] = .((float)Ay[i], (float)Ax[i], (float)Ayy[i], 0);
		sPreetham[0].w = (float)normY;
		sPreetham[1].w = (float)normX;
		sPreetham[2].w = (float)normYy;
		sPreetham[3].w = (float)scale;
		sPreetham[4].w = day;
		return sPreetham;
	}

	public static void Shutdown()
	{
		if (!sCreated)
			return;
		DestroyTables();
		if (sDummy.Valid)
			bgfx.destroy_texture(sDummy);
		for (let program in bgfx.ProgramHandle[?](sTransmittanceProgram, sMultiscatterProgram, sSkyViewProgram))
		{
			if (program.Valid)
				bgfx.destroy_program(program);
		}
		for (let uniform in bgfx.UniformHandle[?](uAtmoParams, uSkyMode, uSkyScale, uMoonDir, uMoonParams, uStarRot, uPreetham, sAtmoTransmittance, sAtmoMultiscatter, sAtmoSkyView))
			bgfx.destroy_uniform(uniform);
		sCreated = false;
		sSupported = false;
		sGeneration = 0;
		ReadyGeneration = 0;
		sSubmitFrame = sUpdatedFrame = -1;
		sBuiltTurbidity = -1;
		sBuiltHeight = float.MinValue;
		sPreethamKey = float.NaN;
	}
}
