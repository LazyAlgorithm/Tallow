using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --packages-test: asset packages (docs/packages.md) from export to removal, in folders of their own that are
/// removed afterwards. Logs "PACKAGES-TEST PASS" or "FAIL" with what failed. Uses the project's Spinner script when
/// it has one (the Sandbox does) to check that scripts of components are exported.
extension EditorApp
{
	void RunPackagesTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			if (!condition)
				report.AppendF("{}FAILED {}", report.IsEmpty ? "" : "; ", what);
			pass &= condition;
		}
		let root = Assets.ProjectPath;
		let t = "_PkgTest";
		let into = "_PkgImported";
		let folder = scope $"{root}/{t}";
		Directory.DelTree(folder).IgnoreError();
		Directory.DelTree(scope $"{root}/{into}").IgnoreError();
		StringView[?] subfolders = .("Models", "Textures", "Materials", "Prefabs", "Unused");
		for (let sub in subfolders)
			Directory.CreateDirectory(scope $"{folder}/{sub}").IgnoreError();
		uint8[16] bytes = .(0x67, 0x6C, 0x54, 0x46, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
		File.WriteAll(scope $"{folder}/Models/box.glb", .(&bytes, 16)).IgnoreError();
		File.WriteAllText(scope $"{folder}/Models/box.glb.bonemap", "Hips Hips\n").IgnoreError();
		bytes[0] = 0x89;
		File.WriteAll(scope $"{folder}/Textures/t.png", .(&bytes, 16)).IgnoreError();
		File.WriteAll(scope $"{folder}/Unused/u.png", .(&bytes, 16)).IgnoreError();
		File.WriteAllText(scope $"{folder}/Materials/m.tmat", scope $"material 1\ntexture \"{t}/Textures/t.png\"\n").IgnoreError();
		let hasSpinner = File.Exists(scope $"{root}/Scripts/Spinner.bf");
		File.WriteAllText(scope $"{folder}/Prefabs/p.tprefab", scope $"object 1 parent 0 active 1 name \"P\"\ncomponent Tallow.MeshRenderer enabled 1\nfield mesh \"{t}/Models/box.glb\"\nfield material \"{t}/Materials/m.tmat\"\n{hasSpinner ? "component Sandbox.Spinner enabled 1\n" : ""}").IgnoreError();
		RefreshAssetIds();
		let boxId = scope String();
		let texId = scope String();
		AssetDatabase.GetId(scope $"{t}/Models/box.glb", boxId);
		AssetDatabase.GetId(scope $"{t}/Textures/t.png", texId);

		// 1. What an export of the prefab holds.
		let items = scope List<AssetPackages.ExportItem>();
		defer { ClearAndDeleteItems!(items); }
		let picked = scope List<StringView>();
		picked.Add(scope $"{t}/Prefabs/p.tprefab");
		AssetPackages.CollectExport(picked, true, items);
		bool Has(StringView path)
		{
			for (let item in items)
			{
				if (item.path == path)
					return true;
			}
			return false;
		}
		Expect(Has(scope $"{t}/Prefabs/p.tprefab") && Has(scope $"{t}/Models/box.glb") && Has(scope $"{t}/Materials/m.tmat"), "prefab, model and material collected");
		Expect(Has(scope $"{t}/Textures/t.png"), "the material's texture collected (two levels)");
		Expect(!Has(scope $"{t}/Unused/u.png"), "an unrelated file is left out");
		Expect(!hasSpinner || Has("Scripts/Spinner.bf"), "the component's script collected");
		Expect(!Has(scope $"{t}/Models/box.glb.tmeta") && !Has(scope $"{t}/Models/box.glb.bonemap"), "side files are not listed on their own");

		// 2. Written and read back.
		let packageFile = scope String();
		AssetPackages.PackagesFolder(packageFile);
		packageFile.Append("/Exports/_PkgTest-1.0.0.tpackage");
		let manifest = scope AssetPackages.Manifest();
		manifest.name.Set("Package Test");
		manifest.version.Set("1.0.0");
		manifest.description.Set("Made by --packages-test");
		let paths = scope List<StringView>();
		for (let item in items)
			paths.Add(item.path);
		let error = scope String();
		Expect(AssetPackages.Export(packageFile, manifest, paths, error) case .Ok, "export");
		let pack = scope PackFile();
		let read = scope AssetPackages.Manifest();
		Expect(AssetPackages.Open(packageFile, pack, read, error) case .Ok, "open");
		Expect(read.name == "Package Test" && read.version == "1.0.0", "manifest name and version");
		let boxEntry = read.Find(scope $"{t}/Models/box.glb");
		Expect(boxEntry != null && boxEntry.id == boxId && boxEntry.size == 16, "the model's ID and size in the manifest");
		Expect(read.Find(scope $"{t}/Models/box.glb.tmeta") != null && read.Find(scope $"{t}/Models/box.glb.bonemap") != null, "side files packed");

		// 3. Into a project that does not have it: the originals go (as if this were another project), and the
		// package goes into a folder of its own.
		Directory.DelTree(folder).IgnoreError();
		RefreshAssetIds();
		let plan = scope List<AssetPackages.ImportItem>();
		defer { ClearAndDeleteItems!(plan); }
		AssetPackages.PlanImport(pack, read, into, plan);
		int newCount = 0;
		for (let item in plan)
		{
			if (item.state == .New)
				newCount++;
			if (item.isScript)
				Expect(item.state == .Same || item.state == .Conflict, "a script the project has already is not taken by default");
		}
		Expect(newCount == 4, scope $"four new assets (got {newCount})");
		bool scriptsAdded;
		let written = AssetPackages.ApplyImport(pack, read, plan, packageFile, out scriptsAdded, error);
		Expect(written == 4 && error.IsEmpty, scope $"four files written (got {written}) {error}");
		Expect(!scriptsAdded, "no scripts written");
		let text = scope String();
		File.ReadAllText(scope $"{root}/{into}/{t}/Prefabs/p.tprefab", text).IgnoreError();
		Expect(text.Contains(scope $"\"{into}/{t}/Models/box.glb\"") && text.Contains(scope $"\"{into}/{t}/Materials/m.tmat\""), "the prefab names where the package's files went");
		File.ReadAllText(scope $"{root}/{into}/{t}/Materials/m.tmat", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"\"{into}/{t}/Textures/t.png\""), "the material too");
		let id = scope String();
		Expect(AssetDatabase.GetId(scope $"{into}/{t}/Models/box.glb", id) && id == boxId, "the model keeps its ID in the new project");
		Expect(File.Exists(scope $"{root}/{into}/{t}/Models/box.glb.bonemap"), "side file imported");
		let installed = scope List<AssetPackages.Installed>();
		defer { ClearAndDeleteItems!(installed); }
		AssetPackages.LoadInstalled(installed);
		AssetPackages.Installed record = null;
		for (let package in installed)
		{
			if (package.name == "Package Test")
				record = package;
		}
		Expect(record != null && record.version == "1.0.0" && record.files.Count >= 4, "recorded as imported");

		ClearAndDeleteItems!(plan);
		AssetPackages.PlanImport(pack, read, into, plan);
		bool allSame = true;
		for (let item in plan)
			allSame &= item.state == .Same || item.isScript;
		Expect(allSame, "just imported into a folder, every file shows as Same (references rewritten count as the same)");

		// 4. Moved since, then imported again: found by ID where it is now; a changed file shows as Changed.
		Directory.CreateDirectory(scope $"{root}/{into}/Elsewhere").IgnoreError();
		Expect(MoveAssetTracked(scope $"{root}/{into}/{t}/Textures/t.png", scope $"{root}/{into}/Elsewhere/t.png"), "move the imported texture");
		File.WriteAllText(scope $"{root}/{into}/{t}/Materials/m.tmat", "material 1\ncolor 1 0 0 1\n").IgnoreError();
		ClearAndDeleteItems!(plan);
		AssetPackages.PlanImport(pack, read, into, plan);
		for (let item in plan)
		{
			if (item.entry.id == texId)
				Expect(item.target == scope $"{into}/Elsewhere/t.png" && item.state == .Same, "the moved texture is found where it is now");
			if (item.entry.path.EndsWith("m.tmat"))
				Expect(item.state == .Changed && item.include, "a changed material shows as Changed");
			if (item.entry.path.EndsWith("box.glb"))
				Expect(item.state == .Same && !item.include, "an unchanged model shows as Same");
		}
		AssetPackages.ApplyImport(pack, read, plan, packageFile, out scriptsAdded, error..Clear());
		File.ReadAllText(scope $"{root}/{into}/{t}/Materials/m.tmat", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"\"{into}/Elsewhere/t.png\""), "the updated material names the texture where it was moved");

		// 5. Removed: changed files stay.
		File.WriteAllText(scope $"{root}/{into}/{t}/Prefabs/p.tprefab", "object 1 parent 0 active 1 name \"Edited\"\n").IgnoreError();
		let kept = scope List<String>();
		defer { ClearAndDeleteItems!(kept); }
		let removed = AssetPackages.Remove("Package Test", kept);
		Expect(removed >= 3, scope $"package files removed (got {removed})");
		Expect(kept.Count == 1 && kept[0].EndsWith("p.tprefab"), "the edited prefab is kept");
		Expect(!File.Exists(scope $"{root}/{into}/Elsewhere/t.png") && !File.Exists(scope $"{root}/{into}/Elsewhere/t.png.tmeta"), "removed with its .tmeta");
		Expect(!Directory.Exists(scope $"{root}/{into}/Elsewhere"), "an emptied folder goes");
		ClearAndDeleteItems!(installed);
		AssetPackages.LoadInstalled(installed);
		bool stillThere = false;
		for (let package in installed)
			stillThere |= package.name == "Package Test";
		Expect(!stillThere, "the record goes");

		// 6. Catalogs.
		let entries = scope List<PackageCatalog.Entry>();
		defer { ClearAndDeleteItems!(entries); }
		PackageCatalog.Parse("tallowcatalog 1\npackage \"A\" version \"1.9.2\" url \"a-1.9.2.tpackage\"\npackage \"A\" version \"1.10.0\" url \"https://x.test/a.tpackage\" sha256 \"ab\"\npackage \"B\" version \"1\" url \"ftp://x\"\n", entries);
		Expect(entries.Count == 1 && entries[0].version == "1.10.0" && entries[0].sha256 == "ab", "catalog keeps the newest version and refuses other schemes");

		File.Delete(packageFile).IgnoreError();
		Directory.DelTree(scope $"{root}/{into}").IgnoreError();
		RefreshAssetIds();
		Log.Info(scope $"PACKAGES-TEST {pass ? "PASS" : "FAIL"}{report.IsEmpty ? "" : ": "}{report}");
	}
}
