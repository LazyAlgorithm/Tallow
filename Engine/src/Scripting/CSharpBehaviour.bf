using System;
using System.Collections;

namespace Tallow;

/// A native scene component that runs a trusted C# Script class in the managed runtime.
/// It participates in the regular scene lifecycle, including networked tick scheduling,
/// so C# gameplay receives the same update cadence and controls as native components.
/// The managed class is named by its full C# namespace and class, e.g. Gameplay.MoveRight.
[Component]
class CSharpBehaviour : Component
{
	/// The fully qualified managed Script subclass in the game's trusted assemblies.
	[HideInInspector] public SharedString scriptType;
	/// The asset ID (.tmeta) of the C# file the class is in. The editor finds a class renamed in its file by it.
	[HideInInspector] public SharedString scriptAsset;
	/// Edited field values: one trusted field name + numeric value per line.
	/// SharedString is handled by Tallow's existing scene/prefab serializer.
	[HideInInspector] public SharedString fieldOverrides;
	/// Object reference fields (a GameObject, Transform, built-in component or C# script, set by dragging an object
	/// into the Inspector): the field names, separated by ';', and the objects, in the same order. A list of
	/// objects is what the scene and prefab serializer keeps pointing at the right objects when ids change.
	[HideInInspector] public SharedString referenceNames;
	[HideInInspector] public List<GameObject> referenceTargets = new .() ~ delete _;

	int32 mInstance = -1;
	/// The per-frame callbacks the script's class overrides (CSharpRuntime.CallbackMask); the others are not sent.
	int32 mCallbacks = -1;

	bool Wants(CSharpRuntime.ManagedEvent event) => (mCallbacks & (1 << (int32)event)) != 0;

	/// The managed component is owned by this native component, not the scene's ECS memory.
	public bool IsLoaded => mInstance > 0 && CSharpRuntime.Ready;

	/// Opaque managed component ID, used only for trusted native API
	/// lookups; do not use GameObject.Id as a managed instance ID.
	public int32 ManagedInstance => mInstance;

	/// Used after GameObject.AddComponent registered a native adapter.
	/// RegisterComponent may have called an empty Awake/OnEnable before the
	/// scriptType was set; dispatch both once the trusted type is known.
	public int32 Configure(StringView managedType)
	{
		if (!scriptType.IsEmpty || managedType.IsEmpty || !CSharpRuntime.Ready)
			return -1;
		scriptType.Set(managedType);
		if (Scene.IsPlaying)
		{
			Awake();
			if (IsLoaded && Enabled)
				OnEnable();
		}
		return mInstance;
	}

	/// Editor entry point for choosing the managed class. In Edit mode this
	/// only records the type; while playing it also creates and starts the
	/// managed script, as a component added by gameplay code would be.
	public void SetScriptType(StringView managedType)
	{
		if (scriptType.IsEmpty && Scene != null && Scene.IsPlaying && CSharpRuntime.Ready)
		{
			if (Configure(managedType) > 0)
				return;
			// Keep the type on a failed attach so the Inspector still names it.
		}
		scriptType.Set(managedType);
	}

	/// Calls a UI document's handler (onclick="Name") on the script: a method of that name taking nothing, a
	/// UIElement or the element's id. False when the script has no such method.
	public bool InvokeUI(StringView method, StringView elementId)
	{
		if (!IsLoaded)
			return false;
		return CSharpRuntime.InvokeUI(mInstance, method, elementId) != 0;
	}

	/// A public field's value as text (for a UI document's bind="name"), while the script runs.
	public bool ReadLiveField(StringView name, String output)
	{
		if (!IsLoaded)
			return false;
		let fields = scope String();
		if (!CSharpRuntime.ReadFields(mInstance, false, fields))
			return false;
		for (let line in fields.Split('\n', .RemoveEmptyEntries))
		{
			let separator = line.IndexOf('\t');
			if (separator > 0 && line.Substring(0, separator) == name)
			{
				output.Append(line.Substring(separator + 1));
				return true;
			}
		}
		return false;
	}

	/// Sets a public field from text (a UI input bound to it). False when the script has no such field or the
	/// text does not fit it.
	public bool WriteLiveField(StringView name, StringView value)
	{
		if (!IsLoaded || name.Contains('\t') || name.Contains('\n') || value.Contains('\t') || value.Contains('\n'))
			return false;
		let probe = scope String();
		if (!ReadLiveField(name, probe))
			return false;
		return CSharpRuntime.ApplyFields(mInstance, scope $"{name}\t{value}\n");
	}

