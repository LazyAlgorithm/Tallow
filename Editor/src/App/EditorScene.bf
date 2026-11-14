using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// Scene operations: new/open/save, selection, creating and deleting objects, play mode.
extension EditorApp
{
	void MarkDirty()
	{
		mDirty = true;
		mUndoPending = true;
	}

	/// checkMap: warn (the Map Warning window) when the game's MapRules.txt says the saved scene could not be a map.
	/// Saves the user asks for check; saves made on the way to an export or a build do not.
	void SaveScene(bool checkMap = true)
	{
		// A sequence preview's poses are not the scene's own: they go back first.
		StopSequencePreview();
		if (mPlay != .Edit)
		{
			Log.Warning("Stop play mode before saving the scene.");
			return;
		}
		// While a prefab is open, Save means the prefab.
		if (EditingPrefab)
		{
			SavePrefab();
			return;
		}
		if (mScene.Path.IsEmpty)
		{
			mOpenSaveAs = true;
			return;
		}
		if (SceneSerializer.SaveToFile(mScene, mScene.Path))
		{
			mDirty = false;
			Log.Info(scope $"Saved {mScene.Path}");
			if (checkMap)
				WarnIfNotMap();
		}
	}

	void OpenScene(StringView path)
	{
		if (mPlay != .Edit)
			StopPlay();
		// Opening a scene while a prefab is open keeps the prefab's changes and leaves the prefab.
		if (EditingPrefab)
			ClosePrefab(true);
		if (SceneSerializer.LoadFromFile(mScene, path))
		{
			mSelectedId = 0;
			mDirty = false;
			AlignSceneCameraToGameCamera();
			// A streamed world: only the cells round the view (docs/world-streaming.md).
			LoadStreamedCellsAroundView();
			ResetUndo();
			Log.Info(scope $"Opened {path}");
		}
	}

	void NewScene()
	{
		if (mPlay != .Edit)
			StopPlay();
		if (EditingPrefab)
			ClosePrefab(true);
		SceneTemplates.BuildDefault(mScene);
		mScene.Name.Set("Untitled");
		mScene.Path.Clear();
		mSelectedId = 0;
		mDirty = true;
		ResetUndo();
	}

