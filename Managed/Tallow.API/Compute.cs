using System.Numerics;

namespace Tallow;

/// <summary>
/// Compute shaders (.tcompute files) run from a script, without a Compute Effect component: make a
/// <see cref="ComputeTexture"/> and a <see cref="ComputeShader"/>, run the shader over the texture when you choose, and
/// show the texture on Mesh Renderers. Everything is local to this machine (compute is visual).
/// </summary>
public static class Compute
{
    /// <summary>False on a dedicated server and on graphics cards without compute shaders: textures are then
    /// empty and running does nothing (returns false).</summary>
    public static bool Supported => CSharpCompute.Supported();
}

/// <summary>
/// A texture a compute shader draws into, step after step (each step reads the one before as <c>previous</c>).
/// Dispose it when done; any left are freed when the game stops.
/// </summary>
public sealed class ComputeTexture : IDisposable
{
    internal int Id { get; private set; }

    /// <summary>A texture of this size (1 to 4096 each way). High precision keeps 16-bit float values instead of
    /// 8-bit colours (for simulations with numbers outside 0 to 1).</summary>
    public ComputeTexture(int width, int height, bool highPrecision = false)
    {
        Width = Math.Clamp(width, 1, 4096);
        Height = Math.Clamp(height, 1, 4096);
        HighPrecision = highPrecision;
        Id = CSharpCompute.CreateTexture(Width, Height, highPrecision);
    }

    /// <summary>Width in pixels.</summary>
    public int Width { get; }
    /// <summary>Height in pixels.</summary>
    public int Height { get; }
    /// <summary>Whether it keeps 16-bit float values.</summary>
    public bool HighPrecision { get; }
    /// <summary>Whether there is a texture on the graphics card (false where compute is not supported, or after Dispose).</summary>
    public bool IsValid => Id != 0;

    /// <summary>Draws this texture on an object's Mesh Renderer in place of its own, kept up to date as the shader runs.
    /// A renderer shows one compute texture at a time.</summary>
    public void ShowOn(MeshRenderer renderer)
    {
        if (!CSharpCompute.ShowTexture(Id, renderer.GameObject.SceneId, renderer.GameObject.Id, true))
            throw new InvalidOperationException($"{renderer.GameObject} has no Mesh Renderer.");
    }

    /// <summary>Puts a Mesh Renderer back to drawing its own texture.</summary>
    public static void StopShowing(MeshRenderer renderer) =>
        CSharpCompute.ShowTexture(0, renderer.GameObject.SceneId, renderer.GameObject.Id, false);

    /// <summary>Frees the texture (renderers showing it go back to their own).</summary>
    public void Dispose()
    {
        if (Id != 0)
            CSharpCompute.ReleaseTexture(Id);
        Id = 0;
    }
}

/// <summary>
/// A compute shader with its property values, to run over <see cref="ComputeTexture"/>s:
/// <code>
/// var ripple = new ComputeShader("Effects/ripple.tcompute");
/// var water = new ComputeTexture(256, 256, ripple.HighPrecision);
/// water.ShowOn(GetComponent&lt;MeshRenderer&gt;());
/// ripple.SetFloat("speed", 3);
/// ripple.Run(water);          // one step; call it each frame, or when you choose
/// </code>
/// </summary>
public sealed class ComputeShader : IDisposable
{
    int id;

    /// <summary>The compute shader at a project path (a .tcompute file, or the one a compute graph writes).</summary>
    /// <exception cref="ArgumentException">There is no such file, or it is not a compute shader.</exception>
    public ComputeShader(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        id = CSharpCompute.CreateShader(path);
        if (id == -1)
            throw new ArgumentException($"No shader at '{path}'.", nameof(path));
        if (id == -2)
            throw new ArgumentException($"'{path}' is not a compute shader.", nameof(path));
        Path = path;
    }

    /// <summary>The project path it was made from.</summary>
    public string Path { get; }

    /// <summary>Whether the shader asks for high-precision textures (<c>precision high</c>): make its textures with that.</summary>
    public bool HighPrecision => CSharpCompute.ShaderHighPrecision(id);

    /// <summary>Sets a property for the next runs. False when the shader declares no such property.</summary>
    public bool SetVector(string name, Vector4 value) => CSharpCompute.SetShaderValue(Live(), name ?? "", value);
    /// <summary>Sets a number property for the next runs.</summary>
    public bool SetFloat(string name, float value) => SetVector(name, new Vector4(value, 0, 0, 0));
    /// <summary>Sets a colour property for the next runs.</summary>
    public bool SetColor(string name, Color value) => SetVector(name, new Vector4(value.R, value.G, value.B, value.A));

    /// <summary>Runs the shader over the texture, <paramref name="steps"/> times (1 to 64). False where compute is
    /// not supported or the shader is not compiled.</summary>
    public bool Run(ComputeTexture target, int steps = 1)
    {
        ArgumentNullException.ThrowIfNull(target);
        return target.IsValid && CSharpCompute.Run(Live(), target.Id, steps);
    }

    int Live() => id > 0 ? id : throw new ObjectDisposedException(nameof(ComputeShader));

    /// <summary>Frees it.</summary>
    public void Dispose()
    {
        if (id > 0)
            CSharpCompute.ReleaseShader(id);
        id = 0;
    }
}
