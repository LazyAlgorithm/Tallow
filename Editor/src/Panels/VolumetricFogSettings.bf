using System;
using Tallow;

namespace Tallow.Editor;

/// The Volumetric Fog part of the Scene Settings (tallowengine.com/docs/day-night): fog lit by the sun and by the
/// scene's point and spot lights, with light shafts where shadows cut it, worked out in a grid of cells over the view.
extension EditorApp
{
	/// The Volumetric Fog part of the Scene Settings. True when something changed.
	bool DrawVolumetricFogSettings(SceneEnvironment env)
	{
		bool changed = false;
		if (!ImGui.CollapsingHeader("Volumetric Fog") || !BeginPropertyTable("vfog"))
			return false;
		BeginProperty("Volumetric Fog");
		changed |= ImGui.Checkbox("##vfog", ref env.volumetricFog);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Fog lit by the sun (with light shafts where shadows cut it) and by the scene's point and spot\nlights, instead of the plain distance fog. Needs Vulkan, Direct3D or Metal; OpenGL and the web\ndraw a cheaper height fog with sun shafts instead. The Graphics Quality setting can also turn it off (Low).");
		ImGui.BeginDisabled(!env.volumetricFog);
		BeginProperty("Density");
		changed |= ImGui.DragFloat("##vfd", ref env.vfDensity, 0.0002f, 0, 0.2f, "%.4f");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How thick the fog is at and below Fog Height, per metre (0.02 fades out over about 50 m).\n0 leaves only Fog Volumes.");
		BeginProperty("Height");
		changed |= ImGui.DragFloat("##vfh", ref env.vfHeight, 0.5f, -1000, 10000, "%.1f m");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The height above which the fog starts to thin out.");
		BeginProperty("Falloff");
		changed |= ImGui.DragFloat("##vff", ref env.vfFalloff, 0.002f, 0, 1, "%.3f / m");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How fast the fog thins above Fog Height, per metre (0: the same everywhere).");
		BeginProperty("Anisotropy");
		changed |= ImGui.SliderFloat("##vfa", ref env.vfAnisotropy, -0.9f, 0.9f);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How much light goes on forward through the fog: higher makes a bright glow round the sun when\nlooking towards it; 0 scatters every way the same.");
		BeginProperty("Albedo");
		changed |= ImGui.ColorEdit3("##vfc", ref env.vfAlbedo);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The fog's colour: what share of each colour of light it scatters back.");
		BeginProperty("Sun Scattering");
		changed |= ImGui.DragFloat("##vfs", ref env.vfSunScattering, 0.01f, 0, 8);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How much sunlight the fog scatters (1 as it should; more for stronger light shafts).");
		BeginProperty("Ambient");
		changed |= ImGui.DragFloat("##vfamb", ref env.vfAmbient, 0.01f, 0, 4);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How much of the ambient (sky) light the fog scatters.");
		BeginProperty("Distance");
		changed |= ImGui.DragFloat("##vfdst", ref env.vfDistance, 1, 8, 4096, "%.0f m");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How far the fog's grid reaches. Beyond it the fog goes on as plain height fog.");
		ImGui.EndDisabled();
		ImGui.EndTable();
		return changed;
	}
}
