using System;
using System.Collections;
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
		LocalLateUpdate,
		Disable,
		Gui,
		LocalEarlyUpdate,
		Validate,
		/// OnDrawGizmos (deltaTime: 1 when the object is selected).
		DrawGizmos,
		Saving,
		Loaded,
		/// OnWorldStateChanged (deltaTime: from * 64 + to).
		WorldStateChanged
	}

	/// Exactly the 48-byte layout of tn_csharp_contact.
	[CRepr]
	public struct NativeContact
	{
		public int32 kind;
		public int32 hasOther;
		public uint64 other;
		public Vector3 point;
		public Vector3 normal;
		public float relativeSpeed;
		public float reserved;
	}

	public enum ContactKind : int32
	{
		CollisionEnter,
		CollisionExit,
		TriggerEnter,
		TriggerExit,
		CollisionStay,
		TriggerStay,
		ControllerHit
	}

	/// A running script's field values, for the editor during Play. allFields false: the Inspector's fields as
	/// "name\tvalue" lines in the scene's text; true: every instance field, "name\ttype\tvalue", read-only.
	public static bool ReadFields(int32 instance, bool allFields, String output) => ReadFields(instance, allFields ? 1 : 0, output);

	/// The full name a running script is registered under (after a [FormerlyNamed] rename, its new name).
	public static bool ReadScriptName(int32 instance, String output) => ReadFields(instance, 3, output);

	/// A running script's [Sync] fields as "name\tvalue" lines (NetworkSync shares them from the server).
	public static bool ReadSyncFields(int32 instance, String output) => ReadFields(instance, 2, output);

	/// A running script's [Saved] fields as "name\tvalue" lines (SaveSystem keeps them in saves).
	public static bool ReadSavedFields(int32 instance, String output) => ReadFields(instance, 4, output);

	/// OnNetworkEvent on a running script.
	/// A UI document handler on a script: 1 called, 0 no such method, -1 it threw (reported).
	public static int32 InvokeUI(int32 instance, StringView method, StringView elementId) =>
		tn_csharp_ui_invoke(instance, scope String(method).CStr(), scope String(elementId).CStr());

	public static bool NetworkEvent(int32 instance, StringView name, float value)
	{
		if (!Ready || instance <= 0)
			return false;
		if (tn_csharp_network_event(instance, scope String(name).CStr(), value) > 0)
			return true;
		ReportFailure(scope $"OnNetworkEvent {name}");
		return false;
	}

	static bool ReadFields(int32 instance, int32 mode, String output)
	{
		if (!Ready || instance <= 0)
			return false;
		char8[1024] small = ?;
		var needed = tn_csharp_read_fields(instance, mode, &small, small.Count);
		if (needed < 0)
			return false;
		if (needed < small.Count)
		{
			output.Append(StringView(&small, needed));
			return true;
		}
		let large = scope char8[needed + 1];
		let again = tn_csharp_read_fields(instance, mode, large.Ptr, (int32)large.Count);
		if (again < 0 || again > needed)
			return false;
		output.Append(StringView(large.Ptr, again));
		return true;
	}

	/// --csharp-field-dump FILE (tools/test_csharp_aot_fields.py, benchmark B29): every running C# script of the scene
	/// in object order, each as its script name, Inspector fields, all fields with types, [Sync] fields and saved
	/// fields, written to FILE. A JIT and a NativeAOT build of the same game must write the same file.
	public static void DumpFields(Scene scene, StringView path)
	{
		let text = scope String();
		int scripts = 0;
		if (scene != null)
		{
			for (int i = 0; i < scene.Objects.Count; i++)
			{
				let gameObject = scene.Objects[i];
				int index = 0;
				for (let component in gameObject.Components)
				{
					if (let behaviour = component as CSharpBehaviour)
					{
						text.AppendF("== {} {} #{}\n", i, gameObject.Name, index++);
						if (!behaviour.IsLoaded)
						{
							text.Append("(not loaded)\n");
							continue;
						}
						scripts++;
						int32[5] modes = .(3, 0, 1, 2, 4);
						StringView[5] titles = .("script", "inspector", "all", "sync", "saved");
						for (int m < 5)
						{
							let mode = modes[m];
							let title = titles[m];
							let fields = scope String();
							text.AppendF("-- {}{}\n", title, ReadFields(behaviour.ManagedInstance, mode, fields) ? "" : " (failed)");
							text.Append(fields);
							if (!fields.IsEmpty && !fields.EndsWith('\n'))
								text.Append('\n');
						}
					}
				}
			}
		}
		if (File.WriteAllText(path, text) case .Err)
			Log.Error(scope $"FIELDDUMP could not write {path}");
		else
			Log.Info(scope $"FIELDDUMP {scripts} scripts written to {path}");
	}

	/// --csharp-field-test (tools/test_csharp_ingame.py): reads Tests/CSharpInGame's running ApiChecks script from
	/// the native side, as the editor's Inspector does during Play, and logs INGAME PASS/FAIL lines.
	public static void RunFieldTest(Scene scene)
	{
		void Check(bool ok, StringView what)
		{
			if (ok)
				Log.Info(scope $"INGAME PASS {what}");
			else
				Log.Error(scope $"INGAME FAIL {what}");
		}
		let runner = scene?.Find("Runner");
		let behaviour = runner?.GetComponent<CSharpBehaviour>();
		Check(behaviour != null && behaviour.IsLoaded, "native side finds the running C# script");
		if (behaviour == null || !behaviour.IsLoaded)
			return;
		let fields = scope String();
		Check(ReadFields(behaviour.ManagedInstance, false, fields), "ReadFields (Inspector fields) succeeds");
		Check(fields.Contains("Speed\t3\n") && fields.Contains("Label\tfrom scene\n") && fields.Contains("Flag\tfalse\n"),
			"live Inspector values use the scene's text format");
		Check(fields.Contains("baseSecret\t7\n"), "live values include base-class [ShowInInspector] fields");
		// A list of [Serializable] items reads back item by item, "Name=value" parts escaped inside the list's own.
		Check(fields.Contains(@"Waves	2;Count=5\;Delay=0\;Kind=Second\;Name=x\\\;y;Count=3\;Delay=0.5\;Kind=First\;Name=" + "\n") &&
			fields.Contains(@"Waypoints	1;At=1,2,3\;Wait=true" + "\n"), "lists of [Serializable] items read back in the scene's format");
		Check(!fields.Contains("_tick\t"), "private unexposed fields stay out of the Inspector list");
		let all = scope String();
		Check(ReadFields(behaviour.ManagedInstance, true, all), "ReadFields (all fields) succeeds");
		Check(all.Contains("_tick\tint\t") && all.Contains("_helper\tHelper\t") && all.Contains("Label\tstring\t\"from scene\""),
			"the debug view lists private fields with types and values");
		// Editing during Play changes only the running script.
		Check(behaviour.WriteEditorField("Speed", "4.5"), "an Inspector edit applies during Play");
		fields.Clear();
		ReadFields(behaviour.ManagedInstance, false, fields);
		Check(fields.Contains("Speed\t4.5\n"), "the edit reads back live");
		all.Clear();
		ReadFields(behaviour.ManagedInstance, true, all);
		Check(all.Contains("_validations\tint\t1\n") && all.Contains("_speedWhenValidated\tfloat\t4.5\n"),
			"OnValidate runs once after an Inspector edit, with the new value set");
		Check(!behaviour.WriteEditorField("Speed", "not a number"), "a bad Inspector edit is refused");
		all.Clear();
		ReadFields(behaviour.ManagedInstance, true, all);
		Check(all.Contains("_validations\tint\t1\n"), "a refused edit does not run OnValidate");
		// The Scene view's gizmo pass (SceneView draws every component's gizmos, saying whether it is selected).
		behaviour.OnDrawGizmos(true);
		behaviour.OnDrawGizmos(false);
		behaviour.OnDrawGizmos(false);
		all.Clear();
		ReadFields(behaviour.ManagedInstance, true, all);
		Check(all.Contains("_gizmosSelected\tint\t1\n") && all.Contains("_gizmosUnselected\tint\t2\n"),
			"OnDrawGizmos runs with whether the object is selected, and can draw gizmos");
		// Reference fields are left out of saves and network sync (ids are local to this run and machine).
		let refProbe = scene.Find("RefProbe")?.GetComponent<CSharpBehaviour>();
		let saved = scope String();
		let synced = scope String();
		Check(refProbe != null && refProbe.IsLoaded && ReadFields(refProbe.ManagedInstance, 4, saved) &&
			ReadFields(refProbe.ManagedInstance, 2, synced) && saved.Contains("KeptNumber\t7\n") &&
			!saved.Contains("NotKept") && !synced.Contains("NotKept"),
			"object references are not saved or synced");
	}

	/// Runs a script's [Rpc] method received from the network. The managed side checks the method is an [Rpc] of
	/// that target and parses the arguments for its parameters before calling it.
	public static bool InvokeRpc(int32 instance, StringView method, StringView arguments, int32 target, int32 sender)
	{
		if (!Ready || instance <= 0)
			return false;
		if (tn_csharp_invoke_rpc(instance, scope String(method).CStr(), scope String(arguments).CStr(), target, sender) > 0)
			return true;
		ReportFailure(scope $"RPC {method}");
		return false;
	}

	/// A script threw (or a call into it failed). One Console error names the exception, where it was thrown and
	/// the line of the game's C# it came from (click it to open the file there), with the whole trace beneath.
	/// The same failure again only counts up on that entry. The script keeps running, as every other one does.
	static int LastIndexOf(StringView text, StringView find)
	{
		for (int i = text.Length - find.Length; i >= 0; i--)
			if (text.Substring(i, find.Length) == find)
				return i;
		return -1;
	}

	/// How often each distinct failure (by action and full text) has been reported.
	static Dictionary<String, int> sFailureCounts = new .() ~ DeleteDictionaryAndKeys!(_);

	/// Logs a managed failure. A script that throws every frame is reported in full once and then only as a
	/// periodic reminder, even when other failures come in between (the log merges only identical neighbours).
	static void ReportFailure(StringView action)
	{
		let text = StringView(tn_csharp_error());
		let key = scope String()..AppendF("{}\n{}", action, text);
		if (sFailureCounts.TryGetValueAlt(key, var count))
		{
			count++;
			sFailureCounts[key] = count;
			if (count % 600 == 0)
			{
				var first = text;
				let end = text.IndexOf('\n');
				if (end >= 0)
					first = text.Substring(0, end);
				Log.Warning(scope $"C# failure repeated {count} times (in {action}): {first}");
			}
			return;
		}
		if (sFailureCounts.Count >= 512)
		{
			for (let entry in sFailureCounts)
				delete entry.key;
			sFailureCounts.Clear();
		}
		sFailureCounts[new String(key)] = 1;
		var firstLine = text;
		let lineEnd = text.IndexOf('\n');
		if (lineEnd >= 0)
			firstLine = text.Substring(0, lineEnd);
		firstLine.TrimEnd();
		// "Dispatching C# component event: System.InvalidOperationException: message": from the exception's type on.
		var header = firstLine;
		let marker = firstLine.IndexOf("Exception: ");
		if (marker > 0)
		{
			var start = marker;
			while (start > 0 && firstLine[start - 1] != ' ' && firstLine[start - 1] != ':')
				start--;
			header = firstLine.Substring(start);
		}
		// The first frame in the game's own code: "   at Game.Player.Update() in /path/Player.cs:line 12".
		StringView frame = default;
		StringView file = default;
		int32 line = -1;
		for (var candidate in text.Split('\n'))
		{
			candidate.Trim();
			if (!candidate.StartsWith("at "))
				continue;
			let inAt = LastIndexOf(candidate, " in ");
			let lineAt = LastIndexOf(candidate, ":line ");
			if (inAt < 0 || lineAt < inAt)
				continue;
			let path = candidate.Substring(inAt + 4, lineAt - inAt - 4);
			if (!path.EndsWith(".cs") || path.Contains("/Managed/Tallow.") || path.Contains("\\Managed\\Tallow."))
				continue;
			frame = candidate.Substring(3, inAt - 3);
			file = path;
			line = (int32)SceneSerializer.ParseInt(candidate.Substring(lineAt + 6)) - 1;
			break;
		}
		let message = scope String();
		message.Append(header.IsEmpty ? (StringView)"C# script failed" : header);
		message.AppendF(" (in {}", action);
		if (!frame.IsEmpty)
		{
			let slash = Math.Max(file.LastIndexOf('/'), file.LastIndexOf('\\'));
			message.AppendF(", {} at {}:{}", frame, file.Substring(slash + 1), line + 1);
		}
		message.Append(')');
		message.Append('\n');
		message.Append(text);
		Log.Add(.Error, message, file, line);
	}

	/// A collision or trigger callback for one managed script. The other object must be in this session's scene.
	public static bool Contact(int32 instance, ContactKind kind, GameObject other, Vector3 point = default, Vector3 normal = default, float relativeSpeed = 0)
	{
		if (!Ready || instance <= 0)
			return false;
		NativeContact contact = .();
		contact.kind = (int32)kind;
		contact.hasOther = (other != null && other.Scene == sScene) ? 1 : 0;
		contact.other = contact.hasOther != 0 ? other.Id : 0;
		contact.point = point;
		contact.normal = normal;
		contact.relativeSpeed = relativeSpeed;
		if (tn_csharp_contact_event(instance, &contact) > 0)
			return true;
		ReportFailure("collision callback");
		return false;
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
	[CLink] static extern int32 tn_csharp_init_native(char8* library);
	[CLink] static extern int32 tn_csharp_set_callbacks(Callbacks* callbacks);
	[CLink] static extern int32 tn_csharp_load_game(char8* gameAssembly);
	[CLink] static extern int32 tn_csharp_use_dotnet_root(char8* root);
	[CLink] static extern void* tn_csharp_find_export(char8* name);
	[CLink] static extern int32 tn_csharp_unload_game();
	[CLink] static extern int32 tn_csharp_reload_game(char8* trustedGameDll);
	[CLink] static extern int32 tn_csharp_attach(char8* typeName, uint64 scene, uint64 entity);
	[CLink] static extern int32 tn_csharp_apply_fields(int32 instance, char8* values);
	[CLink] static extern int32 tn_csharp_tick(int32 instance, float deltaTime);
	[CLink] static extern int32 tn_csharp_dispatch(int32 instance, int32 eventId, float deltaTime);
    [CLink] static extern int32 tn_csharp_dispatch_batch(int32* instances, int32 count, int32 eventId, float deltaTime);
    [CLink] static extern int32 tn_csharp_dispatch_checked_batch(int32* instances, int32 count, int32 eventId, float deltaTime);
	[CLink] static extern int32 tn_csharp_update_input(int32 instance, NativeTickInput* input, float deltaTime);
	[CLink] static extern int32 tn_csharp_run_system(int32 index, uint64 session, uint64 entity, NativeTickInput* input, float deltaTime);
	[CLink] static extern int32 tn_csharp_tick_phase(int32 instance, int32 phase, NativeTickInput* input, float deltaTime);
    [CLink] static extern int32 tn_csharp_update_input_batch(NativeTickBatchItem* items, int32 count);
	[CLink] static extern int32 tn_csharp_contact_event(int32 instance, NativeContact* contact);
	[CLink] static extern int32 tn_csharp_read_fields(int32 instance, int32 mode, char8* buffer, int32 capacity);
	[CLink] static extern int32 tn_csharp_invoke_rpc(int32 instance, char8* method, char8* arguments, int32 target, int32 sender);
	[CLink] static extern int32 tn_csharp_detach(int32 instance);
	[CLink] static extern void tn_csharp_shutdown();
	[CLink] static extern char8* tn_csharp_error();
	[CLink] static extern int32 tn_csharp_network_event(int32 instance, char8* name, float value);
	[CLink] static extern int32 tn_csharp_ui_invoke(int32 instance, char8* method, char8* elementId);
	[CLink] static extern int32 tn_csharp_choose_team(int32 clientId);
	[CLink] static extern int32 tn_csharp_component_event(int32 instance, int32 kind, char8* name, float value);
	[CLink] static extern int32 tn_csharp_behavior_node(int32 handle, int32 phase, char8* className, uint64 session, uint64 entity, char8* values, float deltaTime);
	[CLink] static extern int32 tn_csharp_prediction_state(int32 instance, int32 mode, float* values);
	[CLink] static extern int32 tn_csharp_save_storage(int32 op, int32 task, char8* slot, uint8* data, int32 length);
	[CLink] static extern int32 tn_csharp_terrain_generator(int32 op, int32 handle, float x, float y, float z, float step, int32 samples, float* points, float* density, uint8* paint);
	[CRepr]
	struct GcStats
	{
		public int64 allocatedBytes, heapBytes;
		public int32 gen0, gen1, gen2, reserved;
		public int64 pauseNs;
	}

	[CLink] static extern int32 tn_csharp_pump(float deltaTime, GcStats* stats);

	static ProfilerMarker sAsyncMarker = .("C# await continuations", .Scripts);
	static int32 sAllocatedCounter = -1, sHeapCounter = -1, sCollectionsCounter = -1, sPauseCounter = -1;
	static GcStats sLastGc;
	static bool sHaveGc;

	/// Once a frame while the scene plays, after LateUpdate: C# game-time waits and await continuations. Also
	/// reports the managed heap to the Profiler (Memory): bytes allocated this frame, heap size, collections and
	/// time paused for them this frame.
	public static void Pump(Scene scene, float deltaTime)
	{
		if (!Ready || scene != sScene)
			return;
		GcStats stats = default;
		int32 result;
		using (sAsyncMarker.Sample())
			result = tn_csharp_pump(deltaTime, &stats);
		if (result <= 0)
			ReportFailure("async code");
		if (!Profiler.Enabled)
		{
			sHaveGc = false;
			return;
		}
		if (sAllocatedCounter < 0)
		{
			sAllocatedCounter = Profiler.Counter("C# allocated this frame", .Memory, "bytes");
			sHeapCounter = Profiler.Counter("C# heap", .Memory, "bytes");
			sCollectionsCounter = Profiler.Counter("C# garbage collections this frame", .Memory);
			sPauseCounter = Profiler.Counter("C# GC pause this frame", .Memory, "ms");
		}
		if (sHaveGc)
		{
			Profiler.Set(sAllocatedCounter, (double)Math.Max(stats.allocatedBytes - sLastGc.allocatedBytes, 0));
			Profiler.Set(sCollectionsCounter, (double)Math.Max(stats.gen0 - sLastGc.gen0, 0)); // Every collection counts gen 0.
			Profiler.Set(sPauseCounter, (double)Math.Max(stats.pauseNs - sLastGc.pauseNs, 0) / 1000000.0);
		}
		Profiler.Set(sHeapCounter, (double)stats.heapBytes);
		sLastGc = stats;
		sHaveGc = true;
	}

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
		// .NET put its own exception handler first, which ends the process at the leak check's breakpoint.
		CrashReports.HandleLeakChecksFirst();
		return true;
	}

	/// NativeAOT: the game's runtime, API and assemblies compiled into one native library, used instead of .NET.
	public static bool InitializeNative(StringView library)
	{
		if (sStarted)
			return IsNativeAot;
		let path = scope String(library);
		if (tn_csharp_init_native(path.CStr()) == 0)
		{
			Log.Error(scope $"Could not start this game's native C#: {StringView(tn_csharp_error())}");
			return false;
		}
		sStarted = true;
		IsNativeAot = true;
		return true;
	}

	/// Whether C# runs from a NativeAOT game library (a shipped game), not on .NET.
	public static bool IsNativeAot { get; private set; }

	/// The file name of a NativeAOT game library in Managed/Native.
	public static StringView NativeLibraryName
	{
		get
		{
#if BF_PLATFORM_WINDOWS
			return "TallowGame.dll";
#elif BF_PLATFORM_MACOS
			return "libTallowGame.dylib";
#else
			return "libTallowGame.so";
#endif
		}
	}

	/// Call before attaching components. Invalidate the scene before it is freed.
	public static bool BindScene(Scene scene)
	{
		if (!sStarted || scene == null)
			return false;
		sScene = scene;
		// A new play session reports its failures afresh.
		for (let entry in sFailureCounts)
			delete entry.key;
		sFailureCounts.Clear();
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

	/// The bound scene was emptied (SceneManager.Load during Play) and will
	/// hand out GameObject ids from 1 again. Start a new session so managed
	/// handles to the previous objects fail instead of aliasing new ones.
	/// Every managed script was detached by StopPlay before objects went.
	public static void SceneCleared(Scene scene)
	{
		if (sScene != scene || scene == null)
			return;
		sSession++;
		if (sSession == 0)
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
		else
			CSharpNetReload.Loaded(path);
		return count;
	}

	/// Release the trusted game assembly before recompilation or a new Play session.
	/// Native CSharpBehaviour instances must have been detached first.
	public static bool UnloadGame()
	{
		// Its ECS systems and team chooser go with it.
		CSharpEcsSystem.RemoveAll();
		CSharpMeshes.ReleaseAll();
		CSharpCompute.ReleaseAll();
		CSharpSaves.UseStorage(false);
		CSharpTerrainGenerator.StopAll();
		CSharpTextures.ReleaseAll();
		CSharpScenes.ReleaseAll();
		CSharpModeling.ReleaseAll();
		CSharpNetReload.Stopped();
		HasTeamChooser = false;
		if (!sStarted)
			return true;
		if (tn_csharp_unload_game() != 0)
			return true;
		Log.Warning(scope $"C# game unload failed: {StringView(tn_csharp_error())}");
		return false;
	}

	/// Hot reload while playing, between frames: the running scripts move to the newly built game at projectPath
	/// with their field values (see the managed ReloadGame); Awake and Start do not run again. ECS systems are made
	/// again; the team chooser is kept when it is a named method (a lambda is cleared: set it again). Returns how many scripts were kept, or -1
	/// when the new code could not load (the old keeps running, without its ECS systems).
	public static int32 ReloadGame(StringView projectPath) =>
		ReloadAssembly(scope $"{projectPath}/.tallow-csharp/bin/Tallow.Game/Tallow.Game.dll");

	/// ReloadGame from a Tallow.Game.dll anywhere (its assemblies in folders beside its own).
	public static int32 ReloadAssembly(StringView gameDll)
	{
		if (!Ready)
			return -1;
		// A client in a session keeps a change until the host reloads the same code (CSharpNetReload).
		if (CSharpNetReload.ShouldWait(sScene.Network, gameDll))
			return CSharpNetReload.Waiting;
		return ReloadNow(gameDll);
	}

	/// ReloadAssembly without waiting for the host.
	public static int32 ReloadNow(StringView gameDll)
	{
		if (!Ready)
			return -1;
		let game = scope String(gameDll);
		CSharpEcsSystem.RemoveAll();
		HasTeamChooser = false;
		// The old code's terrain generators stop (a script sets its generator again).
		CSharpTerrainGenerator.StopAll();
		let kept = tn_csharp_reload_game(game.CStr());
		if (kept < 0)
			Log.Error(scope $"C# hot reload failed; the old code keeps running: {StringView(tn_csharp_error())}");
		else
			CSharpNetReload.Reloaded(sScene.Network, game);
		for (let component in sScene.Components)
			if (let script = component as CSharpBehaviour)
				script.Reloaded();
		return kept;
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
			let missing = scope String();
			for (let path in StringView[3](config, runtime, game))
				if (!File.Exists(path))
					missing.AppendF("{}{}", missing.IsEmpty ? "" : ", ", path);
			Log.Error(scope $"C# runtime or compiled game assembly is missing ({missing}). Build the C# project with the .NET SDK before Play.");
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

	/// A built game: Managed/Runtime holds Tallow's managed runtime, Managed/Game the game's assemblies (one folder
	/// each), and dotnet/ beside them, when present, the .NET runtime the game ships with.
	public static bool StartPackagedGame(Scene scene, StringView gameFolder)
	{
#if BF_PLATFORM_WASM
		// In a browser the page has started .NET with the game's assemblies already loaded (tools/build_player.py
		// builds them into the page's .NET bundle); its start-up registered the runtime with the host.
		if (!Initialize("browser", "Tallow.ManagedRuntime") || !BindScene(scene))
			return false;
		if (LoadGame("Tallow.Game.dll") < 0)
		{
			UnloadGame();
			UnbindScene(scene);
			return false;
		}
		return true;
#else
		// NativeAOT export: one native library, no .NET, no game assemblies.
		let native = scope $"{gameFolder}/Managed/Native/{NativeLibraryName}";
		if (File.Exists(native))
		{
			if (!InitializeNative(native) || !BindScene(scene))
				return false;
			// Not a file that is loaded: it names the folder whose Tallow.Game.codeid says which code this is.
			if (LoadGame(scope $"{gameFolder}/Managed/Native/Tallow.Game.dll") < 0)
			{
				UnloadGame();
				UnbindScene(scene);
				return false;
			}
			return true;
		}
		let bundled = scope $"{gameFolder}/dotnet";
		if (Directory.Exists(bundled))
			tn_csharp_use_dotnet_root(bundled.CStr());
		let config = scope $"{gameFolder}/Managed/Runtime/Tallow.ManagedRuntime.runtimeconfig.json";
		let runtime = scope $"{gameFolder}/Managed/Runtime/Tallow.ManagedRuntime.dll";
		let game = scope $"{gameFolder}/Managed/Game/Tallow.Game/Tallow.Game.dll";
		if (!File.Exists(config) || !File.Exists(runtime) || !File.Exists(game))
		{
			Log.Error("This game's C# files are missing from its Managed folder. Build it again.");
			return false;
		}
		if (!Initialize(config, runtime))
		{
			if (!Directory.Exists(bundled))
				Log.Error(scope $"This game needs the .NET {RequiredDotNetMajor} runtime: https://dotnet.microsoft.com/download/dotnet/{RequiredDotNetMajor}.0");
			return false;
		}
		if (!BindScene(scene))
			return false;
		if (LoadGame(game) < 0)
		{
			UnloadGame();
			UnbindScene(scene);
			return false;
		}
		return true;
#endif
	}

#if BF_PLATFORM_WASM
	[CLink] static extern int32 tn_csharp_web_hosted();
	/// In a browser, a C# game is one whose page started .NET (and registered its runtime) before the engine.
	public static bool IsPackagedGame(StringView gameFolder) => tn_csharp_web_hosted() != 0;
#else
	/// A built game ships its C# in a Managed folder beside it.
	public static bool IsPackagedGame(StringView gameFolder) => File.Exists(scope $"{gameFolder}/Managed/Game/Tallow.Game/Tallow.Game.dll") ||
		File.Exists(scope $"{gameFolder}/Managed/Native/{NativeLibraryName}");
#endif

	public const int RequiredDotNetMajor = 11;

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
		ReportFailure("Update");
		return false;
	}

	/// Bits of CallbackMask for EarlyUpdate, Update and LateUpdate; the others are 1 << ManagedEvent.
	public const int32 UpdateCallback = 1 << 20;
	public const int32 EarlyUpdateCallback = 1 << 21;
	public const int32 LateUpdateCallback = 1 << 22;

	/// The per-frame callbacks (EarlyUpdate, Update, LateUpdate, their Local versions, FixedUpdate, OnGUI) the instance's
	/// class overrides, so the rest are not sent; -1 (all) when the runtime cannot say.
	public static int32 CallbackMask(int32 instance)
	{
		if (!Ready || instance <= 0)
			return -1;
		// 2 + mask; 1 is an older host that reduces every success to 1, which cannot say.
		let result = tn_csharp_dispatch(instance, 100, 0);
		return result >= 2 ? result - 2 : -1;
	}

	/// Dispatch lifecycle callbacks when Scene invokes the corresponding Component callback.
	public static bool Dispatch(int32 instance, ManagedEvent eventId, float deltaTime = 0)
	{
		if (!Ready || instance <= 0)
			return false;
		if (tn_csharp_dispatch(instance, (int32)eventId, deltaTime) > 0)
			return true;
		ReportFailure("callback");
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
        ReportFailure("callback");
        return false;
    }

    /// Native scheduling primitive: callback eligibility is rechecked in
    /// the scene before each managed script after earlier callbacks mutate it.
    /// Use only for contiguous, ordered Fixed/LateUpdate groups; never for
    /// Awake/Start/Enable, and preserve per-component profiler fallback.
    public static bool DispatchCheckedBatch(Span<int32> instances,
        ManagedEvent eventId, float deltaTime)
    {
        if (!Ready || (eventId != .FixedUpdate && eventId != .LocalLateUpdate))
            return false;
        if (instances.Length == 0)
            return true;
        if (instances.Length > 4096)
            return false;
        let result = tn_csharp_dispatch_checked_batch(instances.Ptr,
            (int32)instances.Length, (int32)eventId, deltaTime);
        if (result == instances.Length)
            return true;
        ReportFailure("callback");
        return false;
    }

	/// CallbackMask bits for OnSequenceEvent, OnDialogueEvent and OnTreeEvent (ComponentEvent kind 0, 1, 2).
	public const int32 SequenceEventCallback = 1 << 23, DialogueEventCallback = 1 << 24, TreeEventCallback = 1 << 25;
	/// CallbackMask bits for OnDialogueEnded and OnSequenceFinished (ComponentEvent kinds 5 and 6).
	public const int32 DialogueEndedCallback = 1 << 29, SequenceFinishedCallback = 1 << 30;

	/// A Sequence Player's, Dialogue Runner's or Behavior Tree Runner's named event (kind 0, 1, 2) on the C# scripts
	/// of the same object that override its callback.
	/// Runs a phase of a C# behaviour tree node (BTManagedNode): 0 start (values: its settings, separated by 0x1F),
	/// 1 tick, 2 end, 3 aborted, 4 the node is gone. Returns 1 running, 2 success, 3 failure.
	public static int32 BehaviorNodeCall(int32 handle, int32 phase, StringView className, GameObject gameObject, StringView values, float deltaTime)
	{
		if (!Ready)
			return 3;
		let result = tn_csharp_behavior_node(handle, phase, scope String(className).CStr(), sSession, gameObject?.Id ?? 0,
			scope String(values).CStr(), deltaTime);
		if (result < 0)
		{
			ReportFailure(scope $"behaviour node {className}");
			return 3;
		}
		return result;
	}

	public static void ComponentEvent(GameObject gameObject, int32 kind, StringView name, float value = 0)
	{
		if (!Ready || gameObject == null)
			return;
		let bit = kind == 0 ? SequenceEventCallback : kind == 1 ? DialogueEventCallback : kind == 5 ? DialogueEndedCallback :
			kind == 6 ? SequenceFinishedCallback : TreeEventCallback;
		String text = null;
		// By index: a script may add a component while handling the event.
		for (int i = 0; i < gameObject.Components.Count; i++)
		{
			let script = gameObject.Components[i] as CSharpBehaviour;
			if (script == null || !script.IsLoaded || (script.[Friend]mCallbacks & bit) == 0)
				continue;
			if (text == null)
				text = scope:: String(name);
			if (tn_csharp_component_event(script.ManagedInstance, kind, text.CStr(), value) <= 0)
				ReportFailure(kind == 0 ? "OnSequenceEvent" : kind == 1 ? "OnDialogueEvent" : kind == 5 ? "OnDialogueEnded" :
					kind == 6 ? "OnSequenceFinished" : "OnTreeEvent");
		}
	}

	/// A C# TerrainGenerator (see tn_csharp_terrain_generator): below 0 when it is not there or threw. From any thread.
	public static int32 TerrainGeneratorCall(int32 op, int32 handle, Vector3 origin, float step, int32 samples, float* density, uint8* paint, float* points = null)
	{
		if (!Ready)
			return -1;
		return tn_csharp_terrain_generator(op, handle, origin.x, origin.y, origin.z, step, samples, points, density, paint);
	}

	/// The game's C# SaveStorage (see tn_csharp_save_storage for op): below 0 when it is not there or threw.
	public static int32 SaveStorageCall(int32 op, int32 task, StringView slot, Span<uint8> data)
	{
		if (!Ready)
			return -1;
		let result = tn_csharp_save_storage(op, task, scope String(slot).CStr(), data.Ptr, (int32)data.Length);
		if (result < 0)
			ReportFailure("SaveStorage");
		return result;
	}

	/// CallbackMask bit for the prediction state hooks (Capture/Prepare/RestorePredictionState).
	public const int32 PredictionCallback = 1 << 26;

	/// The C# scripts' prediction state hooks on an object (mode 0 capture, 1 prepare, 2 restore), as NetworkIdentity
	/// calls NetworkBehaviour's. A capture over a Rigidbody's state (fromBody) keeps only the two spare vectors the
	/// scripts write, so the body's real velocities stay.
	public static void PredictionState(GameObject gameObject, int32 mode, ref BodyState state, bool fromBody = false)
	{
		if (!Ready || gameObject == null)
			return;
		for (let component in gameObject.Components)
		{
			let script = component as CSharpBehaviour;
			if (script == null || !script.IsLoaded || (script.[Friend]mCallbacks & PredictionCallback) == 0)
				continue;
			float[22] values = .(state.position.x, state.position.y, state.position.z,
				state.rotation.x, state.rotation.y, state.rotation.z, state.rotation.w,
				state.linearVelocity.x, state.linearVelocity.y, state.linearVelocity.z,
				state.angularVelocity.x, state.angularVelocity.y, state.angularVelocity.z,
				state.prediction0.x, state.prediction0.y, state.prediction0.z, state.prediction0.w,
				state.prediction1.x, state.prediction1.y, state.prediction1.z, state.prediction1.w, fromBody ? 1 : 0);
			if (tn_csharp_prediction_state(script.ManagedInstance, mode, &values) <= 0)
			{
				ReportFailure(mode == 0 ? "CapturePredictionState" : mode == 1 ? "PreparePredictionState" : "RestorePredictionState");
				continue;
			}
			if (mode != 0)
				continue;
			if (!fromBody)
			{
				state.position = .(values[0], values[1], values[2]);
				state.rotation = .(values[3], values[4], values[5], values[6]);
				state.linearVelocity = .(values[7], values[8], values[9]);
				state.angularVelocity = .(values[10], values[11], values[12]);
			}
			state.prediction0 = .(values[13], values[14], values[15], values[16]);
			state.prediction1 = .(values[17], values[18], values[19], values[20]);
		}
	}

	/// CallbackMask bits for OnClientJoined and OnClientLeft (ComponentEvent kinds 3 and 4).
	public const int32 ClientJoinedCallback = 1 << 27, ClientLeftCallback = 1 << 28;

	/// Server: a client joined or left (kind 3 or 4); every C# script in the scene that overrides the callback hears it.
	public static void ClientEvent(Scene scene, int32 kind, int32 clientId)
	{
		if (!Ready || scene == null)
			return;
		let bit = kind == 3 ? ClientJoinedCallback : ClientLeftCallback;
		let scripts = scope List<CSharpBehaviour>();
		for (let component in scene.Components)
			if (let script = component as CSharpBehaviour)
				if (script.IsLoaded && (script.[Friend]mCallbacks & bit) != 0)
					scripts.Add(script);
		// Collected first: a script may spawn or destroy objects while handling it.
		for (let script in scripts)
			if (script.IsLoaded && tn_csharp_component_event(script.ManagedInstance, kind, "", clientId) <= 0)
				ReportFailure(kind == 3 ? "OnClientJoined" : "OnClientLeft");
	}

	/// C# set Network.ChooseTeam.
	public static bool HasTeamChooser;

	/// A joining player's team from C#'s Network.ChooseTeam, -1 when there is none or it threw (reported).
	public static int32 ChooseTeam(int32 clientId)
	{
		if (!Ready || !HasTeamChooser)
			return -1;
		let team = tn_csharp_choose_team(clientId);
		if (team < 0)
			ReportFailure("Network.ChooseTeam");
		return team;
	}

	/// Runs a C# EcsSystem (CSharpEcsSystem): on entity, or (0) on every bare entity with its data no client owns.
	public static bool RunSystem(int32 index, uint64 session, uint64 entity, TickInput input, float deltaTime)
	{
		if (!Ready)
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
		if (tn_csharp_run_system(index, session, entity, &native, deltaTime) > 0)
			return true;
		ReportFailure("an ECS system");
		return false;
	}

	/// EarlyUpdate (phase 0), Update (1) or LateUpdate (2) with the tick's controls.
	public static bool TickPhase(int32 instance, int32 phase, TickInput input, float deltaTime)
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
		if (tn_csharp_tick_phase(instance, phase, &native, deltaTime) > 0)
			return true;
		ReportFailure(phase == 0 ? "EarlyUpdate" : "LateUpdate");
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
		ReportFailure("Update");
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
        ReportFailure("Update");
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

	/// Whether the object is still in the scene at all, even if destroyed this frame (and so still drawn).
	public static bool StillInScene(uint64 scene, uint64 entity) =>
		sScene != null && scene == sSession && entity <= uint32.MaxValue && sScene.FindById((uint32)entity) != null;

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
	/// The C# API's symbol resolver, for the editor's scripts (the one a game gets when its scene binds): it finds
	/// the CSharpApi_ exports, so editor scripts can call Tallow.API's scene-free calls (drawing, the modelling API).
	public static void* ResolveApiEntry(void* context, char8* symbol) => ResolveApi(context, symbol);

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
		// The precompiled player (Player/) does not reflect the generated wrappers' types, but exports exactly
		// these symbols (its link flags name the CSharpApi prefix).
		return tn_csharp_find_export(symbol);
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
                       eventId != (int32)ManagedEvent.LocalLateUpdate))
            return 0;
        let obj = Find(session, entity);
        if (obj == null)
            return 0;
        for (let component in obj.Components)
        {
            if (let script = component as CSharpBehaviour)
            {
                if (script.ManagedInstance == instance)
                {
                    let eligible = script.[Friend]mRegistered &&
                        script.[Friend]mStarted && script.IsActiveAndEnabled;
                    return eligible ? 1 : 0;
                }
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
		// A NaN position poisons the transform hierarchy and the physics body.
		if (!xyz[0].IsFinite || !xyz[1].IsFinite || !xyz[2].IsFinite)
			return 1;
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
		// Ignore non-finite values and zero-length rotations rather than
		// store NaN in the transform (Normalized of a zero quaternion is NaN).
		if (!v.x.IsFinite || !v.y.IsFinite || !v.z.IsFinite)
			return 1;
		if ((channel == 2 || channel == 3) &&
			(!q.w.IsFinite || q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w < 1.0e-12f))
			return 1;
		switch (channel)
		{
		case 1: transform.LocalPosition = v;
		case 2: transform.Rotation = q.Normalized;
		case 3: transform.LocalRotation = q.Normalized;
		case 4: transform.LocalScale = v;
		case 6: transform.EulerAngles = v;
		case 7: transform.LocalEulerAngles = v;
		case 11: transform.LookAt(v);
		case 14: transform.Rotate(v);
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
