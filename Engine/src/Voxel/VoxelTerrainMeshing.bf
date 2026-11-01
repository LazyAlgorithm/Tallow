using System;
using System.Collections;

namespace Tallow;

/// Turning a terrain chunk's samples into meshes, on worker threads.
extension VoxelTerrain
{
	/// One worker's scratch space, and the samples just beyond the chunk it is meshing (from the neighbouring chunks,
	/// so normals and edges match on both sides of a border).
	class MeshWork
	{
		public int32[] edgeCache = new int32[SampleCount * 3] ~ delete _;
		/// The neighbours' samples one step out from each of the six faces, and `farDistance` steps out.
		public int8[] near = new int8[6 * FaceCount] ~ delete _;
		public int8[] far = new int8[6 * FaceCount] ~ delete _;
		/// Per column of the chunk: inside the tiles.
		public bool[] inside = new bool[FaceCount] ~ delete _;
		public int8[] center;
		/// Contoured style: the chunk's samples at the step being built, with two more on every side (taken from the
		/// chunks around it, the edge of the tiles applied), and the point made for each cell.
		public int8[] padded = new int8[PaddedSide * PaddedSide * PaddedSide] ~ delete _;
		public bool[] paddedMissing = new bool[PaddedSide * PaddedSide * PaddedSide] ~ delete _;
		public int32[] cellVertex = new int32[(ChunkCells + 1) * (ChunkCells + 1) * (ChunkCells + 1)] ~ delete _;
		public int32 farDistance = 1;
		public bool masked;
		public Snapshot snap;
		public Vector3 origin;
		public float size = 1;
		public int32 lod;
		public bool collision;

		/// A sample, which may be just outside the chunk on one axis.
		public int8 Raw(int x, int y, int z)
		{
			if ((uint)x <= (uint)ChunkCells && (uint)y <= (uint)ChunkCells && (uint)z <= (uint)ChunkCells)
				return center[SampleIndex(x, y, z)];
			int face, distance, a, b;
			if (x < 0)
			{
				face = 0;
				distance = -x;
				a = y;
				b = z;
			}
			else if (x > ChunkCells)
			{
				face = 1;
				distance = x - ChunkCells;
				a = y;
				b = z;
			}
			else if (y < 0)
			{
				face = 2;
				distance = -y;
				a = x;
				b = z;
			}
			else if (y > ChunkCells)
			{
				face = 3;
				distance = y - ChunkCells;
				a = x;
				b = z;
			}
			else if (z < 0)
			{
				face = 4;
				distance = -z;
				a = x;
				b = y;
			}
			else
			{
				face = 5;
				distance = z - ChunkCells;
				a = x;
				b = y;
			}
			a = Math.Clamp(a, 0, ChunkCells);
			b = Math.Clamp(b, 0, ChunkCells);
			return (distance <= 1 ? near : far)[face * FaceCount + a + b * Samples];
		}

		/// A sample with the edge of the tiles applied: air outside them.
		public int8 D(int x, int y, int z)
		{
			let value = Raw(x, y, z);
			if (!masked)
				return value;
			if ((uint)x <= (uint)ChunkCells && (uint)z <= (uint)ChunkCells)
				return inside[x + z * Samples] ? value : Air;
			return snap.Inside(origin.x + x * size, origin.z + z * size) ? value : Air;
		}
	}

	static Int3 FaceOffset(int face)
	{
		switch (face)
		{
		case 0: return .(-1, 0, 0);
		case 1: return .(1, 0, 0);
		case 2: return .(0, -1, 0);
		case 3: return .(0, 1, 0);
		case 4: return .(0, 0, -1);
		default: return .(0, 0, 1);
		}
	}

	/// The sample `distance` steps beyond a face, at (a, b) across it, in this chunk's sample coordinates.
	static void BeyondFace(int face, int distance, int a, int b, out int x, out int y, out int z)
	{
		switch (face)
		{
		case 0:
			x = -distance;
			y = a;
			z = b;
		case 1:
			x = ChunkCells + distance;
			y = a;
			z = b;
		case 2:
			x = a;
			y = -distance;
			z = b;
		case 3:
			x = a;
			y = ChunkCells + distance;
			z = b;
		case 4:
			x = a;
			y = b;
			z = -distance;
		default:
			x = a;
			y = b;
			z = ChunkCells + distance;
		}
	}

