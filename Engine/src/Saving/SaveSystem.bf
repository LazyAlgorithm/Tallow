using System;
using System.Collections;

namespace Tallow;

/// Saves and loads the game. Mark the fields to keep with [Saved], then:
///
///   SaveSystem.Save();            // or Save("slot2")
///   SaveSystem.Load();
///
/// Save gathers every [Saved] field of every component in the scene (Capture), turns it into bytes and hands them
/// to the Storage (a file by default). Load does the reverse (Apply): it changes to the saved scene if another one
/// is playing, takes away scene objects that had been destroyed, makes again the objects that had been made while
/// playing (from prefabs, with a SavedTransform or [Saved] fields), and puts every field back. OnLoaded is then
/// called on each component that was loaded, to rebuild whatever it makes from its fields.
///
/// Turn on LoadAtStart (or "Load the save when the game starts" in Project Settings) and the save is put back as
/// the first scene starts: after its objects are made and before any script's Awake, so scripts only ever see the
/// loaded values. With a storage that answers later (a server), the scene waits for it, up to StartTimeout seconds.
///
/// In a network session only the server saves and loads; what it loads reaches the clients as usual.
///
/// Save and Load return a SaveHandle: a number to ask about later (Done, Succeeded, Found, Error), which stays
/// valid however long it is kept.
static class SaveSystem
{
	struct Outcome
	{
		public bool done, succeeded, found;
		public String error;
	}

	static int32 sNextId = 1;
	static Dictionary<int32, Outcome> sOutcomes = new .() ~ { for (let value in _.Values) delete value.error; delete _; };
	static List<int32> sOutcomeOrder = new .() ~ delete _;

	static SaveStorage sStorage ~ delete _;
	static List<SaveTask> sTasks = new .() ~ DeleteContainerAndItems!(_);
	static HashSet<uint32> sInitial = new .() ~ delete _;
	static Scene sInitialScene;
	/// A save waiting for its scene to start.
	static SaveNode sPendingApply ~ delete _;
	static SaveTask sStartTask;
	static double sStartAsked;
	static bool sStartDone;

	/// Put the save in StartSlot back when the game's first scene starts.
	public static bool LoadAtStart;
	public static String StartSlot = new .("default") ~ delete _;
	/// How long a scene waits at start for a storage that answers later, in seconds.
	public static float StartTimeout = 10;

	/// Called on the frame a save has been written (or failed: see task.Succeeded and task.error).
	public static Event<delegate void(SaveTask task)> Saved ~ _.Dispose();
	/// Called on the frame a save has been put back, or could not be.
	public static Event<delegate void(SaveTask task)> Loaded ~ _.Dispose();

	/// Where saves are kept: files in the player's folder until set. Setting it takes ownership.
	public static SaveStorage Storage
	{
		get
		{
			if (sStorage == null)
				sStorage = new FileSaveStorage();
			return sStorage;
		}
		set
		{
			if (sStorage != value)
				delete sStorage;
			sStorage = value;
		}
	}

	// Saves are kept under names: "default", "slot 2", "My Castle". Any text works; a storage turns it into
	// whatever it needs (FileSaveStorage into a file name it can turn back).

	/// Whether a slot holds a save (as far as the storage can tell without waiting).
	public static bool Exists(StringView slot = "default") => Storage.Exists(slot);
	public static void Delete(StringView slot = "default") => Storage.Delete(slot);
	public static void ListSlots(List<String> slots) => Storage.List(slots);

	static bool MaySave(Scene scene, SaveTask task)
	{
		if (scene == null)
		{
			task.Fail("No scene is playing.");
			return false;
		}
		if (scene.Network != null && scene.Network.Mode != .Offline && !scene.Network.IsServer)
		{
			task.Fail("Only the server saves and loads in a network session.");
			return false;
		}
		return true;
	}

