using System;

namespace Tallow.Editor;

/// Window > Graphics Quality: the presets and each setting, applied at once to the Scene and Game views, to see what a
/// player's Low or Ultra looks like (tallowengine.com/docs/quality). The editor's own choice is not saved as the player's.
extension EditorApp
{
	bool mShowQuality;

	protected override bool LoadsPlayerQuality => false;

	void DrawQualityWindow()
	{
		if (!mShowQuality)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + viewport.workSize.x - 700, viewport.workPos.y + 80), 4);
		ImGui.SetNextWindowSize(.(360, 560), 4);
		if (ImGui.Begin("Graphics Quality", &mShowQuality))
		{
			for (int i < 4)
			{
				let level = (QualityLevel)i;
				if (i > 0)
					ImGui.SameLine();
				if (ImGui.Selectable(scope String(Quality.Names[i]).CStr(), Quality.Level == level, 0, .(70, 0)))
					Quality.Set(level);
			}
			ImGui.TextDisabled(scope String()..AppendF("In use: {}   Suggested here: {}", Quality.Names[(int)Quality.Level], Quality.Names[(int)Quality.Recommended]).CStr());
			ImGui.Separator();
			var v = Quality.Current;
			var changed = false;
			changed |= ImGui.SliderFloat("Render Scale", ref v.renderScale, 0.25f, 1, "%.2f");
			changed |= DrawUpscalerSettings(ref v);
			changed |= ImGui.Checkbox("Shadows", ref v.shadows);
			var shadowSlider = (float)Math.Round(Math.Log(v.shadowMapSize / 512.0) / Math.Log(2));
			if (ImGui.SliderFloat(scope String()..AppendF("Shadow Map ({})###shadowmap", v.shadowMapSize).CStr(), ref shadowSlider, 0, 4, ""))
			{
				v.shadowMapSize = (int32)(512 << (int32)Math.Round(shadowSlider));
				changed = true;
			}
			changed |= ImGui.SliderFloat("Shadow Distance", ref v.shadowDistance, 0.25f, 3, "x%.2f");
			changed |= ImGui.DragInt("Shadowed Lights", ref v.shadowedLights, 0.1f, 0, 32);
			changed |= ImGui.Checkbox("Ambient Occlusion", ref v.ambientOcclusion);
			changed |= ImGui.Checkbox("Depth of Field", ref v.depthOfField);
			changed |= ImGui.Checkbox("Motion Blur", ref v.motionBlur);
			StringView[5] giNames = .("Ambient Lighting", "Baked GI", "Half-Resolution SSGI", "Dynamic GI", "Dynamic GI + SSGI");
			if (ImGui.BeginCombo("Global Illumination", scope String(giNames[Math.Clamp((int)v.globalIllumination, 0, 4)]).CStr()))
			{
				for (int i < 5)
				{
					if (ImGui.Selectable(scope String(giNames[i]).CStr(), (int)v.globalIllumination == i))
					{
						v.globalIllumination = (GlobalIlluminationMode)i;
						changed = true;
					}
				}
				ImGui.EndCombo();
			}
			changed |= ImGui.SliderFloat("Detail Distance", ref v.lodBias, 0.25f, 3, "x%.2f");
			changed |= ImGui.SliderFloat("Foliage Distance", ref v.foliageDistance, 0.25f, 3, "x%.2f");
			changed |= ImGui.Checkbox("GPU Skinning", ref v.gpuSkinning);
			// Clusters of big meshes picked on the graphics card: needs compute and indirect draws (Vulkan, Metal).
			ImGui.BeginDisabled(!GpuDriven.Available);
			changed |= ImGui.Checkbox("GPU-Driven Rendering", ref v.gpuDriven);
			ImGui.EndDisabled();
			if (ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
				ImGui.SetTooltip(GpuDriven.Available ? "Draws big meshes from clusters picked on the graphics card, with the level of detail chosen per cluster." : "Needs compute shaders and indirect draws (Vulkan or Metal).");
			let gpuTip = GpuDriven.Available ? "" : "Needs compute shaders and indirect draws (Vulkan or Metal).";
			ImGui.BeginDisabled(!GpuDriven.Available);
			changed |= ImGui.SliderFloat("Pixel Error", ref v.pixelError, 0.5f, 4, "%.1f px");
			ImGui.EndDisabled();
			if (ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
				ImGui.SetTooltip(GpuDriven.Available ? "How many pixels of error the clusters of GPU-driven meshes may have on screen: lower is sharper and costs more." : gpuTip);
			ImGui.BeginDisabled(!GpuDriven.Available);
			changed |= ImGui.Checkbox("GPU Occlusion Culling", ref v.gpuOcclusion);
			ImGui.EndDisabled();
			if (ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
				ImGui.SetTooltip(GpuDriven.Available ? "Leaves out clusters hidden behind other things (also needs the camera's occlusion culling)." : gpuTip);
			ImGui.BeginDisabled(!GpuDriven.Available);
			changed |= ImGui.Checkbox("Stream Geometry", ref v.streamGeometry);
			ImGui.EndDisabled();
			if (ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
				ImGui.SetTooltip(GpuDriven.Available ? "Loads big meshes' geometry in pages as it is needed instead of all at once." : gpuTip);
			ImGui.BeginDisabled(!GpuDriven.Available);
			changed |= ImGui.DragInt("Geometry Budget (MB)", ref v.geometryBudgetMB, 4, 16, 16384);
			changed |= ImGui.DragInt("Texture Budget (MB)", ref v.textureBudgetMB, 4, 16, 16384);
			changed |= ImGui.DragInt("Virtual Texture Budget (MB)", ref v.vtBudgetMB, 4, 16, 16384);
			ImGui.EndDisabled();
			if (ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
				ImGui.SetTooltip(GpuDriven.Available ? "Memory the streamed geometry pages, texture mip levels and virtual-texture tiles may use." : gpuTip);
			changed |= ImGui.Checkbox("Vsync", ref v.vsync);
			var detail = (float)v.textureDetail;
			StringView[4] detailNames = .("full", "half", "quarter", "eighth");
			if (ImGui.SliderFloat(scope String()..AppendF("Texture Detail ({})###texturedetail", detailNames[Math.Clamp(v.textureDetail, 0, 3)]).CStr(), ref detail, 0, 3, ""))
			{
				v.textureDetail = (int32)Math.Round(detail);
				changed = true;
			}
			changed |= ImGui.Checkbox("Anisotropic Filtering", ref v.anisotropic);
			changed |= ImGui.Checkbox("Reflection Probes", ref v.reflectionProbes);
			int32 sizeIndex = v.reflectionSize >= 256 ? (v.reflectionSize >= 512 ? 4 : 3) : (v.reflectionSize >= 128 ? 2 : (v.reflectionSize >= 64 ? 1 : 0));
			var sizeSlider = (float)sizeIndex;
			if (ImGui.SliderFloat(scope String()..AppendF("Reflection Size ({})###reflectionsize", 32 << sizeIndex).CStr(), ref sizeSlider, 0, 4, ""))
			{
				v.reflectionSize = (int32)(32 << (int)Math.Round(sizeSlider));
				changed = true;
			}
			StringView[3] skyNames = .("low", "medium", "high");
			var skySlider = (float)Math.Clamp(v.skyQuality, 0, 2);
			if (ImGui.SliderFloat(scope String()..AppendF("Sky Detail ({})###skydetail", skyNames[Math.Clamp(v.skyQuality, 0, 2)]).CStr(), ref skySlider, 0, 2, ""))
			{
				v.skyQuality = (int32)Math.Round(skySlider);
				changed = true;
			}
			if (changed)
			{
				Quality.Current = v;
				Quality.Apply();
			}
			ImGui.Separator();
			ImGui.TextWrapped("Applies to the Scene and Game views now (Texture Detail to textures loaded from then on). Games set it with Quality.Set, and the player's choice is saved with Quality.Save.");
			ImGui.TextDisabled(scope String()..AppendF("Textures: {} made, {} compressed, {:0.0} MB", Textures.Made, Textures.Compressed, Textures.Bytes / (1024.0 * 1024.0)).CStr());
			if (ImGui.Button("Back to High"))
				Quality.Set(.High);
		}
		ImGui.End();
	}

	/// Antialiasing, Render Scale's quality modes and the Upscaler, with what this machine cannot do greyed out and the
	/// reason in the tooltip. True when something changed.
	bool DrawUpscalerSettings(ref QualityValues v)
	{
		var changed = false;
		StringView[7] aaNames = .("Off", "FXAA", "SMAA", "MSAA 2x", "MSAA 4x", "MSAA 8x", "TAA");
		let aaIndex = Math.Clamp((int)v.antialiasMode, 0, 6);
		if (ImGui.BeginCombo("Antialiasing", scope String(aaNames[aaIndex]).CStr()))
		{
			for (int i < 7)
			{
				let mode = (AntialiasMode)i;
				// What the card cannot do: multisampling it lacks, and TAA without four render targets.
				var reason = scope String();
				var available = true;
				if (Antialiasing.IsMsaa(mode) && !Antialiasing.SamplesSupported(Antialiasing.Samples(mode)))
				{
					available = false;
					reason.Set("This graphics card cannot multisample the scene this much");
				}
				else if (mode == .TAA && !Antialiasing.TemporalAvailable)
				{
					available = false;
					reason.Set("Temporal antialiasing needs a graphics card with four render targets at once; FXAA is used instead");
				}
				if (ImGui.Selectable(scope String(aaNames[i]).CStr(), aaIndex == i, available ? 0 : ImGui.SelectableFlags.Disabled))
				{
					v.antialiasMode = mode;
					changed = true;
				}
				if (!available && ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
					ImGui.SetTooltip(reason.CStr());
			}
			ImGui.EndCombo();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("MSAA smooths edges while the scene is drawn. FXAA and SMAA filter the finished picture (SMAA is cleaner, FXAA cheaper).");

		// The quality modes are render scales: the picture is drawn smaller and the upscaler brings it back up.
		let mode = Upscaling.ModeOfScale(v.renderScale);
		ImGui.TextDisabled(scope String()..AppendF("Render scale mode: {}", mode >= 0 ? Upscaling.ModeNames[mode] : "Custom").CStr());
		for (int32 i < 5)
		{
			if (i > 0 && i != 3)
				ImGui.SameLine();
			if (ImGui.Selectable(scope String(Upscaling.ModeNames[i]).CStr(), mode == i, 0, .(i == 4 ? 130 : 72, 0)))
			{
				v.renderScale = Upscaling.ModeScales[i];
				changed = true;
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip(scope String()..AppendF("Draws the scene at {:0.00} of the window's size.", Upscaling.ModeScales[i]).CStr());
		}

		StringView[4] upscalerNames = .("Off (bilinear)", "FSR 1", "FSR 2", "DLSS");
		let upIndex = Math.Clamp((int)v.upscaler, 0, 3);
		if (ImGui.BeginCombo("Upscaler", scope String(upscalerNames[upIndex]).CStr()))
		{
			for (int i < 4)
			{
				let kind = (UpscalerKind)i;
				let reason = scope String();
				let available = Upscaling.IsSupported(kind, reason);
				if (ImGui.Selectable(scope String(upscalerNames[i]).CStr(), upIndex == i, available ? 0 : ImGui.SelectableFlags.Disabled))
				{
					v.upscaler = kind;
					changed = true;
				}
				if (!available && ImGui.IsItemHovered(ImGui.HoveredFlags.AllowWhenDisabled))
					ImGui.SetTooltip(reason.CStr());
			}
			ImGui.EndCombo();
		}
		if (v.upscaler != .Off && Upscaling.Effective != v.upscaler)
			ImGui.TextDisabled(scope String()..AppendF("In use: {}", upscalerNames[(int)Upscaling.Effective]).CStr());
		if (Upscaling.IsTemporal(Upscaling.Effective))
			ImGui.TextDisabled("DLSS and FSR 2 run in the Game view and the player; the Scene view is drawn at full size.");
		ImGui.SliderFloat("FSR Sharpness", ref Upscaling.Sharpness, 0, 1, "%.2f");
		return changed;
	}
}