	static void CopyLayer(int8[] source, int8[] layer, int face, int distance)
	{
		let offset = FaceOffset(face);
		for (int b < Samples)
		{
			for (int a < Samples)
			{
				BeyondFace(face, distance, a, b, let x, let y, let z);
				// The same sample in the neighbour's own coordinates.
				layer[face * FaceCount + a + b * Samples] = source[SampleIndex(x - offset.x * ChunkCells, y - offset.y * ChunkCells, z - offset.z * ChunkCells)];
			}
		}
	}

	static void GenerateLayer(MeshWork work, int8[] layer, int face, int distance)
	{
		let snap = work.snap;
		for (int b < Samples)
		{
			for (int a < Samples)
			{
				BeyondFace(face, distance, a, b, let x, let y, let z);
				let p = work.origin + Vector3(x, y, z) * work.size;
				layer[face * FaceCount + a + b * Samples] = Quantize(snap.Density(p.x, p.y, p.z), work.size);
			}
		}
	}

	/// The samples beyond each face: from the neighbouring chunk, its sculpting on file, or the generator.
	void FillApron(Chunk chunk, MeshWork work, int32 farDistance)
	{
		work.farDistance = farDistance;
		bool[6] missing = default;
		using (mMonitor.Enter())
		{
			for (int face < 6)
			{
				let other = chunk.coord + FaceOffset(face);
				int8[] source = null;
				if (mChunks.TryGetValue(other, let live) && live.generated && live.density != null)
					source = live.density;
				else if (work.snap.Locate(other, let tileId, let local))
					source = FindSaved(tileId, local)?.density;
				if (source == null)
				{
					missing[face] = true;
					continue;
				}
				CopyLayer(source, work.near, face, 1);
				if (farDistance > 1)
					CopyLayer(source, work.far, face, farDistance);
			}
		}
		for (int face < 6)
		{
			if (!missing[face])
				continue;
			GenerateLayer(work, work.near, face, 1);
			if (farDistance > 1)
				GenerateLayer(work, work.far, face, farDistance);
		}
	}

	/// Called with mMonitor held, as a worker takes a chunk.
	void TakeJob(Chunk chunk, MeshWork work)
	{
		work.snap = mSnap;
		work.lod = chunk.lod;
		work.collision = chunk.shapeChanged;
		chunk.shapeChanged = false;
	}

	void BuildChunk(Chunk chunk, MeshWork work)
	{
		let snap = work.snap;
		if (!chunk.generated)
			GenerateDensity(chunk, snap);
		if (!mLodOn)
			work.lod = 0;
		let step = (int32)1 << Math.Clamp(work.lod, 0, 3);
		work.center = chunk.density;
		work.size = snap.voxelSize;
		work.origin = Vector3(chunk.coord.x, chunk.coord.y, chunk.coord.z) * (ChunkCells * work.size);
		work.masked = snap.mode == .Fixed;
		if (work.masked)
		{
			for (int z < Samples)
			{
				for (int x < Samples)
					work.inside[x + z * Samples] = snap.Inside(work.origin.x + x * work.size, work.origin.z + z * work.size);
			}
		}
		FillApron(chunk, work, step);
		chunk.vertices.Clear();
		chunk.indices.Clear();
		let separate = mLodOn && mColliders && mStyle != .Blocky;
		if (mStyle == .Blocky)
		{
			BuildBlocky(chunk, work);
			chunk.builtLod = 0;
		}
		else if (mStyle == .Contoured)
		{
			BuildContoured(chunk, work, step, chunk.vertices, chunk.indices);
			if (separate && work.collision)
			{
				chunk.collisionVertices.Clear();
				chunk.collisionIndices.Clear();
				if (step == 1)
				{
					chunk.collisionVertices.AddRange(chunk.vertices);
					chunk.collisionIndices.AddRange(chunk.indices);
				}
				else
					BuildContoured(chunk, work, 1, chunk.collisionVertices, chunk.collisionIndices);
			}
			if (mLodOn)
				AddOpenEdgeSkirts((2 * step + 1) * work.size, chunk.vertices, chunk.indices);
			chunk.builtLod = work.lod;
		}
		else
		{
			BuildSmooth(chunk, work, step, chunk.vertices, chunk.indices);
			if (separate && work.collision)
			{
				chunk.collisionVertices.Clear();
				chunk.collisionIndices.Clear();
				if (step == 1)
				{
					chunk.collisionVertices.AddRange(chunk.vertices);
					chunk.collisionIndices.AddRange(chunk.indices);
				}
				else
					BuildSmooth(chunk, work, 1, chunk.collisionVertices, chunk.collisionIndices);
			}
			if (mLodOn)
				AddSkirts(work, step, chunk.vertices, chunk.indices);
			chunk.builtLod = work.lod;
		}
		chunk.separateCollision = separate;
		chunk.builtCollision = separate ? work.collision : true;
	}

