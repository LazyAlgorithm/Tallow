using System;
using System.Collections;

namespace Tallow;

/// A ModelMesh's settings, in its entity (ModelMesh is the handle).
[Component, HandleData]
struct ModelMeshData
{
	/// The model as text (the .tmesh format). Edited with the Scene view's model tools, not by hand.
	[HideInInspector]
	public String data = new .();
	/// Materials (.tmat) for slots 1, 2, ... separated by ';'. Slot 0 is the Mesh Renderer's material.
	public String materials = new .();
	/// Auto texture coordinates repeat once a metre in the world, so a stretched object keeps the same texture size.
	/// Off: once a metre of the model's own space, stretching with the object.
	public bool worldScaleUVs = true;

	public this() { }
}

/// A model built in the editor (docs/modeling.md): its faces are kept in the scene, inline, and drawn through the
/// object's Mesh Renderer. Objects with the same model share one mesh, so copies of a whitebox piece are drawn
/// together. Faces in material slot 0 use the Mesh Renderer's material; slots 1 and up use Materials.
///
/// A handle (ComponentHandle): its settings are ModelMeshData's fields, what it keeps between frames its ModelMeshState.
/// ModelMesh.FrameAll (from Scene.RunOnFrames) does what OnRegister and OnFrame did; OnRemove what OnUnregister did.
[Component, HandleFields]
struct ModelMesh : ComponentHandle<ModelMeshData>
{
	/// What it keeps between frames, made the first time it is asked for.
	public ModelMeshState Runtime
	{
		get
		{
			CheckValid();
			let state = ComponentState<ModelMeshState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			if (state.[Friend]mGameObject == null)
			{
				state.[Friend]mGameObject = mGameObject;
			}
			return state;
		}
	}

	// The API, unchanged: each member is documented on ModelMeshState.
	public EditMesh Edit => Runtime.Edit;
	public Vector3 UVScale => Runtime.UVScale;
	public Mesh DrawnMesh => Runtime.DrawnMesh;
	public void Save() => Runtime.Save();
	public void Set(EditMesh mesh) => Runtime.Set(mesh);
	public void Preview() => Runtime.Preview();
	public void Rebuild() => Runtime.Rebuild();
	public bool Export(StringView path) => Runtime.Export(path);

	/// What OnFrame did, in edit mode as well as play (from Scene.RunOnFrames). One not built yet (just added, copied
	/// or made from a prefab) is built whether or not it is switched on, as OnRegister built it.
	public static void FrameAll(Scene scene)
	{
		for (let component in scene.FindComponents<ModelMesh>(.. scope .()))
		{
			let state = component.Runtime;
			if (component.IsActiveAndEnabled || state.NeedsBuild)
				state.Frame();
		}
	}

	/// After the Inspector changes a field or a scene is read: built again if its text or materials changed.
	static void OnValidate(GameObject gameObject) => gameObject.GetComponent<ModelMesh>().Runtime.OnValidate();

	static void OnRemove(void* world, uint64 entity)
	{
		// As OnUnregister did: the renderer lets go of the mesh, and the shared mesh loses a user. While the whole
		// object goes (IsGoing), only the latter: its renderer is going too, and may be gone.
		if (let state = ComponentState<ModelMeshState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
		{
			let owner = state.[Friend]mGameObject;
			if (owner != null && !owner.IsGoing)
				state.Unregister();
			else
				state.[Friend]Release();
		}
		ComponentState<ModelMeshState>.Release(world, entity);
		HandleComponents.FreeLists(world, entity, typeof(ModelMesh));
	}
}

/// What a ModelMesh keeps between frames. Its settings are read from the entity each time.
[DataFields(typeof(ModelMeshData), "Settings")]
class ModelMeshState
{
	GameObject mGameObject;

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject.Scene;
	public ModelMesh Handle => mGameObject.GetComponent<ModelMesh>();
	T GetComponent<T>() where T : Component => mGameObject.GetComponent<T>();
	T GetComponent<T>() where T : struct, IComponentHandle => mGameObject.GetComponent<T>();
	bool HasComponent<T>() where T : struct, IComponentHandle => mGameObject.HasComponent<T>();
	ref ModelMeshData Settings
	{
		[Inline]
		get => ref *mGameObject.GetComponent<ModelMeshData>();
	}

