# Rapier3D (prebuilt C bindings)

Rapier's official C bindings (`bindings/c` in `dimforge/rapier`), pinned by `VERSION` and shipped as a static
archive so normal Tallow builds do not need Rust. Rust is a maintainer/CI tool only.

| | |
|---|---|
| Version | 0.36.1+c.0 |
| Source | `dimforge/rapier` @ `475caa3ff4646fd9a796b67d14116256f4962bc7` |
| Build | 3D, f32, static, `enhanced-determinism`, SIMD 4 lanes, parallel off |
| Files | `prebuilt/<platform>/librapier3d_ffi.a`, `include/rapier.h` (and its helpers) |

The archives themselves are not committed (51 MB each). Keep one locally under `prebuilt/<platform>/` for
development, or attach them to an engine release and have CI fetch them; the headers and the license are.

Build or refresh an archive with:

```sh
python3 tools/build_rapier.py --platform linux
```

The script clones the pinned commit into a cache folder, runs the bindings' CMake cargo target, and copies the
archive and headers into `prebuilt/<platform>/` (`linux`, `windows`, `macos`). The web variants still need a cross-compiled archive with Emscripten before Rapier is offered there. Every
platform the engine ships for must have one before the provider is offered; a missing archive keeps the Rapier
provider unlisted, never a link error.

Tallow links the archive only when its build enables Rapier (`TALLOW_RAPIER=ON`) and compiles
`native/tallow_rapier.cpp` against these headers. See `docs/modular-systems-plan.md` section 5.

## Windows archive

`tools/build_rapier.py --platform windows` cross-builds the MSVC archive on Linux. It adds Rust's
`x86_64-pc-windows-msvc` target and builds with the engine's Windows toolchain (`TALLOW_WIN`, default
`~/.local/share/tessera-win`):

- `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=<tool>/bin/lld-link`
- `LIB` and `-C link-arg=/LIBPATH:` pointing at `<tool>/xwin/{crt/lib,sdk/lib/um,sdk/lib/ucrt}/x86_64`

The produced `rapier3d_ffi.lib` is copied to `prebuilt/windows-x86_64/` (gitignored). Programs linking it also need
Rust std's Windows imports: `userenv.lib ntdll.lib bcrypt.lib synchronization.lib` (the engine's launcher, player,
generated project link flags and `tools/build_player.py` list them).

## Determinism

Archives are built with `enhanced-determinism`, SIMD 4 lanes and parallel off. The Linux and Windows x86_64 builds
produce the same fixed-scene state hash (the engine's `--test-physics-rapier` prints `PHYSICS STATEHASH`), which is
what the provider's `CrossPlatformDeterminism` capability and lockstep networking are gated on.
