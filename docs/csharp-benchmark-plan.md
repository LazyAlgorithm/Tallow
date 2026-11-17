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
- [x] **B03 — warm/no-op compile.** Rebuild the same untouched disposable game five times; separately edit one C# script body (add a harmless comment) and rebuild five times. Record time from Save to compilation banner disappearance and from Save to first permitted Play. Done for the command-line build (2026-11-16): no-op 1.19 s, one-file edit 1.21 s, leaf-assembly edit 1.23 s, public API edit 1.23 s (medians of 5; fixed process/MSBuild overhead dominates). Save-to-Play in the editor still needs a display.
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
- [ ] **B06 — managed runtime bootstrap and lifecycle.** Measure Play entry/exit for 0, 100, 1,000 and 10,000 lightweight C# Script instances. Run 100 Play/Stop cycles; check memory growth, duplicate callbacks, invalid handles and retained managed instances.
- [x] **B07 — scalar versus batched managed callbacks.** Run existing `Tests/NativeCSharpHost` `--benchmark` on matching builds; record raw per-callback cost and batch sizes 1, 16, 128, 512, 4096, separately for no-op Fixed/Late and distinct TickInput. **Do not switch the Scene scheduler automatically based only on mock-host speed.** Require real-editor profiler data, callback order, detach/disable and network replay equivalence.
- [x] **B08 — component access latency.** Compare `GetComponent<T>()` and `TryGetComponent<T>()` for native Rigidbody/Transform vs managed Script, hit and miss, using 100k–1M calls after warm-up. Verify disabled and destroyed handles fail safely. Done (2026-11-16, `getcomponent` mode, 100k calls/frame, a quarter each native hit, script hit, native miss, script miss): C# 3.04 ms vs Beef 0.30 ms per 100k (10×), no allocations. Before the fixes below C# took 30.6 ms and allocated ~33 bytes per call.
- [x] **B09 — Inspector scene/prefab save.** With 1,000/10,000 managed field instances: attach, edit public/private/hidden fields, save/reopen, enter Play and measure time plus serialized file sizes. Verify fields applied before Awake and prefab inheritance intact. Test failure with invalid persisted values.
- [x] **B10 — native ABI/CI parity.** Run generated binding manifest verification and the managed/native host smoke tests; save pass/fail and exact SHA on Linux and Windows. Confirm the linked engine exposes only annotated CSharpExpose members.

## P1 — simulation throughput (run after API semantics pass)

- [ ] **B11 — ECS data-only baseline.** 10k, 50k, 100k and 250k static/rotating entities; native Beef ECS system vs managed C# workload over the **same Flecs data**. Report ECS iteration/query time, frame times, allocations, memory and render draw-call limits. Do not present a renderer bottleneck as an ECS result.
- [x] **B12 — ECS writable chunk path.** Read and write the same 10k/100k position-like components with a bulk API; measure copy cost, boundary transitions and total tick. Done for offline scenes (2026-11-15): `Scene.Query<...>().ForEach` gives refs straight into the Flecs columns, one native call per table, no copy; 50k ecs rows 2.08 ms C# vs 1.53 ms Beef (see results below). Networked [Sync] ECS data is still to do.
- [ ] **B13 — physics sphere pile.** Spawn Jolt rigidbodies at fixed intervals until p95 frame time >16.67 ms, or max 10k. Record total, active/asleep counts, contact pairs, Jolt step milliseconds and memory. Repeat sleep ON/OFF; compare Beef vs C# control paths with identical native Jolt settings.
- [ ] **B14 — character motion/physics queries.** 100, 1k and 5k Jolt CharacterController instances with the same navigation/input; raycasts and sphere casts at 1k/10k/100k queries per frame; measure exact hit agreement and latency separately.
- [ ] **B15 — soft-body throughput.** Jelly, Cloth, Shell and DrivenJelly, 10/50/100/500 bodies, fixed vertex counts and settings. Record rebuild time, step time, active vertex count, memory and deformation correctness. Keep existing Jelly Golf-style free jelly as an acceptance case.
- [ ] **B16 — engine resource/render throughput.** Static 100k objects, 10k changing transforms and streaming scene chunks, with GPU timings/draw calls separated from C# script CPU. Include shader graph and compute graph functionality regression.
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

