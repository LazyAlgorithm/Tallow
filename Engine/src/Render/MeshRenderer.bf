using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Draws a mesh with an inline material. Identical mesh/material pairs are batched into instanced draws.
[Component]
class MeshRenderer : Component
{
	/// "builtin:cube", "builtin:sphere", ... or a model path relative to the project.
	public String mesh = new .("builtin:cube") ~ delete _;
	/// Tints the mesh (alpha below 1 makes it see-through).
	public Color color = .White;
	/// How metal-like the surface is, 0 to 1.
	[Range(0, 1)]
	public float metallic = 0.0f;
	/// How rough the surface is: 0 is a mirror, 1 fully matt.
	[Range(0, 1)]
	public float roughness = 0.85f;
	/// Light the surface gives off itself, whatever lights the scene.
	public Color emissive = .Black;
	/// How strong the emissive light is.
	public float emissiveIntensity = 0.0f;
	/// The glow is multiplied by the surface's own colour (vertex colours and texture): the bright parts of a model
	/// glow in their own colour and the dark parts stay dark. Set Emissive to white to keep the colours as they are.
	public bool emissiveFromColor = false;
	/// Faceted shading computed per triangle: the low-poly look without duplicated vertices.
	public bool flatShading = true;
	/// Draws the colour and texture as they are, with no lighting.
	public bool unlit = false;
	/// Whether the mesh casts shadows.
	public bool castShadows = true;
	/// Whether the backs of faces are left out (on: the usual, and cheaper). Off: both sides are drawn, for a single
	/// plane seen from either side (a curtain, a flag, a leaf).
	public bool backFaceCulling = true;
	/// Baked diffuse irradiance, sampled using the mesh's second UV set.
	public String lightmap = new .() ~ delete _;
	/// The baked lightmap's direction map, if any (set when lighting is baked).
	public String lightmapDirection = new .() ~ delete _;
	/// The baked shadowmask, if any (set when lighting is baked).
	public String lightmapShadowmask = new .() ~ delete _;
	/// Where this mesh's part of the lightmap is: x and y scale its lightmap coordinates, z and w offset them.
	public Vector4 lightmapScaleOffset = .(1, 1, 0, 0);
	/// RGBM multiplier/exponent and whether RGB needs sRGB decoding. Linear maps use (1,0,0,0).
	public Vector4 lightmapDecode = .(1, 0, 0, 0);
	/// How far the object bends in the wind (Wind Zone components): 0 not at all, 1 like grass. It bends about its own
	/// origin, more the higher up, so put the origin at the foot of a tree, a flag pole or a reed.
	[Range(0, 2)]
	public float windSway = 0;
	/// Casts its shadow without being drawn itself. For what the camera must not see but the sun still should:
	/// the head and arms of a first-person player's own body, say.
	public bool shadowOnly = false;
	/// Takes part in baked lighting (docs/baked-lighting.md): the Lighting window gives it a lightmap, and it blocks and
	/// bounces light for the others. For things that never move: walls, floors, rocks, buildings.
	public bool bakedLighting = false;
	/// Optional albedo texture path relative to the project.
	public String texture = new .() ~ delete _;
	/// A material (.tmat) made in the editor. With one set, it decides how the surface looks and the fields above
	/// are ignored, except Color, which tints this object on top of the material, and Cast Shadows.
	public String material = new .() ~ delete _;
	/// A model with materials of its own (a glTF, or an FBX, OBJ, ... converted to one) is drawn with them, its
	/// textures included, when no Material or Texture is set here. Off: the whole model takes the fields above.
	public bool useModelMaterials = true;

	// These run for every renderer in every view, and those fields are mostly empty or the same as last time.
	[Inline]
	static bool HasText(String text) => text.[Friend]mLength != 0;
	[Inline]
	static bool Differs(String a, String b) => a.[Friend]mLength != b.[Friend]mLength || (a.[Friend]mLength != 0 && a != b);

	/// Whether it has a baked lightmap.
	public bool HasLightmap { [Inline] get => HasText(lightmap); }

	Tallow.Material mSharedMaterial;
	Tallow.Material mMaterialInstance ~ delete _;
	String mResolvedMaterial = new .() ~ delete _;

