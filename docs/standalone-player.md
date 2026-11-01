# Standalone players

The Tallow engine library contains `GameMain` and `GameApp`: command-line game startup, manifest loading, scene loading, fixed ticks, camera rendering, component GUI and shutdown. They reference no TallowEditor types. EditorMain's development player derives from GameApp and retains editor-only first-run scene templates. Engine and editor share the runtime implementation through the existing Tallow library; the shipping player statically links it. There is no shared runtime DLL or reloadable script module yet.

## Building

**File > Build...** opens the Build window:

- **Build**: the **Game**, or the **Editor** (a copy of Tallow itself for another machine; see `README.md` and `docs/windows.md`).
- **For**: **Linux** or **Windows**. Windows needs a one-time setup, which the window describes; see `docs/windows.md`.
- **Window**: **Start in fullscreen** makes the built game fill the screen when it starts; unticked, it starts in a window. Kept in the project.
- **Assets**: **Pack assets into one file** (on unless you turn it off) puts everything the game reads into `game.tpak`; see Asset packs below. Kept in the project.
- **Folder**: type one or press **Choose...** for the desktop's folder dialog. The choice is remembered for the project.

**Build** puts the game in `<folder>/<Name>-Linux` or `<folder>/<Name>-Windows`. That folder holds everything the game needs and nothing else: move it anywhere, or send it to somebody, and it runs. An earlier build of the game in the same place is replaced; a folder that is anything else is left alone. The editor does not respond while it builds (about a minute); errors appear in the window and the Console. **Show Folder** opens the result. The editor needs Python 3.11+ for this.

The same from a terminal:

```sh
python3 tools/build_player.py /path/to/project --output /path/to/folder
python3 tools/build_player.py /path/to/project --platform windows --output /path/to/folder
```

`--output` is the game's own folder and must not exist, unless `--replace` is given and it is an earlier build. `--fullscreen` and `--windowed` override the project's Start in fullscreen setting, and `--loose` leaves the assets as loose files. `--console` (Windows) keeps a console window.

The tool builds a temporary Beef workspace with TallowEditor removed from dependencies, replaces Program.bf with a GameMain entry point, copies all other runtime scripts, and rejects scripts that reference Tallow.Editor. Graph-generated Beef scripts are included; graph source assets are not shipped. On Linux, additional libraries and native link settings come from the project's existing build files. Existing GameSetup.Register calls are detected; projects with other custom registration should pass --bootstrap Namespace.Type.Method. Custom Program startup logic must be moved into runtime bootstrap code before export.

What is in the folder:
- the executable (`<Name>`, or `<Name>.exe`)
- `game.tpak`: the asset pack. It holds the project's content (without Beef source, graphs, scripts for tools or hidden files), the engine's compiled shaders for the graphics backends the game can start on (Vulkan; and OpenGL on Linux), and the game's manifest (name, start scene, whether to start fullscreen, Steam and audio settings)
- THIRD_PARTY_LICENSES.txt: the licences of the libraries in the executable, which ask to be distributed with it
- with a Steam App ID in Project Settings: `steam_appid.txt` and the Steamworks library (`libsteam_api.so` or `steam_api64.dll`), taken from the project folder if it has one, else from a Steam installation on this machine

With **Pack assets into one file** unticked (or `--loose`), the pack is replaced by what would have been in it: `game.tallow`, `Assets/` and `Engine/assets/shaders/`.

Three more project settings shape a built game's window, set in `project.tallow` (they have no editor field yet, as few games need them): `windowWidth` and `windowHeight` give the window's size in points when it starts in a window (otherwise 1600 by 900), and `escapeQuits = 0` stops Escape from closing the game, for a game or tool with its own way out. A game's own way out calls `Application.Quit()` (or sets `Application.Instance.Running = false`): it closes a built game, and only stops Play in the editor. Tallow Hub, itself a Tallow project, uses all three.

