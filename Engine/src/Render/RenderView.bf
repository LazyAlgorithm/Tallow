using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// How a view draws its surfaces (the editor's views; the game draws Rendered).
public enum ViewShading
{
	/// Lit by the scene's lights, with shadows, reflections and fog.
	Rendered,
	/// Textures and colours under a light from the viewer, the same from every side.
	MaterialPreview,
	/// Colours without textures under a light from the viewer: the shape alone.
	Solid,
	/// Textures and colours as they are, without light.
	Unlit,
	/// Only the edges of the triangles, seen through.
	Wireframe
}

/// Pipeline: four shadow cascades for the sun, an HDR multisampled forward pass with sky,
/// instanced opaque geometry and debug lines, see-through geometry, the viewmodel (a first-person camera's arms and
/// weapon, over everything: Camera.viewmodelLayer), the screen effects the scene asks for (ambient occlusion, depth of
/// field and motion blur, from a depth pass: docs/post-processing.md), bloom, then a tonemapping resolve with colour
/// grading. Decals (docs/decals.md) are laid over the solid scene, using the same depth pass, before see-through
/// things. Point, spot and extra directional lights are sorted into clusters (LightClusters, docs/lighting.md), so a
/// view can have hundreds; the nearest that cast shadows get tiles of one shadow atlas. Each RenderView uses 19
/// consecutive bgfx view ids: sun shadows 0 to 3, point and spot shadows 4, then the scene, depth, decals,
/// transparency, viewmodel, screen effects, bloom and tonemap in views 5 to 18.
class RenderView
{
	struct RenderItem
	{
		public uint64 key;
		public Mesh mesh;
		public MeshRenderer renderer;
		/// The material this item is drawn with: a part's own (MeshRenderer.RuntimeParts) or the renderer's.
		public Material material;
		public Matrix4 world;
		public Vector3 center;
		public float radius;
		/// Multiplies the renderer's colour for this one item (Foliage gives each plant a shade of its own).
		public Color tint;
		/// The reflection probe it mirrors (an index into Reflections.Ready, -1: the sky alone).
		public int32 probe;
		/// The baked light probe grid it takes ambient light from (LightProbeSet.Pick; 0: the scene's grid).
		public int32 lightGrid;
	}

	[CRepr]
	struct InstanceData
	{
		public Matrix4 world;
		public Color color;
	}

	/// How many bgfx view ids one RenderView uses, from ViewBase. Give each RenderView a ViewBase this far apart.
	public const int ViewCount = 23;
	// Each pass's view id, from ViewBase (the four shadow cascades are ShadowView to ShadowView + 3). bgfx draws
	// views in the order of their ids.
	const int ShadowView = 0;
	const int LocalShadowView = 4;
	const int SceneView = 5;
	const int DepthView = 6;
	const int DecalView = 7;
	const int WaterCopyView = 8;
	const int WaterView = 9;
	const int TransparentView = 10;
	const int UnderwaterCopyView = 11;
	const int UnderwaterView = 12;
	const int ViewmodelView = 13;
	const int AoView = 14;
	const int AoApplyView = 15;
	const int DofBlurView = 16;
	const int DofCombineView = 17;
	const int MotionView = 18;
	const int BloomView = 19;
	const int TonemapView = 22;

	/// What the scene target is cleared to (RGBA): opaque black, under the sky.
	const uint32 SceneClearColor = 0x000000ff;
	/// How far past the scene's shadow distance an object may stand and still cast a shadow into it.
	const float ShadowRangeMargin = 60.0f;
	/// How far from the surface the shadow test is pushed, against shadow acne.
	const float ShadowBias = 0.0005f;
	/// Alpha below this counts as see-through.
	const float OpaqueAlpha = 0.999f;
	/// An effect amount below this is treated as off.
	const float MinimumEffect = 0.001f;
	/// A camera that moved further than this in a frame was cut, not moved: no motion blur for that frame.
	const float MotionBlurCutDistance = 5.0f;

	public uint16 ViewBase;
	/// Which of the scene's screen effects this view shows (the editor's Scene view leaves out depth of field and
	/// motion blur, which get in the way of editing).
	public bool ShowAmbientOcclusion = true;
	public bool ShowDepthOfField = true;
	public bool ShowMotionBlur = true;
	/// How surfaces are drawn (the editor's views; see ViewShading).
	public ViewShading shading = .Rendered;
	/// A wireframe view's line colour.
	public Color wireColor = .(0.08f, 0.09f, 0.11f, 1);
	public bool ToBackbuffer;
	/// How much of the output's resolution the 3D scene is drawn at: below 1 it is drawn smaller and stretched to
	/// fit, which costs much less on a phone's many pixels. The interface is drawn afterwards at full resolution.
	public static float RenderScale = 1;
	/// The most pixels the 3D scene is drawn at across the window's short side (its height held sideways, its width
	/// held upright), however sharp the screen (0: no limit). Phones have very sharp screens and modest graphics
	/// chips: the scene is drawn at this and scaled up, the interface stays sharp. The same either way up.
	public static int32 MaxSceneHeight = 0;
	/// Multisampled edges on the scene. Off saves a lot on phones.
	public static bool Antialias = true;
	/// Shadows in every view (a quality setting; DrawShadows is one view's).
	public static bool ShadowsEnabled = true;
	/// Times each scene's shadow distance, in every view (a quality setting).
	public static float ShadowDistanceScale = 1;
	/// How many point and spot lights cast shadows in a view, the nearest first (a quality setting).
	public static int32 MaxShadowedLights = 8;
	/// Whether lightmaps and baked light probes are used (docs/baked-lighting.md); `--no-baked-lighting` turns them
	/// off, to compare.
	public static bool UseBakedLighting = true;
	/// Objects (by id) whose renderers are not drawn: the editor's rigger hides the model it draws itself.
	public static HashSet<uint32> HiddenObjects = new .() ~ delete _;
	/// Objects only the editor's views draw (views with drawEditorOnly on): the modeller's reference images.
	public static HashSet<uint32> EditorOnlyObjects = new .() ~ delete _;
	/// Draws no renderers at all in this view (the sky, gizmos and the editor's own drawing still show): the rigger
	/// shows its model on its own.
	public bool hideRenderers;
	/// When not 0, the only object whose renderers this view draws (the editor's modeller shows the model it edits).
	public uint32 onlyObject;
	/// Draws the EditorOnlyObjects too (the editor's Scene and model views).
	public bool drawEditorOnly;
	/// Objects (by id) this view alone leaves out, or null (borrowed): what the editor's Hierarchy eyes hide from the
	/// Scene view, while the Game view still draws them.
	public HashSet<uint32> hiddenHere;

	/// Whether this view leaves the object out by hiddenHere.
	public bool HidesHere(GameObject gameObject) => hiddenHere != null && hiddenHere.Count > 0 && hiddenHere.Contains(gameObject.Id);
	// The scene's baked light probes, if any.
	LightProbeSet mProbeGrid;
	List<Mesh> mLightmapMeshes = new .() ~ delete _;
	public bool DrawGizmos;
	public bool DrawShadows = true;
	/// Whether drawing this view advances the reflection captures under way (docs/reflections.md). Off for views of
	/// scenes other than the game's, such as asset previews.
	public bool CapturesReflections = true;
	/// A reflection probe's capture view: drawn at full size without multisampling, and left in HDR (no viewmodel,
	/// screen effects, bloom or tonemap), for Reflections to copy into a cube's face.
	public bool Capture;
	/// The HDR scene picture (for Capture views).
	public bgfx.TextureHandle SceneColor => mSceneColor;
	float mReflectionIntensity = 1;
	// The scene's ambient intensity when its ambient light comes from the reflection cubes, else 0.
	float mCubeAmbient;

