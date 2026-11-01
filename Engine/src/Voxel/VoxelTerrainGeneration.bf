using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Making the ground: samples from the generator, painting, and the colours of the surface.
extension VoxelTerrain
{
	/// The shape of the ground before any sculpting: more than zero is solid, less is air, and the surface is where
	/// it crosses zero, so "height - y" makes ground up to that height. x, y and z are in the terrain's own space.
	public delegate float DensityFunction(float x, float y, float z);

	/// Replaces the ground's shape with a function, for a game that makes its world in code (a TerrainGenerator
	/// class named in the Generator field does the same, and can be chosen in the editor). It is called from worker
	/// threads, many times at once, so it must only read data that does not change while the terrain is
	/// generating. Pass null to go back to the Generator field. The terrain takes ownership.
	public void SetGenerator(DensityFunction shape)
	{
		if (mCodeGenerator != null)
		{
			using (mMonitor.Enter())
				mRetired.Add(mCodeGenerator);
		}
		mCodeGenerator = shape != null ? new FunctionTerrainGenerator(shape) : null;
		mGeneratorVersion++;
		if (mSnap != null)
			CaptureSettings();
		if (Streaming)
			Regenerate();
	}

	/// Replaces the ground of one tile with what a generator makes, as if it had been sculpted that way; the edge it
	/// shares with other tiles takes the new ground too, so there is no gap. The caller keeps the generator.
	public bool ApplyGenerator(TerrainGenerator source, int32 tileId)
	{
		if (source == null)
			return false;
		TerrainTile tile;
		if (!FindTile(tileId, out tile))
			return false;
		source.Begin(this);
		let size = Math.Clamp(tileSize, 1, 64);
		Dictionary<Int3, int8[]> made = scope .();
		defer
		{
			for (let entry in made)
				delete entry.value;
		}
		Dictionary<Int3, uint8[]> painted = scope .();
		defer
		{
			for (let entry in painted)
				delete entry.value;
		}
		for (int32 lz < size)
		{
			for (int32 lx < size)
			{
				for (int32 cy = minChunkY; cy <= maxChunkY; cy++)
				{
					let coord = Int3(tile.x * size + lx, cy, tile.z * size + lz);
					made[coord] = SampleGenerator(source, coord, let paint);
					if (paint != null)
						painted[coord] = paint;
				}
			}
		}
		using (mMonitor.Enter())
		{
			for (let entry in made)
			{
				let local = Int3(entry.key.x - tile.x * size, entry.key.y, entry.key.z - tile.z * size);
				painted.TryGetValue(entry.key, let paint);
				PutGenerated(tileId, entry.key, local, entry.value, paint);
			}
		}
		for (let entry in made)
		{
			if (mChunks.TryGetValue(entry.key, let chunk))
				QueueEdited(chunk);
		}
		TakeSharedEdges(made, painted);
		HasUnsavedEdits = true;
		return true;
	}

	/// A chunk's samples (and paint, when the generator paints; else null) straight from a generator.
	int8[] SampleGenerator(TerrainGenerator source, Int3 coord, out uint8[] paint)
	{
		let step = mVoxelSize;
		let density = new int8[SampleCount];
		paint = source.Paints ? new uint8[SampleCount] : null;
		let origin = Vector3(coord.x, coord.y, coord.z) * (ChunkCells * step);
		int index = 0;
		for (int z < Samples)
		{
			for (int y < Samples)
			{
				for (int x < Samples)
				{
					let wx = origin.x + x * step, wy = origin.y + y * step, wz = origin.z + z * step;
					density[index] = Quantize(source.Density(wx, wy, wz), step);
					if (paint != null)
						paint[index] = source.Paint(wx, wy, wz);
					index++;
				}
			}
		}
		return density;
	}

