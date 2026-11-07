using System;
using System.Collections;

namespace Tallow;

/// Environment settings saved with a scene: ambient light, sky and fog.
class SceneEnvironment
{
	/// The sky's colour straight up.
	public Color skyZenith = .(0.16f, 0.36f, 0.72f);
	/// The sky's colour at the horizon.
	public Color skyHorizon = .(0.62f, 0.76f, 0.90f);
	/// The colour below the horizon, where there is no ground to see.
	public Color skyGround = .(0.28f, 0.27f, 0.26f);
	/// The light from the sky on surfaces facing up, on top of the lights.
	public Color ambientSky = .(0.42f, 0.50f, 0.62f);
	/// The light from below on surfaces facing down.
	public Color ambientGround = .(0.22f, 0.20f, 0.18f);
	/// How strong the ambient light is.
	public float ambientIntensity = 0.55f;
	/// The colour things fade to in the distance.
	public Color fogColor = .(0.62f, 0.76f, 0.90f);
	/// How thick the fog is: about how much of the view it takes per metre. 0 is no fog.
	public float fogDensity = 0.004f;
	/// How bright the whole picture is: 1 is as lit, above 1 brighter.
	public float exposure = 1.0f;
	/// Glow around bright things (lights, emissive surfaces, the sun on pale walls). 0 is off; 0.3 to 0.6 is
	/// gentle; above 1 is heavy.
	public float bloom = 0.0f;
	/// How bright something must be before it glows. 1 is the brightest a surface gets from light alone, so at 1
	/// only emissive and over-bright things bloom.
	public float bloomThreshold = 1.0f;
	/// How far from the camera the sun's shadows are drawn, in metres. Shorter is sharper.
	public float shadowDistance = 120.0f;
	/// How strongly surfaces mirror the sky and the reflection probes (docs/reflections.md): 1 as they are, 0 none.
	public float reflectionIntensity = 1;
	/// Ambient light from what is around instead of the two ambient colours: the sky, and inside a reflection probe's
	/// box the room it captured (image-based lighting, docs/reflections.md). Ambient Intensity still scales it.
	/// Lightmapped surfaces keep their lightmaps.
	public bool ambientFromSurroundings;
	/// Baked light probes (docs/baked-lighting.md): the `.tprobes` file the editor's Lighting window writes, which
	/// gives moving things and surfaces without a lightmap the light bounced round the scene. Empty: the two ambient
	/// colours.
	public String lightProbes = new .() ~ delete _;
	/// How the editor's Lighting window bakes this scene (docs/baked-lighting.md): lightmap texels per metre, rays per
	/// texel, bounces, and the light probes and how far apart they are.
	public float bakeTexelsPerMetre = 8;
	public int32 bakeSamples = 256;
	public int32 bakeBounces = 3;
	public bool bakeProbes = true;
	public float bakeProbeSpacing = 3;

	// ---- Screen effects (docs/post-processing.md). All off by default; colour grading's defaults leave the picture
	// as it always was. ----

	/// Ambient occlusion: darkens creases, corners and where things meet the ground. 0 is off; 1 is normal; up to 2.
	public float ambientOcclusion = 0;
	/// How far around each point, in metres, is looked at for what hides it from the open air.
	public float occlusionRadius = 0.6f;

	/// Depth of field: blurs what is nearer or further than the focus. 0 is off; 1 is the largest blur, a circle 3% of
	/// the screen's height across (its radius is DepthOfFieldReach); up to 2.
	public float depthOfField = 0;
	/// The distance, in metres from the camera, that is sharp.
	public float focusDistance = 10;
	/// How deep the sharp band around the focus is, in metres: sharp within half of it either side, fully blurred a
	/// whole range beyond that.
	public float focusRange = 8;
	/// Focus on whatever is in the middle of the screen instead of Focus Distance.
	public bool autoFocus;

	/// Camera motion blur: a smear along the way the picture moves when the camera turns or moves. 0 is off; 0.5 is
	/// like a film camera; 1 is the whole movement of a frame. The viewmodel is never blurred.
	public float motionBlur = 0;

	/// Colour grading, applied with the tonemapping. Contrast and saturation: 1 leaves the picture alone.
	public float contrast = 1;
	/// How strong colours are: 0 is grey, 1 as they are, above 1 stronger.
	public float saturation = 1.05f;
	/// White balance: above 0 warmer (more orange), below 0 cooler (more blue). -1 to 1.
	public float temperature = 0;
	/// Above 0 towards magenta, below 0 towards green. -1 to 1.
	public float tint = 0;
	/// Multiplies the light of the whole picture: a coloured filter on the lens.
	public Color colorFilter = .(1, 1, 1);
	/// Darkening towards the corners.
	public float vignette = 0.35f;
	/// A colour lookup table image (a strip of squares, made with the editor's Make Neutral Lookup Table and
	/// recoloured in any image editor), or empty for none.
	public String colorLookup = new .() ~ delete _;
	/// How much of the lookup table is used: 0 none, 1 all of it.
	public float colorLookupStrength = 1;

	/// World streaming (docs/world-streaming.md): the scene is saved as a grid of cells, each in a file of its own,
	/// and only the cells near a Streaming Source (or a camera) are loaded.
	public bool streaming;
	/// A cell's width and depth in metres.
	public float streamCellSize = 64;
	/// Cells this close to a source are loaded (and unloaded half a cell further out).
	public float streamLoadRadius = 160;
	/// Cells this close that are not loaded show their merged, simpler stand-in.
	public float streamStandInRadius = 800;
	/// Floating origin: when the first source is this far from the centre, the world is moved back round it, keeping
	/// precision far out. 0: never. Not used in a network session.
	public float floatingOrigin = 0;

	/// The radius of the depth of field's largest blur as a share of the screen's height, at Depth Of Field 1.
	public const float DepthOfFieldReach = 0.015f;

	/// Whether the scene needs the depth pass (ambient occlusion, depth of field or motion blur).
	public bool UsesDepthEffects => ambientOcclusion > 0.001f || depthOfField > 0.001f || motionBlur > 0.001f;

	/// How blurred something at `depth` metres is, 0 (sharp) to 1, with the focus at `focus` metres: the shader's sum.
	public float BlurAmount(float depth, float focus)
	{
		if (depth < 0)
			return 0;
		let range = Math.Max(focusRange, 0.01f);
		return Math.Clamp((Math.Abs(depth - focus) - range * 0.5f) / range, 0.0f, 1.0f);
	}

	/// Puts every setting back to how a new scene has it.
	public void Reset()
	{
		let fresh = scope SceneEnvironment();
		CopyFrom(fresh);
	}

	/// Takes every setting from another environment.
	public void CopyFrom(SceneEnvironment other)
	{
		skyZenith = other.skyZenith;
		skyHorizon = other.skyHorizon;
		skyGround = other.skyGround;
		ambientSky = other.ambientSky;
		ambientGround = other.ambientGround;
		ambientIntensity = other.ambientIntensity;
		fogColor = other.fogColor;
		fogDensity = other.fogDensity;
		exposure = other.exposure;
		bloom = other.bloom;
		bloomThreshold = other.bloomThreshold;
		shadowDistance = other.shadowDistance;
		reflectionIntensity = other.reflectionIntensity;
		ambientFromSurroundings = other.ambientFromSurroundings;
		ambientOcclusion = other.ambientOcclusion;
		occlusionRadius = other.occlusionRadius;
		depthOfField = other.depthOfField;
		focusDistance = other.focusDistance;
		focusRange = other.focusRange;
		autoFocus = other.autoFocus;
		motionBlur = other.motionBlur;
		contrast = other.contrast;
		saturation = other.saturation;
		temperature = other.temperature;
		tint = other.tint;
		colorFilter = other.colorFilter;
		vignette = other.vignette;
		colorLookup.Set(other.colorLookup);
		lightProbes.Set(other.lightProbes);
		bakeTexelsPerMetre = other.bakeTexelsPerMetre;
		bakeSamples = other.bakeSamples;
		bakeBounces = other.bakeBounces;
		bakeProbes = other.bakeProbes;
		bakeProbeSpacing = other.bakeProbeSpacing;
		colorLookupStrength = other.colorLookupStrength;
		streaming = other.streaming;
		streamCellSize = other.streamCellSize;
		streamLoadRadius = other.streamLoadRadius;
		streamStandInRadius = other.streamStandInRadius;
		floatingOrigin = other.floatingOrigin;
	}
}

