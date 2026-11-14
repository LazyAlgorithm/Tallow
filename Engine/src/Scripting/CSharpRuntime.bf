using System;
using System.IO;
using System.Reflection;

namespace Tallow;

/// Native CLR host and scene-handle bridge for trusted C# gameplay assemblies.
/// Scene objects remain owned by the Beef/Flecs engine. Managed scripts receive
/// only IDs, checked for every native call, never native GameObject pointers.
/// This is an experimental backend, not an untrusted assembly/mod loader.
static class CSharpRuntime
{
	[CRepr]
	struct Callbacks
	{
		public void* context;
		public function int32(void*, uint64, uint64) isAlive;
		public function int32(void*, uint64, uint64, float*) getPosition;
		public function int32(void*, uint64, uint64, float*) setPosition;
		public function void(void*, uint64, uint64) destroy;
		public function int32(void*, uint64, uint64) isMine;
		public function int32(void*, uint64, uint64, int32, float*) getTransform;
		public function int32(void*, uint64, uint64, int32, float*) setTransform;
		public function void*(void*, char8*) resolveApi;
		public function uint64(void*, uint64, char8*, int32) createSceneObject;
		public function uint64(void*, uint64, char8*, int32) findSceneObject;
		public function uint64(void*, uint64, char8*, int32) instantiatePrefab;
		public function int32(void*, uint64, uint64, int32, int32) canDispatch;
	}

	/// The engine drives all component callbacks, preserving native scheduling.
	public enum ManagedEvent : int32
	{
		Awake,
		Enable,
		Start,
		FixedUpdate,
		LocalUpdate,
		LateUpdate,
		Disable,
		Gui
	}

	[CRepr]
	public struct NativeTickInput
	{
		public float moveX;
		public float moveZ;
		public float yaw;
		public float pitch;
		public uint32 buttons;
		public uint32 previousButtons;
	}

	/// Exactly the 32-byte layout of tn_csharp_tick_batch_item.
    /// Only engine scheduling code creates this record.
    [CRepr]
    public struct NativeTickBatchItem
    {
        public int32 instance;
        public NativeTickInput input;
        public float deltaTime;
    }

	[CLink] static extern int32 tn_csharp_init(char8* runtimeConfig, char8* managedAssembly);
	[CLink] static extern int32 tn_csharp_set_callbacks(Callbacks* callbacks);
	[CLink] static extern int32 tn_csharp_load_game(char8* gameAssembly);
	[CLink] static extern int32 tn_csharp_unload_game();
	[CLink] static extern int32 tn_csharp_attach(char8* typeName, uint64 scene, uint64 entity);
	[CLink] static extern int32 tn_csharp_apply_fields(int32 instance, char8* values);
	[CLink] static extern int32 tn_csharp_tick(int32 instance, float deltaTime);
	[CLink] static extern int32 tn_csharp_dispatch(int32 instance, int32 eventId, float deltaTime);
    [CLink] static extern int32 tn_csharp_dispatch_batch(int32* instances, int32 count, int32 eventId, float deltaTime);
    [CLink] static extern int32 tn_csharp_dispatch_checked_batch(int32* instances, int32 count, int32 eventId, float deltaTime);
	[CLink] static extern int32 tn_csharp_update_input(int32 instance, NativeTickInput* input, float deltaTime);
    [CLink] static extern int32 tn_csharp_update_input_batch(NativeTickBatchItem* items, int32 count);
	[CLink] static extern int32 tn_csharp_detach(int32 instance);
	[CLink] static extern void tn_csharp_shutdown();
	[CLink] static extern char8* tn_csharp_error();

	static Scene sScene;
	static uint64 sSession;
	static bool sStarted;

	public static bool Ready => sStarted && sScene != null;
	public static uint64 Session => sSession;

	public static bool Initialize(StringView runtimeConfig, StringView managedAssembly)
	{
		if (sStarted)
			return true;
		let config = scope String(runtimeConfig);
		let assembly = scope String(managedAssembly);
		if (tn_csharp_init(config.CStr(), assembly.CStr()) == 0)
		{
			Log.Warning(scope $"Could not initialize C# gameplay: {StringView(tn_csharp_error())}");
			return false;
		}
		sStarted = true;
		return true;
	}

