# ECS migration plan

Tallow's runtime moves from heap-allocated GameObjects and Components to an entity component system built on
[Flecs](https://github.com/SanderMertens/flecs). Game code keeps the Unity-style model: GameObjects, scripts
with `Update`, `GetComponent`, prefabs, the Inspector. The ECS is how the engine stores and runs things, not
something a game developer has to learn.

This is a breaking change. No compatibility aliases or old-format readers are kept; samples and templates are
rebuilt against the new runtime.

Work through the phases in order. Each phase ends with the engine building (`./build.sh` or `build.ps1`), the
Showcase passing `tools/validate_showcase.py` once it has been ported, the code formatted
(`tools/format/format_code.py`), and a commit on the `ecs` branch.

## Goals

1. **Scripting stays as close to Unity as possible.** A Unity developer opens a script and recognises
   everything. Nobody has to write a query or a system to make a game. Unity DOTS's learning curve is the thing
   to avoid.
2. **The engine scales.** Transforms, rendering, physics sync, animation, particles, AI crowds and network
   state live in packed Flecs tables and are processed in bulk, on several threads where it is safe.
3. **Networking gets simpler and cheaper.** Snapshots, rollback, delta compression and interest management
   work on component columns instead of walking each object's fields.
4. **Game code rarely touches memory management.** The gameplay API avoids handing scripts heap objects to free.

## What a game developer sees

### Scripts: the normal way to write game code

```beef
[Component]
class Wanderer : Script
{
	[Range(0, 10)] public float speed = 3;
	public GameObject target;

	public override void Update()
	{
		if (!target)
			return;
		Transform.LookAt(target.Transform.Position);
		Transform.Position += Transform.Forward * speed * Time.DeltaTime;
	}
}
```

- `Script` replaces `Component` as the base class for behaviours. The lifecycle is unchanged: `Awake`,
  `OnEnable`, `Start`, `FixedUpdate`, `Update`, `LateUpdate`, `OnDisable`, `OnDestroy`, `OnGUI`.
- `NetworkScript` keeps `OnTick(TickInput input, float deltaTime)` with the same rules as today.
- Script fields, `[ShowInInspector]`, `[HideInInspector]`, `[NonSerialized]`, `[Range]`, `[Layer]` all work
  as now.
- Scripts are ordinary Beef classes owned by the engine. The engine creates and deletes them; their fields
  are saved, migrated on hot reload and shown in the Inspector exactly as today.
- Scripts run on the main thread, in a predictable order, so there are no threading rules to learn.

### Built-in components: same names, now handles

`Transform`, `Rigidbody`, `MeshRenderer`, `Light`, `Camera`, `AudioSource` and the other engine components
keep their names and their properties. Under the hood each one is a small handle struct (the entity plus the
component) whose properties read and write the Flecs data:

```beef
var body = GetComponent<Rigidbody>();
body.AddForce(.(0, 10, 0));
GetComponent<MeshRenderer>().Material = hurtMaterial;
```

The data itself lives in plain structs (`RigidbodyData`, `MeshRendererData`...) that only engine code and
systems use.

### GameObject

`GameObject` becomes a value type: an entity id plus its world. It cannot dangle. A destroyed object is
simply not valid, and `if (obj)` / `obj.IsValid` checks that. `Instantiate`, `Destroy`, `SetActive`, tags,
layers, `Find...` and the hierarchy work as before. Fields of type `GameObject` or of a script type are saved
as entity references and can be dragged in the Inspector.

### Systems: the optional advanced tier

Systems are for when the profiler says a script is too slow because there are thousands of something. They
are documented under "Advanced", and the Showcase uses them in exactly one exhibit (a crowd or bullet storm),
next to the script version of the same thing.

```beef
[Component]
struct Velocity { public Vector3 value; }

[System(.Update)]
static class MoveSystem
{
	public static void Run(Query<Transform, Velocity> query, float deltaTime)
	{
		for (var chunk in query)
		{
			let transforms = chunk.Write<Transform>();
			let velocities = chunk.Read<Velocity>();
			for (int i < chunk.Count)
				transforms[i].position += velocities[i].value * deltaTime;
		}
	}
}
```

Rules for this tier: data components are structs with no heap fields (use `FixedString<N>`, `NameId`,
entity references, asset handles and engine buffers); systems declare what they read and write; systems that
don't conflict may run in parallel.

## Architecture

```
Game code      Scripts (classes, Update/OnTick)        optional Systems (queries over data)
                     │                                          │
Tallow API     GameObject / component handles / Time / Input / Physics / Net
                     │
Runtime        World (Beef wrapper) ── pipeline phases ── engine systems (transforms, render extract,
                     │                                    physics sync, animation, net snapshot)
Native         tallow_ecs.c shim ── Flecs (C)
```

### Native layer

- Vendor Flecs's single-file distribution (`distr/flecs.c`, `distr/flecs.h`) from the latest stable v4 tag
  into `third_party/flecs`. Add its license to `THIRD_PARTY_LICENSES.txt` (`tools/make_licenses.py`).
- Compile it into `tallow_native` from `native/CMakeLists.txt` as a custom build:
  `FLECS_CUSTOM_BUILD` with `FLECS_SYSTEM`, `FLECS_PIPELINE`, `FLECS_META`, `FLECS_OS_API_IMPL`, `FLECS_LOG`,
  plus `FLECS_REST`, `FLECS_HTTP`, `FLECS_STATS` and `FLECS_JSON` in Debug and editor builds only (they power
  the Flecs Explorer).
- Add `native/tallow_ecs.c`: a thin C shim so Beef never mirrors Flecs's large descriptor structs or C macros.
  It exposes plain functions: create a component from size/alignment/name, create a query from an array of
  ids and access flags, iterate tables, add/remove/get/set by id, ChildOf and prefab helpers, defer
  begin/end, running a pipeline, and the built-in ids (`EcsChildOf` and so on) as functions.

### Beef layer (`Engine/src/Ecs/`)

- `Flecs.bf`: `[CLink]` declarations for the shim only.
- `World.bf`: owns an `ecs_world_t`; one per Scene.
- `ComponentId.bf`: `ComponentId<T>.Id`, registered once per type via comptime from `[Component]` structs,
  passing size, alignment, name and field layout (for `FLECS_META`, the Inspector and serialization).
- `Query.bf`: `Query<T...>`, iterating tables as chunks with `Span`-style `Read<T>()` / `Write<T>()`.
- `SystemAttribute.bf` + registration: `[System(phase)]` classes found by reflection at startup; their
  `Run` parameters decide the query and the read/write access.
- `GameObject.bf`, component handle structs, and `Script.bf` (the engine-owned behaviour base class).

**Verify early (Phase 1):** that one `GetComponent<T>()` can serve both script classes and handle structs.
Use comptime dispatch on `T`, or fall back to two clearly named methods if Beef won't allow it cleanly.

### Frame and tick order

Tallow's own loop stays in charge of timing; Flecs pipelines are run by it:

| Tallow step | Flecs phase | What runs |
| --- | --- | --- |
| Frame start | `OnLoad` | input, network receive, streaming |
| Fixed tick (0..n per frame, `Time.TickRate`) | fixed pipeline | `NetworkScript.OnTick`, `FixedUpdate`, predicted systems, physics step, physics → transform sync |
| Update | `OnUpdate` | `Script.Update`, `[System(.Update)]` |
| Late update | `PostUpdate` | `LateUpdate`, animation, world transform propagation |
| Render | `PreStore` / `OnStore` | render extract (cameras, lights, renderers, particles), then bgfx submit |

Scripts are run by one engine system per callback. It walks per-type lists of scripts that override that
callback (as `Scene` does today with `mRunning`), sorted by type for cache friendliness.

### Threads

Engine systems may run multithreaded. Route Flecs's worker threads through `Jobs` (via Flecs's OS API task
hooks), or else give Flecs `Jobs.ThreadCount` threads and keep `Jobs` for non-ECS work. Never run both at
full width at once. Scripts and anything touching the editor stay on the main thread. Structural changes
(add, remove, destroy) made during iteration are deferred to the end of the phase.

