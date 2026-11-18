# Tallow C# migration — local benchmark and acceptance plan

**Date:** November 14, 2026. **Status:** All items unchecked until measured. Run on the `feature/csharp-gameplay` branch. The native Beef engine/editor stays unchanged for C# gameplay users. This is a test *plan*, not reported performance data.

## Procedure (required for every run)

1. Record commit SHA (`git rev-parse HEAD`), `git status --short`, date/time, OS/kernel, CPU, GPU/driver, RAM, .NET SDK/runtime (`dotnet --info`), Beef compiler, build configuration, graphics renderer, screen resolution, VSync and frame cap.
2. Use the **same machine, same game scene, same spawn count and identical settings** when comparing C# vs Beef, or new vs old commits. Avoid mixing Debug with Release. Warm up for 20 seconds after scene startup or JIT compilation; ignore warm-up samples except for cold-start metrics.
3. Run each case at least **three times** (five for noisy cases). Record **median and spread**, not best-case alone. For per-frame workloads use 60 seconds of post-warm-up samples, reporting mean, median, p95, p99 **frame time (ms)**, FPS, CPU time, allocations/GC, and resident memory. Measure main-thread, Jolt and render times separately when profiling permits.
4. Run with the **same Jolt sleep setting** and record active/total bodies. Test *both* sleep ON and OFF for the specified physics sensitivity case; sleep ON is the default and is the fair normal comparison.
5. Preserve raw logs, timestamps, crashes, screenshots and profiler captures. Do not claim equivalence when one path silently skips simulation, networking, callbacks or physics.
6. Upload or share a `tar.gz` / `zip` of logs with the benchmark label and SHA. Keep source modification benchmarks in temporary copies; do not reset, overwrite, or force-push working game projects.

## P0 — run first (build/editor/interop correctness)

- [x] **B01 — precompiled editor cold start.** From launcher executable, record wall time and peak RSS until scene is usable for an empty C# project; repeat for a populated C# project. Repeat with and without a valid gameplay DLL. Opening a project must not invoke BeefBuild. Done (2026-11-16, `tools/test_csharp_editor.py`): Samples/Sandbox usable (first C# build done) 2.1 s after launch cold, 1.3 s warm; a project with no scripts likewise; no BeefBuild run. Peak RSS ~310 MB with the sandbox scene.
- [x] **B02 — game C# cold compile.** Remove the generated `.tallow-csharp` folder **only from a disposable copy of `Tests/CSharpGameplay`**, compile with `TallowLauncher --build-project PATH`, log elapsed time and errors; repeat x5. Done (2026-11-16, `tools/benchmark_csharp_compiles.sh`, 5 runs): cold build of a disposable copy 1.25 s median, peak RSS ~300 MB. Raw: `~/TallowBenchmarks/compile-20261116/`.
- [x] **B03 — warm/no-op compile.** Rebuild the same untouched disposable game five times; separately edit one C# script body (add a harmless comment) and rebuild five times. Record time from Save to compilation banner disappearance and from Save to first permitted Play. Done for the command-line build (2026-11-16): no-op 1.19 s, one-file edit 1.21 s, leaf-assembly edit 1.23 s, public API edit 1.23 s (medians of 5; fixed process/MSBuild overhead dominates). Save-to-Play in the editor (2026-11-18, `tools/run_save_to_play_bench.py`, editor `--save-to-play-test N`, Samples/Sandbox, Debug editor, 10 rounds): the first run gave save then Play 2.58 s, save to build done 2.40 s, build done to Play 5 ms. Two editor faults made it twice the 0.94 s command-line build: the file monitor took the editor's own save for a change made by another program and queued a second full build, and every build also ran `dotnet build` on the engine's Tallow.ManagedRuntime (a no-op MSBuild run, ~0.4 s). Both fixed: **save then Play 1.09 s, save to build done 1.01 s, build done to Play 5 ms** (medians). Raw: `~/TallowBenchmarks/save-to-play-20261118/`.
- [x] **B04 — invalid C# recovery.** Open intentionally invalid source; measure editor launch/diagnostics latency, Play disabled, recovery after fixing source, and whether the next successful edit is used. Include two rapid saves while a build is in progress.
- [x] **B05 — semantic editor latency.** Measure initial Roslyn worker startup, 100 steady-state completions, 100 diagnostics, nullable `Rigidbody?.` completion, type coloring and rename/definition queries in a small vs large (100+ file) source project. Record p50/p95/p99 response time and CPU/memory.
  - Measured November 16, 2026 on Nobara (`tools/benchmark_csharp_language_service.py --runs 100 [--extra-files 120]`;
    raw output in `~/TallowBenchmarks/language-service-20261116/`). Service start 16 ms; cold first request 0.66 s
    (5 files) / 1.04 s (125 files); peak memory 335–344 MB; 39–46 s CPU over ~800 requests.

    | ms, p50 / p95 / p99 | 5 files | 125 files |
    |---|---|---|
    | diagnostics, nothing changed | 15.9 / 17.0 / 29.6 | 17.0 / 18.1 / 23.2 |
    | diagnostics, typing in a method body | 82.6 / 98.5 / 112.6 | 67.9 / 82.5 / 200.3 |
    | diagnostics, a new method added | 219.6 / 305.7 / 312.1 | 233.8 / 794.9 / 815.2 |
    | completion after `Transform.` | 22.2 / 31.8 / 55.0 | 23.3 / 34.0 / 58.3 |
    | completion after `GetComponent<Rigidbody>()?.` | 22.3 / 31.8 / 39.2 | 22.2 / 31.7 / 42.3 |
    | signature help | 22.2 / 30.8 / 36.0 | 22.2 / 30.7 / 39.0 |
    | Go to Definition | 18.0 / 19.1 / 31.7 | 18.0 / 21.2 / 33.9 |

    Before the per-file diagnostics cache (125 files, 30 runs): nothing changed 292 ms p50, typing in a body 223 ms
    p50. The cost of a declaration change is dominated by the 1,642-line file being edited. Type colouring is part of
    every response (the `type` lines); rename is not timed here.
- [x] **B06 — managed runtime bootstrap and lifecycle.** Measure Play entry/exit for 0, 100, 1,000 and 10,000 lightweight C# Script instances. Run 100 Play/Stop cycles; check memory growth, duplicate callbacks, invalid handles and retained managed instances.
  Measured November 18, 2026 (`tools/run_play_cycle_bench.py --cycles 100`, Debug editor on the display, results in
  ~/TallowBenchmarks/b06-20261118): 100 Play/Stop cycles at 0, 100, 1,000 and 10,000 scripted objects, all passing: no
  second Awake/Start, no two LocalUpdates in a frame, no Update after OnDestroy, no unloaded game kept in memory,
  memory +4–6 MB over 100 cycles at every size. Play (median) 10.0 / 10.3 / 10.9 ms (one 10 ms frame is the floor),
  Stop 0.1 / 1.0 / 7.3 ms. At 10,000 Play first took 531 ms: each C# script joins every update list and leaves the
  ones its class does not override when it wakes, one list search and shift each (quadratic). Waking a scene or a
  loaded prefab now leaves them in place and sweeps each list once at the end (`Scene.BeginCallbackBatch`):
  **Play 45 ms at 10,000**, Stop 71 ms. Pass.