	/// Call before attaching components. Invalidate the scene before it is freed.
	public static bool BindScene(Scene scene)
	{
		if (!sStarted || scene == null)
			return false;
		sScene = scene;
		sSession++;
		if (sSession == 0)
			sSession++;
		function int32(void*, uint64, uint64) alive = => IsAlive;
		function int32(void*, uint64, uint64, float*) get = => GetPosition;
		function int32(void*, uint64, uint64, float*) set = => SetPosition;
		function void(void*, uint64, uint64) destroy = => Destroy;
		function int32(void*, uint64, uint64) mine = => IsMine;
		function int32(void*, uint64, uint64, int32, float*) getTransform = => GetTransform;
		function int32(void*, uint64, uint64, int32, float*) setTransform = => SetTransform;
		function void*(void*, char8*) resolver = => ResolveApi;
		function uint64(void*, uint64, char8*, int32) createObject = => CreateSceneObject;
		function uint64(void*, uint64, char8*, int32) findObject = => FindSceneObject;
		function uint64(void*, uint64, char8*, int32) spawnPrefab = => InstantiatePrefab;
		function int32(void*, uint64, uint64, int32, int32) canDispatch = => CanDispatch;
		Callbacks callbacks = .()
		{
			context = null,
			isAlive = alive,
			getPosition = get,
			setPosition = set,
			destroy = destroy,
			isMine = mine,
			getTransform = getTransform,
			setTransform = setTransform,
			resolveApi = resolver,
			createSceneObject = createObject,
			findSceneObject = findObject,
			instantiatePrefab = spawnPrefab,
			canDispatch = canDispatch
		};
		if (tn_csharp_set_callbacks(&callbacks) == 0)
		{
			Log.Warning(scope $"Could not bind C# scene callbacks: {StringView(tn_csharp_error())}");
			sScene = null;
			return false;
		}
		return true;
	}

	public static void UnbindScene(Scene scene)
	{
		if (sScene != scene)
			return;
		sScene = null;
		sSession++;
	}

	public static int32 LoadGame(StringView trustedGameAssembly)
	{
		if (!Ready)
			return -1;
		let path = scope String(trustedGameAssembly);
		let count = tn_csharp_load_game(path.CStr());
		if (count < 0)
			Log.Error(scope $"Could not load C# gameplay: {StringView(tn_csharp_error())}");
		return count;
	}

	/// Release the trusted game assembly before recompilation or a new Play session.
	/// Native CSharpBehaviour instances must have been detached first.
	public static bool UnloadGame()
	{
		if (!sStarted)
			return true;
		if (tn_csharp_unload_game() != 0)
			return true;
		Log.Warning(scope $"C# game unload failed: {StringView(tn_csharp_error())}");
		return false;
	}

	/// Start an already-built trusted game inside a precompiled native engine.
	/// The same entry point is shared by Editor Play and the standalone runner.
	/// Neither needs to compile engine or editor sources.
	public static bool StartTrustedGame(Scene scene, StringView engineRoot, StringView projectPath)
	{
		let config = scope $"{engineRoot}/Managed/Tallow.ManagedRuntime/bin/Debug/net11.0/Tallow.ManagedRuntime.runtimeconfig.json";
		let runtime = scope $"{engineRoot}/Managed/Tallow.ManagedRuntime/bin/Debug/net11.0/Tallow.ManagedRuntime.dll";
		let game = scope $"{projectPath}/.tallow-csharp/bin/Tallow.Game/Tallow.Game.dll";
		if (!File.Exists(config) || !File.Exists(runtime) || !File.Exists(game))
		{
			Log.Error("C# runtime or compiled game assembly is missing. Build the C# project with the .NET SDK before Play.");
			return false;
		}
		if (!Initialize(config, runtime) || !BindScene(scene))
			return false;
		if (LoadGame(game) < 0)
		{
			UnloadGame();
			UnbindScene(scene);
			return false;
		}
		return true;
	}

	/// Call after Scene.StopPlay: all managed components must be detached first.
	public static void EndTrustedGame(Scene scene)
	{
		if (Ready && sScene == scene)
		{
			UnloadGame();
			UnbindScene(scene);
		}
	}