	/// Surface normal from the density gradient (points from solid towards empty).
	static Vector3 Gradient(MeshWork work, int x, int y, int z, int step)
	{
		return .(
			(float)work.D(x - step, y, z) - work.D(x + step, y, z),
			(float)work.D(x, y - step, z) - work.D(x, y + step, z),
			(float)work.D(x, y, z - step) - work.D(x, y, z + step));
	}

	/// Marching cubes over cells `step` samples across (1 is full detail).
	void BuildSmooth(Chunk chunk, MeshWork work, int32 step, List<MeshVertex> vertices, List<uint32> indices)
	{
		let size = work.size;
		let origin = work.origin;
		let edgeCache = work.edgeCache;
		Internal.MemSet(edgeCache.Ptr, 0xFF, edgeCache.Count * sizeof(int32));

		int[8] cornerX = default, cornerY = default, cornerZ = default;
		for (int c < 8)
		{
			cornerX[c] = MarchingTables.Corners[c * 3] * step;
			cornerY[c] = MarchingTables.Corners[c * 3 + 1] * step;
			cornerZ[c] = MarchingTables.Corners[c * 3 + 2] * step;
		}

		uint32[12] edgeVertex = default;
		for (int z = 0; z < ChunkCells; z += step)
		{
			for (int y = 0; y < ChunkCells; y += step)
			{
				for (int x = 0; x < ChunkCells; x += step)
				{
					int config = 0;
					for (int c < 8)
					{
						if (work.D(x + cornerX[c], y + cornerY[c], z + cornerZ[c]) <= 0)
							config |= 1 << c;
					}
					let edgeMask = MarchingTables.Edges[config];
					if (edgeMask == 0)
						continue;

					for (int e < 12)
					{
						if ((edgeMask & (1 << e)) == 0)
							continue;
						let a = e & 7;
						let b = MarchingTables.EdgeEnd[e];
						let ax = x + cornerX[a], ay = y + cornerY[a], az = z + cornerZ[a];
						let bx = x + cornerX[b], by = y + cornerY[b], bz = z + cornerZ[b];
						// Each grid edge is shared by up to four cells; cache its vertex by lower corner and axis.
						let lx = Math.Min(ax, bx), ly = Math.Min(ay, by), lz = Math.Min(az, bz);
						let axis = ax != bx ? 0 : (ay != by ? 1 : 2);
						let cacheIndex = SampleIndex(lx, ly, lz) * 3 + axis;
						var vertexIndex = edgeCache[cacheIndex];
						if (vertexIndex < 0)
						{
							let da = (float)work.D(ax, ay, az);
							let db = (float)work.D(bx, by, bz);
							let t = Crossing(da, db);
							let local = Vector3(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t);
							let normal = SafeNormal(Vector3.Lerp(Gradient(work, ax, ay, az, step), Gradient(work, bx, by, bz, step), t));
							let position = origin + local * size;
							vertexIndex = (int32)vertices.Count;
							var color = SurfaceColor(position.y, normal.y);
							if (chunk.paint != null)
							{
								let layer = chunk.paint[t < 0.5f ? SampleIndex(ax, ay, az) : SampleIndex(bx, by, bz)];
								if (layer != 0)
									color = LayerColor(layer);
							}
							vertices.Add(.(position, normal, color.ToABGR(), .(position.x, position.z)));
							edgeCache[cacheIndex] = vertexIndex;
						}
						edgeVertex[e] = (uint32)vertexIndex;
					}

					// The table winds the other way from Tallow's front faces.
					let row = config * 16;
					for (int i = 0; MarchingTables.Triangles[row + i] != -1; i += 3)
					{
						let a = edgeVertex[MarchingTables.Triangles[row + i]];
						let b = edgeVertex[MarchingTables.Triangles[row + i + 1]];
						let c = edgeVertex[MarchingTables.Triangles[row + i + 2]];
						AddTriangle(indices, a, c, b);
					}
				}
			}
		}
	}

