using System;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Edit > Preferences: the editor's own settings, kept for this user on this machine (not in the project). Its
/// Theme page picks a theme, changes any colour live, and saves, imports and exports themes (docs/themes.md); its
/// Modelling page changes the modeller's shortcuts (ModelShortcuts.bf).
extension EditorApp
{
	bool mShowPreferences;
	/// The page shown: 0 Theme, 1 Modelling (its shortcuts).
	int mPreferencesPage;
	String mThemeName = new .() ~ delete _;
	String mThemeFilter = new .() ~ delete _;
	String mThemeImport = new .() ~ delete _;
	String mThemeExport = new .() ~ delete _;
	String mThemeMessage = new .() ~ delete _;
	bool mThemeMessageBad;

	static readonly StringView[EditorTheme.CodeCount] sCodeLabels = .("Text", "Keywords", "Types", "Numbers", "Strings", "Punctuation", "Preprocessor", "Names", "Known names (engine, project)", "Comments",
		"Background", "Cursor", "Selection", "Whitespace", "Bracket background", "Matching bracket", "Brackets, level 1", "Brackets, level 2", "Brackets, level 3", "Unmatched bracket",
		"Line numbers", "Current line number", "Current line", "Current line border");
	static readonly StringView[EditorTheme.ExtraCount] sExtraLabels = .("Accent (toggled buttons)", "Node canvas", "Text on a canvas", "Code background", "Warnings", "Errors", "Success", "Links and notes", "Prefab bar", "Folder icons", "Object icons", "Component icons");

