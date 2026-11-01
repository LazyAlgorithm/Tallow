using System;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Test switch --theme-test: themes applied to the real interface (docs/themes.md). Picks each built-in theme, checks
/// the colours the code editor is given (each theme's own, or one picked for code alone), changes colours live, starts the themes again as a restart would, saves, exports, imports and deletes a theme, all in a
/// folder of its own (the user's themes are left alone), then logs THEME-TEST PASS or FAIL and puts the user's
/// theme back.
extension EditorApp
{
	void RunThemeTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		bool Near(Color a, Color b) => Math.Abs(a.r - b.r) < 0.002f && Math.Abs(a.g - b.g) < 0.002f && Math.Abs(a.b - b.b) < 0.002f && Math.Abs(a.a - b.a) < 0.002f;
		let folder = scope String();
		RecentProjects.GetConfigFolder(folder);
		folder.Append("theme-test");
		if (Directory.Exists(folder))
			Directory.DelTree(folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		EditorTheme.ConfigOverride.Set(folder);
		EditorTheme.Init();
		Expect(EditorTheme.Current.name == "Tallow Blue" && Near(ImGui.GetStyleColor(ImGui.Col.WindowBg), EditorTheme.Find("Tallow Blue").Get("WindowBg")), "with no theme chosen yet, Tallow Blue is used");

		// Each built-in theme, applied: the interface takes its colours, and it does not count as changed.
		var allApplied = true, noneChanged = true;
		for (let name in StringView[?]("Tallow Blue", "Dark", "Light", "High Contrast", "Forest", "Ember", "Plum"))
		{
			let theme = EditorTheme.Find(name);
			EditorTheme.Select(theme);
			allApplied &= Near(ImGui.GetStyleColor(ImGui.Col.WindowBg), theme.Get("WindowBg")) && Near(ImGui.GetStyleColor(ImGui.Col.Text), theme.Get("Text"));
			noneChanged &= EditorTheme.Find(EditorTheme.Current.name).SameColors(EditorTheme.Current);
		}
		Expect(allApplied, "each built-in theme colours the interface");
		Expect(noneChanged, "a theme just picked is not marked changed");
		Expect(EditorTheme.IsLight == false && EditorTheme.Accent == EditorTheme.Find("Plum").extras[(int)ThemeColor.Accent], "the editor's own colours follow the theme");

		// The code editor: each theme's own code colours, or one theme's whatever the editor uses.
		uint32 Packed(Color c)
		{
			uint32 Byte(float v) => (uint32)Math.Clamp((int)(v * 255 + 0.5f), 0, 255);
			return Byte(c.r) | (Byte(c.g) << 8) | (Byte(c.b) << 16) | (Byte(c.a) << 24);
		}
		bool CodeIs(Theme theme)
		{
			uint32[EditorTheme.CodeCount] given = default;
			if (!EditorTheme.CodeEditorColors(ref given))
				return false;
			for (int i < EditorTheme.CodeCount)
			{
				if (given[i] != Packed(theme.code[i]))
					return false;
			}
			return true;
		}
		Expect(CodeIs(EditorTheme.Find("Plum")) && Near(EditorTheme.CodeBackground, EditorTheme.Find("Plum").code[(int)CodeColor.Background]), "the code editor takes the theme's own code colours");
		EditorTheme.SelectCodeTheme("Ember");
		EditorTheme.Select(EditorTheme.Find("Forest"));
		Expect(CodeIs(EditorTheme.Find("Ember")) && Near(EditorTheme.CodeBackground, EditorTheme.Find("Ember").code[(int)CodeColor.Background]), "a code theme picked on its own stays when the editor's theme changes");
		EditorTheme.Init();
		Expect(EditorTheme.CodeTheme == "Ember" && CodeIs(EditorTheme.Find("Ember")) && EditorTheme.Current.name == "Forest", "and comes back after a restart");
		EditorTheme.SelectCodeTheme("");
		// (The theme in use, read back from its file: its colours rounded to three places.)
		Expect(EditorTheme.Current.name == "Forest" && CodeIs(EditorTheme.Current), "matching the editor theme again");
		EditorTheme.SetCode(.Keyword, .(1, 0.2f, 0.2f, 1));
		uint32[EditorTheme.CodeCount] edited = default;
		Expect(EditorTheme.CodeEditorColors(ref edited) && edited[(int)CodeColor.Keyword] == Packed(.(1, 0.2f, 0.2f, 1)) && !EditorTheme.Find("Forest").SameColors(EditorTheme.Current), "a code colour changed in Preferences shows at once and marks the theme changed");
		EditorTheme.Select(EditorTheme.Find("Plum"));

		// Live changes, kept over a restart.
		EditorTheme.Select(EditorTheme.Find("Light"));
		let pink = Color(0.9f, 0.6f, 0.7f, 1);
		EditorTheme.SetColor(ImGui.Col.WindowBg, pink);
		EditorTheme.SetExtra(.Accent, .(0.1f, 0.6f, 0.3f, 1));
		Expect(Near(ImGui.GetStyleColor(ImGui.Col.WindowBg), pink) && !EditorTheme.Find("Light").SameColors(EditorTheme.Current), "a colour changed in Preferences shows at once and marks the theme changed");
		EditorTheme.SaveActive();
		// As if the editor closed: something else showing, then the themes started again.
		EditorTheme.Current.CopyFrom(EditorTheme.Find("Dark"));
		EditorTheme.Apply();
		EditorTheme.Init();
		Expect(EditorTheme.Current.name == "Light" && Near(ImGui.GetStyleColor(ImGui.Col.WindowBg), pink) && Near(EditorTheme.Accent, .(0.1f, 0.6f, 0.3f, 1)) && EditorTheme.IsLight, "the theme in use, changes and all, comes back after a restart");

		// Saving under a name, exporting, deleting and importing.
		let saved = EditorTheme.SaveAs("Rose Garden");
		Expect(saved != null && File.Exists(scope $"{folder}/themes/Rose Garden.ttheme") && !saved.builtIn && saved.SameColors(EditorTheme.Current), "Save As writes the theme to the themes folder and lists it");
		let exported = scope $"{folder}/shared/Rose.ttheme";
		Expect(EditorTheme.Export(exported) && File.Exists(exported), "Export writes the theme anywhere");
		let mine = EditorTheme.SaveAs("Light");
		Expect(mine != null && mine.name == "Light (mine)" && EditorTheme.Find("Light").builtIn, "saving under a built-in theme's name keeps the built-in one");
		EditorTheme.Delete(EditorTheme.Find("Rose Garden"));
		Expect(EditorTheme.Find("Rose Garden") == null && !File.Exists(scope $"{folder}/themes/Rose Garden.ttheme"), "Delete removes a saved theme");
		EditorTheme.Select(EditorTheme.Find("Dark"));
		let problems = scope String();
		Expect(EditorTheme.Import(exported, problems) && problems.IsEmpty && EditorTheme.Find("Rose Garden") != null && Near(ImGui.GetStyleColor(ImGui.Col.WindowBg), pink), "Import reads a shared theme, saves it and uses it");
		Expect(!EditorTheme.Import(scope $"{folder}/missing.ttheme" , problems..Clear()) && problems.Contains("could not be read"), "importing a missing file says so");
		Expect(!EditorTheme.Delete(EditorTheme.Find("Dark")) && EditorTheme.Find("Dark") != null, "built-in themes cannot be deleted");
		EditorTheme.SelectCodeTheme("Rose Garden");
		EditorTheme.Delete(EditorTheme.Find("Rose Garden"));
		Expect(EditorTheme.CodeTheme.IsEmpty && CodeIs(EditorTheme.Current), "deleting the theme the code editor uses goes back to matching the editor theme");

		// The user's own theme back.
		Directory.DelTree(folder).IgnoreError();
		EditorTheme.ConfigOverride.Clear();
		EditorTheme.Init();
		Log.Info(scope $"THEME-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}
}
