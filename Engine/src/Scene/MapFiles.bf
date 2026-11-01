using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// One map file found by MapFiles: what it says about itself, and anything wrong with it.
class MapFileInfo
{
	/// The .tmap file on disk.
	public String File = new .() ~ delete _;
	/// Stays the same when the file is renamed or copied: players with the same map have the same Id.
	public String Id = new .() ~ delete _;
	public String Name = new .() ~ delete _;
	public String Author = new .() ~ delete _;
	public String Description = new .() ~ delete _;
	/// The game it was made for (GamePaths.Game when it was exported).
	public String Game = new .() ~ delete _;
	public int32 Version;
	/// The whole file's hash (MapFiles.Hash, 16 hex digits) and size: players with the same Id and Hash have the
	/// same map, and one whose Hash differs has another version of it.
	public String Hash = new .() ~ delete _;
	public int64 Bytes;
	/// Why the map cannot be played, one reason a line. Empty when it can.
	public List<String> Problems = new .() ~ DeleteContainerAndItems!(_);
	/// The map's scene file, as text, for a game's own checks (CountComponents).
	public String SceneText = new .() ~ delete _;
	bool mMounted;

	public bool Ok => Problems.Count == 0;
	public bool Mounted => mMounted;

	/// Where the map's scene is while it is mounted, as a project path for SceneManager.Load or LoadAdditive.
	public void ScenePath(String path) => path.AppendF("{}/{}/{}", MapFiles.MountFolder, Id, MapFiles.SceneName);

	/// How many components of a type (its full name, "Tallow.SpawnPoint") the map's scene has.
	public int CountComponents(StringView typeName)
	{
		int count = 0;
		for (let line in SceneText.Split('\n'))
		{
			if (!line.StartsWith("component "))
				continue;
			var rest = line.Substring(10);
			let space = rest.IndexOf(' ');
			if (space >= 0)
				rest = rest.Substring(0, space);
			if (rest == typeName)
				count++;
		}
		return count;
	}

	public void AddProblem(StringView reason) => Problems.Add(new String(reason));

	void SetMounted(bool mounted) => mMounted = mounted;
}

/// Maps: a scene saved into one .tmap file (Export), which a game finds in a folder and plays without being built
/// again: a game's own map editor writes them. A map holds its scene and the scene's own data: terrain sculpting, and
/// any file the scene names under .maps/<Id>/ (a model the player brought in). Everything else it uses (the game's
/// models, prefabs, materials and scripts) comes from the game, so a map can only use what the game has.
///
///   let maps = scope List<MapFileInfo>();
///   defer { ClearAndDeleteItems!(maps); }
///   MapFiles.Find(MapFiles.Folder(.. scope .()), maps);
///   for (let map in maps)
///       if (map.Ok) ... // list map.Name in the menu
///
///   // To play one: mount it, then load its scene as any other.
///   if (MapFiles.Mount(map))
///       SceneManager.LoadAdditive(Scene, map.ScenePath(.. scope .()), true);
///
/// Find checks every map: that the file is whole (each file in it has a checksum), that it was made for this game and
/// by a version of the engine that can read it, that every component it uses exists in the game and that every file
/// it names is there, and that it has what the game's MapRules.txt asks for (MapRules). A map with a problem is still
/// returned, with Problems saying why, so a game can show or log it.
static class MapFiles
{
	public const String Extension = ".tmap";
	/// The version of the map format written by Export; Find refuses maps made with a later one.
	public const int32 FormatVersion = 1;
	/// The files of mounted maps appear in this folder of the project, one folder per map Id.
	public const String MountFolder = ".maps";
	public const String SceneName = "map.tscene";
	const String InfoName = "map.txt";

	/// File types a scene names as assets, which must be in the game for a map to work.
	static readonly StringView[?] AssetExtensions = .(".glb", ".gltf", ".tmesh", ".png", ".jpg", ".jpeg", ".tga", ".hdr", ".tmat", ".tprefab", ".tscene",
		".tanim", ".tcontroller", ".tshader", ".tsgraph", ".tgraph", ".tbt", ".tui", ".tcss", ".tinput", ".tdata", ".ogg", ".wav", ".mp3",
		".flac", ".ttf", ".otf");

