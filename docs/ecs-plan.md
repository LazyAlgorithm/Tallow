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

## Product contract: invisible ECS and networking (2026-11-04)

**Tallow should feel like a conventional Unity-style game engine while obtaining the advantages of ECS and networking by default.** An ordinary developer creates GameObjects, adds components, writes one normal gameplay script, builds prefabs, and presses Play. They do not need to know Flecs, declare queries, create system classes, write custom replication/prediction code, or manually manage jobs just to build a normal game. Engine internals may change incompatibly; preserving the ease and clarity of authoring game code matters more than source compatibility with older engine projects.

### Default path, with no special optimization or networking code

- **One intuitive authoring model:** Inspector components, GameObjects, familiar lifecycle methods, prefab editing, hierarchies, physics, animation, and visual scripting all work through one engine-backed component model. The same code works for offline and networked use wherever behavior is semantically the same.
- **ECS invisibility:** Flecs owns authoritative engine component storage. Tallow chooses packed queries, batching, dirty tracking, lifecycle management, job scheduling, and render extraction internally. The standard authoring experience requires no ECS concepts.
- **Networking invisibility:** For networked objects, the engine supplies useful defaults for authority, ownership, spawning/despawning, replication, interest management, interpolation, reconciliation, and prediction. A new developer should be able to add a Network Identity and get a working basic multiplayer object without implementing RPC plumbing, tick buffers, or custom serializers. A project still needs a session/transport and a way to assign player ownership; the engine must make those explicit and easy.
- **Advanced escape hatches:** Expose optional custom ECS systems, replication policies, prediction controls, ownership options, physics filters, network diagnostics, and explicit scheduling only for cases that need them. Advanced customization must not be a prerequisite for acceptable default operation.
- **Breaking changes are acceptable:** Eliminate legacy object duplication, ownership indirection, and compatibility layers when they inhibit a cleaner implementation. Keep familiar property names and script patterns where they improve usability, not because old binaries or projects must compile unchanged.
- **No misleading blanket performance guarantees:** 10,000 uncomplicated static or instanced objects should be an ordinary benchmark target, not an advanced DOTS exercise. But arbitrary 10,000-instance gameplay scripts, unique materials, heavy physics, or networking bandwidth cannot be optimized away automatically. Profile the full workload and expose a useful cause/effect diagnosis; optimize safe common patterns without changing gameplay semantics.
- **No silent semantic changes:** Automatic systems must respect script ordering contracts, physics ownership, lifecycle events, and server authority. Do not silently parallelize user scripts or infer networking authority in ambiguous cases. Supply understandable defaults and editor diagnostics.
- **Ordinary scripts are a performance target, not merely a compatibility layer:** optimize the default `Script.Update(TickInput, float)` path and the engine work around it. Custom ECS systems remain an optional escape hatch, not the expected solution for typical games.
- **Prediction-safe by default:** simulation affecting authoritative or predicted state uses fixed-tick inputs, stable dependencies and reproducible ordering. Rendering, UI and other presentation work may be frame-rate driven but must not feed nondeterministic values into predicted state. Preserve rollback/replay correctness as an invariant of every optimization. Reducing avoidable divergence should reduce corrective resimulations, but latency, late inputs, authority changes and real prediction error still require rollback/reconciliation.

### Acceptance tests for this contract

1. From a blank project, create a moving prefab using one ordinary script, duplicate it 10,000 times, and run without manually adding ECS systems. Record frame avg/p99, CPU work, memory, and render batches against the main branch on the same hardware; identify the bottleneck, including arbitrary script costs.
2. From the same authoring model, create a two-client multiplayer scene with a player and physics props using built-in Network Identity/session setup. Verify spawn, ownership, remote movement, reconciliation, join/leave, and no custom network script or serializer.
3. Validate that editor duplication, save/load, prefab updates, hot reload, physics, animation, and visual scripting use the same authoritative runtime component state.
4. Verify advanced ECS and networking overrides do not change default behavior in projects that never opt into them.
5. For every phase, track complexity as well as speed: number of game-code concepts, special annotations, manual setup steps, and per-object helper scripts required by an introductory project.
6. Run identical seeded, fixed-tick game and network-prediction scenarios before and after each script optimization; compare per-tick state hashes, authoritative/client replay results and events, plus correction count, rollback count, re-simulated ticks and CPU cost under repeatable packet latency/loss. Distinguish deterministic mismatches from unavoidable network corrections.

## Goals

1. **Scripting and ordinary component workflows stay as close to Unity as possible.** A Unity developer opens a script and recognises
   everything. Nobody has to write a query or a system to make a game. Unity DOTS's learning curve is the thing
   to avoid.
2. **The engine scales.** Transforms, rendering, physics sync, animation, particles, AI crowds and network
   state live in packed Flecs tables and are processed in bulk, on several threads where it is safe.
3. **Networking gets simpler and cheaper, and stays invisible.** Snapshots, rollback, delta compression and
   interest management work on component columns instead of walking each object's fields. As today, a game
   developer adds a Network Identity and writes `Update`. Everything else happens behind the scenes.
4. **Game code rarely touches memory management.** The gameplay API avoids handing scripts heap objects to free.
5. **Fast normal scripts with deterministic results.** The default `Script` and GameObject workflow should benefit materially from ECS without developer-written queries, changed execution semantics or non-reproducible prediction.

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

**Rule: it just works, as it does now.** Fish-Net is the reference for *how* prediction and input forwarding
behave, not for its API. A game developer never writes replicate or reconcile methods, never marks inputs or
state structs, and never picks formats, rates, priorities or relevance to get a working game. They add a
Network Identity to an object and write `Update(TickInput input, float deltaTime)`. The engine works out the
rest from what is on the object:

| Object | What the engine does on its own |
| --- | --- |
| Controlled by a player | Inputs sent to the server and forwarded to clients it is relevant to; predicted on every client; exact state for the owner's corrections |
| Rigidbody, no player | `QuantizedBody`, dormant while sleeping, predicted on clients, dynamic priority, distance relevance |
| Moves without physics (doors, platforms, NPCs) | `QuantizedTransform`, dynamic priority, distance relevance |
| Never moves after spawning | Spawned once, nothing per tick |
| Script fields that change | Sent when they change, to the clients the object is relevant to |

- Every per-object and per-session setting that exists today stays, as an optional override in an
  **Advanced** foldout of the Network Identity and Network Session Inspectors. Defaults are what a new
  user gets, and they are the right choice for most games.
- Values the engine can measure, it tunes itself: input delay follows each client's ping and jitter (0 when
  the connection is good), the snapshot budget follows the connection, and the interpolation delay follows
  packet loss.
- Rollback, island limiting, skipped identical inputs, the rollback cap, baselines, deltas and packet layout
  are internal details with no settings at all.
- Lockstep mode (item 8) is one switch on the Network Session. Nothing in game code changes when it is
  turned on, apart from the determinism rules the debugger and the script editor point out.
- The network panel shows what the engine chose for each object and why, and the estimated bytes per
  client, so nothing is hidden from someone who wants to look.

- `NetworkIdentity` becomes a data component, and `[Replicated]` marks data components (or fields) that sync.
- Per tick, replicated columns are copied into a ring buffer of snapshots. Delta compression compares against
  the client's last acknowledged snapshot, column by column (`NetCompression.bf` reused).
- Rollback restores columns from the snapshot, then re-runs the fixed pipeline: predicted systems and the
  networked `Update` for predicted objects. This replaces the per-object re-run in today's
  `NetworkManagerHistory`; lag compensation reads positions from the same history.
- Interest management: a spatial query per client picks which replicated entities it receives (detailed
  below).
- Script fields marked for sync keep using the reflection-based path from `NetworkSync.bf`. Bulk state such
  as transforms and physics goes through columns.

#### Bandwidth: keep what exists, move it onto columns

Tallow already has most of the standard bandwidth tools (`docs/NETWORK_BANDWIDTH_OPTIONS.md`). All of them
carry over, now computed as column passes instead of per-object reflection:

- Skipping objects unchanged for a few snapshots, with periodic refreshes.
- `dormantWhenSleeping`: one reliable final transform, then nothing until the body wakes.
- `QuantizedTransform` (24-bit positions, smallest-three rotation, 14 bytes) and `QuantizedBody` (finer
  positions, smallest-three rotation, both velocities: 28 bytes moving, 16 at rest).
- Per-object rates (`remoteIntervalTicks`), the per-client budget (`SnapshotBytesPerSecond`),
  `snapshotPriority`, the relevance radius, and lossless compression (ENet or message frames).

#### Bandwidth: new work

1. **Good defaults, chosen automatically.** Today every bandwidth option is opt-in and new games ship the
   legacy format. Instead, the engine picks per object from the table above: `QuantizedBody` with
   `dormantWhenSleeping` for physics bodies, `QuantizedTransform` for other moving objects, and
   `OptimizeSnapshots` and `LosslessCompression` always on. The exact format stays available as an Advanced
   override (`fullPrecision`) for the rare object that needs it.
2. **Field-by-field deltas against each client's acknowledged snapshot.**
   - Each client acknowledges snapshot numbers.
   - The server keeps, per client, the last acknowledged baseline for each relevant entity (from the snapshot
     ring buffer, not a copy per client).
   - An entity record becomes a changed-fields mask plus only those fields. Positions are sent as
     variable-length differences in quantized steps, and velocities and rotations only when they changed past
     their quantization step.
   - When the baseline is older than the history (`HistorySize`) or was never acknowledged, the full
     quantized record is sent. Keep today's guarantee that an unchanged transform never depends on an
     unacknowledged baseline.
3. **Column-grouped packets.** Inside a snapshot packet, write all entity ids, then all change masks, then
   each field for every entity, rather than one entity record after another. Similar values sit together and
   the lossless coder compresses them better. Keep it only if the measurements show a win over per-entity
   records once compressed.
4. **Dynamic priority.** Replace the fixed `snapshotPriority` ordering with a priority accumulator per
   (client, entity):
   - each tick the accumulator grows by a weight from distance to the client's player, being inside the
     client's camera view, speed, recent interaction with the client's player, and the object's
     `snapshotPriority` (now a base weight);
   - within the budget, the highest accumulators are sent first, and sending resets the accumulator.

   Distant, slow or off-screen objects update less often instead of being cut off, and nothing starves.
5. **Full interest management.** Relevance today filters transforms only. Make it cover spawns and despawns,
   synced script fields, enabled/active changes and gameplay events:
   - Build one spatial grid per tick from `Transform` columns, then each client's relevant set from it, with
     hysteresis (the leave radius is larger than the enter radius).
   - Per-object relevance modes: `Always`, `Distance` (the default for props), `OwnerOnly`, `Team`, and a hook
     for custom rules (line of sight, rooms, streaming cells).
   - An object leaving relevance is hidden on the client, not destroyed. It keeps its entity so re-entry is
     one full-state update instead of a respawn.
6. **Rollback that costs only what moves.**
   - Save and restore Jolt state with `SaveState` / `RestoreState`, filtered so sleeping bodies are not
     copied. Jolt skips sleeping bodies when stepping, so a replay costs roughly active bodies × ticks
     replayed, not all bodies.
   - **Skip identical inputs.** When a late input matches what the client guessed (the player kept holding
     the same keys, which is the common case), nothing is replayed.
   - **Optional input delay** per session (0 to 3 ticks): inputs are applied a few ticks after they are
     given, so most arrive before they are needed and rollbacks become rare. 0 keeps today's feel.
   - **Rollback window cap:** an input or correction older than the cap triggers a state resync of the
     affected entities instead of a long replay.
   - **Island-limited rollback (state sync only).** In the modes below where the server sends corrections,
     rewind only the islands (groups of bodies in contact) touched by the changed input or the corrected
     entities. A small difference from the full world is fixed by the next correction. Never do this in
     lockstep mode (item 8), where every machine must compute bit-identical results and Jolt guarantees that
     only when the whole simulated set is stepped the same way.
