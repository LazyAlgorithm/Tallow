using System;
using System.Collections;

namespace Tallow;

/// An entity in a scene: a named Transform with a list of components.
class GameObject
{
	/// The object's name, shown in the Hierarchy; Scene.Find looks objects up by it.
	public String Name = new .() ~ delete _;
	/// A number unique within the scene, kept when the scene is saved and loaded. References to objects are saved as
	/// it.
	public uint32 Id;
	/// Where the object is, how it is turned and sized, and its place in the hierarchy. Every object has one.
	public Transform Transform ~ delete _;
	/// The object's components, in the order the Inspector shows them. Use AddComponent and RemoveComponent to change
	/// them.
	public List<Component> Components = new .() ~ delete _;
	/// An organisational folder in the Hierarchy: it only groups objects. Its transform stays at
	/// identity so it never moves its children, and it carries no components.
	public bool IsFolder;
	/// Generated at runtime (voxel chunks, pooled effects): not saved with the scene and hidden in the Hierarchy.
	public bool Transient;
	/// In a streamed world (docs/world-streaming.md): kept loaded wherever the players are, instead of coming and going
	/// with its cell.
	public bool AlwaysLoaded;
	/// What this object was made from while the game ran: a prefab file, or the name of a registered network prefab.
	/// Empty for objects that came with the scene. SaveSystem uses it to make the object again on loading.
	public String SpawnedFrom ~ delete _;

	Scene mScene;
	Entity mEntity;
	bool mActive = true;
	/// Set by NetworkIdentity while it is registered: Update runs per tick (Component.Update). A bool beside the
	/// others rather than a reference, so GameObject does not grow: every script call reads this object.
	bool mNetworked;
	bool mDestroyed;
	/// Being taken out of the scene (Scene.DestroyTogether).
	bool mGoing;
	int32 mLayer;
	List<String> mTags ~ DeleteContainerAndItems!(_);
	uint32 mWorldStates = uint32.MaxValue;

	/// The physics layer (named in Project Settings, 0 to 31): which other layers this object's colliders, rigid
	/// body and character controller collide with, and which ray and shape queries see it. 0 is "Default".
	public int32 Layer
	{
		get => mLayer;
		set
		{
			let layer = Math.Clamp(value, 0, ProjectConfig.MaxLayers - 1);
			if (layer == mLayer)
				return;
			mLayer = layer;
			mScene?.Physics.RefreshLayer(this);
		}
	}

	/// The world states this object is part of, one bit per state in Project Settings (all of them by default).
	/// Outside the scene's active world state it is not drawn, does not collide, is not heard and is not walked on.
	public uint32 WorldStates
	{
		get => mWorldStates;
		set
		{
			if (value == mWorldStates)
				return;
			mWorldStates = value;
			mScene?.[Friend]WorldMembershipChanged(this);
		}
	}

	/// True when the object is part of that world state.
	public bool InWorldState(int32 state) => state >= 0 && state < 32 && (mWorldStates & (1u << state)) != 0;

	/// Puts the object in or takes it out of one world state.
	public void SetInWorldState(int32 state, bool member)
	{
		if (state < 0 || state >= 32)
			return;
		WorldStates = member ? (mWorldStates | (1u << state)) : (mWorldStates & ~(1u << state));
	}

	/// The world states the object is really in: its own, less any that an object above it is left out of.
	public uint32 EffectiveWorldStates
	{
		get
		{
			var mask = mWorldStates;
			var transform = Transform?.Parent;
			while (transform != null && mask != 0)
			{
				mask &= transform.GameObject.mWorldStates;
				transform = transform.Parent;
			}
			return mask;
		}
	}

	/// True when the object, and every object above it, is part of the scene's active world state: a parent left
	/// out of a state takes its children out with it.
	public bool InActiveWorld => mScene == null || (EffectiveWorldStates & (1u << mScene.WorldState)) != 0;