	/// Puts generated samples in place as sculpting: into the chunk when it is loaded, else into the tile's kept
	/// edits (a chunk still on its way is made again with them). Call with mMonitor held.
	void PutGenerated(int32 tileId, Int3 coord, Int3 local, int8[] density, uint8[] paint)
	{
		mChunks.TryGetValue(coord, let chunk);
		if (chunk != null && chunk.generated)
		{
			Record(chunk.coord);
			density.CopyTo(chunk.density);
			if (paint != null)
			{
				if (chunk.paint == null)
					chunk.paint = new uint8[SampleCount];
				paint.CopyTo(chunk.paint);
			}
			else
				DeleteAndNullify!(chunk.paint);
			chunk.edited = true;
			chunk.shapeChanged = true;
			return;
		}
		Record(coord);
		let saved = new SavedChunk();
		saved.density = new int8[SampleCount];
		density.CopyTo(saved.density);
		if (paint != null)
		{
			saved.paint = new uint8[SampleCount];
			paint.CopyTo(saved.paint);
		}
		PutSaved(tileId, local, saved);
		if (chunk != null)
			chunk.stale = true;
	}

	/// The loaded neighbours of the changed chunks take the samples they share with them.
	void TakeSharedEdges(Dictionary<Int3, int8[]> made, Dictionary<Int3, uint8[]> painted)
	{
		for (let chunk in mChunks.Values)
		{
			if (made.ContainsKey(chunk.coord) || !chunk.generated)
				continue;
			bool touched = false;
			for (int32 dz = -1; dz <= 1; dz++)
			{
				for (int32 dy = -1; dy <= 1; dy++)
				{
					for (int32 dx = -1; dx <= 1; dx++)
					{
						let other = Int3(chunk.coord.x + dx, chunk.coord.y + dy, chunk.coord.z + dz);
						if (!made.TryGetValue(other, let density))
							continue;
						if (!touched)
							Record(chunk.coord);
						painted.TryGetValue(other, let paint);
						if (paint != null && chunk.paint == null)
							chunk.paint = new uint8[SampleCount];
						CopyShared(chunk.density, chunk.paint, density, paint, dx, dy, dz);
						touched = true;
					}
				}
			}
			if (touched)
			{
				chunk.edited = true;
				chunk.shapeChanged = true;
				QueueEdited(chunk);
			}
		}
	}

	/// Copies the samples a chunk shares with its neighbour at (dx, dy, dz) from the neighbour's arrays.
	static void CopyShared(int8[] density, uint8[] paint, int8[] fromDensity, uint8[] fromPaint, int32 dx, int32 dy, int32 dz)
	{
		void Range(int32 d, out int mine0, out int mine1, out int theirs0)
		{
			if (d < 0)
			{
				mine0 = 0;
				mine1 = 0;
				theirs0 = ChunkCells;
			}
			else if (d > 0)
			{
				mine0 = ChunkCells;
				mine1 = ChunkCells;
				theirs0 = 0;
			}
			else
			{
				mine0 = 0;
				mine1 = ChunkCells;
				theirs0 = 0;
			}
		}
		Range(dx, let x0, let x1, let tx);
		Range(dy, let y0, let y1, let ty);
		Range(dz, let z0, let z1, let tz);
		for (int z = z0; z <= z1; z++)
		{
			for (int y = y0; y <= y1; y++)
			{
				for (int x = x0; x <= x1; x++)
				{
					let mine = SampleIndex(x, y, z);
					let theirs = SampleIndex(tx + x - x0, ty + y - y0, tz + z - z0);
					density[mine] = fromDensity[theirs];
					if (paint != null && fromPaint != null)
						paint[mine] = fromPaint[theirs];
				}
			}
		}
	}

	/// True when a chunk is part of the terrain: any chunk in Endless mode, a chunk of a tile in Fixed mode.
	public bool InArea(Int3 coord)
	{
		if (mSnap == null)
			ApplyTilesText();
		if (mode == .Endless)
			return true;
		let size = Math.Clamp(tileSize, 1, 64);
		return TileAt(FloorDiv(coord.x, size), FloorDiv(coord.z, size)) != 0;
	}

