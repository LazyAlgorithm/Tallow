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
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, int, int, int> CanDispatch;
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

        public Script? GetManagedInstance(GameObject gameObject, int instanceId)
        {
            // A script ID is only an opaque handle; it must match the current
            // scene/object as well as the managed instance table.
            if (instanceId > 0 && sInstances.TryGetValue(instanceId, out Script? script) &&
                script.GameObject == gameObject && IsAlive(gameObject))
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

    // Rebound on each native Scene attachment; copied function pointers
    // remain valid for the trusted host's lifetime.
    private static Callbacks sNativeCallbacks;

    private static readonly HashSet<string> sTypes = new(StringComparer.Ordinal);
    // [FormerlyNamed] names of the loaded game's scripts, and each instance's registered name.
    private static readonly Dictionary<string, string> sFormerNames = new(StringComparer.Ordinal);
    private static readonly Dictionary<int, string> sNames = new();
    // Direct constructors shared with future AOT export. Clear this strong
    // reference BEFORE unloading the collectible development game assembly.
    private static IGameplayComponentRegistry? sRegistry;
    private static readonly Dictionary<int, Script> sInstances = [];
    // Preserve attach order for multiple components and subclass lookups.
    private static readonly Dictionary<GameObject, List<Script>> sByGameObject = [];
    private static readonly HashSet<int> sEnabled = [];

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int InvokeRpc(int instance, byte* method, byte* arguments, int target, int sender)
    {
        try
        {
            if (!sInstances.TryGetValue(instance, out Script? script))
                throw new InvalidOperationException("Unknown managed gameplay instance.");
            RpcMethods.RunFromNetwork(script,
                Marshal.PtrToStringUTF8((nint)method) ?? "",
                Marshal.PtrToStringUTF8((nint)arguments) ?? "", target, sender);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    /// Once a frame after LateUpdate: game-time waits and await continuations (GameThread).
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Pump(float deltaTime)
    {
        try
        {
            GameThread.Pump(deltaTime);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int NetworkEvent(int instance, byte* name, float value)
    {
        try
        {
            if (!sInstances.TryGetValue(instance, out Script? script))
                throw new InvalidOperationException("Unknown managed gameplay instance.");
            script.OnNetworkEvent(Marshal.PtrToStringUTF8((nint)name) ?? "", value);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    // Plain native layout, matching tn_csharp_contact (48 bytes).
    [StructLayout(LayoutKind.Sequential)]
    public struct NativeContact
    {
        public int Kind, HasOther;
        public ulong Other;
        public float PointX, PointY, PointZ;
        public float NormalX, NormalY, NormalZ;
        public float RelativeSpeed, Reserved;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Contact(int instance, NativeContact* contact)
    {
        try
        {
            if (contact == null)
                throw new ArgumentNullException(nameof(contact));
            if (!sInstances.TryGetValue(instance, out Script? script))
                throw new InvalidOperationException("Unknown managed gameplay instance.");
            NativeContact value = *contact;
            GameObject other = value.HasOther != 0
                ? new GameObject(script.GameObject.SceneId, value.Other)
                : default;
            switch (value.Kind)
            {
            case 0:
            case 1:
            case 4:
                var collision = new Collision(other,
                    new Vector3(value.PointX, value.PointY, value.PointZ),
                    new Vector3(value.NormalX, value.NormalY, value.NormalZ),
                    value.RelativeSpeed);
                if (value.Kind == 0)
                    script.OnCollisionEnter(collision);
                else if (value.Kind == 4)
                    script.OnCollisionStay(collision);
                else
                    script.OnCollisionExit(collision);
                break;
            case 2:
                script.OnTriggerEnter(other);
                break;
            case 3:
                script.OnTriggerExit(other);
                break;
            case 5:
                script.OnTriggerStay(other);
                break;
            case 6:
                script.OnControllerHit(new ControllerHit(other,
                    new Vector3(value.PointX, value.PointY, value.PointZ),
                    new Vector3(value.NormalX, value.NormalY, value.NormalZ),
                    value.RelativeSpeed));
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(contact));
            }
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

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
        // The same numbers as CSharpRuntime.ManagedEvent in the engine.
        Awake, Enable, Start, FixedUpdate, LocalUpdate, LateUpdate, Disable, Gui,
        Frame, Validate, DrawGizmos, Saving, Loaded
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
            return File.Exists(candidate) ? LoadCopy(candidate) : null;
        }

        /// From a copy in memory, with its symbols: a file the runtime maps stays locked on Windows until the
        /// context is collected, and the next compile could not replace it.
        public Assembly LoadCopy(string path)
        {
            using var image = new MemoryStream(File.ReadAllBytes(path));
            string pdb = Path.ChangeExtension(path, ".pdb");
            using MemoryStream? symbols = File.Exists(pdb) ? new MemoryStream(File.ReadAllBytes(pdb)) : null;
            return LoadFromStream(image, symbols);
        }
    }

    private static GameAssemblyContext? sGameContext;
    private static string sLastError = "";

    private static int sRepeatedErrors;

    // A script that throws in Update fails every tick. Report the first
    // failure in full, then only a periodic reminder of identical ones.
    private static int Failure(Exception exception)
    {
        string text = exception.ToString();
        if (text == sLastError)
        {
            if (++sRepeatedErrors % 600 == 0)
                Console.Error.WriteLine(
                    $"[Tallow C#] (repeated {sRepeatedErrors} times) {exception.GetType().Name}: {exception.Message}");
            return -1;
        }
        sRepeatedErrors = 0;
        sLastError = text;
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
                native->FindSceneObject == null || native->InstantiatePrefab == null ||
                native->CanDispatch == null)
                throw new InvalidOperationException("Native scene callbacks are missing.");
            sNativeCallbacks = *native;
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
            GameThread.Start();
            Assembly game = context.LoadCopy(path);
            foreach (AssemblyName dependency in game.GetReferencedAssemblies())
            {
                if (dependency.Name is null)
                    continue;
                string candidate = Path.Combine(root, dependency.Name, dependency.Name + ".dll");
                if (File.Exists(candidate))
                    context.LoadFromAssemblyName(dependency);
            }

            // Only the known generated registry is discovered from the
            // trusted Tallow.Game assembly. No Assembly.GetTypes scan or
            // arbitrary gameplay constructor reflection is needed.
            Type registryType = game.GetType(
                "Tallow.Generated.TallowGeneratedGameRegistry", throwOnError: false)
                ?? throw new InvalidOperationException(
                    "C# game has no generated component registry. Rebuild it with the current Tallow editor.");
            if (Activator.CreateInstance(registryType) is not IGameplayComponentRegistry registry)
                throw new InvalidOperationException("C# component registry ABI does not match Tallow.API.");
            sRegistry = registry;
            foreach (string typeName in registry.ComponentNames)
            {
                if (string.IsNullOrWhiteSpace(typeName) || !sTypes.Add(typeName))
                    throw new InvalidOperationException(
                        "Generated C# component registry contains a duplicate or invalid name.");
            }
            foreach ((string former, string current) in registry.FormerNames)
            {
                if (!sTypes.Contains(former) && sTypes.Contains(current))
                    sFormerNames[former] = current;
            }
            return sTypes.Count;
        }
        catch (Exception exception)
        {
            // Failed assembly activation must not leave a collectible game
            // context rooted or poison the next rebuild/Play attempt.
            sRegistry = null;
            sTypes.Clear();
            sFormerNames.Clear();
            GameAssemblyContext? failed = sGameContext;
            sGameContext = null;
            failed?.Unload();
            return Failure(exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Attach(byte* className, ulong sceneId, ulong entityId)
    {
        try
        {
            string name = Marshal.PtrToStringUTF8((nint)className) ?? "";
            // A scene that names a script the way it was called before ([FormerlyNamed]).
            if (!sTypes.Contains(name) && sFormerNames.TryGetValue(name, out string? current))
                name = current;
            if (!sTypes.Contains(name) || sRegistry is null)
                throw new TypeLoadException("Unknown trusted C# gameplay script: " + name);
            Script script = sRegistry.Create(name) ??
                throw new TypeLoadException("Generated C# factory did not create: " + name);
            int instance = ++sNextInstance;
            script.AttachNative(new GameObject(sceneId, entityId), instance);
            sInstances.Add(instance, script);
            sNames[instance] = name;
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
    /// <summary>
    /// Live values for the editor during Play. Mode 0: the Inspector's fields
    /// ("name\tvalue" lines, in the same text the scene stores, so the normal
    /// widgets show them). Mode 1: every instance field of the script's own
    /// classes, read-only ("name\ttype\tvalue"). Writes UTF-8 with a NUL when
    /// it fits and returns the byte count needed (without the NUL).
    /// </summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int ReadFields(int instance, int mode, byte* buffer, int capacity)
    {
        try
        {
            if (!sInstances.TryGetValue(instance, out Script? script))
                throw new InvalidOperationException("Unknown managed gameplay instance.");
            var text = new StringBuilder();
            var seen = new HashSet<string>();
            // Mode 3: the script's registered full name (differs from the scene's after a [FormerlyNamed] rename).
            if (mode == 3)
                text.Append(sNames.TryGetValue(instance, out string? registered) ? registered : "");
            for (Type? owner = mode == 3 ? null : script.GetType(); owner != null && owner != typeof(Script); owner = owner.BaseType)
            {
                foreach (FieldInfo field in owner.GetFields(BindingFlags.Instance | BindingFlags.Public |
                    BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
                {
                    // A derived class's field hides a base field of the same name, as in ApplyFields.
                    if (!seen.Add(field.Name) || field.IsDefined(typeof(CompilerGeneratedAttribute), inherit: false))
                        continue;
                    object? value = field.GetValue(script);
                    if (mode == 0 || mode == 2 || mode == 4)
                    {
                        // Mode 2: the [Sync] fields the server shares (NetworkSync); mode 4: the [Saved] fields
                        // SaveSystem keeps. In the same text.
                        if (mode == 0 ? !IsInspectorField(field) : mode == 2 ? !IsSyncField(field) : !IsSavedField(field))
                            continue;
                        string? encoded = FormatInspectorValue(field.FieldType, value);
                        if (encoded != null)
                            text.Append(field.Name).Append('\t').Append(encoded).Append('\n');
                    }
                    else
                    {
                        text.Append(field.Name).Append('\t').Append(FriendlyTypeName(field.FieldType))
                            .Append('\t').Append(SingleLine(DebugText(value))).Append('\n');
                    }
                }
            }
            byte[] bytes = Encoding.UTF8.GetBytes(text.ToString());
            if (buffer != null && capacity > bytes.Length)
            {
                bytes.AsSpan().CopyTo(new Span<byte>(buffer, capacity));
                buffer[bytes.Length] = 0;
            }
            return bytes.Length;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    private static bool IsSavedField(FieldInfo field) =>
        !field.IsStatic && !field.IsInitOnly && !field.IsLiteral &&
        field.IsDefined(typeof(SavedAttribute), inherit: true);

    private static bool IsSyncField(FieldInfo field) =>
        !field.IsStatic && !field.IsInitOnly && !field.IsLiteral &&
        field.IsDefined(typeof(SyncAttribute), inherit: true);

    // The fields scenes and the Inspector may set (the same rule ApplyFields applies).
    private static bool IsInspectorField(FieldInfo field)
    {
        const FieldAttributes nonSerializedBit = (FieldAttributes)0x0080;
        if (field.IsStatic || field.IsInitOnly || field.IsLiteral || (field.Attributes & nonSerializedBit) != 0)
            return false;
        return field.IsPublic || field.IsDefined(typeof(ShowInInspectorAttribute), inherit: true) ||
            field.IsDefined(typeof(HideInInspectorAttribute), inherit: true);
    }

    // The inverse of ParseInspectorValue.
    private static string? FormatInspectorValue(Type type, object? value)
    {
        static string Number(float x) => x.ToString(CultureInfo.InvariantCulture);
        return value switch
        {
            float x => Number(x),
            int x => x.ToString(CultureInfo.InvariantCulture),
            bool x => x ? "true" : "false",
            string x => SingleLine(x),
            null when type == typeof(string) => "",
            Enum x => x.ToString(),
            Vector2 v => $"{Number(v.X)},{Number(v.Y)}",
            Vector3 v => $"{Number(v.X)},{Number(v.Y)},{Number(v.Z)}",
            Vector4 v => $"{Number(v.X)},{Number(v.Y)},{Number(v.Z)},{Number(v.W)}",
            _ => null
        };
    }

    private static string DebugText(object? value)
    {
        const int maxItems = 16;
        switch (value)
        {
            case null: return "null";
            case string text: return "\"" + text + "\"";
            case float x: return x.ToString(CultureInfo.InvariantCulture);
            case double x: return x.ToString(CultureInfo.InvariantCulture);
            case System.Collections.ICollection items:
            {
                var parts = new List<string>();
                foreach (object? item in items)
                {
                    if (parts.Count == maxItems) { parts.Add("..."); break; }
                    parts.Add(item is System.Collections.ICollection ? "[...]" : DebugText(item));
                }
                return $"[{items.Count}] {string.Join(", ", parts)}";
            }
            default:
                try { return Convert.ToString(value, CultureInfo.InvariantCulture) ?? ""; }
                catch (Exception exception) { return "<" + exception.GetType().Name + ">"; }
        }
    }

    private static string SingleLine(string text)
    {
        if (text.Length > 200)
            text = text[..200] + "...";
        return text.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ').Replace('\0', ' ');
    }

    private static string FriendlyTypeName(Type type)
    {
        if (Nullable.GetUnderlyingType(type) is { } inner)
            return FriendlyTypeName(inner) + "?";
        if (!type.IsGenericType)
            return type.Name switch
            {
                "Single" => "float", "Int32" => "int", "Boolean" => "bool", "String" => "string",
                "Double" => "double", "Int64" => "long", "UInt32" => "uint", "Byte" => "byte",
                _ => type.Name
            };
        string name = type.Name[..type.Name.IndexOf('`')];
        return name + "<" + string.Join(", ", type.GetGenericArguments().Select(FriendlyTypeName)) + ">";
    }

    private static object? ParseInspectorValue(Type type, string encoded)
    {
        if (type == typeof(float))
        {
            float number = float.Parse(encoded, CultureInfo.InvariantCulture);
            if (!float.IsFinite(number))
                throw new FormatException("Inspector float fields must be finite.");
            return number;
        }
        if (type == typeof(int))
            return int.Parse(encoded, CultureInfo.InvariantCulture);
        if (type == typeof(bool))
            return encoded == "1" || (encoded != "0" && bool.Parse(encoded));
        if (type == typeof(string))
        {
            if (encoded.IndexOfAny(['\t', '\r', '\n', '\0']) >= 0)
                throw new FormatException("Inspector string fields require single-line text.");
            return encoded;
        }
        if (type.IsEnum)
        {
            object parsed = Enum.Parse(type, encoded, ignoreCase: false);
            if (!Enum.IsDefined(type, parsed) &&
                !type.IsDefined(typeof(FlagsAttribute), inherit: false))
                throw new FormatException("Undefined C# Inspector enum value.");
            return parsed;
        }
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
            // Validate and parse the whole scene/prefab override set before
            // mutating the managed instance. A corrupt later field must not
            // partially apply earlier values before Awake or hot updates.
            var updates = new List<(FieldInfo Field, object Value)>();
            foreach (string line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                int separator = line.IndexOf('\t');
                if (separator < 1)
                    continue;
                string name = line[..separator];
                string value = line[(separator + 1)..];
                // Type.GetField does not return private fields declared on a
                // base class, so walk the user's class chain explicitly.
                FieldInfo? field = null;
                for (Type? owner = script.GetType(); field is null && owner != null &&
                     owner != typeof(Script); owner = owner.BaseType)
                    field = owner.GetField(name, BindingFlags.Instance | BindingFlags.Public |
                        BindingFlags.NonPublic | BindingFlags.DeclaredOnly);
                // ECMA-335 FieldAttributes.NotSerialized is the 0x0080 metadata bit.
                // Both FieldInfo.IsNotSerialized and the named enum member are
                // obsolete in .NET 11; keep the existing Inspector exclusion rule
                // without depending on formatter-based serialization APIs.
                const FieldAttributes nonSerializedBit = (FieldAttributes)0x0080;
                if (field is null || field.IsStatic || field.IsInitOnly || field.IsLiteral ||
                    (field.Attributes & nonSerializedBit) != 0)
                    continue; // Allow scripts to rename/remove fields without breaking old scenes.
                // Do not allow a scene/prefab file to change arbitrary private
                // implementation state. The Roslyn catalog and managed loader
                // must agree on which fields have been opted into persistence.
                // [Sync] fields are opted in too: clients receive the server's values this way.
                if (!field.IsPublic &&
                    !field.IsDefined(typeof(ShowInInspectorAttribute), inherit: true) &&
                    !field.IsDefined(typeof(HideInInspectorAttribute), inherit: true) &&
                    !field.IsDefined(typeof(SyncAttribute), inherit: true) &&
                    !field.IsDefined(typeof(SavedAttribute), inherit: true))
                    continue;
                object? parsed = ParseInspectorValue(field.FieldType, value);
                if (parsed != null)
                    updates.Add((field, parsed));
            }
            foreach ((FieldInfo field, object parsed) in updates)
                field.SetValue(script, parsed);
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    private static void DispatchScript(int instance, Script script,
        ScriptEvent eventId, float deltaTime)
    {
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
            case ScriptEvent.Frame: script.OnFrame(); break;
            case ScriptEvent.Validate: script.OnValidate(); break;
            case ScriptEvent.DrawGizmos: script.OnDrawGizmos(deltaTime != 0); break;
            case ScriptEvent.Saving: script.OnSaving(); break;
            case ScriptEvent.Loaded: script.OnLoaded(); break;
            default: throw new ArgumentOutOfRangeException(nameof(eventId), eventId,
                "Unknown managed gameplay event.");
        }
    }

    private static void DispatchOne(int instance, ScriptEvent eventId, float deltaTime)
    {
        if (!sInstances.TryGetValue(instance, out Script? script))
            throw new InvalidOperationException("Unknown managed gameplay instance.");
        DispatchScript(instance, script, eventId, deltaTime);
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
            // One script throwing must not stop the rest: each runs, the first failure is reported after.
            Exception? failure = null;
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
                if (sInstances.TryGetValue(instances[i], out Script? script))
                {
                    try { DispatchScript(instances[i], script, (ScriptEvent)eventId, deltaTime); }
                    catch (Exception exception) { failure ??= exception; }
                }
            }
            return failure is null ? count : Failure(failure);
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    /// <summary>
    /// Scheduler-only variant. Recheck native component registration,
    /// Start, Enabled and active hierarchy AFTER preceding managed callbacks.
    /// This matters when C# destroys/disables siblings during FixedUpdate.
    /// Lifecycle events other than Fixed/Late use the ordinary engine path.
    /// </summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int DispatchCheckedBatch(int* instances, int count,
        int eventId, float deltaTime)
    {
        try
        {
            // One script throwing must not stop the rest: each runs, the first failure is reported after.
            Exception? failure = null;
            if (count < 0 || count > 4096 || (count > 0 && instances == null))
                throw new ArgumentOutOfRangeException(nameof(count));
            ScriptEvent phase = (ScriptEvent)eventId;
            if (phase is not (ScriptEvent.FixedUpdate or ScriptEvent.LateUpdate))
                throw new ArgumentOutOfRangeException(nameof(eventId),
                    "Checked batches only support native scene FixedUpdate/LateUpdate.");
            if (sNativeCallbacks.CanDispatch == null)
                throw new InvalidOperationException("The native scheduler has not been bound.");
            for (int i = 0; i < count; i++)
                if (!sInstances.ContainsKey(instances[i]))
                    throw new InvalidOperationException("Unknown initial C# scheduler instance.");
            for (int i = 0; i < count; i++)
            {
                if (!sInstances.TryGetValue(instances[i], out Script? script))
                    continue; // Detached by an earlier script.
                GameObject owner = script.GameObject;
                if (sNativeCallbacks.CanDispatch(sNativeCallbacks.Context,
                        owner.SceneId, owner.Id, instances[i], eventId) > 0)
                {
                    try { DispatchScript(instances[i], script, phase, deltaTime); }
                    catch (Exception exception) { failure ??= exception; }
                }
            }
            return failure is null ? count : Failure(failure);
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }

    private static void RunInputScript(Script script, NativeInput input, float deltaTime)
    {
        var tick = new TickInput(
            new Vector2(input.MoveX, input.MoveZ),
            new Vector2(input.Yaw, input.Pitch),
            input.Buttons, input.PreviousButtons);
        script.Update(tick, deltaTime);
    }

    private static void RunInputOne(int instance, NativeInput input, float deltaTime)
    {
        if (!sInstances.TryGetValue(instance, out Script? script))
            throw new InvalidOperationException("Unknown managed gameplay instance.");
        RunInputScript(script, input, deltaTime);
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
            // One script throwing must not stop the rest: each runs, the first failure is reported after.
            Exception? failure = null;
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
                if (sInstances.TryGetValue(items[i].Instance, out Script? script))
                {
                    try { RunInputScript(script, items[i].Input, items[i].DeltaTime); }
                    catch (Exception exception) { failure ??= exception; }
                }
            }
            return failure is null ? count : Failure(failure);
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
            sNames.Remove(instance);
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
            finally
            {
                try { script.OnDestroy(); }
                finally { script.InvalidateNative(); }
            }
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
            // Never retain a generated factory instance across ALC reloads.
            sRegistry = null;
            sTypes.Clear();
            sFormerNames.Clear();
            // Continuations from the unloaded game must not run (they would also keep its context alive).
            GameThread.Stop();
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
            sNames.Clear();
            sByGameObject.Clear();
            // Never retain a generated factory instance across ALC reloads.
            sRegistry = null;
            sTypes.Clear();
            sFormerNames.Clear();
            // Continuations from the unloaded game must not run (they would also keep its context alive).
            GameThread.Stop();
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