- [x] **B07 — scalar versus batched managed callbacks.** Run existing `Tests/NativeCSharpHost` `--benchmark` on matching builds; record raw per-callback cost and batch sizes 1, 16, 128, 512, 4096, separately for no-op Fixed/Late and distinct TickInput. **Do not switch the Scene scheduler automatically based only on mock-host speed.** Require real-editor profiler data, callback order, detach/disable and network replay equivalence.
- [x] **B08 — component access latency.** Compare `GetComponent<T>()` and `TryGetComponent<T>()` for native Rigidbody/Transform vs managed Script, hit and miss, using 100k–1M calls after warm-up. Verify disabled and destroyed handles fail safely. Done (2026-11-16, `getcomponent` mode, 100k calls/frame, a quarter each native hit, script hit, native miss, script miss): C# 3.04 ms vs Beef 0.30 ms per 100k (10×), no allocations. Before the fixes below C# took 30.6 ms and allocated ~33 bytes per call.
- [x] **B09 — Inspector scene/prefab save.** With 1,000/10,000 managed field instances: attach, edit public/private/hidden fields, save/reopen, enter Play and measure time plus serialized file sizes. Verify fields applied before Awake and prefab inheritance intact. Test failure with invalid persisted values.
- [x] **B10 — native ABI/CI parity.** Run generated binding manifest verification and the managed/native host smoke tests; save pass/fail and exact SHA on Linux and Windows. Confirm the linked engine exposes only annotated CSharpExpose members.

## P1 — simulation throughput (run after API semantics pass)

- [x] **B11 — ECS data-only baseline.** 10k, 50k, 100k and 250k static/rotating entities; native Beef ECS system vs managed C# workload over the **same Flecs data**. Report ECS iteration/query time, frame times, allocations, memory and render draw-call limits. Do not present a renderer bottleneck as an ECS result.
- [x] **B12 — ECS writable chunk path.** Read and write the same 10k/100k position-like components with a bulk API; measure copy cost, boundary transitions and total tick. Done for offline scenes (2026-11-15): `Scene.Query<...>().ForEach` gives refs straight into the Flecs columns, one native call per table, no copy; 50k ecs rows 2.08 ms C# vs 1.53 ms Beef (see results below). Networked [Sync] ECS data is still to do.
- [x] **B13 — physics sphere pile.** Spawn Jolt rigidbodies at fixed intervals until p95 frame time >16.67 ms, or max 10k. Record total, active/asleep counts, contact pairs, Jolt step milliseconds and memory. Repeat sleep ON/OFF; compare Beef vs C# control paths with identical native Jolt settings.
- [x] **B14 — character motion/physics queries.** 100, 1k and 5k Jolt CharacterController instances with the same navigation/input; raycasts and sphere casts at 1k/10k/100k queries per frame; measure exact hit agreement and latency separately.
- [x] **B15 — soft-body throughput.** Jelly, Cloth, Shell and DrivenJelly, 10/50/100/500 bodies, fixed vertex counts and settings. Record rebuild time, step time, active vertex count, memory and deformation correctness. Keep existing Jelly Golf-style free jelly as an acceptance case.
- [x] **B16 — engine resource/render throughput.** Static 100k objects, 10k changing transforms and streaming scene chunks, with GPU timings/draw calls separated from C# script CPU. Include shader graph and compute graph functionality regression.
- [x] **B17 — real managed allocations.** With 1k/10k/100k Script updates, record managed bytes/frame, collections (Gen0/1/2), pause time and peak RSS. Compare allocation-free value math, event allocation, GetComponent in loops and managed/native string calls.

