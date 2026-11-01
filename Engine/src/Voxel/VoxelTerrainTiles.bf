using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// The terrain's tiles (Fixed mode): which squares of the world it covers, and reading and writing their list.
extension VoxelTerrain
{
	/// The size of a tile in metres along X and Z.
	public float TileWorldSize => Math.Clamp(tileSize, 1, 64) * ChunkCells * Math.Max(voxelSize, 0.05f);

	public int32 TileCount
	{
		get
		{
			if (mSnap == null)
				ApplyTilesText();
			return (int32)mTiles.Count;
		}
	}

	/// Adds every tile to the list.
	public void GetTiles(List<TerrainTile> list)
	{
		if (mSnap == null)
			ApplyTilesText();
		list.AddRange(mTiles);
	}

	/// The id of the tile at a place in the grid, or 0 where there is none.
	public int32 TileAt(int32 x, int32 z)
	{
		if (mSnap == null)
			ApplyTilesText();
		for (let tile in mTiles)
		{
			if (tile.x == x && tile.z == z)
				return tile.id;
		}
		return 0;
	}

	public bool FindTile(int32 id, out TerrainTile tile)
	{
		if (mSnap == null)
			ApplyTilesText();
		for (let t in mTiles)
		{
			if (t.id == id)
			{
				tile = t;
				return true;
			}
		}
		tile = default;
		return false;
	}

	/// The grid place under a point in world space (on the terrain's ground plane).
	public void TileOfPoint(Vector3 world, out int32 x, out int32 z)
	{
		let local = Transform.InverseTransformPoint(world);
		let w = TileWorldSize;
		x = (int32)Math.Floor(local.x / w);
		z = (int32)Math.Floor(local.z / w);
	}

	/// Adds a flat tile at a place in the grid. Returns its id, or 0 if the place is taken.
	public int32 AddTile(int32 x, int32 z)
	{
		if (TileAt(x, z) != 0)
			return 0;
		int32 id = nextTileId;
		for (let tile in mTiles)
			id = Math.Max(id, tile.id + 1);
		nextTileId = id + 1;
		using (mMonitor.Enter())
		{
			// A tile made after an undone one can be given its id: it starts flat all the same.
			if (mStore.GetAndRemove(id) case .Ok(let old))
				DeleteDictionaryAndValues!(old.value);
		}
		let list = scope List<TerrainTile>(mTiles);
		list.Add(.(id, x, z));
		SetTiles(list);
		return id;
	}

	/// Takes a tile away, leaving a hole. Its sculpting is kept until the scene is saved, so undo can bring it back.
	public bool RemoveTile(int32 id)
	{
		let list = scope List<TerrainTile>(mTiles);
		for (int i < list.Count)
		{
			if (list[i].id == id)
			{
				list.RemoveAt(i);
				SetTiles(list);
				return true;
			}
		}
		return false;
	}

	/// Moves a tile, with its sculpting, to an empty place in the grid.
	public bool MoveTile(int32 id, int32 x, int32 z)
	{
		let other = TileAt(x, z);
		if (other != 0)
			return other == id;
		let list = scope List<TerrainTile>(mTiles);
		for (int i < list.Count)
		{
			if (list[i].id == id)
			{
				list[i].x = x;
				list[i].z = z;
				SetTiles(list);
				return true;
			}
		}
		return false;
	}

	/// Replaces the whole set of tiles. Tiles keep their sculpting by id, wherever they are.
	public void SetTiles(Span<TerrainTile> newTiles)
	{
		if (mSnap == null)
			ApplyTilesText();
		let text = scope String();
		int32 highest = 0;
		for (let tile in newTiles)
		{
			if (!text.IsEmpty)
				text.Append(';');
			text.AppendF("{} {} {}", tile.id, tile.x, tile.z);
			highest = Math.Max(highest, tile.id);
		}
		tiles.Set(text);
		nextTileId = Math.Max(nextTileId, highest + 1);
		ApplyTilesText();
		HasUnsavedEdits = true;
	}

