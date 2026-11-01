using System;
using Tallow;

namespace Tallow.Editor;

/// Inspector tools for reflection probes (docs/reflections.md): capturing again, and what the probe has.
extension EditorApp
{
	void DrawReflectionProbeTools(ReflectionProbe probe)
	{
		if (ImGui.Button("Capture Now"))
			probe.Capture();
		ImGui.SameLine();
		ImGui.TextDisabled("(?)");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Draws what the probe sees again, over the next few frames.\nIt captures by itself when moved or changed; this is for when the things around it changed.");
		if (!Reflections.Enabled || !Reflections.ProbesEnabled)
			ImGui.TextDisabled("Reflection probes are off (Window > Graphics Quality).");
		else if (probe.Captured)
			ImGui.TextDisabled(scope String()..AppendF("Captured: {0} x {0}, {1} levels", Reflections.SizeOf(probe), probe.LastLevel + 1).CStr());
		else
			ImGui.TextDisabled("Capturing...");
		ImGui.TextDisabled("Size the box to the room; surfaces in it mirror what the probe sees.");
	}
}
