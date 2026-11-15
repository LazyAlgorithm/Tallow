using System;

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
	/// Edited field values: one trusted field name + numeric value per line.
	/// SharedString is handled by Tallow's existing scene/prefab serializer.
	[HideInInspector] public SharedString fieldOverrides;

	int32 mInstance = -1;

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
		return true;
	}


	public override void Awake()
	{
		if (scriptType.IsEmpty || !CSharpRuntime.Ready)
			return;
		mInstance = CSharpRuntime.Attach(scriptType, GameObject);
		if (mInstance > 0)
		{
			// Never run Awake/OnEnable/Start when serialized state could not
			// be restored. Otherwise a broken scene could silently initialize
			// networked gameplay with the wrong field values.
			if (!CSharpRuntime.ApplyFields(mInstance, fieldOverrides))
			{
				ReleaseManaged();
				return;
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
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .FixedUpdate, Time.FixedDeltaTime);
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (IsLoaded)
			CSharpRuntime.Update(mInstance, input, deltaTime);
	}

	public override void OnLocalUpdate()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .LocalUpdate);
	}

	public override void LateUpdate()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .LateUpdate, Time.DeltaTime);
	}

	public override void OnGUI()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Gui);
	}

	public override void OnDisable()
	{
		if (IsLoaded)
			CSharpRuntime.Dispatch(mInstance, .Disable);
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
	}
}
