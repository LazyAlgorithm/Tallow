using System;
using System.Collections.Generic;

namespace Tallow;

/// <summary>
/// The ways an interface document's event can call a script method by name (a .tui handler): with no argument, with
/// the clicked <see cref="UIElement"/>, or with the element's id as text. One method may offer several. The build
/// generates these per script class, so a NativeAOT game calls them without reflecting over its own types.
/// </summary>
public sealed class ManagedUiHandler
{
    /// <summary>The handler for a name with no argument, when the method takes none.</summary>
    public Func<object, object?>? NoArgument { get; init; }
    /// <summary>The handler that receives the clicked element.</summary>
    public Action<object, UIElement>? WithElement { get; init; }
    /// <summary>The handler that receives the element's id as text.</summary>
    public Action<object, string>? WithString { get; init; }
}

/// <summary>The build-generated UI handlers of the game's script classes (Tallow.Build), by class and method name.</summary>
public static class ManagedUi
{
    private static readonly Dictionary<Type, Dictionary<string, ManagedUiHandler>> sHandlers = [];
    private static readonly object sLock = new();

    /// <summary>The handlers one script class declares (an empty dictionary when it declares none).</summary>
    public static void Register(Type type, Dictionary<string, ManagedUiHandler> handlers)
    {
        lock (sLock)
            sHandlers[type] = handlers;
    }

    /// <summary>Whether the build described the class (its own methods; base classes have their own entries).</summary>
    public static bool IsRegistered(Type type)
    {
        lock (sLock)
            return sHandlers.ContainsKey(type);
    }

    /// <summary>The handler a class declares for a name, or null when it declares none.</summary>
    public static ManagedUiHandler? Find(Type type, string name)
    {
        lock (sLock)
            return sHandlers.TryGetValue(type, out Dictionary<string, ManagedUiHandler>? handlers) &&
                handlers.TryGetValue(name, out ManagedUiHandler? handler) ? handler : null;
    }

    /// <summary>Forgets the game's classes (its code stopped or was reloaded; the next load registers them).</summary>
    public static void Clear()
    {
        lock (sLock)
            sHandlers.Clear();
    }
}
