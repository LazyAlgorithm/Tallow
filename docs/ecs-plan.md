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

## Benchmark results

To be filled in at the end of Phase 1.

| Objects | GameObject avg / p99 (ms) | ECS 1 thread avg / p99 (ms) | ECS N threads avg / p99 (ms) | Memory before / after |
| --- | --- | --- | --- | --- |
| 1,000 | | | | |
| 10,000 | | | | |
| 50,000 | | | | |
| 100,000 | | | | |
