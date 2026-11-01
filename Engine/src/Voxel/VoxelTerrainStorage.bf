using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Sculpting kept per tile: the chunks changed by hand, held in memory and written to the tile files.
extension VoxelTerrain
{
	SavedChunk FindSaved(int32 tileId, Int3 local)
	{
		if (mStore.TryGetValue(tileId, let chunks) && chunks.TryGetValue(local, let saved))
			return saved;
		return null;
	}

	/// Files a chunk's sculpting, replacing what was there. Call with mMonitor held.
	void PutSaved(int32 tileId, Int3 local, SavedChunk saved)
	{
		Dictionary<Int3, SavedChunk> chunks;
		if (!mStore.TryGetValue(tileId, out chunks))
		{
			chunks = new .();
			mStore[tileId] = chunks;
		}
		if (chunks.TryGetValue(local, let old))
			delete old;
		chunks[local] = saved;
	}

	void RemoveSaved(int32 tileId, Int3 local)
	{
		if (mStore.TryGetValue(tileId, let chunks) && chunks.GetAndRemove(local) case .Ok(let entry))
			delete entry.value;
	}

	/// Keeps an edited chunk's data, for when the chunk itself is unloaded or saved. Call with mMonitor held.
	void Stash(Chunk chunk)
	{
		if (!chunk.edited || chunk.density == null || !chunk.generated)
			return;
		let saved = new SavedChunk();
		saved.density = new int8[SampleCount];
		chunk.density.CopyTo(saved.density);
		if (chunk.paint != null)
		{
			saved.paint = new uint8[SampleCount];
			chunk.paint.CopyTo(saved.paint);
		}
		saved.appliedBrushes = chunk.appliedBrushes;
		PutSaved(chunk.tileId, chunk.local, saved);
	}

	/// Files the sculpting of every loaded chunk.
	void Flush()
	{
		using (mMonitor.Enter())
		{
			for (let chunk in mChunks.Values)
				Stash(chunk);
		}
	}

	/// Takes a chunk out of the terrain, keeping its sculpting. Call with mMonitor held.
	void DropChunk(Chunk chunk)
	{
		mChunks.Remove(chunk.coord);
		mJobs.Remove(chunk);
		mFinished.Remove(chunk);
		chunk.cancelled = true;
		Stash(chunk);
		RetireObject(chunk);
		mGraveyard.Add(chunk);
	}

	/// Reads the sculpting files named in the fields, if that has not happened yet (a terrain made in code, or one
	/// saved before it was ever validated): saving must not write over what it never read.
	void EnsureEditsRead()
	{
		if (mSnap == null)
		{
			ApplyTilesText();
			CaptureSettings();
		}
		if (!editsFile.IsEmpty && mLoadedEdits != editsFile)
		{
			mLoadedEdits.Set(editsFile);
			let path = scope String();
			Assets.ResolvePath(editsFile, path);
			if (LoadEdits(path) && Streaming)
				Regenerate();
		}
		if (!editsFolder.IsEmpty && mLoadedFolder != editsFolder)
		{
			mLoadedFolder.Set(editsFolder);
			if (LoadEditFolder() && Streaming)
				Regenerate();
		}
	}

	public override void OnBeforeSave()
	{
		EnsureEditsRead();
		let legacy = !editsFile.IsEmpty;
		WriteTilesOut();
		if (!HasUnsavedEdits && !legacy)
			return;
		Flush();
		bool any = false;
		using (mMonitor.Enter())
		{
			for (let entry in mStore)
				any |= entry.value.Count > 0;
		}
		if (editsFolder.IsEmpty && !any)
		{
			// Nothing sculpted: no files.
			HasUnsavedEdits = false;
			editsFile.Clear();
			mLoadedEdits.Clear();
			return;
		}
		if (editsFolder.IsEmpty)
			editsFolder.AppendF("Scenes/{}_{}.terrain", Scene.Name, GameObject.Id);
		mLoadedFolder.Set(editsFolder);
		let path = scope String();
		Assets.ResolvePath(editsFolder, path);
		if (WriteEditFolder(path))
		{
			HasUnsavedEdits = false;
			editsFile.Clear();
			mLoadedEdits.Clear();
		}
	}

	static void TileFileName(int32 tileId, String name)
	{
		if (tileId < 0)
			name.Append("endless.voxels");
		else
			name.AppendF("tile_{}.voxels", tileId);
	}

