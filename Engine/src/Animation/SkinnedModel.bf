using System;
using System.Collections;

namespace Tallow;

/// A rigged model loaded from glTF / GLB: bind-pose vertices with bone weights, the skeleton,
/// and its animation clips (sampled at 30 frames per second on import).
class SkinnedModel
{
	public struct Joint
	{
		public String name;
		public int32 parent;
		public Vector3 restPosition;
		public Quaternion restRotation;
		public Vector3 restScale;
		public Matrix4 inverseBind;
		public Matrix4 parentWorld;
	}

	public class Clip
	{
		public String name = new .() ~ delete _;
		public float duration;
		public int32 frames;
		public float[] data ~ delete _; // frames * joints * 10
	}

	public List<Joint> Joints = new .() ~ { for (let j in _) delete j.name; delete _; };
	public List<Clip> Clips = new .() ~ DeleteContainerAndItems!(_);
	/// The clip libraries whose clips ImportClips has added already.
	HashSet<String> mClipLibraries = new .() ~ DeleteContainerAndItems!(_);
	List<ImportedClip> mImported = new .() ~ DeleteContainerAndItems!(_);
	BoneMap mHumanMap ~ delete _;
	/// The file the model was read from, as it was asked for ("Models/hero.glb"); empty for a model made in code.
	public String Path = new .() ~ delete _;
	// Bind pose in the file's own (right-handed) space; Z is flipped after skinning.
	public List<Vector3> Positions = new .() ~ delete _;
	public List<Vector3> Normals = new .() ~ delete _;
	public List<uint32> Colors = new .() ~ delete _;
	public List<Vector2> UVs = new .() ~ delete _;
	public List<uint16> JointIndices = new .() ~ delete _; // 4 per vertex
	public List<float> Weights = new .() ~ delete _; // 4 per vertex
	public List<uint32> Indices = new .() ~ delete _;

	/// One part of the model for each of its materials (a character's skin, cloth and armour): its triangles, as
	/// indices into the vertex lists above, and the material the file gives it.
	public class Part
	{
		/// The material's name in the file, or "Part 2" when it has none.
		public String name = new .() ~ delete _;
		public List<uint32> indices = new .() ~ delete _;
		/// Which of the file's materials it is (-1: the primitives that had none).
		public int32 fileMaterial;
		/// Made from the file: colour factor (in the vertex colours, so white here), metallic and roughness, and
		/// the base colour, normal, metallic-roughness, occlusion and emissive textures, alpha mode and double sides.
		public Material material ~ delete _;
	}

	public List<Part> Parts = new .() ~ DeleteContainerAndItems!(_);
	/// True when the parts are drawn with materials of their own: the file has more than one material, or any
	/// textures. Otherwise the model is one mesh drawn with its Mesh Renderer's settings, as before.
	public bool HasOwnMaterials;

	static Dictionary<String, SkinnedModel> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	/// Models read again since (Forget): kept until the end, as clips and renderers may still point at them.
	static List<SkinnedModel> sRetired = new .() ~ DeleteContainerAndItems!(_);

	/// Reads a model's file again the next time it is asked for (after the rigger wrote it again), and has the
	/// Skinned Mesh Renderers that use it load it again.
	public static void Forget(StringView path)
	{
		if (sCache.GetAndRemoveAlt(path) case .Ok(let pair))
		{
			delete pair.key;
			sRetired.Add(pair.value);
		}
		SkinnedMeshRenderer.ModelChanged(path);
	}

	/// A joint's pose in a clip at a time (seconds), in the model's own right-handed space, as the clip's frames give it.
	public void SampleJoint(Clip clip, float time, bool loop, int joint, out Vector3 position, out Quaternion rotation, out Vector3 scale)
	{
		let jointCount = Joints.Count;
		let t = loop ? (clip.duration > 0 ? time % clip.duration : 0) : Math.Min(time, clip.duration);
		let exact = t * 30.0f;
		let f0 = Math.Clamp((int)exact, 0, clip.frames - 1);
		let f1 = Math.Min(f0 + 1, clip.frames - 1);
		let blend = exact - f0;
		let a = clip.data.Ptr + (f0 * jointCount + joint) * 10;
		let b = clip.data.Ptr + (f1 * jointCount + joint) * 10;
		position = Vector3.Lerp(.(a[0], a[1], a[2]), .(b[0], b[1], b[2]), blend);
		rotation = Quaternion.Slerp(.(a[3], a[4], a[5], a[6]), .(b[3], b[4], b[5], b[6]), blend);
		scale = Vector3.Lerp(.(a[7], a[8], a[9]), .(b[7], b[8], b[9]), blend);
	}

