using System;
using System.IO;

namespace Tallow;

/// The graphics quality presets (tallowengine.com/docs/quality).
enum QualityLevel
{
	Low,
	Medium,
	High,
	Ultra,
	/// Settings changed one by one from a preset.
	Custom
}

/// Every graphics setting a preset sets, in one place.
struct QualityValues : IEquatable<QualityValues>
{
	/// How much of the window's resolution the 3D scene is drawn at (the interface stays sharp).
	public float renderScale = 1;
	/// How edges are smoothed: multisampling, or a filter on the finished picture (FXAA, SMAA).
	public AntialiasMode antialiasMode = .MSAA4x;
	/// How the picture drawn smaller than the window (renderScale below 1) is brought up to size.
	public UpscalerKind upscaler = .Off;
	/// Shadows from the sun, point and spot lights.
	public bool shadows = true;
	/// How many point and spot lights cast shadows in a view, the nearest first (a point light costs six times a
	/// spot light's).
	public int32 shadowedLights = 8;
	/// The shadow map's size in pixels: sharper shadows cost memory and time.
	public int32 shadowMapSize = 4096;
	/// Times each scene's shadow distance: how far away things still cast shadows.
	public float shadowDistance = 1;
	public bool ambientOcclusion = true;
	public bool depthOfField = true;
	public bool motionBlur = true;
	/// Light bounced between surfaces: flat ambient, baked, half-resolution SSGI, dynamic GI, or dynamic GI + SSGI.
	public GlobalIlluminationMode globalIllumination = .ProbeGrid;
	/// Times how far away objects keep their detail (LODGroup.Bias).
	public float lodBias = 1;
	/// Times how far away plants are drawn (each Foliage's View Distance).
	public float foliageDistance = 1;
	/// Bend skinned models on the graphics card where it can.
	public bool gpuSkinning = true;
	/// Wait for the screen's refresh: no tearing, at most the screen's frame rate.
	public bool vsync = true;
	/// How many of each texture's largest mip levels are left out: 0 full detail, 1 half each side (a quarter of the
	/// memory). For textures loaded from then on (Textures.SkipLevels).
	public int32 textureDetail = 0;
	/// Sharper textures on slanted surfaces (floors, walls seen along).
	public bool anisotropic = true;
	/// Reflection probes (off: shiny surfaces mirror only the sky; tallowengine.com/docs/reflections).
	public bool reflectionProbes = true;
	/// The size of a reflection probe's cube, in pixels (those that do not choose their own).
	public int32 reflectionSize = 128;
	/// Draw big meshes from clusters picked on the graphics card (GpuDriven.bf), where it can.
	public bool gpuDriven = true;
	/// How many pixels of error the clusters of those meshes may have on screen: lower is sharper and costs more.
	public float pixelError = 1.0f;
	/// Leave out what is hidden behind other things in GPU-driven drawing (GpuDriven.Occlusion).
	public bool gpuOcclusion = true;
	/// Stream big meshes' geometry in pages instead of loading it whole (GpuDriven.StreamGeometry).
	public bool streamGeometry = true;
	/// Memory the streamed geometry pages, texture mip levels and virtual-texture tiles may use, in megabytes.
	public int32 geometryBudgetMB = 512;
	public int32 textureBudgetMB = 1024;
	public int32 vtBudgetMB = 512;
	/// The physical sky's detail: 0 the smallest sky table (128 x 72), 1 192 x 108, 2 384 x 216 with more samples.
	public int32 skyQuality = 1;
	/// Volumetric fog (RenderViewVolumetric.bf): fog lit by the sun and local lights with shafts. Off, the scene keeps
	/// its plain distance/height fog.
	public bool volumetricFog = true;
	/// How many pixels across and down each froxel cell covers: smaller is finer and costs more (8 to 32).
	public int32 fogTileSize = 12;
	/// How many cells deep the fog grid is: more is smoother and costs more (16 to 160).
	public int32 fogSlices = 64;
	/// Blend each frame's fog cells with last frame's, which hides the banding between depth slices.
	public bool fogTemporal = true;
	/// How many point and spot lights may scatter into the fog in a view (the first in each cell's cluster list).
	public int32 fogLocalLights = 64;
	/// Volumetric clouds (RenderViewClouds.bf) may raymarch the sky; off, the scene's mode is treated as 2D (the cloud
	/// backup on the physical sky) even when the scene asks for volumetric.
	public bool clouds = true;
	/// Raymarch steps through the cloud slab per pixel.
	public int32 cloudSteps = 48;
	/// Steps of each shadow ray towards the sun (the cloud's self-shadowing): more is puffier, costs more.
	public int32 cloudShadowSteps = 4;
	/// Blend each frame's cloud layer with last frame's reprojected layer, which hides the march's noise (and needs
	/// the camera to be still or moving smoothly; a cut drops it).
	public bool cloudTemporal = true;
	/// The largest share of the picture's resolution the cloud march may use (a scene's cloudResolution is capped).
	public float cloudMaxResolution = 0.75f;
	/// The farthest the cloud march goes, in metres (a scene's cloudDistance is capped).
	public float cloudMaxDistance = 12000;

