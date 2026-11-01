using System;
using System.Collections;
using Tallow;

namespace PostProcessingTests;

/// The screen effects and colour grading (docs/post-processing.md): the scene's settings and their defaults, saving
/// and loading (old scenes look as they did), the depth of field's blur sum, colour lookup tables, and the player's
/// settings. The passes themselves draw on the graphics card, which this fixture does not have; check them by eye in
/// the Game view.
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

	static bool Near(float a, float b, float within = 0.0001f) => Math.Abs(a - b) <= within;

	public static int Main(String[] args)
	{
		// ---- defaults: nothing changes for a scene that uses none of it ----
		let env = scope SceneEnvironment();
		Check(!env.UsesDepthEffects, "a new scene has no ambient occlusion, depth of field or motion blur");
		Check(env.contrast == 1 && env.saturation == 1.05f && env.vignette == 0.35f && env.temperature == 0 && env.tint == 0, "colour grading's defaults are the tonemap's old fixed values");
		Check(env.colorFilter.r == 1 && env.colorFilter.g == 1 && env.colorFilter.b == 1 && env.colorLookup.IsEmpty, "no colour filter and no lookup table");

		let plain = scope Scene();
		plain.CreateGameObject("Crate");
		let plainText = scope String();
		SceneSerializer.Save(plain, plainText);
		Check(!plainText.Contains("ambientOcclusion") && !plainText.Contains("contrast") && !plainText.Contains("colorLookup"), "a scene that uses none saves no new lines");

		// ---- saving ----
		let scene = scope Scene();
		let e = scene.Environment;
		e.ambientOcclusion = 1.2f;
		e.occlusionRadius = 0.9f;
		e.depthOfField = 0.7f;
		e.focusDistance = 4;
		e.focusRange = 3;
		e.autoFocus = true;
		e.motionBlur = 0.5f;
		e.contrast = 1.2f;
		e.saturation = 0.8f;
		e.temperature = 0.3f;
		e.tint = -0.2f;
		e.colorFilter = .(1, 0.9f, 0.8f);
		e.vignette = 0.6f;
		e.colorLookup.Set("Grading/warm look.png");
		e.colorLookupStrength = 0.75f;
		Check(e.UsesDepthEffects, "any of the three needs the depth pass");
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let l = loaded.Environment;
		Check(Near(l.ambientOcclusion, 1.2f) && Near(l.occlusionRadius, 0.9f), "a scene keeps its ambient occlusion");
		Check(Near(l.depthOfField, 0.7f) && Near(l.focusDistance, 4) && Near(l.focusRange, 3) && l.autoFocus, "and its depth of field");
		Check(Near(l.motionBlur, 0.5f), "and its motion blur");
		Check(Near(l.contrast, 1.2f) && Near(l.saturation, 0.8f) && Near(l.temperature, 0.3f) && Near(l.tint, -0.2f) && Near(l.vignette, 0.6f), "and its grading");
		Check(Near(l.colorFilter.g, 0.9f) && Near(l.colorFilter.b, 0.8f), "and its colour filter");
		Check(l.colorLookup == "Grading/warm look.png" && Near(l.colorLookupStrength, 0.75f), "and its lookup table, even with a space in the path");

		// Loading a scene saved before these settings existed, over one that had them, gives the defaults back.
		SceneSerializer.Load(loaded, plainText);
		Check(!loaded.Environment.UsesDepthEffects && loaded.Environment.contrast == 1 && loaded.Environment.colorLookup.IsEmpty, "a scene without the settings loads with none, whatever was loaded before");

		// ---- depth of field: how blurred each distance is ----
		let lens = scope SceneEnvironment();
		lens.focusRange = 8;
		Check(lens.BlurAmount(10, 10) == 0 && lens.BlurAmount(14, 10) == 0 && lens.BlurAmount(6, 10) == 0, "sharp within half the range either side of the focus");
		Check(Near(lens.BlurAmount(18, 10), 0.5f) && lens.BlurAmount(22, 10) == 1 && lens.BlurAmount(40, 10) == 1, "fully blurred a whole range beyond that");
		// In front of the focus there may not be a whole range of room: at 0.5 m it is 9.5 m from the focus, 5.5 m past the sharp part.
		Check(Near(lens.BlurAmount(2, 10), 0.5f) && Near(lens.BlurAmount(0.5f, 10), 5.5f / 8), "and the same in front of the focus, as far as there is room");
		lens.focusRange = 2;
		Check(lens.BlurAmount(7, 10) == 1 && lens.BlurAmount(0.5f, 10) == 1, "a narrow range blurs the near ground fully");
		lens.focusRange = 8;
		Check(lens.BlurAmount(-1, 10) == 0, "the viewmodel (depth -1) is always sharp");

		// ---- lookup tables ----
		Check(PostProcess.LookupSize(256, 16) == 16 && PostProcess.LookupSize(1024, 32) == 32, "256 x 16 and 1024 x 32 images are lookup tables");
		Check(PostProcess.LookupSize(100, 10) == 10 && PostProcess.LookupSize(4, 2) == 2 && PostProcess.LookupSize(4096, 64) == 64, "so is any size from 2 to 64 (100 x 10 is size 10)");
		Check(PostProcess.LookupSize(256, 256) == 0 && PostProcess.LookupSize(100, 16) == 0 && PostProcess.LookupSize(1, 1) == 0 && PostProcess.LookupSize(16900, 130) == 0, "other images are not");
		List<uint8> neutral = scope .();
		PostProcess.MakeNeutralLookup(16, neutral);
		Check(neutral.Count == 256 * 16 * 4, "a neutral table of 16 is 256 x 16 pixels");
		bool same = true;
		var random = scope Random(7);
		for (int i < 200)
		{
			let c = Color((float)random.NextDouble(), (float)random.NextDouble(), (float)random.NextDouble());
			let back = PostProcess.Apply(neutral, 16, c);
			if (!Near(back.r, c.r, 0.01f) || !Near(back.g, c.g, 0.01f) || !Near(back.b, c.b, 0.01f))
				same = false;
		}
		Check(same, "a neutral table leaves colours as they are");
		List<uint8> inverted = scope .();
		PostProcess.MakeNeutralLookup(16, inverted);
		for (int i < inverted.Count)
		{
			if (i % 4 != 3)
				inverted[i] = (uint8)(255 - inverted[i]);
		}
		let flipped = PostProcess.Apply(inverted, 16, .(0.2f, 0.5f, 0.9f));
		Check(Near(flipped.r, 0.8f, 0.01f) && Near(flipped.g, 0.5f, 0.01f) && Near(flipped.b, 0.1f, 0.01f), "a recoloured table recolours (inverted here)");

		// ---- --effects on the command line ----
		let tried = scope SceneEnvironment();
		let set = PostProcess.ApplySettings("ao=1, dof=0.6,focus=12,autofocus=1,motion=0.4,lut=Grading/warm.png,bogus=3", tried);
		Check(set == 6 && tried.ambientOcclusion == 1 && Near(tried.depthOfField, 0.6f) && tried.focusDistance == 12 && tried.autoFocus && Near(tried.motionBlur, 0.4f) && tried.colorLookup == "Grading/warm.png", "--effects sets the scene's settings and skips unknown names");

		// ---- the player's settings ----
		Check(ScreenEffects.AmbientOcclusion && ScreenEffects.DepthOfField && ScreenEffects.MotionBlur && ScreenEffects.MotionBlurAmount == 1 && ScreenEffects.Brightness == 1, "the player's settings start with everything on");
		Gfx.UseMobileQuality();
		Check(!ScreenEffects.AmbientOcclusion && !ScreenEffects.DepthOfField && !ScreenEffects.MotionBlur, "phone quality turns the depth pass effects off");
		ScreenEffects.Reset();
		Check(ScreenEffects.AmbientOcclusion && ScreenEffects.MotionBlur, "and a game can turn them back on");
		Check(RenderView.ViewCount == 23, "a RenderView reserves separate sun and point and spot shadow views, a decal view and four water views");

		Console.WriteLine(sFailures == 0 ? "All post-processing tests passed." : scope $"{sFailures} post-processing test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
