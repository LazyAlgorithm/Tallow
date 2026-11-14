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

	/// Preserve unrelated fields and overwrite a single field's value safely.
	public void WriteEditorField(StringView name, StringView value)
	{
		if (name.IsEmpty || name.Contains('\t') || name.Contains('\n') ||
			value.Contains('\t') || value.Contains('\n'))
			return;
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
		fieldOverrides.Set(updated);
		if (IsLoaded)
			CSharpRuntime.ApplyFields(mInstance, fieldOverrides);
	}


	public override void Awake()
	{
		if (scriptType.IsEmpty || !CSharpRuntime.Ready)
			return;
		mInstance = CSharpRuntime.Attach(scriptType, GameObject);
		if (mInstance > 0)
		{
			// Public C# fields are initialized before the first lifecycle callback.
			CSharpRuntime.ApplyFields(mInstance, fieldOverrides);
			CSharpRuntime.Dispatch(mInstance, .Awake);
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