	public this()
	{
	}

	public bool Equals(QualityValues other) => renderScale == other.renderScale && antialiasMode == other.antialiasMode && upscaler == other.upscaler && shadows == other.shadows && shadowedLights == other.shadowedLights && shadowMapSize == other.shadowMapSize && shadowDistance == other.shadowDistance && ambientOcclusion == other.ambientOcclusion && depthOfField == other.depthOfField && motionBlur == other.motionBlur && globalIllumination == other.globalIllumination && lodBias == other.lodBias && foliageDistance == other.foliageDistance && gpuSkinning == other.gpuSkinning && vsync == other.vsync && textureDetail == other.textureDetail && anisotropic == other.anisotropic && reflectionProbes == other.reflectionProbes && reflectionSize == other.reflectionSize && gpuDriven == other.gpuDriven && pixelError == other.pixelError && gpuOcclusion == other.gpuOcclusion && streamGeometry == other.streamGeometry && geometryBudgetMB == other.geometryBudgetMB && textureBudgetMB == other.textureBudgetMB && vtBudgetMB == other.vtBudgetMB && skyQuality == other.skyQuality && volumetricFog == other.volumetricFog && fogTileSize == other.fogTileSize && fogSlices == other.fogSlices && fogTemporal == other.fogTemporal && fogLocalLights == other.fogLocalLights && clouds == other.clouds && cloudSteps == other.cloudSteps && cloudShadowSteps == other.cloudShadowSteps && cloudTemporal == other.cloudTemporal && cloudMaxResolution == other.cloudMaxResolution && cloudMaxDistance == other.cloudMaxDistance;
	public static bool operator ==(QualityValues a, QualityValues b) => a.Equals(b);
}

/// The settings a lighting preset sets, and only those: shadows, ambient occlusion, global illumination, reflections
/// and the volumetric fog grid. A game's Lighting Quality option changes these, so the render scale, the upscaler and
/// the rest of the graphics quality stay as the player chose them.
struct LightingValues : IEquatable<LightingValues>
{
	public bool shadows = true;
	public int32 shadowedLights = 8;
	public int32 shadowMapSize = 4096;
	public float shadowDistance = 1;
	public bool ambientOcclusion = true;
	public GlobalIlluminationMode globalIllumination = .ProbeGrid;
	public bool reflectionProbes = true;
	public int32 reflectionSize = 128;
	public bool volumetricFog = true;
	public int32 fogTileSize = 12;
	public int32 fogSlices = 64;
	public bool fogTemporal = true;
	public int32 fogLocalLights = 64;
	public bool clouds = true;
	public int32 cloudSteps = 48;
	public int32 cloudShadowSteps = 4;
	public bool cloudTemporal = true;
	public float cloudMaxResolution = 0.75f;
	public float cloudMaxDistance = 12000;

