using System;
using System.Collections;
using Tallow;

namespace RetargetingTests;

class Program
{
	static int sFailures;

	static void Check(bool condition, StringView name)
	{
		Console.WriteLine(scope $"{condition ? "PASS" : "FAIL"}: {name}");
		if (!condition)
			sFailures++;
	}

	/// Adds a joint whose place and turn are given in the model's space; its local rest pose is worked out from its
	/// parent's, as a file would store it.
	static void Add(SkinnedModel model, List<Quaternion> globals, List<Vector3> places, StringView name, int parent, Vector3 place, Quaternion turn)
	{
		SkinnedModel.Joint joint = default;
		joint.name = new String(name);
		joint.parent = (int32)parent;
		joint.restScale = .One;
		if (parent < 0)
		{
			joint.restPosition = place;
			joint.restRotation = turn;
		}
		else
		{
			joint.restPosition = globals[parent].Conjugate * (place - places[parent]);
			joint.restRotation = (globals[parent].Conjugate * turn).Normalized;
		}
		model.Joints.Add(joint);
		globals.Add(turn);
		places.Add(place);
	}

	static readonly StringView[?] sMixamo = .("mixamorig:Hips", "mixamorig:Spine", "mixamorig:Spine1", "mixamorig:Neck", "mixamorig:Head", "mixamorig:LeftUpLeg", "mixamorig:LeftLeg", "mixamorig:LeftFoot", "mixamorig:RightUpLeg", "mixamorig:RightLeg", "mixamorig:RightFoot", "mixamorig:LeftArm", "mixamorig:LeftForeArm", "mixamorig:LeftHand", "mixamorig:LeftHandIndex1", "mixamorig:LeftHandIndex2", "mixamorig:LeftHandIndex3", "mixamorig:RightArm", "mixamorig:RightForeArm", "mixamorig:RightHand");
	static readonly StringView[?] sSynty = .("Pelvis", "spine_01", "spine_02", "neck_01", "head", "Thigh_L", "calf_l", "Foot_L", "Thigh_R", "calf_r", "Foot_R", "UpperArm_L", "lowerarm_l", "Hand_L", "indexFinger_01_l", "indexFinger_02_l", "indexFinger_03_l", "UpperArm_R", "lowerarm_r", "Hand_R");
	static readonly int[?] sParents = .(-1, 0, 1, 2, 3, 0, 5, 6, 0, 8, 9, 2, 11, 12, 13, 14, 15, 2, 17, 18);
	/// Each joint's place in a one-metre-legged figure facing +Z (its left side at +X).
	static readonly Vector3[?] sPlaces = .(.(0, 1, 0), .(0, 1.2f, 0), .(0, 1.4f, 0), .(0, 1.6f, 0), .(0, 1.7f, 0), .(0.1f, 1, 0), .(0.1f, 0.55f, 0), .(0.1f, 0.1f, 0), .(-0.1f, 1, 0), .(-0.1f, 0.55f, 0), .(-0.1f, 0.1f, 0), .(0.2f, 1.55f, 0), .(0.45f, 1.55f, 0), .(0.7f, 1.55f, 0), .(0.78f, 1.55f, 0), .(0.81f, 1.55f, 0), .(0.84f, 1.55f, 0), .(-0.2f, 1.55f, 0), .(-0.45f, 1.55f, 0), .(-0.7f, 1.55f, 0));

	/// A figure with the given names, made `size` times as big, turned about the up axis, with every bone given a
	/// different roll when rolled is set (as rigs from different tools have).
	static SkinnedModel Figure(Span<StringView> names, float size, float facing, bool rolled, bool aPose = false)
	{
		let model = new SkinnedModel();
		let globals = scope List<Quaternion>();
		let places = scope List<Vector3>();
		let turn = Quaternion.AngleAxis(facing, .Up);
		for (int j < names.Length)
		{
			var roll = Quaternion.Identity;
			if (rolled)
				roll = Quaternion.AngleAxis(37 * (j + 1), Vector3(1, 2, 3 - j).Normalized);
			var place = sPlaces[j];
			// An A pose: the arms hang 45 degrees down from the shoulders.
			if (aPose && j >= 12 && j <= 19 && j != 17)
			{
				let shoulder = j < 17 ? sPlaces[11] : sPlaces[17];
				place = shoulder + Quaternion.AngleAxis(j < 17 ? -45 : 45, .Forward) * (place - shoulder);
			}
			Add(model, globals, places, names[j], sParents[j], turn * (place * size), (turn * roll).Normalized);
		}
		return model;
	}