	/// A joint's number by its name, or -1.
	public int FindJoint(StringView name)
	{
		for (int i < Joints.Count)
		{
			if (Joints[i].name == name)
				return i;
		}
		return -1;
	}

	public Clip FindClip(StringView name)
	{
		for (let clip in Clips)
		{
			if (clip.name == name)
				return clip;
		}
		return null;
	}

	/// Adds the clips of another model (a clip library) to this one, so characters can share one file of animations.
	/// Libraries made for the same skeleton (most bones named as this model's are) are matched by name: each bone
	/// turns from its rest pose as the library's turns from its own, and only bones the library moves (the hips)
	/// take its movement, so the rest keep this model's proportions. Any other humanoid is retargeted through both
	/// models' HumanMaps: each bone is first swung to point the way its counterpart points at rest (so an A pose
	/// and a T pose line up), then takes the turn its counterpart makes in the model's space, so bone rolls, rest
	/// poses and facings may differ. Either
	/// way the hips' movement is scaled by the two models' leg lengths, so a child walks a child's stride. Bones the
	/// library lacks stay at rest. A clip this model has already is kept as it is. libraryPath names the library, so
	/// asking again adds nothing. Returns how many clips were added.
	public int ImportClips(SkinnedModel library, StringView libraryPath)
	{
		if (library == null || library == this || mClipLibraries.ContainsAlt(libraryPath))
			return 0;
		mClipLibraries.Add(new String(libraryPath));
		int added = 0;
		for (let clip in library.Clips)
		{
			if (FindClip(clip.name) != null)
				continue;
			let copy = new Clip();
			copy.name.Set(clip.name);
			copy.duration = clip.duration;
			copy.frames = clip.frames;
			Clips.Add(copy);
			let imported = new ImportedClip();
			imported.clip = copy;
			imported.library = library;
			imported.from = clip;
			mImported.Add(imported);
			added++;
		}
		RemakeImported(library);
		return added;
	}

	/// True when a clip came from a clip library (ImportClips).
	public bool IsImported(Clip clip)
	{
		for (let imported in mImported)
		{
			if (imported.clip == clip)
				return true;
		}
		return false;
	}

	/// How the clips from one library are being fitted to this model.
	public enum RetargetMode
	{
		/// No clips from that library.
		None,
		/// The same skeleton: bones matched by name, turns measured in each bone's own frame.
		SameSkeleton,
		/// Another humanoid: bones matched through the HumanMaps, turns measured in the model's space.
		Humanoid
	}

	/// How the clips from a library are fitted to this model, decided from the two skeletons' names.
	public RetargetMode ModeFor(SkinnedModel library)
	{
		if (library == null)
			return .None;
		let mine = HumanMap;
		let theirs = library.HumanMap;
		if (!mine.IsHumanoid || !theirs.IsHumanoid)
			return .SameSkeleton;
		// Bones both maps know: the same skeleton when most of them are named alike.
		int both = 0, alike = 0;
		for (int b < BoneMap.Count)
		{
			let a = mine[(HumanBone)b];
			let c = theirs[(HumanBone)b];
			if (a.IsEmpty || c.IsEmpty)
				continue;
			both++;
			if (a == c)
				alike++;
		}
		return (alike * 2 >= both) ? RetargetMode.SameSkeleton : RetargetMode.Humanoid;
	}

	/// Which joint of this model is each humanoid bone: matched by name, then corrected by the .bonemap file beside
	/// the model, when it has one (see BoneMap).
	public BoneMap HumanMap
	{
		get
		{
			if (mHumanMap != null)
				return mHumanMap;
			mHumanMap = new BoneMap();
			mHumanMap.Match(this);
			let file = scope String();
			let text = scope String();
			if (GetBoneMapPath(file) && Assets.ReadText(file, text))
				mHumanMap.Read(text, this, file);
			return mHumanMap;
		}
	}

	/// The model's .bonemap file ("Models/hero.bonemap" for "Models/hero.glb"); false for a model made in code.
	public bool GetBoneMapPath(String into)
	{
		if (Path.IsEmpty)
			return false;
		let dot = Path.LastIndexOf('.');
		let slash = Path.LastIndexOf('/');
		into.Append(dot > slash ? Path.Substring(0, dot) : Path);
		into.Append(BoneMap.Extension);
		return true;
	}

