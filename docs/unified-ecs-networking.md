# Unified ECS, scripting, visual graphs and networking

Working branch: `ecs-unified-authoring-network` (based on `ecs`).

## Contract

One object, one Flecs entity, one Inspector/prefab/scene identity. A user may attach
`[Component] class MyBehaviour : Script`, `[Component] struct MyData`, and
`NetworkIdentity` to that **same** object. The script, the Inspector, visual
scripts, and ECS queries must read and write the **same** stored data.
`Update(TickInput input, float deltaTime)` remains unchanged. Ordinary authors
do not need a second workflow. Power users may explicitly query ECS data.

## Implementation status

- [x] **Existing foundation**: GameObjects own `Entity` IDs; class scripts and
  `[Component]` structs already coexist on that entity. Scene files, prefabs,
  and Inspector support custom data components.
- [x] Extend `NetworkSync` to include fields marked `[Sync]` on custom ECS
  data structs attached to a networked GameObject. Re-resolve field addresses
  by component index and byte offset, so Flecs archetype moves do not leave
  stale network pointers.
- [x] Keep field index ordering stable across machines: scripts first, built-in
  component handles next, then custom ECS types by full name and field name.
  Add the custom data layout to network slot cache invalidation.
- [x] Reliably mirror the presence/absence of synchronized custom ECS component
  types before sending their indexed fields. Send layout to late joiners and
  clients returning to interest range. Local-only (non-[Sync]) ECS components
  are not removed on receipt.
- [x] Add reflected visual scripting nodes for custom ECS component
  Has/Add/Remove and supported primitive field Get/Set, operating on the same
  GameObject/Entity as code scripts.
- [x] Add ECS *For Each* visual flow with per-row object and directly
  referenced packed field outputs; cache the underlying query per World.
  Structural changes during the graph loop are deferred until it exits.
- [x] Add mixed script/ECS/network slot and archetype-move regression checks
  in EcsBench.
- [x] **Local verification** (2026-11-09): the engine, the launcher and
  EcsBench build in Debug and Release with no errors or new warnings; EcsBench
  check mode passes in both; `src/Graphs/EcsSyncedMotionGraph.tgraph` compiles
  through the editor (`--graph <absolute path> --compile-graph`) and the
  project builds with the generated script; NetworkEcs gives the same 82 PASS
  as `ecs` and NetworkBytesEcs sends byte-identical data. Two bugs this found
  are fixed: `NetworkManager.~this` crashed in `NativeStop` (Beef destroys an
  extension's fields before the class's own destructor body, so the native
  state now hangs off one field of the main class), and Flecs left the data
  components it adds uninitialised (Tallow registered them without a
  constructor; every component now gets a zeroing one, as `World.Ensure`,
  `Add` and `CreateMany` document).
- [ ] **Real multiplayer acceptance**: separate processes done; editing
  scripts and visual graphs during play is still to do. Done (2026-11-09,
  `~/TallowEcsTests/NetworkUnifiedCross`, run with `crossrun_unified.sh`): a
  Linux dedicated server and four clients in their own processes, two Linux and
  two Windows builds (cross-compiled, run under Wine), 40 ms simulated lag.
  Two join at the start, two about 10 s in (late join), and one Windows client
  leaves after the third phase and comes back in a new scene. Checked at each
  phase on every client: networked GameObjects with a `[Component]` struct with
  `[Sync]` fields and a script (spawn, despawn, field changes, a second synced
  struct added to and removed from some of them, one leaving every client's
  area and its changes while away showing when it returns, through
  `relevance = .Nearby`), and bare entities (made, changed, deleted, more made
  later). 35 checks pass, run twice. Not covered yet: live script and
  visual-graph edits while playing, and separate machines.
- [ ] **Prediction acceptance**: compare state hashes and correction frequency
  for normal-script vs query-based movement under packet delay, loss and
  rollback. Arbitrary query systems are not automatically prediction-aware.
- [x] **Native entity replication**: `World.CreateMany<T>`, `Set<T>`,
  `Ensure<T>` and `Add<T>` enrol GameObject-free entities when a game-defined
  `[Component]` struct has supported `[Sync]` fields; server-assigned network
  ids, creation, deletion, presence of synced types, client replicas, session
  cleanup, late joiners and host migration, with no GameObject allocated.
- [x] **Native ECS networking acceptance** (in one process, over loopback,
  2026-11-09): `~/TallowEcsTests/NetworkNativeEcs` (39 checks: values and
  `SharedString` text, fields without `[Sync]` left alone, writes through
  `Get<T>` found, local-only data on replicas kept, synced types added and
  removed, archetype moves, `World.Delete` and removing the last synced type,
  recreating, client-made entities staying local, late join with changes and a
  delete during the join, 10,000 at once while older ones change, a change to
  all 10,000, a late joiner given 10,037 over 18 snapshots, 5,000 deletes at
  once, leaving, a new session, deleting the NetworkManager) and
  `~/TallowEcsTests/HostMigrationNative` (17 checks, the host leaves with 20
  bare entities). The protocol was reworked for it (see *Bare Flecs entities*):
  types described once, fields by bit mask, a per-snapshot byte budget shared
  fairly between new entities and changes, and late joiners paced over
  snapshots with the baseline every other client holds.
