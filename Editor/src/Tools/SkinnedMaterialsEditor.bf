using System;
using Tallow;

namespace Tallow.Editor;

/// Inspector list of a skinned model's parts (one per material in the file), each with the .tmat it is drawn with
/// instead of the file's own material.
extension EditorApp
{
	void DrawSkinnedParts(SkinnedMeshRenderer skinned)
	{
		let count = skinned.PartCount;
		if (count == 0)
		{
			ImGui.TextDisabled("One material: drawn with the Mesh Renderer's settings.");
			return;
		}
		ImGui.TextDisabled(scope String()..AppendF("{} parts, each with the file's own material unless given one here:", count).CStr());
		if (!BeginPropertyTable("skinnedparts"))
			return;
		let path = scope String();
		for (int i < count)
		{
			ImGui.PushID((int32)i);
			BeginProperty(scope String(skinned.PartName(i)).CStr());
			skinned.GetPartMaterial(skinned.PartName(i), path);
			ImGui.SetNextItemWidth(-1);
			if (ImGui.InputText("##material", path))
			{
				skinned.SetPartMaterial(i, path);
				MarkDirty();
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("A .tmat path, such as Materials/skin.tmat. Empty: the material saved in the model.");
			ImGui.PopID();
		}
		ImGui.EndTable();
	}
}