	/// A built model shared by every object with the same text (and scale, with World Scale UVs).
	class Shared
	{
		public String key ~ delete _;
		public Mesh mesh ~ delete _;
		/// One mesh per material slot, when there is more than one slot.
		public List<Mesh> slots = new .() ~ DeleteContainerAndItems!(_);
		public int32 users;
	}

	static Dictionary<String, Shared> sShared = new .() ~ { for (let shared in _.Values) delete shared; delete _; };

	EditMesh mEdit ~ delete _;
	/// What the model was built from, to tell when it must be built again.
	String mParsed = new .() ~ delete _;
	Shared mShared;
	/// Built while the model is being edited (not shared, not in the text yet).
	Mesh mPreview ~ delete _;
	List<Mesh> mPreviewSlots = new .() ~ DeleteContainerAndItems!(_);
	List<MeshRenderer.Part> mParts = new .() ~ DeleteContainerAndItems!(_);
	String mBuiltMaterials = new .() ~ delete _;
	Vector3 mBuiltScale;
	bool mBuiltWorldScale;
	bool mAttachPending;

	/// The model's faces, read from the text the first time. Change it, then call Preview (while dragging) or Save.
	public EditMesh Edit
	{
		get
		{
			if (mEdit == null || mParsed != data)
			{
				if (mEdit == null)
					mEdit = new EditMesh();
				if (!mEdit.Read(data))
					mEdit.Clear();
				mParsed.Set(data);
			}
			return mEdit;
		}
	}

	/// The object's scale in the world, which Auto texture coordinates follow with World Scale UVs.
	public Vector3 UVScale
	{
		get
		{
			if (!worldScaleUVs)
				return .One;
			let m = Transform.LocalToWorld;
			return .(Vector3(m.m[0], m.m[1], m.m[2]).Length, Vector3(m.m[4], m.m[5], m.m[6]).Length, Vector3(m.m[8], m.m[9], m.m[10]).Length);
		}
	}

	/// The mesh drawn now.
	public Mesh DrawnMesh => mPreview ?? mShared?.mesh;

	/// Not built from its text yet, or built from other text or materials.
	public bool NeedsBuild => mParsed != Settings.data || mBuiltMaterials != Settings.materials || mBuiltWorldScale != Settings.worldScaleUVs || (mShared == null && mPreview == null);

	/// What OnUnregister did (the handle's OnRemove).
	public void Unregister()
	{
		let renderer = GetComponent<MeshRenderer>();
		if (renderer)
		{
			if (renderer.RuntimeMesh == DrawnMesh)
				renderer.RuntimeMesh = null;
			if (renderer.RuntimeParts == mParts)
				renderer.RuntimeParts = null;
		}
		Release();
		DeleteAndNullify!(mPreview);
		ClearAndDeleteItems(mPreviewSlots);
	}

	public void OnValidate()
	{
		if (mParsed != data || mBuiltMaterials != materials || mBuiltWorldScale != worldScaleUVs)
			Rebuild();
	}

	public void Frame()
	{
		// Built the first frame after it is added or copied (OnRegister did it at once; a handle has no such hook).
		if (NeedsBuild)
		{
			Rebuild();
			return;
		}
		if (mAttachPending)
		{
			mAttachPending = false;
			Attach();
		}
		// Scaling a model with World Scale UVs changes its Auto coordinates.
		if (worldScaleUVs && mPreview == null && (UVScale - mBuiltScale).LengthSquared > 1.0e-8f)
			Rebuild();
	}

	/// Writes the edited faces into the text and draws them (shared with other objects of the same model).
	public void Save()
	{
		let edit = Edit;
		let text = scope String();
		edit.Write(text);
		data.Set(text);
		mParsed.Set(data);
		DeleteAndNullify!(mPreview);
		ClearAndDeleteItems(mPreviewSlots);
		Rebuild();
	}

	/// Replaces the model with another (copied) and saves it.
	public void Set(EditMesh mesh)
	{
		Edit.CopyFrom(mesh);
		Save();
	}