	const int32 Pad = 2;
	const int32 PaddedSide = ChunkCells + 1 + Pad * 2;

	/// Fills work.padded: every `step`th sample of the chunk and two more beyond each side, from the chunks around it
	/// (their samples, their sculpting on file, or the generator), with air outside the tiles.
	void FillPadded(Chunk chunk, MeshWork work, int32 step)
	{
		let n = ChunkCells / step;
		let side = n + 1 + Pad * 2;
		let padded = work.padded;
		let missing = work.paddedMissing;
		bool anyMissing = false;
		using (mMonitor.Enter())
		{
			int8*[27] sources = default;
			bool[27] absent = default;
			for (int32 oz = -1; oz <= 1; oz++)
			{
				for (int32 oy = -1; oy <= 1; oy++)
				{
					for (int32 ox = -1; ox <= 1; ox++)
					{
						let slot = (ox + 1) + (oy + 1) * 3 + (oz + 1) * 9;
						if (ox == 0 && oy == 0 && oz == 0)
						{
							sources[slot] = work.center.Ptr;
							continue;
						}
						let other = Int3(chunk.coord.x + ox, chunk.coord.y + oy, chunk.coord.z + oz);
						int8[] source = null;
						if (mChunks.TryGetValue(other, let live) && live.generated && live.density != null)
							source = live.density;
						else if (work.snap.Locate(other, let tileId, let local))
							source = FindSaved(tileId, local)?.density;
						sources[slot] = source != null ? source.Ptr : null;
						absent[slot] = source == null;
					}
				}
			}
			for (int k < side)
			{
				let rz = (k - Pad) * step;
				let oz = rz < 0 ? -1 : (rz > ChunkCells ? 1 : 0);
				for (int j < side)
				{
					let ry = (j - Pad) * step;
					let oy = ry < 0 ? -1 : (ry > ChunkCells ? 1 : 0);
					for (int i < side)
					{
						let rx = (i - Pad) * step;
						let ox = rx < 0 ? -1 : (rx > ChunkCells ? 1 : 0);
						let slot = (ox + 1) + (oy + 1) * 3 + (oz + 1) * 9;
						let at = i + j * side + k * side * side;
						if (absent[slot])
						{
							missing[at] = true;
							anyMissing = true;
							continue;
						}
						missing[at] = false;
						padded[at] = sources[slot][SampleIndex(rx - ox * ChunkCells, ry - oy * ChunkCells, rz - oz * ChunkCells)];
					}
				}
			}
		}
		let snap = work.snap;
		let size = work.size;
		if (anyMissing)
		{
			for (int k < side)
			{
				for (int j < side)
				{
					for (int i < side)
					{
						let at = i + j * side + k * side * side;
						if (!missing[at])
							continue;
						let p = work.origin + Vector3((i - Pad) * step, (j - Pad) * step, (k - Pad) * step) * size;
						padded[at] = Quantize(snap.Density(p.x, p.y, p.z), size);
					}
				}
			}
		}
		if (work.masked)
		{
			for (int k < side)
			{
				for (int i < side)
				{
					if (snap.Inside(work.origin.x + (i - Pad) * step * size, work.origin.z + (k - Pad) * step * size))
						continue;
					for (int j < side)
						padded[i + j * side + k * side * side] = Air;
				}
			}
		}
	}

	/// A normal from an unnormalised direction; straight up when there is no direction to speak of.
	static Vector3 SafeNormal(Vector3 direction)
	{
		let length = direction.Length;
		return length > 0.00001f ? direction * (1.0f / length) : Vector3(0, 1, 0);
	}

	/// How far along an edge from a sample of density `da` to one of `db` the surface (density 0) crosses it.
	static float Crossing(float da, float db) => Math.Abs(da - db) > 0.001f ? Mathf.Clamp01(da / (da - db)) : 0.5f;

