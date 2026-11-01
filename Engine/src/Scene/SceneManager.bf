using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Scenes while the game runs: bring another scene's contents into the one that is playing, take them out again,
/// or change to a different scene altogether.
///
///   // A level kept in its own scene file, added to the scene that holds the game's menus and rules:
///   let level = SceneManager.LoadAdditive(Scene, "Scenes/Harbour.tscene", true);
///   ...
///   SceneManager.Unload(level);
///
///   // Or leave this scene for another one (it happens at the start of the next frame):
///   SceneManager.Load("Scenes/Credits.tscene");
///
/// Paths are relative to the project's asset folder, like every other asset path.
static class SceneManager
{
	static String sPending = new .() ~ delete _;
	static String sCurrent = new .() ~ delete _;

	/// The scene asked for with Load that has not been switched to yet, or empty.
	public static StringView Pending => sPending;
	/// The scene last switched to with Load, relative to the asset folder; empty until Load has been used.
	public static StringView Current => sCurrent;

	/// Adds everything in a scene file to a scene that is already loaded, and returns an object that holds it all:
	/// the file's top-level objects become its children. Components wake up at once if the scene is playing.
	/// With applyEnvironment the file's sky, fog and ambient light replace the scene's. Returns null if the file
	/// cannot be read.
	///
	/// Objects get fresh ids, so the same file can be added more than once. Nothing here is networked: in a
	/// multiplayer game every machine loads the scene for itself, as it does its start scene.
	public static GameObject LoadAdditive(Scene scene, StringView path, bool applyEnvironment = false)
	{
		if (scene == null)
			return null;
		// Its pack has not downloaded yet (only in a browser): check AssetPack.SceneReady first.
		if (!AssetPack.SceneReady(path))
		{
			AssetPack.Request(path);
			Log.Error(scope $"Scene not downloaded yet: {path}");
			return null;
		}
		let full = scope String();
		Assets.ResolvePath(path, full);
		let text = scope String();
		if (AssetPack.ReadAllText(full, text) case .Err)
		{
			Log.Error(scope $"Scene not found: {path}");
			return null;
		}
		let before = scene.Roots.Count;
		SceneSerializer.Instantiate(scene, text);
		List<GameObject> added = scope .();
		for (int i = before; i < scene.Roots.Count; i++)
			added.Add(scene.Roots[i]);
		let name = scope String();
		Path.GetFileNameWithoutExtension(path, name);
		let group = scene.CreateGameObject(name);
		// Part of what is running, not of the scene that was saved.
		group.Transient = true;
		for (let object in added)
			object.Transform.SetParent(group.Transform, true);
		if (applyEnvironment)
			SceneSerializer.LoadEnvironment(scene, text);
		return group;
	}

	/// Removes what LoadAdditive added, at once.
	public static void Unload(GameObject group)
	{
		if (group != null && group.Scene != null && !group.IsDestroyed)
			group.Scene.DestroyImmediate(group);
	}

	/// Changes to another scene: at the start of the next frame the running scene is stopped and emptied, the file
	/// is loaded in its place and play carries on in it. A network session in the old scene is closed. In the
	/// editor this happens inside play mode only; stopping still brings back the scene that was being edited.
	public static void Load(StringView path)
	{
		sPending.Set(path);
	}

	/// Called by the application between frames. Returns true if the scene was changed.
	public static bool ApplyPending(Scene scene)
	{
		if (sPending.IsEmpty || scene == null)
			return false;
		// A scene whose pack is still downloading (in a browser) is switched to once it has arrived.
		if (!AssetPack.SceneReady(sPending))
		{
			AssetPack.Request(sPending);
			return false;
		}
		let path = scope String(sPending);
		sPending.Clear();
		let full = scope String();
		Assets.ResolvePath(path, full);
		if (!AssetPack.Exists(full))
		{
			Log.Error(scope $"Scene not found: {path}");
			return false;
		}
		let wasPlaying = scene.IsPlaying;
		if (wasPlaying)
			scene.StopPlay();
		if (scene.Network != null)
		{
			scene.Network.Stop();
			delete scene.Network;
			scene.Network = null;
		}
		// The scene object keeps the path it was opened from: in the editor that is the file being edited.
		let opened = scope String(scene.Path);
		SceneSerializer.LoadFromFile(scene, full);
		scene.Path.Set(opened);
		sCurrent.Set(path);
		if (wasPlaying)
			scene.StartPlay();
		return true;
	}

	// ---- loading in the background ----

	static List<SceneLoad> sLoads = new .() ~ DeleteContainerAndItems!(_);

