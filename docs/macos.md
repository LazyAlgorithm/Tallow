# macOS

Tallow builds and runs on Macs with Apple silicon (M1 and later), macOS 12 or newer. It draws with Metal, which every such Mac has. A Mac builds macOS games and web games; Linux and Windows games are built on Linux (see `docs/windows.md`).

**How far it has been tested.** macOS builds are paused for now: the code stays, but `.github/workflows/macos.yml` no longer runs on pushes or tags, only by hand (Actions > macOS > Run workflow), and releases have no macOS zip. When run, it builds Tallow on a GitHub macOS runner: the Beef compiler from source, the native libraries, all the headless test fixtures (`tools/run_tests.py`; they all pass there), the packaged editor (kept as the run's `Tallow-macOS` download) and the Sandbox, which then draws two scenes with Metal (the run's `metal-pictures`). It has not yet been tried on a real Mac by a person, so expect to find things on the first try there, especially in the editor's windows and file dialogs.

## Setting up, once

Tools: the Xcode command line tools (`xcode-select --install`), and from Homebrew `brew install cmake ninja llvm@22 python@3.12`.

The Beef compiler, built from source (the same commit as `.github/workflows/macos.yml`'s `BEEF_COMMIT`):

```sh
git clone https://github.com/beefytech/Beef ~/beef
cd ~/beef/bin && PATH="$(brew --prefix llvm@22)/bin:$PATH" ./build.sh
export PATH="$HOME/beef/IDE/dist:$PATH"     # BeefBuild
```

The engine's native libraries (bgfx for Metal, SDL3, Jolt, ENet, Opus...), from the engine's folder:

```sh
python3 tools/patch_textedit.py
cmake -S native -B build/native -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++
cmake --build build/native --target tallow_native bgfx bimg bimg_decode bx SDL3-static joltc Jolt enet shaderc
```

Then `BeefBuild -platform=macOS` builds the editor (from the engine's folder) and any Tallow project, and `python3 tools/run_tests.py` runs the test fixtures.

## Link settings

A Beef project that uses Tallow needs its `[Configs.Debug.macOS]` and `[Configs.Release.macOS]` link settings: the engine's native archives and the system frameworks SDL and Metal use. `python3 tools/macos_link.py --write path/to/BeefProj.toml` adds them (for any number of projects), with the archives named from `$(WorkspaceDir)` so the file works on any machine. The engine's own projects, the Launcher, the Tests and the Sandbox already have them.

## Building a game for macOS

**File > Build...** in the editor on a Mac: **Game**, **macOS** and a folder. Or:

```sh
python3 tools/build_player.py /path/to/project --platform macos --output /path/to/folder
```

The folder holds the game's program, its assets, the Metal shaders and the licences: copy it to another Mac and run the program. A Steam game wants `libsteam_api.dylib` from the Steamworks SDK beside the project, as on Linux.

The program is not signed. A Mac that downloads it marks it as from the internet and refuses to open it; the player opens it once with right-click > Open, or runs `xattr -dr com.apple.quarantine <folder>`. Signing and notarising need an Apple Developer account and are not done by Tallow.

**File > Build... > Editor** packages Tallow itself for macOS (`tools/package_engine.py --platform macos`).

## Networking

Nothing changes: a Mac plays with and against Linux and Windows machines, as a client, a host or a dedicated server, over the same protocol. Physics runs with Jolt's cross-platform determinism on every system, so client-side physics prediction behaves the same on a Mac (Apple silicon is ARM; Jolt is built to give the same results there as on x64).

## Limits

- Script reload while playing (`docs/script-hot-reload.md`) is for Linux and Windows; on a Mac a script change needs Stop and Play.
- Built games are a plain folder with the program, not an `.app` bundle, and are not signed.
- The anti-cheat guard sees debuggers and injected libraries on macOS but cannot close the game's memory to other programs as it does on Linux.
- The Tallow Hub has no macOS build yet.
- Intel Macs are not built for.

## Tests

`.github/workflows/macos.yml` is the check: the whole engine and editor compile and link for macOS, all the fixtures in `Tests/README.md` pass there (the real-time networking ones get a second try, and Http, which asks GitHub's API without a token, is left out on the shared runners), the editor packages, and the Sandbox draws with Metal.
