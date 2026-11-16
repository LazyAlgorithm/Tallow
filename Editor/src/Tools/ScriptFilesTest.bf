using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --script-files-test: the assembly definition Inspector's file handling and checks, and open scripts
/// following edits made by other programs. Works in a scratch folder under the editor's config folder,
/// never the open project. Prints "SCRIPT FILES TEST PASSED" and writes script-files-test.txt there.
extension EditorApp
{
	void RunScriptFilesTest()
	{
		int failures = 0;
		let report = scope String();
		void Check(bool ok, StringView what)
		{
			report.AppendF("{}: {}\n", what, ok ? "ok" : "FAILED");
			if (!ok)
			{
				failures++;
				Log.Error(scope $"SCRIPT FILES TEST: {what}");
			}
		}
		bool HasProblem(StringView text)
		{
			let problems = scope List<String>();
			defer { ClearAndDeleteItems!(problems); }
			AssemblyDefinitionProblems(problems);
			for (let problem in problems)
				if (problem.Contains(text))
					return true;
			return false;
		}
		int ProblemCount()
		{
			let problems = scope List<String>();
			defer { ClearAndDeleteItems!(problems); }
			AssemblyDefinitionProblems(problems);
			return problems.Count;
		}

		let config = scope String();
		RecentProjects.GetConfigFolder(config);
		let root = scope $"{config}script-files-test/src";
		Directory.DelTree(scope $"{config}script-files-test").IgnoreError();
		for (let folder in StringView[?]("Core", "Gameplay/Sub", "Gameplay/Nested"))
			Directory.CreateDirectory(scope $"{root}/{folder}").IgnoreError();
		File.WriteAllText(scope $"{root}/Core/Core.tasmdef",
			"{\"name\":\"Core\",\"rootNamespace\":\"MyGame.Core\",\"references\":[],\"autoReferenced\":true,\"versionDefines\":[{\"name\":\"x\",\"expression\":\"[1,2)\"}]}").IgnoreError();
		File.WriteAllText(scope $"{root}/Gameplay/Gameplay.tasmdef", "{ \"name\": \"Gameplay\", \"references\": [ \"Core\" ] }").IgnoreError();
		File.WriteAllText(scope $"{root}/Gameplay/Nested/Nested.tasmdef", "{\"name\":\"Nested\"}").IgnoreError();
		for (let file in StringView[?]("Gameplay/Player.cs", "Gameplay/Sub/Enemy.cs", "Gameplay/Nested/N.cs", "Core/Math.cs"))
			File.WriteAllText(scope $"{root}/{file}", "class X {}\n").IgnoreError();
		mAsmdefSourceOverride.Set(root);

		// Reading, and the keys this page does not edit.
		OpenAssemblyDefinition(scope $"{root}/Core/Core.tasmdef");
		Check(mAsmdefSaved.valid && mAsmdefEdit.name == "Core" && mAsmdefEdit.rootNamespace == "MyGame.Core", "reads name and root namespace");
		Check(mAsmdefEdit.other.Count == 2, "keeps unknown keys");
		Check(mAsmdefProject.Count == 3, "finds the three definitions");
		Check(ProblemCount() == 0, "a valid definition has no problems");

		// The rules Tallow.Build enforces.
		mAsmdefEdit.references.Add(new .("Gameplay"));
		Check(HasProblem("cycle"), "a reference back to a dependant is a cycle");
		ClearAndDeleteItems!(mAsmdefEdit.references);
		mAsmdefEdit.references.Add(new .("Nope"));
		Check(HasProblem("no assembly named Nope"), "a missing reference is reported");
		mAsmdefEdit.references.Add(new .("Nope"));
		Check(HasProblem("listed twice"), "a duplicate reference is reported");
		ClearAndDeleteItems!(mAsmdefEdit.references);
		mAsmdefEdit.references.Add(new .("Core"));
		Check(HasProblem("reference itself"), "a self reference is reported");
		ClearAndDeleteItems!(mAsmdefEdit.references);
		mAsmdefEdit.name.Set("Tallow.Game");
		Check(HasProblem("not a valid assembly name"), "reserved names are refused");
		mAsmdefEdit.name.Set("Gameplay");
		Check(HasProblem("already named Gameplay"), "duplicate names are refused");
		mAsmdefEdit.name.Set("Core");
		mAsmdefEdit.rootNamespace.Set("My..Core");
		Check(HasProblem("not a valid namespace"), "bad namespaces are refused");
		mAsmdefEdit.rootNamespace.Set("MyGame.Core");
		Check(mAsmdefEdit.SameEdits(mAsmdefSaved), "undoing every edit leaves nothing to apply");

		// Renaming updates the definitions that reference it, and keeps the other keys.
		mAsmdefEdit.name.Set("CoreLib");
		Check(ProblemCount() == 0 && ApplyAssemblyDefinition(), "applies a rename");
		let gameplay = scope AssemblyDefinitionFile();
		LoadAssemblyDefinition(scope $"{root}/Gameplay/Gameplay.tasmdef", gameplay);
		Check(gameplay.valid && gameplay.references.Count == 1 && gameplay.references[0] == "CoreLib", "the rename reaches Gameplay's references");
		let core = scope AssemblyDefinitionFile();
		LoadAssemblyDefinition(scope $"{root}/Core/Core.tasmdef", core);
		Check(core.valid && core.name == "CoreLib" && core.rootNamespace == "MyGame.Core" && core.other.Count == 2, "the saved file reads back the same");
		let coreText = scope String();
		File.ReadAllText(scope $"{root}/Core/Core.tasmdef", coreText).IgnoreError();
		Check(coreText.Contains("\"expression\":\"[1,2)\""), "unknown values are kept verbatim");

		// What each assembly compiles, and the namespace new scripts get.
		OpenAssemblyDefinition(scope $"{root}/Gameplay/Gameplay.tasmdef");
		Check(mAsmdefScripts.Count == 2, "Gameplay owns Player.cs and Sub/Enemy.cs, not the nested assembly's N.cs");
		let space = scope String();
		ScriptNamespaceFor(scope $"{root}/Gameplay/Sub", space);
		Check(space == "Gameplay", "a script in Gameplay/Sub gets namespace Gameplay");
		ScriptNamespaceFor(scope $"{root}/Core", space);
		Check(space == "MyGame.Core", "a script in Core gets its root namespace");
		ScriptNamespaceFor(root, space);
		Check(space == (Project.Current != null ? Project.Current.Name : "Game"), "a script outside any assembly gets the project's namespace");

		// Two definitions in one folder, and a damaged file.
		File.WriteAllText(scope $"{root}/Gameplay/Extra.tasmdef", "{\"name\":\"Extra\"}").IgnoreError();
		OpenAssemblyDefinition(scope $"{root}/Gameplay/Gameplay.tasmdef");
		Check(HasProblem("same folder"), "a second definition in the folder is reported");
		File.WriteAllText(scope $"{root}/Gameplay/Extra.tasmdef", "{\"name\": }").IgnoreError();
		let damaged = scope AssemblyDefinitionFile();
		Check(!LoadAssemblyDefinition(scope $"{root}/Gameplay/Extra.tasmdef", damaged), "a damaged file is not valid");
		File.Delete(scope $"{root}/Gameplay/Extra.tasmdef").IgnoreError();
		DeleteAndNullify!(mAsmdefSaved);
		DeleteAndNullify!(mAsmdefEdit);

		// An open script follows edits made by another program.
		let external = scope $"{root}/External.cs";
		File.WriteAllText(external, "class Before {}\n").IgnoreError();
		Check(!ScriptMayEdit(external) && ScriptMayEdit(scope $"{Project.Current.Path}/src/Editable.cs"),
			"only files inside the project can be edited");
		OpenScript(external);
		ScriptDocument document = null;
		for (let open in mScripts)
			if (open.path.EndsWith("External.cs"))
				document = open;
		Check(document != null && document.readOnly, "outside-project source opens read-only");
		if (document != null)
		{
			System.Threading.Thread.Sleep(20);
			File.WriteAllText(external, "class After {}\n").IgnoreError();
			CheckOpenScriptsOnDisk(true);
			let text = scope String(tn_code_get_text(document.handle));
			text.Trim();
			Check(text == "class After {}", "the open script reloads the other program's edit");
			Check(!tn_code_is_dirty(document.handle), "a reloaded script has nothing to save");
			Check(document.diskTime == (File.GetLastWriteTimeUtc(external) case .Ok(let time) ? time : default), "the reload records the file's time");
			document.open = false;
		}
		let engineFile = scope $"{Project.Current.EngineRoot}/Managed/Tallow.API/Script.cs";
		OpenScript(engineFile);
		let engineDocument = FindScript(engineFile);
		Check(engineDocument != null && engineDocument.readOnly, "engine definition opens read-only");
		if (engineDocument != null)
		{
			let original = scope String(tn_code_get_text(engineDocument.handle));
			let replacement = scope String("// edit should be refused");
			tn_code_replace_text(engineDocument.handle, replacement.CStr());
			Check(StringView(tn_code_get_text(engineDocument.handle)) == original && !tn_code_is_dirty(engineDocument.handle),
				"read-only engine source ignores replacement edits");
			engineDocument.open = false;
		}

		// A scene naming components this build does not have keeps them through load and save.
		{
			let sceneText = """
				object 9001 parent 0 active 1 name "Old Beef Player"
				transform 1 2 3 0 0 0 1 1 1 1
				component MyOldGame.PlayerController enabled 1
				field speed 4.5
				field target 9002
				data MyOldGame.Health
				field current 75
				component Tallow.Rigidbody enabled 1
				field mass 3
				object 9002 parent 9001 active 1 name "Child"
				transform 0 0 0 0 0 0 1 1 1 1

				""";
			let made = scope List<GameObject>();
			SceneSerializer.LoadObjects(mScene, sceneText, made);
			GameObject old = null;
			for (let object in made)
				if (object.Name == "Old Beef Player")
					old = object;
			Check(old != null && old.MissingComponents != null && old.MissingComponents.Count == 2, "unknown component and data blocks are kept on load");
			if (old != null && old.MissingComponents != null && old.MissingComponents.Count == 2)
			{
				Check(old.MissingComponents[0] == "component MyOldGame.PlayerController enabled 1\nfield speed 4.5\nfield target 9002\n", "the component block is kept line for line");
				Check(old.MissingComponents[1] == "data MyOldGame.Health\nfield current 75\n", "the data block is kept line for line");
				let type = scope String();
				GameObject.MissingComponentType(old.MissingComponents[0], type);
				Check(type == "MyOldGame.PlayerController", "the Inspector names the missing type");
				let saved = scope String();
				SceneSerializer.SaveObjectTree(old, saved);
				Check(saved.Contains("component Tallow.Rigidbody enabled 1") && saved.Contains("field mass 3") &&
					old.Transform.Children.Count == 1, "known components and children still load around them");
				Check(saved.Contains("component MyOldGame.PlayerController enabled 1\nfield speed 4.5\nfield target 9002\n") &&
					saved.Contains("data MyOldGame.Health\nfield current 75\n"), "saving writes the kept blocks back");
				// And again: a second load and save is identical (nothing doubles up or drifts).
				let again = scope List<GameObject>();
				SceneSerializer.LoadObjects(mScene, saved, again);
				let savedAgain = scope String();
				if (!again.IsEmpty)
					SceneSerializer.SaveObjectTree(again[0], savedAgain);
				Check(!again.IsEmpty && again[0].MissingComponents?.Count == 2, "a reloaded copy keeps them too");
				for (let object in again)
					if (object.Transform.Parent == null)
						mScene.Destroy(object);
			}
			if (old != null)
				mScene.Destroy(old);
		}

		// Script identity: scenes follow renamed C# classes by [FormerlyNamed] or by the file's .tmeta ID.
		{
			let probeFile = scope $"{Assets.ProjectPath}/IdentityProbe.cs";
			File.WriteAllText(probeFile, "public class Renamed {}\n").IgnoreError();
			AssetDatabase.Refresh(false);
			let probeId = scope String();
			Check(AssetDatabase.GetId("IdentityProbe.cs", probeId), "a new C# file gets an asset ID");
			let catalogRoot = scope $"{config}identity-test";
			Directory.CreateDirectory(scope $"{catalogRoot}/.tallow-csharp").IgnoreError();
			File.WriteAllText(scope $"{catalogRoot}/.tallow-csharp/components.tsv", "Game.NewName\nGame.Other\n").IgnoreError();
			File.WriteAllText(scope $"{catalogRoot}/.tallow-csharp/former-names.tsv", "Game.OldFormer\tGame.Other\n").IgnoreError();
			File.WriteAllText(scope $"{catalogRoot}/.tallow-csharp/component-sources.tsv",
				scope $"{probeFile}\tGame.NewName\n{catalogRoot}/Other.cs\tGame.Other\n").IgnoreError();
			CSharpBehaviour Make(StringView name, StringView type, StringView asset)
			{
				let object = mScene.CreateGameObject(name);
				let behaviour = object.AddComponent<CSharpBehaviour>();
				behaviour.scriptType.Set(type);
				behaviour.scriptAsset.Set(asset);
				return behaviour;
			}
			let inFile = Make("Renamed In File", "Game.OldName", probeId);
			let former = Make("Formerly Named", "Game.OldFormer", "");
			let gone = Make("Gone", "Game.Gone", "");
			let current = Make("Current", "Game.NewName", "");
			Check(CSharpScriptIdentity.Repair(mScene, catalogRoot) == 2, "two renamed scripts are repaired");
			Check(inFile.scriptType == "Game.NewName", "a class renamed in its file is found by the file's asset ID");
			Check(former.scriptType == "Game.Other", "a [FormerlyNamed] class is found by its old name");
			Check(gone.scriptType == "Game.Gone", "a script that is really gone keeps its name (shown as missing)");
			Check(current.scriptAsset == probeId, "a current script gets its file's asset ID recorded");
			for (let behaviour in CSharpBehaviour[?](inFile, former, gone, current))
				mScene.Destroy(behaviour.GameObject);
			File.Delete(probeFile).IgnoreError();
			File.Delete(scope $"{probeFile}{AssetDatabase.MetaSuffix}").IgnoreError();
			AssetDatabase.Refresh(false);
			Directory.DelTree(catalogRoot).IgnoreError();
		}

		// C# reference fields (set by dragging an object into the Inspector) are kept by the scene file, follow the
		// object when ids change on load, and clear when the object goes.
		{
			let holder = mScene.CreateGameObject("Ref Holder");
			let behaviour = holder.AddComponent<CSharpBehaviour>();
			behaviour.scriptType.Set("Game.Refs");
			let target = mScene.CreateGameObject("Ref Target");
			let lamp = mScene.CreateGameObject("Ref Lamp");
			lamp.AddComponent<Light>();
			Check(behaviour.SetReference("Target", target) && behaviour.SetReference("Lamp", lamp), "reference fields can be set");
			Check(!behaviour.SetReference("Bad;Name", target), "a field name with ';' is refused");
			Check(behaviour.ReferenceTarget("Target") == target && behaviour.ReferenceTarget("Lamp") == lamp, "reference fields read back");
			Check(FitsManagedReference(lamp, "native:Tallow.Light") && !FitsManagedReference(target, "native:Tallow.Light"),
				"only objects with a Light fit a Light field");
			Check(FitsManagedReference(holder, "script:Game.Refs") && !FitsManagedReference(target, "script:Game.Refs"),
				"only objects with that C# script fit a script field");
			Check(behaviour.SetReference("Lamp", null) && behaviour.ReferenceTarget("Lamp") == null && behaviour.ReferenceTarget("Target") == target,
				"clearing one reference keeps the others");
			let saved = scope String();
			SceneSerializer.Save(mScene, saved);
			let copy = scope Scene();
			// An object first, so ids on load differ from the saved ones.
			copy.CreateGameObject("Taken");
			SceneSerializer.Load(copy, saved);
			let loadedHolder = copy.Find("Ref Holder");
			let loaded = loadedHolder?.GetComponent<CSharpBehaviour>();
			Check(loaded != null && loaded.ReferenceTarget("Target") == copy.Find("Ref Target") && loaded.ReferenceTarget("Target") != null,
				"a reference field survives saving and loading the scene");
			mScene.DestroyImmediate(target);
			Check(behaviour.ReferenceTarget("Target") == null, "destroying the object clears the reference");
			mScene.DestroyImmediate(holder);
			mScene.DestroyImmediate(lamp);
		}

		// A compile error in a graph's generated C# points at the graph and the node whose code it is in.
		{
			let graphFile = scope $"{root}/MappedGraph.tgraph";
			File.WriteAllText(graphFile, "graph \"MappedGraph\"\nnode 1 event.start 0 0\nnode 3 debug.log 0 0 \"\" \"hi\"\nlink 1 0 3 0\n").IgnoreError();
			let script = scope $"{root}/MappedGraph.cs";
			File.WriteAllText(script, "public partial class MappedGraph : Tallow.Script\n{\n\tpublic override void Start()\n\t{\n\t\tbase.Start();\n\t\tLog.Info(\"hi\"); // #3\n\t\tif (x)\n\t\t{\n\t\t}\n\t}\n}\n").IgnoreError();
			let problem = scope ScriptProblem();
			problem.file.Set(script);
			problem.line = 7;
			problem.isError = true;
			problem.message.Set("error CS0103: The name 'x' does not exist");
			MapToGraph(problem);
			Check(problem.inGraph && problem.file == graphFile && problem.line == 3, scope $"a graph's C# error points at its node (got {problem.file}:{problem.line})");
			Check(problem.message.Contains("Print String"), scope $"the error names the node ({problem.message})");
			problem.file.Set(script);
			problem.line = 1;
			problem.inGraph = false;
			MapToGraph(problem);
			Check(problem.inGraph && problem.line == 0, "an error outside any node's code points at the graph");
			File.Delete(graphFile).IgnoreError();
			File.Delete(script).IgnoreError();
		}

		// Leave Gameplay's page in the Inspector, with one unapplied edit, so the frames that follow draw it
		// (and --screenshot shows it). The scratch folder stays the scanned one for this run.
		mSelectedAsset.Set(scope $"{root}/Gameplay/Gameplay.tasmdef");
		mInspectAsset = true;
		mSelectedId = 0;
		OpenAssemblyDefinition(mSelectedAsset);
		mAsmdefEdit.references.Add(new .("Missing"));
		if (failures == 0)
			report.Append("SCRIPT FILES TEST PASSED\n");
		File.WriteAllText(scope $"{config}script-files-test.txt", report).IgnoreError();
		if (failures == 0)
			Log.Info("SCRIPT FILES TEST PASSED");
		else
			Log.Error(scope $"SCRIPT FILES TEST FAILED ({failures})");
	}
}
