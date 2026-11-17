using System;
using System.Collections;

namespace Tallow;

/// Player-made maps for C# (Managed/Tallow.API/Maps.cs): MapFiles and MapSharing. A map is known to C# by its file;
/// what MapFiles.Check found travels as text, one field after another separated by 0x1E, the problems separated by
/// 0x1F, and several maps separated by 0x1D. Maps C# mounted are kept here (by file) until it unmounts them.
[CSharpExpose]
static class CSharpMaps
{
	static Dictionary<String, MapFileInfo> sMounted = new .() ~ { for (let pair in _) { delete pair.key; delete pair.value; } delete _; };
	static String sExportProblems = new .() ~ delete _;

	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// file, id, name, author, description, game, version, hash, bytes, problems.
	static void Describe(MapFileInfo map, String text)
	{
		text.AppendF("{}\x1e{}\x1e{}\x1e{}\x1e{}\x1e{}\x1e{}\x1e{}\x1e{}\x1e", map.File, map.Id, map.Name, map.Author, map.Description,
			map.Game, map.Version, map.Hash, map.Bytes);
		for (let problem in map.Problems)
		{
			if (@problem.Index > 0)
				text.Append('\x1f');
			text.Append(problem);
		}
	}

	/// Where the game keeps its maps (GamePaths' game folder + "Maps").
	[CSharpExpose]
	public static int32 Folder(Span<uint8> buffer) => Copy(MapFiles.Folder(.. scope .()), buffer);

	/// Every .tmap in a folder (not its sub-folders), sorted by name, broken ones included.
	[CSharpExpose]
	public static int32 Find(StringView folder, Span<uint8> buffer)
	{
		let maps = scope List<MapFileInfo>();
		defer { ClearAndDeleteItems!(maps); }
		MapFiles.Find(folder, maps);
		let text = scope String();
		for (let map in maps)
		{
			if (@map.Index > 0)
				text.Append('\x1d');
			Describe(map, text);
		}
		return Copy(text, buffer);
	}

	/// Reads and checks one map file.
	[CSharpExpose]
	public static int32 Check(StringView file, Span<uint8> buffer)
	{
		let map = MapFiles.Check(file);
		defer delete map;
		return Copy(Describe(map, .. scope .()), buffer);
	}

	/// How many components of a type (its full name) the map's scene has; -1 when the file cannot be read.
	[CSharpExpose]
	public static int32 CountComponents(StringView file, StringView typeName)
	{
		let map = MapFiles.Check(file);
		defer delete map;
		return map.SceneText.IsEmpty ? -1 : (int32)map.CountComponents(typeName);
	}

	[CSharpExpose]
	public static bool IsMounted(StringView file) => sMounted.ContainsKeyAlt(file);

	/// Makes a map's files readable so its scene loads from .maps/<id>/map.tscene. False for a map with problems
	/// (unless allowProblems) or one whose file has gone.
	[CSharpExpose]
	public static bool Mount(StringView file, bool allowProblems)
	{
		if (sMounted.ContainsKeyAlt(file))
			return true;
		let map = MapFiles.Check(file);
		if (!MapFiles.Mount(map, allowProblems))
		{
			delete map;
			return false;
		}
		sMounted[new String(file)] = map;
		return true;
	}

	/// Frees a mounted map's files (unload its scene first).
	[CSharpExpose]
	public static void Unmount(StringView file)
	{
		if (sMounted.GetAndRemoveAlt(file) case .Ok(let pair))
		{
			MapFiles.Unmount(pair.value);
			delete pair.key;
			delete pair.value;
		}
	}

	/// Writes the scene (or, with group not 0, the objects under it) as a map file. keepId: the Id of the map saved
	/// again, empty for a new one. False when it could not be written; ExportProblems lists what was wrong either way.
	[CSharpExpose]
	public static bool Export(uint64 session, uint64 group, StringView file, StringView keepId, StringView name, StringView author,
		StringView description)
	{
		sExportProblems.Clear();
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null)
		{
			sExportProblems.Append("There is no scene.");
			return false;
		}
		GameObject root = null;
		if (group != 0)
		{
			root = CSharpRuntime.PhysicsObject(session, group);
			if (root == null)
			{
				sExportProblems.Append("The group object is not in the scene.");
				return false;
			}
		}
		let problems = scope List<String>();
		defer { ClearAndDeleteItems!(problems); }
		let result = MapFiles.Export(scene, root, file, keepId, name, author, description, problems);
		for (let problem in problems)
		{
			if (@problem.Index > 0)
				sExportProblems.Append('\x1f');
			sExportProblems.Append(problem);
		}
		return result case .Ok;
	}

	[CSharpExpose]
	public static int32 ExportProblems(Span<uint8> buffer) => Copy(sExportProblems, buffer);

	// ---- sharing

	/// Host: offers the map in that file to players who ask for it by Id.
	[CSharpExpose]
	public static bool Offer(StringView file)
	{
		let map = MapFiles.Check(file);
		defer delete map;
		if (map.Id.IsEmpty)
			return false;
		MapSharing.Offer(map);
		return true;
	}

	[CSharpExpose]
	public static void ClearOffers() => MapSharing.ClearOffers();

	[CSharpExpose]
	public static bool Have(StringView id, StringView hash, StringView folder) => MapSharing.Have(id, hash, folder);

	/// Player: asks the host for its map.
	[CSharpExpose]
	public static bool Request(uint64 session, StringView id, StringView hash)
	{
		let network = CSharpRuntime.PhysicsScene(session)?.Network;
		if (network == null || !network.IsClient)
			return false;
		MapSharing.Request(network, id, hash);
		return true;
	}

	[CSharpExpose]
	public static void Reset() => MapSharing.Reset();

	/// MapDownloadState as a number: 0 None, 1 Asking, 2 Downloading, 3 Done, 4 Failed.
	[CSharpExpose]
	public static int32 State() => (int32)MapSharing.State;

	[CSharpExpose]
	public static float Progress() => MapSharing.Progress;

	[CSharpExpose]
	public static int32 TotalBytes() => (int32)MapSharing.TotalBytes;

	/// 0 WantedId, 1 Name, 2 Error, 3 DownloadedFile, 4 Folder (where downloads go).
	[CSharpExpose]
	public static int32 SharingText(int32 which, Span<uint8> buffer)
	{
		switch (which)
		{
		case 0: return Copy(MapSharing.WantedId, buffer);
		case 1: return Copy(MapSharing.Name, buffer);
		case 2: return Copy(MapSharing.Error, buffer);
		case 3: return Copy(MapSharing.DownloadedFile, buffer);
		default: return Copy(MapSharing.Folder, buffer);
		}
	}

	[CSharpExpose]
	public static void SetSharingFolder(StringView folder) => MapSharing.Folder = folder;
}
