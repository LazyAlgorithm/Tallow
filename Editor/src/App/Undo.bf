using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// One step of undo history: the scene as text on the other side of the step, or terrain sculpting before and after.
class UndoStep
{
	public String scene ~ delete _;
	public uint32 terrainObject;
	public VoxelTerrain.EditRecord terrain ~ delete _;
}

/// Undo and redo for scene edits. Each scene step is a saved copy of the scene; applying one only rebuilds the
/// objects that differ, so untouched objects (and streamed terrain) stay as they are. Terrain sculpting and painting
/// are steps of their own, holding just the chunks a stroke changed; adding, moving and removing terrain tiles are
/// scene steps that the terrain takes in place.
extension EditorApp
{
	const int MaxUndo = 64;

	List<UndoStep> mUndoStack = new .() ~ DeleteContainerAndItems!(_);
	List<UndoStep> mRedoStack = new .() ~ DeleteContainerAndItems!(_);
	String mBaseline = new .() ~ delete _;
	bool mUndoPending;

	bool CanUndo => mUndoStack.Count > 0 && mPlay == .Edit;
	bool CanRedo => mRedoStack.Count > 0 && mPlay == .Edit;

	void ResetUndo()
	{
		ClearAndDeleteItems!(mUndoStack);
		ClearAndDeleteItems!(mRedoStack);
		mBaseline.Clear();
		Foliage.SyncAll(mScene);
		SceneSerializer.Save(mScene, mBaseline);
		mUndoPending = false;
	}

	void PushUndo(UndoStep step)
	{
		mUndoStack.Add(step);
		if (mUndoStack.Count > MaxUndo)
		{
			delete mUndoStack[0];
			mUndoStack.RemoveAt(0);
		}
		ClearAndDeleteItems!(mRedoStack);
	}

	/// Records sculpting (from VoxelTerrain.EndEditRecord) as an undo step, after any scene change before it.
	void PushTerrainUndo(VoxelTerrain terrain, VoxelTerrain.EditRecord record)
	{
		if (record == null)
			return;
		if (mPlay != .Edit)
		{
			delete record;
			return;
		}
		if (mUndoPending)
		{
			// Scene changes made before the stroke come first.
			mUndoPending = false;
			CommitSceneStep();
		}
		let step = new UndoStep();
		step.terrainObject = terrain.GameObject.Id;
		step.terrain = record;
		PushUndo(step);
	}

	/// Records a step once the user lets go, so a whole drag or text edit is one entry.
	void CommitUndoWhenIdle()
	{
		if (!mUndoPending || mPlay != .Edit || ImGui.IsAnyItemActive() || ImGui.IsMouseDown(0))
			return;
		mUndoPending = false;
		CommitSceneStep();
	}

	void CommitSceneStep()
	{
		let current = new String();
		Foliage.SyncAll(mScene);
		SceneSerializer.Save(mScene, current);
		if (current == mBaseline)
		{
			delete current;
			return;
		}
		let step = new UndoStep();
		step.scene = new String(mBaseline);
		PushUndo(step);
		mBaseline.Set(current);
		delete current;
	}

	VoxelTerrain TerrainOfStep(UndoStep step) => mScene.FindById(step.terrainObject)?.GetComponent<VoxelTerrain>();

	void Undo()
	{
		CommitUndoWhenIdle();
		if (!CanUndo)
			return;
		let step = mUndoStack.PopBack();
		if (step.terrain != null)
		{
			TerrainOfStep(step)?.ApplyEditRecord(step.terrain, true);
			mRedoStack.Add(step);
		}
		else
		{
			let target = step.scene;
			step.scene = new String(mBaseline);
			mRedoStack.Add(step);
			ApplySnapshot(mBaseline, target);
			mBaseline.Set(target);
			delete target;
		}
		mDirty = true;
	}

	void Redo()
	{
		if (!CanRedo)
			return;
		let step = mRedoStack.PopBack();
		if (step.terrain != null)
		{
			TerrainOfStep(step)?.ApplyEditRecord(step.terrain, false);
			mUndoStack.Add(step);
		}
		else
		{
			let target = step.scene;
			step.scene = new String(mBaseline);
			mUndoStack.Add(step);
			ApplySnapshot(mBaseline, target);
			mBaseline.Set(target);
			delete target;
		}
		mDirty = true;
	}

	struct Block
	{
		public uint32 id;
		public uint32 parent;
		public StringView text;
	}

	/// Splits serialized scene text into one block per object.
	static void SplitBlocks(StringView text, List<Block> blocks)
	{
		int start = -1;
		Block current = default;
		int offset = 0;
		void Close(int end)
		{
			if (start >= 0)
			{
				current.text = text.Substring(start, end - start);
				blocks.Add(current);
			}
		}
		for (let line in text.Split('\n'))
		{
			if (line.StartsWith("object "))
			{
				Close(offset);
				start = offset;
				var parts = line.Split(' ');
				parts.GetNext();
				current.id = (uint32)SceneSerializer.ParseInt(parts.GetNext().GetValueOrDefault());
				parts.GetNext();
				current.parent = (uint32)SceneSerializer.ParseInt(parts.GetNext().GetValueOrDefault());
			}
			offset += line.Length + 1;
		}
		Close(Math.Min(offset, text.Length));
	}

