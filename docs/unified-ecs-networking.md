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
- [ ] **Local verification**: compile all touched Beef targets in Release and
  Debug; run EcsBench checks, Editor graph compile tests, NetworkEcs tests.
- [ ] **Real multiplayer acceptance**: Linux server/client and Windows/Linux
  client, spawn/despawn, late join, interest exit/return, add/remove custom
  components during play, script and visual-graph edits, and disconnect/rejoin.
- [ ] **Prediction acceptance**: compare state hashes and correction frequency
  for normal-script vs query-based movement under packet delay, loss and
  rollback. Arbitrary query systems are not automatically prediction-aware.
- [x] **Initial native entity replication implementation (awaiting build and multiplayer validation)**:
  `World.CreateMany<T>`, `Set<T>`, `Ensure<T>` and `Add<T>` enroll
  GameObject-free entities when a game-defined `[Component]` data struct has
  supported `[Sync]` fields. Server-assigned IDs, authoritative creation,
  deletion, type/field-name state serialization, changed-state tracking,
  reliable bounded batches, client replica mapping, session cleanup and late
  join snapshots are now wired in without allocating a GameObject.
- [ ] **Native ECS networking acceptance**: validate builds and full packet
  round-trips, archetype moves, add/remove synced types, delete/recreate,
  server state changed during join, session restart and a large bulk spawn.
  Also address initial baseline fairness and sending late-join state over
  multiple ticks rather than bursting it.
- [ ] **Native ECS prediction and relevance**: the first implementation is
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
opt-in signal. When the network is running, the server automatically registers
bare entities created or populated with `World.CreateMany<T>`,
`World.Set<T>`, `World.Add<T>` or `World.Ensure<T>`. No `NetworkIdentity`,
GameObject wrapper or separate registration call is required:

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

Clients receive replicated bare Flecs entities, with their own local Entity
handles (a network ID is not the Flecs Entity ID). Supported synchronized
fields and synchronized component presence are server-owned. The client can
query the same `BulletMotion` type without an ObjectLink; local-only components
are not automatically removed. Deleting on the server sends a reliable
despawn. Existing server entities are sent to new clients.

**Not yet equivalent to fully network-predicted ECS**: clients must not
independently run authoritative query movement and assume rollback will
reconcile it. The first stage uses reliable changed-state messages, not
snapshot-delta compression or spatial relevance. Changes are examined in
round-robin batches of at most 512 entities per snapshot interval, so very
large native ECS spawns can take multiple intervals to appear remotely.
Late join currently sends the whole native inventory at once. Server and
client must use matching reflected component schemas and game builds.
A native synced type with unsupported or excessively large fields is not
guaranteed to replicate; supported primitive, vector and SharedString fields
are the intended first tests. This feature remains unverified until its Beef
build and a real server/client session pass on the developer machine.

Network diagnostic text now reports native server entities and client replicas
separately from GameObject network identities. Native entity replication uses
reserved engine message ID **237**. GameObject ECS component layout uses
**236**. Both IDs are distinct from anti-cheat (**243**) and map-sharing
(**242**); engine-reserved message IDs are **236–255**.

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
   check mode (`TALLOW_BENCH_MODE=check`). Report any Beef diagnostics with file/line.
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
5. For the new bare-entity path, create 32 `SyncedEcsMotion` entities
   with `World.CreateMany<T>` **on the server**, then use `Set<T>` to change
   their [Sync] fields. In the client's native `Query<SyncedEcsMotion>`,
   verify the 32 replicas have no ObjectLink, values match, and
   `NetworkManager.Describe` reports the expected native replica count.
   Remove/add a synchronized component on the server; delete one entity.
   Verify the matching remote changes without local GameObjects.
6. Test a late-joining client both before and after the server has sent its
   first native snapshot; delete an entity between the join and the next
   snapshot. Also verify client-created local-only data is not replicated.
   **Do not** create the same authoritative raw entities independently on
   both machines: client-side creation suppression/deterministic matching is
   still pending and doing so currently makes duplicates.
7. Repeat with 1k/10k bare synced entities, then a typical mixed scene:
   measure FPS, packet rate, reliable bytes, snapshot build/read time,
   and corrections. Compare with the original `ecs` branch under equivalent
   settings. The native path is not yet spatially filtered or predicted.

## Design decision for later pure ECS networking

Do not silently allocate a GameObject per raw ECS entity merely to replicate
it; that would erase the benefits of `CreateMany`. The experimental native
replication path deliberately uses direct network IDs and packed Flecs data.
The next milestone is deterministic script/query scheduling, relevance,
prediction history and rollback semantics, with a compatible low-overhead
serializer for both object-backed and pure ECS data.