### Transforms and hierarchy

- `Transform` data: local position, rotation, scale, plus a cached world matrix and a dirty flag.
- Parenting uses Flecs `ChildOf` pairs. One system propagates world matrices in hierarchy order (a cascade
  query), touching only dirty subtrees.
- Handle setters for world-space values (`Position`, `Rotation`) convert through the parent's matrix, as
  `Transform.bf` does now.

### Rendering, physics, audio, AI

- `Scene.Renderers`, `Lights`, `Cameras`, `Particles` lists and the `OnRegister` / `OnUnregister` bookkeeping
  are replaced by queries. Render extract builds the same draw lists the renderer uses today, so
  `Engine/src/Render` changes at its input boundary, not throughout.
- Physics: `RigidbodyData` holds the Jolt body id. Observers create and destroy bodies when the component is
  added or removed. After each step, one system copies Jolt poses into `Transform` in bulk, and kinematic
  bodies are pushed the other way.
- Audio, navigation agents, animators, particle emitters and voxel objects follow the same pattern: data
  component, observers for create/destroy, one system per update step.

### Networking

- `NetworkIdentity` becomes a data component, and `[Replicated]` marks data components (or fields) that sync.
- Per tick, replicated columns are copied into a ring buffer of snapshots. Delta compression compares against
  the client's last acknowledged snapshot, column by column (`NetCompression.bf` reused).
