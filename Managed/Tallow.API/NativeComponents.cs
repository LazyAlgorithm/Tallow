using System.Globalization;
using System.Numerics;
using System.Text;

namespace Tallow;

/// <summary>
/// Any built-in component on an object, by its type name ("Tallow.Light"), with its Inspector fields read and
/// written by name. The typed handles (<see cref="Light"/>, <see cref="MeshRenderer"/>...) are built on this; use it
/// directly for a field they do not cover. Object references and lists are not reachable this way.
/// </summary>
public readonly record struct NativeComponent(GameObject GameObject, string TypeName) : IComponent
{
    public bool IsValid => CSharpNativeComponents.Has(GameObject.SceneId, GameObject.Id, TypeName);

    /// <summary>Sets a field from its scene-file text ("0.5", "1 2 3", "Point"). False when it does not exist or parse.</summary>
    public bool TrySetText(string field, string sceneText) =>
        CSharpNativeComponents.SetField(GameObject.SceneId, GameObject.Id, TypeName, field, sceneText);

    /// <summary>A field's scene-file text, or null when the component or field is missing.</summary>
    public string? GetText(string field)
    {
        Span<byte> buffer = stackalloc byte[256];
        int length = CSharpNativeComponents.CopyField(GameObject.SceneId, GameObject.Id, TypeName, field, buffer);
        if (length < 0)
            return null;
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, CSharpNativeComponents.CopyField(GameObject.SceneId, GameObject.Id, TypeName, field, buffer));
        }
        return Encoding.UTF8.GetString(buffer[..length]);
    }

    private void SetText(string field, string text)
    {
        if (!TrySetText(field, text))
            throw IsValid
                ? new ArgumentException($"{TypeName} has no field '{field}' that takes \"{text}\".", nameof(field))
                : new InvalidOperationException($"{GameObject} has no {TypeName}.");
    }

    private string[] Tokens(string field) =>
        GetText(field)?.Split(' ', StringSplitOptions.RemoveEmptyEntries) ?? [];

    private static string Number(float value) => value.ToString("0.#########", CultureInfo.InvariantCulture);
    private static float Parse(string text) =>
        float.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out float value) ? value : 0f;

    public void Set(string field, float value) => SetText(field, Number(value));
    public void Set(string field, int value) => SetText(field, value.ToString(CultureInfo.InvariantCulture));
    public void Set(string field, bool value) => SetText(field, value ? "1" : "0");
    public void Set(string field, Vector2 value) => SetText(field, $"{Number(value.X)} {Number(value.Y)}");
    public void Set(string field, Vector3 value) => SetText(field, $"{Number(value.X)} {Number(value.Y)} {Number(value.Z)}");
    public void Set(string field, Vector4 value) =>
        SetText(field, $"{Number(value.X)} {Number(value.Y)} {Number(value.Z)} {Number(value.W)}");
    public void Set(string field, Quaternion value) =>
        SetText(field, $"{Number(value.X)} {Number(value.Y)} {Number(value.Z)} {Number(value.W)}");
    public void Set(string field, Color value) =>
        SetText(field, $"{Number(value.R)} {Number(value.G)} {Number(value.B)} {Number(value.A)}");
    public void Set<TEnum>(string field, TEnum value) where TEnum : struct, Enum => SetText(field, value.ToString());

    public void Set(string field, string value)
    {
        var quoted = new StringBuilder("\"");
        foreach (char c in value ?? "")
        {
            if (c is '"' or '\\')
                quoted.Append('\\').Append(c);
            else if (c == '\n')
                quoted.Append("\\n");
            else if (c != '\r')
                quoted.Append(c);
        }
        SetText(field, quoted.Append('"').ToString());
    }

    public float GetFloat(string field) => Tokens(field) is [var x, ..] ? Parse(x) : 0f;
    public int GetInt(string field) => Tokens(field) is [var x, ..] && int.TryParse(x, CultureInfo.InvariantCulture, out int v) ? v : 0;
    public bool GetBool(string field) => Tokens(field) is ["1", ..];
    public Vector3 GetVector3(string field) =>
        Tokens(field) is [var x, var y, var z, ..] ? new Vector3(Parse(x), Parse(y), Parse(z)) : default;
    public Color GetColor(string field) =>
        Tokens(field) is [var r, var g, var b, var a, ..] ? new Color(Parse(r), Parse(g), Parse(b), Parse(a)) : default;
    public TEnum GetEnum<TEnum>(string field) where TEnum : struct, Enum =>
        Tokens(field) is [var x, ..] && Enum.TryParse(x, out TEnum v) ? v : default;

    public string GetString(string field)
    {
        string? text = GetText(field);
        if (text is null || text.Length < 2 || text[0] != '"')
            return text ?? "";
        var plain = new StringBuilder();
        for (int i = 1; i < text.Length - 1; i++)
        {
            if (text[i] == '\\' && i + 1 < text.Length - 1)
                plain.Append(text[++i] == 'n' ? '\n' : text[i]);
            else
                plain.Append(text[i]);
        }
        return plain.ToString();
    }
}

