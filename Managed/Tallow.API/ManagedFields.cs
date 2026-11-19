using System;
using System.Collections;
using System.Collections.Generic;

namespace Tallow;

/// <summary>
/// One instance field the runtime reads, writes, saves or syncs, described by the build (Tallow.Build generates a
/// table for every script, data asset and [Serializable] class or struct). A NativeAOT game then never reflects over
/// its own types to find or set a field. A type the build did not describe (one from a package) falls back to
/// reflection in Tallow.ManagedRuntime.
/// </summary>
public sealed class ManagedField
{
    /// <summary>Describes one field: its name and type, how to read and write it, and how it is saved, synced and shown.</summary>
    public ManagedField(string name, Type fieldType, Func<object, object?> get, Action<object, object?>? set,
        bool isPublic, bool showInInspector, bool hideInInspector, bool saved, bool sync, bool notSerialized,
        bool compilerGenerated)
    {
        Name = name;
        FieldType = fieldType;
        Get = get;
        Set = set;
        IsPublic = isPublic;
        ShowInInspector = showInInspector;
        HideInInspector = hideInInspector;
        Saved = saved;
        Sync = sync;
        NotSerialized = notSerialized;
        CompilerGenerated = compilerGenerated;
    }

    /// <summary>The field's name in the scene, save and Inspector text.</summary>
    public string Name { get; }
    /// <summary>The declared field type.</summary>
    public Type FieldType { get; }
    /// <summary>The field's value in an object of its declaring (or a derived) type.</summary>
    public Func<object, object?> Get { get; }
    /// <summary>Stores a value; null for a readonly or const field (the runtime never writes those).</summary>
    public Action<object, object?>? Set { get; }
    /// <summary>Whether the field is public (and so settable from a script).</summary>
    public bool IsPublic { get; }
    /// <summary>Whether the Inspector shows the field.</summary>
    public bool ShowInInspector { get; }
    /// <summary>Whether the Inspector hides the field.</summary>
    public bool HideInInspector { get; }
    /// <summary>Whether the field is written to the save game.</summary>
    public bool Saved { get; }
    /// <summary>Whether the field syncs over the network.</summary>
    public bool Sync { get; }
    /// <summary>Whether the field is excluded from serialization.</summary>
    public bool NotSerialized { get; }
    /// <summary>Whether the compiler generated the field rather than it being written in source.</summary>
    public bool CompilerGenerated { get; }
}

/// <summary>
/// The build's field tables, default-value constructors, List&lt;T&gt; factories and component lookups, registered by
/// the game assemblies (a module initializer each). Everything here is optional: the runtime falls back to reflection
/// for a type no assembly registered, so an old build still plays.
/// </summary>
public static class ManagedFields
{
    private static readonly Dictionary<Type, ManagedField[]> sFields = new();
    private static readonly Dictionary<Type, Func<object>> sCreate = new();
    private static readonly Dictionary<Type, Func<IList>> sLists = new();
    private static readonly Dictionary<Type, Func<GameObject, object?>> sComponents = new();
    private static readonly object sLock = new();

    /// <summary>The fields a type declares itself (base classes have their own tables). Generated code calls this.</summary>
    public static void RegisterFields(Type type, ManagedField[] fields)
    {
        lock (sLock)
            sFields[type] = fields;
    }

    /// <summary>A parameterless value of the type (a struct, or a class with such a constructor).</summary>
    public static void RegisterCreate(Type type, Func<object> create)
    {
        lock (sLock)
            sCreate[type] = create;
    }

    /// <summary>A new empty List&lt;T&gt; for an Inspector field's element type.</summary>
    public static void RegisterList(Type element, Func<IList> create)
    {
        lock (sLock)
            sLists[element] = create;
    }

    /// <summary>The component of a type on an object, as TryGetComponent&lt;T&gt; finds it (null when absent).</summary>
    public static void RegisterComponent(Type type, Func<GameObject, object?> find)
    {
        lock (sLock)
            sComponents[type] = find;
    }

    /// <summary>The type's own fields, or null when the build did not describe it.</summary>
    public static ManagedField[]? Fields(Type type)
    {
        lock (sLock)
            return sFields.TryGetValue(type, out ManagedField[]? fields) ? fields : null;
    }

    /// <summary>A new default value of the type, when the build registered a constructor; otherwise false and a null value.</summary>
    public static bool TryCreate(Type type, out object value)
    {
        lock (sLock)
        {
            if (sCreate.TryGetValue(type, out Func<object>? create))
            {
                value = create();
                return true;
            }
        }
        value = null!;
        return false;
    }

    /// <summary>Whether the build registered a parameterless value of the type.</summary>
    public static bool ContainsCreate(Type type)
    {
        lock (sLock)
            return sCreate.ContainsKey(type);
    }

    /// <summary>A new empty List&lt;T&gt; for the element type, when the build registered one; otherwise false and a null list.</summary>
    public static bool TryNewList(Type element, out IList list)
    {
        lock (sLock)
        {
            if (sLists.TryGetValue(element, out Func<IList>? create))
            {
                list = create();
                return true;
            }
        }
        list = null!;
        return false;
    }

    /// <summary>The component of the type on the object, when the build registered a lookup; otherwise false and null.</summary>
    public static bool TryComponent(GameObject owner, Type type, out object? component)
    {
        lock (sLock)
        {
            if (sComponents.TryGetValue(type, out Func<GameObject, object?>? find))
            {
                component = find(owner);
                return true;
            }
        }
        component = null;
        return false;
    }

    /// <summary>Forgets the tables of a game whose code stopped or was reloaded (its next load registers them).</summary>
    public static void Clear()
    {
        lock (sLock)
        {
            sFields.Clear();
            sCreate.Clear();
            sLists.Clear();
            sComponents.Clear();
        }
    }
}
