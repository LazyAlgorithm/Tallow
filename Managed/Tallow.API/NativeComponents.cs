using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Runtime.CompilerServices;
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
    /// <summary>Whether the object still has a component of this type.</summary>
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

    /// <summary>Sets a number field. Throws when the component or field does not exist (TrySetText does not).</summary>
    public void Set(string field, float value) => SetText(field, Number(value));
    /// <summary>Sets a whole-number field.</summary>
    public void Set(string field, int value) => SetText(field, value.ToString(CultureInfo.InvariantCulture));
    /// <summary>Sets a tick-box field.</summary>
    public void Set(string field, bool value) => SetText(field, value ? "1" : "0");
    /// <summary>Sets a two-number field.</summary>
    public void Set(string field, Vector2 value) => SetText(field, $"{Number(value.X)} {Number(value.Y)}");
    /// <summary>Sets a vector field.</summary>
    public void Set(string field, Vector3 value) => SetText(field, $"{Number(value.X)} {Number(value.Y)} {Number(value.Z)}");
    /// <summary>Sets a four-number field.</summary>
    public void Set(string field, Vector4 value) =>
        SetText(field, $"{Number(value.X)} {Number(value.Y)} {Number(value.Z)} {Number(value.W)}");
    /// <summary>Sets a rotation field.</summary>
    public void Set(string field, Quaternion value) =>
        SetText(field, $"{Number(value.X)} {Number(value.Y)} {Number(value.Z)} {Number(value.W)}");
    /// <summary>Sets a colour field.</summary>
    public void Set(string field, Color value) =>
        SetText(field, $"{Number(value.R)} {Number(value.G)} {Number(value.B)} {Number(value.A)}");
    /// <summary>Sets a choice field by its member's name.</summary>
    public void Set<TEnum>(string field, TEnum value) where TEnum : struct, Enum => SetText(field, value.ToString());

    /// <summary>Sets a text or asset-path field.</summary>
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

    /// <summary>Reads a number field (0 when it cannot be read).</summary>
    public float GetFloat(string field)
    {
        Span<float> v = stackalloc float[1];
        return Numbers(field, v) >= 1 ? v[0] : 0f;
    }
    /// <summary>Reads a whole-number field.</summary>
    public int GetInt(string field)
    {
        Span<byte> buffer = stackalloc byte[256];
        ReadOnlySpan<byte> text = FieldUtf8(field, ref buffer);
        return int.TryParse(NextToken(ref text), NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) ? v : 0;
    }
    /// <summary>Reads a tick-box field.</summary>
    public bool GetBool(string field)
    {
        Span<byte> buffer = stackalloc byte[256];
        ReadOnlySpan<byte> text = FieldUtf8(field, ref buffer);
        return NextToken(ref text) is [(byte)'1'];
    }
    /// <summary>Reads a two-number field.</summary>
    public Vector2 GetVector2(string field)
    {
        Span<float> v = stackalloc float[2];
        return Numbers(field, v) == 2 ? new Vector2(v[0], v[1]) : default;
    }
    /// <summary>Reads a four-number field.</summary>
    public Vector4 GetVector4(string field)
    {
        Span<float> v = stackalloc float[4];
        return Numbers(field, v) == 4 ? new Vector4(v[0], v[1], v[2], v[3]) : default;
    }
    /// <summary>Reads a vector field.</summary>
    public Vector3 GetVector3(string field)
    {
        Span<float> v = stackalloc float[3];
        return Numbers(field, v) == 3 ? new Vector3(v[0], v[1], v[2]) : default;
    }
    /// <summary>Reads a colour field.</summary>
    public Color GetColor(string field)
    {
        Span<float> v = stackalloc float[4];
        return Numbers(field, v) == 4 ? new Color(v[0], v[1], v[2], v[3]) : default;
    }

    /// <summary>The field's text as UTF-8 in buffer (grown when it does not fit); empty when it is missing.</summary>
    private ReadOnlySpan<byte> FieldUtf8(string field, ref Span<byte> buffer)
    {
        int length = CSharpNativeComponents.CopyField(GameObject.SceneId, GameObject.Id, TypeName, field, buffer);
        if (length < 0)
            return default;
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Clamp(CSharpNativeComponents.CopyField(GameObject.SceneId, GameObject.Id, TypeName, field, buffer), 0, length);
        }
        return buffer[..length];
    }

    private static ReadOnlySpan<byte> NextToken(ref ReadOnlySpan<byte> text)
    {
        text = text.TrimStart((byte)' ');
        int end = text.IndexOf((byte)' ');
        ReadOnlySpan<byte> token = end < 0 ? text : text[..end];
        text = end < 0 ? default : text[(end + 1)..];
        return token;
    }

    /// <summary>Reads up to values.Length space-separated numbers without allocating; returns how many there were.</summary>
    private int Numbers(string field, Span<float> values)
    {
        Span<byte> buffer = stackalloc byte[256];
        ReadOnlySpan<byte> text = FieldUtf8(field, ref buffer);
        int count = 0;
        while (count < values.Length)
        {
            ReadOnlySpan<byte> token = NextToken(ref text);
            if (token.IsEmpty)
                break;
            values[count++] = float.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out float value) ? value : 0f;
        }
        return count;
    }
    /// <summary>Reads a choice field as the enum member of that name (default when there is none).</summary>
    public TEnum GetEnum<TEnum>(string field) where TEnum : struct, Enum =>
        Tokens(field) is [var x, ..] && Enum.TryParse(x, out TEnum v) ? v : default;

    /// <summary>Reads a text or asset-path field (empty when it cannot be read).</summary>
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
    /// <summary>The engine's component type name ("Tallow.Light").</summary>
    public string TypeName { get; } = typeName;
}