/// A hierarchy of GameObjects plus the per-scene systems (rendering lists, physics).
class Scene
{
	/// The scene's name, from its file.
	public String Name = new .("Untitled") ~ delete _;
	/// The file the scene was loaded from, relative to the project's assets, or empty.
	public String Path = new .() ~ delete _;
	/// The scene's sky, lighting, fog and screen effects.
	public SceneEnvironment Environment = new .() ~ delete _;
	/// The ECS storage behind the scene's objects (docs/ecs-plan.md): one entity for each GameObject, parented with
	/// ChildOf as the objects are. Deleted after the objects (the destructor clears the scene first).
	public World World = new .() ~ delete _;

	List<GameObject> mRoots = new .() ~ delete _;
	List<GameObject> mObjects = new .() ~ delete _;
	Dictionary<uint32, GameObject> mById = new .() ~ delete _;
	List<Component> mComponents = new .() ~ delete _;
	/// The components whose class overrides each per-frame callback (ScriptCallbacks), in the order they joined.
	/// The update loops go through these only.
	List<Component> mFixedList = new .() ~ delete _;
	/// Update or OnLocalUpdate.
	List<Component> mFrameList = new .() ~ delete _;
	List<Component> mLateList = new .() ~ delete _;
	List<Component> mOnFrameList = new .() ~ delete _;

	void AddToCallbackLists(Component component)
	{
		let callbacks = ScriptCallbackIndex.Of(component.GetType());
		component.[Friend]mCallbacks = callbacks;
		if (callbacks.HasFlag(.FixedUpdate))
			mFixedList.Add(component);
		if (callbacks.HasFlag(.Update) || callbacks.HasFlag(.OnLocalUpdate))
			mFrameList.Add(component);
		if (callbacks.HasFlag(.LateUpdate))
			mLateList.Add(component);
		if (callbacks.HasFlag(.OnFrame))
			mOnFrameList.Add(component);
	}

	/// After all script instances have been replaced, rebuild once in registration order. Adding a callback
	/// during hot reload must not move that script behind scripts registered after it.
	void RebuildCallbackLists()
	{
		mFixedList.Clear();
		mFrameList.Clear();
		mLateList.Clear();
		mOnFrameList.Clear();
		for (let component in mComponents)
			AddToCallbackLists(component);
	}

	void RemoveFromCallbackLists(Component component)
	{
		let callbacks = component.[Friend]mCallbacks;
		if (callbacks.HasFlag(.FixedUpdate))
			mFixedList.Remove(component);
		if (callbacks.HasFlag(.Update) || callbacks.HasFlag(.OnLocalUpdate))
			mFrameList.Remove(component);
		if (callbacks.HasFlag(.LateUpdate))
			mLateList.Remove(component);
		if (callbacks.HasFlag(.OnFrame))
			mOnFrameList.Remove(component);
	}

	List<Component> mPendingStart = new .() ~ delete _;
	List<GameObject> mDestroyQueue = new .() ~ delete _;
	uint32 mNextId = 1;
	/// How many objects are NetworkHidden (0: none, so nothing need look).
	int32 mNetworkHiddenCount;
	/// The id the next new object gets. A streamed world keeps it in its file, so objects made while some cells are
	/// not loaded never take the ids of objects in them.
	public uint32 NextId
	{
		get => mNextId;
		set
		{
			mNextId = Math.Max(mNextId, value);
		}
	}

	bool mPlaying;
	bool mClearing;
	NavigationCrowdIndex mNavigationCrowd ~ delete _;

	/// Where the scene's Navigation Agents stand, for steering round each other (made when the first one joins).
	public NavigationCrowdIndex NavigationCrowd
	{
		get
		{
			if (mNavigationCrowd == null)
				mNavigationCrowd = new .(this);
			return mNavigationCrowd;
		}
	}

	// Non-owning lists maintained by the components themselves in OnRegister / OnUnregister.
	Query<MeshRendererData, ObjectLink> mRendererQuery ~ delete _;
	List<RenderProxy> mRenderers = new .() ~ delete _;
	/// What the renderer draws: every switched-on Mesh Renderer's RenderProxy, its settings copied in from the
	/// entity as the list is made. Rebuilt each time it is read (once per view); keep it only for the frame.
	public List<RenderProxy> Renderers
	{
		get
		{
			mRenderers.Clear();
			if (mRendererQuery == null)
				mRendererQuery = new .(World, .Read, .Read);
			for (var chunk in mRendererQuery)
			{
				let settings = chunk.Read<MeshRendererData>();
				let links = chunk.Read<ObjectLink>();
				let entities = chunk.Entities;
				for (int i < chunk.Count)
				{
					let proxy = ComponentState<RenderProxy>.Make(World, entities[i]);
					proxy.[Friend]mGameObject = links[i].gameObject;
					proxy.data = settings[i];
					mRenderers.Add(proxy);
				}
			}
			return mRenderers;
		}
	}

	/// The query behind Components<T>() for each handle type, by its data's ComponentTypes index.
	Dictionary<int32, IndexQuery> mHandleQueries = new .() ~ DeleteDictionaryAndValues!(_);

	/// Every switched-on component of handle type T in the scene (Light, WindZone...), on active and inactive
	/// objects alike, in no set order. Straight from Flecs: a switched-off one is not visited at all.
	public void Components<T>(List<T> output) where T : struct, IComponentHandle
	{
		let index = T.DataIndex;
		IndexQuery query;
		if (!mHandleQueries.TryGetValue(index, out query))
		{
			int32[2] types = .(index, ComponentId<ObjectLink>.Index);
			Flecs.TermAccess[2] access = .(.Filter, .Read);
			query = new IndexQuery(World, types, access);
			mHandleQueries[index] = query;
		}
		for (var chunk in query)
		{
			for (let link in chunk.Read<ObjectLink>())
			{
				output.Add(link.gameObject.[Friend]MakeHandle<T>());
			}
		}
	}

	/// Every component of handle type T in the scene, switched on or not, as FindComponents does for a script.
	public void FindComponents<T>(List<T> output) where T : struct, IComponentHandle => AllComponents(output);

	/// The first component of handle type T in the scene, switched on or not; not valid if there is none.
	public T FindComponent<T>() where T : struct, IComponentHandle
	{
		for (let gameObject in mObjects)
		{
			if (gameObject.HasComponent<T>())
				return gameObject.GetComponent<T>();
		}
		return default;
	}

	/// Every component of handle type T in the scene, switched on or not.
	public void AllComponents<T>(List<T> output) where T : struct, IComponentHandle
	{
		for (let gameObject in mObjects)
		{
			if (gameObject.HasComponent<T>())
				output.Add(gameObject.GetComponent<T>());
		}
	}

	List<Light> mLights = new .() ~ delete _;
	List<Light> mAllLights = new .() ~ delete _;

	/// The scene's switched-on lights (Light.enabled), on active and inactive objects alike, in no set order. Rebuilt
	/// each time it is read; keep the list only until the scene changes.
	public List<Light> Lights
	{
		get
		{
			mLights.Clear();
			Components(mLights);
			return mLights;
		}
	}