	/// A clip of two frames: rest, then the left thigh kicked forward, the index finger curled and the hips moved
	/// forward and up.
	static SkinnedModel.Clip Kick(SkinnedModel model)
	{
		let count = model.Joints.Count;
		let clip = new SkinnedModel.Clip();
		clip.name.Set("Kick");
		clip.frames = 2;
		clip.duration = 1 / 30.0f;
		clip.data = new float[2 * count * 10];
		for (int f < 2)
		{
			for (int j < count)
			{
				let joint = model.Joints[j];
				var position = joint.restPosition;
				var rotation = joint.restRotation;
				if (f == 1 && j == 0)
					position += .(0, 0.2f, 1);
				if (f == 1 && j == 5)
					rotation = (Quaternion.AngleAxis(-40, .Right) * rotation).Normalized;
				if (f == 1 && j == 14)
					rotation = (rotation * Quaternion.AngleAxis(60, .Up)).Normalized;
				let a = clip.data.Ptr + (f * count + j) * 10;
				a[0] = position.x;
				a[1] = position.y;
				a[2] = position.z;
				a[3] = rotation.x;
				a[4] = rotation.y;
				a[5] = rotation.z;
				a[6] = rotation.w;
				a[7] = a[8] = a[9] = 1;
			}
		}
		model.Clips.Add(clip);
		return clip;
	}

	static Vector3 Direction(SkinnedModel.GlobalPose[] pose, int from, int to) => (pose[to].position - pose[from].position).Normalized;