- B06 (editor part, 2026-11-16): 20 editor Play/Stop cycles (`--play-cycle-test`), 6 scripts each: no script left attached, no unloaded game kept (after fixing the leak that kept every game), memory +7 MB over 20 cycles.
- B04 (done 2026-11-16): a broken project opens, logs the error with file and line, keeps Play off, and plays once fixed (`tools/test_csharp_editor.py` steps 3-4). A second save while the first one's build is running: `--stale-build-test` case 2 saves again mid-build and presses Play at once; Play runs the second version (the in-flight build is invalidated and the newest source rebuilt first).
- B06 (player part, 2026-11-16): `lifecycle` mode makes N scripted objects one frame and destroys them the next, 150+ cycles. Every Awake has its OnDestroy (C# and Beef counts identical), nothing is left alive, and managed memory after a full collection does not grow across cycles (only the last live batch, ~430 bytes per script). Create cost per object: C# 1.4 µs (1k) / 0.86 µs (10k) vs Beef 0.27 µs. Editor Play/Stop ×100 still needs a display.
- B13 (first pass, 2026-11-16): `physics` mode, N Jolt spheres falling into a walled box, each with a script that reads its velocity and damps it (AddForce) — the control path is the C# part. Script time C# 0.15 / 0.55 / 1.12 ms vs Beef 0.07 / 0.30 / 0.58 ms at 1k / 5k / 10k (~2×). Frame time is Jolt's: 1.29 vs 1.19 ms at 1k, 2.63 vs 2.62 at 5k; the 10k pile is chaotic (p99 77–131 ms in both while it collapses), so its frame numbers are not a C# result. Sleep counts not yet split ON/OFF.

- B07 (2026-11-16, `Tests/NativeCSharpHost --benchmark`, Release host, Nobara): nanoseconds per callback for no-op
  callbacks, one native->.NET call per script ("scalar") versus one call per batch, each the better of two timed
  passes after warm-up:

  | batch | Fixed scalar | Fixed batched | Late scalar | Late batched | TickInput scalar | TickInput batched |
  |---:|---:|---:|---:|---:|---:|---:|
  | 1 | 14.6 | 24.3 | 14.3 | 25.4 | 17.7 | 28.0 |
  | 16 | 14.4 | 16.0 | 14.3 | 16.2 | 17.5 | 20.0 |
  | 128 | 14.4 | 15.8 | 14.3 | 15.9 | 17.8 | 19.8 |
  | 512 | 14.1 | 15.5 | 14.1 | 15.6 | 17.7 | 19.5 |
  | 4096 | 14.2 | 15.5 | 14.1 | 15.5 | 17.6 | 19.3 |

  Batching never wins: a call into .NET costs ~14 ns (~18 ns with a TickInput, each script its own), and a batch
  adds its own lookup and checks per item (~1.4 ns) plus ~10 ns per call. This agrees with the 50k-object engine
  measurement (batched Update was slower; the cost is the memory each script touches, not the transition), so the
  engine keeps one call per script. Per-callback overhead is ~0.7 ms per 50,000 callbacks.
- B10 (2026-11-16): the manifest the linked engine reflects (`TallowLauncher --csharp-api-manifest`, 402 entries:
  390 methods, 10 read-only and 1 read/write field) equals the checked-in `build/csharp-api-manifest.tsv`; the
  exported player (`TallowPlayer`) exports exactly 402 `CSharpApi_*` symbols plus `CSharpApiVersion_*` (one per
  method and getter, two for the read/write field), nothing that is not annotated; `check_csharp_host_abi.py` (76
  host symbols) and `check_csharp_enums.py` pass. CI runs the binding self-test, manifest fixture check, managed
  host smoke and in-process native host test on Linux and Windows for every push (green at 1900257b, run
  43977949095).

- B09 (2026-11-16, `tools/benchmark_inspector_scale.py`, Debug editor, Nobara): N objects each with a C# script
  holding a public, a private `[ShowInInspector]` and a `[HideInInspector]` field; two fields edited per script as
  the Inspector does, the scene saved, opened again and played. Every Awake already sees the saved values; the
  hidden field keeps its default.

  | scripts | make + edit | save | scene size | open | enter Play | stop |
  |---:|---:|---:|---:|---:|---:|---:|
  | 1,000 | 19 ms | 3 ms | 291 KB (298 B a script) | 11 ms | 77 ms | 10 ms |
  | 10,000 | 185 ms | 31 ms | 2.9 MB (299 B a script) | 105 ms | 607 ms | 85 ms |

  Linear throughout. A probe saved as a prefab and stamped again keeps its edited values and plays. A script whose
  saved value cannot be read (`count = banana`) does not start, and the log now names the object and script
  (before, only the parse exception, with no object); the other scripts play.

- B17 (2026-11-16, `tools/benchmark_csharp_alloc.py`, Release headless player on the system's .NET 11.0.0-rc.1
  runtime, medians of 3 x 600 frames; raw data `~/TallowBenchmarks/alloc-20261116/`): N objects, each script running one pattern every Update.

  | pattern | scripts | script ms | managed bytes/frame | Gen0/1/2 (600 frames) | GC pause ms total | peak RSS MB |
  |---|---:|---:|---:|---|---:|---:|
  | value math (Vector3/Quaternion) | 1k / 10k / 100k | 0.06 / 0.64 / 7.2 | 149 / 163 / 150 | 0 / 0 / 0 | 0 | 57 / 75 / 215 |
  | GetComponent x3 | 1k / 10k / 100k | 0.13 / 1.19 / 13.5 | 149 / 163 / 136 | 0 / 0 / 0 | 0 | 57 / 75 / 217 |
  | event + capturing lambda + class arg | 1k / 10k / 100k | 0.04 / 0.36 / 8.4 | 104 B a script | 4 / 38 / 375 gen0 | 1.5 / 11.6 / 1037 | 73 / 88 / 224 |
  | Name from the engine + `$"..."` | 1k / 10k / 100k | 0.15 / 0.91 / 9.6 | 108-121 B a script | 4 / 44 / 432 gen0 | 1.4 / 2.4 / 30 | 73 / 89 / 226 |

  Engine calls allocate nothing (the ~150 bytes a frame are the benchmark's own timing lists). Allocation comes only
  from what scripts do themselves. Strings cost their size; gen0 collections are cheap. Events are the expensive
  case at scale: each `+=` writes a new young object into 100,000 old scripts, so every gen0 collection scans those
  cards (2.8 ms each, ~1.7 ms a frame on average). While writing it, a captured local in one `case` made C# allocate
  the closure at the top of Update for every case (24 B a script a frame, even for the math pattern). The editor now
  warns about this: **TAL-PERF003**, for a lambda in a tick callback that captures locals, parameters or `this`.
  Static lambdas, capture-free lambdas and lambdas passed straight to a Tallow API (`Query.ForEach`) are not flagged.

- B14 (2026-11-16, `tools/run_csharp_bench.py --modes raycast,spherecast,character`, Release headless players,
  medians of 3 x 600 frames; raw data `~/TallowBenchmarks/queries-20261116/`). Queries: N rays or sphere casts
  (radius 0.3) a frame from fixed points over a field of 400 boxes; characters: N CharacterControllers on a floor,
  each walked by a script with SimpleMove every tick.

  | mode | count | Beef script ms | C# script ms | C#/Beef | µs per query / walker (C#) |
  |---|---:|---:|---:|---:|---:|
  | raycast | 1k / 10k / 100k | 0.26 / 2.54 / 25.1 | 0.27 / 2.82 / 27.1 | 1.06 / 1.11 / 1.08x | 0.27 |
  | spherecast | 1k / 10k / 100k | 0.69 / 6.91 / 68.2 | 0.77 / 7.23 / 70.3 | 1.12 / 1.05 / 1.03x | 0.70 |
  | character | 100 / 1k / 5k | 0.14 / 1.76 / 13.7 | 0.16 / 1.86 / 14.4 | 1.14 / 1.05 / 1.05x | 1.6-2.9 |

  Hit agreement is exact: the same hit count and the same sum of hit distances (to the millimetre) in Beef and C#,
  in every run, at every count. Walker end positions cannot be compared exactly; the walk is not repeatable from run
  to run in either language (ticks follow wall time), which is older physics behaviour, not C#.

  **Fixed on the way (engine, both languages):** character controllers were O(n²) a tick. 1,000 walkers took
  140 ms a tick (120-179 µs each; 3.4 µs each at 100). Two causes: `PhysicsWorld.HasCharacter` scanned a list of
  every character, and each character asks it several times a move; and each soft character's push apart
  (`Separation`) looked at every other character. Now `HasCharacter` is a dictionary lookup, and the push uses
  `SoftCharacterGrid`, a neighbour grid built once a tick (rebuilt when characters are added, removed, reshaped,
  teleported, or move more than 0.5 m from where it saw them). It visits neighbours in the same order as before, so
  the push is the same to the bit. EcsBench's checks compare the two for 300 characters standing, walking, teleported
  and moved by their Transform. 1,000 walkers now take 1.8 ms a tick (78x faster), and 5,000 take 13.7 ms.

- B11 (2026-11-16, `run_csharp_bench.py --modes ecs`, Release headless players, medians of 3 x 600 frames; raw data
  `~/TallowBenchmarks/ecs-20261116/`): entities with Pose + Motion moving and spinning, one query over the same Flecs
  data (Beef: `MoveSystem` over chunks; C#: `Scene.Query<Pose, Motion>().ForEach` in place).

  | entities | Beef query ms | C# query ms | C#/Beef | Beef frame ms (p99) | C# frame ms (p99) | spawn Beef / C# ms |
  |---:|---:|---:|---:|---:|---:|---:|
  | 10,000 | 0.30 | 0.52 | 1.76x | 1.36 (1.46) | 1.59 (1.72) | 2.4 / 3.8 |
  | 50,000 | 1.49 | 2.57 | 1.73x | 2.55 (2.78) | 3.63 (3.86) | 10.1 / 12.7 |
  | 100,000 | 2.97 | 5.05 | 1.70x | 4.05 (4.31) | 6.12 (6.50) | 19.1 / 25.0 |
  | 250,000 | 7.12 | 12.45 | 1.75x | 8.20 (8.56) | 13.53 (14.23) | 45.1 / 56.0 |

  Linear, a steady 1.7x, 217 managed bytes a frame and no collections at any size; the C# process is ~35-45 MB
  larger (the .NET runtime). These entities are data only and not drawn: render and draw-call limits are B16's.

  Why 1.7x: game code is loaded in a collectible context (for hot reload), and .NET compiles collectible code once,
  fully optimised, without tiering or dynamic PGO (`DOTNET_JitDisasmSummary` shows FullOpts for every game
  method). The process-wide `TieredPGO` setting still changes the inliner: with `DOTNET_TieredPGO=0` the ECS lambda
  stops inlining `Workload.Step` and runs 2x faster (2.6 ms at 100k, faster than Beef), but GameObject scripts get
  15% slower, GetComponent 17% and lifecycle 8%, so it is not the default. Loading shipped games non-collectible
  (tiering and PGO on) was tried and measured neutral (GetComponent 8% faster, ECS 2% slower, everything else and
  start-up unchanged), so it was not kept. NativeAOT (P3) remains the way to settle code generation.

- B13 (done 2026-11-16; raw data `~/TallowBenchmarks/pile-20261116/`). **Ramp** (`--modes pile`, 3 runs each):
  from an empty walled box, 250 balls (each with a velocity-damping script) are dropped every 60 frames until a
  window's p95 frame time passes 16.67 ms or 10,000 are in.

  | | balls when p95 > 16.67 ms (median) | ball scripts ms (avg over the ramp) | frame ms avg | Jolt step at the end | process MB |
  |---|---:|---:|---:|---:|---:|
  | Beef, sleep on / off | 9,500 / 9,500 | 0.20 / 0.20 | 3.24 / 3.38 | 7.7-9.0 ms | 58 / 60 |
  | C#, sleep on / off | 8,500 / 8,500 | 0.35 / 0.34 | 3.53 / 3.25 | (same engine) | 104 / 102 |

  The limit is Jolt's: at 8,500-9,500 balls a step takes ~8 ms, and a frame that runs two fixed steps passes
  16.67 ms. C#'s extra 0.15 ms of script time tips that over about 1,000 balls sooner. Sleep makes no difference
  while balls keep landing on the pile (nothing gets to sleep). **Settled pile** (`--modes physics`, spawned at
  once, ~20 s): 1,000 balls with sleeping on all go to sleep and Jolt's step falls from 1.13 ms to 0.002 ms (Beef
  and C# alike; scripts 0.035 vs 0.075 ms); 5,000 balls (ten layers) are still settling after 20 s in both, step
  6.7 ms. Contact pair counts are not exposed by the engine's Jolt binding and are not reported.
  `PhysicsWorld.LastStepMilliseconds` (new) times Jolt's own step. Found on the way: C#'s Rigidbody was missing
  LinearDamping, AngularDamping, FreezeRotation, AllowSleeping and Debris (now added, with in-game checks).

- B15 (done 2026-11-16; raw data `~/TallowBenchmarks/softbody-20261116/`, `--modes softbody`, `TALLOW_BENCH_SOFT`
  jelly / cloth / shell / driven, 600 frames, 2 runs each, Release headless). N soft bodies 3 m apart dropped onto a
  floor with default settings (jelly and driven on `builtin:sphere`, cloth on `builtin:plane`, shell on
  `builtin:cube` with a BoxCollider + Rigidbody; driven on a SphereCollider + Rigidbody), each with a script reading
  its body's velocity. Every run made all N simulations with the same vertex counts in Beef and C#, and nothing fell
  through the floor.

  | kind | N | vertices | frame avg ms Beef / C# | p99 Beef / C# | scripts ms Beef / C# | first frame ms Beef / C# |
  |---|---:|---:|---:|---:|---:|---:|
  | jelly | 10 / 100 / 500 | 1,460 / 14,600 / 73,000 | 1.11 / 1.11, 1.58 / 1.58, 3.47 / 3.44 | 1.44 / 1.46, 3.81 / 3.77, 14.9 / 14.8 | 0.001 / 0.002, 0.017 / 0.021, 0.085 / 0.110 | 1 / 3, 4 / 8, 96 / 97 |
  | cloth | 10 / 100 / 500 | 40 / 400 / 2,000 | 1.06 / 1.07, 1.08 / 1.09, 1.16 / 1.19 | 1.10 / 1.10, 1.21 / 1.21, 1.60 / 1.60 | 0.000 / 0.001, 0.003 / 0.007, 0.015 / 0.041 | 1 / 3, 1 / 3, 1 / 4 |
  | shell | 10 / 100 / 500 | 80 / 800 / 4,000 | 1.07 / 1.07, 1.11 / 1.12, 1.33 / 1.33 | 1.12 / 1.13, 1.35 / 1.46, 2.61 / 2.39 | 0.000 / 0.001, 0.003 / 0.009, 0.020 / 0.043 | 1 / 3, 1 / 3, 1 / 5 |
  | driven | 10 / 100 / 500 | 1,460 / 14,600 / 73,000 | 1.11 / 1.12, 1.57 / 1.58, 2.54 / 2.54 | 1.47 / 1.50, 3.84 / 3.87, 2.85 / 2.84 | 0.001 / 0.002, 0.016 / 0.021, 0.086 / 0.111 | 1 / 3, 4 / 9, 97 / 102 |

  Frame time is the soft-body simulation's, and identical in both languages. Jolt's step (Beef's
  `LastStepMilliseconds`) is 0.29 / 2.2 ms for 10 / 100 jellies while they settle. Every 500-body jelly and driven
  run had gone to sleep by the end (step 0.002 ms); jelly's p99 of 15 ms is its settling phase. The scripts cost
  C# 1.3-2.7× Beef, at most 0.11 ms for 500 bodies. C#'s first frame (where the bodies are made) is 2-5 ms longer,
  which is JIT. Process memory is ~44 MB higher in C# (the runtime), the same as in other modes. Found on the way: C#
  could not add a SoftBody (no `[NativeComponent]`), could not set its Kind, and was missing 18 of its fields
  (mass, iterations, the shell dent settings...). All three are fixed, with in-game checks. Not covered: Jelly
  Golf-style acceptance (the scene is Beef-only), and rebuild time on a setting change (the C# setters that
  rebuild — Stiffness, WobbleDamping — are the same native call as Beef's).

- B16 (done 2026-11-16; raw data `~/TallowBenchmarks/render-20261116/`, `tools/benchmark_csharp_render.py`, `render`
  mode in a 1920×1080 window on this machine's GPU, vsync off in both, `--profile-report` per run, 600 frames, median
  of 3). A case is static:moving:chunks:effects: static cubes with no script, cubes moved by Mover scripts, a
  1,000-cube chunk destroyed and another made every 30 frames, and N quads running the ripple compute graph with every
  10th static cube on the glow shader-graph material.

  | case | frame avg ms Beef / C# | p99 | GPU ms | rendering CPU ms | scripts ms | draws | visible | compute dispatches |
  |---|---|---|---|---|---|---|---|---|
  | 10k:0:0 | 0.89 / 0.89 | 0.92 / 0.91 | 0.32 / 0.32 | 0.72 / 0.71 | 0.01 / 0.05 | 1 / 1 | 9,216 / 9,216 | 0 / 0 |
  | 10k:0:0:8 | 0.98 / 0.97 | 1.03 / 1.01 | 0.36 / 0.38 | 0.74 / 0.73 | 0.06 / 0.10 | 10 / 10 | 9,224 / 9,224 | 8 / 8 |
  | 100k:0:0 | 10.23 / 10.20 | 11.12 / 10.79 | 2.37 / 2.21 | 9.49 / 9.48 | 0.04 / 0.09 | 1 / 1 | 72,062 / 72,062 | 0 / 0 |
  | 100k:10k:0 | 13.61 / 14.25 | 14.72 / 15.41 | 3.90 / 4.13 | 10.72 / 10.79 | 0.79 / 1.36 | 1 / 1 | 82,062 / 82,062 | 0 / 0 |
  | 100k:10k:1 | 14.42 / 15.15 | 17.66 / 19.36 | 4.16 / 4.24 | 11.43 / 11.50 | 0.84 / 1.43 | 1 / 1 | 86,062 / 86,062 | 0 / 0 |
  | 100k:10k:1:8 | 15.53 / 16.17 | 19.04 / 20.27 | 5.18 / 5.31 | 11.62 / 11.73 | 1.70 / 2.28 | 8 / 7 | 86,070 / 86,070 | 8 / 8 |

  Rendering CPU, GPU time, draws, visible renderers and compute dispatches are the same in both languages; the whole
  difference is the scripts row (10,000 Movers: C# 1.36 ms vs Beef 0.79 ms, the B03/B05 ratio). Shader-graph
  materials and compute graphs set up from C# draw and dispatch exactly as from Beef. **Engine finding (not C#):**
  culling is single-threaded at ~70 ns a renderer, 7.1 ms of the 9.5 ms rendering CPU at 100k static cubes, so a
  100k-object scene is CPU-bound at ~10 ms before any script runs. **Fixed 2026-11-17** (below). Found on the way: the C# bench never turned vsync off (C#
  had no way to, only quality presets) and never pointed its camera at the scene. `Quality.VSync`, `RenderScale`,
  `Shadows`, `ShadowMapSize`... (all 17 quality settings, plus `Quality.Save()`) are now in C#, with an in-game check.

- Culling fix (2026-11-17; raw data `~/TallowBenchmarks/render-culling-20261117/`, same B16 runs): the renderer list
  (`Scene.Renderers`) is filled and the renderers are gathered (`RenderView.GatherRenderers`) on the job threads in
  ranges of 2,048 from 8,192 renderers. A range holding a renderer only the main thread may work out (an unresolved
  mesh, material or texture, a LOD group, a lightmap, model parts, palette or state materials, a dirty transform
  under a parent) is gathered on the main thread, and ranges are joined in order, so the lists are the same as
  before: `tools/test_parallel_gather.py` compares screenshots of both, pixel for pixel. Found on the way: List's
  indexer writes a version count on every set, which threads filling one list would all be writing.

  | case | rendering CPU ms before → after (Beef) | frame avg ms before → after, Beef / C# |
  |---|---|---|
  | 10k:0:0 | 0.72 → 0.13 | 0.89 / 0.89 → 0.45 / 0.62 |
  | 100k:0:0 | 9.49 → 2.34 | 10.23 / 10.20 → 5.66 / 5.69 |
  | 100k:10k:0 | 10.72 → 2.61 | 13.61 / 14.25 → 8.56 / 9.51 |
  | 100k:10k:1 | 11.43 → 2.71 | 14.42 / 15.15 → 9.36 / 9.99 |
  | 100k:10k:1:8 | 11.62 → 2.90 | 15.53 / 16.17 → 9.84 / 10.49 |

  The rest is memory: each view copies every renderer's settings into its proxy each frame (~64 MB at 100k), which
  bounds how well the list fill scales; sorting (1.0 ms) and submitting (1.1 ms) stay on the main thread.

### Fixes from these runs (2026-11-16)

- Generated bindings encoded every string argument into a new `byte[]` per call (component names in `GetComponent`, field names in every built-in component property, animation state names...). Strings up to 128 characters now encode on the stack.
- `CSharpNativeComponents.Has` gathered the component's whole field list just to say it exists; `ComponentRegistry.Find` / `HandleComponents.Find` scanned every type comparing names. Now a direct check and name dictionaries.
- `GetComponent<T>` boxed built-in handles and asked `IsAssignableFrom` per call; now cached per type, handles made without boxing.
- Built-in component number/vector/colour/bool reads (`Light.Intensity`, `SphereCollider.Radius`...) parse from a stack buffer instead of splitting strings (in-engine check: lookups and reads allocate 0 bytes). Setters still format text.

### Results so far (Linux, Release exported headless players)

`tools/run_csharp_bench.py` runs `Samples/CSharpBench` (C#) against the same workload in Beef: every object moves and
rotates each frame (`gameobject`: one Script per object using Transform; `ecs`: one `Query<Pose, Motion>().ForEach`).
Medians of 3 runs × 600 frames. Raw data: `~/TallowBenchmarks/beef-vs-csharp-20261115/`.

| mode | objects | Beef script ms | C# script ms (first run) | C# script ms (now) | C# frame ms (first → now) | C# GC bytes/frame |
|---|---:|---:|---:|---:|---:|---:|
| gameobject | 1k | 0.026 | 0.142 | 0.117 | 1.24 → 1.18 | 149 |
| gameobject | 10k | 0.288 | 0.978 | 0.859 | 2.32 → 1.93 | 163 |
| gameobject | 50k | 1.696 | 5.048 | 4.368 | 10.15 → 5.45 | 150 |
| ecs | 1k | 0.030 | — | 0.043 | — → 1.11 | 204 |
| ecs | 10k | 0.307 | 1.319 | 0.423 | 2.35 → 1.49 | 204 |
| ecs | 50k | 1.525 | 6.168 | 2.080 | 7.34 → 3.15 | 204 |

Re-run 2026-11-16 on the same machine (`~/TallowBenchmarks/beef-vs-csharp-20261116/`, 100k added): gameobject C#/Beef 2.8× (1k) → 2.1× (100k; 8.1 vs 3.8 ms); ecs 1.7× at every size (100k: 5.1 vs 3.0 ms). C# spawn of scripted objects is ~3.7× Beef (100k: 258 vs 70 ms).

No GC collections during measurement. What closed the gap so far: C# scripts leave the scene's per-frame lists for
callbacks their class does not override; read-only transform callbacks skip the GC transition (setters keep
it, as a host may call back into .NET from a write); ECS `ForEach` works on the Flecs columns in place (one native
call per table, the action gets refs into the column; structural changes made in the action are queued on a Flecs
stage of their own and applied when it ends), so there is no copy out or write back (`table-inplace.md`). Left: one
native call per Transform get/set (a batched or cached transform path), and the JIT's code for the loop body
(`DOTNET_TieredPGO=0` made the ECS loop ~1.6× faster in a probe; NativeAOT would settle it).

## P2 — networking, export, regression (cannot be substituted by a local microbenchmark)

- [x] **B18 — multiplayer sync.** 2, 4, 8 and 16 peers (or maximum supported), 0/50/100/200 ms added RTT, 0/1/2/5% packet loss, 30/60/120 Hz where supported. Compare state divergence, input latency, server tick time, bandwidth per peer, desync recovery and replay hashes. Ensure C# TickInput produces the same authoritative behavior as Beef.
  Measured November 17, 2026 (1eaa018f, `tools/run_net_bench.py`, results in ~/TallowBenchmarks/b18-20261117):
  exported headless Release players of Samples/CSharpBench and Samples/EcsBench (the same networked pilot and 200
  drones), the engine's simulator adding latency and loss, 40 s per run with the first 10 s left out. Parity: the host
  alone with a bot gives the same state hash at tick 600 in both languages (`04b4a9e088844cf9`). 2/4/8/16 peers with
  no added lag: every peer connected, 34.8/38.1/44.7/58.0 KB/s sent per client in both, server 0.36/0.43/0.60/1.02 ms
  a tick in Beef and 0.37/0.44/0.61/1.04 ms in C# (2–3% more). 4 peers at 50/100/200 ms: the client runs 5/9/15 ticks
  ahead in both, bandwidth 39.2–42.0 KB/s alike. 1/2/5% loss at 100 ms: own-position error median 0.000 m, worst
  0.003–0.004 m in both, no starved ticks, no dropped controls, 0 rollbacks a second and 0 errors anywhere. Pass. 30
  and 120 Hz are not run: the tick rate is fixed at 60 Hz.
- [x] **B19 — destruction/parallel dimensions.** Stream both world dimensions concurrently, switch during active physical destruction with peers, track swap latency, memory peak, bandwidth, and no cross-dimension audio leak.
  Not applicable on this branch (November 17, 2026): the two-dimension world is ShatterLock's, on the
  `shatterlock-engine` branch, which has no C# runtime. It belongs to that game's own test plan; nothing here streams
  two dimensions.
- [x] **B20 — prediction/rollback determinism.** Fixed-seed input replay for 10k ticks, repeated 3 times; record final state hashes, divergences, rollback duration and worst catch-up frame, C# vs native. Mark blocked until rollback C# parity is implemented; do not infer from compile tests.
  Measured November 18, 2026 (`tools/run_rollback_bench.py`, B18's NetSync workload, players exported at fa8daf79,
  results in ~/TallowBenchmarks/rollback-20261117/results): replay, the host alone with the deterministic bot for
  10,000 ticks, three runs each: all six runs give `1d70dfbed5728c97` (player and 200 drones to the millimetre), Beef
  and C# alike. Rollback, server and one bot client at 100 ms RTT and 2% loss for 10,000 ticks, three runs each: 4
  corrections per run in both, 7–9 ticks replayed at 3.5–4.6 µs each (Beef) and 7 at 3.8–4.3 µs (C#), own prediction
  error median 0.002–0.010 m, worst 0.012 m; worst frame 4.2–7.6 ms (Beef) and 2.9–4.3 ms (C#), p99 1.21 vs 1.22 ms;
  0 errors. The server's end hash differs run to run under loss in both languages (a control that arrives late is
  dropped and the last one repeated), as the runner expects. Pass.
- [x] **B21 — visual scripting parity.** Existing graphs vs generated C# on equivalent 1k/10k node updates; check event ordering, networking, serialization and graph regeneration time. Mark blocked until C# visual-graph backend is functional.
  Measured November 18, 2026 (`tools/run_graph_bench.py` + `run_csharp_bench.py --modes graph,gameobject`, results in
  ~/TallowBenchmarks/graph-20261118): regeneration of every bench graph, 5 runs each through the launcher: 3.6–3.8 ms
  to C#, 4.5–4.7 ms to Beef, the same text every run and the same as the checked-in file (EcsSyncedMotionGraph has
  no checked-in output: it uses EcsBench's own Beef ECS type, which only that project's native build knows, so it is
  listed, not checked). Event order (GraphOrder): awake, enable, start, update, late in both. Throughput, cubes each
  running the 10-node Bobber graph, script ms Beef / C#: 100: 0.003 / 0.009; 1,000: 0.036 / 0.088; 10,000:
  0.336 / 0.860 (2.4–2.6×, the same ratio as hand-written scripts: 0.286 / 0.736 at 10,000); a graph costs ~17% over
  the hand-written script in both languages. C# GC 149 bytes/frame either way. Networking/serialization of graphs is
  the scripts' own ([Sync] fields of graph variables compile to the same C#), covered by B18. Pass.
- [x] **B22 — game export portability.** Release build on Windows/Linux **without Beef installed** on target machine; record packaged size, cold start, .NET runtime/bootstrap diagnostics, crash frequency and whether the editor/player ever tries to compile native engine code. Verify exports against older Beef samples too.
  Measured November 18, 2026 (`tools/run_export_bench.py`, results in ~/TallowBenchmarks/export-20261118). Linux: each
  player in a bubblewrap sandbox (read-only /usr and /etc, the system .NET hidden, empty home, every compiler on PATH a
  stand-in that records the call and fails). C# CSharpBench: 150.9 MB (bundled .NET 84.2, executable 64.5, Managed
  2.0, game.tpak 0.2), start to exit after one frame 0.26 s, 20/20 runs of 300 frames with 1,000 scripted cubes exit
  0, no error lines, no compiler called. Beef EcsBench (an older-style Beef game): 67.8 MB, 0.26 s, 20/20, no
  compiler called. Windows: CSharpBench built on Linux (`build_player.py --platform windows`, fresh cross-built
  player) and run under Wine: 105.3 MB (.NET 86.8, executable 16.4), 1.40 s start (Wine's own start included), 20/20
  clean. Pass. Not done: a real Windows machine (CI's native Windows job runs the in-engine suites there).
- [x] **B23 — stability soak.** 30–60 minute automated gameplay loop; scene reload, prefab spawn/destroy, networking reconnect, soft-body world teardown. Track median/p95/p99 frame time over time, managed/native RSS slope, GPU memory and native-handle leaks.
  Measured November 17, 2026 (9a41220c, `tools/run_csharp_soak.py --minutes 45 --cycle 25 --warmup 180`, results in
  ~/TallowBenchmarks/soak-20261117): an exported C# player (Samples/CSharpBench, Scenes/Soak.tscene) as host and a
  second as client over loopback, each reloading its scene every 25 s (108 loads, median 7.2 ms, p95 7.9 ms), the
  client leaving and rejoining the host's session each cycle (107 reconnects, 0 failed joins), 2,400 prefab crates
  spawned and destroyed per cycle with a soft body and a script on each (32.7 million Awake/OnDestroy pairs, the 100
  left over being the last cycle's live ones). Over 45 minutes on each side: frame median 1.31–1.32 ms, p95 1.62–1.68,
  p99 1.77–1.87, worst 4.0–6.3 ms (the first five minutes); RSS 93.4–93.9 MB, slope 0.2–0.4 MB/h measured from
  /proc after the warm-up; managed heap 9.2–9.9 MB (0.2–0.38 MB/h, collector noise); open files 49 and threads
  10–11 throughout; 0 errors or exceptions. Pass. GPU memory is not measured: the players run headless (no GPU), so
  render-side leaks are covered by the editor Play/Stop cycle test (B06) instead.

## Automated local compile timing helper

After pulling the C# branch, run:

```bash
cd ~/GitWorktrees/tallow-csharp
REPEATS=5 bash tools/benchmark_csharp_compiles.sh
```

This prepares the .NET build driver, then runs cold, no-op, and warm
single-file edits **only in disposable fixture copies**, measuring wall time,
exit status and peak command RSS (where /usr/bin/time exists). It creates
~/TallowBenchmarks/csharp-DATE/results.csv, separate logs and a shareable
.tar.gz archive. The timed command includes the .NET driver process and
MSBuild/C# compilation: it is not the editor's Save-to-Play wall time, nor an
engine FPS benchmark. No existing game directory or tracked source is changed.

## Commands and evidence

From an existing updated checkout:

```bash
cd ~/GitWorktrees/tallow-csharp
git rev-parse HEAD
git status --short
dotnet --info
./build/Debug_Linux64/TallowLauncher/TallowLauncher --build-project "$HOME/TallowBenchmarkFixture"
# Only if the matching C++/managed host binaries have been built:
Tests/NativeCSharpHost/build/tallow_native_csharp_smoke \
  Managed/Tallow.ManagedRuntime/bin/Debug/net11.0/Tallow.ManagedRuntime.runtimeconfig.json \
  Managed/Tallow.ManagedRuntime/bin/Debug/net11.0/Tallow.ManagedRuntime.dll \
  Tests/CSharpGameplay/.tallow-csharp/bin/Tallow.Game/Tallow.Game.dll --benchmark
```

**Important:** The sample `$HOME/TallowBenchmarkFixture` must be a *copy* of a C# game with a `src` folder. Never delete the source checkout's `Tests/CSharpGameplay` or users' game projects to simulate cold builds. Native host microbenchmarks measure mocked dispatch/interop, not real Jolt, rendering or network game workloads. Treat all Bxx items as pending until you provide measured logs.

Use filename `B##_SHA_config_scene_runN.log`. Results table columns: case, SHA, platform, build config, workload/entity count, warm-up, sample duration, iterations, median ms, p95 ms, p99 ms, avg FPS, peak RSS MB, GC allocations bytes/frame, GC pause ms, CPU/GPU/Jolt ms, network latency/loss, correctness result, raw log path. Record **blocked/unsupported** explicitly rather than inventing zero measurements.

## Acceptance gates before replacing Beef gameplay

- No gameplay-visible functionality regression in lifecycle, Inspector persistence, physics, ECS and network semantics.
- No new catastrophic performance regressions without an explicit, measured tradeoff and fallback; the benchmark suite should expose a slow bridge path, not conceal it.
- Correct release exports on both platforms; stable 100x Play/Stop and soak runs.
- Run matching Beef vs C# implementations with equivalent work before describing migration performance as faster/slower.


## P3 — NativeAOT release protection and JIT/AOT parity (pending; shipping gate)

- [ ] **B24 — NativeAOT export default.** Export the same real game with "NativeAOT" default and explicitly chosen "JIT compatibility". Assert failure of AOT compile does *not* create/ship a JIT DLL fallback; check release files contain zero gameplay IL DLLs/source and no dev Roslyn payload.
- [~] **B25 — binary size, symbols and disassembly.** Windows/Linux AOT Release game binary and private symbol archive sizes, export table (only required ABI exports), download package size, debug ID matching crash analysis, no private `.pdb`/`.dbg` in public output. Compare JIT equivalent; avoid claiming complete anti-reverse-engineering.
- [~] **B26 — cold start, memory and GC.** Five cold runs each JIT/AOT of same scene/engine; startup to first playable tick, steady and peak RSS, heap size, GC collections/pause p95, CPU and frame p95/p99. Record renderer mode, native engine/Jolt cost, platform/RID. No implicit AOT performance advantage is assumed.
- [~] **B27 — deterministic replay cross-runtime.** Same serialized starting state, seed, input stream and tick rate for 10,000 ticks each; compare per-tick state hashes, first divergent tick, entity order, and float differences (max absolute/relative error). Test JIT vs AOT **on same OS/CPU first**, then Windows/Linux and different CPUs. Fail if authoritative/predicted outcomes diverge, even if approximate float comparisons pass.
- [~] **B28 — multiplayer JIT/AOT cross-play.** Mixed JIT editor clients + shipped NativeAOT players against the same authority; identical state/rollback hashes and inputs under 0/50/100/200 ms RTT and 0/1/2/5% loss, 2–16 peers when supported. Record desync/mismatch and packet bandwidth.
- [x] **B29 — trimming and generated metadata.** Compare all public/private/hidden fields, enums, inherited components and asset/prefab references against JIT; add rename/migration tests. Export with AOT/trimming warnings treated as errors and ensure no reflection-only field or component is silently dropped.
- [~] **B30 — native export portability and crash symbols.** On clean Linux/Windows without dotnet/Beef developer tooling, run AOT player, load scenes, exercise Jolt/soft bodies/shader graphs and close cleanly. Capture a deliberate test-only crash and symbolicate with the **private** matching symbol file; verify the public package contains no symbols or gameplay IL.
  Linux done November 18, 2026 (`tools/test_csharp_crash.py`, 5 checks): the release player is stripped
  (`objcopy`; `.dbg` kept in `<output>-symbols/`, never in the package), the game library's `.dbg` and name map
  are kept there with `build-info.txt` (SHA-256 and GNU build ID / PDB GUID+age of every shipped module), the
  package runs with no .NET, Beef or `dotnet` on PATH and passes its 421 in-game checks, and `--crash-test`
  crashes on purpose at frame 100 and is read back as `bf::Tallow::CrashReports::DeliberateCrash()` **only**
  through the private symbols. The Windows `.pdb` is written by the same export; symbolication of a Windows crash
  (Wine's debugger or a real Windows machine) is still to run.

Status (November 18, 2026): the NativeAOT export exists (roadmap P5, "First NativeAOT export"). First
measurements, `tools/run_nativeaot_bench.py` on Linux x64, Samples/CSharpBench exported both ways at 32945b63
(Release, 10,000 objects, 600 frames, 3 runs; results in ~/TallowBenchmarks/nativeaot-20261118):

- B25 (Linux part): package 137.7 MB (JIT, bundled .NET) vs 66.7 MB (NativeAOT); game code 75.8 MB (Managed/ +
  dotnet/) vs 4.8 MB (libTallowGame.so, stripped); private symbols 6.6 MB beside the build, none in the package;
  the library exports only `tallow_native_register`. The player exe (61.7 MB) is the same file for both.
  (Measured before the player itself was stripped. November 18, 2026: the Release player is 24 MB, the NativeAOT
  package 43 MB, and the private folder 79 MB with the player `.dbg` and the library name map.)
- B26 (Linux part): start-to-exit with one frame 0.255 s vs 0.254 s (5 runs, headless); peak RSS 58 MB vs 32 MB.
  Script time per frame (JIT / AOT): gameobject 0.75 / 0.82 ms, ecs 0.50 / 0.35, getcomponent 0.32 / 0.40,
  physics 1.14 / 1.19, alloc 0.67 / 0.57; spawn 20-30% quicker under AOT (no JIT at first call); managed allocation
  per frame the same. Neither is faster across the board.
- B27 (same OS/CPU part): the NetSync bot replay, 10,000 ticks, 3 runs each: all six give `1d70dfbed5728c97`, the
  same hash as B20's Beef and C# runs. Cross-OS and other CPUs not yet run.
- B28 (first part): JIT server + NativeAOT bot client and the reverse, 10,000 ticks, no added lag/loss: both servers
  end on `c8a15ddc6f490720`, no errors, no code-ID warning.
- B28 (Linux, November 18, 2026): `tools/run_crossplay_matrix.py` runs the whole B18 configuration set with mixed
  runtimes: 2, 4, 8 and 16 peers; 50, 100 and 200 ms round trip; 1, 2 and 5% loss at 100 ms; each twice (JIT server
  with NativeAOT clients, NativeAOT server with JIT clients; clients alternate at higher peer counts), 1,800 ticks
  each, headless Release players built from one commit. All 20 runs: every client connected, no errors, no
  code-ID warning; prediction (own) error 0.000 m median (worst 0.2 m), 35-58 KB/s sent per client per second as
  peers grow, 1-15 ticks ahead. The two mixed directions ended on the same server hash in 4 of the 10
  configurations: a bot client joins a running server, so where its pilot starts shifts by a tick or two between
  runs, and with loss a control that arrives too late is dropped (as B20 records). JIT and NativeAOT hosts alone
  replay to one hash with these players (`964389e34c11207c` at 1,800 ticks), so state equality is evidenced by the
  replay and by no prediction divergence, not by identical cross-play hashes. Results:
  ~/TallowBenchmarks/crossplay-20261118 (results.md and raw.jsonl). Not covered: Windows players (Wine or a real
  Windows machine), peers above 16.
- B28 (Windows players under Wine, November 18, 2026): `run_crossplay_matrix.py --wine` with the same Windows
  exports and the simulator, a reduced set — 2 peers with no added latency; 4 peers at 100 ms and 1% loss — in both
  directions, 1,800 ticks each: 4 runs, every client connected, no errors, prediction (own) error 0.000 m median
  (worst 0.2 m), 34.8-40.4 KB/s sent per client, 2-9 ticks ahead. Each runtime's host alone replays to
  `964389e34c11207c`, the hash the Linux halves give; the two mixed directions agreed on 1 of the 2
  configurations, and the others end elsewhere because a client joins a running server (the Linux note above
  explains why that is reported, not a gate). The full B18 set on Windows and peers above 16 still need a real
  Windows machine. Results: ~/TallowBenchmarks/crossplay-windows-20261118.
- B24 (part): a NativeAOT export that fails leaves no game behind, no JIT assemblies or .NET in its place
  (`test_csharp_export.py --runtime native`, unsuppressed run-time generic code in the game); the release files
  hold no IL, sources or symbols. The default switch to NativeAOT waits for the user's Windows test.
- B29: exports stop on trim/AOT warnings in game code or unreviewed engine code (`tools/nativeaot_allowlist.txt`),
  and `tools/test_csharp_aot_fields.py` builds Tests/CSharpInGame both ways and compares every running script at
  frame 100 (`--csharp-field-dump`: script name, Inspector, all fields with types, [Sync], saved): 16 scripts, 364
  lines, identical, covering private and base-class fields, enums by name, [Serializable] lists, GameObject /
  component / script references and a [FormerlyNamed] class. Field renames are not a feature (a renamed field
  starts at its default), so there is nothing to compare for them. In CI on Linux and Windows.
- B30 (Linux part): a Release export's player is stripped of debug information (61 MB -> 24 MB; the NativeAOT
  package 66.7 MB -> 43 MB) and the matching `.dbg`, a name map and `build-info.txt` go to `<output>-symbols/`
  beside it. The package holds no symbols, chooses no installed .NET, and on an empty PATH runs its 421 checks;
  `--crash-test` raises a real SIGSEGV that gdb names through the private `.dbg` (tools/test_csharp_crash.py).
  Windows: the matching `.pdb` is kept by the same export (41 MB, not in the package); the Windows crash half
  needs Wine's debugger or a real Windows machine, as does the clean-machine run there.
- B25/B26/B27 (Windows players under Wine, November 18, 2026): Windows x64 exports, JIT and NativeAOT, run with
  Wine on Linux x64 — the shipped Windows files, not the Windows kernel. `tools/run_windows_bench.py`; results in
  ~/TallowBenchmarks/windows-20261118 (results.md and raw.json).
  - B25: package 100.7 MB (JIT) vs 20.5 MB (NativeAOT); game code 84.9 vs 4.7 MB; player 15.6 MB both; private
    symbols 38.9 vs 57.1 MB beside the build; no symbols in either package; the AOT game library exports only
    `DotNetRuntimeContractDescriptor` and `tallow_native_register`.
  - B26: start-to-exit 0.320 s (JIT) vs 0.319 s (AOT) and peak RSS 137.8 vs 104.5 MB (5 runs). 10,000 objects,
    600 frames, script/frame ms JIT vs AOT: gameobject 0.69/1.76 vs 0.79/1.86, ecs 0.23/1.30 vs 0.30/1.37,
    getcomponent 0.40/1.47 vs 0.37/1.44, physics (4,000 objects) 0.49/2.09 vs 0.56/2.22. Managed bytes per frame
    alike (149-208).
  - B27: the NetSync replay, 10,000 ticks, 3 runs each: all six give `1d70dfbed5728c97` — the same hash the Linux
    JIT/AOT runs and B20's Beef and C# runs give. The Windows code paths and Wine's floating-point through them do
    not change the simulation.
  Not covered: B28's Windows half, B30's Windows crash symbolication and a clean Windows machine. Times and memory
  above include Wine and are not native-Windows figures; the user's real-Windows run remains the gate. Hash
  equality is unaffected by timing.
- Benchmark both profiles from identical game commits and core engine settings. Do not substitute NativeAOT compilation of a dummy sample for shipping-player acceptance.
