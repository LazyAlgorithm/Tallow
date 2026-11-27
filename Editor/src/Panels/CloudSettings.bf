using System;
using Tallow;

namespace Tallow.Editor;

/// The Clouds part of the Scene Settings (tallowengine.com/docs/clouds): a layer of clouds in the physical sky,
/// either raymarched through a slab of air or drawn by the cheap 2D cloud in the sky shader.
extension EditorApp
{
	/// The Clouds part of the Scene Settings. True when something changed.
	bool DrawCloudSettings(SceneEnvironment env)
	{
		bool changed = false;
		if (!ImGui.CollapsingHeader("Clouds") || !BeginPropertyTable("clouds"))
			return false;
		BeginProperty("Clouds");
		changed |= ImGui.Checkbox("##clouds", ref env.clouds);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Clouds in the physical sky: a layer of weather drifting with the wind. Off: the sky exactly as\nbefore.\nDrawn with the Physical sky, or a Custom skybox with Physical Sky Under above 0; a full skybox\nreplaces the sky and shows no clouds.");
		ImGui.BeginDisabled(!env.clouds);
		BeginProperty("Mode");
		StringView[2] cloudModes = .("Volumetric", "2D");
		if (ImGui.BeginCombo("##cloudmode", scope String(cloudModes[Math.Clamp((int32)env.cloudMode, 0, 1)]).CStr()))
		{
			for (int32 i < 2)
			{
				if (ImGui.Selectable(scope String(cloudModes[i]).CStr(), (int32)env.cloudMode == i))
				{
					env.cloudMode = (CloudMode)i;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Volumetric: raymarched through a slab of air, with lit tops and shaded bases (Vulkan,\nDirect3D and Metal).\n2D: the cheap procedural cloud drawn in the sky shader (every backend).\nLow graphics quality draws the 2D path whatever this says.");
		BeginProperty("Coverage");
		changed |= ImGui.SliderFloat("##cloudcov", ref env.cloudCoverage, 0, 1);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The share of the sky the weather map fills: 0 is clear, 1 is overcast.");
		BeginProperty("Density");
		changed |= ImGui.DragFloat("##cloudden", ref env.cloudDensity, 0.002f, 0, 0.5f, "%.3f / m");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How thick the inside of a full cloud is, per metre (0.04 fades out over about 25 m).");
		BeginProperty("Altitude");
		changed |= ImGui.DragFloat("##cloudh", ref env.cloudHeight, 10, 0, 20000, "%.0f m");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The bottom of the cloud layer, in metres above the world.");
		BeginProperty("Thickness");
		changed |= ImGui.DragFloat("##cloudth", ref env.cloudThickness, 10, 1, 20000, "%.0f m");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How deep the cloud layer is, in metres (its top is Altitude + this).");
		BeginProperty("Wind Speed");
		changed |= ImGui.DragFloat("##cloudws", ref env.cloudWindSpeed, 0.1f, 0, 100, "%.1f m/s");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How fast the weather drifts, in metres a second. 0 freezes it (the seed still decides the shape).");
		BeginProperty("Wind Direction");
		changed |= ImGui.SliderFloat("##cloudwd", ref env.cloudWindDirection, 0, 360, "%.0f deg");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The direction the weather drifts, in degrees clockwise seen from above (0: towards +Z, north).");
		BeginProperty("Seed");
		changed |= ImGui.DragInt("##cloudseed", ref env.cloudSeed, 1, 0, 1000000);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The wind seed: picks the weather map. Peers with the same seed and wind settings agree on the\nclouds, with no network messages.");
		BeginProperty("Anisotropy");
		changed |= ImGui.SliderFloat("##cloudan", ref env.cloudAnisotropy, -0.9f, 0.9f);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How much light goes on forward through a cloud: higher makes a bright silver lining when looking\ntowards the sun; 0 scatters every way the same.");
		BeginProperty("Ambient");
		changed |= ImGui.SliderFloat("##cloudamb", ref env.cloudAmbient, 0, 1);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How much of the sky and ground ambient light the clouds scatter.");
		BeginProperty("Tint");
		changed |= ImGui.ColorEdit3("##cloudtint", ref env.cloudTint);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The colour the clouds scatter back (their albedo; white as it is).");
		BeginProperty("Distance");
		changed |= ImGui.DragFloat("##clouddst", ref env.cloudDistance, 50, 500, 100000, "%.0f m");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("How far the volumetric march reaches, in metres. The Graphics Quality setting may cap it.");
		BeginProperty("Resolution");
		changed |= ImGui.SliderFloat("##cloudres", ref env.cloudResolution, 0.25f, 1, "%.2f");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The march's share of the picture's resolution (0.5: half, for speed). The Graphics Quality\nsetting may cap it.");
		ImGui.EndDisabled();
		ImGui.EndTable();
		return changed;
	}
}
