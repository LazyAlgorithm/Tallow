using System;
using System.Collections;

namespace Tallow;

/// Gradient noise used for terrain generation. Deterministic for a given seed on every platform.
/// Only Perlin/Fbm are exported to C#; low-level implementation stays in Beef.
[CSharpExpose]
static class Noise
{
	[Inline]
	static uint32 Hash(int32 x, int32 y, int32 z, uint32 seed)
	{
		var h = (uint32)x * 374761393 + (uint32)y * 668265263 + (uint32)z * 2147483647 + seed * 3266489917;
		h = (h ^ (h >> 13)) * 1274126177;
		return h ^ (h >> 16);
	}

	[Inline]
	static float Grad(uint32 hash, float x, float y, float z)
	{
		let h = hash & 15;
		let u = h < 8 ? x : y;
		let v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
		return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
	}

	[Inline]
	static float Fade(float t) => t * t * t * (t * (t * 6 - 15) + 10);

	/// Perlin noise in roughly -1..1.
	[CSharpExpose]
	public static float Perlin(float x, float y, float z, uint32 seed)
	{
		let xi = (int32)Math.Floor(x);
		let yi = (int32)Math.Floor(y);
		let zi = (int32)Math.Floor(z);
		let xf = x - xi;
		let yf = y - yi;
		let zf = z - zi;
		let u = Fade(xf);
		let v = Fade(yf);
		let w = Fade(zf);
		let n000 = Grad(Hash(xi, yi, zi, seed), xf, yf, zf);
		let n100 = Grad(Hash(xi + 1, yi, zi, seed), xf - 1, yf, zf);
		let n010 = Grad(Hash(xi, yi + 1, zi, seed), xf, yf - 1, zf);
		let n110 = Grad(Hash(xi + 1, yi + 1, zi, seed), xf - 1, yf - 1, zf);
		let n001 = Grad(Hash(xi, yi, zi + 1, seed), xf, yf, zf - 1);
		let n101 = Grad(Hash(xi + 1, yi, zi + 1, seed), xf - 1, yf, zf - 1);
		let n011 = Grad(Hash(xi, yi + 1, zi + 1, seed), xf, yf - 1, zf - 1);
		let n111 = Grad(Hash(xi + 1, yi + 1, zi + 1, seed), xf - 1, yf - 1, zf - 1);
		let x00 = n000 + (n100 - n000) * u;
		let x10 = n010 + (n110 - n010) * u;
		let x01 = n001 + (n101 - n001) * u;
		let x11 = n011 + (n111 - n011) * u;
		let y0 = x00 + (x10 - x00) * v;
		let y1 = x01 + (x11 - x01) * v;
		return y0 + (y1 - y0) * w;
	}

	/// Fractal sum of Perlin octaves.
	[CSharpExpose]
	public static float Fbm(float x, float y, float z, uint32 seed, int32 octaves)
	{
		float sum = 0;
		float amplitude = 1;
		float frequency = 1;
		float total = 0;
		for (int i < octaves)
		{
			sum += Perlin(x * frequency, y * frequency, z * frequency, seed + (uint32)i * 101) * amplitude;
			total += amplitude;
			amplitude *= 0.5f;
			frequency *= 2.0f;
		}
		return sum / total;
	}
}

/// Required on every terrain generator class, as [Component] is on components: it lets the editor list the class
/// (the terrain's Generator field, and Apply Generator on tiles) and make one by name.
[AttributeUsage(.Class, .AlwaysIncludeTarget | .ReflectAttribute, ReflectUser = .All, AlwaysIncludeUser = .AssumeInstantiated | .IncludeAllMethods)]
struct TerrainGeneratorAttribute : Attribute
{
}