	void ApplySnapshot(StringView from, StringView to)
	{
		List<Block> before = scope .();
		List<Block> after = scope .();
		SplitBlocks(from, before);
		SplitBlocks(to, after);
		Dictionary<uint32, StringView> beforeById = scope .();
		for (let block in before)
			beforeById[block.id] = block.text;

		// Objects that differ, plus everything beneath them (children are destroyed with a parent).
		HashSet<uint32> rebuild = scope .();
		HashSet<uint32> afterIds = scope .();
		for (let block in after)
		{
			afterIds.Add(block.id);
			if (!beforeById.TryGetValue(block.id, let old) || old != block.text)
			{
				// A terrain whose tiles are all that changed takes them in place, keeping what it has loaded; so does
				// an object whose painted plants are all that changed (which is often the terrain too).
				if (old.Ptr != null && TilesOnlyChange(block.id, old, block.text))
					continue;
				rebuild.Add(block.id);
			}
		}
		bool grew = true;
		while (grew)
		{
			grew = false;
			for (let block in after)
			{
				if (block.parent != 0 && rebuild.Contains(block.parent) && rebuild.Add(block.id))
					grew = true;
			}
		}

		// Terrains made again keep the sculpting that is not saved yet.
		Dictionary<uint32, Object> keptEdits = scope .();
		defer
		{
			for (let entry in keptEdits)
				delete entry.value;
		}
		for (let block in before)
		{
			if (afterIds.Contains(block.id) && !rebuild.Contains(block.id))
				continue;
			let existing = mScene.FindById(block.id);
			if (existing != null)
			{
				let terrain = existing.GetComponent<VoxelTerrain>();
				if (terrain != null)
					keptEdits[block.id] = terrain.TakeEdits();
				mScene.DestroyImmediate(existing);
			}
		}
		let text = scope String();
		for (let block in after)
		{
			if (rebuild.Contains(block.id))
				text.Append(block.text);
		}
		if (!text.IsEmpty)
			SceneSerializer.LoadObjects(mScene, text);
		List<uint32> given = scope .();
		for (let entry in keptEdits)
		{
			let terrain = mScene.FindById(entry.key)?.GetComponent<VoxelTerrain>();
			if (terrain != null)
			{
				terrain.GiveEdits(entry.value);
				given.Add(entry.key);
			}
		}
		for (let id in given)
			keptEdits.Remove(id);
		SceneSerializer.LoadEnvironment(mScene, to);
		if (mSelectedId != 0 && mScene.FindById(mSelectedId) == null)
			mSelectedId = 0;
	}

	/// True, and the change made, when the only lines of an object that differ are a terrain's tiles and Foliage
	/// components' plants: those are put into the components as they stand, with nothing made again.
	bool TilesOnlyChange(uint32 id, StringView before, StringView after)
	{
		bool Tiles(StringView line) => line.StartsWith("field tiles ") || line.StartsWith("field nextTileId ") || line.StartsWith("field plants ");
		let a = scope String(), b = scope String();
		for (let line in before.Split('\n'))
		{
			if (!Tiles(line))
				a..Append(line).Append('\n');
		}
		for (let line in after.Split('\n'))
		{
			if (!Tiles(line))
				b..Append(line).Append('\n');
		}
		if (a != b)
			return false;
		let owner = mScene.FindById(id);
		if (owner == null)
			return false;
		let terrain = owner.GetComponent<VoxelTerrain>();
		// The object's Foliage components, in the order the text has them.
		List<Foliage> kinds = scope .();
		for (let component in owner.Components)
		{
			if (let foliage = component as Foliage)
				kinds.Add(foliage);
		}
		int kind = 0;
		bool anyPlants = false;
		for (var line in after.Split('\n'))
		{
			line.Trim();
			if (!line.StartsWith("field plants "))
				continue;
			if (kind >= kinds.Count)
				return false;
			var value = line.Substring(13);
			value.Trim();
			if (value.StartsWith('"') && value.EndsWith('"') && value.Length >= 2)
				value = value.Substring(1, value.Length - 2);
			if (kinds[kind].plants != value)
			{
				kinds[kind].plants.Set(value);
				kinds[kind].OnValidate();
			}
			kind++;
			anyPlants = true;
		}
		if (terrain == null)
			return anyPlants;
		for (var line in after.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("field tiles "))
			{
				var value = line.Substring(12);
				value.Trim();
				if (value.StartsWith('"') && value.EndsWith('"') && value.Length >= 2)
					value = value.Substring(1, value.Length - 2);
				terrain.tiles.Set(value);
			}
			else if (line.StartsWith("field nextTileId "))
				terrain.nextTileId = SceneSerializer.ParseInt(line.Substring(17));
		}
		terrain.OnValidate();
		return true;
	}

	void SaveSelectedAsPrefab()
	{
		let selected = Selected;
		if (selected == null)
			return;
		let name = scope String();
		for (let c in selected.Name.RawChars)
			name.Append(c.IsLetterOrDigit || c == '_' ? c : '_');
		if (name.IsEmpty)
			name.Set("Prefab");
		let path = scope $"{mBrowsePath}/{name}.tprefab";
		if (Prefab.Save(selected, path))
			Log.Info(scope $"Saved prefab {path}. Drag it from Project into the Scene to place copies.");
		else
			Log.Error(scope $"Could not write {path}");
		RefreshAssetList();
	}
}
