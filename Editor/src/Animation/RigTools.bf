using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// The Animation window's helpers for rigged characters: its Rig menu (showing the bones, an IK rig in one press,
/// IK targets snapped to the bones, IK baked into keys, a model's own clip copied into the open one to edit) and
/// the Hand Posing window (finger shapes and curls, keyed in one press). See docs/animator.md.
extension EditorApp
{
	bool mShowHandPosing;
	bool mFocusHandPosing;
	int32 mRigTestFrames;

	/// The names the IK rig gives its targets and poles, below the Animator's object, so that clips key them.
	static readonly StringView[4] RigLimbs = .("Hand L", "Hand R", "Foot L", "Foot R");

	/// The footer's Rig and Hands buttons, from where x is; returns where they end.
	float DrawRigButtons(Animator animator, float x, float y)
	{
		ImGui.SetCursorScreenPos(.(x, y));
		if (ImGui.Button("Rig", .(0, ImGui.GetFrameHeight())))
			ImGui.OpenPopup("##rigmenu");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Bones, IK rig and baking for a rigged character.");
		ImGui.SameLine();
		if (ImGui.Button("Hands", .(0, ImGui.GetFrameHeight())))
		{
			mShowHandPosing = true;
			mFocusHandPosing = true;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Pose the fingers with sliders and ready-made shapes, and key them.");
		ImGui.SameLine();
		let end = ImGui.GetCursorScreenPos().x;
		if (ImGui.BeginPopup("##rigmenu"))
		{
			DrawRigMenu(animator);
			ImGui.EndPopup();
		}
		return end;
	}

	void DrawRigMenu(Animator animator)
	{
		let editing = mPlay == .Edit;
		let skinned = FindSkinned(animator);
		if (skinned == null)
		{
			ImGui.TextDisabled("No Skinned Mesh Renderer on this object or below it.");
			return;
		}
		if (!skinned.exposeBones)
		{
			if (ImGui.MenuItem("Expose Bones", null, false, editing))
			{
				skinned.exposeBones = true;
				skinned.OnFrame();
				MarkDirty();
			}
			ImGui.TextDisabled("Bones need to be objects to be posed and keyed.");
			return;
		}
		if (ImGui.MenuItem("Show Bones in the Scene View", null, mShowBones))
			mShowBones = !mShowBones;
		ImGui.Separator();
		let humanoid = skinned.Model != null && skinned.Model.HumanMap.IsHumanoid;
		if (ImGui.MenuItem("Set Up IK Rig", null, false, editing && humanoid))
			SetUpIKRig(animator, skinned);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Adds hand and foot targets (with Limb IK), elbow and knee poles and a look target below\nthis object. Key them with Record or Auto Key to animate the limbs by their ends.");
		if (ImGui.MenuItem("Snap IK Targets to Bones", null, false, editing && mClip != null))
			SnapIKTargets(animator);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Moves every IK target and pole to where the clip alone puts its hand or foot at the marker,\nso that turning IK on changes nothing until a target is moved.");
		if (ImGui.MenuItem("Bake IK Into Keys", null, false, editing && mClip != null))
			BakeIK(animator);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Keys the pose IK makes on every frame of the clip into the bones it moves, so the clip plays\nit with no IK components needed.");
		if (!humanoid)
			ImGui.TextDisabled("The IK rig needs a humanoid skeleton (see Bone Map in the Inspector).");
		ImGui.Separator();
		if (skinned.Model != null && ImGui.BeginMenu("Copy Model Clip Into This Clip", editing && mClip != null))
		{
			for (let source in skinned.Model.Clips)
			{
				if (ImGui.MenuItem(source.name.CStr()))
					CopyModelClip(animator, skinned, source);
			}
			ImGui.EndMenu();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("A key on every bone on every frame of one of the model's clips (retargeted ones too),\nwritten into the open clip so that it can be changed here.");
	}

	/// Finds a child by name, or makes it, at a place and turn.
	Transform RigObject(Transform parent, StringView name, Vector3 position, Quaternion rotation)
	{
		for (let child in parent.Children)
		{
			if (child.GameObject.Name == name)
				return child;
		}
		let made = mScene.CreateGameObject(name, parent).Transform;
		made.Position = position;
		made.Rotation = rotation;
		return made;
	}

	/// The way the character faces, from its left side to its right (across the hips or the shoulders).
	static Vector3 RigForward(SkinnedMeshRenderer skinned, Transform fallback)
	{
		let forward = LimbIK.HumanForward(skinned);
		return forward != .Zero ? forward : fallback.Forward;
	}

	/// Set Up IK Rig: for each hand and foot a target object holding a Limb IK, a pole the elbow or knee points at,
	/// and a look target for the head, all where the character is now, so that nothing moves until they do.
	void SetUpIKRig(Animator animator, SkinnedMeshRenderer skinned)
	{
		let map = skinned.Model.HumanMap;
		let root = animator.Transform;
		let forward = RigForward(skinned, root);
		HumanBone[4] tips = .(.LeftHand, .RightHand, .LeftFoot, .RightFoot);
		int made = 0;
		for (int i < 4)
		{
			let tip = skinned.Bone(map[tips[i]]);
			if (tip == null || tip.Parent == null || tip.Parent.Parent == null)
				continue;
			let middle = tip.Parent;
			let upper = middle.Parent;
			let target = RigObject(root, scope $"IK {RigLimbs[i]}" , tip.Position, tip.Rotation);
			var limb = target.GameObject.GetComponent<LimbIK>();
			if (limb == null)
				limb = target.GameObject.AddComponent<LimbIK>();
			limb.tip = tip;
			limb.target = target;
			// The pole sits out from the elbow or knee the way it bends now, or behind (elbows) or in front (knees)
			// when the limb is nearly straight or bent clearly the wrong way.
			let length = (middle.Position - upper.Position).Length;
			var bend = middle.Position - (upper.Position + tip.Position) * 0.5f;
			let natural = i < 2 ? -forward : forward;
			if (bend.Length < length * 0.05f || Vector3.Dot(bend.Normalized, natural) < -0.5f)
				bend = natural;
			let poleName = scope $"IK {(i < 2 ? "Elbow" : "Knee")} {RigLimbs[i].Substring(5)}";
			limb.pole = RigObject(root, poleName, middle.Position + bend.Normalized * Math.Max(length, 0.1f), .Identity);
			made++;
		}
		let head = skinned.Bone(map[.Head]);
		if (head != null)
		{
			let look = RigObject(root, "IK Look", head.Position + forward * 1.5f, .Identity);
			var lookAt = look.GameObject.GetComponent<LookAtIK>();
			if (lookAt == null)
				lookAt = look.GameObject.AddComponent<LookAtIK>();
			lookAt.bone = head;
			lookAt.target = look;
			lookAt.forward = (head.Rotation.Conjugate * forward).Normalized;
			made++;
		}
		IKSystem.Solve(mScene);
		MarkDirty();
		Log.Info(scope $"IK rig: {made} targets below {animator.GameObject.Name}. Move them with Record or Auto Key on to animate.");
	}

	/// The Limb IK and Look At IK components working on bones below the Animator.
	void RigComponents(Animator animator, List<IKComponent> found)
	{
		for (let component in mScene.Components)
		{
			if (let limb = component as LimbIK)
			{
				if (limb.tip != null && IsBelow(limb.tip, animator.Transform))
					found.Add(limb);
			}
			else if (let look = component as LookAtIK)
			{
				if (look.bone != null && IsBelow(look.bone, animator.Transform))
					found.Add(look);
			}
		}
	}

	/// Snap IK Targets to Bones: the clip alone (no IK) poses the character at the marker, and each target takes
	/// its hand's or foot's place and turn, each pole a place out from its elbow or knee.
	void SnapIKTargets(Animator animator)
	{
		let components = scope List<IKComponent>();
		RigComponents(animator, components);
		animator.SampleClip(mClip, mClipTime);
		for (let component in components)
		{
			if (let limb = component as LimbIK)
			{
				if (limb.target != null)
				{
					limb.target.Position = limb.tip.Position;
					limb.target.Rotation = (limb.tip.Rotation * Quaternion.Euler(limb.rotationOffset).Conjugate).Normalized;
				}
				if (limb.pole != null && limb.Middle != null && limb.Upper != null)
				{
					let length = (limb.Middle.Position - limb.Upper.Position).Length;
					let bend = limb.Middle.Position - (limb.Upper.Position + limb.tip.Position) * 0.5f;
					if (bend.Length > length * 0.05f)
						limb.pole.Position = limb.Middle.Position + bend.Normalized * Math.Max(length, 0.1f);
				}
			}
		}
		IKSystem.Solve(mScene);
		mClipPosedTime = mClipTime;
		MarkDirty();
	}

	/// Bake IK Into Keys: Key IK on every frame of the clip (at its sample rate, 30 a second at most).
	void BakeIK(Animator animator)
	{
		let marker = mClipTime;
		let rate = Math.Min(mClip.frameRate > 0 ? (float)mClip.frameRate : 30, 30);
		let frames = (int)Math.Round(mClip.duration * rate);
		for (int f <= frames)
		{
			mClipTime = Math.Min(f / rate, mClip.duration);
			animator.SampleClip(mClip, mClipTime);
			KeyIK(animator);
		}
		mClipTime = marker;
		mClipPosedTime = -1;
		Log.Info(scope $"Baked IK into {frames + 1} frames. Set the IK components' Weight to 0 to see the clip alone.");
	}

	/// Copy Model Clip Into This Clip: every bone the clip moves keyed on every frame of one of the model's clips.
	void CopyModelClip(Animator animator, SkinnedMeshRenderer skinned, SkinnedModel.Clip source)
	{
		let marker = mClipTime;
		// Bones the clip never moves from their scene pose (helper joints, often) get no keys.
		let moves = scope bool[skinned.BoneCount];
		for (int f < source.frames)
		{
			if (!skinned.PoseBones(source.name, f / 30.0f))
				break;
			for (int j < skinned.BoneCount)
			{
				let bone = skinned.BoneAt(j);
				if (bone == null || moves[j])
					continue;
				Vector3 position, scale;
				Quaternion rotation;
				if (!animator.RestPose(bone, out position, out rotation, out scale))
					continue;
				moves[j] = (bone.LocalPosition - position).Length > 0.0001f || Math.Abs(Quaternion.Dot(bone.LocalRotation, rotation)) < 0.99999f;
			}
		}
		for (int f < source.frames)
		{
			let time = f / 30.0f;
			if (!skinned.PoseBones(source.name, time))
				break;
			mClipTime = time;
			for (int j < skinned.BoneCount)
			{
				let bone = skinned.BoneAt(j);
				if (bone != null && moves[j])
					KeyChild(animator, bone, true);
			}
		}
		mClip.duration = source.duration;
		mClipTime = marker;
		mClipPosedTime = -1;
		mClipDirty = true;
		Log.Info(scope $"Copied {source.name}: {source.frames} frames of {skinned.BoneCount} bones.");
	}

	/// Test switches, applied to the selection (--select): --ik-rig sets up an IK rig on its Animator, --hand-shape
	/// <Fist> poses both hands in a ready-made shape and opens Hand Posing, --hand-posing opens it, --bone-map opens
	/// the Bone Map of the rigged model.
	void ApplyRigSwitches()
	{
		let animator = SelectedAnimator();
		let skinned = animator != null ? FindSkinned(animator) : BoneOwner(Selected);
		if (HasArg("--bone-map") && skinned != null && skinned.Model != null)
			OpenBoneMap(skinned.Model);
		if (HasArg("--hand-posing"))
			mShowHandPosing = true;
		// Waits for the Scene view to be laid out, since the test clicks on a bone.
		if (HasArg("--rig-test"))
			mRigTestFrames = 20;
		if (animator == null || skinned == null || skinned.Model == null)
			return;
		if (HasArg("--ik-rig"))
			SetUpIKRig(animator, skinned);
		let shapeName = scope String();
		if (GetArg("--hand-shape", shapeName))
		{
			mShowHandPosing = true;
			for (let bone in HumanBone[2](.LeftHand, .RightHand))
			{
				let pose = HandPoseOn(animator, skinned.Bone(skinned.Model.HumanMap[bone]), true);
				if (pose != null && Enum.Parse<HandShape>(shapeName, true) case .Ok(let shape))
				{
					pose.shape = shape;
					pose.OnValidate();
				}
			}
			IKSystem.Solve(mScene);
		}
	}

	/// Test switch --rig-test (with --select on a rigged character's Animator): copies a library clip into a new
	/// clip, sets up an IK rig and moves a hand by its target, bakes IK, keys a fist and clicks a bone, then logs
	/// RIG-TEST PASS or FAIL with what it saw.
	void RunRigTest()
	{
		let animator = SelectedAnimator();
		let skinned = animator != null ? FindSkinned(animator) : null;
		if (skinned == null || skinned.Model == null || skinned.BoneCount == 0)
		{
			Log.Info("RIG-TEST FAIL: select a rigged character's Animator, with Expose Bones on");
			return;
		}
		bool pass = true;
		let report = scope String();
		let model = skinned.Model;
		CreateClipFor(animator);
		SkinnedModel.Clip source = model.Clips[0];
		for (let clip in model.Clips)
		{
			if (model.IsImported(clip))
				source = clip;
		}
		CopyModelClip(animator, skinned, source);
		let copied = mClip.tracks.Count >= 20 && Math.Abs(mClip.duration - source.duration) < 0.05f;
		report.AppendF("copied {} into {} tracks over {:0.00} s: {}; ", source.name, mClip.tracks.Count, mClip.duration, copied);
		pass &= copied;

		mClipTime = 0;
		animator.SampleClip(mClip, 0);
		SetUpIKRig(animator, skinned);
		let hand = skinned.Bone(model.HumanMap[.LeftHand]);
		Transform target = null;
		for (let child in animator.Transform.Children)
		{
			if (child.GameObject.Name == "IK Hand L")
				target = child;
		}
		let rigged = target != null && target.GameObject.GetComponent<LimbIK>() != null && hand != null && (target.Position - hand.Position).Length < 0.001f;
		report.AppendF("IK rig made, target on the hand: {}; ", rigged);
		pass &= rigged;
		if (rigged)
		{
			target.Position = target.Position + .(0, 0.15f, 0.1f);
			IKSystem.Solve(mScene);
			let reached = (hand.Position - target.Position).Length;
			report.AppendF("hand follows its target ({:0.000} m off); ", reached);
			pass &= reached < 0.01f;
			let keysBefore = mClip.FindTrack(hand.GameObject.Name)?.keys.Count ?? 0;
			BakeIK(animator);
			let keysAfter = mClip.FindTrack(hand.GameObject.Name)?.keys.Count ?? 0;
			report.AppendF("baked hand keys {} -> {}; ", keysBefore, keysAfter);
			pass &= keysAfter >= keysBefore;
			animator.SampleClip(mClip, 0);
			IKSystem.Solve(mScene);
		}

		let pose = HandPoseOn(animator, hand, true);
		if (pose != null)
		{
			pose.shape = .Fist;
			pose.OnValidate();
			IKSystem.Solve(mScene);
			int fingerTracks = 0;
			let fingers = scope List<Transform>();
			Descendants(hand, fingers);
			KeyFingers(animator, hand);
			for (let bone in fingers)
			{
				if (mClip.FindTrack(bone.GameObject.Name) != null)
					fingerTracks++;
			}
			report.AppendF("fist keyed on {} finger bones, Hand Pose handed back: {}; ", fingerTracks, pose.weight == 0);
			pass &= fingerTracks >= 4 && pose.weight == 0;
		}

		// Click halfway along the left forearm in the Scene view.
		let forearm = skinned.Bone(model.HumanMap[.LeftLowerArm]);
		mSelectedId = skinned.GameObject.Id;
		mGizmoOperation = 0;
		BuildBoneGizmos();
		Vector2 screen = default;
		bool seen = false;
		for (let pick in mBonePicks)
		{
			if (pick.transform == forearm && !pick.handle)
				seen = SceneScreenPoint(mSceneCamera.projection * mSceneCamera.view, (pick.head + pick.tail) * 0.5f, out screen);
		}
		let picked = seen && PickBone(screen.x / mSceneSize.x, screen.y / mSceneSize.y) && Selected == forearm.GameObject && mGizmoOperation == 1;
		report.AppendF("clicking the forearm selects it with the Rotate handle: {}", picked);
		pass &= picked;
		Log.Info(scope $"RIG-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}

	// ---- the Hand Posing window ----

	void DrawHandPosing()
	{
		if (mRigTestFrames > 0 && --mRigTestFrames == 0)
			RunRigTest();
		if (!mShowHandPosing)
			return;
		if (mFocusHandPosing)
		{
			ImGui.SetNextWindowFocus();
			mFocusHandPosing = false;
		}
		ImGui.SetNextWindowSize(.(560, 330), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Hand Posing", &mShowHandPosing))
			DrawHandPosingContents();
		ImGui.End();
	}

	void DrawHandPosingContents()
	{
		let animator = SelectedAnimator();
		let skinned = animator != null ? FindSkinned(animator) : null;
		if (skinned == null || skinned.Model == null)
		{
			ImGui.TextDisabled("Select a rigged character (its Animator's object or one of its bones).");
			return;
		}
		if (!skinned.exposeBones)
		{
			ImGui.TextDisabled("Turn on Expose Bones (Rig > Expose Bones in the Animation window) to pose the fingers.");
			return;
		}
		let map = skinned.Model.HumanMap;
		let left = skinned.Bone(map[.LeftHand]);
		let right = skinned.Bone(map[.RightHand]);
		if (left == null && right == null)
		{
			ImGui.TextDisabled("No hands found: set Left Hand and Right Hand in the model's Bone Map (Inspector).");
			return;
		}
		ImGui.TextDisabled(mClip != null ? "Moves are keyed at the time marker with Record or Auto Key on; Key Fingers keys them now." : "Open a clip in the Animation window to key what you pose here.");
		if (ImGui.BeginTable("hands", 2, ImGui.TableFlags.SizingStretchProp))
		{
			ImGui.TableNextColumn();
			DrawHandColumn(animator, left, right, "Left Hand");
			ImGui.TableNextColumn();
			DrawHandColumn(animator, right, left, "Right Hand");
			ImGui.EndTable();
		}
	}

	/// The Hand Pose on a hand bone, made (straight fingers measured from the scene's pose) when asked for.
	HandPose HandPoseOn(Animator animator, Transform hand, bool make)
	{
		if (hand == null)
			return null;
		var pose = hand.GameObject.GetComponent<HandPose>();
		if (pose != null || !make)
			return pose;
		// The fingers' straight pose is taken from the model's own rest pose, not whatever the clip shows (an idle's
		// half-closed hand would make every shape curl too far), else from the scene's pose of the bones.
		let fingers = scope List<Transform>();
		Descendants(hand, fingers);
		let skinned = FindSkinned(animator);
		let model = skinned != null ? skinned.Model : null;
		for (let bone in fingers)
		{
			let joint = model != null ? model.FindJoint(bone.GameObject.Name) : -1;
			if (joint >= 0)
			{
				bone.LocalRotation = model.Joints[joint].restRotation;
				continue;
			}
			Vector3 position, scale;
			Quaternion rotation;
			if (animator.RestPose(bone, out position, out rotation, out scale))
				bone.LocalRotation = rotation;
		}
		pose = hand.GameObject.AddComponent<HandPose>();
		pose.hand = hand;
		pose.Bind();
		pose.UseCurrentPoseAsRest();
		IKSystem.Solve(mScene);
		mClipPosedTime = -1;
		MarkDirty();
		return pose;
	}

	void DrawHandColumn(Animator animator, Transform hand, Transform otherHand, StringView title)
	{
		ImGui.PushID(scope String(title).CStr());
		defer ImGui.PopID();
		ImGui.SeparatorText(scope String(title).CStr());
		if (hand == null)
		{
			ImGui.TextDisabled("Not found.");
			return;
		}
		let pose = HandPoseOn(animator, hand, false);
		if (pose == null)
		{
			if (ImGui.Button("Pose Fingers", .(-1, 0)))
				HandPoseOn(animator, hand, true);
			ImGui.TextDisabled("Adds a Hand Pose to the hand bone.");
			return;
		}
		bool changed = false, released = false;
		// Ready-made shapes, four to a row.
		HandShape[8] shapes = .(.Open, .Relaxed, .Fist, .Grip, .Trigger, .Point, .Pinch, .ThumbsUp);
		StringView[8] labels = .("Open", "Relaxed", "Fist", "Grip", "Trigger", "Point", "Pinch", "Thumbs Up");
		let buttonWidth = (ImGui.GetContentRegionAvail().x - 6) / 4;
		for (int i < 8)
		{
			if (i % 4 != 0)
				ImGui.SameLine(0, 2);
			if (ToolButton(scope String(labels[i]).CStr(), pose.shape == shapes[i], buttonWidth))
			{
				pose.shape = shapes[i];
				pose.OnValidate();
				changed = released = true;
			}
		}
		StringView[5] fingers = .("Thumb", "Index", "Middle", "Ring", "Pinky");
		float*[5] values = .(&pose.thumb, &pose.index, &pose.middle, &pose.ring, &pose.pinky);
		for (int i < 5)
		{
			ImGui.SetNextItemWidth(-60);
			if (pose.BoneCount(i) == 0)
				ImGui.BeginDisabled();
			if (ImGui.SliderFloat(scope String(fingers[i]).CStr(), ref *values[i], 0, 1, "%.2f"))
				changed = true;
			released |= ImGui.IsItemDeactivatedAfterEdit();
			if (pose.BoneCount(i) == 0)
				ImGui.EndDisabled();
		}
		ImGui.SetNextItemWidth(-60);
		changed |= ImGui.SliderFloat("Spread", ref pose.spread, -1, 1, "%.2f");
		released |= ImGui.IsItemDeactivatedAfterEdit();
		ImGui.SetNextItemWidth(-60);
		changed |= ImGui.SliderFloat("Weight", ref pose.weight, 0, 1, "%.2f");
		released |= ImGui.IsItemDeactivatedAfterEdit();
		if (changed)
		{
			// Posing turns the Hand Pose up; keying hands the fingers back to the clip (KeyFingers).
			if (pose.weight == 0 && !ImGui.IsItemActive())
				pose.weight = 1;
			pose.OnValidate();
			IKSystem.Solve(mScene);
			MarkDirty();
		}
		ImGui.BeginDisabled(mClip == null);
		if (ImGui.Button("Key Fingers"))
			KeyFingers(animator, hand);
		ImGui.EndDisabled();
		ImGui.SameLine();
		if (ImGui.Button("Copy to Other Hand") && otherHand != null)
		{
			let other = HandPoseOn(animator, otherHand, true);
			other.shape = pose.shape;
			other.thumb = pose.thumb;
			other.index = pose.index;
			other.middle = pose.middle;
			other.ring = pose.ring;
			other.pinky = pose.pinky;
			other.spread = pose.spread;
			other.weight = pose.weight;
			other.OnValidate();
			IKSystem.Solve(mScene);
			if (mClip != null && mPlay == .Edit && (mClipRecord || mClipAutoKey))
				KeyFingers(animator, otherHand);
			MarkDirty();
		}
		// Recording: a finished change is keyed at once.
		if (released && mClip != null && mPlay == .Edit && (mClipRecord || mClipAutoKey))
			KeyFingers(animator, hand);
	}

	/// Keys the pose the hand's Hand Pose gives its fingers, at the marker. The Hand Pose's Weight then goes to 0,
	/// so that the clip's keys are what shows as the marker moves; posing again turns it back up.
	void KeyFingers(Animator animator, Transform hand)
	{
		if (mClip == null)
			return;
		IKSystem.Solve(mScene);
		let fingers = scope List<Transform>();
		Descendants(hand, fingers);
		for (let bone in fingers)
		{
			if (IKSystem.Drives(bone))
				KeyChild(animator, bone, true);
		}
		let pose = hand.GameObject.GetComponent<HandPose>();
		if (pose != null)
		{
			pose.weight = 0;
			MarkDirty();
		}
	}
}
