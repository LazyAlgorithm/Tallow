using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// What the renderer draws a Mesh Renderer from: a copy of its settings (MeshRendererData, refreshed from the
/// object's entity each time Scene.Renderers is read), and what it works out from them and keeps between frames:
/// the mesh, texture and material it resolved, this object's own material copy, meshes and parts set from code.
/// Each Mesh Renderer has one (kept in ComponentState, freed with the component). Foliage, particles and the ECS
/// render extract make their own, with no object, for settings shared by many instances.
[DataFields(typeof(MeshRendererData), "data")]
class RenderProxy
{
	/// The settings drawn with. For a Mesh Renderer, a copy: change the renderer, not this.
	public MeshRendererData data = .();
	GameObject mGameObject;

	/// The object drawn, or null for a proxy of its own (Foliage, particles, the ECS render extract).
	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject?.Transform;
	public Scene Scene => mGameObject?.Scene;
	/// The Mesh Renderer it draws for (not valid for a proxy of its own).
	public MeshRenderer Renderer => mGameObject != null ? mGameObject.GetComponent<MeshRenderer>() : default;
	/// Its object is active (a proxy without one always is). Scene.Renderers holds switched-on renderers only.
	public bool IsActiveAndEnabled => mGameObject == null || mGameObject.ActiveInHierarchy;

	// These run for every renderer in every view; a SharedString compares by pointer.
	[Inline]
	static bool HasText(SharedString text) => !text.IsEmpty;
	[Inline]
	static bool Differs(SharedString a, SharedString b) => a != b;

	/// Whether it has a baked lightmap.
	public bool HasLightmap { [Inline] get => HasText(lightmap); }

	Tallow.Material mSharedMaterial;
	Tallow.Material mMaterialInstance ~ delete _;
	SharedString mResolvedMaterial;

	/// The material from the Material field, shared with every other renderer that names it. Null with none set.
	public Tallow.Material SharedMaterial
	{
		get
		{
			if (Differs(mResolvedMaterial, material))
			{
				mResolvedMaterial = material;
				mSharedMaterial = Tallow.Material.Load(material);
				// A copy made for this object was a copy of the old material.
				DeleteAndNullify!(mMaterialInstance);
			}
			return mSharedMaterial;
		}
	}

	/// This object's own copy of its material, made the first time it is asked for. Change it to change this
	/// object without changing the others that share the material. Null with no material set.
	public Tallow.Material Material
	{
		get
		{
			let shared = SharedMaterial;
			if (shared == null)
				return null;
			if (mMaterialInstance == null)
				mMaterialInstance = shared.Clone();
			return mMaterialInstance;
		}
	}

	/// What the renderer draws with: this object's own copy if it has one, otherwise the shared material.
	public Tallow.Material ActiveMaterial
	{
		get
		{
			let shared = SharedMaterial;
			return mMaterialInstance != null ? mMaterialInstance : shared;
		}
	}

	/// Sets a property of this renderer's own copy of its material (MeshRenderer.SetMaterialValue, without the
	/// network). False when it has no material.
	public bool ApplyMaterialValue(StringView name, Vector4 value)
	{
		let own = Material;
		if (own == null)
			return false;
		switch (name)
		{
		case "color": own.color = .(value.x, value.y, value.z, value.w);
		case "emissive": own.emissive = .(value.x, value.y, value.z, value.w);
		case "metallic": own.metallic = Mathf.Clamp01(value.x);
		case "roughness": own.roughness = Mathf.Clamp01(value.x);
		case "emissiveIntensity": own.emissiveIntensity = Math.Max(value.x, 0);
		case "cutoff": own.cutoff = Mathf.Clamp01(value.x);
		case "tiling": own.tiling = .(value.x, value.y);
		case "offset": own.offset = .(value.x, value.y);
		default:
			own.SetVector(name, value);
		}
		own.Changed();
		return true;
	}

	/// Set by lines and trails whose colours fade: drawn see-through, as an alpha below 1 in Color is.
	[NonSerialized]
	public bool vertexAlpha;
	/// World-space offset applied only when drawing. The network layer uses it to blend out corrections.
	[NonSerialized]
	public Vector3 VisualOffset;
	/// Optional world-space presentation correction; never changes transforms or colliders.
	[NonSerialized]
	public bool UseVisualCorrection;
	/// The correction applied when drawing while UseVisualCorrection is on.
	[NonSerialized]
	public Matrix4 VisualCorrection = .Identity;
	/// The world matrix the mesh is drawn with: its transform's, with VisualOffset and VisualCorrection applied.
	public Matrix4 RenderMatrix
	{
		get
		{
			var world = mGameObject != null ? Transform.LocalToWorld : Matrix4.Identity;
			if (UseVisualCorrection)
				world = VisualCorrection * world;
			world.m[12] += VisualOffset.x;
			world.m[13] += VisualOffset.y;
			world.m[14] += VisualOffset.z;
			return world;
		}
	}

