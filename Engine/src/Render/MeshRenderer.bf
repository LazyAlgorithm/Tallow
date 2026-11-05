using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Draws a mesh with an inline material. Identical mesh/material pairs are batched into instanced draws.
///
/// A handle (ComponentHandle): its settings are MeshRendererData's fields, in the object's entity. What is worked out
/// from them and kept between frames (resolved mesh and texture, its own material copy, meshes and parts set from
/// code) is its RenderProxy.
[Component, HandleFields]
struct MeshRenderer : ComponentHandle<MeshRendererData>
{
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

	/// What the renderer keeps between frames, made the first time it is needed, without refreshing its settings.
	RenderProxy State
	{
		get
		{
			CheckValid();
			let proxy = ComponentState<RenderProxy>.Make(mGameObject.Scene.World, mGameObject.Entity);
			proxy.[Friend]mGameObject = mGameObject;
			return proxy;
		}
	}

	/// The renderer's RenderProxy with its settings copied in from the entity now.
	public RenderProxy Proxy
	{
		get
		{
			let proxy = State;
			proxy.data = Data;
			return proxy;
		}
	}

	/// Whether it has a baked lightmap.
	public bool HasLightmap => !lightmap.IsEmpty;

	/// The material from the Material field, shared with every other renderer that names it. Null with none set.
	public Tallow.Material SharedMaterial => Proxy.SharedMaterial;
	/// This object's own copy of its material, made the first time it is asked for. Change it to change this
	/// object without changing the others that share the material. Null with no material set.
	public Tallow.Material Material => Proxy.Material;
	/// What the renderer draws with: this object's own copy if it has one, otherwise the shared material.
	public Tallow.Material ActiveMaterial => Proxy.ActiveMaterial;

	/// Changes which material this object uses. In a network session, on the server or on the owner's machine,
	/// every machine follows.
	public void SetMaterial(StringView materialPath)
	{
		if (material == materialPath)
			return;
		material = materialPath;
		NetworkSync.MaterialChanged(this, 0, materialPath, default);
	}

	/// Sets a property of this object's own copy of its material: one of the custom shader's properties by name,
	/// or "color", "emissive", "metallic", "roughness", "emissiveIntensity", "cutoff", "tiling" and "offset".
	/// In a network session, on the server or the owner's machine, every machine follows.
	public void SetMaterialValue(StringView name, Vector4 value)
	{
		if (Proxy.ApplyMaterialValue(name, value))
			NetworkSync.MaterialChanged(this, 1, name, value);
	}

	/// Sets a number of the renderer's material (a copy of its own is made the first time).
	public void SetMaterialFloat(StringView name, float value) => SetMaterialValue(name, .(value, 0, 0, 0));
	/// Sets a colour of the renderer's material (a copy of its own is made the first time).
	public void SetMaterialColor(StringView name, Color value) => SetMaterialValue(name, .(value.r, value.g, value.b, value.a));

	/// Set by lines and trails whose colours fade: drawn see-through, as an alpha below 1 in Color is.
	public ref bool vertexAlpha => ref State.vertexAlpha;
	/// World-space offset applied only when drawing. The network layer uses it to blend out corrections.
	public ref Vector3 VisualOffset => ref State.VisualOffset;
	/// Optional world-space presentation correction; never changes transforms or colliders.
	public ref bool UseVisualCorrection => ref State.UseVisualCorrection;
	/// The correction applied when drawing while UseVisualCorrection is on.
	public ref Matrix4 VisualCorrection => ref State.VisualCorrection;
	/// The world matrix the mesh is drawn with: its transform's, with VisualOffset and VisualCorrection applied.
	public Matrix4 RenderMatrix => State.RenderMatrix;
	/// A texture made at run time (a Compute Texture, say) to draw with instead of the one named by the
	/// material or the Texture field. Set it invalid again to go back.
	public ref bgfx.TextureHandle TextureOverride => ref State.TextureOverride;
	/// The frame (Time.FrameCount) this renderer was last drawn on, in any view or shadow map; -1 if never.
	public int64 LastDrawnFrame => State.LastDrawnFrame;
	/// Whether it can move by itself (a Rigidbody, or a skinned model), and so is no Auto occluder.
	public bool IsMoving => State.IsMoving;
	/// The LOD Group above it that picks when it is drawn, if any (set by the group).
	public ref LODGroup LodGroup => ref State.LodGroup;
	/// Its level in that group (from an `_LOD<n>` name), or -1 for every level.
	public ref int8 LodLevel => ref State.LodLevel;
	/// Assign a procedurally built mesh. The renderer does not take ownership.
	public Mesh RuntimeMesh
	{
		get => State.RuntimeMesh;
		set => State.RuntimeMesh = value;
	}

