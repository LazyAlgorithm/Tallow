# Rapier3D (prebuilt C bindings)

Rapier's official C bindings (`bindings/c` in `dimforge/rapier`), pinned by `VERSION` and shipped as a static
archive so normal Tallow builds do not need Rust. Rust is a maintainer/CI tool only.

| | |
|---|---|
| Version | 0.36.1+c.0 |
| Source | `dimforge/rapier` @ `475caa3ff4646fd9a796b67d14116256f4962bc7` |
| Build | 3D, f32, static, `enhanced-determinism`, SIMD 4 lanes, parallel on (rayon), fat LTO, 1 codegen unit |
| Source changes | Rapier itself: none (stock, so comparisons with Jolt are out of the box). C bindings: `bindings-changes/*.patch` |
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

## Bindings changes

`tools/build_rapier.py` applies `bindings-changes/*.patch` in name order after checking out the pinned commit and
refuses any patch that touches files outside `bindings/c/`: the physics engine is never modified, only the C API
Tallow calls it through. They change no simulation results (the determinism hashes below are checked with them).

- `0001-query-refresh-and-contact-summaries.patch`
  - `r3RefreshQueriesForBodies`: after Tallow moves, teleports or creates bodies, pushes their poses to their
    colliders and refits those colliders' query-tree boxes (`propagate_modified_body_positions_to_colliders`,
    `BroadPhaseBvh::set_aabb`, both public Rapier API). Stock bindings only offer `r3DetectCollisions`, a whole
    collision-detection pass, before every query that follows a teleport.
  - `r3ActiveContactSummaries`: every touching pair with ids, sensor flags, resting state and the strongest contact's
    point, normal and speed in one read-only call, instead of four locked calls per contact event.

## Threads

The archives are built with Rapier's `parallel` feature (`--serial` builds without it). Every world steps on
rayon's global pool, sized from `RAYON_NUM_THREADS` when it starts; `native/tallow_rapier.cpp` sets it to 4 when
the environment has no value (Jolt uses 3 workers plus the stepping thread; past about 8 threads the step gets
slower again). Results are bit-identical at any thread count and on Linux and Windows: `--test-physics-rapier`
(PHYSICS STATEHASH) and `--bench-physics Rapier 6000 128` (BENCH STATEHASH) printed the same hashes at 1, 2, 4,
8, 16 and 24 threads on Linux and at 1, 4 and 16 under Wine (2026-11-23), and match the serial build. Re-run that
check whenever the pinned commit changes, since lockstep relies on it.
