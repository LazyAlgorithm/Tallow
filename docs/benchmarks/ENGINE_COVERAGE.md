# Tallow engine-wide benchmark suite (ECS branch)

**Branch:** `ecs-benchmarks` (based on `ecs`). This is a feature branch, not merged into `ecs`.

This plan was built from the engine's source tree, `Samples/EcsBench`, `EcsChecks`, the profiling APIs and `tools/run_ecs_bench.py`. It separates measurements that **run now** from those that **require new fixtures**. Never report an unimplemented performance category as tested.

## Run on Linux

```bash
cd /home/zerker24/GitWorktrees/tallow-ecs
git fetch origin
git switch -c ecs-benchmarks --track origin/ecs-benchmarks
bash tools/run_engine_bench.sh --pull --preset quick
# After the smoke suite works:
bash tools/run_engine_bench.sh --preset standard
# Inspect planned and supported cases without building:
python3 tools/run_engine_bench.py --list
```

Requires Python 3.11+, CMake, Ninja, BeefBuild, a working Vulkan display/driver and the normal Tallow build dependencies. The shell runner rebuilds Release binaries when tracked files change or the branch commit changes. `--skip-build` reuses an existing binary; `--pull` fast-forwards the checked-out branch before building. Set `BEEFBUILD` if BeefBuild is not on PATH.

Outputs are saved in timestamped directories under `build/benchmark-results/`: `metadata.json`, `results.jsonl`, `summary.csv`, `summary.md`, `profiles.jsonl`, individual profile logs, `checks.json`, `failures.jsonl` on failures, `coverage.json` and `status.json`. All completed runs are appended immediately, even if a later test fails.

For reproducible comparisons use **Release** builds, a fixed resolution/quality setting, VSync off, a consistent power profile, an idle desktop, the same drivers and same processor. Run 3–5 times per case and compare medians. The standard preset comprises 56 graphics/frame configurations × 3 repeats, plus 6 CPU-only profile configurations and correctness suites. The stress preset is intentionally expensive and may exhaust memory.

## Implemented, instrumented benchmarks

| Engine area | Scenario/entry | Measures | Important limitations |
| --- | --- | --- | --- |
| Normal GameObject/script | `gameobject` | moving script components, full-frame and update cost, spawn, memory | MeshRenderer + Mover; not a pure dispatch microbenchmark |
| ECS, single-thread | `ecs` | packed MoveSystem, rendering, memory | explicit ECS program, not ordinary user scripts |
| ECS, parallel | `ecs-mt` | packed MoveSystem + Jobs workers | thread count is runtime-determined |
| ECS, static rendering | `ecs-static` | static ECS instance rendering | no moving components |
| Renderer, GameObjects | `render-static` | many MeshRenderers with no movement | GPU timestamp costs not yet separated |
| Script callback dispatch | `script-empty` | empty normal Update calls | deliberately no rendering or simulation work |
| Prefab instantiation | `prefab` | repeated prefab renderer + Mover | measures runtime instantiation and updates, not file IO |
| Integrated lightweight mix | `mixed` | scripts, prefabs, 1% kinematic bodies, 2% behavior trees, 5% offline NetworkIdentity | *not* Jolt saturation or live networking |
| AI behavior trees | `ai-tree` | behavior tree tick overhead on instances | no real navmesh, steering or path requests |
| NetworkIdentity (offline) | `net-offline` | identity registration and offline ticks | **zero network packets**, no latency/prediction conclusion |
| Jolt static colliders | `physics-static` | static body registration and maintenance | no dynamic contact solving, no renderer |
| Jolt moving/active | `physics-active` | non-sleeping dynamic rigidbody piles | no MeshRenderer; frame includes fixed-tick physics |
| Jolt sleeping | `physics-sleep` | same bodies allowed to sleep after extended warmup | check actual `sleeping_bodies` count before claiming speedup |
| Jolt kinematic | `physics-kinematic` | kinematic body overhead | stationary kinematic bodies, not velocity-driven |
| ECS CPU microprofiles | `--profile-ecs N` | packed query read/write, parallel update, handle lookup, 10% structural churn, spawn | no GPU, Scene or Jolt |
| Scene CPU microprofiles | `--profile-scene N` | GameObject creation, transform reads, in-memory scene save/load | no disk IO or editor interaction |
| Normal script CPU microprofiles | `--profile-scripts N` | empty dispatch, mover, transform read/write/rotation, GetComponent | stages are independent, not additive |
| Engine correctness | `--check-scripts`, `TALLOW_BENCH_MODE=check` | script callback/determinism and integration checks | pass/fail only, not performance numbers |

Frame results log mean, median, p95, p99 and p99.9 frame ms; update ms, spawn/despawn ms, memory RSS delta, draw calls, process CPU where supported, script time, and the scenario-specific body/tree/identity counters. `memory_before` and `memory_after` are whole-process RSS values. The Linux `tools/bench_allocations.c` shim is optional for libc allocation counts; custom allocator calls are not fully captured.

**Instrumentation gotchas:** (1) Frame time spans consecutive `Bench.Update` invocations and includes render submission and other engine work. (2) `update_avg_ms` spans different user-code workloads; it is not an isolated `PhysicsWorld.Step` or GPU profiler. (3) `physics_step_error` reports Jolt's capacity error bits, not the total number of contacts. (4) Offline NetworkIdentity does not measure traffic. (5) All scenarios start fresh player processes; caching effects and first-frame compilation may still differ between machines.