	/// Draws the edited faces as they are now without saving them: for while a handle is being dragged. Save at
	/// the end. Faces hidden in the editor are left out.
	public void Preview()
	{
		let edit = Edit;
		if (mPreview == null)
			mPreview = new Mesh();
		let slots = edit.MaterialCount;
		edit.Build(mPreview, UVScale, -1, true);
		mPreview.Upload();
		while (mPreviewSlots.Count > (slots > 1 ? slots : 0))
			delete mPreviewSlots.PopBack();
		if (slots > 1)
		{
			while (mPreviewSlots.Count < slots)
				mPreviewSlots.Add(new Mesh());
			for (int32 s < (int32)slots)
			{
				edit.Build(mPreviewSlots[s], UVScale, s, true);
				mPreviewSlots[s].Upload();
			}
		}
		Release();
		MakeParts(slots > 1 ? mPreviewSlots : null);
		Attach();
	}

	/// Builds (or finds) the shared mesh for the text and hands it to the renderer.
	public void Rebuild()
	{
		let edit = Edit;
		mBuiltScale = UVScale;
		mBuiltWorldScale = worldScaleUVs;
		mBuiltMaterials.Set(materials);
		let key = scope String();
		key.Append(data);
		if (worldScaleUVs)
			key.AppendF("|{:0.0000} {:0.0000} {:0.0000}", mBuiltScale.x, mBuiltScale.y, mBuiltScale.z);
		if (mShared == null || mShared.key != key)
		{
			Release();
			if (!sShared.TryGetValue(key, out mShared))
			{
				mShared = new Shared();
				mShared.key = new String(key);
				mShared.mesh = new Mesh();
				edit.Build(mShared.mesh, mBuiltScale);
				mShared.mesh.Upload();
				let slots = edit.MaterialCount;
				if (slots > 1)
				{
					for (int32 s < (int32)slots)
					{
						let part = new Mesh();
						edit.Build(part, mBuiltScale, s);
						part.Upload();
						mShared.slots.Add(part);
					}
				}
				sShared[mShared.key] = mShared;
			}
			mShared.users++;
		}
		MakeParts(mShared.slots.Count > 1 ? mShared.slots : null);
		Attach();
	}

	void Release()
	{
		if (mShared == null)
			return;
		if (--mShared.users <= 0)
		{
			sShared.Remove(mShared.key);
			delete mShared;
		}
		mShared = null;
	}

	void MakeParts(List<Mesh> slots)
	{
		ClearAndDeleteItems(mParts);
		if (slots == null)
			return;
		let names = scope List<StringView>();
		for (let name in materials.Split(';'))
		{
			var trimmed = name;
			names.Add(trimmed..Trim());
		}
		for (int s < slots.Count)
		{
			let part = new MeshRenderer.Part();
			part.mesh = slots[s];
			if (s > 0 && s - 1 < names.Count && !names[s - 1].IsEmpty)
				part.material = Material.Load(names[s - 1]);
			mParts.Add(part);
		}
	}

	void Attach()
	{
		// The renderer may not exist yet while a scene is still loading this object's components.
		let renderer = GetComponent<MeshRenderer>();
		if (!renderer)
		{
			mAttachPending = true;
			return;
		}
		renderer.RuntimeMesh = DrawnMesh;
		renderer.RuntimeParts = mParts.Count > 0 ? mParts : null;
		GetComponent<Collider>()?.Refresh();
	}

	static void ClearAndDeleteItems(List<MeshRenderer.Part> list)
	{
		for (let item in list)
			delete item;
		list.Clear();
	}

	static void ClearAndDeleteItems(List<Mesh> list)
	{
		for (let item in list)
			delete item;
		list.Clear();
	}

	/// Saves the model as a .tmesh file (path relative to the project), which a Mesh Renderer can name as its mesh.
	public bool Export(StringView path)
	{
		let text = scope String();
		Edit.Write(text);
		let full = Assets.ResolvePath(path, .. scope .());
		return System.IO.File.WriteAllText(full, text) case .Ok;
	}
}