	/// The two axes across a grid edge along `axis`, going round it: for X, Y then Z; for Y, Z then X; for Z, X then Y.
	static void AxesAround(int axis, out Int3 u, out Int3 v)
	{
		switch (axis)
		{
		case 0:
			u = .(0, 1, 0);
			v = .(0, 0, 1);
		case 1:
			u = .(0, 0, 1);
			v = .(1, 0, 0);
		default:
			u = .(1, 0, 0);
			v = .(0, 1, 0);
		}
	}

	static void AddTriangle(List<uint32> indices, uint32 a, uint32 b, uint32 c)
	{
		indices.Add(a);
		indices.Add(b);
		indices.Add(c);
	}

	/// Finds the point of a cell that best fits the planes where the surface crosses its edges (a quadratic error
	/// function, as dual contouring calls it).
	struct CellFit
	{
		public Vector3 mass;
		public Vector3 facing;
		public Vector3 right;
		public float a00, a01, a02, a11, a12, a22;
		public int crossings;

		/// One crossing: where it is in the cell (0 to 1 on each axis) and which way the surface faces there.
		public void Add(Vector3 point, Vector3 normal) mut
		{
			mass = mass + point;
			facing = facing + normal;
			let along = Vector3.Dot(normal, point);
			a00 += normal.x * normal.x;
			a01 += normal.x * normal.y;
			a02 += normal.x * normal.z;
			a11 += normal.y * normal.y;
			a12 += normal.y * normal.z;
			a22 += normal.z * normal.z;
			right = right + normal * along;
			crossings++;
		}

		/// The middle of the crossings, moved `sharpness` of the way (0 to 1) to the point nearest every crossing's
		/// plane, which is what keeps corners and ridges sharp.
		public Vector3 Solve(float sharpness)
		{
			let middle = mass * (1.0f / crossings);
			if (sharpness <= 0)
				return middle;
			// Pulled a little towards the middle so that it is always well defined (flat ground has planes that all
			// agree).
			let pull = 0.1f * crossings;
			let m00 = a00 + pull, m11 = a11 + pull, m22 = a22 + pull;
			let rx = right.x + pull * middle.x, ry = right.y + pull * middle.y, rz = right.z + pull * middle.z;
			let c00 = m11 * m22 - a12 * a12, c01 = a02 * a12 - a01 * m22, c02 = a01 * a12 - a02 * m11;
			let det = m00 * c00 + a01 * c01 + a02 * c02;
			if (Math.Abs(det) <= 1.0e-9f)
				return middle;
			let c11 = m00 * m22 - a02 * a02, c12 = a01 * a02 - m00 * a12, c22 = m00 * m11 - a01 * a01;
			var solved = Vector3((c00 * rx + c01 * ry + c02 * rz) / det, (c01 * rx + c11 * ry + c12 * rz) / det, (c02 * rx + c12 * ry + c22 * rz) / det);
			// Kept inside its cell: a point outside would fold the surface over its neighbours.
			solved = .(Mathf.Clamp01(solved.x), Mathf.Clamp01(solved.y), Mathf.Clamp01(solved.z));
			return Vector3.Lerp(middle, solved, sharpness);
		}
	}

	/// Dual contouring over cells `step` samples across. Each cell the surface passes through gets one point, placed
	/// from where the surface crosses the cell's edges and which way it faces there; each grid edge the surface crosses
	/// gets a quad joining the points of the four cells round it. The outermost points belong to cells of the chunks
	/// around this one, which make the same points from the same samples, so chunks meet without a seam.
	void BuildContoured(Chunk chunk, MeshWork work, int32 step, List<MeshVertex> vertices, List<uint32> indices)
	{
		FillPadded(chunk, work, step);
		Internal.MemSet(work.cellVertex.Ptr, 0xFF, work.cellVertex.Count * sizeof(int32));
		PlaceCellPoints(chunk, work, step, vertices);
		JoinCellPoints(work, step, vertices, indices);
	}

