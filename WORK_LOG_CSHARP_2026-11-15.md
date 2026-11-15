# C# gameplay work log — 2026-11-15

This file records the changes made in this conversation on `feature/csharp-gameplay`. It separates changes already pushed from local commits and records what has been verified.

## Pushed to GitHub

- `01006f86` — Existing local commit pushed during this conversation. Converted the animator, physics queries, character controller, input, saving, and scenes guides to C# examples and added the gameplay APIs those examples use. Added compiling documentation snippets and in-engine checks. Saved and synchronized object-reference fields are skipped because their IDs are specific to one run and machine.
- `df1ef12a` — Committed and pushed the six pre-existing working-tree changes: C# `AudioSource` playback controls, mixer settings and group volumes, native component registration, an `AudioGroup` enum parity check, and delayed code-editor hover popups that dismiss when the pointer leaves or input changes. Removed one trailing-whitespace line before committing. The branch and GitHub were synchronized at `df1ef12a`.

## Local commits after that push

- `bef12403` — Added a roadmap task for a pinned .NET 11 SDK in a Tallow-owned per-user folder shared across engine versions. It covers first-run download, verification, atomic staging, SDK selection for all C# tools, offline reuse, failure handling, clean-machine checks, and an optional offline engine package. This is a plan; SDK acquisition is not implemented.
- `2d63e0ae` — Changed the graph editor so a completed C# build does not free node definitions while an open graph still refers to them. The node catalog refreshes when the graph is reopened. Also rejects negative or out-of-range graph pin indices during loading, validation, and overload adaptation. This addresses a likely cause shown by the local editor crash dump; an interactive repeat test is still needed.

## Graph and Project window fixes in this commit

- **Convert to Script:** After the `.tgraph` is removed, its `.tmeta` and other companion files are removed too, and the asset-ID index is refreshed. A failed generated-script read or write now stops the conversion before removing the graph.
- **View Generated Code:** Compiles the saved graph without opening or focusing the Graph window, then selects its generated `.cs` or `.bf` file in the Scripts code editor. Existing generated-code tabs reload from disk. The existing graph-source check keeps the tab read-only while the `.tgraph` exists. A subgraph reports that it has no standalone generated script.
- **Generated-code ownership:** Reopening a script refreshes its read-only state from the presence of its source graph. Viewing or recompiling a graph replaces any open generated-code buffer with the graph's current output and locks it. The code editor blocks Cut, Paste, Undo, Redo, completion insertion, and programmatic rename changes in read-only code; saving checks for a source graph again before writing. Convert to Script remains the one-way step that removes the graph and makes the script editable.
- **Project window Create menu:** Right-clicking empty grid space or gaps between tiles opens the Create menu, including when the Project window was not previously focused. The grid menu opens only when the right button is released over empty space, so it cannot cover a file's context menu. Blank space in the folder pane also opens Create. Tile context menus are attached to the tile button itself rather than a later drawn item. Graph actions from tile menus run after the asset grid has finished drawing, so conversion cannot invalidate its current iteration.
- **Delete graph:** Deleting a `.tgraph` through the asset database also deletes its generated `.cs` (or legacy `.bf`) and the generated script's `.tmeta`. A script that was converted remains because conversion removes the graph while keeping the script. The asset-ID test covers graph and generated-script cleanup.

## Checks and limits

- Full native Debug Linux build passed after the earlier graph crash fix and after the graph/Project-window changes. The managed runtime build passed with zero warnings and errors.
- Full native Debug Linux build passed again after graph deletion cleanup, after restricting the grid menu to empty space, and after locking generated code in the engine's Scripts editor. The `--asset-ids-test` editor run passed on a disposable C# project, including deletion of the graph, generated C# file, their `.tmeta` files, and asset-ID entries. It also confirmed that the generated C# tab is read-only and rejects a code replacement.
- The real-engine C# test passed **189 checks**, including graph compilation and execution, after the graph crash fix. It was run before the three Project-window fixes in this commit.
- The changed Beef files passed the engine formatter check; `git diff --check` passed.
- The Project-window context menu and read-only Scripts tab still need an interactive editor check. The intermittent graph-editor crash is not yet confirmed resolved by repeated interactive use.
- The shared SDK installer, full Beef-versus-C# benchmark, and complete C# gameplay parity remain future work. No benchmark result is claimed here.

The two local commits above and this commit have not been pushed to GitHub as part of this work log.