The player finds this package beside its executable, independent of working directory. --game overrides the package folder. --scene overrides the start scene. Application's renderer/headless/frame-limit options and network startup options remain available. --editor is rejected. A Linux build needs the system's graphics and X11 libraries, which every desktop has; a Windows build needs a Vulkan graphics driver and nothing else. ImGui remains a runtime dependency for component GUI; TallowEditor panels/tools are excluded.

Checked with a full game (Ringfall): both builds were moved to another folder and started from a different working directory; the Windows build was run under Wine.

## Asset packs

A built game keeps its assets in one file, `game.tpak`, instead of folders of scenes, models, sounds and images that anyone can open and change. The game mounts the pack when it starts and everything the engine loads comes out of it: scenes, prefabs, materials, shaders, models, textures, sounds (also streamed music), UI documents, animations, behaviour trees, navigation data. In the editor, and in a build made with loose files, the same code reads the files from disk, so nothing changes while developing.

What the pack does and does not do:

- Files are compressed and scrambled, so they cannot be opened, played or edited with ordinary tools, and their contents cannot be found by searching the file.
- Each file carries a checksum. If the pack is edited anyway, the changed file is refused and does not load; a loose file placed beside the pack is not accepted in its place.
- It is **not encryption**. The key is in every copy of the game, so someone determined can still take the pack apart. It keeps honest players honest and assets out of plain sight.

### Compression

**Compress the pack** in the Build window (on unless you turn it off; `--no-compress` from a terminal) deflates each file that gets smaller for it. Files that are already compressed (`.png`, `.jpg`, `.ogg`, `.mp3`, `.flac`) are stored as they are.

- **Size.** Uncompressed sound (`.wav`) shrinks by about a third, models and text files (scenes, prefabs, UI) to a tenth or less. A game that is mostly PNG textures and OGG music gains little.
- **Loading.** A compressed file is read whole and inflated when it is first loaded, at a few hundred megabytes a second on one core; the smaller read from disk pays some of that back. For the sample shooter (17 MB of assets, 10 MB packed) start-up took the same time packed and loose, to within a few hundredths of a second. A game with gigabytes of assets would add roughly a second of unpacking per few hundred megabytes loaded, spread over its loading screens.
- **While playing.** Nothing: files are unpacked when loaded, not while in use. The frame rate is the same.
- **Memory.** While one file is loading, its packed and unpacked bytes are both in memory for a moment. Streamed music is the exception to know about: from a pack (compressed or not) a streamed sound's file is held in memory whole while it plays, where a loose file is read from disk a piece at a time. An OGG track is a few megabytes; hours of uncompressed audio would be worth keeping as loose files or as OGG.

Turning compression off keeps the scrambling and the checksums; it only saves the unpacking.

### A pack for each scene

**A pack for each scene** in the Build window (on unless you turn it off; `--single-pack` from a terminal, or `packSplit = 0` in `project.tallow`) gives each scene the files that only it uses in a pack of its own beside `game.tpak`: `scene-foundry.tpak` for `Scenes/Foundry.tscene`, say. Everything else, including whatever two scenes share, the start scene and what it uses, the engine's shaders and the manifest, stays in `game.tpak`.

- **Updates.** Packs come out byte for byte the same from the same files, so changing one map rewrites that map's pack and nothing else. A store that patches by file, or by changed parts of a file (Steam does both), sends players only that.
- **Loading.** The game mounts every pack at start. Only each pack's list of files is read, a few kilobytes, so starting takes no longer than with one pack; files are read from whichever pack holds them, as before.
- **In a browser** the page downloads `game.tpak`, starts the game, and fetches the scene packs in the background, smallest first. `SceneManager.Load` waits for a scene's pack by itself. Code that adds a scene with `LoadAdditive` checks `AssetPack.SceneReady(path)` first and calls `AssetPack.Request(path)` to have that pack fetched next; `AssetPack.Waiting` is how many packs have not arrived.

