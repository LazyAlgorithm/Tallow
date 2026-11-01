using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Asset packs: a built game's assets in one file (`game.tpak`) instead of loose files that anyone can open and
/// change. File > Build... makes the pack; a packed game mounts it by itself when it starts.
///
/// Everything the engine loads (scenes, prefabs, materials, models, textures, sounds, UI documents, shaders...)
/// comes from the pack when it is there and from disk when it is not, so nothing changes while developing. Game
/// code that reads its own data files should do it through this class, or Assets.ReadText / Assets.ReadBytes, for the
/// same reason:
///
///   let text = scope String();
///   if (Assets.ReadText("Data/levels.txt", text)) ...
///
/// A pack keeps assets from being opened or edited with ordinary tools, and a file that was changed anyway fails
/// its checksum and does not load. It is not encryption.
///
/// A build can split the assets: game.tpak holds everything shared, and each scene's own files (what only that
/// scene uses) go into a pack of their own, listed in packs.txt inside game.tpak. Changing one map then rewrites one
/// small file, which is all an update has to send. MountGame mounts them all; reading a file does not care which
/// pack holds it. In a browser the scene packs download after the game has started: SceneReady says whether a
/// scene's pack has arrived, and Request asks for it next. SceneManager.Load waits for it by itself.
static class AssetPack
{
	class Deferred
	{
		public String file = new .() ~ delete _;
		public String scene = new .() ~ delete _;
		public int64 size;
		public bool mounted;
	}

	static List<Deferred> sDeferred = new .() ~ DeleteContainerAndItems!(_);
	/// Files held in memory by full path, read before packs and disk: the contents of a map that is being played
	/// (MapFiles.Mount). Sounds load on other threads, so every use takes sMemoryLock.
	static Dictionary<String, List<uint8>> sMemoryFiles = new .() ~
		{
			for (let entry in _)
			{
				delete entry.key;
				delete entry.value;
			}
			delete _;
		};
	static Monitor sMemoryLock = new .() ~ delete _;
	static String sRoot = new .() ~ delete _;
	static int sWaiting;
#if BF_PLATFORM_WASM
	[CLink] static extern void tn_web_request_pack(char8* name);
#endif

	[CLink] static extern int32 tn_pack_mount(char8* file, char8* root);
	[CLink] static extern void tn_pack_unmount_all();
	[CLink] static extern int32 tn_pack_exists(char8* path);
	[CLink] static extern int32 tn_pack_has_folder(char8* path);
	[CLink] static extern void* tn_pack_read(char8* path, uint* size);
	[CLink] static extern void tn_pack_free(void* data);
	[CLink] static extern int32 tn_pack_count();
	[CLink] static extern char8* tn_pack_path(int32 index);

	/// How many files are in the mounted packs. 0 when the game runs from loose files.
	public static int FileCount => tn_pack_count();
	public static bool Mounted => tn_pack_count() > 0;

	/// Mounts a pack file. Its files then appear to be inside the folder `root`, where the loose files would have
	/// been. False if the file is missing or is not a pack.
	public static bool Mount(StringView packFile, StringView root)
	{
		return tn_pack_mount(scope String(packFile).CStr(), scope String(root).CStr()) >= 0;
	}

	public static void UnmountAll()
	{
		tn_pack_unmount_all();
		ClearAndDeleteItems!(sDeferred);
		sWaiting = 0;
	}

	/// Mounts a built game's packs from its folder: game.tpak, and the scene packs packs.txt lists. A pack that is
	/// not there yet (in a browser, still downloading) is mounted by Poll when it arrives.
	public static void MountGame(StringView root)
	{
		sRoot.Set(root);
		if (!Mount(scope $"{root}/game.tpak" , root))
			return;
		let list = scope String();
		if (ReadAllText(scope $"{root}/packs.txt" , list) case .Err)
			return;
		for (let line in list.Split('\n'))
		{
			var parts = line.Split('\t');
			let file = parts.GetNext();
			let scene = parts.GetNext();
			let size = parts.GetNext();
			if (file case .Err || scene case .Err)
				continue;
			let entry = new Deferred();
			entry.file.Set(file.Value);
			entry.scene.Set(scene.Value);
			if (size case .Ok(let text))
			{
				if (int64.Parse(text) case .Ok(let number))
					entry.size = number;
			}
			sDeferred.Add(entry);
			sWaiting++;
		}
		Poll();
	}