	/// Uses another bone map from now on (the editor's, while it is being fixed) and makes again the clips that
	/// depend on it: this model's own imported clips, and those other loaded models took from it.
	public void SetHumanMap(BoneMap map)
	{
		HumanMap.CopyFrom(map);
		RemakeImported(null);
		for (let other in sCache.Values)
		{
			if (other != this)
				other.RemakeImported(this);
		}
	}

	/// Reads every loaded model's bone map again (after a .bonemap file changed) and makes their imported clips again.
	public static void ReloadBoneMaps()
	{
		for (let model in sCache.Values)
			DeleteAndNullify!(model.mHumanMap);
		for (let model in sCache.Values)
			model.RemakeImported(null);
	}

	/// How many joints a joint has above it.
	public int Depth(int joint)
	{
		int depth = 0;
		var parent = Joints[joint].parent;
		while (parent >= 0 && depth < Joints.Count)
		{
			depth++;
			parent = Joints[parent].parent;
		}
		return depth;
	}

	/// Makes again the imported clips that came from a library (every library when null).
	void RemakeImported(SkinnedModel library)
	{
		let done = scope HashSet<SkinnedModel>();
		for (let imported in mImported)
		{
			let from = imported.library;
			if ((library != null && from != library) || done.Contains(from))
				continue;
			done.Add(from);
			let fit = scope Retargeting(this, from);
			for (let other in mImported)
			{
				if (other.library == from)
					fit.Make(other.from, other.clip);
			}
		}
	}

	/// Where a clip ImportClips added came from, so that it can be made again when a bone map changes.
	class ImportedClip
	{
		public Clip clip;
		public SkinnedModel library;
		public Clip from;
	}

	/// A pose of every joint in the model's space (the file's root transform included): position, turn and size.
	public struct GlobalPose
	{
		public Vector3 position;
		public Quaternion rotation;
		public Vector3 scale;
	}

	/// Fits the clips of one library to a model (see ImportClips).
	class Retargeting
	{
		SkinnedModel mTarget;
		SkinnedModel mSource;
		public RetargetMode mode;
		/// For each of the target's joints, the library's joint it follows, or -1.
		int[] mFrom ~ delete _;
		/// The hips' movement is multiplied by this: the target's leg length over the library's.
		public float scale = 1;
		/// Turns the library's facing into the target's (Humanoid only).
		Quaternion mFacing = .Identity;
		int mTargetHips = -1, mSourceHips = -1;
		/// For each of the target's joints, the swing that points it the way its counterpart points at rest (an arm
		/// hanging in an A pose for one lying out in a T pose), before the library's turns are applied.
		Quaternion[] mAlign ~ delete _;
		int[] mTargetOrder ~ delete _;
		int[] mSourceOrder ~ delete _;
		GlobalPose[] mTargetRest ~ delete _;
		GlobalPose[] mSourceRest ~ delete _;

		public this(SkinnedModel target, SkinnedModel source)
		{
			mTarget = target;
			mSource = source;
			mode = target.ModeFor(source);
			let mine = target.HumanMap;
			let theirs = source.HumanMap;
			mFrom = new int[target.Joints.Count];
			for (int j < target.Joints.Count)
			{
				let name = target.Joints[j].name;
				mFrom[j] = -1;
				if (mode == .Humanoid)
				{
					let bone = mine.BoneOf(name);
					if (bone >= 0)
						mFrom[j] = source.FindJoint(theirs[(HumanBone)bone]);
				}
				if (mFrom[j] < 0)
					mFrom[j] = source.FindJoint(name);
			}
			mTargetOrder = target.ParentsFirst();
			mSourceOrder = source.ParentsFirst();
			mTargetRest = new GlobalPose[target.Joints.Count];
			mSourceRest = new GlobalPose[source.Joints.Count];
			target.Pose(null, mTargetOrder, mTargetRest);
			source.Pose(null, mSourceOrder, mSourceRest);
			if (mine.IsHumanoid && theirs.IsHumanoid)
			{
				mTargetHips = target.FindJoint(mine[.Hips]);
				mSourceHips = source.FindJoint(theirs[.Hips]);
				let targetLegs = LegLength(target, mine, mTargetRest);
				let sourceLegs = LegLength(source, theirs, mSourceRest);
				if (targetLegs > 0.0001f && sourceLegs > 0.0001f)
					scale = targetLegs / sourceLegs;
				if (mode == .Humanoid)
					mFacing = Facing(target, mine, mTargetRest) * Facing(source, theirs, mSourceRest).Conjugate;
			}
			mAlign = new Quaternion[target.Joints.Count];
			for (int j < target.Joints.Count)
				mAlign[j] = mode == .Humanoid ? RestAlignment(j) : .Identity;
		}

