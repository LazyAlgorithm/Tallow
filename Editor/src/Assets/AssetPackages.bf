using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Asset packages (docs/packages.md): a set of assets, with their dependencies and scripts, in one .tpackage file to
/// be put into another project, as a Unity package is.
///
/// A .tpackage is a pack file (PackFile, the format of game.tpak) holding "package.txt", which names the package and
/// lists its files, and each file under "assets/<its path>", with its .tmeta, so the assets keep their IDs
/// (AssetDatabase) in every project they go into. That is how importing a newer version finds the files an older one
/// put in, wherever they were moved since, and updates them in place.
///
/// What a project has imported is kept in <project>/Packages/packages.txt, so the Package Manager can list, update
/// and remove packages.
static class AssetPackages
{
	public const String Extension = ".tpackage";
	public const int FormatVersion = 1;

	public class Manifest
	{
		public String name = new .() ~ delete _;
		public String version = new .() ~ delete _;
		public String author = new .() ~ delete _;
		public String description = new .() ~ delete _;
		public String engine = new .() ~ delete _;
		public List<FileEntry> files = new .() ~ DeleteContainerAndItems!(_);

		public FileEntry Find(StringView path)
		{
			for (let file in files)
			{
				if (file.path == path)
					return file;
			}
			return null;
		}
	}

	public class FileEntry
	{
		/// Its path in the project it was exported from (relative to the Assets folder).
		public String path = new .() ~ delete _;
		/// From its .tmeta; empty for scripts and side files, which have none.
		public String id = new .() ~ delete _;
		public uint32 crc;
		public int64 size;
	}

	/// The package's name made safe for a file name: "Forest Props" -> "Forest_Props".
	public static void FileNameOf(StringView name, String outName)
	{
		for (let c in name.RawChars)
			outName.Append((c.IsLetterOrDigit || c == '-' || c == '.') ? c : '_');
		if (outName.IsEmpty)
			outName.Append("Package");
	}

	/// The project's own folder of packages (<project>/Packages).
	public static void PackagesFolder(String outPath)
	{
		let project = Project.Current;
		if (project != null)
			outPath.AppendF("{}/Packages", project.Path);
	}

	public static void EngineVersion(String outVersion)
	{
		let project = Project.Current;
		let text = scope String();
		if (project == null || File.ReadAllText(scope $"{project.EngineRoot}/tallow-version.json", text) case .Err)
			return;
		let key = text.IndexOf("\"version\"");
		if (key < 0)
			return;
		let start = text.IndexOf('"', text.IndexOf(':', key) + 1);
		let end = start >= 0 ? text.IndexOf('"', start + 1) : -1;
		if (start >= 0 && end > start)
			outVersion.Append(text, start + 1, end - start - 1);
	}

	// ---------------------------------------------------------------- what to export

	/// Why a file is in an export: picked, or needed by one that is.
	public class ExportItem
	{
		public String path = new .() ~ delete _;
		public String reason = new .() ~ delete _;
		public bool include = true;
		public bool isScript;
	}