	/// Every light, switched on or not (network sync).
	public List<Light> AllLights
	{
		get
		{
			mAllLights.Clear();
			AllComponents(mAllLights);
			return mAllLights;
		}
	}

	/// Every Camera in the scene.
	List<Camera> mCameras = new .() ~ delete _;
	/// The scene's switched-on cameras, oldest object first. Rebuilt each time it is read.
	public List<Camera> Cameras
	{
		get
		{
			mCameras.Clear();
			Components(mCameras);
			mCameras.Sort(scope (a, b) => a.GameObject.Id <=> b.GameObject.Id);
			return mCameras;
		}
	}

	/// The scene's world streaming, once it has used it (WorldStreaming.Of).
	public WorldStreamer Streamer ~ delete _;
	// Kept as the entity, which Flecs can tell is gone, rather than the object, which would dangle.
	Entity mCameraOverride;
	/// When set (and active), the camera the game is seen through instead of the first one: a cutscene's. Not
	/// valid once its object or component is gone.
	public Camera CameraOverride
	{
		get
		{
			if (mCameraOverride.IsNull || !World.IsAlive(mCameraOverride))
				return default;
			let link = World.Get<ObjectLink>(mCameraOverride);
			return link != null && link.gameObject != null ? link.gameObject.GetComponent<Camera>() : default;
		}
		set
		{
			mCameraOverride = value.GameObject != null ? value.GameObject.Entity : default;
		}
	}

	/// The camera the game is seen through: CameraOverride when it is active, otherwise the first active camera (of
	/// the oldest object); not valid if there is none.
	public Camera ViewCamera
	{
		get
		{
			let cameraOverride = CameraOverride;
			if (cameraOverride && cameraOverride.IsActiveAndEnabled)
				return cameraOverride;
			Camera best = default;
			for (let camera in Components<Camera>(.. scope .()))
			{
				if (camera.GameObject.ActiveInHierarchy && (best.GameObject == null || camera.GameObject.Id < best.GameObject.Id))
					best = camera;
			}
			return best;
		}
	}

	/// Every Particle System in the scene.
	List<ParticleState> mParticles = new .() ~ delete _;
	/// Every switched-on Particle System's particles, with its settings copied in (from one query, each call).
	public List<ParticleState> Particles
	{
		get
		{
			mParticles.Clear();
			for (let system in Components<ParticleSystem>(.. scope .()))
				mParticles.Add(system.State);
			return mParticles;
		}
	}

	/// The decals made by Decals.Spawn, oldest first. Their texture strings are owned here.
	public List<SpawnedDecal> SpawnedDecals = new .() ~ { for (let decal in _) delete decal.texture; delete _; };

	/// Every registered component under its class and each class above it (down to Component), in the order they
	/// were registered: FindComponent and ComponentsOfType look here instead of at every component in the scene.
	Dictionary<Type, List<Component>> mByType = new .() ~ DeleteDictionaryAndValues!(_);
	static List<Component> sNoComponents = new .() ~ delete _;

	/// The scene's physics: bodies, rays and shape queries (made when play starts).
	public PhysicsWorld Physics ~ delete _;
	/// Set while a multiplayer session is running (see NetworkManager).
	public NetworkManager Network ~ delete _;

	/// The scene gameplay code is running in.
	public static Scene Active;
	/// Seconds since the current spawn start phase began, and whether it was closed early. See SpawnPoints.
	public float SpawnPhaseTime;
	/// Whether the spawn start phase was closed early. See SpawnPoints.
	public bool SpawnStartOver;

	Dictionary<String, List<GameObject>> mTagged = new .() ~
		{
			for (let entry in _)
			{
				delete entry.key;
				delete entry.value;
			}
			delete _;
		};
	int32 mWorldState;

	/// Called when the active world state changes, with the state before and the state now.
	public Event<delegate void(int32 from, int32 to)> WorldStateChanged ~ _.Dispose();

	/// The active world state (an index into ProjectConfig.WorldStates). Objects that are not part of it are not
	/// drawn, do not collide, are not heard and are not walked on. Setting it switches all of that in one go.
	public int32 WorldState
	{
		get => mWorldState;
		set
		{
			let state = Math.Clamp(value, 0, ProjectConfig.MaxWorldStates - 1);
			if (state == mWorldState)
				return;
			let previous = mWorldState;
			mWorldState = state;
			Physics.ApplyWorldState(this);
			WorldStateChanged(previous, state);
		}
	}

	/// The same by name; false when the project has no world state of that name.
	public bool SetWorldState(StringView name)
	{
		let state = ProjectConfig.WorldStateNamed(name);
		if (state < 0)
			return false;
		WorldState = state;
		return true;
	}

	void WorldMembershipChanged(GameObject gameObject)
	{
		Physics.ApplyWorldState(gameObject);
	}

	void IndexTag(GameObject gameObject, StringView tag, bool add)
	{
		if (add)
		{
			List<GameObject> list;
			if (!mTagged.TryGetValueAlt(tag, out list))
			{
				list = new .();
				mTagged[new String(tag)] = list;
			}
			list.Add(gameObject);
		}
		else if (mTagged.TryGetValueAlt(tag, let list))
			list.Remove(gameObject);
	}

	/// The first object with that tag that is active, or null. Fast: tagged objects are kept in lists by tag.
	public GameObject FindWithTag(StringView tag)
	{
		if (mTagged.TryGetValueAlt(tag, let list))
		{
			for (let gameObject in list)
			{
				if (!gameObject.IsDestroyed && gameObject.ActiveInHierarchy)
					return gameObject;
			}
		}
		return null;
	}

	/// Adds every object with that tag (active or not) to the list.
	public void FindAllWithTag(StringView tag, List<GameObject> found)
	{
		if (mTagged.TryGetValueAlt(tag, let list))
		{
			for (let gameObject in list)
			{
				if (!gameObject.IsDestroyed)
					found.Add(gameObject);
			}
		}
	}

	/// The objects at the top of the hierarchy, in Hierarchy order.
	public List<GameObject> Roots => mRoots;
	/// Every object in the scene, at every level.
	public List<GameObject> Objects => mObjects;
	/// Every component in the scene. To find those of one class, ComponentsOfType and FindComponents are much faster
	/// than looking through this.
	public List<Component> Components => mComponents;
	/// Whether the scene is playing (components get Awake, Start, Update...), not just open in the editor.
	public bool IsPlaying => mPlaying;

	/// An empty scene. SceneManager loads scene files into one.
	public this()
	{
		Physics = new PhysicsWorld();
		AddSteps();
	}

	public ~this()
	{
		if (Active == this)
			Active = null;
		Network?.Stop();
		Clear();
		if (Active == this)
			Active = null;
	}

	/// Removes every object. Components are unregistered without gameplay callbacks.
	public void Clear()
	{
		// Stop callbacks while all referenced objects still exist, then clear borrowed links once: clearing them
		// object by object would make unloading a whole level quadratic.
		let wasPlaying = mPlaying;
		if (wasPlaying)
			StopPlay();
		mClearing = true;
		defer
		{
			mClearing = false;
			mPlaying = wasPlaying;
		}
		for (let slot in mReferenceSlots)
			*slot.field = null;
		mReferenceSlots.Clear();
		for (let entry in mReferenceLists)
			FieldLists.ClearReferences(entry.field, scope (value) => true);
		mReferenceLists.Clear();
		while (mRoots.Count > 0)
			DestroyTogether(scope List<GameObject>()..AddRange(mRoots));
		mDestroyQueue.Clear();
		mPendingStart.Clear();
		mNextId = 1;
		Decals.Clear(this);
	}