	public this()
	{
	}

	public bool Equals(LightingValues other) => shadows == other.shadows && shadowedLights == other.shadowedLights && shadowMapSize == other.shadowMapSize && shadowDistance == other.shadowDistance && ambientOcclusion == other.ambientOcclusion && globalIllumination == other.globalIllumination && reflectionProbes == other.reflectionProbes && reflectionSize == other.reflectionSize && volumetricFog == other.volumetricFog && fogTileSize == other.fogTileSize && fogSlices == other.fogSlices && fogTemporal == other.fogTemporal && fogLocalLights == other.fogLocalLights && clouds == other.clouds && cloudSteps == other.cloudSteps && cloudShadowSteps == other.cloudShadowSteps && cloudTemporal == other.cloudTemporal && cloudMaxResolution == other.cloudMaxResolution && cloudMaxDistance == other.cloudMaxDistance;
	public static bool operator ==(LightingValues a, LightingValues b) => a.Equals(b);
}

/// Graphics quality: four presets (Low, Medium, High, Ultra) and the settings each one sets, applied to the engine at
/// once, remembered for the player between runs, and a recommendation for the machine. A game's options screen
/// calls Quality.Set(.Medium) or changes Quality.Current and calls Apply; nothing else is needed. A Lighting Quality
/// option of its own uses SetLighting (a preset's lighting settings only, leaving the render scale and upscaler).
/// See tallowengine.com/docs/quality.
static class Quality
{
	/// What is in use now.
	public static QualityValues Current = .();
	/// The preset in use, or Custom when settings were changed one by one.
	public static QualityLevel Level = .High;
	/// The player's choice is saved here between runs (in their player data folder).
	public const String FileName = "graphics.cfg";

	public static StringView[5] Names = .("Low", "Medium", "High", "Ultra", "Custom");