	/// Saves the scene that is playing into a slot. The returned task says when it is done (it is kept until the
	/// frame after); the Saved event says the same.
	public static SaveHandle Save(StringView slot = "default")
	{
		let task = new SaveTask(.Save, slot);
		task.[Friend]mId = sNextId++;
		sTasks.Add(task);
		let scene = Scene.Active;
		if (!MaySave(scene, task))
			return .(task.[Friend]mId);
		let data = Capture(scene);
		data.ToBytes(task.data);
		delete data;
		Storage.Write(task);
		return .(task.[Friend]mId);
	}

	/// Loads a slot into the game: at once when the storage has it to hand, otherwise when it arrives.
	public static SaveHandle Load(StringView slot = "default")
	{
		let task = new SaveTask(.Load, slot);
		task.[Friend]mId = sNextId++;
		sTasks.Add(task);
		if (!MaySave(Scene.Active, task))
			return .(task.[Friend]mId);
		Storage.Read(task);
		if (task.Done)
		{
			task.[Friend]mApplied = true;
			FinishLoad(task);
		}
		return .(task.[Friend]mId);
	}

	static void FinishLoad(SaveTask task)
	{
		if (!task.Succeeded || !task.Found)
			return;
		let data = SaveNode.FromBytes(task.data);
		if (data == null)
		{
			task.Fail("The save is damaged or from a newer version of the game.");
			return;
		}
		Apply(data, Scene.Active);
		delete data;
	}

	/// Once a frame, from the application: finishes saves and loads whose storage answered, and fires the events.
	public static void Update()
	{
		DataAsset.Poll();
		for (int i = sTasks.Count - 1; i >= 0; i--)
		{
			let task = sTasks[i];
			if (!task.Done)
				continue;
			if (task == sStartTask)
				continue;
			if (task.kind == .Load && !task.[Friend]mApplied)
			{
				task.[Friend]mApplied = true;
				FinishLoad(task);
			}
			if (!task.[Friend]mReported)
			{
				task.[Friend]mReported = true;
				Remember(task);
				if (task.kind == .Save)
					Saved(task);
				else
					Loaded(task);
				if (!task.Succeeded)
					Log.Error(scope $"{task.kind == .Save ? "Saving" : "Loading"} '{task.slot}' failed: {task.error}");
			}
			sTasks.RemoveAt(i);
			delete task;
		}
	}

	/// What became of a save or load, for SaveHandle: from the task while it is still going, then from a record
	/// of the last few hundred.
	static Outcome OutcomeOf(int32 id)
	{
		for (let task in sTasks)
		{
			if (task.[Friend]mId == id)
				return .() { done = task.Done, succeeded = task.Succeeded, found = task.Found, error = task.error };
		}
		if (sOutcomes.TryGetValue(id, let outcome))
			return outcome;
		return .() { done = true };
	}

	static void Remember(SaveTask task)
	{
		sOutcomes[task.[Friend]mId] = .() { done = true, succeeded = task.Succeeded, found = task.Found, error = new String(task.error) };
		sOutcomeOrder.Add(task.[Friend]mId);
		if (sOutcomeOrder.Count > 256)
		{
			if (sOutcomes.GetAndRemove(sOutcomeOrder[0]) case .Ok(let old))
				delete old.value.error;
			sOutcomeOrder.RemoveAt(0);
		}
	}

	// ---- starting a scene ----

	/// A new run of the game (the editor's Play): LoadAtStart applies again.
	public static void NewRun()
	{
		sStartDone = false;
		DeleteAndNullify!(sPendingApply);
	}