	/// The object a reference field points at, or null.
	public GameObject ReferenceTarget(StringView name)
	{
		int index = 0;
		for (let entry in referenceNames.View.Split(';', .RemoveEmptyEntries))
		{
			if (entry == name)
				return (index < referenceTargets.Count && referenceTargets[index] != null && !referenceTargets[index].IsDestroyed) ?
					referenceTargets[index] : null;
			index++;
		}
		return null;
	}

	/// Points a reference field at an object (null clears it). While the script runs, the field changes at once.
	public bool SetReference(StringView name, GameObject target)
	{
		if (name.IsEmpty || name.Contains(';') || name.Contains('\t') || name.Contains('\n'))
			return false;
		let names = scope List<StringView>();
		for (let entry in referenceNames.View.Split(';', .RemoveEmptyEntries))
			names.Add(entry);
		while (referenceTargets.Count < names.Count)
			referenceTargets.Add(null);
		int index = names.IndexOf(name);
		if (target == null)
		{
			if (index < 0)
				return true;
			names.RemoveAt(index);
			referenceTargets.RemoveAt(index);
		}
		else if (index < 0)
		{
			names.Add(name);
			referenceTargets.Add(target);
		}
		else
			referenceTargets[index] = target;
		let joined = scope String();
		for (let entry in names)
		{
			if (!joined.IsEmpty)
				joined.Append(';');
			joined.Append(entry);
		}
		referenceNames.Set(joined);
		if (IsLoaded)
			ApplyReference(name, target);
		return true;
	}

	/// Gives one reference field its object ("#id", or "" for none). A field that is no longer a reference (the
	/// script changed) is left alone.
	void ApplyReference(StringView name, GameObject target)
	{
		let line = scope String()..AppendF("{}\t", name);
		if (target != null && !target.IsDestroyed && target.Scene == GameObject.Scene)
			line.AppendF("#{}", target.Id);
		line.Append('\n');
		if (!CSharpRuntime.ApplyFields(mInstance, line))
			Log.Warning(scope $"'{GameObject.Name}': the C# field {name} could not be pointed at {(target != null ? (StringView)target.Name : "nothing")}.");
	}

	/// Gives every reference field its object. The C# scripts on the objects referred to are attached first (their
	/// Awake runs early if it has not yet), so a reference to another script is set by this script's Awake.
	void ApplyReferences()
	{
		int index = 0;
		for (let name in referenceNames.View.Split(';', .RemoveEmptyEntries))
		{
			let target = index < referenceTargets.Count ? referenceTargets[index] : null;
			index++;
			if (target != null && !target.IsDestroyed && target != GameObject && target.ActiveInHierarchy)
			{
				for (let component in target.Components)
				{
					if (let script = component as CSharpBehaviour)
					{
						if (!script.IsLoaded)
							script.Awake();
					}
				}
			}
			ApplyReference(name, target);
		}
	}

	/// Read an Inspector override, falling back to the source's declared initializer.
	public bool ReadEditorField(StringView name, String output)
	{
		for (let line in fieldOverrides.View.Split('\n', .RemoveEmptyEntries))
		{
			let separator = line.IndexOf('\t');
			if (separator >= 0 && line.Substring(0, separator) == name)
			{
				output.Set(line.Substring(separator + 1));
				return true;
			}
		}
		return false;
	}

	/// Preserve unrelated serialized fields and reject values that cannot
	/// round-trip through the scene's line-based override format.
	/// Return false without storing bad values or desynchronizing Play state.
	public bool WriteEditorField(StringView name, StringView value)
	{
		if (name.IsEmpty || name.Contains('\t') || name.Contains('\n') ||
			name.Contains('\r') || name.Contains('\0') ||
			value.Contains('\t') || value.Contains('\n') ||
			value.Contains('\r') || value.Contains('\0'))
			return false;
		let updated = scope String();
		for (let line in fieldOverrides.View.Split('\n', .RemoveEmptyEntries))
		{
			let separator = line.IndexOf('\t');
			if (separator < 0 || line.Substring(0, separator) != name)
			{
				updated.Append(line);
				updated.Append('\n');
			}
		}
		updated.AppendF("{}\t{}\n", name, value);
		// Apply only the edited field to a live script: re-sending every
		// saved override would undo values the game changed while playing.
		// The managed loader validates before mutating; persist on success.
		if (IsLoaded && !CSharpRuntime.ApplyFields(mInstance, scope $"{name}\t{value}\n"))
			return false;
		fieldOverrides.Set(updated);
		OnValidate();
		return true;
	}


