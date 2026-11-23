using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// The parts of a character a layer may move: an Avatar Mask, as Unity has one (.tmask file). Made in the Avatar
/// Mask window.
///
///   avatarmask 1
///   part Spine
///   part LeftShoulder
///   bone spine_02 1
///   bone Head 0
///
/// A `part` is a humanoid bone: Hips, Spine, Chest, UpperChest, Neck, Head, and for each side the Shoulder,
/// UpperArm, LowerArm, Hand, the finger bones, UpperLeg, LowerLeg, Foot and Toes. Parts are found on any character
/// whose model has a bone map (Mixamo's LeftUpLeg, Synty's Thigh_L and Unreal's thigh_l all answer LeftUpperLeg),
/// and on clips made for bones that are plain objects, by the same name matching.
///
/// A `bone` is any bone by name, with a weight from 0 to 1: 0 leaves it out even when a part above it takes it in.
/// Each part or bone takes the bones below it with the same weight, until another one below it says otherwise, so
/// "part Spine" covers the upper body and "bone head 0" takes the head back out.
///
/// A mask with no parts and no bones moves every bone, as an empty mask always did.
class AvatarMask
{
	public String name = new .() ~ delete _;
	/// The humanoid bones the mask moves.
	public bool[BoneMap.Count] parts;
	/// Bones by name with a weight (0 leaves out, 1 moves, in between blends), which override the parts.
	public class BoneEntry
	{
		public String bone = new .() ~ delete _;
		public float weight = 1;
	}

	public List<BoneEntry> bones = new .() ~ DeleteContainerAndItems!(_);
	/// Goes up whenever the mask is edited, so running Animators resolve it again.
	public int32 Revision { get; private set; }

	static Dictionary<String, AvatarMask> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	/// True when the mask names nothing, and so moves every bone.
	public bool IsEmpty
	{
		get
		{
			if (!bones.IsEmpty)
				return false;
			for (let part in parts)
			{
				if (part)
					return false;
			}
			return true;
		}
	}

	public bool HasPart(HumanBone part) => parts[(int)part];

	public void SetPart(HumanBone part, bool on)
	{
		if (parts[(int)part] == on)
			return;
		parts[(int)part] = on;
		Revision++;
	}

	/// Every part at once (the whole body, or nothing).
	public void SetAllParts(bool on)
	{
		for (int i < BoneMap.Count)
			parts[i] = on;
		Revision++;
	}

	/// A named bone's weight, when the mask names it (otherwise it goes with the part or bone above it).
	public bool TryGetBone(StringView bone, out float weight)
	{
		for (let entry in bones)
		{
			if (entry.bone == bone)
			{
				weight = entry.weight;
				return true;
			}
		}
		weight = 0;
		return false;
	}

	/// Names a bone with a weight from 0 to 1, or changes the one it has.
	public void SetBone(StringView bone, float weight)
	{
		let value = Mathf.Clamp01(weight);
		if (TryGetBone(bone, let existing))
		{
			if (existing == value)
				return;
		}
		else
		{
			let entry = new BoneEntry();
			entry.bone.Set(bone);
			bones.Add(entry);
		}
		for (let entry in bones)
		{
			if (entry.bone == bone)
				entry.weight = value;
		}
		Revision++;
	}

	public void RemoveBone(StringView bone)
	{
		for (int i = bones.Count - 1; i >= 0; i--)
		{
			if (bones[i].bone == bone)
			{
				delete bones[i];
				bones.RemoveAt(i);
				Revision++;
			}
		}
	}

	public void RemoveAllBones()
	{
		if (bones.IsEmpty)
			return;
		ClearAndDeleteItems!(bones);
		Revision++;
	}

