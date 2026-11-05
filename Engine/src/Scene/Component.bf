using System;
using System.Collections;
using System.Reflection;

namespace Tallow;

/// Put [Component] on every component class. It keeps the type, its constructor and its fields
/// in the reflection data so the class can be created by name when a scene loads, listed in
/// the Add Component menu, and edited in the Inspector. Beef does not inherit attributes, so
/// each subclass needs its own. On a struct it marks an ECS data component (docs/ecs-plan.md).
[AttributeUsage(.Class | .Struct, .AlwaysIncludeTarget | .ReflectAttribute, ReflectUser = .All, AlwaysIncludeUser = .AssumeInstantiated | .IncludeAllMethods)]
struct ComponentAttribute : Attribute
{
}

/// Save a supported private field and expose it in the Inspector.
[AttributeUsage(.Field, .ReflectAttribute)]
struct ShowInInspectorAttribute : Attribute
{
}

/// Keep a public field out of the Inspector (it is still saved).
[AttributeUsage(.Field, .ReflectAttribute)]
struct HideInInspectorAttribute : Attribute
{
}

/// Keep a public field out of scene files and the Inspector.
[AttributeUsage(.Field, .ReflectAttribute)]
struct NonSerializedAttribute : Attribute
{
}

/// Show an integer field as a choice of the project's layers (Project Settings), by name, with "None" for -1:
///   [Layer] public int32 viewmodelLayer = -1;
[AttributeUsage(.Field, .ReflectAttribute)]
struct LayerAttribute : Attribute
{
}

/// Show a numeric field as a slider.
[AttributeUsage(.Field, .ReflectAttribute)]
struct RangeAttribute : Attribute
{
	/// The slider's lowest value.
	public float min;
	/// The slider's highest value.
	public float max;

	/// A slider from min to max.
	public this(float min, float max)
	{
		this.min = min;
		this.max = max;
	}
}

/// Base class for everything attached to a GameObject.
///
/// Lifecycle while the scene is playing: Awake, OnEnable, Start (before the first Update),
/// then FixedUpdate at Time.TickRate, Update and LateUpdate per frame, and OnDisable / OnDestroy.
/// Public fields of supported types are saved with the scene and shown in the Inspector.
[Component]
abstract class Component
{
	GameObject mGameObject;
	bool mEnabled = true;
	bool mAwake;
	bool mStarted;
	bool mRegistered;
	/// In OnUnregister as part of a batch of objects going, which the scene clears out of its lists in one pass.
	bool mLeavingTogether;
	/// The Profiler's marker slot for its type (ProfilerComponents), -1 until it is first timed.
	int32 mProfileSlot = -1;
	/// Which per-frame callbacks this component's class overrides (ScriptCallbacks), set when it joins a scene.
	ScriptCallbacks mCallbacks;

	/// The object this component is on.
	public GameObject GameObject { [Inline] get => mGameObject; }
	/// The transform of the object this component is on.
	public Transform Transform { [Inline] get => mGameObject.Transform; }
	/// The scene the component's object is in.
	public Scene Scene { [Inline] get => mGameObject.Scene; }
	/// Whether Awake has run (it runs when play starts, or when the component is added while playing).
	public bool IsAwake => mAwake;

	/// Whether the component runs. Switching it while playing calls OnEnable or OnDisable.
	public bool Enabled
	{
		get => mEnabled;
		set
		{
			if (mEnabled == value)
				return;
			mEnabled = value;
			if (mAwake && mGameObject.Scene.IsPlaying)
			{
				if (value)
					OnEnable();
				else
					OnDisable();
			}
			if (mGameObject?.Scene?.Network != null)
				NetworkSync.EnabledChanged(this);
		}
	}

	/// True when this component is enabled and its object is active in the hierarchy.
	public bool IsActiveAndEnabled => mEnabled && mGameObject.ActiveInHierarchy;