	/// Scene.StartPlay asks this first. True holds the scene back (its save is still on its way); it asks again
	/// each frame until false, and then the scene wakes up.
	public static bool HoldStart(Scene scene)
	{
		if (!sStartDone && LoadAtStart && sPendingApply == null)
		{
			if (sStartTask == null)
			{
				sStartTask = new SaveTask(.Load, StartSlot);
				sTasks.Add(sStartTask);
				sStartAsked = Time.RealTime;
				Storage.Read(sStartTask);
			}
			if (!sStartTask.Done && Time.RealTime - sStartAsked < StartTimeout)
				return true;
			sStartDone = true;
			let task = sStartTask;
			sStartTask = null;
			task.[Friend]mApplied = true;
			if (!task.Done)
				task.Fail("The storage did not answer in time; starting without the save.");
			else if (task.Succeeded && task.Found)
			{
				let data = SaveNode.FromBytes(task.data);
				if (data == null)
					task.Fail("The save is damaged or from a newer version of the game.");
				else
				{
					// Applied below, once the scene's own objects are counted.
					sPendingApply = data;
					let saved = data["scene"];
					if (saved != null && saved.kind == .String && !SameScene(scene, saved.text))
					{
						// The save is of another scene: start that one instead, and apply it there.
						SceneManager.Load(saved.text);
					}
				}
			}
		}
		sStartDone = true;
		return false;
	}

	/// Scene.StartPlay calls this after HoldStart, before any component wakes: the scene's own objects are
	/// remembered (so that ones destroyed later can be told apart), and a save waiting for this scene is applied.
	public static void SceneStarting(Scene scene)
	{
		sInitial.Clear();
		sInitialScene = scene;
		for (let gameObject in scene.Objects)
			sInitial.Add(gameObject.Id);
		// A save waiting for this scene (loaded while another scene played, or at start).
		if (sPendingApply != null && SceneManager.Pending.IsEmpty)
		{
			let saved = sPendingApply["scene"];
			if (saved == null || saved.kind != .String || SameScene(scene, saved.text))
			{
				let data = sPendingApply;
				sPendingApply = null;
				ApplyObjects(data, scene);
				delete data;
			}
		}
	}

	static bool SameScene(Scene scene, StringView saved)
	{
		if (saved.IsEmpty)
			return true;
		let current = SceneManager.Current.IsEmpty ? StringView(scene.Path) : SceneManager.Current;
		let a = scope String(current)..Replace('\\', '/');
		let b = scope String(saved)..Replace('\\', '/');
		return a == b || a.EndsWith(scope $"/{b}") || b.EndsWith(scope $"/{a}");
	}

	// ---- capturing ----

	/// Object references while saving or loading: each object used gets a number, kept in the save as its key.
	class References : ISaveReferences
	{
		public Scene scene;
		public List<String> keys = new .() ~ DeleteContainerAndItems!(_);
		public Dictionary<GameObject, int64> numbers = new .() ~ delete _;
		public Dictionary<String, GameObject> byKey = new .() ~ DeleteDictionaryAndKeys!(_);

		public int64 KeyOf(GameObject gameObject)
		{
			if (numbers.TryGetValue(gameObject, let number))
				return number;
			let key = scope String();
			if (!SaveSystem.KeyOf(gameObject, key))
				return 0;
			keys.Add(new String(key));
			numbers[gameObject] = keys.Count;
			return keys.Count;
		}

		public GameObject Find(int64 number)
		{
			if (number < 1 || number > keys.Count)
				return null;
			if (byKey.TryGetValueAlt(keys[(int)number - 1], let found))
				return found;
			return null;
		}
	}

	/// Played by someone: a player's own object is theirs, not the save's.
	static bool OwnedByPlayer(GameObject gameObject)
	{
		var check = gameObject.Transform;
		while (check != null)
		{
			let identity = check.GameObject.GetComponent<NetworkIdentity>();
			if (identity != null && identity.ownerId != 0)
				return true;
			check = check.Parent;
		}
		return false;
	}

	/// The object made while playing that this one belongs to (itself, or the one it is part of), or null.
	static GameObject SpawnedRoot(GameObject gameObject)
	{
		var check = gameObject.Transform;
		while (check != null)
		{
			let candidate = check.GameObject;
			if (sInitial.Contains(candidate.Id) && sInitialScene == candidate.Scene)
				return null;
			if (candidate.SpawnedFrom != null && !candidate.SpawnedFrom.IsEmpty)
				return candidate;
			check = check.Parent;
		}
		return null;
	}