7. **Input forwarding with server reconciliation (the main path; Fish-Net is the reference for how it
   behaves).** Automatic for every player-controlled object, with no code or settings. The server relays
   each player's inputs to the clients that player is relevant to, as well as running them itself:
   - clients predict remote players in the present from their forwarded inputs, instead of showing them in
     the past, and so predict the props they push correctly. With predicted physics on
     (`NetworkManager.PredictPhysics`), crates hit by another player move on every screen the tick it
     happens;
   - a client missing a player's input for a tick repeats the last one, and replays from that tick when the
     real input arrives (with item 6's skips and cap);
   - **the server still sends state** and stays authoritative, so nothing depends on perfect determinism:
     drift, late joiners and cheaters are corrected as today. Because Jolt is built with
     `CROSS_PLATFORM_DETERMINISTIC ON` and everyone runs the same inputs on the same tick, corrections are rare
     and tiny. So state for well-predicted bodies can drop to a low refresh rate under dynamic priority
     (item 4) and is sent at full rate only when something diverges;
   - inputs travel inside the snapshot packets (several ticks batched, each tick's input as a difference from
     the previous, at most 9 bytes per player per tick), so one player's inputs cost about what one moving
     body's state does;
   - interest management (item 5) applies: a client receives only the inputs of players relevant to it, so
     hidden information stays hidden and the cost does not grow with the whole server's player count;
   - the shared clock is reused as is: one fixed tick (`Time.TickRate`, `Time.Tick`), clients kept in step
     through `TickScale`, and inputs stamped with the server tick they were given at.
8. **Lockstep mode (optional, one switch on the Network Session).** For games where moving objects vastly outnumber players and every
   client should simulate everything (RTS, physics sandboxes, co-op), a session can stop sending body state
   entirely: inputs plus hashes only.
   - Each machine hashes the simulated columns every N ticks and sends it to the server. A mismatch
     triggers a full-state resync of the affected entities (or the world). Late joiners get a full state
     first.
   - Rollback replays the whole simulated set (item 6 without island limiting). Use input delay by default
     in this mode.
   - Limits to document: every client simulates the whole world, so the weakest player's machine sets the
     object budget; there is no hidden information (wallhacks become trivial), so it does not suit
     competitive shooters; late join costs a full-state download.

   The physics and the tick are deterministic already. The game code around them must be too (this also
   makes item 7's corrections rarer):
   - simulation code uses the tick's `deltaTime` only, never `Time.DeltaTime`, `Time.Time` or wall-clock time;
   - iteration in a stable order (sort by entity id where Flecs table order could differ);
   - seeded per-tick random numbers;
   - Beef and native code built without fast-math or floating-point contraction;
   - engine-provided deterministic `Sin`/`Cos`/`Sqrt` (Jolt has its own) instead of the platform C library's
     in simulation code.
9. **Desync and prediction debugger.** In both item 7 and item 8, hash each system's output columns per tick
   in Debug builds. When machines disagree, the network panel shows the first tick and the first system
   where the hashes split, plus the entities and fields that differ. In item 7 the same data shows how often
   and how far predictions are corrected, per object type. The script editor warns about `Time.DeltaTime`,
   `Time.Time`, unseeded random numbers and platform math inside a networked `Update`.

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

Steps, each committed on its own (see "Networking" under Architecture for the details):

- **6a. Port.** `NetworkIdentity` as data, column snapshots, rollback through the fixed pipeline with the
  networked `Update` on top, lag compensation and host migration. The existing bandwidth options carry over,
  computed from columns.
  **Exit:** networked Showcase exhibits pass; the existing test fixture profiles (baseline, exact, quantized,
  sleep, rate, budget, compressed, all, steam) produce the same bytes as `main`.
- **6b. It just works.** Automatic per-object choices from the table under Networking, Advanced foldouts
  for every existing setting, self-tuning input delay, budget and interpolation, and the network panel's "what
  was chosen and why" view with bytes per client.
  **Exit:** a new project with a networked player and a pile of physics crates plays smoothly between two
  machines with no networking settings touched, and its scripts contain nothing but `Update`.
- **6c. Field deltas.** Per-client acknowledged baselines, change masks and variable-length position
  differences, then the column-grouped packet layout (kept only if it measures smaller).
  **Exit:** bytes per client measured against 6b on the 4096-prop scaling workload.
- **6d. Dynamic priority.** Per-(client, entity) accumulators replace fixed ordering under the budget.
  **Exit:** under a tight budget, near and visible objects update at full rate, far ones degrade smoothly and
  none go stale past a set limit.
- **6e. Interest management.** Relevance covers spawns, despawns, fields and events; spatial grid; relevance
  modes; hysteresis; hide-not-destroy.
  **Exit:** a large map where each client receives only its area, with no pop-in at the hysteresis edge.
- **6f. Rollback costs.** Filtered Jolt `SaveState` / `RestoreState`, skipping identical inputs, optional
  input delay, rollback window cap, island-limited rollback for state sync.
  **Exit:** the cost per re-simulated tick is recorded for a couple of hundred active bodies; a stack of
  predicted crates corrects without visible snapping.
- **6g. Input forwarding (Fish-Net style).** Relay relevant players' inputs to each client, predict remote
  players and props in the present, keep server reconciliation, lower state rates for well-predicted bodies.
  **Exit:** two clients pushing the same crates see them move the same tick on both screens; corrections stay
  rare and small over 10 minutes; bytes per client measured against 6e.
- **6h. Lockstep mode (optional).** Inputs and hashes only, whole-set rollback, input delay by default, resync,
  full state for late joiners, the deterministic math functions and build flags checked on every platform.
  **Exit:** Windows, Linux and macOS clients stay in sync for 10 minutes of heavy prop physics with no hash
  mismatch.
- **6i. Desync and prediction debugger.** Per-system hashes, the first-split view in the network panel,
  correction statistics and the script editor warnings.
  **Exit:** a desync planted on purpose (an unseeded random number in one script) is found by the debugger,
  down to the system and the field.

**Phase exit:** measure a dedicated server with thousands of replicated bodies and many simulated clients,
before (from `main`) and after each of 6c to 6h: server CPU per tick and bytes per client per second.

### Phase 7: Scripting experience and transparent performance (L)

**Product objective:** ordinary GameObject scripts stay recognisably Unity-like and are themselves fast. An ECS-backed engine with faster rendering but slower `Script.Update` is not the finished experience. No new annotation, query, system class, thread configuration or manual memory management should be required to obtain the default improvements.

#### 7a. Profile and optimize the default script path

- Profile end-to-end frame cost and isolate script dispatch, transform/component reads and writes, cache misses, dirty propagation, engine callback indexing and ECS reference refresh. The November 5 benchmarks show faster total frames but slower `Mover.Update` (10k: 0.37 → 0.44 ms; 100k: 3.55 → 4.22 ms); treat this as an explicit regression to investigate, not a tradeoff to ignore.
- Optimize hot `Transform` and built-in component handle access, reuse validated references where safe, avoid unnecessary lookups and allocations, and preserve the visible property API. Component references must remain valid across archetype moves, deletes, prefab changes, reloads and world transfers.
- Reduce callback overhead using callback-specific lists, efficient iteration and, where measured safe, compiler-generated or type-specialized dispatch/accessors. Benchmark against the existing virtual-call path; do not assume grouping or code generation is automatically faster.
- Keep script instance lifecycle, enabled-state handling, `Awake`/`Start`/`Update`/`FixedUpdate`/`LateUpdate`, inspector fields, hot reload and registration order unchanged. Type grouping or new iteration order cannot silently change gameplay behavior.
- Automatically batch compatible **engine** work (transform propagation, animation, render extraction, physics sync, navigation, network snapshots) through ECS queries, dirty data and Jobs where safe. Avoid per-object redundant work even when gameplay remains a conventional script.
- Keep explicitly written `Query`/`ParallelFor` systems as an advanced optimization for unusually large homogeneous simulations. Do not promise that arbitrary script bodies can be automatically vectorized or executed in parallel.

#### 7b. Deterministic execution and network prediction invariants

- **Fixed-tick authority:** on an object with Network Identity, `Update(TickInput input, float deltaTime)` runs on the deterministic fixed simulation tick and uses the supplied tick input and fixed delta, as already specified in Phase 2. Preserve the same behavior on server, predicted client and replay. Non-networked `Update` may remain per-frame; gameplay that must be reproduced during prediction must not depend on `Time.DeltaTime`, render frame rate or wall-clock time.
- **Stable ordering:** preserve script registration order and explicitly order state-dependent engine systems, command application, spawn/despawn and event dispatch. Flecs table iteration order and worker completion order are *not* gameplay ordering guarantees. Predicted simulations must use stable entity identities and canonical iteration/reduction order where results depend on order.
- **Safe parallelism:** parallelize only disjoint data updates or operations with proven order independence. Gather and apply shared writes, collisions, forces, events and reductions in an explicitly deterministic sequence. Never silently parallelize ordinary user scripts or allow races, unordered atomics or floating-point reductions to change predicted results.
- **Repeatable inputs and state:** provide/use seeded, serializable RNG for predicted gameplay; deterministic scheduling and physics-step parameters; stable spawn IDs and tick-stamped commands; reproducible state snapshots including all gameplay fields and RNG state. Isolate presentation-only effects, audio, camera and UI from authoritative state.
- **Floating-point/platform boundary:** test within-build same-platform replay equivalence first. Cross-platform lockstep is a stricter separate Phase 6h goal requiring compatible compiler flags, floating-point behavior, math and physics verification; do not claim bitwise determinism on Windows/Linux/macOS without tests.
- **Prediction and correction:** correctness comes first. More deterministic replay prevents *avoidable* divergence and corrective rollbacks, but cannot eliminate rollbacks caused by latency, missing/late inputs, server decisions or physics interactions. Retain authoritative reconciliation, state hashes, rollback and resynchronization; never suppress a necessary correction to improve a metric.
- **Diagnostics:** expose tick, system/script, entity, input hash, RNG state, first divergent field and cause where possible. Warn when a networked script reads frame-dependent state, nondeterministic RNG or unordered shared results in predicted `Update`.

#### 7c. Acceptance benchmarks and developer experience

- Compare pre-ECS `main`, current `ecs` baseline and optimized `ecs` on the **same reference hardware and build settings**, with interleaved Release runs. Use ordinary editor-created prefabs with 1k/10k/50k/100k moving scripted objects, including a realistic mix of rendering, collision, AI and networked movement. Report frame average/p99, script-update average/p99, CPU time, memory, allocation count, spawn/despawn, batches and component-access costs.
- Run the identical workload as an optional explicit ECS system to measure the remaining gap, but judge the default GameObject path by its own performance and ease of use. Set numeric targets after collecting baseline and hardware data; do not promise 60 FPS for arbitrary 100k-object games.
- Test deterministic hashes and observable script/event order before versus after optimizations on fixed input sequences (including changes to archetypes, enabled state, hierarchy and script reload). Exercise single-thread versus multithread schedules repeatedly. Where order is part of the contract, results must match; document any intentionally different semantics.
- Test server/client prediction and rollback under reproducible packet delay, jitter and loss, with replay and resimulation. Require no new desyncs, lost events, different authoritative outcomes or greater avoidable correction frequency from performance optimizations. Report correction/rollback counts, re-simulated ticks and CPU separately from network-induced corrections.
- Preserve the low-allocation gameplay API, coroutine helpers and editor quick fixes above. Document the Systems tier as **advanced**, with a Showcase crowd exhibit in both normal-script and explicit-system styles.
- **Exit:** a new project's template scripts contain no `delete`, `scope` or queries; ordinary scripts measurably improve over the pre-ECS baseline or a documented blocker explains the remaining script regression; full-frame gains are reported separately; fixed-tick/replay/network determinism checks pass; a developer needs no special ECS knowledge to realize the measured default-path improvements.

### Phase 8: Docs and release (M)

- Update every page in `docs/` that mentions `Component`, `OnRegister` or scene lists. Add `docs/ecs.md`
  (how the engine works inside) and `docs/systems.md` (the advanced tier). Update `README.md`,
  `RELEASE_NOTES.md` and the API docs (`tools/generate_api_docs.py`).
- **Exit:** CI green on Windows, Linux and macOS; release candidate built.

## Risks and decisions

- **Half-converted engine.** Work on the `ecs` branch and keep `main` releasable. Merge only after Phase 5
  at the earliest, or Phase 6 if networked games are the priority.
- **Script speed is a known regression and an explicit Phase 7 target.** Scripts currently remain per-object calls; the November 5 benchmark shows approximately 17–19% slower script-update time despite better whole-frame throughput. Phase 7 must profile and improve the ordinary `Script` path without forcing developers into Systems. Some workloads may still benefit greatly from optional explicit ECS systems; quantify that gap rather than hiding it.
- **Adding or removing components often is slow** (entities move between tables). Use enabled flags or Flecs
  toggles for things that switch on and off often.
- **Determinism is a hard constraint on optimization, not a presumed side effect of ECS.** Preserve fixed-tick input semantics, stable state-dependent ordering, reproducible RNG and physics settings, and canonical application of parallel results for server/predicted client/replay. Verify same-build repeatability with per-tick hashes and adversarial tests, then separately validate cross-platform lockstep (6h). Hashes, reconciliation and resync remain mandatory; reduced avoidable mismatches can reduce corrective rollbacks, but network latency and authoritative changes still require them.
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
- [x] **4. Script dispatch and the frame and tick order through the world.**
  - One list per callback (FixedUpdate, Update/OnLocalUpdate, LateUpdate, OnFrame) holding only components whose
    class overrides it, found once per class by reflection (`ScriptCallbackIndex`). This replaces `mRunning` and
    the hand-kept `sIdleTypes`. A class whose methods reflection cannot see goes in every list. Lists keep the
    order components joined (not sorted by type, so call order between scripts is as before).
  - `Scene` has two Flecs pipelines, `FramePipeline` and `TickPipeline`, and its work is in steps (immediate
    systems with no query, `World.AddStep`) in Flecs phases:
    - Tick: OnLoad Starts (its own pipeline), then NetworkReceive (PreTick, between pipelines: Phase 6), PreUpdate Update (networked objects, offline),
      OnUpdate FixedUpdate, OnValidate Physics (water and Jolt), PostUpdate NetworkSend (PostTick).
    - Frame: OnLoad OnFrame, PostLoad Audio (voice and audio), PreUpdate Starts, OnUpdate Update and
      OnLocalUpdate, OnValidate Paths, PostUpdate LateUpdate, PreStore Animation (IK and skinning), OnStore
      Destroy.
    Engine systems from Phase 4 on are added to these pipelines by phase. Flecs 4.2 never defers the world, so
    steps and the scripts they run change it directly. Running a pipeline from inside one of the same scene is
    refused with an error.
  - The world now imports Flecs's system and pipeline modules (`ecs_mini` leaves them out).
  - **Decision: object lists stay.** `mObjects`, `mRoots`, `mById`, `mComponents` and `mByType` remain as ordered
    indexes beside the world. Their order is load-bearing: scene identities get network ids in this order on every
    machine, saves and scene files are written in it, and the Hierarchy shows siblings in it. Flecs tables do
    not keep a stable order across adds and removes. Queries take over where order does not matter, as data moves
    into components (Phase 4 on).
  - Checked by `EcsChecks` (steps run in phase order around Update; callback detection for engine and sample
    classes). Interleaved Release benchmark against the pre-Phase-2 build at 100,000 objects: frame
    32.6 / 32.0 / 33.3 ms before, 29.4 / 29.2 / 29.1 ms now (the callback lists skip classes with nothing to
    run). Script update is 5.2 to 5.4 ms before, 6.0 to 6.4 ms now; at 10,000 objects both are unchanged.
  - Where the script-update difference comes from: the engine Profiler (`--profile-report`, per-script timing)
    on both builds at 100,000 objects shows the same per-call cost: `Mover.Update()` 6.99 ms before and 7.16 ms
    now for 100,000 calls, loop overhead 4.44 and 4.49 ms. The difference is cache warmth, not work. Before, the
    OnFrame pass called an empty `OnFrame()` on every Mover just before Update, which loaded every script,
    GameObject and Transform into the cache; it also called empty `LateUpdate()` and `FixedUpdate()` on all of
    them. The callback lists skip those calls (the frame is about 20% faster: 26.4 against 32.8 ms), so Update is
    now the first pass to touch the scripts each frame and takes the cache misses OnFrame used to take. Nothing
    to fix; Phase 4 removes most of the remaining misses by moving engine data into columns.

**Phase 2 exit: met (2026-11-04).** New Empty, Sample and Showcase projects created with the launcher build and
run; the Showcase self-test reports `SHOWCASE_READY rooms=8 probes=2` with no errors; the Sandbox runs in game
and editor with its ported scripts. Not yet built for Windows or the web.

## Phase 3 progress

Scripts and GameObjects stayed classes in Phase 2, so the editor already handled them; Phase 3 is about data
components (`[Component]` structs in an object's entity) taking part everywhere scripts do.

- [x] **3a. Data components on objects and in files.** `AddComponent<T>(value)`, `GetComponent<T>` (a pointer,
  valid until the object's data changes), `HasComponent<T>`, `RemoveComponent<T>` for structs, beside the class
  versions; by-type versions (`AddData`, `GetData`, `RemoveData`) for the editor. `DataComponents` lists a
  project's data types and their plain-value fields; `[EngineData]` hides engine bookkeeping (`ObjectLink`,
  `InactiveSelf`, `TransformData`). Scene files keep them as `data <type>` blocks of `field` lines after the
  scripts. Map checks report a data type the game lacks.
- [x] **3b. Editor.** The Inspector shows each data component after the scripts, with its fields, and a menu:
  Reset, Copy, Paste Values, Remove. Add Component has a Data group. Undo, the play-mode snapshot, the prefab
  editor and prefab files all go through `SceneSerializer`, so they carry data components without changes of
  their own; prefab instances are copies (no override records), so they keep whatever the file has.
  Checked: a scene with data opens in the editor and the Inspector shows the values; saving from the editor
  writes them back unchanged.
- [x] **3c. Hot reload.** Data components are written out as text before a script reload and read back by field
  name after it, so reordered fields keep their values and renamed ones start at zero. A size change already
  makes the reload ask for a full rebuild, which reloads the scene from text. New data types appear in Add
  Component after a reload. Checked by `EcsChecks` (the save and read-back round trip); not yet exercised with a
  live reload.
- [x] **3d. Flecs Explorer; Hierarchy.** Window > Flecs Explorer serves the open scene's world over Flecs's REST
  server (port 27750, `World.StartExplorer`) and opens https://www.flecs.dev/explorer, which connects to it; the
  scene answers requests once a frame (the Frame pipeline's Explorer step). The REST, HTTP, JSON and stats addons
  are now in every native build (`TALLOW_FLECS_EXPLORER`, on by default) because the native library is always
  built in Release; nothing listens until something starts the server. Checked: the benchmark started with
  `TALLOW_BENCH_EXPLORER=1` answers `GET /world` with the world, its pipelines and steps.
  **Decision:** the Hierarchy keeps reading the ordered `Transform` children. `ChildOf` mirrors them, but Flecs
  does not keep sibling order, and the Hierarchy shows siblings in the order the user arranged them.
- [x] **Phase 3 exit: met (2026-11-04).** In the editor: a scene with data components opens, the Inspector shows
  and edits them, the editor saves them unchanged, and play mode starts on it. Prefab chain (`EcsChecks.
  PrefabChecks`): a prefab with a script, data on its root and on a child is saved, instanced, the instance's data
  edited, the scene saved, loaded into a fresh scene and played for five frames; the edit, the child's data, the
  hierarchy and the script's Update all survive. Not yet exercised by hand: a live script reload with data
  components, and Windows or web builds.

## Phase 4 progress

**Decision (project owner, 2026-11-04): full handles**, as "Built-in components: same names, now handles"
describes, rather than keeping the classes and mirroring their data. Built-in components move one at a time.

### How a handle works

- The settings live in a `[Component, HandleData]` struct in the object's entity (`LightData`). Field
  initializers are the defaults; the struct needs an explicit `public this() {}` so reflection can run them.
- The handle is `[Component, HandleFields] struct Light : ComponentHandle<LightData>`. It holds only the
  GameObject (Engine/src/Scene/ComponentHandle.bf). `[HandleFields]` writes, at compile time, a `ref` property for
  every public field of the data, so `light.intensity = 2`, `light.intensity *= 2` and `light.color.a = 0.5f`
  read as before. Behaviour goes on the handle as methods and properties.
- `GameObject.AddComponent<T>()`, `GetComponent<T>()`, `HasComponent<T>()` and `RemoveComponent<T>()` have
  overloads for handles (`where T : struct, IComponentHandle`) beside the script and data ones.
- **Validity:** `if (light)` or `light.IsValid`. Beef cannot make `light == null` work on a struct: it compiles
  with warning BF0472 ("always false"), and `if (let light = GetComponent<Light>())` is always true, also with
  BF0472. Each handle conversion has to look for these warnings and for `= null`, `== null` and `!= null` on the
  converted type, in the engine and in every game that updates to this engine. `component is Light` and
  `component as Light` on a Component compile with no warning and are always false/null: search for them too.
- **On and off:** `light.enabled` uses Flecs's per-component toggle (`CanToggle`, added to every `HandleData`
  type when a world registers it); queries skip switched-off components without a check of their own.
- **Files:** a handle saves as the class did (`component Tallow.Light enabled 1` and `field` lines), so old
  scenes load and newly saved ones are unchanged.
- **References:** a script field of a handle type (`public Light lamp;`) is an object reference. It is saved as
  the object, dropped and picked in the Inspector, and cleared when the object is destroyed, as a class field is.
- **Editor:** the Inspector draws handles like script components (enable toggle, icon, Reset, Copy, Paste
  Values, Remove). Add Component lists them in their category. Gizmos come from an optional
  `static void DrawGizmos(GameObject, bool selected)` on the handle.
- **Lists:** `scene.Components<T>(list)` gives every switched-on component of a handle type, from a cached
  Flecs query of its data and `ObjectLink` (`IndexQuery`, a query built from ComponentTypes indices). Switched-off
  components are not visited at all; callers still check the object is active. `scene.FindComponents<T>(list)` and
  `FindComponent<T>()` have handle overloads that include switched-off ones, as for scripts. `Scene.Lights` and
  `AllLights` are built from these each time they are read.
- **Text in data:** `SharedString` (Engine/src/Core/SharedString.bf) is a pointer to one interned, never-freed
  copy of a text, so data holding it can be copied byte for byte. It converts to and from `StringView` and
  `String`, so `decal.texture = "Textures/ring.png"` and `if (decal.texture == "x")` read as before (an exact
  `String` overload of `==` keeps literals unambiguous). It is a `FieldKind.String` field: scene files, the
  Inspector, `[Sync]` and UI bindings read and write it through `StringFields.Get/Set(slot, type, ...)`. Meant
  for asset paths and names, not text that changes every frame. `decal.texture.Set(...)` no longer exists.
- **State outside the data:** GPU textures, voices and bodies must not be in data that Flecs copies. A handle
  keeps them in `ComponentState<TState>` (a table keyed by World and entity), made on first use, and declares
  `static void OnRemove(void* world, uint64 entity)` to free them. HandleComponents finds `OnRemove` by
  reflection, and each World registers it as the component's Flecs `on_remove` hook (`tallow_ecs_on_remove`), so
  it runs on RemoveComponent, on destroying the object, and when the scene's world ends. Engine code that keeps a
  handle across frames (Reflections' capture job) is told in the same hook, by World and entity, because the
  GameObject may be gone by then.
  A handle that keeps other handles in a list must not test them with `if (handle)` once their object may have been
  destroyed (the test reads the object): keep the entity too and check `World.IsAlive` first (LODGroupState).
- **Being added, switched on and off:** `static void OnAdded(GameObject)` runs inside `HandleComponents.Add`, before
  a scene's saved fields are read (a class's OnRegister, and OnEnable while playing); `static void OnSwitched
  (GameObject, bool on)` runs while playing when the component starts or stops counting as on (SetActive,
  `enabled`, play starting or stopping): a class's OnEnable / OnDisable. NetworkIdentity uses both (Phase 6).
- **One per object:** Flecs keeps a component once per entity, so an object has at most one of each built-in
  component; AddComponent returns the one already there. No scene or prefab in the samples, the Gallery template or
  the projects under ~/TallowProjects and ~/TesseraProjects had two of the same built-in component on one object
  (only UIDocument, which is not converted), and DialogueRunner only adds a source when there is none. A second
  sound goes on a child object or through PlayOneShot. Colliders and Joints need the same rule or a compound
  shape when they are converted; flagged for the project owner.
- **Behaviour that was a callback:** a handle has no OnFrame, Start or OnDisable. Engine code runs it from a
  pipeline step instead: Audio Listener and Audio Source each have a `static FrameAll(Scene)` called from the
  scene's Frame.Audio step. Audio Source's Play On Start happens there once the scene plays, and a source switched
  off or on an inactive object has its voice stopped there, as OnDisable did.
- **Network switches:** `handle.enabled = x` sends `NetworkSync.HandleEnabledChanged` (object path plus the
  handle's full name) as Component.Enabled sends EnabledChanged; a client may switch only cosmetic ones (Light,
  AudioSource, Decal, AudioReverbZone) on objects it owns.
- **Scripts:** Component has `GetComponent<T>()` and `HasComponent<T>()` overloads for handles (without them,
  `GetComponent<AudioSource>()` in a script picked the raw data overload and returned a pointer).
- **Inspector tools:** the tools a class used to draw under its fields (`component as Decal`) are called from
  `InspectorPanel.DrawHandleTools` by handle type.

### Components

- [x] **Light.** The renderer, light clusters, light baking, world streaming and network sync read the handle.
  Network sync addresses a light by its object and also carries `enabled`. Checked by `EcsChecks.HandleChecks`
  (defaults, field writes, enable and `Scene.Lights`, save and load, a script's `Light` field resolved and
  cleared on destroy, remove). The Sandbox renders with its sun and lamp. In the editor, the Lamp loads from the
  existing scene and shows in the Inspector as before, and an editor save writes the Light blocks back unchanged.
- [x] **WindZone and FoliageBender.** `Wind.At`, `Wind.Gather` and `FoliageBender.Gather` read
  `scene.Components<T>`. Checked by `EcsChecks.WindChecks` (global and sphere wind, switched off, inactive
  object, bender gather, save and load).
- [x] **Decal.** `texture` is a `SharedString`. The renderer and the Scene view's picking read
  `scene.Components<Decal>`; Stick to Surface moved to DrawHandleTools. Checked by `EcsChecks.DecalChecks`
  (SharedString interning, defaults, the text surviving a table move, editable field, save and load).
- [x] **ReflectionProbe.** Its cube and capture progress are `ReflectionProbeState` in `ComponentState`, freed by
  `OnRemove`, which also tells Reflections to drop the probe from its ready list and capture job. Checked by
  `EcsChecks.ProbeChecks` (state made on capture, kept across a table move, freed by RemoveComponent, by
  destroying the object and by the scene ending; FindComponents). The Gallery captures its two probes
  (4 captures, as before) and in the editor the Hall probe shows its fields, Capture Now and "Captured: 512 x 512,
  8 levels", with the spheres mirroring the room.
- [x] **LightProbeVolume.** The baker and ProbePlacer read it through `FindComponents`; checked for its counts.
- [x] **Camera.** Its settings are `CameraSettings` (CameraData was already the renderer's per-view struct).
  `Scene.Cameras` is the switched-on cameras from `Components<Camera>`, oldest object first; `ViewCamera` is the
  override if active, else the active camera of the oldest object, and is not valid when there is none.
  `CameraOverride` is kept as the entity, which Flecs can tell is gone, so it stops being valid when its object is
  destroyed without a hook. The build's BF0472 warnings found every `camera == null` in the engine and editor (16
  places, now `!camera`); the Sandbox scripts had three more. `component is Camera` tests (world streaming,
  hierarchy icons) became `HasComponent<Camera>()`: those compile without a warning and are always false, so they
  have to be searched for (`grep -E "(is|as) Camera\b"`). Checked by `EcsChecks.CameraChecks`; the Sandbox's
  follow camera drives the game view.
- [x] **AudioSource, AudioListener, AudioReverbZone.** The voice, its loaded clip, occlusion and the Play On
  Start flag are `AudioSourceState`; its destructor (run by OnRemove) stops the voice and takes down the subtitles
  following it (Subtitles keys them by the state now). Network sound events name the source by its object. Profiler
  counts playing sources from the query. Checked by `EcsChecks.AudioChecks` (defaults, no voice until played,
  Play(clip), reverb weights, listener, save and load, voices freed with the scene); the Sandbox, whose Boulder has
  a source, plays without errors.
- [x] **MeshRenderer.** Its saved settings are `MeshRendererData` (mesh, texture, material and the lightmap
  paths are `SharedString`). What the renderer works out at run time (material caches, runtime mesh and parts,
  LOD level, last drawn frame, visual offset) lives in a `RenderProxy`, a class kept in `ComponentState` and freed
  by OnRemove. The draw path (RenderView, occlusion, planar reflections, foliage, instanced sources) takes
  `RenderProxy`; `Scene.Renderers` builds the list from one query, copying each entity's settings into its proxy,
  which replaces the old registration list and its sweep. Code that writes settings (light baking, the editor
  tools, voxels, ropes, soft bodies) uses the `MeshRenderer` handle. `MeshRenderer.MeshOf(gameObject)` reads a
  mesh without making a proxy for an object that has no renderer. Material changes over the network name the
  object. LODGroup stays a class component; it keeps handles and asks for meshes by proxy.
  Checked by `EcsChecks.RendererChecks` (defaults, writes, Scene.Renderers, runtime values in the proxy, switching
  off, moving tables, save and load, proxies freed on remove and with the scene); the Sandbox draws as before and
  the Gallery self-test passes. EcsBench `gameobject` (Release, A/B against the commit before, interleaved): 10k
  cubes 1.71 → 1.63 ms a frame; 100k cubes 26.6 → 20.4 ms a frame, update 6.5 → 4.3 ms, spawn 142 → 74 ms.
  Fixed on the way: component sizes are registered by stride (`strideof`), not size, so a struct whose size is not
  a multiple of its alignment is no longer read past its end; using a handle that is not valid stops with a clear
  message instead of crashing (`CheckValid` before state is made).
- [x] **SkinnedMeshRenderer.** Its settings are `SkinnedMeshRendererData` (the model, clip and part lists are
  `SharedString`). The model, clips playing, blend, layer, bone objects, bent mesh and GPU skinning buffers are a
  `SkinnedRig` in `ComponentState`; the handle hands it out with the settings copied in, and a changed model, clip
  or clip library is loaded then (what OnValidate did). `SkinnedMeshRenderer.FrameAll` animates switched-on rigs on
  active objects at the end of the Frame.OnFrame step (in the editor too, as OnFrame did); OnRemove takes the bent
  mesh off the object's RenderProxy and frees the rig. SetPartMaterial, SetPartColor, SetPartHidden and
  SetPartShadowOnly write the settings through the handle. Network clip events name the object; a joining player
  is sent each rig's clip from the query. Editor tools call `Refresh()` (load now) and `FrameNow()` in place of
  OnValidate and OnFrame. Checked by `EcsChecks.SkinnedChecks` (defaults, no rig until needed, model and clip load,
  part lists, the Mesh Renderer it adds, Expose Bones, save and load, freed on remove and with the scene; the
  bench now has `Models/rigged_sample.glb`); the Sandbox's Skinning scene and main scene animate as before, the
  Inspector shows it, and the Gallery self-test passes.
- [x] **ParticleSystem.** Its settings are `ParticleSystemData`; the living particles, emitter clock and bounds are
  a `ParticleState` in `ComponentState`. `ParticleSystem.FrameAll` moves switched-on systems on active objects in
  the Frame.OnFrame step (in the editor too); `Scene.Particles` is built from the query, which replaces the
  registration list. Play over the network names the object. Checked by `EcsChecks.ParticleChecks` (defaults,
  burst, Play, switched off, inactive object, save and load, freed on remove and with the scene); the Sandbox's
  campfire previews in the editor and the Gallery self-test passes.
- [x] **LineRenderer and TrailRenderer.** Lists in data, added for them: a built-in component's data may hold
  `List<T>` fields of plain values, and the data owns them. Wherever the data is copied byte for byte (added with
  its defaults, Reset, the Inspector's Paste Component Values), `HandleComponents.OwnLists` gives the copy lists of
  its own, made by a `NewList` function `[HandleData]` writes at compile time (reflection cannot make a `List<T>`
  it never saw made); the handle's OnRemove frees them with `HandleComponents.FreeLists`. The Inspector clipboard
  keeps lists of its own. Copies kept elsewhere (a state's `data`) only read them. A line's points are
  `LineRendererData.positions`; its strip is a `LineState`, a trail's points and clock a `TrailState`. Both
  rebuild in the Frame.OnFrame step in the editor and after the scripts' LateUpdate while playing; switched-off
  ones stop drawing. Ribbon holds its hidden child by id, since children are destroyed before their parent's
  components go, and leaves it alone while the scene is emptied. Checked by `EcsChecks.LineChecks` (own lists per
  component, paste and Reset copy points not lists, hidden child made, saved without it and removed with the
  component, save and load, trails in editor and play, freed with the scene); a test scene draws a tapered
  gradient line and a dashed loop, the Inspector edits the point list, and the Gallery self-test passes.
- [x] **Foliage.** Its settings are `FoliageData`; the packed plants text is a `String` the data owns (text in data
  that is long and changes with every brush stroke, so not a `SharedString`, which is interned and never freed):
  `HandleComponents.OwnLists` / `FreeLists` now copy and free `String` fields as they do lists, and the Inspector and
  scene files read them as `FieldKind.String`. The plants, cells, render proxy and own material are a `FoliageState`;
  the handle's `State` reads the text again whenever it differs from what was last read, which is what OnValidate
  did (loading, undo writing the text in place). `Foliage.All` is gone: the renderer reads `scene.Components<Foliage>`.
  **One per object:** a Foliage was documented as stackable on one object, and the Terrain Tools' Foliage tool did
  that. Now each kind of plant added from the tool is a child object of the terrain (named Grass, Bush...), the tool
  lists the terrain's own Foliage and its children's, and the brush paints a child's Foliage while the terrain is
  selected. A Foliage stands on the terrain of its object, else of its nearest parent, else the scene's
  (`Foliage.GroundOf`), so children of the terrain follow its sculpting. No scene in the samples, templates or
  projects had two Foliage on one object (the Campus scenes keep each on its own object). Checked by
  `EcsChecks.FoliageChecks` (defaults, each Foliage's own text, Paint, Add, Erase, Visible, Sync, save and load,
  re-read on a text change, Reset, freed on remove and with the scene); the editor's `--undo-test-foliage` passes on
  a one-Foliage scene, and Campus loads and draws. (On Campus itself that test paints off its terrain tile and adds
  nothing, as it did before.)
- [x] **Water and Floater.** Their settings are `WaterData` and `FloaterData`; the waves worked out from the settings
  and the bodies floating at the last step are a `WaterState`. `Water.At` returns a handle that is not valid where
  there is no water (`if (!water)`, not `== null`). The renderer, buoyancy (`Simulate`, rollback's `SimulateAt`) and
  the Character Controller's swimming read `scene.Components<Water>`. **[Sync] on built-in components:** Water's
  settings are `[Sync]`. NetworkSync's slots used to hold a pointer into the component; handle data moves between
  Flecs tables, so a slot for a handle field keeps its object, its data's index and its offset, and finds the field
  each time it is read or written (`Slot.Ptr`). Handle slots come after the class components' slots, by handle name,
  then field name, so every machine has the same order; the object's handle types are part of the slot list's
  signature. Checked by `EcsChecks.WaterChecks` (defaults, flat and waved surface after a setting change, Contains,
  At with several waters, switched off and inactive, [Sync] slots found and following the data to a new table, save
  and load, freed on remove and with the scene); the editor's `--separate-worlds-test` passes (a crate floats in its
  world state's water and one in the other falls through) and the Gallery self-test passes.
- [x] **Rigidbody.** Its settings are `RigidbodyData`; its body id is a `RigidbodyState` (OnRemove takes the body out of
  the physics world). With no Start, OnEnable or OnDisable, `Rigidbody.SyncAll(scene)` runs after the pending Starts
  of each tick and each frame, and once more when play stops: a switched-on Rigidbody on an active object gets its
  body while the scene plays (all of an object built in code exists by then, as Start relied on), and one switched
  off, on an inactive object, or in a stopped scene loses it. `EnsureBody()` still makes it at once.
  `PhysicsWorld.CreateBody` takes a `RigidbodyData*` (null for a static collider's body). The body calls (Velocity,
  AddForce, Sleep, State...) do nothing on a handle with no body, so code that used `GetComponent<Rigidbody>()?.X`
  reads as before with `.X`. The build's BF0472 warnings found 40 `== null` / `!= null` / `?.` uses in the engine
  (SavedTransform, NavigationAgent, NetworkIdentity, SoftBody, Rope, Joint, Water...), now `IsValid` or
  `HasComponent<Rigidbody>()`; `component as Rigidbody` (WorldStreaming's origin shift) and `component is Rigidbody`
  (SpawnPoint's crowding test) compiled silently and were always false, now queries. The showcase template's
  Gallery script had two more. Checked by `EcsChecks.RigidbodyChecks` (defaults, no body before play, calls on an
  absent body, body on play, falling, Velocity, switched off and on, inactive object, resting on the ground, a body
  built in code made at the next Starts with its collider, removal, stopping, save and load, freed with the scene);
  the Gallery self-test passes, `--separate-worlds-test` passes, and the Campus copy plays 400 frames without errors.
  Games that update to this engine need the same search (BF0472 on Rigidbody, `as`/`is Rigidbody`).
- [x] **CharacterController.** Its settings are `CharacterControllerData`; the Jolt character and everything it knows
  between steps (state, air time, swimming, push sizes) are a `CharacterControllerState`, which reads the settings
  from the entity each time (`[DataFields]` over a `ref` property), because SetCapsule, SetBox and the network write
  them. The handle forwards the API unchanged; its read-only properties give "none" on a handle that is not valid, and
  `Teleport` does nothing there (NetworkIdentity used `?.Teleport`). `CharacterController.SyncAll` makes and takes away
  characters beside `Rigidbody.SyncAll`. `PhysicsWorld.Controllers` lists the states (soft contact between
  characters). Wind, world streaming's origin shift and spawn crowding read `scene.Components<CharacterController>`
  (two of those were `component is/as CharacterController`, silently false). Checked by `EcsChecks.CharacterChecks`
  (defaults, Move without a character, made on play, falling to the ground, walking, SetCapsule writing the
  settings, switched off and on, Teleport, a missing controller, stopping, save, freed on remove and with the scene);
  the separate-worlds test (characters in two world states) and the Gallery self-test pass, and Campus plays.
- **Staying classes for now** (each listed with what it waits for):
  - **Colliders** (Box, Sphere, Capsule, Mesh, Compound, Convex) — **decided 2026-11-05 by the project owner:
    (a), they stay classes.** Stacking keeps working as it does, nothing changes for games. They are a class
    hierarchy (`GetComponent<Collider>()` finds any kind), static bodies are made once at Start with no per-frame
    cost, and objects stack them: without a Rigidbody each collider is its own static body, and the Tumble Toys
    aircraft prefabs put several BoxColliders on one object (a Rigidbody takes only the first). Handles allow one of
    a kind per object. Options: (a) keep them classes; (b) one of each kind per object, with every collider on an
    object merged into one compound body (stacked ones moved into a Compound Collider when a scene loads); (c)
    stacked colliders moved to child objects when a scene loads.
  - **Joint and Rope** hold references to other objects (`Rigidbody connectedTo`, `Transform startAttachedTo`), and
    built-in component data cannot hold object references yet (DataComponents leaves them out: a pointer would
    dangle, and saving, the Inspector picker and clearing on destroy are not done for data). Phase 5: object
    references in data (an entity id, saved as the object, resolved on use), then these two and LODGroup.
    *Unblocked:* `ObjectRef<T>` is done (Phase 5 progress). *Since then:* Joint and LODGroup are handles; Rope (with SoftBody) stays a
    class for now (Phase 5 progress, "Staying classes for now: Rope and SoftBody").
  - **SoftBody** runs a FixedUpdate and LateUpdate of its own and shares its native proxy pass with Rope
    (`UpdateProxies(world, softBodies, ropes)`); it moves with Rope in Phase 5. A handful per scene, so nothing is
    lost meanwhile.
  - **LODGroup** (holds renderer handles) and **UIDocument** (stacked on objects in every project) as before.
- [x] **Phase 4 exit.** A Gallery made from the showcase template with everything above converted builds and its
  `--self-test --frames 1500` prints `SHOWCASE_READY rooms=8 probes=2` with no `[error]` line, which is what
  `tools/validate_showcase.py --play` checks on a packaged engine (the package step itself is Phase 8's release
  build). EcsBench checks all pass; the Campus copy plays 400 frames clean.

## Phase 5 progress

Same method as Phase 4: one component at a time, each with its checks, committed on its own.

- [x] **Animator.** Its settings are `AnimatorData`; `clips`, `defaultClip` and `controller` stay `String` (text the
  data owns), so `animator.clips.Append(...)` and `defaultClip.Set(...)` work as before. The bones, clips playing,
  controller, layers and parameters are an `AnimatorState`, which reads the settings from the entity each time; the
  handle forwards the whole API. With no Start or OnLocalUpdate, `Animator.FrameAll` runs in a new `Frame.Animators`
  step right after `Frame.Update` (the scripts' Update and OnLocalUpdate) while playing: it starts animators that have
  not started (Bind, then the default clip) and moves every switched-on one on an active object a frame on, so
  scripts' parameters are in before the pose and LateUpdate and IK see it, as with the usual component order.
  `StopPlay` lets them start again next play. Flecs gives steps unique names: a second "Frame.Animation" step
  silently replaced IK's, so the new one is "Frame.Animators". `GameObject.GetComponentInChildren<T>()` has a handle
  overload. Network animation messages name the animator by its object, as Skinned Mesh Renderer's do (the
  messages are a few bytes shorter than with the component index). `tools/fix_handle_nulls.py <build log> <Type...>` rewrites the BF0472 `== null` / `!= null` sites the build reports into `IsValid`; 22 were in the
  editor's animation and rig tools, more in Sequence and the Sandbox's CharacterAnimation. Checked by
  `EcsChecks.AnimatorChecks` (defaults, owned clip text, GetComponentInChildren, started by the step, SampleClip
  posing a child bone, stopping, save and load, freed on remove and with the scene); the Sandbox character idles
  (not in its rest pose), the editor's `--rigger-test` passes, the Gallery self-test passes and Campus plays.
  `--rig-test` needs a character whose model has clips: on one without, it now says so instead of stopping on an
  index out of range.

- [x] **Object references in data (`ObjectRef<T>`, Engine/src/Scene/ObjectRef.bf).** Holds the target object's id
  (and, for a class component, its index on the object) and looks it up when used. A destroyed object is not
  found, so the reference reads as none without anything having to clear it, and nothing dangles when the data
  moves tables. T is GameObject, Transform, a class component or a handle. It converts from a GameObject,
  Transform or Component, so `agent.surface = surface;` reads as before. `ComponentRegistry` treats it as an
  ObjectReference field (`ObjectRefs.Owner` / `Assign`), so it saves as class references do (`field surface <id>
  <index>`), loads (remapped for copies, re-finding the field after the entity has moved tables) and is picked in
  the Inspector. `FieldRef` gained `owner` / `ownerType` (set by `DataComponents.GetFields(..., owner)`), which
  give the reference its scene. Scene reference slots and script reload migration skip ObjectRef fields.
- [x] **NavigationAgent.** `NavigationAgentData` (the settings; `surface` is an `ObjectRef<NavigationSurface>`),
  the `NavigationAgent` handle and `NavigationAgentState` (the path, steering, link crossing, OnLinkStarted /
  OnLinkFinished events). `agent.Surface` is the resolved surface, the one set or the one SetDestination found
  (`agent.surface?.Data` becomes `agent.Surface?.Data`); the state resolves it once per update or tick.
  `NavigationAgent.FrameAll` (a new `Frame.Navigation` step after `Frame.Update`, before `Frame.Animators`) does
  what OnLocalUpdate did and stops an agent that has been switched off, as OnDisable did. `TickAll` (a new
  `Tick.Navigation` step after `Tick.FixedUpdate`) does what FixedUpdate did. The scene's crowd index holds states
  (listed when first made, taken out in OnRemove with the path queue). A handle can't derive from
  `AIMovementDriver`, which stays for projects' own movers: `BTContext.Mover` is now an `AIMover` struct holding
  the object's Navigation Agent or its driver (`mover.IsValid` instead of `!= null`). Checked by
  `EcsChecks.NavigationChecks`: defaults, the reference, the crowd, walking a baked path, switching off, save and
  load to the loaded surface, a destroyed surface reading as none, and freeing. A surface's box runs from its
  position by its size, not around it. The Sandbox's Navigation scene at frame 480 matches the previous commit,
  apart from one agent slightly further along (agents now move after all the scripts' Update, not in component
  order). The Gallery self-test passes and Campus plays.
  Games that update: `GetComponent<NavigationAgent>() == null` checks (fix_handle_nulls.py), `agent.surface?.Data`,
  and a project's `AIMovementDriver` subclass keeps working through `AIMover`.

- [x] **BehaviorTreeRunner.** `BehaviorTreeRunnerData` (`tree` and `startValues` are owned String), the handle,
  and `BehaviorTreeRunnerState` (the tree, blackboard and events), which is what nodes see as `context.runner`,
  with GameObject / Transform / Scene / GetComponent (class and handle) so node code did not change. A new
  `Frame.Behaviour` step after `Frame.Update` and before `Frame.Navigation` does Start (Home, Start Values, the
  tree) once per play and OnLocalUpdate, and aborts running nodes when a runner is switched off (OnDisable).
  OnRemove ends the running nodes as OnDestroy did, except when the whole scene is being cleared. The handle's
  tree file is `runner.TreeData`, since a handle's `Data` is its settings. The editor's Behavior tab works on the
  state. Checked by `EcsChecks.BehaviourChecks`: defaults, start (Home, tree, Start Values), an Alarm sent for
  each Hit, no ticks while switched off, save and load, freeing. The Sandbox's Navigation scene plays with no
  warnings: its wandering agents match, and its Guard wanders differently on every run on both builds (the tree
  context's Random is unseeded). The Gallery self-test passes.

- [x] **Handles in save games.** `[Saved]` fields in a `[HandleData]` struct get SaveCodegen's `SaveFields`, and
  `[HandleData]` adds `static SaveData(void*, SaveIO)` calling it. SaveSystem's Capture and Apply include each
  handle on an object whose data has one, keyed by the component's full name. A handle may have
  `static void OnSaving(GameObject)` / `OnLoaded(GameObject)` (what a class component's overrides did), found
  as `DrawGizmos` is.
- [x] **Handles' OnGUI.** A handle may have `static void OnGUI(Scene)`. `GUI.Run` calls them
  (`HandleComponents.RunGUI`) after the class components'.
- [x] **DialogueRunner.** `DialogueRunnerData` (settings, `[Sync]` fields with the `syncChoices` text, `[Saved]`
  fields), the handle, and `DialogueRunnerState` (the conversation, voice, events). A new `Frame.Dialogue` step does
  Start (Play On Start), OnLocalUpdate and OnDisable; its OnGUI, OnSaving and OnLoaded are the static hooks above;
  Awake runs when its state is made. A client's requests name the object (one runner per object), not a component
  index. The Inspector's runner tools moved to `DrawHandleTools`. Made by `tools/class_to_handle.py` (it moves a
  class component's settings into data, its body into the state, writes the forwarders, FrameAll / StopAll /
  OnGUI / OnSaving / OnLoaded / OnRemove from the overrides it has, and `tools/handle_data_defaults.py` gives bare data fields
  `= default`). Checked by `EcsChecks.DialogueChecks`: defaults, Play On Start, a line, the answers, a choice
  setting a variable, an event reaching the game, a save keeping its `[Saved]` fields and loading putting them back,
  freeing. The Sandbox guide's welcome line shows as before; the Gallery self-test passes.

- [x] **SequencePlayer.** Made with `tools/class_to_handle.py` as DialogueRunner was: `SequencePlayerData` (settings,
  `[Sync]`, `[Saved]`), the handle (`SequencePlayer.PlayingCount` too) and `SequencePlayerState`. A new
  `Frame.Sequences` step does Start / OnLocalUpdate / OnDisable. OnRemove does what OnDisable did as a component
  went: it stops counting as playing and, unless the scene is being cleared, puts back what it moved (Restore
  When Done). Client requests name the object; the Sequencer window finds players with `FindComponents`. Checked by
  `EcsChecks.SequenceChecks`: defaults, Play On Start, a track moving its object, a save, finishing and the playing
  count, playing again, removing it restoring the object, freeing. In the Sandbox's Navigation scene the crate
  follows its sequence as before; the Gallery self-test passes.

- [x] **SpawnPoint.** All data (`SpawnPointData`, its use counters `[NonSerialized]` there too), no runtime
  state; its gizmo is the handle's static DrawGizmos. `SpawnPoints` (Next, Random, Place, Count, the start phase)
  works on handles and returns an invalid one where it returned null. World streaming keeps objects with one by
  `HasComponent` (an `is SpawnPoint` there had silently become false). Map rules find a handle field's default
  from its data's initializers. Checked by `EcsChecks.SpawnChecks`: defaults, Count, the start phase line-up first,
  teams, Place, switched off, saving settings but not use, loading. The Gallery self-test passes.
  Games that update: `SpawnPoints.Next(...) != null` and `point == null` (fix_handle_nulls.py).
- **Staying classes for now (Phase 5):** the IK components (LimbIK, LookAtIK, FootPlacement, HandPose). They
  share an abstract base that layers each solver over the pose before it, fade their weight with a network event
  (`NetworkSync.SendEvent` / `OnNetworkEvent` on a Component), give the pose back in OnBeforeSave, and the editor's
  rig tools (IK rig setup, hand posing, baking) and ShatterLock's WeaponHold build them in code and keep them as
  class references. A scene has a handful, so the ECS gains nothing measurable. Converting them needs
  `OnNetworkEvent` and `OnBeforeSave` for handles first. The state classes could keep the abstract base as it is.

- [x] **SceneLoader** (tools/class_to_handle.py): data, handle, state (the load); a `Frame.SceneLoaders` step does
  Start (Load On Start) and OnLocalUpdate. Checked by `EcsChecks.SceneLoaderChecks` (an additive load from Load On
  Start, progress reaching 1).
- [x] **UI bindings find built-in components' fields.** `UIDocument.FindField` (bind="...") looked only through
  class components, so since Phase 4 a document could not bind to a converted component's field (a Light's
  intensity, say). It now looks through the object's handles' data too. Already so before the ECS work:
  SceneLoader's `progress` is `[NonSerialized]`, which leaves it out of the fields a binding can find, so the
  `bind="progress"` its documentation suggests finds nothing. Left as it is (making it a field would add it to scene
  files); worth a decision.

- [x] **SavedTransform.** `SavedTransformData` (what to keep), the handle, and a `SavedTransformState` made only
  when a velocity is loaded before the object's body exists. A handle may now write its own save with
  `static void SaveFields(GameObject, SaveIO)` (`HandleComponents.Info.saveObject`; `Info.Save` calls whichever
  the handle has). Its save entry keeps the class's key, `Tallow.SavedTransform`, so existing saves load. A
  `Tick.SavedTransforms` step after `Tick.FixedUpdate` hands a waiting velocity to the body or character, as
  FixedUpdate did. Checked by `EcsChecks.SavedTransformChecks`: defaults, a save with place and velocity, loading
  them back while playing, and a velocity loaded before play given on the first tick. The Gallery self-test passes.

- [x] **StreamingSource.** A data-only handle (`extraRadius`); the streamer finds sources with
  `scene.Components<StreamingSource>` instead of the `Scene.StreamingSources` list they registered in (removed),
  and streaming keeps objects with one by `HasComponent`. The editor's `--world-streaming-test` passes on a
  scratch project (its walker has a source: loading round it, stand-ins, the floating origin).

- [x] **Handles' OnValidate.** A handle may have `static void OnValidate(GameObject)`; the Inspector calls it after
  changing one of its fields, and the scene loader after reading the scene, as for class components.
- [x] **ViewmodelPose** (tools/class_to_handle.py, then by hand): data, handle, state. A `Frame.Viewmodels` step
  after `Frame.LateUpdate` does what LateUpdate did; switching it on again forgets the camera's last place (what
  OnEnable did); its edit-mode preview is the OnValidate hook above. The Inspector's hip / aim buttons moved to
  `DrawHandleTools`. Checked by `EcsChecks.ViewmodelChecks`: defaults, the preview from OnValidate and from reading
  a scene, coming up to aim while playing, Kick.

- [x] **ComputeEffect** (tools/class_to_handle.py, which now takes OnFrame too): data, handle, state (the texture,
  the shader, the values set). `ComputeEffect.FrameAll` runs from `Scene.RunOnFrames`, in edit mode as well as
  play, as OnFrame did; switching it off or removing it gives the Mesh Renderer its own texture back (OnDisable).
  Checked by `EcsChecks.ComputeChecks`: defaults, nothing to run without a shader, and with Sandbox's compiled ripple
  shader copied in for the check, a frame in edit mode running it on the GPU and showing it, and switching it off.

- [x] **ModelMesh** (tools/class_to_handle.py, then by hand). `ModelMeshData` (the model text, materials, World Scale
  UVs), the handle, and `ModelMeshState` (the edit mesh, the shared mesh, previews, parts; the shared-mesh table
  moved with it). A handle has no hook for being added, so instead of OnRegister it builds lazily: `ModelMesh.FrameAll`
  (from `Scene.RunOnFrames`, edit and play) builds any that `NeedsBuild`, switched on or not, and does OnFrame for the
  rest; its static OnValidate builds one as a scene is read. Code that sets a model through `Set` / `Save` builds at
  once, as before. OnRemove does OnUnregister (or only gives up its share of the mesh while the scene clears).
  `GameObject.ComponentOn<T>(object)` is new: what `object?.GetComponent<T>()` gave for a class component.
  The modelling tools were updated (`?.GetComponent<ModelMesh>`, `return null`, `model.GetComponent`, null checks).
  Checked by `EcsChecks.ModelMeshChecks` (Set, sharing, a copy built the next frame even switched off, reading a
  scene, removing), the editor's `--model-test` and `--palette-test` (both PASS on a scratch project), and the
  Gallery self-test.

- [x] **LODGroup** (tools/class_to_handle.py, then by hand). `LODGroupData`, the handle (with `Source`, `Bias`,
  `ForceLevel` and `LevelInName`), and `LODGroupState`, which a renderer's `RenderProxy.LodGroup` now points to. The
  state keeps a copy of the settings, taken at each Refresh and each level pick (once per group per camera a frame),
  so drawing (`LevelForHeight`, `MeshAt`, `TrianglesAt`) reads no entity data per renderer. Like ModelMesh it has no
  OnRegister: `LODGroup.FrameAll` (in `Scene.RunOnFrames`) refreshes one not yet refreshed, switched on or not, and
  does OnFrame for the rest; static OnValidate refreshes it as a scene is read; OnRemove does OnUnregister. The
  Inspector's LOD tools moved to `DrawHandleTools`. Checked by `EcsChecks.LODChecks` (finding levels next frame,
  levels by distance, culling, a setting changed by code, a new child, reading a scene, removing) and the editor's
  `--model-test` (Make Levels of Detail). A/B against 785b001f on Sandbox's Culling scene (33 groups, 900 frames,
  3 runs each): 9.53 s against 9.49 s average (the run may be frame-capped, so this shows no regression rather than
  a gain), and the final frames are pixel-identical.

- [x] **VoxelObject** (tools/class_to_handle.py, then by hand). `VoxelObjectData` (shape, size, colours, pieces...),
  the handle, and `VoxelObjectState` (the grid, mesh, surface, pieces). OnRegister's two halves moved: the grid is
  filled when the state is made (its first use; code that adds one sets its fields first, so the shape is theirs),
  except while `SpawnPiece` is making a piece, which hands over its own grid; the mesh is built by `FrameAll`
  (`Scene.RunOnFrames`) the first frame one has none, switched on or not, or at once by OnValidate / Rebuild / Carve
  as before. OnRemove does OnUnregister. `OnValidate()` stays public on the handle (scripts call it after setting a
  shape). Network carves route the handle. Checked by `EcsChecks.VoxelObjectChecks` (shape set before first use,
  built next frame with a renderer added, Carve, a half cut off breaking away as a piece with its settings and own
  grid, piece lifetime, reading a scene, removing), the editor's `--palette-test` and `--separate-worlds-test`
  (PASS), and the Gallery self-test.
- [x] **Script null checks found by building projects.** A handle compared with null in a script only warns
  (BF0472), and template scripts are compiled only inside a project, so these were missed: the showcase
  Gallery's `voxels != null` (always true, so its terrain branch never ran), the common template's
  CharacterAnimation (`mAnimator == null || body == null`, always false since Phase 4), and ProjectGenerator's
  generated `camera == null` and `voxels != null`. All fixed. A fresh default project, a fresh showcase and Sandbox
  now build with no BF0472 in their scripts. To find more: build a project with `BeefBuild -verbosity=normal` and
  grep BF0472.
- [x] **`Scene.ComponentsOfType(typeof(SomeHandle))`** finds nothing, as a handle is not a Component class (and
  `(SomeHandle)component` compiles); it now logs a warning once per type naming `scene.Components<T>()` instead.
  `GameObject.ComponentOn<T>(object)` is for engine and editor code; inside a script `GameObject` is the
  component's own object, so scripts write `o != null ? o.GetComponent<T>() : T()`.
- Games that update for VoxelObject: `GetComponent<VoxelObject>() != null` / `?.Carve` (use IsValid),
  `ComponentsOfType(typeof(VoxelObject))` with `(VoxelObject)c` (use `Scene.Components<VoxelObject>()`).
  Seen in the user's MyGame / Canous (AuthoredCampus, Exhibition), Gallery copies and Digger copies.

- [x] **Joint.** `JointData` with `connectedTo` an `ObjectRef<Rigidbody>` (saved as `<object id> -1`, as the
  class's handle field was, so existing scenes load), the handle (`ConnectedTo` gives the Rigidbody, `Connect`,
  `IsConnected`, `Rebuild`, a static DrawGizmos) and `JointState` (the physics joint). A `Frame.Joints` step does
  Start / OnEnable / OnDisable; OnRemove lets the joint go, also when its object is destroyed (bodies should not go
  with a constraint still on them). `ObjectRef<T>` converts implicitly from T, so `joint.connectedTo = body` takes a
  handle. Checked by `EcsChecks.JointChecks`: Connected To round trip and saved format, made at play, holding a
  swinging weight at its length, switched off and on, Connect (and not to itself), removal while connected,
  reading a scene. Games that update: ShatterLock's Ragdoll (`GetComponent<Joint>()?.IsConnected == true`, use
  `.IsValid && ...IsConnected`); `Joint.Connect` returns an invalid handle, not null.
- [x] **`GameObject.IsGoing`** (destroyed, or its scene emptying). When an object is destroyed its class components
  are unregistered first, then `World.Delete` runs its handles' OnRemove in Flecs' own order, so a handle's
  OnRemove must not reach into the object's other built-in components, which may already be freed. ModelMesh,
  LODGroup, ComputeEffect, VoxelObject and BehaviorTreeRunner now check `IsGoing` instead of only the scene clearing;
  `DestroyTree` sets the destroyed flag before deleting the entity (DestroyImmediate did not). SequencePlayer
  (puts back other objects) and Joint (the physics constraint) still act when only their object goes.
- **An intermittent SIGTRAP in the checks** turned out to be the voxel check reading a destroyed GameObject
  (`fragment.IsDestroyed` after it was deleted; Beef's debug object check traps). Fixed in the check (look the id
  up). To find such a crash without a debugger: `coredumpctl info -1` gives the stack, `addr2line -e <exe> <addr>`
  the line.
- **Staying a class for now: VoxelTerrain.** One per scene; split over nine `extension VoxelTerrain` files;
  OnRegister starts worker threads; its own undo, streaming and editor brushes. Nothing measurable to gain, real
  risk. Converting it needs threads that hold the state class (not `this` component) and the extensions moved
  onto the state.

- **Staying classes for now: Rope and SoftBody.** A scene has a few. Both are tied into PhysicsWorld (its rope list
  and soft-body proxies hold the class, with native tie / body handles), networking (rope ties, snaps and changes
  are requests addressed by component index; dents are shared), Water (floating ropes) and each other
  (`SoftBody.UpdateProxies` takes the ropes), and no test covers them yet beyond the Gallery's rope. Converting them
  is possible now (`ObjectRef<Transform>` for the attachments; note `ObjectRef<T>`'s implicit conversion from T
  would duplicate the Transform one for that T, so it needs a guard first) but gains nothing measurable. Do it
  with rope and soft-body checks written first, against the class.
- **Phase 5 status (2026-11-05):** converted Animator, NavigationAgent, BehaviorTreeRunner, DialogueRunner,
  SequencePlayer, SpawnPoint, SceneLoader, SavedTransform, StreamingSource, ViewmodelPose, ComputeEffect,
  ModelMesh, LODGroup, VoxelObject and Joint. Staying classes, each with its reason above: the IK components,
  VoxelTerrain, Rope, SoftBody. Exit check: the Gallery (Showcase) self-test passes (`SHOWCASE_READY rooms=8`, no
  errors), with EcsBench checks, the editor's model, palette, separate-worlds and world-streaming tests. Colliders
  (from Phase 4): the project owner chose (a), they stay classes (2026-11-05).

## Phase 6 progress

### Baselines (2026-11-05)

The network tests were taken out of the repo in 80213f07; they are kept outside it (by request) in
`~/TallowEcsTests`, with `nettest.sh <engine root> <test> <out dir>` (CONFIG=Release for timing) and `main`'s output
in `baseline-main/`:

- `Network` (82 checks; `NetworkEcs` is the same test written for this branch: `Update(TickInput, float)`,
  `CharacterController.SyncAll`, state classes, handle tests with `.IsValid`), `NetworkBandwidth` (31),
  `PhysicsPrediction` (22).
- `NetworkBytes` (new): a hash of every byte a server sends to two clients, then three, over 150 ticks of 64 props
  (half of them bodies, moving, then resting), for each fixture profile (baseline exact quantized sleep rate budget
  compressed all steam, set as Tumble Toys' NetworkValidation sets them). This is the 6a exit's "same bytes as
  `main`".
- `NetworkPerf` (new): the same with 2000 props, timing the server's SendSnapshots and the frame, plus a run with
  no identities as a control.

Before any 6a change, `main` (e9d87cdd) and this branch (6aa1c427) gave the same results on all of them.

### 6a steps

- [x] **NetworkIdentity is a handle** (`NetworkIdentityData`: format, interval, dormancy, distance filter,
  priority, physics prediction, player control, owner, team, correction smoothing; `NetworkIdentityState`: the net
  id, history, keys, prediction and smoothing state). `NetworkBehaviour` moved to its own file, unchanged.
  - Two new handle hooks, found by reflection like the others: `static void OnAdded(GameObject)`, called by
    `HandleComponents.Add` (AddComponent, a scene or prefab line, the Inspector) before saved fields are read, as
    a class component's OnRegister was (and OnEnable while playing); and `static void OnSwitched(GameObject, bool
    on)`, called while playing when the component starts or stops counting as on: `SetActive` (and its children),
    `enabled`, a switch from the session (`HandleComponents.SetEnabled`), and play starting and stopping (the
    scene goes through its objects in the order they were made, before the class components wake, and backwards
    when play stops). Identities join the session at exactly the moments the class did, so `Identities` (the
    order snapshots list objects in) and `mPartsIdLimit` are the same.
  - `NetworkManager.IdentityStates` keeps each identity's state beside its handle, and the per-object loops of
    the server (snapshots, PostTick) use it; a state converts to its handle implicitly. Settings are read once per
    record. The snapshot order is computed once per candidate rather than in every comparison (the order is total,
    by NetId, so the result is the same).
  - `ComponentHandle` gained `GetComponent<T>` / `HasComponent<T>` (the object's) and `IHashable` (handles are
    dictionary keys: NetworkSync's slots). Offline networked Update (`TickUpdatesOffline`) and
    `RegisterSceneIdentities` go through the scene's objects in order, as the class registry did.
  - An identity's own on/off switch is not sent to other machines (as before; `is NetworkIdentity` tests on class
    components, now always false, were removed). WorldStreaming keeps cells with identities by `HasComponent`.
  - A wire detail: `team`'s [Sync] slot now comes after the class components' [Sync] fields (handles' fields are
    listed after the classes'). Both ends run the same engine, so this only matters to a recording.
  - Fixed while here: `LODGroup` kept MeshRenderer handles of LOD children that `DestroyImmediate` freed, and its
    next Refresh read the freed object (the editor's `--model-test` crashed, also before this change). It keeps
    each renderer's entity and checks `World.IsAlive` before touching one. **The model test had been run on a
    scratch copy of MyGame whose engine path pointed at another worktree** (tallow-rename-continue), so the Phase
    5 notes saying it passed were not about this branch; it and the other three editor tests are now run in a
    fresh project made by this branch's launcher (`--create`), where all four pass.
  - Sandbox's FollowCamera and BallLauncher and ProjectGenerator's camera script tested `identity != null`, which
    is always true for a handle and so asserted on objects without one in a session: `identity.IsValid`.
  - Checked: `NetworkEcs` 82, `NetworkBandwidth` 31, `PhysicsPrediction` 22, all the same as `main`, and
    `NetworkBytes` identical for all nine profiles (also at 2000 props); `EcsChecks.NetworkIdentityChecks` (joins
    at play and at once when added during play, in order; leaves and joins as its object or itself is switched;
    removed, destroyed, play stopping; settings saved and read; corrections eased and drawn); EcsBench checks;
    Gallery self-test; editor model, palette, separate-worlds and world-streaming tests.
  - Timing (Release, 2000 props, 3 clients, 150 ticks; SendSnapshots ms, `main` / this branch):
    baseline 94 / 103, quantized 63 / 82, all 81 / 90. Before the state list and hoisting it was 123 / 177 / 177.
    What is left is mostly handle lookups in CaptureState (the Rigidbody's). The identities' per-frame easing costs
    about 2 ms over the 150 frames, against 5 ms for the class's OnFrame (most identities have nothing to ease and
    are skipped).
  - **Found, not networking:** a frame with 2000 objects (1000 of them bodies) and no identities costs 25 ms over
    150 frames on this branch against 0 on `main`: the handles' FrameAll passes (each builds a list of its
    components every frame). To look at in the performance pass.
  - Games that update: `GetComponent<NetworkIdentity>() == null` / `!= null` (use `.IsValid`), `?.` on an
    identity, `as` / `is NetworkIdentity`, `NetworkIdentity x = null` (use `default`), `FindIdentity` returning
    an invalid handle, not null. Build with `-verbosity=normal` and grep BF0472 to find the tests.
- [x] **Column snapshots** (2026-11-05). The optimized send (every profile but `baseline`) reads what it needs of
  each identity once per tick into a row (`SnapshotRow`: its `NetworkIdentityData`, position, net id, change
  number, whether it rests) instead of once per client, and writes each record at most twice a tick, for the
  object's owner and for everyone else, copying the bytes into each client's packets (a record depends on the
  client only through who owns the object). Rows are in registration order, not Flecs order: snapshot order is
  part of the bytes. NetworkBytes the same as `main` for all nine profiles; Network, NetworkBandwidth and
  PhysicsPrediction too. NetworkPerf (2000 props, 2 clients, Release, three interleaved runs, send ms):
  quantized 74-78 (main 63-64, this branch before 82), all 75-80 (main 80-82, before 90), baseline 99-105 (main
  92-93; that path is unchanged). Left for 6b: quantized is still slower than `main` (the body and transform reads
  through handles); the frames with no network work (the `noid` control: 25 ms over the run against 0) are the
  FrameAll item above.
- [x] **Rollback through the fixed pipeline.** A tick is now Tick.Starts (its own pipeline, `TickStart`), then the
  network's receive (`NetworkManager.PreTick`, called from `Scene.FixedUpdate` between pipelines), then
  `TickPipeline`. The receive left the pipeline because a correction rewinds and replays ticks, and Flecs keeps one
  current-pipeline state per world (`world->pq`), so a pipeline run inside a step would break the tick around it.
  Each replayed tick runs `Scene.ReplayPipeline`: Replay.RemoteStates (PostLoad), Replay.Update (PreUpdate: the
  networked Update and Simulate of what this machine controls), Replay.Physics (OnValidate: water and Jolt, when
  anything replayed needs it), Replay.Record (PostUpdate: history for the next comparison). A game adds its own
  predicted systems to it beside TickPipeline. Same work in the same order as the loop it replaces. A game step
  added to TickPipeline at OnLoad now runs after the receive (it ran before). Checked: Network, PhysicsPrediction
  (which corrects and replays: 1, 2 and 11 corrections in its cases), NetworkBandwidth, Voice and NetworkBytes the
  same as `main`; EcsBench checks.
- [x] **Restored suites, beyond networking** (2026-11-05): the 45 other suites taken out in 80213f07, each run on
  `main` and on this branch (`~/TallowEcsTests`, scratch runner): 25 give the same results; 5 fail the same way on
  `main` (AsyncLoading, CodeEditor, GraphApi, Http, Material: not this branch's doing); Maps and AntiCheat (network)
  match after the MapFiles fix (a map's `component` lines may name built-in components). Decals, Water and
  ScriptCatalog match with branch copies (Water registers its identity through `Register`; ScriptCatalog names a
  built-in component that is still a class). The 16 suites written against the class API have branch copies too
  (lifecycle calls become `Runtime.Frame()`/`Tick()`/`Start()`, `== null` becomes `IsValid`, save hooks are the
  handles' static OnSaving/OnLoaded, one runner or Foliage per object) and all 16 give `main`'s results:
  AnimationLayers, BehaviorTree, CharacterController, Culling, Dialogue, Foliage, Joints, Navigation,
  NavigationMesh, Profiler (timings only), References, Sequencer, SkinnedMaterials (crashes at the same place as
  on `main`), SpawnPoints, Viewmodel, VoxelObject. Engine fixes they found:
  - Dropping an object without the component on a handle-typed reference field cleared it; it now leaves the
    value as a class field does (References: save/load and prefab remapping of `Camera` fields).
  - SpawnPoint picks among points in creation order again (Flecs query order changed which of two equally old
    points won).
  - `LODGroup.LevelForHeight` reads the current settings (it used those of the last pick).
  - NavigationAgent joins the scene's crowd index when added (`OnAdded`), not on first use: the index and other
    agents' avoidance missed agents before their first frame and in edit mode.
  - VoxelObject builds its mesh when added (`OnAdded`), as OnRegister did, not on the first frame.
  Rechecked after them: Network, NetworkBytes (same bytes), Water, Maps, Decals, AntiCheat, ScriptCatalog and the
  Gallery self-test. Water's timing line is slower on this branch (194 µs against 145 µs, Debug); open item: a
  frame with 2000 objects and no networked ones costs about 0.17 ms more than `main` (the handles' FrameAll
  passes each walk the scene), to look at with the profiler in 6b.
- [x] **Lag compensation and host migration checked on the handles** (2026-11-05). Lag compensation: the Network
  suite's rewind checks pass as on `main`. Host migration had no test on either branch, so one was written
  (`~/TallowEcsTests/HostMigration`, builds unchanged against both): a host and two clients over loopback with
  HostMigration on; the host spawns a pickup and changes a [Sync] field, then leaves. The first client becomes the
  host, the second reconnects with its old client id, the old host's player goes, the others keep their owners
  (the new host's own player becomes owner 0), the world is as it was, and the new host's field changes and
  spawns reach the client with no repeated net id. 12 checks, the same on `main` and `ecs`, three runs each clean.
- [x] **Networked Showcase exhibits (the 6a exit)** (2026-11-05). The Gallery had none: it now starts a session
  in `Gallery.Awake` when run with `--host` or `--connect <address>` (`--port`), before the visitor exists, so the
  scene's moving exhibits are shared and each machine keeps its own visitor and balls (README updated). A test
  switch `--net-report N` prints what is shared, where, and each voxel object's surface size;
  `~/TallowEcsTests/gallery_net.sh` makes a Gallery from this branch, runs a host and a client 4 s apart and
  compares them. Physics Yard (8 shots into the crate stack): 43 shared objects, 23 moved, every one but the
  walking robots within 0.25 m on the client (all at 0.00), the robots walking on the client. Voxel Quarry (20
  cuts before the client joined): the cut pillar's surface identical on the client. Found on the way, also on
  `main`: the patrol robots never set off (a robot not yet sent anywhere has neither arrived nor failed); fixed
  in the template. The plain self-test still gives `SHOWCASE_READY rooms=8 probes=2 objects=368`.

**6a exit: met (2026-11-05).** Networked Showcase exhibits pass, and NetworkBytes gives `main`'s bytes for all
nine profiles.

### 6b steps

- [x] **Automatic per-object choices and Advanced foldouts** (2026-11-05).
  - `NetworkIdentityData.automatic` (on by default): each snapshot the server works out the settings it uses
    (`NetworkIdentityState.Choose` into `Chosen`, with `ChosenKind`) from what is on the object. A player's
    object (owned by a client, or spawned from the player prefab): packed transform, sent first. A dynamic
    Rigidbody: `QuantizedBody`, distance relevance, and dormant while asleep unless clients predict it (a
    predicted body at rest has to be mentioned now and then, or a client that stopped predicting it never takes
    it up again: PhysicsPrediction found this). Anything else: packed transform, distance relevance. Only
    settings left at their defaults are chosen; one set by hand is kept, so code that sets `remoteIntervalTicks`
    keeps working (NetworkBandwidth found this). Off: the settings exactly as set.
  - The packed transform (`Legacy`: 2 mm steps, a two-byte turn while upright) is what players and movers get,
    not `QuantizedTransform` as the table above said: it is never larger, and smaller for upright things (the
    running-players check measured it).
  - `OptimizeSnapshots` and `LosslessCompression` are on by default (NetworkManager and NetworkSession).
  - The optimized send now treats a client's own objects like the rest (sent while they change, a few times
    more, then at the refresh rate; it sent them every snapshot) and lets other records share their packet while
    they fit (it always began a new one). Idle traffic to a client in the Network suite: 340 bytes a second on
    `main`, 1980 with the optimized path as it was, 260 now; two players running: 2141 on `main`, 2221 now.
  - `[Advanced]` (new attribute): the Inspector draws such fields under a closed Advanced foldout. Every
    Network Identity setting but Player Controlled, and the Network Session's tuning, are Advanced.
  - Checked: NetworkBytesEcs (the nine profiles with `automatic = false` give `main`'s bytes; a tenth, `auto`,
    with nothing set: 72,105 bytes against 547,798 for `baseline` and 48,020 for the hand-tuned `all`),
    Network, NetworkBandwidth, PhysicsPrediction, Voice, HostMigration, AntiCheat, Water, Maps, Decals,
    Dialogue, Sequencer, SpawnPoints, ScriptCatalog.
- [x] **Network panel** (2026-11-05). Window > Network (`--network-window` opens it): the session, each
  client with the bytes a second sent to it and its controls waiting, the bytes of the last second by kind of
  message (snapshots, object state, ropes, soft bodies...; engine messages are counted by their own id inside
  MsgCustom), and each shared object with what it was taken as, its format, its bytes a second and why
  (`NetworkIdentityState.Explain`). `NetworkManager.Describe` writes the same as text (the Gallery's
  `--net-report` prints it). What it found at once in the networked Gallery: 9,885 bytes a second to one client,
  6,480 of them the two flickering braziers, because changed light settings were looked at and sent every tick.
  They are now looked at once per snapshot: 5,510 bytes a second, of which the swinging wrecking ball is 1,100 and
  each predicted crate at rest 55.
- [x] **Self-tuning** (2026-11-05), with nothing set by hand:
  - Input delay: already tuned (the client aims for a number of ticks of its controls waiting on the server,
    raised when the server runs dry, lowered after 200 calm snapshots, and steers its clock by it). Applying
    inputs a few ticks late locally (rollback avoidance) is 6f.
  - Interpolation delay (`InterpolationTicks` 0): starts at two snapshots; each second the view runs past the
    newest news of something moving it goes half a snapshot further back (at most six snapshots); every three calm
    seconds it comes a quarter of the way back to a snapshot and a tick. Eased, so nothing jumps. Losses alone do
    not move it (a first version did, and sat near the maximum under steady loss).
  - Snapshot budget (`SnapshotBytesPerSecond` 0): clients count snapshots missing from the ticks they receive
    and say so once a second (`MsgLink`, 3 bytes); at 3% lost or more the server cuts that client's budget to
    three quarters of what it was getting (never below 16 KB/s, as a loss is as often bad luck as too much sent),
    calm seconds grow it back, and well above what is needed it goes.
  - The panel shows each client's losses and budget, and on a client its losses, view delay and controls waiting.
  - Checked by `~/TallowEcsTests/NetworkTuning` (new): calm, the view comes from 6 ticks to 4; at 20% simulated
    loss each way (38% of snapshots) it goes to 8.8 and the server sets a 16,000 bytes a second budget; calm
    again, the budget goes and the view returns to 4; the movers keep arriving. Network: lag compensation finds
    the target 0.30 behind instead of 0.40, as others are shown nearer the present; movement stays even.
- [x] **6b EXIT MET** (2026-11-05). `~/TallowEcsTests/exit6b.sh <engine> <work>` makes a project with
  `TallowLauncher --create --sample`, builds it (no warnings), hosts it and joins it over loopback with bots
  driving both players, and prints each machine's panel (`--net-describe N`, new; also in development builds).
  Nothing networking is set by hand; the sample's scripts have no networking code left: the camera script
  asks `IsMine` (new on every component: this machine is in charge of the object), and CharacterAnimation picks
  its clip from how far the object moved, so it works for a Character Controller, a Rigidbody or a network-moved
  player alike (it read a Rigidbody the sample player does not have, so it never animated). Loopback: 2,666
  bytes a second to the client (each resting crate 54), no rollbacks, no waits for news, 6 crates predicted
  without error. With `--lag 40 --jitter 10 --loss 2`: one correction of 0.038 while the controls depth rose
  from 1.5 to 3, then calm; 4,040 bytes a second. Gallery self-test still ready (rooms=8 probes=2).

## Benchmark results

See "Phase 1 results" above.

### Against the engine before the ECS (2026-11-05, after ParticleSystem)

EcsBench `gameobject` mode (one GameObject per cube, a MeshRenderer and a Mover script each), Release, three
interleaved runs per side: 08125074 (Phase 1, which only added Flecs beside the old engine) against `ecs` with
everything above converted.

| Cubes | Measure | Before | Now | Change |
|---|---|---|---|---|
| 10,000 | frame | 1.76 ms | 1.64 ms | 7% faster |
| 10,000 | frame p99 | 1.98 ms | 1.75 ms | 12% faster |
| 10,000 | script Update | 0.37 ms | 0.44 ms | 17% slower |
| 10,000 | spawn | 11.9 ms | 8.1 ms | 32% faster |
| 100,000 | frame | 34.3 ms | 20.0 ms | 42% faster |
| 100,000 | frame p99 | 36.6 ms | 20.9 ms | 43% faster |
| 100,000 | script Update | 3.55 ms | 4.22 ms | 19% slower |
| 100,000 | spawn | 118 ms | 73 ms | 38% faster |
| 100,000 | memory | 206 MB | 186 MB | 10% less |

The frame gain is the render path reading MeshRenderer data from one query. Script Update is slower: each
Mover's Transform reads and writes go through the entity now. To look at with the Profiler (Phase 7).