	/// Makes an empty object (with only a Transform), at the top of the scene or under a parent.
	public GameObject CreateGameObject(StringView name, Transform parent = null)
	{
		return CreateGameObjectWithId(name, 0, parent);
	}

	/// Makes an empty object with a given id, or the next free one if that id is 0 or taken. Loading a scene uses it to
	/// keep saved ids.
	public GameObject CreateGameObjectWithId(StringView name, uint32 id, Transform parent = null)
	{
		let gameObject = new GameObject(name);
		var useId = id;
		if (useId == 0 || mById.ContainsKey(useId))
			useId = mNextId;
		mNextId = Math.Max(mNextId, useId + 1);
		gameObject.Id = useId;
		gameObject.[Friend]mScene = this;
		let entity = World.Create();
		World.Set<ObjectLink>(entity, .() { gameObject = gameObject });
		gameObject.[Friend]mEntity = entity;
		gameObject.Transform.[Friend]Bind(World, entity);
		mObjects.Add(gameObject);
		mById[useId] = gameObject;
		mRoots.Add(gameObject);
		if (parent != null)
			gameObject.Transform.SetParent(parent, false);
		return gameObject;
	}

	/// The object with an id, or null.
	public GameObject FindById(uint32 id)
	{
		if (mById.TryGetValue(id, let gameObject))
			return gameObject;
		return null;
	}

	/// The first object with a name, or null. It looks through every object, so keep what it finds rather than calling
	/// it every frame.
	public GameObject Find(StringView name)
	{
		for (let gameObject in mObjects)
		{
			if (gameObject.Name == name)
				return gameObject;
		}
		return null;
	}

	/// The first registered component of that class (or a class derived from it), or null.
	public T FindComponent<T>() where T : Component
	{
		let list = ComponentsOfType(typeof(T));
		return list.IsEmpty ? null : (T)list[0];
	}

	/// Every registered component of that class or one derived from it, in registration order. Do not add or remove
	/// components while going through the list.
	public List<Component> ComponentsOfType(Type type)
	{
		if (mByType.TryGetValue(type, let list))
			return list;
		// A built-in component is not a Component class, so it is never in this list: say so once rather than
		// let a script that was written before it became a handle find nothing without a word.
		if (type.IsValueType && !sWarnedHandleTypes.Contains(type) && HandleComponents.Find(type) != null)
		{
			sWarnedHandleTypes.Add(type);
			Log.Warning(scope $"ComponentsOfType({type.GetName(.. scope .())}) finds nothing: it is a built-in component. Use scene.Components<{type.GetName(.. scope .())}>() (or FindComponents) instead.");
		}
		return sNoComponents;
	}

	static HashSet<Type> sWarnedHandleTypes = new .() ~ delete _;

	/// Adds every registered component of that class (or one derived from it) to the list.
	public void FindComponents<T>(List<T> found) where T : Component
	{
		for (let component in ComponentsOfType(typeof(T)))
			found.Add((T)component);
	}

	/// A field of a registered component that refers to another object (GameObject, Transform or component). Such
	/// references do not own what they point at, so they are cleared when it is destroyed.
	struct ReferenceSlot
	{
		public Component owner;
		public Object* field;
	}

	/// Every reference field of every registered component, kept up to date as components come and go, so that
	/// destroying an object does not have to look through every component's fields to find what points at it.
	List<ReferenceSlot> mReferenceSlots = new .() ~ delete _;
	/// List and array fields of references (their elements move when they are resized, so they are looked through
	/// whole when an object goes).
	List<(Component owner, FieldRef field)> mReferenceLists = new .() ~ delete _;

	void AddReferenceSlots(Component component)
	{
		List<FieldRef> fields = scope .();
		ComponentRegistry.GetFields(component, fields);
		for (let field in fields)
		{
			if ((field.kind == .List || field.kind == .Array) && field.elementKind == .ObjectReference)
				mReferenceLists.Add((component, field));
			// An ObjectRef is an id looked up on use: nothing to clear.
			if (field.kind != .ObjectReference || ObjectRefs.Is(field.type))
				continue;
			ReferenceSlot slot;
			slot.owner = component;
			slot.field = (Object*)field.ptr;
			mReferenceSlots.Add(slot);
		}
	}

	void RemoveReferenceSlots(Component component)
	{
		for (int i = mReferenceSlots.Count - 1; i >= 0; i--)
		{
			if (mReferenceSlots[i].owner == component)
				mReferenceSlots.RemoveAtFast(i);
		}
		for (int i = mReferenceLists.Count - 1; i >= 0; i--)
		{
			if (mReferenceLists[i].owner == component)
				mReferenceLists.RemoveAtFast(i);
		}
	}

	/// The object a reference field's value belongs to (see ComponentRegistry.ReferenceOwner).
	static GameObject OwnerOf(Object value)
	{
		if (value == null)
			return null;
		if (let gameObject = value as GameObject)
			return gameObject;
		if (let transform = value as Transform)
			return transform.GameObject;
		if (let component = value as Component)
			return component.GameObject;
		return null;
	}

	void IndexComponent(Component component, bool add)
	{
		var type = component.GetType();
		while (type != null && type != typeof(Component))
		{
			if (add)
			{
				if (!mByType.TryGetValue(type, var list))
				{
					list = new List<Component>();
					mByType[type] = list;
				}
				list.Add(component);
			}
			else if (mByType.TryGetValue(type, let list))
			{
				list.Remove(component);
			}
			type = type.BaseType;
		}
	}

	/// Script reload: a component of a reloaded class takes the place of the old one in every list.
	void ReplaceComponent(Component old, Component replacement)
	{
		let index = mComponents.IndexOf(old);
		if (index >= 0)
			mComponents[index] = replacement;
		// Migration rebuilds membership in registration order once all replacements are installed. Until then,
		// replace references in place; no callback can retain the retired instance.
		replacement.[Friend]mCallbacks = old.[Friend]mCallbacks;
		for (let list in scope List<Component>[](mFixedList, mFrameList, mLateList, mOnFrameList))
		{
			let at = list.IndexOf(old);
			if (at >= 0)
				list[at] = replacement;
		}
		let pending = mPendingStart.IndexOf(old);
		if (pending >= 0)
			mPendingStart[pending] = replacement;
		let deferred = mDeferredStart.IndexOf(old);
		if (deferred >= 0)
			mDeferredStart[deferred] = replacement;
		// Take the old one's place in its classes' lists, keeping their order. The new class may sit under classes
		// the old one did not: there it goes in by its place in the scene.
		var type = replacement.GetType();
		while (type != null && type != typeof(Component))
		{
			if (!mByType.TryGetValue(type, var list))
			{
				list = new List<Component>();
				mByType[type] = list;
			}
			let at = list.IndexOf(old);
			if (at >= 0)
			{
				list[at] = replacement;
			}
			else
			{
				int insertAt = 0;
				while (insertAt < list.Count && mComponents.IndexOf(list[insertAt]) < index)
					insertAt++;
				list.Insert(insertAt, replacement);
			}
			type = type.BaseType;
		}
		// And leave those it is no longer under.
		for (let list in mByType.Values)
			list.Remove(old);
		RemoveReferenceSlots(old);
		AddReferenceSlots(replacement);
	}

	/// Queues an object (and its children) for destruction at the end of the frame.
	public void Destroy(GameObject gameObject)
	{
		if (gameObject == null || gameObject.IsDestroyed)
			return;
		// In multiplayer the server decides what happens to shared objects, and tells the clients.
		if (Network != null && !Network.AllowDestroy(gameObject))
			return;
		gameObject.[Friend]mDestroyed = true;
		mDestroyQueue.Add(gameObject);
	}

