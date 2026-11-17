using System;
using System.Collections;

namespace Tallow;

/// Loading in the background for C# scripts (SceneManager.LoadAsync, Scene.LoadAdditiveAsync and AssetLoader.Preload
/// in Tallow.API). Loads are followed by number: SceneManager lets a SceneLoad go the frame after it is done, and its
/// final state is kept here for C# to read.
[CSharpExpose]
static class CSharpScenes
{
	static Dictionary<int32, SceneLoad> sLoads = new .() ~ delete _;
	/// Loads SceneManager has let go: stage and the additive group's object.
	static Dictionary<int32, (int32 stage, uint64 group)> sFinished = new .() ~ delete _;
	static Dictionary<int32, AssetLoader.Batch> sBatches = new .() ~ DeleteDictionaryAndValues!(_);
	static int32 sNext = 1;

	/// Starts a load: additive into the session's scene (with its sky, fog and light when environment), or a change
	/// of scene. Its number, 0 when there is no such scene to add to.
	[CSharpExpose]
	public static int32 Start(uint64 session, StringView path, bool additive, bool environment)
	{
		if (path.IsEmpty)
			return 0;
		SceneLoad load;
		if (additive)
		{
			let scene = CSharpRuntime.PhysicsScene(session);
			if (scene == null)
				return 0;
			load = SceneManager.LoadAdditiveAsync(scene, path, environment);
		}
		else
			load = SceneManager.LoadAsync(path);
		let id = sNext++;
		load.csharpId = id;
		sLoads[id] = load;
		return id;
	}

	/// A load's stage (SceneLoad.Stage: 0 reading, 1 loading, 2 ready, 3 done, 4 failed; -1 unknown), with progress,
	/// asset count and assets loaded in values when it has room.
	[CSharpExpose]
	public static int32 State(int32 id, Span<float> values)
	{
		if (sLoads.TryGetValue(id, let load))
		{
			if (values.Length >= 3)
			{
				values[0] = load.Progress;
				values[1] = load.AssetCount;
				values[2] = load.AssetsLoaded;
			}
			return (int32)load.CurrentStage;
		}
		if (sFinished.TryGetValue(id, let finished))
		{
			if (values.Length >= 3)
			{
				values[0] = finished.stage == (int32)SceneLoad.Stage.Done ? 1 : 0;
				values[1] = 0;
				values[2] = 0;
			}
			return finished.stage;
		}
		return -1;
	}

	/// An additive load's group object once it is done (0 before, or for a change of scene).
	[CSharpExpose]
	public static uint64 Group(int32 id)
	{
		if (sLoads.TryGetValue(id, let load))
			return GroupOf(load);
		return sFinished.TryGetValue(id, let finished) ? finished.group : 0;
	}

	/// Holds a finished load at Ready (false) or lets it finish (true).
	[CSharpExpose]
	public static void AllowActivation(int32 id, bool allow)
	{
		if (sLoads.TryGetValue(id, let load))
			load.allowActivation = allow;
	}

	static uint64 GroupOf(SceneLoad load)
	{
		if (load.Group == null || load.Group.IsDestroyed)
			return 0;
		return (uint64)load.Group.Id;
	}

	/// SceneManager lets a load go: its final state stays for C#.
	public static void Finished(SceneLoad load)
	{
		if (!sLoads.Remove(load.csharpId))
			return;
		sFinished[load.csharpId] = ((int32)load.CurrentStage, GroupOf(load));
	}

	/// Starts loading files ('\n' between paths) before they are needed: its number.
	[CSharpExpose]
	public static int32 Preload(StringView paths)
	{
		let list = scope List<StringView>();
		for (let path in paths.Split('\n', .RemoveEmptyEntries))
			list.Add(path);
		let array = scope StringView[list.Count];
		for (int i < list.Count)
			array[i] = list[i];
		let batch = AssetLoader.Preload(params array);
		let id = sNext++;
		sBatches[id] = batch;
		return id;
	}

	/// A preload's progress (0 to 1), with total and loaded in values; -1 when there is no such preload.
	[CSharpExpose]
	public static float PreloadState(int32 id, Span<float> values)
	{
		if (!sBatches.TryGetValue(id, let batch))
			return -1;
		if (values.Length >= 2)
		{
			values[0] = batch.Total;
			values[1] = batch.Loaded;
		}
		return batch.Progress;
	}

	/// Lets go of a preload (what it loaded stays loaded).
	[CSharpExpose]
	public static void ReleasePreload(int32 id)
	{
		if (sBatches.GetAndRemove(id) case .Ok(let pair))
			delete pair.value;
	}

	/// The game's code is going: loads in progress carry on, unfollowed.
	public static void ReleaseAll()
	{
		for (let load in sLoads.Values)
			load.csharpId = 0;
		sLoads.Clear();
		sFinished.Clear();
		for (let batch in sBatches.Values)
			delete batch;
		sBatches.Clear();
	}
}
