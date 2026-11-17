namespace Tallow;

/// <summary>What a texture holds, for its smaller mip levels (how far-off and slanted surfaces are drawn).</summary>
public enum TextureKind
{
    /// <summary>A colour picture (albedo, emissive, interface): averaged in linear light.</summary>
    Color,
    /// <summary>Numbers that are not a colour (metal / roughness, occlusion, masks): averaged as stored.</summary>
    Data,
    /// <summary>A normal map: the directions averaged and made unit length again.</summary>
    Normal,
}

/// <summary>
/// A texture made in code: set its pixels, <see cref="Apply"/> them, and name it in a material like an image file
/// (<see cref="Name"/> goes where a texture path goes):
/// <code>
/// var minimap = new Texture("Generated/minimap", 128, 128);
/// minimap.Fill(Color.Black);
/// minimap.SetPixel(64, 64, Color.Red);
/// minimap.Apply();
/// GetComponent&lt;MeshRenderer&gt;().Texture = minimap.Name;   // or a material's Texture
/// </code>
/// Every material naming it draws the new pixels from the next frame after each Apply. Textures are local to this
/// machine (a dedicated server has no graphics card: Apply does nothing there, but the pixels are kept). Dispose it
/// when done; any left are released when the game stops.
/// </summary>
public sealed class Texture : IDisposable
{
    private readonly byte[] pixels;
    private bool disposed;

    /// <summary>A texture of this size (1 to 8192 each way), transparent black, under a name of its own (use one no
    /// image file has, such as "Generated/minimap").</summary>
    public Texture(string name, int width, int height, TextureKind kind = TextureKind.Color)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        ArgumentOutOfRangeException.ThrowIfLessThan(width, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(height, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(width, 8192);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(height, 8192);
        Name = name;
        Width = width;
        Height = height;
        Kind = kind;
        pixels = new byte[width * height * 4];
    }

    /// <summary>A texture with the pixels of an image file in the project (PNG, JPEG, TGA...), to change in code; null
    /// when the file cannot be read. Its name is the file's with "#copy" after it, so the file itself is untouched.</summary>
    public static Texture? Load(string path, TextureKind? kind = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        int size = CSharpTextures.ImageSize(path);
        if (size <= 0 || size / 65536 < 1 || size % 65536 < 1)
            return null;
        var texture = new Texture(path + "#copy", size / 65536, size % 65536,
            kind ?? (TextureKind)CSharpTextures.KindOf(path));
        return CSharpTextures.ReadImage(path, texture.pixels) == texture.pixels.Length ? texture : null;
    }

    /// <summary>The name materials use for it, as they use an image file's path.</summary>
    public string Name { get; }
    /// <summary>Width in pixels.</summary>
    public int Width { get; }
    /// <summary>Height in pixels.</summary>
    public int Height { get; }
    /// <summary>What it holds.</summary>
    public TextureKind Kind { get; }

    /// <summary>The pixels, 4 bytes each (red, green, blue, alpha), row after row from the top. Change them, then
    /// <see cref="Apply"/>.</summary>
    public Span<byte> Pixels => Live().pixels;

    /// <summary>The colour of a pixel (x from the left, y from the top).</summary>
    public Color GetPixel(int x, int y)
    {
        int at = Index(x, y);
        byte[] data = Live().pixels;
        return new Color(data[at] / 255f, data[at + 1] / 255f, data[at + 2] / 255f, data[at + 3] / 255f);
    }

    /// <summary>Sets a pixel (x from the left, y from the top); shown after <see cref="Apply"/>.</summary>
    public void SetPixel(int x, int y, Color color)
    {
        int at = Index(x, y);
        Write(Live().pixels, at, color);
    }

    /// <summary>Sets every pixel.</summary>
    public void Fill(Color color)
    {
        byte[] data = Live().pixels;
        for (int at = 0; at < data.Length; at += 4)
            Write(data, at, color);
    }

    /// <summary>Sends the pixels to the graphics card (with their mip levels). False where there is none (a dedicated
    /// server or a headless run).</summary>
    public bool Apply() => CSharpTextures.Upload(Name, Width, Height, (int)Kind, Live().pixels);

    /// <summary>Says what an image file holds before it is loaded (a mask or a data texture whose name does not tell).</summary>
    public static void Hint(string path, TextureKind kind) => CSharpTextures.Hint(path ?? "", (int)kind);

    /// <summary>What an image file holds, as worked out from its name ("rock_normal.png": Normal) and hints.</summary>
    public static TextureKind KindOf(string path) => (TextureKind)CSharpTextures.KindOf(path ?? "");

    /// <summary>Releases it on the graphics card; materials naming it draw white.</summary>
    public void Dispose()
    {
        if (disposed)
            return;
        disposed = true;
        CSharpTextures.Remove(Name);
    }

    private int Index(int x, int y)
    {
        if ((uint)x >= (uint)Width || (uint)y >= (uint)Height)
            throw new ArgumentOutOfRangeException(nameof(x), $"({x}, {y}) is outside the {Width}x{Height} texture.");
        return (y * Width + x) * 4;
    }

    private Texture Live() => disposed ? throw new ObjectDisposedException(Name) : this;

    private static void Write(byte[] data, int at, Color color)
    {
        data[at] = ToByte(color.R);
        data[at + 1] = ToByte(color.G);
        data[at + 2] = ToByte(color.B);
        data[at + 3] = ToByte(color.A);
    }

    private static byte ToByte(float value) => (byte)Math.Clamp((int)MathF.Round(value * 255f), 0, 255);
}
