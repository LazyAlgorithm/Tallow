using System;
using System.Collections;
using System.IO;
using System.Security.Cryptography;
using Tallow;

namespace Tallow.Editor;

/// Stable asset IDs (docs/asset-ids.md). Every asset in the project's Assets folder has an ID that never changes,
/// kept beside it in "<file>.tmeta", so the editor knows a file is the same asset after it has been moved or renamed,
/// in the editor or outside it.
///
/// Scenes, prefabs, materials, UI documents and scripts keep naming assets by path ("Models/crate.glb"): that is what
/// the game loads, and it reads the same in every file. What the IDs add is that when an asset moves, every file that
/// names it is changed to its new path:
///
/// - moved in the Project window: at once (Move);
/// - moved outside the editor (a file manager, git): the next time the editor looks (Refresh), from the ID in the
///   .tmeta that went with it, or, when the .tmeta was left behind, from a file with the same name;
///
/// and asset packages (docs/packages.md) use them to know which files of a package the project already has.
///
/// The paths each ID was last seen at are kept in <project>/.cache/asset-ids.txt, which is how a move outside the
/// editor is recognised.
static class AssetDatabase
{
	public const String MetaSuffix = ".tmeta";

	/// id -> path relative to the Assets folder, and back.
	static Dictionary<String, String> sPathOf = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static Dictionary<String, String> sIdOf = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static int sCounter;

	/// How many assets have IDs.
	public static int Count => sPathOf.Count;

	/// Files that are never assets of their own: scripts (found by class name, not path), the .tmeta files, and the
	/// files that belong to another file and go wherever it goes (CompanionOf).
	public static bool IsTracked(StringView relative)
	{
		let name = Path.GetFileName(relative, .. scope .());
		if (name.StartsWith('.') || name == "Program.bf")
			return false;
		if (name.EndsWith(".bf", .OrdinalIgnoreCase) || name.EndsWith(MetaSuffix, .OrdinalIgnoreCase))
			return false;
		for (let part in relative.Split('/'))
		{
			if (part == "Compiled" || part.StartsWith('.'))
				return false;
		}
		return true;
	}

	/// The kinds of file that travel with the file they are named after ("crate.glb.import", "crate.glb.bonemap",
	/// "crate.glb.tmeta").
	public static readonly StringView[?] CompanionSuffixes = .(MetaSuffix, ".import", ".bonemap");

	public static bool IsCompanion(StringView name)
	{
		for (let suffix in CompanionSuffixes)
		{
			if (name.EndsWith(suffix, .OrdinalIgnoreCase) && name.Length > suffix.Length)
				return true;
		}
		return false;
	}

	/// The files that move, are packaged and are deleted with an asset: its .tmeta and other side files.
	public static void GetCompanions(StringView full, List<String> outFiles)
	{
		for (let suffix in CompanionSuffixes)
		{
			let candidate = scope $"{full}{suffix}";
			if (File.Exists(candidate))
				outFiles.Add(new String(candidate));
		}
	}

	public static void MetaPath(StringView full, String outPath) => outPath.AppendF("{}{}", full, MetaSuffix);

	public static bool GetId(StringView relative, String outId)
	{
		if (sIdOf.TryGetValueAlt(relative, let id))
		{
			outId.Append(id);
			return true;
		}
		return false;
	}

	public static bool GetPath(StringView id, String outPath)
	{
		if (sPathOf.TryGetValueAlt(id, let path))
		{
			outPath.Append(path);
			return true;
		}
		return false;
	}

	public static bool HasPath(StringView relative) => sIdOf.ContainsKeyAlt(relative);

	/// A new ID: 32 hexadecimal digits, from the time, a count and the path, so that two projects making assets at
	/// the same moment still get different ones.
	public static void NewId(StringView seed, String outId)
	{
		let sha = scope SHA256();
		var ticks = DateTime.UtcNow.Ticks;
		sha.Update(.((uint8*)&ticks, sizeof(int64)));
		var count = ++sCounter;
		sha.Update(.((uint8*)&count, sizeof(int)));
		var stack = 0;
		var address = (int)(void*)&stack;
		sha.Update(.((uint8*)&address, sizeof(int)));
		sha.Update(.((uint8*)seed.Ptr, seed.Length));
		let hash = sha.Finish();
		for (int i < 16)
			outId.AppendF("{:x2}", hash.mHash[i]);
	}

