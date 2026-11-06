# Component-owned resources

`Component.Own` transfers an **exclusively owned** heap object to a component. The component releases it after
its destruction/unregistration callbacks, when play stops, when hot reload retires it, or as a fallback on deletion.
No ownership lookup or cleanup runs in each Update. The ownership lists are allocated only when used; components
currently carry two nullable list fields and a closed-state flag, whose memory impact still needs benchmarking.

```beef
[Component]
class Preloader : Script
{
    AssetLoader.Batch loading;

    public override void Awake()
    {
        loading = AssetLoader.Preload(this, "Models/room.glb", "Textures/wall.png");
    }

    public override void Update(TickInput input, float deltaTime)
    {
        if (loading.IsDone && !loading.IsCancelled)
        {
            // The ordinary renderer/asset APIs can now use the cached assets.
        }
    }
}
```

The overload releases the preload **batch**, not the shared loaded meshes/textures. Existing unowned `Preload`
callers retain their existing responsibility to delete the batch. The shared asset caches still require explicit
unload coordination; this change does not provide versioned/refcounted shared asset handles.

Use `Own(new List<...>())` for an exclusively owned collection. Do not also give an adopted field a `~ delete _`
initializer, manually delete the adopted object, adopt it into another component, or adopt a cache-owned asset
such as a mesh returned by `Assets.GetMesh`. Adopting the same object twice into one component is deduplicated.
Adoption does not recursively collect referenced objects, eliminate ownership cycles, or make raw references weak.

`OnCleanup(new () => { ... })` transfers a cleanup delegate to the owner. It runs once, in reverse registration
order, before owned resources are deleted. Use it to disconnect a known subscription or cancel/join owned work.
It does not discover subscriptions or cancel arbitrary tasks automatically. Cleanup must run on the scene thread;
it cannot destroy its own owner or add resources/cleanup callbacks during cleanup. Code registered on an external
publisher must still account for that publisher's lifetime.

Reacquire resources in Awake on a new play session. Do not use old batch/resource references after StopPlay,
removal, scene teardown or hot reload; owned references are not transferred to a replacement script instance.
Custom resources still need correct destructors. Existing arbitrary delegates retained outside this mechanism
and retired hot-reload instances remain limitations described in `script-hot-reload.md`.

The EcsBench ownership checks cover duplicate adoption, cleanup-before-delete ordering, play restart, component
removal, object destruction and detached-component deletion. These passed in Linux Debug and Release at `d9993ece` (workflow 42264324947), including shutdown/cancellation and
releasing a batch after shutdown. Windows compiled successfully; equivalent runtime checks there remain pending.

Preload shutdown joins workers before discarding pending payloads. Outstanding batches become done/cancelled
and remain safe to inspect until their owner releases them. Uploaded image staging buffers are freed immediately;
`AssetLoader.Busy` includes work currently executing on a decoding thread.

A complete, compiled gameplay example is [`PatrolExample.bf`](../Samples/EcsBench/src/PatrolExample.bf).
Attach it to a visible GameObject and set `speed` and `distance` in the Inspector. It moves between two points using
`Transform` and the supplied `deltaTime`; its waypoint collection is adopted once in `Awake`, with no per-frame
allocation or manual deletion. This is a local movement example, not a navigation, collision or network prediction
controller. Mutable reference collections are not automatically deep-copied into rollback history.
