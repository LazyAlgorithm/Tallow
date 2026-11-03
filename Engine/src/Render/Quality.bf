using System;
using System.IO;

namespace Tallow;

/// The graphics quality presets (docs/quality.md).
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
	/// Multisampled edges.
	public bool antialias = true;
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
	/// Reflection probes (off: shiny surfaces mirror only the sky; docs/reflections.md).
	public bool reflectionProbes = true;
	/// The size of a reflection probe's cube, in pixels (those that do not choose their own).
	public int32 reflectionSize = 128;

	public this()
	{
	}

	public bool Equals(QualityValues other) => renderScale == other.renderScale && antialias == other.antialias && shadows == other.shadows && shadowedLights == other.shadowedLights && shadowMapSize == other.shadowMapSize && shadowDistance == other.shadowDistance && ambientOcclusion == other.ambientOcclusion && depthOfField == other.depthOfField && motionBlur == other.motionBlur && lodBias == other.lodBias && foliageDistance == other.foliageDistance && gpuSkinning == other.gpuSkinning && vsync == other.vsync && textureDetail == other.textureDetail && anisotropic == other.anisotropic && reflectionProbes == other.reflectionProbes && reflectionSize == other.reflectionSize;
	public static bool operator ==(QualityValues a, QualityValues b) => a.Equals(b);
}

/// Graphics quality: four presets (Low, Medium, High, Ultra) and the settings each one sets, applied to the engine at
/// once, remembered for the player between runs, and a recommendation for the machine. A game's options screen
/// calls Quality.Set(.Medium) or changes Quality.Current and calls Apply; nothing else is needed. See docs/quality.md.
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
			v.renderScale = 0.7f;
			v.antialias = false;
			v.shadowMapSize = 1024;
			v.shadowedLights = 2;
			v.shadowDistance = 0.5f;
			v.ambientOcclusion = false;
			v.depthOfField = false;
			v.motionBlur = false;
			v.lodBias = 0.6f;
			v.foliageDistance = 0.5f;
			v.textureDetail = 1;
			v.anisotropic = false;
			v.reflectionProbes = false;
			v.reflectionSize = 64;
		case .Medium:
			v.renderScale = 0.85f;
			v.shadowMapSize = 2048;
			v.shadowedLights = 4;
			v.shadowDistance = 0.75f;
			v.depthOfField = false;
			v.motionBlur = false;
			v.lodBias = 0.8f;
			v.foliageDistance = 0.75f;
			v.reflectionSize = 64;
		case .High,.Custom:
		case .Ultra:
			v.shadowedLights = 16;
			v.shadowDistance = 1.5f;
			v.lodBias = 1.5f;
			v.foliageDistance = 1.5f;
			v.reflectionSize = 256;
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

	/// Puts Current into the engine: the renderer, shadows, screen effects, LOD, foliage, skinning, vsync and textures.
	public static void Apply()
	{
		Level = LevelOf(Current);
		RenderView.RenderScale = Math.Clamp(Current.renderScale, 0.25f, 1);
		RenderView.Antialias = Current.antialias;
		RenderView.ShadowsEnabled = Current.shadows;
		RenderView.ShadowDistanceScale = Math.Max(Current.shadowDistance, 0.05f);
		RenderView.MaxShadowedLights = Math.Clamp(Current.shadowedLights, 0, LightClusters.MaxTiles);
		RenderResources.SetShadowAtlasSize(Current.shadowMapSize);
		ScreenEffects.AmbientOcclusion = Current.ambientOcclusion;
		ScreenEffects.WaterReflections = Current.reflectionProbes;
		ScreenEffects.SurfaceReflections = Current.reflectionProbes;
		ScreenEffects.DepthOfField = Current.depthOfField;
		ScreenEffects.MotionBlur = Current.motionBlur;
		LODGroup.Bias = Math.Max(Current.lodBias, 0.05f);
		Foliage.DistanceScale = Math.Max(Current.foliageDistance, 0.05f);
		GpuSkinning.Enabled = Current.gpuSkinning;
		Gfx.SetVsync(Current.vsync);
		Textures.SkipLevels = Math.Clamp(Current.textureDetail, 0, 3);
		Gfx.SetAnisotropic(Current.anisotropic);
		Reflections.ProbesEnabled = Current.reflectionProbes;
		Reflections.Resolution = Math.Clamp(Current.reflectionSize, 32, 512);
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
		text.AppendF("renderScale={}\nantialias={}\nshadows={}\nshadowedLights={}\nshadowMapSize={}\nshadowDistance={}\nambientOcclusion={}\ndepthOfField={}\nmotionBlur={}\nlodBias={}\nfoliageDistance={}\ngpuSkinning={}\nvsync={}\ntextureDetail={}\nanisotropic={}\nreflectionProbes={}\nreflectionSize={}\n",
			v.renderScale, v.antialias ? 1 : 0, v.shadows ? 1 : 0, v.shadowedLights, v.shadowMapSize, v.shadowDistance, v.ambientOcclusion ? 1 : 0, v.depthOfField ? 1 : 0, v.motionBlur ? 1 : 0, v.lodBias, v.foliageDistance, v.gpuSkinning ? 1 : 0, v.vsync ? 1 : 0, v.textureDetail, v.anisotropic ? 1 : 0, v.reflectionProbes ? 1 : 0, v.reflectionSize);
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
			case "antialias": v.antialias = flag;
			case "shadows": v.shadows = flag;
			case "shadowedLights": v.shadowedLights = (int32)Math.Clamp(number, 0, LightClusters.MaxTiles);
			case "shadowMapSize": v.shadowMapSize = (int32)Math.Clamp(number, 256, 8192);
			case "shadowDistance": v.shadowDistance = Math.Clamp(number, 0.05f, 4);
			case "ambientOcclusion": v.ambientOcclusion = flag;
			case "depthOfField": v.depthOfField = flag;
			case "motionBlur": v.motionBlur = flag;
			case "lodBias": v.lodBias = Math.Clamp(number, 0.05f, 4);
			case "foliageDistance": v.foliageDistance = Math.Clamp(number, 0.05f, 4);
			case "gpuSkinning": v.gpuSkinning = flag;
			case "vsync": v.vsync = flag;
			case "textureDetail": v.textureDetail = (int32)Math.Clamp(number, 0, 3);
			case "anisotropic": v.anisotropic = flag;
			case "reflectionProbes": v.reflectionProbes = flag;
			case "reflectionSize": v.reflectionSize = (int32)Math.Clamp(number, 32, 512);
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