	/// How an object is known in a save: its id for one that came with the scene; for one made while playing, the
	/// id the object it was made from had, then the path of child numbers down to it.
	static bool KeyOf(GameObject gameObject, String key)
	{
		if (gameObject == null || gameObject.Transient || OwnedByPlayer(gameObject))
			return false;
		if (sInitial.Contains(gameObject.Id))
		{
			key.AppendF("{}", gameObject.Id);
			return true;
		}
		let root = SpawnedRoot(gameObject);
		if (root == null)
			return false;
		let path = scope List<int>();
		var check = gameObject.Transform;
		while (check != null && check.GameObject != root)
		{
			let parent = check.Parent;
			if (parent == null)
				return false;
			path.Add(parent.Children.IndexOf(check));
			check = parent;
		}
		key.AppendF("{}", root.Id);
		for (int i = path.Count - 1; i >= 0; i--)
			key.AppendF("/{}", path[i]);
		return true;
	}

	static bool HasSavedContent(GameObject root)
	{
		for (let component in root.Components)
		{
			if (component.HasSavedFields)
				return true;
		}
		if (HandlesWithSaves(root, scope .()) > 0)
			return true;
		for (let child in root.Transform.Children)
		{
			if (HasSavedContent(child.GameObject))
				return true;
		}
		return false;
	}

	/// The built-in components on an object whose data has [Saved] fields (keyed by their full name, one per object).
	static int HandlesWithSaves(GameObject gameObject, List<HandleComponents.Info> output)
	{
		let all = scope List<HandleComponents.Info>();
		HandleComponents.On(gameObject, all);
		for (let info in all)
		{
			if (info.Saves)
				output.Add(info);
		}
		return output.Count;
	}

	static void ComponentKey(Component component, String key)
	{
		component.GetType().GetFullName(key);
		int index = 0;
		for (let other in component.GameObject.Components)
		{
			if (other == component)
				break;
			if (other.GetType() == component.GetType())
				index++;
		}
		if (index > 0)
			key.AppendF("#{}", index);
	}

