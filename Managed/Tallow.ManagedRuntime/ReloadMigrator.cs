using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
using Tallow;

namespace Tallow.ManagedRuntime;

/// <summary>
/// Hot reload: copies a running script's fields from the old game code to the new, as objects rather than text, so
/// anything a script keeps comes across: dictionaries, sets, queues, arrays, nested classes and structs of the game's
/// own types (matched by full name in the new assemblies, field by field), shared objects and cycles (one copy each).
/// Script references point at the new instances. A value that cannot be carried (a delegate or task made by the old
/// code, a type the new code removed, a field whose type changed beyond a number conversion) leaves the new field at
/// its initializer. Nothing in the result references the old context, so it can be unloaded.
/// </summary>
internal sealed class ReloadMigrator(AssemblyLoadContext oldContext, AssemblyLoadContext newContext,
    IReadOnlyDictionary<Script, Script> scripts)
{
    private const int MaxDepth = 64;
    private const FieldAttributes NonSerializedBit = (FieldAttributes)0x0080;
    private static readonly object Skip = new();
    // Running work of the old code (delegates, tasks, timers): expected to start again, so not reported.
    private static readonly object Restart = new();

    private readonly Dictionary<object, object?> _copies = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<Type, Type?> _types = [];
    private readonly Dictionary<string, Assembly> _newAssemblies = newContext.Assemblies
        .GroupBy(assembly => assembly.GetName().Name ?? "").ToDictionary(group => group.Key, group => group.First());

    /// <summary>How many fields kept their old value, and the names of those that did not.</summary>
    public int Copied { get; private set; }
    public List<string> Dropped { get; } = [];

    /// <summary>Copies every instance field below Script (private and base-class ones too), except [NonSerialized].</summary>
    public void CopyScript(Script from, Script to)
    {
        var target = to.GetType();
        for (Type? owner = from.GetType(); owner != null && owner != typeof(Script); owner = owner.BaseType)
        {
            Type? newOwner = FindOwner(target, owner.Name);
            if (newOwner == null)
                continue;
            foreach (FieldInfo field in owner.GetFields(BindingFlags.Instance | BindingFlags.Public |
                BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
            {
                if ((field.Attributes & NonSerializedBit) != 0 || field.IsLiteral)
                    continue;
                FieldInfo? next = newOwner.GetField(field.Name, BindingFlags.Instance | BindingFlags.Public |
                    BindingFlags.NonPublic | BindingFlags.DeclaredOnly);
                if (next == null || (next.Attributes & NonSerializedBit) != 0)
                    continue;
                CopyField(field, next, from, to, $"{to.GetType().Name}.{field.Name}");
            }
        }
    }

    // The class in the new chain with the same name as one in the old chain (a base class can be renamed only
    // with the script; [FormerlyNamed] maps the script itself).
    private static Type? FindOwner(Type type, string name)
    {
        for (Type? owner = type; owner != null && owner != typeof(Script); owner = owner.BaseType)
            if (owner.Name == name)
                return owner;
        return null;
    }

    private void CopyField(FieldInfo from, FieldInfo to, object source, object target, string label)
    {
        object? value;
        try
        {
            value = Convert(from.GetValue(source), to.FieldType, 0);
        }
        catch (Exception)
        {
            value = Skip;
        }
        if (ReferenceEquals(value, Restart))
            return;
        if (ReferenceEquals(value, Skip))
        {
            Dropped.Add(label);
            return;
        }
        try
        {
            to.SetValue(target, value);
            Copied++;
        }
        catch (Exception)
        {
            Dropped.Add(label);
        }
    }

    /// <summary>The value for a field of type <paramref name="declared"/> in the new code, or Skip.</summary>
    private object? Convert(object? value, Type declared, int depth)
    {
        if (value == null)
            return declared.IsValueType && Nullable.GetUnderlyingType(declared) == null ? Skip : null;
        if (depth > MaxDepth)
            return Skip;
        if (value is Script script)
            return scripts.TryGetValue(script, out Script? replacement) && declared.IsInstanceOfType(replacement) ? replacement : Skip;
        Type type = value.GetType();
        if (!type.IsValueType && _copies.TryGetValue(value, out object? done))
            return done != null && declared.IsInstanceOfType(done) ? done : Skip;

        Type? mapped = MapType(type);
        if (mapped == null)
            return Skip;
        if (mapped.IsPrimitive || mapped == typeof(string) || mapped == typeof(decimal))
            return Number(value, declared);
        if (mapped.IsEnum)
        {
            // By member name, so reordering an enum keeps the meaning; by number for a removed name or flags.
            object converted = type == mapped ? value
                : Enum.IsDefined(type, value) && Enum.TryParse(mapped, value.ToString(), out object? named) ? named!
                : Enum.ToObject(mapped, System.Convert.ToInt64(value));
            return declared.IsInstanceOfType(converted) ? converted : Number(converted, declared);
        }
        if (!(Nullable.GetUnderlyingType(declared) ?? declared).IsAssignableFrom(mapped))
            return Skip;
        // Running work of the old code: the new field starts at its initializer (scripts start their timers again).
        if (value is Delegate || value is Task || value is MemberInfo || value is Assembly || value is Thread ||
            value is Timer || value is System.Timers.Timer || value is CancellationTokenSource || value is IAsyncResult)
            return Restart;

        if (value is Array array)
            return CopyArray(array, mapped, depth);
        if (type.IsGenericType && CopyCollection(value, type, mapped, depth) is { } collection)
            return collection;
        // Engine and system types (Vector3, GameObject handles, StringBuilder ...) hold nothing of the old code;
        // a tuple or pair of object can, so it is copied.
        if (!Owned(type) && !(type.IsValueType && type.IsGenericType && HoldsObjects(type)))
            return value;
        return CopyObject(value, type, mapped, depth);
    }

    private static bool Usable(object? value) => !ReferenceEquals(value, Skip) && !ReferenceEquals(value, Restart);

    // Numbers and text: the same value, or a number converted when the field's type changed (int -> float).
    private static object? Number(object value, Type declared)
    {
        Type target = Nullable.GetUnderlyingType(declared) ?? declared;
        if (target.IsInstanceOfType(value))
            return value;
        if (value is IConvertible && (target.IsPrimitive || target == typeof(decimal)) && value is not string)
        {
            try
            {
                return System.Convert.ChangeType(value, target, System.Globalization.CultureInfo.InvariantCulture);
            }
            catch (Exception)
            {
                return Skip;
            }
        }
        return declared == typeof(object) ? value : Skip;
    }

    private object? CopyArray(Array array, Type mapped, int depth)
    {
        Type element = mapped.GetElementType()!;
        if (array.Rank != 1)
            return Owned(array.GetType()) ? Skip : array;
        Array copy = Array.CreateInstance(element, array.Length);
        _copies[array] = copy;
        for (int i = 0; i < array.Length; i++)
        {
            object? item = Convert(array.GetValue(i), element, depth + 1);
            if (!ReferenceEquals(item, Skip) && !ReferenceEquals(item, Restart))
                copy.SetValue(item, i);
        }
        return copy;
    }

    // List, Dictionary, HashSet, SortedSet/SortedDictionary/SortedList, Queue, Stack, LinkedList: a new collection
    // of the new item types (only the default comparer is kept), filled in the old order.
    private object? CopyCollection(object value, Type type, Type mapped, int depth)
    {
        Type definition = type.GetGenericTypeDefinition();
        if (definition.Assembly != typeof(List<>).Assembly && definition.Assembly != typeof(LinkedList<>).Assembly &&
            definition.Assembly != typeof(SortedSet<>).Assembly)
            return null;
        Type[] arguments = mapped.GetGenericArguments();
        if (value is IDictionary dictionary && arguments.Length == 2)
        {
            if (!Owned(type) && !HoldsObjects(type))
                return value;
            object copy = Create(value, mapped);
            _copies[value] = copy;
            var target = (IDictionary)copy;
            foreach (DictionaryEntry entry in dictionary)
            {
                object? key = Convert(entry.Key, arguments[0], depth + 1);
                object? item = Convert(entry.Value, arguments[1], depth + 1);
                if (Usable(key) && Usable(item) && key != null)
                    target[key] = item;
            }
            return copy;
        }
        if (arguments.Length != 1 || value is not IEnumerable items)
            return null;
        string? add = definition == typeof(Queue<>) ? "Enqueue" : definition == typeof(Stack<>) ? "Push" :
            definition == typeof(LinkedList<>) ? "AddLast" : definition == typeof(List<>) || definition == typeof(HashSet<>) ||
            definition == typeof(SortedSet<>) ? "Add" : null;
        if (add == null)
            return Owned(type) ? Skip : null;
        if (!Owned(type) && !HoldsObjects(type))
            return value;
        object result = Create(value, mapped);
        _copies[value] = result;
        MethodInfo method = mapped.GetMethod(add, [arguments[0]])!;
        var list = items.Cast<object?>().ToList();
        // A stack enumerates from the top; pushing in that order would turn it over.
        if (definition == typeof(Stack<>))
            list.Reverse();
        foreach (object? item in list)
        {
            object? converted = Convert(item, arguments[0], depth + 1);
            if (Usable(converted))
                method.Invoke(result, [converted]);
        }
        return result;
    }

    // With the old collection's comparer when it is an engine or system one (StringComparer.OrdinalIgnoreCase ...).
    private object Create(object value, Type mapped)
    {
        object? comparer = value.GetType().GetProperty("Comparer")?.GetValue(value);
        if (comparer != null && !Owned(comparer.GetType()) &&
            mapped.GetConstructors().Any(c => c.GetParameters() is [{ } only] && only.ParameterType.IsInstanceOfType(comparer)))
        {
            try
            {
                return Activator.CreateInstance(mapped, comparer)!;
            }
            catch (Exception)
            {
                // Falls back to the default comparer below.
            }
        }
        return Activator.CreateInstance(mapped)!;
    }

    // A collection of object, interfaces or non-sealed classes can hold scripts or game objects even when its own
    // type names none.
    private static bool HoldsObjects(Type type) =>
        type.GetGenericArguments().Any(argument => !argument.IsValueType && argument != typeof(string));

    private object? CopyObject(object value, Type type, Type mapped, int depth)
    {
        if (mapped.IsAbstract || typeof(Delegate).IsAssignableFrom(mapped))
            return Skip;
        object copy;
        try
        {
            // The new constructor runs, so a field new in this version starts at its initializer.
            copy = mapped.IsValueType || mapped.GetConstructor(BindingFlags.Instance | BindingFlags.Public |
                BindingFlags.NonPublic, Type.EmptyTypes) == null
                ? RuntimeHelpers.GetUninitializedObject(mapped)
                : Activator.CreateInstance(mapped, nonPublic: true)!;
        }
        catch (Exception)
        {
            return Skip;
        }
        if (!type.IsValueType)
            _copies[value] = copy;
        for (Type? owner = type; owner != null && owner != typeof(object) && owner != typeof(ValueType); owner = owner.BaseType)
        {
            Type? newOwner = mapped;
            while (newOwner != null && newOwner.Name != owner.Name)
                newOwner = newOwner.BaseType;
            if (newOwner == null)
                continue;
            foreach (FieldInfo field in owner.GetFields(BindingFlags.Instance | BindingFlags.Public |
                BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
            {
                if ((field.Attributes & NonSerializedBit) != 0)
                    continue;
                FieldInfo? next = newOwner.GetField(field.Name, BindingFlags.Instance | BindingFlags.Public |
                    BindingFlags.NonPublic | BindingFlags.DeclaredOnly);
                if (next == null)
                    continue;
                object? converted;
                try
                {
                    converted = Convert(field.GetValue(value), next.FieldType, depth + 1);
                }
                catch (Exception)
                {
                    continue;
                }
                if (Usable(converted))
                    next.SetValue(copy, converted);
            }
        }
        return copy;
    }

    /// <summary>Whether the type, or any type it is built from, comes from the old game code.</summary>
    private bool Owned(Type type)
    {
        if (type.HasElementType)
            return Owned(type.GetElementType()!);
        if (type.IsGenericType && type.GetGenericArguments().Any(Owned))
            return true;
        return AssemblyLoadContext.GetLoadContext(type.Assembly) == oldContext;
    }

    /// <summary>The same type in the new code (by assembly and full name), or null when the new code removed it.</summary>
    private Type? MapType(Type type)
    {
        if (_types.TryGetValue(type, out Type? known))
            return known;
        Type? mapped;
        if (type.IsArray)
        {
            Type? element = MapType(type.GetElementType()!);
            mapped = element == null ? null : type.IsSZArray ? element.MakeArrayType() : element.MakeArrayType(type.GetArrayRank());
        }
        else if (type.IsGenericType && !type.IsGenericTypeDefinition)
        {
            Type? definition = MapType(type.GetGenericTypeDefinition());
            Type?[] arguments = type.GetGenericArguments().Select(MapType).ToArray();
            mapped = definition == null || arguments.Any(argument => argument == null) ? null
                : definition.MakeGenericType(arguments!);
        }
        else if (AssemblyLoadContext.GetLoadContext(type.Assembly) != oldContext)
            mapped = type;
        else
            mapped = _newAssemblies.TryGetValue(type.Assembly.GetName().Name ?? "", out Assembly? assembly)
                ? assembly.GetType(type.FullName ?? "", throwOnError: false) : null;
        _types[type] = mapped;
        return mapped;
    }
}