		/// The bone a bone points at, for lining the rest poses up: the first of these both maps have.
		static void NextBones(HumanBone bone, List<HumanBone> next)
		{
			switch (bone)
			{
			case .Spine:
				next.Add(.Chest);
				next.Add(.UpperChest);
				next.Add(.Neck);
			case .Chest:
				next.Add(.UpperChest);
				next.Add(.Neck);
			case .UpperChest: next.Add(.Neck);
			case .Neck: next.Add(.Head);
			case .LeftShoulder: next.Add(.LeftUpperArm);
			case .LeftUpperArm: next.Add(.LeftLowerArm);
			case .LeftLowerArm: next.Add(.LeftHand);
			case .LeftHand:
				next.Add(.LeftMiddle1);
				next.Add(.LeftIndex1);
			case .RightShoulder: next.Add(.RightUpperArm);
			case .RightUpperArm: next.Add(.RightLowerArm);
			case .RightLowerArm: next.Add(.RightHand);
			case .RightHand:
				next.Add(.RightMiddle1);
				next.Add(.RightIndex1);
			case .LeftUpperLeg: next.Add(.LeftLowerLeg);
			case .LeftLowerLeg: next.Add(.LeftFoot);
			case .LeftFoot: next.Add(.LeftToes);
			case .RightUpperLeg: next.Add(.RightLowerLeg);
			case .RightLowerLeg: next.Add(.RightFoot);
			case .RightFoot: next.Add(.RightToes);
			default:
				// A finger's first two segments point at the next one.
				if (bone >= .LeftThumb1 && ((int)bone - (int)HumanBone.LeftThumb1) % 3 != 2)
					next.Add((HumanBone)((int)bone + 1));
			}
		}

		/// The swing from where a target joint points at rest to where its counterpart points at rest (both in the
		/// model's space, the library turned to face the same way), or none for a joint with nothing to point at.
		Quaternion RestAlignment(int joint)
		{
			let mine = mTarget.HumanMap;
			let theirs = mSource.HumanMap;
			let bone = mine.BoneOf(mTarget.Joints[joint].name);
			let source = mFrom[joint];
			if (bone < 0 || source < 0)
				return .Identity;
			let next = scope List<HumanBone>();
			NextBones((HumanBone)bone, next);
			for (let candidate in next)
			{
				let targetEnd = mTarget.FindJoint(mine[candidate]);
				let sourceEnd = mSource.FindJoint(theirs[candidate]);
				if (targetEnd < 0 || sourceEnd < 0)
					continue;
				let from = mTargetRest[targetEnd].position - mTargetRest[joint].position;
				let to = mFacing * (mSourceRest[sourceEnd].position - mSourceRest[source].position);
				if (from.Length < 0.000001f || to.Length < 0.000001f)
					return .Identity;
				return Swing(from.Normalized, to.Normalized);
			}
			return .Identity;
		}

		/// The shortest turn taking one direction onto another.
		static Quaternion Swing(Vector3 from, Vector3 to)
		{
			let dot = Vector3.Dot(from, to);
			if (dot < -0.99999f)
			{
				// Opposite: half a turn about any axis at right angles to them.
				var axis = Vector3.Cross(from, .Right);
				if (axis.Length < 0.001f)
					axis = Vector3.Cross(from, .Up);
				axis = axis.Normalized;
				return .(axis.x, axis.y, axis.z, 0);
			}
			let axis = Vector3.Cross(from, to);
			return Quaternion(axis.x, axis.y, axis.z, 1 + dot).Normalized;
		}

		/// The left leg's length (hip to knee to ankle) in the model's space, or 0 when the map lacks it.
		static float LegLength(SkinnedModel model, BoneMap map, GlobalPose[] rest)
		{
			let upper = model.FindJoint(map[.LeftUpperLeg]);
			let lower = model.FindJoint(map[.LeftLowerLeg]);
			let foot = model.FindJoint(map[.LeftFoot]);
			if (upper < 0 || lower < 0 || foot < 0)
				return 0;
			return (rest[lower].position - rest[upper].position).Length + (rest[foot].position - rest[lower].position).Length;
		}

