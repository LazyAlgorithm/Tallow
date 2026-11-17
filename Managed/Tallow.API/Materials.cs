using System.Numerics;

namespace Tallow;

/// <summary>How a material is drawn.</summary>
public enum MaterialBlend
{
    /// <summary>Solid.</summary>
    Opaque,
    /// <summary>Solid, with holes where the texture's alpha is below <see cref="Material.Cutoff"/>: leaves, fences, grates.</summary>
    Cutout,
    /// <summary>See-through: blended over what is behind it, and casts no shadow.</summary>
    Transparent
}

/// <summary>
/// A material (.tmat) shared by every object that uses it: changing it changes all of them at once. To change one
/// object only, use <see cref="MeshRenderer.SetMaterialValue"/>, which works on that object's own copy.
/// Changes are made on this machine only (they are not sent to other players) and last until the game stops; the
/// file is not changed.
/// </summary>
public sealed class Material : IEquatable<Material>
{
    readonly bool made;

    Material(string path, bool made)
    {
        Path = path;
        this.made = made;
    }

    /// <summary>The project path that names it, such as "Materials/Rock.tmat" (for one made in code, the name it was given).</summary>
    public string Path { get; }

    /// <summary>The material file at a project path, or null when there is none.</summary>
    public static Material? Load(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        return CSharpMaterials.Exists(path, false) ? new Material(path, false) : null;
    }

    /// <summary>
    /// A material made in code, under a name of your choosing (give it to a renderer with
    /// <see cref="MeshRenderer.Material"/>). It starts as a copy of <paramref name="copyOf"/> when given, else blank;
    /// a material of that name that exists already is returned as it is. Made-in-code materials no renderer uses are
    /// freed after a while once there are many, so give them to renderers by name rather than keeping only the object.
    /// </summary>
    public static Material Create(string name, string? copyOf = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        if (!CSharpMaterials.Create(name, copyOf ?? ""))
            throw new ArgumentException($"No material at '{copyOf}'.", nameof(copyOf));
        return new Material(name, true);
    }

    /// <summary>The colour the surface is, multiplied by the texture.</summary>
    public Color Color { get => ToColor(Get("color")); set => Set("color", FromColor(value)); }
    /// <summary>Light the surface gives off itself (strength from <see cref="EmissiveIntensity"/>).</summary>
    public Color Emissive { get => ToColor(Get("emissive")); set => Set("emissive", FromColor(value)); }
    /// <summary>How strong the emissive light is.</summary>
    public float EmissiveIntensity { get => Get("emissiveIntensity").X; set => Set("emissiveIntensity", new Vector4(value, 0, 0, 0)); }
    /// <summary>How metal-like the surface is, 0 to 1.</summary>
    public float Metallic { get => Get("metallic").X; set => Set("metallic", new Vector4(value, 0, 0, 0)); }
    /// <summary>How rough the surface is: 0 is a mirror, 1 fully matt.</summary>
    public float Roughness { get => Get("roughness").X; set => Set("roughness", new Vector4(value, 0, 0, 0)); }
    /// <summary>Below this texture alpha a <see cref="MaterialBlend.Cutout"/> material has holes.</summary>
    public float Cutoff { get => Get("cutoff").X; set => Set("cutoff", new Vector4(value, 0, 0, 0)); }
    /// <summary>How many times the textures repeat across the surface.</summary>
    public Vector2 Tiling { get { var v = Get("tiling"); return new Vector2(v.X, v.Y); } set => Set("tiling", new Vector4(value, 0, 0)); }
    /// <summary>How far the textures are moved across the surface.</summary>
    public Vector2 Offset { get { var v = Get("offset"); return new Vector2(v.X, v.Y); } set => Set("offset", new Vector4(value, 0, 0)); }
    /// <summary>How strong the normal map's bumps are.</summary>
    public float NormalStrength { get => Get("normalStrength").X; set => Set("normalStrength", new Vector4(value, 0, 0, 0)); }
    /// <summary>How much the occlusion map darkens, 0 to 1.</summary>
    public float OcclusionStrength { get => Get("occlusionStrength").X; set => Set("occlusionStrength", new Vector4(value, 0, 0, 0)); }
    /// <summary>How far the surface has dissolved away, 0 to 1.</summary>
    public float Dissolve { get => Get("dissolve").X; set => Set("dissolve", new Vector4(value, 0, 0, 0)); }
    /// <summary>Lights each triangle evenly, for a faceted look.</summary>
    public bool FlatShading { get => Get("flatShading").X != 0; set => Set("flatShading", new Vector4(value ? 1 : 0, 0, 0, 0)); }
    /// <summary>Draws the colour and texture as they are, with no lighting.</summary>
    public bool Unlit { get => Get("unlit").X != 0; set => Set("unlit", new Vector4(value ? 1 : 0, 0, 0, 0)); }
    /// <summary>Draws both sides of each triangle.</summary>
    public bool DoubleSided { get => Get("doubleSided").X != 0; set => Set("doubleSided", new Vector4(value ? 1 : 0, 0, 0, 0)); }
    /// <summary>Solid, cut out or see-through.</summary>
    public MaterialBlend Blend { get => (MaterialBlend)(int)Get("blend").X; set => Set("blend", new Vector4((int)value, 0, 0, 0)); }

