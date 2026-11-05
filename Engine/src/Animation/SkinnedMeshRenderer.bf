using System;
using System.Collections;

namespace Tallow;

/// Draws a rigged model and plays its animation clips, bending the mesh with its skeleton.
/// Export from Blender as glTF 2.0 (.glb) with the armature, mesh and animations included.
///
/// Materials: a model with several materials, or any textures, is drawn in parts, one per material, each with the
/// material saved in the file (its textures included) unless the part is given a .tmat of its own (the Inspector
/// lists the parts; SetPartMaterial from code). A material on the Mesh Renderer covers every part that has none of
/// its own. A model with one plain material is one mesh drawn with the Mesh Renderer's settings, as before.
/// See docs/skinned-materials.md.
/// A Skinned Mesh Renderer's settings, in its entity (SkinnedMeshRenderer is the handle).
[Component, HandleData]
struct SkinnedMeshRendererData
{
	/// Rigged .glb / .gltf file relative to the project's asset folder.
	public SharedString model = default;
	/// Clip to start with; empty plays the first clip in the file.
	public SharedString clip = default;
	/// Rigged .glb files whose clips this model can play too, separated by ';': a file of animations made for the
	/// same skeleton (bones are matched by name), such as the Basic Motions asset pack for POLYGON characters.
	public SharedString clipLibrary = default;
	public float speed = 1.0f;
	public bool loop = true;
	/// Makes an object for every bone of the skeleton, under this one, and bends the mesh from those objects: then
	/// things can be parented to a bone (a weapon in a hand), the IK components can work on the skeleton, an Animator
	/// can play .tanim clips on it and the Animation window can key it. The model's own clips still play, underneath.
	/// The objects are ordinary ones, saved with the scene; delete them yourself if you turn this off again.
	public bool exposeBones = false;
	/// Bends the mesh on the graphics card (much cheaper for crowds), where it can do compute work. Off bends it on the
	/// CPU, keeping the bent vertices in Mesh.Vertices for code that reads them.
	public bool gpuSkinning = true;
	/// The parts' own materials, "Part=Materials/skin.tmat;Other=..." (the Inspector edits it as a list).
	[HideInInspector]
	public SharedString materials = default;
	/// Parts not drawn, by name, separated by ';': the clothes a character is not wearing, when every choice of a
	/// character customizer is a part of one model ("Hat_Tricorn;Hair_Long").
	public SharedString hiddenParts = default;
	/// Parts drawn only into shadows, by name, separated by ';': a first-person player's own head.
	public SharedString shadowOnlyParts = default;
	/// Each part's colour, multiplying its material's, "Coat=0.5 0.1 0.1;Hair=0.2 0.15 0.1" (red, green, blue from 0
	/// to 1): one model dressed in many colours.
	public SharedString partColors = default;


	public this() { }
}

/// A handle (ComponentHandle): its settings are SkinnedMeshRendererData's fields; the model, the clips playing and
/// the bent mesh are its SkinnedRig, kept outside the data and freed with the component.
[Component, HandleFields]
struct SkinnedMeshRenderer : ComponentHandle<SkinnedMeshRendererData>
{
	/// The rig, made the first time it is needed, with the settings copied in from the entity now (a changed model,
	/// clip or clip library is loaded, as the Inspector's edits were).
	public SkinnedRig Rig
	{
		get
		{
			CheckValid();
			let world = mGameObject.Scene.World;
			let rig = ComponentState<SkinnedRig>.Make(world, mGameObject.Entity);
			if (rig.[Friend]mGameObject == null)
			{
				rig.[Friend]mGameObject = mGameObject;
				rig.[Friend]mEcsWorld = world;
				rig.[Friend]mEntity = mGameObject.Entity;
				rig.data = Data;
				rig.[Friend]Started();
			}
			else
				rig.[Friend]Refresh(Data);
			return rig;
		}
	}

	/// Set by an Animator whose controller uses layers or blend trees: it poses the bone objects from the model's
	/// clips itself, so the renderer leaves them alone.
	public ref bool posedByAnimator => ref Rig.posedByAnimator;

	public Transform Bone(StringView name) => Rig.Bone(name);
	public int BoneCount => Rig.BoneCount;
	public Transform BoneAt(int joint) => Rig.BoneAt(joint);
	public bool PoseBones(StringView clipName, float time) => Rig.PoseBones(clipName, time);
	public StringView CurrentClip => Rig.CurrentClip;
	public SkinnedModel Model => Rig.Model;
	public int PartCount => Rig.PartCount;
	public StringView PartName(int index) => Rig.PartName(index);
	public void GetPartMaterial(StringView part, String path) => Rig.GetPartMaterial(part, path);
	public bool HasClip(StringView name) => Rig.HasClip(name);
	public void Play(StringView name, float fadeSeconds = 0.15f) => Rig.Play(name, fadeSeconds);
	public void PlayLayer(StringView name, StringView bones, float fadeSeconds = 0.15f) => Rig.PlayLayer(name, bones, fadeSeconds);
	public void StopLayer(float fadeSeconds = 0.15f) => Rig.StopLayer(fadeSeconds);
	public StringView CurrentLayerClip => Rig.CurrentLayerClip;
	public bool SkinnedOnGpu => Rig.SkinnedOnGpu;
	/// Loads what the settings now name (a changed model, clip or clip library) at once, rather than on the next frame.
	public void Refresh()
	{
		Rig.[Friend]mGameObject = mGameObject;
	}