	/// Destroys an object right now. Prefer Destroy from gameplay code.
	public void DestroyImmediate(GameObject gameObject)
	{
		if (mGoing == null && CountUpTo(gameObject, SweepFrom) < SweepFrom)
		{
			UnregisterTree(gameObject, false);
			DestroyTree(gameObject);
		}
		else
			DestroyTogether(scope List<GameObject>() { gameObject });
	}

	/// From this many objects going at once, one sweep of the scene's lists beats taking each out of them.
	const int SweepFrom = 5;

	/// How many objects a tree holds, not counting further than `limit`.
	static int CountUpTo(GameObject gameObject, int limit)
	{
		int count = 1;
		for (let child in gameObject.Transform.Children)
		{
			count += CountUpTo(child.GameObject, limit - count);
			if (count >= limit)
				break;
		}
		return count;
	}

	/// Destroys several objects right now, in far less time than one by one.
	public void DestroyImmediate(List<GameObject> objects)
	{
		DestroyTogether(objects);
	}

	/// Objects going together. Their components hear it first, before any object is freed, so that one can still look
	/// at the others in OnUnregister (IK putting back the bones under it, say). Then what they leave behind in the
	/// scene's lists is swept out in one pass, so that the cost does not grow with objects times scene size.
	void DestroyTogether(List<GameObject> objects)
	{
		// From an OnDestroy while a batch is going: it joins that batch, and is freed with it.
		if (mGoing != null)
		{
			for (let gameObject in objects)
			{
				if (!gameObject.[Friend]mGoing)
				{
					UnregisterTree(gameObject, true);
					mGoing.Add(gameObject);
				}
			}
			return;
		}
		let going = scope List<GameObject>();
		mGoing = going;
		for (int i < objects.Count)
		{
			let gameObject = objects[i];
			// Under something else in the batch: it goes with that.
			if (!gameObject.[Friend]mGoing)
			{
				UnregisterTree(gameObject, true);
				going.Add(gameObject);
			}
		}
		Sweep();
		mGoing = null;
		for (int i < going.Count)
		{
			if (going[i].[Friend]mGoing)
				DestroyTree(going[i]);
		}
	}

	void UnregisterTree(GameObject gameObject, bool together)
	{
		gameObject.[Friend]mGoing = together;
		let children = gameObject.Transform.Children;
		for (int i = children.Count - 1; i >= 0; i--)
		{
			if (i < children.Count)
				UnregisterTree(children[i].GameObject, together);
		}
		for (int i = gameObject.Components.Count - 1; i >= 0; i--)
		{
			if (i < gameObject.Components.Count)
				UnregisterComponent(gameObject.Components[i], together);
		}
	}

	static void Keep(List<Component> list)
	{
		int kept = 0;
		for (int i < list.Count)
		{
			let component = list[i];
			if (component.[Friend]mRegistered)
				list[kept++] = component;
		}
		list.Count = kept;
	}

	static void Keep(List<GameObject> list)
	{
		int kept = 0;
		for (int i < list.Count)
		{
			let gameObject = list[i];
			if (!gameObject.[Friend]mGoing)
				list[kept++] = gameObject;
		}
		list.Count = kept;
	}

	/// Takes every component and object of the batch out of the scene's lists, keeping the order of the rest.
	void Sweep()
	{
		Keep(mComponents);
		Keep(mFixedList);
		Keep(mFrameList);
		Keep(mLateList);
		Keep(mOnFrameList);
		for (let type in mSweptTypes)
		{
			if (mByType.TryGetValue(type, let list))
				Keep(list);
		}
		mSweptTypes.Clear();
		if (mRunningStarts)
		{
			// RunPendingStarts is going through the list: leave gaps rather than move what it has yet to reach.
			for (int i < mPendingStart.Count)
			{
				let component = mPendingStart[i];
				if (component != null && !component.[Friend]mRegistered)
					mPendingStart[i] = null;
			}
		}
		else
			Keep(mPendingStart);
		Keep(mDeferredStart);
		Keep(mObjects);
		Keep(mRoots);
		if (mClearing)
			return;
		// Clear non-owning references before freeing their targets.
		for (int i = mReferenceSlots.Count - 1; i >= 0; i--)
		{
			let slot = mReferenceSlots[i];
			if (!slot.owner.[Friend]mRegistered)
			{
				// The component's own fields are about to be freed with it.
				mReferenceSlots.RemoveAtFast(i);
				continue;
			}
			let target = OwnerOf(*slot.field);
			if (target != null && target.[Friend]mGoing)
				*slot.field = null;
		}
		for (int i = mReferenceLists.Count - 1; i >= 0; i--)
		{
			let entry = mReferenceLists[i];
			if (!entry.owner.[Friend]mRegistered)
			{
				mReferenceLists.RemoveAtFast(i);
				continue;
			}
			FieldLists.ClearReferences(entry.field, scope (value) =>
				{
					let target = OwnerOf(value);
					return target != null && target.[Friend]mGoing;
				});
		}
	}

	void DestroyTree(GameObject gameObject)
	{
		// Added to the tree after the batch was swept, by a component going: the long way.
		let swept = gameObject.[Friend]mGoing;
		if (!mClearing && !swept)
		{
			for (let slot in mReferenceSlots)
			{
				if (OwnerOf(*slot.field) == gameObject)
					*slot.field = null;
			}
			for (let entry in mReferenceLists)
				FieldLists.ClearReferences(entry.field, scope (value) => OwnerOf(value) == gameObject);
		}
		gameObject.[Friend]mGoing = false;
		let transform = gameObject.Transform;
		while (transform.Children.Count > 0)
			DestroyTree(transform.Children.Back.GameObject);
		// Normally done already (UnregisterTree); this catches a component added from another's OnUnregister.
		for (int i = gameObject.Components.Count - 1; i >= 0; i--)
			UnregisterComponent(gameObject.Components[i]);

		if (transform.Parent != null)
		{
			let siblings = transform.Parent.Children;
			let index = siblings.LastIndexOf(transform);
			if (index >= 0)
				siblings.RemoveAt(index);
		}
		else if (!swept)
			mRoots.Remove(gameObject);
		if (!swept)
			mObjects.Remove(gameObject);
		mById.Remove(gameObject.Id);
		if (!mDestroyQueue.IsEmpty)
			mDestroyQueue.Remove(gameObject);
		for (int i < gameObject.TagCount)
			IndexTag(gameObject, gameObject.GetTag(i), false);
		// Children went first (above), so this never takes another object's entity with it.
		gameObject.Transform.[Friend]Unbind();
		// Destroyed now (DestroyImmediate does not set it), so its built-in components' OnRemove see IsGoing.
		gameObject.[Friend]mDestroyed = true;
		if (World.IsAlive(gameObject.Entity))
			World.Delete(gameObject.Entity);
		delete gameObject;
	}

	void RegisterComponent(Component component)
	{
		if (component.[Friend]mRegistered)
			return;
		component.[Friend]mOwnershipClosed = false;
		component.[Friend]mRegistered = true;
		mComponents.Add(component);
		AddToCallbackLists(component);
		IndexComponent(component, true);
		AddReferenceSlots(component);
		component.OnRegister();
		if (mPlaying)
			WakeComponent(component);
	}