	/// Mounts scene packs that have arrived since the last call. The game calls this once a frame; it costs nothing
	/// once every pack is in.
	public static void Poll()
	{
		if (sWaiting == 0)
			return;
		for (let entry in sDeferred)
		{
			if (entry.mounted)
				continue;
			let path = scope $"{sRoot}/{entry.file}";
			if (!File.Exists(path))
				continue;
			entry.mounted = true;
			sWaiting--;
			if (!Mount(path, sRoot))
				Log.Error(scope $"The asset pack {entry.file} is damaged.");
		}
	}

	/// How many scene packs have not arrived yet: 0 except in a browser that is still downloading them.
	public static int Waiting => sWaiting;

	static Deferred PackOf(StringView scene)
	{
		var wanted = StringView(scene);
		if (wanted.StartsWith("Assets/"))
			wanted = wanted.Substring(7);
		for (let entry in sDeferred)
		{
			if (entry.scene == wanted)
				return entry;
		}
		return null;
	}

	/// Whether everything a scene needs is here. False only in a browser while that scene's pack downloads.
	public static bool SceneReady(StringView scene)
	{
		if (sWaiting == 0)
			return true;
		Poll();
		let entry = PackOf(scene);
		return entry == null || entry.mounted;
	}

	/// Asks for a scene's pack before the others still waiting to download. Does nothing where it is already here.
	public static void Request(StringView scene)
	{
		let entry = PackOf(scene);
		if (entry == null || entry.mounted)
			return;
#if BF_PLATFORM_WASM
		tn_web_request_pack(entry.file.CStr());
#endif
	}

	/// Makes a file readable at a full path, from memory, until RemoveMemoryFiles: it is found before a pack's or a
	/// loose file of the same name. MapFiles uses this for the files inside a map.
	public static void AddMemoryFile(StringView fullPath, Span<uint8> data)
	{
		// Models and pictures are read by native code (cgltf, stb_image), which keeps its own copy.
		if (NativeReads(fullPath))
			tn_memory_file_add(scope String(fullPath).CStr(), data.Ptr, (uint)data.Length);
		let key = MemoryKey(fullPath, .. new .());
		let copy = new List<uint8>(data.Length);
		copy.AddRange(data);
		using (sMemoryLock.Enter())
		{
			if (sMemoryFiles.GetAndRemoveAlt(key) case .Ok(let old))
			{
				delete old.key;
				delete old.value;
			}
			sMemoryFiles[key] = copy;
		}
	}

	/// Forgets every memory file inside a folder (a full path), and returns how many there were.
	public static int RemoveMemoryFiles(StringView folder)
	{
		tn_memory_file_remove_folder(scope String(folder).CStr());
		let prefix = MemoryKey(folder, .. scope .())..Append('/');
		let gone = scope List<String>();
		using (sMemoryLock.Enter())
		{
			for (let key in sMemoryFiles.Keys)
			{
				if (key.StartsWith(prefix))
					gone.Add(key);
			}
			for (let key in gone)
			{
				if (sMemoryFiles.GetAndRemove(key) case .Ok(let pair))
				{
					delete pair.key;
					delete pair.value;
				}
			}
		}
		return gone.Count;
	}

	[CLink] static extern void tn_memory_file_add(char8* path, void* data, uint size);
	[CLink] static extern void tn_memory_file_remove_folder(char8* folder);

	static bool NativeReads(StringView path)
	{
		for (let fileType in StringView[?](".glb", ".gltf", ".bin", ".png", ".jpg", ".jpeg", ".tga", ".bmp"))
		{
			if (path.EndsWith(fileType, .OrdinalIgnoreCase))
				return true;
		}
		return false;
	}