	/// Animates and bends it now, as a frame does (an editor tool that poses it outside the frame).
	public void FrameNow() => Rig.[Friend]Frame();
	public Bounds BoundsFromJoints() => Rig.BoundsFromJoints();

	/// Gives a part a .tmat of its own (empty: back to the model's own material). In a network session, on the server
	/// or on the owner's machine, every machine follows.
	public void SetPartMaterial(int index, StringView path)
	{
		let part = PartName(index);
		if (part.IsEmpty || path.Contains(';') || path.Contains('='))
			return;
		let current = scope String();
		GetPartMaterial(part, current);
		if (current == path)
			return;
		let rebuilt = scope String();
		for (var entry in materials.View.Split(';'))
		{
			let equals = entry.IndexOf('=');
			if (entry.IsEmpty || (equals > 0 && entry.Substring(0, equals) == part))
				continue;
			rebuilt.AppendF("{}{}", rebuilt.IsEmpty ? "" : ";", entry);
		}
		if (!path.IsEmpty)
			rebuilt.AppendF("{}{}={}", rebuilt.IsEmpty ? "" : ";", part, path);
		materials = rebuilt;
		if (mGameObject.HasComponent<MeshRenderer>())
			NetworkSync.MaterialChanged(mGameObject.GetComponent<MeshRenderer>(), 2, path, .(index, 0, 0, 0));
	}

	/// Sets a part's colour (Part Colors), by the part's name.
	public void SetPartColor(StringView part, Color color)
	{
		SkinnedRig.SetEntry(ref partColors, part, scope $"{color.r:0.###} {color.g:0.###} {color.b:0.###}");
	}

	/// Hides or shows a part (Hidden Parts), by the part's name.
	public void SetPartHidden(StringView part, bool hidden) => SkinnedRig.SetListed(ref hiddenParts, part, hidden);

	/// Draws a part only into shadows, or normally again (Shadow Only Parts), by the part's name.
	public void SetPartShadowOnly(StringView part, bool shadowOnly) => SkinnedRig.SetListed(ref shadowOnlyParts, part, shadowOnly);

	/// Animates and re-skins every switched-on renderer on an active object, in the editor as well as in play mode
	/// (the Frame.OnFrame step).
	public static void FrameAll(Scene scene)
	{
		for (let skinned in scene.Components<SkinnedMeshRenderer>(.. scope .()))
		{
			if (skinned.GameObject.ActiveInHierarchy)
				skinned.Rig.[Friend]Frame();
		}
	}

	/// Bends every rigged model whose bones are objects from where those objects are now. Scene.Update calls it at the
	/// end of the frame, after animation, scripts and IK have had their say.
	public static void SkinFromBones(Scene scene) => SkinnedRig.SkinFromBones(scene);
	/// Bends every model queued this frame on the CPU (SkinnedRig.FinishCpuSkinning).
	public static void FinishCpuSkinning() => SkinnedRig.FinishCpuSkinning();
	/// Has every rig of a model load it again (SkinnedModel.Forget).
	public static void ModelChanged(StringView path) => SkinnedRig.ModelChanged(path);

	static void OnRemove(void* world, uint64 entity)
	{
		if (let rig = ComponentState<SkinnedRig>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
			rig.[Friend]Detach();
		ComponentState<SkinnedRig>.Release(world, entity);
	}
}

/// What a Skinned Mesh Renderer keeps between frames: the model, the clips playing and their blend, the bone objects
/// and the bent mesh it hands its Mesh Renderer. `data` is a copy of the settings, refreshed whenever the handle
/// hands the rig out.
[DataFields(typeof(SkinnedMeshRendererData), "data")]
class SkinnedRig
{
	public SkinnedMeshRendererData data = .();
	/// Set by an Animator whose controller uses layers or blend trees (see SkinnedMeshRenderer.posedByAnimator).
	public bool posedByAnimator;

	GameObject mGameObject;
	World mEcsWorld;
	Entity mEntity;

	public ~this()
	{
		// Frees the GPU skinning buffers and arrays (GpuSkinning.bf).
		ReleaseGpuSkinning();
	}

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject.Scene;
	MeshRenderer Renderer => (mGameObject != null && mGameObject.HasComponent<MeshRenderer>()) ? mGameObject.GetComponent<MeshRenderer>() : default;
	bool IsActiveAndEnabled => mGameObject != null && !mGameObject.IsDestroyed && mGameObject.ActiveInHierarchy && mGameObject.GetComponent<SkinnedMeshRenderer>().enabled;

	/// Takes new settings: a changed model, clip or clip library is loaded, Expose Bones makes or forgets the bones.
	void Refresh(SkinnedMeshRendererData settings)
	{
		let before = data;
		data = settings;
		if (before.model != data.model || before.clip != data.clip || before.clipLibrary != data.clipLibrary)
			Reload();
		if (mBonesFor != exposeBones)
			SyncBones();
	}

