using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Looking at the ground from outside: chunk meshes for tests and tools, and rays and heights against the surface.
extension VoxelTerrain
{
	/// How many samples that neighbouring loaded chunks share differ between the two chunks' copies, in density or
	/// paint. 0 means sculpting and painting meet exactly at every chunk and tile edge.
	public int32 SeamMismatches()
	{
		int32 count = 0;
		for (let chunk in mChunks.Values)
		{
			if (!chunk.generated || chunk.density == null)
				continue;
			for (int axis < 3)
			{
				let other = chunk.coord + (axis == 0 ? Int3(1, 0, 0) : (axis == 1 ? Int3(0, 1, 0) : Int3(0, 0, 1)));
				if (!mChunks.TryGetValue(other, let next) || !next.generated || next.density == null)
					continue;
				for (int b < Samples)
				{
					for (int a < Samples)
					{
						int i, j;
						if (axis == 0)
						{
							i = SampleIndex(ChunkCells, a, b);
							j = SampleIndex(0, a, b);
						}
						else if (axis == 1)
						{
							i = SampleIndex(a, ChunkCells, b);
							j = SampleIndex(a, 0, b);
						}
						else
						{
							i = SampleIndex(a, b, ChunkCells);
							j = SampleIndex(a, b, 0);
						}
						let paintA = chunk.paint != null ? chunk.paint[i] : 0;
						let paintB = next.paint != null ? next.paint[j] : 0;
						if (chunk.density[i] != next.density[j] || paintA != paintB)
							count++;
					}
				}
			}
		}
		return count;
	}

	/// The mesh a loaded chunk is drawn with, or null.
	public Mesh ChunkMesh(Int3 coord) => mChunks.TryGetValue(coord, let chunk) && chunk.state == .Uploaded ? chunk.mesh : null;

	/// The mesh a loaded chunk collides with when it is not the drawn one (level of detail on), or null.
	public Mesh ChunkCollisionMesh(Int3 coord) => mChunks.TryGetValue(coord, let chunk) && chunk.separateCollision ? chunk.collisionMesh : null;

	/// The level of detail a loaded chunk's mesh was made at (0 full), or -1.
	public int32 ChunkLod(Int3 coord) => mChunks.TryGetValue(coord, let chunk) ? chunk.builtLod : -1;

	// ---- reading the ground ----

	/// Trilinear density at a point in the terrain's local space; false where no chunk is loaded.
	bool SampleLocal(Vector3 p, out float density)
	{
		density = -1;
		let size = mVoxelSize;
		let chunkWorld = ChunkCells * size;
		let coord = Int3((int32)Math.Floor(p.x / chunkWorld), (int32)Math.Floor(p.y / chunkWorld), (int32)Math.Floor(p.z / chunkWorld));
		if (!mChunks.TryGetValue(coord, let chunk) || !chunk.generated)
			return false;
		if (mSnap != null && !mSnap.Inside(p.x, p.z))
		{
			density = Air;
			return true;
		}
		let fx = (p.x - coord.x * chunkWorld) / size;
		let fy = (p.y - coord.y * chunkWorld) / size;
		let fz = (p.z - coord.z * chunkWorld) / size;
		let x = Math.Min((int)fx, ChunkCells - 1), y = Math.Min((int)fy, ChunkCells - 1), z = Math.Min((int)fz, ChunkCells - 1);
		let tx = fx - x, ty = fy - y, tz = fz - z;
		let d = chunk.density;
		float S(int ix, int iy, int iz) => (float)d[SampleIndex(ix, iy, iz)];
		let c00 = S(x, y, z) + (S(x + 1, y, z) - S(x, y, z)) * tx;
		let c10 = S(x, y + 1, z) + (S(x + 1, y + 1, z) - S(x, y + 1, z)) * tx;
		let c01 = S(x, y, z + 1) + (S(x + 1, y, z + 1) - S(x, y, z + 1)) * tx;
		let c11 = S(x, y + 1, z + 1) + (S(x + 1, y + 1, z + 1) - S(x, y + 1, z + 1)) * tx;
		let c0 = c00 + (c10 - c00) * ty;
		let c1 = c01 + (c11 - c01) * ty;
		density = c0 + (c1 - c0) * tz;
		return true;
	}

	/// The density at a point in world space, as the ground is now (more than zero is solid); false where no chunk is
	/// loaded.
	public bool DensityAt(Vector3 world, out float density) => SampleLocal(Transform.InverseTransformPoint(world), out density);

	/// Ray against the voxel surface itself (no physics needed, so it also works in the editor).
	public bool Raycast(Ray worldRay, float maxDistance, out Vector3 point)
	{
		point = default;
		let toLocal = Transform.WorldToLocal;
		let origin = toLocal.TransformPoint(worldRay.origin);
		let direction = toLocal.TransformDirection(worldRay.direction).Normalized;
		let step = mVoxelSize * 0.5f;
		float previous = 0;
		bool started = false;
		for (float t = 0; t < maxDistance; t += step)
		{
			float density;
			if (!SampleLocal(origin + direction * t, out density))
			{
				started = false;
				continue;
			}
			if (density > 0 && started)
			{
				// Bisect between the last empty sample and this solid one.
				float lo = previous, hi = t;
				for (int i < 6)
				{
					let mid = (lo + hi) * 0.5f;
					float d;
					if (SampleLocal(origin + direction * mid, out d) && d > 0)
						hi = mid;
					else
						lo = mid;
				}
				point = Transform.TransformPoint(origin + direction * hi);
				return true;
			}
			if (density > 0)
				return false; // The ray starts inside the ground.
			previous = t;
			started = true;
		}
		return false;
	}
}
