using System.Numerics;

namespace Tallow;

/// <summary>A terrain's painted layers (<see cref="TerrainGenerator.Paint"/>): Automatic leaves the colour to the
/// terrain's own rules (grass on flat ground, rock on slopes, snow up high).</summary>
public enum TerrainLayer : byte
{
    Automatic,
    Grass,
    Rock,
    Sand,
    Snow,
    Dirt,
}

/// <summary>
/// What ground looks like before anyone sculpts it: derive from this and give it to a terrain with
/// <see cref="VoxelTerrain.SetGenerator"/> (every chunk nobody has sculpted, in every tile or without end), or bake it
/// into one tile with <see cref="VoxelTerrain.ApplyGenerator"/>.
/// <code>
/// class Islands : TerrainGenerator
/// {
///     public override float Density(float x, float y, float z)
///     {
///         float hill = Noise.Fbm(x * 0.01f, 0, z * 0.01f, seed: 7, octaves: 4) * 30;
///         return hill - y;        // more than zero is solid, less is air
///     }
///     public override bool Paints => true;
///     public override TerrainLayer Paint(float x, float y, float z) => y &lt; 1 ? TerrainLayer.Sand : TerrainLayer.Automatic;
/// }
/// </code>
/// <see cref="Density"/>, <see cref="Paint"/> and <see cref="Fill"/> run on the terrain's worker threads, several
/// at once: read only data that does not change while the terrain is generating, and set it up in
/// <see cref="Begin"/>, which runs on the game thread first. Coordinates are metres in the terrain's own space.
/// </summary>
public abstract class TerrainGenerator
{
    /// <summary>More than zero is solid, less is air; the surface is where it crosses zero, so "height - y" makes
    /// ground up to that height.</summary>
    public abstract float Density(float x, float y, float z);

    /// <summary>True when <see cref="Paint"/> gives layers; false (the default) leaves the colours to the terrain.</summary>
    public virtual bool Paints => false;

    /// <summary>The painted layer at a point.</summary>
    public virtual TerrainLayer Paint(float x, float y, float z) => TerrainLayer.Automatic;

    /// <summary>Called on the game thread before the terrain generates with it, and again when the terrain's settings
    /// change: copy what the worker threads will read.</summary>
    public virtual void Begin() { }

    /// <summary>Makes a whole cube of samples at once. The default calls <see cref="Density"/> (and
    /// <see cref="Paint"/>) for each; override it to share work between samples (a column's height, say).</summary>
    public virtual void Fill(TerrainSamples samples)
    {
        int size = samples.Size, index = 0;
        bool paints = samples.Paint.Length > 0;
        for (int z = 0; z < size; z++)
        {
            for (int y = 0; y < size; y++)
            {
                for (int x = 0; x < size; x++, index++)
                {
                    Vector3 at = samples.Position(x, y, z);
                    samples.Density[index] = Density(at.X, at.Y, at.Z);
                    if (paints)
                        samples.Paint[index] = (byte)Paint(at.X, at.Y, at.Z);
                }
            }
        }
    }
}

/// <summary>
/// A cube of terrain samples to fill (<see cref="TerrainGenerator.Fill"/>): <see cref="Size"/> a side, from
/// <see cref="Origin"/> in steps of <see cref="Step"/> metres, x fastest, then y, then z.
/// </summary>
public readonly ref struct TerrainSamples
{
    internal TerrainSamples(Vector3 origin, float step, int size, Span<float> density, Span<byte> paint)
    {
        Origin = origin;
        Step = step;
        Size = size;
        Density = density;
        Paint = paint;
    }

    /// <summary>The first sample's position.</summary>
    public Vector3 Origin { get; }
    /// <summary>Metres between samples.</summary>
    public float Step { get; }
    /// <summary>Samples a side.</summary>
    public int Size { get; }
    /// <summary>Size³ densities to set (more than zero solid).</summary>
    public Span<float> Density { get; }
    /// <summary>Size³ layers (<see cref="TerrainLayer"/> values) to set when the generator paints; else empty.</summary>
    public Span<byte> Paint { get; }

    /// <summary>The index of sample (x, y, z) in Density and Paint.</summary>
    public int Index(int x, int y, int z) => (z * Size + y) * Size + x;

    /// <summary>Where sample (x, y, z) is.</summary>
    public Vector3 Position(int x, int y, int z) => Origin + new Vector3(x, y, z) * Step;
}

/// <summary>The generators the engine's terrains hold, by handle (the engine calls them from worker threads).</summary>
internal static class TerrainGenerators
{
    private static readonly Dictionary<int, TerrainGenerator> sByHandle = [];
    private static readonly HashSet<int> sReported = [];
    private static int sNext;
    private static readonly object sLock = new();

    internal static int Add(TerrainGenerator generator)
    {
        lock (sLock)
        {
            int handle = ++sNext;
            sByHandle[handle] = generator;
            return handle;
        }
    }

