using System;
using System.Collections;
using System.IO;
using System.Security.Cryptography;
using Tallow;

namespace Tallow.Editor;

/// The windows for asset packages (docs/packages.md): Export Package, Import Package and the Package Manager.
extension EditorApp
{
	// ---------------------------------------------------------------- Export Package

	bool mShowExportPackage;
	List<String> mExportPicked = new .() ~ DeleteContainerAndItems!(_);
	List<AssetPackages.ExportItem> mExportItems = new .() ~ DeleteContainerAndItems!(_);
	bool mExportDependencies = true;
	String mExportName = new .() ~ delete _;
	String mExportVersion = new .("1.0.0") ~ delete _;
	String mExportAuthor = new .() ~ delete _;
	String mExportDescription = new .() ~ delete _;
	String mExportFile = new .() ~ delete _;

	/// Opens Export Package with these assets (full paths, files or folders) picked.
	void OpenExportPackage(Span<StringView> fullPaths)
	{
		EnsureAssetIds();
		ClearAndDeleteItems!(mExportPicked);
		for (let full in fullPaths)
		{
			let relative = scope String();
			if (AssetDatabase.ToRelative(full, relative))
				mExportPicked.Add(new String(relative));
		}
		if (mExportName.IsEmpty && mExportPicked.Count > 0)
			Path.GetFileNameWithoutExtension(mExportPicked[0], mExportName);
		if (mExportName.IsEmpty && Project.Current != null)
			mExportName.Set(Project.Current.Name);
		RecollectExport();
		UpdateExportFile();
		mShowExportPackage = true;
	}

	void RecollectExport()
	{
		ClearAndDeleteItems!(mExportItems);
		let picked = scope List<StringView>();
		for (let path in mExportPicked)
			picked.Add(path);
		AssetPackages.CollectExport(picked, mExportDependencies, mExportItems);
	}

	void UpdateExportFile()
	{
		mExportFile.Clear();
		AssetPackages.PackagesFolder(mExportFile);
		mExportFile.Append("/Exports/");
		AssetPackages.FileNameOf(mExportName, mExportFile);
		mExportFile.AppendF("-{}{}", mExportVersion, AssetPackages.Extension);
	}

