using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Undo and redo of sculpting in the editor, and handing edits over between terrains.
extension VoxelTerrain
{
	/// Starts noting which chunks change, as they were before, until EndEditRecord: one undo step of sculpting.
	public void BeginEditRecord()
	{
		delete mRecording;
		mRecording = new .();
	}

	/// Stops noting and returns what changed (yours to delete), or null if nothing did.
	public EditRecord EndEditRecord()
	{
		let record = mRecording;
		mRecording = null;
		if (record == null)
			return null;
		let snap = mSnap;
		List<Int3> same = scope .();
		for (let entry in record.before)
		{
			let state = Capture(entry.key, snap);
			let was = entry.value;
			bool equal = (state.density == null) == (was.density == null) && (state.paint == null) == (was.paint == null);
			if (equal && state.density != null)
				equal = Internal.MemCmp(state.density.Ptr, was.density.Ptr, SampleCount) == 0;
			if (equal && state.paint != null)
				equal = Internal.MemCmp(state.paint.Ptr, was.paint.Ptr, SampleCount) == 0;
			if (equal)
			{
				delete state;
				same.Add(entry.key);
			}
			else
				record.after[entry.key] = state;
		}
		for (let coord in same)
		{
			if (record.before.GetAndRemove(coord) case .Ok(let entry))
				delete entry.value;
		}
		if (record.before.Count == 0)
		{
			delete record;
			return null;
		}
		return record;
	}

	/// Notes a chunk as it is now, the first time it changes while recording.
	void Record(Int3 coord)
	{
		if (mRecording == null || mRecording.before.ContainsKey(coord))
			return;
		mRecording.before[coord] = Capture(coord, mSnap);
	}

	EditRecord.State Capture(Int3 coord, Snapshot snap)
	{
		let state = new EditRecord.State();
		int8[] density = null;
		uint8[] paint = null;
		if (mChunks.TryGetValue(coord, let chunk) && chunk.generated)
		{
			if (chunk.edited)
			{
				density = chunk.density;
				paint = chunk.paint;
			}
		}
		else if (snap.Locate(coord, let tileId, let local))
		{
			let saved = FindSaved(tileId, local);
			if (saved != null)
			{
				density = saved.density;
				paint = saved.paint;
			}
		}
		if (density != null)
			state.density = Copy(density);
		if (paint != null)
			state.paint = Copy(paint);
		return state;
	}

	/// Puts chunks back as a record had them: before (undo) or after (redo).
	public void ApplyEditRecord(EditRecord record, bool undo)
	{
		let snap = mSnap;
		if (record == null || snap == null)
			return;
		List<Chunk> remesh = scope .();
		using (mMonitor.Enter())
		{
			// Every chunk first, then the meshing: a chunk made again must not read a neighbour's old edge.
			for (let entry in undo ? record.before : record.after)
			{
				let coord = entry.key;
				let state = entry.value;
				if (!snap.Locate(coord, let tileId, let local))
					continue;
				mChunks.TryGetValue(coord, let chunk);
				if (state.density == null)
				{
					RemoveSaved(tileId, local);
					if (chunk != null)
					{
						// Not sculpted: made again from the generator.
						if (chunk.generated)
							chunk.generated = false;
						else
							chunk.stale = true;
						chunk.edited = false;
					}
				}
				else if (chunk != null && chunk.generated)
				{
					state.density.CopyTo(chunk.density);
					if (state.paint != null)
					{
						if (chunk.paint == null)
							chunk.paint = new uint8[SampleCount];
						state.paint.CopyTo(chunk.paint);
					}
					else
						DeleteAndNullify!(chunk.paint);
					chunk.edited = true;
				}
				else
				{
					let saved = new SavedChunk();
					saved.density = Copy(state.density);
					if (state.paint != null)
						saved.paint = Copy(state.paint);
					PutSaved(tileId, local, saved);
					if (chunk != null)
						chunk.stale = true;
				}
				if (chunk != null)
				{
					chunk.shapeChanged = true;
					remesh.Add(chunk);
				}
			}
		}
		for (let chunk in remesh)
			QueueEdited(chunk);
		HasUnsavedEdits = true;
		// Undo and redo move ground anywhere a stroke did: every plant on this terrain finds its footing again, once
		// the chunks that were put back have been made again (OnFrame).
		mFoliageStale = 3;
	}

	/// The sculpting this terrain holds, loaded or not, taken out of it: the editor keeps it while undo makes the
	/// terrain object again, then gives it to the new one with GiveEdits, so sculpting not saved yet is not lost.
	public Object TakeEdits()
	{
		Flush();
		let kept = new KeptEdits();
		using (mMonitor.Enter())
			Swap!(kept.store, mStore);
		kept.unsaved = HasUnsavedEdits;
		return kept;
	}

	public void GiveEdits(Object edits)
	{
		let kept = edits as KeptEdits;
		if (kept == null)
		{
			delete edits;
			return;
		}
		using (mMonitor.Enter())
			Swap!(kept.store, mStore);
		HasUnsavedEdits |= kept.unsaved;
		// What the files say is already in what was given.
		mLoadedFolder.Set(editsFolder);
		mLoadedEdits.Set(editsFile);
		delete kept;
		if (Streaming)
			Regenerate();
	}

	class KeptEdits
	{
		public Dictionary<int32, Dictionary<Int3, SavedChunk>> store = new .() ~ { for (let entry in _) DeleteDictionaryAndValues!(entry.value); delete _; };
		public bool unsaved;
	}
}
