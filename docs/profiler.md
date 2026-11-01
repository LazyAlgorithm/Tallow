# Profiler

The Profiler shows where each frame's time goes: on the main thread, on the job threads and on the GPU. It also keeps counters for every part of the engine (draw calls, memory, bodies, network bytes, particles and more). It records the editor (in edit or play mode), a running build or dedicated server over the network, or a saved capture. Open it with **Window > Profiler**.

Nothing is recorded, and almost nothing is spent, until recording starts.

## The window

- **Record / Stop** starts and stops recording. **Play Mode Only** records only while the scene plays.
- The source picker chooses **This Editor**, **Attached Build** (address and port, then **Attach**) or **Loaded File**.
- **Each Component** times every component's `Update`, `LateUpdate`, `FixedUpdate` and `OnFrame` by type (`PlayerController.Update()` with its call count). Turn it off for less overhead; the "(every component)" totals stay.
- **<** and **>** step through frames, and **Newest** goes back to following the latest one. Clicking or dragging on any chart also picks a frame.
- **Save** writes the frames to `Profiles/capture-<date>.tprofile` in the project, and **Load** opens one.
- **Export Report** writes a text report to `Profiles/report-<date>.md` and copies it to the clipboard ([below](#reports-for-debugging)).

Charts sit above the details, one for each module ticked in the row of checkboxes:

| Module | Shows |
|---|---|
| CPU Usage | The main thread's time per frame, stacked by category (Scripts, Rendering, Physics, Animation, Audio, Networking, AI, UI, Particles, Assets, Jobs, Editor, Waiting, Other), with 30 and 60 fps lines. |
| GPU | GPU time per frame, stacked by render pass (bgfx view). |
| Rendering | Draw calls, instances, triangles, visible renderers, views and shadowed lights drawn by the engine; bgfx's draws, compute dispatches, copies and primitives over every pass; render passes. |
| Memory | Process memory (resident), texture, render-target and GPU memory from bgfx, engine textures, mesh CPU copies, texture and mesh counts. |
| Physics | Bodies, joints. |
| Animation | Animators, skinned mesh renderers. |
| Audio | Playing sources, one-shot sounds. |
| Networking | Bytes sent and received per second, rollbacks, physics rollbacks, predicted bodies, inputs not yet used, the last correction. |
| AI | Navigation agents, behaviour trees, paths found, path-search visits. |
| UI, Particles, Assets, Scripts, Jobs | UI documents; particle systems and live particles; background loads and loader busy; game objects and components; job threads. |

Each counter line is scaled to its own highest value. The legend gives the picked frame's figures.

The tabs below show the picked frame:

- **Hierarchy**: the frame's calls on one thread merged by path, with total and self time (and their share of the frame) and call counts. Rows open and close. The search box lists every row whose marker matches. Self time is a marker's time minus the markers inside it.
- **Timeline**: every thread's samples across the frame, one lane per thread, nested downwards. The wheel zooms around the mouse, dragging scrolls, and double-clicking shows the whole frame. Hover a block for its time. Job workers' blocks carry the marker that started the job.
- **GPU Passes**: each pass's GPU time and share.
- **Counters**: every counter for the frame, with the lowest, average and highest over the frames kept.
- **Memory**: **Take Snapshot** lists every texture and mesh the engine holds with its size, plus the process and GPU totals. Pick a second snapshot under **Compared with** to see what grew, what is new and what went, largest first.

The window keeps the last 300 frames (`Profiler.Local.limit`).

## Markers and counters in game code

```beef
static ProfilerMarker sPathfinding = .("Enemy Pathfinding", .AI);
static ProfilerCounter sEnemies = .("Enemies Alive", .Scripts);

public override void Update()
{
	sPathfinding.Begin();
	FindPaths();
	Profiler.End();

	using (sPathfinding.Sample())   // the same, ended at the block's end
		FindMorePaths();

	sEnemies.Set(enemies.Count);    // Set keeps the last value in a frame; Add sums
}
```

A marker or counter registers its name on first use, so the fields cost nothing until then. Recording works from any thread: a thread you start yourself can be named with `Profiler.NameThread("Loader")`. `Profiler.Marker(name, category)`, `Profiler.Begin(id)` and `Profiler.Counter(name, category, unit)` are the plain forms. Units are free text, and units starting with "bytes" are shown as KB, MB and GB.

A sample still open when a frame ends is cut there and continues in the next frame, so long work on another thread shows in every frame it spans.

## Builds and dedicated servers

| Switch | Does |
|---|---|
| `--profile` | Records from the start. |
| `--profile-listen [port]` | Lets an editor attach (default port 7741, UDP through ENet). Recording runs while an editor is attached, and the editor's Record/Stop controls it. |
| `--profile-save <file>` | Records, and writes a `.tprofile` capture when the program ends. |
| `--profile-report <file>` | Records, and writes a text report when the program ends. |

To watch a build: start it with `--profile-listen`, then in the editor choose **Attached Build**, enter its address and port, and press **Attach**. The build sends every frame along with any names made since the last one. Allow about 40 KB per frame on a busy scene. A web build cannot listen.

## Reports for debugging

A report is a Markdown text file to read yourself, or to give someone else (or an AI assistant such as Claude or Codex) to find out why a game is slow. Write one with **Export Report** in the window (it is also copied to the clipboard), with `--profile-report <file>` on any build or server, or in code with `capture.SaveReport(path)` / `capture.WriteReport(text)`. It contains:

- The spread of frame interval, CPU and GPU times (average, median, 95%, 99%, worst, best), and how many frames were spikes (over twice the median).
- The main thread's average time per category.
- For each thread, the markers by average self time per frame, with total time, calls per frame, the worst frame and how many frames each ran in.
- The five slowest frames in full: the main thread's call tree (rows over 0.05 ms), how busy the other threads were, and the GPU passes.
- Average and worst GPU time per pass.
- Every counter's first, lowest, average, highest and last value (memory growing from first to last without coming down can be a leak).

To reproduce a problem for someone else, record the moment it happens, then **Export Report**, or run the build with `--profile-report report.md` and quit right after the problem.

## Overhead and limits

- While recording, a sample costs two clock reads and a short append to the thread's own buffer. **Each Component** adds one sample per component per method, which matters with thousands of components; turn it off then.
- GPU times come from bgfx's timer queries, turned on only while recording. They describe the latest frame the GPU has finished, a frame or two behind the CPU. OpenGL and some drivers give no per-pass times. A headless run or a dedicated server has none.
- Beef has no garbage collector, so there is no garbage module. The Beef runtime does not count allocations, so the hierarchy has no allocation column. Use memory snapshots to see what is held.
- Process memory is read on Linux and Windows. macOS shows -1 for now.
- The editor's own panels appear under **Editor.DrawUI** when the editor is recorded.

## Test switches

`Tests/Profiler` checks nesting, self and total time, calls, counters, categories, job-thread samples, samples cut at frame ends, per-component markers, the 300-frame history, saving and loading, reports, memory snapshots, and an editor attaching over ENet.

In the editor: `--profiler` opens the window recording, `--profiler-tab <0-4>` picks a tab (4 also takes a memory snapshot), `--profiler-attach <host:port>` attaches to a build, and `--profiler-test` records 30 frames and logs `PROFILER-TEST PASS` (`--profiler-report <file>` also writes a report then).

## Navigation and overlap queries

Recording now includes `Navigation.Regions`, `Navigation.Nodes`, `Navigation.Nearest`, `Navigation.Search`, `Navigation.Corridor`, `Navigation.Smooth` and `Navigation.LineClear`. Search includes corridor construction; smoothing includes its line checks. Compare self times when adding costs.

`Physics.Overlap` is a whole overlap query; `Physics.Overlap.NativeContacts` is the part of it in Jolt (finding the bodies and their contacts), the rest is turning them into hits.

The standalone headless benchmark harnesses in `Benchmarks/full-engine/features` and `Benchmarks/full-engine/tallow` accept `SCENARIO COUNT WARMUP SAMPLES --capture /absolute/path.tprofile`. Warmup is excluded, each measured batch is a profiler frame, and a matching `.tprofile.md` report is exported. Capture writing happens after timing. These switches belong to the benchmark harnesses; normal builds use the application switches above.

For focused native overlap diagnostics, configure native CMake with `-DTALLOW_PROFILE_CONVEX_QUERIES=ON` and rebuild `tallow_native` (which also builds Jolt). During recorded overlaps, the convex dispatch translation unit forwards `Physics.Overlap.ConvexPair` and `Physics.Overlap.EPA` scopes to the engine profiler. These diagnostic scopes add substantial overhead and do not cover every Jolt routine. Restore the option to `OFF`, rebuild native and standalone binaries, and disable recording for production timing comparisons. The CMake option defaults to `OFF`.
