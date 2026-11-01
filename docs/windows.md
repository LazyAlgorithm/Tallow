# Building for Windows

Tallow is developed on Linux, and builds Windows games, and a Windows copy of the editor, from there. No Windows machine is needed to build.

**How far it has been tested.** The Windows builds are made on Linux and run there under Wine: a packaged game starts, draws with Vulkan, plays a match and joins a server running the Linux build; the launcher and editor start, open a project, show its interface documents and play it. A built game has also been run on a Windows machine. The launcher and editor have not been run on one yet, so expect to find things on the first try there.

## Setting up, once

```sh
tools/windows/setup.sh --accept-license
```

This downloads about 3 GB into `~/.local/share/tallow-win` (or `$TALLOW_WIN`) and builds the engine's native libraries for Windows into `build/native-win`:

- Microsoft's C runtime and Windows SDK libraries, fetched with the `xwin` tool. They are Microsoft's, under the Microsoft Visual Studio Build Tools licence; `--accept-license` says you accept it. They are linked into what you build and are never copied into a package.
- The Windows release of the Beef compiler, which is run under Wine.
- The LLVM linker, if the system has none.

It needs `wine`, `clang` (with `clang-cl`), `llvm`, `cmake`, `ninja`, `curl` and `7z` installed. It is safe to run again; after changing anything in `native/` run it again to rebuild the Windows libraries.

## Building a game for Windows

**File > Build...** in the editor: choose **Game**, **Windows** and a folder. Or:

```sh
python3 tools/build_player.py /path/to/project --platform windows --output /path/to/folder
```

The folder gets `<Name>.exe`, the game's assets, the Vulkan shaders and the licences: copy it to a Windows machine and run the `.exe`. Nothing has to be installed there (the C runtime is linked in); the machine needs a graphics driver with Vulkan, which every current NVIDIA, AMD and Intel driver has. `--console` keeps a console window for log output, which a dedicated server wants. See `docs/standalone-player.md` for what the folder holds.

A Windows and a Linux build of the same game play together: the physics library is built for identical results on both.

## The editor on Windows

**File > Build...**, **Editor**, **Windows**, or:

```sh
python3 tools/package_engine.py --platform windows --folder /path/to/Tallow-Windows
```

The folder holds the launcher, the engine and editor source, the Windows native libraries and the tools. On the Windows machine start `Tallow.exe`. Every project compiles its own scripts together with the engine, so that machine needs:

- the Beef toolchain from beeflang.org, with `BeefBuild` on the PATH;
- Microsoft C++ Build Tools (Beef's installer says where to get them; they are free);
- Python 3.11 or later, as `python` on the PATH, for File > Build....

Differences from the Linux editor:

- Scripts are reloaded while the editor runs, as on Linux: save a script and it is compiled and swapped in with the scene, field values and Play state kept. See [Automatic script library reload](script-hot-reload) for what it covers and how it works on Windows. A project made with an earlier version needs **File > Full Rebuild & Restart** once, so that it is linked with the map of its symbols that reload uses.
- File > Build... builds Windows games only; Linux games and the editor packages are built on Linux.
- Steam needs `steam_api64.dll` from the Steamworks SDK beside the game (see `docs/steam.md`).

## How it works

| Part | On Linux | For Windows |
|---|---|---|
| Native libraries (bgfx, SDL, Jolt, ENet, miniaudio, Opus, Dear ImGui) | `build/native/*.a`, built by `build.sh` | `build/native-win/*.lib`, cross-compiled with clang-cl and `tools/windows/toolchain.cmake`, against the static C runtime |
| Beef code | `BeefBuild` | the Windows `BeefBuild.exe` under Wine with its LLVM toolset (Beef on Linux refuses Windows targets) |
| Link settings | `[Configs.*.Linux64]` | `[Configs.*.Win64]`, written beside them by the editor for every project |
| Graphics | Vulkan, OpenGL as fallback | Vulkan. bgfx would choose Direct3D, so the engine asks for Vulkan on Windows |
| Shader compiler for project shaders | `shaderc` | `shaderc.exe`, cross-compiled with the libraries |
| Running commands | `sh` | `cmd`; see `Editor/src/Project/Terminal.bf` |

## Not done

- **Direct3D.** Only Vulkan shaders are shipped. Direct3D bytecode needs Microsoft's shader compiler; compile with bgfx's `shaderc` on Windows into `Engine/assets/shaders/dx11` and remove the Vulkan default in `native/tallow_native.cpp` to use it.
- **The test fixtures** have Linux link settings only.
- **A real Windows machine.** File dialogs, audio output and the microphone, gamepads, high-DPI scaling and Steam there are untried.

## Opening projects from a Hub installation

Windows editor builds now quote both the Beef compiler executable and every native archive in generated project link flags. This is required for the Hub's `Tallow Hub` installation folder and Windows user/tool folders containing spaces. Earlier packages can fail with `lld-link: could not open .../Tallow` or a command-not-found error before compilation starts. Update the engine package through the Hub; reopening a project regenerates its Beef build files.

The launcher also supports `Tallow.exe --build-project <folder>` to compile a project without opening a graphics window. This applies the Hub toolchain and locates the installed engine, including when the project remembers an engine from another machine.

`tools/test_windows_project_open.py --package <Tallow-Windows> --beef <BeefBuild.exe>` copies the engine and compiler beneath folders with spaces, creates a project in another such folder, and checks engine relocation, a full debug build, and rebuilding. CI runs this against the packaged Windows editor before releasing it. On Linux add `--wine` and use the Windows compiler. These checks establish project compilation, not rendered editor behavior on Windows hardware.

Windows launchers and generated editor executables use the GUI subsystem, so starting the editor does not create an external command-prompt window. Compiler/build shells use `CreateNoWindow`; their output stays in the project build log and the editor's built-in Console remains available. Command-line launcher checks preserve redirected diagnostics and may attach to an existing caller console.

Engine CI starts on pushes to `dev` and `main`: both build platform packages and run the native Windows project-open regression. `main` publishes Windows/Linux ZIPs and checksums as a `build-` release in `LazyAlgorithm/Tallow`, which is the repository/tag prefix Tallow Hub checks for engine updates. `dev` retains packages as Actions artifacts. No Hub application release is needed for an engine-only update.

## Miniature dynamic worlds

`PhysicsWorld.LengthScale` now conditions body inertia calculations as well as contact tolerances. For small scales, body creation computes inertia with a larger temporary calculation mass, then restores the assigned physical mass and rescales inverse inertia before simulation. This avoids Jolt's near-zero inertia fallback to a one-metre sphere; contacts on toy aircraft can produce the expected rotation without artificial angular impulses. `Rigidbody.Sleep()` keeps authored resting props dynamic and wakes them through normal contacts or forces.

The `Tests/ShapeQueries` regression checks a 1 cm, 12 g cube against its analytical torque response and linear acceleration, plus sleep/wake behavior.

### Large collision meshes

Physics mesh conversion allocates its vertex buffer on the heap and frees it after Jolt builds the shape. Imported bedroom meshes exceeded the default 1 MB Windows stack; the previous stack allocation failed in `_chkstk` while loading the room. The ShapeQueries integration test now builds a 100,000-vertex mesh and checks its collision response; Linux and Windows under Wine pass with the normal stack reserve.