	/// The tiles as `tiles` (or, while that is empty, sizeX and sizeZ) say, put into effect.
	void ApplyTilesText()
	{
		let list = scope List<TerrainTile>();
		if (!tiles.IsEmpty)
			ParseTiles(tiles, list);
		else
			TilesFromRectangle(list);
		mAppliedTiles.Set(tiles);
		mAppliedSizeX = sizeX;
		mAppliedSizeZ = sizeZ;
		mAppliedTileSize = tileSize;

		if (mSnap == null)
		{
			mTiles.Set(list);
			return;
		}

		// What moved or went: their chunks are put away under their tile first, then the new layout takes over.
		HashSet<int32> gone = scope .();
		List<TerrainTile> changed = scope .();
		CompareTiles(mTiles, list, gone, changed);
		if (changed.Count == 0)
		{
			mTiles.Set(list);
			return;
		}
		using (mMonitor.Enter())
		{
			List<Chunk> drop = scope .();
			for (let chunk in mChunks.Values)
			{
				if (gone.Contains(chunk.tileId))
					drop.Add(chunk);
			}
			for (let chunk in drop)
				DropChunk(chunk);
		}
		mTiles.Set(list);
		CaptureSettings();
		// Chunks along the changed tiles' edges now end (or no longer end) there.
		let size = Math.Clamp(tileSize, 1, 64);
		for (let chunk in mChunks.Values)
		{
			for (let tile in changed)
			{
				if (chunk.coord.x >= tile.x * size - 1 && chunk.coord.x <= (tile.x + 1) * size && chunk.coord.z >= tile.z * size - 1 && chunk.coord.z <= (tile.z + 1) * size)
				{
					chunk.shapeChanged = true;
					QueueRemesh(chunk);
					break;
				}
			}
		}
	}

	/// "id x z;id x z;...": tiles with an id of 0 or less, or an id or place already taken, are left out.
	static void ParseTiles(StringView text, List<TerrainTile> list)
	{
		for (let entry in text.Split(';'))
		{
			var parts = entry.Split(' ', .RemoveEmptyEntries);
			let id = int32.Parse(parts.GetNext().GetValueOrDefault()).GetValueOrDefault();
			let x = int32.Parse(parts.GetNext().GetValueOrDefault()).GetValueOrDefault();
			let z = int32.Parse(parts.GetNext().GetValueOrDefault()).GetValueOrDefault();
			if (id <= 0)
				continue;
			bool taken = false;
			for (let tile in list)
				taken |= tile.id == id || (tile.x == x && tile.z == z);
			if (!taken)
				list.Add(.(id, x, z));
		}
	}

	/// A rectangle of chunks from before tiles (sizeX by sizeZ): tiles as big as fit it exactly, numbered by place.
	void TilesFromRectangle(List<TerrainTile> list)
	{
		let sx = Math.Clamp(sizeX, 1, 256), sz = Math.Clamp(sizeZ, 1, 256);
		var size = Math.Clamp(tileSize, 1, 64);
		if (sx % size != 0 || sz % size != 0)
		{
			// The largest size that divides both sides.
			int32 a = sx, b = sz;
			while (b != 0)
			{
				let r = a % b;
				a = b;
				b = r;
			}
			size = Math.Min(a, 64);
			tileSize = size;
		}
		for (int32 z < sz / size)
		{
			for (int32 x < sx / size)
				list.Add(.(1 + x + z * 256, x, z));
		}
	}

	/// The tiles that went or moved (`gone` has their ids), and every tile whose place changed, old and new.
	static void CompareTiles(List<TerrainTile> before, List<TerrainTile> after, HashSet<int32> gone, List<TerrainTile> changed)
	{
		Dictionary<int32, TerrainTile> byId = scope .();
		for (let tile in before)
			byId[tile.id] = tile;
		for (let tile in before)
		{
			bool kept = false;
			for (let now in after)
			{
				if (now.id == tile.id)
				{
					kept = now.x == tile.x && now.z == tile.z;
					break;
				}
			}
			if (!kept)
			{
				gone.Add(tile.id);
				changed.Add(tile);
			}
		}
		for (let tile in after)
		{
			if (!byId.TryGetValue(tile.id, let old) || old.x != tile.x || old.z != tile.z)
				changed.Add(tile);
		}
	}

	/// Writes the tiles out to `tiles`, if they still come from the old rectangle.
	void WriteTilesOut()
	{
		if (!tiles.IsEmpty || mode != .Fixed)
			return;
		if (mSnap == null)
			ApplyTilesText();
		let list = scope List<TerrainTile>(mTiles);
		SetTiles(list);
	}
}