	SkinnedModel mModel;
	String mLoadedPath = new .() ~ delete _;
	String mLoadedLibrary = new .() ~ delete _;
	Mesh mMesh ~ delete _;
	// One per part of a model with materials of its own (SkinnedModel.Parts), sharing mMesh's vertices.
	List<MeshRenderer.Part> mParts = new .() ~ { for (let part in _) delete part.mesh; DeleteContainerAndItems!(_); };
	String mResolvedMaterials = new .() ~ delete _;
	String mResolvedLooks = new .() ~ delete _;
	int32 mResolvedRendererMaterial = -1;
	SkinnedModel.Clip mCurrent;
	SkinnedModel.Clip mPrevious;
	float mTime;
	float mPreviousTime;
	float mFade;
	float mFadeDuration;
	Matrix4[] mWorld ~ delete _;
	Matrix4[] mSkin ~ delete _;
	bool[] mDone ~ delete _;
	bool mAttachPending;
	Transform[] mBones ~ delete _;
	bool mBonesFor;
	bool mSkinnedOnce;
	int32 mStagger = sNextStagger++;
	// The layer (PlayLayer): its clip, the one it is fading from, and which bones it poses.
	SkinnedModel.Clip mLayer;
	SkinnedModel.Clip mLayerPrevious;
	float mLayerTime, mLayerPreviousTime, mLayerFade, mLayerFadeDuration;
	float mLayerWeight, mLayerTarget, mLayerWeightSpeed;
	bool[] mLayerMask ~ delete _;
	String mLayerBones = new .() ~ delete _;
	static int32 sNextStagger;
	static List<SkinnedRig> sAll = new .() ~ delete _;

	/// While nothing draws the model, its mesh is bent only on every this many frames.
	const int HiddenSkinInterval = 8;

	/// The object for a bone, by the bone's name in the model, when Expose Bones is on; else null.
	public Transform Bone(StringView name)
	{
		if (mModel == null || mBones == null)
			return null;
		for (int i < mModel.Joints.Count)
		{
			if (mModel.Joints[i].name == name)
				return mBones[i];
		}
		return null;
	}

	/// How many bone objects there are (the model's joints, while Expose Bones is on; else 0).
	public int BoneCount => mBones != null ? mBones.Count : 0;

	/// The object for the model's joint of that number (SkinnedModel.Joints), when Expose Bones is on; else null.
	public Transform BoneAt(int joint) => (mBones != null && joint >= 0 && joint < mBones.Count) ? mBones[joint] : null;

	/// Puts the bone objects in the pose one of the model's clips has at a time (Expose Bones on). False when there
	/// are no bone objects or no such clip. The Animation window copies a model's clips into editable ones with it.
	public bool PoseBones(StringView clipName, float time)
	{
		let source = mModel != null ? mModel.FindClip(clipName) : null;
		if (source == null || mBones == null)
			return false;
		for (int i < mModel.Joints.Count)
		{
			let bone = mBones[i];
			if (bone == null || bone.GameObject.IsDestroyed)
				continue;
			Vector3 position, scale;
			Quaternion rotation;
			SamplePose(source, time, i, out position, out rotation, out scale, false);
			bone.LocalPosition = Mirror(position);
			bone.LocalRotation = Mirror(rotation);
			bone.LocalScale = scale;
		}
		return true;
	}

	// The model's space is right-handed and Tallow's is not: a pose crosses over by mirroring Z.
	static Vector3 Mirror(Vector3 v) => .(v.x, v.y, -v.z);
	static Quaternion Mirror(Quaternion q) => .(-q.x, -q.y, q.z, q.w);

	static Transform ChildNamed(Transform parent, StringView name)
	{
		for (let child in parent.Children)
		{
			if (child.GameObject.Name == name && !child.GameObject.IsDestroyed)
				return child;
		}
		return null;
	}

	Transform BoneObject(int index)
	{
		if (mBones[index] != null)
			return mBones[index];
		let joint = mModel.Joints[index];
		var parent = Transform;
		if (joint.parent >= 0)
			parent = BoneObject(joint.parent);
		else
		{
			// What the file has above the skeleton (an armature turned or scaled) becomes an object above the root
			// bone, so that bone objects sit exactly where the mesh's bones are.
			let above = joint.parentWorld;
			let scale = Vector3(above.Right.Length, above.Up.Length, above.Forward.Length);
			let plain = (above.Translation).LengthSquared < 1.0e-10f && Math.Abs(scale.x - 1) < 1.0e-4f && Math.Abs(scale.y - 1) < 1.0e-4f && Math.Abs(scale.z - 1) < 1.0e-4f
				&& Math.Abs(above.Right.x - 1) < 1.0e-4f && Math.Abs(above.Up.y - 1) < 1.0e-4f;
			if (!plain && scale.x > 0 && scale.y > 0 && scale.z > 0)
			{
				let name = scope $"{joint.name}.Armature";
				var holder = ChildNamed(Transform, name);
				if (holder == null)
					holder = Scene.CreateGameObject(name, Transform).Transform;
				holder.LocalPosition = Mirror(above.Translation);
				holder.LocalRotation = Mirror(Quaternion.FromBasis(above.Right / scale.x, above.Up / scale.y, above.Forward / scale.z));
				holder.LocalScale = scale;
				parent = holder;
			}
		}
		var bone = ChildNamed(parent, joint.name);
		if (bone == null)
		{
			bone = Scene.CreateGameObject(joint.name, parent).Transform;
			bone.LocalPosition = Mirror(joint.restPosition);
			bone.LocalRotation = Mirror(joint.restRotation);
			bone.LocalScale = joint.restScale;
		}
		mBones[index] = bone;
		return bone;
	}