	/// Returns a managed instance ID; negative when the C# script failed.
	public static int32 Attach(StringView className, GameObject gameObject)
	{
		if (!Ready || gameObject == null || gameObject.Scene != sScene)
			return -1;
		let typeName = scope String(className);
		let instance = tn_csharp_attach(typeName.CStr(), sSession, gameObject.Id);
		if (instance < 0)
			Log.Error(scope $"Could not attach {className}: {StringView(tn_csharp_error())}");
		return instance;
	}

	public static bool Update(int32 instance, float deltaTime)
	{
		if (!Ready || instance < 0)
			return false;
		if (tn_csharp_tick(instance, deltaTime) != 0)
			return true;
		Log.Warning(scope $"C# gameplay update failed: {StringView(tn_csharp_error())}");
		return false;
	}

	/// Dispatch lifecycle callbacks when Scene invokes the corresponding Component callback.
	public static bool Dispatch(int32 instance, ManagedEvent eventId, float deltaTime = 0)
	{
		if (!Ready || instance <= 0)
			return false;
		if (tn_csharp_dispatch(instance, (int32)eventId, deltaTime) > 0)
			return true;
		Log.Warning(scope $"C# component callback failed: {StringView(tn_csharp_error())}");
		return false;
	}

	/// Future scheduler-only entrypoint. Do not pre-collect callbacks that
    /// could be disabled/destroyed by earlier scripts in the same batch.
    public static bool DispatchBatch(Span<int32> instances, ManagedEvent eventId, float deltaTime = 0)
    {
        if (!Ready)
            return false;
        if (instances.Length == 0)
            return true;
        if (instances.Length > 4096)
            return false;
        int32 result = tn_csharp_dispatch_batch(instances.Ptr, (int32)instances.Length, (int32)eventId, deltaTime);
        if (result == instances.Length)
            return true;
        Log.Warning(scope $"C# batch callback failed: {StringView(tn_csharp_error())}");
        return false;
    }

    /// Native scheduling primitive: callback eligibility is rechecked in
    /// the scene before each managed script after earlier callbacks mutate it.
    /// Use only for contiguous, ordered Fixed/LateUpdate groups; never for
    /// Awake/Start/Enable, and preserve per-component profiler fallback.
    public static bool DispatchCheckedBatch(Span<int32> instances,
        ManagedEvent eventId, float deltaTime)
    {
        if (!Ready || (eventId != .FixedUpdate && eventId != .LateUpdate))
            return false;
        if (instances.Length == 0)
            return true;
        if (instances.Length > 4096)
            return false;
        let result = tn_csharp_dispatch_checked_batch(instances.Ptr,
            (int32)instances.Length, (int32)eventId, deltaTime);
        if (result == instances.Length)
            return true;
        Log.Warning(scope $"Checked C# scene batch failed: {StringView(tn_csharp_error())}");
        return false;
    }

    /// Send the exact networked TickInput, including previous button state for Pressed/Released.
	public static bool Update(int32 instance, TickInput input, float deltaTime)
	{
		if (!Ready || instance <= 0)
			return false;
		NativeTickInput native = .()
		{
			moveX = input.raw.moveX,
			moveZ = input.raw.moveZ,
			yaw = input.raw.yaw,
			pitch = input.raw.pitch,
			buttons = input.raw.buttons,
			previousButtons = input.previous.buttons
		};
		if (tn_csharp_update_input(instance, &native, deltaTime) > 0)
			return true;
		Log.Warning(scope $"C# gameplay update failed: {StringView(tn_csharp_error())}");
		return false;
	}

	/// Trusted engine-only batching primitive. The caller supplies one
    /// session-validated, eligible script ID and corresponding network input
    /// per entry; the managed host does not read local device input.
    public static bool UpdateBatch(Span<NativeTickBatchItem> items)
    {
        if (!Ready)
            return false;
        if (items.Length == 0)
            return true;
        if (items.Length > 4096)
            return false;
        let result = tn_csharp_update_input_batch(items.Ptr, (int32)items.Length);
        if (result == items.Length)
            return true;
        Log.Warning(scope $"C# network input batch failed: {StringView(tn_csharp_error())}");
        return false;
    }

