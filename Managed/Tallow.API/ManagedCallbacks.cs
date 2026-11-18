using System;
using System.Collections.Generic;

namespace Tallow;

/// <summary>
/// The callbacks a script class overrides, described by the build (Tallow.Build generates one entry per Script class)
/// so the engine skips the callbacks a class does not have without reflecting over game types, which a NativeAOT
/// build cannot see through. The names are the <see cref="Script"/> methods; the runtime knows their bits.
/// </summary>
public static class ManagedCallbacks
{
    private static readonly Dictionary<Type, string[]> sOverridden = [];
    private static readonly object sLock = new();

    /// <summary>The callback methods (by name) a script class declares or inherits below Script. Generated code calls
    /// this; an empty list means "none", which is as important to know as a non-empty one.</summary>
    public static void Register(Type type, string[] overridden)
    {
        lock (sLock)
            sOverridden[type] = overridden;
    }

    /// <summary>The callback names of a registered script class, or null when no game assembly described it.</summary>
    public static string[]? Of(Type type)
    {
        lock (sLock)
            return sOverridden.TryGetValue(type, out string[]? names) ? names : null;
    }

    /// <summary>Forgets the game's classes (its code stopped or was reloaded; the next load registers them).</summary>
    public static void Clear()
    {
        lock (sLock)
            sOverridden.Clear();
    }
}
