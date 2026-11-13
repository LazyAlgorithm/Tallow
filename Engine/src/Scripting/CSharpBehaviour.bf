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
	public SharedString scriptType;

	int32 mInstance = -1;

	/// The managed component is owned by this native component, not the scene's ECS memory.
	public bool IsLoaded => mInstance > 0 && CSharpRuntime.Ready;

	public override void Awake()
	{
		if (scriptType.IsEmpty || !CSharpRuntime.Ready)
			return;
		mInstance = CSharpRuntime.Attach(scriptType, GameObject);
		if (mInstance > 0)
			CSharpRuntime.Dispatch(mInstance, .Awake);
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