	/// The settings of a preset.
	public static QualityValues Preset(QualityLevel level)
	{
		var v = QualityValues();
		switch (level)
		{
		case .Low:
			// Drawn at 70% and sharpened up by FSR 1, with the cheapest antialiasing.
			v.renderScale = 0.7f;
			v.upscaler = .FSR1;
			v.antialiasMode = .FXAA;
			v.shadowMapSize = 1024;
			v.shadowedLights = 2;
			v.shadowDistance = 0.5f;
			v.ambientOcclusion = false;
			v.depthOfField = false;
			v.motionBlur = false;
			v.globalIllumination = .Baked;
			v.lodBias = 0.6f;
			v.foliageDistance = 0.5f;
			v.textureDetail = 1;
			v.anisotropic = false;
			v.reflectionProbes = false;
			v.reflectionSize = 64;
			v.gpuDriven = false;
			v.pixelError = 2.5f;
			v.geometryBudgetMB = 256;
			v.textureBudgetMB = 512;
			v.vtBudgetMB = 256;
			v.skyQuality = 0;
			// Low keeps the fallback's plain height fog and cheap sun shafts instead of the grid.
			v.volumetricFog = false;
			v.fogTileSize = 16;
			v.fogSlices = 32;
			v.fogTemporal = false;
			v.fogLocalLights = 0;
			// Low draws the 2D cloud backup instead of the raymarch (the scene's mode is treated as 2D).
			v.clouds = false;
			v.cloudSteps = 0;
			v.cloudShadowSteps = 0;
			v.cloudTemporal = false;
			v.cloudMaxResolution = 0.5f;
			v.cloudMaxDistance = 6000;
		case .Medium:
			v.renderScale = 0.85f;
			v.upscaler = .FSR1;
			v.antialiasMode = .FXAA;
			v.shadowMapSize = 2048;
			v.shadowedLights = 4;
			v.shadowDistance = 0.75f;
			v.depthOfField = false;
			v.motionBlur = false;
			v.globalIllumination = .ScreenSpace;
			v.lodBias = 0.8f;
			v.foliageDistance = 0.75f;
			v.reflectionSize = 64;
			v.pixelError = 2.0f;
			v.skyQuality = 0;
			v.volumetricFog = true;
			v.fogTileSize = 16;
			v.fogSlices = 48;
			v.fogTemporal = true;
			v.fogLocalLights = 16;
			// Half the picture's resolution, 32 steps and 2 shadow steps: the raymarch is on but cheap.
			v.clouds = true;
			v.cloudSteps = 32;
			v.cloudShadowSteps = 2;
			v.cloudTemporal = true;
			v.cloudMaxResolution = 0.5f;
			v.cloudMaxDistance = 8000;
		case .High,.Custom:
			// High is the cloud march's default (48 steps, 4 shadow steps, 0.75 of the picture, 12 km); Ultra refines it.
			v.clouds = true;
			v.cloudSteps = 48;
			v.cloudShadowSteps = 4;
			v.cloudTemporal = true;
			v.cloudMaxResolution = 0.75f;
			v.cloudMaxDistance = 12000;
		case .Ultra:
			// TAA (a graphics card that cannot do it falls back to FXAA: Antialiasing.Resolve).
			v.antialiasMode = .TAA;
			v.shadowedLights = 16;
			v.globalIllumination = .ProbeGridAndScreenSpace;
			v.shadowDistance = 1.5f;
			v.lodBias = 1.5f;
			v.foliageDistance = 1.5f;
			v.reflectionSize = 256;
			v.pixelError = 0.75f;
			v.geometryBudgetMB = 1024;
			v.textureBudgetMB = 2048;
			v.vtBudgetMB = 1024;
			v.skyQuality = 2;
			// High is the fog grid's default (12 px cells, 64 slices, temporal, 64 lights); Ultra refines it.
			v.fogTileSize = 8;
			v.fogSlices = 128;
			v.fogLocalLights = 128;
			// Ultra: the full picture, 64 steps and 20 km.
			v.cloudSteps = 64;
			v.cloudMaxResolution = 1.0f;
			v.cloudMaxDistance = 20000;
		}
		return v;
	}

	/// Switches to a preset and applies it.
	public static void Set(QualityLevel level)
	{
		if (level == .Custom)
			return;
		Current = Preset(level);
		Level = level;
		Apply();
	}

	/// The preset whose settings these are, or Custom.
	public static QualityLevel LevelOf(QualityValues values)
	{
		for (int i < 4)
		{
			if (Preset((QualityLevel)i) == values)
				return (QualityLevel)i;
		}
		return .Custom;
	}

	// ---- lighting quality (shadows, ambient occlusion, global illumination, reflections and the volumetric fog grid)

	/// The serialized names of the settings a lighting preset changes (Quality.Write's spelling).
	public static StringView[19] LightingFieldNames = .("shadows", "shadowedLights", "shadowMapSize", "shadowDistance", "ambientOcclusion", "globalIllumination", "reflectionProbes", "reflectionSize", "volumetricFog", "fogTileSize", "fogSlices", "fogTemporal", "fogLocalLights", "clouds", "cloudSteps", "cloudShadowSteps", "cloudTemporal", "cloudMaxResolution", "cloudMaxDistance");

	/// Whether a setting is one a lighting preset changes.
	public static bool IsLightingField(StringView name)
	{
		for (let field in LightingFieldNames)
		{
			if (field == name)
				return true;
		}
		return false;
	}

	/// The lighting settings in use now.
	public static LightingValues Lighting => LightingOf(Current);

	/// The lighting settings of a preset.
	public static LightingValues LightingPreset(QualityLevel level) => LightingOf(Preset(level));