/// <summary>Built-in component handles that <see cref="GameObject.AddComponent{T}"/> can add, by native type name.</summary>
internal static partial class NativeComponentTypes
{
    static NativeComponentTypes() => AddGenerated();

    /// <summary>The generated handles (NativeComponents.Generated.cs).</summary>
    static partial void AddGenerated();

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
        [typeof(VoxelTerrain)] = ("Tallow.VoxelTerrain", o => new VoxelTerrain(o)),
        [typeof(CharacterMotor)] = ("Tallow.CharacterMotor", o => new CharacterMotor(o)),
        [typeof(AudioSource)] = ("Tallow.AudioSource", o => new AudioSource(o)),
        [typeof(SoftBody)] = ("Tallow.SoftBody", o => new SoftBody(o)),
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

/// <summary>
/// What <see cref="GameObject.TryGetComponent{T}"/> works out once per type: whether it is a script, and for a
/// built-in handle that is just its GameObject (every generated one), a way to make it without boxing.
/// </summary>
/// <remarks>T is an engine handle (or a game script) defined in Tallow.API, which the export ships whole: the
/// field read below only tells whether the handle is its GameObject, and no member of it is trimmed.</remarks>
[UnconditionalSuppressMessage("AOT", "IL2090", Justification =
    "T is an engine handle or script from Tallow.API, which ships whole; the check reads only its one GameObject field.")]
internal static class ComponentLookup<T> where T : IComponent
{
    public static readonly bool IsScript = typeof(Script).IsAssignableFrom(typeof(T));

    private static readonly bool HandleIsGameObject = typeof(T).IsValueType
        && Unsafe.SizeOf<T>() == Unsafe.SizeOf<GameObject>()
        && typeof(T).GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic) is [{ } field]
        && field.FieldType == typeof(GameObject);

    public static T Make(GameObject gameObject, Func<GameObject, IComponent> make)
    {
        if (HandleIsGameObject)
            return Unsafe.As<GameObject, T>(ref gameObject);
        return (T)make(gameObject);
    }
}

/// <summary>What a light shines like: everywhere one way (the sun), out from a point, or in a cone.</summary>
public enum LightType { Directional, Point, Spot }