	/// The size in metres, along X and Z, of the rectangle the tiles span.
	public Vector2 AreaSize
	{
		get
		{
			if (mSnap == null)
				ApplyTilesText();
			if (mTiles.Count == 0)
				return .Zero;
			int32 x0 = int32.MaxValue, z0 = int32.MaxValue, x1 = int32.MinValue, z1 = int32.MinValue;
			for (let tile in mTiles)
			{
				x0 = Math.Min(x0, tile.x);
				x1 = Math.Max(x1, tile.x);
				z0 = Math.Min(z0, tile.z);
				z1 = Math.Max(z1, tile.z);
			}
			let w = TileWorldSize;
			return .((x1 - x0 + 1) * w, (z1 - z0 + 1) * w);
		}
	}

	/// Fills a chunk's samples: its sculpting if it has any, otherwise the generator's ground, taking the samples it
	/// shares with sculpted neighbours from them so the surface meets theirs. Runs on worker threads.
	void GenerateDensity(Chunk chunk, Snapshot snap)
	{
		if (chunk.density == null)
			chunk.density = new int8[SampleCount];
		using (mMonitor.Enter())
		{
			// Sculpted chunks come back exactly as they were saved.
			let saved = FindSaved(chunk.tileId, chunk.local);
			if (saved != null)
			{
				saved.density.CopyTo(chunk.density);
				if (saved.paint != null)
				{
					if (chunk.paint == null)
						chunk.paint = new uint8[SampleCount];
					saved.paint.CopyTo(chunk.paint);
				}
				else
					DeleteAndNullify!(chunk.paint);
				chunk.edited = true;
				chunk.appliedBrushes = saved.appliedBrushes;
				chunk.generated = true;
				return;
			}
		}
		let size = snap.voxelSize;
		let origin = Vector3(chunk.coord.x, chunk.coord.y, chunk.coord.z) * (ChunkCells * size);
		let generator = snap.generator;
		let paints = generator != null && generator.Paints;
		if (paints && chunk.paint == null)
			chunk.paint = new uint8[SampleCount];
		else if (!paints)
			DeleteAndNullify!(chunk.paint);
		int index = 0;
		for (int z < Samples)
		{
			for (int y < Samples)
			{
				for (int x < Samples)
				{
					let wx = origin.x + x * size, wy = origin.y + y * size, wz = origin.z + z * size;
					chunk.density[index] = Quantize(snap.Density(wx, wy, wz), size);
					if (paints)
						chunk.paint[index] = generator.Paint(wx, wy, wz);
					index++;
				}
			}
		}
		chunk.edited = false;
		using (mMonitor.Enter())
		{
			for (int32 dz = -1; dz <= 1; dz++)
			{
				for (int32 dy = -1; dy <= 1; dy++)
				{
					for (int32 dx = -1; dx <= 1; dx++)
					{
						if (dx == 0 && dy == 0 && dz == 0)
							continue;
						let other = Int3(chunk.coord.x + dx, chunk.coord.y + dy, chunk.coord.z + dz);
						int8[] density = null;
						uint8[] paint = null;
						if (mChunks.TryGetValue(other, let live) && live != chunk)
						{
							if (live.generated && live.edited && live.density != null)
							{
								density = live.density;
								paint = live.paint;
							}
						}
						else if (snap.Locate(other, let tileId, let local))
						{
							let saved = FindSaved(tileId, local);
							if (saved != null)
							{
								density = saved.density;
								paint = saved.paint;
							}
						}
						if (density == null)
							continue;
						if (paint != null && chunk.paint == null)
							chunk.paint = new uint8[SampleCount];
						CopyShared(chunk.density, chunk.paint, density, paint, dx, dy, dz);
					}
				}
			}
		}
		chunk.generated = true;
	}

	Color LayerColor(uint8 layer)
	{
		switch (layer)
		{
		case 1: return mGrass;
		case 2: return mRock;
		case 3: return mSand;
		case 4: return mSnow;
		default: return mDirt;
		}
	}

	Color SurfaceColor(float worldY, float slopeUp)
	{
		if (slopeUp < 0.55f)
			return slopeUp < 0.2f ? mDirt : mRock;
		if (worldY < mSeaLevel + 1.5f * mVoxelSize)
			return mSand;
		if (worldY > mTerrainHeight * 0.75f)
			return mSnow;
		return mGrass;
	}
}