	/// `together`: part of a batch, whose Sweep takes it out of the scene's lists.
	void UnregisterComponent(Component component, bool together = false)
	{
		if (!component.[Friend]mRegistered)
			return;
		if (mPlaying && component.IsAwake)
		{
			if (component.Enabled)
				component.OnDisable();
			component.OnDestroy();
		}
		if (together)
		{
			component.[Friend]mLeavingTogether = true;
			component.OnUnregister();
			component.[Friend]ReleaseOwned();
			component.[Friend]mLeavingTogether = false;
			component.[Friend]mRegistered = false;
			component.[Friend]mAwake = false;
			var type = component.GetType();
			while (type != null && type != typeof(Component))
			{
				mSweptTypes.Add(type);
				type = type.BaseType;
			}
			return;
		}
		if (!mClearing)
		{
			for (int i = mReferenceSlots.Count - 1; i >= 0; i--)
			{
				let slot = mReferenceSlots[i];
				if (*slot.field == component)
					*slot.field = null;
				// The component's own fields are about to be freed with it.
				if (slot.owner == component)
					mReferenceSlots.RemoveAtFast(i);
			}
		}
		component.OnUnregister();
		component.[Friend]ReleaseOwned();
		component.[Friend]mRegistered = false;
		component.[Friend]mAwake = false;
		mComponents.Remove(component);
		RemoveFromCallbackLists(component);
		IndexComponent(component, false);
		let pending = mPendingStart.IndexOf(component);
		if (pending >= 0)
		{
			// RunPendingStarts is going through the list: leave a gap rather than move what it has yet to reach.
			if (mRunningStarts)
				mPendingStart[pending] = null;
			else
				mPendingStart.RemoveAt(pending);
		}
		mDeferredStart.Remove(component);
	}

	/// A renderer leaving the scene.
	void WakeComponent(Component component)
	{
		if (component.IsAwake)
			return;
		component.[Friend]mOwnershipClosed = false;
		component.[Friend]mAwake = true;
		component.Awake();
		if (component.Enabled)
			component.OnEnable();
		mPendingStart.Add(component);
	}

	/// Enters play mode: every component receives Awake / OnEnable, then Start before its first update.
	public void StartPlay()
	{
		if (mPlaying)
			return;
		// A save to load at start that is still on its way holds the scene back (Update asks again).
		mStartHeld = SaveSystem.HoldStart(this);
		if (mStartHeld)
			return;
		SaveSystem.SceneStarting(this);
		mPlaying = true;
		Active = this;
		Time.Restart();
		Time.Tick = 0;
		// Built-in components that join something while on (a Network Identity its session) do so first, in the
		// order the objects were made, so that scripts waking next find them.
		if (!HandleComponents.Switched.IsEmpty)
		{
			for (int i = 0; i < mObjects.Count; i++)
			{
				if (mObjects[i].ActiveInHierarchy)
					HandleComponents.NotifySwitched(mObjects[i], true);
			}
		}
		for (int i = 0; i < mComponents.Count; i++)
			WakeComponent(mComponents[i]);
	}

	/// Leaves play mode: every component gets OnDisable and OnDestroy, and the physics world is put away.
	public void StopPlay()
	{
		mStartHeld = false;
		if (!mPlaying)
			return;
		// A game that locked the mouse does not keep it once it has stopped.
		Input.LockCursor = false;
		for (int i = mComponents.Count - 1; i >= 0; i--)
		{
			if (i >= mComponents.Count)
				continue;
			let component = mComponents[i];
			if (!component.IsAwake)
				continue;
			if (component.Enabled)
				component.OnDisable();
			component.OnDestroy();
			component.[Friend]ReleaseOwned();
			component.[Friend]mAwake = false;
			component.[Friend]mStarted = false;
		}
		mPendingStart.Clear();
		for (int i = mObjects.Count - 1; i >= 0 && !HandleComponents.Switched.IsEmpty; i--)
		{
			if (mObjects[i].ActiveInHierarchy)
				HandleComponents.NotifySwitched(mObjects[i], false);
		}
		mPlaying = false;
		// Built-in components' bodies leave the physics world as the class components' did in OnDisable.
		Rigidbody.SyncAll(this);
		Animator.StopAll(this);
		BehaviorTreeRunner.StopAll(this);
		DialogueRunner.StopAll(this);
		SequencePlayer.StopAll(this);
		SceneLoader.StopAll(this);
		ViewmodelPose.StopAll(this);
		Joint.StopAll(this);
		CharacterController.SyncAll(this);
	}

	void RunPendingStarts()
	{
		// Start can add components (and so more pending starts), which are run in the same pass.
		mRunningStarts = true;
		for (int i = 0; i < mPendingStart.Count; i++)
		{
			let component = mPendingStart[i];
			if (component == null)
				continue;
			if (!component.[Friend]mStarted && component.IsActiveAndEnabled)
			{
				component.[Friend]mStarted = true;
				component.Start();
			}
			else if (!component.[Friend]mStarted)
			{
				// Still disabled: retry next frame without spinning here.
				mDeferredStart.Add(component);
			}
		}
		mRunningStarts = false;
		mPendingStart.Clear();
		for (let component in mDeferredStart)
			mPendingStart.Add(component);
		mDeferredStart.Clear();
	}

	List<Component> mDeferredStart = new .() ~ delete _;
	bool mRunningStarts;
	/// The batch DestroyTogether has under way, and what it has for Sweep.
	List<GameObject> mGoing;
	HashSet<Type> mSweptTypes = new .() ~ delete _;

	static ProfilerMarker sStartMarker = .("Start", .Scripts);
	static ProfilerMarker sPreTickMarker = .("Network Pre-Tick", .Networking);
	static ProfilerMarker sPostTickMarker = .("Network Post-Tick", .Networking);
	static ProfilerMarker sPhysicsMarker = .("Physics.Step", .Physics);
	static ProfilerMarker sFrameComponentsMarker = .("OnFrame (every component)", .Scripts);
	static ProfilerMarker sUpdateMarker = .("Update and OnLocalUpdate (every component)", .Scripts);
	static ProfilerMarker sTickUpdateMarker = .("Update (networked objects, offline)", .Scripts);
	static ProfilerMarker sLateMarker = .("LateUpdate (every component)", .Scripts);
	static ProfilerMarker sFixedMarker = .("FixedUpdate (every component)", .Scripts);
	static ProfilerMarker sVoiceMarker = .("VoiceChat.Update", .Audio);
	static ProfilerMarker sAudioMarker = .("Audio.Update", .Audio);
	static ProfilerMarker sPathsMarker = .("Navigation Paths", .AI);
	static ProfilerMarker sIKMarker = .("IK", .Animation);
	static ProfilerMarker sAnimatorMarker = .("Animators", .Animation);
	static ProfilerMarker sNavigationMarker = .("Navigation.Agents", .AI);
	static ProfilerMarker sBehaviourMarker = .("Behaviour.Trees", .AI);
	static ProfilerMarker sSkinMarker = .("Skinning", .Animation);
	static ProfilerMarker sDestroyMarker = .("Destroy", .Scripts);

	/// Calls one component method, timed under its type's marker when the Profiler times components.
	[Inline]
	void Run(Component component, ProfilerComponents.Method method)
	{
		Watchdog.Running = component;
		let timed = ProfilerComponents.Timing;
		if (timed)
			Profiler.Begin(ProfilerComponents.MarkerFor(component, method));
		switch (method)
		{
		case .FixedUpdate: component.FixedUpdate();
		case .Update: component.Update(mFrameInput, Time.DeltaTime);
		case .LateUpdate: component.LateUpdate();
		case .OnFrame: component.OnFrame();
		case .OnLocalUpdate: component.OnLocalUpdate();
		}
		if (timed)
			Profiler.End();
		Watchdog.Running = null;
	}

	/// Calls Component.Update with the given controls (a network tick's, or this frame's).
	[Inline]
	void RunUpdate(Component component, TickInput input, float deltaTime)
	{
		Watchdog.Running = component;
		let timed = ProfilerComponents.Timing;
		if (timed)
			Profiler.Begin(ProfilerComponents.MarkerFor(component, .Update));
		component.Update(input, deltaTime);
		if (timed)
			Profiler.End();
		Watchdog.Running = null;
	}