	/// Only the settings a lighting preset changes, from a full set of quality values.
	public static LightingValues LightingOf(QualityValues values)
	{
		var v = LightingValues();
		v.shadows = values.shadows;
		v.shadowedLights = values.shadowedLights;
		v.shadowMapSize = values.shadowMapSize;
		v.shadowDistance = values.shadowDistance;
		v.ambientOcclusion = values.ambientOcclusion;
		v.globalIllumination = values.globalIllumination;
		v.reflectionProbes = values.reflectionProbes;
		v.reflectionSize = values.reflectionSize;
		v.volumetricFog = values.volumetricFog;
		v.fogTileSize = values.fogTileSize;
		v.fogSlices = values.fogSlices;
		v.fogTemporal = values.fogTemporal;
		v.fogLocalLights = values.fogLocalLights;
		v.clouds = values.clouds;
		v.cloudSteps = values.cloudSteps;
		v.cloudShadowSteps = values.cloudShadowSteps;
		v.cloudTemporal = values.cloudTemporal;
		v.cloudMaxResolution = values.cloudMaxResolution;
		v.cloudMaxDistance = values.cloudMaxDistance;
		return v;
	}

	/// The preset whose lighting settings are in use, or Custom.
	public static QualityLevel LightingLevel
	{
		get
		{
			let lighting = LightingOf(Current);
			for (int i < 4)
			{
				if (LightingOf(Preset((QualityLevel)i)) == lighting)
					return (QualityLevel)i;
			}
			return .Custom;
		}
	}

	/// Puts only the lighting settings in Current into the engine: shadows, ambient occlusion, global illumination,
	/// reflections and the volumetric fog grid. The render scale, upscaler and every other setting stay as they are.
	public static void ApplyLighting()
	{
		RenderView.ShadowsEnabled = Current.shadows;
		RenderView.ShadowDistanceScale = Math.Max(Current.shadowDistance, 0.05f);
		RenderView.MaxShadowedLights = Math.Clamp(Current.shadowedLights, 0, LightClusters.MaxTiles);
		RenderResources.SetShadowAtlasSize(Current.shadowMapSize);
		ScreenEffects.AmbientOcclusion = Current.ambientOcclusion;
		ScreenEffects.WaterReflections = Current.reflectionProbes;
		ScreenEffects.SurfaceReflections = Current.reflectionProbes;
		ScreenEffects.GlobalIllumination = Current.globalIllumination;
		Reflections.ProbesEnabled = Current.reflectionProbes;
		Reflections.Resolution = Math.Clamp(Current.reflectionSize, 32, 512);
		// Volumetric fog (RenderViewVolumetric.bf): whether a scene may use it at all, its grid, its temporal blend and
		// how many local lights may scatter into it.
		RenderView.FogEnabled = Current.volumetricFog;
		RenderView.FogTileSize = Math.Clamp(Current.fogTileSize, 4, 32);
		RenderView.FogSlices = Math.Clamp(Current.fogSlices, 16, 160);
		RenderView.FogTemporalAllowed = Current.fogTemporal;
		RenderView.FogLocalLights = Math.Clamp(Current.fogLocalLights, 0, 256);
		RenderView.FogHistoryBlend = LightingLevel == .Ultra ? 0.95f : 0.9f;
		// Volumetric clouds (RenderViewClouds.bf): whether the raymarch may run, its step/ray budget, the temporal blend
		// and the caps on the scene's own resolution and distance.
		RenderView.CloudsAllowed = Current.clouds;
		RenderView.CloudSteps = Math.Clamp(Current.cloudSteps, 0, 128);
		RenderView.CloudShadowSteps = Math.Clamp(Current.cloudShadowSteps, 0, 8);
		RenderView.CloudTemporalAllowed = Current.cloudTemporal;
		RenderView.CloudMaxResolution = Math.Clamp(Current.cloudMaxResolution, 0.25f, 1);
		RenderView.CloudMaxDistance = Math.Clamp(Current.cloudMaxDistance, 500, 100000);
	}

