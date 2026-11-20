using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Tallow;


namespace Tallow.ManagedRuntime;

/// <summary>
/// A C# game in a browser. There the page starts .NET (WebAssembly, with the engine linked into the same module)
/// rather than the engine starting .NET, so the order is the desktop one turned round: the generated web start-up
/// (tools/build_player.py) calls <see cref="Run"/>, which registers <see cref="NativeEntrypoints"/> with the
/// engine's host (native/tallow_dotnet_host.cpp) and starts the precompiled player (Player/, a Beef static
/// library: BeefStart runs its Main). The player returns once the browser has its frame loop, and so does Run;
/// the browser then calls the engine every frame and the engine calls in here as on the desktop.
/// The game's assemblies are part of the page's .NET bundle and load into the default context: a browser game is
/// never reloaded or unloaded.
/// </summary>
public static unsafe class WebHost
{
    // The engine is linked into the page's WebAssembly; .NET's P/Invoke table binds these by name to its symbols.
    private const string Engine = "tallowengine";

    [DllImport(Engine)] private static extern int tn_csharp_web_register(byte* name, nint pointer);
    [DllImport(Engine)] private static extern void BfpSystem_SetCommandLine(int argc, byte** argv);
    [DllImport(Engine)] private static extern int BeefStart();

    /// <summary>Starts the engine with the page's arguments (?arg=... in its address). Returns 0 once it runs.</summary>
    public static int Run(string[] args)
    {
        if (!OperatingSystem.IsBrowser())
            throw new PlatformNotSupportedException("WebHost runs only in a browser.");
        foreach ((string name, nint pointer) in NativeEntrypoints.Table())
            Register(name, pointer);

        // Beef reads its arguments as a C program's: the program's name, then each argument. The engine may keep
        // pointers into them for good, so they are never freed.
        string[] all = ["game", .. args];
        byte** argv = (byte**)NativeMemory.Alloc((nuint)(all.Length + 1), (nuint)sizeof(byte*));
        for (int i = 0; i < all.Length; i++)
            argv[i] = Utf8(all[i]);
        argv[all.Length] = null;
        BfpSystem_SetCommandLine(all.Length, argv);
        BeefStart();
        return 0;
    }

    /// <summary>The game's registry, from Tallow.Game in the page's bundle (see NativeEntrypoints.LoadGame).</summary>
    internal static IGameplayComponentRegistry OpenGame() =>
        NativeEntrypoints.CreateRegistry(Assembly.Load(new AssemblyName("Tallow.Game")));

    private static void Register(string name, nint pointer)
    {
        byte* text = Utf8(name);
        int registered = tn_csharp_web_register(text, pointer);
        NativeMemory.Free(text);
        if (registered == 0)
            throw new InvalidOperationException("The engine refused the C# entrypoint " + name + ".");
    }

    private static byte* Utf8(string text)
    {
        int length = Encoding.UTF8.GetByteCount(text);
        byte* bytes = (byte*)NativeMemory.Alloc((nuint)length + 1);
        Encoding.UTF8.GetBytes(text, new Span<byte>(bytes, length));
        bytes[length] = 0;
        return bytes;
    }
}

/// <summary>
/// .NET's WebAssembly interpreter can call native code only through signatures it was built with, and it learns
/// them from the P/Invoke declarations of the assemblies it bundles, not from function-pointer calls. These
/// declarations are never called: they give it the signatures of the engine's callback table (NativeEntrypoints'
/// Callbacks and the API resolver). The generated bindings' own are in Tallow.API (WebSignatures.g.cs).
/// </summary>
internal static unsafe class WebCallbackSignatures
{
    private const string Signatures = "tallow_signatures";

    [DllImport(Signatures)] private static extern int IsAlive(nint context, ulong scene, ulong entity);
    [DllImport(Signatures)] private static extern int GetPosition(nint context, ulong scene, ulong entity, float* xyz);
    [DllImport(Signatures)] private static extern void Destroy(nint context, ulong scene, ulong entity);
    [DllImport(Signatures)] private static extern int GetTransform(nint context, ulong scene, ulong entity, int channel, float* xyzw);
    [DllImport(Signatures)] private static extern nint ResolveApi(nint context, byte* symbol);
    [DllImport(Signatures)] private static extern ulong CreateSceneObject(nint context, ulong session, byte* name, int length);
    [DllImport(Signatures)] private static extern int CanDispatch(nint context, ulong session, ulong entity, int instance, int eventId);
    [DllImport(Signatures)] private static extern int ApiVersion();
}
