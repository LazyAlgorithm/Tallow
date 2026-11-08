# Advanced systems and ordinary scripts

Start with a `Script`. Tallow registers callbacks, stores built-in component data in Flecs and batches compatible
rendering automatically. An ordinary moving object needs no query, job configuration or manual cleanup:

```beef
[Component]
class Spinner : Script
{
	public Vector3 speed = .(0, 45, 0);

	public override void Update(TickInput input, float deltaTime)
	{
		Transform.Rotate(speed * deltaTime);
	}
}
```

Without a Network Identity this runs once per frame. With a Network Identity, the simulation path supplies tick
inputs and the fixed delta, including during prediction replay. Use those arguments for simulation. Presentation
work such as a local camera or GUI may use `OnLocalUpdate`, `LateUpdate` or `OnGUI` instead. Direct input reads,
frame time and unseeded randomness in predicted updates receive clickable determinism warnings in the Console.

## Mixed script and ECS data

A GameObject is already an ECS entity; these are not separate authoring modes.
You can put a normal script and an ECS data component on the same object:

```beef
[Component]
struct SpeedData
{
    [Sync] public float speed;
}

[Component]
class Accelerate : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        let speed = GetComponent<SpeedData>();
        if (speed != null)
            speed.speed += deltaTime;
    }
}
```

The same `SpeedData` can be read by `Query<SpeedData, ObjectLink>`. With a
`NetworkIdentity` on the GameObject, supported `[Sync]` fields participate
in Tallow's existing networking. Custom ECS data on bare `World.CreateMany`
entities without an ObjectLink is not automatically networked yet.

You can also borrow `Scene.World.ObjectsWith<SpeedData>()`, a query cached for
the lifetime of the World. Do not delete that query. It returns packed
`SpeedData` and `ObjectLink` columns and excludes standalone entities
without a GameObject.

**Visual scripting:** after compiling a project `[Component] struct`, open a
graph and search the **ECS** category for its component and field nodes.
**For Each** creates one query iteration for all matching objects; its
Body flow exposes the current object and direct packed data-field outputs.
Runtime Add/Remove operations inside that graph loop are deferred until the
loop exits. Generated graphs use the same GameObject component storage and
network behavior as Beef scripts.

## When a query helps

Use a query when profiling identifies a large homogeneous workload. The Gallery courtyard has two small crowds:
blue members run `CrowdWalker.Update`; orange members use `GalleryCrowd`'s query over `CrowdMotion` and
`ObjectLink`. Both evaluate the same motion. The example makes the alternative visible; it is not a performance
claim for that small scene. `Samples/EcsBench` measures larger script and query workloads.

Data components are structs marked `[Component]`. Store values and engine-supported references, not independently
owned heap objects. A `Query<A, B>` belongs to one `World`; keep it while that world lives and destroy it before
the world. Its destructor releases the native query. Within an iteration, `chunk.Read<T>()` and `Write<T>()`
expose packed columns. The spans are valid only for that chunk. Never retain a row pointer across structural
changes, scene transfers or another iteration.

The current explicit API is `Query<T...>` and `World.AddStep`; the migration plan's proposed `[System]`
attribute is not a registration API implemented by this release. `World.AddStep` accepts a pipeline, name,
phase and engine-owned callback. `Scene.FramePipeline` and `TickPipeline` expose the engine's scheduling points.
Avoid adding a separate tick step for logic already run by a networked script.

## Ordering and parallel work

Ordinary scripts run on the main thread in registration order. Query table order can change when components
are added or removed. Do not use that order for shared gameplay state, event ordering, spawning or random draws.
Where ordering matters, gather operations and apply them by a stable identity in an explicitly chosen sequence.

`Query.ParallelFor` uses Tallow's Jobs threads. Only independent row work belongs in its callback. It temporarily
makes the world structurally read-only: do not create, destroy, add or remove components, access the editor,
call arbitrary scripts or mutate shared objects. A floating-point reduction is not automatically deterministic.
Parallel motion is safe only when each output depends on its own row and fixed, immutable inputs.

## Small script conveniences

`CreateString` and `CreateList<T>` create resources owned by a script. Create them once, usually in the script's
constructor, and reuse them. They are released when the engine deletes the script. Do not delete them yourself,
transfer them to another owner or replace an owning field with an unrelated resource. List elements remain
values or references owned elsewhere; the helper does not recursively delete them.

`GUI.LabelFormat(x, y, "{} fps", fps)` and `UIElement.SetTextFormat("Hello, {}", name)` format directly into
engine-managed temporary or element text. They simplify authoring; formatting still has a CPU cost.

For timed sequences, keep a public float initialised to `-1` and use `ScriptTimer.Start(ref wait, seconds)` and
`ScriptTimer.Advance(ref wait, deltaTime)`. Advance returns true exactly once at completion. A switch over an
ordinary stage field can perform the next action. The state is ordinary serialisable script data rather than
an opaque suspended call stack. Lockstep snapshots can restore those fields; state-sync gameplay state that
must survive corrections still needs the engine's supported sync fields. Timers do not eliminate that rule.

## Measuring improvements

Use Release builds on the same hardware. Save the baseline player, then run `tools/run_ecs_bench.py` with
`--baseline-executable`, `--runs` and `--output`. Compare full-frame cost separately from script-update cost,
and keep individual runs. The tool alternates execution order and reports medians of each run's measurements.
Other active workloads can dominate small differences. Re-run deterministic state/event checks after changing
dispatch or access paths, and retain the network correction and replay counters when comparing prediction.