	/// A point for every cell the surface passes through (cells -1 to n - 1 along each axis), its vertex index kept
	/// in work.cellVertex.
	void PlaceCellPoints(Chunk chunk, MeshWork work, int32 step, List<MeshVertex> vertices)
	{
		let n = ChunkCells / step;
		let side = n + 1 + Pad * 2;
		let sideY = side, sideZ = side * side;
		let data = work.padded.Ptr;
		let cellSide = n + 1;
		int Corner(int at, int c) => at + (c & 1) + ((c >> 1) & 1) * sideY + ((c >> 2) & 1) * sideZ;
		Vector3 Slope(int at) => .((float)data[at - 1] - data[at + 1], (float)data[at - sideY] - data[at + sideY], (float)data[at - sideZ] - data[at + sideZ]);
		for (int cz = -1; cz < n; cz++)
		{
			for (int cy = -1; cy < n; cy++)
			{
				for (int cx = -1; cx < n; cx++)
				{
					let at = (cx + Pad) + (cy + Pad) * sideY + (cz + Pad) * sideZ;
					float[8] corner = ?;
					int solid = 0;
					for (int c < 8)
					{
						let value = data[Corner(at, c)];
						corner[c] = value;
						if (value > 0)
							solid |= 1 << c;
					}
					if (solid == 0 || solid == 255)
						continue;
					// Where the surface crosses each edge of the cell, and which way it faces there.
					CellFit fit = default;
					for (int axis < 3)
					{
						let bit = 1 << axis;
						for (int c < 8)
						{
							if ((c & bit) != 0)
								continue;
							let d = c | bit;
							if (((solid >> c) & 1) == ((solid >> d) & 1))
								continue;
							let t = Crossing(corner[c], corner[d]);
							var point = Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
							point[axis] = t;
							fit.Add(point, SafeNormal(Vector3.Lerp(Slope(Corner(at, c)), Slope(Corner(at, d)), t)));
						}
					}
					if (fit.crossings == 0)
						continue;
					let point = fit.Solve(mSharpness);
					let normal = SafeNormal(fit.facing);
					let position = work.origin + (Vector3(cx, cy, cz) + point) * (step * work.size);
					var color = SurfaceColor(position.y, normal.y);
					if (chunk.paint != null)
					{
						let layer = chunk.paint[NearestSolidSample(cx, cy, cz, step, solid, point)];
						if (layer != 0)
							color = LayerColor(layer);
					}
					work.cellVertex[(cx + 1) + (cy + 1) * cellSide + (cz + 1) * cellSide * cellSide] = (int32)vertices.Count;
					vertices.Add(.(position, normal, color.ToABGR(), .(position.x, position.z)));
				}
			}
		}
	}

