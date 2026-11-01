using System;
using System.Collections;
using System.IO;
using Tessera;

namespace Tessera.Editor;

/// The editor's own colours, beside the interface's: what a theme sets for the things the editor draws itself.
enum ThemeColor
{
	/// Toggled-on buttons (Move, Rotate, Snap...) and other highlights.
	Accent,
	/// The background of node canvases (graphs, behaviour trees).
	Canvas,
	/// Quiet text drawn on a canvas.
	CanvasText,
	/// Under the code editor's text.
	CodeBackground,
	Warning,
	Error,
	/// Things that worked.
	Good,
	/// Links and notes.
	Info,
	/// The bar shown while editing a prefab.
	Prefab,
	/// Icons in the Hierarchy and Project panels.
	Folder,
	Object,
	Component
}

/// The code editor's colours (docs/themes.md), in the order the code editor keeps them.
enum CodeColor
{
	Text,
	Keyword,
	/// Type names where they are declared or used.
	Declaration,
	Number,
	String,
	Punctuation,
	/// #if and the like.
	Preprocessor,
	Identifier,
	/// Names the editor knows from the engine and the project.
	KnownIdentifier,
	Comment,
	Background,
	Cursor,
	Selection,
	Whitespace,
	BracketBackground,
	BracketActive,
	Bracket1,
	Bracket2,
	Bracket3,
	BracketError,
	LineNumber,
	CurrentLineNumber,
	CurrentLine,
	CurrentLineBorder
}

/// One editor theme (docs/themes.md): whether it starts from ImGui's dark or light colours, the interface's colours
/// by ImGui's names ("WindowBg"), the editor's own (ThemeColor) and the code editor's (CodeColor).
class Theme
{
	public String name = new .() ~ delete _;
	public bool light;
	/// One of the editor's own themes (cannot be changed or deleted, only copied).
	public bool builtIn;
	/// The file a saved theme lives in.
	public String path = new .() ~ delete _;
	/// The code editor's colours. The background is also the CodeBackground editor colour (kept the same).
	public Color[EditorTheme.CodeCount] code;
	public List<(String name, Color color)> colors = new .() ~ { for (let entry in _) delete entry.name; delete _; };
	public Color[EditorTheme.ExtraCount] extras;

	public void Set(StringView colorName, Color color)
	{
		for (var entry in ref colors)
		{
			if (entry.name == colorName)
			{
				entry.color = color;
				return;
			}
		}
		colors.Add((new String(colorName), color));
	}

	public bool TryGet(StringView colorName, out Color color)
	{
		for (let entry in colors)
		{
			if (entry.name == colorName)
			{
				color = entry.color;
				return true;
			}
		}
		color = default;
		return false;
	}

	public Color Get(StringView colorName) => TryGet(colorName, let color) ? color : default;

	public void CopyFrom(Theme other)
	{
		name.Set(other.name);
		light = other.light;
		code = other.code;
		builtIn = other.builtIn;
		path.Set(other.path);
		for (let entry in colors)
			delete entry.name;
		colors.Clear();
		for (let entry in other.colors)
			colors.Add((new String(entry.name), entry.color));
		extras = other.extras;
	}

	/// Whether two themes look the same (names and files aside).
	public bool SameColors(Theme other)
	{
		if (light != other.light || colors.Count != other.colors.Count)
			return false;
		for (int i < EditorTheme.ExtraCount)
		{
			if (!Close(extras[i], other.extras[i]))
				return false;
		}
		for (int i < EditorTheme.CodeCount)
		{
			if (!Close(code[i], other.code[i]))
				return false;
		}
		for (let entry in colors)
		{
			if (!other.TryGet(entry.name, let color) || !Close(color, entry.color))
				return false;
		}
		return true;
	}

	/// The same as far as a theme file keeps (three decimals).
	static bool Close(Color a, Color b) => Math.Abs(a.r - b.r) < 0.002f && Math.Abs(a.g - b.g) < 0.002f && Math.Abs(a.b - b.b) < 0.002f && Math.Abs(a.a - b.a) < 0.002f;
}

/// The base colours a built-in theme is made from, one for each role, as the interface uses them.
struct ThemePalette
{
	public bool light;
	public Color text, textDisabled;
	public Color window, panel, header, popup, menuBar;
	public Color field, fieldHovered, fieldActive;
	public Color border, tableLight;
	public Color hover, active;
	public Color accent, accentHovered;
	public Color button, buttonHovered;
	public Color scrollbar, grab, grabHovered, grabActive, slider, check;
	public Color selectedText;
	public Color[EditorTheme.ExtraCount] extras;
	public Color[EditorTheme.CodeCount] code;
}

/// The editor's colours (docs/themes.md): the built-in themes (Dark, Light, High Contrast, Tallow Blue), the
/// user's own (`.ttheme` files in the editor's config folder, `themes/`), the one in use, saved between runs in
/// `theme.ttheme`, and the editor's own colours (ThemeColor) for code that draws things itself.
static class EditorTheme
{
	public const int ExtraCount = 12;
	public static readonly StringView[ExtraCount] ExtraNames = .("Accent", "Canvas", "CanvasText", "CodeBackground", "Warning", "Error", "Good", "Info", "Prefab", "Folder", "Object", "Component");
	public const int CodeCount = 24;
	public static readonly StringView[CodeCount] CodeNames = .("Text", "Keyword", "Declaration", "Number", "String", "Punctuation", "Preprocessor", "Identifier", "KnownIdentifier", "Comment",
		"Background", "Cursor", "Selection", "Whitespace", "BracketBackground", "BracketActive", "Bracket1", "Bracket2", "Bracket3", "BracketError",
		"LineNumber", "CurrentLineNumber", "CurrentLine", "CurrentLineBorder");
	/// The theme whose code colours the code editor uses, by name; empty to match the editor's theme.
	public static String CodeTheme = new .() ~ delete _;

