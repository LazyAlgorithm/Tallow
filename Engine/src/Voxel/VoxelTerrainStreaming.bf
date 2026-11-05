using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Streaming, on the main thread: which chunks are wanted around the viewers, queuing them and uploading what the workers finish.
extension VoxelTerrain
{
	/// Where the viewers are, in chunks of the terrain's own space.
	void ViewerChunks(List<Vector2> list)
	{
		let chunkWorld = ChunkCells * mVoxelSize;
		void Add(Vector3 world)
		{
			let local = Transform.InverseTransformPoint(world);
			let p = Vector2(local.x / chunkWorld, local.z / chunkWorld);
			for (let other in list)
			{
				if (Math.Abs(other.x - p.x) < 0.5f && Math.Abs(other.y - p.y) < 0.5f)
					return;
			}
			list.Add(p);
		}
		Add(ViewerPosition);
		for (let viewer in Viewers)
		{
			if (list.Count >= 64)
				break;
			Add(viewer);
		}
	}

	/// The level of detail for a distance in chunks.
	int32 LodFor(float distance)
	{
		if (!mLodOn)
			return 0;
		let d = (float)lodDistance;
		if (distance < d) return 0;
		if (distance < d * 2) return 1;
		if (distance < d * 4) return 2;
		return 3;
	}

	Chunk MakeChunk(Int3 coord, int32 tileId, Int3 local)
	{
		let chunk = new Chunk();
		chunk.coord = coord;
		chunk.tileId = tileId;
		chunk.local = local;
		chunk.state = .Queued;
		using (mMonitor.Enter())
			mChunks[coord] = chunk;
		return chunk;
	}

	/// Puts what the chunks wanted depend on into a list: where the viewers are (to a quarter of a chunk, which the
	/// level of detail's half-chunk give covers), the settings, and how many chunks there are (so a chunk dropped or
	/// added elsewhere is noticed).
	void MakeStreamKey(List<Vector2> viewers, Snapshot snap, List<int32> key)
	{
		key.Clear();
		for (let v in viewers)
		{
			key.Add((int32)Math.Floor(v.x * 4));
			key.Add((int32)Math.Floor(v.y * 4));
		}
		key.Add(viewDistance);
		key.Add(minChunkY);
		key.Add(maxChunkY);
		key.Add(lodDistance);
		key.Add(mLodOn ? 1 : 0);
		key.Add(streamTiles ? 1 : 0);
		key.Add((int32)mode);
		key.Add((int32)mTiles.Count);
		key.Add((int32)mChunks.Count);
		key.Add((int32)(int)Internal.UnsafeCastToPtr(snap));
		key.Add((int32)((uint64)(uint)Internal.UnsafeCastToPtr(snap) >> 32));
	}

	/// Whether the chunks wanted could be different from when UpdateWantedChunks last ran.
	bool WantedChunksMayHaveChanged(List<Vector2> viewers, Snapshot snap)
	{
		if (--mStreamRecheck <= 0)
			return true;
		let key = scope List<int32>();
		MakeStreamKey(viewers, snap, key);
		if (key.Count != mStreamKey.Count)
			return true;
		for (int i < key.Count)
		{
			if (key[i] != mStreamKey[i])
				return true;
		}
		return false;
	}

	/// How far, in chunks, the nearest viewer is from the middle of a chunk's column.
	static float NearestViewer(List<Vector2> viewers, Int3 coord)
	{
		float best = float.MaxValue;
		for (let v in viewers)
		{
			let dx = coord.x + 0.5f - v.x, dz = coord.z + 0.5f - v.y;
			best = Math.Min(best, dx * dx + dz * dz);
		}
		return Math.Sqrt(best);
	}

	/// Whether a chunk's column is within `radius` chunks of a viewer's chunk.
	static bool NearViewer(List<Vector2> viewers, Int3 coord, int32 radius)
	{
		for (let v in viewers)
		{
			let dx = coord.x - (int32)Math.Floor(v.x), dz = coord.z - (int32)Math.Floor(v.y);
			if (dx * dx + dz * dz <= radius * radius)
				return true;
		}
		return false;
	}

	/// Queues the chunks in range that are missing, drops the ones out of range and sets each one's level of detail.
	void UpdateWantedChunks(List<Vector2> viewers, Snapshot snap)
	{
		QueueMissingChunks(viewers, snap);
		DropUnwantedChunks(viewers, snap);
		if (mLodOn)
			UpdateLevelsOfDetail(viewers);
	}