	// Statistics from the last Render call.
	/// Every view's draws, instances, triangles and visible renderers this frame, for the Profiler (ProfilerModules
	/// reads and clears them).
	public static int32 FrameDrawCalls, FrameInstances, FrameTriangles, FrameVisible, FrameViews, FrameShadowTiles;
	static ProfilerMarker sRenderMarker = .("RenderView.Render", .Rendering);
	static ProfilerMarker sCullMarker = .("Culling", .Rendering);
	static ProfilerMarker sSortMarker = .("Sorting", .Rendering);
	static ProfilerMarker sShadowMarker = .("Shadows", .Rendering);
	static ProfilerMarker sOpaqueMarker = .("Opaque", .Rendering);
	static ProfilerMarker sDecalMarker = .("Decals", .Rendering);
	static ProfilerMarker sTransparentMarker = .("Transparent", .Rendering);
	static ProfilerMarker sWaterMarker = .("Water", .Rendering);
	static ProfilerMarker sEffectsMarker = .("Screen Effects", .Rendering);
	public int32 DrawCalls;
	public int32 Instances;
	public int32 Triangles;
	public int32 VisibleRenderers;
	/// Renderers left out because their LOD Group was too small on screen.
	public int32 LodCulled;
	/// Renderers left out because they were hidden behind occluders (cameras with Occlusion Culling).
	public int32 OcclusionCulled;
	/// The occluders and their triangles drawn for occlusion culling.
	public int32 Occluders, OccluderTriangles;
	/// The last occlusion picture, for the editor's view of it (null until a camera with Occlusion Culling draws).
	public OcclusionBuffer Occlusion => mOcclusion;
	OcclusionBuffer mOcclusion ~ delete _;
	bool mOcclusionOn;

	int32 mWidth;
	int32 mHeight;
	// The size drawn to (the window, or the output texture); the scene is mWidth x mHeight, RenderScale of it.
	int32 mOutWidth, mOutHeight;
	float mBuiltScale;
	bool mBuiltAntialias;
	bgfx.TextureHandle mSceneColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mSceneFb = .() { idx = uint16.MaxValue };
	bgfx.TextureHandle mOutputColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mOutputFb = .() { idx = uint16.MaxValue };
	// Bloom works at a quarter of the size: one target to shrink into and blur down, one to blur across.
	bgfx.TextureHandle[2] mBloomColor = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	bgfx.FrameBufferHandle[2] mBloomFb = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	int32 mBloomWidth, mBloomHeight;
	// The screen effects', made the first time a scene uses one: the depth pass (distance in front of the camera,
	// with a depth buffer of its own), two full-size pictures to pass the image between, half-size ambient occlusion
	// and depth of field.
	bgfx.TextureHandle mDepthColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mDepthFb = .() { idx = uint16.MaxValue };
	bgfx.TextureHandle[2] mPostColor = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	bgfx.FrameBufferHandle[2] mPostFb = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	bgfx.TextureHandle mAoColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mAoFb = .() { idx = uint16.MaxValue };
	bgfx.TextureHandle mDofColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mDofFb = .() { idx = uint16.MaxValue };
	int32 mHalfWidth, mHalfHeight;
	// Last frame's camera, for motion blur.
	Matrix4 mPrevViewProj;
	Vector3 mPrevPosition;
	bool mHasPrev;
	Vector4 mPostRight, mPostUp, mPostForward, mPostEye;

	List<RenderItem> mItems = new .() ~ delete _;
	List<RenderItem> mShadowItems = new .() ~ delete _;
	List<RenderItem> mTransparentItems = new .() ~ delete _;
	/// Foliage, in runs of one kind of plant: drawn like mItems, but already in order and far too many to sort.
	List<RenderItem> mFoliageItems = new .() ~ delete _;
	List<int32> mFoliageVisible = new .() ~ delete _;
	Vector4 mWind;
	Vector4[4] mWindZone, mWindPush;
	Vector4[8] mBender, mBenderPush;
	// The viewmodel's (Camera.viewmodelLayer): solid, and see-through.
	List<RenderItem> mViewmodelItems = new .() ~ delete _;
	List<RenderItem> mViewmodelTransparent = new .() ~ delete _;

	// Frame constants, re-sent with every draw because bgfx orders uniform updates by sorted draw.
	Vector4 mCamPos, mSunDir, mSunColor, mAmbientSky, mAmbientGround, mFogColor, mLightCount, mCascadeSplits, mShadowParams;
	Vector4 mClusterForward, mClusterParams;
	Matrix4 mClusterViewProj;
	Matrix4[RenderResources.CascadeCount] mShadowMtx;
	Matrix4[RenderResources.CascadeCount] mCascadeViewProj;
	Matrix4[RenderResources.CascadeCount] mCascadeView;
	Matrix4[RenderResources.CascadeCount] mCascadeProj;
	Vector3[RenderResources.CascadeCount] mCascadeCenter;
	float[RenderResources.CascadeCount] mCascadeRadius;
	Vector3 mLightRight, mLightUp;
	bool mHasSun;
	/// This view's point, spot and extra directional lights, in clusters, and the shadow tiles of the nearest.
	LightClusters mLights = new .() ~ delete _;
	bool mHasLocalShadows;
	// Where the shadow pass being drawn looks from, and (point and spot tiles) the part of the atlas it may draw in.
	Matrix4 mShadowPassViewProj;
	int32[4] mShadowScissor;
	/// Whether the depth pass was drawn this frame (decals and the screen effects share it).
	bool mDepthDrawn;
	List<DecalItem> mDecalItems = new .() ~ delete _;
	/// Decals drawn by the last Render.
	public int32 VisibleDecals;

	public this(uint16 viewBase)
	{
		ViewBase = viewBase;
	}

	public ~this()
	{
		ReleaseTargets();
	}

	/// The size of the picture drawn (the scene inside may be drawn smaller: RenderScale).
	public int32 Width => mOutWidth;
	public int32 Height => mOutHeight;
	/// Texture holding the finished image when not rendering to the backbuffer.
	public uint16 OutputTexture => mOutputColor.idx;

	void ReleaseTargets()
	{
		if (!Gfx.Initialized)
			return;
		if (mSceneFb.Valid)
			bgfx.destroy_frame_buffer(mSceneFb);
		if (mOutputFb.Valid)
			bgfx.destroy_frame_buffer(mOutputFb);
		mSceneFb.idx = uint16.MaxValue;
		mOutputFb.idx = uint16.MaxValue;
		for (int i < 2)
		{
			if (mBloomFb[i].Valid)
				bgfx.destroy_frame_buffer(mBloomFb[i]);
			mBloomFb[i].idx = uint16.MaxValue;
		}
		ReleaseEffectTargets();
		ReleaseWaterTargets();
	}