	/// Every theme to choose from: the built-in ones, then the user's.
	public static List<Theme> Themes = new .() ~ DeleteContainerAndItems!(_);
	/// The theme in use, with any changes made to it in Preferences.
	public static Theme Current = new .() ~ delete _;

	static Color[ExtraCount] sExtras = Defaults();
	static Color sText = .(0.824f, 0.824f, 0.824f, 1);
	static Color sTextDim = .(0.52f, 0.52f, 0.52f, 1);

	public static Color Accent => sExtras[(int)ThemeColor.Accent];
	public static Color Canvas => sExtras[(int)ThemeColor.Canvas];
	public static Color CanvasText => sExtras[(int)ThemeColor.CanvasText];
	/// Under the code editor's text: the code colours' background (CodeColors).
	public static Color CodeBackground => CodeColors[(int)CodeColor.Background];
	public static Color Warning => sExtras[(int)ThemeColor.Warning];
	public static Color Error => sExtras[(int)ThemeColor.Error];
	public static Color Good => sExtras[(int)ThemeColor.Good];
	public static Color Info => sExtras[(int)ThemeColor.Info];
	public static Color Prefab => sExtras[(int)ThemeColor.Prefab];
	public static Color Folder => sExtras[(int)ThemeColor.Folder];
	public static Color Object => sExtras[(int)ThemeColor.Object];
	public static Color Component => sExtras[(int)ThemeColor.Component];
	/// The interface's text colours, for text the editor draws itself on a panel.
	public static Color Text => sText;
	public static Color TextDim => sTextDim;
	public static bool IsLight => Current.light;

	static Color[ExtraCount] Defaults() => Dark().extras;

	// ---- the built-in themes ----

	/// The editor's look since the start: neutral charcoal greys with a blue accent.
	public static ThemePalette Dark()
	{
		ThemePalette p = default;
		p.text = Grey(0.824f);
		p.textDisabled = Grey(0.52f);
		p.window = Grey(0.22f);
		p.panel = Grey(0.165f);
		p.header = Grey(0.243f);
		p.popup = .(0.19f, 0.19f, 0.19f, 0.98f);
		p.menuBar = Grey(0.118f);
		p.field = Grey(0.165f);
		p.fieldHovered = Grey(0.2f);
		p.fieldActive = Grey(0.13f);
		p.border = Grey(0.098f);
		p.tableLight = Grey(0.16f);
		p.hover = Grey(0.31f);
		p.active = Grey(0.38f);
		p.accent = .(0.173f, 0.365f, 0.529f, 1);
		p.accentHovered = .(0.227f, 0.447f, 0.69f, 1);
		p.button = Grey(0.345f);
		p.buttonHovered = Grey(0.404f);
		p.scrollbar = Grey(0.2f);
		p.grab = Grey(0.37f);
		p.grabHovered = Grey(0.45f);
		p.grabActive = Grey(0.52f);
		p.slider = Grey(0.6f);
		p.check = Grey(0.85f);
		p.selectedText = .(0.173f, 0.365f, 0.529f, 0.85f);
		p.extras = .(.(0.24f, 0.44f, 0.66f, 1), .(0.10f, 0.10f, 0.11f, 0.92f), .(0.62f, 0.64f, 0.68f, 1), Grey(0.118f),
			.(1.0f, 0.75f, 0.33f, 1), .(1.0f, 0.45f, 0.4f, 1), .(0.55f, 0.85f, 0.42f, 1), .(0.45f, 0.62f, 0.98f, 1),
			.(0.13f, 0.30f, 0.46f, 1), .(0.86f, 0.72f, 0.38f, 1), .(0.55f, 0.75f, 0.95f, 1), .(0.72f, 0.78f, 0.86f, 1));
		p.code = VisualStudioDark();
		return p;
	}

	/// Pale greys and white fields with dark text, for bright rooms.
	public static ThemePalette Light()
	{
		ThemePalette p = default;
		p.light = true;
		p.code = VisualStudioLight();
		p.text = Grey(0.1f);
		p.textDisabled = Grey(0.42f);
		p.window = Grey(0.93f);
		p.panel = Grey(0.85f);
		p.header = Grey(0.86f);
		p.popup = .(0.97f, 0.97f, 0.97f, 0.98f);
		p.menuBar = Grey(0.88f);
		p.field = Grey(1);
		p.fieldHovered = Grey(0.97f);
		p.fieldActive = Grey(0.92f);
		p.border = Grey(0.68f);
		p.tableLight = Grey(0.82f);
		p.hover = Grey(0.79f);
		p.active = Grey(0.73f);
		p.accent = .(0.70f, 0.82f, 0.96f, 1);
		p.accentHovered = .(0.26f, 0.52f, 0.86f, 1);
		p.button = Grey(0.83f);
		p.buttonHovered = Grey(0.77f);
		p.scrollbar = Grey(0.9f);
		p.grab = Grey(0.69f);
		p.grabHovered = Grey(0.61f);
		p.grabActive = Grey(0.54f);
		p.slider = Grey(0.5f);
		p.check = Grey(0.15f);
		p.selectedText = .(0.26f, 0.52f, 0.86f, 0.35f);
		p.extras = .(.(0.62f, 0.77f, 0.95f, 1), .(0.80f, 0.81f, 0.83f, 1), Grey(0.3f), Grey(1),
			.(0.66f, 0.38f, 0.0f, 1), .(0.78f, 0.12f, 0.10f, 1), .(0.13f, 0.50f, 0.13f, 1), .(0.10f, 0.32f, 0.78f, 1),
			.(0.74f, 0.85f, 0.96f, 1), .(0.70f, 0.50f, 0.05f, 1), .(0.15f, 0.42f, 0.75f, 1), .(0.30f, 0.36f, 0.45f, 1));
		p.extras[(int)ThemeColor.CodeBackground] = p.code[(int)CodeColor.Background];
		return p;
	}

