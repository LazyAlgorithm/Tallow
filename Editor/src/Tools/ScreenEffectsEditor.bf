using System;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Scene Settings: the screen effects (ambient occlusion, depth of field, motion blur) and colour grading. See
/// docs/post-processing.md. Everything here is saved with the scene; the Game view shows it as it is changed.
extension EditorApp
{
	/// Scene Settings > Screen Effects and Color Grading. Returns true when anything changed.
	bool DrawScreenEffectsSettings(SceneEnvironment env)
	{
		bool changed = false;
		if (ImGui.CollapsingHeader("Screen Effects") && BeginPropertyTable("screeneffects"))
			changed |= DrawScreenEffects(env);
		if (ImGui.CollapsingHeader("Color Grading") && BeginPropertyTable("grading"))
			changed |= DrawColorGrading(env);
		return changed;
	}

	static void Tip(char8* text)
	{
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip(text);
	}

	/// Ambient occlusion, depth of field and motion blur, and whether the Scene view shows the last two. Ends the
	/// property table it is drawn in.
	bool DrawScreenEffects(SceneEnvironment env)
	{
		bool changed = false;
		BeginProperty("Ambient Occlusion");
		changed |= ImGui.SliderFloat("##ao", ref env.ambientOcclusion, 0, 2);
		Tip("Darkens creases, corners and where things meet the ground. 0 is off; 1 is normal.");
		if (env.ambientOcclusion > 0)
		{
			BeginProperty("Occlusion Radius");
			changed |= ImGui.SliderFloat("##aor", ref env.occlusionRadius, 0.05f, 4, "%.2f m");
			Tip("How far around each point is looked at. Small for fine detail, large for broad shading under big shapes.");
		}

		BeginProperty("Depth Of Field");
		changed |= ImGui.SliderFloat("##dof", ref env.depthOfField, 0, 2);
		Tip("Blurs what is nearer or further than the focus. 0 is off; 1 is a blur 3% of the screen's height across.");
		if (env.depthOfField > 0)
		{
			BeginProperty("Auto Focus");
			changed |= ImGui.Checkbox("##af", ref env.autoFocus);
			Tip("Focus on whatever is in the middle of the screen.");
			if (!env.autoFocus)
			{
				BeginProperty("Focus Distance");
				changed |= ImGui.DragFloat("##fdist", ref env.focusDistance, 0.1f, 0, 1000, "%.1f m");
			}
			BeginProperty("Focus Range");
			changed |= ImGui.DragFloat("##frange", ref env.focusRange, 0.1f, 0.01f, 1000, "%.1f m");
			Tip("How deep the sharp band is: sharp within half of it either side of the focus, fully blurred a whole range beyond.");
		}

		BeginProperty("Motion Blur");
		changed |= ImGui.SliderFloat("##mb", ref env.motionBlur, 0, 1);
		Tip("Smears the picture along the way it moves when the camera turns or moves. 0.5 is like a film camera. The viewmodel is never blurred.");

		BeginProperty("In Scene View");
		bool sceneShows = mSceneView.ShowDepthOfField;
		if (ImGui.Checkbox("##esv", ref sceneShows))
		{
			mSceneView.ShowDepthOfField = sceneShows;
			mSceneView.ShowMotionBlur = sceneShows;
		}
		Tip("Show depth of field and motion blur in the Scene view too (an editor setting, not saved with the scene). Ambient occlusion always shows.");
		ImGui.EndTable();
		return changed;
	}

	/// Contrast, saturation, temperature, tint, filter, vignette and a lookup table. Ends the property table it is
	/// drawn in.
	bool DrawColorGrading(SceneEnvironment env)
	{
		bool changed = false;
		BeginProperty("Contrast");
		changed |= ImGui.SliderFloat("##gc", ref env.contrast, 0.5f, 2);
		BeginProperty("Saturation");
		changed |= ImGui.SliderFloat("##gs", ref env.saturation, 0, 2);
		BeginProperty("Temperature");
		changed |= ImGui.SliderFloat("##gt", ref env.temperature, -1, 1);
		Tip("Above 0 warmer (more orange), below 0 cooler (more blue).");
		BeginProperty("Tint");
		changed |= ImGui.SliderFloat("##gti", ref env.tint, -1, 1);
		Tip("Above 0 towards magenta, below 0 towards green.");
		BeginProperty("Color Filter");
		changed |= ImGui.ColorEdit3("##gf", ref env.colorFilter);
		BeginProperty("Vignette");
		changed |= ImGui.SliderFloat("##gv", ref env.vignette, 0, 2);
		BeginProperty("Lookup Table");
		ImGui.PushID("lut");
		if (DrawAssetPicker(env.colorLookup, "texture"))
		{
			changed = true;
			PostProcess.ForgetLookups();
		}
		ImGui.PopID();
		Tip("A colour lookup table image: a strip of square tiles, such as 256 x 16 pixels. Empty for none.");
		if (!env.colorLookup.IsEmpty)
		{
			BeginProperty("Lookup Strength");
			changed |= ImGui.SliderFloat("##gls", ref env.colorLookupStrength, 0, 1);
		}
		BeginProperty("");
		if (ImGui.Button("Make Neutral Lookup Table"))
			MakeNeutralLookup(env);
		Tip("Saves Grading/neutral_lut.png in the project and uses it. Open it in an image editor with a screenshot of the game, grade the two together, and save it over the original.");
		if (!env.colorLookup.IsEmpty)
		{
			ImGui.SameLine();
			if (ImGui.Button("Reload"))
				PostProcess.ForgetLookups();
			Tip("Read the lookup table image again after changing it.");
		}
		BeginProperty("");
		if (ImGui.Button("Reset Grading"))
		{
			ResetGrading(env);
			changed = true;
		}
		ImGui.EndTable();
		return changed;
	}

	/// The grading settings back to a new scene's.
	static void ResetGrading(SceneEnvironment env)
	{
		let fresh = scope SceneEnvironment();
		env.contrast = fresh.contrast;
		env.saturation = fresh.saturation;
		env.temperature = fresh.temperature;
		env.tint = fresh.tint;
		env.colorFilter = fresh.colorFilter;
		env.vignette = fresh.vignette;
		env.colorLookup.Clear();
		env.colorLookupStrength = fresh.colorLookupStrength;
	}

	void MakeNeutralLookup(SceneEnvironment env)
	{
		let folder = scope $"{Assets.ProjectPath}/Grading";
		Directory.CreateDirectory(folder).IgnoreError();
		let file = scope $"{folder}/neutral_lut.png";
		if (!PostProcess.SaveNeutralLookup(file, 16))
		{
			Log.Error(scope $"Could not write {file}");
			return;
		}
		let relative = scope String();
		ToRelative(file, relative);
		env.colorLookup.Set(relative);
		PostProcess.ForgetLookups();
		MarkDirty();
		Log.Info(scope $"Saved a neutral colour lookup table as {relative}");
	}
}