	public void Resize(int32 width, int32 height)
	{
		let outWidth = Math.Max(width, 8);
		let outHeight = Math.Max(height, 8);
		var scale = Capture ? 1 : Math.Clamp(RenderScale, 0.25f, 1.0f);
		if (MaxSceneHeight > 0 && !Capture)
			scale = Math.Max(Math.Min(scale, (float)MaxSceneHeight / Math.Min(outWidth, outHeight)), 0.25f);
		let antialias = Antialias && !Capture;
		if (outWidth == mOutWidth && outHeight == mOutHeight && scale == mBuiltScale && antialias == mBuiltAntialias && mSceneFb.Valid)
			return;
		ReleaseTargets();
		mOutWidth = outWidth;
		mOutHeight = outHeight;
		mBuiltScale = scale;
		mBuiltAntialias = antialias;
		let w = Math.Max((int32)(outWidth * scale), 8);
		let h = Math.Max((int32)(outHeight * scale), 8);
		mWidth = w;
		mHeight = h;

		let clamp = Gfx.SamplerClamp;
		// Multisampling also makes the texture a render target; without it the texture has to say so itself.
		let msaa4 = antialias ? Gfx.TextureRenderTargetMsaa4 : 0;
		let target = antialias ? msaa4 : Gfx.TextureRenderTarget;
		let writeOnly = Gfx.TextureWriteOnly;
		let rt = Gfx.TextureRenderTarget;
		bgfx.TextureHandle[2] sceneTextures;
		sceneTextures[0] = bgfx.create_texture_2d((uint16)w, (uint16)h, false, 1, .RGBA16F, target | clamp, null, 0);
		sceneTextures[1] = bgfx.create_texture_2d((uint16)w, (uint16)h, false, 1, .D32F, msaa4 | writeOnly, null, 0);
		mSceneColor = sceneTextures[0];
		mSceneFb = bgfx.create_frame_buffer_from_handles(2, &sceneTextures, true);

		mBloomWidth = Math.Max(w / 4, 4);
		mBloomHeight = Math.Max(h / 4, 4);
		for (int i < 2)
		{
			mBloomColor[i] = bgfx.create_texture_2d((uint16)mBloomWidth, (uint16)mBloomHeight, false, 1, .RGBA16F, rt | clamp, null, 0);
			mBloomFb[i] = bgfx.create_frame_buffer_from_handles(1, &mBloomColor[i], true);
		}

		if (!ToBackbuffer)
		{
			mOutputColor = bgfx.create_texture_2d((uint16)outWidth, (uint16)outHeight, false, 1, .RGBA8, rt | clamp, null, 0);
			mOutputFb = bgfx.create_frame_buffer_from_handles(1, &mOutputColor, true);
		}
	}

	static Vector4 Linear(Color c, float scale = 1.0f)
	{
		return .(Math.Pow(Math.Max(c.r, 0), 2.2f) * scale, Math.Pow(Math.Max(c.g, 0), 2.2f) * scale, Math.Pow(Math.Max(c.b, 0), 2.2f) * scale, c.a);
	}

	/// Draws the scene from a camera: shadows, the scene, see-through things, the viewmodel, then the screen effects,
	/// bloom and the tonemap, each in a view of its own (see the class comment).
	public void Render(Scene scene, CameraData camera)
	{
		if (!mSceneFb.Valid)
			return;
		RenderResources.EnsureCreated();
		sRenderMarker.Begin();
		defer
		{
			Profiler.End();
			FrameDrawCalls += DrawCalls;
			FrameInstances += Instances;
			FrameTriangles += Triangles;
			FrameVisible += VisibleRenderers;
			FrameViews++;
		}
		DrawCalls = 0;
		Instances = 0;
		Triangles = 0;
		LodCulled = 0;
		OcclusionCulled = 0;
		Occluders = 0;
		OccluderTriangles = 0;

		let frustum = Frustum(camera.projection * camera.view, Gfx.HomogeneousDepth);
		let env = scene.Environment;
		let sun = GatherLights(scene, camera);
		let lightDirection = SetSun(sun);
		let castShadows = DrawShadows && ShadowsEnabled && sun != null && sun.castShadows && shading == .Rendered;
		SetFrameConstants(camera, env);
		Reflections.Update(scene, mSunDir, mSunColor, CapturesReflections && !Capture);
		mReflectionIntensity = Math.Max(env.reflectionIntensity, 0);
		mCubeAmbient = env.ambientFromSurroundings ? Math.Max(env.ambientIntensity, 0.0001f) : 0;

		ClearItems();
		var shadowRange = env.shadowDistance * ShadowDistanceScale + ShadowRangeMargin;
		for (let tile in mLights.Tiles)
			shadowRange = Math.Max(shadowRange, (tile.light.Transform.Position - camera.position).Length + tile.light.range);
		mOcclusionOn = camera.occlusionCulling && !camera.orthographic;
		sCullMarker.Begin();
		if (mOcclusionOn)
		{
			if (mOcclusion == null)
				mOcclusion = new .();
			mOcclusion.Build(scene, camera, frustum);
			Occluders = mOcclusion.Occluders;
			OccluderTriangles = mOcclusion.OccluderTriangles;
		}
		GatherRenderers(scene, camera, frustum, castShadows || mHasLocalShadows, shadowRange);
		if (mOcclusionOn)
			OcclusionCulled = mOcclusion.Culled;
		GatherFoliage(scene, camera, frustum, castShadows || mHasLocalShadows, shadowRange);
		Wind.Gather(scene, camera.position, out mWind, ref mWindZone, ref mWindPush);
		FoliageBender.Gather(scene, camera.position, ref mBender, ref mBenderPush);
		VisibleRenderers = (int32)(mItems.Count + mViewmodelItems.Count);
		Profiler.End();
		using (sSortMarker.Sample())
			SortItems();

		sShadowMarker.Begin();
		if (castShadows)
			DrawShadowCascades(camera, lightDirection, env.shadowDistance * ShadowDistanceScale);
		else
		{
			mShadowParams = .(1.0f / RenderResources.ShadowAtlasSize, 0, 0, 0);
			mCascadeSplits = .(0, 0, 0, 0);
		}
		if (mHasLocalShadows)
			DrawLocalShadows();
		Profiler.End();
		FrameShadowTiles += (int32)mLights.Tiles.Count;
		using (sOpaqueMarker.Sample())
			DrawScene(scene, camera, frustum, env);
		mDepthDrawn = false;
		using (sDecalMarker.Sample())
			DrawDecals(scene, camera, frustum);
		using (sWaterMarker.Sample())
			DrawWater(scene, camera, frustum);
		using (sTransparentMarker.Sample())
			DrawTransparent(camera);
		if (Capture)
			return;
		using (sWaterMarker.Sample())
			DrawUnderwater(scene, camera);
		DrawViewmodel(camera);
		sEffectsMarker.Begin();
		defer Profiler.End();
		let picture = DrawScreenEffects(camera, env);
		let bloom = Math.Max(env.bloom, 0);
		let drawsBloom = bloom > MinimumEffect;
		if (drawsBloom)
			DrawBloom(env, picture);
		DrawTonemap(env, picture, drawsBloom ? bloom : 0);
	}

	/// Points a bgfx view at a target and a rectangle, with what to clear it to.
	void SetUpView(uint16 view, StringView name, bgfx.FrameBufferHandle target, int32 x, int32 y, int32 width, int32 height,
		uint16 clearFlags = 0, uint32 clearColor = 0)
	{
		bgfx.set_view_name(view, name.Ptr, (int32)name.Length);
		bgfx.set_view_frame_buffer(view, target);
		bgfx.set_view_rect(view, (int16)x, (int16)y, (uint16)width, (uint16)height, 0, 1);
		bgfx.set_view_clear(view, clearFlags, clearColor, 1.0f, 0);
	}

	/// Picks the sun (the directional light that casts shadows, or the first one, if none does) and sorts the
	/// scene's other lights into this view's clusters. Returns the sun.
	Light GatherLights(Scene scene, CameraData camera)
	{
		Light sun = null;
		// Directional lights other than the sun go in the ordinary light list, so fill lights still count.
		for (let light in scene.Lights)
		{
			if (!light.IsActiveAndEnabled || !light.GameObject.InActiveWorld || light.type != .Directional)
				continue;
			if (sun == null || (!sun.castShadows && light.castShadows))
				sun = light;
		}
		let shadowed = DrawShadows && ShadowsEnabled ? MaxShadowedLights : 0;
		mLights.Build(scene, camera, sun, shadowed, RenderResources.ShadowAtlasSize);
		mHasLocalShadows = mLights.Tiles.Count > 0;
		mLightCount = .(mLights.DirectionalCount, sun != null ? sun.shadowMaskChannel + 1 : 0, mLights.Lights.Count, 0);
		mClusterViewProj = mLights.ViewProj;
		mClusterForward = .(mLights.CameraForward, 0);
		mClusterParams = .(mLights.SliceScale, mLights.SliceOffset, mLights.Near, 0);
		if (Gfx.Initialized)
			mLights.Upload();
		return sun;
	}

