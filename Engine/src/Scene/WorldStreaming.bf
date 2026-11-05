using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// What a streamed world loads round (docs/world-streaming.md): put one on the player (on a server every player's
/// object has one, so the world is loaded round each of them), a vehicle or a camera. With none in the scene, the
/// world streams round the scene's cameras.
[Component]
class StreamingSource : Component
{
	/// Added to the scene's Load Radius for this source: a fast vehicle may want more of the world ahead of it.
	public float extraRadius = 0;

	public override void OnRegister() => Scene.StreamingSources.Add(this);
	public override void OnUnregister() => Scene.StreamingSources.Remove(this);
}

/// World streaming (docs/world-streaming.md): one large scene, saved as a grid of cells that load and unload round
/// the players with no code.
static class WorldStreaming
{
	/// The scene's streaming state (made the first time it is asked for).
	public static WorldStreamer Of(Scene scene)
	{
		if (scene.Streamer == null)
			scene.Streamer = new .();
		return scene.Streamer;
	}

	/// Called once a frame while the game runs (SceneManager.Update).
	public static void Update(Scene scene)
	{
		if (scene != null && scene.IsPlaying && scene.Environment.streaming && scene.Streamer != null)
			scene.Streamer.Update(scene);
	}
}

/// A streamed world's cells: which there are, which are loaded, and the loads under way. Each scene has one
/// (WorldStreaming.Of).
class WorldStreamer
{
	/// A cell's place in the grid as one number.
	public static int64 Key(int32 x, int32 z) => ((int64)x << 32) | (int64)(uint32)z;
	public static int32 KeyX(int64 key) => (int32)(key >> 32);
	public static int32 KeyZ(int64 key) => (int32)(uint32)(key & 0xFFFFFFFF);

	/// Most cell files read at once.
	const int MaxLoading = 4;
	/// Stand-ins are cut down to about this many triangles a cell.
	const int StandInTriangles = 4000;

	String mFolder = new .() ~ delete _;
	HashSet<int64> mCells = new .() ~ delete _;
	HashSet<int64> mLoaded = new .() ~ delete _;
	/// Cells taken out in the editor before being saved: their objects as text, written by the next save.
	Dictionary<int64, String> mHeld = new .() ~ DeleteDictionaryAndValues!(_);
	Dictionary<int64, CellLoad> mLoading = new .() ~ DeleteDictionaryAndValues!(_);
	/// The stand-in object shown for each cell that is not loaded, by id (the scene may have been reloaded since).
	Dictionary<int64, uint32> mStandIns = new .() ~ delete _;
	bool mPrimed;

	/// The floating origin's offset: a position in the scene plus Origin is where it is in the world as saved.
	public Vector3 Origin;
	/// Cells added and taken out since the world was opened (for tests and the Profiler).
	public int CellsAdded, CellsRemoved;

	/// Every cell the world has.
	public HashSet<int64> Cells => mCells;
	/// The cells whose objects are in the scene.
	public HashSet<int64> Loaded => mLoaded;
	/// True while cells are being read.
	public bool Loading => mLoading.Count > 0;
	/// The folder of cell files: "<scene>.cells" beside the scene file.
	public StringView Folder => mFolder;

	public bool IsHeld(int64 key) => mHeld.ContainsKey(key);

	static void FolderFor(StringView scenePath, String outFolder)
	{
		outFolder.Append(scenePath);
		if (outFolder.EndsWith(".tscene"))
			outFolder.RemoveFromEnd(7);
		outFolder.Append(".cells");
	}

	public void CellFile(int64 key, String outPath) => outPath.AppendF("{}/{}_{}.tcell", mFolder, KeyX(key), KeyZ(key));
	public void StandInFile(int64 key, String outPath) => outPath.AppendF("{}/{}_{}.standin.tmesh", mFolder, KeyX(key), KeyZ(key));

	// ---- cells and what is in them ----

	/// The cell a position in the scene is in.
	public int64 CellOf(Scene scene, Vector3 position)
	{
		let size = scene.Environment.streamCellSize;
		return Key((int32)Math.Floor((position.x + Origin.x) / size), (int32)Math.Floor((position.z + Origin.z) / size));
	}