	/// The material from the Material field, shared with every other renderer that names it. Null with none set.
	public Tallow.Material SharedMaterial
	{
		get
		{
			if (Differs(mResolvedMaterial, material))
			{
				mResolvedMaterial.Set(material);
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

	/// Changes which material this object uses. In a network session, on the server or on the owner's machine,
	/// every machine follows.
	public void SetMaterial(StringView materialPath)
	{
		if (material == materialPath)
			return;
		material.Set(materialPath);
		NetworkSync.MaterialChanged(this, 0, materialPath, default);
	}

	/// Sets a property of this object's own copy of its material: one of the custom shader's properties by name,
	/// or "color", "emissive", "metallic", "roughness", "emissiveIntensity", "cutoff", "tiling" and "offset".
	/// In a network session, on the server or the owner's machine, every machine follows.
	public void SetMaterialValue(StringView name, Vector4 value)
	{
		let own = Material;
		if (own == null)
			return;
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
		NetworkSync.MaterialChanged(this, 1, name, value);
	}

	/// Sets a number of the renderer's material (a copy of its own is made the first time).
	public void SetMaterialFloat(StringView name, float value) => SetMaterialValue(name, .(value, 0, 0, 0));
	/// Sets a colour of the renderer's material (a copy of its own is made the first time).
	public void SetMaterialColor(StringView name, Color value) => SetMaterialValue(name, .(value.r, value.g, value.b, value.a));

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
			var world = Transform.LocalToWorld;
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
	String mResolvedPath = new .() ~ delete _;
	bool mResolved;
	int32 mMeshVersion;
	bgfx.TextureHandle mTexture = .() { idx = uint16.MaxValue };
	String mResolvedTexture = new .() ~ delete _;
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

	/// Whether it hides what is behind it from cameras with Occlusion Culling (docs/occlusion-culling.md).
	public OccluderMode occluder = .Auto;

	/// Whether it can move by itself (a Rigidbody, or a skinned model), and so is no Auto occluder.
	public bool IsMoving => GameObject.GetComponent<Rigidbody>() != null || GameObject.GetComponent<SkinnedMeshRenderer>() != null;

	/// The LOD Group above it that picks when it is drawn, if any (set by the group).
	[NonSerialized]
	public LODGroup LodGroup;
	/// Its level in that group (from an `_LOD<n>` name), or -1 for every level.
	[NonSerialized]
	public int8 LodLevel = -1;

	public override void OnRegister() => Scene.Renderers.Add(this);
	public override void OnUnregister() => Scene.[Friend]RendererLeft(this);

	/// Assign a procedurally built mesh. The renderer does not take ownership.
	public Mesh RuntimeMesh
	{
		get => mRuntimeMesh;
		set
		{
			mRuntimeMesh = value;
		}
	}

	/// One of several meshes a renderer draws, each with a material of its own (null: the renderer's own).
	public class Part
	{
		public Mesh mesh;
		public Tallow.Material material;
		/// Multiplies the part's colour (a character's coat dyed red).
		public Color tint = .White;
		/// Not drawn at all, and casts no shadow.
		public bool hidden;
		/// Casts a shadow but is not drawn (the player's own head, seen from inside it).
		public bool shadowOnly;
	}

	/// Set from code (a Skinned Mesh Renderer whose model has several materials): drawn in place of the renderer's
	/// mesh, each part with its own material. The renderer's color still tints all of them. Null or empty: the
	/// renderer draws its one mesh as usual.
	public List<Part> RuntimeParts;

	List<Part> mModelParts;
	String mModelPartsPath = new .() ~ delete _;
	int32 mModelPartsVersion = -1;

	/// The parts drawn: RuntimeParts when set, else the model's own materials (useModelMaterials), else null (the
	/// renderer draws ActiveMesh with its own material).
	public List<Part> DrawnParts
	{
		get
		{
			if (RuntimeParts != null && RuntimeParts.Count > 0)
				return RuntimeParts;
			if (!useModelMaterials || mRuntimeMesh != null || HasText(material) || HasText(texture))
				return null;
			if (mModelPartsVersion != Assets.MeshVersion || Differs(mModelPartsPath, mesh))
			{
				mModelPartsPath.Set(mesh);
				mModelParts = mesh.StartsWith("builtin:") ? null : Assets.GetModelParts(mesh);
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
				mResolvedPath.Set(mesh);
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
				mResolvedTexture.Set(texture);
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
			if (m == null)
				return .(Transform.Position, Transform.Position);
			return m.Bounds.Transformed(Transform.LocalToWorld);
		}
	}
}
