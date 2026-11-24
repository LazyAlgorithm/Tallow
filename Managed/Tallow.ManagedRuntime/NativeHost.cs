using System.Runtime.InteropServices;
using Tallow;

namespace Tallow.ManagedRuntime;

/// <summary>
/// A NativeAOT game: Tallow's runtime, Tallow.API and the game's assemblies compiled into one native library
/// (Tallow.Build export's NativeAOT step), which the precompiled player loads instead of starting .NET. The library exports one
/// function, generated beside the game (<c>tallow_native_register</c>), that calls <see cref="Register"/>: it hands
/// the engine's host the same entrypoints the JIT host binds by name (<see cref="NativeEntrypoints.Table"/>) and
/// fixes the game's generated registry. No assembly is ever loaded at run time; there is no hot reload, and the
/// library stays loaded until the process ends.
/// </summary>
public static unsafe class NativeHost
{
    /// <summary>The version of the table the host and this runtime agree on (TN_CSHARP_NATIVE_ABI in
    /// native/tallow_dotnet_host.h). Raised whenever an entrypoint is added, removed or changes signature.</summary>
    public const int AbiVersion = 1;

    private static IGameplayComponentRegistry? sRegistry;
    private static string? sError;

    /// <summary>The registry compiled into this library (NativeEntrypoints.LoadGame uses it), or null in a JIT or
    /// browser host.</summary>
    internal static IGameplayComponentRegistry? Registry => sRegistry;

    /// <summary>Why <see cref="Register"/> refused, for the host to show.</summary>
    internal static string? Error => sError;

    /// <summary>Called once by the generated export. Returns 1, or 0 when the host expects another table version or
    /// refused an entrypoint (the reason is written to <paramref name="error"/>, UTF-8, when it is not null).</summary>
    public static int Register(delegate* unmanaged[Cdecl]<byte*, nint, int> register, int hostAbi,
        IGameplayComponentRegistry registry, byte* error, int errorCapacity)
    {
        try
        {
            if (hostAbi != AbiVersion)
                throw new InvalidOperationException(
                    $"This game's native C# library was built for host ABI {AbiVersion}, but the player speaks " +
                    $"{hostAbi}. Build the game again with this engine.");
            ArgumentNullException.ThrowIfNull(registry);
            if (register == null)
                throw new ArgumentNullException(nameof(register));
            sRegistry = registry;
            foreach ((string name, nint pointer) in NativeEntrypoints.Table())
            {
                byte[] utf8 = System.Text.Encoding.UTF8.GetBytes(name + "\0");
                fixed (byte* text = utf8)
                {
                    if (register(text, pointer) == 0)
                        throw new InvalidOperationException("The player refused the C# entrypoint " + name + ".");
                }
            }
            return 1;
        }
        catch (Exception exception)
        {
            sError = exception.Message;
            if (error != null && errorCapacity > 0)
            {
                byte[] utf8 = System.Text.Encoding.UTF8.GetBytes(exception.Message);
                int length = Math.Min(utf8.Length, errorCapacity - 1);
                Marshal.Copy(utf8, 0, (nint)error, length);
                error[length] = 0;
            }
            return 0;
        }
    }
}