	/// The folder a game looks in by default: Maps, beside a built game's program (or in the project's folder when
	/// it runs from the editor).
	public static void Folder(String path) => path.AppendF("{}Maps", GamePaths.GameFolder);

	/// Looks at every .tmap file in a folder (not its sub-folders) and adds what it finds to maps, sorted by name,
	/// broken ones included with their Problems. Returns how many can be played. The MapFileInfo objects belong to the
	/// caller. A missing folder finds nothing.
	public static int Find(StringView folder, List<MapFileInfo> maps)
	{
		if (!Directory.Exists(folder))
			return 0;
		let found = scope List<MapFileInfo>();
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let path = scope String();
			entry.GetFilePath(path);
			if (path.EndsWith(Extension, .OrdinalIgnoreCase))
				found.Add(Check(path));
		}
		found.Sort(scope (a, b) => a.Name.CompareTo(b.Name, true));
		int playable = 0;
		for (let map in found)
		{
			for (let other in maps)
			{
				if (map.Ok && other.Ok && other.Id == map.Id)
					map.AddProblem(scope $"It is the same map as {other.File}.");
			}
			if (map.Ok)
				playable++;
			maps.Add(map);
		}
		return playable;
	}

	/// Reads and checks one map file. The MapFileInfo belongs to the caller.
	public static MapFileInfo Check(StringView file)
	{
		let map = new MapFileInfo();
		map.File.Set(file);
		Path.GetFileNameWithoutExtension(file, map.Name);
		let bytes = scope List<uint8>();
		if (System.IO.File.ReadAll(file, bytes) case .Ok)
		{
			map.Bytes = bytes.Count;
			Hash(bytes, map.Hash);
		}
		let pack = scope PackFile();
		if (pack.Open(file) case .Err)
		{
			map.AddProblem("It is not a map file, or it is damaged.");
			return map;
		}
		let info = scope List<uint8>();
		if (pack.Read(InfoName, info) case .Err)
		{
			map.AddProblem("It has no map description (map.txt), or it is damaged.");
			return map;
		}
		ReadInfo(StringView((char8*)info.Ptr, info.Count), map);
		if (map.Version <= 0 || map.Id.IsEmpty)
		{
			map.AddProblem("Its map description (map.txt) is not one this game can read.");
			return map;
		}
		if (map.Version > FormatVersion)
			map.AddProblem("It was made with a newer version of the engine than this game's.");
		if (!map.Game.IsEmpty && map.Game != GamePaths.Game)
			map.AddProblem(scope $"It was made for {map.Game}, not {GamePaths.Game}.");
		// Every file is read once, which checks its checksum: a changed or cut-short file is caught here, not mid-game.
		for (let entry in pack.Entries)
		{
			let data = scope List<uint8>();
			if (pack.Read(entry, data) case .Err)
				map.AddProblem(scope $"{entry.name} inside it is damaged.");
			else if (entry.name == SceneName)
				map.SceneText.Set(StringView((char8*)data.Ptr, data.Count));
		}
		if (map.SceneText.IsEmpty)
		{
			map.AddProblem("It has no scene in it.");
			return map;
		}
		CheckScene(map, pack);
		MapRules.Check(map.SceneText, map.Problems);
		return map;
	}

	/// The scene's components must exist in the game, and the files it names must be in the game or in the map.
	static void CheckScene(MapFileInfo map, PackFile pack)
	{
		if (!map.SceneText.StartsWith("scene "))
		{
			map.AddProblem("Its scene is not a scene file.");
			return;
		}
		let missingTypes = scope HashSet<String>();
		let missingFiles = scope HashSet<String>();
		defer
		{
			ClearAndDeleteItems!(missingTypes);
			ClearAndDeleteItems!(missingFiles);
		}
		let inMap = scope $"{MountFolder}/{map.Id}/";
		for (let line in map.SceneText.Split('\n'))
		{
			if (line.StartsWith("component "))
			{
				var type = line.Substring(10);
				let space = type.IndexOf(' ');
				if (space >= 0)
					type = type.Substring(0, space);
				if (ComponentRegistry.Find(type) == null && !missingTypes.ContainsAlt(type))
					missingTypes.Add(new String(type));
				continue;
			}
			let path = scope String();
			if (!QuotedPath(line, path))
				continue;
			if (path.StartsWith(inMap))
			{
				if (!InPack(pack, path.Substring(inMap.Length)))
					AddOnce(missingFiles, path);
			}
			else if (!Assets.FileExists(path) && !AssetPack.FolderExists(Assets.ResolvePath(path, .. scope .())))
				AddOnce(missingFiles, path);
		}
		for (let type in missingTypes)
			map.AddProblem(scope $"It uses {type}, which this game does not have.");
		for (let file in missingFiles)
			map.AddProblem(scope $"It needs {file}, which this game does not have.");
	}

	static void AddOnce(HashSet<String> set, StringView value)
	{
		if (!set.ContainsAlt(value))
			set.Add(new String(value));
	}

	/// A file, or a folder of files, inside the map.
	static bool InPack(PackFile pack, StringView name)
	{
		for (let entry in pack.Entries)
		{
			if (entry.name == name || (entry.name.StartsWith(name) && entry.name.Length > name.Length && entry.name[name.Length] == '/'))
				return true;
		}
		return false;
	}

	/// The asset a "field name "value"" line names, if it names one: a value with an asset's file type (a part
	/// number "#2" after it is left off), or a map's own folder. Built-in meshes and other values are not files.
	static bool QuotedPath(StringView line, String path)
	{
		if (!line.StartsWith("field "))
			return false;
		let open = line.IndexOf('"');
		if (open < 0 || !line.EndsWith('"') || line.Length - open < 3)
			return false;
		var value = line.Substring(open + 1, line.Length - open - 2);
		if (value.Contains('\\') || value.StartsWith("builtin:") || value.Contains(':'))
			return false;
		let part = value.IndexOf('#');
		if (part >= 0)
			value = value.Substring(0, part);
		if (value.StartsWith(MountFolder))
		{
			path.Set(value);
			return true;
		}
		for (let fileType in AssetExtensions)
		{
			if (value.EndsWith(fileType, .OrdinalIgnoreCase))
			{
				path.Set(value);
				return true;
			}
		}
		return false;
	}

	static void ReadInfo(StringView text, MapFileInfo map)
	{
		for (var line in text.Split('\n'))
		{
			line.Trim();
			let space = line.IndexOf(' ');
			if (space < 0)
				continue;
			let key = line.Substring(0, space);
			let value = line.Substring(space + 1);
			switch (key)
			{
			case "tmap": map.Version = SceneSerializer.ParseInt(value);
			case "id": map.Id.Set(value);
			case "name": map.Name.Set(value);
			case "author": map.Author.Set(value);
			case "description": map.Description.Set(value);
			case "game": map.Game.Set(value);
			}
		}
	}

	/// Makes a map's files readable (from memory) so that its scene can be loaded from map.ScenePath. False for a
	/// map with problems (unless allowProblems: a map editor opens a map that is not finished yet), or one whose file
	/// has gone since it was checked.
	public static bool Mount(MapFileInfo map, bool allowProblems = false)
	{
		if (map.Mounted)
			return true;
		if (!map.Ok && !allowProblems)
			return false;
		let pack = scope PackFile();
		if (pack.Open(map.File) case .Err)
			return false;
		let root = scope $"{Assets.ProjectPath}/{MountFolder}/{map.Id}";
		for (let entry in pack.Entries)
		{
			let data = scope List<uint8>();
			if (pack.Read(entry, data) case .Err)
			{
				AssetPack.RemoveMemoryFiles(root);
				return false;
			}
			AssetPack.AddMemoryFile(scope $"{root}/{entry.name}" , data);
		}
		map.[Friend]SetMounted(true);
		return true;
	}

	/// Frees the memory a mounted map's files take, and forgets the models and textures loaded from them. Unload its
	/// scene first.
	public static void Unmount(MapFileInfo map)
	{
		if (!map.Mounted)
			return;
		AssetPack.RemoveMemoryFiles(scope $"{Assets.ProjectPath}/{MountFolder}/{map.Id}");
		Assets.Forget(scope $"{MountFolder}/{map.Id}/");
		map.[Friend]SetMounted(false);
	}

	/// A file's hash as 16 hex digits (64-bit FNV-1a): quick to work out, and different for a changed file.
	public static void Hash(Span<uint8> data, String hash)
	{
		uint64 value = 14695981039346656037UL;
		for (let b in data)
		{
			value ^= b;
			value *= 1099511628211UL;
		}
		hash.AppendF("{:x16}", value);
	}

	/// Writes a scene as a map file with a new Id. See the other Export.
	public static Result<void> Export(Scene scene, StringView file, StringView name, StringView author, StringView description, List<String> problems)
		=> Export(scene, null, file, "", name, author, description, problems);

	/// Writes a scene as a map file. group, when not null, is a scene loaded into a running game (the GameObject
	/// SceneManager.LoadAdditive returned): only the objects under it are written. keepId is the Id of the map being
	/// saved again, so that players who have it get the new version instead of a second map; empty gives a new Id.
	///
	/// The scene's own data is copied into the map: each Voxel Terrain's sculpting folder (save the scene first: it
	/// takes what is on disk), and every file the scene names under .maps/ (a model a map editor brought in, kept in
	/// memory with AssetPack.AddMemoryFile or on disk), whose paths are changed to the map's Id. Files the scene names
	/// that the project does not have are listed in problems, and the map is still written.
	public static Result<void> Export(Scene scene, GameObject group, StringView file, StringView keepId, StringView name, StringView author, StringView description, List<String> problems)
	{
		let id = scope String(keepId);
		if (id.IsEmpty)
			MakeId(name, id);
		let text = scope String();
		if (group != null)
			SceneSerializer.SaveGroup(scene, group, name, text);
		else
			SceneSerializer.Save(scene, text);
		let files = scope List<(String name, List<uint8> data)>();
		defer
		{
			for (let entry in files)
			{
				delete entry.name;
				delete entry.data;
			}
		}
		int terrainNumber = 0;
		for (let component in scene.Components)
		{
			let terrain = component as VoxelTerrain;
			if (terrain == null || terrain.editsFolder.IsEmpty || (group != null && !Under(terrain.GameObject, group)))
				continue;
			let folder = scope $"terrain{++terrainNumber}";
			let source = Assets.ResolvePath(terrain.editsFolder, .. scope .());
			if (Directory.Exists(source))
			{
				for (let entry in Directory.EnumerateFiles(source))
				{
					let fileName = scope String();
					entry.GetFileName(fileName);
					let data = new List<uint8>();
					if (System.IO.File.ReadAll(entry.GetFilePath(.. scope .()), data) case .Err)
					{
						delete data;
						problems.Add(new $"Could not read {terrain.editsFolder}/{fileName}.");
						continue;
					}
					files.Add((new $"{folder}/{fileName}" , data));
				}
			}
			let before = scope String("field editsFolder ");
			SceneSerializer.Quote(terrain.editsFolder, before);
			let after = scope String("field editsFolder ");
			SceneSerializer.Quote(scope $"{MountFolder}/{id}/{folder}" , after);
			text.Replace(before, after);
		}
		CarryOwnFiles(text, id, files, problems);
		for (let line in text.Split('\n'))
		{
			let path = scope String();
			if (QuotedPath(line, path) && !path.StartsWith(MountFolder) && !Assets.FileExists(path))
				problems.Add(new $"The scene names {path}, which the project does not have.");
		}
		let info = scope String();
		info.AppendF("tmap {}\nid {}\nname {}\ngame {}\n", FormatVersion, id, OneLine(name, .. scope .()), GamePaths.Game);
		if (!author.IsEmpty)
			info.AppendF("author {}\n", OneLine(author, .. scope .()));
		if (!description.IsEmpty)
			info.AppendF("description {}\n", OneLine(description, .. scope .()));
		let entries = scope List<(StringView name, Span<uint8> data)>();
		entries.Add((InfoName, .((uint8*)info.Ptr, info.Length)));
		entries.Add((SceneName, .((uint8*)text.Ptr, text.Length)));
		for (let entry in files)
			entries.Add((entry.name, entry.data));
		let folder = scope String();
		if (Path.GetDirectoryPath(file, folder) case .Ok && !folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		return PackFile.Write(file, entries);
	}

	static bool Under(GameObject gameObject, GameObject group)
	{
		for (var transform = gameObject.Transform; transform != null; transform = transform.Parent)
		{
			if (transform.GameObject == group)
				return true;
		}
		return false;
	}

	/// Copies the files the scene names under .maps/<some Id>/ into the map (a file named "#2" after is read once),
	/// and changes those paths to .maps/<id>/, where they are once the map is mounted. Folders (terrain sculpting)
	/// are left to the terrain step.
	static void CarryOwnFiles(String text, StringView id, List<(String name, List<uint8> data)> files, List<String> problems)
	{
		let oldIds = scope HashSet<String>();
		defer
		{
			ClearAndDeleteItems!(oldIds);
		}
		for (let line in text.Split('\n'))
		{
			let path = scope String();
			if (!QuotedPath(line, path) || !path.StartsWith(scope $"{MountFolder}/"))
				continue;
			var rest = path.Substring(MountFolder.Length + 1);
			let slash = rest.IndexOf('/');
			if (slash <= 0)
				continue;
			let oldId = rest.Substring(0, slash);
			let inside = rest.Substring(slash + 1);
			bool carried = false;
			for (let entry in files)
				carried |= entry.name == inside || (entry.name.StartsWith(inside) && entry.name.Length > inside.Length && entry.name[inside.Length] == '/');
			if (carried)
				continue;
			if (!Assets.FileExists(path))
			{
				// A folder (a terrain with no sculpting yet) has no file type.
				if (Path.GetExtension(path, .. scope .()).Length > 0 && !AssetPack.FolderExists(Assets.ResolvePath(path, .. scope .())))
					problems.Add(new $"The scene names {path}, which is not there.");
				continue;
			}
			let data = new List<uint8>();
			if (!Assets.ReadBytes(path, data))
			{
				delete data;
				problems.Add(new $"Could not read {path}.");
				continue;
			}
			files.Add((new String(inside), data));
			if (oldId != id && !oldIds.ContainsAlt(oldId))
				oldIds.Add(new String(oldId));
		}
		for (let oldId in oldIds)
			text.Replace(scope $"\"{MountFolder}/{oldId}/" , scope $"\"{MountFolder}/{id}/");
	}

	/// The map's name in lower case, letters and digits only, and a random number: "harbour-4f2a91c0".
	static void MakeId(StringView name, String id)
	{
		for (let c in name.RawChars)
		{
			if (c.IsLetterOrDigit && id.Length < 32)
				id.Append(c.ToLower);
			else if (!id.IsEmpty && !id.EndsWith('-') && id.Length < 32)
				id.Append('-');
		}
		while (id.EndsWith('-'))
			id.RemoveFromEnd(1);
		if (id.IsEmpty)
			id.Append("map");
		let random = scope Random();
		id.AppendF("-{:x8}", (uint32)random.Next(int32.MaxValue) ^ (uint32)Internal.GetTickCountMicro());
	}

	static void OneLine(StringView text, String output)
	{
		output.Append(text);
		output.Replace('\n', ' ');
		output.Replace('\r', ' ');
		output.Trim();
	}
}