/// <summary>A light: its type, color, intensity and range.</summary>
[NativeComponent("Tallow.Light")]
public readonly partial record struct Light(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.Light");
    /// <summary>Whether the object still has a Light.</summary>
    public bool IsValid => Data.IsValid;
    /// <summary>Directional, Point or Spot.</summary>
    public LightType Type { get => Data.GetEnum<LightType>("type"); set => Data.Set("type", value); }
    /// <summary>The light's colour.</summary>
    public Color Color { get => Data.GetColor("color"); set => Data.Set("color", value); }
    /// <summary>How bright it is (1 is normal).</summary>
    public float Intensity { get => Data.GetFloat("intensity"); set => Data.Set("intensity", value); }
    /// <summary>How far a point or spot light reaches, in metres.</summary>
    public float Range { get => Data.GetFloat("range"); set => Data.Set("range", value); }
    /// <summary>A spot light's cone, in degrees.</summary>
    public float SpotAngle { get => Data.GetFloat("spotAngle"); set => Data.Set("spotAngle", value); }
    /// <summary>Whether it casts shadows.</summary>
    public bool CastShadows { get => Data.GetBool("castShadows"); set => Data.Set("castShadows", value); }
}

/// <summary>Draws a mesh ("builtin:cube", "builtin:sphere_smooth" or a model path) with a simple material.</summary>
[NativeComponent("Tallow.MeshRenderer")]
public readonly partial record struct MeshRenderer(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.MeshRenderer");
    /// <summary>Whether the object still has a Mesh Renderer.</summary>
    public bool IsValid => Data.IsValid;
    /// <summary>The mesh drawn: an asset path or a built-in one ("builtin:cube").</summary>
    public string Mesh { get => Data.GetString("mesh"); set => Data.Set("mesh", value); }
    /// <summary>The surface colour (multiplied with its texture).</summary>
    public Color Color { get => Data.GetColor("color"); set => Data.Set("color", value); }
    /// <summary>How metallic the surface is, 0 to 1.</summary>
    public float Metallic { get => Data.GetFloat("metallic"); set => Data.Set("metallic", value); }
    /// <summary>How rough it is, 0 (mirror) to 1 (matte).</summary>
    public float Roughness { get => Data.GetFloat("roughness"); set => Data.Set("roughness", value); }
    /// <summary>Light the surface gives off by itself.</summary>
    public Color Emissive { get => Data.GetColor("emissive"); set => Data.Set("emissive", value); }
    /// <summary>How strong the emissive colour is.</summary>
    public float EmissiveIntensity { get => Data.GetFloat("emissiveIntensity"); set => Data.Set("emissiveIntensity", value); }
    /// <summary>One normal per face: hard, faceted edges.</summary>
    public bool FlatShading { get => Data.GetBool("flatShading"); set => Data.Set("flatShading", value); }
    /// <summary>Drawn in its own colour, with no lighting.</summary>
    public bool Unlit { get => Data.GetBool("unlit"); set => Data.Set("unlit", value); }
    /// <summary>Whether it casts shadows.</summary>
    public bool CastShadows { get => Data.GetBool("castShadows"); set => Data.Set("castShadows", value); }
    /// <summary>Whether a mesh's back faces are hidden (off for thin, two-sided things such as leaves).</summary>
    public bool BackFaceCulling { get => Data.GetBool("backFaceCulling"); set => Data.Set("backFaceCulling", value); }
    /// <summary>An image drawn on the mesh when it has no material ("" for none).</summary>
    public string Texture { get => Data.GetString("texture"); set => Data.Set("texture", value); }

    /// <summary>
    /// The material (a .tmat path, "" for none). Setting it switches this object's material; in a network session,
    /// set on the server or the owner's machine, every machine follows.
    /// </summary>
    public string Material
    {
        get => Data.GetString("material");
        set
        {
            if (!CSharpComponentActions.RendererSetMaterial(GameObject.SceneId, GameObject.Id, value ?? ""))
                throw new InvalidOperationException($"{GameObject} has no Mesh Renderer.");
        }
    }

    /// <summary>
    /// The material this object names, shared with every other object that names it: changing it changes them all.
    /// Null with no material set.
    /// </summary>
    public Tallow.Material? SharedMaterial
    {
        get
        {
            var path = Data.GetString("material");
            return string.IsNullOrEmpty(path) ? null : Tallow.Material.Load(path);
        }
    }

    /// <summary>
    /// Sets a property of this object's own copy of its material (made the first time, so objects sharing the
    /// material are not changed): a custom shader property by name, or "color", "emissive", "metallic",
    /// "roughness", "emissiveIntensity", "cutoff", "tiling" or "offset". Networked like <see cref="Material"/>.
    /// Nothing changes while it has no material (set <see cref="Color"/> and the other fields instead).
    /// </summary>
    public void SetMaterialValue(string name, Vector4 value)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        if (!CSharpComponentActions.RendererMaterialValue(GameObject.SceneId, GameObject.Id, name, value))
            throw new InvalidOperationException($"{GameObject} has no Mesh Renderer.");
    }

    /// <summary>A number of this object's own material (see <see cref="SetMaterialValue"/>).</summary>
    public void SetMaterialFloat(string name, float value) => SetMaterialValue(name, new Vector4(value, 0, 0, 0));

    /// <summary>A colour of this object's own material (see <see cref="SetMaterialValue"/>).</summary>
    public void SetMaterialColor(string name, Color value) => SetMaterialValue(name, new Vector4(value.R, value.G, value.B, value.A));

    /// <summary>The box the drawn mesh fills in the world; false when there is nothing to draw.</summary>
    public bool TryGetWorldBounds(out Vector3 min, out Vector3 max)
    {
        Span<float> values = stackalloc float[6];
        bool ok = CSharpComponentActions.RendererBounds(GameObject.SceneId, GameObject.Id, values);
        min = ok ? new Vector3(values[0], values[1], values[2]) : default;
        max = ok ? new Vector3(values[3], values[4], values[5]) : default;
        return ok;
    }

    /// <summary>Whether it was drawn this frame or the last, by any camera or shadow (false in a headless run).</summary>
    public bool IsVisible => CSharpComponentActions.RendererFramesSinceDrawn(GameObject.SceneId, GameObject.Id) == 0;

    /// <summary>
    /// Draws a mesh built in code in place of the one named by <see cref="Mesh"/>: a position per vertex, three
    /// indices per triangle (clockwise seen from the front), and optionally a normal (left out: smooth normals are
    /// worked out) and a texture coordinate per vertex. Call it again to change the shape (the same mesh is reused);
    /// <see cref="ClearMesh"/> goes back to the named one. It is drawn on this machine only: build it on every
    /// machine in multiplayer. Colliders keep their own shapes.
    /// </summary>
    public void SetMesh(ReadOnlySpan<Vector3> positions, ReadOnlySpan<int> triangles,
        ReadOnlySpan<Vector3> normals = default, ReadOnlySpan<Vector2> uvs = default)
    {
        if (!normals.IsEmpty && normals.Length != positions.Length)
            throw new ArgumentException("Give one normal per position, or none.", nameof(normals));
        if (!uvs.IsEmpty && uvs.Length != positions.Length)
            throw new ArgumentException("Give one texture coordinate per position, or none.", nameof(uvs));
        if (triangles.Length % 3 != 0)
            throw new ArgumentException("Give three indices per triangle.", nameof(triangles));
        float[] index = new float[triangles.Length];
        for (int i = 0; i < triangles.Length; i++)
            index[i] = triangles[i];
        int result = CSharpMeshes.SetMesh(GameObject.SceneId, GameObject.Id,
            System.Runtime.InteropServices.MemoryMarshal.Cast<Vector3, float>(positions).ToArray(),
            System.Runtime.InteropServices.MemoryMarshal.Cast<Vector3, float>(normals).ToArray(),
            System.Runtime.InteropServices.MemoryMarshal.Cast<Vector2, float>(uvs).ToArray(), index);
        if (result == -1)
            throw new InvalidOperationException($"'{GameObject.Name}' has no Mesh Renderer.");
        if (result == -3)
            throw new ArgumentOutOfRangeException(nameof(triangles), "Every index must be one of the positions.");
        if (result < 0)
            throw new ArgumentException("The positions, normals and texture coordinates do not fit together.");
    }

    /// <summary>Goes back to the mesh named by <see cref="Mesh"/> after <see cref="SetMesh"/>; false when none was set.</summary>
    public bool ClearMesh() => CSharpMeshes.ClearMesh(GameObject.SceneId, GameObject.Id);
}