	/// Set from code (a Skinned Mesh Renderer whose model has several materials): drawn in place of the renderer's
	/// mesh, each part with its own material. The renderer's color still tints all of them. Null or empty: the
	/// renderer draws its one mesh as usual.
	public ref List<Part> RuntimeParts => ref State.RuntimeParts;
	/// The parts drawn: RuntimeParts when set, else the model's own materials (useModelMaterials), else null.
	public List<Part> DrawnParts => Proxy.DrawnParts;
	/// The mesh drawn: RuntimeMesh if one is set, else the one named by the mesh field.
	public Mesh ActiveMesh => Proxy.ActiveMesh;
	/// The texture drawn with when the renderer has no material.
	public bgfx.TextureHandle ActiveTexture => Proxy.ActiveTexture;
	/// The box round the drawn mesh, in the world.
	public Bounds WorldBounds => Proxy.WorldBounds;

	/// The mesh an object's Mesh Renderer draws, or null when it has none (or no renderer).
	public static Mesh MeshOf(GameObject gameObject)
	{
		if (gameObject == null || !gameObject.HasComponent<MeshRenderer>())
			return null;
		return gameObject.GetComponent<MeshRenderer>().ActiveMesh;
	}

	static void OnRemove(void* world, uint64 entity) => ComponentState<RenderProxy>.Release(world, entity);
}

/// A Mesh Renderer's settings.
[Component, HandleData]
struct MeshRendererData
{
	/// "builtin:cube", "builtin:sphere", ... or a model path relative to the project.
	public SharedString mesh = "builtin:cube";
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
	public SharedString lightmap = default;
	/// The baked lightmap's direction map, if any (set when lighting is baked).
	public SharedString lightmapDirection = default;
	/// The baked shadowmask, if any (set when lighting is baked).
	public SharedString lightmapShadowmask = default;
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
	/// Mirrors what is on the screen as well as the reflection probe: objects in the room show in the surface where
	/// they really are, not flattened onto the probe's walls. For flat, shiny surfaces (a polished floor, a mirror
	/// wall): it costs a few dozen depth reads a pixel of the surface. Smooth surfaces only (roughness under 0.4);
	/// a material with a custom shader keeps its own reflections. Off with the Reflection Probes quality setting.
	public bool screenReflections = false;
	/// Drawn in reflection probes' captures. A probe sees its room from one point and spreads what it saw over its
	/// box, so things standing in the room (furniture, statues, a ball) come out flattened onto its walls, in the
	/// wrong place in every reflection. Turn it off for them: the probe then holds the room alone, and shiny
	/// surfaces with Screen Reflections still mirror them where they are on the screen. Their shadows stay.
	public bool inReflectionProbes = true;
	/// Mirrors the scene exactly, as a flat mirror would: the scene is drawn a second time, from the camera mirrored
	/// under the surface's top face, and the surface shows that picture. Unlike Screen Reflections it has everything,
	/// off the screen or hidden too, and each thing as seen from below (the underside of a ball, its own reflections
	/// from there). For one flat, shiny floor or water-like surface in view: it costs about as much as drawing the
	/// scene again. One surface a view has it at a time (the nearest); others fall back to Screen Reflections. The
	/// game's view and the editor's Scene and Game views only.
	public bool planarReflection = false;
	/// Optional albedo texture path relative to the project.
	public SharedString texture = default;
	/// A material (.tmat) made in the editor. With one set, it decides how the surface looks and the fields above
	/// are ignored, except Color, which tints this object on top of the material, and Cast Shadows.
	public SharedString material = default;
	/// A model with materials of its own (a glTF, or an FBX, OBJ, ... converted to one) is drawn with them, its
	/// textures included, when no Material or Texture is set here. Off: the whole model takes the fields above.
	public bool useModelMaterials = true;
	/// Whether it hides what is behind it from cameras with Occlusion Culling (docs/occlusion-culling.md).
	public OccluderMode occluder = .Auto;

	public this() { }
}