- Rollback restores columns from the snapshot, then re-runs the fixed pipeline: predicted systems and
  `NetworkScript.OnTick` for predicted objects. This replaces the per-object re-run in today's
  `NetworkManagerHistory`; lag compensation reads positions from the same history.
- Interest management: a spatial query per client picks which replicated entities it receives.
- Script fields marked for sync keep using the reflection-based path from `NetworkSync.bf`. Bulk state such
  as transforms and physics goes through columns.

### Scenes, prefabs, saving

- The scene file keeps one block per object with its components by name. Data components are written from
  their registered field layout, scripts as today. `SceneSerializer`, `SceneLoader`, `MapFiles` and `Saving`
  move to this format.
- Prefabs instantiate by copying an entity tree, keeping Unity semantics: instances own their values, and
  overrides are recorded against the prefab. Don't use Flecs `IsA` sharing for prefabs, because shared values
  surprise Unity users.
- Play mode: the editor serializes the world to memory when play starts and restores it on stop.
- World streaming loads and unloads entity groups by streaming cell.

### Editor

- Hierarchy reads `ChildOf`. The Inspector lists data components (from their field layout) and scripts (from
  reflection) in one list. Add Component offers both. Copy/paste, undo, drag-and-drop and multi-edit keep
  working through the same field-reference abstraction (`FieldLists`, `ComponentClipboard`).
- `ApiIndex` picks up the new types automatically. Add completion for the handle components' properties.
- Debug and editor builds can start the Flecs REST endpoint so the Flecs Explorer shows a running game's
  entities. Add a menu item to open it.
- The Profiler gets one marker per system and per script type (`ProfilerComponents` already does per-type
  markers).

### Hot reload

- Scripts: the existing `ScriptReload` and `ScriptStateMigration` path keeps working unchanged in principle.
- Data components or systems changed in a reload: serialize the world to memory, re-register components,
  rebuild queries and systems, deserialize. This is the same idea as `ScriptReloadStructural`.

### Gameplay API that avoids memory management

Part of this work, so new users rarely write `delete`:

- `FixedString<N>` and interned `NameId` for names and tags in components and APIs.
- An engine-owned dynamic buffer component, freed with the entity, for "a list on an object".
- A per-frame allocator (`new:Frame`) that is cleared at the end of the frame, for temporary strings and lists.
- Events through observers or engine message queues instead of delegates the caller must delete.
- Coroutine-style helpers for timed sequences, because Unity tutorials lean on `yield return`.
- Script editor warnings with quick fixes for C# habits: `foreach`, string `+`, `new` inside `Update` with no
  cleanup, `yield return`.

## Phases

Each phase lists its exit check. Sizes are relative: S, M, L.

### Phase 1: Proof of concept (S)

- Vendor Flecs, add the CMake build and `tallow_ecs.c`, write `Flecs.bf`, `World`, `ComponentId<T>`,
  `Query<T...>`.