	/// Black and white with bright edges and highlights, for the clearest reading.
	public static ThemePalette HighContrast()
	{
		ThemePalette p = default;
		p.text = Grey(1);
		p.textDisabled = Grey(0.78f);
		p.window = Grey(0);
		p.panel = Grey(0);
		p.header = Grey(0.16f);
		p.popup = .(0.0f, 0.0f, 0.0f, 1);
		p.menuBar = Grey(0);
		p.field = Grey(0.06f);
		p.fieldHovered = Grey(0.16f);
		p.fieldActive = Grey(0.22f);
		p.border = Grey(0.9f);
		p.tableLight = Grey(0.55f);
		p.hover = .(0.0f, 0.30f, 0.50f, 1);
		p.active = .(0.0f, 0.40f, 0.65f, 1);
		p.accent = .(0.0f, 0.32f, 0.56f, 1);
		p.accentHovered = .(1.0f, 0.85f, 0.0f, 1);
		p.button = Grey(0.12f);
		p.buttonHovered = .(0.0f, 0.30f, 0.50f, 1);
		p.scrollbar = Grey(0.05f);
		p.grab = Grey(0.7f);
		p.grabHovered = Grey(0.85f);
		p.grabActive = .(1.0f, 0.85f, 0.0f, 1);
		p.slider = .(1.0f, 0.85f, 0.0f, 1);
		p.check = .(1.0f, 0.85f, 0.0f, 1);
		p.selectedText = .(0.0f, 0.32f, 0.56f, 1);
		p.extras = .(.(0.0f, 0.32f, 0.56f, 1), Grey(0.04f), Grey(0.9f), Grey(0),
			.(1.0f, 0.88f, 0.2f, 1), .(1.0f, 0.5f, 0.5f, 1), .(0.45f, 1.0f, 0.45f, 1), .(0.55f, 0.82f, 1.0f, 1),
			.(0.0f, 0.30f, 0.50f, 1), .(1.0f, 0.85f, 0.3f, 1), .(0.55f, 0.85f, 1.0f, 1), Grey(0.9f));
		// Every colour at least 7:1 on black.
		p.code = Code(Grey(0), Grey(1), .(0.55f, 0.80f, 1.0f, 1), .(0.30f, 1.0f, 0.85f, 1), .(0.75f, 1.0f, 0.55f, 1), .(1.0f, 0.78f, 0.50f, 1),
			.(1.0f, 0.62f, 1.0f, 1), Grey(1), .(1.0f, 1.0f, 0.55f, 1), .(0.45f, 0.95f, 0.45f, 1), .(0.0f, 0.32f, 0.56f, 1));
		p.code[(int)CodeColor.LineNumber] = Grey(0.8f);
		p.code[(int)CodeColor.CurrentLine] = Grey(0.1f);
		p.code[(int)CodeColor.CurrentLineBorder] = Grey(0.6f);
		p.code[(int)CodeColor.BracketActive] = .(1.0f, 0.85f, 0.0f, 1);
		return p;
	}

	/// Deep blue-greys with a brighter blue accent: Tallow's own colours.
	public static ThemePalette TallowBlue()
	{
		ThemePalette p = default;
		p.text = .(0.86f, 0.89f, 0.94f, 1);
		p.textDisabled = .(0.52f, 0.57f, 0.65f, 1);
		p.window = .(0.13f, 0.16f, 0.21f, 1);
		p.panel = .(0.10f, 0.12f, 0.17f, 1);
		p.header = .(0.17f, 0.21f, 0.28f, 1);
		p.popup = .(0.12f, 0.15f, 0.20f, 0.98f);
		p.menuBar = .(0.08f, 0.10f, 0.14f, 1);
		p.field = .(0.09f, 0.11f, 0.15f, 1);
		p.fieldHovered = .(0.12f, 0.15f, 0.21f, 1);
		p.fieldActive = .(0.07f, 0.09f, 0.13f, 1);
		p.border = .(0.05f, 0.06f, 0.09f, 1);
		p.tableLight = .(0.10f, 0.12f, 0.17f, 1);
		p.hover = .(0.22f, 0.28f, 0.38f, 1);
		p.active = .(0.27f, 0.34f, 0.46f, 1);
		p.accent = .(0.14f, 0.36f, 0.64f, 1);
		p.accentHovered = .(0.27f, 0.53f, 0.86f, 1);
		p.button = .(0.22f, 0.28f, 0.38f, 1);
		p.buttonHovered = .(0.28f, 0.35f, 0.47f, 1);
		p.scrollbar = .(0.10f, 0.12f, 0.17f, 1);
		p.grab = .(0.28f, 0.34f, 0.45f, 1);
		p.grabHovered = .(0.34f, 0.41f, 0.54f, 1);
		p.grabActive = .(0.27f, 0.53f, 0.86f, 1);
		p.slider = .(0.45f, 0.55f, 0.70f, 1);
		p.check = .(0.55f, 0.75f, 1.0f, 1);
		p.selectedText = .(0.16f, 0.40f, 0.70f, 0.85f);
		p.extras = .(.(0.20f, 0.46f, 0.78f, 1), .(0.07f, 0.09f, 0.13f, 0.94f), .(0.60f, 0.66f, 0.76f, 1), .(0.08f, 0.10f, 0.14f, 1),
			.(1.0f, 0.78f, 0.36f, 1), .(1.0f, 0.47f, 0.43f, 1), .(0.55f, 0.88f, 0.50f, 1), .(0.50f, 0.72f, 1.0f, 1),
			.(0.12f, 0.30f, 0.52f, 1), .(0.88f, 0.74f, 0.40f, 1), .(0.55f, 0.78f, 1.0f, 1), .(0.70f, 0.78f, 0.90f, 1));
		// Blues and teals over the panels' deep blue-grey, with warm strings and numbers.
		p.code = Code(.(0.08f, 0.10f, 0.14f, 1), .(0.84f, 0.87f, 0.93f, 1), .(0.47f, 0.68f, 1.0f, 1), .(0.38f, 0.85f, 0.86f, 1), .(0.96f, 0.74f, 0.52f, 1),
			.(0.92f, 0.66f, 0.56f, 1), .(0.78f, 0.60f, 0.98f, 1), .(0.66f, 0.82f, 1.0f, 1), .(0.94f, 0.88f, 0.62f, 1), .(0.47f, 0.62f, 0.52f, 1), .(0.16f, 0.36f, 0.62f, 1));
		return p;
	}

