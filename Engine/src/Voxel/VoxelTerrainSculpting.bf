using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Sculpting and painting the ground, and sharing brush strokes with other players.
extension VoxelTerrain
{
	/// Adds (amount > 0) or removes (amount < 0) material inside a sphere given in world space.
	public void ModifySphere(Vector3 worldCenter, float radius, float amount)
	{
		Brush(worldCenter, radius, Math.Abs(amount), amount >= 0 ? .Raise : .Lower);
	}

	/// Applies a sculpting or painting brush in real time; only the chunks it touches are re-meshed, and it carries
	/// on across chunk and tile edges as one surface.
	/// paintLayer: 1 grass, 2 rock, 3 sand, 4 snow, 5 dirt, 0 back to automatic. flattenHeight is a world Y.
	///
	/// In multiplayer the edit is applied on every machine. Called on a client it is sent to the server first and
	/// takes effect when the server passes it back, a moment later.
	public void Brush(Vector3 worldCenter, float radius, float strength, VoxelBrush mode, int32 paintLayer = 1, float flattenHeight = 0)
	{
		if (NetworkSync.RouteBrush(this, worldCenter, radius, strength, mode, paintLayer, flattenHeight))
			return;
		BrushStroke stroke;
		stroke.center = Transform.InverseTransformPoint(worldCenter);
		stroke.radius = radius;
		stroke.strength = strength;
		stroke.mode = mode;
		stroke.paintLayer = paintLayer;
		stroke.flattenLocal = Transform.InverseTransformPoint(.(worldCenter.x, flattenHeight, worldCenter.z)).y;
		// In a session the stroke is remembered, so chunks that are not loaded yet get it when they arrive.
		let shared = NetworkSync.InSession(Scene);
		if (shared)
			mSessionBrushes.Add(stroke);
		let chunkWorld = ChunkCells * mVoxelSize;
		let reach = radius + mVoxelSize;
		let center = stroke.center;
		let minC = Int3((int32)Math.Floor((center.x - reach) / chunkWorld), (int32)Math.Floor((center.y - reach) / chunkWorld), (int32)Math.Floor((center.z - reach) / chunkWorld));
		let maxC = Int3((int32)Math.Floor((center.x + reach) / chunkWorld), (int32)Math.Floor((center.y + reach) / chunkWorld), (int32)Math.Floor((center.z + reach) / chunkWorld));
		List<Chunk> touched = scope .();
		for (int32 cz = minC.z; cz <= maxC.z; cz++)
		{
			for (int32 cy = minC.y; cy <= maxC.y; cy++)
			{
				for (int32 cx = minC.x; cx <= maxC.x; cx++)
				{
					if (mChunks.TryGetValue(Int3(cx, cy, cz), let chunk) && chunk.generated)
						touched.Add(chunk);
				}
			}
		}
		if (shared)
		{
			for (let chunk in touched)
				CatchUp(chunk);
			if (mode != .Paint)
				Foliage.GroundChanged(this, worldCenter, radius);
			return;
		}
		// Smoothing reads the neighbours of each sample, across chunk edges: every chunk reads the ground as it was
		// before this stroke, so the copies of a shared edge get the same values.
		Dictionary<Int3, int8[]> before = null;
		if (mode == .Smooth)
		{
			before = scope:: .();
			for (let chunk in touched)
				before[chunk.coord] = Copy(chunk.density);
			// Neighbours just outside the stroke's chunks are read too.
			for (let chunk in touched)
			{
				for (int32 dz = -1; dz <= 1; dz++)
				{
					for (int32 dy = -1; dy <= 1; dy++)
					{
						for (int32 dx = -1; dx <= 1; dx++)
						{
							let other = Int3(chunk.coord.x + dx, chunk.coord.y + dy, chunk.coord.z + dz);
							if (!before.ContainsKey(other) && mChunks.TryGetValue(other, let near) && near.generated)
								before[other] = Copy(near.density);
						}
					}
				}
			}
		}
		defer
		{
			if (before != null)
			{
				for (let entry in before)
					delete entry.value;
			}
		}
		for (let chunk in touched)
			ApplyStroke(chunk, stroke, before);
		// Plants standing on the ground go with it, or go altogether if it buries them or leaves them in the air.
		if (mode != .Paint)
			Foliage.GroundChanged(this, worldCenter, radius);
	}

	/// Applies the session strokes a chunk has not had yet, in order.
	void CatchUp(Chunk chunk)
	{
		for (int i = chunk.appliedBrushes; i < mSessionBrushes.Count; i++)
			ApplyStroke(chunk, mSessionBrushes[i], null);
		chunk.appliedBrushes = (int32)mSessionBrushes.Count;
	}