/// <summary>
/// Names the built-in (engine) component a C# handle stands for. The build reads it to let the Inspector offer
/// objects that have one for a field of the handle's type.
/// </summary>
[AttributeUsage(AttributeTargets.Struct | AttributeTargets.Class, Inherited = false)]
public sealed class NativeComponentAttribute(string typeName) : Attribute
{
    public string TypeName { get; } = typeName;
}

/// <summary>Built-in component handles that <see cref="GameObject.AddComponent{T}"/> can add, by native type name.</summary>
internal static class NativeComponentTypes
{
    private static readonly Dictionary<Type, (string Native, Func<GameObject, IComponent> Make)> Known = new()
    {
        [typeof(Light)] = ("Tallow.Light", o => new Light(o)),
        [typeof(MeshRenderer)] = ("Tallow.MeshRenderer", o => new MeshRenderer(o)),
        [typeof(SphereCollider)] = ("Tallow.SphereCollider", o => new SphereCollider(o)),
        [typeof(BoxCollider)] = ("Tallow.BoxCollider", o => new BoxCollider(o)),
        [typeof(NavigationAgent)] = ("Tallow.NavigationAgent", o => new NavigationAgent(o)),
        [typeof(NavigationSurface)] = ("Tallow.NavigationSurface", o => new NavigationSurface(o)),
        [typeof(Rigidbody)] = ("Tallow.Rigidbody", o => new Rigidbody(o)),
        [typeof(CharacterController)] = ("Tallow.CharacterController", o => new CharacterController(o)),
        [typeof(UIDocument)] = ("Tallow.UIDocument", o => new UIDocument(o)),
        [typeof(Animator)] = ("Tallow.Animator", o => new Animator(o)),
        [typeof(VoxelObject)] = ("Tallow.VoxelObject", o => new VoxelObject(o)),
        [typeof(CharacterMotor)] = ("Tallow.CharacterMotor", o => new CharacterMotor(o)),
        [typeof(AudioSource)] = ("Tallow.AudioSource", o => new AudioSource(o)),
    };

    /// <summary>Every handle type with its native name (the in-engine tests check them against their attributes).</summary>
    public static IEnumerable<(Type Type, string Native)> All => Known.Select(entry => (entry.Key, entry.Value.Native));

    public static bool TryGet(Type type, out string native, out Func<GameObject, IComponent> make)
    {
        if (Known.TryGetValue(type, out var entry))
        {
            (native, make) = entry;
            return true;
        }
        (native, make) = ("", null!);
        return false;
    }
}

public enum LightType { Directional, Point, Spot }

/// <summary>A light: its type, color, intensity and range.</summary>
[NativeComponent("Tallow.Light")]
public readonly record struct Light(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.Light");
    public bool IsValid => Data.IsValid;
    public LightType Type { get => Data.GetEnum<LightType>("type"); set => Data.Set("type", value); }
    public Color Color { get => Data.GetColor("color"); set => Data.Set("color", value); }
    public float Intensity { get => Data.GetFloat("intensity"); set => Data.Set("intensity", value); }
    public float Range { get => Data.GetFloat("range"); set => Data.Set("range", value); }
    public float SpotAngle { get => Data.GetFloat("spotAngle"); set => Data.Set("spotAngle", value); }
    public bool CastShadows { get => Data.GetBool("castShadows"); set => Data.Set("castShadows", value); }
}

