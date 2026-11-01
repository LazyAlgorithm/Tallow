using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Editing a prefab by itself. Double-clicking a .tprefab in the Project panel puts the scene aside and opens the
/// prefab alone in the Scene view, with the Hierarchy and Inspector working on it as they do on a scene. A bar at
/// the top of the Hierarchy saves it and goes back to the scene, which returns exactly as it was left, unsaved
/// changes included.
extension EditorApp
{
	String mPrefabPath = new .() ~ delete _;
	String mStashedScene = new .() ~ delete _;
	String mStashedScenePath = new .() ~ delete _;
	String mStashedSceneName = new .() ~ delete _;
	bool mStashedDirty;
	uint32 mStashedSelection;

	/// True while a prefab, not the scene, is open in the Scene view.
	bool EditingPrefab => !mPrefabPath.IsEmpty;

	/// The object a prefab file holds: the first object of the stage that is not the editor's own.
	GameObject PrefabRoot()
	{
		for (let object in mScene.Objects)
		{
			if (!object.Transient && !object.IsDestroyed && object.Transform.Parent == null)
				return object;
		}
		return null;
	}

	/// Opens a prefab for editing. The path is a file on disk.
	public void OpenPrefab(StringView fullPath)
	{
		if (mPlay != .Edit)
			StopPlay();
		if (EditingPrefab)
		{
			// Going from one prefab straight to another: keep the first one's changes, and the same scene waiting.
			if (mDirty)
				SavePrefab();
		}
		else
		{
			for (let component in mScene.Components)
				component.OnBeforeSave();
			mStashedScene.Clear();
			Foliage.SyncAll(mScene);
			SceneSerializer.Save(mScene, mStashedScene);
			mStashedScenePath.Set(mScene.Path);
			mStashedSceneName.Set(mScene.Name);
			mStashedDirty = mDirty;
			mStashedSelection = mSelectedId;
		}
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		// An empty stage with the prefab in it, and a light of the editor's own to see it by.
		SceneSerializer.Load(mScene, "");
		Prefab.ClearCache();
		let root = Prefab.Create(mScene, relative);
		if (root == null)
		{
			Log.Error(scope $"Could not open prefab {relative}");
			mPrefabPath.Set(fullPath);
			ClosePrefab(false);
			return;
		}
		// A prefab is saved without a place of its own; edit it at the origin.
		root.Transform.Position = .Zero;
		let lamp = mScene.CreateGameObject("Prefab Stage Light");
		lamp.Transient = true;
		lamp.Transform.Rotation = Quaternion.Euler(50, -30, 0);
		lamp.AddComponent<Light>();
		// A prefab has no camera of its own, so the Game view has nothing to show: work in the Scene view, where
		// the editor's own camera flies around it.
		mShowScene = true;
		mPrefabPath.Set(fullPath);
		mScene.Path.Clear();
		let name = scope String();
		Path.GetFileNameWithoutExtension(fullPath, name);
		mScene.Name.Set(scope $"Prefab: {name}");
		mSelectedId = root.Id;
		mDirty = false;
		ResetUndo();
		FocusSelected();
	}

	/// Writes the prefab being edited back to its file.
	void SavePrefab()
	{
		if (!EditingPrefab)
			return;
		let root = PrefabRoot();
		if (root == null)
		{
			Log.Error("There is nothing to save: the prefab's object was deleted. Use Back to Scene to leave, or undo.");
			return;
		}
		for (let component in mScene.Components)
			component.OnBeforeSave();
		if (Prefab.Save(root, mPrefabPath))
		{
			Prefab.ClearCache();
			AssetPreviews.Invalidate(mPrefabPath);
			mDirty = false;
			Log.Info(scope $"Saved {mPrefabPath}");
		}
	}

	/// Leaves the prefab and brings the scene back as it was. With save, unsaved changes to the prefab are kept.
	void ClosePrefab(bool save)
	{
		if (!EditingPrefab)
			return;
		if (save && mDirty)
			SavePrefab();
		mPrefabPath.Clear();
		SceneSerializer.Load(mScene, mStashedScene);
		mScene.Path.Set(mStashedScenePath);
		mScene.Name.Set(mStashedSceneName);
		mDirty = mStashedDirty;
		mSelectedId = mStashedSelection;
		mStashedScene.Clear();
		ResetUndo();
	}

	/// The bar across the top of the Hierarchy while a prefab is open.
	void DrawPrefabBar()
	{
		if (!EditingPrefab)
			return;
		let name = scope String();
		Path.GetFileName(mPrefabPath, name);
		ImGui.PushStyleColor(ImGui.Col.ChildBg, EditorTheme.Prefab);
		ImGui.BeginChild("prefabbar", .(0, 54), ImGui.ChildBorders);
		ImGui.Text(scope $"{name}{mDirty ? "*" : ""}");
		if (ImGui.SmallButton("Back to Scene"))
		{
			ClosePrefab(true);
			ImGui.EndChild();
			ImGui.PopStyleColor();
			return;
		}
		ImGui.SameLine();
		ImGui.BeginDisabled(!mDirty);
		if (ImGui.SmallButton("Save"))
			SavePrefab();
		ImGui.SameLine();
		if (ImGui.SmallButton("Revert"))
		{
			// Throw the changes away by opening the file again; the scene stays stashed.
			let path = scope String(mPrefabPath);
			mDirty = false;
			OpenPrefab(path);
		}
		ImGui.EndDisabled();
		ImGui.EndChild();
		ImGui.PopStyleColor();
	}
}