	/// A sample of the ground before the stroke, which may be in a neighbouring chunk.
	static int8 Before(Dictionary<Int3, int8[]> before, Int3 coord, int8[] own, int x, int y, int z)
	{
		if ((uint)x < (uint)Samples && (uint)y < (uint)Samples && (uint)z < (uint)Samples)
			return before.TryGetValue(coord, let mine) ? mine[SampleIndex(x, y, z)] : own[SampleIndex(x, y, z)];
		var c = coord;
		var px = x, py = y, pz = z;
		if (px < 0)
		{
			c.x--;
			px += ChunkCells;
		}
		else if (px > ChunkCells)
		{
			c.x++;
			px -= ChunkCells;
		}
		if (py < 0)
		{
			c.y--;
			py += ChunkCells;
		}
		else if (py > ChunkCells)
		{
			c.y++;
			py -= ChunkCells;
		}
		if (pz < 0)
		{
			c.z--;
			pz += ChunkCells;
		}
		else if (pz > ChunkCells)
		{
			c.z++;
			pz -= ChunkCells;
		}
		if (before.TryGetValue(c, let other))
			return other[SampleIndex(px, py, pz)];
		return own[SampleIndex(Math.Clamp(x, 0, ChunkCells), Math.Clamp(y, 0, ChunkCells), Math.Clamp(z, 0, ChunkCells))];
	}

	/// Applies one stroke to one chunk; nothing happens if the stroke does not reach it.
	void ApplyStroke(Chunk chunk, BrushStroke stroke, Dictionary<Int3, int8[]> before)
	{
		let size = mVoxelSize;
		let chunkWorld = ChunkCells * size;
		let center = stroke.center;
		let radius = stroke.radius;
		let strength = stroke.strength;
		let mode = stroke.mode;
		let reach = radius + size;
		let origin = Vector3(chunk.coord.x, chunk.coord.y, chunk.coord.z) * chunkWorld;
		let x0 = Math.Max(0, (int)Math.Floor((center.x - reach - origin.x) / size));
		let x1 = Math.Min(Samples - 1, (int)Math.Ceiling((center.x + reach - origin.x) / size));
		let y0 = Math.Max(0, (int)Math.Floor((center.y - reach - origin.y) / size));
		let y1 = Math.Min(Samples - 1, (int)Math.Ceiling((center.y + reach - origin.y) / size));
		let z0 = Math.Max(0, (int)Math.Floor((center.z - reach - origin.z) / size));
		let z1 = Math.Min(Samples - 1, (int)Math.Ceiling((center.z + reach - origin.z) / size));
		if (x0 > x1 || y0 > y1 || z0 > z1)
			return;
		Record(chunk.coord);
		if (mode == .Paint && chunk.paint == null)
			chunk.paint = new uint8[SampleCount];
		let density = chunk.density;
		bool changed = false;
		for (int z = z0; z <= z1; z++)
		{
			for (int y = y0; y <= y1; y++)
			{
				for (int x = x0; x <= x1; x++)
				{
					let p = origin + Vector3(x, y, z) * size;
					let falloff = 1.0f - (p - center).Length / radius;
					if (falloff <= 0)
						continue;
					let index = SampleIndex(x, y, z);
					var value = (float)density[index];
					switch (mode)
					{
					case .Raise: value += strength * falloff * 48.0f;
					case .Lower: value -= strength * falloff * 48.0f;
					case .Flatten:
						let target = Mathf.Clamp((stroke.flattenLocal - p.y) / size * 24.0f, -127, 127);
						value = Mathf.Lerp(value, target, Math.Min(1.0f, strength * falloff));
					case .Smooth:
						float average;
						if (before != null)
						{
							let c = chunk.coord;
							value = Before(before, c, density, x, y, z);
							average = ((float)Before(before, c, density, x - 1, y, z) + Before(before, c, density, x + 1, y, z)
								+ Before(before, c, density, x, y - 1, z) + Before(before, c, density, x, y + 1, z)
								+ Before(before, c, density, x, y, z - 1) + Before(before, c, density, x, y, z + 1)) / 6.0f;
						}
						else
						{
							int sum = 0;
							sum += density[SampleIndex(Math.Max(x - 1, 0), y, z)];
							sum += density[SampleIndex(Math.Min(x + 1, (int)ChunkCells), y, z)];
							sum += density[SampleIndex(x, Math.Max(y - 1, 0), z)];
							sum += density[SampleIndex(x, Math.Min(y + 1, (int)ChunkCells), z)];
							sum += density[SampleIndex(x, y, Math.Max(z - 1, 0))];
							sum += density[SampleIndex(x, y, Math.Min(z + 1, (int)ChunkCells))];
							average = sum / 6.0f;
						}
						value = Mathf.Lerp(value, average, Math.Min(1.0f, strength * falloff));
					case .Paint:
						chunk.paint[index] = (uint8)stroke.paintLayer;
					}
					density[index] = (int8)Mathf.Clamp(value, -127, 127);
					changed = true;
				}
			}
		}
		if (changed)
		{
			chunk.edited = true;
			chunk.shapeChanged = true;
			HasUnsavedEdits = true;
			QueueEdited(chunk);
		}
	}
}
