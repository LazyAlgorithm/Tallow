using System;
using System.Collections;
using Tallow;
using Tallow.Editor;

namespace ThemeTests;

/// Editor themes (docs/themes.md), without a window: every built-in theme's text is readable on every surface it
/// is drawn on, the Dark theme is the editor's old look, theme files read back as they were written, mistakes in a
/// file are reported by line and the rest still read, and file names are safe. Applying themes, saving, importing
/// and exporting are checked in the editor: `--theme-test`.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	static bool Near(Color a, Color b) => Math.Abs(a.r - b.r) < 0.002f && Math.Abs(a.g - b.g) < 0.002f && Math.Abs(a.b - b.b) < 0.002f && Math.Abs(a.a - b.a) < 0.002f;

	/// The worst contrast of a colour against several backgrounds, and which one.
	static float Worst(Theme theme, Color color, Span<StringView> backgrounds, String which)
	{
		var worst = float.MaxValue;
		for (let name in backgrounds)
		{
			let contrast = EditorTheme.Contrast(color, theme.Get(name));
			if (contrast < worst)
			{
				worst = contrast;
				which.Set(name);
			}
		}
		return worst;
	}

	static void Readable()
	{
		EditorTheme.AddBuiltIns();
		var allThere = EditorTheme.Themes.Count == 7;
		for (let name in StringView[?]("Tallow Blue", "dark", "Light", "High Contrast", "Forest", "Ember", "Plum"))
			allThere &= EditorTheme.Find(name) != null;
		Check(allThere, "seven built-in themes: Tallow Blue, Dark, Light, High Contrast, Forest, Ember and Plum");
		Check(EditorTheme.Themes[0].name == EditorTheme.DefaultTheme && EditorTheme.DefaultTheme == "Tallow Blue", "Tallow Blue is the default, first in the list");
		StringView[?] surfaces = .("WindowBg", "PopupBg", "FrameBg", "Button", "Header", "HeaderHovered", "HeaderActive", "TitleBg", "MenuBarBg", "Tab", "TabSelected");
		for (let theme in EditorTheme.Themes)
		{
			let high = theme.name == "High Contrast";
			let which = scope String();
			// Ordinary text: 4.5 (WCAG AA), 7 for High Contrast (AAA).
			let text = Worst(theme, theme.Get("Text"), surfaces, which);
			Check(text >= (high ? 7 : 4.5f), scope $"{theme.name}: text is readable on every surface (worst {text:0.0} on {which})");
			let quiet = Worst(theme, theme.Get("TextDisabled"), StringView[?]("WindowBg", "FrameBg"), which);
			Check(quiet >= (high ? 4.5f : 3), scope $"{theme.name}: quiet text still reads ({quiet:0.0} on {which})");
			// The editor's own text colours, on the window.
			var worstExtra = float.MaxValue;
			for (let kind in ThemeColor[?](.Warning, .Error, .Good, .Info))
				worstExtra = Math.Min(worstExtra, EditorTheme.Contrast(theme.extras[(int)kind], theme.Get("WindowBg")));
			Check(worstExtra >= (high ? 4.5f : 3), scope $"{theme.name}: warnings, errors, success and links read on the window ({worstExtra:0.0})");
			let canvas = EditorTheme.Contrast(theme.extras[(int)ThemeColor.CanvasText], theme.extras[(int)ThemeColor.Canvas]);
			Check(canvas >= 3, scope $"{theme.name}: text on a node canvas reads ({canvas:0.0})");
			Check(EditorTheme.Contrast(theme.Get("Text"), theme.extras[(int)ThemeColor.Accent]) >= 3, scope $"{theme.name}: a toggled button's label reads");

			// Its code colours: code reads on the code background (and on the current line), comments a little
			// quieter; the background is the editor's CodeBackground too.
			let code = theme.code;
			let background = code[(int)CodeColor.Background];
			var worstCode = float.MaxValue;
			var worstName = StringView();
			for (let kind in CodeColor[?](.Text, .Keyword, .Declaration, .Number, .String, .Punctuation, .Preprocessor, .Identifier, .KnownIdentifier))
			{
				for (let under in Color[?](background, code[(int)CodeColor.CurrentLine]))
				{
					let contrast = EditorTheme.Contrast(code[(int)kind], under);
					if (contrast < worstCode)
					{
						worstCode = contrast;
						worstName = EditorTheme.CodeNames[(int)kind];
					}
				}
			}
			Check(worstCode >= (high ? 7 : 4.5f), scope $"{theme.name}: code is readable ({worstCode:0.0} for {worstName})");
			let comment = EditorTheme.Contrast(code[(int)CodeColor.Comment], background);
			Check(comment >= (high ? 7 : 3), scope $"{theme.name}: comments read ({comment:0.0})");
			let numbers = EditorTheme.Contrast(code[(int)CodeColor.LineNumber], background);
			Check(numbers >= 3 && Near(background, theme.extras[(int)ThemeColor.CodeBackground]), scope $"{theme.name}: line numbers read ({numbers:0.0}) and the background is the editor's code background");
		}
		// Each theme's code is its own.
		var distinct = true;
		for (let a in EditorTheme.Themes)
		{
			for (let b in EditorTheme.Themes)
			{
				if (a != b && Near(a.code[(int)CodeColor.Keyword], b.code[(int)CodeColor.Keyword]) && Near(a.code[(int)CodeColor.Background], b.code[(int)CodeColor.Background]))
					distinct = false;
			}
		}
		Check(distinct, "every built-in theme has code colours of its own");
		let dark = EditorTheme.Find("Dark");
		Check(Near(dark.Get("WindowBg"), .(0.22f, 0.22f, 0.22f, 1)) && Near(dark.Get("Text"), .(0.824f, 0.824f, 0.824f, 1)) && Near(dark.Get("Button"), .(0.345f, 0.345f, 0.345f, 1)) && Near(dark.Get("HeaderActive"), .(0.173f, 0.365f, 0.529f, 1)), "Dark is the editor's old look");
		Check(EditorTheme.Find("Light").light && !dark.light, "Light starts from ImGui's light colours, Dark from the dark ones");
		var visualStudio = true;
		let vsDark = EditorTheme.VisualStudioDark(), vsLight = EditorTheme.VisualStudioLight();
		for (int i < EditorTheme.CodeCount)
			visualStudio &= Near(dark.code[i], vsDark[i]) && Near(EditorTheme.Find("Light").code[i], vsLight[i]);
		Check(visualStudio, "Dark's code is the code editor's old Visual Studio colours, and Light's their light set");
	}

	static void Files()
	{
		let blue = EditorTheme.Find("Tallow Blue");
		let text = scope String();
		EditorTheme.Write(blue, text);
		let read = scope Theme();
		let problems = scope String();
		Check(EditorTheme.Parse(text, read, problems) && problems.IsEmpty, "a written theme reads back without problems");
		Check(read.name == "Tallow Blue" && read.light == blue.light && read.SameColors(blue), "and with the same name, base and colours");
		Check(!read.builtIn, "a theme read from a file is not built in");

		let light = EditorTheme.Find("Light");
		text.Clear();
		EditorTheme.Write(light, text);
		Check(text.Contains("base light") && text.Contains("code Keyword ") && text.Contains("editor Accent ") && text.Contains("color WindowBg "), "files say the base, the code colours, the editor's colours and the interface's");
		let forest = EditorTheme.Find("Forest");
		let forestText = EditorTheme.Write(forest, .. scope .());
		let forestRead = scope Theme();
		EditorTheme.Parse(forestText, forestRead, problems..Clear());
		Check(Near(forestRead.code[(int)CodeColor.Keyword], forest.code[(int)CodeColor.Keyword]) && Near(forestRead.code[(int)CodeColor.Comment], forest.code[(int)CodeColor.Comment]), "code colours read back as written");

		// Files from before code colours: `code light` is Visual Studio's light set, keeping the file's background.
		let older = scope Theme();
		EditorTheme.Parse("name \"Old\"\nbase light\ncode light\neditor CodeBackground 0.9 0.9 0.8 1\n", older, problems..Clear());
		Check(problems.IsEmpty && Near(older.code[(int)CodeColor.Keyword], EditorTheme.VisualStudioLight()[(int)CodeColor.Keyword]) && Near(older.code[(int)CodeColor.Background], .(0.9f, 0.9f, 0.8f, 1)), "older files with code dark or light still read");
		EditorTheme.Parse("code Sparkle 1 1 1 1\n", older, problems..Clear());
		Check(problems.Contains("no code colour"), "an unknown code colour is reported");

		// A file with mistakes: they are reported by line, and the rest still read.
		let broken = """
			# a hand-made theme
			name "Sunset"
			base dusk
			color WindowBg 0.3 0.1 0.1
			color Text 1 0.9 0.8 1
			color Button red green blue
			editor Accent 0.9 0.4 0.1 1
			editor Sparkle 1 1 1 1
			colour Border 0 0 0 1
			""";
		let theme = scope Theme();
		problems.Clear();
		let clean = EditorTheme.Parse(broken, theme, problems);
		Check(!clean && problems.Contains("line 3") && problems.Contains("line 6") && problems.Contains("line 8") && problems.Contains("line 9") && !problems.Contains("line 4"), scope $"mistakes are reported by line ({problems.Count('\n')} problems)");
		Check(theme.name == "Sunset" && Near(theme.Get("WindowBg"), .(0.3f, 0.1f, 0.1f, 1)) && Near(theme.Get("Text"), .(1, 0.9f, 0.8f, 1)) && Near(theme.extras[(int)ThemeColor.Accent], .(0.9f, 0.4f, 0.1f, 1)), "the good lines still count (alpha 1 when left out)");
		Check(Near(theme.Get("Button"), EditorTheme.Find("Dark").Get("Button")), "a colour the file does not set keeps the Dark theme's");
		problems.Clear();
		EditorTheme.Parse("color Text 2 -1 0.5 1\n", theme, problems);
		Check(Near(theme.Get("Text"), .(1, 0, 0.5f, 1)), "values are kept between 0 and 1");

		Check(EditorTheme.FileName("My Theme", .. scope .()) == "My Theme.ttheme" && EditorTheme.FileName("../evil:/name", .. scope .()) == "___evil__name.ttheme" && EditorTheme.FileName("  ", .. scope .()) == "Theme.ttheme", "theme names make safe file names");
		Check(Math.Abs(EditorTheme.Contrast(.(0, 0, 0, 1), .(1, 1, 1, 1)) - 21) < 0.01f && Math.Abs(EditorTheme.Contrast(.(0.5f, 0.5f, 0.5f, 1), .(0.5f, 0.5f, 0.5f, 1)) - 1) < 0.001f, "contrast runs from 1 (the same) to 21 (black on white)");
	}

	public static int Main(String[] args)
	{
		Readable();
		Files();
		Console.WriteLine(sFailures == 0 ? "All theme checks passed." : scope $"{sFailures} theme check(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