	public override void Awake()
	{
		// Already attached: another script's references brought this one up early (ApplyReferences).
		if (scriptType.IsEmpty || !CSharpRuntime.Ready || IsLoaded)
			return;
		mInstance = CSharpRuntime.Attach(scriptType, GameObject);
		if (mInstance > 0)
		{
			mCallbacks = CSharpRuntime.CallbackMask(mInstance);
			// Leave the scene's per-frame lists for callbacks the script's class does not override, so they cost
			// nothing at all (CSharpBehaviour itself overrides every one).
			ScriptCallbacks wanted = .None;
			if ((mCallbacks & CSharpRuntime.UpdateCallback) != 0) wanted |= .Update;
			if ((mCallbacks & CSharpRuntime.EarlyUpdateCallback) != 0) wanted |= .EarlyUpdate;
			if ((mCallbacks & CSharpRuntime.LateUpdateCallback) != 0) wanted |= .LateUpdate;
			if (Wants(.FixedUpdate)) wanted |= .FixedUpdate;
			if (Wants(.LocalEarlyUpdate)) wanted |= .LocalEarlyUpdate;
			if (Wants(.LocalUpdate)) wanted |= .LocalUpdate;
			if (Wants(.LocalLateUpdate)) wanted |= .LocalLateUpdate;
			GameObject.Scene?.SetCallbacks(this, wanted);
			// Never run Awake/OnEnable/Start when serialized state could not
			// be restored. Otherwise a broken scene could silently initialize
			// networked gameplay with the wrong field values.
			if (!CSharpRuntime.ApplyFields(mInstance, fieldOverrides))
			{
				ReleaseManaged();
				return;
			}
			ApplyReferences();
			if (!IsLoaded)
				return;
			// Found by a [FormerlyNamed] name: use the new one from now on (saved with the scene).
			let registered = scope String();
			if (CSharpRuntime.ReadScriptName(mInstance, registered) && !registered.IsEmpty && registered != scriptType)
			{
				Log.Warning(scope $"'{GameObject.Name}' names the script {scriptType}, which is now {registered} ([FormerlyNamed]). Save the scene to keep the new name.");
				scriptType.Set(registered);
				this.[Friend]mProfileSlot = -1; // The Profiler names it by its new name.
			}
			if (!CSharpRuntime.Dispatch(mInstance, .Awake))
				ReleaseManaged();
		}
	}