	/// The files an export of these assets (relative paths, files or folders) holds: every file in a folder, and, with
	/// dependencies, what each names (models, textures, materials, prefabs, scenes, sounds...) and the scripts of the
	/// components its scenes and prefabs use, followed through all of those.
	public static void CollectExport(Span<StringView> picked, bool dependencies, List<ExportItem> outItems)
	{
		let root = Assets.ProjectPath;
		let have = scope HashSet<String>();
		defer { for (let item in have) delete item; }
		let queue = scope List<String>();
		defer { ClearAndDeleteItems!(queue); }

		void Add(StringView path, StringView reason)
		{
			if (have.ContainsAlt(path))
				return;
			let full = scope $"{root}/{path}";
			if (!File.Exists(full))
				return;
			let name = Path.GetFileName(path, .. scope .());
			if (AssetDatabase.IsCompanion(name) || name == "Program.bf" || name.StartsWith('.'))
				return;
			have.Add(new String(path));
			let item = new ExportItem();
			item.path.Set(path);
			item.reason.Set(reason);
			item.isScript = path.EndsWith(".bf");
			outItems.Add(item);
			queue.Add(new String(path));
		}

		for (let path in picked)
		{
			let full = scope $"{root}/{path}";
			if (Directory.Exists(full))
			{
				let files = scope List<String>();
				defer { ClearAndDeleteItems!(files); }
				ListFiles(full, files, 0);
				for (let file in files)
				{
					let relative = scope String();
					if (AssetDatabase.ToRelative(file, relative))
						Add(relative, "picked");
				}
			}
			else
				Add(path, "picked");
		}
		if (!dependencies)
			return;

		let scripts = new Dictionary<String, String>();
		defer { DeleteDictionaryAndKeysAndValues!(scripts); }
		bool scriptsIndexed = false;
		int next = 0;
		while (next < queue.Count)
		{
			let path = scope String(queue[next++]);
			let full = scope $"{root}/{path}";
			// A graph's generated script and a shader graph's generated shader go with it.
			StringView[?] generatedFrom = .(".tgraph", ".tsgraph", ".tsgraph");
			StringView[?] generatedAs = .(".bf", ".tshader", ".tcompute");
			for (int g < generatedFrom.Count)
			{
				if (path.EndsWith(generatedFrom[g]))
					Add(scope $"{path.Substring(0, path.Length - generatedFrom[g].Length)}{generatedAs[g]}", scope $"made from {path}");
			}
			if (!AssetDatabase.MayHoldReferences(path))
				continue;
			let text = scope String();
			if (File.ReadAllText(full, text) case .Err)
				continue;
			if (text.Contains('\0'))
				continue;
			let named = scope List<String>();
			defer { ClearAndDeleteItems!(named); }
			AssetDatabase.GetNamedAssets(text, named);
			// glTF names its buffers and pictures relative to itself.
			if (path.EndsWith(".gltf", .OrdinalIgnoreCase))
			{
				let folder = scope String();
				Path.GetDirectoryPath(path, folder).IgnoreError();
				let local = scope List<String>();
				defer { ClearAndDeleteItems!(local); }
				GetQuoted(text, local);
				for (let uri in local)
				{
					let candidate = folder.IsEmpty ? scope String(uri) : scope $"{folder}/{uri}";
					if (File.Exists(scope $"{root}/{candidate}"))
						named.Add(new String(candidate));
				}
			}
			for (let other in named)
				Add(other, scope $"named by {path}");
			// Components in scenes and prefabs: the project's scripts that define them.
			if (path.EndsWith(".tscene") || path.EndsWith(".tprefab") || path.EndsWith(".tmap"))
			{
				for (var line in text.Split('\n'))
				{
					line.Trim();
					StringView typeName = default;
					if (line.StartsWith("component "))
						typeName = line.Substring(10);
					else if (line.StartsWith("data "))
						typeName = line.Substring(5);
					else
						continue;
					let space = typeName.IndexOf(' ');
					if (space >= 0)
						typeName = typeName.Substring(0, space);
					let dot = typeName.LastIndexOf('.');
					let shortName = dot >= 0 ? typeName.Substring(dot + 1) : typeName;
					if (!scriptsIndexed)
					{
						scriptsIndexed = true;
						IndexScripts(scripts);
					}
					if (scripts.TryGetValueAlt(shortName, let script))
						Add(script, scope $"component {shortName}, used by {path}");
				}
			}
		}
	}