	/// Switches to a preset's lighting settings and applies only them; the rest of Current stays as it is. Custom does
	/// nothing.
	public static void SetLighting(QualityLevel level)
	{
		if (level == .Custom)
			return;
		let v = Preset(level);
		Current.shadows = v.shadows;
		Current.shadowedLights = v.shadowedLights;
		Current.shadowMapSize = v.shadowMapSize;
		Current.shadowDistance = v.shadowDistance;
		Current.ambientOcclusion = v.ambientOcclusion;
		Current.globalIllumination = v.globalIllumination;
		Current.reflectionProbes = v.reflectionProbes;
		Current.reflectionSize = v.reflectionSize;
		Current.volumetricFog = v.volumetricFog;
		Current.fogTileSize = v.fogTileSize;
		Current.fogSlices = v.fogSlices;
		Current.fogTemporal = v.fogTemporal;
		Current.fogLocalLights = v.fogLocalLights;
		Current.clouds = v.clouds;
		Current.cloudSteps = v.cloudSteps;
		Current.cloudShadowSteps = v.cloudShadowSteps;
		Current.cloudTemporal = v.cloudTemporal;
		Current.cloudMaxResolution = v.cloudMaxResolution;
		Current.cloudMaxDistance = v.cloudMaxDistance;
		ApplyLighting();
		Level = LevelOf(Current);
	}

	/// Changes one lighting setting from text (Quality.Write's names) and applies only the lighting settings. False for
	/// a name a lighting preset does not change.
	public static bool SetLightingValue(StringView name, StringView value)
	{
		if (!IsLightingField(name))
			return false;
		Current = Read(scope $"{name}={value}", Current);
		ApplyLighting();
		Level = LevelOf(Current);
		return true;
	}

	/// Puts Current into the engine: the renderer, shadows, screen effects, LOD, foliage, skinning, vsync and textures.
	public static void Apply()
	{
		Level = LevelOf(Current);
		RenderView.RenderScale = Math.Clamp(Current.renderScale, 0.25f, 1);
		RenderView.AntialiasingMode = Current.antialiasMode;
		Upscaling.Current = Current.upscaler;
		Upscaling.Reset();
		ScreenEffects.DepthOfField = Current.depthOfField;
		ScreenEffects.MotionBlur = Current.motionBlur;
		LODGroup.Bias = Math.Max(Current.lodBias, 0.05f);
		Foliage.DistanceScale = Math.Max(Current.foliageDistance, 0.05f);
		GpuSkinning.Enabled = Current.gpuSkinning;
		Gfx.SetVsync(Current.vsync);
		Textures.SkipLevels = Math.Clamp(Current.textureDetail, 0, 3);
		Gfx.SetAnisotropic(Current.anisotropic);
		GpuDriven.QualitySetting = Current.gpuDriven;
		if (!GpuDriven.PixelErrorFromArgs)
			GpuDriven.PixelError = Math.Clamp(Current.pixelError, 0.25f, 16);
		if (!GpuDriven.OcclusionFromArgs)
			GpuDriven.Occlusion = Current.gpuOcclusion;
		if (!GpuDriven.StreamGeometryFromArgs)
			GpuDriven.StreamGeometry = Current.streamGeometry;
		StreamingCore.ApplyBudgetsMB(Current.geometryBudgetMB, Current.textureBudgetMB, Current.vtBudgetMB);
		PhysicalSky.Quality = Math.Clamp(Current.skyQuality, 0, 2);
		ApplyLighting();
	}

	/// The preset suggested for this machine: Low on phones, Medium on integrated graphics and in a browser, High
	/// otherwise.
	public static QualityLevel Recommended => Recommend(WebPlatform.IsMobile, Gfx.IsIntegratedGpu, Gfx.IsWeb);