		/// The turn about the up axis from facing +Z to the way the skeleton faces at rest (from its left side to
		/// its right, across the upper legs or the upper arms).
		static Quaternion Facing(SkinnedModel model, BoneMap map, GlobalPose[] rest)
		{
			var left = model.FindJoint(map[.LeftUpperLeg]);
			var right = model.FindJoint(map[.RightUpperLeg]);
			if (left < 0 || right < 0)
			{
				left = model.FindJoint(map[.LeftUpperArm]);
				right = model.FindJoint(map[.RightUpperArm]);
			}
			if (left < 0 || right < 0)
				return .Identity;
			let across = rest[right].position - rest[left].position;
			if (Math.Abs(across.x) + Math.Abs(across.z) < 0.0001f)
				return .Identity;
			// Facing +Z, a character's right is -X (right-handed, Y up).
			let degrees = Math.Atan2(-across.z, -across.x) * (180.0f / Math.PI_f);
			return Quaternion.AngleAxis(-degrees, .Up);
		}

		/// Fills a clip of the target from a clip of the library, frame by frame.
		public void Make(Clip from, Clip into)
		{
			let jointCount = mTarget.Joints.Count;
			let sourceCount = mSource.Joints.Count;
			delete into.data;
			into.data = new float[from.frames * jointCount * 10];
			// Same skeleton: a bone moves in the clip when its position leaves the library's rest position.
			let moves = scope bool[jointCount];
			if (mode == .SameSkeleton)
			{
				for (int j < jointCount)
				{
					let source = mFrom[j];
					if (source < 0)
						continue;
					let rest = mSource.Joints[source].restPosition;
					for (int f < from.frames)
					{
						let a = from.data.Ptr + (f * sourceCount + source) * 10;
						if ((Vector3(a[0], a[1], a[2]) - rest).Length > 0.0001f)
						{
							moves[j] = true;
							break;
						}
					}
				}
			}
			let sourcePose = scope GlobalPose[sourceCount];
			let targetPose = scope GlobalPose[jointCount];
			for (int f < from.frames)
			{
				let frame = from.data.Ptr + f * sourceCount * 10;
				let output = into.data.Ptr + f * jointCount * 10;
				if (mode == .Humanoid)
				{
					mSource.Pose(frame, mSourceOrder, sourcePose);
					MakeHumanoidFrame(sourcePose, targetPose, output);
				}
				else
				{
					MakeSameSkeletonFrame(frame, moves, output);
				}
			}
		}

		void MakeSameSkeletonFrame(float* frame, bool[] moves, float* output)
		{
			for (int j < mTarget.Joints.Count)
			{
				let joint = mTarget.Joints[j];
				var position = joint.restPosition;
				var rotation = joint.restRotation;
				let source = mFrom[j];
				if (source >= 0)
				{
					let a = frame + source * 10;
					let sourceRest = mSource.Joints[source];
					rotation = (joint.restRotation * sourceRest.restRotation.Conjugate * Quaternion(a[3], a[4], a[5], a[6])).Normalized;
					if (moves[j])
						position = joint.restPosition + (Vector3(a[0], a[1], a[2]) - sourceRest.restPosition) * scale;
				}
				Write(output + j * 10, position, rotation, joint.restScale);
			}
		}

		void MakeHumanoidFrame(GlobalPose[] source, GlobalPose[] pose, float* output)
		{
			for (let j in mTargetOrder)
			{
				let joint = mTarget.Joints[j];
				let parent = joint.parent >= 0 ? pose[joint.parent] : mTarget.RootPose(j);
				var rotation = joint.restRotation;
				var position = joint.restPosition;
				let from = mFrom[j];
				if (from >= 0)
				{
					// The bone's turn from rest in the library's space, turned to face the target's way.
					let turn = mFacing * source[from].rotation * mSourceRest[from].rotation.Conjugate * mFacing.Conjugate;
					rotation = (parent.rotation.Conjugate * turn * mAlign[j] * mTargetRest[j].rotation).Normalized;
				}
				if (j == mTargetHips && mSourceHips >= 0)
				{
					let moved = mFacing * (source[mSourceHips].position - mSourceRest[mSourceHips].position) * scale;
					let world = mTargetRest[j].position + moved;
					position = (parent.rotation.Conjugate * (world - parent.position)) / parent.scale;
				}
				pose[j].rotation = (parent.rotation * rotation).Normalized;
				pose[j].position = parent.position + parent.rotation * (parent.scale * position);
				pose[j].scale = parent.scale * joint.restScale;
				Write(output + j * 10, position, rotation, joint.restScale);
			}
		}