	/// Finds the bone objects, making the ones that are missing.
	void SyncBones()
	{
		delete mBones;
		mBones = null;
		mBonesFor = exposeBones;
		if (!exposeBones || mModel == null)
			return;
		mBones = new Transform[mModel.Joints.Count];
		for (int i < mModel.Joints.Count)
			BoneObject(i);
	}

	/// Bends every rigged model whose bones are objects from where those objects are now (SkinnedMeshRenderer).
	public static void SkinFromBones(Scene scene)
	{
		for (let (entity, rig) in ComponentState<SkinnedRig>.In(scene.World, .. scope .()))
		{
			if (rig.exposeBones && rig.mBones != null && rig.IsActiveAndEnabled)
				rig.SkinNow();
		}
	}

	void BoneWorld(int index)
	{
		if (mDone[index])
			return;
		let joint = mModel.Joints[index];
		let bone = mBones[index];
		Matrix4 local;
		if (bone != null && !bone.GameObject.IsDestroyed)
			local = Matrix4.TRS(Mirror(bone.LocalPosition), Mirror(bone.LocalRotation), bone.LocalScale);
		else
			local = Matrix4.TRS(joint.restPosition, joint.restRotation, joint.restScale);
		if (joint.parent >= 0)
		{
			BoneWorld(joint.parent);
			mWorld[index] = mWorld[joint.parent] * local;
		}
		else
			mWorld[index] = joint.parentWorld * local;
		mSkin[index] = mWorld[index] * joint.inverseBind;
		mDone[index] = true;
	}

	/// Whether to bend the mesh this frame. Bending is most of an animated model's cost, so it is done every frame
	/// only while some view or shadow map draws the model. While none does (off screen and too far away to cast a
	/// shadow), it is done on every eighth frame, so the pose and bounds it is found again with are recent, and on a
	/// dedicated server, which draws nothing, not at all. The animation itself keeps playing either way.
	bool ShouldSkin()
	{
		if (Application.Instance != null && Application.Instance.Headless)
			return false;
		if (!mSkinnedOnce)
			return true;
		let renderer = Renderer;
		if (!renderer || renderer.LastDrawnFrame >= Time.FrameCount - 1)
			return true;
		return (Time.FrameCount + mStagger) % HiddenSkinInterval == 0;
	}

	void SkinNow()
	{
		if (mModel == null || mMesh == null || mBones == null || mBones.Count != mModel.Joints.Count)
			return;
		if (!ShouldSkin())
			return;
		for (int i < mDone.Count)
			mDone[i] = false;
		for (int i < mModel.Joints.Count)
			BoneWorld(i);
		SkinVertices();
	}

	public StringView CurrentClip => mCurrent != null ? (StringView)mCurrent.name : "";
	public SkinnedModel Model => mModel;

	/// Made: load the model.
	void Started()
	{
		sAll.Add(this);
		Reload();
	}

	/// The component is going: nothing may draw or bend this rig's mesh any more.
	void Detach()
	{
		sAll.Remove(this);
		if (mCpuQueued)
		{
			sCpuQueue.Remove(this);
			mCpuQueued = false;
		}
		// The renderer's proxy, if it is still there (it may have gone first as the entity is deleted).
		if (let proxy = ComponentState<RenderProxy>.Get(mEcsWorld, mEntity))
		{
			if (proxy.RuntimeMesh == mMesh)
				proxy.RuntimeMesh = null;
			if (proxy.RuntimeParts == mParts)
				proxy.RuntimeParts = null;
		}
	}

	/// The model's parts (one per material) when it is drawn in parts, else none: their names are the model's
	/// material names.
	public int PartCount => (mModel != null && mModel.HasOwnMaterials) ? mModel.Parts.Count : 0;
	public StringView PartName(int index) => (index >= 0 && index < PartCount) ? (StringView)mModel.Parts[index].name : "";

	/// The .tmat a part is drawn with instead of the model's own material, or empty.
	public void GetPartMaterial(StringView part, String path)
	{
		path.Clear();
		for (var entry in materials.View.Split(';'))
		{
			let equals = entry.IndexOf('=');
			if (equals > 0 && entry.Substring(0, equals) == part)
			{
				path.Append(entry.Substring(equals + 1));
				return;
			}
		}
	}