What a scene uses is found by reading it: the prefabs, models, materials, sounds and documents it names, what those name in turn, and files beside the scene with its name (a terrain's `.voxels`). Paths written in scripts as text (`"Audio/ui_click.wav"`) are found too, and go into `game.tpak`. A path a script puts together while running (`$"Models/prop_{kind}.glb"`) cannot be found by reading, so list those files under **Always shared** in the Build window (`packShared = Models/prop_*.glb; Audio/*` in `project.tallow`, wildcards separated by semicolons). A scene's pack is only made when its own files come to 64 KB or more; smaller ones stay in `game.tpak`.

Game code that reads its own data files should go through the engine, so that it works packed and loose:

```beef
let text = scope String();
if (Assets.ReadText("Data/levels.txt", text)) { /* ... */ }

let bytes = scope List<uint8>();
Assets.ReadBytes("Data/table.bin", bytes);
if (Assets.FileExists("Data/extra.txt")) { /* ... */ }
```

| | |
|---|---|
| `Assets.ReadText(path, text)`, `Assets.ReadBytes(path, data)`, `Assets.FileExists(path)` | A project file by its asset path: packed in a built game, from disk otherwise. |
| `AssetPack.Mounted`, `AssetPack.FileCount` | Whether the game is running from a pack. |
| `AssetPack.FilesIn(folder, paths)` | The packed files in a folder, for code that would have listed a folder on disk. |
| `AssetPack.Mount(packFile, root)` | Mounts another pack (downloadable content, say): its files appear inside `root`. |
| `AssetPack.SceneReady(path)`, `AssetPack.Request(path)`, `AssetPack.Waiting` | In a browser: whether a scene's pack has downloaded, fetch it next, and how many are still coming. Always ready elsewhere. |

Reading a file directly with `File.ReadAllText` only finds loose files. Files the game *writes* (saves, settings) belong in the player's own folder, not among the assets. Folders added with `Assets.AddSearchPath` (mods, Workshop items) stay loose and are still found first.

`tools/pack_assets.py --list game.tpak` shows what a pack holds, and `--verify` checks every file in it. The format is described at the top of `native/tallow_pack.c`.

## Fullscreen

A built game starts fullscreen (borderless, at the desktop's resolution) or in a window as **Start in fullscreen** in the Build window says. Starting it with `--fullscreen` or `--windowed` overrides that for one run.

To let the player switch, set `GameWindow.Fullscreen` from your settings menu; it changes at once:

```beef
// A toggle in a UI document: <toggle id="fullscreen" onchange="OnFullscreen" />
public void OnFullscreen(UIElement source)
{
    GameWindow.Fullscreen = source.value > 0.5f;
    // ...and save the choice with the game's other settings.
}

// When the game starts, before or after the window opens: only if the player has chosen.
if (playerHasChosen)
    GameWindow.Fullscreen = savedChoice;
```

| | |
|---|---|
| `GameWindow.Fullscreen` | Whether the window fills the screen. Set it to switch. |
| `GameWindow.ToggleFullscreen()` | Flips it, for a key such as F11. |
| `GameWindow.StartsFullscreen` | How this build was set to start (or what the command line asked for). |

Leave `GameWindow.Fullscreen` alone until the player has made a choice and the build's setting stays the default; set it at start-up from a saved choice and the window opens that way with no flicker. In the editor the game is drawn in the Game view, so the value is remembered and nothing else happens; the same on a server with no window.

## Asset discovery

ProjectFolderMonitor checks recursive folder metadata once per second, independent of Project panel visibility. It compares sorted path/size/UTC-write-tick snapshots and refreshes Project and subgraph definitions only when something changes. Hidden folders/files are ignored, and recursion is bounded at 32 levels. Deletions clear stale selections and reset a removed browsing folder to the asset root. This is a main-thread polling implementation; very large asset trees may warrant an incremental/background implementation. It discovers files, but does not replace cached assets or loaded script types.

## Script reload

Shipping games exclude TallowEditor and use static game scripts. Linux x86-64 Debug editors separately support automatic script-library reload, including supported field changes and new components; see script-hot-reload.md. Baked navigation runs in the engine without editor dependencies.
