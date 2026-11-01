# Building Tallow from source

The repository contains the engine, editor, templates and vendored dependencies. Build output goes under `build/`; do not copy someone else's CMake cache into a checkout. The checkout may live anywhere, including a path with spaces. Use an x64 compiler/toolchain. The first CMake configure fetches the pinned Jolt Physics source, so it needs Git and an internet connection.

## Linux x64

Install Python 3.11+, CMake 3.20+, Ninja, a C/C++20 compiler, the Beef compiler and development libraries for X11/OpenGL and audio. On Ubuntu 24.04:

```sh
sudo apt-get update
sudo apt-get install build-essential cmake ninja-build python3 git libx11-dev libxext-dev libxi-dev libxfixes-dev libxcursor-dev libxrandr-dev libxss-dev libxrender-dev libgl-dev libegl-dev libasound2-dev libpulse-dev libwayland-dev libxkbcommon-dev
```

Ubuntu 22.04 also works, but its default Python is 3.10: install Python 3.11+ separately and set `PYTHON` to that executable. Other distributions need equivalent packages. Install the Linux Beef toolchain from [Beef](https://www.beeflang.org/) or build the compiler revision in `tools/toolchain.txt`; its shared-library dependencies must also be installed. Put `BeefBuild` on `PATH`, or set `BEEFBUILD` to the compiler executable/wrapper. LLVM 22 tools enable LLVM/ThinLTO; Beef can fall back to GNU linking when they are absent.

For a prebuilt Linux compiler, The project's toolchain release provides the same compiler bundle used by Hub. This installs it in your user folder:

```sh
mkdir -p "$HOME/.local/share/TesseraBuildTools"
curl -fL https://github.com/LazyAlgorithm/Tessera/releases/download/toolchain-2/beef-linux-x64.tar.gz -o /tmp/tessera-beef.tar.gz
tar -xzf /tmp/tessera-beef.tar.gz -C "$HOME/.local/share/TesseraBuildTools"
export BEEFBUILD="$HOME/.local/share/TesseraBuildTools/beef/IDE/dist/BeefBuild.sh"
```

```sh
git clone https://github.com/LazyAlgorithm/Tessera.git
cd Tessera
# Repository URL and directory retain their original names until the GitHub repository is renamed.
./build.sh --config Debug --jobs 8
./build/Debug_Linux64/TallowLauncher/TallowLauncher
```

`build.sh` uses Python 3 by default; `PYTHON=/path/to/python3.12 ./build.sh` selects another interpreter. You can call `python3 tools/build.py` directly. The build patches the vendored text editor, compiles the native libraries/tools, compiles the shipped shader backends, collects licenses and builds the launcher. A Vulkan-capable graphics driver is required to run the editor; headless project creation/compilation does not need a display.

## Windows x64 (build on Windows)

Install:

- Git, Python 3.11+, CMake 3.20+ and Ninja, available on `PATH`.
- The Windows Beef toolchain from [Beef](https://www.beeflang.org/), with `BeefBuild.exe` on `PATH` or `BEEFBUILD` set to its full path.
- Visual Studio 2022 Build Tools, **Desktop development with C++**, including the x64 MSVC libraries and Windows SDK. Beef must be configured to find these libraries (its installer normally handles this).
- LLVM with `clang-cl.exe` on `PATH` (the Visual Studio C++ Clang tools component or the official LLVM installation).

Open an **x64 Native Tools Command Prompt for VS 2022** so the MSVC/SDK include and library environment is set, then:

```bat
git clone https://github.com/LazyAlgorithm/Tessera.git
cd Tessera
python tools/build.py --config Debug --jobs 8
build\Debug_Win64\TallowLauncher\TallowLauncher.exe
```

From a Visual Studio developer PowerShell you can instead run `./build.ps1 --config Debug --jobs 8`. No Bash, Wine, Linux checkout or developer-specific folders are needed on Windows. The native C runtime is static (`MultiThreaded`) to match Beef. Windows uses Vulkan; Direct3D is not a supported default backend.

For Windows cross-builds **on Linux**, the separate `tools/windows/setup.sh --accept-license` prepares Wine, xwin and the native Windows archives. See [Windows](windows.md). This is optional and is not the native Windows source-build procedure above.

## Create, open and package a project

Run the launcher to create a project, or use its display-free commands. Replace `LAUNCHER` with the path printed by the build:

```text
LAUNCHER --create /path/to/MyCampus --showcase
LAUNCHER --build-project /path/to/MyCampus
LAUNCHER --open /path/to/MyCampus
```

Use quoted Windows paths such as `"C:\Projects With Spaces\MyCampus"`. The bundled Sandbox is also available via `LAUNCHER --open Samples/Sandbox`; its engine reference is resolved relative to the sample folder.

To make Release engine packages:

```text
python tools/build.py --config Release
python tools/package_engine.py --platform windows --folder dist/Tallow-Windows
```

On Linux select `--platform linux`, and use `python3` if that is your Python 3.11+ command. Packaging rebuilds the launcher and includes source, templates, shaderc and native archives. Building a game uses `tools/build_player.py PROJECT --output OUTPUT`; first open/build that project in the launcher to generate its Beef build files.

## Tests and repeated builds

```text
python tools/run_tests.py Quality Water ShapeQueries
python tools/audit_portability.py
```

Fixtures resolve native archives from their own workspace relative to the repository root. Linux/macOS archive paths and Windows archive paths are quoted for spaces; Windows fixture workspaces select LLVM. Some tests need graphics, audio devices, a network connection or platform-specific integrations; building the engine is not a claim that every integration has been exercised on all hardware.

`--skip-native` and `--skip-shaders` are explicit options for already-built checkouts. Leave them off for the first build. A failed launcher rebuild restores the previous executable. Delete/reconfigure a build directory when changing native toolchains rather than moving a CMake cache between machines.