	/// Which material each part draws with: its own .tmat, else the Mesh Renderer's material, else the model's.
	void ResolvePartMaterials(MeshRenderer renderer)
	{
		let rendererMaterial = renderer.ActiveMaterial;
		let rendererKey = rendererMaterial != null ? (int32)(int)Internal.UnsafeCastToPtr(rendererMaterial) ^ rendererMaterial.Revision : 0;
		if (materials == mResolvedMaterials && mResolvedRendererMaterial == rendererKey)
			return;
		mResolvedMaterials.Set(materials);
		mResolvedRendererMaterial = rendererKey;
		let path = scope String();
		for (int i < mParts.Count)
		{
			GetPartMaterial(mModel.Parts[i].name, path);
			let own = path.IsEmpty ? null : Material.Load(path);
			mParts[i].material = own ?? rendererMaterial ?? mModel.Parts[i].material;
		}
	}

	static bool Listed(StringView list, StringView name)
	{
		for (var entry in list.Split(';'))
		{
			entry.Trim();
			if (entry == name)
				return true;
		}
		return false;
	}

	public static void SetListed(ref SharedString list, StringView name, bool listed)
	{
		if (Listed(list, name) == listed || name.IsEmpty)
			return;
		let rebuilt = scope String();
		for (var entry in list.View.Split(';'))
		{
			entry.Trim();
			if (!entry.IsEmpty && entry != name)
				rebuilt.AppendF("{}{}", rebuilt.IsEmpty ? "" : ";", entry);
		}
		if (listed)
			rebuilt.AppendF("{}{}", rebuilt.IsEmpty ? "" : ";", name);
		list = rebuilt;
	}

	public static void SetEntry(ref SharedString list, StringView name, StringView value)
	{
		let rebuilt = scope String();
		for (var entry in list.View.Split(';'))
		{
			let equals = entry.IndexOf('=');
			if (entry.IsEmpty || (equals > 0 && entry.Substring(0, equals) == name))
				continue;
			rebuilt.AppendF("{}{}", rebuilt.IsEmpty ? "" : ";", entry);
		}
		rebuilt.AppendF("{}{}={}", rebuilt.IsEmpty ? "" : ";", name, value);
		list = rebuilt;
	}

	/// Applies Hidden Parts, Shadow Only Parts and Part Colors to the parts, when one of them has changed.
	void ResolvePartLooks()
	{
		let looks = scope $"{hiddenParts}\n{shadowOnlyParts}\n{partColors}";
		if (mResolvedLooks == looks)
			return;
		mResolvedLooks.Set(looks);
		for (int i < mParts.Count)
		{
			let name = mModel.Parts[i].name;
			mParts[i].hidden = Listed(hiddenParts, name);
			mParts[i].shadowOnly = Listed(shadowOnlyParts, name);
			mParts[i].tint = .White;
		}
		for (var entry in partColors.View.Split(';'))
		{
			let equals = entry.IndexOf('=');
			if (equals <= 0)
				continue;
			let name = entry.Substring(0, equals);
			var numbers = entry.Substring(equals + 1);
			float[3] rgb = .(1, 1, 1);
			int n = 0;
			for (let word in numbers.Split(' ', .RemoveEmptyEntries))
			{
				if (n < 3)
					rgb[n++] = SceneSerializer.ParseFloat(word);
			}
			for (int i < mParts.Count)
			{
				if (mModel.Parts[i].name == name)
					mParts[i].tint = .(rgb[0], rgb[1], rgb[2], 1);
			}
		}
	}

	/// Has every rig of a model load it again (SkinnedModel.Forget).
	public static void ModelChanged(StringView path)
	{
		for (let renderer in sAll)
		{
			if (renderer.model == path)
				renderer.mLoadedPath.Clear();
		}
	}

	void Reload()
	{
		if (model.IsEmpty || model == mLoadedPath)
		{
			if (mModel != null && clipLibrary != mLoadedLibrary)
				ImportLibraries();
			if (mModel != null && !clip.IsEmpty && clip != CurrentClip)
				Play(clip, 0.2f);
			return;
		}
		mLoadedPath.Set(model);
		mModel = SkinnedModel.Load(model);
		mCurrent = null;
		mPrevious = null;
		mLayer = null;
		mLayerPrevious = null;
		mLayerWeight = mLayerTarget = 0;
		DeleteAndNullify!(mLayerMask);
		if (mModel == null)
		{
			Log.Warning(scope $"'{model}' has no skeleton (or could not be read). Use a Mesh Renderer for unrigged models.");
			return;
		}
		delete mWorld;
		delete mSkin;
		delete mDone;
		mWorld = new Matrix4[mModel.Joints.Count];
		mSkin = new Matrix4[mModel.Joints.Count];
		mDone = new bool[mModel.Joints.Count];
		if (mMesh == null)
			mMesh = new Mesh();
		mMesh.Clear();
		for (int i < mModel.Positions.Count)
		{
			let p = mModel.Positions[i];
			let n = mModel.Normals[i];
			mMesh.Vertices.Add(.(.(p.x, p.y, -p.z), .(n.x, n.y, -n.z), mModel.Colors[i], mModel.UVs[i]));
		}
		mMesh.Indices.AddRange(mModel.Indices);
		ReleaseGpuSkinning();
		mMesh.UploadDynamic(GpuSkinning.Available);
		// A model with materials of its own is drawn in parts, sharing the vertices.
		for (let part in mParts)
			delete part.mesh;
		ClearAndDeleteItems!(mParts);
		if (mModel.HasOwnMaterials)
		{
			for (let source in mModel.Parts)
			{
				let part = new MeshRenderer.Part();
				part.mesh = new Mesh();
				part.mesh.VertexSource = mMesh;
				part.mesh.Indices.AddRange(source.indices);
				part.mesh.UploadIndices();
				part.material = source.material;
				mParts.Add(part);
			}
		}
		mResolvedMaterials.Set("\n");
		mResolvedLooks.Set("\n\n\n");
		mAttachPending = true;
		mSkinnedOnce = false;
		SyncBones();
		ImportLibraries();
		if (!clip.IsEmpty)
			Play(clip, 0);
		else if (mModel.Clips.Count > 0)
			Play(mModel.Clips[0].name, 0);
	}

