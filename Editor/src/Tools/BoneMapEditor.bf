using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Bone Map window: which joint of a rigged model is each humanoid bone, as matched by name, with a choice of
/// joint for each that saves to a .bonemap file beside the model. Clips retargeted onto the model (or from it) are
/// made again at once as matches change. See docs/retargeting.md.
extension EditorApp
{
	bool mShowBoneMap;
	String mBoneMapModel = new .() ~ delete _;
	BoneMap mBoneMapEdit = new .() ~ delete _;
	bool mBoneMapDirty;

	/// The Inspector's line under a Skinned Mesh Renderer: how much of a humanoid it is, and the Bone Map button.
	void DrawBoneMapLine(SkinnedMeshRenderer skinned)
	{
		let map = skinned.Model.HumanMap;
		ImGui.TextDisabled(map.IsHumanoid ? scope String()..AppendF("Humanoid: {} of {} bones matched", map.Matched, BoneMap.Count).CStr() : "Not matched as a humanoid (no hips found)");
		ImGui.SameLine();
		if (ImGui.SmallButton("Bone Map..."))
			OpenBoneMap(skinned.Model);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Which joint is each humanoid bone. Clips from other humanoids (Clip Library) are\nretargeted through it.");
	}

	void OpenBoneMap(SkinnedModel model)
	{
		mBoneMapModel.Set(model.Path);
		mBoneMapEdit.CopyFrom(model.HumanMap);
		mBoneMapDirty = false;
		mShowBoneMap = true;
	}

	void DrawBoneMap()
	{
		if (!mShowBoneMap)
			return;
		let model = mBoneMapModel.IsEmpty || !SkinnedModel.IsLoaded(mBoneMapModel) ? null : SkinnedModel.Load(mBoneMapModel);
		ImGui.SetNextWindowSize(.(460, 560), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Bone Map", &mShowBoneMap) && model != null)
			DrawBoneMapContents(model);
		ImGui.End();
	}

	void DrawBoneMapContents(SkinnedModel model)
	{
		ImGui.Text(mBoneMapModel);
		ImGui.TextDisabled(scope String()..AppendF("{} of {} bones matched{}", mBoneMapEdit.Matched, BoneMap.Count, mBoneMapDirty ? " (not saved)" : "").CStr());
		if (ImGui.Button("Match by Name"))
		{
			mBoneMapEdit.Match(model);
			model.SetHumanMap(mBoneMapEdit);
			mBoneMapDirty = true;
		}
		ImGui.SameLine();
		ImGui.BeginDisabled(!mBoneMapDirty);
		if (ImGui.Button("Save"))
			SaveBoneMap(model);
		ImGui.SameLine();
		if (ImGui.Button("Revert"))
		{
			SkinnedModel.ReloadBoneMaps();
			mBoneMapEdit.CopyFrom(model.HumanMap);
			mBoneMapDirty = false;
		}
		ImGui.EndDisabled();
		ImGui.Separator();
		if (!ImGui.BeginChild("bones", .(0, 0)))
		{
			ImGui.EndChild();
			return;
		}
		if (BeginPropertyTable("bonemap"))
		{
			let name = scope String();
			for (int b < BoneMap.Count)
			{
				let bone = (HumanBone)b;
				if (bone == .LeftShoulder || bone == .LeftUpperLeg || bone == .LeftThumb1)
				{
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.SeparatorText(bone == .LeftShoulder ? "Arms" : (bone == .LeftUpperLeg ? "Legs" : "Fingers"));
				}
				name.Clear();
				BoneMap.BoneName(bone, name);
				ImGui.PushID((int32)b);
				BeginProperty(name.CStr());
				let current = mBoneMapEdit[bone];
				ImGui.SetNextItemWidth(-1);
				if (ImGui.BeginCombo("##joint", current.IsEmpty ? "(none)" : scope String(current).CStr()))
				{
					if (ImGui.Selectable("(none)", current.IsEmpty))
						SetBoneMapJoint(model, bone, "");
					for (let joint in model.Joints)
					{
						if (ImGui.Selectable(joint.name.CStr(), joint.name == current))
							SetBoneMapJoint(model, bone, joint.name);
					}
					ImGui.EndCombo();
				}
				ImGui.PopID();
			}
			ImGui.EndTable();
		}
		ImGui.EndChild();
	}

	void SetBoneMapJoint(SkinnedModel model, HumanBone bone, StringView joint)
	{
		mBoneMapEdit[bone] = joint;
		model.SetHumanMap(mBoneMapEdit);
		mBoneMapDirty = true;
	}

	/// Writes the map beside the model and has every loaded model read its map again.
	void SaveBoneMap(SkinnedModel model)
	{
		let relative = scope String();
		if (!model.GetBoneMapPath(relative))
			return;
		let full = scope String();
		Assets.ResolvePath(relative, full);
		let text = scope String();
		mBoneMapEdit.Write(text);
		if (File.WriteAllText(full, text) case .Err)
		{
			Log.Error(scope $"Could not write {full}.");
			return;
		}
		SkinnedModel.ReloadBoneMaps();
		mBoneMapEdit.CopyFrom(model.HumanMap);
		mBoneMapDirty = false;
		Log.Info(scope $"Saved {relative}.");
	}
}