	/// Apply serialized public field overrides to a trusted script, including
	/// while playing. The native component owns these settings for scene files.
	public static bool ApplyFields(int32 instance, StringView values)
	{
		if (!Ready || instance <= 0 || values.IsEmpty)
			return true;
		let text = scope String(values);
		if (tn_csharp_apply_fields(instance, text.CStr()) > 0)
			return true;
		Log.Warning(scope $"C# Inspector field initialization failed: {StringView(tn_csharp_error())}");
		return false;
	}

	public static void Detach(int32 instance)
	{
		if (sStarted && instance > 0 && tn_csharp_detach(instance) == 0)
			Log.Warning(scope $"C# component cleanup failed: {StringView(tn_csharp_error())}");
	}

	public static void Shutdown()
	{
		if (sStarted)
			tn_csharp_shutdown();
		sStarted = false;
		sScene = null;
		sSession++;
	}

	// Shared with generated, session-safe physics bindings. Keep all scene
	// ownership checks in the existing trusted C# runtime.
	public static Scene PhysicsScene(uint64 scene) =>
		Ready && scene == sSession ? sScene : null;

	public static GameObject PhysicsObject(uint64 scene, uint64 entity) => Find(scene, entity);

	static GameObject Find(uint64 scene, uint64 entity)
	{
		if (sScene == null || scene != sSession || entity > uint32.MaxValue)
			return null;
		let gameObject = sScene.FindById((uint32)entity);
		if (gameObject == null || gameObject.IsDestroyed)
			return null;
		return gameObject;
	}