	/// Makes and queues every chunk in range that is not there yet, nearest first.
	void QueueMissingChunks(List<Vector2> viewers, Snapshot snap)
	{
		List<Chunk> added = scope .();
		// A column's chunks; `local` (for a tile's chunk) is the column's place in its tile, or null (endless).
		void Column(int32 x, int32 z, int32 tileId, Int3? local)
		{
			for (int32 cy = minChunkY; cy <= maxChunkY; cy++)
			{
				let coord = Int3(x, cy, z);
				if (!mChunks.ContainsKey(coord))
					added.Add(MakeChunk(coord, tileId, local.HasValue ? Int3(local.Value.x, cy, local.Value.z) : coord));
			}
		}
		if (mode == .Fixed)
		{
			// Every column of every tile (only those near a viewer, when tiles stream).
			let size = snap.tileSize;
			for (let tile in mTiles)
			{
				for (int32 lz < size)
				{
					for (int32 lx < size)
					{
						let column = Int3(tile.x * size + lx, 0, tile.z * size + lz);
						if (!streamTiles || NearViewer(viewers, column, viewDistance))
							Column(column.x, column.z, tile.id, Int3(lx, 0, lz));
					}
				}
			}
		}
		else
		{
			// A circle of columns round each viewer.
			for (let v in viewers)
			{
				let centerX = (int32)Math.Floor(v.x), centerZ = (int32)Math.Floor(v.y);
				for (int32 dz = -viewDistance; dz <= viewDistance; dz++)
				{
					for (int32 dx = -viewDistance; dx <= viewDistance; dx++)
					{
						if (dx * dx + dz * dz <= viewDistance * viewDistance)
							Column(centerX + dx, centerZ + dz, -1, null);
					}
				}
			}
		}
		if (added.Count == 0)
			return;
		for (let chunk in added)
			chunk.lod = LodFor(NearestViewer(viewers, chunk.coord));
		// Jobs are taken from the back, so the nearest go last.
		added.Sort(scope (a, b) => NearestViewer(viewers, b.coord) <=> NearestViewer(viewers, a.coord));
		using (mMonitor.Enter())
		{
			for (let chunk in added)
				mJobs.Add(chunk);
		}
		for (let thread in mThreads)
			mWake.Set(false);
	}

	/// Drops chunks that are no longer wanted: out of range, or of a tile that is not there now.
	void DropUnwantedChunks(List<Vector2> viewers, Snapshot snap)
	{
		let dropDistance = viewDistance + 2;
		List<Chunk> remove = scope .();
		for (let chunk in mChunks.Values)
		{
			bool drop;
			if (mode == .Fixed)
			{
				let tileGone = !snap.Locate(chunk.coord, let tileId, let local) || tileId != chunk.tileId;
				let outOfHeight = chunk.coord.y < minChunkY || chunk.coord.y > maxChunkY;
				drop = tileGone || outOfHeight || (streamTiles && !NearViewer(viewers, chunk.coord, dropDistance));
			}
			else
				drop = chunk.tileId != -1 || !NearViewer(viewers, chunk.coord, dropDistance);
			if (drop)
				remove.Add(chunk);
		}
		if (remove.Count == 0)
			return;
		using (mMonitor.Enter())
		{
			for (let chunk in remove)
				DropChunk(chunk);
		}
	}

	/// Level of detail by distance, with a little give so that a chunk at a boundary does not flicker between two.
	void UpdateLevelsOfDetail(List<Vector2> viewers)
	{
		for (let chunk in mChunks.Values)
		{
			let distance = NearestViewer(viewers, chunk.coord);
			let wanted = LodFor(distance);
			if (wanted == chunk.lod)
				continue;
			if (wanted > chunk.lod ? LodFor(distance - 0.5f) <= chunk.lod : LodFor(distance + 0.5f) >= chunk.lod)
				continue;
			chunk.lod = wanted;
			if (chunk.state == .Uploaded)
				QueueRemesh(chunk);
		}
	}

	public override void OnFrame()
	{
		if (!Streaming)
			return;
		if (mFoliageStale > 0 && PendingChunks == 0 && --mFoliageStale == 0)
			Foliage.GroundChanged(this, .Zero, -1);
		// The mode was changed from code without OnValidate.
		if (mode != mSnap.mode)
			Regenerate();
		let snap = mSnap;
		List<Vector2> viewers = scope .();
		ViewerChunks(viewers);
		// Working out which chunks are wanted looks at every chunk in range, so it is done only when something it
		// depends on has changed, and twice a second in case of anything else.
		if (WantedChunksMayHaveChanged(viewers, snap))
		{
			UpdateWantedChunks(viewers, snap);
			MakeStreamKey(viewers, snap, mStreamKey);
			mStreamRecheck = 30;
		}

		// Free retired chunks once no worker can still be touching them.
		using (mMonitor.Enter())
		{
			for (int i = mGraveyard.Count - 1; i >= 0; i--)
			{
				let chunk = mGraveyard[i];
				if (chunk.state != .Working)
				{
					mFinished.Remove(chunk);
					mGraveyard.RemoveAt(i);
					delete chunk;
				}
			}
			if (mBusy == 0 && mRetired.Count > 0)
				ClearAndDeleteItems!(mRetired);
		}

		if (mInline)
			BuildInline();

		// Upload finished meshes within the frame budget.
		for (int i < Math.Max(uploadsPerFrame, 1))
		{
			Chunk chunk = null;
			using (mMonitor.Enter())
			{
				if (mFinished.Count > 0)
				{
					chunk = mFinished[0];
					mFinished.RemoveAt(0);
				}
			}
			if (chunk == null)
				break;
			if (chunk.cancelled)
				continue;
			if (chunk.stale)
			{
				chunk.stale = false;
				chunk.generated = false;
				chunk.state = .Uploaded;
				QueueRemesh(chunk);
				continue;
			}
			UploadChunk(chunk);
			// A chunk that streamed in after shared brush strokes were made gets them now.
			if (chunk.generated && chunk.appliedBrushes < mSessionBrushes.Count)
				CatchUp(chunk);
			if (chunk.dirty || chunk.lod != chunk.builtLod)
				QueueRemesh(chunk);
		}
	}

