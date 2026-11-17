# Advanced systems and ordinary scripts

Start with a `Script`. Tallow registers callbacks, stores built-in component data in Flecs and batches compatible
rendering automatically. An ordinary moving object needs no query, job configuration or manual cleanup:

```csharp
public class Spinner : Script
{
    public Vector3 Speed = new(0, 45, 0);

    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Rotate(Speed * deltaTime);
    }
}
```

Without a Network Identity this runs once per frame. With a Network Identity, the simulation path supplies tick
inputs and the fixed delta, including during prediction replay. Use those arguments for simulation. Presentation
work such as a local camera or GUI belongs in `LocalUpdate`, `LocalLateUpdate` or `OnGUI` instead. Keep direct
input reads (`Input`), frame time and unseeded randomness out of predicted updates: they differ between machines and
between a tick and its replay.

## Mixed script and ECS data

A GameObject is already an ECS entity; these are not separate authoring modes.
You can put a normal script and an ECS data component on the same object:

```csharp
[Component]
public struct SpeedData
{
    [Sync] public float Speed;
}

public class Accelerate : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        EcsEntity entity = GameObject.Entity;
        if (entity.TryGet(out SpeedData data))
        {
            data.Speed += deltaTime;
            entity.Set(data);
        }
    }
}
```

The same `SpeedData` is read by `Scene.Query<SpeedData>()`, and `EcsEntity.GameObject` is the object an entity
belongs to (null for a bare entity). With a `NetworkIdentity` on the GameObject, `[Sync]` fields of the struct
take part in Tallow's networking like a script's. Bare entities (`Scene.CreateLocalEcsEntity()`, no GameObject)
whose `[Component]` struct has `[Sync]` fields are replicated by the server: they stay packed in Flecs and get no
hidden GameObjects; unmarked data stays local. See `docs/unified-ecs-networking.md` for how that works inside the
engine.

**Visual scripting:** after compiling a project `[Component] struct`, open a graph and search the **ECS** category
for its component and field nodes. **For Each** creates one query iteration for all matching objects; its Body flow
exposes the current object and the data's fields. Add and Remove inside that loop are deferred until the loop
exits. Compiled graphs use the same component storage and network behaviour as scripts.

## When a query helps

Use a query when profiling identifies a large homogeneous workload. The Gallery courtyard has two small crowds:
blue members run a script's `Update`; orange members are moved by one query over their data. Both evaluate the same
motion. The example makes the alternative visible; it is not a performance claim for that small scene.
`Samples/CSharpBench` measures larger script and query workloads.

Data components are `unmanaged` structs marked `[Component]`: values and entity ids, no strings or objects.

```csharp
Scene.Query<SpeedData, Charge>().ForEach((EcsEntity entity, ref SpeedData speed, ref Charge charge) =>
{
    speed.Speed += charge.Amount * 0.1f;     // changed rows are written back after the loop
});
int count = Scene.Query<SpeedData>().Without<Frozen>().Count;
```

`ForEach` copies the data out in pages and writes back the rows the action changed, so it costs a few calls per
thousand entities, not one per entity. Entities may be created and destroyed inside it, and data added or removed;
an entity that has gone (or lost a component) by the end is not written back, and entities made during it are
visited next time.

For per-tick simulation of bare entities, derive from `EcsSystem<T>` (or `EcsSystem<T1, T2>`,
`EcsSystem<T1, T2, T3>`): the build finds the class, and the engine runs its `Update(entity, ref data, input,
deltaTime)` every fixed tick, on the server and predicted on the client that owns the entity
(`EcsEntity.SetOwner`). Its Update must depend only on the entity it is given, the controls and the delta time.

## Ordering and parallel work

Ordinary scripts run on the main thread in registration order. Query order can change when components are added or
removed. Do not use that order for shared gameplay state, event ordering, spawning or random draws. Where ordering
matters, gather operations and apply them by a stable identity in an explicitly chosen sequence.

The engine must only be used from the game thread. For heavy work that does not touch the engine (path planning on
your own data, procedural generation), use .NET's own `Parallel.For` or `Task.Run` on plain arrays, then apply the
results on the game thread (an `await` returns there). A floating-point reduction across threads is not
automatically deterministic: keep parallel results out of predicted gameplay unless each output depends only on its
own input.

## Timed sequences

`await` runs on the game thread: `await Wait(2f)` waits two seconds of game time and `await NextFrame()` one frame,
and code after the await may use the engine. Waits end when the script is destroyed; pass `Destroyed` to other async
calls. An await is not network state: a predicted update that must survive corrections keeps its progress in
`[Sync]` fields (a stage number and a time left), not in a suspended method.

## Measuring improvements

Use Release builds on the same hardware. `tools/run_csharp_bench.py` runs the C# and Beef copies of the same
workloads and keeps each run. Compare full-frame cost separately from script-update cost; other active workloads
can dominate small differences. Re-run the deterministic state and event checks after changing dispatch or access
paths, and keep the network correction and replay counters when comparing prediction.