	/// How far a position in the scene is from a cell, across the ground (0 inside it).
	public float Distance(Scene scene, int64 key, Vector3 position)
	{
		let size = scene.Environment.streamCellSize;
		let x = position.x + Origin.x;
		let z = position.z + Origin.z;
		let minX = KeyX(key) * size;
		let minZ = KeyZ(key) * size;
		let dx = Math.Max(Math.Max(minX - x, x - (minX + size)), 0);
		let dz = Math.Max(Math.Max(minZ - z, z - (minZ + size)), 0);
		return Math.Sqrt(dx * dx + dz * dz);
	}

	/// Whether an object (with its children) comes and goes with its cell. Folders stay (their contents stream);
	/// cameras, directional lights, voxel terrain (which streams by itself), spawn points, networked objects and
	/// streaming sources stay loaded, as does anything marked Always Loaded.
	public static bool Streams(GameObject unit)
	{
		if (unit.AlwaysLoaded || unit.IsFolder)
			return false;
		bool Keeps(GameObject gameObject)
		{
			let light = gameObject.GetComponent<Light>();
			if ((light && light.type == .Directional) || gameObject.HasComponent<Camera>())
				return true;
			for (let component in gameObject.Components)
			{
				if (component is NetworkIdentity || component is VoxelTerrain || component is StreamingSource || component is SpawnPoint)
					return true;
			}
			for (let child in gameObject.Transform.Children)
			{
				if (Keeps(child.GameObject))
					return true;
			}
			return false;
		}
		return !Keeps(unit);
	}

	/// The objects that stream, each with its children: those at the top of the scene or of folders.
	public static void Units(Scene scene, List<GameObject> units)
	{
		void Walk(GameObject gameObject)
		{
			if (gameObject.Transient || gameObject.IsDestroyed)
				return;
			if (gameObject.IsFolder)
			{
				for (let child in gameObject.Transform.Children)
					Walk(child.GameObject);
				return;
			}
			if (Streams(gameObject))
				units.Add(gameObject);
		}
		for (let root in scene.Roots)
			Walk(root);
	}

	/// The streaming objects now in a cell.
	public void UnitsIn(Scene scene, int64 key, List<GameObject> units)
	{
		let all = scope List<GameObject>();
		Units(scene, all);
		for (let unit in all)
		{
			if (CellOf(scene, unit.Transform.Position) == key)
				units.Add(unit);
		}
	}

	// ---- opening and saving ----

