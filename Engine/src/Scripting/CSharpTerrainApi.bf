using System;
using System.Collections;

namespace Tallow;

/// A terrain's C# TerrainGenerator (by handle in the managed TerrainGenerators): whole chunks at once through
/// tn_csharp_terrain_generator, from the terrain's worker threads.
class CSharpTerrainGenerator : TerrainGenerator
{
	/// Every one alive (made and deleted on the main thread), to stop them when the game's code goes.
	static List<CSharpTerrainGenerator> sAlive = new .() ~ delete _;

	/// 0 once the game's code has gone: then it makes flat ground at 0 without calling anything.
	volatile int32 mHandle;
	bool mPaints;
	bool mOwnsHandle;

	public this(int32 handle, bool paints, bool ownsHandle = true)
	{
		mHandle = handle;
		mPaints = paints;
		mOwnsHandle = ownsHandle;
		sAlive.Add(this);
	}

	public ~this()
	{
		sAlive.Remove(this);
		// The managed side lets go of its object (a baking one is let go by the managed side itself).
		if (mHandle > 0 && mOwnsHandle)
			CSharpRuntime.TerrainGeneratorCall(2, mHandle, .(), 0, 0, null, null);
	}

	/// The game's code is going (unload or hot reload): its generators stop.
	public static void StopAll()
	{
		for (let generator in sAlive)
			generator.mHandle = 0;
	}

	public override bool Paints => mPaints && mHandle > 0;
	public override bool FillsChunks => mHandle > 0;

	public override bool Fill(Vector3 origin, float step, int32 samples, float* density, uint8* paint)
	{
		if (mHandle <= 0)
			return false;
		if (CSharpRuntime.TerrainGeneratorCall(0, mHandle, origin, step, samples, density, paint) > 0)
			return true;
		// It threw (reported once by the managed side): air, rather than asking again for every sample.
		let count = samples * samples * samples;
		for (int i < count)
			density[i] = -1;
		if (paint != null)
			Internal.MemSet(paint, 0, count);
		return true;
	}

	public override bool FillPoints(Vector3* points, int32 count, float* density)
	{
		if (mHandle <= 0)
			return false;
		if (CSharpRuntime.TerrainGeneratorCall(3, mHandle, .(), 0, count, density, null, (float*)points) > 0)
			return true;
		for (int i < count)
			density[i] = -1;
		return true;
	}

	// One point (anything asking for a single sample).
	public override float Density(float x, float y, float z)
	{
		if (mHandle <= 0)
			return -y;
		float value = 0;
		uint8 layer = 0;
		if (CSharpRuntime.TerrainGeneratorCall(0, mHandle, .(x, y, z), 1, 1, &value, mPaints ? &layer : null) <= 0)
			return -1; // air: a generator that failed makes no ground
		return value;
	}

	public override uint8 Paint(float x, float y, float z)
	{
		if (mHandle <= 0)
			return 0;
		float value = 0;
		uint8 layer = 0;
		CSharpRuntime.TerrainGeneratorCall(0, mHandle, .(x, y, z), 1, 1, &value, &layer);
		return layer;
	}

	public override void Begin(VoxelTerrain terrain)
	{
		if (mHandle > 0)
			CSharpRuntime.TerrainGeneratorCall(1, mHandle, .(), 0, 0, null, null);
	}
}

/// Terrain generators for C# scripts (VoxelTerrain.SetGenerator in Tallow.API).
[CSharpExpose]
static class CSharpTerrain
{
	/// Gives the terrain a C# generator (handle above 0), or takes it away (0: back to its Generator field).
	[CSharpExpose]
	public static bool SetGenerator(uint64 session, uint64 entity, int32 handle, bool paints)
	{
		let terrain = CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>();
		if (terrain == null)
			return false;
		terrain.SetGenerator(handle > 0 ? new CSharpTerrainGenerator(handle, paints) : null);
		return true;
	}

	/// Bakes a C# generator into one tile, as if it had been sculpted that way.
	[CSharpExpose]
	public static bool ApplyGenerator(uint64 session, uint64 entity, int32 handle, bool paints, int32 tileId)
	{
		let terrain = CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>();
		if (terrain == null || handle <= 0)
			return false;
		let generator = scope CSharpTerrainGenerator(handle, paints, false);
		generator.Begin(terrain);
		return terrain.ApplyGenerator(generator, tileId);
	}

	/// Makes every chunk nobody has sculpted again (after a generator's settings changed).
	[CSharpExpose]
	public static bool Regenerate(uint64 session, uint64 entity)
	{
		let terrain = CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>();
		if (terrain == null)
			return false;
		terrain.Regenerate();
		return true;
	}

	/// Adds a flat tile at a grid place: its id, 0 when the place is taken (or there is no terrain).
	[CSharpExpose]
	public static int32 AddTile(uint64 session, uint64 entity, int32 x, int32 z) =>
		CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>()?.AddTile(x, z) ?? 0;

	/// The density at a world point (more than zero solid); NaN where no chunk is loaded.
	[CSharpExpose]
	public static float DensityAt(uint64 session, uint64 entity, Vector3 world)
	{
		let terrain = CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>();
		float density = 0;
		if (terrain == null || !terrain.DensityAt(world, out density))
			return float.NaN;
		return density;
	}

	/// A ray against the voxel surface itself (no colliders needed): the distance to the hit, or -1.
	[CSharpExpose]
	public static float Raycast(uint64 session, uint64 entity, Vector3 origin, Vector3 direction, float maxDistance, Span<float> point)
	{
		let terrain = CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>();
		if (terrain == null || direction.LengthSquared < 1e-12f || !(maxDistance > 0))
			return -1;
		Vector3 hit = default;
		if (!terrain.Raycast(.(origin, direction.Normalized), maxDistance, out hit))
			return -1;
		if (point.Length >= 3)
		{
			point[0] = hit.x;
			point[1] = hit.y;
			point[2] = hit.z;
		}
		return Vector3.Distance(origin, hit);
	}

	/// The terrain's tiles' ids, separated by ',' (Fixed mode); the whole length.
	[CSharpExpose]
	public static int32 TileIds(uint64 session, uint64 entity, Span<uint8> buffer)
	{
		let terrain = CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>();
		if (terrain == null)
			return 0;
		let text = scope String();
		for (let tile in terrain.[Friend]mTiles)
		{
			if (!text.IsEmpty)
				text.Append(',');
			text.AppendF("{}", tile.id);
		}
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}
}