/// <summary>A sphere-shaped collider.</summary>
[NativeComponent("Tallow.SphereCollider")]
public readonly partial record struct SphereCollider(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.SphereCollider");
    /// <summary>Whether the object still has a Sphere Collider.</summary>
    public bool IsValid => Data.IsValid;
    /// <summary>The sphere's radius, in metres (before the object's scale).</summary>
    public float Radius { get => Data.GetFloat("radius"); set => Data.Set("radius", value); }
    /// <summary>Where the sphere is, relative to the object.</summary>
    public Vector3 Center { get => Data.GetVector3("center"); set => Data.Set("center", value); }
    /// <summary>What it is made of ("Metal", "Wood"), reported by hits (<see cref="PhysicsHit.Surface"/>).</summary>
    public string Surface { get => Data.GetString("surface"); set => Data.Set("surface", value); }
}

/// <summary>A box-shaped collider.</summary>
[NativeComponent("Tallow.BoxCollider")]
public readonly partial record struct BoxCollider(GameObject GameObject) : IComponent
{
    private NativeComponent Data => new(GameObject, "Tallow.BoxCollider");
    /// <summary>Whether the object still has a Box Collider.</summary>
    public bool IsValid => Data.IsValid;
    /// <summary>The box's full size, in metres (before the object's scale). A new Box Collider starts fitted to the
    /// meshes its object and its children draw (no mesh: 1 on each axis).</summary>
    public Vector3 Size { get => Data.GetVector3("size"); set => Data.Set("size", value); }
    /// <summary>Where the box is, relative to the object. A new Box Collider starts at the middle of those meshes.</summary>
    public Vector3 Center { get => Data.GetVector3("center"); set => Data.Set("center", value); }
    /// <summary>What it is made of ("Metal", "Wood"), reported by hits (<see cref="PhysicsHit.Surface"/>).</summary>
    public string Surface { get => Data.GetString("surface"); set => Data.Set("surface", value); }
}