	/// Writes a file for each tile with sculpting, and removes the files of tiles that are gone.
	public bool WriteEditFolder(StringView folder)
	{
		Flush();
		Directory.CreateDirectory(folder).IgnoreError();
		if (!Directory.Exists(folder))
		{
			Log.Error(scope $"Could not make the terrain folder {folder}");
			return false;
		}
		HashSet<String> keep = scope .();
		defer
		{
			for (let name in keep)
				delete name;
		}
		bool ok = true;
		List<int32> ids = scope .();
		for (let tile in mTiles)
			ids.Add(tile.id);
		if (mode == .Endless)
			ids.Add(-1);
		for (let id in ids)
		{
			List<uint8> data = scope .();
			using (mMonitor.Enter())
			{
				if (!mStore.TryGetValue(id, let chunks) || chunks.Count == 0)
					continue;
				EncodeTile(id, chunks, data);
			}
			let name = new String();
			TileFileName(id, name);
			keep.Add(name);
			if (File.WriteAll(scope $"{folder}/{name}" , data) case .Err)
			{
				Log.Error(scope $"Could not write terrain sculpting to {folder}/{name}");
				ok = false;
			}
		}
		for (let entry in Directory.EnumerateFiles(folder, "*.voxels"))
		{
			let name = entry.GetFileName(.. scope .());
			if (!keep.Contains(name))
				File.Delete(entry.GetFilePath(.. scope .())).IgnoreError();
		}
		return ok;
	}

	/// Reads the file of every tile from editsFolder. Returns true when anything was loaded.
	bool LoadEditFolder()
	{
		let folder = scope String();
		Assets.ResolvePath(editsFolder, folder);
		bool any = false;
		List<int32> ids = scope .();
		for (let tile in mTiles)
			ids.Add(tile.id);
		ids.Add(-1);
		for (let id in ids)
		{
			let name = scope String();
			TileFileName(id, name);
			List<uint8> data = scope .();
			if (AssetPack.ReadAll(scope $"{folder}/{name}" , data) case .Err)
				continue;
			if (!DecodeTile(Span<uint8>(data.Ptr, data.Count)))
				Log.Warning(scope $"{folder}/{name} is not a terrain sculpting file this version can read.");
			else
				any = true;
		}
		return any;
	}

	const uint32 FileMagic = 0x584f5654; // "TVOX"

	static void Put<T>(List<uint8> data, T value) where T : struct
	{
		var v = value;
		let start = data.Count;
		data.Count += sizeof(T);
		Internal.MemCpy(data.Ptr + start, &v, sizeof(T));
	}

	static void PutChunk(List<uint8> data, Int3 coord, int8[] density, uint8[] paint)
	{
		Put(data, coord.x);
		Put(data, coord.y);
		Put(data, coord.z);
		Put(data, (uint8)(paint != null ? 1 : 0));
		var start = data.Count;
		data.Count += SampleCount;
		Internal.MemCpy(data.Ptr + start, density.Ptr, SampleCount);
		if (paint != null)
		{
			start = data.Count;
			data.Count += SampleCount;
			Internal.MemCpy(data.Ptr + start, paint.Ptr, SampleCount);
		}
	}

	/// One tile's file: "TVOX", version 2, samples per side, the tile id, then its chunks by their place in the tile.
	static void EncodeTile(int32 tileId, Dictionary<Int3, SavedChunk> chunks, List<uint8> data)
	{
		Put(data, FileMagic);
		Put(data, (int32)2);
		Put(data, (int32)Samples);
		Put(data, tileId);
		Put(data, (int32)chunks.Count);
		for (let entry in chunks)
			PutChunk(data, entry.key, entry.value.density, entry.value.paint);
	}

	/// Reads chunks written by PutChunk, from offset on; calls back for each.
	static int ReadChunks(Span<uint8> data, int start, int32 count, delegate void(Int3 coord, SavedChunk saved) take)
	{
		var offset = start;
		for (int i < count)
		{
			if (offset + 13 + SampleCount > data.Length)
				break;
			Int3 coord = .(0, 0, 0);
			Internal.MemCpy(&coord, data.Ptr + offset, 12);
			let hasPaint = data[offset + 12] != 0;
			offset += 13;
			let saved = new SavedChunk();
			saved.density = new int8[SampleCount];
			Internal.MemCpy(saved.density.Ptr, data.Ptr + offset, SampleCount);
			offset += SampleCount;
			if (hasPaint && offset + SampleCount <= data.Length)
			{
				saved.paint = new uint8[SampleCount];
				Internal.MemCpy(saved.paint.Ptr, data.Ptr + offset, SampleCount);
				offset += SampleCount;
			}
			take(coord, saved);
		}
		return offset;
	}