	/// After a streamed scene file was loaded: reads its list of cells. Nothing is loaded yet.
	public void Open(Scene scene, StringView path, StringView text)
	{
		Reset();
		FolderFor(path, mFolder);
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("streamcell "))
			{
				var parts = line.Split(' ');
				parts.GetNext();
				let x = SceneSerializer.ParseInt(parts.GetNext().GetValueOrDefault());
				let z = SceneSerializer.ParseInt(parts.GetNext().GetValueOrDefault());
				mCells.Add(Key(x, z));
			}
			else if (line.StartsWith("nextid "))
				scene.NextId = (uint32)SceneSerializer.ParseInt(line.Substring(7));
		}
	}

	void Reset()
	{
		mCells.Clear();
		mLoaded.Clear();
		for (let text in mHeld.Values)
			delete text;
		mHeld.Clear();
		for (let load in mLoading.Values)
			delete load;
		mLoading.Clear();
		mStandIns.Clear();
		mFolder.Clear();
		Origin = .Zero;
		mPrimed = false;
		CellsAdded = CellsRemoved = 0;
	}

	/// Writes the world: into text the scene's settings, what is always loaded and the list of cells; and each cell
	/// whose objects are loaded (or held) into its own file, with its stand-in. Cells not loaded are left as they are
	/// on disk (copied, if the world is saved under a new name).
	public void SaveWorld(Scene scene, StringView path, String text)
	{
		let folder = FolderFor(path, .. scope .());
		let oldFolder = scope String(mFolder);
		// Objects moved into a cell that is on disk but not loaded: its other objects come in first, so the cell is
		// written whole.
		let units = scope List<GameObject>();
		Units(scene, units);
		for (let unit in units)
		{
			let key = CellOf(scene, unit.Transform.Position);
			if ((mCells.Contains(key) || mHeld.ContainsKey(key)) && !mLoaded.Contains(key))
				LoadNow(scene, key);
		}
		units.Clear();
		Units(scene, units);
		let groups = new Dictionary<int64, List<GameObject>>();
		defer
		{
			DeleteDictionaryAndValues!(groups);
		}
		let skip = scope HashSet<GameObject>();
		for (let unit in units)
		{
			let key = CellOf(scene, unit.Transform.Position);
			if (!groups.TryGetValue(key, var list))
				groups[key] = list = new .();
			list.Add(unit);
			skip.Add(unit);
		}

		SceneSerializer.SaveExcept(scene, skip, text);
		text.AppendF("nextid {}\n", scene.NextId);
		mFolder.Set(folder);
		Directory.CreateDirectory(folder).IgnoreError();
		let cells = scope HashSet<int64>();
		for (let (key, list) in groups)
		{
			let cellText = scope String();
			cellText.AppendF("cell {} {}\n", KeyX(key), KeyZ(key));
			SceneSerializer.SaveObjects(list, cellText);
			File.WriteAllText(CellFile(key, .. scope .()), cellText).IgnoreError();
			WriteStandIn(key, list);
			cells.Add(key);
			mLoaded.Add(key);
		}
		for (let (key, held) in mHeld)
		{
			File.WriteAllText(CellFile(key, .. scope .()), held).IgnoreError();
			cells.Add(key);
		}
		for (let key in mCells)
		{
			if (cells.Contains(key) || mLoaded.Contains(key))
				continue;
			// Not loaded: as it is on disk (a world saved under another name takes a copy).
			if (oldFolder != folder && !oldFolder.IsEmpty)
			{
				let from = scope $"{oldFolder}/{KeyX(key)}_{KeyZ(key)}";
				let to = scope $"{folder}/{KeyX(key)}_{KeyZ(key)}";
				File.Copy(scope $"{from}.tcell" , scope $"{to}.tcell" , true).IgnoreError();
				File.Copy(scope $"{from}.standin.tmesh" , scope $"{to}.standin.tmesh" , true).IgnoreError();
			}
			cells.Add(key);
		}
		// Loaded cells left empty: their files go.
		let emptied = scope List<int64>();
		for (let key in mLoaded)
		{
			if (!groups.ContainsKey(key))
				emptied.Add(key);
		}
		for (let key in emptied)
		{
			File.Delete(CellFile(key, .. scope .())).IgnoreError();
			File.Delete(StandInFile(key, .. scope .())).IgnoreError();
			mLoaded.Remove(key);
		}
		for (let held in mHeld.Values)
			delete held;
		mHeld.Clear();
		mCells.Clear();
		for (let key in cells)
		{
			mCells.Add(key);
			text.AppendF("streamcell {} {}\n", KeyX(key), KeyZ(key));
		}
	}

	/// A cell's stand-in: its Mesh Renderers merged (in their colours), cut down, and written as a .tmesh drawn in
	/// its place while it is not loaded.
	void WriteStandIn(int64 key, List<GameObject> units)
	{
		let edit = scope EditMesh();
		void Add(MeshRenderer renderer)
		{
			if (!renderer.Enabled || renderer.shadowOnly)
				return;
			let world = renderer.Transform.LocalToWorld;
			let tint = renderer.color;
			void AddMesh(Mesh mesh, Color partColor)
			{
				if (mesh == null || mesh.IsDynamic)
					return;
				let first = (int32)edit.positions.Count;
				for (let vertex in mesh.Vertices)
					edit.positions.Add(world.TransformPoint(vertex.position) + Origin);
				for (int i = 0; i + 2 < mesh.Indices.Count; i += 3)
				{
					let face = edit.AddFace();
					for (int k < 3)
					{
						let index = mesh.Indices[i + k];
						let abgr = mesh.Vertices[(int)index].color;
						let c = Color((abgr & 0xFF) / 255.0f, ((abgr >> 8) & 0xFF) / 255.0f, ((abgr >> 16) & 0xFF) / 255.0f, 1);
						face.Add(first + (int32)index, .Zero, .(c.r * tint.r * partColor.r, c.g * tint.g * partColor.g, c.b * tint.b * partColor.b, 1));
					}
				}
			}
			let parts = renderer.DrawnParts;
			if (parts != null)
			{
				for (let part in parts)
				{
					if (!part.hidden && !part.shadowOnly)
						AddMesh(part.mesh, part.material?.color ?? .White);
				}
			}
			else
				AddMesh(renderer.ActiveMesh, renderer.ActiveMaterial?.color ?? .White);
		}
		void Walk(GameObject gameObject)
		{
			if (!gameObject.ActiveSelf)
				return;
			if (gameObject.HasComponent<MeshRenderer>())
				Add(gameObject.GetComponent<MeshRenderer>());
			for (let child in gameObject.Transform.Children)
				Walk(child.GameObject);
		}
		for (let unit in units)
			Walk(unit);
		let file = StandInFile(key, .. scope .());
		if (edit.faces.IsEmpty)
		{
			File.Delete(file).IgnoreError();
			return;
		}
		let triangles = MeshOps.TriangleCount(edit);
		if (triangles > StandInTriangles)
			MeshOps.Decimate(edit, (float)StandInTriangles / triangles);
		let text = scope String();
		edit.Write(text);
		File.WriteAllText(file, text).IgnoreError();
		Assets.Forget(Assets.MakeRelative(file, .. scope .()));
	}

	// ---- loading and taking out ----

	/// Adds a cell's objects now (its file, or the text held for it).
	public void LoadNow(Scene scene, int64 key)
	{
		if (mLoaded.Contains(key))
			return;
		if (mLoading.GetAndRemove(key) case .Ok(let pending))
			delete pending.value;
		let text = scope String();
		if (mHeld.GetAndRemove(key) case .Ok(let held))
		{
			text.Set(held.value);
			delete held.value;
		}
		else if (AssetPack.ReadAllText(CellFile(key, .. scope .()), text) case .Err)
			return;
		Add(scene, key, text);
	}

	void Add(Scene scene, int64 key, StringView text)
	{
		// The objects keep their ids: references to them (and theirs to what is always loaded) still work.
		let created = scope List<GameObject>();
		SceneSerializer.LoadObjects(scene, text, created);
		// A world moved by the floating origin: the cell's objects come in where the world now is. Those in folders
		// already are, as the folders were moved with the rest.
		if (Origin != .Zero)
		{
			for (let object in created)
			{
				if (object.Transform.Parent == null)
					object.Transform.Position = object.Transform.Position - Origin;
			}
		}
		mLoaded.Add(key);
		CellsAdded++;
		HideStandIn(scene, key);
	}

	/// Takes a cell's objects out of the scene. In the editor (hold) they are kept as text for the next save.
	public void Unload(Scene scene, int64 key, bool hold)
	{
		let units = scope List<GameObject>();
		UnitsIn(scene, key, units);
		if (hold && !units.IsEmpty)
		{
			let text = new String();
			text.AppendF("cell {} {}\n", KeyX(key), KeyZ(key));
			SceneSerializer.SaveObjects(units, text);
			if (mHeld.GetAndRemove(key) case .Ok(let old))
				delete old.value;
			mHeld[key] = text;
			mCells.Add(key);
		}
		scene.DestroyImmediate(units);
		mLoaded.Remove(key);
		CellsRemoved++;
	}

	/// Loads every cell within the Load Radius of a position at once (opening a scene in the editor, or the first
	/// frame of the game, so that nobody starts on missing ground).
	public void LoadAround(Scene scene, Vector3 position, float extra = 0)
	{
		for (let key in mCells)
		{
			if (!mLoaded.Contains(key) && Distance(scene, key, position) <= scene.Environment.streamLoadRadius + extra)
				LoadNow(scene, key);
		}
		for (let key in mHeld.Keys)
		{
			if (!mLoaded.Contains(key) && Distance(scene, key, position) <= scene.Environment.streamLoadRadius + extra)
				LoadNow(scene, key);
		}
	}

	/// Where the world streams round: the Streaming Sources, else the scene's cameras.
	public void Sources(Scene scene, List<(Vector3 position, float extra)> sources)
	{
		for (let source in scene.StreamingSources)
		{
			if (source.IsActiveAndEnabled)
				sources.Add((source.Transform.Position, source.extraRadius));
		}
		if (!sources.IsEmpty)
			return;
		for (let camera in scene.Cameras)
		{
			if (camera.IsActiveAndEnabled)
				sources.Add((camera.Transform.Position, 0));
		}
	}

	/// One frame of streaming while the game runs: cells come in round the sources (read in the background, one
	/// added a frame), far ones go, stand-ins show for the cells between, and the floating origin follows.
	public void Update(Scene scene)
	{
		let env = scene.Environment;
		let sources = scope List<(Vector3 position, float extra)>();
		Sources(scene, sources);
		if (sources.IsEmpty)
			return;
		if (env.floatingOrigin > 0 && scene.Network == null)
		{
			let first = sources[0].position;
			if (Math.Sqrt(first.x * first.x + first.z * first.z) > env.floatingOrigin)
			{
				let size = env.streamCellSize;
				ShiftOrigin(scene, .(Math.Round(first.x / size) * size, 0, Math.Round(first.z / size) * size));
				sources.Clear();
				Sources(scene, sources);
			}
		}
		// The first frame: what is near the sources now, at once.
		if (!mPrimed)
		{
			mPrimed = true;
			for (let source in sources)
				LoadAround(scene, source.position, source.extra);
		}

		let unload = scope List<int64>();
		for (let key in mCells)
		{
			float nearest = float.MaxValue;
			float extra = 0;
			for (let source in sources)
			{
				let distance = Distance(scene, key, source.position) - source.extra;
				if (distance < nearest)
				{
					nearest = distance;
					extra = source.extra;
				}
			}
			let loaded = mLoaded.Contains(key);
			if (!loaded && nearest <= env.streamLoadRadius && !mLoading.ContainsKey(key) && mLoading.Count < MaxLoading)
			{
				let held = mHeld.GetValueOrDefault(key);
				mLoading[key] = new CellLoad(CellFile(key, .. scope .()), held);
			}
			else if (loaded && nearest > env.streamLoadRadius + env.streamCellSize * 0.5f)
				unload.Add(key);
			if (!loaded && nearest <= env.streamStandInRadius)
				ShowStandIn(scene, key);
			else if (loaded || nearest > env.streamStandInRadius + env.streamCellSize)
				HideStandIn(scene, key);
		}
		for (let key in unload)
			Unload(scene, key, false);
		// One cell added a frame, once its file and what it names are loaded, so that there is no hitch.
		int64 ready = 0;
		bool found = false;
		for (let (key, load) in mLoading)
		{
			if (load.Step())
			{
				ready = key;
				found = true;
				break;
			}
		}
		if (found && mLoading.GetAndRemove(ready) case .Ok(let pair))
		{
			let load = pair.value;
			if (!load.Failed)
			{
				// Held text (play mode in the editor) is used once, by this load.
				if (mHeld.GetAndRemove(ready) case .Ok(let held))
					delete held.value;
				Add(scene, ready, load.Text);
			}
			delete load;
		}
	}

	/// Moves the whole scene back by shift (the floating origin): every top-level object, physics bodies, characters
	/// and static colliders. Origin keeps the sum.
	public void ShiftOrigin(Scene scene, Vector3 shift)
	{
		for (let root in scene.Roots)
			root.Transform.Position = root.Transform.Position - shift;
		Origin += shift;
		for (let body in scene.Components<Rigidbody>(.. scope .()))
		{
			if (body.HasBody)
			{
				var state = body.State;
				state.position -= shift;
				body.SetState(state);
			}
		}
		for (let component in scene.Components)
		{
			if (let character = component as CharacterController)
				character.Teleport(character.Transform.Position, character.Velocity);
			else if (let collider = component as Collider)
			{
				if (!collider.HasComponent<Rigidbody>())
					collider.Refresh();
			}
		}
	}

	void ShowStandIn(Scene scene, int64 key)
	{
		if (mStandIns.TryGetValue(key, let id) && scene.FindById(id) != null)
			return;
		let file = StandInFile(key, .. scope .());
		if (!AssetPack.Exists(file))
			return;
		let standIn = scene.CreateGameObject(scope $"Stand-in {KeyX(key)},{KeyZ(key)}");
		standIn.Transient = true;
		standIn.Transform.Position = -Origin;
		let renderer = standIn.AddComponent<MeshRenderer>();
		renderer.mesh.Set(Assets.MakeRelative(file, .. scope .()));
		renderer.flatShading = false;
		renderer.castShadows = false;
		mStandIns[key] = standIn.Id;
	}

	void HideStandIn(Scene scene, int64 key)
	{
		if (mStandIns.GetAndRemove(key) case .Ok(let pair))
		{
			let standIn = scene.FindById(pair.value);
			if (standIn != null)
				scene.DestroyImmediate(standIn);
		}
	}

	/// Shows the stand-in of every cell that is not loaded (the editor's view of the whole world).
	public void ShowAllStandIns(Scene scene)
	{
		for (let key in mCells)
		{
			if (!mLoaded.Contains(key))
				ShowStandIn(scene, key);
		}
	}

	public bool HasStandIn(Scene scene, int64 key) => mStandIns.TryGetValue(key, let id) && scene.FindById(id) != null;

	// ---- play mode in the editor ----

	/// The state to go back to when play mode stops (the scene itself comes back from its snapshot).
	public class State
	{
		public HashSet<int64> loaded = new .() ~ delete _;
		public Dictionary<int64, String> held = new .() ~ DeleteDictionaryAndValues!(_);
		public Vector3 origin;
	}

	public State SaveState()
	{
		let state = new State();
		for (let key in mLoaded)
			state.loaded.Add(key);
		for (let (key, text) in mHeld)
			state.held[key] = new String(text);
		state.origin = Origin;
		return state;
	}

	public void RestoreState(State state)
	{
		mLoaded.Clear();
		for (let key in state.loaded)
			mLoaded.Add(key);
		for (let text in mHeld.Values)
			delete text;
		mHeld.Clear();
		for (let (key, text) in state.held)
			mHeld[key] = new String(text);
		for (let load in mLoading.Values)
			delete load;
		mLoading.Clear();
		mStandIns.Clear();
		Origin = state.origin;
		mPrimed = false;
	}
}

