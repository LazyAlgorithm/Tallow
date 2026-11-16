using System.Collections.Concurrent;
using System.Globalization;
using System.Numerics;
using System.Reflection;
using System.Text;

namespace Tallow;

/// <summary>Where an <see cref="RpcAttribute"/> method runs.</summary>
public enum RpcTarget
{
    /// <summary>On the server only. A client may call it on an object it owns.</summary>
    Server = 0,
    /// <summary>On the server and every client. Called on the server, or by the client that owns the object
    /// (through the server, which then runs it everywhere, that client included).</summary>
    Everyone = 1,
}

/// <summary>
/// Marks a script method that <see cref="Script.Rpc"/> can call across the network. Parameters may be
/// int, float, bool, string, enums, Vector2/3/4 and <see cref="GameObject"/>. Without a session it simply
/// runs here.
/// </summary>
[AttributeUsage(AttributeTargets.Method, Inherited = true)]
public sealed class RpcAttribute(RpcTarget target = RpcTarget.Everyone) : Attribute
{
    public RpcTarget Target { get; } = target;
}

/// The [Rpc] methods of script types, and the text their arguments travel as.
internal static class RpcMethods
{
    internal sealed record Entry(MethodInfo Method, RpcTarget Target, Type[] Parameters);

    private static readonly ConcurrentDictionary<(Type, string), Entry?> Cache = new();
    private const char Separator = '\u001f';

    /// <summary>Forgets every game type (keys hold them): the runtime calls this when the game unloads.</summary>
    internal static void Forget() => Cache.Clear();

    /// <summary>Client id of the machine that called the RPC now running (0: the server or this machine).</summary>
    [ThreadStatic] internal static int CurrentSender;

    internal static Entry? Find(Type type, string name) => Cache.GetOrAdd((type, name), key => Resolve(key.Item1, key.Item2));

    private static Entry? Resolve(Type type, string name)
    {
        for (Type? owner = type; owner != null && owner != typeof(Script); owner = owner.BaseType)
        {
            MethodInfo[] candidates = owner.GetMethods(BindingFlags.Instance | BindingFlags.Public |
                    BindingFlags.NonPublic | BindingFlags.DeclaredOnly)
                .Where(method => method.Name == name && method.IsDefined(typeof(RpcAttribute), inherit: true))
                .ToArray();
            if (candidates.Length == 0)
                continue;
            if (candidates.Length > 1)
                throw new InvalidOperationException($"{type.Name}.{name}: an [Rpc] method cannot be overloaded.");
            MethodInfo found = candidates[0];
            if (found.IsGenericMethodDefinition || found.ReturnType != typeof(void))
                throw new InvalidOperationException($"{type.Name}.{name}: an [Rpc] method returns void and is not generic.");
            Type[] parameters = found.GetParameters().Select(parameter => parameter.ParameterType).ToArray();
            foreach (Type parameter in parameters)
                if (!Supported(parameter))
                    throw new InvalidOperationException(
                        $"{type.Name}.{name}: [Rpc] parameters cannot be {parameter.Name}. Use int, float, bool, string, enums, vectors or GameObject.");
            return new Entry(found, found.GetCustomAttribute<RpcAttribute>(inherit: true)!.Target, parameters);
        }
        return null;
    }

    private static bool Supported(Type type) =>
        type == typeof(int) || type == typeof(float) || type == typeof(bool) || type == typeof(string) ||
        type.IsEnum || type == typeof(Vector2) || type == typeof(Vector3) || type == typeof(Vector4) ||
        type == typeof(GameObject);

    internal static string Encode(Entry entry, object?[] arguments)
    {
        if (arguments.Length != entry.Parameters.Length)
            throw new ArgumentException(
                $"{entry.Method.Name} takes {entry.Parameters.Length} argument(s), not {arguments.Length}.");
        var text = new StringBuilder();
        for (int i = 0; i < arguments.Length; i++)
        {
            if (i > 0)
                text.Append(Separator);
            object? value = arguments[i];
            Type type = entry.Parameters[i];
            if (value is null ? type != typeof(string) : !type.IsInstanceOfType(value))
                throw new ArgumentException($"{entry.Method.Name}: argument {i + 1} must be {type.Name}.");
            text.Append(Escape(Format(value)));
        }
        return text.ToString();
    }

    private static string Number(float value) => value.ToString(CultureInfo.InvariantCulture);

