# ECS-first AI and navigation roadmap

Branch: `ecs-ai-navigation` (based on `ecs-unified-authoring-network`, itself based on `ecs`).
Track this work separately from `ecs` until the Linux build and multiplayer regressions pass.

## Product contract

A Tallow developer adds a **Behavior Tree Runner**, **Navigation Agent**, **Animator**,
optional **Character Controller/Rigidbody**, and ordinary script or ECS components to the
**same GameObject**. They use the existing Behavior Tree editor, `.tbt` assets,
`Blackboard`, `NavigationAgent.SetDestination()`, prefabs and visual script nodes.
Tallow manages ECS storage, AI scheduling, navigation, authoritative simulation and
replication. No second AI authoring workflow and no required ECS/networking boilerplate.

A dedicated server must be able to simulate crowds without rendering them. Multiplayer
clients should normally **not** run authoritative AI decisions, navigation searches, crowd
steering or avoidance. They display relevant replicated objects with interpolation and
supported animation/gameplay state. Local-player prediction stays separate from NPC AI.
A listen server does both server work and client rendering.

**Performance goal:** scalability without sacrificing correctness, not a promise that
10,000 complex agents at 60 FPS is achievable on any host. Measure navigation cost,
tree evaluation, physics, replication bandwidth, and client rendering independently.

## Architecture

```
Visual Behavior Tree + Inspector + Script + ECS Components
             |
    Scene Frame / Network Tick Pipelines
             |
  [AI scheduler + state in Flecs ECS]
       |                  |
  [Perception]       [Behavior Tree]
       |                  |
       +--------> [Navigation requests]
                  [Path batching / route cache]
                  [Crowd steering and avoidance]
                           |
              Jolt / Controller / Transform
                           |
         Authoritative snapshot + [Sync] results
                           |
                 Relevant remote clients
```

## Work stages and acceptance gates

### 0. Baseline and compatibility [ ]
- [ ] Get a clean Linux compile and `TALLOW_BENCH_MODE=check` pass on the
  unified-ECS parent branch; do not mistake untested code for a passing baseline.
- [ ] Capture current AI and navigation timings, path visits, AI tick counts, and
  host/client bandwidth for representative worlds. Include per-frame spikes.
- [ ] Add a dedicated automated AI/network regression mode and reproduce the
  current navigation/behavior baseline, including save/load and disabled state.

### 1. ECS-driven AI and navigation scheduling [in progress]
- [x] **Existing**: `BehaviorTreeRunnerData` and `NavigationAgentData` live
  in Flecs; their public handles and runtime classes keep old APIs.
- [x] **Existing**: frame/tick steps are part of Flecs pipelines; navigation path
  requests can be processed on worker threads.
- [x] Replace scene-wide handle discovery in BehaviorTreeRunner.FrameAll with the
  scene's cached ECS handle query.
- [x] Replace scene-wide handle discovery in NavigationAgent.FrameAll with the
  same ECS query path (TickAll already used it).
- [x] Handle enable/disable and hierarchy deactivation through existing
  `OnSwitched` hooks so disabled runners do not need to be scanned every frame.
- [ ] Verify state transitions and deterministic scheduling order with live
  server/client, play-stop-play, object reuse, and hot reload.

### 2. Shared AI perception and obstacle indexing [planned]
- [ ] Index relevant target positions/tag/name categories in a scene-owned
  spatial index; eliminate `BTSenses.Find()`'s per-AI full scene scan.
- [ ] Index dynamic Navigation Obstacles; eliminate `NavigationAgent.Avoid()`'s
  per-agent obstacle scan.
- [ ] Use efficient, thread-safe snapshots of positions/velocities for
  perception and avoidance, preserving the current line-of-sight rules,
  `#Tag`, prefix name patterns and inactive-world filtering.
- [ ] Batch raycasts where safe and expose separate broadphase/narrowphase
  profiler counters and configurable per-frame budgets.

### 3. ECS-first tree runtime [planned]
- [ ] Compile each `.tbt` definition once into a shared, indexed layout/bytecode;
  separate mutable per-agent state from immutable tree definitions.
- [ ] Store hot runner state (node status, last tick, timers, blackboard numeric
  values, event metadata) compactly in ECS-owned storage. Pool variable-length
  paths, strings, event queues and custom-node state rather than copying
  owning objects into Flecs tables.
- [ ] Preserve all composite/decorator semantics, reactive interruption,
  subtrees, random selectors, events, editor live tracing, hot reload, and
  custom `BTNode` classes.