	/// A texture made at run time (a Compute Texture, say) to draw with instead of the one named by the
	/// material or the Texture field. Set it invalid again to go back.
	[NonSerialized]
	public bgfx.TextureHandle TextureOverride = .() { idx = uint16.MaxValue };

	Mesh mResolvedMesh;
	Mesh mRuntimeMesh;
	SharedString mResolvedPath;
	bool mResolved;
	int32 mMeshVersion;
	bgfx.TextureHandle mTexture = .() { idx = uint16.MaxValue };
	SharedString mResolvedTexture;
	int32 mTextureVersion = -1;
	int64 mLastDrawnFrame = -1;

	/// The frame (Time.FrameCount) this renderer was last drawn on, in any view or shadow map; -1 if never.
	/// A Skinned Mesh Renderer uses it to stop bending a mesh nobody can see.
	public int64 LastDrawnFrame
	{
		get => mLastDrawnFrame;
		set
		{
			mLastDrawnFrame = value;
		}
	}

	/// Whether it can move by itself (a Rigidbody, or a skinned model), and so is no Auto occluder.
	public bool IsMoving => mGameObject != null && (mGameObject.HasComponent<Rigidbody>() || mGameObject.HasComponent<SkinnedMeshRenderer>());

	/// The LOD Group above it that picks when it is drawn, if any (set by the group).
	[NonSerialized]
	public LODGroup LodGroup;
	/// Its level in that group (from an `_LOD<n>` name), or -1 for every level.
	[NonSerialized]
	public int8 LodLevel = -1;

	/// Assign a procedurally built mesh. The renderer does not take ownership.
	public Mesh RuntimeMesh
	{
		get => mRuntimeMesh;
		set
		{
			mRuntimeMesh = value;
		}
	}

	/// Set from code (a Skinned Mesh Renderer whose model has several materials): drawn in place of the renderer's
	/// mesh, each part with its own material. The renderer's color still tints all of them. Null or empty: the
	/// renderer draws its one mesh as usual.
	public List<MeshRenderer.Part> RuntimeParts;

	List<MeshRenderer.Part> mModelParts;
	SharedString mModelPartsPath;
	int32 mModelPartsVersion = -1;

	/// The parts drawn: RuntimeParts when set, else the model's own materials (useModelMaterials), else null (the
	/// renderer draws ActiveMesh with its own material).
	public List<MeshRenderer.Part> DrawnParts
	{
		get
		{
			if (RuntimeParts != null && RuntimeParts.Count > 0)
				return RuntimeParts;
			if (!useModelMaterials || mRuntimeMesh != null || HasText(material) || HasText(texture))
				return null;
			if (mModelPartsVersion != Assets.MeshVersion || Differs(mModelPartsPath, mesh))
			{
				mModelPartsPath = mesh;
				mModelParts = mesh.View.StartsWith("builtin:") ? null : Assets.GetModelParts(mesh);
				mModelPartsVersion = Assets.MeshVersion;
			}
			return mModelParts;
		}
	}

	/// The mesh drawn: RuntimeMesh if one is set, else the one named by the mesh field.
	public Mesh ActiveMesh
	{
		get
		{
			if (mRuntimeMesh != null)
				return mRuntimeMesh;
			if (!mResolved || mMeshVersion != Assets.MeshVersion || Differs(mResolvedPath, mesh))
			{
				mResolvedPath = mesh;
				mResolvedMesh = Assets.GetMesh(mesh);
				mResolved = true;
				mMeshVersion = Assets.MeshVersion;
			}
			return mResolvedMesh;
		}
	}

	/// The texture drawn with when the renderer has no material.
	public bgfx.TextureHandle ActiveTexture
	{
		get
		{
			if (!mTexture.Valid || mTextureVersion != Assets.TextureVersion || Differs(mResolvedTexture, texture))
			{
				mResolvedTexture = texture;
				mTextureVersion = Assets.TextureVersion;
				mTexture = Assets.GetTexture(texture);
			}
			return mTexture;
		}
	}

	/// The box round the drawn mesh, in the world.
	public Bounds WorldBounds
	{
		get
		{
			let m = ActiveMesh;
			let world = mGameObject != null ? Transform.LocalToWorld : Matrix4.Identity;
			if (m == null)
				return .(world.Translation, world.Translation);
			return m.Bounds.Transformed(world);
		}
	}
}