	/// This view's lights after the last Render: how many, and how many were left out (more than LightClusters.MaxLights).
	public int32 LightCount => (int32)mLights.Lights.Count;
	public int32 LightsDropped => mLights.Dropped;
	/// Point and spot shadow tiles drawn by the last Render.
	public int32 ShadowTiles => (int32)mLights.Tiles.Count;

	/// Sets the sun's colour and direction (none: no sunlight, and a default direction). Returns the direction its
	/// light travels in.
	Vector3 SetSun(Light sun)
	{
		mHasSun = sun != null;
		if (sun == null)
		{
			let direction = Vector3(0.3f, -1.0f, 0.2f).Normalized;
			mSunColor = .(0, 0, 0, 1);
			mSunDir = .(-direction, 0);
			return direction;
		}
		let direction = sun.Transform.Forward;
		let color = Linear(sun.color, sun.intensity);
		mSunColor = .(color.x, color.y, color.z, 1);
		mSunDir = .(-direction, sun.shadowStrength);
		return direction;
	}

	/// The camera, ambient light and fog, which every draw is given.
	void SetFrameConstants(CameraData camera, SceneEnvironment env)
	{
		mCamPos = .(camera.position, 1);
		mProbeGrid = UseBakedLighting ? LightProbes.Get(env.lightProbes) : null;
		mAmbientSky = Linear(env.ambientSky, env.ambientIntensity);
		mAmbientGround = Linear(env.ambientGround, env.ambientIntensity);
		let fog = Linear(env.fogColor);
		// No fog through an orthographic camera: how far away it stands means nothing to what it shows.
		mFogColor = .(fog.x, fog.y, fog.z, camera.orthographic ? 0 : env.fogDensity);
	}

	void ClearItems()
	{
		mItems.Clear();
		mShadowItems.Clear();
		mTransparentItems.Clear();
		mViewmodelItems.Clear();
		mViewmodelTransparent.Clear();
		mFoliageItems.Clear();
	}

	/// Sorts every renderer's meshes into the lists drawn this frame: solid, see-through, viewmodel and shadows.
	void GatherRenderers(Scene scene, CameraData camera, Frustum frustum, bool castShadows, float shadowRange)
	{
		for (let renderer in scene.Renderers)
		{
			// Outside the scene's world state: not drawn and casts no shadow.
			if (!renderer.IsActiveAndEnabled || !renderer.GameObject.InActiveWorld)
				continue;
			if (hideRenderers || HidesHere(renderer.GameObject) || (HiddenObjects.Count > 0 && HiddenObjects.Contains(renderer.GameObject.Id)) || (onlyObject != 0 && renderer.GameObject.Id != onlyObject && !EditorOnlyObjects.Contains(renderer.GameObject.Id)))
				continue;
			if (!drawEditorOnly && EditorOnlyObjects.Count > 0 && EditorOnlyObjects.Contains(renderer.GameObject.Id))
				continue;
			// A renderer with parts draws each with its own material; otherwise its one mesh (a "part" of its own).
			let parts = renderer.DrawnParts;
			let hasParts = parts != null && parts.Count > 0;
			let partCount = hasParts ? parts.Count : 1;
			// Baked lighting: the meshes with lightmap coordinates, made the first time (LightmapUV).
			let lightmapped = !renderer.lightmap.IsEmpty && UseBakedLighting && LightmapUV.MeshesFor(renderer, mLightmapMeshes) && mLightmapMeshes.Count == partCount;
			// Levels of detail (docs/lod.md): the group picks one level for this camera, and too small is not drawn.
			let lodGroup = renderer.LodGroup;
			let lodLevel = lodGroup != null ? lodGroup.LevelFor(camera) : 0;
			if (lodLevel < 0)
			{
				LodCulled++;
				continue;
			}
			for (int partIndex < partCount)
			{
				var mesh = hasParts ? parts[partIndex].mesh : renderer.ActiveMesh;
				if (lightmapped)
					mesh = mLightmapMeshes[partIndex];
				if (lodGroup != null)
					mesh = lodGroup.MeshAt(renderer, mesh, lodLevel);
				if (mesh == null || !mesh.HasGpuData || (hasParts && parts[partIndex].hidden))
					continue;
				let shadowOnly = renderer.shadowOnly || (hasParts && parts[partIndex].shadowOnly);
				RenderItem item;
				item.tint = hasParts ? parts[partIndex].tint : .White;
				item.mesh = mesh;
				item.renderer = renderer;
				item.material = (hasParts && parts[partIndex].material != null) ? parts[partIndex].material : renderer.ActiveMaterial;
				item.world = renderer.RenderMatrix;
				let bounds = mesh.Bounds.Transformed(item.world);
				item.center = bounds.Center;
				item.radius = bounds.Extents.Length;
				let transparent = IsTransparent(renderer, item.material);
				// The viewmodel: drawn in a pass of its own after the world (no culling: it is a few things at the eye).
				let viewmodel = DrawsAsViewmodel(camera, renderer.GameObject);
				let drawn = !shadowOnly && (viewmodel || (frustum.Intersects(bounds) && (!mOcclusionOn || mOcclusion.IsVisible(bounds))));
				let shadowAllowed = !viewmodel || camera.viewmodelCastsShadows;
				let shadow = !transparent && castShadows && renderer.castShadows && shadowAllowed && (item.center - camera.position).Length - item.radius < shadowRange;
				// Out of view and casting no shadow here: nothing more to work out.
				if (!drawn && !shadow)
					continue;
				item.probe = Reflections.Pick(item.center, item.radius);
				item.lightGrid = LightGridAt(item.center);
				item.key = ProbeKey(MakeKey(renderer, mesh, item.material), item.probe, item.lightGrid) * 2 + (Mirrored(item.world) ? 1u : 0u);
				if (drawn)
				{
					if (viewmodel)
						(transparent ? mViewmodelTransparent : mViewmodelItems).Add(item);
					else
						(transparent ? mTransparentItems : mItems).Add(item);
					renderer.LastDrawnFrame = Time.FrameCount;
				}
				if (shadow)
				{
					mShadowItems.Add(item);
					renderer.LastDrawnFrame = Time.FrameCount;
				}
			}
		}
	}

	/// A colour alpha below 1, or a Transparent material, makes an object see-through: it is drawn after everything
	/// solid, blended, and (being glass-like) casts no shadow.
	static bool IsTransparent(MeshRenderer renderer, Material material)
	{
		if (material == null)
			return renderer.color.a < OpaqueAlpha;
		return material.IsTransparent || (material.blend == .Opaque && renderer.color.a * material.color.a < OpaqueAlpha);
	}

	static bool InShadowRange(RenderItem item, CameraData camera, float shadowRange)
	{
		return (item.center - camera.position).Length - item.radius < shadowRange;
	}

