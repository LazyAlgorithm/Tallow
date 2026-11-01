# Editor themes

The editor's colours come from a **theme**. Seven are built in, and any of them can be changed colour by colour, saved under a new name, and shared as a file. Each theme also has its own colours for the code editor (the Scripts tab).

| Theme | What it looks like | Its code |
|---|---|---|
| **Tallow Blue** | Deep blue-greys with a brighter blue accent. The default. | Blue keywords, teal types, warm strings on deep blue. |
| **Dark** | The editor's original look: neutral charcoal greys with a blue accent. | Visual Studio's dark colours (the code editor's original look). |
| **Light** | Pale greys and white fields with dark text, for bright rooms. | Visual Studio's light colours on white. |
| **High Contrast** | White text on black, bright edges and yellow highlights. All text reaches a contrast of at least 7:1 (WCAG AAA). | Bright colours on black, all at least 7:1. |
| **Forest** | Mossy greens with a leaf-green accent. | Leaf-green keywords, teal types, wheat strings. |
| **Ember** | Warm browns with an orange accent. | Orange keywords, gold types, olive strings. |
| **Plum** | Dusky purples with a violet accent. | Violet keywords, pink types, mint strings. |

Until a theme is picked, the editor uses Tallow Blue (`EditorTheme.DefaultTheme`).

## Preferences

**Edit > Preferences... > Theme**:

- **Theme**: click a theme to use it. The editor recolours at once, and the theme is remembered for next time.
- **Code editor**: which theme's code colours the Scripts tab uses. **Match the editor theme** (the default) gives each theme its own. Picking a theme here keeps its code colours whatever theme the rest of the editor uses, so you can have Forest panels with Light code, for example. Any saved theme can be picked too. The choice is remembered on its own (`code-theme.txt` in the config folder). If the saved theme it names is deleted, the code editor goes back to matching.
- **Colours**: every colour has a live picker, and changes show as you drag. **Editor colours** holds the colours the editor draws itself: the accent on toggled buttons (Move, Snap...), node canvases, warnings, errors, success and link text, the prefab bar, and the Hierarchy and Project icons. **Code colours** holds the theme's code editor colours: text, keywords, types, numbers, strings, comments, the background, selection, line numbers, brackets and the current line. **Interface colours** holds every colour ImGui has (window, text, buttons, fields, tabs, headers...). **Find a colour** narrows the lists. Code colours belong to the theme being edited. If the code editor is set to another theme, a note says so.
- A changed theme says so, and stays as you left it between runs. **Revert Changes** goes back to the theme as saved. **Save As** keeps it under a name. Using a built-in theme's name saves "Name (mine)", so the built-in theme stays as it is.
- **Delete** removes a saved theme. Built-in themes cannot be deleted.
- **Import** reads a `.ttheme` file from any path, copies it into the themes folder and uses it. **Export** writes the theme in use to any path (the project folder by default), so it can be shared.
- **Open Folder** opens the themes folder.

Themes belong to the person using the editor, not to the project. They live in the editor's config folder (`~/.local/share/Tallow/Editor` on Linux, `%APPDATA%\Tallow\Editor` on Windows, `~/Library/Application Support/Tallow/Editor` on macOS): saved themes in `themes/`, and the theme in use, with any changes, in `theme.ttheme`.

## Theme files

A `.ttheme` file is plain text, one setting per line:

```
# Tallow editor theme (docs/themes.md)
name "Sunset"
base dark
editor Accent 0.9 0.4 0.1 1
editor Warning 1 0.75 0.33 1
color WindowBg 0.3 0.1 0.1 1
color Text 1 0.9 0.8 1
code Keyword 1 0.6 0.3 1
code Background 0.12 0.08 0.08 1
```

| Line | Meaning |
|---|---|
| `name "..."` | The theme's name. |
| `base dark` or `light` | Which of ImGui's colour sets the theme starts from. |
| `code <Name> r g b [a]` | One of the code editor's colours: Text, Keyword, Declaration (types), Number, String, Punctuation, Preprocessor, Identifier, KnownIdentifier (names from the engine and project), Comment, Background, Cursor, Selection, Whitespace, BracketBackground, BracketActive, Bracket1, Bracket2, Bracket3, BracketError, LineNumber, CurrentLineNumber, CurrentLine, CurrentLineBorder. The Background is also the editor colour CodeBackground. |
| `code dark` or `light` | In files saved before themes had code colours: Visual Studio's dark or light set. A saved "theme in use" naming a built-in theme takes that theme's own code colours instead. |
| `editor <Name> r g b [a]` | One of the editor's colours: Accent, Canvas, CanvasText, CodeBackground, Warning, Error, Good, Info, Prefab, Folder, Object, Component. |
| `color <Name> r g b [a]` | One of the interface's colours, by ImGui's name (`WindowBg`, `Text`, `Button`, `FrameBg`, `Header`, `Tab`...). |

Values run from 0 to 1 (anything outside is clamped), and alpha is 1 if left out. Lines starting with `#` are comments. A file only needs the colours it changes: the rest come from the Dark theme. Lines that cannot be read are reported by line number, and the rest of the file still counts. An exported theme lists every colour.

## Switches

- `--theme <name>`: use a theme (built-in or saved) for this run.
- `--code-theme <name>`: give the code editor that theme's code colours for this run.
- `--preferences`: open the Preferences window at start-up.
- `--theme-test`: applies each built-in theme to the real interface, checks the colours the code editor is given (each theme's own, one picked for code alone, kept over a restart, and back to matching when that theme is deleted), changes colours live, restarts the themes, and saves, exports, imports and deletes a theme in a folder of its own (your themes are left alone), then logs `THEME-TEST PASS` or `FAIL`.

## In code

Editor code that draws its own colours uses `EditorTheme`, so they follow the theme:

```beef
ImGui.TextColored(EditorTheme.Warning, "Unsaved changes");
ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
ImGui.DrawText(pos, EditorTheme.Text, label.CStr());
```

`EditorTheme.Text` and `TextDim` are the interface's text colours, for text drawn by hand on a panel. Text drawn over the 3D view or on dark node bodies keeps fixed colours, since what is behind it does not change with the theme.

## Tests

- `Tests/Themes` (CPU, in `tools/run_tests.py`): all seven built-in themes are there with Tallow Blue first; text in every built-in theme is readable on every surface it is drawn on (contrast at least 4.5, and 7 for High Contrast), as are quiet text, warnings, errors and canvas text. Each theme's code reads on its code background and current line (4.5, 7 for High Contrast), as do comments (3) and line numbers. Every theme's code colours are its own. Dark's and Light's code are Visual Studio's sets. Code colours read back from files, and older files with `code dark`/`light` still read. Also checks that Dark matches the editor's old look, that files read back as written, that mistakes are reported by line while the rest still reads, that values are clamped, and that file names are safe.
- `--theme-test` in the editor (above).
