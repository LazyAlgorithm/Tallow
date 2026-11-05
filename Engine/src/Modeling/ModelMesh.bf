using System;
using System.Collections;

namespace Tallow;

/// A model built in the editor (docs/modeling.md): its faces are kept in the scene, inline, and drawn through the
/// object's Mesh Renderer. Objects with the same model share one mesh, so copies of a whitebox piece are drawn
/// together. Faces in material slot 0 use the Mesh Renderer's material; slots 1 and up use Materials.
[Component]
class ModelMesh : Component
{
	/// The model as text (the .tmesh format). Edited with the Scene view's model tools, not by hand.
	[HideInInspector]
	public String data = new .() ~ delete _;
	/// Materials (.tmat) for slots 1, 2, ... separated by ';'. Slot 0 is the Mesh Renderer's material.
	public String materials = new .() ~ delete _;
	/// Auto texture coordinates repeat once a metre in the world, so a stretched object keeps the same texture size.
	/// Off: once a metre of the model's own space, stretching with the object.
	public bool worldScaleUVs = true;

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

	public override void OnRegister() => Rebuild();

	public override void OnUnregister()
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

	public override void OnValidate()
	{
		if (mParsed != data || mBuiltMaterials != materials || mBuiltWorldScale != worldScaleUVs)
			Rebuild();
	}

	public override void OnFrame()
	{
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