	/// Adds the clips of each file in clipLibrary to the model (once per model and file).
	void ImportLibraries()
	{
		mLoadedLibrary.Set(clipLibrary);
		for (var path in clipLibrary.View.Split(';'))
		{
			path.Trim();
			if (path.IsEmpty)
				continue;
			let library = SkinnedModel.Load(path);
			if (library == null)
				Log.Warning(scope $"Clip library '{path}' has no skeleton (or could not be read).");
			else
				mModel.ImportClips(library, path);
		}
	}

	public bool HasClip(StringView name) => mModel != null && mModel.FindClip(name) != null;

	/// Switches clips with a cross-fade. Does nothing if that clip is already playing.
	public void Play(StringView name, float fadeSeconds = 0.15f)
	{
		if (mModel == null || (mCurrent != null && mCurrent.name == name))
			return;
		let next = mModel.FindClip(name);
		if (next == null)
			return;
		mPrevious = mCurrent;
		mPreviousTime = mTime;
		mCurrent = next;
		mTime = 0;
		mFade = 0;
		mFadeDuration = mPrevious != null ? fadeSeconds : 0;
		// In multiplayer a clip started by the server, or by the player who controls this object, plays everywhere.
		NetworkSync.AnimationPlayed(mGameObject.GetComponent<SkinnedMeshRenderer>(), name, fadeSeconds);
	}

	/// Plays a clip on some bones only, over the main clip: `bones` names them, separated by ';', and each takes
	/// everything below it too ("spine_01" is the whole upper body). The layer fades in over fadeSeconds, and a
	/// different clip on it cross-fades. A character's arms can then keep holding a weapon (its Idle) while its
	/// legs play a jump or a crouching walk made for empty hands. Played on this machine only; it always loops.
	public void PlayLayer(StringView name, StringView bones, float fadeSeconds = 0.15f)
	{
		if (mModel == null)
			return;
		let next = mModel.FindClip(name);
		if (next == null)
			return;
		if (mLayerMask == null || mLayerBones != bones)
		{
			mLayerBones.Set(bones);
			delete mLayerMask;
			mLayerMask = new bool[mModel.Joints.Count];
			for (int i < mModel.Joints.Count)
			{
				for (var at = i; at >= 0 && !mLayerMask[i]; at = mModel.Joints[at].parent)
				{
					for (let bone in bones.Split(';'))
						mLayerMask[i] |= !bone.IsEmpty && mModel.Joints[at].name == bone;
				}
			}
		}
		if (next != mLayer)
		{
			// Fully faded out, the layer starts afresh; still showing, it cross-fades to the new clip.
			mLayerPrevious = mLayerWeight > 0 ? mLayer : null;
			mLayerPreviousTime = mLayerTime;
			mLayer = next;
			mLayerTime = 0;
			mLayerFade = 0;
			mLayerFadeDuration = fadeSeconds;
		}
		mLayerTarget = 1;
		mLayerWeightSpeed = fadeSeconds > 0 ? 1 / fadeSeconds : 1000;
	}

	/// Fades the layer out over some seconds, leaving every bone to the main clip again.
	public void StopLayer(float fadeSeconds = 0.15f)
	{
		mLayerTarget = 0;
		mLayerWeightSpeed = fadeSeconds > 0 ? 1 / fadeSeconds : 1000;
	}

	/// The clip playing on the layer while it shows, or "".
	public StringView CurrentLayerClip => (mLayer != null && mLayerTarget > 0) ? (StringView)mLayer.name : "";

	/// Puts the layer's pose over a joint's pose from the main clip, if the layer moves that joint.
	void LayerPose(int joint, ref Vector3 position, ref Quaternion rotation, ref Vector3 scale)
	{
		if (mLayer == null || mLayerWeight <= 0 || mLayerMask == null || !mLayerMask[joint])
			return;
		Vector3 layerPosition, layerScale;
		Quaternion layerRotation;
		SamplePose(mLayer, mLayerTime, joint, out layerPosition, out layerRotation, out layerScale, true);
		if (mLayerPrevious != null && mLayerFade < mLayerFadeDuration)
		{
			Vector3 fromPosition, fromScale;
			Quaternion fromRotation;
			SamplePose(mLayerPrevious, mLayerPreviousTime, joint, out fromPosition, out fromRotation, out fromScale, true);
			let swap = Mathf.SmoothStep(0, 1, mLayerFade / mLayerFadeDuration);
			layerPosition = Vector3.Lerp(fromPosition, layerPosition, swap);
			layerRotation = Quaternion.Slerp(fromRotation, layerRotation, swap);
			layerScale = Vector3.Lerp(fromScale, layerScale, swap);
		}
		let weight = Mathf.SmoothStep(0, 1, mLayerWeight);
		position = Vector3.Lerp(position, layerPosition, weight);
		rotation = Quaternion.Slerp(rotation, layerRotation, weight);
		scale = Vector3.Lerp(scale, layerScale, weight);
	}

