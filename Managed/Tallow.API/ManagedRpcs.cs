using System;
using System.Collections.Generic;

namespace Tallow;

/// <summary>
/// One <see cref="RpcAttribute"/> method the build described: where it runs, its parameter types, and a direct call
/// (no reflection). A method the build could not call (generic, returning a value, or with a parameter type an RPC
/// cannot carry) is registered with its error instead, so the run-time message is the same as a reflected lookup's.
/// </summary>
public sealed class ManagedRpc
{
    /// <summary>Describes one [Rpc] method: where it runs, its parameter types, and how to call it (or why it cannot be).</summary>
    public ManagedRpc(RpcTarget target, Type[] parameters, Action<object, object?[]>? invoke, string? error)
    {
        Target = target;
        Parameters = parameters;
        Invoke = invoke;
        Error = error;
    }

    /// <summary>Where the method runs (server, client, or both).</summary>
    public RpcTarget Target { get; }
    /// <summary>The method's parameter types, in order.</summary>
    public Type[] Parameters { get; }
    /// <summary>Calls the method on a script instance with one already-parsed value per parameter.</summary>
    public Action<object, object?[]>? Invoke { get; }
    /// <summary>Why the method cannot be called, when it cannot; null when it can.</summary>
    public string? Error { get; }
}

/// <summary>
/// The build's <see cref="RpcAttribute"/> methods per script class (Tallow.Build generates them), so a NativeAOT
/// game calls an RPC without reflecting over its own types. A class from a package has no entry and is resolved the
/// old way.
/// </summary>
public static class ManagedRpcs
{
    private static readonly Dictionary<Type, Dictionary<string, List<ManagedRpc>>> sMethods = [];
    private static readonly object sLock = new();

    /// <summary>Adds one [Rpc] method of a class. Generated code calls this once per method.</summary>
    public static void Register(Type type, string name, ManagedRpc rpc)
    {
        lock (sLock)
        {
            if (!sMethods.TryGetValue(type, out Dictionary<string, List<ManagedRpc>>? byName))
                sMethods[type] = byName = new Dictionary<string, List<ManagedRpc>>(StringComparer.Ordinal);
            if (!byName.TryGetValue(name, out List<ManagedRpc>? list))
                byName[name] = list = [];
            list.Add(rpc);
        }
    }

    /// <summary>Whether the build described the class (its own methods; base classes have their own entries).</summary>
    public static bool IsRegistered(Type type)
    {
        lock (sLock)
            return sMethods.ContainsKey(type);
    }

    /// <summary>The [Rpc] methods a class declares under a name: none, one, or several (which is an error).</summary>
    public static ManagedRpc[]? Find(Type type, string name)
    {
        lock (sLock)
            return sMethods.TryGetValue(type, out Dictionary<string, List<ManagedRpc>>? byName) &&
                byName.TryGetValue(name, out List<ManagedRpc>? list) ? [.. list] : null;
    }

    /// <summary>Forgets the game's classes (its code stopped or was reloaded; the next load registers them).</summary>
    public static void Clear()
    {
        lock (sLock)
            sMethods.Clear();
    }
}