/// <summary>Walks its object along the navigation mesh to a destination.</summary>
[NativeComponent("Tallow.NavigationAgent")]
public readonly partial record struct NavigationAgent(GameObject GameObject) : IComponent
{
    /// <summary>Whether the object still has a Navigation Agent.</summary>
    public bool IsValid => CSharpNavigation.HasAgent(GameObject.SceneId, GameObject.Id);
    /// <summary>Finds a path to point and walks it at speed metres a second, stopping within stoppingDistance.</summary>
    public void SetDestination(Vector3 point, float speed, float stoppingDistance = 0.2f) =>
        CSharpNavigation.SetDestination(GameObject.SceneId, GameObject.Id, point, speed, stoppingDistance);
    /// <summary>Stops where it is and forgets its path.</summary>
    public void StopMovement() => CSharpNavigation.StopMovement(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether its path is still being worked out.</summary>
    public bool PathPending => CSharpNavigation.PathPending(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether no path to the destination was found.</summary>
    public bool PathFailed => CSharpNavigation.PathFailed(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether it reached its destination (within the stopping distance).</summary>
    public bool HasArrived => CSharpNavigation.HasArrived(GameObject.SceneId, GameObject.Id);
    /// <summary>Whether it is going over a navigation link (a jump, a ladder) just now.</summary>
    public bool IsCrossingLink => CSharpNavigation.IsCrossingLink(GameObject.SceneId, GameObject.Id);
    /// <summary>Corners on the current path (0 with none).</summary>
    public int PathCornerCount => CSharpNavigation.PathCount(GameObject.SceneId, GameObject.Id);
    /// <summary>How far it still has to go along its path, in metres.</summary>
    public float RemainingDistance => CSharpNavigation.RemainingDistance(GameObject.SceneId, GameObject.Id);
}

/// <summary>Sounds the AI hears (gunshots, footsteps, a thrown bottle): behaviour trees' Heard Noise nodes pick them up.</summary>
public static class AINoise
{
    /// <summary>A noise at a point, heard within <paramref name="radius"/> metres. Its source (who made it) is
    /// remembered by those who hear it, and does not hear itself.</summary>
    public static void Make(Scene scene, Vector3 position, float radius, GameObject? source = null) =>
        CSharpNavigation.MakeNoise(scene.SessionId, position, radius, source?.Id ?? 0);

    /// <summary>Drops noises older than some seconds (all of them with 0, for a new level).</summary>
    public static void Forget(float olderThan = 0) => CSharpNavigation.ForgetNoises(olderThan);
}

/// <summary>A baked navigation mesh agents walk on, with queries for choosing where to go.</summary>
[NativeComponent("Tallow.NavigationSurface")]
public readonly partial record struct NavigationSurface(GameObject GameObject) : IComponent
{
    /// <summary>Whether the object still has a Navigation Surface.</summary>
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
    /// <summary>The body's mass, in kilograms.</summary>
    public float Mass { get => Data.GetFloat("mass"); set => Data.Set("mass", value); }
    /// <summary>Whether gravity pulls it.</summary>
    public bool UseGravity { get => Data.GetBool("useGravity"); set => Data.Set("useGravity", value); }
    /// <summary>Moved only by its Transform (scripts, animation), not by forces; it still pushes other bodies.</summary>
    public bool IsKinematic { get => Data.GetBool("isKinematic"); set => Data.Set("isKinematic", value); }
    /// <summary>How much it grips what it slides on, 0 to 1.</summary>
    public float Friction { get => Data.GetFloat("friction"); set => Data.Set("friction", value); }
    /// <summary>How much it bounces, 0 (none) to 1.</summary>
    public float Bounciness { get => Data.GetFloat("bounciness"); set => Data.Set("bounciness", value); }
    /// <summary>Checked along its path each step, so a fast small body does not pass through thin things.</summary>
    public bool ContinuousCollision { get => Data.GetBool("continuousCollision"); set => Data.Set("continuousCollision", value); }
    /// <summary>How quickly it slows down by itself, moving (LinearDamping) and turning (AngularDamping).</summary>
    public float LinearDamping { get => Data.GetFloat("linearDamping"); set => Data.Set("linearDamping", value); }
    /// <inheritdoc cref="LinearDamping"/>
    public float AngularDamping { get => Data.GetFloat("angularDamping"); set => Data.Set("angularDamping", value); }
    /// <summary>Keeps the body from turning (characters that should stay upright).</summary>
    public bool FreezeRotation { get => Data.GetBool("freezeRotation"); set => Data.Set("freezeRotation", value); }
    /// <summary>Lets the body stop being simulated while it lies still, until something touches it.</summary>
    public bool AllowSleeping { get => Data.GetBool("allowSleeping"); set => Data.Set("allowSleeping", value); }
    /// <summary>Rests on scenery, but nothing that moves is stopped by it, and queries ignore it (corpses, rubble).</summary>
    public bool Debris { get => Data.GetBool("debris"); set => Data.Set("debris", value); }
    // Like the Inspector's fields (and Mass, Friction...), these are read when the body is made: set them in the
    // frame the Rigidbody is added, before it plays.
}

public readonly partial record struct CharacterController
{
    private NativeComponent Data => new(GameObject, "Tallow.CharacterController");
    /// <summary>The capsule's radius, in metres.</summary>
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

public readonly partial record struct Camera
{
    /// <summary>The camera's transform (where it is and which way it faces).</summary>
    public Transform Transform => GameObject.Transform;
}

public readonly partial record struct SpawnPoint
{
    /// <summary>The spawn point's transform: its position and facing.</summary>
    public Transform Transform => GameObject.Transform;
}

public readonly partial record struct Light
{
    /// <summary>The light's transform.</summary>
    public Transform Transform => GameObject.Transform;
}

public readonly partial record struct MeshRenderer
{
    /// <summary>The mesh's transform.</summary>
    public Transform Transform => GameObject.Transform;
}