	void SamplePose(SkinnedModel.Clip source, float time, int joint, out Vector3 position, out Quaternion rotation, out Vector3 scale) =>
		SamplePose(source, time, joint, out position, out rotation, out scale, loop);

	void SamplePose(SkinnedModel.Clip source, float time, int joint, out Vector3 position, out Quaternion rotation, out Vector3 scale, bool looping)
	{
		let jointCount = mModel.Joints.Count;
		var t = looping ? time % source.duration : Math.Min(time, source.duration);
		let exact = t * 30.0f;
		let f0 = Math.Min((int)exact, source.frames - 1);
		let f1 = Math.Min(f0 + 1, source.frames - 1);
		let blend = exact - f0;
		let a = source.data.Ptr + (f0 * jointCount + joint) * 10;
		let b = source.data.Ptr + (f1 * jointCount + joint) * 10;
		position = Vector3.Lerp(.(a[0], a[1], a[2]), .(b[0], b[1], b[2]), blend);
		rotation = Quaternion.Slerp(.(a[3], a[4], a[5], a[6]), .(b[3], b[4], b[5], b[6]), blend);
		scale = Vector3.Lerp(.(a[7], a[8], a[9]), .(b[7], b[8], b[9]), blend);
	}

	void ComputeJoint(int index, float weight)
	{
		if (mDone[index])
			return;
		let joint = mModel.Joints[index];
		var position = joint.restPosition;
		var rotation = joint.restRotation;
		var scale = joint.restScale;
		if (mCurrent != null)
		{
			SamplePose(mCurrent, mTime, index, out position, out rotation, out scale);
			if (weight < 1.0f && mPrevious != null)
			{
				Vector3 fromPosition, fromScale;
				Quaternion fromRotation;
				SamplePose(mPrevious, mPreviousTime, index, out fromPosition, out fromRotation, out fromScale);
				position = Vector3.Lerp(fromPosition, position, weight);
				rotation = Quaternion.Slerp(fromRotation, rotation, weight);
				scale = Vector3.Lerp(fromScale, scale, weight);
			}
			LayerPose(index, ref position, ref rotation, ref scale);
		}
		let local = Matrix4.TRS(position, rotation, scale);
		if (joint.parent >= 0)
		{
			ComputeJoint(joint.parent, weight);
			mWorld[index] = mWorld[joint.parent] * local;
		}
		else
			mWorld[index] = joint.parentWorld * local;
		mSkin[index] = mWorld[index] * joint.inverseBind;
		mDone[index] = true;
	}

	/// Animates and re-skins (SkinnedMeshRenderer.FrameAll, every frame, in the editor as well as in play mode).
	void Frame()
	{
		if (mModel == null || mMesh == null)
			return;
		if (mAttachPending)
		{
			mAttachPending = false;
			var renderer = Renderer;
			if (!renderer)
				renderer = GameObject.AddComponent<MeshRenderer>();
			renderer.RuntimeMesh = mMesh;
			renderer.RuntimeParts = mParts.Count > 0 ? mParts : null;
		}
		if (mParts.Count > 0)
		{
			let renderer = Renderer;
			if (renderer)
				ResolvePartMaterials(renderer);
			ResolvePartLooks();
		}
		let step = Time.DeltaTime * speed;
		mTime += step;
		mPreviousTime += step;
		mFade += Time.DeltaTime;
		let weight = (mPrevious != null && mFade < mFadeDuration) ? Mathf.SmoothStep(0, 1, mFade / mFadeDuration) : 1.0f;
		mLayerTime += Time.DeltaTime;
		mLayerPreviousTime += Time.DeltaTime;
		mLayerFade += Time.DeltaTime;
		mLayerWeight = Mathf.MoveTowards(mLayerWeight, mLayerTarget, Time.DeltaTime * mLayerWeightSpeed);

		if (exposeBones && mBones != null)
		{
			// The clip poses the bone objects; the mesh is bent from them at the end of the frame (SkinFromBones),
			// once IK and scripts have moved them too. With no clip playing they are left as they are.
			if (mCurrent != null && !posedByAnimator)
			{
				for (int i < mModel.Joints.Count)
				{
					let bone = mBones[i];
					if (bone == null || bone.GameObject.IsDestroyed)
						continue;
					Vector3 position, scale;
					Quaternion rotation;
					SamplePose(mCurrent, mTime, i, out position, out rotation, out scale);
					if (weight < 1.0f && mPrevious != null)
					{
						Vector3 fromPosition, fromScale;
						Quaternion fromRotation;
						SamplePose(mPrevious, mPreviousTime, i, out fromPosition, out fromRotation, out fromScale);
						position = Vector3.Lerp(fromPosition, position, weight);
						rotation = Quaternion.Slerp(fromRotation, rotation, weight);
						scale = Vector3.Lerp(fromScale, scale, weight);
					}
					LayerPose(i, ref position, ref rotation, ref scale);
					bone.SetLocalPoseDeferred(Mirror(position), Mirror(rotation), scale);
				}
				// Each branch is told once, from its top, rather than once for each bone above every bone.
				for (int i < mModel.Joints.Count)
				{
					let parent = mModel.Joints[i].parent;
					if (parent < 0 || mBones[parent] == null || mBones[parent].GameObject.IsDestroyed)
						mBones[i]?.PoseChanged();
				}
			}
			return;
		}
		if (!ShouldSkin())
			return;
		for (int i < mDone.Count)
			mDone[i] = false;
		for (int i < mModel.Joints.Count)
			ComputeJoint(i, weight);
		SkinVertices();
	}