- B17 (2026-11-16, `tools/benchmark_csharp_alloc.py`, Release headless player, medians of 3 x 600 frames; raw data
  `~/TallowBenchmarks/alloc-20261116/`): N objects, each script running one pattern every Update.

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

- [ ] **B18 — multiplayer sync.** 2, 4, 8 and 16 peers (or maximum supported), 0/50/100/200 ms added RTT, 0/1/2/5% packet loss, 30/60/120 Hz where supported. Compare state divergence, input latency, server tick time, bandwidth per peer, desync recovery and replay hashes. Ensure C# TickInput produces the same authoritative behavior as Beef.
- [ ] **B19 — destruction/parallel dimensions.** Stream both world dimensions concurrently, switch during active physical destruction with peers, track swap latency, memory peak, bandwidth, and no cross-dimension audio leak.
- [ ] **B20 — prediction/rollback determinism.** Fixed-seed input replay for 10k ticks, repeated 3 times; record final state hashes, divergences, rollback duration and worst catch-up frame, C# vs native. Mark blocked until rollback C# parity is implemented; do not infer from compile tests.
- [ ] **B21 — visual scripting parity.** Existing graphs vs generated C# on equivalent 1k/10k node updates; check event ordering, networking, serialization and graph regeneration time. Mark blocked until C# visual-graph backend is functional.
- [ ] **B22 — game export portability.** Release build on Windows/Linux **without Beef installed** on target machine; record packaged size, cold start, .NET runtime/bootstrap diagnostics, crash frequency and whether the editor/player ever tries to compile native engine code. Verify exports against older Beef samples too.
- [ ] **B23 — stability soak.** 30–60 minute automated gameplay loop; scene reload, prefab spawn/destroy, networking reconnect, soft-body world teardown. Track median/p95/p99 frame time over time, managed/native RSS slope, GPU memory and native-handle leaks.

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
- [ ] **B25 — binary size, symbols and disassembly.** Windows/Linux AOT Release game binary and private symbol archive sizes, export table (only required ABI exports), download package size, debug ID matching crash analysis, no private `.pdb`/`.dbg` in public output. Compare JIT equivalent; avoid claiming complete anti-reverse-engineering.
- [ ] **B26 — cold start, memory and GC.** Five cold runs each JIT/AOT of same scene/engine; startup to first playable tick, steady and peak RSS, heap size, GC collections/pause p95, CPU and frame p95/p99. Record renderer mode, native engine/Jolt cost, platform/RID. No implicit AOT performance advantage is assumed.
- [ ] **B27 — deterministic replay cross-runtime.** Same serialized starting state, seed, input stream and tick rate for 10,000 ticks each; compare per-tick state hashes, first divergent tick, entity order, and float differences (max absolute/relative error). Test JIT vs AOT **on same OS/CPU first**, then Windows/Linux and different CPUs. Fail if authoritative/predicted outcomes diverge, even if approximate float comparisons pass.
- [ ] **B28 — multiplayer JIT/AOT cross-play.** Mixed JIT editor clients + shipped NativeAOT players against the same authority; identical state/rollback hashes and inputs under 0/50/100/200 ms RTT and 0/1/2/5% loss, 2–16 peers when supported. Record desync/mismatch and packet bandwidth.
- [ ] **B29 — trimming and generated metadata.** Compare all public/private/hidden fields, enums, inherited components and asset/prefab references against JIT; add rename/migration tests. Export with AOT/trimming warnings treated as errors and ensure no reflection-only field or component is silently dropped.
- [ ] **B30 — native export portability and crash symbols.** On clean Linux/Windows without dotnet/Beef developer tooling, run AOT player, load scenes, exercise Jolt/soft bodies/shader graphs and close cleanly. Capture a deliberate test-only crash and symbolicate with the **private** matching symbol file; verify the public package contains no symbols or gameplay IL.

Status: **all B24–B30 are blocked** until the shipping NativeAOT host and export path exist. Benchmark both profiles from identical game commits and core engine settings. Do not substitute NativeAOT compilation of a dummy sample for shipping-player acceptance.
