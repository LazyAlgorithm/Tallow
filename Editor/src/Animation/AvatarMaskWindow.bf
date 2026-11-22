using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Avatar Mask window: which parts of a body an Animator layer may move (.tmask file), as Unity's Avatar Mask
/// has them. The top half is the humanoid body parts (hips, spine, head, each arm, leg and fingers); the bottom half
/// lists the bones of the selected character, each with a weight, for leaving out one bone in the middle of a part
/// or for a soft edge. A mask is set on a layer in the Animator window.
extension EditorApp
{
	bool mShowAvatarMask;
	bool mDockAvatarMask;
	bool mAvatarMaskFocus;
	AvatarMask mAvatarMask;
	String mAvatarMaskPath = new .() ~ delete _;
	String mAvatarMaskRelative = new .() ~ delete _;
	bool mAvatarMaskDirty;
	/// The selected character's bones, for the bone list: names, their parents' indexes and their depths.
	List<String> mAvatarMaskBones = new .() ~ DeleteContainerAndItems!(_);
	List<int32> mAvatarMaskParents = new .() ~ delete _;
	List<int32> mAvatarMaskDepth = new .() ~ delete _;
	BoneMap mAvatarMaskMap = new .() ~ delete _;
	uint32 mAvatarMaskBonesFor;
	int64 mAvatarMaskBonesFrame = -1000;
	/// The weight each bone gets now, to show inherited weights and to resolve a click.
	float[] mAvatarMaskWeights ~ delete _;
	int32 mAvatarMaskWeightsRevision = -1;
	uint32 mAvatarMaskWeightsFor;

	/// Opens a mask file (a full path) in the Avatar Mask window, saving the one open before.
	public void OpenAvatarMask(StringView fullPath)
	{
		if (mAvatarMask != null && mAvatarMaskDirty)
			SaveAvatarMask();
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		let mask = AvatarMask.Load(relative);
		if (mask == null)
			return;
		mAvatarMask = mask;
		mAvatarMaskPath.Set(fullPath);
		mAvatarMaskRelative.Set(relative);
		mAvatarMaskDirty = false;
		mAvatarMaskWeightsRevision = -1;
		mShowAvatarMask = true;
		mDockAvatarMask = true;
		mAvatarMaskFocus = true;
	}

	/// Project > + > Avatar Mask: an empty mask, which moves the whole body until parts or bones are chosen.
	void CreateAvatarMaskAsset(StringView name)
	{
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Avatar mask names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.tmask";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		let relative = scope String();
		Assets.MakeRelative(path, relative);
		let mask = AvatarMask.Create(relative, name);
		mask.Save(path);
		OpenAvatarMask(path);
	}

	void SaveAvatarMask()
	{
		if (mAvatarMask == null || mAvatarMaskPath.IsEmpty)
			return;
		mAvatarMask.Save(mAvatarMaskPath);
		mAvatarMaskDirty = false;
	}

	void DrawAvatarMask()
	{
		if (!mShowAvatarMask)
			return;
		if (mDockAvatarMask && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockAvatarMask = false;
		}
		if (mAvatarMaskFocus && Time.FrameCount > 30)
		{
			ImGui.SetNextWindowFocus();
			mAvatarMaskFocus = false;
		}
		ImGui.SetNextWindowSize(.(500, 620), ImGui.Cond.FirstUseEver);
		let visible = ImGui.Begin("Avatar Mask", &mShowAvatarMask);
		if (visible && mAvatarMask == null)
			ImGui.TextDisabled("Create a mask with Project > + > Avatar Mask, or double-click a .tmask file.");
		else if (visible)
			DrawAvatarMaskContents();
		ImGui.End();
		if (!mShowAvatarMask && mAvatarMaskDirty)
			SaveAvatarMask();
	}

	void DrawAvatarMaskContents()
	{
		if (ImGui.SmallButton("Save"))
			SaveAvatarMask();
		ImGui.SameLine();
		ImGui.BeginDisabled(!mAvatarMaskDirty);
		if (ImGui.SmallButton("Revert"))
		{
			mAvatarMaskDirty = false;
			OpenAvatarMask(scope String(mAvatarMaskPath));
		}
		ImGui.EndDisabled();
		ImGui.SameLine(0, 14);
		ImGui.TextDisabled(scope String()..AppendF("{}{}", mAvatarMaskRelative, mAvatarMaskDirty ? " *" : "").CStr());
		ImGui.Separator();

		RefreshAvatarMaskBones();
		RefreshAvatarMaskWeights();
		if (!ImGui.BeginChild("parts"))
		{
			ImGui.EndChild();
			return;
		}
		DrawAvatarMaskParts();

		ImGui.SeparatorText("Bone Weights");
		if (mAvatarMaskBones.IsEmpty)
			ImGui.TextDisabled("Select a character in the scene to set one bone at a time.\nThe parts above work on any character.");
		else
		{
			ImGui.TextDisabled("A bone takes the bones below it, until one of them says otherwise. 0 leaves it out.");
			if (!ImGui.BeginChild("bones", .(0, 0), 0))
			{
				ImGui.EndChild();
				ImGui.EndChild();
				return;
			}
			DrawAvatarMaskBones();
			ImGui.EndChild();
		}
		ImGui.EndChild();
	}