	bool DecodeTile(Span<uint8> data)
	{
		if (data.Length < 20)
			return false;
		var reader = NetReader(data.Ptr, data.Length);
		if (reader.Read<uint32>() != FileMagic || reader.Read<int32>() != 2 || reader.Read<int32>() != Samples)
			return false;
		let tileId = reader.Read<int32>();
		let count = reader.Read<int32>();
		using (mMonitor.Enter())
		{
			if (mStore.GetAndRemove(tileId) case .Ok(let old))
				DeleteDictionaryAndValues!(old.value);
			ReadChunks(data, 20, count, scope (coord, saved) => PutSaved(tileId, coord, saved));
		}
		return true;
	}

	/// Writes every sculpted or painted chunk to one file (the format from before tiles, which LoadEdits reads).
	public bool SaveEdits(StringView path)
	{
		List<uint8> data = scope .();
		SaveEdits(data);
		if (File.WriteAll(path, data) case .Err)
		{
			Log.Error(scope $"Could not write terrain edits to {path}");
			return false;
		}
		return true;
	}

	/// The same as bytes, for a game that keeps its terrain somewhere of its own (inside a map file, say). Chunks are
	/// stored by where they are, not by tile. Returns how many chunks were written.
	public int32 SaveEdits(List<uint8> data)
	{
		if (mSnap == null)
			ApplyTilesText();
		Flush();
		let size = Math.Clamp(tileSize, 1, 64);
		int32 count = 0;
		List<uint8> body = scope .();
		using (mMonitor.Enter())
		{
			if (mode == .Endless)
			{
				if (mStore.TryGetValue(-1, let chunks))
				{
					for (let entry in chunks)
					{
						PutChunk(body, entry.key, entry.value.density, entry.value.paint);
						count++;
					}
				}
			}
			else for (let tile in mTiles)
				{
					if (!mStore.TryGetValue(tile.id, let chunks))
						continue;
					for (let entry in chunks)
					{
						PutChunk(body, .(entry.key.x + tile.x * size, entry.key.y, entry.key.z + tile.z * size), entry.value.density, entry.value.paint);
						count++;
					}
				}
		}
		Put(data, FileMagic);
		Put(data, (int32)1);
		Put(data, (int32)Samples);
		Put(data, count);
		data.AddRange(body);
		return count;
	}

	/// Reads edited chunks from a file that SaveEdits(path) wrote. Returns true when anything was loaded.
	public bool LoadEdits(StringView path)
	{
		List<uint8> data = scope .();
		if (AssetPack.ReadAll(path, data) case .Err)
			return false;
		if (!LoadEdits(Span<uint8>(data.Ptr, data.Count)))
		{
			if (data.Count < 16 || *(uint32*)data.Ptr != FileMagic)
				Log.Warning(scope $"{path} is not a compatible terrain edit file.");
			return false;
		}
		return true;
	}

	/// Takes edited chunks from bytes that SaveEdits wrote, in place of all the sculpting the terrain had: each goes
	/// to the tile where it is. Call Regenerate afterwards for a terrain that is already there. Returns true when
	/// anything was loaded.
	public bool LoadEdits(Span<uint8> data)
	{
		if (data.Length < 16)
			return false;
		var reader = NetReader(data.Ptr, data.Length);
		if (reader.Read<uint32>() != FileMagic || reader.Read<int32>() != 1 || reader.Read<int32>() != Samples)
			return false;
		let count = reader.Read<int32>();
		if (mSnap == null)
		{
			ApplyTilesText();
			CaptureSettings();
		}
		let snap = mSnap;
		bool any = false;
		using (mMonitor.Enter())
		{
			for (let entry in mStore)
				DeleteDictionaryAndValues!(entry.value);
			mStore.Clear();
			ReadChunks(data, 16, count, scope [&] (coord, saved) =>
				{
					if (snap.Locate(coord, let tileId, let local))
					{
						PutSaved(tileId, local, saved);
						any = true;
					}
					else
						delete saved;
				});
		}
		return any;
	}

	/// Throws away every loaded chunk and makes the terrain again from the settings and the sculpting.
	public void Regenerate()
	{
		if (mAppliedTiles != tiles || (tiles.IsEmpty && (mAppliedSizeX != sizeX || mAppliedSizeZ != sizeZ)))
			ApplyTilesText();
		CaptureSettings();
		using (mMonitor.Enter())
		{
			mJobs.Clear();
			for (let chunk in mChunks.Values)
			{
				chunk.cancelled = true;
				Stash(chunk);
				RetireObject(chunk);
				mGraveyard.Add(chunk);
			}
			mChunks.Clear();
			mFinished.Clear();
		}
	}
}