	/// The [Saved] state of a scene as a tree, for code that keeps saves its own way. Delete it when done.
	public static SaveNode Capture(Scene scene = null)
	{
		let target = scene ?? Scene.Active;
		let root = new SaveNode(.Object);
		if (target == null)
			return root;
		for (let gameObject in target.Objects)
		{
			for (let component in gameObject.Components)
			{
				if (component.HasSavedFields)
					component.OnSaving();
			}
			for (let info in HandlesWithSaves(gameObject, .. scope .()))
			{
				if (info.onSaving != null)
					info.onSaving(gameObject);
			}
		}
		root.Set("format", SaveNode.MakeInt(1));
		root.Set("scene", SaveNode.MakeString(SceneManager.Current.IsEmpty ? StringView(target.Path) : SceneManager.Current));
		// Scene objects that are gone.
		let removed = new SaveNode(.List);
		if (sInitialScene == target)
		{
			let present = scope HashSet<uint32>();
			for (let gameObject in target.Objects)
			{
				if (!gameObject.IsDestroyed)
					present.Add(gameObject.Id);
			}
			let gone = scope List<uint32>();
			for (let id in sInitial)
			{
				if (!present.Contains(id))
					gone.Add(id);
			}
			gone.Sort();
			for (let id in gone)
				removed.items.Add(SaveNode.MakeInt(id));
		}
		root.Set("removed", removed);
		// Objects made while playing that have something to keep.
		let spawned = new SaveNode(.List);
		for (let gameObject in target.Objects)
		{
			if (gameObject.IsDestroyed || gameObject.SpawnedFrom == null || gameObject.SpawnedFrom.IsEmpty || sInitial.Contains(gameObject.Id))
				continue;
			if (SpawnedRoot(gameObject) != gameObject || OwnedByPlayer(gameObject) || !HasSavedContent(gameObject))
				continue;
			let entry = new SaveNode(.Object);
			entry.Set("key", SaveNode.MakeInt(gameObject.Id));
			entry.Set("from", SaveNode.MakeString(gameObject.SpawnedFrom));
			spawned.items.Add(entry);
		}
		root.Set("spawned", spawned);
		// Every [Saved] field.
		let references = scope References() { scene = target };
		let objects = new SaveNode(.Object);
		let key = scope String();
		let componentKey = scope String();
		for (let gameObject in target.Objects)
		{
			if (gameObject.IsDestroyed)
				continue;
			SaveNode entry = null;
			for (let component in gameObject.Components)
			{
				if (!component.HasSavedFields)
					continue;
				if (entry == null)
				{
					key.Clear();
					if (!KeyOf(gameObject, key))
						break;
					entry = new SaveNode(.Object);
				}
				let io = scope SaveIO();
				io.references = references;
				component.SaveFields(io);
				componentKey.Clear();
				ComponentKey(component, componentKey);
				entry.Set(componentKey, io.TakeRoot());
			}
			// Built-in components' [Saved] data fields, keyed by the component's name.
			for (let info in HandlesWithSaves(gameObject, .. scope .()))
			{
				if (entry == null)
				{
					key.Clear();
					if (!KeyOf(gameObject, key))
						break;
					entry = new SaveNode(.Object);
				}
				let io = scope SaveIO();
				io.references = references;
				info.Save(gameObject, io);
				entry.Set(info.fullName, io.TakeRoot());
			}
			if (entry != null)
				objects.Set(key, entry);
		}
		root.Set("objects", objects);
		let keys = new SaveNode(.List);
		for (let referenced in references.keys)
			keys.items.Add(SaveNode.MakeString(referenced));
		root.Set("references", keys);
		return root;
	}

	// ---- applying ----

	/// Puts a captured state back into the scene that is playing, or, if it is of another scene, changes to that
	/// scene and puts it back as soon as that scene has started.
	public static void Apply(SaveNode data, Scene scene = null)
	{
		let target = scene ?? Scene.Active;
		if (target == null || data == null)
			return;
		let saved = data["scene"];
		if (saved != null && saved.kind == .String && !SameScene(target, saved.text))
		{
			DeleteAndNullify!(sPendingApply);
			sPendingApply = data.Clone();
			SceneManager.Load(saved.text);
			return;
		}
		ApplyObjects(data, target);
	}

	static GameObject Respawn(Scene scene, StringView from)
	{
		if (from.EndsWith(".tprefab"))
			return Prefab.Instantiate(scene, from);
		if (scene.Network != null && scene.Network.Mode != .Offline && scene.Network.IsServer)
			return scene.Network.Spawn(from, .Zero, .Identity, 0);
		if (NetworkManager.IsRegistered(from))
			return NetworkManager.CreateRegistered(scene, from);
		Log.Error(scope $"A saved object was made from '{from}', which is neither a prefab file nor a registered prefab.");
		return null;
	}