- Add a `Samples/EcsBench` project that runs the same workload both ways: N objects with a position and
  velocity, bouncing in a box and spinning. Once with today's `Component.Update`, once with a system. N = 1k,
  10k, 50k, 100k. Report average and 99th-percentile frame time and memory, single-threaded and
  multithreaded. Render both with the existing renderer so the numbers include a real render extract.
- Answer the `GetComponent<T>` question above.
- **Exit:** benchmark numbers written into this document. Go/no-go decision on continuing.

### Phase 2: Core runtime (L)

- `GameObject` as an entity, `Script` as the behaviour base, the `Transform` handle and data, hierarchy,
  tags, layers, active state, world states, `Instantiate` / `Destroy`, the frame and tick order above.
- Replace `Scene`'s object and component lists with the world. Remove `Component`.
- **Exit:** an empty project and the Sandbox sample run with scripts and transforms. Port the Sandbox
  scripts (`Wanderer`, `SampleMenu`, `CharacterAnimation`) to show how small the change is.

### Phase 3: Editor and files (L)

- Inspector, Hierarchy, Add Component, clipboard, undo, prefabs, scene save/load, play-mode snapshot, hot
  reload for scripts and for data component changes.
- **Exit:** create, edit, save, reload and play a scene entirely in the editor; prefab instances survive
  edit → save → load → play.

### Phase 4: Rendering, physics, audio (L)

- Render extract from queries; Jolt sync; audio sources and listeners; lights, cameras, decals, particles,
  LOD, occlusion, foliage and water as data components.
- **Exit:** the Showcase's rendering and physics exhibits pass `tools/validate_showcase.py`.

### Phase 5: Animation, AI, everything else (M)

- Animator, IK, skinning, navigation agents, behaviour trees, dialogue, sequencer, voxel objects, spawn
  points, world streaming, saving.
- **Exit:** all Showcase exhibits pass.

### Phase 6: Networking (L)

- `NetworkIdentity` as data, column snapshots, delta compression, rollback through the fixed pipeline,
  `NetworkScript.OnTick` on top, lag compensation, interest management, host migration.
- **Exit:** networked Showcase exhibits pass. Measure a dedicated server with many replicated entities and
  several simulated clients, before (from `main`) and after.

### Phase 7: Scripting experience (M)

- The low-allocation gameplay API, coroutine helpers and editor quick fixes above.
- The Systems tier documented as advanced, with the Showcase crowd exhibit in both styles.
- **Exit:** a new project's template scripts contain no `delete`, `scope` or queries.

### Phase 8: Docs and release (M)

- Update every page in `docs/` that mentions `Component`, `OnRegister` or scene lists. Add `docs/ecs.md`
  (how the engine works inside) and `docs/systems.md` (the advanced tier). Update `README.md`,
  `RELEASE_NOTES.md` and the API docs (`tools/generate_api_docs.py`).
- **Exit:** CI green on Windows, Linux and macOS; release candidate built.

## Risks and decisions

- **Half-converted engine.** Work on the `ecs` branch and keep `main` releasable. Merge only after Phase 5
  at the earliest, or Phase 6 if networked games are the priority.
- **Script speed is unchanged, not improved.** Scripts stay per-object virtual calls, about today's cost. The
  gains come from engine systems and from moving hot gameplay to the Systems tier when the profiler says so.
- **Adding or removing components often is slow** (entities move between tables). Use enabled flags or Flecs
  toggles for things that switch on and off often.
- **Determinism for rollback.** Predicted systems must be deterministic within a build: fixed tick, no
  frame-time dependence, ordered iteration. Document this next to `OnTick`'s rules.
- **Flecs upgrades.** Pin the tag in `third_party/flecs` and keep the shim small, so an upgrade only touches
  `tallow_ecs.c`.
