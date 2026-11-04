using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Required on every data asset class, as [Component] is on components: it keeps the class's fields visible to the
/// Inspector and the asset loader.
[AttributeUsage(.Class, .AlwaysIncludeTarget | .ReflectAttribute, ReflectUser = .All, AlwaysIncludeUser = .AssumeInstantiated | .IncludeAllMethods)]
struct DataAssetAttribute : Attribute
{
}

/// A file of data that every script shares: game settings, a table of weapons, the levels in order. Write a class,
/// make the file in the Project window (+ > Data Asset), fill it in in the Inspector, and read it from anywhere:
///
///   [DataAsset]
///   class GameSettings : DataAsset
///   {
///       public float maxFieldOfView = 95;      // set in the Inspector, the same for every player
///       [Saved] public float volume = 0.8f;      // each player's own: kept with their files
///       [Saved] public String name = new .("Player") ~ delete _;
///   }
///
///   let settings = DataAsset.Get<GameSettings>();     // the project's GameSettings asset, loaded once and shared
///   settings.volume = 0.5f;
///   settings.Save();                                  // keeps the player's [Saved] fields
///
/// The asset file (.tdata) holds what was set in the editor, and ships with the game. Fields marked [Saved] are the
/// player's to change: Save keeps them in the player's folder (GamePaths.PlayerData), and the next Get finds them
/// there and puts them over the file's values. Revert goes back to the file's.
///
/// A class with no asset file still works: Get makes one with the values written in the code.
abstract class DataAsset
{
	static Dictionary<String, DataAsset> sLoaded = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static Dictionary<String, String> sFileOfType ~ DeleteDictionaryAndKeysAndValues!(_);
	static SaveStorage sStorage ~ delete _;
	static List<(DataAsset asset, SaveTask task)> sReading = new .() ~ { for (let entry in _) delete entry.task; delete _; };

	/// The asset file, relative to the asset folder ("Data/Settings.tdata"), or the class's name for one with no file.
	public readonly String AssetPath = new .() ~ delete _;

	/// Writes or reads the [Saved] fields: the compiler writes this for classes with [Saved] fields.
	public virtual void SaveFields(SaveIO io) { }
	/// Called after the player's copy has been put over the file's values (at Get, Load, or when it arrives).
	public virtual void OnLoaded() { }

	/// Where players' copies are kept: files in GamePaths.PlayerData + "data/" until set. Setting it takes ownership.
	public static SaveStorage Storage
	{
		get
		{
			if (sStorage == null)
				sStorage = new FileSaveStorage(scope $"{GamePaths.PlayerData}data");
			return sStorage;
		}
		set
		{
			if (sStorage != value)
				delete sStorage;
			sStorage = value;
		}
	}

	// ---- finding and loading ----

	/// The asset at a path (relative to the asset folder), loaded once and shared by everyone who asks.
	public static T Get<T>(StringView path) where T : DataAsset
	{
		if (sLoaded.TryGetValueAlt(path, let found))
			return found as T;
		let asset = Load(path, typeof(T));
		return asset as T;
	}

	/// The project's asset of this class: the first .tdata file made from it (or, with none, one with the code's
	/// values). Loaded once and shared.
	public static T Get<T>() where T : DataAsset
	{
		let path = scope String();
		if (!FileOf(typeof(T), path))
			typeof(T).GetFullName(path);
		return Get<T>(path);
	}

	/// Every asset file of a class, for a game with several (one per level, say).
	public static void FilesOf(Type type, List<String> paths)
	{
		Index();
		let name = type.GetFullName(.. scope .());
		for (let entry in sFileOfType)
		{
			if (entry.value == name)
				paths.Add(new String(entry.key));
		}
		paths.Sort(scope (a, b) => a.CompareTo(b));
	}

	static bool FileOf(Type type, String path)
	{
		let paths = scope List<String>();
		FilesOf(type, paths);
		defer
		{
			ClearAndDeleteItems!(paths);
		}
		if (paths.IsEmpty)
			return false;
		path.Set(paths[0]);
		return true;
	}

