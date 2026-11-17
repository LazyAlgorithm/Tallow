# Jobs: work spread over the cores

The engine spreads its own heavy work (bent models, navigation paths, agents' steering) over the cores by itself; see below. For a C# game's own heavy work, use .NET's `Parallel.For`:

```csharp
float[] scores = new float[targets.Length];
Parallel.For(0, targets.Length, i => scores[i] = Score(targets[i]));   // plain data only
```

- **Each body must only touch its own item's data.** Reading shared data that nothing changes during the batch is fine; writing it is not.
- **Do not use the engine from other threads**: no moving objects, no components, no physics queries, no logging through the engine. Copy what the work needs into arrays first and apply the results on the game thread afterwards.
- For work that takes longer than a frame, `await Task.Run(() => ...)` in a script: the code after the `await` is back on the game thread.

Engine (Beef) code has `Jobs.For(count, body)`, which runs `body(i)` on the engine's worker threads and the calling thread together, with `chunk`, `minimum`, `Jobs.ThreadIndex` and `Jobs.ThreadCount`.

The engine has one worker for each core but two (one is the calling thread's; the rest leave room for the physics and audio threads), up to 15. `TALLOW_JOB_THREADS=N` caps the threads sharing a batch at N, the calling one included (a server sharing its machine, or checking that results do not depend on the thread count). They start the first time a batch is big enough to share and sleep between batches. Web builds and one-core machines have none: everything runs on the calling thread.

## What uses them

- **Models bent on the CPU** (Skinned Mesh Renderers without GPU skinning): the frame's models are bent together at the end of `Scene.Update`, once animation, scripts and IK are done. 100 characters of 5,184 vertices: 13 ms to 4.2 ms.
- **Navigation paths**: what Navigation Agents ask for during `Update` is found together after it (`NavigationData.FindPaths`), each thread with its own search memory. Reading an agent's `Path`, `HasArrived`, `PathFailed` or `RemainingDistance` before then finds that agent's path at once, so scripts see the same thing as before.

- **Navigation Agents steering round each other**: each step, the agents' steering runs in tiles over the threads (`NavigationAgentSystem`, see docs/navigation.md, Avoidance). Agents in a tile go one after another; tiles too far apart to see each other run at once, so the result is the same with any number of threads.

Bent models and paths wait for the batch only inside `Scene.Update`: called on their own (an editor tool calling `OnFrame`, a test calling `Update`), they do their work at once.