	/// Find managed gameplay without scanning hidden build artifacts.
	bool HasCSharpSources(StringView folder, int depth = 0)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return false;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name.EndsWith(".cs", .OrdinalIgnoreCase))
				return true;
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.StartsWith('.') && HasCSharpSources(scope $"{folder}/{name}", depth + 1))
				return true;
		}
		return false;
	}

	/// Initial managed Play loading, using the same scene and component lifecycle as native gameplay.
	/// No third-party DLL search or untrusted mod loading occurs here.
	bool PrepareCSharpPlay()
	{
		let project = Project.Current;
		if (CSharpRuntime.StartTrustedGame(mScene, project.EngineRoot, project.Path))
			return true;
		mStatus.Set("C# gameplay could not start. See Console for the detailed error.");
		return false;
	}

	void StartPlay()
	{
		if (mPlay != .Edit)
			return;
		// Always save first; unsaved scripts must not run stale code.
		SaveAllScripts();
		// Manual mode also needs to recognize harmless formatting changes.
		// Do not queue a build for a script revision equivalent to the host.
		if (mScriptsNeedReload && !mCheckRunning && !mReloadQueued && CheckScriptChanges() == 0)
			mScriptsNeedReload = false;
		if (mCheckRunning || mReloadQueued)
		{
			mPlayAfterCompile = true;
			mStatus.Set(mCheckRunning ? "Compiling scripts before Play..." : "Waiting to compile scripts before Play...");
			return;
		}
		if (mScriptsNeedReload)
		{
			if (!mReloadReady)
			{
				mStatus.Set("Script reload is unavailable. Use Full Rebuild & Restart before Play.");
				return;
			}
			mPlayAfterCompile = true;
			QueueScriptReload(true, true);
			mStatus.Set("Waiting to compile scripts before Play...");
			return;
		}
		// Build gameplay C# before starting a scene. The Play request is resumed by
		// CollectCheckResults once the managed compiler succeeds.
		let hasCSharp = HasCSharpSources(scope $"{Project.Current.Path}/src");
		if (hasCSharp && !mManagedBuildReady)
		{
			mPlayAfterCompile = true;
			StartManagedErrorCheck();
			mStatus.Set("Compiling C# gameplay before Play...");
			return;
		}
		StopSequencePreview();
		if (EditingPrefab)
		{
			Log.Warning("A prefab is open. Go back to the scene to play.");
			return;
		}
		if (hasCSharp && !PrepareCSharpPlay())
			return;
		// A successful Play transition must never retain a stale compile notice.
		mStatus.Clear();
		// Side files (sculpted terrain) must be on disk, because stopping reloads the scene.
		for (let component in mScene.Components)
			component.OnBeforeSave();
		mPrePlaySelection = mSelectedId;
		mPrePlayDirty = mDirty;
		mSnapshot.Clear();
		Foliage.SyncAll(mScene);
		SceneSerializer.Save(mScene, mSnapshot);
		StartPlayStreaming();
		mPlay = .Playing;
		mStopPlayRequested = false;
		mFocusGame = true;
		// Each Play is a fresh run of the game: a save set to load at start is loaded again.
		GamePaths.Game.Set(Project.Current.Name);
		GamePaths.Refresh();
		SaveSystem.LoadAtStart = Project.Current.LoadSaveAtStart;
		SaveSystem.StartSlot.Set(Project.Current.SaveSlot);
		SaveSystem.NewRun();
		mScene.StartPlay();
	}

	void StopPlay()
	{
		if (mPlay == .Edit)
			return;
		mScene.StopPlay();
		// All CSharpBehaviour components have detached in StopPlay. Unload the game
		// assembly before restoring the edit-time scene, so code can be rebuilt.
		CSharpRuntime.EndTrustedGame(mScene);
		// Data assets as the game left them are not the files: the next Play reads them afresh.
		DataAsset.ClearCache();
		if (mScene.Network != null)
		{
			mScene.Network.Stop();
			delete mScene.Network;
			mScene.Network = null;
		}
		// Play mode never changes the saved scene: restore the snapshot taken when it started.
		let path = scope String(mScene.Path);
		SceneSerializer.Load(mScene, mSnapshot);
		mScene.Path.Set(path);
		StopPlayStreaming();
		mSelectedId = mPrePlaySelection;
		mDirty = mPrePlayDirty;
		mPlay = .Edit;
		Time.TimeScale = 1;
	}

	GameObject CreateObject(StringView name, StringView mesh = default)
	{
		let parent = Selected;
		let gameObject = mScene.CreateGameObject(name, parent != null ? parent.Transform : null);
		// The surface it was dropped on, if any, and which way that faces.
		var surface = Vector3.Zero;
		var onSurface = false;
		if (parent == null || parent.IsFolder)
		{
			// Drop new objects in front of the scene camera, on the surface in the middle of the view when it is near.
			let forward = Quaternion.Euler(mCamPitch, mCamYaw, 0) * Vector3.Forward;
			var position = mCamPosition + forward * 8.0f;
			if (forward.y < -0.05f && mCamPosition.y / -forward.y <= 30.0f)
			{
				position = mCamPosition + forward * (-mCamPosition.y / forward.y);
				surface = .Up;
				onSurface = true;
			}
			else if (forward.y < -0.05f)
				position = mCamPosition + forward * 30.0f;
			Vector3 point, normal;
			if (RaycastScene(Ray(mCamPosition, forward), out point, out normal, null, false, 30))
			{
				position = point;
				surface = normal.LengthSquared > 1.0e-6f ? normal.Normalized : .Up;
				onSurface = true;
			}
			gameObject.Transform.Position = position;
		}
		if (!mesh.IsEmpty)
		{
			let renderer = gameObject.AddComponent<MeshRenderer>();
			renderer.mesh.Set(mesh);
			// Rests on the surface instead of half inside it: something made to fall (a Rigidbody, a jelly) would be
			// thrown out of the ground on Play.
			if (onSurface)
			{
				let bounds = renderer.WorldBounds;
				let extents = bounds.Extents;
				let reach = Math.Abs(surface.x) * extents.x + Math.Abs(surface.y) * extents.y + Math.Abs(surface.z) * extents.z;
				let below = Vector3.Dot(surface, gameObject.Transform.Position - bounds.Center) + reach;
				if (below > 0)
					gameObject.Transform.Position = gameObject.Transform.Position + surface * below;
			}
		}
		mSelectedId = gameObject.Id;
		MarkDirty();
		return gameObject;
	}

	GameObject Duplicate(GameObject source, Transform parent)
	{
		let text = scope String();
		SceneSerializer.SaveObjectTree(source, text);
		let copy = SceneSerializer.Instantiate(mScene, text);
		if (copy != null)
			copy.Transform.SetParent(parent, false);
		return copy;
	}

	void DeleteSelected()
	{
		let selected = Selected;
		if (selected == null)
			return;
		mScene.Destroy(selected);
		mSelectedId = 0;
		MarkDirty();
	}

	void FocusSelected()
	{
		let selected = Selected;
		// Folders have no place in the world to frame.
		if (selected == null || selected.IsFolder)
			return;
		var radius = 1.5f;
		var center = selected.Transform.Position;
		let renderer = selected.GetComponent<MeshRenderer>();
		if (renderer)
		{
			let bounds = renderer.WorldBounds;
			center = bounds.Center;
			radius = Math.Max(bounds.Extents.Length, 0.5f);
		}
		// A navigation surface is framed by its bake volume, which starts at the object rather than around it.
		let navigation = selected.GetComponent<NavigationSurface>();
		if (navigation != null)
		{
			center = selected.Transform.Position + navigation.size * 0.5f;
			radius = Math.Max(navigation.size.Length * 0.5f, 0.5f);
		}
		// A terrain is framed by its tiles, from above.
		let terrain = selected.GetComponent<VoxelTerrain>();
		if (terrain != null && terrain.mode == .Fixed && terrain.TileCount > 0)
		{
			List<TerrainTile> tiles = scope .();
			terrain.GetTiles(tiles);
			let w = terrain.TileWorldSize;
			var low = Vector3(float.MaxValue, 0, float.MaxValue);
			var high = Vector3(float.MinValue, 0, float.MinValue);
			for (let tile in tiles)
			{
				low = .(Math.Min(low.x, tile.x * w), terrain.flatHeight, Math.Min(low.z, tile.z * w));
				high = .(Math.Max(high.x, (tile.x + 1) * w), terrain.flatHeight, Math.Max(high.z, (tile.z + 1) * w));
			}
			center = selected.Transform.TransformPoint((low + high) * 0.5f);
			radius = (high - low).Length * 0.5f;
			mCamPitch = Math.Max(mCamPitch, 40);
			let look = Quaternion.Euler(mCamPitch, mCamYaw, 0) * Vector3.Forward;
			mCamPosition = center - look * (radius * 1.6f + 1.0f);
			return;
		}
		let forward = Quaternion.Euler(mCamPitch, mCamYaw, 0) * Vector3.Forward;
		mCamPosition = center - forward * (radius * 2.8f + 1.0f);
	}
}