/// <summary>Draws a mesh ("builtin:cube", "builtin:sphere_smooth" or a model path) with a simple material.</summary>
[NativeComponent("Tallow.MeshRenderer")]
public readonly record struct MeshRenderer(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.MeshRenderer");
    public bool IsValid => Data.IsValid;
    public string Mesh { get => Data.GetString("mesh"); set => Data.Set("mesh", value); }
    public Color Color { get => Data.GetColor("color"); set => Data.Set("color", value); }
    public float Metallic { get => Data.GetFloat("metallic"); set => Data.Set("metallic", value); }
    public float Roughness { get => Data.GetFloat("roughness"); set => Data.Set("roughness", value); }
    public Color Emissive { get => Data.GetColor("emissive"); set => Data.Set("emissive", value); }
    public float EmissiveIntensity { get => Data.GetFloat("emissiveIntensity"); set => Data.Set("emissiveIntensity", value); }
    public bool FlatShading { get => Data.GetBool("flatShading"); set => Data.Set("flatShading", value); }
    public bool Unlit { get => Data.GetBool("unlit"); set => Data.Set("unlit", value); }
    public bool CastShadows { get => Data.GetBool("castShadows"); set => Data.Set("castShadows", value); }
}

[NativeComponent("Tallow.SphereCollider")]
public readonly record struct SphereCollider(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.SphereCollider");
    public bool IsValid => Data.IsValid;
    public float Radius { get => Data.GetFloat("radius"); set => Data.Set("radius", value); }
    public Vector3 Center { get => Data.GetVector3("center"); set => Data.Set("center", value); }
}

[NativeComponent("Tallow.BoxCollider")]
public readonly record struct BoxCollider(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.BoxCollider");
    public bool IsValid => Data.IsValid;
    public Vector3 Size { get => Data.GetVector3("size"); set => Data.Set("size", value); }
    public Vector3 Center { get => Data.GetVector3("center"); set => Data.Set("center", value); }
}

/// <summary>Walks its object along the navigation mesh to a destination.</summary>
[NativeComponent("Tallow.NavigationAgent")]
public readonly record struct NavigationAgent(GameObject GameObject) : IComponent
{
    public bool IsValid => CSharpNavigation.HasAgent(GameObject.SceneId, GameObject.Id);
    public void SetDestination(Vector3 point, float speed, float stoppingDistance = 0.2f) =>
        CSharpNavigation.SetDestination(GameObject.SceneId, GameObject.Id, point, speed, stoppingDistance);
    public void StopMovement() => CSharpNavigation.StopMovement(GameObject.SceneId, GameObject.Id);
    public bool PathPending => CSharpNavigation.PathPending(GameObject.SceneId, GameObject.Id);
    public bool PathFailed => CSharpNavigation.PathFailed(GameObject.SceneId, GameObject.Id);
    public bool HasArrived => CSharpNavigation.HasArrived(GameObject.SceneId, GameObject.Id);
    /// <summary>Corners on the current path (0 with none).</summary>
    public int PathCornerCount => CSharpNavigation.PathCount(GameObject.SceneId, GameObject.Id);
    public float RemainingDistance => CSharpNavigation.RemainingDistance(GameObject.SceneId, GameObject.Id);
}