	static void ApplyObjects(SaveNode data, Scene scene)
	{
		RemoveDestroyed(data, scene);
		let references = scope References() { scene = scene };
		RespawnSaved(data, scene, references);
		let keys = data["references"];
		if (keys != null && keys.kind == .List)
		{
			for (let item in keys.items)
				references.keys.Add(new String(item.kind == .String ? StringView(item.text) : ""));
		}
		let objects = data["objects"];
		if (objects == null || objects.kind != .Object)
			return;
		// Every object named anywhere in the save, found in the scene now.
		for (let key in objects.keys)
			Resolve(scene, references, key);
		for (let key in references.keys)
			Resolve(scene, references, key);

		let loaded = scope List<Component>();
		let loadedHandles = scope List<(GameObject, HandleComponents.Info)>();
		let componentKey = scope String();
		for (int i < objects.keys.Count)
		{
			if (!references.byKey.TryGetValueAlt(objects.keys[i], let gameObject))
				continue;
			let entry = objects.items[i];
			if (entry.kind != .Object)
				continue;
			for (let component in gameObject.Components)
			{
				if (!component.HasSavedFields)
					continue;
				componentKey.Clear();
				ComponentKey(component, componentKey);
				let fields = entry[componentKey];
				if (fields == null)
					continue;
				let io = scope SaveIO(fields);
				io.references = references;
				component.SaveFields(io);
				loaded.Add(component);
			}
			for (let info in HandlesWithSaves(gameObject, .. scope .()))
			{
				let fields = entry[info.fullName];
				if (fields == null)
					continue;
				let io = scope SaveIO(fields);
				io.references = references;
				info.Save(gameObject, io);
				if (info.onLoaded != null)
					loadedHandles.Add((gameObject, info));
			}
		}
		for (let component in loaded)
			component.OnLoaded();
		for (let (gameObject, info) in loadedHandles)
			info.onLoaded(gameObject);
	}

	/// Destroys the scene's own objects that had been destroyed when the game was saved.
	static void RemoveDestroyed(SaveNode data, Scene scene)
	{
		let removed = data["removed"];
		if (removed == null || removed.kind != .List)
			return;
		for (let item in removed.items)
		{
			let gameObject = scene.FindById((uint32)item.AsInteger);
			if (gameObject != null)
				scene.Destroy(gameObject);
		}
	}

	/// Objects made while playing: the ones there now go, and the saved ones are made again (each noted under its
	/// key, for references to find).
	static void RespawnSaved(SaveNode data, Scene scene, References references)
	{
		for (let gameObject in scene.Objects)
		{
			if (gameObject.IsDestroyed || gameObject.SpawnedFrom == null || gameObject.SpawnedFrom.IsEmpty || sInitial.Contains(gameObject.Id))
				continue;
			if (SpawnedRoot(gameObject) == gameObject && !OwnedByPlayer(gameObject) && HasSavedContent(gameObject))
				scene.Destroy(gameObject);
		}
		let spawned = data["spawned"];
		if (spawned == null || spawned.kind != .List)
			return;
		for (let entry in spawned.items)
		{
			let key = entry["key"];
			let from = entry["from"];
			if (key == null || from == null || from.kind != .String)
				continue;
			let made = Respawn(scene, from.text);
			if (made != null)
				references.byKey[new $"{key.AsInteger}" ] = made;
		}
	}

	/// Finds the object a save's key names and notes it in references.byKey. A key is the object's id (or, for one
	/// made while playing, its spawn key), then the index of a child at each level down: "12/0/3".
	static void Resolve(Scene scene, References references, StringView key)
	{
		if (references.byKey.ContainsKeyAlt(key))
			return;
		let parts = scope List<StringView>();
		for (let part in key.Split('/'))
			parts.Add(part);
		if (parts.IsEmpty)
			return;
		uint32 id = 0;
		if (uint32.Parse(parts[0]) case .Ok(let number))
			id = number;
		else
			return;
		GameObject found = null;
		if (references.byKey.TryGetValueAlt(parts[0], let spawnedRoot))
			found = spawnedRoot;
		else if (sInitial.Contains(id))
			found = scene.FindById(id);
		for (int i = 1; i < parts.Count && found != null; i++)
		{
			if (!(int.Parse(parts[i]) case .Ok(let index)) || index < 0 || index >= found.Transform.Children.Count)
			{
				found = null;
				break;
			}
			found = found.Transform.Children[index].GameObject;
		}
		if (found != null && !found.IsDestroyed)
			references.byKey[new String(key)] = found;
	}
}