	public static int Main(String[] args)
	{
		Console.WriteLine("Retargeting tests");

		// ---- names ----
		{
			let core = scope String();
			Check(BoneMap.Simplify("mixamorig:LeftUpLeg", core) == -1 && core == "upleg", "a Mixamo name loses its prefix and side");
			core.Clear();
			Check(BoneMap.Simplify("jnt_right_forearm", core) == 1 && core == "forearm", "jnt_right_forearm is the right forearm");
			core.Clear();
			Check(BoneMap.Simplify("DEF-thigh.L", core) == -1 && core == "thigh", "a Rigify deform bone is read");
			core.Clear();
			Check(BoneMap.Simplify("Bip01 L Thigh", core) == -1 && core == "thigh", "a Biped name is read");
			Check(BoneMap.Simplify("ik_hand_l", core..Clear()) == 2 && BoneMap.Simplify("jnt_left_armroll", core..Clear()) == 2 && BoneMap.Simplify("mixamorig:HeadTop_End", core..Clear()) == 2, "IK targets, roll bones and end points are not bones of the body");
		}

		let mixamo = Figure(sMixamo, 1, 0, false);
		defer delete mixamo;
		let synty = Figure(sSynty, 0.5f, 180, true);
		defer delete synty;

		// ---- matching ----
		{
			let a = mixamo.HumanMap;
			let b = synty.HumanMap;
			Check(a[.Hips] == "mixamorig:Hips" && a[.Spine] == "mixamorig:Spine" && a[.Chest] == "mixamorig:Spine1" && a[.UpperChest].IsEmpty, "spines are taken in order from the hips");
			Check(a[.LeftUpperLeg] == "mixamorig:LeftUpLeg" && a[.LeftLowerLeg] == "mixamorig:LeftLeg" && a[.LeftUpperArm] == "mixamorig:LeftArm" && a[.LeftLowerArm] == "mixamorig:LeftForeArm", "Mixamo's legs and arms are matched");
			Check(a[.LeftHand] == "mixamorig:LeftHand" && a[.LeftIndex1] == "mixamorig:LeftHandIndex1" && a[.LeftIndex3] == "mixamorig:LeftHandIndex3", "the hand and the finger's segments are matched");
			Check(b[.Hips] == "Pelvis" && b[.LeftUpperLeg] == "Thigh_L" && b[.LeftLowerLeg] == "calf_l" && b[.RightFoot] == "Foot_R" && b[.LeftLowerArm] == "lowerarm_l" && b[.LeftIndex2] == "indexFinger_02_l" && b[.Head] == "head" && b[.Neck] == "neck_01", "Synty's names are matched");
			Check(a.Matched == 20 && b.Matched == 20, scope $"every joint of both is a bone ({a.Matched}, {b.Matched})");
			Check(synty.ModeFor(mixamo) == .Humanoid, "differently named humanoids are retargeted through their bone maps");
		}

		// ---- retargeting ----
		{
			let kick = Kick(mixamo);
			Check(synty.ImportClips(mixamo, "mixamo") == 1, "the clip is added");
			let copy = synty.FindClip("Kick");
			let a = scope SkinnedModel.GlobalPose[mixamo.Joints.Count];
			let b = scope SkinnedModel.GlobalPose[synty.Joints.Count];
			let b0 = scope SkinnedModel.GlobalPose[synty.Joints.Count];
			let rest = scope SkinnedModel.GlobalPose[synty.Joints.Count];
			mixamo.SamplePose(kick, 1, a);
			synty.SamplePose(copy, 1, b);
			synty.SamplePose(copy, 0, b0);
			synty.SamplePose(null, 0, rest);
			let turn = Quaternion.AngleAxis(180, .Up);
			bool still = true;
			for (int j < synty.Joints.Count)
				still &= (b0[j].position - rest[j].position).Length < 0.0001f;
			Check(still, "the clip's first frame is the target's rest pose, whatever its bone rolls");
			let thigh = Vector3.Dot(Direction(b, 5, 6), turn * Direction(a, 5, 6));
			Check(thigh > 0.999f, scope $"the thigh kicks the way the target faces ({thigh})");
			let finger = Vector3.Dot(Direction(b, 14, 15), turn * Direction(a, 14, 15));
			Check(finger > 0.999f, scope $"the finger curls as the library's does ({finger})");
			let moved = b[0].position - rest[0].position;
			Check((moved - Vector3(0, 0.1f, -0.5f)).Length < 0.001f, scope $"the hips move forward for the target, at half the stride for half the legs ({moved})");
			let shin = (b[7].position - b[6].position).Length;
			Check(Math.Abs(shin - 0.225f) < 0.001f, "the target keeps its own bone lengths");
			let head = Vector3.Dot(Direction(b, 3, 4), Direction(rest, 3, 4));
			Check(head > 0.9999f, "a bone the clip does not turn keeps the target's rest direction");

			// A fixed map: the thigh no longer follows anything, and the clip is made again in place.
			let map = scope BoneMap();
			map.CopyFrom(synty.HumanMap);
			map.Read("LeftUpperLeg =\n# a comment\nNoSuchBone = x\nLeftFoot = NoSuchJoint\n", synty, "test.bonemap");
			Check(map[.LeftUpperLeg].IsEmpty && map[.LeftFoot] == "Foot_L", "a .bonemap empties a bone and ignores bad lines");
			synty.SetHumanMap(map);
			Check(synty.FindClip("Kick") == copy, "fixing the map keeps the same clip");
			synty.SamplePose(copy, 1, b);
			let unmatched = Vector3.Dot(Direction(b, 5, 6), Direction(rest, 5, 6));
			Check(unmatched > 0.9999f, "a bone the map leaves out stays at rest");
			let text = scope String();
			map.Write(text);
			let back = scope BoneMap();
			back.Read(text, synty, "written");
			Check(back[.LeftUpperLeg].IsEmpty && back[.RightUpperLeg] == "Thigh_R" && back.Matched == map.Matched, "a written map reads back the same");
		}

		// ---- rest poses that differ ----
		{
			let hanging = Figure(sMixamo, 1, 0, true, true);
			defer delete hanging;
			let still = Kick(hanging);
			let target = Figure(sSynty, 0.5f, 180, true);
			defer delete target;
			target.ImportClips(hanging, "hanging");
			let a = scope SkinnedModel.GlobalPose[hanging.Joints.Count];
			let b = scope SkinnedModel.GlobalPose[target.Joints.Count];
			hanging.SamplePose(still, 0, a);
			target.SamplePose(target.FindClip("Kick"), 0, b);
			let turn = Quaternion.AngleAxis(180, .Up);
			let arm = Vector3.Dot(Direction(b, 12, 13), turn * Direction(a, 12, 13));
			let hand = Vector3.Dot(Direction(b, 13, 14), turn * Direction(a, 13, 14));
			Check(arm > 0.999f && hand > 0.999f, scope $"a T-posed character playing an A-posed library's clip hangs its arms as the clip does ({arm}, {hand})");
		}

		// ---- the same skeleton ----
		{
			let other = Figure(sMixamo, 1, 0, true);
			defer delete other;
			Check(other.ModeFor(mixamo) == .SameSkeleton, "a library with the same names is the same skeleton");
			other.ImportClips(mixamo, "mixamo");
			let pose = scope SkinnedModel.GlobalPose[other.Joints.Count];
			let rest = scope SkinnedModel.GlobalPose[other.Joints.Count];
			other.SamplePose(other.FindClip("Kick"), 1, pose);
			other.SamplePose(null, 0, rest);
			Check(((pose[0].position - rest[0].position) - Vector3(0, 0.2f, 1)).Length < 0.001f, "the same skeleton at the same size takes the hips' movement as it is");
		}

		Console.WriteLine(sFailures == 0 ? "All retargeting tests passed." : scope $"{sFailures} retargeting test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
