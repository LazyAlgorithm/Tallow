using System;
using System.IO;
using Tallow;

namespace QualityTests;

/// Graphics quality presets (docs/quality.md): the presets, telling which one is in use, applying them to the engine,
/// saving and reading the player's choice, the suggestion for a machine and the --quality names. Drawing needs the
/// graphics card, which this fixture does not have; the Sandbox is checked by eye with --quality.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	public static int Main(String[] args)
	{
		// High is what the engine did before presets, so existing projects look the same.
		let high = Quality.Preset(.High);
		Check(high == QualityValues(), "High is the engine's default settings");
		Check(RenderView.RenderScale == high.renderScale && RenderView.Antialias == high.antialias && RenderResources.ShadowAtlasSize == high.shadowMapSize && LODGroup.Bias == high.lodBias && GpuSkinning.Enabled == high.gpuSkinning, "the engine starts at High's settings");
		Check(Quality.Level == .High, "the level in use starts at High");

		// The presets go from cheap to costly.
		let low = Quality.Preset(.Low);
		let medium = Quality.Preset(.Medium);
		let ultra = Quality.Preset(.Ultra);
		Check(low.renderScale < medium.renderScale && medium.renderScale < high.renderScale, "render scale rises Low < Medium < High");
		Check(low.shadowMapSize < medium.shadowMapSize && medium.shadowMapSize < high.shadowMapSize, "shadow map rises Low < Medium < High");
		Check(low.lodBias < medium.lodBias && medium.lodBias < high.lodBias && high.lodBias < ultra.lodBias, "detail distance rises through every preset");
		Check(low.foliageDistance < ultra.foliageDistance && low.shadowDistance < ultra.shadowDistance, "foliage and shadow distance Low < Ultra");
		Check(!low.ambientOcclusion && !low.antialias && high.ambientOcclusion && high.antialias, "Low drops ambient occlusion and antialiasing, High keeps them");

		// Which preset settings are.
		Check(Quality.LevelOf(low) == .Low && Quality.LevelOf(medium) == .Medium && Quality.LevelOf(ultra) == .Ultra, "each preset's settings are known as that preset");
		var tweaked = medium;
		tweaked.motionBlur = true;
		Check(Quality.LevelOf(tweaked) == .Custom, "a changed setting makes it Custom");

		// Applying puts every setting into the engine.
		Quality.Set(.Low);
		Check(Quality.Level == .Low && Quality.Current == low, "Set(Low) makes Low the one in use");
		Check(RenderView.RenderScale == low.renderScale && !RenderView.Antialias && RenderView.ShadowDistanceScale == low.shadowDistance, "Low sets the render scale, antialiasing and shadow distance");
		Check(RenderResources.ShadowAtlasSize == low.shadowMapSize, "Low sets the shadow map size (remembered before the graphics card starts)");
		Check(!ScreenEffects.AmbientOcclusion && !ScreenEffects.DepthOfField && !ScreenEffects.MotionBlur, "Low turns the costly screen effects off");
		Check(LODGroup.Bias == low.lodBias && Foliage.DistanceScale == low.foliageDistance, "Low sets the detail and foliage distances");
		Quality.Current.shadows = false;
		Quality.Current.vsync = false;
		Quality.Current.gpuSkinning = false;
		Quality.Apply();
		Check(Quality.Level == .Custom && !RenderView.ShadowsEnabled && !GpuSkinning.Enabled, "settings changed one by one apply, and make it Custom");
		Check((Gfx.ResetFlags & Gfx.ResetVsync) == 0, "vsync off clears the reset flag");
		Quality.Set(.Custom);
		Check(Quality.Level == .Custom, "Set(Custom) changes nothing");
		Quality.Set(.High);
		Check((Gfx.ResetFlags & Gfx.ResetVsync) != 0 && RenderView.ShadowsEnabled && GpuSkinning.Enabled && RenderView.RenderScale == 1 && RenderResources.ShadowAtlasSize == 4096 && ScreenEffects.AmbientOcclusion, "Set(High) puts everything back");
		Quality.Set(.Ultra);
		Check(LODGroup.Bias == ultra.lodBias && RenderView.ShadowDistanceScale == ultra.shadowDistance, "Ultra keeps detail and shadows farther");

		// The settings as text.
		let text = scope String();
		var odd = ultra;
		odd.renderScale = 0.6f;
		odd.vsync = false;
		odd.shadowMapSize = 1024;
		Quality.Write(odd, text);
		Check(Quality.Read(text, .()) == odd, "settings read back as they were written");
		let partial = Quality.Read("motionBlur=0\nmystery=5\nrenderScale=9\nshadowMapSize=99999\n", .());
		Check(!partial.motionBlur && partial.renderScale == 1 && partial.shadowMapSize == 8192 && partial.ambientOcclusion, "unknown lines are skipped, missing ones kept, values held in range");

		// The player's choice between runs.
		let folder = scope String();
		Directory.GetCurrentDirectory(folder);
		folder.Append("/build/quality_test/");
		if (Directory.Exists(folder))
			Directory.DelTree(folder).IgnoreError();
		Check(!Quality.Load(folder), "nothing saved yet: Load says so");
		Check(Quality.Level == .Ultra, "and leaves the settings alone");
		Quality.Set(.Medium);
		Quality.Current.depthOfField = true;
		Quality.Apply();
		Check(Quality.Save(folder), "Save writes the player's settings");
		Quality.Set(.High);
		Check(Quality.Load(folder) && Quality.Level == .Custom && Quality.Current.depthOfField && Quality.Current.renderScale == medium.renderScale, "Load brings them back and applies them");
		Check(ScreenEffects.DepthOfField && RenderView.RenderScale == medium.renderScale, "loaded settings reach the engine");

		// Suggested preset and names.
		Check(Quality.Recommend(true, false, true) == .Low, "phones are suggested Low");
		Check(Quality.Recommend(false, true, false) == .Medium && Quality.Recommend(false, false, true) == .Medium, "built-in graphics and browsers are suggested Medium");
		Check(Quality.Recommend(false, false, false) == .High, "other machines are suggested High");
		QualityLevel parsed = .High, parsedLow = .High, ignored;
		Check(Quality.Parse("ULTRA", out parsed) && parsed == .Ultra && Quality.Parse("low", out parsedLow) && parsedLow == .Low, "--quality names are read in any case");
		Check(!Quality.Parse("custom", out ignored) && !Quality.Parse("best", out ignored), "Custom and unknown names are not presets");

		Quality.Set(.High);
		Console.WriteLine(scope $"\n{sFailures} failure(s)");
		return sFailures == 0 ? 0 : 1;
	}
}