	/// Finds the .tdata files and what class each is, once.
	static void Index()
	{
		if (sFileOfType != null)
			return;
		sFileOfType = new .();
		let root = scope String(Assets.ProjectPath);
		let files = scope List<String>();
		defer
		{
			ClearAndDeleteItems!(files);
		}
		if (AssetPack.Mounted)
			AssetPack.FilesIn(root, files);
		else
			ListFiles(root, files);
		for (let file in files)
		{
			if (!file.EndsWith(".tdata"))
				continue;
			let text = scope String();
			if (AssetPack.ReadAllText(file, text) case .Err)
				continue;
			let typeName = scope String();
			if (!TypeNameIn(text, typeName))
				continue;
			let relative = scope String();
			let single = scope String(root);
			while (single.Contains("//"))
				single.Replace("//", "/");
			if (file.StartsWith(single) && file.Length > single.Length && file[single.Length] == '/')
				relative.Append(file.Substring(single.Length + 1));
			else
				Assets.MakeRelative(file, relative);
			sFileOfType[new String(relative)] = new String(typeName);
		}
	}

	static void ListFiles(StringView folder, List<String> files)
	{
		if (!Directory.Exists(folder))
			return;
		for (let entry in Directory.Enumerate(folder))
		{
			let path = entry.GetFilePath(.. scope .());
			let name = entry.GetFileName(.. scope .());
			if (name.StartsWith('.') || name == "build")
				continue;
			if (entry.IsDirectory)
				ListFiles(path, files);
			else
				files.Add(new String(path));
		}
	}

