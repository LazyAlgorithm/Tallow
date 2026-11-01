using System;
using System.Collections;

namespace Tallow;

/// The bones every humanoid skeleton shares, whatever its file calls them. A clip made for one humanoid plays on
/// another through them (see BoneMap and SkinnedModel.ImportClips).
enum HumanBone
{
	Hips, Spine, Chest, UpperChest, Neck, Head,
	LeftShoulder, LeftUpperArm, LeftLowerArm, LeftHand,
	RightShoulder, RightUpperArm, RightLowerArm, RightHand,
	LeftUpperLeg, LeftLowerLeg, LeftFoot, LeftToes,
	RightUpperLeg, RightLowerLeg, RightFoot, RightToes,
	LeftThumb1, LeftThumb2, LeftThumb3, LeftIndex1, LeftIndex2, LeftIndex3, LeftMiddle1, LeftMiddle2, LeftMiddle3,
	LeftRing1, LeftRing2, LeftRing3, LeftLittle1, LeftLittle2, LeftLittle3,
	RightThumb1, RightThumb2, RightThumb3, RightIndex1, RightIndex2, RightIndex3, RightMiddle1, RightMiddle2, RightMiddle3,
	RightRing1, RightRing2, RightRing3, RightLittle1, RightLittle2, RightLittle3
}

/// Which of a model's joints is each HumanBone. Made by matching the joints' names (Mixamo's LeftUpLeg, Synty's
/// Thigh_L, Unreal's thigh_l, Blender's thigh.L, jnt_left_upleg...), or read from a .bonemap file beside the model
/// (Models/hero.glb has Models/hero.bonemap) that fixes the matches. The file has one line a bone:
///
///   LeftUpperArm = UpperArm_L
///   LeftToes =
///
/// A bone left empty has no match. Bones the file leaves out are matched by name.
class BoneMap
{
	public const int Count = (int)HumanBone.RightLittle3 + 1;
	public const String Extension = ".bonemap";

	String[Count] mJoints;

	public this()
	{
		for (int i < Count)
			mJoints[i] = new String();
	}

	public ~this()
	{
		for (let joint in mJoints)
			delete joint;
	}

	/// The joint's name for a bone; empty when the model has none.
	public StringView this[HumanBone bone]
	{
		get => mJoints[(int)bone];
		set => mJoints[(int)bone].Set(value);
	}

	/// True when the map knows the hips, without which a skeleton is not treated as a humanoid.
	public bool IsHumanoid => !mJoints[(int)HumanBone.Hips].IsEmpty;

	/// How many bones have a joint.
	public int Matched
	{
		get
		{
			int count = 0;
			for (let joint in mJoints)
			{
				if (!joint.IsEmpty)
					count++;
			}
			return count;
		}
	}

	/// The bone a joint is, or -1.
	public int BoneOf(StringView joint)
	{
		if (joint.IsEmpty)
			return -1;
		for (int i < Count)
		{
			if (mJoints[i] == joint)
				return i;
		}
		return -1;
	}

	public void CopyFrom(BoneMap other)
	{
		for (int i < Count)
			mJoints[i].Set(other.mJoints[i]);
	}

	public void Clear()
	{
		for (let joint in mJoints)
			joint.Clear();
	}

	/// The bone's name as the .bonemap file and the editor show it ("LeftUpperArm").
	public static void BoneName(HumanBone bone, String into) => bone.ToString(into);

	/// The bone named, or -1.
	public static int FindBone(StringView name)
	{
		let text = scope String();
		for (int i < Count)
		{
			text.Clear();
			BoneName((HumanBone)i, text);
			if (text.Equals(name, .OrdinalIgnoreCase))
				return i;
		}
		return -1;
	}

	/// Writes the map as a .bonemap file's text, every bone on a line.
	public void Write(String text)
	{
		text.Append("# Which joint of the model is each humanoid bone (empty: none). See docs/retargeting.md.\n");
		for (int i < Count)
		{
			BoneName((HumanBone)i, text);
			text.Append(" = ");
			text.Append(mJoints[i]);
			text.Append('\n');
		}
	}