	/// The humanoid parts, grouped the way Unity groups them. A group is all of its bones on when every one is.
	void DrawAvatarMaskParts()
	{
		ImGui.SeparatorText("Body");
		PartCheck(.Hips, "Hips");
		ImGui.SameLine();
		PartCheck(.Spine, "Spine");
		ImGui.SameLine();
		PartCheck(.Chest, "Chest");
		ImGui.SameLine();
		PartCheck(.UpperChest, "Upper Chest");
		ImGui.SameLine();
		PartCheck(.Neck, "Neck");
		ImGui.SameLine();
		PartCheck(.Head, "Head");

		DrawAvatarMaskArm("Left Arm", .LeftShoulder);
		DrawAvatarMaskArm("Right Arm", .RightShoulder);
		DrawAvatarMaskLeg("Left Leg", .LeftUpperLeg);
		DrawAvatarMaskLeg("Right Leg", .RightUpperLeg);

		ImGui.Dummy(.(0, 4));
		if (ImGui.SmallButton("All Parts"))
		{
			mAvatarMask.SetAllParts(true);
			mAvatarMaskDirty = true;
		}
		ImGui.SameLine();
		if (ImGui.SmallButton("No Parts"))
		{
			mAvatarMask.SetAllParts(false);
			mAvatarMaskDirty = true;
		}
		ImGui.SameLine();
		ImGui.TextDisabled("No parts and no bones: the whole body.");
	}