## Subsystems requiring dedicated benchmark fixtures

| Source folder / feature | Next test fixture | Metrics | Priority |
| --- | --- | --- | --- |
| `Engine/src/Net`, `Platform/ENet.bf`, `VoiceChat.bf` | server + 2/8/32 actual clients; 0/1/5% loss; 20/80/150 ms RTT; identity interest sweeps, prediction/rollback | server fixed-tick p99, outgoing B/s, correction and rollback counts, resim ticks, voice jitter | P0 |
| `Engine/src/AI/Navigation*` | baked navmesh, 100–10K agents, near/far path requests, avoidance ON/OFF | path requests/s, p99 path latency, avoidance CPU, success rates | P0 |
| `Engine/src/Render`, `Lighting`, `Water` | multi-material meshes, offscreen objects, GPU timing queries; light/shadow/postprocess and water passes | CPU render-extract, GPU ms per pass, draw calls, VRAM, visible pixels | P0 |
| `Engine/src/Animation`, `Rigging` | 100/1K/5K identical and varied rigs; IK, GPU skinning, animation blending | main/worker/GPU ms, bones per frame, memory, rig errors | P1 |
| `Engine/src/Physics/SoftBody.bf`, `Joint.bf`, `Rope.bf` | 10/100/1K deformable bodies; joints/rope chains, self-collision, static/dynamic impacts | solver ms, p99 physics, active contacts, stability | P1 |
| `Engine/src/Physics/PhysicsWorld.bf` | 1K/100K raycasts & overlaps/shape casts against sparse/dense scenes | queries/s, p95/p99 query latency, hit correctness | P1 |
| `Engine/src/Scene/WorldStreaming.bf` | deterministic camera/stream source path across 5/50/200 cells | cell load ms, hitch p99.9/max, peak RSS and reclaim, seam correctness | P1 |
| `Engine/src/Voxel` | terrain generation, chunk remesh after destructible edits, collision rebuild, voxel save/load | chunk ms, triangles/s, physics updates, memory, latency | P1 |
| `Engine/src/Assets`, `tools/pack_assets.py` | cold/warm asset pack load, import/convert, texture/model compression and packaging | load time, throughput MB/s, disk bytes, peak RSS | P1 |
| `Engine/src/Audio` | 8/32/128/512 active 2D/3D sources and HRTF; streaming | mixer CPU, underruns, latency, memory, voices | P1 |
| `Engine/src/UI`, `Input` | 100/1K/10K elements, text/layout, pointer hit-test, scrolling | layout ms, draw calls, event dispatch latency | P2 |
| `Engine/src/Dialogue`, `Sequence`, `Saving` | many simultaneous state machines, sequence tracks, save/load sizes | tick latency, serialization throughput and data equality | P2 |
| `Engine/src/Scripting`, Editor hot reload | reload 100/1K/10K scripts after field/API edit | compile+reload duration, state migration, failure/recovery | P2 |
| `Editor/src` | inspect a large scene, duplicate/delete, Play transition, undo/redo | click-to-response, frame hitches, editor memory | P2 |
| `Engine/src/Modeling` / `Rigging` | hard-surface edits, painting, meshes, auto-rig on reproducible assets | edit/mesh time, GPU uploads, generated data size | P2 |
| `tools/build.py`, shaders, launcher | clean/incremental builds and project packaging | wall time, CPU sec, artifacts size | P2 |
| Windows/macOS/Web | match fixed workloads and test player build correctness on each platform | median+p99, state hashes, binary footprint | P2 |

## Validation and acceptance criteria

1. Every case must have a **specific fixed seed/fixture**, object count, configuration and expected state check. A scene that merely spawns `NetworkIdentity` or `NavigationAgent` cannot be described as simulated multiplayer or pathfinding.
2. Capture process identity (git SHA, dirty state, OS, CPU, GPU/driver, count, warmup, frames, repeated run number). Do not mix editor Debug and player Release results.
3. A missing/mismatched JSON row, timeout, crash or failed correctness check makes the run fail and leaves a log. No fabricated zeroes.
4. Use minimum three runs and per-run medians for performance discussion; preserve p99/99.9 as distributions, not inferred FPS. For high-percentile hitch studies collect at least 10K frames.
5. Compare normal GameObject workflows to advanced ECS paths **as different programming models**. Benchmark Jolt alone before attributing physics-limited frame rates to ECS. Use separate sleeping and awake-body counts.
6. Match scene contents, render path, physics contacts and network load when making public cross-engine claims. A single instanced draw call cannot stand in for a typical complex game.
7. On Linux, run the quick preset first to validate new Beef fixture compilation and check all cases; then capture standard results. This branch has not yet been compiled or executed on the owner's GPU in the connected environment.

## Recommended next implementation sequence

**P0:** (1) real network two-client test with simulated loss, (2) navmesh crowd stress, (3) renderer GPU timestamp instrumentation. **P1:** (4) voxel/world streaming, (5) soft bodies and joints, (6) animation/IK/skinning, (7) audio mixing. **P2:** (8) editor/modeling/visual scripting and platform automated runs. Each new fixture should add a `MODE_GROUPS` entry (or headless profile), validate output, and become eligible for the single runner without changing the reporting format.