	/// Changes to another scene without stopping the game while it loads: the file, and the models and textures it
	/// names (and those of the prefabs and materials it names), are read in the background while the current scene
	/// plays on; then, when everything is ready (and allowActivation is true), the scene is switched to as Load does.
	/// Show a loading screen meanwhile from the returned SceneLoad's Progress. The SceneLoad belongs to SceneManager;
	/// it stays valid until the frame after it is done.
	public static SceneLoad LoadAsync(StringView path)
	{
		let load = new SceneLoad(path, null, false, false);
		sLoads.Add(load);
		return load;
	}

	/// LoadAdditive without stopping the game while it loads: when everything the file names is ready, its contents
	/// are added to the scene and Group holds them (the SceneLoad is then done).
	public static SceneLoad LoadAdditiveAsync(Scene scene, StringView path, bool applyEnvironment = false)
	{
		let load = new SceneLoad(path, scene, true, applyEnvironment);
		sLoads.Add(load);
		return load;
	}

	/// The scene loads in progress.
	public static List<SceneLoad> Loads => sLoads;

	/// Called by the application once a frame: background loading, then scene changes. Returns true if the scene was
	/// changed.
	public static bool Update(Scene scene)
	{
		AssetLoader.Update();
		bool changed = false;
		for (int i = 0; i < sLoads.Count; i++)
		{
			let load = sLoads[i];
			if (load.[Friend]mForget)
			{
				sLoads.RemoveAt(i--);
				delete load;
				continue;
			}
			changed |= load.[Friend]Step(scene);
		}
		changed |= ApplyPending(scene);
		// A streamed world's cells round the players (docs/world-streaming.md).
		WorldStreaming.Update(scene);
		return changed;
	}

	/// Puts a scene's text in place of the running scene, as ApplyPending does with a file.
	static void Switch(Scene scene, StringView path, StringView text)
	{
		let wasPlaying = scene.IsPlaying;
		if (wasPlaying)
			scene.StopPlay();
		if (scene.Network != null)
		{
			scene.Network.Stop();
			delete scene.Network;
			scene.Network = null;
		}
		let opened = scope String(scene.Path);
		SceneSerializer.Load(scene, text);
		// A streamed world: its list of cells (docs/world-streaming.md), which load round the players from here.
		if (scene.Environment.streaming)
			WorldStreaming.Of(scene).Open(scene, Assets.ResolvePath(path, .. scope .()), text);
		else if (scene.Streamer != null)
			DeleteAndNullify!(scene.Streamer);
		scene.Path.Set(opened);
		sCurrent.Set(path);
		if (wasPlaying)
			scene.StartPlay();
	}

	/// Adds a scene's text to a scene, as LoadAdditive does with a file.
	static GameObject Add(Scene scene, StringView path, StringView text, bool applyEnvironment)
	{
		let before = scene.Roots.Count;
		SceneSerializer.Instantiate(scene, text);
		List<GameObject> added = scope .();
		for (int i = before; i < scene.Roots.Count; i++)
			added.Add(scene.Roots[i]);
		let name = scope String();
		Path.GetFileNameWithoutExtension(path, name);
		let group = scene.CreateGameObject(name);
		group.Transient = true;
		for (let object in added)
			object.Transform.SetParent(group.Transform, true);
		if (applyEnvironment)
			SceneSerializer.LoadEnvironment(scene, text);
		return group;
	}

	/// The models and textures a scene's text names, and those named by the prefabs, scenes and materials it names
	/// (two levels deep). Only reads files: safe on a loading thread.
	public static void References(StringView text, List<(String path, AssetLoader.Kind kind)> output, int depth = 0)
	{
		bool skinned = false;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("component "))
			{
				skinned = line.Contains("SkinnedMeshRenderer");
				continue;
			}
			// The quoted values of fields and of material lines alike: field mesh "Models/a.glb", texture "x.png".
			let open = line.IndexOf('"');
			if (open < 0)
				continue;
			let close = line.IndexOf('"', open + 1);
			if (close <= open + 1)
				continue;
			let value = line.Substring(open + 1, close - open - 1);
			let name = line.Substring(0, open);
			let lower = scope String(value)..ToLower();
			if ((lower.EndsWith(".tprefab") || lower.EndsWith(".tscene") || lower.EndsWith(".tmat")) && depth < 2)
			{
				let full = scope String();
				Assets.ResolvePath(value, full);
				let inner = scope String();
				if (AssetPack.ReadAllText(full, inner) case .Ok)
					References(inner, output, depth + 1);
				continue;
			}
			if (!AssetLoader.KindOf(value, var kind))
				continue;
			if (kind == .Mesh && skinned && name.Contains("model"))
				kind = .SkinnedModel;
			bool seen = false;
			for (let entry in output)
				seen |= entry.kind == kind && entry.path == value;
			if (!seen)
				output.Add((new String(value), kind));
		}
	}
}