	public override void OnEnable()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Enable);
	}

	public override void Start()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Start);
	}

	public override void FixedUpdate()
	{
		if (IsLoaded && Wants(.FixedUpdate))
			CSharpRuntime.Dispatch(mInstance, .FixedUpdate, Time.FixedDeltaTime);
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (IsLoaded && (mCallbacks & CSharpRuntime.UpdateCallback) != 0)
			CSharpRuntime.Update(mInstance, input, deltaTime);
	}

	public override void EarlyUpdate(TickInput input, float deltaTime)
	{
		if (IsLoaded && (mCallbacks & CSharpRuntime.EarlyUpdateCallback) != 0)
			CSharpRuntime.TickPhase(mInstance, 0, input, deltaTime);
	}

	public override void LateUpdate(TickInput input, float deltaTime)
	{
		if (IsLoaded && (mCallbacks & CSharpRuntime.LateUpdateCallback) != 0)
			CSharpRuntime.TickPhase(mInstance, 2, input, deltaTime);
	}

	public override void LocalEarlyUpdate()
	{
		if (IsLoaded && Wants(.LocalEarlyUpdate))
			CSharpRuntime.Dispatch(mInstance, .LocalEarlyUpdate, Time.DeltaTime);
	}

	public override void LocalUpdate()
	{
		if (IsLoaded && Wants(.LocalUpdate))
			CSharpRuntime.Dispatch(mInstance, .LocalUpdate, Time.DeltaTime);
	}

	public override void LocalLateUpdate()
	{
		if (IsLoaded && Wants(.LocalLateUpdate))
			CSharpRuntime.Dispatch(mInstance, .LocalLateUpdate, Time.DeltaTime);
	}

	public override void OnGUI()
	{
		if (IsLoaded && Wants(.Gui))
			CSharpRuntime.Dispatch(mInstance, .Gui);
	}

	public override void OnDisable()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Disable);
	}

	// The callbacks below reach a script only while it runs (Play, or a built game): in the editor C# scripts are
	// not loaded outside Play.
	public override void OnValidate()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Validate);
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .DrawGizmos, selected ? 1 : 0);
	}

	public override void OnNetworkEvent(StringView name, float value)
	{
		if (IsLoaded)
			CSharpRuntime.NetworkEvent(mInstance, name, value);
	}

	// ---- [Saved] fields (SaveSystem) ----
	/// Whether the running script has [Saved] fields: read once, as the class cannot change while it runs.
	int8 mHasSaved = -1;

	public override bool HasSavedFields
	{
		get
		{
			if (!IsLoaded)
				return false;
			if (mHasSaved < 0)
			{
				let saved = scope String();
				mHasSaved = CSharpRuntime.ReadSavedFields(mInstance, saved) && !saved.IsEmpty ? 1 : 0;
			}
			return mHasSaved > 0;
		}
	}

	/// Each [Saved] field under its own name, as its Inspector text: a renamed or removed field is skipped on load.
	public override void SaveFields(SaveIO io)
	{
		if (!IsLoaded)
			return;
		let current = scope String();
		if (!CSharpRuntime.ReadSavedFields(mInstance, current))
			return;
		let loaded = scope String();
		for (let line in current.Split('\n', .RemoveEmptyEntries))
		{
			let tab = line.IndexOf('\t');
			if (tab <= 0)
				continue;
			let name = line.Substring(0, tab);
			String value = scope String(line.Substring(tab + 1));
			if (!io.Key(name))
				continue;
			io.Value(ref value);
			if (io.Reading && value != null)
				loaded.AppendF("{}\t{}\n", name, value);
		}
		if (io.Reading && !loaded.IsEmpty)
			CSharpRuntime.ApplyFields(mInstance, loaded);
	}

	public override void OnSaving()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Saving);
	}

	public override void OnLoaded()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Loaded);
	}

	public override void OnCollisionEnter(Collision collision)
	{
		if (IsLoaded)
			CSharpRuntime.Contact(mInstance, .CollisionEnter, collision.gameObject, collision.point, collision.normal, collision.relativeSpeed);
	}

	public override void OnCollisionStay(Collision collision)
	{
		if (IsLoaded)
			CSharpRuntime.Contact(mInstance, .CollisionStay, collision.gameObject, collision.point, collision.normal, collision.relativeSpeed);
	}

	public override void OnControllerHit(ControllerHit hit)
	{
		if (IsLoaded)
			CSharpRuntime.Contact(mInstance, .ControllerHit, hit.gameObject, hit.point, hit.normal, hit.moveVelocity.Length);
	}

	public override void OnTriggerStay(GameObject other)
	{
		if (IsLoaded)
			CSharpRuntime.Contact(mInstance, .TriggerStay, other);
	}

	public override void OnCollisionExit(Collision collision)
	{
		if (IsLoaded)
			CSharpRuntime.Contact(mInstance, .CollisionExit, collision.gameObject);
	}

	public override void OnTriggerEnter(GameObject other)
	{
		if (IsLoaded)
			CSharpRuntime.Contact(mInstance, .TriggerEnter, other);
	}

	public override void OnTriggerExit(GameObject other)
	{
		if (IsLoaded)
			CSharpRuntime.Contact(mInstance, .TriggerExit, other);
	}

	public override void OnDestroy()
	{
		ReleaseManaged();
	}

	public override void OnUnregister()
	{
		// A scene can be cleared in edit mode without an OnDestroy callback.
		ReleaseManaged();
	}

	void ReleaseManaged()
	{
		if (mInstance <= 0)
			return;
		CSharpRuntime.Detach(mInstance);
		mInstance = -1;
		mCallbacks = -1;
		mHasSaved = -1;
	}
}