	/// Every plant near enough and in view, one item each, in runs of one kind of plant.
	void GatherFoliage(Scene scene, CameraData camera, Frustum frustum, bool castShadows, float shadowRange)
	{
		for (let foliage in Foliage.All)
		{
			if (foliage.GameObject == null || foliage.GameObject.IsDestroyed || foliage.Scene != scene)
				continue;
			if (!foliage.IsActiveAndEnabled || !foliage.GameObject.InActiveWorld || HidesHere(foliage.GameObject))
				continue;
			let mesh = foliage.Mesh;
			if (mesh == null || !mesh.HasGpuData)
				continue;
			mFoliageVisible.Clear();
			foliage.Visible(camera.position, frustum, mFoliageVisible);
			if (mFoliageVisible.Count == 0)
				continue;
			let proxy = foliage.Proxy;
			let material = foliage.ActiveMaterial;
			let key = MakeKey(proxy, mesh, material);
			let meshRadius = mesh.Bounds.Extents.Length;
			let shadows = castShadows && foliage.castShadows;
			for (let index in mFoliageVisible)
			{
				RenderItem item;
				item.mesh = mesh;
				item.renderer = proxy;
				item.material = material;
				Color tint;
				float scale;
				item.world = foliage.WorldOf(index, out tint, out scale);
				item.tint = tint;
				item.center = .(item.world.m[12], item.world.m[13] + mesh.Bounds.Center.y * scale, item.world.m[14]);
				item.radius = meshRadius * scale;
				item.probe = Reflections.Pick(item.center, item.radius);
				item.lightGrid = LightGridAt(item.center);
				item.key = ProbeKey(key, item.probe, item.lightGrid) * 2 + (Mirrored(item.world) ? 1u : 0u);
				mFoliageItems.Add(item);
				if (shadows && InShadowRange(item, camera, shadowRange))
					mShadowItems.Add(item);
			}
		}
	}

	/// Puts draws that can share a batch next to each other.
	void SortItems()
	{
		mItems.Sort(scope (a, b) => a.key <=> b.key);
		mViewmodelItems.Sort(scope (a, b) => a.key <=> b.key);
		// Shadows only care about the mesh and how it sways, so they are sorted by those alone: sorted by the full key,
		// draws of one mesh with different materials end up apart and cannot be drawn together.
		mShadowItems.Sort(scope (a, b) =>
			{
				let byMesh = (int)Internal.UnsafeCastToPtr(a.mesh) <=> (int)Internal.UnsafeCastToPtr(b.mesh);
				return byMesh != 0 ? byMesh : a.renderer.windSway <=> b.renderer.windSway;
			});
	}

	/// The sky, solid things, plants, particles and lines, into the HDR scene target.
	void DrawScene(Scene scene, CameraData camera, Frustum frustum, SceneEnvironment env)
	{
		let view = (uint16)(ViewBase + SceneView);
		var viewMatrix = camera.view;
		var projMatrix = camera.projection;
		SetUpView(view, "Scene", mSceneFb, 0, 0, mWidth, mHeight, Gfx.ClearColor | Gfx.ClearDepth, SceneClearColor);
		bgfx.set_view_transform(view, &viewMatrix, &projMatrix);
		bgfx.touch(view);
		SubmitSky(view, env);
		SubmitMeshes(view, mItems);
		SubmitMeshes(view, mFoliageItems);
		SubmitParticles(view, scene, frustum);
		SubmitLines(view, DebugDraw.Lines);
		if (DrawGizmos)
		{
			SubmitLines(view, Gizmos.Triangles, true);
			SubmitLines(view, Gizmos.Lines);
			SubmitLines(view, Gizmos.OnTopTriangles, true, true);
			SubmitLines(view, Gizmos.OnTopLines, false, true);
		}
	}

	/// See-through things, in a view of their own so that they are drawn in order, back to front.
	void DrawTransparent(CameraData camera)
	{
		if (mTransparentItems.Count == 0)
			return;
		let view = (uint16)(ViewBase + TransparentView);
		var viewMatrix = camera.view;
		var projMatrix = camera.projection;
		SetUpView(view, "Transparent", mSceneFb, 0, 0, mWidth, mHeight);
		bgfx.set_view_transform(view, &viewMatrix, &projMatrix);
		bgfx.set_view_mode(view, .Sequential);
		SubmitBackToFront(view, mTransparentItems, camera.position);
	}

	/// The viewmodel, over everything, with its own field of view and near clip.
	void DrawViewmodel(CameraData camera)
	{
		if (mViewmodelItems.Count + mViewmodelTransparent.Count == 0)
			return;
		let view = (uint16)(ViewBase + ViewmodelView);
		var viewMatrix = camera.view;
		var projection = camera.viewmodelProjection;
		// Depth only: the world stays in the picture, and nothing in it can hide the viewmodel.
		SetUpView(view, "Viewmodel", mSceneFb, 0, 0, mWidth, mHeight, Gfx.ClearDepth);
		bgfx.set_view_transform(view, &viewMatrix, &projection);
		// Solid first, then see-through parts back to front, in that order.
		bgfx.set_view_mode(view, .Sequential);
		bgfx.touch(view);
		SubmitMeshes(view, mViewmodelItems);
		SubmitBackToFront(view, mViewmodelTransparent, camera.position);
	}

	void SubmitBackToFront(uint16 view, List<RenderItem> items, Vector3 eye)
	{
		items.Sort(scope (a, b) => (b.center - eye).LengthSquared <=> (a.center - eye).LengthSquared);
		// Neighbours in that order that could share a batch are one instanced draw: instances blend in order, so the
		// order holds.
		int start = 0;
		while (start < items.Count)
		{
			int end = start + 1;
			while (end < items.Count && items[end].key == items[start].key)
				end++;
			SubmitBatch(view, items, start, end - start, false, true);
			start = end;
		}
	}

	/// Whether an object is drawn in the viewmodel pass for this camera (Camera.viewmodelLayer) rather than with the world.
	public static bool DrawsAsViewmodel(CameraData camera, GameObject gameObject) => camera.hasViewmodel && gameObject != null && gameObject.Layer == camera.viewmodelLayer;

	public static bool Mirrored(Matrix4 world) => Vector3.Dot(world.Right, Vector3.Cross(world.Up, world.Forward)) < 0;

	/// Draws lit by different probes (reflection probes or light probe volumes) cannot share a batch.
	static uint64 ProbeKey(uint64 key, int32 probe, int32 lightGrid)
	{
		var key;
		if (probe >= 0)
			key = key * 1099511628211 ^ (uint64)(probe + 1);
		if (lightGrid > 0)
			key = key * 1099511628211 ^ ((uint64)lightGrid << 32);
		return key;
	}

	/// The baked light probe grid for a thing whose middle is here (0: the scene's grid, or no probes).
	int32 LightGridAt(Vector3 center) => mProbeGrid != null && mProbeGrid.grids.Count > 1 ? mProbeGrid.Pick(center) : 0;

	static uint64 MakeKey(MeshRenderer renderer, Mesh mesh, Material material)
	{
		uint64 key = (uint64)(int)Internal.UnsafeCastToPtr(mesh);
		if (!renderer.lightmap.IsEmpty)
			key = key * 1099511628211 ^ (uint64)(int)Internal.UnsafeCastToPtr(renderer);
		// With a material, the material is what draws differ by.
		let shared = material;
		key = key * 1099511628211 ^ (uint64)renderer.TextureOverride.idx;
		key = key * 1099511628211 ^ (uint64)(uint32)(renderer.windSway * 100.0f);
		key = key * 1099511628211 ^ (renderer.backFaceCulling ? 0 : 1u);
		if (shared != null)
		{
			key = key * 1099511628211 ^ (uint64)(int)Internal.UnsafeCastToPtr(shared);
			key = key * 1099511628211 ^ (uint64)shared.Revision;
			return key;
		}
		// Metallic and roughness travel with each instance (FillInstances), so they do not split batches.
		key = key * 1099511628211 ^ (uint64)((renderer.flatShading ? 1 : 0) | (renderer.unlit ? 2 : 0));
		key = key * 1099511628211 ^ (uint64)renderer.ActiveTexture.idx;
		if (renderer.emissiveIntensity > 0)
		{
			key = key * 1099511628211 ^ (uint64)renderer.emissive.ToABGR();
			key = key * 1099511628211 ^ (uint64)(uint32)(renderer.emissiveIntensity * 64.0f);
		}
		return key;
	}

