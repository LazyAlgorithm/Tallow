using System.Text;

namespace Tallow;

/// <summary>
/// Runtime infrastructure for generated CSharpExpose wrappers. Gameplay authors
/// never call this. Pointers are resolved once per wrapper and then called
/// directly, without reflection, boxing or a per-call name lookup.
/// </summary>
internal static unsafe partial class GeneratedNativeApi
{
    private static nint sContext;
    private static delegate* unmanaged[Cdecl]<nint, byte*, nint> sResolver;

    // Implemented by generated code; absent when no APIs have been exported.
    static partial void VerifyVersion();
    static partial void ResetVersion();

    private static readonly List<Action> sWhenBound = [];

    internal static void Bind(nint context, nint resolver)
    {
        sContext = context;
        sResolver = (delegate* unmanaged[Cdecl]<nint, byte*, nint>)resolver;
        ResetVersion();
        // A NativeAOT game runs its module initializers when the library is first called, before the engine binds:
        // what they had to tell the engine (ECS data layouts, systems) is told now, in the order they ran.
        Action[] queued = [.. sWhenBound];
        sWhenBound.Clear();
        foreach (Action call in queued)
            call();
    }

    /// <summary>Calls the engine now, or once it binds when no engine is attached yet (NativeAOT: module
    /// initializers run first). A host that never binds one (the pure-managed smoke test) never runs them.</summary>
    internal static void WhenBound(Action call)
    {
        if (IsBound)
            call();
        else
            sWhenBound.Add(call);
    }

    /// <summary>Whether an engine is attached (a pure-managed host, such as the lifecycle smoke test, has none).</summary>
    internal static bool IsBound => sResolver != null;

    internal static nint ResolveRaw(string symbol)
    {
        if (sResolver == null)
            throw new InvalidOperationException("The trusted native API resolver has not been bound.");
        byte[] utf8 = Encoding.UTF8.GetBytes(symbol + "\0");
        fixed (byte* name = utf8)
            return sResolver(sContext, name);
    }

    internal static nint Resolve(string symbol)
    {
        VerifyVersion();
        nint address = ResolveRaw(symbol);
        return address != 0 ? address :
            throw new MissingMethodException($"Native Tallow entrypoint is missing: {symbol}");
    }
}

/// <summary>One string of a generated binding that passes its strings packed (more arguments than .NET in a browser
/// allows one by one): UTF-8 bytes and their length. The layout of Beef's <c>CSharpStringArg</c>.</summary>
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
internal readonly unsafe struct NativeStringArg(byte* ptr, int length)
{
    public readonly byte* Ptr = ptr;
    public readonly int Length = length;
}
