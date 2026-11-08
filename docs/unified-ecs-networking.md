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
- [ ] **Native entity-only replication**: `World.CreateMany<T>` without a
  GameObject/ObjectLink still has no `NetworkIdentity` adapter, replicated
  spawn/despawn, schema, or prediction history. Build a direct ECS network
  entity registry, per-entity net IDs, authoritative lifecycle, marked data
  replication and reconciliation before claiming *all* native ECS entities
  network exactly like GameObjects. Preserve the packed ECS benchmark path.
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

- The ECS layout message uses engine network message ID **242**. Server and
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
5. Repeat with a typical mixed scene and measure FPS, packet rate, packet
   bytes, snapshot build/read time, and corrections. Compare with the
   original `ecs` branch under equivalent settings.

## Design decision for later pure ECS networking

Do not silently allocate a GameObject per raw ECS entity merely to replicate
it; that would erase the benefits of `CreateMany`. Implement direct net IDs
and lifecycle for entity-only data and use the same snapshot/field serializer
as GameObject-associated entities. Keep predictable script callbacks, entity
spawn ordering, relevancy, history and rollback semantics. Until then, advanced
ECS systems can operate on networked GameObjects via their existing entity
(`ObjectLink`), without a second user-visible entity type.
