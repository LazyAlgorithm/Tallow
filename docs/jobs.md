# Jobs: work spread over the cores

`Jobs.For(count, body)` runs `body(i)` for every `i` below `count` on the engine's worker threads and the calling thread together, and returns when every one has run:

```beef
Jobs.For(enemies.Count, scope (index) => enemies[index].Think());
```

- **Each body must only touch its own item's data.** Reading shared data that nothing changes during the batch is fine; writing it is not (no adding to a shared list, no moving objects in the scene, no graphics calls).
- `chunk` hands out that many items at a time, for cheap items (`Jobs.For(100000, body, 256)`), so the threads take turns less often.
- `minimum`: fewer items than this run on the calling thread alone (waking the workers costs a few microseconds).
- `Jobs.ThreadIndex` says which thread a body is on (0 the caller, 1 and up the workers, all below `Jobs.ThreadCount`), for scratch memory kept per thread.
- A `Jobs.For` started inside another (or from a second thread while one runs) runs on the calling thread.

There is one worker for each core but two (one is the calling thread's; the rest leave room for the physics and audio threads), up to 15. `TALLOW_JOB_THREADS=N` caps the threads sharing a batch at N, the calling one included (a server sharing its machine, or checking that results do not depend on the thread count). They start the first time a batch is big enough to share and sleep between batches. Web builds and one-core machines have none: everything runs on the calling thread.

## What uses them

- **Models bent on the CPU** (Skinned Mesh Renderers without GPU skinning): the frame's models are bent together at the end of `Scene.Update`, once animation, scripts and IK are done. 100 characters of 5,184 vertices: 13 ms to 4.2 ms.
- **Navigation paths**: what Navigation Agents ask for during `Update` is found together after it (`NavigationData.FindPaths`), each thread with its own search memory. Reading an agent's `Path`, `HasArrived`, `PathFailed` or `RemainingDistance` before then finds that agent's path at once, so scripts see the same thing as before.

- **Navigation Agents steering round each other**: each step, the agents' steering runs in tiles over the threads (`NavigationAgentSystem`, see docs/navigation.md, Avoidance). Agents in a tile go one after another; tiles too far apart to see each other run at once, so the result is the same with any number of threads.

Bent models and paths wait for the batch only inside `Scene.Update`: called on their own (an editor tool calling `OnFrame`, a test calling `Update`), they do their work at once.
