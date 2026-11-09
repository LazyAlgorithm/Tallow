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
- [x] **Real multiplayer acceptance** (2026-11-09). Live edits:
  `~/TallowEcsTests/NetworkLiveEdit/run.py <engine root> <work folder>` (20
  checks). One Debug program runs as three processes over loopback: a
  dedicated server and a client that apply each script library (two editors
  on the same project, the client a second later), and a client that never
  does (a built game). The game code is edited on disk, the library built
  with `tools/reload_scripts.py` (3 to 4.4 s each), and the values checked on
  every process:
  1. A method edit in a script and in a `[NativeSystem]` class: the new
     values reach every client.
  2. A visual graph's constant, through the graph compiler: it reaches every
     client.
  3. A new `[Sync]` field on a script (structural): it counts up on the
     server and reaches the other editor. The built game warns and keeps its
     last values; it still gets the bare entities.
  4. A networked graph variable added (structural): likewise.
  5. A field added to a `[Component]` struct: refused on both editors, and the
     session carries on.

  Two engine changes came out of it. A native system can be a class, made
  again after a structural reload (a delegate from `AddNativeSystem` kept
  its old code). And objects' `[Sync]` fields are not applied while the
  declarations differ (before, the built game wrote another field's bytes
  into `mode` and `version`). See *Editing while playing*.
  Separate processes, done (2026-11-09,
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
- [x] **Prediction acceptance** (2026-11-09, `~/TallowEcsTests/NetworkPredictQuery`,
  run with `crossbuild.sh` then `crossrun_predict.sh`). A predicted player
  moves by its controls, written three ways. In each case a Linux server, a
  Linux client and a Windows client run in their own processes: 8 s at 40 ms
  lag, then 10 s with 5% of packets lost as well, then stop and compare
  positions with the server.

  | Movement | Corrections, 40 ms | With 5% loss | Stopped |
  |---|---|---|---|
  | Script moving its own Transform | 0 | 0 | exactly the server's |
  | Query in `TickPipeline` only | 160 (every snapshot) | 200 | exactly the server's |
  | The same query also in `ReplayPipeline` | 0 | 0 | exactly the server's |

  Linux and Windows clients gave the same numbers. A query is not
  prediction-aware by itself: a correction replays the scripts' `Update` but
  not the query, so the replayed ticks lose their movement and the next
  snapshot corrects again. Add the same step to `Scene.ReplayPipeline` (after
  `Replay.Update`, in `.PreUpdate`) and have it move only what this machine
  runs (everything on the server, `IsOwner` objects on a client); see
  *Queries and prediction*. Bare entities use native systems instead, which
  are replayed for their owner.
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
- [x] **Native ECS prediction and relevance** (2026-11-09): each client has
  its own stream and the server knows what each holds (`NativeView`). A
  `[SyncPosition]` Vector3 field makes an entity *spatial*: it goes only to
  clients whose player is within `SnapshotRelevanceRadius`, and leaves past
  `RelevanceHysteresis` times that. Native systems (`AddNativeSystem<T>`) are
  the fixed-tick scheduling contract. `NativeSetOwner` maps an entity to a
  client's controls; the owner predicts it, notes its synced state after every
  tick, and on each snapshot's ack takes the server's state and runs its
  controls again where they differ (see *Native systems and prediction*).
  `~/TallowEcsTests/NetworkNativePredict` passes 33 checks, and the
  cross-process test has each of four Linux and Windows clients fly a ship.
  Over 5 s of steady flight there were **0 corrections**, and each stopped ship
  matched the server bit for bit.
- [x] **Performance acceptance** (2026-11-09, Release, Linux, interleaved
  A/B against the `ecs` branch at 14b97ac0; see *Performance* for the
  tables). Ordinary scripts, mixed objects and ECS systems at
  1k/10k/50k/100k (`tools/run_ecs_bench.py`, 3 runs each, the noisiest row
  repeated with 6) and the headless script paths (`--profile-scripts`) are
  within run-to-run noise of the `ecs` branch. Networked GameObjects send the
  same bytes and cost the same (`~/TallowEcsTests/NetworkObjectsPerf`).
  Bare entities under relevance (`~/TallowEcsTests/NetworkNativePerf`, 1k to
  100k, a server and two clients, each holding a fifth) cost the server under
  1 ms per snapshot and stay exact once still. Two fixes came out of it: a
  change no client holds no longer spends the byte budget (2.5 times the
  updates per client when everything moves), and each entity's types and
  data are found through cached Flecs references while its table is
  unchanged (a quarter off the send time).

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
- Each client has its own stream of records, and the server keeps the set of
  entities it holds. A change goes to the clients holding the entity. A client
  that joins late is told the type table at once, then sent the entities
  already there over the following snapshots, `NativeJoinBytesPerSnapshot`
  (32 KB) at a time, with the state every other client holds.
- **Relevance**: an entity with a `[SyncPosition]` Vector3 field (which is
  synced like `[Sync]`) goes only to clients whose player is within
  `SnapshotRelevanceRadius`. It is deleted on a client once it is further than
  `RelevanceHysteresis` times that, and sent whole again when it comes back,
  with whatever changed meanwhile. Its owner always holds it. Entities without
  the field, and every entity when the radius is 0 or the client has no
  player yet, go to everyone. As with Nearby GameObjects, an entity is found
  leaving or coming back when it is compared, in its turn (within a snapshot
  or a few for up to 16,384 entities). Unlike a GameObject, which is hidden, a
  bare entity is deleted on the client, local-only data with it.
  `NativeHeldBy(clientId)`, `NativeIsHeldBy(entity, clientId)`, `NativeEntered`
  and `NativeLeft` tell the server what clients hold.
- A change to an entity no client holds (none is near it) costs nothing of
  the budget, so when much is moving the bandwidth goes to what clients see.
  `NativePassSnapshots` is how many snapshots the last full pass of the round
  robin took: the longest a change can wait. `NativeCaughtUp` is true when
  nothing is waiting and that pass found nothing new, so every client holds
  exactly what the server has in its area (for tests and tools).
- Everything is reliable and in order; deletes go with the next snapshot.
- Host migration: the new host takes the replicas it holds as its own
  entities, under the same network ids and owners (its own become the
  server's), and sends them whole to everyone; clients that come back drop
  their replicas first.
- After a script reload the server describes the types again and sends every
  entity whole.

`NetworkManager.Describe` (Window > Network) has a NATIVE ECS line. On the
server it shows entities, how many are owned by clients, how many wait to be
sent, the records and bytes sent, and entities that came into or left a
client's area, how long a pass over them takes, and whether clients have
caught up. On a client it shows replicas, bytes, how many are predicted,
and corrections. Both show the time spent putting snapshots together (server)
or reading them (client), also `NativeSendMilliseconds` and
`NativeReadMilliseconds`, and in the Profiler as *Native ECS Send* and
*Native ECS Read*. `NativeEntityCount`, `NativeWaiting` and `NativeBytes` give
the same in code.

### Native systems and prediction

A native system advances one bare entity's data by one tick. Write it as a
class marked `[NativeSystem]`: the engine finds it, makes one and runs it on
every machine, and editing it while the game plays takes effect like a
script's `Update` (see *Editing while playing*):

```beef
[Component]
struct ShipMotion
{
    [SyncPosition] public Vector3 position;
    [Sync] public int32 jumps;
}

[NativeSystem]
class ShipSystem : NativeSystem<ShipMotion>
{
    public override void Update(Entity entity, ref ShipMotion ship, TickInput input, float deltaTime)
    {
        ship.position += Vector3(input.Move.x, 0, input.Move.y) * 8 * deltaTime;
        if (input.Pressed(.Jump))
            ship.jumps++;
    }
}

// Server: this client's controls fly it, and it predicts it.
Scene.Network.NativeSetOwner(ship, clientId);
```

A system can also be registered once with a delegate, on every machine in the
same order, like a prefab:
`NetworkManager.AddNativeSystem<ShipMotion>("Ship", new (entity, ship, input,
deltaTime) => { ... })`. That keeps the code it was made with until the
program restarts: a script reload does not change it.

Every tick, before scripts' `Update`, the systems run: those added with
`AddNativeSystem` in the order added, then the classes by
`[NativeSystem(order)]` and full name:

- with no session, on every bare entity with the data (not GameObjects), with
  this machine's controls;
- on the server, on its own bare entities (with the host's controls on a host,
  none on a dedicated server), and on each entity a client owns with that
  client's controls as they are run (the tick its NetworkScripts run);
- on a client, only on the replicas it owns, at once, with its own controls.
  It notes their synced data after each tick. With each snapshot the server
  sends its state of them and the last tick of the client's controls it has
  run (an *ack* record). Where that differs from what the client noted for the
  same tick, the client takes the server's state and runs its controls since
  then again for those entities only (`NativeCorrections`,
  `NativeReplayedTicks`). Owned entities are compared every snapshot, outside
  the round robin, so each ack has their state.

The contract (what makes the replay right):

- A system may depend only on the entity it is given: its data, the controls
  and the delta time. Not other entities, wall-clock time or `Input`. The order
  entities are run in is not fixed.
- Only `[Sync]` fields are put right by the server and run again; the others
  stay each machine's own.
- Add, Remove and Delete inside a system are deferred to the end of the run.
  `CreateMany` cannot be called there.
- A client runs no system on the server's entities. Those are shown as the
  server last sent them, without interpolation yet. Lockstep sessions do not
  run native systems.
- When a client's controls arrive after the server has run their tick, the
  server carries on with the last ones it had, and the owner is corrected (as
  for GameObjects). In one process every scene shares `Time.TickScale`, so
  clients cannot run ahead of the server and such corrections are normal
  there (7 in 300 ticks at 30 ms in `NetworkNativePredict`). In separate
  processes there were none.

Still not supported: clients creating the same authoritative bare entities
themselves (they would be duplicates), interpolation of other clients'
entities, and changes as unreliable snapshot deltas (they go reliably).

Native entity replication uses reserved engine message ID **237**. GameObject
ECS component layout uses **236**. Both IDs are distinct from anti-cheat
(**243**) and map-sharing (**242**); engine-reserved message IDs are
**236–255**.

### Editing while playing

In the editor, scripts are reloaded while a session plays (Linux and Windows
Debug, [script hot reload](script-hot-reload.md)). In a session:

- A method body (a script's `Update`, a `[NativeSystem]` class, a graph
  compiled again) takes effect on the machine that reloaded. What it does to
  synced data reaches every client, including built games running the old
  code.
- A new or changed `[Sync]` field on a script, or a graph variable made
  networked, changes the list of fields on that machine only. GameObject
  fields go by index, so the machines must agree. Each machine notes a hash of
  its `[Sync]` declarations (`NetworkSync.SyncSchema`). One that changes it
  during a session tells the other side: the server tells every client, a
  client tells the server. A client applies objects' `[Sync]` fields only
  while its hash is the server's. Otherwise it keeps the last values and logs
  a warning. When the two agree again (the other editor reloaded the same
  change, or the game is restarted with it), the server sends that client
  every field afresh. Nothing extra is sent in a session where no machine
  reloads. Bare entities are matched by type and field name, so they carry
  on regardless: unknown fields are skipped, and missing ones keep their
  values.
- A change to a `[Component]` struct's layout (a field added, removed or
  retyped) is refused while playing ("Full rebuild required"). The session
  goes on with the code it has; stop, rebuild and play again.

So for multiplayer testing, run each player as an editor on the same project
(each reloads what is saved) or restart built games after a change to `[Sync]`
fields.

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

## Queries and prediction

A query that moves predicted GameObjects must run in replays as well as
ticks:

```beef
// The script stores its controls (data.move = input.Move); the query moves by them.
void MovePilots(Scene scene)
{
    let network = scene.Network;
    for (var chunk in scene.World.ObjectsWith<PilotData>())
    {
        let pilots = chunk.Read<PilotData>();
        let links = chunk.Read<ObjectLink>();
        for (int i < chunk.Count)
        {
            let pilot = links[i].gameObject;
            if (network != null && !network.IsServer && !pilot.GetComponent<NetworkIdentity>().IsOwner)
                continue;
            pilot.Transform.Position += Vector3(pilots[i].move.x, 0, pilots[i].move.y) * pilots[i].speed * Time.FixedDeltaTime;
        }
    }
}

scene.World.AddStep(scene.TickPipeline, "Game.MovePilots", .OnUpdate, new () => MovePilots(scene));
scene.World.AddStep(scene.ReplayPipeline, "Game.MovePilots", .PreUpdate, new () => MovePilots(scene));
```

Only the Transform, bodies and controllers are rewound for a replay. ECS data
the query reads, such as `move` above, must be set again by the replayed
`Update`, or be derived from rewound state.

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

## Performance

Release, Linux, one machine (2026-11-09). Each comparison interleaves the two
builds and takes the median of the runs.

Scene update against the `ecs` branch (`run_ecs_bench.py`, frame average,
3 runs; the ECS 10k row repeated with 6, which gave +0.3%):

| Objects | GameObject | Mixed | ECS |
| --- | --- | --- | --- |
| 1,000 | -4.6% | +5.8% | +4.3% |
| 10,000 | -0.8% | -2.8% | +0.3% |
| 50,000 | -0.5% | +0.4% | +1.6% |
| 100,000 | -1.7% | +0.7% | +0.6% |

The 1k rows take a quarter of a millisecond, where a few microseconds of
scheduling show as several percent either way. The headless script paths
(`--profile-scripts`: scene and dispatch loops, transform reads and writes,
GetComponent, movers) are within ±5% at every count, mostly within ±2%. The
unified data paths, new rows there, per object per tick: a script's
`GetComponent<T>()` on a `[Component]` struct and a write, 6 to 7 ns; an
`ObjectsWith<T>` query writing it, 1.1 ns; the same query reading the struct
and its object's Transform, 2.7 ns at 1k and 7.3 ns at 100k.

Networked GameObjects (`NetworkObjectsPerf`: a dedicated server and two
clients in one process, unpaced; Nearby, radius 252 m over a 1 km square;
a moving object also changes a `[Sync]` field of its script every tick):

| Objects | Moving | Server tick, `ecs` / unified | Client tick | Bytes |
| --- | --- | --- | --- | --- |
| 1,000 | 10% | 0.348 / 0.341 ms | 0.225 / 0.231 ms | identical |
| 1,000 | 100% | 0.522 / 0.517 ms | 0.337 / 0.341 ms | identical |
| 10,000 | 10% | 5.51 / 5.52 ms | 3.92 / 3.81 ms | identical |
| 10,000 | 100% | 7.87 / 7.69 ms | 4.97 / 5.04 ms | identical |

Bare entities (`NetworkNativePerf`: the same layout, each entity a
`Particle` with a `[SyncPosition]` and a `[Sync]` Vector3, moved by a native
system; each client holds about a fifth). Send is per snapshot (every 3
ticks); the pass is the longest a change can wait:

| Entities | Moving | Server tick (p99) | Send | Client tick | Read | Per client | Pass |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1,000 | 100% | 0.10 (0.33) ms | 0.10 ms | 0.05 ms | 0.01 ms | 76 KB/s | 1 |
| 10,000 | 10% | 0.28 (0.76) ms | 0.61 ms | 0.05 ms | 0.01 ms | 101 KB/s | 1 |
| 10,000 | 100% | 0.38 (1.1) ms | 0.41 ms | 0.14 ms | 0.04 ms | 330 KB/s | 3 |
| 50,000 | 10% | 0.55 (1.4) ms | 0.96 ms | 0.08 ms | 0.02 ms | 122 KB/s | 4 |
| 50,000 | 100% | 0.48 (1.4) ms | 0.38 ms | 0.16 ms | 0.04 ms | 325 KB/s | 12 |
| 100,000 | 10% | 0.68 (1.7) ms | 0.98 ms | 0.09 ms | 0.03 ms | 129 KB/s | 7 |
| 100,000 | 100% | 0.59 (1.7) ms | 0.35 ms | 0.15 ms | 0.03 ms | 316 KB/s | 31 |

With 10% moving the send is bound by the scan (16,384 compared per snapshot,
about 60 ns each); with everything moving, by the byte budget, so at 100,000
a moving entity is updated about every 1.5 s. Raise
`NativeBytesPerSnapshot` for more, at the cost of bandwidth. Initial delivery
of 100,000 (20,000 to each client) took 274 ticks at the default budgets.
After everything stopped, every replica matched the server exactly at every
size, and each client held what was within the radius (and nothing beyond
the hysteresis).

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
   loopback; `--bulk N` sets the big spawn, 10,000 by default),
   `nettest.sh <engine root> NetworkNativePredict <out dir>` (relevance,
   native systems, ownership and prediction under lag and loss) and
   `nettest.sh <engine root> HostMigrationNative <out dir>`.