	public static QualityLevel Recommend(bool phone, bool integratedGpu, bool browser)
	{
		if (phone)
			return .Low;
		if (integratedGpu || browser)
			return .Medium;
		return .High;
	}

	/// The settings as text, one `name=value` a line.
	public static void Write(QualityValues v, String text)
	{
		text.AppendF("renderScale={}\nantialias={}\nantialiasMode={}\nupscaler={}\nshadows={}\nshadowedLights={}\nshadowMapSize={}\nshadowDistance={}\nambientOcclusion={}\ndepthOfField={}\nmotionBlur={}\nglobalIllumination={}\nlodBias={}\nfoliageDistance={}\ngpuSkinning={}\nvsync={}\ntextureDetail={}\nanisotropic={}\nreflectionProbes={}\nreflectionSize={}\ngpuDriven={}\npixelError={}\ngpuOcclusion={}\nstreamGeometry={}\ngeometryBudgetMB={}\ntextureBudgetMB={}\nvtBudgetMB={}\nskyQuality={}\nvolumetricFog={}\nfogTileSize={}\nfogSlices={}\nfogTemporal={}\nfogLocalLights={}\nclouds={}\ncloudSteps={}\ncloudShadowSteps={}\ncloudTemporal={}\ncloudMaxResolution={}\ncloudMaxDistance={}\n",
			v.renderScale, v.antialiasMode != .Off ? 1 : 0, (int32)v.antialiasMode, (int32)v.upscaler, v.shadows ? 1 : 0, v.shadowedLights, v.shadowMapSize, v.shadowDistance, v.ambientOcclusion ? 1 : 0, v.depthOfField ? 1 : 0, v.motionBlur ? 1 : 0, (int32)v.globalIllumination, v.lodBias, v.foliageDistance, v.gpuSkinning ? 1 : 0, v.vsync ? 1 : 0, v.textureDetail, v.anisotropic ? 1 : 0, v.reflectionProbes ? 1 : 0, v.reflectionSize, v.gpuDriven ? 1 : 0, v.pixelError, v.gpuOcclusion ? 1 : 0, v.streamGeometry ? 1 : 0, v.geometryBudgetMB, v.textureBudgetMB, v.vtBudgetMB, v.skyQuality, v.volumetricFog ? 1 : 0, v.fogTileSize, v.fogSlices, v.fogTemporal ? 1 : 0, v.fogLocalLights, v.clouds ? 1 : 0, v.cloudSteps, v.cloudShadowSteps, v.cloudTemporal ? 1 : 0, v.cloudMaxResolution, v.cloudMaxDistance);
	}