	/// Reads a .bonemap file's text over the map: the bones it names take its joints (or none, when it leaves them
	/// empty); the others keep theirs. Joints the model lacks are dropped with a warning.
	public void Read(StringView text, SkinnedModel model, StringView fileName)
	{
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			let equals = line.IndexOf('=');
			if (equals < 0)
				continue;
			var name = line.Substring(0, equals);
			var joint = line.Substring(equals + 1);
			name.Trim();
			joint.Trim();
			let bone = FindBone(name);
			if (bone < 0)
			{
				Log.Warning(scope $"{fileName}: \"{name}\" is not a humanoid bone.");
				continue;
			}
			if (!joint.IsEmpty && model != null && model.FindJoint(joint) < 0)
			{
				Log.Warning(scope $"{fileName}: the model has no joint \"{joint}\" (for {name}).");
				continue;
			}
			mJoints[bone].Set(joint);
		}
	}

	// ---- matching by name ----

	/// Matches every bone to a joint of the model by name, replacing what the map had.
	public void Match(SkinnedModel model)
	{
		Clear();
		let jointCount = model.Joints.Count;
		let depth = scope int[jointCount];
		for (int j < jointCount)
			depth[j] = model.Depth(j);
		// Each joint's guess, as a bone (fingers and spines by their kind: the segment is decided by depth below).
		let guess = scope int[jointCount];
		let side = scope int[jointCount];
		let core = scope String();
		for (int j < jointCount)
		{
			core.Clear();
			side[j] = Simplify(model.Joints[j].name, core);
			guess[j] = Guess(core, side[j]);
		}
		// One-of-a-kind bones: the shallowest joint that looks like it.
		for (int b < Count)
		{
			if (IsChain((HumanBone)b))
				continue;
			int best = -1;
			for (int j < jointCount)
			{
				if (guess[j] == b && (best < 0 || depth[j] < depth[best]))
					best = j;
			}
			if (best >= 0)
				mJoints[b].Set(model.Joints[best].name);
		}
		// Chains: the spine (Spine, Chest, UpperChest) and each finger's three segments, from the root out.
		let chain = scope List<int>();
		for (int b < Count)
		{
			if (!IsChain((HumanBone)b) || !IsChainStart((HumanBone)b))
				continue;
			chain.Clear();
			for (int j < jointCount)
			{
				if (guess[j] == b)
					chain.Add(j);
			}
			chain.Sort(scope (a, c) => depth[a] - depth[c]);
			for (int k < Math.Min(chain.Count, 3))
				mJoints[b + k].Set(model.Joints[chain[k]].name);
		}
	}

	static bool IsChain(HumanBone bone) => (bone >= .Spine && bone <= .UpperChest) || bone >= .LeftThumb1;
	static bool IsChainStart(HumanBone bone) => bone == .Spine || (bone >= .LeftThumb1 && ((int)bone - (int)HumanBone.LeftThumb1) % 3 == 0);

	/// Splits a joint's name into words (at separators and where lower case meets upper case), takes the side words
	/// out, and joins the rest into core, lower case, without prefixes such as "mixamorig:", "jnt_" or "DEF-".
	/// Returns the side: -1 left, 1 right, 0 none; 2 for a joint that is a helper, not a bone of the body (IK
	/// targets, twist and roll bones, end points, weapon sockets).
	public static int Simplify(StringView name, String core)
	{
		var name;
		let colon = name.LastIndexOf(':');
		if (colon >= 0)
			name = name.Substring(colon + 1);
		let words = scope List<String>();
		defer
		{
			for (let w in words)
				delete w;
		}
		var word = new String();
		for (int i < name.Length)
		{
			let c = name[i];
			let separator = c == '_' || c == '.' || c == '-' || c == ' ' || c == '|';
			let camel = c.IsUpper && i > 0 && name[i - 1].IsLower;
			if ((separator || camel) && !word.IsEmpty)
			{
				words.Add(word);
				word = new String();
			}
			if (!separator)
				word.Append(c.ToLower);
		}
		if (!word.IsEmpty)
			words.Add(word);
		else
			delete word;

		int side = 0;
		for (let w in words)
		{
			if (w == "ik" || w == "end" || w == "nub" || w == "pole" || w == "target" || w == "twist" || w == "roll" || w == "weapon" || w == "socket" || w == "ctrl" || w == "mch" || w == "helper")
				return 2;
			if (w == "l" || w == "left")
				side = -1;
			else if (w == "r" || w == "right")
				side = 1;
			else if (w == "jnt" || w == "j" || w == "def" || w == "bip" || w == "bip01" || w == "b" || w == "bone" || w == "org" || w == "rig" || w == "mixamorig")
				continue;
			else
				core.Append(w);
		}
		if (core.Contains("roll") || core.Contains("twist") || core.EndsWith("end") || core.Contains("weapon") || core.Contains("pole") || core.Contains("target") || core.Contains("helper"))
			return 2;
		return side;
	}

	/// The bone a joint looks like from its simplified name, or -1. Spine joints answer Spine and finger joints
	/// their finger's first segment; Match puts them in order.
	static int Guess(StringView core, int side)
	{
		if (side == 2 || core.IsEmpty)
			return -1;
		if (side == 0)
		{
			if (core == "hips" || core == "hip" || core.Contains("pelvis"))
				return (int)HumanBone.Hips;
			if (core.Contains("spine") || core.Contains("chest"))
				return (int)HumanBone.Spine;
			if (core.Contains("neck"))
				return (int)HumanBone.Neck;
			if (core.Contains("head"))
				return (int)HumanBone.Head;
			return -1;
		}
		HumanBone bone;
		if (core.Contains("thumb"))
			bone = .LeftThumb1;
		else if (core.Contains("index"))
			bone = .LeftIndex1;
		else if (core.Contains("middle"))
			bone = .LeftMiddle1;
		else if (core.Contains("ring"))
			bone = .LeftRing1;
		else if (core.Contains("pinky") || core.Contains("little"))
			bone = .LeftLittle1;
		else if (core.Contains("toe") || core.Contains("ball"))
			bone = .LeftToes;
		else if (core.Contains("foot") || core.Contains("ankle"))
			bone = .LeftFoot;
		else if (core.Contains("thigh") || core.Contains("upleg") || core.Contains("upperleg") || core.Contains("femur"))
			bone = .LeftUpperLeg;
		else if (core.Contains("calf") || core.Contains("shin") || core.Contains("knee") || core.Contains("lowerleg") || core.EndsWith("leg"))
			bone = .LeftLowerLeg;
		else if (core.Contains("hand") || core.Contains("wrist") || core.Contains("palm"))
			bone = .LeftHand;
		else if (core.Contains("forearm") || core.Contains("lowerarm") || core.Contains("elbow"))
			bone = .LeftLowerArm;
		else if (core.Contains("upperarm") || core.Contains("uparm") || core.EndsWith("arm"))
			bone = .LeftUpperArm;
		else if (core.Contains("clavicle") || core.Contains("collar") || core.Contains("shoulder"))
			bone = .LeftShoulder;
		else
			return -1;
		// The right side's bones follow the left's in the same order.
		return side < 0 ? (int)bone : (int)bone + (bone >= .LeftThumb1 ? 15 : 4);
	}
}