- [ ] **Native ECS prediction and relevance**: the implementation is
  server-authoritative state replication, not client-authoritative movement,
  rollback or interest-filtered spatial streaming. Add a deterministic
  fixed-tick query scheduling contract, entity input/owner mapping, prediction
  history and reconciliation. Relevance needs a well-defined spatial component
  and a per-client last-delivered baseline. Do not claim that a pure ECS query
  automatically predicts like a GameObject NetworkBehaviour yet.
- [ ] **Performance acceptance**: profile 1k/10k/50k/100k ordinary scripts,
  batched visual loops, mixed ECS objects, snapshot/field serialization and
  net bandwidth under realistic relevance filtering; optimize allocations
  and structural cache checks without breaking synchronization.

## Supported now on networked scene GameObjects

```beef
[Component]
struct ProjectileMotion
{
    [Sync] public Vector3 velocity;
    [Sync] public float age;
    public int32 localTrailIndex; // intentionally not networked
}

[Component]
class ProjectileRules : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        let motion = GetComponent<ProjectileMotion>();
        if (motion == null)
            return;
        motion.age += deltaTime;
        Transform.Position += motion.velocity * deltaTime;
    }
}
```

Give the prefab a `NetworkIdentity`; attach both components to its object.
A compatible scene client receives changed `[Sync]` data and the synchronized
data component's existence. The `localTrailIndex` field remains local.

Normal code can also use `Scene.World.ObjectsWith<ProjectileMotion>()` to
iterate cached packed `ProjectileMotion` and `ObjectLink` columns. That query
includes scene GameObjects, **not** raw entity-only objects.

## Bare Flecs entities (experimental on the unified branch)

A game-defined `[Component]` struct with supported `[Sync]` fields is the
opt-in signal. While a session runs, the server registers bare entities
created or given such data with `World.CreateMany<T>`, `World.Set<T>`,
`World.Add<T>` or `World.Ensure<T>`, and those made before the session
started. No `NetworkIdentity`, GameObject wrapper or registration call is
needed:

```beef
[Component]
struct BulletMotion
{
    [Sync] public Vector3 position;
    [Sync] public Vector3 velocity;
    public int32 localEffectIndex; // not sent
}

// Run on the authoritative server:
let bullets = scope List<Entity>();
Scene.World.CreateMany<BulletMotion>(32, bullets);
for (let entity in bullets)
    Scene.World.Set<BulletMotion>(entity, .() { position = .(0, 2, 0), velocity = .(0, 0, 5) });
```

Clients get entities of their own with the same data (a network id is not a
Flecs `Entity`), and query them like any other: `Query<BulletMotion>` finds
them, without an `ObjectLink`. `NetworkManager.NativeNetId(entity)` gives a
bare entity's network id on either side and `NativeEntity(netId)` the entity
for one, for game messages about it.

What is sent:

- The `[Sync]` fields of every synced type the entity has, matched by field
  name: a field the client's type lacks, or has with another size, is skipped,
  but server and client should run the same build. Supported: the kinds
  `NetworkSync.SizeOf` sizes (numbers, bools, enums, chars, vectors,
  quaternions, colours, matrices) and `SharedString` text up to 1024 bytes.
  `ObjectRef` and other reference fields are not sent. Fields without `[Sync]`
  stay each machine's own, and so does data of types without `[Sync]` fields,
  which replication never adds or removes.
- Presence: a synced type added or removed on the server is added or removed
  on clients. Removing the last one, or `World.Delete`, deletes the client's
  entity; so does an entity deleted any other way (found by the scan below).
- Each type is described once per session (its name, field names and sizes)
  and then named by a small wire id. A new entity, or one whose set of synced
  types changed, goes whole; after that only the fields that changed go, with
  a bit per field. Measured on loopback (Debug): 29 bytes per new
  `BulletMotion`, 18 per change of one field.

When it is sent (server, with each snapshot, every `SnapshotInterval` ticks):

- Up to `NativeBytesPerSnapshot` bytes (32 KB) of new entities and changes.
  Changes are found by comparing up to `NativeScanPerSnapshot` entities
  (16,384) with what was last sent, round robin; new entities go oldest
  first. Each kind gets at least half of the budget while the other is
  waiting, so a big spawn does not hold up changes to entities that were
  there before, and what does not fit goes first in the next snapshot. 10,000
  made at once reach two clients in 27 ticks while a change to an older one
  takes 3 (the first implementation: 60 ticks, about 80 bytes each).
- A client that joins late is told the type table at once, then sent the
  entities already there over the following snapshots,
  `NativeJoinBytesPerSnapshot` (32 KB) at a time. It is sent the state every
  other client holds (not a newer one) and reads past changes to entities it
  has not been sent yet; those come whole later.