/// A cell being read in the background: its file, then the models and textures it names.
class CellLoad
{
	String mPath = new .() ~ delete _;
	String mText = new .() ~ delete _;
	List<(String path, AssetLoader.Kind kind)> mReferences = new .() ~ { for (let entry in _) delete entry.path; delete _; };
	AssetLoader.Batch mBatch ~ delete _;
	Thread mThread ~ delete _;
	volatile bool mRead, mFailed;

	public StringView Text => mText;
	public bool Failed => mFailed;

	public this(StringView path, String held)
	{
		mPath.Set(path);
		if (held != null)
		{
			mText.Set(held);
			SceneManager.References(mText, mReferences);
			mRead = true;
			return;
		}
#if BF_PLATFORM_WASM
		Read();
#else
		mThread = new .(new => Read);
		mThread.SetName("Cell loading");
		mThread.Start(false);
#endif
	}

	public ~this()
	{
		mThread?.Join();
	}

	void Read()
	{
		if (AssetPack.ReadAllText(mPath, mText) case .Err)
			mFailed = true;
		else
			SceneManager.References(mText, mReferences);
		mRead = true;
	}

	/// True once it is ready to add (or failed).
	public bool Step()
	{
		if (!mRead)
			return false;
		if (mFailed)
			return true;
		if (mBatch == null)
		{
			mBatch = new .();
			for (let entry in mReferences)
				AssetLoader.Add(mBatch, entry.path, entry.kind);
		}
		return mBatch.IsDone;
	}
}