	/// This frame's local controls, for the Update of objects without a Network Identity.
	TickInput mFrameInput;

	/// Whether Update on this object runs per network tick (it has a Network Identity) rather than per frame.
	[Inline]
	static bool TicksUpdate(GameObject gameObject) => gameObject.[Friend]mNetworked;

	/// With no session running, objects with a Network Identity run Update here, once per tick, with the local
	/// controls (or none, for objects no player controls). In a session the network runs them (NetworkManager).
	void TickUpdatesOffline()
	{
		if (Network != null && Network.Mode != .Offline)
			return;
		// In the order the objects were made, as the identities were when they were classes.
		for (int i = 0; i < mObjects.Count; i++)
		{
			if (!mObjects[i].[Friend]mNetworked)
				continue;
			let identity = mObjects[i].GetComponent<NetworkIdentity>();
			if (identity.IsActiveAndEnabled)
				identity.TickUpdate(identity.GatherControls(), Time.FixedDeltaTime);
		}
	}

	/// The scene's two pipelines (docs/ecs-plan.md, "Frame and tick order"): the steps below, in Flecs phases, so
	/// that engine systems added later run at their place among them. Steps in one phase run in the order added.
	World.Pipeline mFramePipeline;
	World.Pipeline mTickPipeline;
	World.Pipeline mTickStartPipeline;
	World.Pipeline mReplayPipeline;
	/// The per-frame pipeline: add engine systems or steps to it by phase (World.AddStep).
	public World.Pipeline FramePipeline => mFramePipeline;
	/// The fixed-tick pipeline.
	public World.Pipeline TickPipeline => mTickPipeline;
	/// The pipeline a client runs for each tick it replays after a correction from the server (see AddSteps).
	public World.Pipeline ReplayPipeline => mReplayPipeline;

	/// Runs one replayed tick (NetworkManager, from the network's receive, between pipelines).
	public void RunReplayTick() => World.Run(mReplayPipeline, Time.FixedDeltaTime);

	void AddSteps()
	{
		// A tick runs in three parts: Tick.Starts (its own pipeline), then the network's receive, then the rest
		// (TickPipeline). The receive is between pipelines, not a step, because a correction from the server rewinds
		// and replays ticks through ReplayPipeline, and Flecs cannot run a pipeline inside another.
		mTickStartPipeline = World.CreatePipeline("TickStart");
		mTickPipeline = World.CreatePipeline("Tick");
		mReplayPipeline = World.CreatePipeline("Replay");
		World.AddStep(mTickStartPipeline, "Tick.Starts", .OnLoad, new () =>
			{
				using (sStartMarker.Sample())
				{
					RunPendingStarts();
					Rigidbody.SyncAll(this);
					CharacterController.SyncAll(this);
				}
			}
			);
		World.AddStep(mTickPipeline, "Tick.Update", .PreUpdate, new () =>
			{
				using (sTickUpdateMarker.Sample()) TickUpdatesOffline();
			}
			);
		World.AddStep(mTickPipeline, "Tick.FixedUpdate", .OnUpdate, new => RunFixedUpdates);
		// Agents walking through a controller or body steer them after the scripts' FixedUpdate, before physics.
		World.AddStep(mTickPipeline, "Tick.Navigation", .OnUpdate, new () => NavigationAgent.TickAll(this));
		// A saved velocity loaded before its body existed is given to it (SavedTransform.FixedUpdate did).
		World.AddStep(mTickPipeline, "Tick.SavedTransforms", .OnUpdate, new () => SavedTransform.TickAll(this));
		World.AddStep(mTickPipeline, "Tick.Physics", .OnValidate, new () =>
			{
				using (sPhysicsMarker.Sample())
				{
					Water.Simulate(this, Time.FixedDeltaTime);
					Physics.Step(Time.FixedDeltaTime);
					if (Network != null && Network.DesyncDebugger)
						Network.[Friend]DesyncNotePhysics();
				}
			});
		World.AddStep(mTickPipeline, "Tick.NetworkSend", .PostUpdate, new () =>
			{
				using (sPostTickMarker.Sample()) Network?.PostTick();
			}
			);

		// One replayed tick on a client correcting its prediction (NetworkManager): what the server was showing then,
		// the networked Update of what this machine controls, physics if anything predicted needs it, and noting
		// where everything ended up. A game's own predicted systems go in this pipeline as well as TickPipeline.
		World.AddStep(mReplayPipeline, "Replay.RemoteStates", .PostLoad, new () => Network?.[Friend]ReplayRemoteStates());
		World.AddStep(mReplayPipeline, "Replay.Update", .PreUpdate, new () => Network?.[Friend]ReplayUpdate());
		World.AddStep(mReplayPipeline, "Replay.Physics", .OnValidate, new () => Network?.[Friend]ReplayPhysics());
		World.AddStep(mReplayPipeline, "Replay.Record", .PostUpdate, new () => Network?.[Friend]ReplayRecord());

		mFramePipeline = World.CreatePipeline("Frame");
		World.AddStep(mFramePipeline, "Frame.OnFrame", .OnLoad, new => RunOnFrames);
		World.AddStep(mFramePipeline, "Frame.Audio", .PostLoad, new () =>
			{
				using (sVoiceMarker.Sample())
					VoiceChat.Update(this);
				using (sAudioMarker.Sample())
				{
					AudioListener.FrameAll(this);
					AudioSource.FrameAll(this);
					Audio.Update(this);
				}
			});
		World.AddStep(mFramePipeline, "Frame.Starts", .PreUpdate, new () =>
			{
				if (!mPlaying)
					return;
				using (sStartMarker.Sample())
				{
					RunPendingStarts();
					Rigidbody.SyncAll(this);
					CharacterController.SyncAll(this);
				}
			});
		World.AddStep(mFramePipeline, "Frame.Update", .OnUpdate, new => RunFrameUpdates);
		// Conversations move on after the scripts' Update (DialogueRunner.OnLocalUpdate did, in component order).
		World.AddStep(mFramePipeline, "Frame.Dialogue", .OnUpdate, new () => DialogueRunner.FrameAll(this));
		// Scene loaders start (Load On Start) and follow their loads (SceneLoader.Start and OnLocalUpdate did).
		World.AddStep(mFramePipeline, "Frame.SceneLoaders", .OnUpdate, new () => SceneLoader.FrameAll(this));
		// Joints are made as they start or are switched on, and let go when switched off (Joint's Start, OnEnable
		// and OnDisable did this).
		World.AddStep(mFramePipeline, "Frame.Joints", .OnUpdate, new () => Joint.FrameAll(this));
		// Sequences move their objects after the scripts' Update (SequencePlayer.OnLocalUpdate did).
		World.AddStep(mFramePipeline, "Frame.Sequences", .OnUpdate, new () => SequencePlayer.FrameAll(this));
		// Behaviour trees think after the scripts' Update (BehaviorTreeRunner.OnLocalUpdate did, in component order),
		// before the agents they steer move.
		World.AddStep(mFramePipeline, "Frame.Behaviour", .OnUpdate, new () =>
			{
				using (sBehaviourMarker.Sample())
					BehaviorTreeRunner.FrameAll(this);
			});
		// Navigation agents move once the scripts have set their destinations (NavigationAgent.OnLocalUpdate did, in
		// component order).
		World.AddStep(mFramePipeline, "Frame.Navigation", .OnUpdate, new () =>
			{
				using (sNavigationMarker.Sample())
					NavigationAgent.FrameAll(this);
			});
		// Animators pose their bones once the scripts have set their parameters (Animator.OnLocalUpdate did, in
		// component order); LateUpdate and IK see the pose.
		World.AddStep(mFramePipeline, "Frame.Animators", .OnUpdate, new () =>
			{
				using (sAnimatorMarker.Sample())
					Animator.FrameAll(this);
			});
		// Paths the agents asked for in Update, found together on the job threads.
		World.AddStep(mFramePipeline, "Frame.Paths", .OnValidate, new () =>
			{
				if (!mPlaying)
					return;
				using (sPathsMarker.Sample())
					NavigationAgent.FindQueuedPaths();
			});
		World.AddStep(mFramePipeline, "Frame.LateUpdate", .PostUpdate, new => RunLateUpdates);
		// Viewmodels follow the camera once scripts have moved it in LateUpdate (ViewmodelPose.LateUpdate did).
		World.AddStep(mFramePipeline, "Frame.Viewmodels", .PostUpdate, new () => ViewmodelPose.FrameAll(this));
		// Inverse kinematics goes on top of whatever clips and scripts made of the pose this frame, and rigged models
		// whose bones are objects are skinned from the result.
		World.AddStep(mFramePipeline, "Frame.Animation", .PreStore, new () =>
			{
				using (sIKMarker.Sample())
					IKSystem.Solve(this);
				sSkinMarker.Begin();
				SkinnedMeshRenderer.SkinFromBones(this);
				SkinnedMeshRenderer.FinishCpuSkinning();
				Profiler.End();
			});
		World.AddStep(mFramePipeline, "Frame.Destroy", .OnStore, new => RunDestroyQueue);
		// Answers the Flecs Explorer, when the editor has started it (World.StartExplorer).
		World.AddStep(mFramePipeline, "Frame.Explorer", .OnStore, new () => World.PollExplorer(Time.UnscaledDeltaTime));
	}