- Everything is reliable and in order; deletes go with the next snapshot, in
  batches.
- Host migration: the new host takes the replicas it holds as its own
  entities, under the same network ids, and sends them whole to everyone;
  clients that come back drop their replicas first.
- After a script reload the server describes the types again and sends every
  entity whole.

`NetworkManager.Describe` (Window > Network) has a NATIVE ECS line: entities,
how many wait to be sent, clients catching up, and the records and bytes
sent. `NativeEntityCount`, `NativeWaiting` and `NativeBytes` give the same in
code.

**Not yet equivalent to fully network-predicted ECS**: clients must not
independently run authoritative query movement on replicas and assume
rollback will reconcile it, and must not create the same authoritative bare
entities themselves (they would be duplicates). Every client is sent every
entity: there is no relevance filtering yet, and changes go reliably, not as
unreliable snapshot deltas.

Native entity replication uses reserved engine message ID **237**. GameObject
ECS component layout uses **236**. Both IDs are distinct from anti-cheat
(**243**) and map-sharing (**242**); engine-reserved message IDs are
**236–255**.

## Visual scripting

Once the project has compiled the `[Component] struct`, the Graph node palette
has **ECS** nodes for that type: `Has Component`, `Add Component`,
`Remove Component`, per-field `Get` and `Set`, and **For Each**.
The **For Each** Body flow receives the current `GameObject` plus direct packed
data-field outputs; its Done output continues after the query. Attach the
resulting graph script to an ordinary GameObject, with or without other scripts.
When authoritative network behavior matters, run it through the same
network-tick rules as normal scripts; do not read untracked `Input` or
wall-clock time during prediction.

## Compatibility and constraints

- The ECS layout message uses engine network message ID **236**. Server and
  client should run the same game/engine build; mixed protocol versions are
  not supported. Current message format caps the synchronized type inventory
  at 64 types per object and uses normal `WriteString` type names.
- `[Sync]` supports the field kinds already handled by `NetworkSync.SizeOf`
  and supported strings; complex collections or arbitrary pointers are not
  automatically replicated. Floats, ints, bools, vectors, matrices and
  supported enums are in that implementation.
- Merely attaching a custom ECS struct does **not** imply an object needs to
  replicate. Use the normal `NetworkIdentity`/network prefab rules, or the
  existing session's `Auto Replicate` for supported built-in moving objects.
- Multiple classes may call `Update` on a GameObject, but a packed ECS query
  isn't automatically safe for network prediction. Queries do not give stable
  iteration order; scripts doing shared writes must impose a stable order.
- Data component structure is synchronized for types with supported `[Sync]`
  fields. Other components (including visual-only data) remain local.

## Test sequence on the developer machine

1. Build Tallow from `ecs-unified-authoring-network` and run the ECS bench
   check mode (`TALLOW_BENCH_MODE=check`, with an absolute `--project` path:
   a relative one makes the file-based checks look in the wrong folder).
2. In the editor, create one GameObject with a normal `Script`, an editable
   `[Component]` struct containing `[Sync] public float speed`, and
   `NetworkIdentity`. Verify script changes appear in Inspector/query and
   persist through save/load and prefab duplication.
3. Build a graph with `ECS: <Struct>: For Each` and use its Object/field
   outputs to update several entities. Run a separate graph using per-field
   Get/Set; verify the same data changes in Beef scripts.
4. Start a server and two clients. Change `speed` on the server; verify the
   second client receives it. Add/remove the custom data during play, join
   late, then move out of interest radius and back in. Verify local-only data
   is unchanged and no stale field index is applied.
5. Bare entities, in one process: `~/TallowEcsTests/nettest.sh <engine root>
   NetworkNativeEcs <out dir>` (a dedicated server and three clients over
   loopback; `--bulk N` sets the big spawn, 10,000 by default) and
   `nettest.sh <engine root> HostMigrationNative <out dir>`.
6. **Do not** create the same authoritative bare entities independently on
   both machines: client-side creation suppression or deterministic matching
   is still pending and doing so makes duplicates.
7. Separate processes and platforms: `~/TallowEcsTests/crossbuild.sh <engine
   root> NetworkUnifiedCross <out dir>` (needs `tools/windows/setup.sh` and the
   engine's `build/native-win`), then `crossrun_unified.sh <out dir>`.
8. Repeat with 1k/10k bare synced entities across separate processes and
   machines, then a typical mixed scene: measure FPS, packet rate, reliable
   bytes, snapshot build/read time, and corrections. Compare with the
   original `ecs` branch under equivalent settings. The native path is not yet
   spatially filtered or predicted.

## Design decision for later pure ECS networking

Do not silently allocate a GameObject per raw ECS entity merely to replicate
it; that would erase the benefits of `CreateMany`. The experimental native
replication path deliberately uses direct network IDs and packed Flecs data.
The next milestone is deterministic script/query scheduling, relevance,
prediction history and rollback semantics, with a compatible low-overhead
serializer for both object-backed and pure ECS data.