	static void ListFiles(StringView folder, List<String> outFiles, int depth)
	{
		if (depth > 32)
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (!name.StartsWith('.'))
				outFiles.Add(new String(scope $"{folder}/{name}"));
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (!name.StartsWith('.') && name != "Compiled")
				ListFiles(scope $"{folder}/{name}", outFiles, depth + 1);
		}
	}

	/// Every quoted string in a text.
	static void GetQuoted(StringView text, List<String> outValues)
	{
		int i = 0;
		while (i < text.Length)
		{
			if (text[i] != '"')
			{
				i++;
				continue;
			}
			int end = i + 1;
			while (end < text.Length && text[end] != '"' && text[end] != '\n')
				end++;
			if (end < text.Length && text[end] == '"' && end > i + 1)
				outValues.Add(new String(text, i + 1, end - i - 1));
			i = end + 1;
		}
	}

	/// Type name -> the project's script that defines it ("class Spinner", "struct Health").
	static void IndexScripts(Dictionary<String, String> outScripts)
	{
		let files = scope List<String>();
		defer { ClearAndDeleteItems!(files); }
		ListFiles(Assets.ProjectPath, files, 0);
		for (let file in files)
		{
			if (!file.EndsWith(".bf") || file.EndsWith("/Program.bf"))
				continue;
			let text = scope String();
			if (File.ReadAllText(file, text) case .Err)
				continue;
			let relative = scope String();
			AssetDatabase.ToRelative(file, relative);
			StringView[?] keywords = .("class ", "struct ");
			for (let keyword in keywords)
			{
				int at = 0;
				while ((at = text.IndexOf(keyword, at)) >= 0)
				{
					at += keyword.Length;
					// Only a declaration: at the start of a line or after an access word.
					int lineStart = at - keyword.Length;
					while (lineStart > 0 && text[lineStart - 1] != '\n')
						lineStart--;
					let before = StringView(text, lineStart, at - keyword.Length - lineStart);
					bool declaration = true;
					for (let c in before.RawChars)
					{
						if (!c.IsLetter && c != ' ' && c != '\t')
							declaration = false;
					}
					if (!declaration)
						continue;
					int end = at;
					while (end < text.Length && (text[end].IsLetterOrDigit || text[end] == '_'))
						end++;
					if (end == at)
						continue;
					let name = StringView(text, at, end - at);
					if (!outScripts.ContainsKeyAlt(name))
						outScripts[new String(name)] = new String(relative);
				}
			}
		}
	}

	// ---------------------------------------------------------------- writing and reading

	/// Writes a .tpackage of these files (relative paths), each with its side files (.tmeta, .import, .bonemap).
	public static Result<void> Export(StringView outFile, Manifest manifest, Span<StringView> paths, String error)
	{
		let root = Assets.ProjectPath;
		let names = scope List<String>();
		let datas = scope List<List<uint8>>();
		defer
		{
			ClearAndDeleteItems!(names);
			ClearAndDeleteItems!(datas);
		}
		ClearAndDeleteItems!(manifest.files);
		void AddFile(StringView relative, bool asset)
		{
			let data = new List<uint8>();
			if (File.ReadAll(scope $"{root}/{relative}", data) case .Err)
			{
				delete data;
				return;
			}
			let entry = new FileEntry();
			entry.path.Set(relative);
			if (asset && !AssetDatabase.GetId(relative, entry.id))
				AssetDatabase.ReadMeta(scope $"{root}/{relative}{AssetDatabase.MetaSuffix}", entry.id);
			entry.crc = PackFile.Crc32(data);
			entry.size = data.Count;
			manifest.files.Add(entry);
			names.Add(new String(scope $"assets/{relative}"));
			datas.Add(data);
		}
		for (let path in paths)
		{
			if (!File.Exists(scope $"{root}/{path}"))
				continue;
			AddFile(path, true);
			let companions = scope List<String>();
			defer { ClearAndDeleteItems!(companions); }
			AssetDatabase.GetCompanions(scope $"{root}/{path}", companions);
			for (let companion in companions)
			{
				let relative = scope String();
				if (AssetDatabase.ToRelative(companion, relative))
					AddFile(relative, false);
			}
		}
		if (manifest.engine.IsEmpty)
			EngineVersion(manifest.engine);
		let text = scope String();
		WriteManifest(manifest, text);
		let manifestData = scope List<uint8>();
		manifestData.AddRange(.((uint8*)text.Ptr, text.Length));

		let files = scope List<(StringView name, Span<uint8> data)>();
		files.Add(("package.txt", manifestData));
		for (int i < names.Count)
			files.Add((names[i], datas[i]));
		let folder = scope String();
		Path.GetDirectoryPath(outFile, folder).IgnoreError();
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		if (PackFile.Write(outFile, files) case .Err)
		{
			error.Set(scope $"Could not write {outFile}.");
			return .Err;
		}
		return .Ok;
	}

	public static void WriteManifest(Manifest manifest, String text)
	{
		text.AppendF("tallowpackage {}\n", FormatVersion);
		void Line(StringView key, StringView value)
		{
			text.Append(key);
			text.Append(' ');
			SceneSerializer.Quote(value, text);
			text.Append('\n');
		}
		Line("name", manifest.name);
		Line("version", manifest.version);
		if (!manifest.author.IsEmpty)
			Line("author", manifest.author);
		if (!manifest.description.IsEmpty)
			Line("description", manifest.description);
		if (!manifest.engine.IsEmpty)
			Line("engine", manifest.engine);
		for (let file in manifest.files)
		{
			text.Append("file ");
			SceneSerializer.Quote(file.path, text);
			if (!file.id.IsEmpty)
				text.AppendF(" id {}", file.id);
			text.AppendF(" crc {} size {}\n", file.crc, file.size);
		}
	}

	/// Checksums are written as unsigned numbers, past int32's range.
	static uint32 ParseCrc(StringView text) => (uint32.Parse(text) case .Ok(let value)) ? value : 0;

	public static bool ReadManifest(StringView text, Manifest manifest)
	{
		bool valid = false;
		let tokens = scope List<StringView>();
		let storage = scope List<String>();
		defer { ClearAndDeleteItems!(storage); }
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2)
				continue;
			switch (tokens[0])
			{
			case "tallowpackage": valid = true;
			case "name": manifest.name.Set(tokens[1]);
			case "version": manifest.version.Set(tokens[1]);
			case "author": manifest.author.Set(tokens[1]);
			case "description": manifest.description.Set(tokens[1]);
			case "engine": manifest.engine.Set(tokens[1]);
			case "file":
				let entry = new FileEntry();
				entry.path.Set(tokens[1]);
				for (int i = 2; i + 1 < tokens.Count; i += 2)
				{
					switch (tokens[i])
					{
					case "id": if (AssetDatabase.IsId(tokens[i + 1])) entry.id.Set(tokens[i + 1]);
					case "crc": entry.crc = ParseCrc(tokens[i + 1]);
					case "size": entry.size = (int64.Parse(tokens[i + 1]) case .Ok(let size)) ? size : 0;
					}
				}
				// Paths that would leave the Assets folder are not taken.
				if (entry.path.IsEmpty || entry.path.Contains("..") || Assets.IsAbsolute(entry.path) || entry.path.Contains('\\'))
					delete entry;
				else
					manifest.files.Add(entry);
			}
		}
		return valid && !manifest.name.IsEmpty;
	}

	/// Opens a .tpackage and reads its manifest. The pack stays open for reading its files.
	public static Result<void> Open(StringView file, PackFile pack, Manifest manifest, String error)
	{
		if (pack.Open(file) case .Err)
		{
			error.Set("That is not a package file, or it is damaged.");
			return .Err;
		}
		let data = scope List<uint8>();
		if (pack.Read("package.txt", data) case .Err)
		{
			error.Set("The package has no package.txt.");
			return .Err;
		}
		if (!ReadManifest(StringView((char8*)data.Ptr, data.Count), manifest))
		{
			error.Set("The package's package.txt could not be read.");
			return .Err;
		}
		return .Ok;
	}

	// ---------------------------------------------------------------- importing

	public enum ImportState
	{
		/// Not in the project: added.
		New,
		/// In the project already (the same ID, or the same path for a script) and the same.
		Same,
		/// In the project already, different: replaced by the package's.
		Changed,
		/// Its path is taken by something else: added under a free name (assets) or, for a script, only if chosen.
		Conflict
	}

	public class ImportItem
	{
		public FileEntry entry;
		/// Where it goes, relative to the Assets folder.
		public String target = new .() ~ delete _;
		public ImportState state;
		public bool include = true;
		public bool isScript;
		/// Its side files (.tmeta...), which go wherever it goes.
		public List<FileEntry> companions = new .() ~ delete _;
	}

	/// Works out where each file of a package goes. folder: put the package's files under this folder of the Assets
	/// folder (empty: at the paths they had where they were exported). Assets the project already has (by ID) stay
	/// where they are and are updated there.
	public static void PlanImport(PackFile pack, Manifest manifest, StringView folder, List<ImportItem> outItems)
	{
		let root = Assets.ProjectPath;
		let taken = scope HashSet<String>();
		defer { for (let path in taken) delete path; }
		// Side files first known by their owner.
		let owners = scope Dictionary<StringView, ImportItem>();
		List<String> scriptFiles = null;
		defer { if (scriptFiles != null) DeleteContainerAndItems!(scriptFiles); }
		for (let entry in manifest.files)
		{
			let name = Path.GetFileName(entry.path, .. scope .());
			if (AssetDatabase.IsCompanion(name) && manifest.Find(OwnerOf(entry.path, .. scope .())) != null)
				continue;
			let item = new ImportItem();
			item.entry = entry;
			item.isScript = entry.path.EndsWith(".bf");
			let existing = scope String();
			if (!entry.id.IsEmpty && AssetDatabase.GetPath(entry.id, existing))
				item.target.Set(existing);
			else if (folder.IsEmpty)
				item.target.Set(entry.path);
			else
				item.target.AppendF("{}/{}", folder, entry.path);
			// A script is known by its file name (scripts have no IDs): the project's copy, wherever it is, rather than a
			// second one that would define the same classes again.
			if (item.isScript && !File.Exists(scope $"{root}/{item.target}"))
			{
				if (scriptFiles == null)
				{
					scriptFiles = new List<String>();
					ListFiles(root, scriptFiles, 0);
				}
				let scriptName = Path.GetFileName(entry.path, .. scope .());
				for (let file in scriptFiles)
				{
					if (!file.EndsWith(scope $"/{scriptName}"))
						continue;
					let relative = scope String();
					AssetDatabase.ToRelative(file, relative);
					item.target.Set(relative);
					let data = scope List<uint8>();
					if ((File.ReadAll(file, data) case .Ok) && data.Count == entry.size && PackFile.Crc32(data) == entry.crc)
						break;
				}
			}
			let full = scope $"{root}/{item.target}";
			if (File.Exists(full))
			{
				let existingId = scope String();
				AssetDatabase.GetId(item.target, existingId);
				let sameAsset = !entry.id.IsEmpty && existingId == entry.id;
				let data = scope List<uint8>();
				let same = (File.ReadAll(full, data) case .Ok) && data.Count == entry.size && PackFile.Crc32(data) == entry.crc;
				if (sameAsset || (item.isScript && same) || (entry.id.IsEmpty && same))
					item.state = same ? .Same : .Changed;
				else if (item.isScript || entry.id.IsEmpty)
				{
					// A script or other file of the same name that is the project's own: replaced only if chosen.
					item.state = .Conflict;
					item.include = false;
				}
				else
				{
					// Another asset has its path: this one goes beside it under a free name.
					item.state = .Conflict;
					FreeName(item.target, taken);
				}
			}
			else
				item.state = .New;
			if (item.state == .Same)
				item.include = false;
			taken.Add(new String(item.target));
			owners[entry.path] = item;
			outItems.Add(item);
		}
		for (let entry in manifest.files)
		{
			let owner = OwnerOf(entry.path, .. scope .());
			if (owner.IsEmpty)
				continue;
			if (owners.TryGetValueAlt(owner, let item) && item.entry.path != entry.path)
				item.companions.Add(entry);
		}
	}

	/// For "Models/crate.glb.tmeta", "Models/crate.glb"; empty when the file is not a side file.
	static void OwnerOf(StringView path, String outOwner)
	{
		for (let suffix in AssetDatabase.CompanionSuffixes)
		{
			if (path.EndsWith(suffix, .OrdinalIgnoreCase) && path.Length > suffix.Length)
			{
				outOwner.Append(path.Substring(0, path.Length - suffix.Length));
				return;
			}
		}
	}

	/// "Models/crate.glb" -> "Models/crate 1.glb", the first name that is free on disk and not taken by this import.
	static void FreeName(String path, HashSet<String> taken)
	{
		let root = Assets.ProjectPath;
		let folder = scope String();
		Path.GetDirectoryPath(path, folder).IgnoreError();
		let stem = Path.GetFileNameWithoutExtension(path, .. scope .());
		let ext = Path.GetExtension(path, .. scope .());
		for (int n = 1; n < 1000; n++)
		{
			let candidate = scope String();
			if (!folder.IsEmpty)
				candidate.AppendF("{}/", folder);
			candidate.AppendF("{} {}{}", stem, n, ext);
			if (!File.Exists(scope $"{root}/{candidate}") && !taken.ContainsAlt(candidate))
			{
				path.Set(candidate);
				return;
			}
		}
	}

	/// Puts the chosen files of a planned import into the project. Text files that name other files of the package
	/// are changed to where those went. Returns how many files were written; scriptsAdded says whether any were
	/// scripts (the project then needs compiling).
	public static int ApplyImport(PackFile pack, Manifest manifest, List<ImportItem> items, StringView source, out bool scriptsAdded, String error)
	{
		scriptsAdded = false;
		let root = Assets.ProjectPath;
		let moves = scope List<(StringView from, StringView to)>();
		for (let item in items)
		{
			// Files left as they are still count: what the package names is where they are.
			if ((item.include || item.state == .Same) && item.entry.path != item.target)
				moves.Add((item.entry.path, item.target));
		}
		int written = 0;
		let installed = scope List<(String path, uint32 crc)>();
		defer
		{
			for (let file in installed)
				delete file.path;
		}
		for (let item in items)
		{
			// Not recorded as the package's: a file the project had before (the same script) must not go when the
			// package is removed. An earlier version's record of it stays.
			if (!item.include)
				continue;
			let data = scope List<uint8>();
			if (pack.Read(scope $"assets/{item.entry.path}", data) case .Err)
			{
				error.AppendF("{} could not be read from the package. ", item.entry.path);
				continue;
			}
			// References inside the package, to where its files went.
			if (moves.Count > 0 && AssetDatabase.MayHoldReferences(item.entry.path) && !data.Contains(0))
			{
				let text = scope String((char8*)data.Ptr, data.Count);
				if (AssetDatabase.RewriteText(text, moves))
				{
					data.Clear();
					data.AddRange(.((uint8*)text.Ptr, text.Length));
				}
			}
			let full = scope $"{root}/{item.target}";
			let folder = scope String();
			Path.GetDirectoryPath(full, folder).IgnoreError();
			Directory.CreateDirectory(folder).IgnoreError();
			if (File.WriteAll(full, data) case .Err)
			{
				error.AppendF("{} could not be written. ", item.target);
				continue;
			}
			written++;
			installed.Add((new String(item.target), PackFile.Crc32(data)));
			if (item.isScript)
				scriptsAdded = true;
			for (let companion in item.companions)
			{
				let side = scope List<uint8>();
				if (pack.Read(scope $"assets/{companion.path}", side) case .Err)
					continue;
				let suffix = companion.path.Substring(item.entry.path.Length);
				File.WriteAll(scope $"{full}{suffix}", side).IgnoreError();
			}
			// An asset whose .tmeta was not in the package still keeps the package's ID.
			if (!item.entry.id.IsEmpty)
				AssetDatabase.WriteMeta(scope $"{full}{AssetDatabase.MetaSuffix}", item.entry.id);
		}
		AssetDatabase.Refresh(false);
		Record(manifest, source, installed);
		return written;
	}

	// ---------------------------------------------------------------- what the project has

	public class Installed
	{
		public String name = new .() ~ delete _;
		public String version = new .() ~ delete _;
		public String source = new .() ~ delete _;
		public String description = new .() ~ delete _;
		/// Each file as imported: its path and checksum (to tell whether it was changed since).
		public List<(String path, uint32 crc)> files = new .() ~ { for (let file in _) delete file.path; delete _; };
	}

	static void RecordPath(String outPath)
	{
		PackagesFolder(outPath);
		outPath.Append("/packages.txt");
	}

	public static void LoadInstalled(List<Installed> outPackages)
	{
		let text = scope String();
		if (File.ReadAllText(RecordPath(.. scope .()), text) case .Err)
			return;
		let tokens = scope List<StringView>();
		let storage = scope List<String>();
		defer { ClearAndDeleteItems!(storage); }
		Installed current = null;
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2)
				continue;
			switch (tokens[0])
			{
			case "package":
				current = new Installed();
				current.name.Set(tokens[1]);
				outPackages.Add(current);
			case "version": current?.version.Set(tokens[1]);
			case "source": current?.source.Set(tokens[1]);
			case "description": current?.description.Set(tokens[1]);
			case "file":
				if (current != null)
				{
					uint32 crc = 0;
					if (tokens.Count > 2)
						crc = ParseCrc(tokens[2]);
					current.files.Add((new String(tokens[1]), crc));
				}
			}
		}
	}

	public static void SaveInstalled(List<Installed> packages)
	{
		let text = scope String();
		text.Append("# Asset packages imported into this project (docs/packages.md). Written by the editor.\n");
		for (let package in packages)
		{
			text.Append("package ");
			SceneSerializer.Quote(package.name, text);
			text.Append("\nversion ");
			SceneSerializer.Quote(package.version, text);
			text.Append("\nsource ");
			SceneSerializer.Quote(package.source, text);
			text.Append('\n');
			if (!package.description.IsEmpty)
			{
				text.Append("description ");
				SceneSerializer.Quote(package.description, text);
				text.Append('\n');
			}
			for (let file in package.files)
			{
				text.Append("file ");
				SceneSerializer.Quote(file.path, text);
				text.AppendF(" {}\n", file.crc);
			}
		}
		let path = RecordPath(.. scope .());
		let folder = scope String();
		Path.GetDirectoryPath(path, folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		File.WriteAllText(path, text).IgnoreError();
	}

	/// Notes a package as imported (replacing an earlier version's record, keeping files that version put in that
	/// this one still has).
	static void Record(Manifest manifest, StringView source, List<(String path, uint32 crc)> files)
	{
		let packages = scope List<Installed>();
		defer { ClearAndDeleteItems!(packages); }
		LoadInstalled(packages);
		Installed record = null;
		for (let package in packages)
		{
			if (package.name == manifest.name)
				record = package;
		}
		if (record == null)
		{
			record = new Installed();
			record.name.Set(manifest.name);
			packages.Add(record);
		}
		record.version.Set(manifest.version);
		record.source.Set(source);
		record.description.Set(manifest.description);
		for (let file in files)
		{
			bool found = false;
			for (var existing in ref record.files)
			{
				if (existing.path == file.path)
				{
					existing.crc = file.crc;
					found = true;
				}
			}
			if (!found)
				record.files.Add((new String(file.path), file.crc));
		}
		SaveInstalled(packages);
	}

	/// Whether a package's file is as it was imported. (Records follow moves made in the editor, ApplyMoves.)
	public static bool IsUnchanged(StringView path, uint32 crc)
	{
		let data = scope List<uint8>();
		if (File.ReadAll(scope $"{Assets.ProjectPath}/{path}", data) case .Err)
			return false;
		return PackFile.Crc32(data) == crc;
	}

	/// Removes a package: its files that are as they were imported (changed ones stay, and are listed in kept), and
	/// folders left empty. Its record goes.
	public static int Remove(StringView name, List<String> kept)
	{
		let packages = scope List<Installed>();
		defer { ClearAndDeleteItems!(packages); }
		LoadInstalled(packages);
		int removed = 0;
		for (let package in packages)
		{
			if (package.name != name)
				continue;
			let folders = scope HashSet<String>();
			defer { for (let folder in folders) delete folder; }
			for (let file in package.files)
			{
				let full = scope $"{Assets.ProjectPath}/{file.path}";
				if (!File.Exists(full))
					continue;
				if (!IsUnchanged(file.path, file.crc))
				{
					kept.Add(new String(file.path));
					continue;
				}
				if (AssetDatabase.Delete(full) case .Ok)
					removed++;
				let folder = scope String();
				Path.GetDirectoryPath(full, folder).IgnoreError();
				if (!folders.ContainsAlt(folder))
					folders.Add(new String(folder));
			}
			// Empty folders, deepest first.
			let sorted = scope List<String>();
			for (let folder in folders)
				sorted.Add(folder);
			sorted.Sort(scope (a, b) => b.Length <=> a.Length);
			for (let folder in sorted)
			{
				let current = scope String(folder);
				while (current.Length > Assets.ProjectPath.Length && IsEmptyFolder(current))
				{
					Directory.Delete(current).IgnoreError();
					let parent = scope String();
					Path.GetDirectoryPath(current, parent).IgnoreError();
					current.Set(parent);
				}
			}
			packages.Remove(package);
			delete package;
			break;
		}
		SaveInstalled(packages);
		AssetDatabase.Refresh(false);
		return removed;
	}

	static bool IsEmptyFolder(StringView folder)
	{
		if (!Directory.Exists(folder))
			return false;
		for (let entry in Directory.EnumerateFiles(folder))
			return false;
		for (let entry in Directory.EnumerateDirectories(folder))
			return false;
		return true;
	}

	/// After assets moved: the records follow, so removing and updating still find them.
	public static void ApplyMoves(Span<(String from, String to)> moves)
	{
		let packages = scope List<Installed>();
		defer { ClearAndDeleteItems!(packages); }
		LoadInstalled(packages);
		bool changed = false;
		for (let package in packages)
		{
			for (let file in package.files)
			{
				let remapped = scope String();
				for (let move in moves)
				{
					if (!file.path.StartsWith(move.from))
						continue;
					let rest = file.path.Substring(move.from.Length);
					if (!rest.IsEmpty && rest[0] != '/')
						continue;
					remapped.AppendF("{}{}", move.to, rest);
					break;
				}
				if (!remapped.IsEmpty)
				{
					file.path.Set(remapped);
					changed = true;
				}
			}
		}
		if (changed)
			SaveInstalled(packages);
	}
}
