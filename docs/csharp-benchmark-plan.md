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

- [ ] **B01 — precompiled editor cold start.** From launcher executable, record wall time and peak RSS until scene is usable for an empty C# project; repeat for a populated C# project. Repeat with and without a valid gameplay DLL. Opening a project must not invoke BeefBuild.
- [ ] **B02 — game C# cold compile.** Remove the generated `.tallow-csharp` folder **only from a disposable copy of `Tests/CSharpGameplay`**, compile with `TallowLauncher --build-project PATH`, log elapsed time and errors; repeat x5.
- [ ] **B03 — warm/no-op compile.** Rebuild the same untouched disposable game five times; separately edit one C# script body (add a harmless comment) and rebuild five times. Record time from Save to compilation banner disappearance and from Save to first permitted Play.
- [ ] **B04 — invalid C# recovery.** Open intentionally invalid source; measure editor launch/diagnostics latency, Play disabled, recovery after fixing source, and whether the next successful edit is used. Include two rapid saves while a build is in progress.
- [ ] **B05 — semantic editor latency.** Measure initial Roslyn worker startup, 100 steady-state completions, 100 diagnostics, nullable `Rigidbody?.` completion, type coloring and rename/definition queries in a small vs large (100+ file) source project. Record p50/p95/p99 response time and CPU/memory.
- [ ] **B06 — managed runtime bootstrap and lifecycle.** Measure Play entry/exit for 0, 100, 1,000 and 10,000 lightweight C# Script instances. Run 100 Play/Stop cycles; check memory growth, duplicate callbacks, invalid handles and retained managed instances.
- [ ] **B07 — scalar versus batched managed callbacks.** Run existing `Tests/NativeCSharpHost` `--benchmark` on matching builds; record raw per-callback cost and batch sizes 1, 16, 128, 512, 4096, separately for no-op Fixed/Late and distinct TickInput. **Do not switch the Scene scheduler automatically based only on mock-host speed.** Require real-editor profiler data, callback order, detach/disable and network replay equivalence.
- [ ] **B08 — component access latency.** Compare `GetComponent<T>()` and `TryGetComponent<T>()` for native Rigidbody/Transform vs managed Script, hit and miss, using 100k–1M calls after warm-up. Verify disabled and destroyed handles fail safely.
- [ ] **B09 — Inspector scene/prefab save.** With 1,000/10,000 managed field instances: attach, edit public/private/hidden fields, save/reopen, enter Play and measure time plus serialized file sizes. Verify fields applied before Awake and prefab inheritance intact. Test failure with invalid persisted values.
- [ ] **B10 — native ABI/CI parity.** Run generated binding manifest verification and the managed/native host smoke tests; save pass/fail and exact SHA on Linux and Windows. Confirm the linked engine exposes only annotated CSharpExpose members.

## P1 — simulation throughput (run after API semantics pass)

- [ ] **B11 — ECS data-only baseline.** 10k, 50k, 100k and 250k static/rotating entities; native Beef ECS system vs managed C# workload over the **same Flecs data**. Report ECS iteration/query time, frame times, allocations, memory and render draw-call limits. Do not present a renderer bottleneck as an ECS result.
- [ ] **B12 — ECS writable chunk path.** Read and write the same 10k/100k position-like components with a bulk API; measure copy cost, boundary transitions and total tick. Mark *blocked* until C# writable typed Flecs queries/chunks are implemented; current Rigidbody-mass bridge is read-only.
- [ ] **B13 — physics sphere pile.** Spawn Jolt rigidbodies at fixed intervals until p95 frame time >16.67 ms, or max 10k. Record total, active/asleep counts, contact pairs, Jolt step milliseconds and memory. Repeat sleep ON/OFF; compare Beef vs C# control paths with identical native Jolt settings.
- [ ] **B14 — character motion/physics queries.** 100, 1k and 5k Jolt CharacterController instances with the same navigation/input; raycasts and sphere casts at 1k/10k/100k queries per frame; measure exact hit agreement and latency separately.
- [ ] **B15 — soft-body throughput.** Jelly, Cloth, Shell and DrivenJelly, 10/50/100/500 bodies, fixed vertex counts and settings. Record rebuild time, step time, active vertex count, memory and deformation correctness. Keep existing Jelly Golf-style free jelly as an acceptance case.
- [ ] **B16 — engine resource/render throughput.** Static 100k objects, 10k changing transforms and streaming scene chunks, with GPU timings/draw calls separated from C# script CPU. Include shader graph and compute graph functionality regression.
- [ ] **B17 — real managed allocations.** With 1k/10k/100k Script updates, record managed bytes/frame, collections (Gen0/1/2), pause time and peak RSS. Compare allocation-free value math, event allocation, GetComponent in loops and managed/native string calls.

## P2 — networking, export, regression (cannot be substituted by a local microbenchmark)

- [ ] **B18 — multiplayer sync.** 2, 4, 8 and 16 peers (or maximum supported), 0/50/100/200 ms added RTT, 0/1/2/5% packet loss, 30/60/120 Hz where supported. Compare state divergence, input latency, server tick time, bandwidth per peer, desync recovery and replay hashes. Ensure C# TickInput produces the same authoritative behavior as Beef.
- [ ] **B19 — destruction/parallel dimensions.** Stream both world dimensions concurrently, switch during active physical destruction with peers, track swap latency, memory peak, bandwidth, and no cross-dimension audio leak.
- [ ] **B20 — prediction/rollback determinism.** Fixed-seed input replay for 10k ticks, repeated 3 times; record final state hashes, divergences, rollback duration and worst catch-up frame, C# vs native. Mark blocked until rollback C# parity is implemented; do not infer from compile tests.
- [ ] **B21 — visual scripting parity.** Existing graphs vs generated C# on equivalent 1k/10k node updates; check event ordering, networking, serialization and graph regeneration time. Mark blocked until C# visual-graph backend is functional.
- [ ] **B22 — game export portability.** Release build on Windows/Linux **without Beef installed** on target machine; record packaged size, cold start, .NET runtime/bootstrap diagnostics, crash frequency and whether the editor/player ever tries to compile native engine code. Verify exports against older Beef samples too.
- [ ] **B23 — stability soak.** 30–60 minute automated gameplay loop; scene reload, prefab spawn/destroy, networking reconnect, soft-body world teardown. Track median/p95/p99 frame time over time, managed/native RSS slope, GPU memory and native-handle leaks.

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
