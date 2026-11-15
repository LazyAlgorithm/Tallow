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
		OpenScript(external);
		ScriptDocument document = null;
		for (let open in mScripts)
			if (open.path.EndsWith("External.cs"))
				document = open;
		Check(document != null, "the script opens");
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