	/// The weight each bone (names, with their parents' indexes; parents come before children) gets: 1 where the
	/// mask moves it, 0 where it leaves it to the layer below, and in between for a soft edge. humanMap is the
	/// character's bone map (see SkinnedModel.HumanMap) or null, in which case the names are matched.
	public void Resolve(List<StringView> names, List<int32> parents, BoneMap humanMap, float[] weights)
	{
		let count = names.Count;
		let any = !IsEmpty;
		for (int i < count)
			weights[i] = any ? 0 : 1;
		if (!any)
			return;
		bool[] said = scope bool[count];
		// Which bone of the character is each humanoid part: through its bone map, or matched from the names. The
		// matched map is made on the heap, as map is used after the block that makes it.
		BoneMap map = humanMap;
		if (map == null || !map.IsHumanoid)
		{
			let matched = new BoneMap();
			// A one-statement defer captures the value where it is written, so it goes after the allocation.
			defer:: delete matched;
			matched.MatchBones(names, parents);
			map = matched;
		}
		for (int b < BoneMap.Count)
		{
			if (!parts[b])
				continue;
			let joint = map[(HumanBone)b];
			if (joint.IsEmpty)
				continue;
			let index = IndexOf(names, joint);
			if (index < 0)
				continue;
			weights[index] = 1;
			said[index] = true;
		}
		for (let entry in bones)
		{
			let index = IndexOf(names, entry.bone);
			if (index < 0)
				continue;
			weights[index] = entry.weight;
			said[index] = true;
		}
		// Each part or bone takes what is below it, until one below it says otherwise.
		for (int i < count)
		{
			if (said[i])
				continue;
			let parent = parents[i];
			weights[i] = parent >= 0 && parent < i ? weights[parent] : (any ? 0 : 1);
		}
	}

	static int IndexOf(List<StringView> names, StringView name)
	{
		for (int i < names.Count)
		{
			if (names[i] == name)
				return i;
		}
		return -1;
	}

	/// Writes the mask in the format Read reads.
	public void Save(StringView fullPath)
	{
		let text = scope String();
		text.Append("avatarmask 1\n");
		for (int b < BoneMap.Count)
		{
			if (!parts[b])
				continue;
			text.Append("part ");
			BoneMap.BoneName((HumanBone)b, text);
			text.Append('\n');
		}
		for (let entry in bones)
		{
			text.Append("bone ");
			SceneSerializer.Quote(entry.bone, text);
			text.AppendF(" {}\n", entry.weight);
		}
		if (File.WriteAllText(fullPath, text) case .Err)
			Log.Error(scope $"Could not save {fullPath}");
		Revision++;
	}

	public bool Read(StringView fullPath)
	{
		let text = scope String();
		if (AssetPack.ReadAllText(fullPath, text) case .Err)
			return false;
		ClearAndDeleteItems!(bones);
		for (int i < BoneMap.Count)
			parts[i] = false;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2)
				continue;
			if (tokens[0] == "part")
			{
				let part = BoneMap.FindBone(tokens[1]);
				if (part < 0)
				{
					Log.Warning(scope $"{fullPath}: \"{tokens[1]}\" is not a humanoid bone.");
					continue;
				}
				parts[part] = true;
			}
			else if (tokens[0] == "bone" && tokens.Count >= 3)
			{
				let entry = new BoneEntry();
				entry.bone.Set(tokens[1]);
				entry.weight = Mathf.Clamp01(SceneSerializer.ParseFloat(tokens[2]));
				bones.Add(entry);
			}
		}
		Revision++;
		return true;
	}

	/// Makes an empty mask and registers it under a project path, as if it had been loaded from there.
	public static AvatarMask Create(StringView path, StringView name)
	{
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let mask = new AvatarMask();
		mask.name.Set(name);
		sCache[new String(path)] = mask;
		return mask;
	}

	/// Loads (and caches) a mask. The path is relative to the project's asset folder. Everything using the same file
	/// shares one mask, so an edit in the Avatar Mask window shows on every Animator at once.
	public static AvatarMask Load(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let full = scope String();
		Assets.ResolvePath(path, full);
		let mask = new AvatarMask();
		if (!mask.Read(full))
		{
			delete mask;
			Log.Warning(scope $"Avatar mask not found: {path}");
			return null;
		}
		mask.name.Set(path);
		sCache[new String(path)] = mask;
		return mask;
	}
}