/// The shape of a game's ground. Tallow stores, edits, meshes and streams terrain; what the ground looks like before
/// anyone sculpts it is the game's to say, with a class like this:
///
///   [TerrainGenerator]
///   class Islands : TerrainGenerator
///   {
///       public override float Density(float x, float y, float z)
///       {
///           let hill = Noise.Fbm(x * 0.01f, 0, z * 0.01f, 7, 4) * 30;
///           return hill - y;      // more than zero is solid, less is air
///       }
///   }
///
/// Name it in a terrain's Generator field to shape every chunk nobody has sculpted (an Endless terrain, or tiles that
/// should be generated), or bake it into chosen tiles in the editor (Tiles > Apply Generator), after which those
/// tiles are ordinary sculpted ground.
///
/// Density and Paint are called from worker threads, many at once: read only data that does not change while the
/// terrain is generating. Begin is called on the main thread first, to copy whatever the generator needs.
abstract class TerrainGenerator
{
	/// More than zero is solid, less is air; the surface is where it crosses zero, so "height - y" makes ground up to
	/// that height. x, y and z are metres in the terrain's own space.
	public abstract float Density(float x, float y, float z);

	/// True when Paint gives layers; false (the default) leaves the colours to the terrain's automatic rules.
	public virtual bool Paints => false;

	/// The painted layer at a point: 1 grass, 2 rock, 3 sand, 4 snow, 5 dirt, 0 automatic.
	public virtual uint8 Paint(float x, float y, float z) => 0;

	/// Called on the main thread before the terrain generates with this generator, and again when the terrain's
	/// settings change.
	public virtual void Begin(VoxelTerrain terrain) { }

	/// The generator class of that name (full or short), if the program has one.
	public static Type TypeNamed(StringView name)
	{
		if (name.IsEmpty)
			return null;
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type == null || !type.IsObject || type.IsAbstract || !type.IsSubtypeOf(typeof(TerrainGenerator)))
				continue;
			if (type.GetFullName(.. scope .()) == name || type.GetName(.. scope .()) == name)
				return type;
		}
		return null;
	}

	/// Every generator class in the program, for the editor's menus.
	public static void Types(List<Type> types)
	{
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type != null && type.IsObject && !type.IsAbstract && type.IsSubtypeOf(typeof(TerrainGenerator)) && !type.IsBoxed)
				types.Add(type);
		}
		types.Sort(scope (a, b) => a.GetName(.. scope .()).CompareTo(b.GetName(.. scope .())));
	}

	/// Makes a generator of the named class, or null.
	public static TerrainGenerator Create(StringView name)
	{
		let type = TypeNamed(name);
		if (type != null && type.CreateObject() case .Ok(let obj))
		{
			if (let generator = obj as TerrainGenerator)
				return generator;
			delete obj;
		}
		return null;
	}
}

/// Rolling hills with caves, from noise: the sample generator. An Endless terrain with no generator of its own uses
/// it, with the terrain's seed, height, scale and cave settings.
[TerrainGenerator]
class NoiseTerrainGenerator : TerrainGenerator
{
	public uint32 seed = 1337;
	public float height = 28.0f;
	public float scale = 0.012f;
	public float caveAmount = 0.35f;

	public override void Begin(VoxelTerrain terrain)
	{
		seed = (uint32)terrain.seed;
		height = terrain.terrainHeight;
		scale = terrain.terrainScale;
		caveAmount = terrain.caveAmount;
	}

	public override float Density(float x, float y, float z)
	{
		let continental = Noise.Fbm(x * scale, 0, z * scale, seed, 5);
		let ridges = 1.0f - Mathf.Abs(Noise.Fbm(x * scale * 2.3f, 17.0f, z * scale * 2.3f, seed + 7, 3));
		let ground = continental * height + ridges * ridges * height * 0.35f;
		var density = ground - y;
		if (caveAmount > 0 && density > -4.0f)
		{
			let cave = Noise.Fbm(x * 0.045f, y * 0.06f, z * 0.045f, seed + 31, 3);
			density -= Math.Max(0, cave - (0.42f - caveAmount * 0.4f)) * 60.0f;
		}
		return density;
	}
}

/// A generator made from a function (VoxelTerrain.SetGenerator).
class FunctionTerrainGenerator : TerrainGenerator
{
	VoxelTerrain.DensityFunction mFunction ~ delete _;

	public this(VoxelTerrain.DensityFunction shape)
	{
		mFunction = shape;
	}

	public override float Density(float x, float y, float z) => mFunction(x, y, z);
}