	/// Reads settings from text (unknown or missing lines keep the values given).
	public static QualityValues Read(StringView text, QualityValues start)
	{
		var v = start;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			let equals = line.IndexOf('=');
			if (equals <= 0)
				continue;
			let name = line.Substring(0, equals);
			let value = line.Substring(equals + 1);
			let number = SceneSerializer.ParseFloat(value);
			let flag = value == "1" || value == "true";
			switch (name)
			{
			case "renderScale": v.renderScale = Math.Clamp(number, 0.25f, 1);
			// The old on/off setting: on is 4x multisampling unless a mode is already chosen (antialiasMode comes after it
			// in a saved file and wins).
			case "antialias": v.antialiasMode = flag ? (v.antialiasMode == .Off ? .MSAA4x : v.antialiasMode) : .Off;
			case "antialiasMode": v.antialiasMode = (AntialiasMode)(int32)Math.Clamp(number, 0, 6);
			case "upscaler": v.upscaler = (UpscalerKind)(int32)Math.Clamp(number, 0, 3);
			case "shadows": v.shadows = flag;
			case "shadowedLights": v.shadowedLights = (int32)Math.Clamp(number, 0, LightClusters.MaxTiles);
			case "shadowMapSize": v.shadowMapSize = (int32)Math.Clamp(number, 256, 8192);
			case "shadowDistance": v.shadowDistance = Math.Clamp(number, 0.05f, 4);
			case "ambientOcclusion": v.ambientOcclusion = flag;
			case "depthOfField": v.depthOfField = flag;
			case "motionBlur": v.motionBlur = flag;
			case "globalIllumination": v.globalIllumination = (GlobalIlluminationMode)(int32)Math.Clamp(number, 0, 4);
			case "lodBias": v.lodBias = Math.Clamp(number, 0.05f, 4);
			case "foliageDistance": v.foliageDistance = Math.Clamp(number, 0.05f, 4);
			case "gpuSkinning": v.gpuSkinning = flag;
			case "vsync": v.vsync = flag;
			case "textureDetail": v.textureDetail = (int32)Math.Clamp(number, 0, 3);
			case "anisotropic": v.anisotropic = flag;
			case "reflectionProbes": v.reflectionProbes = flag;
			case "reflectionSize": v.reflectionSize = (int32)Math.Clamp(number, 32, 512);
			case "gpuDriven": v.gpuDriven = flag;
			case "pixelError": v.pixelError = Math.Clamp(number, 0.25f, 16);
			case "gpuOcclusion": v.gpuOcclusion = flag;
			case "streamGeometry": v.streamGeometry = flag;
			case "geometryBudgetMB": v.geometryBudgetMB = (int32)Math.Clamp(number, 16, 16384);
			case "textureBudgetMB": v.textureBudgetMB = (int32)Math.Clamp(number, 16, 16384);
			case "vtBudgetMB": v.vtBudgetMB = (int32)Math.Clamp(number, 16, 16384);
			case "skyQuality": v.skyQuality = (int32)Math.Clamp(number, 0, 2);
			case "volumetricFog": v.volumetricFog = flag;
			case "fogTileSize": v.fogTileSize = (int32)Math.Clamp(number, 4, 32);
			case "fogSlices": v.fogSlices = (int32)Math.Clamp(number, 16, 160);
			case "fogTemporal": v.fogTemporal = flag;
			case "fogLocalLights": v.fogLocalLights = (int32)Math.Clamp(number, 0, 256);
			case "clouds": v.clouds = flag;
			case "cloudSteps": v.cloudSteps = (int32)Math.Clamp(number, 0, 128);
			case "cloudShadowSteps": v.cloudShadowSteps = (int32)Math.Clamp(number, 0, 8);
			case "cloudTemporal": v.cloudTemporal = flag;
			case "cloudMaxResolution": v.cloudMaxResolution = Math.Clamp(number, 0.25f, 1);
			case "cloudMaxDistance": v.cloudMaxDistance = Math.Clamp(number, 500, 100000);
			}
		}
		return v;
	}

	/// Remembers the player's settings for the next run.
	public static bool Save(StringView folder = default)
	{
		let path = scope String(folder.IsEmpty ? GamePaths.PlayerData : folder);
		Directory.CreateDirectory(path).IgnoreError();
		path.Append(FileName);
		let text = scope String();
		Write(Current, text);
		return File.WriteAllText(path, text) case .Ok;
	}

	/// Applies the player's saved settings, if there are any. False when the player has not chosen yet (the engine's
	/// own settings stay as they are, or the game can Set(Recommended)).
	public static bool Load(StringView folder = default)
	{
		let path = scope String(folder.IsEmpty ? GamePaths.PlayerData : folder);
		path.Append(FileName);
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err)
			return false;
		Current = Read(text, .());
		Apply();
		return true;
	}

	/// A preset by name (any case), as the --quality switch takes it.
	public static bool Parse(StringView name, out QualityLevel level)
	{
		for (int i < 4)
		{
			if (name.Equals(Names[i], true))
			{
				level = (QualityLevel)i;
				return true;
			}
		}
		level = .High;
		return false;
	}
}