/// <summary>A baked navigation mesh agents walk on, with queries for choosing where to go.</summary>
[NativeComponent("Tallow.NavigationSurface")]
public readonly record struct NavigationSurface(GameObject GameObject) : IComponent
{
    public bool IsValid => CSharpNavigation.HasSurface(GameObject.SceneId, GameObject.Id);

    /// <summary>The scene's first Navigation Surface (default when it has none).</summary>
    public static NavigationSurface Find(Scene scene)
    {
        ulong id = CSharpNavigation.FindSurface(scene.SessionId);
        return id == 0 ? default : new NavigationSurface(new GameObject(scene.SessionId, id));
    }

    /// <summary>The nearest usable point within <paramref name="maxDistance"/> of a point.</summary>
    public bool SamplePosition(Vector3 point, float maxDistance, out Vector3 found) =>
        Query(0, point, default, maxDistance, 0, out found);

    /// <summary>A random usable point within a radius of a centre and reachable from it (for wandering). The same
    /// <paramref name="random"/> sequence gives the same points on every machine.</summary>
    public bool RandomPoint(Vector3 center, float radius, System.Random random, out Vector3 found) =>
        Query(1, center, default, radius, random.Next(), out found);

    /// <summary>True when an agent could walk straight from one point to the other; otherwise false, with
    /// <paramref name="blocked"/> where it would stop.</summary>
    public bool Raycast(Vector3 from, Vector3 to, out Vector3 blocked) => Query(2, from, to, 0, 0, out blocked);

    /// <summary>Rebuilds the part inside a box after geometry changed there (include the old and new bounds of
    /// anything moved). Agents plan again. Not saved by itself.</summary>
    public bool Rebuild(Vector3 boundsMin, Vector3 boundsMax) =>
        CSharpNavigation.SurfaceRebuild(GameObject.SceneId, GameObject.Id, boundsMin, boundsMax);

    private bool Query(int kind, Vector3 a, Vector3 b, float distance, int seed, out Vector3 found)
    {
        Vector4 result = CSharpNavigation.SurfaceQuery(GameObject.SceneId, GameObject.Id, kind, a, b, distance, seed);
        found = new Vector3(result.X, result.Y, result.Z);
        return result.W != 0;
    }
}

public readonly partial record struct Rigidbody
{
    private NativeComponent Data => new(GameObject, "Tallow.Rigidbody");
    public float Mass { get => Data.GetFloat("mass"); set => Data.Set("mass", value); }
    public bool UseGravity { get => Data.GetBool("useGravity"); set => Data.Set("useGravity", value); }
    public bool IsKinematic { get => Data.GetBool("isKinematic"); set => Data.Set("isKinematic", value); }
    public float Friction { get => Data.GetFloat("friction"); set => Data.Set("friction", value); }
    public float Bounciness { get => Data.GetFloat("bounciness"); set => Data.Set("bounciness", value); }
}

public readonly partial record struct CharacterController
{
    private NativeComponent Data => new(GameObject, "Tallow.CharacterController");
    public float Radius { get => Data.GetFloat("radius"); set => Data.Set("radius", value); }
    /// <summary>How hard walking into rigid bodies pushes them.</summary>
    public float PushStrength { get => Data.GetFloat("pushStrength"); set => Data.Set("pushStrength", value); }
    /// <summary>The capsule's height as set in the Inspector (see <see cref="Height"/> for the current one).</summary>
    public float StandingHeight { get => Data.GetFloat("height"); set => Data.Set("height", value); }
}

public readonly partial record struct UIDocument
{
    /// <summary>The .tui file shown (project relative).</summary>
    public string Document
    {
        get => new NativeComponent(GameObject, "Tallow.UIDocument").GetString("document");
        set => new NativeComponent(GameObject, "Tallow.UIDocument").Set("document", value);
    }
}

/// <summary>The game's command line, for test switches such as <c>--view 3</c>.</summary>
public static class CommandLine
{
    /// <summary>Whether a switch is there.</summary>
    public static bool Has(string name) => !string.IsNullOrEmpty(name) && CSharpCommandLine.HasArg(name);

    /// <summary>The value after a switch, or null without it.</summary>
    public static string? Get(string name)
    {
        if (string.IsNullOrEmpty(name))
            return null;
        Span<byte> buffer = stackalloc byte[256];
        int length = CSharpCommandLine.CopyArg(name, buffer);
        if (length < 0)
            return null;
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, CSharpCommandLine.CopyArg(name, buffer));
        }
        return Encoding.UTF8.GetString(buffer[..length]);
    }

    /// <summary>The whole number after a switch, or fallback without it (or when it is not one).</summary>
    public static int GetInt(string name, int fallback = 0) =>
        int.TryParse(Get(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out int value) ? value : fallback;
}