	/// Models waiting to be bent on the CPU this frame: Scene.Update bends them together, spread over the job threads
	/// (FinishCpuSkinning).
	static List<SkinnedRig> sCpuQueue = new .() ~ delete _;
	bool mCpuQueued;
	Bounds mCpuBounds;

	void SkinVertices()
	{
		// On the graphics card when it can (docs/gpu-skinning.md); on the CPU, with the other models, at the end of the
		// frame otherwise.
		if (SkinOnGpu())
			return;
		if (Scene == null || !Scene.Updating)
		{
			SkinOnCpu();
			UseCpuSkin();
			return;
		}
		if (!mCpuQueued)
		{
			mCpuQueued = true;
			sCpuQueue.Add(this);
		}
	}

	/// Bends every model queued this frame (SkinVertices) on the CPU, several at once on the job threads, then hands
	/// the vertices to the graphics card. Scene.Update calls it once animation, scripts and IK are done.
	public static void FinishCpuSkinning()
	{
		if (sCpuQueue.IsEmpty)
			return;
		Jobs.For(sCpuQueue.Count, scope (index) => sCpuQueue[index].SkinOnCpu());
		for (let renderer in sCpuQueue)
		{
			renderer.mCpuQueued = false;
			renderer.UseCpuSkin();
		}
		sCpuQueue.Clear();
	}

	/// Hands the vertices SkinOnCpu made to the graphics card, with their bounds.
	void UseCpuSkin()
	{
		mMesh.Bounds = mCpuBounds;
		mMesh.UpdateDynamic();
		mSkinnedOnce = true;
		for (let part in mParts)
			part.mesh.Bounds = mCpuBounds;
	}

	// This vertex loop also needs optimization in editor Debug builds. It runs on a job thread: it only reads the model
	// and the pose, and writes this renderer's own vertices and bounds.
	[Optimize]
	void SkinOnCpu()
	{
		let positions = mModel.Positions.Ptr;
		let normals = mModel.Normals.Ptr;
		let joints = mModel.JointIndices.Ptr;
		let weights = mModel.Weights.Ptr;
		let matrices = mSkin.Ptr;
		let vertices = mMesh.Vertices.Ptr;
		var bounds = Bounds.Empty;
		for (int v < mModel.Positions.Count)
		{
			let p = positions[v];
			let n = normals[v];
			float px = 0, py = 0, pz = 0, nx = 0, ny = 0, nz = 0;
			for (int k < 4)
			{
				let w = weights[v * 4 + k];
				if (w <= 0) continue;
				let matrix = &matrices[joints[v * 4 + k]].m;
				px += ((*matrix)[0] * p.x + (*matrix)[4] * p.y + (*matrix)[8] * p.z + (*matrix)[12]) * w;
				py += ((*matrix)[1] * p.x + (*matrix)[5] * p.y + (*matrix)[9] * p.z + (*matrix)[13]) * w;
				pz += ((*matrix)[2] * p.x + (*matrix)[6] * p.y + (*matrix)[10] * p.z + (*matrix)[14]) * w;
				nx += ((*matrix)[0] * n.x + (*matrix)[4] * n.y + (*matrix)[8] * n.z) * w;
				ny += ((*matrix)[1] * n.x + (*matrix)[5] * n.y + (*matrix)[9] * n.z) * w;
				nz += ((*matrix)[2] * n.x + (*matrix)[6] * n.y + (*matrix)[10] * n.z) * w;
			}
			let length = Math.Sqrt(nx * nx + ny * ny + nz * nz);
			let inverse = length < 1.0e-12f ? 0.0f : 1.0f / length;
			// Into Tallow's left-handed space.
			vertices[v].position = .(px, py, -pz);
			vertices[v].normal = .(nx * inverse, ny * inverse, -nz * inverse);
			if (px < bounds.min.x)
				bounds.min.x = px;
			if (py < bounds.min.y)
				bounds.min.y = py;
			if (-pz < bounds.min.z)
				bounds.min.z = -pz;
			if (px > bounds.max.x)
				bounds.max.x = px;
			if (py > bounds.max.y)
				bounds.max.y = py;
			if (-pz > bounds.max.z)
				bounds.max.z = -pz;
		}
		mCpuBounds = bounds;
	}
}