    internal static unsafe int Call(int op, int handle, Vector3 origin, float step, int size, float* points, float* density, byte* paint)
    {
        TerrainGenerator? generator;
        lock (sLock)
        {
            // Op 2: the engine let go of it.
            if (op == 2)
                return sByHandle.Remove(handle) ? 1 : 0;
            sByHandle.TryGetValue(handle, out generator);
        }
        if (generator == null)
            return 0;
        try
        {
            if (op == 1)
            {
                generator.Begin();
                return 1;
            }
            if (op == 3)
            {
                // Scattered points (the meshing's edges where no neighbour is made yet).
                var at = new ReadOnlySpan<Vector3>(points, size);
                for (int i = 0; i < at.Length; i++)
                    density[i] = generator.Density(at[i].X, at[i].Y, at[i].Z);
                return 1;
            }
            int count = size * size * size;
            generator.Fill(new TerrainSamples(origin, step, size, new Span<float>(density, count),
                paint != null ? new Span<byte>(paint, count) : Span<byte>.Empty));
            return 1;
        }
        catch (Exception exception)
        {
            // Once per generator: a broken one would otherwise report for every chunk.
            bool first;
            lock (sLock)
                first = sReported.Add(handle);
            if (first)
                Log.Error($"Terrain generator {generator.GetType().FullName} threw {exception.GetType().Name}: " +
                    $"{exception.Message} (its chunks are left empty)\n{exception.StackTrace}");
            return 0;
        }
    }

    internal static void Release(int handle)
    {
        lock (sLock)
            sByHandle.Remove(handle);
    }

    internal static void Clear()
    {
        lock (sLock)
        {
            sByHandle.Clear();
            sReported.Clear();
        }
    }
}

public readonly partial record struct VoxelTerrain
{
    /// <summary>Shapes every chunk nobody has sculpted with a generator, in every tile (or without end, in Endless
    /// mode), for as long as the game runs; sculpting on top is kept. Null goes back to the terrain's own Generator
    /// field. A hot reload stops it: set it again.</summary>
    public void SetGenerator(TerrainGenerator? generator)
    {
        int handle = generator == null ? 0 : TerrainGenerators.Add(generator);
        if (!CSharpTerrain.SetGenerator(GameObject.SceneId, GameObject.Id, handle, generator?.Paints ?? false))
            throw ActionText.Missing(GameObject, "Voxel Terrain");
    }

    /// <summary>Bakes a generator into one tile (an id from <see cref="TileIds"/>), as if it had been sculpted that
    /// way; the edge it shares with other tiles takes the new ground too. False when there is no such tile.</summary>
    public bool ApplyGenerator(TerrainGenerator generator, int tileId)
    {
        ArgumentNullException.ThrowIfNull(generator);
        int handle = TerrainGenerators.Add(generator);
        try
        {
            return CSharpTerrain.ApplyGenerator(GameObject.SceneId, GameObject.Id, handle, generator.Paints, tileId);
        }
        finally
        {
            TerrainGenerators.Release(handle);
        }
    }

    /// <summary>Makes every chunk nobody has sculpted again (after the generator's own settings changed).</summary>
    public void Regenerate() => CSharpTerrain.Regenerate(GameObject.SceneId, GameObject.Id);

    /// <summary>Adds a flat tile at a place in the tile grid (Fixed mode): its id, or 0 when the place is taken.</summary>
    public int AddTile(int x, int z) => CSharpTerrain.AddTile(GameObject.SceneId, GameObject.Id, x, z);

    /// <summary>The ground's density at a world point as it is now (more than zero is solid); null where no chunk is
    /// made yet.</summary>
    public float? DensityAt(Vector3 world)
    {
        float density = CSharpTerrain.DensityAt(GameObject.SceneId, GameObject.Id, world);
        return float.IsNaN(density) ? null : density;
    }

    /// <summary>A ray against the voxel surface itself (no colliders needed, so it works before they are made):
    /// true and where it hit.</summary>
    public bool Raycast(Vector3 origin, Vector3 direction, float maxDistance, out Vector3 point)
    {
        Span<float> hit = stackalloc float[3];
        float distance = CSharpTerrain.Raycast(GameObject.SceneId, GameObject.Id, origin, direction, maxDistance, hit);
        point = distance >= 0 ? new Vector3(hit[0], hit[1], hit[2]) : default;
        return distance >= 0;
    }

    /// <summary>The ids of the terrain's tiles (Fixed mode).</summary>
    public int[] TileIds()
    {
        (ulong scene, ulong id) = (GameObject.SceneId, GameObject.Id);
        string text = NativeText.Read(buffer => CSharpTerrain.TileIds(scene, id, buffer)) ?? "";
        return text.Length == 0 ? [] : Array.ConvertAll(text.Split(','), int.Parse);
    }
}