	// ---- tags ----

	/// How many tags the object has, and each in turn.
	public int TagCount => mTags != null ? mTags.Count : 0;
	/// The tag at an index, 0 to TagCount - 1.
	public StringView GetTag(int index) => mTags[index];

	/// Whether the object has a tag (Project Settings > Tags names them).
	public bool HasTag(StringView tag)
	{
		if (mTags == null)
			return false;
		for (let t in mTags)
		{
			if (t == tag)
				return true;
		}
		return false;
	}

	/// Gives the object a tag (any text; the editor offers the tags listed in Project Settings). Scene.FindWithTag
	/// and FindAllWithTag find tagged objects without looking at every object.
	public void AddTag(StringView tag)
	{
		if (tag.IsEmpty || HasTag(tag))
			return;
		if (mTags == null)
			mTags = new .();
		mTags.Add(new .(tag));
		mScene?.[Friend]IndexTag(this, tag, true);
	}

	/// Takes a tag off the object, if it has it.
	public void RemoveTag(StringView tag)
	{
		if (mTags == null)
			return;
		for (int i < mTags.Count)
		{
			if (mTags[i] == tag)
			{
				mScene?.[Friend]IndexTag(this, tag, false);
				delete mTags[i];
				mTags.RemoveAt(i);
				return;
			}
		}
	}

	/// An object outside any scene. Use Scene.CreateGameObject to make one in a scene.
	public this(StringView name)
	{
		Name.Set(name);
		Transform = new Transform(this);
	}

	public ~this()
	{
		for (let component in Components)
			delete component;
	}

	/// The scene the object is in.
	public Scene Scene { [Inline] get => mScene; }
	/// The object's entity in its scene's World (docs/ecs-plan.md), or Entity.Null outside a scene.
	public Entity Entity { [Inline] get => mEntity; }
	/// Whether this object itself is switched on, whatever its parents are (see ActiveInHierarchy).
	public bool ActiveSelf => mActive;
	/// True once Scene.Destroy has been called on the object; it is freed at the end of the frame.
	public bool IsDestroyed => mDestroyed;

	/// Whether the object and every parent above it are switched on: only then do its components run.
	public bool ActiveInHierarchy
	{
		get
		{
			var t = Transform;
			while (t != null)
			{
				if (!t.GameObject.mActive)
					return false;
				t = t.Parent;
			}
			return true;
		}
	}

	/// Activates or deactivates this object and everything under it. While playing, components
	/// receive OnDisable / OnEnable, so for example a deactivated Rigidbody leaves the simulation.
	public void SetActive(bool active)
	{
		if (mActive == active)
			return;
		let wasActive = ActiveInHierarchy;
		mActive = active;
		if (mScene != null && !mEntity.IsNull)
		{
			if (active)
				mScene.World.Remove<InactiveSelf>(mEntity);
			else
				mScene.World.Add<InactiveSelf>(mEntity);
		}
		let isActive = ActiveInHierarchy;
		if (wasActive != isActive && mScene != null && mScene.IsPlaying)
			NotifyActiveChanged(isActive);
		if (mScene?.Network != null)
			NetworkSync.ActiveChanged(this);
	}

	void NotifyActiveChanged(bool active)
	{
		for (int i = 0; i < Components.Count; i++)
		{
			let component = Components[i];
			if (!component.IsAwake || !component.Enabled)
				continue;
			if (active)
				component.OnEnable();
			else
				component.OnDisable();
		}
		for (let child in Transform.Children)
		{
			// Children that are switched off themselves were already disabled.
			if (child.GameObject.mActive)
				child.GameObject.NotifyActiveChanged(active);
		}
	}

	/// Adds a new component of a type and returns it. While the scene plays, it wakes at once (Awake, OnEnable) and
	/// starts before the next Update.
	// ---- Data components ([Component] structs, stored in the object's entity) ----

