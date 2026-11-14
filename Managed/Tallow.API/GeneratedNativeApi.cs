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

    internal static void Bind(nint context, nint resolver)
    {
        sContext = context;
        sResolver = (delegate* unmanaged[Cdecl]<nint, byte*, nint>)resolver;
        ResetVersion();
    }

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
