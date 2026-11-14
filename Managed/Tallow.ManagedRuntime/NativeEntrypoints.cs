using System.Numerics;
using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Text;
using Tallow;

namespace Tallow.ManagedRuntime;

/// <summary>
/// Trusted C# runtime for the native hostfxr bridge. It is not a mod loader:
/// native gameplay controls assembly paths and invokes the entrypoints.
/// </summary>
public static unsafe class NativeEntrypoints
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Callbacks
    {
        public nint Context;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, int> IsAlive;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, float*, int> GetPosition;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, float*, int> SetPosition;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, void> Destroy;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, int> IsMine;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, int, float*, int> GetTransform;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, int, float*, int> SetTransform;
        public delegate* unmanaged[Cdecl]<nint, byte*, nint> ResolveApi;
        public delegate* unmanaged[Cdecl]<nint, ulong, byte*, int, ulong> CreateSceneObject;
        public delegate* unmanaged[Cdecl]<nint, ulong, byte*, int, ulong> FindSceneObject;
        public delegate* unmanaged[Cdecl]<nint, ulong, byte*, int, ulong> InstantiatePrefab;
    }

    private sealed class NativeBridge(Callbacks callbacks) : IEngineBridge
    {
        private readonly Callbacks _callbacks = callbacks;

        public bool IsAlive(GameObject gameObject) =>
            _callbacks.IsAlive(_callbacks.Context, gameObject.SceneId, gameObject.Id) != 0;

        // Validate handles inside each native operation. This halves the
        // crossings for hot Transform reads/writes and avoids a TOCTOU check.
        private static void ThrowStale()
        {
            throw new ObjectDisposedException(nameof(GameObject),
                "The native scene entity was destroyed or its session ended.");
        }

        public Vector3 GetPosition(GameObject gameObject)
        {
            float* xyz = stackalloc float[3];
            if (_callbacks.GetPosition(_callbacks.Context,
                    gameObject.SceneId, gameObject.Id, xyz) == 0)
                ThrowStale();
            return new Vector3(xyz[0], xyz[1], xyz[2]);
        }

        public void SetPosition(GameObject gameObject, Vector3 position)
        {
            float* xyz = stackalloc float[3] { position.X, position.Y, position.Z };
            if (_callbacks.SetPosition(_callbacks.Context,
                    gameObject.SceneId, gameObject.Id, xyz) == 0)
                ThrowStale();
        }

        public Vector4 GetTransform(GameObject gameObject, TransformChannel channel)
        {
            float* values = stackalloc float[4];
            if (_callbacks.GetTransform(_callbacks.Context,
                    gameObject.SceneId, gameObject.Id, (int)channel, values) == 0)
                ThrowStale();
            return new Vector4(values[0], values[1], values[2], values[3]);
        }

        public void SetTransform(GameObject gameObject, TransformChannel channel, Vector4 value)
        {
            float* values = stackalloc float[4] { value.X, value.Y, value.Z, value.W };
            if (_callbacks.SetTransform(_callbacks.Context,
                    gameObject.SceneId, gameObject.Id, (int)channel, values) == 0)
                ThrowStale();
        }

        public Vector3 TransformPoint(GameObject gameObject, Vector3 point, bool inverse)
        {
            float* values = stackalloc float[4] { point.X, point.Y, point.Z, 0 };
            if (_callbacks.GetTransform(_callbacks.Context, gameObject.SceneId, gameObject.Id,
                    inverse ? (int)TransformChannel.InverseTransformPoint :
                              (int)TransformChannel.TransformPoint, values) == 0)
                ThrowStale();
            return new Vector3(values[0], values[1], values[2]);
        }

        public Script? GetManagedComponent(GameObject gameObject, Type scriptType)
        {
            if (!IsAlive(gameObject))
                return null;
            // Managed components share the native scene/entity identity. Never
            // expose scripts from an old scene session or an unrelated entity.
            // Indexed by native scene/entity handle: avoid scanning every managed
            // script in the game for each GetComponent<T>() call.
            if (sByGameObject.TryGetValue(gameObject, out List<Script>? scripts))
                foreach (Script script in scripts)
                    if (scriptType.IsInstanceOfType(script))
                        return script;
            return null;
        }

        public void Destroy(GameObject gameObject) =>
            _callbacks.Destroy(_callbacks.Context, gameObject.SceneId, gameObject.Id);

        public bool IsMine(GameObject gameObject) =>
            _callbacks.IsMine(_callbacks.Context, gameObject.SceneId, gameObject.Id) != 0;

        // These calls return opaque object IDs. The native scene validates
        // the session and keeps ownership; no managed code receives a pointer.
        private ulong CallScene(
            delegate* unmanaged[Cdecl]<nint, ulong, byte*, int, ulong> callback,
            ulong session, string value)
        {
            byte[] utf8 = Encoding.UTF8.GetBytes(value);
            if (utf8.Length is 0 or > 4096)
                return 0;
            fixed (byte* bytes = utf8)
                return callback(_callbacks.Context, session, bytes, utf8.Length);
        }

        public ulong CreateSceneObject(ulong session, string name) =>
            CallScene(_callbacks.CreateSceneObject, session, name);

        public ulong FindSceneObject(ulong session, string name) =>
            CallScene(_callbacks.FindSceneObject, session, name);

        public ulong InstantiatePrefab(ulong session, string path) =>
            CallScene(_callbacks.InstantiatePrefab, session, path);
    }

    private static readonly Dictionary<string, Type> sTypes = new(StringComparer.Ordinal);
    private static readonly Dictionary<int, Script> sInstances = [];
    // Preserve attach order for multiple components and subclass lookups.
    private static readonly Dictionary<GameObject, List<Script>> sByGameObject = [];
    private static readonly HashSet<int> sEnabled = [];

    // Plain native layout, matching tn_csharp_tick_input.
    [StructLayout(LayoutKind.Sequential)]
    public struct NativeInput
    {
        public float MoveX, MoveZ, Yaw, Pitch;
        public uint Buttons, PreviousButtons;
    }

    // Native/managed ABI: 4-byte instance, 24-byte current/previous
    // TickInput, 4-byte deltaTime. No managed references or pointers.
    [StructLayout(LayoutKind.Sequential)]
    public struct NativeBatchInput
    {
        public int Instance;
        public NativeInput Input;
        public float DeltaTime;
    }

    // These event IDs are shared with the native header and the Beef adapter.
    private enum ScriptEvent
    {
        Awake, Enable, Start, FixedUpdate, LocalUpdate, LateUpdate, Disable, Gui
    }
    private static int sNextInstance;
    // Trusted development gameplay gets a separate collectible context. The engine's
    // Tallow.API types stay in the host context so class inheritance works correctly.
    // AssemblyLoadContext does not sandbox third-party code; only engine-built game
    // assemblies are permitted here.
    private sealed class GameAssemblyContext(string root) :
        AssemblyLoadContext("Tallow.TrustedGame", isCollectible: true)
    {
        protected override Assembly? Load(AssemblyName name)
        {
            if (name.Name == typeof(Script).Assembly.GetName().Name)
                return typeof(Script).Assembly;
            if (name.Name is null)
                return null;
            string candidate = Path.Combine(root, name.Name, name.Name + ".dll");
            return File.Exists(candidate) ? LoadFromAssemblyPath(candidate) : null;
        }
    }

    private static GameAssemblyContext? sGameContext;
    private static string sLastError = "";

    private static int Failure(Exception exception)
    {
        sLastError = exception.ToString();
        Console.Error.WriteLine("[Tallow C#] " + sLastError);
        return -1;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Configure(nint callbacks)
    {
        try
        {
            if (callbacks == 0)
                throw new ArgumentNullException(nameof(callbacks));
            if (sizeof(NativeInput) != 24 || sizeof(NativeBatchInput) != 32)
                throw new InvalidOperationException(
                    "Native TickInput batch layout does not match the host ABI.");
            Callbacks* native = (Callbacks*)callbacks;
            if (native->IsAlive == null || native->GetPosition == null ||
                native->SetPosition == null || native->Destroy == null || native->IsMine == null ||
                native->GetTransform == null || native->SetTransform == null ||
                native->ResolveApi == null || native->CreateSceneObject == null ||
                native->FindSceneObject == null || native->InstantiatePrefab == null)
                throw new InvalidOperationException("Native scene callbacks are missing.");
            Engine.Bind(new NativeBridge(*native));
            GeneratedNativeApi.Bind(native->Context, (nint)native->ResolveApi);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int LoadGame(byte* trustedPath)
    {
        try
        {
            if (trustedPath == null || sGameContext != null || sTypes.Count != 0 || sInstances.Count != 0)
                throw new InvalidOperationException("A trusted game is already loaded, or no game path was provided.");
            string path = Path.GetFullPath(Marshal.PtrToStringUTF8((nint)trustedPath) ?? "");
            if (Path.GetFileName(path) != "Tallow.Game.dll" || !File.Exists(path))
                throw new FileNotFoundException("Only the trusted Tallow.Game assembly can be loaded.", path);

            string root = Directory.GetParent(Path.GetDirectoryName(path)!)!.FullName;
            GameAssemblyContext context = new(root);
            sGameContext = context;
            Assembly game = context.LoadFromAssemblyPath(path);
            foreach (AssemblyName dependency in game.GetReferencedAssemblies())
            {
                if (dependency.Name is null)
                    continue;
                string candidate = Path.Combine(root, dependency.Name, dependency.Name + ".dll");
                if (File.Exists(candidate))
                    context.LoadFromAssemblyName(dependency);
            }

            // Only scan this game's assemblies, not assemblies loaded by the host.
            foreach (Assembly assembly in context.Assemblies)
            {
                foreach (Type type in assembly.GetTypes())
                {
                    if (type.IsAbstract || !typeof(Script).IsAssignableFrom(type) ||
                        !type.IsDefined(typeof(ComponentAttribute), inherit: true) ||
                        type.GetConstructor(Type.EmptyTypes) is null)
                        continue;
                    sTypes.Add(type.FullName!, type);
                }
            }
            return sTypes.Count;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Attach(byte* className, ulong sceneId, ulong entityId)
    {
        try
        {
            string name = Marshal.PtrToStringUTF8((nint)className) ?? "";
            if (!sTypes.TryGetValue(name, out Type? type))
                throw new TypeLoadException("Unknown trusted C# gameplay script: " + name);
            Script script = (Script)Activator.CreateInstance(type)!;
            script.Attach(new GameObject(sceneId, entityId));
            int instance = ++sNextInstance;
            sInstances.Add(instance, script);
            if (!sByGameObject.TryGetValue(script.GameObject, out List<Script>? scripts))
            {
                scripts = [];
                sByGameObject.Add(script.GameObject, scripts);
            }
            scripts.Add(script);
            return instance;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    // Values come from trusted scene files; never evaluate expressions or
    // resolve arbitrary types while applying Inspector values.
    private static object? ParseInspectorValue(Type type, string encoded)
    {
        if (type == typeof(float))
            return float.Parse(encoded, CultureInfo.InvariantCulture);
        if (type == typeof(int))
            return int.Parse(encoded, CultureInfo.InvariantCulture);
        if (type == typeof(bool))
            return bool.Parse(encoded);
        if (type == typeof(Vector2) || type == typeof(Vector3) || type == typeof(Vector4))
        {
            string[] values = encoded.Split(',');
            int dimensions = type == typeof(Vector2) ? 2 : type == typeof(Vector3) ? 3 : 4;
            if (values.Length != dimensions)
                throw new FormatException("Vector component count does not match the C# field type.");
            float[] numbers = values.Select(value => float.Parse(value, CultureInfo.InvariantCulture)).ToArray();
            if (numbers.Any(float.IsNaN) || numbers.Any(float.IsInfinity))
                throw new FormatException("Vector fields require finite coordinates.");
            return dimensions switch
            {
                2 => new Vector2(numbers[0], numbers[1]),
                3 => new Vector3(numbers[0], numbers[1], numbers[2]),
                _ => new Vector4(numbers[0], numbers[1], numbers[2], numbers[3])
            };
        }
        return null;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int ApplyFields(int instance, byte* values)
    {
        try
        {
            if (!sInstances.TryGetValue(instance, out Script? script))
                throw new InvalidOperationException("Unknown managed gameplay instance.");
            if (values == null)
                return 1;
            string text = Marshal.PtrToStringUTF8((nint)values) ?? "";
            foreach (string line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                int separator = line.IndexOf('\t');
                if (separator < 1)
                    continue;
                string name = line[..separator];
                string value = line[(separator + 1)..];
                FieldInfo? field = script.GetType().GetField(name, BindingFlags.Instance | BindingFlags.Public);
                // ECMA-335 FieldAttributes.NotSerialized is the 0x0080 metadata bit.
                // Both FieldInfo.IsNotSerialized and the named enum member are
                // obsolete in .NET 11; keep the existing Inspector exclusion rule
                // without depending on formatter-based serialization APIs.
                const FieldAttributes nonSerializedBit = (FieldAttributes)0x0080;
                if (field is null || field.IsStatic || field.IsInitOnly || field.IsLiteral ||
                    (field.Attributes & nonSerializedBit) != 0)
                    continue; // Allow scripts to rename/remove fields without breaking old scenes.
                object? parsed = ParseInspectorValue(field.FieldType, value);
                if (parsed != null)
                    field.SetValue(script, parsed);
            }
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    private static void DispatchOne(int instance, ScriptEvent eventId, float deltaTime)
    {
        if (!sInstances.TryGetValue(instance, out Script? script))
            throw new InvalidOperationException("Unknown managed gameplay instance.");
        switch (eventId)
        {
            case ScriptEvent.Awake: script.Awake(); break;
            case ScriptEvent.Enable:
                if (sEnabled.Add(instance))
                    script.OnEnable();
                break;
            case ScriptEvent.Start: script.Start(); break;
            case ScriptEvent.FixedUpdate: script.FixedUpdate(deltaTime); break;
            case ScriptEvent.LocalUpdate: script.OnLocalUpdate(); break;
            case ScriptEvent.LateUpdate: script.LateUpdate(deltaTime); break;
            case ScriptEvent.Disable:
                if (sEnabled.Remove(instance))
                    script.OnDisable();
                break;
            case ScriptEvent.Gui: script.OnGUI(); break;
            default: throw new ArgumentOutOfRangeException(nameof(eventId), eventId,
                "Unknown managed gameplay event.");
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Dispatch(int instance, int eventId, float deltaTime)
    {
        try
        {
            DispatchOne(instance, (ScriptEvent)eventId, deltaTime);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    // Contiguous batches can amortize the native-to-CLR transition without
    // changing public Script methods. Validate the full input before dispatch.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int DispatchBatch(int* instances, int count, int eventId, float deltaTime)
    {
        try
        {
            if (count < 0 || count > 4096 || (count > 0 && instances == null))
                throw new ArgumentOutOfRangeException(nameof(count));
            for (int i = 0; i < count; i++)
                if (!sInstances.ContainsKey(instances[i]))
                    throw new InvalidOperationException("Unknown C# instance in lifecycle batch.");
            for (int i = 0; i < count; i++)
            {
                // An earlier callback may destroy a later component. Mirror
                // the input-batch path: only dispatch instances still attached
                // at the moment their turn arrives.
                if (sInstances.ContainsKey(instances[i]))
                    DispatchOne(instances[i], (ScriptEvent)eventId, deltaTime);
            }
            return count;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    private static void RunInputOne(int instance, NativeInput input, float deltaTime)
    {
        if (!sInstances.TryGetValue(instance, out Script? script))
            throw new InvalidOperationException("Unknown managed gameplay instance.");
        var tick = new TickInput(
            new Vector2(input.MoveX, input.MoveZ),
            new Vector2(input.Yaw, input.Pitch),
            input.Buttons, input.PreviousButtons);
        script.Update(tick, deltaTime);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int UpdateInput(int instance, NativeInput* input, float deltaTime)
    {
        try
        {
            if (input == null)
                throw new ArgumentNullException(nameof(input));
            RunInputOne(instance, *input, deltaTime);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    /// <summary>
    /// One transition for a native-ordered input batch. Every entry has its
    /// own TickInput and previous buttons; no shared player input is assumed.
    /// This is a scheduling primitive, not automatic rollback/prediction.
    /// </summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int UpdateInputBatch(NativeBatchInput* items, int count)
    {
        try
        {
            if (count < 0 || count > 4096 || (count > 0 && items == null))
                throw new ArgumentOutOfRangeException(nameof(count));
            // Avoid partially dispatching a batch containing a stale instance.
            for (int i = 0; i < count; i++)
                if (!sInstances.ContainsKey(items[i].Instance))
                    throw new InvalidOperationException("Unknown managed gameplay instance in input batch.");
            for (int i = 0; i < count; i++)
            {
                // A prior Update could remove another script in the same
                // batch; preserve lifecycle safety by skipping detached IDs.
                if (sInstances.ContainsKey(items[i].Instance))
                    RunInputOne(items[i].Instance, items[i].Input, items[i].DeltaTime);
            }
            return count;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Tick(int instance, float deltaTime)
    {
        try
        {
            if (!sInstances.TryGetValue(instance, out Script? script))
                throw new InvalidOperationException("Unknown C# component instance.");
            script.Update(new TickInput(Vector2.Zero, Vector2.Zero, 0), deltaTime);
            script.OnLocalUpdate();
            script.LateUpdate(deltaTime);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Detach(int instance)
    {
        try
        {
            if (!sInstances.Remove(instance, out Script? script))
                return 0;
            GameObject owner = script.GameObject;
            if (sByGameObject.TryGetValue(owner, out List<Script>? scripts))
            {
                scripts.Remove(script);
                if (scripts.Count == 0)
                    sByGameObject.Remove(owner);
            }
            try
            {
                if (sEnabled.Remove(instance))
                    script.OnDisable();
            }
            finally { script.OnDestroy(); }
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int GetLastError(byte* buffer, int length)
    {
        if (buffer == null || length < 1)
            return 0;
        byte[] utf8 = Encoding.UTF8.GetBytes(sLastError);
        int count = Math.Min(utf8.Length, length - 1);
        utf8.AsSpan(0, count).CopyTo(new Span<byte>(buffer, count));
        buffer[count] = 0;
        return count;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int UnloadGame()
    {
        try
        {
            if (sInstances.Count != 0)
                throw new InvalidOperationException(
                    "Detach all managed components before unloading the gameplay assembly.");
            sEnabled.Clear();
            sByGameObject.Clear();
            sTypes.Clear();
            GameAssemblyContext? previous = sGameContext;
            sGameContext = null;
            previous?.Unload();
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Shutdown()
    {
        try
        {
            foreach ((int instance, Script script) in sInstances)
            {
                try
                {
                    if (sEnabled.Contains(instance))
                        script.OnDisable();
                }
                finally { script.OnDestroy(); }
            }
            sEnabled.Clear();
            sInstances.Clear();
            sByGameObject.Clear();
            sTypes.Clear();
            GameAssemblyContext? previous = sGameContext;
            sGameContext = null;
            previous?.Unload();
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }
}