	/// The first component of a type on the same object, or null.
	public T GetComponent<T>() where T : Component => mGameObject.GetComponent<T>();
	/// The object's data component T, or null (GameObject.GetComponent).
	public T* GetComponent<T>() where T : struct => mGameObject.GetComponent<T>();

	// ---- gameplay callbacks (play mode only) ----
	/// Called once when play starts (or when the component is added while playing), before any Start.
	public virtual void Awake() { }
	/// Called when the component starts running: after Awake, and whenever it or its object is switched back on.
	public virtual void OnEnable() { }
	/// Called once, before the component's first Update.
	public virtual void Start() { }
	/// Called at the fixed tick rate (Time.FixedDeltaTime apart), with physics: the place for movement and forces.
	public virtual void FixedUpdate() { }
	/// The object's gameplay step. Write it once; the engine picks when it runs:
	/// - On an object with a Network Identity: once per network tick (deltaTime is Time.FixedDeltaTime), with the
	///   controls of the player who controls the object. It runs on the server and, predicted, on that player's
	///   machine, and runs again after a correction (see NetworkScript for the rules that keep that working).
	///   Objects no player controls (NetworkIdentity.playerControlled off) get empty controls.
	/// - Everywhere else: once a frame (deltaTime is Time.DeltaTime), with this machine's controls.
	/// Take controls from input rather than Input, and the script works the same in both.
	public virtual void Update(TickInput input, float deltaTime) { }
	/// Called once a frame while playing, on this machine only: never networked, never replayed. Engine components do
	/// their per-frame work here; game scripts put gameplay in Script.Update and keep this for effects, UI and other
	/// work that is only for the local player.
	public virtual void OnLocalUpdate() { }
	/// Called once a frame after every Update: the place for cameras that follow something.
	public virtual void LateUpdate() { }
	/// Called when the component stops running: switched off, its object switched off, or before OnDestroy.
	public virtual void OnDisable() { }
	/// Called when the component or its object is destroyed while playing.
	public virtual void OnDestroy() { }

	// ---- engine callbacks (edit and play mode) ----
	/// Called when the component joins a scene, including in the editor. Engine components
	/// use it to add themselves to the scene's render / physics lists.
	public virtual void OnRegister() { }
	/// Called when the component leaves a scene, including in the editor: the counterpart of OnRegister.
	public virtual void OnUnregister() { }
	/// Called every frame in edit and play mode (streaming, procedural generation).
	public virtual void OnFrame() { }
	/// Draw in-game interface with the GUI class. Called every frame while playing.
	public virtual void OnGUI() { }
	/// Called on every machine when SendNetworkEvent is used on this component (and at once, with no session).
	public virtual void OnNetworkEvent(StringView name, float value) { }
	/// Tells this component on every machine that something happened. Allowed from the server, or from the
	/// client that owns the object. Without a session it simply calls OnNetworkEvent here.
	public void SendNetworkEvent(StringView name, float value = 0) => NetworkSync.SendEvent(this, name, value);
	/// Called just before the scene is written to disk; save side files here.
	public virtual void OnBeforeSave() { }
	/// Writes or reads this component's [Saved] fields (SaveSystem). The compiler writes this for every component
	/// with a [Saved] field; override it, calling base, only to keep extra values by hand.
	public virtual void SaveFields(SaveIO io) { }
	/// Whether the component has [Saved] fields: written by the compiler with SaveFields.
	public virtual bool HasSavedFields => false;
	/// SaveSystem.Save is about to read this component's [Saved] fields: bring them up to date here.
	public virtual void OnSaving() { }
	/// SaveSystem.Load has just put this component's [Saved] fields back: rebuild anything made from them here.
	public virtual void OnLoaded() { }
	/// Called after a field was changed by the Inspector or the scene loader.
	public virtual void OnValidate() { }
	/// Draw editor-only helpers with DebugDraw.
	public virtual void OnDrawGizmos(bool selected) { }
}
