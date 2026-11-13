using System.Numerics;
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
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, float*, void> GetPosition;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, float*, void> SetPosition;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, void> Destroy;
        public delegate* unmanaged[Cdecl]<nint, ulong, ulong, int> IsMine;
    }

    private sealed class NativeBridge(Callbacks callbacks) : IEngineBridge
    {
        private readonly Callbacks _callbacks = callbacks;

        public bool IsAlive(GameObject gameObject) =>
            _callbacks.IsAlive(_callbacks.Context, gameObject.SceneId, gameObject.Id) != 0;

        public Vector3 GetPosition(GameObject gameObject)
        {
            if (!IsAlive(gameObject))
                throw new ObjectDisposedException(nameof(GameObject), "The native scene entity was destroyed.");
            float* xyz = stackalloc float[3];
            _callbacks.GetPosition(_callbacks.Context, gameObject.SceneId, gameObject.Id, xyz);
            return new Vector3(xyz[0], xyz[1], xyz[2]);
        }

        public void SetPosition(GameObject gameObject, Vector3 position)
        {
            if (!IsAlive(gameObject))
                throw new ObjectDisposedException(nameof(GameObject), "The native scene entity was destroyed.");
            float* xyz = stackalloc float[3] { position.X, position.Y, position.Z };
            _callbacks.SetPosition(_callbacks.Context, gameObject.SceneId, gameObject.Id, xyz);
        }

        public void Destroy(GameObject gameObject) =>
            _callbacks.Destroy(_callbacks.Context, gameObject.SceneId, gameObject.Id);

        public bool IsMine(GameObject gameObject) =>
            _callbacks.IsMine(_callbacks.Context, gameObject.SceneId, gameObject.Id) != 0;
    }

    private static readonly Dictionary<string, Type> sTypes = new(StringComparer.Ordinal);
    private static readonly Dictionary<int, Script> sInstances = [];
    private static int sNextInstance;
    private static readonly AssemblyLoadContext sRuntimeContext =
        AssemblyLoadContext.GetLoadContext(typeof(NativeEntrypoints).Assembly) ?? AssemblyLoadContext.Default;
    private static string? sTrustedAssemblyRoot;
    private static bool sResolverInstalled;
    private static string sLastError = "";

    private static Assembly? Resolve(AssemblyLoadContext context, AssemblyName name)
    {
        if (sTrustedAssemblyRoot is null || name.Name is null)
            return null;

        // Only the compiler-produced sibling assemblies of the trusted game.
        string candidate = Path.Combine(sTrustedAssemblyRoot, name.Name, name.Name + ".dll");
        return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
    }

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
            Callbacks* native = (Callbacks*)callbacks;
            if (native->IsAlive == null || native->GetPosition == null ||
                native->SetPosition == null || native->Destroy == null || native->IsMine == null)
                throw new InvalidOperationException("Native scene callbacks are missing.");
            Engine.Bind(new NativeBridge(*native));
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
            if (trustedPath == null || sTypes.Count != 0 || sInstances.Count != 0)
                throw new InvalidOperationException("A trusted game is already loaded, or no game path was provided.");
            string path = Path.GetFullPath(Marshal.PtrToStringUTF8((nint)trustedPath) ?? "");
            if (Path.GetFileName(path) != "Tallow.Game.dll" || !File.Exists(path))
                throw new FileNotFoundException("Only the trusted Tallow.Game assembly can be loaded.", path);

            sTrustedAssemblyRoot = Directory.GetParent(Path.GetDirectoryName(path)!)!.FullName;
            if (!sResolverInstalled)
            {
                sRuntimeContext.Resolving += Resolve;
                sResolverInstalled = true;
            }

            Assembly game = sRuntimeContext.LoadFromAssemblyPath(path);
            foreach (AssemblyName dependency in game.GetReferencedAssemblies())
            {
                string candidate = Path.Combine(sTrustedAssemblyRoot, dependency.Name!,
                    dependency.Name! + ".dll");
                if (File.Exists(candidate))
                    sRuntimeContext.LoadFromAssemblyName(dependency);
            }

            foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                string? location = null;
                try { location = assembly.Location; }
                catch (NotSupportedException) { }
                if (assembly != game && (location == null ||
                    !Path.GetFullPath(location).StartsWith(sTrustedAssemblyRoot +
                        Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)))
                    continue;

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
            script.Awake();
            script.OnEnable();
            script.Start();
            return instance;
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
            try { script.OnDisable(); }
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
    public static int Shutdown()
    {
        try
        {
            foreach (Script script in sInstances.Values)
            {
                try { script.OnDisable(); }
                finally { script.OnDestroy(); }
            }
            sInstances.Clear();
            sTypes.Clear();
            sTrustedAssemblyRoot = null;
            return 1;
        }
        catch (Exception exception)
        {
            return Failure(exception);
        }
    }
}