		static void Write(float* b, Vector3 position, Quaternion rotation, Vector3 scale)
		{
			b[0] = position.x;
			b[1] = position.y;
			b[2] = position.z;
			b[3] = rotation.x;
			b[4] = rotation.y;
			b[5] = rotation.z;
			b[6] = rotation.w;
			b[7] = scale.x;
			b[8] = scale.y;
			b[9] = scale.z;
		}
	}

	/// The joints in an order where each comes after its parent.
	int[] ParentsFirst()
	{
		let order = new int[Joints.Count];
		ParentsFirst(order);
		return order;
	}

	void ParentsFirst(int[] order)
	{
		let depth = scope int[Joints.Count];
		for (int j < Joints.Count)
		{
			order[j] = j;
			depth[j] = Depth(j);
		}
		Array.Sort(order, scope (a, b) => depth[a] != depth[b] ? depth[a] - depth[b] : a - b);
	}

	/// What a root joint hangs from: the file's transform above the skeleton (none for a model made in code).
	GlobalPose RootPose(int joint)
	{
		GlobalPose pose;
		let world = Joints[joint].parentWorld;
		if (world.m[15] == 0)
		{
			pose.position = .Zero;
			pose.rotation = .Identity;
			pose.scale = .One;
			return pose;
		}
		world.Decompose(out pose.position, out pose.rotation, out pose.scale);
		return pose;
	}

	/// Every joint's pose in the model's space (glTF's right-handed axes, before the Z flip on drawing) at a frame of a
	/// clip, or at rest when clip is null. pose needs one entry a joint.
	public void SamplePose(Clip clip, int frame, GlobalPose[] pose)
	{
		let order = scope int[Joints.Count];
		ParentsFirst(order);
		float* data = null;
		if (clip != null && clip.frames > 0)
			data = clip.data.Ptr + Math.Clamp(frame, 0, clip.frames - 1) * Joints.Count * 10;
		Pose(data, order, pose);
	}

	/// Every joint's pose in the model's space, from a frame of a clip (ten numbers a joint), or at rest when null.
	void Pose(float* frame, int[] order, GlobalPose[] pose)
	{
		for (let j in order)
		{
			let joint = Joints[j];
			var position = joint.restPosition;
			var rotation = joint.restRotation;
			var scale = joint.restScale;
			if (frame != null)
			{
				let a = frame + j * 10;
				position = .(a[0], a[1], a[2]);
				rotation = .(a[3], a[4], a[5], a[6]);
				scale = .(a[7], a[8], a[9]);
			}
			let parent = joint.parent >= 0 ? pose[joint.parent] : RootPose(j);
			pose[j].rotation = (parent.rotation * rotation).Normalized;
			pose[j].position = parent.position + parent.rotation * (parent.scale * position);
			pose[j].scale = parent.scale * scale;
		}
	}

	/// An image found in a model, read on a loading thread and turned into a texture on the main thread.
	public class PendingImage
	{
		public String name = new .() ~ delete _;
		public uint8[] pixels ~ delete _;
		public int32 width, height;
		public TextureKind kind;
	}

	/// True when the model is loaded already (Load returns it at once).
	public static bool IsLoaded(StringView path) => sCache.ContainsKeyAlt(path);

	/// Loads (and caches) a rigged model. Returns null when the file has no skeleton.
	public static SkinnedModel Load(StringView path)
	{
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let model = Build(path, null);
		if (model != null)
			sCache[new String(path)] = model;
		return model;
	}

	/// Takes a model read on a loading thread (Build) into the cache, making textures of its images. Returns the
	/// model now cached under that path (an earlier one if it was loaded meanwhile; the new one is then deleted).
	public static SkinnedModel Adopt(StringView path, SkinnedModel model, List<PendingImage> images)
	{
		for (let image in images)
			Assets.AddTexture(image.name, image.pixels.Ptr, image.width, image.height, image.kind);
		if (sCache.TryGetValueAlt(path, let cached))
		{
			delete model;
			return cached;
		}
		if (model != null)
			sCache[new String(path)] = model;
		return model;
	}