/// A scene being loaded in the background (SceneManager.LoadAsync and LoadAdditiveAsync).
class SceneLoad
{
	public enum Stage
	{
		/// Reading the scene file and finding what it names.
		Reading,
		/// Loading the models and textures it names.
		Loading,
		/// Everything is loaded; waiting for allowActivation.
		Ready,
		Done,
		/// The file could not be read.
		Failed
	}

	/// The scene file, relative to the project.
	public String Path = new .() ~ delete _;
	/// False holds a finished load at Ready (Progress 0.9) until it is set: for "press any key to continue".
	public bool allowActivation = true;
	/// For an additive load: the object holding what was added, once Done.
	public GameObject Group;

	Scene mScene;
	bool mAdditive, mEnvironment;
	Stage mStage = .Reading;
	String mText = new .() ~ delete _;
	List<(String path, AssetLoader.Kind kind)> mReferences = new .() ~ { for (let entry in _) delete entry.path; delete _; };
	AssetLoader.Batch mBatch ~ delete _;
	System.Threading.Thread mThread ~ delete _;
	volatile bool mRead, mReadFailed;
	bool mForget;

	public Stage CurrentStage => mStage;
	public bool IsDone => mStage == .Done || mStage == .Failed;
	public bool Failed => mStage == .Failed;
	/// 0 to 1: reading the file is the first tenth, loading what it names up to 0.9, switching the last tenth.
	public float Progress
	{
		get
		{
			switch (mStage)
			{
			case .Reading: return 0.02f;
			case .Loading: return 0.1f + 0.8f * (mBatch != null ? mBatch.Progress : 0);
			case .Ready: return 0.9f;
			default: return 1;
			}
		}
	}

	/// How many models and textures it names, and how many are loaded.
	public int32 AssetCount => mBatch != null ? mBatch.Total : 0;
	public int32 AssetsLoaded => mBatch != null ? mBatch.Loaded : 0;

	public this(StringView path, Scene scene, bool additive, bool environment)
	{
		Path.Set(path);
		mScene = scene;
		mAdditive = additive;
		mEnvironment = environment;
	}

	/// Lets a load that is Ready be switched to (the same as setting allowActivation).
	public void Activate() => allowActivation = true;

	void Read()
	{
		let full = scope String();
		Assets.ResolvePath(Path, full);
		if (AssetPack.ReadAllText(full, mText) case .Err)
		{
			mReadFailed = true;
			mRead = true;
			return;
		}
		SceneManager.References(mText, mReferences);
		mRead = true;
	}

	/// One frame of the load, on the main thread. Returns true when it switched the scene.
	bool Step(Scene running)
	{
		switch (mStage)
		{
		case .Reading:
			if (mThread == null && !mRead)
			{
				// Its pack has not downloaded yet (only in a browser): wait for it.
				if (!AssetPack.SceneReady(Path))
				{
					AssetPack.Request(Path);
					return false;
				}
#if BF_PLATFORM_WASM
				Read();
#else
				mThread = new .(new => Read);
				mThread.SetName("Scene loading");
				mThread.Start(false);
#endif
			}
			if (!mRead)
				return false;
			mThread?.Join();
			if (mReadFailed)
			{
				Log.Error(scope $"Scene not found: {Path}");
				mStage = .Failed;
				return false;
			}
			mBatch = new .();
			for (let entry in mReferences)
				AssetLoader.Add(mBatch, entry.path, entry.kind);
			mStage = .Loading;
			return false;
		case .Loading:
			if (!mBatch.IsDone)
				return false;
			mStage = .Ready;
			fallthrough;
		case .Ready:
			if (!allowActivation)
				return false;
			if (mAdditive)
			{
				let target = mScene ?? running;
				if (target != null)
					Group = SceneManager.[Friend]Add(target, Path, mText, mEnvironment);
				mStage = .Done;
				return false;
			}
			if (running == null)
				return false;
			SceneManager.[Friend]Switch(running, Path, mText);
			mStage = .Done;
			return true;
		case .Done,.Failed:
			// Kept for one more frame so that whoever started it sees it done, then let go.
			mForget = true;
			return false;
		}
	}
}
