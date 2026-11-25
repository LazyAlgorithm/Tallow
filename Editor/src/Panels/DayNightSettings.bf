using System;
using Tallow;

namespace Tallow.Editor;

/// The Day / Night part of the Scene Settings (tallowengine.com/docs/day-night): the clock that turns the sun and moon.
extension EditorApp
{
	/// The Day / Night part of the Scene Settings. True when something changed.
	bool DrawDayNightSettings(SceneEnvironment env)
	{
		bool changed = false;
		if (!ImGui.CollapsingHeader("Day / Night") || !BeginPropertyTable("daynight"))
			return false;
		BeginProperty("Day / Night");
		changed |= ImGui.Checkbox("##dn", ref env.dayNight);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Turn the sun (and moon) by a clock instead of placing them by hand.\nThe sun light's rotation is set from the time each frame.\nBaked lightmaps keep the light they were baked with: for a moving sun,\nleave the sun Realtime (Baked Only off) and bake only indirect and local lights.");
		if (env.dayNight)
		{
			BeginProperty("Time Of Day");
			if (ImGui.SliderFloat("##tod", ref env.timeOfDay, 0, 24, "%.2f h"))
			{
				env.timeOfDay = DayNight.WrapHours(env.timeOfDay);
				changed = true;
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Hours, 0 to 24 (12 is noon). Drag it to move the sun; in Edit mode the clock does not run.");
			BeginProperty("Day Length");
			changed |= ImGui.DragFloat("##dl", ref env.dayLengthMinutes, 0.5f, 0, 1440, "%.1f min");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Real minutes a whole 24-hour day takes while playing. 0 stops the clock.");
			BeginProperty("Paused");
			changed |= ImGui.Checkbox("##dnp", ref env.dayNightPaused);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Stop the clock while playing; the sun stays where the time puts it.");
			BeginProperty("Latitude");
			changed |= ImGui.SliderFloat("##lat", ref env.latitude, -90, 90, "%.1f deg");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("How far north (+) or south (-) of the equator the scene is: how high the sun climbs.");
			BeginProperty("Axis Tilt");
			changed |= ImGui.SliderFloat("##tilt", ref env.axisTilt, 0, 90, "%.2f deg");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("The planet's tilt (Earth: 23.44): how much the sun's path changes over the year.");
			BeginProperty("North Direction");
			changed |= ImGui.DragFloat("##north", ref env.northDirection, 1, -360, 360, "%.0f deg");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Which way north is, in degrees round from +Z, clockwise seen from above.\nThe sun rises in the east and sets in the west.");
			BeginProperty("Day Of Year");
			changed |= ImGui.DragInt("##doy", ref env.dayOfYear, 1, 1, 365);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("1 to 365. 172 is the June solstice (longest day in the north), 355 the December one.\nAlso sets the moon's phase.");
			BeginProperty("Sun");
			changed |= DirectionalPicker("##sun", ref env.sunLight, "First Directional Light", env.moonLight);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("The Directional light turned as the sun. Default: the first one (the one casting shadows, if any).\nIts rotation is driven by the clock while Day / Night is on.");
			BeginProperty("Moon");
			changed |= DirectionalPicker("##moon", ref env.moonLight, "None", env.sunLight);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("An optional Directional light turned as the moon.");
			if (env.moonLight != 0)
			{
				BeginProperty("Moon Shadows");
				changed |= ImGui.Checkbox("##ms", ref env.moonShadows);
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("Whether the moon casts the shadows at night.");
			}
			BeginProperty("Sun Intensity");
			changed |= ImGui.DragFloat("##si", ref env.sunIntensity, 0.01f, 0, 20, "%.2f");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("The sun light's brightness at noon. Its colour and intensity follow the air it shines through:\nwhite high up, orange then red near the horizon, dark after sunset.");
			if (env.moonLight != 0)
			{
				BeginProperty("Moon Intensity");
				changed |= ImGui.DragFloat("##mi", ref env.moonIntensity, 0.005f, 0, 2, "%.3f");
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("The moon light's brightness at full moon, high up. Dimmer at other phases and near the horizon.");
			}
			BeginProperty("Auto Colours");
			changed |= ImGui.Checkbox("##ac", ref env.autoColors);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Also set the ambient sky, ambient ground and fog colours from the sun's height\n(blue by day, warm at sunset, dark at night). Off keeps the hand-picked colours.");
			BeginProperty("Sun Height");
			let sun = DayNight.FindSun(mScene);
			let height = scope String()..AppendF("{:F1} deg", DayNight.SunElevation(env));
			if (DayNight.IsNight(env))
				height.Append(", night");
			if (sun)
				height.AppendF("  ({} is driven by Day / Night)", sun.GameObject.Name);
			else
				height.Append("  (no Directional light)");
			ImGui.TextDisabled(height.CStr());
		}
		ImGui.EndTable();
		if (changed)
			DayNight.Apply(mScene);
		return changed;
	}

	/// A list of the scene's Directional lights to pick one by object id (0 = `none`). `other` is left out.
	bool DirectionalPicker(char8* id, ref uint32 value, StringView none, uint32 other)
	{
		let current = value != 0 ? mScene.FindById(value) : null;
		let preview = current != null ? scope String(current.Name) : scope String(none);
		bool changed = false;
		if (ImGui.BeginCombo(id, preview.CStr()))
		{
			if (ImGui.Selectable(scope String(none).CStr(), value == 0))
			{
				value = 0;
				changed = true;
			}
			for (let light in mScene.AllLights)
			{
				let objectId = light.GameObject.Id;
				if (light.type != .Directional || (objectId == other && other != 0))
					continue;
				if (ImGui.Selectable(scope $"{light.GameObject.Name}##{objectId}", objectId == value))
				{
					value = objectId;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}
}