	/// A dark theme tinted all through with one hue, with an accent of its own.
	/// `hue` scales each channel of the greys (1, 1, 1 is neutral); `accent` is selected things, `bright` hovered ones.
	static ThemePalette Tinted(Color hue, Color accent, Color bright, Color text, Color keyword, Color declaration, Color number, Color str,
		Color preprocessor, Color known, Color comment)
	{
		Color Shade(float v, float a = 1) => .(hue.r * v, hue.g * v, hue.b * v, a);
		Color Mix(Color a, Color b, float t) => .(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
		ThemePalette p = default;
		p.text = text;
		p.textDisabled = Mix(text, Shade(0.2f), 0.42f);
		p.window = Shade(0.2f);
		p.panel = Shade(0.155f);
		p.header = Shade(0.27f);
		p.popup = Shade(0.185f, 0.98f);
		p.menuBar = Shade(0.12f);
		p.field = Shade(0.14f);
		p.fieldHovered = Shade(0.19f);
		p.fieldActive = Shade(0.11f);
		p.border = Shade(0.08f);
		p.tableLight = Shade(0.155f);
		p.hover = Shade(0.35f);
		p.active = Shade(0.42f);
		p.accent = accent;
		p.accentHovered = bright;
		p.button = Shade(0.34f);
		p.buttonHovered = Shade(0.42f);
		p.scrollbar = Shade(0.155f);
		p.grab = Shade(0.43f);
		p.grabHovered = Shade(0.52f);
		p.grabActive = bright;
		p.slider = Mix(Shade(0.7f), bright, 0.4f);
		p.check = Mix(bright, text, 0.4f);
		p.selectedText = .(accent.r, accent.g, accent.b, 0.85f);
		p.extras = .(Mix(accent, bright, 0.3f), Shade(0.11f, 0.94f), Mix(text, Shade(0.11f), 0.3f), Shade(0.12f),
			.(1.0f, 0.78f, 0.36f, 1), .(1.0f, 0.5f, 0.45f, 1), .(0.55f, 0.88f, 0.50f, 1), .(0.55f, 0.75f, 1.0f, 1),
			Mix(accent, Shade(0.1f), 0.3f), .(0.88f, 0.74f, 0.40f, 1), Mix(bright, text, 0.5f), Mix(text, Shade(0.5f), 0.15f));
		p.code = Code(Shade(0.12f), text, keyword, declaration, number, str, preprocessor, Mix(text, bright, 0.25f), known, comment, accent);
		return p;
	}

	/// A dark or light set of code colours from its syntax colours; the rest (cursor, line numbers, brackets...)
	/// follow from the background and text.
	static Color[CodeCount] Code(Color background, Color text, Color keyword, Color declaration, Color number, Color str, Color preprocessor,
		Color identifier, Color known, Color comment, Color selection)
	{
		Color Mix(Color a, Color b, float t) => .(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
		Color[CodeCount] c = default;
		c[(int)CodeColor.Text] = text;
		c[(int)CodeColor.Keyword] = keyword;
		c[(int)CodeColor.Declaration] = declaration;
		c[(int)CodeColor.Number] = number;
		c[(int)CodeColor.String] = str;
		c[(int)CodeColor.Punctuation] = text;
		c[(int)CodeColor.Preprocessor] = preprocessor;
		c[(int)CodeColor.Identifier] = identifier;
		c[(int)CodeColor.KnownIdentifier] = known;
		c[(int)CodeColor.Comment] = comment;
		c[(int)CodeColor.Background] = background;
		c[(int)CodeColor.Cursor] = text;
		c[(int)CodeColor.Selection] = selection;
		c[(int)CodeColor.Whitespace] = Mix(background, text, 0.2f);
		c[(int)CodeColor.BracketBackground] = Mix(background, text, 0.15f);
		c[(int)CodeColor.BracketActive] = .(1.0f, 0.84f, 0.0f, 1);
		c[(int)CodeColor.Bracket1] = known;
		c[(int)CodeColor.Bracket2] = preprocessor;
		c[(int)CodeColor.Bracket3] = keyword;
		c[(int)CodeColor.BracketError] = .(0.96f, 0.28f, 0.28f, 1);
		c[(int)CodeColor.LineNumber] = Mix(text, background, 0.45f);
		c[(int)CodeColor.CurrentLineNumber] = text;
		c[(int)CodeColor.CurrentLine] = Mix(background, text, 0.06f);
		c[(int)CodeColor.CurrentLineBorder] = Mix(background, text, 0.12f);
		return c;
	}

	static Color Rgb(int r, int g, int b) => .(r / 255.0f, g / 255.0f, b / 255.0f, 1);

	/// Visual Studio's dark code colours: the code editor's colours since the start.
	public static Color[CodeCount] VisualStudioDark() => .(Rgb(212, 212, 212), Rgb(86, 156, 214), Rgb(78, 201, 176), Rgb(181, 206, 168), Rgb(206, 145, 120),
		Rgb(212, 212, 212), Rgb(197, 134, 192), Rgb(156, 220, 254), Rgb(220, 220, 170), Rgb(106, 153, 85), Rgb(30, 30, 30), Rgb(174, 175, 173), Rgb(38, 79, 120),
		Rgb(64, 64, 64), Rgb(62, 62, 66), Rgb(255, 215, 0), Rgb(255, 215, 0), Rgb(218, 112, 214), Rgb(23, 159, 255), Rgb(244, 71, 71), Rgb(133, 133, 133),
		Rgb(198, 198, 198), Rgb(42, 42, 44), Rgb(54, 54, 58));

	/// Visual Studio's light code colours (type names and numbers a little darker, to read on the current line).
	public static Color[CodeCount] VisualStudioLight() => .(Rgb(30, 30, 30), Rgb(0, 0, 255), Rgb(29, 108, 130), Rgb(9, 115, 75), Rgb(163, 21, 21),
		Rgb(30, 30, 30), Rgb(175, 0, 219), Rgb(0, 16, 128), Rgb(121, 94, 38), Rgb(0, 128, 0), Rgb(255, 255, 255), Rgb(0, 0, 0), Rgb(173, 214, 255),
		Rgb(200, 200, 200), Rgb(220, 220, 220), Rgb(180, 120, 0), Rgb(4, 49, 250), Rgb(49, 147, 49), Rgb(123, 56, 20), Rgb(205, 49, 49), Rgb(35, 120, 147),
		Rgb(11, 33, 108), Rgb(238, 238, 238), Rgb(220, 220, 220));

	/// Mossy greens with a leaf-green accent.
	/// Its code: leaf-green keywords, teal types, wheat strings.
	public static ThemePalette Forest() => Tinted(.(0.72f, 1.0f, 0.8f, 1), .(0.16f, 0.45f, 0.28f, 1), .(0.30f, 0.68f, 0.42f, 1), .(0.87f, 0.93f, 0.88f, 1),
		.(0.50f, 0.86f, 0.52f, 1), .(0.50f, 0.85f, 0.80f, 1), .(0.88f, 0.68f, 0.50f, 1), .(0.90f, 0.82f, 0.55f, 1), .(0.80f, 0.68f, 0.92f, 1),
		.(0.93f, 0.92f, 0.65f, 1), .(0.52f, 0.64f, 0.54f, 1));

	/// Warm browns with an orange accent, like a fire's glow.
	/// Its code: orange keywords, gold types, olive strings.
	public static ThemePalette Ember() => Tinted(.(1.0f, 0.8f, 0.68f, 1), .(0.60f, 0.29f, 0.10f, 1), .(0.90f, 0.52f, 0.20f, 1), .(0.95f, 0.90f, 0.85f, 1),
		.(1.0f, 0.62f, 0.30f, 1), .(1.0f, 0.82f, 0.45f, 1), .(0.96f, 0.56f, 0.50f, 1), .(0.76f, 0.85f, 0.50f, 1), .(0.92f, 0.62f, 0.78f, 1),
		.(1.0f, 0.90f, 0.66f, 1), .(0.64f, 0.56f, 0.48f, 1));

	/// Dusky purples with a violet accent.
	/// Its code: violet keywords, pink types, mint strings.
	public static ThemePalette Plum() => Tinted(.(0.88f, 0.72f, 1.0f, 1), .(0.42f, 0.24f, 0.62f, 1), .(0.64f, 0.44f, 0.90f, 1), .(0.92f, 0.88f, 0.96f, 1),
		.(0.76f, 0.58f, 1.0f, 1), .(0.96f, 0.62f, 0.86f, 1), .(1.0f, 0.76f, 0.56f, 1), .(0.64f, 0.88f, 0.70f, 1), .(0.56f, 0.80f, 1.0f, 1),
		.(0.90f, 0.84f, 1.0f, 1), .(0.62f, 0.55f, 0.70f, 1));

	static Color Grey(float v) => .(v, v, v, 1);
	static Color Alpha(Color c, float a) => .(c.r, c.g, c.b, a);

	/// A theme from a palette: each role given to the interface's colours that play it.
	public static Theme Build(StringView name, ThemePalette p)
	{
		let theme = new Theme();
		theme.name.Set(name);
		theme.light = p.light;
		theme.builtIn = true;
		theme.extras = p.extras;
		theme.code = p.code;
		theme.extras[(int)ThemeColor.CodeBackground] = p.code[(int)CodeColor.Background];
		void Set(StringView colorName, Color color) => theme.Set(colorName, color);
		let none = Color(0, 0, 0, 0);
		Set("Text", p.text);
		Set("TextDisabled", p.textDisabled);
		Set("WindowBg", p.window);
		Set("ChildBg", none);
		Set("PopupBg", p.popup);
		Set("Border", p.border);
		Set("BorderShadow", none);
		Set("FrameBg", p.field);
		Set("FrameBgHovered", p.fieldHovered);
		Set("FrameBgActive", p.fieldActive);
		Set("TitleBg", p.panel);
		Set("TitleBgActive", p.panel);
		Set("TitleBgCollapsed", p.panel);
		Set("MenuBarBg", p.menuBar);
		Set("ScrollbarBg", p.scrollbar);
		Set("ScrollbarGrab", p.grab);
		Set("ScrollbarGrabHovered", p.grabHovered);
		Set("ScrollbarGrabActive", p.grabActive);
		Set("CheckMark", p.check);
		Set("SliderGrab", p.slider);
		Set("SliderGrabActive", p.accentHovered);
		Set("Button", p.button);
		Set("ButtonHovered", p.buttonHovered);
		Set("ButtonActive", p.accent);
		Set("Header", p.header);
		Set("HeaderHovered", p.hover);
		Set("HeaderActive", p.accent);
		Set("Separator", p.border);
		Set("SeparatorHovered", p.accentHovered);
		Set("SeparatorActive", p.accentHovered);
		Set("ResizeGrip", none);
		Set("ResizeGripHovered", p.hover);
		Set("ResizeGripActive", p.active);
		Set("Tab", p.panel);
		Set("TabHovered", p.hover);
		Set("TabSelected", p.window);
		Set("TabSelectedOverline", p.accentHovered);
		Set("TabDimmed", p.panel);
		Set("TabDimmedSelected", p.window);
		Set("TabDimmedSelectedOverline", none);
		Set("DockingPreview", Alpha(p.accentHovered, 0.55f));
		Set("DockingEmptyBg", p.menuBar);
		Set("TableHeaderBg", p.header);
		Set("TableBorderStrong", p.border);
		Set("TableBorderLight", p.tableLight);
		Set("TextSelectedBg", p.selectedText);
		Set("TextLink", p.extras[(int)ThemeColor.Info]);
		Set("DragDropTarget", p.accentHovered);
		Set("NavCursor", p.accentHovered);
		Set("ModalWindowDimBg", .(0, 0, 0, 0.45f));
		return theme;
	}

	public static void AddBuiltIns()
	{
		// Tallow Blue first: the default.
		Themes.Add(Build("Tallow Blue", TallowBlue()));
		Themes.Add(Build("Dark", Dark()));
		Themes.Add(Build("Light", Light()));
		Themes.Add(Build("High Contrast", HighContrast()));
		Themes.Add(Build("Forest", Forest()));
		Themes.Add(Build("Ember", Ember()));
		Themes.Add(Build("Plum", Plum()));
	}

	/// The theme the editor starts with until another is picked.
	public const String DefaultTheme = "Tallow Blue";

	public static Theme Find(StringView name)
	{
		for (let theme in Themes)
		{
			if (theme.name.Equals(name, .OrdinalIgnoreCase))
				return theme;
		}
		return null;
	}

	// ---- files ----

	/// Writes a theme as a `.ttheme` file's text.
	public static void Write(Theme theme, String output)
	{
		output.Append("# Tallow editor theme (docs/themes.md)\n");
		output.AppendF("name \"{}\"\n", theme.name);
		output.AppendF("base {}\n", theme.light ? "light" : "dark");
		for (int i < ExtraCount)
			output.AppendF("editor {} {}\n", ExtraNames[i], ColorText(theme.extras[i], .. scope .()));
		for (int i < CodeCount)
			output.AppendF("code {} {}\n", CodeNames[i], ColorText(theme.code[i], .. scope .()));
		for (let entry in theme.colors)
			output.AppendF("color {} {}\n", entry.name, ColorText(entry.color, .. scope .()));
	}

	static void ColorText(Color c, String output)
	{
		output.AppendF("{0:0.###} {1:0.###} {2:0.###} {3:0.###}", c.r, c.g, c.b, c.a);
	}

	/// Reads a `.ttheme` file's text into a theme (starting from the Dark theme's own colours, so that a file need
	/// not name every one). Lines it cannot read are listed in `problems`, by line number; false when there are any.
	public static bool Parse(StringView text, Theme into, String problems)
	{
		let dark = scope Theme();
		let built = Build("Dark", Dark());
		dark.CopyFrom(built);
		delete built;
		into.CopyFrom(dark);
		into.builtIn = false;
		into.name.Set("Untitled");
		int lineNumber = 0;
		for (var line in text.Split('\n'))
		{
			lineNumber++;
			line.Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			let space = line.IndexOf(' ');
			let word = space < 0 ? line : line.Substring(0, space);
			var rest = space < 0 ? StringView() : line.Substring(space + 1);
			rest.Trim();
			switch (word)
			{
			case "name":
				var name = rest;
				if (name.StartsWith('"') && name.EndsWith('"') && name.Length >= 2)
					name = name.Substring(1, name.Length - 2);
				if (name.IsEmpty)
					problems.AppendF("line {}: the name is empty\n", lineNumber);
				else
					into.name.Set(name);
			case "base","code":
				if (word == "code" && rest.IndexOf(' ') >= 0)
					ParseColor(word, rest, lineNumber, into, problems);
				else if (rest != "dark" && rest != "light")
					problems.AppendF("line {}: {} is dark or light, not '{}'\n", lineNumber, word, rest);
				else if (word == "base")
					into.light = rest == "light";
				else
				{
					// Older files: Visual Studio's dark or light code colours (the background stays the theme's own).
					let background = into.code[(int)CodeColor.Background];
					into.code = rest == "light" ? VisualStudioLight() : VisualStudioDark();
					into.code[(int)CodeColor.Background] = background;
				}
			case "color","editor":
				ParseColor(word, rest, lineNumber, into, problems);
			default:
				problems.AppendF("line {}: '{}' is not name, base, code, color or editor\n", lineNumber, word);
			}
		}
		return problems.IsEmpty;
	}

	/// A `color`, `editor` or `code` line's name and colour.
	static void ParseColor(StringView word, StringView rest, int lineNumber, Theme into, String problems)
	{
		let parts = scope List<StringView>();
		for (let part in rest.Split(' ', .RemoveEmptyEntries))
			parts.Add(part);
		float[4] values = .(0, 0, 0, 1);
		var good = parts.Count == 4 || parts.Count == 5;
		for (int i = 1; good && i < parts.Count; i++)
		{
			if (float.Parse(parts[i]) case .Ok(let value))
				values[i - 1] = Math.Clamp(value, 0, 1);
			else
				good = false;
		}
		if (!good)
		{
			problems.AppendF("line {}: expected {} <name> <red> <green> <blue> [alpha], 0 to 1\n", lineNumber, word);
			return;
		}
		let color = Color(values[0], values[1], values[2], values[3]);
		if (word == "editor")
		{
			let index = ExtraIndex(parts[0]);
			if (index < 0)
				problems.AppendF("line {}: no editor colour is called '{}'\n", lineNumber, parts[0]);
			else
			{
				into.extras[index] = color;
				if (index == (int)ThemeColor.CodeBackground)
					into.code[(int)CodeColor.Background] = color;
			}
		}
		else if (word == "code")
		{
			let index = CodeIndex(parts[0]);
			if (index < 0)
				problems.AppendF("line {}: no code colour is called '{}'\n", lineNumber, parts[0]);
			else
			{
				into.code[index] = color;
				if (index == (int)CodeColor.Background)
					into.extras[(int)ThemeColor.CodeBackground] = color;
			}
		}
		else
			into.Set(parts[0], color);
	}

	public static int CodeIndex(StringView name)
	{
		for (int i < CodeCount)
		{
			if (CodeNames[i] == name)
				return i;
		}
		return -1;
	}

	public static int ExtraIndex(StringView name)
	{
		for (int i < ExtraCount)
		{
			if (ExtraNames[i] == name)
				return i;
		}
		return -1;
	}

	/// A file name for a theme's name: letters, digits, spaces, '-' and '_' kept.
	public static void FileName(StringView name, String output)
	{
		for (let c in name.RawChars)
			output.Append(c.IsLetterOrDigit || c == '-' || c == '_' || c == ' ' ? c : '_');
		output.Trim();
		if (output.IsEmpty)
			output.Append("Theme");
		output.Append(".ttheme");
	}

	/// How readable one colour is on another (WCAG contrast ratio: 1 the same, 21 black on white; 4.5 is enough for
	/// ordinary text).
	public static float Contrast(Color a, Color b)
	{
		float Luminance(Color c)
		{
			float Channel(float v) => v <= 0.03928f ? v / 12.92f : Math.Pow((v + 0.055f) / 1.055f, 2.4f);
			return 0.2126f * Channel(c.r) + 0.7152f * Channel(c.g) + 0.0722f * Channel(c.b);
		}
		let la = Luminance(a), lb = Luminance(b);
		return (Math.Max(la, lb) + 0.05f) / (Math.Min(la, lb) + 0.05f);
	}

	// ---- the editor ----

	/// A folder used in place of the editor's config folder (tests, so that the user's themes are left alone).
	public static String ConfigOverride = new .() ~ delete _;

	static void ConfigFolder(String output)
	{
		if (ConfigOverride.IsEmpty)
			RecentProjects.GetConfigFolder(output);
		else
			output.AppendF("{}/", ConfigOverride);
	}

	/// Where the user's themes are kept, and the one in use.
	public static void Folder(String output)
	{
		ConfigFolder(output);
		output.Append("themes");
	}

	static void ActivePath(String output)
	{
		ConfigFolder(output);
		output.Append("theme.ttheme");
	}

	/// Where the code editor's own choice of theme is kept (empty or missing: match the editor's theme).
	static void CodeThemePath(String output)
	{
		ConfigFolder(output);
		output.Append("code-theme.txt");
	}

	/// The theme whose code colours are in use: the one picked for code, or the editor's own.
	public static Theme CodeSource
	{
		get
		{
			if (!CodeTheme.IsEmpty)
			{
				let found = Find(CodeTheme);
				if (found != null)
					return found;
			}
			return Current;
		}
	}

	/// The code editor's colours in use.
	public static Color[CodeCount] CodeColors => CodeSource.code;

	/// Gives the code editor a theme's code colours, apart from the editor's theme (empty: match the editor's
	/// theme again), and remembers the choice.
	public static void SelectCodeTheme(StringView name)
	{
		let found = name.IsEmpty ? null : Find(name);
		CodeTheme.Set(found != null ? found.name : "");
		PutCode();
		if (CodeTheme.IsEmpty)
			File.Delete(CodeThemePath(.. scope .())).IgnoreError();
		else
			File.WriteAllText(CodeThemePath(.. scope .()), CodeTheme).IgnoreError();
	}

	/// Hands the code colours in use to the code editor.
	static void PutCode()
	{
		uint32[CodeCount] packed = default;
		for (int i < CodeCount)
		{
			let c = CodeColors[i];
			uint32 Byte(float v) => (uint32)Math.Clamp((int)(v * 255 + 0.5f), 0, 255);
			packed[i] = Byte(c.r) | (Byte(c.g) << 8) | (Byte(c.b) << 16) | (Byte(c.a) << 24);
		}
		tn_code_set_palette(&packed, CodeCount);
	}

	[CLink] static extern void tn_code_set_palette(uint32* colors, int32 count);
	[CLink] static extern bool tn_code_get_palette(uint32* colors, int32 count);

	/// The colours the code editor was last given, as 0xAABBGGRR (for tests).
	public static bool CodeEditorColors(ref uint32[CodeCount] colors) => tn_code_get_palette(&colors, CodeCount);

	/// At start-up, once the interface exists: the built-in and saved themes, the one last used (or `named`) and the
	/// code editor's own choice (or `codeNamed`).
	public static void Init(StringView named = "", StringView codeNamed = "")
	{
		DeleteContainerAndItems!(Themes);
		Themes = new .();
		AddBuiltIns();
		for (let theme in Themes)
			Put(theme);
		sReady = true;
		LoadUserThemes();
		let problems = scope String();
		let text = scope String();
		let wanted = named.IsEmpty ? null : Find(named);
		if (wanted != null)
			Current.CopyFrom(wanted);
		else if (File.ReadAllText(ActivePath(.. scope .()), text) case .Ok && Parse(text, Current, problems))
		{
			// Still the built-in or saved theme of that name if nothing was changed since.
			let source = Find(Current.name);
			// Saved before themes had code colours of their own: the theme's own, not Visual Studio's.
			if (source != null && !text.Contains("\ncode Keyword "))
			{
				Current.code = source.code;
				Current.extras[(int)ThemeColor.CodeBackground] = source.code[(int)CodeColor.Background];
			}
			Current.builtIn = source != null && source.builtIn && source.SameColors(Current);
			if (source != null)
				Current.path.Set(source.path);
		}
		else
			Current.CopyFrom(Find(DefaultTheme));
		if (!named.IsEmpty && wanted == null)
			Log.Warning(scope $"There is no theme called '{named}'.");
		CodeTheme.Clear();
		if (!codeNamed.IsEmpty)
		{
			if (Find(codeNamed) != null)
				CodeTheme.Set(Find(codeNamed).name);
			else
				Log.Warning(scope $"There is no theme called '{codeNamed}' for the code editor.");
		}
		else if (File.ReadAllText(CodeThemePath(.. scope .()), text..Clear()) case .Ok)
		{
			text.Trim();
			// A saved theme deleted since: the editor's theme again.
			if (Find(text) != null)
				CodeTheme.Set(text);
		}
		Apply();
	}

	/// Reads every `.ttheme` in the themes folder.
	public static void LoadUserThemes()
	{
		for (int i = Themes.Count - 1; i >= 0; i--)
		{
			if (!Themes[i].builtIn)
			{
				delete Themes[i];
				Themes.RemoveAt(i);
			}
		}
		let folder = Folder(.. scope .());
		if (!Directory.Exists(folder))
			return;
		let paths = scope List<String>();
		defer
		{
			ClearAndDeleteItems!(paths);
		}
		for (let entry in Directory.EnumerateFiles(folder, "*.ttheme"))
			paths.Add(entry.GetFilePath(.. new .()));
		paths.Sort((a, b) => a.CompareTo(b, true));
		for (let path in paths)
		{
			let text = scope String();
			if (File.ReadAllText(path, text) case .Err)
				continue;
			let theme = new Theme();
			let problems = scope String();
			if (!Parse(text, theme, problems))
				Log.Warning(scope $"{path}: {problems}");
			theme.path.Set(path);
			Themes.Add(theme);
			if (sReady)
				Put(theme);
		}
		if (sReady)
			Apply();
	}

	/// Whether the interface exists, so that themes can be filled in from it (not in tests without a window).
	static bool sReady;

	/// Puts a theme's colours into the interface, then fills the theme in with every colour the interface has (those
	/// it does not name come from ImGui's dark or light set), so that themes compare and save whole.
	static void Put(Theme theme)
	{
		ImGui.StyleColorsBase(theme.light);
		let count = ImGui.StyleColorCount;
		for (let entry in theme.colors)
		{
			for (int32 i < count)
			{
				if (ImGui.StyleColorName(i) == entry.name)
				{
					ImGui.SetStyleColor(i, entry.color);
					break;
				}
			}
		}
		for (int32 i < count)
			theme.Set(ImGui.StyleColorName(i), ImGui.GetStyleColor(i));
	}

	/// Puts the current theme into the interface and the editor's own colours.
	public static void Apply()
	{
		Put(Current);
		sExtras = Current.extras;
		sText = Current.Get("Text");
		sTextDim = Current.Get("TextDisabled");
		PutCode();
	}

	/// Changes one of the interface's colours, at once.
	public static void SetColor(int32 index, Color color)
	{
		ImGui.SetStyleColor(index, color);
		Current.Set(ImGui.StyleColorName(index), color);
		Current.builtIn = false;
		if (index == ImGui.Col.Text)
			sText = color;
		else if (index == ImGui.Col.TextDisabled)
			sTextDim = color;
	}

	public static void SetExtra(ThemeColor which, Color color)
	{
		Current.extras[(int)which] = color;
		Current.builtIn = false;
		sExtras = Current.extras;
		if (which == .CodeBackground)
			SetCode(.Background, color);
	}

	/// Changes one of the current theme's code colours, at once.
	public static void SetCode(CodeColor which, Color color)
	{
		Current.code[(int)which] = color;
		Current.builtIn = false;
		if (which == .Background)
		{
			Current.extras[(int)ThemeColor.CodeBackground] = color;
			sExtras = Current.extras;
		}
		PutCode();
	}

	/// Uses a theme from the list.
	public static void Select(Theme theme)
	{
		Current.CopyFrom(theme);
		Apply();
		SaveActive();
	}

	/// Remembers the theme in use (with its changes) for the next run.
	public static void SaveActive()
	{
		let text = scope String();
		Write(Current, text);
		File.WriteAllText(ActivePath(.. scope .()), text).IgnoreError();
	}

	/// Saves the theme in use under a name in the themes folder (replacing a saved theme of that name). Returns the
	/// saved theme, or null when it could not be written.
	public static Theme SaveAs(StringView name)
	{
		var trimmed = scope String(name)..Trim();
		if (trimmed.IsEmpty)
			return null;
		let builtIn = Find(trimmed);
		if (builtIn != null && builtIn.builtIn)
			trimmed.Append(" (mine)");
		let folder = Folder(.. scope .());
		Directory.CreateDirectory(folder).IgnoreError();
		let path = scope $"{folder}/{FileName(trimmed, .. scope .())}";
		Current.name.Set(trimmed);
		Current.builtIn = false;
		Current.path.Set(path);
		let text = scope String();
		Write(Current, text);
		if (File.WriteAllText(path, text) case .Err)
			return null;
		SaveActive();
		LoadUserThemes();
		return Find(trimmed);
	}

	/// Deletes a saved theme's file (built-in themes stay).
	public static bool Delete(Theme theme)
	{
		if (theme.builtIn || theme.path.IsEmpty)
			return false;
		File.Delete(theme.path).IgnoreError();
		let wasCode = theme.name == CodeTheme;
		LoadUserThemes();
		if (wasCode)
			SelectCodeTheme("");
		return true;
	}

	/// Reads a theme file from anywhere, copies it into the themes folder and uses it. Problems in the file are
	/// listed in `problems`; false when it could not be read at all.
	public static bool Import(StringView path, String problems)
	{
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err)
		{
			problems.AppendF("{} could not be read\n", path);
			return false;
		}
		let theme = scope Theme();
		Parse(text, theme, problems);
		Current.CopyFrom(theme);
		Apply();
		return SaveAs(theme.name) != null;
	}

	/// Writes the theme in use to a file anywhere, to share it.
	public static bool Export(StringView path)
	{
		let text = scope String();
		Write(Current, text);
		let folder = Path.GetDirectoryPath(path, .. scope .());
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		return File.WriteAllText(path, text) case .Ok;
	}
}