- [ ] Explicit fallbacks for user-defined actions that touch GameObjects or
  non-thread-safe engine APIs; never run those on worker threads implicitly.

### 4. ECS-first navigation and crowd movement [planned]
- [ ] Keep `NavigationAgentData` as editable ECS settings; migrate hot
  destination, waypoint, velocity, timers, request flags, and avoidance inputs
  into packed data where measurements warrant it.
- [ ] Reuse existing parallel `NavigationData.FindPaths` workers, Detour/NavMesh,
  grid backend, smooth paths, off-mesh links, and route cache.
- [ ] Build spatial neighbors/obstacle inputs once per stage and batch independent
  candidate-velocity evaluation. Threading cannot mutate Jolt, Transform or
  shared lists unsafely.
- [ ] Apply computed motion through Character Controller, Rigidbody, or Transform
  in a deterministic simulation stage without changing the public API.
- [ ] Keep agents responsive after disable/enable, changes to surface, links,
  world states, and moving obstacles.

### 5. Automatic authority and replication [planned]
- [ ] Preserve server-only `BehaviorTreeRunner.Frame` and
  `NavigationAgentState.Frame/Tick`; remote clients must not run AI decisions,
  path requests or crowd steering.
- [ ] Ensure common prefabs and dynamic AI spawns automatically get network
  identity/lifecycle under the networking policy. A sync checkbox on every
  internal AI field is **not** the authoring requirement.
- [ ] Replicate relevant position/orientation, action state, animation,
  important gameplay parameters and appearance changes, not internal nav paths
  or complete blackboards by default. Provide explicit opt-in for additional
  gameplay state.
- [ ] Preserve client prediction/reconciliation for owned players, while AI
  remains server authoritative. Validate rollback order if AI shares a pipeline
  with predicted player gameplay.
- [ ] Native entity-only `World.CreateMany<T>` still requires its own direct
  replication, spawn/despawn and interest handling from the unified-networking
  roadmap. No silent GameObject-per-entity expansion.
- [ ] Verify host, dedicated server, 2 clients, late join, relevance exit/return,
  disconnect/reconnect, despawn, packet delay/loss, and client-only rendering.

### 6. Adaptive scheduling without surprising gameplay [planned]
- [ ] Separate low-frequency *decisions/perception* from fixed-tick physical
  movement. Important events, nearby threats, attacks, collisions, link
  transitions and network authoritative actions still update promptly.
- [ ] Expose simple presets (Default / Crowds / Always Full Rate) rather than
  requiring developers to hand-author different AI scripts.
- [ ] Default safety: no silent reduction of gameplay critical logic; use
  distance/relevance/visibility based LOD only after determinism tests.

### 7. Performance, docs, release gate [planned]
- [ ] Host/server: run 100, 1k, 5k and 10k agents on reproducible scenes.
  Measure tree ms, perception ms, path searches/visits, avoidance ms,
  navigation ms, Jolt ms, allocations, p99 spikes and per-core CPU.
- [ ] Network: relevant entity counts, snapshot bytes/sec, messages/sec,
  replication latency and correction counts at 1, 2 and 8 remote clients.
- [ ] Clients: rendering, animation/skinning, physics, snapshot decode, memory,
  and draw calls independent of server AI simulation.
- [ ] Compare with `ecs` and the unified-ECS parent on identical scenes.
- [ ] Existing projects and `.tbt` files open without conversion. Update
  Editor docs, examples and screenshots. Merge only when the Linux tests and
  networking acceptance checklist pass.

## First patch and how to test

The first code patch targets **Stage 1**. It replaces O(scene objects) handle
searches for every frame's Behavior Tree and Navigation Agent scheduling with
the cached Flecs handle component query already used elsewhere in the engine.
The existing handle-switch callback is used to stop/abort state immediately
when a component or its hierarchy is disabled; this preserves behavior while
avoiding a separate full-scene scan for disabled components.

No behavior-tree algorithms, navigation algorithms, networking formats, APIs,
or tick ordering are intended to change in Stage 1.

For a reproducible local acceptance check, build the EcsBench sample in the
same Beef toolchain used for the engine, then run:
`TALLOW_BENCH_MODE=check Samples/EcsBench/build/Release_Linux64/EcsBench/EcsBench --project Samples/EcsBench`
See `tools/test_ecs_ai_linux.sh` for an update/build/test wrapper.

**Status notes:** Stages 2–7 are roadmap work, not implemented by the initial
patch. Explicit developer test results are needed before marking Stage 1 verified.