6. **Do not** create the same authoritative bare entities independently on
   both machines: client-side creation suppression or deterministic matching
   is still pending and doing so makes duplicates.
7. Separate processes and platforms: `~/TallowEcsTests/crossbuild.sh <engine
   root> NetworkUnifiedCross <out dir>` (needs `tools/windows/setup.sh` and the
   engine's `build/native-win`), then `crossrun_unified.sh <out dir>`.
8. Performance (Release): `tools/run_ecs_bench.py --counts 1000 10000 50000
   100000 --modes gameobject mixed ecs --runs 3 --baseline-executable <ecs
   branch EcsBench>`; `EcsBench --profile-scripts <count>` from both builds,
   interleaved; `CONFIG=Release nettest.sh <engine root> NetworkNativePerf
   <out dir>`, then its program with `<count> <moving percent> [radius]`;
   `NetworkObjectsPerf` built against both engines with `<count> <moving
   percent>`, interleaved.
9. Editing while playing: `python3 ~/TallowEcsTests/NetworkLiveEdit/run.py
   <engine root> <work folder>` (builds the program and the graph generator
   in the work folder, Linux Debug).

## Design decision for later pure ECS networking

Do not silently allocate a GameObject per raw ECS entity merely to replicate
it; that would erase the benefits of `CreateMany`. The experimental native
replication path deliberately uses direct network IDs and packed Flecs data.
The next milestone is deterministic script/query scheduling, relevance,
prediction history and rollback semantics, with a compatible low-overhead
serializer for both object-backed and pure ECS data.