	/// Paths as memory files are kept: forward slashes, never two together, none at the end.
	static void MemoryKey(StringView path, String key)
	{
		key.Append(path);
		key.Replace('\\', '/');
		while (key.Contains("//"))
			key.Replace("//", "/");
		while (key.Length > 1 && key.EndsWith('/'))
			key.RemoveFromEnd(1);
	}

	static bool ReadMemory(StringView path, List<uint8> data)
	{
		if (sMemoryFiles.Count == 0)
			return false;
		let key = MemoryKey(path, .. scope .());
		using (sMemoryLock.Enter())
		{
			if (!sMemoryFiles.TryGetValueAlt(key, let bytes))
				return false;
			data.AddRange(bytes);
		}
		return true;
	}

	static bool InMemory(StringView path, bool folder)
	{
		if (sMemoryFiles.Count == 0)
			return false;
		let key = MemoryKey(path, .. scope .());
		using (sMemoryLock.Enter())
		{
			if (!folder)
				return sMemoryFiles.ContainsKeyAlt(key);
			key.Append('/');
			for (let name in sMemoryFiles.Keys)
			{
				if (name.StartsWith(key))
					return true;
			}
		}
		return false;
	}

	/// Whether a full path names a file in a pack.
	public static bool Contains(StringView path) => tn_pack_count() > 0 && tn_pack_exists(scope String(path).CStr()) != 0;

	/// Whether the file exists: in a pack, or on disk.
	public static bool Exists(StringView path) => InMemory(path, false) || Contains(path) || File.Exists(path);

	/// Whether the folder exists: holding at least one packed file, or on disk.
	public static bool FolderExists(StringView path) => InMemory(path, true) || (tn_pack_count() > 0 && tn_pack_has_folder(scope String(path).CStr()) != 0) || Directory.Exists(path);

	/// Reads a whole file, from a pack if it is in one and from disk otherwise.
	public static Result<void> ReadAll(StringView path, List<uint8> data)
	{
		if (ReadMemory(path, data))
			return .Ok;
		if (tn_pack_count() > 0)
		{
			let cPath = scope String(path);
			uint size = 0;
			let bytes = tn_pack_read(cPath.CStr(), &size);
			if (bytes != null)
			{
				data.AddRange(Span<uint8>((uint8*)bytes, (int)size));
				tn_pack_free(bytes);
				return .Ok;
			}
			// In the pack but unreadable: the pack was changed. The loose file is not a stand-in for it.
			if (tn_pack_exists(cPath.CStr()) != 0)
				return .Err;
		}
		if (File.ReadAll(path, data) case .Err)
			return .Err;
		return .Ok;
	}

	public static Result<void> ReadAllText(StringView path, String text)
	{
		let memory = scope List<uint8>();
		if (ReadMemory(path, memory))
		{
			text.Append(StringView((char8*)memory.Ptr, memory.Count));
			return .Ok;
		}
		if (tn_pack_count() > 0)
		{
			let bytes = scope List<uint8>();
			if (Contains(path))
			{
				if (ReadAll(path, bytes) case .Err)
					return .Err;
				text.Append(StringView((char8*)bytes.Ptr, bytes.Count));
				return .Ok;
			}
		}
		if (File.ReadAllText(path, text) case .Err)
			return .Err;
		return .Ok;
	}

	/// The full paths of the packed files inside a folder (and its sub-folders), for code that used to list a folder.
	public static void FilesIn(StringView folder, List<String> paths)
	{
		let prefix = scope String(folder);
		prefix.Replace('\\', '/');
		// Packed paths are kept with single slashes ("/" + "/Assets" is a root of "/" on the web).
		while (prefix.Contains("//"))
			prefix.Replace("//", "/");
		while (prefix.EndsWith('/'))
			prefix.RemoveFromEnd(1);
		prefix.Append('/');
		for (int32 i = 0; i < tn_pack_count(); i++)
		{
			let path = StringView(tn_pack_path(i));
			if (path.StartsWith(prefix))
				paths.Add(new String(path));
		}
		using (sMemoryLock.Enter())
		{
			for (let path in sMemoryFiles.Keys)
			{
				if (path.StartsWith(prefix))
					paths.Add(new String(path));
			}
		}
	}
}