	/// Adds data component T (or keeps the one there) and sets it to value. Returns where it is, valid until the
	/// object's data components change.
	public T* AddComponent<T>(T value = default) where T : struct
	{
		let world = mScene.World;
		world.Set<T>(mEntity, value);
		return world.Get<T>(mEntity);
	}

	/// The object's data component T, or null. Valid until the object's data components change: read or write it
	/// right away rather than keeping the pointer.
	public T* GetComponent<T>() where T : struct => mScene.World.Get<T>(mEntity);

	public bool HasComponent<T>() where T : struct => mScene.World.Has<T>(mEntity);

	public void RemoveComponent<T>() where T : struct => mScene.World.Remove<T>(mEntity);

	// ---- Built-in components (handles: Light, MeshRenderer... docs/ecs-plan.md) ----

	/// Adds built-in component T with its default values, or returns the one the object has.
	public T AddComponent<T>() where T : struct, IComponentHandle
	{
		HandleComponents.Add(this, HandleComponents.Find(typeof(T)));
		return MakeHandle<T>();
	}

	/// The object's built-in component T; not valid (`if (light)` is false) if it has none.
	public T GetComponent<T>() where T : struct, IComponentHandle => mScene.World.Has(mEntity, T.DataIndex) ? MakeHandle<T>() : default;

	public bool HasComponent<T>() where T : struct, IComponentHandle => mScene.World.Has(mEntity, T.DataIndex);

	public void RemoveComponent<T>() where T : struct, IComponentHandle => mScene.World.Remove(mEntity, T.DataIndex);

	/// A handle is the object and nothing more (ComponentHandle), so it is made by writing the object into it.
	T MakeHandle<T>() where T : struct, IComponentHandle
	{
		System.Diagnostics.Debug.Assert(sizeof(T) == sizeof(GameObject), "A component handle must not declare fields");
		T handle = default;
		*(GameObject*)&handle = this;
		return handle;
	}

	/// The same by type, for the editor and scene files (DataComponents).
	public void* AddData(Type type) => mScene.World.Ensure(mEntity, ComponentTypes.Add(type, type.Size, type.Align));
	public void* GetData(Type type) => mScene.World.Get(mEntity, ComponentTypes.Add(type, type.Size, type.Align));
	public void RemoveData(Type type) => mScene.World.Remove(mEntity, ComponentTypes.Add(type, type.Size, type.Align));

	public T AddComponent<T>() where T : Component
	{
		return (T)AddComponent(typeof(T));
	}

	/// Adds a new component of a type given at run time, or logs an error and returns null if the type is not a
	/// [Component].
	public Component AddComponent(Type type)
	{
		let component = ComponentRegistry.Create(type);
		if (component == null)
		{
			Log.Error(scope $"Cannot create component {type}. Is the class marked with [Component]?");
			return null;
		}
		AttachComponent(component);
		return component;
	}

	void AttachComponent(Component component)
	{
		component.[Friend]mGameObject = this;
		Components.Add(component);
		if (mScene != null)
			mScene.[Friend]RegisterComponent(component);
	}

	/// The object's first component of a type (or a type derived from it), or null.
	public T GetComponent<T>() where T : Component
	{
		for (let component in Components)
		{
			if (let typed = component as T)
				return typed;
		}
		return null;
	}

	/// The first component of a type on this object or anything under it, searching this object first, or null.
	public T GetComponentInChildren<T>() where T : Component
	{
		let own = GetComponent<T>();
		if (own != null)
			return own;
		for (let child in Transform.Children)
		{
			let found = child.GameObject.GetComponentInChildren<T>();
			if (found != null)
				return found;
		}
		return null;
	}

	/// Removes and frees one of the object's components (OnDisable and OnDestroy run first while playing).
	public void RemoveComponent(Component component)
	{
		if (!Components.Remove(component))
			return;
		if (mScene != null)
			mScene.[Friend]UnregisterComponent(component);
		delete component;
	}
}