	void DrawExportPackage()
	{
		if (!mShowExportPackage)
			return;
		ImGui.SetNextWindowSize(.(640, 560), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Export Package", &mShowExportPackage))
		{
			bool nameChanged = ImGui.InputText("Name", mExportName);
			nameChanged |= ImGui.InputText("Version", mExportVersion);
			if (nameChanged)
				UpdateExportFile();
			ImGui.InputText("Author", mExportAuthor);
			ImGui.InputText("Description", mExportDescription);
			ImGui.InputText("File", mExportFile);
			if (ImGui.Checkbox("Include dependencies (what the picked assets name, and the scripts of their components)", ref mExportDependencies))
				RecollectExport();
			ImGui.Separator();
			int included = 0;
			int scripts = 0;
			for (let item in mExportItems)
			{
				if (item.include)
				{
					included++;
					if (item.isScript)
						scripts++;
				}
			}
			let summary = scope String();
			summary.AppendF("{} of {} files", included, mExportItems.Count);
			if (scripts > 0)
				summary.AppendF(", {} script{}", scripts, (scripts == 1) ? "" : "s");
			ImGui.Text(summary);
			if (ImGui.BeginChild("exportfiles", .(0, -ImGui.GetFrameHeight() * 1.6f), 1))
			{
				for (int i < mExportItems.Count)
				{
					let item = mExportItems[i];
					ImGui.PushID((int32)i);
					ImGui.Checkbox(item.path, ref item.include);
					if (item.reason != "picked")
					{
						ImGui.SameLine();
						ImGui.TextDisabled(item.reason);
					}
					ImGui.PopID();
				}
			}
			ImGui.EndChild();
			ImGui.BeginDisabled(included == 0 || mExportName.IsEmpty || mExportFile.IsEmpty);
			if (ImGui.Button("Export", .(140, 0)))
				ExportPackageNow();
			ImGui.EndDisabled();
			ImGui.SameLine();
			if (ImGui.Button("Show Folder", .(140, 0)))
			{
				let folder = scope String();
				Path.GetDirectoryPath(mExportFile, folder).IgnoreError();
				Directory.CreateDirectory(folder).IgnoreError();
				Terminal.Open(folder);
			}
		}
		ImGui.End();
	}

	bool ExportPackageNow()
	{
		let manifest = scope AssetPackages.Manifest();
		manifest.name.Set(mExportName);
		manifest.version.Set(mExportVersion);
		manifest.author.Set(mExportAuthor);
		manifest.description.Set(mExportDescription);
		let paths = scope List<StringView>();
		for (let item in mExportItems)
		{
			if (item.include)
				paths.Add(item.path);
		}
		let error = scope String();
		if (AssetPackages.Export(mExportFile, manifest, paths, error) case .Err)
		{
			Log.Error(error);
			return false;
		}
		Log.Info(scope $"Exported {manifest.name} {manifest.version} ({manifest.files.Count} files) to {mExportFile}");
		return true;
	}

	// ---------------------------------------------------------------- Import Package

	bool mShowImportPackage;
	PackFile mImportPack ~ delete _;
	AssetPackages.Manifest mImportManifest ~ delete _;
	List<AssetPackages.ImportItem> mImportItems = new .() ~ DeleteContainerAndItems!(_);
	String mImportFile = new .() ~ delete _;
	String mImportFolder = new .() ~ delete _;
	String mImportError = new .() ~ delete _;

	/// Opens a .tpackage in the Import Package window. False (and the reason logged) when it cannot be read.
	bool OpenImportPackage(StringView file)
	{
		EnsureAssetIds();
		DeleteAndNullify!(mImportPack);
		DeleteAndNullify!(mImportManifest);
		ClearAndDeleteItems!(mImportItems);
		mImportError.Clear();
		mImportFile.Set(file);
		mImportPack = new PackFile();
		mImportManifest = new AssetPackages.Manifest();
		if (AssetPackages.Open(file, mImportPack, mImportManifest, mImportError) case .Err)
		{
			Log.Error(scope $"{file}: {mImportError}");
			DeleteAndNullify!(mImportPack);
			DeleteAndNullify!(mImportManifest);
			return false;
		}
		ReplanImport();
		mShowImportPackage = true;
		return true;
	}

	void ReplanImport()
	{
		ClearAndDeleteItems!(mImportItems);
		if (mImportPack == null)
			return;
		var folder = StringView(mImportFolder);
		folder.Trim();
		while (folder.EndsWith('/'))
			folder.RemoveFromEnd(1);
		AssetPackages.PlanImport(mImportPack, mImportManifest, folder, mImportItems);
	}

	static Color ImportStateColor(AssetPackages.ImportState state)
	{
		switch (state)
		{
		case .New: return .(0.45f, 0.85f, 0.45f, 1);
		case .Same: return .(0.6f, 0.6f, 0.6f, 1);
		case .Changed: return .(0.45f, 0.7f, 1, 1);
		case .Conflict: return .(1, 0.7f, 0.3f, 1);
		}
	}

	void DrawImportPackage()
	{
		if (!mShowImportPackage)
			return;
		ImGui.SetNextWindowSize(.(680, 560), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Import Package", &mShowImportPackage) && mImportManifest != null)
		{
			let m = mImportManifest;
			let title = scope String();
			title.AppendF("{} {}", m.name, m.version);
			if (!m.author.IsEmpty)
				title.AppendF("  by {}", m.author);
			ImGui.Text(title);
			if (!m.description.IsEmpty)
				ImGui.TextWrapped(m.description);
			if (!m.engine.IsEmpty)
				ImGui.TextDisabled(scope $"Made with Tallow {m.engine}");
			let installed = scope List<AssetPackages.Installed>();
			defer { ClearAndDeleteItems!(installed); }
			AssetPackages.LoadInstalled(installed);
			for (let package in installed)
			{
				if (package.name == m.name)
					ImGui.TextColored(.(0.45f, 0.7f, 1, 1), scope $"Version {package.version} is in this project: this updates it.");
			}
			if (ImGui.InputText("Into folder", mImportFolder, 0, "(empty: where the package's files were)"))
				ReplanImport();
			ImGui.TextDisabled("Assets the project already has (the same ID) are updated where they are, wherever that is now.");
			ImGui.Separator();
			int chosen = 0;
			int scripts = 0;
			for (let item in mImportItems)
			{
				if (item.include)
				{
					chosen++;
					if (item.isScript)
						scripts++;
				}
			}
			if (ImGui.BeginChild("importfiles", .(0, -ImGui.GetFrameHeight() * 3.6f), 1))
			{
				for (int i < mImportItems.Count)
				{
					let item = mImportItems[i];
					ImGui.PushID((int32)i);
					ImGui.Checkbox("##take", ref item.include);
					ImGui.SameLine();
					let state = scope String();
					item.state.ToString(state);
					ImGui.TextColored(ImportStateColor(item.state), state);
					ImGui.SameLine(110);
					ImGui.Text(item.target);
					if (item.target != item.entry.path && ImGui.IsItemHovered())
						ImGui.SetTooltip(scope $"In the package: {item.entry.path}");
					ImGui.PopID();
				}
			}
			ImGui.EndChild();
			ImGui.TextWrapped("New: added.  Changed: replaced with the package's.  Same: already as in the package.  Conflict: the name is taken; an asset goes beside it under a free name, a script only replaces the project's if ticked.");
			ImGui.BeginDisabled(chosen == 0);
			if (ImGui.Button(scope $"Import {chosen} file{(chosen == 1) ? "" : "s"}", .(180, 0)))
				ImportPackageNow();
			ImGui.EndDisabled();
			if (scripts > 0)
			{
				ImGui.SameLine();
				ImGui.TextDisabled(scope $"{scripts} script{(scripts == 1) ? "" : "s"}: the project is compiled after importing.");
			}
		}
		ImGui.End();
	}

	bool ImportPackageNow()
	{
		if (mImportPack == null)
			return false;
		let error = scope String();
		let written = AssetPackages.ApplyImport(mImportPack, mImportManifest, mImportItems, mImportFile, let scriptsAdded, error);
		if (!error.IsEmpty)
			Log.Warning(error);
		Log.Info(scope $"Imported {mImportManifest.name} {mImportManifest.version}: {written} file{(written == 1) ? "" : "s"}.");
		RefreshAssetList();
		ModelImport.Scan();
		if (scriptsAdded)
			RequestRebuild();
		mShowImportPackage = false;
		return true;
	}

	// ---------------------------------------------------------------- Package Manager

	bool mShowPackageManager;
	int32 mPackageTab;
	List<AssetPackages.Installed> mInstalledPackages = new .() ~ DeleteContainerAndItems!(_);
	List<String> mPackageFiles = new .() ~ DeleteContainerAndItems!(_);
	String mPackagePathInput = new .() ~ delete _;
	String mRemovePackage = new .() ~ delete _;
	List<PackageCatalog.Entry> mCatalog = new .() ~ DeleteContainerAndItems!(_);
	String mCatalogSources = new .() ~ delete _;
	String mCatalogError = new .() ~ delete _;
	HttpDownload mPackageDownload ~ delete _;
	PackageCatalog.Entry mDownloading ~ delete _;

	void OpenPackageManager()
	{
		mShowPackageManager = true;
		RefreshPackageManager();
	}

	void RefreshPackageManager()
	{
		EnsureAssetIds();
		ClearAndDeleteItems!(mInstalledPackages);
		AssetPackages.LoadInstalled(mInstalledPackages);
		ClearAndDeleteItems!(mPackageFiles);
		let folders = scope List<String>();
		defer { ClearAndDeleteItems!(folders); }
		folders.Add(AssetPackages.PackagesFolder(.. new String()));
		let home = scope String();
		Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
		if (home.IsEmpty)
			Environment.GetEnvironmentVariable("USERPROFILE", home).IgnoreError();
		if (!home.IsEmpty)
			folders.Add(new String(scope $"{home}/Downloads"));
		for (let folder in folders)
			FindPackageFiles(folder, mPackageFiles, 0);
		mCatalogSources.Clear();
		PackageCatalog.LoadSources(mCatalogSources);
	}

	static void FindPackageFiles(StringView folder, List<String> outFiles, int depth)
	{
		if (depth > 3 || !Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (name.EndsWith(AssetPackages.Extension, .OrdinalIgnoreCase))
				outFiles.Add(new String(scope $"{folder}/{name}"));
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (!name.StartsWith('.'))
				FindPackageFiles(scope $"{folder}/{name}", outFiles, depth + 1);
		}
	}

	void DrawPackageManager()
	{
		PollPackageDownload();
		if (!mShowPackageManager)
			return;
		ImGui.SetNextWindowSize(.(720, 520), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Package Manager", &mShowPackageManager))
		{
			if (ImGui.RadioButton("In this project", mPackageTab == 0))
				mPackageTab = 0;
			ImGui.SameLine();
			if (ImGui.RadioButton("Package files", mPackageTab == 1))
				mPackageTab = 1;
			ImGui.SameLine();
			if (ImGui.RadioButton("Catalogs", mPackageTab == 2))
				mPackageTab = 2;
			ImGui.SameLine();
			if (ImGui.Button("Refresh"))
				RefreshPackageManager();
			ImGui.Separator();
			switch (mPackageTab)
			{
			case 0: DrawInstalledPackages();
			case 1: DrawPackageFiles();
			default: DrawPackageCatalogs();
			}
		}
		ImGui.End();
	}

	void DrawInstalledPackages()
	{
		if (mInstalledPackages.IsEmpty)
		{
			ImGui.TextDisabled("No packages have been imported into this project.");
			return;
		}
		for (int i < mInstalledPackages.Count)
		{
			let package = mInstalledPackages[i];
			ImGui.PushID((int32)i);
			int present = 0;
			int changed = 0;
			for (let file in package.files)
			{
				if (!File.Exists(scope $"{Assets.ProjectPath}/{file.path}"))
					continue;
				present++;
				if (!AssetPackages.IsUnchanged(file.path, file.crc))
					changed++;
			}
			ImGui.Text(scope $"{package.name}  {package.version}");
			ImGui.SameLine();
			let counts = scope String();
			counts.AppendF("{} file{}", present, (present == 1) ? "" : "s");
			if (changed > 0)
				counts.AppendF(", {} changed since", changed);
			ImGui.TextDisabled(counts);
			if (!package.description.IsEmpty)
				ImGui.TextWrapped(package.description);
			if (ImGui.Button("Remove"))
			{
				mRemovePackage.Set(package.name);
				ImGui.OpenPopup("Remove Package");
			}
			if (File.Exists(package.source))
			{
				ImGui.SameLine();
				if (ImGui.Button("Import Again"))
					OpenImportPackage(package.source);
			}
			if (ImGui.BeginPopupModal("Remove Package", null, ImGui.WindowFlags.AlwaysAutoResize))
			{
				ImGui.Text(scope $"Remove {mRemovePackage}?");
				ImGui.TextDisabled("Its files that are as they were imported are deleted; files changed since are kept.");
				if (ImGui.Button("Remove", .(120, 0)))
				{
					let kept = scope List<String>();
					defer { ClearAndDeleteItems!(kept); }
					bool hadScripts = false;
					for (let other in mInstalledPackages)
					{
						if (other.name != mRemovePackage)
							continue;
						for (let file in other.files)
							hadScripts |= file.path.EndsWith(".bf");
					}
					let removed = AssetPackages.Remove(mRemovePackage, kept);
					// Its scripts are gone: the project is compiled without them.
					if (hadScripts)
						RequestRebuild();
					let message = scope String();
					message.AppendF("Removed {}: {} file{} deleted", mRemovePackage, removed, (removed == 1) ? "" : "s");
					if (kept.Count > 0)
						message.AppendF(", {} changed file{} kept", kept.Count, (kept.Count == 1) ? "" : "s");
					message.Append('.');
					Log.Info(message);
					for (let path in kept)
						Log.Info(scope $"  kept {path}");
					ImGui.CloseCurrentPopup();
					RefreshAssetList();
					RefreshPackageManager();
					ImGui.EndPopup();
					ImGui.PopID();
					return;
				}
				ImGui.SameLine();
				if (ImGui.Button("Cancel", .(120, 0)))
					ImGui.CloseCurrentPopup();
				ImGui.EndPopup();
			}
			ImGui.Separator();
			ImGui.PopID();
		}
	}

	void DrawPackageFiles()
	{
		ImGui.TextDisabled("Package files in this project's Packages folder and in Downloads. Dropping a .tpackage on the editor opens it too.");
		ImGui.SetNextItemWidth(-130);
		ImGui.InputText("##packagepath", mPackagePathInput, 0, "/path/to/Package.tpackage");
		ImGui.SameLine();
		if (ImGui.Button("Open", .(120, 0)) && !mPackagePathInput.IsEmpty)
			OpenImportPackage(mPackagePathInput);
		ImGui.Separator();
		if (mPackageFiles.IsEmpty)
			ImGui.TextDisabled("None found.");
		for (int i < mPackageFiles.Count)
		{
			ImGui.PushID((int32)i);
			if (ImGui.Button("Import..."))
				OpenImportPackage(mPackageFiles[i]);
			ImGui.SameLine();
			ImGui.Text(mPackageFiles[i]);
			ImGui.PopID();
		}
	}

	void DrawPackageCatalogs()
	{
		ImGui.TextDisabled("Catalog addresses, one per line (kept in Packages/sources.txt). A catalog lists packages to download.");
		if (ImGui.InputTextMultiline("##sources", mCatalogSources, .(-1, ImGui.GetTextLineHeight() * 4.5f)))
			PackageCatalog.SaveSources(mCatalogSources);
		ImGui.BeginDisabled(mCatalogSources.IsEmpty);
		if (ImGui.Button("Fetch Catalogs"))
		{
			ClearAndDeleteItems!(mCatalog);
			mCatalogError.Clear();
			PackageCatalog.Fetch(mCatalogSources, mCatalog, mCatalogError);
		}
		ImGui.EndDisabled();
		if (!mCatalogError.IsEmpty)
			ImGui.TextColored(.(1, 0.6f, 0.4f, 1), mCatalogError);
		if (mPackageDownload != null && mDownloading != null)
		{
			let fraction = mPackageDownload.Fraction;
			ImGui.ProgressBar(fraction < 0 ? 0 : fraction, .(-1, 0), scope $"Downloading {mDownloading.name} {mDownloading.version}");
		}
		ImGui.Separator();
		let installed = scope List<AssetPackages.Installed>();
		defer { ClearAndDeleteItems!(installed); }
		AssetPackages.LoadInstalled(installed);
		for (int i < mCatalog.Count)
		{
			let entry = mCatalog[i];
			ImGui.PushID((int32)i);
			String have = null;
			for (let package in installed)
			{
				if (package.name == entry.name)
					have = package.version;
			}
			let title = scope String();
			title.AppendF("{}  {}", entry.name, entry.version);
			if (!entry.author.IsEmpty)
				title.AppendF("  by {}", entry.author);
			ImGui.Text(title);
			ImGui.SameLine();
			if (have != null)
			{
				let note = scope String();
				if (have == entry.version)
					note.Append("(in this project)");
				else
					note.AppendF("(this project has {})", have);
				ImGui.TextDisabled(note);
			}
			if (!entry.description.IsEmpty)
				ImGui.TextWrapped(entry.description);
			ImGui.BeginDisabled(mPackageDownload != null);
			if (ImGui.Button(have == null ? "Download and Import..." : (have == entry.version ? "Download Again..." : "Update...")))
				StartPackageDownload(entry);
			ImGui.EndDisabled();
			ImGui.Separator();
			ImGui.PopID();
		}
	}

	void StartPackageDownload(PackageCatalog.Entry entry)
	{
		let folder = scope String();
		AssetPackages.PackagesFolder(folder);
		folder.Append("/Downloads");
		Directory.CreateDirectory(folder).IgnoreError();
		let file = scope String();
		file.AppendF("{}/", folder);
		AssetPackages.FileNameOf(entry.name, file);
		file.AppendF("-{}{}", entry.version, AssetPackages.Extension);
		// A catalog on a drive names files: copied, not downloaded.
		if (!entry.url.StartsWith("http://") && !entry.url.StartsWith("https://"))
		{
			let source = entry.url.StartsWith("file://") ? entry.url.Substring(7) : (StringView)entry.url;
			if (File.Copy(source, file, true) case .Err)
			{
				Log.Error(scope $"Could not copy {source}.");
				return;
			}
			if (VerifyPackageFile(entry, file) && OpenImportPackage(file) && mImportWhenDownloaded)
				ImportPackageNow();
			mImportWhenDownloaded = false;
			return;
		}
		DeleteAndNullify!(mDownloading);
		mDownloading = entry.Clone();
		delete mPackageDownload;
		mPackageDownload = new HttpDownload(entry.url, file);
		mPackageDownload.Start();
	}

	void PollPackageDownload()
	{
		if (mPackageDownload == null || !mPackageDownload.Finished)
			return;
		let download = mPackageDownload;
		mPackageDownload = null;
		defer { delete download; }
		if (!download.Succeeded)
		{
			Log.Error(scope $"Could not download {mDownloading.name}: {download.Error}");
			return;
		}
		if (!VerifyPackageFile(mDownloading, download.Path))
			return;
		Log.Info(scope $"Downloaded {mDownloading.name} {mDownloading.version}.");
		if (OpenImportPackage(download.Path) && mImportWhenDownloaded)
			ImportPackageNow();
		mImportWhenDownloaded = false;
	}

	/// The catalog's checksum, when it gives one, must match: what was fetched is what was published. A file that does
	/// not match is deleted.
	static bool VerifyPackageFile(PackageCatalog.Entry entry, StringView file)
	{
		if (entry.sha256.IsEmpty)
			return true;
		let data = scope List<uint8>();
		File.ReadAll(file, data).IgnoreError();
		let hash = SHA256.Hash(data).ToString(.. scope .());
		if (StringView.Compare(hash, entry.sha256, true) == 0)
			return true;
		Log.Error(scope $"{entry.name}: the download does not match the catalog's checksum, so it was not opened.");
		File.Delete(file).IgnoreError();
		return false;
	}

	/// --package-download <catalog address> [--import-package-now]: fetches the catalog and downloads its first
	/// package (automated checks of catalogs and downloads).
	bool mImportWhenDownloaded;

	void StartCatalogSwitch(StringView catalog)
	{
		ClearAndDeleteItems!(mCatalog);
		mCatalogError.Clear();
		PackageCatalog.Fetch(catalog, mCatalog, mCatalogError);
		if (!mCatalogError.IsEmpty)
			Log.Error(mCatalogError);
		Log.Info(scope $"Catalog: {mCatalog.Count} package{(mCatalog.Count == 1) ? "" : "s"}");
		if (mCatalog.IsEmpty)
			return;
		mImportWhenDownloaded = HasArg("--import-package-now");
		StartPackageDownload(mCatalog[0]);
	}

	/// A file dropped on the editor that is a package: opened in Import Package rather than copied in.
	bool ImportDroppedPackage(StringView file)
	{
		if (!file.EndsWith(AssetPackages.Extension, .OrdinalIgnoreCase))
			return false;
		OpenImportPackage(file);
		return true;
	}

	void DrawPackageWindows()
	{
		DrawExportPackage();
		DrawImportPackage();
		DrawPackageManager();
	}
}

/// Package catalogs: text files on the web listing packages to download (docs/packages.md):
///
///   tallowcatalog 1
///   package "Forest Props" version "1.2.0" url "https://example.com/Forest_Props-1.2.0.tpackage" sha256 "..." author "..." description "..."
static class PackageCatalog
{
	public class Entry
	{
		public String name = new .() ~ delete _;
		public String version = new .() ~ delete _;
		public String url = new .() ~ delete _;
		public String sha256 = new .() ~ delete _;
		public String author = new .() ~ delete _;
		public String description = new .() ~ delete _;

		public Entry Clone()
		{
			let copy = new Entry();
			copy.name.Set(name);
			copy.version.Set(version);
			copy.url.Set(url);
			copy.sha256.Set(sha256);
			copy.author.Set(author);
			copy.description.Set(description);
			return copy;
		}
	}

	static void SourcesPath(String outPath)
	{
		AssetPackages.PackagesFolder(outPath);
		outPath.Append("/sources.txt");
	}

	public static void LoadSources(String outText)
	{
		File.ReadAllText(SourcesPath(.. scope .()), outText).IgnoreError();
	}

	public static void SaveSources(StringView text)
	{
		let path = SourcesPath(.. scope .());
		let folder = scope String();
		Path.GetDirectoryPath(path, folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		File.WriteAllText(path, text).IgnoreError();
	}

	/// Reads a catalog's text. The newest version of each package is kept when several are listed.
	public static void Parse(StringView text, List<Entry> outEntries)
	{
		let tokens = scope List<StringView>();
		let storage = scope List<String>();
		defer { ClearAndDeleteItems!(storage); }
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2 || tokens[0] != "package")
				continue;
			let entry = new Entry();
			entry.name.Set(tokens[1]);
			for (int i = 2; i + 1 < tokens.Count; i += 2)
			{
				switch (tokens[i])
				{
				case "version": entry.version.Set(tokens[i + 1]);
				case "url": entry.url.Set(tokens[i + 1]);
				case "sha256": entry.sha256.Set(tokens[i + 1]);
				case "author": entry.author.Set(tokens[i + 1]);
				case "description": entry.description.Set(tokens[i + 1]);
				}
			}
			// Web and file addresses, or one relative to the catalog; nothing else.
			if (entry.url.IsEmpty || (entry.url.Contains("://") && !(entry.url.StartsWith("https://") || entry.url.StartsWith("http://") || entry.url.StartsWith("file://"))))
			{
				delete entry;
				continue;
			}
			bool replaced = false;
			for (int k < outEntries.Count)
			{
				if (outEntries[k].name != entry.name)
					continue;
				replaced = true;
				if (CompareVersions(entry.version, outEntries[k].version) > 0)
				{
					delete outEntries[k];
					outEntries[k] = entry;
				}
				else
					delete entry;
				break;
			}
			if (!replaced)
				outEntries.Add(entry);
		}
	}

	/// "1.10.0" after "1.9.2": numbers compared as numbers, part by part.
	public static int CompareVersions(StringView a, StringView b)
	{
		var partsA = a.Split('.');
		var partsB = b.Split('.');
		while (true)
		{
			let hasA = partsA.GetNext() case .Ok(let pa);
			let hasB = partsB.GetNext() case .Ok(let pb);
			if (!hasA && !hasB)
				return 0;
			let na = hasA ? ((int.Parse(pa) case .Ok(let x)) ? x : 0) : 0;
			let nb = hasB ? ((int.Parse(pb) case .Ok(let y)) ? y : 0) : 0;
			if (na != nb)
				return na <=> nb;
			if (hasA && hasB && na == 0 && pa != pb)
				return StringView.Compare(pa, pb, false);
		}
	}

	/// Fetches every catalog named in sources (one address per line; "#" starts a comment). A local file path or
	/// file:// address works too, for a catalog on a shared drive.
	public static void Fetch(StringView sources, List<Entry> outEntries, String error)
	{
		for (var line in sources.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			let text = scope String();
			let problem = scope String();
			bool ok;
			if (line.StartsWith("http://") || line.StartsWith("https://"))
				ok = Http.GetText(line, text, problem);
			else
			{
				let path = line.StartsWith("file://") ? line.Substring(7) : line;
				ok = File.ReadAllText(path, text) case .Ok;
				if (!ok)
					problem.Set("no such file");
			}
			if (!ok)
			{
				error.AppendF("{}{}: {}", error.IsEmpty ? "" : "\n", line, problem);
				continue;
			}
			if (!text.StartsWith("tallowcatalog"))
			{
				error.AppendF("{}{}: not a package catalog", error.IsEmpty ? "" : "\n", line);
				continue;
			}
			// Relative package addresses are relative to the catalog.
			let before = outEntries.Count;
			Parse(text, outEntries);
			for (int i = before; i < outEntries.Count; i++)
				ResolveUrl(line, outEntries[i].url);
		}
	}

	static void ResolveUrl(StringView catalog, String url)
	{
		if (url.Contains("://"))
			return;
		let slash = catalog.LastIndexOf('/');
		if (slash >= 0)
			url.Insert(0, catalog.Substring(0, slash + 1));
	}
}