	/// One fixed simulation tick through the Tick pipeline: pending Starts, the network's receive and simulation,
	/// Update on networked objects when offline, FixedUpdate, physics, then the network's send.
	public void FixedUpdate()
	{
		if (!mPlaying)
			return;
		Active = this;
		SpawnPhaseTime += Time.FixedDeltaTime;
		RunPipeline(mTickStartPipeline, Time.FixedDeltaTime);
		using (sPreTickMarker.Sample())
			Network?.PreTick();
		RunPipeline(mTickPipeline, Time.FixedDeltaTime);
		Time.Tick++;
	}

	void RunFixedUpdates()
	{
		sFixedMarker.Begin();
		for (int i = 0; i < mFixedList.Count; i++)
		{
			let component = mFixedList[i];
			if (component.[Friend]mStarted && component.IsActiveAndEnabled)
				Run(component, .FixedUpdate);
		}
		Profiler.End();
	}

	/// Per-frame update. In edit mode only the destroy queue is processed.
	bool mStartHeld;
	/// Waiting for a save before play starts (SaveSystem.LoadAtStart with a storage that answers later).
	public bool StartHeld => mStartHeld;

	/// True while Update runs the components: work they ask for that can be done together (models bent on the CPU,
	/// navigation paths) waits for the rest and is done on the job threads before Update returns. Outside it, the same
	/// calls do their work at once.
	public bool Updating { get; private set; }

	/// How many times Update has run.
	public int64 UpdateCount { get; private set; }

	/// Runs one frame through the Frame pipeline: OnFrame on every component (in the editor too), audio, then while
	/// playing the pending Starts, Update and OnLocalUpdate, queued paths and LateUpdate, and always IK, skinning and
	/// the destroy queue.
	public void Update()
	{
		Active = this;
		if (mStartHeld)
			StartPlay();
		UpdateCount++;
		Updating = true;
		defer
		{
			Updating = false;
		}
		RunPipeline(mFramePipeline, Time.DeltaTime);
	}

	bool mInPipeline;

	/// Runs one of the scene's pipelines. Flecs keeps one running pipeline per world, so a frame or tick asked for
	/// from inside another (a script calling Scene.Update) is refused rather than corrupting it.
	void RunPipeline(World.Pipeline pipeline, float deltaTime)
	{
		if (mInPipeline)
		{
			Log.Error("Scene.Update or Scene.FixedUpdate was called from inside a frame or tick of the same scene; ignored.");
			return;
		}
		mInPipeline = true;
		World.Run(pipeline, deltaTime);
		mInPipeline = false;
	}

	void RunOnFrames()
	{
		sFrameComponentsMarker.Begin();
		// Networked objects' drawn positions first, so that scripts that follow one see where it is drawn.
		NetworkIdentity.FrameAll(this);
		for (int i = 0; i < mOnFrameList.Count; i++)
		{
			let component = mOnFrameList[i];
			if (component.IsActiveAndEnabled)
				Run(component, .OnFrame);
		}
		SkinnedMeshRenderer.FrameAll(this);
		ComputeEffect.FrameAll(this);
		ModelMesh.FrameAll(this);
		LODGroup.FrameAll(this);
		VoxelObject.FrameAll(this);
		ParticleSystem.FrameAll(this);
		LineRenderer.FrameAll(this);
		TrailRenderer.FrameAll(this);
		Profiler.End();
	}

	void RunFrameUpdates()
	{
		if (!mPlaying)
			return;
		mFrameInput.previous = mFrameInput.raw;
		mFrameInput.raw = default;
		LocalControls.Read(ref mFrameInput.raw);
		let deltaTime = Time.DeltaTime;
		sUpdateMarker.Begin();
		for (int i = 0; i < mFrameList.Count; i++)
		{
			let component = mFrameList[i];
			if (component.[Friend]mStarted && component.IsActiveAndEnabled)
			{
				let callbacks = component.[Friend]mCallbacks;
<<<<<<< Updated upstream
				let hasLocalUpdate = callbacks.HasFlag(.OnLocalUpdate);
				if (hasLocalUpdate)
					Run(component, .OnLocalUpdate);
				// Only a callback between the checks can change enabled state or the hierarchy. Ordinary Update-only
				// scripts do not need to walk their parents twice. Preserve the recheck after OnLocalUpdate.
				// Update runs here for objects without a Network Identity; theirs runs per tick.
				if (callbacks.HasFlag(.Update) && !TicksUpdate(component.GameObject) && (!hasLocalUpdate || component.IsActiveAndEnabled))
=======
				if (callbacks.HasFlag(.OnLocalUpdate))
				{
					Run(component, .OnLocalUpdate);
					// Local callbacks can disable this component or its hierarchy before Update.
					if (!component.IsActiveAndEnabled)
						continue;
				}
				// Update runs here for objects without a Network Identity; theirs runs per tick.
				if (callbacks.HasFlag(.Update) && !TicksUpdate(component.GameObject))
>>>>>>> Stashed changes
					RunUpdate(component, mFrameInput, deltaTime);
			}
		}
		Profiler.End();
	}

	void RunLateUpdates()
	{
		if (!mPlaying)
			return;
		sLateMarker.Begin();
		for (int i = 0; i < mLateList.Count; i++)
		{
			let component = mLateList[i];
			if (component.[Friend]mStarted && component.IsActiveAndEnabled)
				Run(component, .LateUpdate);
		}
		// Lines and trails follow what the scripts moved.
		LineRenderer.LateAll(this);
		TrailRenderer.LateAll(this);
		Profiler.End();
	}

	void RunDestroyQueue()
	{
		sDestroyMarker.Begin();
		while (mDestroyQueue.Count > 0)
		{
			if (mDestroyQueue.Count < SweepFrom)
			{
				DestroyImmediate(mDestroyQueue.PopBack());
				continue;
			}
			let queued = scope List<GameObject>()..AddRange(mDestroyQueue);
			mDestroyQueue.Clear();
			DestroyTogether(queued);
		}
		Profiler.End();
	}
}