	/// Reads a rigged model without touching the graphics card or the cache, so that it can run on a loading thread:
	/// with images given, the model's pictures are copied into it instead of being made into textures.
	public static SkinnedModel Build(StringView path, List<PendingImage> images)
	{
		let full = scope String();
		Assets.ResolvePath(path, full);
		let scene = Native.tn_gltf_load(full.CStr());
		if (scene == null)
			return null;
		defer Native.tn_gltf_free(scene);
		let jointCount = Native.tn_gltf_joint_count(scene);
		if (jointCount == 0)
			return null;

		let model = new SkinnedModel();
		model.Path.Set(path);
		model.ReadJoints(scene, jointCount);
		model.ReadClips(scene, jointCount);
		let imageNames = scope List<String>();
		defer
		{
			for (let name in imageNames)
				delete name;
		}
		ReadImages(scene, path, images, imageNames);
		bool anyTexture = false;
		for (uint32 p < Native.tn_gltf_prim_count(scene))
		{
			let prim = Native.tn_gltf_get_prim(scene, p);
			if (prim.joints == null)
				continue;
			model.AddPrimitive(prim, model.PartFor(prim, imageNames, ref anyTexture), jointCount);
		}
		model.HasOwnMaterials = model.Parts.Count > 1 || anyTexture;
		if (model.Positions.Count == 0)
		{
			delete model;
			return null;
		}
		return model;
	}

	void ReadJoints(void* scene, int32 jointCount)
	{
		for (int32 j < jointCount)
		{
			let source = Native.tn_gltf_get_joint(scene, j);
			Joint joint;
			joint.name = new String(&source.name);
			joint.parent = source.parent;
			joint.restPosition = .(source.rest[0], source.rest[1], source.rest[2]);
			joint.restRotation = .(source.rest[3], source.rest[4], source.rest[5], source.rest[6]);
			joint.restScale = .(source.rest[7], source.rest[8], source.rest[9]);
			joint.inverseBind = default;
			joint.parentWorld = default;
			for (int i < 16)
			{
				joint.inverseBind.m[i] = source.inverseBind[i];
				joint.parentWorld.m[i] = source.parentWorld[i];
			}
			Joints.Add(joint);
		}
	}

	/// Each clip: 30 frames a second, ten numbers a joint a frame (position, rotation, scale).
	void ReadClips(void* scene, int32 jointCount)
	{
		for (int32 a < Native.tn_gltf_anim_count(scene))
		{
			let source = Native.tn_gltf_get_anim(scene, a);
			let clip = new Clip();
			clip.name.Append(&source.name);
			clip.duration = source.duration;
			clip.frames = source.frames;
			let count = source.frames * jointCount * 10;
			clip.data = new float[count];
			Internal.MemCpy(clip.data.Ptr, source.data, count * sizeof(float));
			Clips.Add(clip);
		}
	}

	/// The file's images become textures named after it: "Models/hero.glb#image2". With `images` given they are
	/// copied out for the main thread to make into textures; otherwise they are made into textures now.
	public static void ReadImages(void* scene, StringView path, List<PendingImage> images, List<String> names)
	{
		for (int32 i < Native.tn_gltf_image_count(scene))
		{
			int32 width = 0, height = 0;
			let pixels = Native.tn_gltf_get_image(scene, i, &width, &height);
			let name = new String()..AppendF("{}#image{}", path, i);
			names.Add(name);
			if (pixels == null)
				continue;
			if (images == null)
			{
				Assets.AddTexture(name, pixels, width, height, Textures.GltfImageKind(scene, i));
				continue;
			}
			let image = new PendingImage();
			image.name.Set(name);
			image.width = width;
			image.height = height;
			image.kind = Textures.GltfImageKind(scene, i);
			image.pixels = new uint8[width * height * 4];
			Internal.MemCpy(image.pixels.Ptr, pixels, width * height * 4);
			images.Add(image);
		}
	}

	/// The part for a primitive's material, made (with that material) the first time the material comes up.
	Part PartFor(Native.GltfPrim* prim, List<String> imageNames, ref bool anyTexture)
	{
		for (let existing in Parts)
		{
			if (existing.fileMaterial == prim.material)
				return existing;
		}
		let part = new Part();
		part.fileMaterial = prim.material;
		part.name.Append(&prim.materialName);
		if (part.name.IsEmpty)
			part.name.AppendF("Part {}", Parts.Count + 1);
		part.material = MaterialFrom(prim, imageNames, ref anyTexture);
		Parts.Add(part);
		return part;
	}