	void SubmitMeshes(uint16 view, List<RenderItem> items)
	{
		int start = 0;
		while (start < items.Count)
		{
			int end = start + 1;
			while (end < items.Count && items[end].key == items[start].key)
				end++;
			SubmitBatch(view, items, start, end - start, false);
			start = end;
		}
	}

	/// How a batch's surface is drawn: from its material when it has one, else from the renderer's own settings.
	struct Surface
	{
		public Vector4 material;
		public Vector4 emissive;
		public Vector4 uvTransform;
		public Vector4 surface;
		public Vector4 pbr;
		public Vector4[ShaderAsset.MaxValues] values;
		public StringView[ShaderAsset.MaxTextures] textures;
		public StringView normalMap, metalRoughMap, occlusionMap, emissiveMap;
		public bgfx.TextureHandle texture;
		public bgfx.ProgramHandle program;
		public uint64 cull;
	}

	/// Draws `count` items from `start` that share a mesh and material, as one instanced draw (as many as the frame's
	/// instance memory has room for).
	void SubmitBatch(uint16 view, List<RenderItem> items, int start, int count, bool shadowPass, bool transparent = false)
	{
		let stride = (uint16)sizeof(InstanceData);
		let available = (int)bgfx.get_avail_instance_data_buffer((uint32)count, stride);
		let drawCount = Math.Min(count, available);
		if (drawCount <= 0)
			return;
		bgfx.InstanceDataBuffer buffer = default;
		bgfx.alloc_instance_data_buffer(&buffer, (uint32)drawCount, stride);
		FillInstances((InstanceData*)buffer.data, items, start, drawCount);
		// The editor's own objects (reference images) keep their look in every shading.
		// Foliage/particle batches use proxy renderers without a GameObject.
		let owner = items[start].renderer.GameObject;
		let shaded = shading != .Rendered && (owner == null || !EditorOnlyObjects.Contains(owner.Id));
		let wire = !shadowPass && shaded && shading == .Wireframe;
		if (wire)
		{
			// Black lines, coloured by their glow alone (see ApplyShading).
			let data = (InstanceData*)buffer.data;
			for (int i < drawCount)
				data[i].color = .(0, 0, 0, 1);
		}

		let first = items[start];
		let mesh = first.mesh;
		if (mesh.IsDynamic)
			bgfx.set_dynamic_vertex_buffer(0, mesh.DynamicBuffer, 0, (uint32)mesh.VertexCount);
		else
			bgfx.set_vertex_buffer(0, mesh.VertexBuffer, 0, (uint32)mesh.VertexCount);
		bgfx.IndexBufferHandle edges = default;
		int32 edgeCount = 0;
		let lines = wire && mesh.EdgeLines(out edges, out edgeCount);
		if (lines)
			bgfx.set_index_buffer(edges, 0, (uint32)edgeCount);
		else
			bgfx.set_index_buffer(mesh.IndexBuffer, 0, (uint32)mesh.IndexCount);
		bgfx.set_instance_data_buffer(&buffer, 0, (uint32)drawCount);

		if (shadowPass)
		{
			SetWindUniforms(first.renderer.windSway);
			bgfx.set_uniform(RenderResources.uShadowViewProj, &mShadowPassViewProj, 1);
			if (mShadowScissor[2] > 0)
				bgfx.set_scissor((uint16)mShadowScissor[0], (uint16)mShadowScissor[1], (uint16)mShadowScissor[2], (uint16)mShadowScissor[3]);
			bgfx.set_state(Gfx.StateWriteZ | Gfx.StateDepthLess, 0);
			bgfx.submit(view, RenderResources.ShadowProgram, 0, 0xff);
			return;
		}

		let renderer = first.renderer;
		SetFrameUniforms();
		Reflections.Bind(first.probe, mReflectionIntensity, mCubeAmbient);
		if (first.lightGrid > 0)
			LightProbes.Bind(mProbeGrid, first.lightGrid);
		var surface = ResolveSurface(renderer, first.material, first.world);
		if (shaded)
			ApplyShading(ref surface);
		SetLightmapUniforms(renderer, first.mesh);
		SetSurfaceUniforms(renderer, ref surface);
		if (lines)
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | Gfx.StateLines | Gfx.StateMsaa, 0);
		else if (transparent)
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateDepthLess | surface.cull | Gfx.StateMsaa | Gfx.StateBlendAlpha, 0);
		else
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | surface.cull | Gfx.StateMsaa, 0);
		bgfx.submit(view, surface.program, 0, 0xff);

		DrawCalls++;
		Instances += (int32)drawCount;
		Triangles += (int32)drawCount * mesh.IndexCount / 3;
	}

	/// An editor view's shading (ViewShading) in place of the surface's own lighting. Every mode but Rendered draws
	/// with the standard shader: u_material.w 1 is unlit, 2 the light from the viewer.
	void ApplyShading(ref Surface surface)
	{
		if (shading == .Rendered)
			return;
		surface.program = RenderResources.MeshProgram;
		surface.values = default;
		switch (shading)
		{
		case .MaterialPreview:
			surface.material.w = 2;
		case .Solid:
			surface.material.w = 2;
			surface.texture = Gfx.WhiteTexture;
			surface.pbr = default;
			surface.normalMap = surface.metalRoughMap = surface.occlusionMap = surface.emissiveMap = "";
		case .Unlit:
			surface.material.w = 1;
		case .Wireframe:
			surface.material.w = 1;
			surface.texture = Gfx.WhiteTexture;
			surface.pbr = default;
			surface.surface.x = 0;
			surface.emissive = Linear(wireColor, 1);
			surface.normalMap = surface.metalRoughMap = surface.occlusionMap = surface.emissiveMap = "";
		default:
		}
	}

	/// Each instance's world matrix and colour: the renderer's colour, times the item's tint and the material's colour.
	/// Without a material, the renderer's metallic and roughness go in the matrix's bottom row, which is always
	/// (0, 0, 0, 1) and which the shaders rebuild (vs_mesh.sc): with 1 in the third place to say they are there.
	static void FillInstances(InstanceData* data, List<RenderItem> items, int start, int count)
	{
		for (int i < count)
		{
			let item = items[start + i];
			let color = item.renderer.color;
			data[i].world = item.world;
			if (item.material == null)
			{
				data[i].world.m[3] = item.renderer.metallic;
				data[i].world.m[7] = item.renderer.roughness;
				data[i].world.m[11] = 1;
			}
			data[i].color = .(color.r * item.tint.r, color.g * item.tint.g, color.b * item.tint.b, color.a * item.tint.a);
			let material = item.material;
			if (material != null)
			{
				let tint = data[i].color;
				data[i].color = .(tint.r * material.color.r, tint.g * material.color.g, tint.b * material.color.b, tint.a * material.color.a);
			}
		}
	}

	/// A material, when the renderer (or this part) has one, replaces the renderer's own surface settings.
	static Surface ResolveSurface(MeshRenderer renderer, Material shared, Matrix4 world)
	{
		Surface surface = default;
		surface.material = .(renderer.metallic, renderer.roughness, renderer.flatShading ? 1 : 0, renderer.unlit ? 1 : 0);
		surface.emissive = Linear(renderer.emissive, renderer.emissiveIntensity);
		surface.uvTransform = .(1, 1, 0, 0);
		surface.surface = .(0, Time.RealTime, renderer.emissiveFromColor ? 1 : 0, 0);
		surface.normalMap = surface.metalRoughMap = surface.occlusionMap = surface.emissiveMap = "";
		surface.program = RenderResources.MeshProgram;
		surface.cull = !renderer.backFaceCulling ? 0 : Mirrored(world) ? Gfx.StateCullCw : Gfx.StateCullCcw;
		if (shared == null)
			surface.texture = renderer.ActiveTexture;
		else
		{
			surface.material = .(shared.metallic, shared.roughness, shared.flatShading ? 1 : 0, shared.unlit ? 1 : 0);
			surface.emissive = Linear(shared.emissive, shared.emissiveIntensity);
			surface.uvTransform = .(shared.tiling.x, shared.tiling.y, shared.offset.x, shared.offset.y);
			if (shared.blend == .Cutout)
				surface.surface.x = Math.Max(shared.cutoff, 0.001f);
			surface.surface.w = shared.previewOutput;
			if (shared.doubleSided)
				surface.cull = 0;
			surface.texture = shared.MainTexture;
			surface.normalMap = shared.normalMap;
			surface.metalRoughMap = shared.metallicRoughnessMap;
			surface.occlusionMap = shared.occlusionMap;
			surface.emissiveMap = shared.emissiveMap;
			surface.pbr = .(surface.normalMap.IsEmpty ? 0 : Math.Max(shared.normalStrength, 0.001f), surface.metalRoughMap.IsEmpty ? 0 : 1,
				surface.occlusionMap.IsEmpty ? 0 : shared.occlusionStrength, surface.emissiveMap.IsEmpty ? 0 : 1);
			shared.GatherValues(ref surface.values, ref surface.textures);
			let compiled = shared.Shader?.Program;
			if (compiled != null && compiled.Value.idx != uint16.MaxValue)
				surface.program = compiled.Value;
		}
		if (renderer.TextureOverride.idx != uint16.MaxValue)
			surface.texture = renderer.TextureOverride;
		return surface;
	}

	/// The renderer's baked lighting: its lightmap, and the direction and shadowmask maps that go with it. A mesh
	/// without lightmap coordinates (a lower level of detail) is drawn without it, lit by the light probes.
	static void SetLightmapUniforms(MeshRenderer renderer, Mesh mesh)
	{
		Vector4 bakedTransform = renderer.lightmapScaleOffset;
		Vector4 bakedDecode = renderer.lightmapDecode;
		let lightmapped = UseBakedLighting && !renderer.lightmap.IsEmpty && mesh.LightmapUVs;
		bakedDecode.w = !lightmapped ? 0 : (1 + (renderer.lightmapDirection.IsEmpty ? 0 : 1) + (renderer.lightmapShadowmask.IsEmpty ? 0 : 2));
		bgfx.set_uniform(RenderResources.uLightmapTransform, &bakedTransform, 1);
		bgfx.set_uniform(RenderResources.uLightmapDecode, &bakedDecode, 1);
		bgfx.set_texture(8, RenderResources.sLightmap, Assets.GetTexture(renderer.lightmap, .Data), uint32.MaxValue);
		bgfx.set_texture(9, RenderResources.sLightmapDirection, Assets.GetTexture(renderer.lightmapDirection, .Data), uint32.MaxValue);
		bgfx.set_texture(10, RenderResources.sLightmapShadowmask, Assets.GetTexture(renderer.lightmapShadowmask, .Data), uint32.MaxValue);
	}

	static void SetSurfaceUniforms(MeshRenderer renderer, ref Surface surface)
	{
		bgfx.set_uniform(RenderResources.uMaterial, &surface.material, 1);
		bgfx.set_uniform(RenderResources.uEmissive, &surface.emissive, 1);
		bgfx.set_uniform(RenderResources.uUvTransform, &surface.uvTransform, 1);
		bgfx.set_uniform(RenderResources.uSurface, &surface.surface, 1);
		Vector4 sway = .(renderer.windSway, 0, 0, 0);
		bgfx.set_uniform(RenderResources.uSway, &sway, 1);
		bgfx.set_uniform(RenderResources.uParams, &surface.values, ShaderAsset.MaxValues);
		bgfx.set_texture(0, RenderResources.sAlbedo, surface.texture, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sShadowMap, RenderResources.ShadowMap, uint32.MaxValue);
		bgfx.set_texture(2, RenderResources.sTexture1, Assets.GetTexture(surface.textures[0]), uint32.MaxValue);
		bgfx.set_texture(3, RenderResources.sTexture2, Assets.GetTexture(surface.textures[1]), uint32.MaxValue);
		bgfx.set_uniform(RenderResources.uPbr, &surface.pbr, 1);
		bgfx.set_texture(4, RenderResources.sNormalMap, Assets.GetTexture(surface.normalMap, .Normal), uint32.MaxValue);
		bgfx.set_texture(5, RenderResources.sMetalRoughMap, Assets.GetTexture(surface.metalRoughMap, .Data), uint32.MaxValue);
		bgfx.set_texture(6, RenderResources.sOcclusionMap, Assets.GetTexture(surface.occlusionMap, .Data), uint32.MaxValue);
		bgfx.set_texture(7, RenderResources.sEmissiveMap, Assets.GetTexture(surface.emissiveMap), uint32.MaxValue);
	}

	/// Each particle system is one instanced draw of its mesh.
	void SubmitParticles(uint16 view, Scene scene, Frustum frustum)
	{
		let stride = (uint16)sizeof(InstanceData);
		for (let system in scene.Particles)
		{
			if (!system.IsActiveAndEnabled || system.AliveCount == 0 || !system.GameObject.InActiveWorld || HidesHere(system.GameObject))
				continue;
			let mesh = Assets.GetMesh(system.mesh);
			if (mesh == null || !mesh.HasGpuData || !frustum.Intersects(system.WorldBounds))
				continue;
			let count = Math.Min(system.AliveCount, (int32)bgfx.get_avail_instance_data_buffer((uint32)system.AliveCount, stride));
			if (count <= 0)
				continue;
			bgfx.InstanceDataBuffer buffer = default;
			bgfx.alloc_instance_data_buffer(&buffer, (uint32)count, stride);
			system.WriteInstances((Matrix4*)buffer.data, count, (int32)stride);

			bgfx.set_vertex_buffer(0, mesh.VertexBuffer, 0, (uint32)mesh.VertexCount);
			bgfx.set_index_buffer(mesh.IndexBuffer, 0, (uint32)mesh.IndexCount);
			bgfx.set_instance_data_buffer(&buffer, 0, (uint32)count);
			SetFrameUniforms();
			let lightGrid = LightGridAt(system.WorldBounds.Center);
			if (lightGrid > 0)
				LightProbes.Bind(mProbeGrid, lightGrid);
			Vector4 material = .(0, 0.9f, 1, system.unlit ? 1 : 0);
			Vector4 emissive = .(0, 0, 0, 0);
			Vector4 bakedTransform = .(1, 1, 0, 0), bakedDecode = .(1, 0, 0, 0);
			bgfx.set_uniform(RenderResources.uLightmapTransform, &bakedTransform, 1);
			bgfx.set_uniform(RenderResources.uLightmapDecode, &bakedDecode, 1);
			bgfx.set_texture(8, RenderResources.sLightmap, Gfx.WhiteTexture, uint32.MaxValue);
			bgfx.set_texture(9, RenderResources.sLightmapDirection, Gfx.WhiteTexture, uint32.MaxValue);
			bgfx.set_texture(10, RenderResources.sLightmapShadowmask, Gfx.WhiteTexture, uint32.MaxValue);
			bgfx.set_uniform(RenderResources.uMaterial, &material, 1);
			bgfx.set_uniform(RenderResources.uEmissive, &emissive, 1);
			Vector4 uvTransform = .(1, 1, 0, 0);
			Vector4 surface = .(0, Time.RealTime, 0, 0);
			Vector4[ShaderAsset.MaxValues] values = default;
			bgfx.set_uniform(RenderResources.uUvTransform, &uvTransform, 1);
			bgfx.set_uniform(RenderResources.uSurface, &surface, 1);
			bgfx.set_uniform(RenderResources.uParams, &values, ShaderAsset.MaxValues);
			bgfx.set_texture(2, RenderResources.sTexture1, Gfx.WhiteTexture, uint32.MaxValue);
			bgfx.set_texture(3, RenderResources.sTexture2, Gfx.WhiteTexture, uint32.MaxValue);
			Vector4 pbr = .(0, 0, 0, 0);
			bgfx.set_uniform(RenderResources.uPbr, &pbr, 1);
			for (uint8 stage = 4; stage < 8; stage++)
				bgfx.set_texture(stage, stage == 4 ? RenderResources.sNormalMap : (stage == 5 ? RenderResources.sMetalRoughMap : (stage == 6 ? RenderResources.sOcclusionMap : RenderResources.sEmissiveMap)), Gfx.WhiteTexture, uint32.MaxValue);
			bgfx.set_texture(0, RenderResources.sAlbedo, Gfx.WhiteTexture, uint32.MaxValue);
			bgfx.set_texture(1, RenderResources.sShadowMap, RenderResources.ShadowMap, uint32.MaxValue);
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | Gfx.StateCullCcw | Gfx.StateMsaa, 0);
			bgfx.submit(view, RenderResources.MeshProgram, 0, 0xff);
			DrawCalls++;
			Instances += count;
			Triangles += count * mesh.IndexCount / 3;
		}
	}

	/// What the shadow and depth passes need to bend a draw in the wind as the lit pass does: the wind, the time and
	/// how far this draw sways.
	void SetWindUniforms(float amount)
	{
		Vector4 sway = .(amount, 0, 0, 0);
		Vector4 surface = .(0, Time.RealTime, 0, 0);
		bgfx.set_uniform(RenderResources.uSway, &sway, 1);
		bgfx.set_uniform(RenderResources.uSurface, &surface, 1);
		bgfx.set_uniform(RenderResources.uWind, &mWind, 1);
		bgfx.set_uniform(RenderResources.uWindZone, &mWindZone, 4);
		bgfx.set_uniform(RenderResources.uWindPush, &mWindPush, 4);
		bgfx.set_uniform(RenderResources.uBender, &mBender, 8);
		bgfx.set_uniform(RenderResources.uBenderPush, &mBenderPush, 8);
	}

	void SetFrameUniforms()
	{
		bgfx.set_uniform(RenderResources.uCamPos, &mCamPos, 1);
		bgfx.set_uniform(RenderResources.uSunDir, &mSunDir, 1);
		bgfx.set_uniform(RenderResources.uSunColor, &mSunColor, 1);
		bgfx.set_uniform(RenderResources.uAmbientSky, &mAmbientSky, 1);
		bgfx.set_uniform(RenderResources.uAmbientGround, &mAmbientGround, 1);
		bgfx.set_uniform(RenderResources.uFogColor, &mFogColor, 1);
		bgfx.set_uniform(RenderResources.uWind, &mWind, 1);
		bgfx.set_uniform(RenderResources.uWindZone, &mWindZone, 4);
		bgfx.set_uniform(RenderResources.uWindPush, &mWindPush, 4);
		bgfx.set_uniform(RenderResources.uBender, &mBender, 8);
		bgfx.set_uniform(RenderResources.uBenderPush, &mBenderPush, 8);
		bgfx.set_uniform(RenderResources.uLightCount, &mLightCount, 1);
		bgfx.set_uniform(RenderResources.uClusterViewProj, &mClusterViewProj, 1);
		bgfx.set_uniform(RenderResources.uClusterForward, &mClusterForward, 1);
		bgfx.set_uniform(RenderResources.uClusterParams, &mClusterParams, 1);
		bgfx.set_texture(15, RenderResources.sLightData, mLights.Texture, uint32.MaxValue);
		bgfx.set_texture(11, RenderResources.sLocalShadowMap, RenderResources.LocalShadowTexture, uint32.MaxValue);
		bgfx.set_uniform(RenderResources.uShadowMtx, &mShadowMtx, RenderResources.CascadeCount);
		bgfx.set_uniform(RenderResources.uCascadeSplits, &mCascadeSplits, 1);
		bgfx.set_uniform(RenderResources.uShadowParams, &mShadowParams, 1);
		Reflections.Bind(-1, mReflectionIntensity, mCubeAmbient);
		LightProbes.Bind(mProbeGrid);
	}

	void SubmitSky(uint16 view, SceneEnvironment env)
	{
		var zenith = Linear(env.skyZenith);
		var horizon = Linear(env.skyHorizon);
		var ground = Linear(env.skyGround);
		bgfx.set_uniform(RenderResources.uCamPos, &mCamPos, 1);
		bgfx.set_uniform(RenderResources.uSunDir, &mSunDir, 1);
		bgfx.set_uniform(RenderResources.uSunColor, &mSunColor, 1);
		bgfx.set_uniform(RenderResources.uSkyZenith, &zenith, 1);
		bgfx.set_uniform(RenderResources.uSkyHorizon, &horizon, 1);
		bgfx.set_uniform(RenderResources.uSkyGround, &ground, 1);
		SubmitFullscreen(view, RenderResources.SkyProgram, Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateDepthLequal | Gfx.StateMsaa);
	}

	void SubmitFullscreen(uint16 view, bgfx.ProgramHandle program, uint64 state)
	{
		if (bgfx.get_avail_transient_vertex_buffer(3, &Gfx.ScreenLayout) < 3)
			return;
		bgfx.TransientVertexBuffer buffer = default;
		bgfx.alloc_transient_vertex_buffer(&buffer, 3, &Gfx.ScreenLayout);
		let vertices = (ScreenVertex*)buffer.data;
		// One oversized triangle covering the viewport; UV origin follows the backend's texture origin.
		let top = Gfx.OriginBottomLeft ? 1.0f : 0.0f;
		let bottom = Gfx.OriginBottomLeft ? 0.0f : 1.0f;
		vertices[0].position = .(-1, -1, 0);
		vertices[0].uv = .(0, bottom);
		vertices[1].position = .(-1, 3, 0);
		vertices[1].uv = .(0, bottom + (top - bottom) * 2.0f);
		vertices[2].position = .(3, -1, 0);
		vertices[2].uv = .(2, bottom);
		bgfx.set_transient_vertex_buffer(0, &buffer, 0, 3);
		bgfx.set_state(state, 0);
		bgfx.submit(view, program, 0, 0xff);
	}

	/// Draws a batch as line segments, or as unculled triangles that test depth without writing it (or, on top, over
	/// everything).
	void SubmitLines(uint16 view, LineBatch batch, bool triangles = false, bool onTop = false)
	{
		let count = (uint32)batch.Vertices.Count;
		if (count == 0)
			return;
		var available = bgfx.get_avail_transient_vertex_buffer(count, &Gfx.LineLayout);
		available -= available % (triangles ? 3 : 2);
		if (available == 0)
			return;
		bgfx.TransientVertexBuffer buffer = default;
		bgfx.alloc_transient_vertex_buffer(&buffer, available, &Gfx.LineLayout);
		Internal.MemCpy(buffer.data, batch.Vertices.Ptr, (int)available * sizeof(LineVertex));
		bgfx.set_transient_vertex_buffer(0, &buffer, 0, available);
		bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | (onTop ? 0 : Gfx.StateDepthLequal) | (triangles ? 0 : Gfx.StateLines) | Gfx.StateMsaa | Gfx.StateBlendAlpha, 0);
		bgfx.submit(view, RenderResources.LineProgram, 0, 0xff);
	}
}