    /// <summary>The custom shader (.tshader path), or "" for the standard one.</summary>
    public string Shader { get => GetText("shader"); set => SetText("shader", value); }
    /// <summary>The main texture (an image path, "" for none).</summary>
    public string Texture { get => GetText("texture"); set => SetText("texture", value); }
    /// <summary>The normal map (an image path, "" for none).</summary>
    public string NormalMap { get => GetText("normalMap"); set => SetText("normalMap", value); }
    /// <summary>The metallic (blue) and roughness (green) map (an image path, "" for none).</summary>
    public string MetallicRoughnessMap { get => GetText("metallicRoughnessMap"); set => SetText("metallicRoughnessMap", value); }
    /// <summary>The ambient occlusion map (an image path, "" for none).</summary>
    public string OcclusionMap { get => GetText("occlusionMap"); set => SetText("occlusionMap", value); }
    /// <summary>The emissive map (an image path, "" for none).</summary>
    public string EmissiveMap { get => GetText("emissiveMap"); set => SetText("emissiveMap", value); }

    /// <summary>Sets a property of the custom shader (a float uses X).</summary>
    public void SetVector(string name, Vector4 value)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        Set(name, value);
    }
    /// <summary>Sets a number property of the custom shader.</summary>
    public void SetFloat(string name, float value) => SetVector(name, new Vector4(value, 0, 0, 0));
    /// <summary>Sets a colour property of the custom shader.</summary>
    public void SetColor(string name, Color value) => SetVector(name, FromColor(value));
    /// <summary>A property of the custom shader: what was set, else the shader's default, else zero.</summary>
    public Vector4 GetVector(string name) => Get(name);
    /// <summary>A number property of the custom shader.</summary>
    public float GetFloat(string name) => Get(name).X;
    /// <summary>A colour property of the custom shader.</summary>
    public Color GetColor(string name) => ToColor(Get(name));
    /// <summary>Sets a texture property of the custom shader to an image in the project.</summary>
    public void SetTexture(string name, string texturePath)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        SetText(name, texturePath);
    }
    /// <summary>The image a texture property of the custom shader names ("" for none).</summary>
    public string GetTexture(string name) => GetText(name);

    void Set(string name, Vector4 value)
    {
        if (!CSharpMaterials.SetValue(Path, made, name, value))
            throw Missing();
    }

    Vector4 Get(string name)
    {
        Span<float> values = stackalloc float[4];
        if (!CSharpMaterials.GetValue(Path, made, name, values))
            throw Missing();
        return new Vector4(values[0], values[1], values[2], values[3]);
    }

    void SetText(string name, string value)
    {
        if (!CSharpMaterials.SetText(Path, made, name, value ?? ""))
            throw Missing();
    }

    string GetText(string name) => NativeText.Read(buffer => CSharpMaterials.GetText(Path, made, name, buffer)) ?? throw Missing();

    InvalidOperationException Missing() => new($"The material '{Path}' is not there any more.");

    static Color ToColor(Vector4 v) => new(v.X, v.Y, v.Z, v.W);
    static Vector4 FromColor(Color c) => new(c.R, c.G, c.B, c.A);

    /// <inheritdoc/>
    public bool Equals(Material? other) => other is not null && other.Path == Path;
    /// <inheritdoc/>
    public override bool Equals(object? obj) => Equals(obj as Material);
    /// <inheritdoc/>
    public override int GetHashCode() => Path.GetHashCode();
    /// <summary>Whether both name the same material.</summary>
    public static bool operator ==(Material? a, Material? b) => a is null ? b is null : a.Equals(b);
    /// <summary>Whether they name different materials.</summary>
    public static bool operator !=(Material? a, Material? b) => !(a == b);
    /// <inheritdoc/>
    public override string ToString() => Path;
}