    private static string Format(object? value) => value switch
    {
        null => "",
        float x when !float.IsFinite(x) => throw new ArgumentException("RPC floats must be finite."),
        float x => Number(x),
        int x => x.ToString(CultureInfo.InvariantCulture),
        bool x => x ? "1" : "0",
        string x => x,
        Enum x => x.ToString(),
        Vector2 v => $"{Number(v.X)},{Number(v.Y)}",
        Vector3 v => $"{Number(v.X)},{Number(v.Y)},{Number(v.Z)}",
        Vector4 v => $"{Number(v.X)},{Number(v.Y)},{Number(v.Z)},{Number(v.W)}",
        GameObject o => o.Id.ToString(CultureInfo.InvariantCulture),
        _ => throw new ArgumentException($"RPC arguments cannot be {value.GetType().Name}."),
    };

    private static string Escape(string text)
    {
        if (text.Contains('\0'))
            throw new ArgumentException("RPC strings cannot contain NUL characters.");
        return text.Replace("\\", "\\\\").Replace("\u001f", "\\u");
    }

    private static List<string> Split(string text)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (c == '\\' && i + 1 < text.Length)
            {
                char next = text[++i];
                current.Append(next == 'u' ? Separator : next);
            }
            else if (c == Separator)
            {
                parts.Add(current.ToString());
                current.Clear();
            }
            else
                current.Append(c);
        }
        parts.Add(current.ToString());
        return parts;
    }

    private static float Float(string text)
    {
        float value = float.Parse(text, CultureInfo.InvariantCulture);
        return float.IsFinite(value) ? value : throw new FormatException("RPC floats must be finite.");
    }

    private static object Parse(Type type, string text, ulong sceneId)
    {
        if (type == typeof(int)) return int.Parse(text, CultureInfo.InvariantCulture);
        if (type == typeof(float)) return Float(text);
        if (type == typeof(bool)) return text == "1";
        if (type == typeof(string)) return text;
        if (type == typeof(GameObject)) return new GameObject(sceneId, ulong.Parse(text, CultureInfo.InvariantCulture));
        if (type.IsEnum)
        {
            object value = Enum.Parse(type, text, ignoreCase: false);
            if (!Enum.IsDefined(type, value) && !type.IsDefined(typeof(FlagsAttribute), inherit: false))
                throw new FormatException("Undefined enum value in an RPC.");
            return value;
        }
        float[] numbers = text.Split(',').Select(Float).ToArray();
        if (type == typeof(Vector2) && numbers.Length == 2) return new Vector2(numbers[0], numbers[1]);
        if (type == typeof(Vector3) && numbers.Length == 3) return new Vector3(numbers[0], numbers[1], numbers[2]);
        if (type == typeof(Vector4) && numbers.Length == 4) return new Vector4(numbers[0], numbers[1], numbers[2], numbers[3]);
        throw new FormatException($"Bad {type.Name} in an RPC.");
    }

    internal static object?[] Decode(Entry entry, string text, ulong sceneId)
    {
        if (entry.Parameters.Length == 0)
            return text.Length == 0 ? [] : throw new FormatException("Arguments for an RPC that takes none.");
        List<string> parts = Split(text);
        if (parts.Count != entry.Parameters.Length)
            throw new FormatException($"{entry.Method.Name} received {parts.Count} argument(s), not {entry.Parameters.Length}.");
        var values = new object?[parts.Count];
        for (int i = 0; i < parts.Count; i++)
            values[i] = Parse(entry.Parameters[i], parts[i], sceneId);
        return values;
    }

    internal static void Run(Script script, Entry entry, object?[] arguments, int sender)
    {
        int previous = CurrentSender;
        CurrentSender = sender;
        try
        {
            entry.Method.Invoke(script, BindingFlags.DoNotWrapExceptions, null, arguments, CultureInfo.InvariantCulture);
        }
        finally
        {
            CurrentSender = previous;
        }
    }

    /// A call received from the network: only an [Rpc] method of exactly that target, with valid arguments.
    internal static void RunFromNetwork(Script script, string method, string arguments, int target, int sender)
    {
        Entry entry = Find(script.GetType(), method) ??
            throw new InvalidOperationException($"{script.GetType().Name} has no [Rpc] method {method}.");
        if ((int)entry.Target != target)
            throw new InvalidOperationException($"{method} is not an RPC for {(RpcTarget)target}.");
        Run(script, entry, Decode(entry, arguments, script.GameObject.SceneId), sender);
    }
}