	/// A glTF primitive's material as an engine one: its colours, maps (the file's images, named by imageNames) and
	/// blending. anyTexture becomes true when it has a map. Also used by Mesh Renderers (Assets.GetModelParts).
	public static Material MaterialFrom(Native.GltfPrim* prim, List<String> imageNames, ref bool anyTexture)
	{
		void Image(String into, int32 index)
		{
			into.Clear();
			if (index >= 0 && index < imageNames.Count)
				into.Set(imageNames[index]);
		}
		let material = new Material();
		material.flatShading = false;
		material.metallic = prim.metallic;
		material.roughness = prim.roughness;
		material.emissive = Color(prim.emissive[0], prim.emissive[1], prim.emissive[2], 1);
		material.emissiveIntensity = (prim.emissive[0] + prim.emissive[1] + prim.emissive[2]) > 0 ? 1 : 0;
		Image(material.texture, prim.baseColorImage);
		Image(material.normalMap, prim.normalImage);
		material.normalStrength = prim.normalScale;
		Image(material.metallicRoughnessMap, prim.metalRoughImage);
		Image(material.occlusionMap, prim.occlusionImage);
		material.occlusionStrength = prim.occlusionStrength;
		Image(material.emissiveMap, prim.emissiveImage);
		if (!material.emissiveMap.IsEmpty)
			material.emissiveIntensity = 1;
		material.blend = prim.alphaMode == 1 ? .Cutout : (prim.alphaMode == 2 ? .Transparent : .Opaque);
		material.cutoff = prim.alphaCutoff;
		material.doubleSided = prim.doubleSided != 0;
		anyTexture |= !material.texture.IsEmpty || !material.normalMap.IsEmpty || !material.metallicRoughnessMap.IsEmpty || !material.occlusionMap.IsEmpty || !material.emissiveMap.IsEmpty;
		return material;
	}

	/// A primitive's vertices (with up to four joints each, their weights adding to one) and triangles.
	void AddPrimitive(Native.GltfPrim* prim, Part part, int32 jointCount)
	{
		let baseVertex = (uint32)Positions.Count;
		let baseColor = Color(prim.baseColor[0], prim.baseColor[1], prim.baseColor[2], prim.baseColor[3]);
		for (uint32 v < prim.vertexCount)
		{
			Positions.Add(.(prim.positions[v * 3], prim.positions[v * 3 + 1], prim.positions[v * 3 + 2]));
			Normals.Add(prim.normals != null ? Vector3(prim.normals[v * 3], prim.normals[v * 3 + 1], prim.normals[v * 3 + 2]) : Vector3.Up);
			var color = baseColor;
			if (prim.colors != null)
			{
				color.r *= prim.colors[v * 4];
				color.g *= prim.colors[v * 4 + 1];
				color.b *= prim.colors[v * 4 + 2];
			}
			// glTF stores linear color; the shader expects sRGB-encoded vertex colors.
			Colors.Add(Color(Math.Pow(color.r, 1.0f / 2.2f), Math.Pow(color.g, 1.0f / 2.2f), Math.Pow(color.b, 1.0f / 2.2f), color.a).ToABGR());
			UVs.Add(prim.uvs != null ? Vector2(prim.uvs[v * 2], prim.uvs[v * 2 + 1]) : default);
			float total = 0;
			for (int k < 4)
				total += prim.weights[v * 4 + (uint32)k];
			for (int k < 4)
			{
				JointIndices.Add((uint16)Math.Min((int32)prim.joints[v * 4 + (uint32)k], jointCount - 1));
				Weights.Add(total > 0 ? prim.weights[v * 4 + (uint32)k] / total : (k == 0 ? 1.0f : 0.0f));
			}
		}
		// Mirroring Z on output turns triangles inside out, so swap two corners.
		for (uint32 i = 0; i + 2 < prim.indexCount; i += 3)
		{
			let a = baseVertex + prim.indices[i];
			let b = baseVertex + prim.indices[i + 2];
			let c = baseVertex + prim.indices[i + 1];
			Indices.Add(a);
			Indices.Add(b);
			Indices.Add(c);
			part.indices.Add(a);
			part.indices.Add(b);
			part.indices.Add(c);
		}
	}
}
