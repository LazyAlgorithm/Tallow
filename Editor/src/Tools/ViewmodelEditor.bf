using System;
using Tallow;

namespace Tallow.Editor;

/// Inspector tools for a Viewmodel Pose: take the object's current place as the hip or the aim pose.
extension EditorApp
{
	void DrawViewmodelPoseTools(ViewmodelPose pose)
	{
		if (ImGui.Button("Use current place as Hip"))
		{
			pose.UseCurrentAsHip();
			MarkDirty();
		}
		ImGui.SameLine();
		if (ImGui.Button("Use current place as Aim"))
		{
			pose.UseCurrentAsAim();
			MarkDirty();
		}
		if (pose.Transform.Parent == null || !pose.Transform.Parent.GameObject.GetComponent<Camera>())
			ImGui.TextDisabled("Put this on a child of the camera: it moves the arms and weapon under it.");
		else
			ImGui.TextDisabled("Move the object until it looks right in the Game view, then press a button. Preview blends hip to aim.");
	}
}