- **Possible later addition:** a second scripting language (C# or Luau) can bind to the same component
  registry and handles. Nothing in this plan blocks it.

## Phase 1 results (2026-11-04)

### What was built

- `third_party/flecs`: Flecs **v4.2.0**. Phase 1 started on v4.1.6 and moved to 4.2.0 the same day. The
  differences that matter here:
  - 4.2 has no deferred mode on the world, so `ecs_defer_begin` / `ecs_defer_end` are gone. Changes are queued
    by passing a *stage* instead of the world, and applied with `ecs_merge`. `World.DeferBegin` / `DeferEnd`
    keep their meaning by sending changes to stage 0 and merging it at the last `DeferEnd`. A system queues
    its changes on `it->stage` (`Flecs.IterStage`).
  - Cached queries, query plans, prefabs and frame functions are now addons, so the custom build turns on
    `FLECS_CACHED_QUERIES`, `FLECS_QUERY_PLANS`, `FLECS_PREFAB` and `FLECS_FRAME`.
  - `ecs_entity_desc_t` no longer has `.add`, so the shim adds a system's phase after creating it.
- `TALLOW_BENCH_MODE=check` runs `Samples/EcsBench/src/EcsChecks.bf`: set/get, deferred changes during
  iteration, `ParallelFor` coverage and delete. All of them pass in Debug and Release.
- `native/tallow_ecs.c`, built into `tallow_native` as the `tallow_flecs` object library. Release native builds
  leave out the Explorer addons unless `-DTALLOW_FLECS_EXPLORER=ON` is set. `tools/build.py` always builds the
  native libraries as Release, so the editor needs that flag to get the Explorer.
- `Engine/src/Ecs/`: `Flecs.bf` (shim declarations), `World.bf` (`World`, `Entity`), `ComponentId.bf`, `Query.bf`
  (`Query<T1>` to `Query<T1, T2, T3, T4>`, `Chunk.Read<T>()` / `Write<T>()`, `ParallelFor`).
- `[Component]` may now go on structs.
- `RenderView.InstancedSources`: a minimal render extract hook. Each source hands over runs of matrices for
  one mesh, which are culled and drawn like foliage, in runs and without sorting. Phase 4 replaces it with the
  real extract.
- `Samples/EcsBench` and `tools/run_ecs_bench.py`.

### Decisions made while building it

- **Component ids:** Flecs ids belong to one world, so `ComponentId<T>.Index` is a global index, and
  `world.Id<T>()` turns it into that world's Flecs id the first time it is used. Field layouts are not passed
  to `FLECS_META` yet; that comes in Phase 3, when the Inspector needs them.
- **Threads:** `Query.ParallelFor` runs on Tallow's `Jobs` threads. The world goes read-only, each thread uses
  its own Flecs stage, and `ecs_worker_iter` splits each table between the threads. Flecs's own thread pool is
  not used, so the two never compete for cores.
- **Query arity:** Beef has no variadic generics, so there is one class each for one to four terms.
- **`GetComponent<T>`:** answered: one name works. Beef picks between overloads by their constraints, so
  `GetComponent<T>() where T : Script` and `GetComponent<T>() where T : struct, IComponentHandle` live side by
  side. Checked with BeefBuild 0.43.6.

### Benchmark

These are Release builds on an AMD Ryzen 9 7900X (24 threads) with an RTX 3070 and Vulkan, at 1600×900 with
vsync off. Each run measured 600 frames after a 120-frame warm-up. "GameObject" is the engine as it is today:
one GameObject per cube with a `MeshRenderer` and a `Mover` component. The ECS runs used 1 thread and
`Jobs.ThreadCount` = 16 threads. Run it with `tools/run_ecs_bench.py`.

Frame time, avg / p99 (ms), from one Update to the next (includes the render extract and the submit):

| Objects | GameObject | ECS 1 thread | ECS 16 threads | Memory growth GameObject / ECS |
| --- | --- | --- | --- | --- |
| 1,000 | 0.28 / 0.60 | 0.23 / 0.68 | 0.23 / 0.65 | 23 MB / 22 MB |
| 10,000 | 1.82 / 1.96 | 1.05 / 1.08 | 0.74 / 1.29 | 40 MB / 27 MB |
| 50,000 | 16.30 / 16.76 | 4.64 / 4.71 | 2.96 / 6.39 | 116 MB / 49 MB |
| 100,000 | 33.77 / 35.90 | 9.28 / 9.61 | 5.83 / 7.34 | 197 MB / 66 MB |

Update time, avg / p99 (ms): every `Mover.Update`, or the move system:

| Objects | GameObject | ECS 1 thread | ECS 16 threads |
| --- | --- | --- | --- |
| 1,000 | 0.03 / 0.04 | 0.04 / 0.05 | 0.03 / 0.07 |
| 10,000 | 0.39 / 0.40 | 0.45 / 0.47 | 0.11 / 0.15 |
| 50,000 | 1.80 / 1.85 | 2.12 / 2.13 | 0.38 / 0.45 |
| 100,000 | 3.52 / 3.59 | 4.19 / 4.34 | 0.72 / 0.90 |

These are Flecs 4.2.0 numbers. The same runs on 4.1.6 were within run-to-run noise of these.

Spawning 100,000 objects took 119 ms as GameObjects and 17 ms as entities.

Reading the numbers:

- The ECS system's update also builds each cube's world matrix. The GameObject path builds its matrices later,
  during rendering, so single-threaded update times are about even, which is expected. Multithreaded, the
  system is about 5× faster.
- Most of the frame time saved comes from the render extract. The GameObject path walks every renderer and
  sorts the draws. The ECS path hands over columns that are already grouped. At 100,000 objects a frame is
  3.7× faster on one thread and 6× faster on 16.
- Memory growth is about a third of today's at 100,000 objects.
- With 16 threads, the 99th percentile at 50k (and on some runs at 100k) is about twice the average. Some frames lose time
  handing work to the `Jobs` threads. Look into this in Phase 2 (fewer, larger batches, or keeping the workers
  awake during the frame) before engine systems depend on `ParallelFor`.

**Go/no-go:** the numbers support going ahead with Phase 2. The final decision is the project owner's.

## Phase 2 progress

Goal for this phase, from the project owner: scripts work as close to today's as possible.

### Decisions

- **`GameObject` stays a class.** It is the engine-owned front for its entity, not the value type described
  under "GameObject" above. Beef treats `struct == null` as always false and lets no operator change that, and a
  class's `==` operator is ignored when comparing with `null`. A struct GameObject would silently turn every
  `target == null` in existing scripts into `false`. Dangling is handled as it is today: when an object is
  destroyed, `Scene` clears every script field and list entry that pointed at it, so `target == null` becomes
  true, as in Unity.
- **Scripts keep running in registration order**, not sorted by type as "Frame and tick order" suggests. Sorting
  would change the order of `Update` calls between scripts.

### Update: one signature, networked when the object is (project owner, 2026-11-04)

Every script writes the same `Update`, and the engine decides behind the scenes how it runs:

```beef
[Component]
class Hover : Script
{
	public float speed = 5;

	public override void Update(TickInput input, float deltaTime)
	{
		Transform.Position += input.MoveDirection * speed * deltaTime;
		if (input.Pressed(.Jump))
			Transform.Position += .(0, 1, 0);
	}
}
```

- **Without a Network Identity:** `Update` runs once per frame, as today's `Update()` does. `deltaTime` is the
  frame's `Time.DeltaTime`, and `input` holds this machine's controls for the frame. `input.previous` holds the
  last frame's, so `Pressed` and `Released` work.
- **With a Network Identity:** `Update` runs each tick at `Time.FixedDeltaTime`, exactly as `NetworkScript.OnTick`
  does now. That means running on the server, predicted on the controlling player's machine, and run again
  after a correction. `input` holds the controlling player's controls for that tick. Objects no player
  controls (NPCs, doors, pickups) get an empty `input` and run on the server only; clients see the result.
  Host mode needs care here: the host's player and server objects both have `ownerId` 0 today, so "controlled
  by a player" must become its own flag on `NetworkIdentity`, set when an object is spawned as a player or given
  to one. That way NPCs don't receive the host's controls.
- **`OnLocalUpdate()`:** runs every frame on every object, networked or not, for work that is only for this
  machine: effects, UI, camera feel. It replaces today's frame `Update()` wherever that work must not be
  networked. Engine components that override `Update()` today (8 of them) move to `OnLocalUpdate()`, so they
  behave exactly as before.
- **`OnTick` goes away.** `NetworkScript` keeps its mouse look and `ReadInput`, and its per-tick code moves to
  `Update`.
- **`FixedUpdate` and `LateUpdate` are unchanged:** fixed-step physics work, and once per frame after every
  `Update`.
- The `OnTick` rules apply to `Update` on a networked object: take controls from `input`, not `Input`, and guard
  one-off effects with `if (IsServer)` or `if (!IsReplaying)`. The script editor should warn about `Input.`
  inside `Update` on a script whose object has a Network Identity.
- Breaking change: `override void Update()` becomes `override void Update(TickInput input, float deltaTime)`.
  The samples and templates are ported in this step.

### Steps

- [x] **1. An entity for every GameObject.** `Scene.World` holds one entity per object (`GameObject.Entity`),
  with `ObjectLink` pointing back to the object, `ChildOf` following `Transform.SetParent`, and an `InactiveSelf`
  tag while `ActiveSelf` is false. The entity is deleted with its object. Checked by `EcsChecks.SceneChecks`;
  the Sandbox runs.
- [x] **2. Transform data in the entity.** `TransformData` (local pose, cached world matrix and rotation,
  dirty flags) lives in the object's entity. `Transform` keeps its API and reaches the data through a
  `ComponentRef<T>`, a Flecs `ecs_ref_t` whose version check is done inline in Beef, so the common case makes no
  call into C. The shim is built inside `flecs.c`'s translation unit (`native/tallow_flecs.c`) so it can read
  the world's table versions without changes to the vendored files. Checked by `EcsChecks`; the Sandbox runs in
  game and editor.
  - Cost: none measurable. Release GameObject benchmark at 100,000 objects, run interleaved with a build of the
    pre-Phase-2 commit on the same machine. Frame / script update in ms: original 30.87 / 5.20, 31.49 / 5.35,
    32.16 / 5.53; now 31.57 / 5.54, 31.34 / 5.36, 30.67 / 5.25.
  - A `Transform` object must stay small. A first version kept a 136-byte fallback copy inside every
    `Transform`, which split the fields used on every access across cache lines and made 100,000-object scripts
    about 2× slower. The fallback now lives on the heap, only while the object is in no scene.
  - Single benchmark runs vary a lot between sessions (the same build gave 3.5 to 9 ms of script update at
    100,000). Compare builds with interleaved runs, not against numbers from another session.
  - `ComponentRefStats.SlowPath` counts references that had to be refreshed. The benchmark reports it per
    frame; it stays in the hundreds against millions of accesses.
- [x] **3. `Script` and the new `Update`.** Done as designed in "Update: one signature" above:
  - `Script` (Engine/src/Scene/Script.bf) is the base for game scripts; templates, the generated new-project
    scripts, the editor's New Script and script graphs use it. `Component` stays underneath until step 4 and
    Phase 4 move engine components to data.
  - `Update(TickInput input, float deltaTime)` replaces both the old `Update()` and `NetworkScript.OnTick`. On an
    object with a `NetworkIdentity` it runs once per tick: in a session from the network's simulation (server,
    the owner's prediction and replays), offline from `Scene.FixedUpdate`. Elsewhere it runs once a frame with
    this machine's controls (`LocalControls`).
  - `NetworkIdentity.playerControlled` (on by default, off for objects spawned with `Adopt`, set on player
    spawns): objects no player controls get empty controls, so NPCs no longer get the host's input. A dedicated
    server now runs its own objects (`SimulateOwned(0, default)`) instead of never ticking them.
  - `OnLocalUpdate()` is the per-frame, never-networked call; the engine's own components that used `Update()`
    moved to it, and the profiler times it separately.
  - Script graphs: On Update gives the controls; old graphs' On Tick nodes compile to the same `Update`.
  - Checked by `EcsChecks.UpdateChecks` (a plain object updates per frame, a networked one per tick with empty
    controls when no player controls it); Sandbox runs as host in game and editor.
  - Not yet checked: a real two-machine session and Windows/web builds.
- [ ] 4. Scene's object and component lists replaced by queries; frame and tick order run through the world.

## Benchmark results

See "Phase 1 results" above.