	/// The sample at a cell's solid corner nearest its point, for its paint (corners outside the chunk read its edge).
	static int NearestSolidSample(int cx, int cy, int cz, int32 step, int solid, Vector3 point)
	{
		int best = -1;
		float bestDistance = float.MaxValue;
		for (int c < 8)
		{
			if (((solid >> c) & 1) == 0)
				continue;
			let distance = (Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1) - point).LengthSquared;
			if (distance < bestDistance)
			{
				bestDistance = distance;
				best = c;
			}
		}
		let px = Math.Clamp((cx + (best & 1)) * step, 0, ChunkCells);
		let py = Math.Clamp((cy + ((best >> 1) & 1)) * step, 0, ChunkCells);
		let pz = Math.Clamp((cz + ((best >> 2) & 1)) * step, 0, ChunkCells);
		return SampleIndex(px, py, pz);
	}

	/// A quad across every grid edge the surface crosses, joining the points of the four cells round it (this chunk
	/// owns the edges that start inside it).
	static void JoinCellPoints(MeshWork work, int32 step, List<MeshVertex> vertices, List<uint32> indices)
	{
		let n = ChunkCells / step;
		let side = n + 1 + Pad * 2;
		let sideY = side, sideZ = side * side;
		let data = work.padded.Ptr;
		let cells = work.cellVertex;
		let cellSide = n + 1;
		for (int z < n)
		{
			for (int y < n)
			{
				for (int x < n)
				{
					let at = (x + Pad) + (y + Pad) * sideY + (z + Pad) * sideZ;
					let here = data[at] > 0;
					for (int axis < 3)
					{
						let there = data[at + (axis == 0 ? 1 : (axis == 1 ? sideY : sideZ))] > 0;
						if (here == there)
							continue;
						// The four cells round the edge, going round it: back along both other axes, then each in turn.
						AxesAround(axis, let u, let v);
						int Cell(int dx, int dy, int dz) => cells[(x + dx + 1) + (y + dy + 1) * cellSide + (z + dz + 1) * cellSide * cellSide];
						let q0 = Cell(-u.x - v.x, -u.y - v.y, -u.z - v.z);
						let q1 = Cell(-v.x, -v.y, -v.z);
						let q2 = Cell(0, 0, 0);
						let q3 = Cell(-u.x, -u.y, -u.z);
						if (q0 < 0 || q1 < 0 || q2 < 0 || q3 < 0)
							continue;
						// Split along the shorter diagonal, which keeps the two triangles from being slivers.
						let across = (vertices[q0].position - vertices[q2].position).LengthSquared <= (vertices[q1].position - vertices[q3].position).LengthSquared;
						uint32 a = (uint32)q0, b = (uint32)q1, c = (uint32)q2, d = (uint32)q3;
						// Facing the other way: go round the quad in the other direction.
						if (!here)
							Swap!(b, d);
						if (across)
						{
							AddTriangle(indices, a, b, c);
							AddTriangle(indices, a, c, d);
						}
						else
						{
							AddTriangle(indices, a, b, d);
							AddTriangle(indices, b, c, d);
						}
					}
				}
			}
		}
	}

	/// The key of the edge between two vertices, the same whichever way round they are given.
	static uint64 EdgeKey(uint32 a, uint32 b) => a < b ? ((uint64)a << 32) | b : ((uint64)b << 32) | a;

	/// A strip from the edge between two vertices down into the ground, `depth` along their normals, seen from both
	/// sides.
	static void AddSkirt(List<MeshVertex> vertices, List<uint32> indices, uint32 ia, uint32 ib, float depth)
	{
		var a = vertices[(int)ia];
		var b = vertices[(int)ib];
		a.position -= a.normal * depth;
		b.position -= b.normal * depth;
		let a2 = (uint32)vertices.Count;
		let b2 = a2 + 1;
		vertices.Add(a);
		vertices.Add(b);
		AddTriangle(indices, ia, ib, b2);
		AddTriangle(indices, ia, b2, a2);
		AddTriangle(indices, ia, b2, ib);
		AddTriangle(indices, ia, a2, b2);
	}

	/// Skirts for contoured chunks: a strip down into the ground from every edge of the mesh that only one triangle
	/// uses, which is its rim. Chunks at different detail then meet without gaps showing.
	static void AddOpenEdgeSkirts(float depth, List<MeshVertex> vertices, List<uint32> indices)
	{
		Dictionary<uint64, int32> uses = scope .();
		let triangles = indices.Count / 3;
		for (int t < triangles)
		{
			for (int e < 3)
			{
				let key = EdgeKey(indices[t * 3 + e], indices[t * 3 + (e + 1) % 3]);
				if (uses.TryGetValue(key, let count))
					uses[key] = count + 1;
				else
					uses[key] = 1;
			}
		}
		for (int t < triangles)
		{
			for (int e < 3)
			{
				let ia = indices[t * 3 + e], ib = indices[t * 3 + (e + 1) % 3];
				if (uses[EdgeKey(ia, ib)] == 1)
					AddSkirt(vertices, indices, ia, ib, depth);
			}
		}
	}

	/// Chunks drawn at different detail do not meet exactly along their shared side. A skirt (a strip from the edge of
	/// the surface down into the ground, seen from both sides) on the chunks' sides covers the gap.
	static void AddSkirts(MeshWork work, int32 step, List<MeshVertex> vertices, List<uint32> indices)
	{
		let size = work.size;
		let depth = (2 * step + 1) * size;
		let limit = ChunkCells * size;
		let epsilon = size * 0.001f;
		// Which of the chunk's four sides (bits: -X, +X, -Z, +Z) a vertex lies on.
		int Sides(Vector3 position)
		{
			let p = position - work.origin;
			int sides = 0;
			if (Math.Abs(p.x) < epsilon)
				sides |= 1;
			if (Math.Abs(p.x - limit) < epsilon)
				sides |= 2;
			if (Math.Abs(p.z) < epsilon)
				sides |= 4;
			if (Math.Abs(p.z - limit) < epsilon)
				sides |= 8;
			return sides;
		}
		let triangles = indices.Count / 3;
		for (int t < triangles)
		{
			for (int e < 3)
			{
				let ia = indices[t * 3 + e];
				let ib = indices[t * 3 + (e + 1) % 3];
				if ((Sides(vertices[(int)ia].position) & Sides(vertices[(int)ib].position)) != 0)
					AddSkirt(vertices, indices, ia, ib, depth);
			}
		}
	}

	/// Cubes: a square face between every solid cell and an empty one.
	void BuildBlocky(Chunk chunk, MeshWork work)
	{
		let size = work.size;
		let origin = work.origin;
		// A chunk owns the faces between each of its cells and the next cell along +X, +Y and +Z.
		for (int z < ChunkCells)
		{
			for (int y < ChunkCells)
			{
				for (int x < ChunkCells)
				{
					let solid = work.D(x, y, z) > 0;
					let p = origin + Vector3(x, y, z) * size;
					for (int axis < 3)
					{
						let nx = x + (axis == 0 ? 1 : 0), ny = y + (axis == 1 ? 1 : 0), nz = z + (axis == 2 ? 1 : 0);
						let neighbor = work.D(nx, ny, nz) > 0;
						if (solid == neighbor)
							continue;
						// The face sits on the +axis side of this cell, facing whichever side is empty.
						AxesAround(axis, let across, let up);
						let n = Vector3(axis == 0 ? 1 : 0, axis == 1 ? 1 : 0, axis == 2 ? 1 : 0);
						let u = Vector3(across.x, across.y, across.z);
						let v = Vector3(up.x, up.y, up.z);
						let corner = p + n * size;
						let normal = solid ? n : -n;
						let cellY = solid ? p.y : p.y + (axis == 1 ? size : 0);
						var faceColor = SurfaceColor(cellY, normal.y > 0.5f ? 1.0f : (normal.y < -0.5f ? 0.0f : 0.4f));
						if (chunk.paint != null)
						{
							let layer = chunk.paint[solid ? SampleIndex(x, y, z) : SampleIndex(nx, ny, nz)];
							if (layer != 0)
								faceColor = LayerColor(layer);
						}
						let color = faceColor.ToABGR();
						let first = (uint32)chunk.vertices.Count;
						chunk.vertices.Add(.(corner, normal, color, .(0, 0)));
						chunk.vertices.Add(.(corner + u * size, normal, color, .(1, 0)));
						chunk.vertices.Add(.(corner + (u + v) * size, normal, color, .(1, 1)));
						chunk.vertices.Add(.(corner + v * size, normal, color, .(0, 1)));
						if (solid)
						{
							AddTriangle(chunk.indices, first, first + 1, first + 2);
							AddTriangle(chunk.indices, first, first + 2, first + 3);
						}
						else
						{
							AddTriangle(chunk.indices, first, first + 2, first + 1);
							AddTriangle(chunk.indices, first, first + 3, first + 2);
						}
					}
				}
			}
		}
	}

	void WorkerMain()
	{
		let work = new MeshWork();
		defer delete work;
		while (true)
		{
			Chunk chunk = null;
			using (mMonitor.Enter())
			{
				if (mQuit)
					return;
				if (mJobs.Count > 0)
				{
					chunk = mJobs.PopBack();
					chunk.state = .Working;
					chunk.dirty = false;
					mBusy++;
					TakeJob(chunk, work);
				}
			}
			if (chunk == null)
			{
				mWake.WaitFor(50);
				continue;
			}
			BuildChunk(chunk, work);
			using (mMonitor.Enter())
			{
				chunk.state = .Ready;
				mFinished.Add(chunk);
				mBusy--;
			}
		}
	}

	/// Without worker threads: builds queued chunks on this thread until the time budget is spent (always at least
	/// one, so the terrain keeps coming in on a slow device).
	void BuildInline()
	{
		let start = SDL.SDL_GetTicksNS();
		while (mJobs.Count > 0)
		{
			let chunk = mJobs.PopBack();
			chunk.dirty = false;
			TakeJob(chunk, mInlineWork);
			BuildChunk(chunk, mInlineWork);
			chunk.state = .Ready;
			mFinished.Add(chunk);
			if (SDL.SDL_GetTicksNS() - start > InlineBudgetNs)
				break;
		}
	}

	/// How long a web build spends building terrain chunks each frame.
	const uint64 InlineBudgetNs = 6 * 1000000;
}