	void DrawPreferencesWindow()
	{
		if (!mShowPreferences)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + viewport.workSize.x * 0.5f - 330, viewport.workPos.y + 60), 4);
		ImGui.SetNextWindowSize(.(660, 640), 4);
		if (ImGui.Begin("Preferences", &mShowPreferences))
		{
			if (ImGui.BeginChild("pages", .(130, 0), 1))
			{
				if (ImGui.Selectable("Theme", mPreferencesPage == 0))
					mPreferencesPage = 0;
				if (ImGui.Selectable("Modelling", mPreferencesPage == 1))
					mPreferencesPage = 1;
			}
			ImGui.EndChild();
			ImGui.SameLine();
			if (ImGui.BeginChild("page", .(0, 0)))
			{
				if (mPreferencesPage == 1)
					DrawModelShortcutsPage();
				else
					DrawThemePage();
			}
			ImGui.EndChild();
		}
		ImGui.End();
	}

	/// "WindowBg" as "Window Bg", for the colour list.
	static void Friendly(StringView name, String output)
	{
		for (int i < name.Length)
		{
			let c = name[i];
			if (i > 0 && c.IsUpper && !name[i - 1].IsUpper)
				output.Append(' ');
			output.Append(c);
		}
	}

	void ThemeMessage(StringView text, bool bad = false)
	{
		mThemeMessage.Set(text);
		mThemeMessageBad = bad;
	}

	void DrawThemePage()
	{
		let current = EditorTheme.Current;
		let source = EditorTheme.Find(current.name);
		let changed = source == null || !source.SameColors(current);
		if (mThemeName.IsEmpty)
			mThemeName.Set(current.name);

		ImGui.SeparatorText("Theme");
		for (let theme in EditorTheme.Themes)
		{
			let label = scope String(theme.name);
			if (theme.builtIn)
				label.Append("  (built in)");
			label.AppendF("###theme{}", @theme.Index);
			if (ImGui.Selectable(label.CStr(), theme == source))
			{
				EditorTheme.Select(theme);
				mThemeName.Set(theme.name);
				ThemeMessage("");
			}
		}
		if (changed)
		{
			ImGui.TextColored(EditorTheme.Warning, scope $"In use: {current.name}, changed (kept between runs; Save As to keep it as a theme)" .CStr());
			if (source != null && ImGui.Button("Revert Changes"))
				EditorTheme.Select(source);
		}

		ImGui.SeparatorText("Save, import and export");
		ImGui.SetNextItemWidth(-200);
		ImGui.InputText("##themename", mThemeName, 0, "Name");
		ImGui.SameLine();
		if (ImGui.Button("Save As", .(90, 0)))
		{
			let saved = EditorTheme.SaveAs(mThemeName);
			if (saved == null)
				ThemeMessage("Give the theme a name first (or the themes folder could not be written).", true);
			else
			{
				mThemeName.Set(saved.name);
				ThemeMessage(scope $"Saved {saved.path}");
			}
		}
		ImGui.SameLine();
		let canDelete = source != null && !source.builtIn;
		if (ImGui.Button("Delete", .(90, 0)) && canDelete)
		{
			EditorTheme.Delete(source);
			ThemeMessage(scope $"Deleted {current.name}. It stays in use until another theme is picked.");
		}
		ImGui.SetNextItemWidth(-200);
		ImGui.InputText("##themeimport", mThemeImport, 0, "A .ttheme file to import");
		ImGui.SameLine();
		if (ImGui.Button("Import", .(184, 0)))
		{
			let problems = scope String();
			if (EditorTheme.Import(mThemeImport, problems))
			{
				mThemeName.Set(EditorTheme.Current.name);
				ThemeMessage(problems.IsEmpty ? scope $"Imported {EditorTheme.Current.name}." : scope $"Imported, with problems:\n{problems}" , !problems.IsEmpty);
			}
			else
				ThemeMessage(problems, true);
		}
		if (mThemeExport.IsEmpty)
			mThemeExport.AppendF("{}/{}", Project.Current.Path, EditorTheme.FileName(current.name, .. scope .()));
		ImGui.SetNextItemWidth(-200);
		ImGui.InputText("##themeexport", mThemeExport, 0, "Where to write it");
		ImGui.SameLine();
		if (ImGui.Button("Export", .(184, 0)))
		{
			if (EditorTheme.Export(mThemeExport))
				ThemeMessage(scope $"Wrote {mThemeExport}");
			else
				ThemeMessage(scope $"Could not write {mThemeExport}" , true);
		}
		let folder = EditorTheme.Folder(.. scope .());
		ImGui.TextDisabled(scope $"Saved themes: {folder}" .CStr());
		ImGui.SameLine();
		if (ImGui.SmallButton("Open Folder"))
		{
			Directory.CreateDirectory(folder).IgnoreError();
			Terminal.Open(folder);
		}
		if (!mThemeMessage.IsEmpty)
			ImGui.TextColored(mThemeMessageBad ? EditorTheme.Error : EditorTheme.Good, mThemeMessage.CStr());

		ImGui.SeparatorText("Code editor");
		let matching = EditorTheme.CodeTheme.IsEmpty;
		let preview = matching ? scope $"Match the editor theme ({current.name})" : scope String(EditorTheme.CodeTheme);
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##codetheme", preview.CStr()))
		{
			if (ImGui.Selectable("Match the editor theme", matching))
				EditorTheme.SelectCodeTheme("");
			for (let theme in EditorTheme.Themes)
			{
				if (ImGui.Selectable(scope $"{theme.name}###code{@theme.Index}" .CStr(), !matching && theme.name == EditorTheme.CodeTheme))
					EditorTheme.SelectCodeTheme(theme.name);
			}
			ImGui.EndCombo();
		}
		ImGui.TextDisabled(matching ? "Each theme has code colours of its own; the code editor uses this theme's." : "The code editor keeps these colours whatever theme the editor uses.");

		ImGui.SeparatorText("Colours");
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##themefilter", mThemeFilter, 0, "Find a colour");
		let filter = scope String(mThemeFilter)..Trim();
		bool Shown(StringView name) => filter.IsEmpty || name.IndexOf(filter, true) >= 0;
		let flags = ImGui.ColorFlags.AlphaBar;
		if (ImGui.CollapsingHeader("Editor colours", ImGui.TreeFlags.DefaultOpen))
		{
			for (int i < EditorTheme.ExtraCount)
			{
				// The code background is with the code colours.
				if (i == (int)ThemeColor.CodeBackground || (!Shown(sExtraLabels[i]) && !Shown(EditorTheme.ExtraNames[i])))
					continue;
				var color = current.extras[i];
				if (ImGui.ColorEdit4(scope $"{sExtraLabels[i]}###extra{i}" .CStr(), ref color, flags))
					EditorTheme.SetExtra((ThemeColor)i, color);
				if (ImGui.IsItemDeactivatedAfterEdit())
					EditorTheme.SaveActive();
			}
		}
		if (ImGui.CollapsingHeader("Code colours", ImGui.TreeFlags.DefaultOpen))
		{
			if (!matching)
				ImGui.TextColored(EditorTheme.Info, scope $"These are {current.name}'s code colours; the code editor is using {EditorTheme.CodeTheme}'s." .CStr());
			for (int i < EditorTheme.CodeCount)
			{
				if (!Shown(sCodeLabels[i]) && !Shown(EditorTheme.CodeNames[i]))
					continue;
				var color = current.code[i];
				if (ImGui.ColorEdit4(scope $"{sCodeLabels[i]}###code{i}" .CStr(), ref color, flags))
					EditorTheme.SetCode((CodeColor)i, color);
				if (ImGui.IsItemDeactivatedAfterEdit())
					EditorTheme.SaveActive();
			}
		}
		if (ImGui.CollapsingHeader("Interface colours", ImGui.TreeFlags.DefaultOpen))
		{
			for (int32 i < ImGui.StyleColorCount)
			{
				let name = ImGui.StyleColorName(i);
				let label = Friendly(name, .. scope .());
				if (!Shown(name) && !Shown(label))
					continue;
				var color = ImGui.GetStyleColor(i);
				if (ImGui.ColorEdit4(scope $"{label}###color{i}" .CStr(), ref color, flags))
					EditorTheme.SetColor(i, color);
				if (ImGui.IsItemDeactivatedAfterEdit())
					EditorTheme.SaveActive();
			}
		}
	}
}
