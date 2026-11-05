using System;
using Tallow;

namespace Tallow.Editor;

/// Inspector tools under an LOD Group: its levels, what the Scene view's camera sees, and previewing one level.
extension EditorApp
{
	void DrawLODGroupTools(LODGroup group)
	{
		let level = group.LevelFor(mSceneCamera);
		let height = group.ScreenHeight(mSceneCamera);
		ImGui.Text(scope String()..AppendF("Scene view: {:0.#}% of the screen's height, {}", height * 100, level < 0 ? "not drawn" : scope String()..AppendF("level {}", level)));
		for (int32 i < group.LevelCount)
		{
			int renderers = 0, triangles = 0;
			for (let renderer in group.Renderers)
			{
				var mesh = renderer.ActiveMesh;
				mesh = group.MeshAt(renderer.Proxy, mesh, i);
				if (mesh == null)
					continue;
				renderers++;
				triangles += mesh.Indices.Count / 3;
			}
			let below = i == 0 ? 1 : (i == 1 ? group.level1Below : (i == 2 ? group.level2Below : group.level3Below));
			ImGui.TextDisabled(scope String()..AppendF("  Level {}: {} renderer(s), {} triangles, below {:0.#}%", i, renderers, triangles, below * 100).CStr());
		}
		if (group.source == .Children && group.LevelCount == 1)
			ImGui.TextColored(EditorTheme.Warning, "No children named _LOD1, _LOD2 ... found: name them so, or use Generated.");
		ImGui.Text("Preview");
		for (int32 i = -1; i < group.LevelCount; i++)
		{
			ImGui.SameLine();
			ImGui.PushID(i);
			let active = LODGroup.ForceLevel == i;
			if (active)
				ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
			if (ImGui.SmallButton(i < 0 ? "Auto" : scope String()..AppendF("{}", i).CStr()))
				LODGroup.ForceLevel = i;
			if (active)
				ImGui.PopStyleColor();
			ImGui.PopID();
		}
		ImGui.TextDisabled("Preview shows every LOD Group at that level, in the Scene and Game views.");
	}
}