	/// Generated wrappers are exported and reflected by Beef. Return their
	/// function pointers once per managed wrapper, never reflect on every call.
	static void* ResolveApi(void* context, char8* symbol)
	{
		if (symbol == null)
			return null;
		let name = StringView(symbol);
		if (!name.StartsWith("CSharpApi_") && !name.StartsWith("CSharpApiVersion_"))
			return null;
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type == null)
				continue;
			for (let method in type.GetMethods(.Static | .Public | .DeclaredOnly))
			{
				if (method.Name == name &&
					(method.GetCustomAttribute<CSharpApiExportAttribute>() case .Ok))
					return method.Ptr;
			}
		}
		return null;
	}

	// Scene calls never expose native object pointers. The session token
	// prevents an old managed Scene from targeting a newer scene.
	static bool ValidSceneName(uint64 session, char8* name, int32 length) =>
		sScene != null && session == sSession && sSession != 0 &&
		name != null && length > 0 && length <= 4096;

	static uint64 CreateSceneObject(void* context, uint64 session, char8* name, int32 length)
	{
		if (!ValidSceneName(session, name, length))
			return 0;
		let created = sScene.CreateGameObject(.(name, length));
		return created != null ? created.Id : 0;
	}

	static uint64 FindSceneObject(void* context, uint64 session, char8* name, int32 length)
	{
		if (!ValidSceneName(session, name, length))
			return 0;
		let found = sScene.Find(.(name, length));
		return (found != null && !found.IsDestroyed) ? (uint64)found.Id : 0;
	}

	static uint64 InstantiatePrefab(void* context, uint64 session, char8* path, int32 length)
	{
		if (!ValidSceneName(session, path, length))
			return 0;
		// Prefab.Instantiate already enforces network authority and ownership.
		let created = Prefab.Instantiate(sScene, .(path, length));
		return (created != null && !created.IsDestroyed) ? (uint64)created.Id : 0;
	}

	/// Used by native engine-build CI to ensure generated wrappers really
	/// exist in Beef reflection; mere source text/manifest presence is not enough.
	public static bool HasGeneratedApi(StringView symbol)
	{
		let name = scope String(symbol);
		return ResolveApi(null, name.CStr()) != null;
	}

    /// Called from .NET between callbacks. The scene owns eligibility,
    /// including registration, Start, component Enabled and parent Active.
    /// Resolve by exact managed instance, not by script type (duplicates).
    static int32 CanDispatch(void* context, uint64 session, uint64 entity,
        int32 instance, int32 eventId)
    {
        if (!Ready || (eventId != (int32)ManagedEvent.FixedUpdate &&
                       eventId != (int32)ManagedEvent.LateUpdate))
            return 0;
        let obj = Find(session, entity);
        if (obj == null)
            return 0;
        for (let component in obj.Components)
        {
            if (let script = component as CSharpBehaviour)
            {
                if (script.ManagedInstance == instance)
                    return script.[Friend]mRegistered &&
                        script.[Friend]mStarted && script.IsActiveAndEnabled ? 1 : 0;
            }
        }
        return 0;
    }

	static int32 IsAlive(void* context, uint64 scene, uint64 entity) => Find(scene, entity) != null ? 1 : 0;

	/// One native call per operation: each callback validates the live scene/entity
	/// handle and returns success, avoiding a separate isAlive round trip.
	static int32 GetPosition(void* context, uint64 scene, uint64 entity, float* xyz)
	{
		if (xyz == null)
			return 0;
		let gameObject = Find(scene, entity);
		if (gameObject == null)
			return 0;
		let position = gameObject.Transform.Position;
		xyz[0] = position.x;
		xyz[1] = position.y;
		xyz[2] = position.z;
		return 1;
	}

	static int32 SetPosition(void* context, uint64 scene, uint64 entity, float* xyz)
	{
		if (xyz == null)
			return 0;
		let gameObject = Find(scene, entity);
		if (gameObject == null)
			return 0;
		gameObject.Transform.Position = .(xyz[0], xyz[1], xyz[2]);
		return 1;
	}

	/// Matches C# TransformChannel and uses Beef for parent-aware maths.
	static int32 GetTransform(void* context, uint64 scene, uint64 entity, int32 channel, float* values)
	{
		if (values == null)
			return 0;
		let gameObject = Find(scene, entity);
		if (gameObject == null)
			return 0;
		let transform = gameObject.Transform;
		if (channel == 12 || channel == 13)
		{
			Vector3 point = .(values[0], values[1], values[2]);
			Vector3 result = channel == 12 ?
				transform.TransformPoint(point) : transform.InverseTransformPoint(point);
			values[0] = result.x;
			values[1] = result.y;
			values[2] = result.z;
			values[3] = 0;
			return 1;
		}
		values[0] = 0;
		values[1] = 0;
		values[2] = 0;
		values[3] = 0;
		if (channel == 2 || channel == 3)
		{
			Quaternion q = channel == 2 ? transform.Rotation : transform.LocalRotation;
			values[0] = q.x;
			values[1] = q.y;
			values[2] = q.z;
			values[3] = q.w;
			return 1;
		}
		Vector3 v = .Zero;
		switch (channel)
		{
		case 1: v = transform.LocalPosition;
		case 4: v = transform.LocalScale;
		case 5: v = transform.WorldScale;
		case 6: v = transform.EulerAngles;
		case 7: v = transform.LocalEulerAngles;
		case 8: v = transform.Forward;
		case 9: v = transform.Right;
		case 10: v = transform.Up;
		default: return 0;
		}
		values[0] = v.x;
		values[1] = v.y;
		values[2] = v.z;
		return 1;
	}

	static int32 SetTransform(void* context, uint64 scene, uint64 entity, int32 channel, float* values)
	{
		if (values == null)
			return 0;
		let gameObject = Find(scene, entity);
		if (gameObject == null)
			return 0;
		let transform = gameObject.Transform;
		Vector3 v = .(values[0], values[1], values[2]);
		Quaternion q = .(values[0], values[1], values[2], values[3]);
		switch (channel)
		{
		case 1: transform.LocalPosition = v;
		case 2: transform.Rotation = q.Normalized;
		case 3: transform.LocalRotation = q.Normalized;
		case 4: transform.LocalScale = v;
		case 6: transform.EulerAngles = v;
		case 7: transform.LocalEulerAngles = v;
		case 11: transform.LookAt(v);
		default: return 0;
		}
		return 1;
	}

	static void Destroy(void* context, uint64 scene, uint64 entity)
	{
		let gameObject = Find(scene, entity);
		if (gameObject != null)
			gameObject.Scene.Destroy(gameObject);
	}

	static int32 IsMine(void* context, uint64 scene, uint64 entity)
	{
		let gameObject = Find(scene, entity);
		if (gameObject == null)
			return 0;
		if (gameObject.Scene.Network == null)
			return 1;
		let identity = gameObject.GetComponent<NetworkIdentity>();
		return identity && identity.IsOwner ? 1 : 0;
	}
}