	void RetireObject(Chunk chunk)
	{
		if (chunk.gameObject == null)
			return;
		let renderer = chunk.gameObject.GetComponent<MeshRenderer>();
		if (renderer)
			renderer.RuntimeMesh = null;
		let collider = chunk.gameObject.GetComponent<MeshCollider>();
		if (collider != null)
			collider.CollisionMesh = null;
		Scene.Destroy(chunk.gameObject);
		chunk.gameObject = null;
	}

	void UploadChunk(Chunk chunk)
	{
		chunk.state = .Uploaded;
		let separate = chunk.separateCollision;
		if (chunk.builtCollision && separate)
		{
			if (chunk.collisionMesh == null)
				chunk.collisionMesh = new Mesh();
			Swap!(chunk.collisionMesh.Vertices, chunk.collisionVertices);
			Swap!(chunk.collisionMesh.Indices, chunk.collisionIndices);
		}
		if (chunk.indices.Count == 0)
		{
			if (chunk.gameObject != null)
				chunk.gameObject.SetActive(false);
			return;
		}
		if (chunk.mesh == null)
			chunk.mesh = new Mesh();
		Swap!(chunk.mesh.Vertices, chunk.vertices);
		Swap!(chunk.mesh.Indices, chunk.indices);
		chunk.mesh.Upload();

		if (chunk.gameObject == null)
		{
			chunk.gameObject = Scene.CreateGameObject("VoxelChunk", Transform);
			chunk.gameObject.Transient = true;
			let renderer = chunk.gameObject.AddComponent<MeshRenderer>();
			renderer.RuntimeMesh = chunk.mesh;
			renderer.flatShading = mFlat;
			renderer.roughness = 0.95f;
			if (mColliders)
				chunk.gameObject.AddComponent<MeshCollider>().CollisionMesh = separate ? chunk.collisionMesh : null;
		}
		else
		{
			chunk.gameObject.SetActive(true);
			let drawn = chunk.gameObject.GetComponent<MeshRenderer>();
			if (drawn)
				drawn.flatShading = mFlat;
			// Rebuild the collision for the new surface (not when only the drawing detail changed).
			let collider = chunk.gameObject.GetComponent<MeshCollider>();
			if (collider != null && chunk.builtCollision)
			{
				collider.CollisionMesh = separate ? chunk.collisionMesh : null;
				collider.Refresh();
			}
		}
	}

	/// A chunk whose samples changed. Contoured ground places the points of a chunk's outermost cells from samples
	/// up to two steps inside the chunks around it, so those are built again too and the edges go on meeting.
	void QueueEdited(Chunk chunk)
	{
		QueueRemesh(chunk);
		if (mStyle != .Contoured)
			return;
		for (int32 dz = -1; dz <= 1; dz++)
		{
			for (int32 dy = -1; dy <= 1; dy++)
			{
				for (int32 dx = -1; dx <= 1; dx++)
				{
					if (dx == 0 && dy == 0 && dz == 0)
						continue;
					if (mChunks.TryGetValue(.(chunk.coord.x + dx, chunk.coord.y + dy, chunk.coord.z + dz), let near) && near.generated)
					{
						near.shapeChanged = true;
						QueueRemesh(near);
					}
				}
			}
		}
	}

	void QueueRemesh(Chunk chunk)
	{
		using (mMonitor.Enter())
		{
			if (chunk.state == .Working || chunk.state == .Ready)
			{
				// A worker is on it, or its result is waiting for upload: redo afterwards.
				chunk.dirty = true;
				return;
			}
			if (chunk.state == .Queued)
				return;
			chunk.dirty = false;
			chunk.state = .Queued;
			mJobs.Add(chunk);
		}
		mWake.Set(false);
	}
}
