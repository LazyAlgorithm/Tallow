using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --asset-ids-test: stable asset IDs (docs/asset-ids.md) from start to end, in a folder of its own that is removed
/// afterwards. Logs "ASSET-IDS-TEST PASS" or "FAIL" with what was checked.
extension EditorApp
{
	const String AssetIdTestFolder = "_AssetIdTest";

	void RunAssetIdsTest()
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
		let folder = scope $"{root}/{AssetIdTestFolder}";
		Directory.DelTree(folder).IgnoreError();
		Directory.CreateDirectory(scope $"{folder}/a").IgnoreError();
		let t = AssetIdTestFolder;
		uint8[16] bytes = .(0x67, 0x6C, 0x54, 0x46, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
		File.WriteAll(scope $"{folder}/a/crate.glb", .(&bytes, 16)).IgnoreError();
		File.WriteAllText(scope $"{folder}/a/crate.glb.import", "scale 1\n").IgnoreError();
		bytes[0] = 0x89;
		File.WriteAll(scope $"{folder}/a/tex.png", .(&bytes, 16)).IgnoreError();
		File.WriteAllText(scope $"{folder}/wood.tmat", scope $"material 1\ntexture \"{t}/a/tex.png\"\n").IgnoreError();
		File.WriteAllText(scope $"{folder}/thing.tprefab", scope $"object 1 parent 0 active 1 name \"Thing\"\ncomponent Tallow.MeshRenderer enabled 1\nfield mesh \"{t}/a/crate.glb#Root\"\nfield material \"{t}/wood.tmat\"\n").IgnoreError();
		File.WriteAllText(scope $"{folder}/notes.txt", scope $"Load(\"{t}/a/crate.glb\"); Load(\"{t}/a/crate.glbx\"); folder \"{t}/a\"\n").IgnoreError();

		// 1. New files get IDs.
		RefreshAssetIds();
		let crateId = scope String();
		let texId = scope String();
		Expect(AssetDatabase.GetId(scope $"{t}/a/crate.glb", crateId) && AssetDatabase.IsId(crateId), "crate has an ID");
		Expect(AssetDatabase.GetId(scope $"{t}/a/tex.png", texId), "texture has an ID");
		Expect(File.Exists(scope $"{folder}/a/crate.glb.tmeta"), "crate.glb.tmeta written");
		Expect(!AssetDatabase.HasPath(scope $"{t}/a/crate.glb.import"), "the .import is not an asset of its own");
		Expect(crateId != texId, "IDs differ");
		let again = scope String();
		RefreshAssetIds();
		AssetDatabase.GetId(scope $"{t}/a/crate.glb", again);
		Expect(again == crateId, "ID stays the same on the next look");

		// 2. The open scene names the crate.
		let probe = mScene.CreateGameObject("AssetIdProbe");
		let renderer = probe.AddComponent<MeshRenderer>();
		renderer.mesh.Set(scope $"{t}/a/crate.glb");

		// 3. Moved and renamed in the editor.
		Directory.CreateDirectory(scope $"{folder}/b").IgnoreError();
		Expect(MoveAssetTracked(scope $"{folder}/a/crate.glb", scope $"{folder}/b/crate2.glb"), "tracked move");
		Expect(File.Exists(scope $"{folder}/b/crate2.glb.tmeta") && File.Exists(scope $"{folder}/b/crate2.glb.import"), "side files moved");
		Expect(!File.Exists(scope $"{folder}/a/crate.glb.tmeta"), "old .tmeta gone");
		let path = scope String();
		Expect(AssetDatabase.GetPath(crateId, path) && path == scope $"{t}/b/crate2.glb", "ID follows the move");
		let text = scope String();
		File.ReadAllText(scope $"{folder}/thing.tprefab", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"\"{t}/b/crate2.glb#Root\""), "prefab reference (with #part) changed");
		File.ReadAllText(scope $"{folder}/notes.txt", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"Load(\"{t}/b/crate2.glb\")"), "script-like text changed");
		Expect(text.Contains(scope $"Load(\"{t}/a/crate.glbx\")"), "a longer name that only starts the same is left alone");
		Expect(renderer.mesh == scope $"{t}/b/crate2.glb", "the open scene's field changed");

		// 4. A folder moved in the editor.
		Expect(MoveAssetTracked(scope $"{folder}/a", scope $"{folder}/c"), "folder move");
		File.ReadAllText(scope $"{folder}/wood.tmat", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"\"{t}/c/tex.png\""), "material's texture follows the folder");
		File.ReadAllText(scope $"{folder}/notes.txt", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"folder \"{t}/c\""), "the folder's own path changed");
		Expect(AssetDatabase.GetPath(texId, path..Clear()) && path == scope $"{t}/c/tex.png", "texture ID follows its folder");

		// 5. Moved outside the editor with its .tmeta (a file manager, git mv).
		Directory.CreateDirectory(scope $"{folder}/d").IgnoreError();
		File.Move(scope $"{folder}/c/tex.png", scope $"{folder}/d/tex.png").IgnoreError();
		File.Move(scope $"{folder}/c/tex.png.tmeta", scope $"{folder}/d/tex.png.tmeta").IgnoreError();
		RefreshAssetIds();
		File.ReadAllText(scope $"{folder}/wood.tmat", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"\"{t}/d/tex.png\""), "outside move with .tmeta found");

		// 6. Moved outside the editor without it: the left-behind .tmeta is matched by name.
		Directory.CreateDirectory(scope $"{folder}/e").IgnoreError();
		File.Move(scope $"{folder}/b/crate2.glb", scope $"{folder}/e/crate2.glb").IgnoreError();
		RefreshAssetIds();
		Expect(AssetDatabase.GetPath(crateId, path..Clear()) && path == scope $"{t}/e/crate2.glb", "outside move without .tmeta keeps the ID");
		Expect(!File.Exists(scope $"{folder}/b/crate2.glb.tmeta") && File.Exists(scope $"{folder}/e/crate2.glb.tmeta"), "the .tmeta moved after it");
		File.ReadAllText(scope $"{folder}/thing.tprefab", text..Clear()).IgnoreError();
		Expect(text.Contains(scope $"\"{t}/e/crate2.glb#Root\""), "prefab follows an outside move");
		Expect(renderer.mesh == scope $"{t}/e/crate2.glb", "the open scene follows an outside move");

		// 7. Copied with its .tmeta: the copy gets an ID of its own.
		let woodId = scope String();
		AssetDatabase.GetId(scope $"{t}/wood.tmat", woodId);
		File.Copy(scope $"{folder}/wood.tmat", scope $"{folder}/wood2.tmat").IgnoreError();
		File.Copy(scope $"{folder}/wood.tmat.tmeta", scope $"{folder}/wood2.tmat.tmeta").IgnoreError();
		RefreshAssetIds();
		let copyId = scope String();
		let originalId = scope String();
		AssetDatabase.GetId(scope $"{t}/wood2.tmat", copyId);
		AssetDatabase.GetId(scope $"{t}/wood.tmat", originalId);
		Expect(originalId == woodId && !copyId.IsEmpty && copyId != woodId, "a copy gets a new ID, the original keeps its own");

		// 8. Unquoted values (project.tallow's startScene).
		let settings = scope String("name = Game\nstartScene = Scenes/Old.tscene\n");
		let moves = scope List<(StringView from, StringView to)>();
		moves.Add(("Scenes/Old.tscene", "Levels/New.tscene"));
		Expect(AssetDatabase.RewriteText(settings, moves, false, true) && settings.Contains("startScene = Levels/New.tscene") && settings.Contains("name = Game"), "project.tallow's start scene");

		// 9. References and deleting.
		let users = scope List<String>();
		AssetDatabase.FindReferences(scope $"{t}/wood.tmat", users);
		Expect(users.Count == 1 && users[0].EndsWith("thing.tprefab"), "Find References");
		ClearAndDeleteItems!(users);
		Expect(AssetDatabase.Delete(scope $"{folder}/wood2.tmat") case .Ok, "delete");
		Expect(!File.Exists(scope $"{folder}/wood2.tmat.tmeta") && !AssetDatabase.GetPath(copyId, path..Clear()), "delete takes the .tmeta and the ID");

		mScene.Destroy(probe);
		Directory.DelTree(folder).IgnoreError();
		RefreshAssetIds();
		Expect(!AssetDatabase.GetPath(crateId, path..Clear()), "IDs of removed files are forgotten");
		Log.Info(scope $"ASSET-IDS-TEST {pass ? "PASS" : "FAIL"} ({AssetDatabase.Count} assets){report.IsEmpty ? "" : ": "}{report}");
	}
}
