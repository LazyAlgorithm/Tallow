using System;

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
		public function void(void*, uint64, uint64, float*) getPosition;
		public function void(void*, uint64, uint64, float*) setPosition;
		public function void(void*, uint64, uint64) destroy;
		public function int32(void*, uint64, uint64) isMine;
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
	struct NativeTickInput
	{
		public float moveX;
		public float moveZ;
		public float yaw;
		public float pitch;
		public uint32 buttons;
		public uint32 previousButtons;
	}

	[CLink] static extern int32 tn_csharp_init(char8* runtimeConfig, char8* managedAssembly);
	[CLink] static extern int32 tn_csharp_set_callbacks(Callbacks* callbacks);
	[CLink] static extern int32 tn_csharp_load_game(char8* gameAssembly);
	[CLink] static extern int32 tn_csharp_attach(char8* typeName, uint64 scene, uint64 entity);
	[CLink] static extern int32 tn_csharp_tick(int32 instance, float deltaTime);
	[CLink] static extern int32 tn_csharp_dispatch(int32 instance, int32 eventId, float deltaTime);
	[CLink] static extern int32 tn_csharp_update_input(int32 instance, NativeTickInput* input, float deltaTime);
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
		function void(void*, uint64, uint64, float*) get = => GetPosition;
		function void(void*, uint64, uint64, float*) set = => SetPosition;
		function void(void*, uint64, uint64) destroy = => Destroy;
		function int32(void*, uint64, uint64) mine = => IsMine;
		Callbacks callbacks = .()
		{
			context = null,
			isAlive = alive,
			getPosition = get,
			setPosition = set,
			destroy = destroy,
			isMine = mine
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

	static GameObject Find(uint64 scene, uint64 entity)
	{
		if (sScene == null || scene != sSession || entity > uint32.MaxValue)
			return null;
		let gameObject = sScene.FindById((uint32)entity);
		return gameObject != null && !gameObject.IsDestroyed ? gameObject : null;
	}

	static int32 IsAlive(void* context, uint64 scene, uint64 entity) => Find(scene, entity) != null ? 1 : 0;

	static void GetPosition(void* context, uint64 scene, uint64 entity, float* xyz)
	{
		if (xyz == null)
			return;
		let gameObject = Find(scene, entity);
		if (gameObject == null)
			return;
		let position = gameObject.Transform.Position;
		xyz[0] = position.x;
		xyz[1] = position.y;
		xyz[2] = position.z;
	}

	static void SetPosition(void* context, uint64 scene, uint64 entity, float* xyz)
	{
		if (xyz == null)
			return;
		let gameObject = Find(scene, entity);
		if (gameObject != null)
			gameObject.Transform.Position = .(xyz[0], xyz[1], xyz[2]);
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