	void DrawAvatarMaskArm(char8* label, HumanBone first)
	{
		ImGui.SeparatorText(label);
		PartCheck(first, "Shoulder");
		ImGui.SameLine();
		PartCheck((HumanBone)((int)first + 1), "Upper Arm");
		ImGui.SameLine();
		PartCheck((HumanBone)((int)first + 2), "Lower Arm");
		ImGui.SameLine();
		PartCheck((HumanBone)((int)first + 3), "Hand");
		ImGui.SameLine();
		// The fifteen finger bones, as one toggle.
		var fingers = true;
		let fingerFirst = first == .LeftShoulder ? HumanBone.LeftThumb1 : HumanBone.RightThumb1;
		for (int i < 15)
		{
			if (!mAvatarMask.HasPart((HumanBone)((int)fingerFirst + i)))
				fingers = false;
		}
		ImGui.PushID((int32)first);
		if (ImGui.Checkbox("Fingers", ref fingers))
		{
			for (int i < 15)
				mAvatarMask.SetPart((HumanBone)((int)fingerFirst + i), fingers);
			mAvatarMaskDirty = true;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("All five fingers. Set one at a time with its bone weight below.");
		ImGui.PopID();
	}

	void DrawAvatarMaskLeg(char8* label, HumanBone first)
	{
		ImGui.SeparatorText(label);
		PartCheck(first, "Upper Leg");
		ImGui.SameLine();
		PartCheck((HumanBone)((int)first + 1), "Lower Leg");
		ImGui.SameLine();
		PartCheck((HumanBone)((int)first + 2), "Foot");
		ImGui.SameLine();
		PartCheck((HumanBone)((int)first + 3), "Toes");
	}

	void PartCheck(HumanBone part, char8* label)
	{
		var on = mAvatarMask.HasPart(part);
		ImGui.PushID((int32)part);
		if (ImGui.Checkbox(label, ref on))
		{
			mAvatarMask.SetPart(part, on);
			mAvatarMaskDirty = true;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Moves this bone and the ones below it, unless a bone weight says otherwise.");
		ImGui.PopID();
	}

	/// The selected character's bones for the list, with their parents: a rigged model's joints when it has one
	/// (their names on exposed bones are the joints'), otherwise the Animator's child objects.
	void RefreshAvatarMaskBones()
	{
		let character = AvatarMaskCharacter();
		if (character == null)
		{
			if (mAvatarMaskBonesFor != 0)
			{
				ClearAndDeleteItems!(mAvatarMaskBones);
				mAvatarMaskParents.Clear();
				mAvatarMaskDepth.Clear();
				mAvatarMaskMap.Clear();
				mAvatarMaskBonesFor = 0;
			}
			return;
		}
		if (mAvatarMaskBonesFor == character.Id && Time.FrameCount - mAvatarMaskBonesFrame < 60)
			return;
		mAvatarMaskBonesFor = character.Id;
		mAvatarMaskBonesFrame = Time.FrameCount;
		ClearAndDeleteItems!(mAvatarMaskBones);
		mAvatarMaskParents.Clear();
		mAvatarMaskDepth.Clear();
		mAvatarMaskMap.Clear();
		let skinned = FindSkinnedOn(character);
		if (skinned && skinned.Model != null)
		{
			let model = skinned.Model;
			mAvatarMaskMap.CopyFrom(model.HumanMap);
			for (let joint in model.Joints)
			{
				mAvatarMaskBones.Add(new String(joint.name));
				mAvatarMaskParents.Add(joint.parent);
			}
		}
		else
		{
			var root = character.Transform;
			for (var at = character; at != null; at = at.Transform.Parent?.GameObject)
			{
				if (at.GetComponent<Animator>().IsValid)
				{
					root = at.Transform;
					break;
				}
			}
			void Walk(Transform parent, int32 parentIndex)
			{
				for (let child in parent.Children)
				{
					mAvatarMaskBones.Add(new String(child.GameObject.Name));
					mAvatarMaskParents.Add(parentIndex);
					Walk(child, (int32)mAvatarMaskBones.Count - 1);
				}
			}
			Walk(root, -1);
		}
		for (int i < mAvatarMaskBones.Count)
		{
			int32 depth = 0;
			for (var at = mAvatarMaskParents[i]; at >= 0 && depth <= i; at = mAvatarMaskParents[at])
				depth++;
			mAvatarMaskDepth.Add(depth);
		}
		mAvatarMaskWeightsRevision = -1;
	}

	GameObject AvatarMaskCharacter()
	{
		var object = Selected;
		while (object != null)
		{
			if (object.HasComponent<Animator>() || object.HasComponent<SkinnedMeshRenderer>())
				return object;
			object = object.Transform.Parent?.GameObject;
		}
		return null;
	}

	static SkinnedMeshRenderer FindSkinnedOn(GameObject object)
	{
		let own = object.GetComponent<SkinnedMeshRenderer>();
		if (own)
			return own;
		for (let child in object.Transform.Children)
		{
			let found = child.GameObject.GetComponent<SkinnedMeshRenderer>();
			if (found)
				return found;
		}
		return default;
	}

	/// Each bone's weight now, from the parts and bone weights together (the Animator's own resolution, so the
	/// window shows what a layer will do).
	void RefreshAvatarMaskWeights()
	{
		if (mAvatarMaskBones.IsEmpty)
		{
			delete mAvatarMaskWeights;
			mAvatarMaskWeightsRevision = -1;
			return;
		}
		if (mAvatarMaskWeights != null && mAvatarMaskWeights.Count == mAvatarMaskBones.Count
			&& mAvatarMaskWeightsRevision == mAvatarMask.Revision && mAvatarMaskWeightsFor == mAvatarMaskBonesFor)
			return;
		delete mAvatarMaskWeights;
		mAvatarMaskWeights = new .[mAvatarMaskBones.Count];
		List<StringView> names = scope .();
		for (let bone in mAvatarMaskBones)
			names.Add(bone);
		let map = mAvatarMaskMap.IsHumanoid ? mAvatarMaskMap : null;
		mAvatarMask.Resolve(names, mAvatarMaskParents, map, mAvatarMaskWeights);
		mAvatarMaskWeightsRevision = mAvatarMask.Revision;
		mAvatarMaskWeightsFor = mAvatarMaskBonesFor;
	}

	void DrawAvatarMaskBones()
	{
		if (ImGui.SmallButton("Clear Bone Weights"))
		{
			mAvatarMask.RemoveAllBones();
			mAvatarMaskDirty = true;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Every bone goes with its part again.");
		ImGui.Separator();
		bool anyWeights = false;
		for (int i < mAvatarMaskBones.Count)
		{
			let name = mAvatarMaskBones[i];
			let weight = mAvatarMaskWeights != null && i < mAvatarMaskWeights.Count ? mAvatarMaskWeights[i] : 0;
			float own = 0;
			let hasOwn = mAvatarMask.TryGetBone(name, out own);
			anyWeights |= hasOwn;
			ImGui.PushID((int32)i);
			ImGui.SetCursorPosX(8 + Math.Min(mAvatarMaskDepth[i], 20) * 12);
			var on = weight > 0.5f;
			if (ImGui.Checkbox("##on", ref on))
			{
				mAvatarMask.SetBone(name, on ? 1 : 0);
				mAvatarMaskDirty = true;
			}
			ImGui.SameLine();
			if (hasOwn)
			{
				ImGui.Text(name);
				ImGui.SameLine();
				ImGui.SetNextItemWidth(70);
				var ownValue = own;
				if (ImGui.DragFloat("##weight", ref ownValue, 0.01f, 0, 1))
				{
					mAvatarMask.SetBone(name, ownValue);
					mAvatarMaskDirty = true;
				}
				ImGui.SameLine();
				if (ImGui.SmallButton("x"))
				{
					mAvatarMask.RemoveBone(name);
					mAvatarMaskDirty = true;
				}
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("Goes with the part above it again.");
			}
			else
			{
				ImGui.TextDisabled(name.CStr());
				ImGui.SameLine();
				ImGui.TextDisabled(scope String()..AppendF("{:0.##}", weight).CStr());
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("Inherited: set by a part or a bone above it. Click the box to set this bone on its own.");
			}
			ImGui.PopID();
		}
		if (!anyWeights)
			ImGui.TextDisabled("No bone has a weight of its own.");
	}
}