	/// The ID in a .tmeta file, or false when it has none (missing or not a .tmeta).
	public static bool ReadMeta(StringView metaFile, String outId)
	{
		let text = scope String();
		if (File.ReadAllText(metaFile, text) case .Err)
			return false;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("id "))
			{
				var value = line.Substring(3);
				value.Trim();
				if (IsId(value))
				{
					outId.Append(value);
					return true;
				}
			}
		}
		return false;
	}

	public static bool IsId(StringView text)
	{
		if (text.Length != 32)
			return false;
		for (let c in text)
		{
			if (!c.IsDigit && !(c >= 'a' && c <= 'f'))
				return false;
		}
		return true;
	}

	public static bool WriteMeta(StringView metaFile, StringView id)
	{
		return File.WriteAllText(metaFile, scope $"id {id}\n") case .Ok;
	}

	static void CachePath(String outPath)
	{
		let parent = scope String();
		Path.GetDirectoryPath(Assets.ProjectPath, parent).IgnoreError();
		outPath.AppendF("{}/.cache/asset-ids.txt", parent);
	}

	static void Clear()
	{
		for (let entry in sPathOf)
		{
			delete entry.key;
			delete entry.value;
		}
		sPathOf.Clear();
		for (let entry in sIdOf)
		{
			delete entry.key;
			delete entry.value;
		}
		sIdOf.Clear();
	}

	static void Set(StringView id, StringView relative)
	{
		if (sPathOf.GetAndRemoveAlt(id) case .Ok(let old))
		{
			if (sIdOf.GetAndRemoveAlt(old.value) case .Ok(let back))
			{
				delete back.key;
				delete back.value;
			}
			delete old.key;
			delete old.value;
		}
		if (sIdOf.GetAndRemoveAlt(relative) case .Ok(let other))
		{
			if (sPathOf.GetAndRemoveAlt(other.value) case .Ok(let forward))
			{
				delete forward.key;
				delete forward.value;
			}
			delete other.key;
			delete other.value;
		}
		sPathOf[new String(id)] = new String(relative);
		sIdOf[new String(relative)] = new String(id);
	}

	static void Forget(StringView relative)
	{
		if (sIdOf.GetAndRemoveAlt(relative) case .Ok(let entry))
		{
			if (sPathOf.GetAndRemoveAlt(entry.value) case .Ok(let forward))
			{
				delete forward.key;
				delete forward.value;
			}
			delete entry.key;
			delete entry.value;
		}
	}

	static void SaveCache()
	{
		let file = CachePath(.. scope .());
		let folder = scope String();
		Path.GetDirectoryPath(file, folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		let paths = scope List<StringView>();
		for (let entry in sIdOf)
			paths.Add(entry.key);
		paths.Sort(scope (a, b) => StringView.Compare(a, b, false));
		let text = scope String();
		for (let path in paths)
			text.AppendF("{}\t{}\n", sIdOf[scope String(path)], path);
		File.WriteAllText(file, text).IgnoreError();
	}

	static void LoadCache(Dictionary<String, String> pathOf)
	{
		let text = scope String();
		if (File.ReadAllText(CachePath(.. scope .()), text) case .Err)
			return;
		for (let line in text.Split('\n'))
		{
			let tab = line.IndexOf('\t');
			if (tab != 32)
				continue;
			let id = line.Substring(0, tab);
			if (!IsId(id) || pathOf.ContainsKeyAlt(id))
				continue;
			pathOf[new String(id)] = new String(line.Substring(tab + 1));
		}
	}

	struct Found
	{
		public String relative;
		public String id; // null when the file has no .tmeta (or an unreadable one)
	}

	static void Scan(StringView root, StringView folder, List<Found> files, List<(String relative, String id)> orphans, int depth)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return;
		let names = scope List<String>();
		defer { ClearAndDeleteItems!(names); }
		for (let entry in Directory.EnumerateFiles(folder))
			names.Add(entry.GetFileName(.. new String()));
		let present = scope HashSet<StringView>();
		for (let name in names)
			present.Add(name);
		for (let name in names)
		{
			let full = scope $"{folder}/{name}";
			let relative = scope String(full.Substring(root.Length + 1));
			if (name.EndsWith(MetaSuffix) && name.Length > MetaSuffix.Length)
			{
				let owner = name.Substring(0, name.Length - MetaSuffix.Length);
				if (!present.Contains(owner) && !Directory.Exists(scope $"{folder}/{owner}"))
				{
					let id = scope String();
					if (ReadMeta(full, id))
						orphans.Add((new String(relative.Substring(0, relative.Length - MetaSuffix.Length)), new String(id)));
				}
				continue;
			}
			if (!IsTracked(relative))
				continue;
			// A file that belongs to another (crate.glb.import) is not an asset of its own.
			if (IsCompanion(name))
			{
				bool owned = false;
				for (let suffix in CompanionSuffixes)
				{
					if (name.EndsWith(suffix, .OrdinalIgnoreCase) && present.Contains(name.Substring(0, name.Length - suffix.Length)))
						owned = true;
				}
				if (owned)
					continue;
			}
			Found found;
			found.relative = new String(relative);
			let id = scope String();
			found.id = ReadMeta(scope $"{full}{MetaSuffix}", id) ? new String(id) : null;
			files.Add(found);
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (name.StartsWith('.') || name == "Compiled")
				continue;
			Scan(root, scope $"{folder}/{name}", files, orphans, depth + 1);
		}
	}

	/// Looks at every file in the Assets folder: gives new files an ID, gives a copy that came with its original's
	/// .tmeta an ID of its own, and finds assets that were moved since the last look. With fixReferences, files that
	/// named a moved asset by its old path are changed to the new one. Returns how many moves were found; outMoves,
	/// when given, gets them (old path, new path) so that the editor can update what it has open.
	public static int Refresh(bool fixReferences = true, List<(String from, String to)> outMoves = null)
	{
		let root = Assets.ProjectPath;
		if (root.IsEmpty || !Directory.Exists(root))
			return 0;
		let lastPathOf = new Dictionary<String, String>();
		defer { DeleteDictionaryAndKeysAndValues!(lastPathOf); }
		// What was known in this session wins over the file, which may be another session's.
		for (let entry in sPathOf)
			lastPathOf[new String(entry.key)] = new String(entry.value);
		LoadCache(lastPathOf);

		let files = scope List<Found>();
		let orphans = scope List<(String relative, String id)>();
		defer
		{
			for (let found in files)
			{
				delete found.relative;
				delete found.id;
			}
			for (let orphan in orphans)
			{
				delete orphan.relative;
				delete orphan.id;
			}
		}
		Scan(root, root, files, orphans, 0);

		Clear();
		let moves = scope List<(String from, String to)>();
		defer
		{
			for (let move in moves)
			{
				delete move.from;
				delete move.to;
			}
		}
		// Files with their .tmeta. Two with the same ID are a file copied with its .tmeta: the one where the ID was
		// last seen keeps it, the others get new ones.
		let owner = scope Dictionary<StringView, int>();
		for (int i < files.Count)
		{
			let found = files[i];
			if (found.id == null)
				continue;
			if (owner.TryGetValue(found.id, let other))
			{
				let keepThis = (lastPathOf.GetValueAlt(found.id) case .Ok(let last)) && last == found.relative;
				if (keepThis)
					owner[found.id] = i;
				let loser = keepThis ? files[other] : found;
				let fresh = NewId(loser.relative, .. scope .());
				WriteMeta(scope $"{root}/{loser.relative}{MetaSuffix}", fresh);
				loser.id.Set(fresh);
				continue;
			}
			owner[found.id] = i;
		}
		for (let found in files)
		{
			if (found.id != null)
				Set(found.id, found.relative);
		}
		// Files without a .tmeta: one left behind by a move outside the editor, if it names a file of the same name
		// that is no longer there; otherwise a new asset.
		for (let found in files)
		{
			if (found.id != null)
				continue;
			let name = Path.GetFileName(found.relative, .. scope .());
			int match = -1;
			for (int k < orphans.Count)
			{
				if (orphans[k].id == null || sPathOf.ContainsKeyAlt(orphans[k].id))
					continue;
				if (Path.GetFileName(orphans[k].relative, .. scope .()) != name)
					continue;
				match = k;
				break;
			}
			if (match >= 0)
			{
				let orphan = orphans[match];
				WriteMeta(scope $"{root}/{found.relative}{MetaSuffix}", orphan.id);
				File.Delete(scope $"{root}/{orphan.relative}{MetaSuffix}").IgnoreError();
				Set(orphan.id, found.relative);
				DeleteAndNullify!(orphans[match].id);
				continue;
			}
			let id = NewId(found.relative, .. scope .());
			if (WriteMeta(scope $"{root}/{found.relative}{MetaSuffix}", id))
				Set(id, found.relative);
		}
		// Moves: an ID whose path has changed, and whose old path holds nothing now.
		for (let entry in sPathOf)
		{
			if (lastPathOf.TryGetValueAlt(entry.key, let was) && was != entry.value && !File.Exists(scope $"{root}/{was}"))
				moves.Add((new String(was), new String(entry.value)));
		}
		SaveCache();
		if (outMoves != null)
		{
			for (let move in moves)
				outMoves.Add((new String(move.from), new String(move.to)));
		}
		if (fixReferences && moves.Count > 0)
		{
			let pairs = scope List<(StringView from, StringView to)>();
			for (let move in moves)
				pairs.Add((move.from, move.to));
			let changed = RewriteReferences(pairs);
			for (let move in moves)
				Log.Info(scope $"{move.from} was moved to {move.to}.");
			if (changed > 0)
				Log.Info(scope $"References to moved assets were updated in {changed} file{(changed == 1) ? "" : "s"}.");
		}
		return moves.Count;
	}

	/// Moves a file or folder of the Assets folder (full paths) with its side files and changes every reference to
	/// it, and to what a folder holds, to the new path. outMoves, when given, gets every asset that moved (old and
	/// new relative path) and the file or folder itself.
	public static Result<void> Move(StringView fromFull, StringView toFull, List<(String from, String to)> outMoves = null)
	{
		if (fromFull == toFull || File.Exists(toFull) || Directory.Exists(toFull))
			return .Err;
		let fromRelative = scope String();
		let toRelative = scope String();
		if (!ToRelative(fromFull, fromRelative) || !ToRelative(toFull, toRelative))
			return .Err;
		let isFolder = Directory.Exists(fromFull);
		let folder = scope String();
		Path.GetDirectoryPath(toFull, folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		if (isFolder)
		{
			if (Directory.Move(fromFull, toFull) case .Err)
				return .Err;
		}
		else
		{
			let companions = scope List<String>();
			defer { ClearAndDeleteItems!(companions); }
			GetCompanions(fromFull, companions);
			if (File.Move(fromFull, toFull) case .Err)
				return .Err;
			for (let companion in companions)
				File.Move(companion, scope $"{toFull}{companion.Substring(fromFull.Length)}").IgnoreError();
		}

		// The IDs follow.
		let moved = scope List<(String from, String to)>();
		defer
		{
			for (let move in moved)
			{
				delete move.from;
				delete move.to;
			}
		}
		for (let entry in sIdOf)
		{
			if (entry.key == fromRelative || (isFolder && entry.key.StartsWith(fromRelative) && entry.key.Length > fromRelative.Length && entry.key[fromRelative.Length] == '/'))
				moved.Add((new String(entry.key), new String(scope $"{toRelative}{entry.key.Substring(fromRelative.Length)}")));
		}
		for (let move in moved)
		{
			let id = scope String();
			GetId(move.from, id);
			Set(id, move.to);
		}
		SaveCache();

		let pairs = scope List<(StringView from, StringView to)>();
		pairs.Add((fromRelative, toRelative));
		let changed = RewriteReferences(pairs, isFolder);
		if (changed > 0)
			Log.Info(scope $"References to {fromRelative} were changed to {toRelative} in {changed} file{(changed == 1) ? "" : "s"}.");
		if (outMoves != null)
		{
			for (let move in moved)
				outMoves.Add((new String(move.from), new String(move.to)));
			if (isFolder)
				outMoves.Add((new String(fromRelative), new String(toRelative)));
		}
		return .Ok;
	}

	/// Deletes a file or folder of the Assets folder with its side files.
	public static Result<void> Delete(StringView full)
	{
		if (Directory.Exists(full))
		{
			if (Directory.DelTree(full) case .Err)
				return .Err;
		}
		else
		{
			let companions = scope List<String>();
			defer { ClearAndDeleteItems!(companions); }
			GetCompanions(full, companions);
			if (File.Delete(full) case .Err)
				return .Err;
			for (let companion in companions)
				File.Delete(companion).IgnoreError();
		}
		let relative = scope String();
		if (ToRelative(full, relative))
		{
			let gone = scope List<String>();
			defer { ClearAndDeleteItems!(gone); }
			for (let entry in sIdOf)
			{
				if (entry.key == relative || (entry.key.StartsWith(relative) && entry.key.Length > relative.Length && entry.key[relative.Length] == '/'))
					gone.Add(new String(entry.key));
			}
			for (let path in gone)
				Forget(path);
			SaveCache();
		}
		return .Ok;
	}

	public static bool ToRelative(StringView full, String outRelative)
	{
		let root = Assets.ProjectPath;
		if (full.Length > root.Length && full.StartsWith(root) && full[root.Length] == '/')
		{
			outRelative.Append(full.Substring(root.Length + 1));
			return true;
		}
		return false;
	}

	/// Files that are never text, so never hold references: not read when looking for them.
	public static readonly StringView[?] BinaryExtensions = .(".glb", ".png", ".jpg", ".jpeg", ".tga", ".bmp", ".hdr", ".exr", ".ktx", ".dds", ".wav", ".ogg", ".mp3", ".flac", ".fbx", ".blend", ".3ds", ".dae", ".stl", ".ply", ".bin", ".ttf", ".otf", ".ico", ".zip", ".tpak", ".tpackage", ".voxels", ".tmeta", ".so", ".dll", ".dylib", ".exe", ".a", ".lib");

	public static bool MayHoldReferences(StringView name)
	{
		for (let suffix in BinaryExtensions)
		{
			if (name.EndsWith(suffix, .OrdinalIgnoreCase))
				return false;
		}
		return true;
	}

	/// The project's files that may name assets: the Assets folder's text files (scripts too) and project.tallow.
	public static void GetReferencingFiles(List<String> outFiles)
	{
		let root = Assets.ProjectPath;
		CollectText(root, outFiles, 0);
		let parent = scope String();
		Path.GetDirectoryPath(root, parent).IgnoreError();
		let projectFile = scope $"{parent}/project.tallow";
		if (File.Exists(projectFile))
			outFiles.Add(new String(projectFile));
	}

	static void CollectText(StringView folder, List<String> outFiles, int depth)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (name.StartsWith('.') || !MayHoldReferences(name))
				continue;
			if (entry.GetFileSize() > 64 * 1024 * 1024)
				continue;
			outFiles.Add(new String(scope $"{folder}/{name}"));
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (name.StartsWith('.') || name == "Compiled")
				continue;
			CollectText(scope $"{folder}/{name}", outFiles, depth + 1);
		}
	}

	/// Changes, in text, every quoted path that is `from` (or starts with "from#", a part of a model) to `to`; with
	/// isFolder, every quoted path inside the folder too. project.tallow's unquoted "key = path" values as well.
	/// Returns whether anything changed.
	public static bool RewriteText(String text, Span<(StringView from, StringView to)> moves, bool isFolder = false, bool unquotedValues = false)
	{
		bool changed = false;
		let result = scope String(text.Length + 64);
		int i = 0;
		while (i < text.Length)
		{
			let c = text[i];
			if (c == '"' || c == '\'')
			{
				// The quoted text, up to the closing quote on the same line.
				int end = i + 1;
				while (end < text.Length && text[end] != c && text[end] != '\n')
					end++;
				if (end < text.Length && text[end] == c)
				{
					let inner = StringView(text, i + 1, end - i - 1);
					let replaced = scope String();
					if (RewritePath(inner, moves, isFolder, replaced))
					{
						result.Append(c);
						result.Append(replaced);
						result.Append(c);
						changed = true;
						i = end + 1;
						continue;
					}
				}
				result.Append(text, i, Math.Min(end + 1, text.Length) - i);
				i = end + 1;
				continue;
			}
			if (unquotedValues && c == '=' )
			{
				// key = value, to the end of the line.
				int end = i + 1;
				while (end < text.Length && text[end] != '\n')
					end++;
				var value = StringView(text, i + 1, end - i - 1);
				value.Trim();
				let replaced = scope String();
				if (!value.IsEmpty && RewritePath(value, moves, isFolder, replaced))
				{
					result.Append("= ");
					result.Append(replaced);
					changed = true;
					i = end;
					continue;
				}
			}
			result.Append(c);
			i++;
		}
		if (changed)
			text.Set(result);
		return changed;
	}

	/// The new path for one path, if a move covers it.
	public static bool RewritePath(StringView path, Span<(StringView from, StringView to)> moves, bool isFolder, String outPath)
	{
		if (path.IsEmpty)
			return false;
		for (let move in moves)
		{
			if (!path.StartsWith(move.from))
				continue;
			if (path.Length == move.from.Length)
			{
				outPath.Append(move.to);
				return true;
			}
			let next = path[move.from.Length];
			// "Models/hero.glb#Armature": a part of the model. "Models/Props/...": inside a moved folder.
			if (next == '#' || (isFolder && next == '/'))
			{
				outPath.Append(move.to);
				outPath.Append(path.Substring(move.from.Length));
				return true;
			}
		}
		return false;
	}

	/// Rewrites references in every file that may hold them. Returns the number of files changed.
	public static int RewriteReferences(Span<(StringView from, StringView to)> moves, bool isFolder = false)
	{
		let files = scope List<String>();
		defer { ClearAndDeleteItems!(files); }
		GetReferencingFiles(files);
		int changed = 0;
		for (let file in files)
		{
			let text = scope String();
			if (File.ReadAllText(file, text) case .Err)
				continue;
			if (text.Contains('\0'))
				continue;
			if (RewriteText(text, moves, isFolder, file.EndsWith("project.tallow")))
			{
				if (File.WriteAllText(file, text) case .Ok)
					changed++;
			}
		}
		return changed;
	}

	/// The files that name an asset (relative path) by its path: for "Used by" in the Delete window, and Find
	/// References.
	public static void FindReferences(StringView relative, List<String> outFiles)
	{
		let files = scope List<String>();
		defer { ClearAndDeleteItems!(files); }
		GetReferencingFiles(files);
		let isFolder = Directory.Exists(scope $"{Assets.ProjectPath}/{relative}");
		for (let file in files)
		{
			let text = scope String();
			if (File.ReadAllText(file, text) case .Err)
				continue;
			if (text.Contains('\0') || !text.Contains(relative))
				continue;
			let probe = scope List<(StringView from, StringView to)>();
			probe.Add((relative, "x"));
			if (RewriteText(scope String(text), probe, isFolder, file.EndsWith("project.tallow")))
				outFiles.Add(new String(file));
		}
	}

	/// Every quoted path in a text that names an asset of the project (relative paths, as written; a model part's
	/// "#..." taken off).
	public static void GetNamedAssets(StringView text, List<String> outPaths, bool unquotedValues = false)
	{
		let root = Assets.ProjectPath;
		void Consider(StringView value)
		{
			var value;
			let hash = value.IndexOf('#');
			if (hash > 0)
				value = value.Substring(0, hash);
			if (value.IsEmpty || value.Length > 400 || value.Contains('\n') || value.StartsWith("builtin:") || Assets.IsAbsolute(value))
				return;
			if (sIdOf.ContainsKeyAlt(value) || File.Exists(scope $"{root}/{value}"))
			{
				for (let existing in outPaths)
				{
					if (existing == value)
						return;
				}
				outPaths.Add(new String(value));
			}
		}
		int i = 0;
		while (i < text.Length)
		{
			let c = text[i];
			if (c == '"' || c == '\'')
			{
				int end = i + 1;
				while (end < text.Length && text[end] != c && text[end] != '\n')
					end++;
				if (end < text.Length && text[end] == c)
					Consider(StringView(text, i + 1, end - i - 1));
				i = end + 1;
				continue;
			}
			if (unquotedValues && c == '=')
			{
				int end = i + 1;
				while (end < text.Length && text[end] != '\n')
					end++;
				var value = StringView(text, i + 1, end - i - 1);
				value.Trim();
				Consider(value);
				i = end;
				continue;
			}
			i++;
		}
	}
}
