using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Inspector tools for the IK components: making targets, lining a hand up, and the ready-made hand shapes.
extension EditorApp
{
	static bool IkNamed(StringView name, params StringView[] parts)
	{
		let lower = scope String(name)..ToLower();
		for (let part in parts)
		{
			if (lower.Contains(part))
				return true;
		}
		return false;
	}

	static void IkDescendants(Transform parent, List<Transform> output)
	{
		for (let child in parent.Children)
		{
			output.Add(child);
			IkDescendants(child, output);
		}
	}

	void DrawLimbIKTools(LimbIK limb)
	{
		if (limb.tip == null)
		{
			// Offer the hands and feet found below this object, so that setting a limb up is one press.
			ImGui.TextDisabled("Tip is the hand or foot. Found below this object:");
			List<Transform> below = scope .();
			IkDescendants(limb.Transform, below);
			int shown = 0;
			for (let bone in below)
			{
				if (!IkNamed(bone.GameObject.Name, "hand", "wrist", "foot", "ankle") || bone.Parent == null || bone.Parent.Parent == null)
					continue;
				if (shown % 2 == 1)
					ImGui.SameLine();
				ImGui.PushID(Internal.UnsafeCastToPtr(bone));
				if (ImGui.Button(scope String(bone.GameObject.Name).CStr()))
				{
					limb.tip = bone;
					MarkDirty();
				}
				ImGui.PopID();
				shown++;
			}
			if (shown == 0)
				ImGui.TextDisabled("None by name: drag the bone into Tip. (A rigged model needs Expose Bones on its Skinned Mesh Renderer.)");
			return;
		}
		if (limb.Upper == null)
		{
			ImGui.TextDisabled("Tip needs two bones above it (forearm and upper arm, shin and thigh).");
			return;
		}
		if (limb.target == null)
		{
			if (ImGui.Button("Make Target And Pole"))
			{
				// The target starts where the hand is, so nothing moves until it is dragged; the pole starts out
				// beyond the elbow, the way it already bends.
				let target = mScene.CreateGameObject(scope $"{limb.tip.GameObject.Name} Target" , limb.Transform).Transform;
				limb.target = target;
				limb.TargetToTip();
				let middle = limb.Middle, upper = limb.Upper;
				let along = (limb.tip.Position - upper.Position);
				var outward = middle.Position - (upper.Position + along * 0.5f);
				// A straight limb, or one bent clearly the wrong way, gets the natural bend: elbows back, knees forward.
				// (A model's front is often its object's back, so the object's Forward cannot be trusted for this.)
				let natural = limb.NaturalBend();
				if (natural != .Zero && (outward.Length < along.Length * 0.025f || Vector3.Dot(outward.Normalized, natural) < -0.5f))
					outward = natural;
				if (outward.LengthSquared < 1.0e-6f)
					outward = -limb.Transform.Forward;
				let pole = mScene.CreateGameObject(scope $"{limb.tip.GameObject.Name} Pole" , limb.Transform).Transform;
				pole.Position = middle.Position + outward.Normalized * Math.Max(along.Length * 0.6f, 0.2f);
				limb.pole = pole;
				mSelectedId = target.GameObject.Id;
				MarkDirty();
			}
			ImGui.TextDisabled("Or drag any object into Target: an empty placed on a weapon's grip, say.");
			return;
		}
		if (ImGui.Button("Keep Hand's Rotation"))
		{
			limb.KeepCurrentRotation();
			limb.rotationWeight = 1;
			MarkDirty();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Sets Rotation Offset so that the hand stays turned the way its own pose has it while it follows the target.\nPose the hand first with Weight at 0, press this, then bring Weight back up.");
		ImGui.SameLine();
		if (ImGui.Button("Target To Hand"))
		{
			limb.TargetToTip();
			MarkDirty();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Moves the target to where the hand is now.");
		let reach = limb.Reach;
		if (reach > 1)
			ImGui.TextColored(EditorTheme.Warning, "The target is out of reach: the limb is straight.");
		else
			ImGui.TextDisabled("Move the target with the Move tool. From code: LetGo() and Grab() free and return one limb.");
	}

	void DrawHandPoseTools(HandPose pose)
	{
		ImGui.TextDisabled("Shapes");
		char8*[?] names = .("Open", "Relaxed", "Fist", "Grip", "Trigger", "Point", "Pinch", "Thumbs Up");
		HandShape[?] shapes = .(.Open, .Relaxed, .Fist, .Grip, .Trigger, .Point, .Pinch, .ThumbsUp);
		for (int i < names.Count)
		{
			if (i % 4 != 0)
				ImGui.SameLine();
			if (ImGui.Button(names[i], .(84, 0)))
			{
				pose.shape = shapes[i];
				pose.OnValidate();
				MarkDirty();
			}
		}
		if (ImGui.Button("Use Current Pose As Straight"))
		{
			pose.UseCurrentPoseAsRest();
			MarkDirty();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Curls are measured from the fingers' straight pose, remembered when the hand was first found.\nSet Weight to 0, straighten the fingers, then press this to remember them again.");
		let found = scope String();
		char8*[5] fingers = .("thumb", "index", "middle", "ring", "pinky");
		int total = 0;
		for (int i < 5)
		{
			if (pose.BoneCount(i) == 0)
				continue;
			found.AppendF("{}{} ({})", found.IsEmpty ? "" : ", ", StringView(fingers[i]), pose.BoneCount(i));
			total++;
		}
		if (total == 0)
			ImGui.TextColored(EditorTheme.Warning, "No fingers found below the hand. Fingers are the hand's children and the bones below them.");
		else
		{
			ImGui.PushTextWrapPos(0);
			ImGui.TextDisabled(scope String()..AppendF("Found: {}. Curling backwards? Tick Flip Curl.", found).CStr());
			ImGui.PopTextWrapPos();
		}
	}

	void DrawFootPlacementTools(FootPlacement placement)
	{
		if (placement.leftFoot == null || placement.rightFoot == null)
		{
			List<Transform> below = scope .();
			IkDescendants(placement.Transform, below);
			Transform left = null, right = null, hips = null;
			for (let bone in below)
			{
				let name = bone.GameObject.Name;
				if (hips == null && IkNamed(name, "hips", "pelvis"))
					hips = bone;
				if (!IkNamed(name, "foot", "ankle") || bone.Parent == null || bone.Parent.Parent == null)
					continue;
				let lower = scope String(name)..ToLower();
				if (left == null && (lower.Contains("left") || lower.EndsWith(".l") || lower.EndsWith("_l") || lower.Contains("l_") || lower.Contains(".l.")))
					left = bone;
				else if (right == null)
					right = bone;
			}
			ImGui.BeginDisabled(left == null || right == null);
			if (ImGui.Button("Find Feet And Hips"))
			{
				placement.leftFoot = left;
				placement.rightFoot = right;
				if (placement.hips == null)
					placement.hips = hips;
				MarkDirty();
			}
			ImGui.EndDisabled();
			if (left == null || right == null)
				ImGui.TextDisabled("No two feet found by name: drag the foot bones in.");
		}
		ImGui.TextDisabled("Feet are placed while the game plays, on ground that has colliders.");
	}
}