	static bool TypeNameIn(StringView text, String typeName)
	{
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("dataasset "))
			{
				typeName.Set(line.Substring(10));
				typeName.Trim();
				return true;
			}
		}
		return false;
	}

	/// The class of that name, if it is a data asset class in this program.
	public static Type TypeNamed(StringView name)
	{
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type == null || !type.IsObject || type.IsAbstract || !type.IsSubtypeOf(typeof(DataAsset)))
				continue;
			if (type.GetFullName(.. scope .()) == name)
				return type;
		}
		return null;
	}

	/// Every data asset class in the program, for the editor's menu.
	public static void Types(List<Type> types)
	{
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type != null && type.IsObject && !type.IsAbstract && type.IsSubtypeOf(typeof(DataAsset)) && type != typeof(DataAsset))
				types.Add(type);
		}
	}

	/// A new asset of a class with the code's values, not shared: the editor uses this.
	public static DataAsset Create(Type type)
	{
		if (type == null)
			return null;
		Object created = null;
		if (type.CreateObject() case .Ok(let made))
			created = made;
		else
			return null;
		let asset = created as DataAsset;
		if (asset == null)
			delete created;
		return asset;
	}

	static DataAsset Load(StringView path, Type wanted)
	{
		let full = scope String();
		Assets.ResolvePath(path, full);
		let text = scope String();
		var type = wanted;
		var hasFile = false;
		if (path.EndsWith(".tdata") && AssetPack.ReadAllText(full, text) case .Ok)
		{
			hasFile = true;
			let typeName = scope String();
			if (TypeNameIn(text, typeName))
			{
				let named = TypeNamed(typeName);
				if (named != null && (wanted == null || named == wanted || named.IsSubtypeOf(wanted)))
					type = named;
			}
		}
		let asset = Create(type);
		if (asset == null)
		{
			Log.Error(scope $"Data asset {path}: its class could not be made.");
			return null;
		}
		asset.AssetPath.Set(path);
		if (hasFile)
			asset.ReadText(text);
		sLoaded[new String(path)] = asset;
		asset.Load();
		return asset;
	}

	// ---- the player's copy ----

	void SlotName(String slot)
	{
		slot.Append(AssetPath);
		if (slot.EndsWith(".tdata"))
			slot.RemoveFromEnd(6);
	}

	/// Keeps the [Saved] fields in the player's folder (or Storage).
	public void Save()
	{
		let io = scope SaveIO();
		SaveFields(io);
		let task = scope SaveTask(.Save, SlotName(.. scope .()));
		io.Root.ToBytes(task.data);
		Storage.Write(task);
		if (task.Done && !task.Succeeded)
			Log.Error(scope $"Could not keep {AssetPath}: {task.error}");
	}

	/// Puts the player's copy of the [Saved] fields back over the current values. With a storage that answers later,
	/// it happens when the answer arrives (SaveSystem.Update), and OnLoaded says so.
	public void Load()
	{
		let task = new SaveTask(.Load, SlotName(.. scope .()));
		Storage.Read(task);
		if (!task.Done)
		{
			sReading.Add((this, task));
			return;
		}
		Finish(task);
		delete task;
	}

	void Finish(SaveTask task)
	{
		if (!task.Succeeded || !task.Found)
			return;
		let node = SaveNode.FromBytes(task.data);
		if (node == null)
		{
			Log.Error(scope $"The player's copy of {AssetPath} is damaged; the asset's values are used.");
			return;
		}
		let io = scope SaveIO(node);
		SaveFields(io);
		delete node;
		OnLoaded();
	}

	/// Forgets the player's copy and goes back to the values in the asset file (or the code).
	public void Revert()
	{
		Storage.Delete(SlotName(.. scope .()));
		let fresh = Create(GetType());
		if (fresh == null)
			return;
		defer delete fresh;
		let full = scope String();
		Assets.ResolvePath(AssetPath, full);
		let text = scope String();
		if (AssetPath.EndsWith(".tdata") && AssetPack.ReadAllText(full, text) case .Ok)
			fresh.ReadText(text);
		// The file's values, and the code's for [Saved] fields: copied over through a save of the fresh one.
		let io = scope SaveIO();
		fresh.SaveFields(io);
		let back = scope SaveIO(io.Root);
		SaveFields(back);
		if (!text.IsEmpty)
			ReadText(text);
		OnLoaded();
	}

	/// Copies arriving from a storage that answered later. Called by SaveSystem.Update.
	public static void Poll()
	{
		for (int i = sReading.Count - 1; i >= 0; i--)
		{
			let entry = sReading[i];
			if (!entry.task.Done)
				continue;
			sReading.RemoveAt(i);
			entry.asset.Finish(entry.task);
			delete entry.task;
		}
	}

	/// Drops every loaded asset and the file index (the editor calls this after scripts reload or play stops).
	/// Goes up each time ClearCache drops the loaded assets: code that keeps an asset can tell it must Get it again.
	public static int CacheVersion { get; private set; }

	public static void ClearCache()
	{
		CacheVersion++;
		for (let entry in sReading)
			delete entry.task;
		sReading.Clear();
		for (let entry in sLoaded)
		{
			delete entry.key;
			delete entry.value;
		}
		sLoaded.Clear();
		if (sFileOfType != null)
			DeleteDictionaryAndKeysAndValues!(sFileOfType);
		sFileOfType = null;
	}

	// ---- the file ----

	/// The asset file's text: the class, each field the Inspector shows, and the [Saved] fields that it cannot (lists
	/// and the like) as one line of JSON.
	public void WriteText(String text)
	{
		text.AppendF("dataasset {}\n", GetType().GetFullName(.. scope .()));
		let fields = scope List<FieldRef>();
		ComponentRegistry.GetFields(this, typeof(DataAsset), fields);
		for (let field in fields)
		{
			// No scene to refer to; and [Saved] fields go in the "saved" line below.
			if (field.HoldsReferences || ((field.kind == .List || field.kind == .Array) && field.saved))
				continue;
			text.AppendF("field {} ", field.name);
			SceneSerializer.WriteValue(field, text);
			text.Append('\n');
		}
		let io = scope SaveIO();
		SaveFields(io);
		if (io.Root.Count > 0)
		{
			text.Append("saved ");
			io.Root.ToText(text, false);
			text.Append('\n');
		}
	}

	public void ReadText(StringView text)
	{
		let fields = scope List<FieldRef>();
		ComponentRegistry.GetFields(this, typeof(DataAsset), fields);
		let tokens = scope List<StringView>();
		let storage = scope List<String>();
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("saved "))
			{
				let node = SaveNode.FromText(line.Substring(6));
				if (node != null)
				{
					let io = scope SaveIO(node);
					SaveFields(io);
					delete node;
				}
				continue;
			}
			if (!line.StartsWith("field "))
				continue;
			tokens.Clear();
			ClearAndDeleteItems!(storage);
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 3)
				continue;
			for (let field in fields)
			{
				if (field.name == tokens[1] && !field.HoldsReferences)
				{
					SceneSerializer.ReadValue(field, Span<StringView>(tokens.Ptr + 2, tokens.Count - 2));
					break;
				}
			}
		}
		ClearAndDeleteItems!(storage);
	}
}
