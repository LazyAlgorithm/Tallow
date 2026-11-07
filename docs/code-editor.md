# Code editor

The Scripts tab uses the Beef IDE's compiler for completion, symbol information, definitions, diagnostics and
project-wide rename. It reads the same project sources and dependencies as the editor's Debug build, including
unsaved open documents. Engine API indexing is still used for syntax colours and visual scripting; semantic
suggestions come from Beef's type resolver.

## Completion and navigation

Type a member access, or press Ctrl+Space, to request completion. Suggestions account for local type inference,
inheritance, generics, visibility, engine component handles and project-defined types. Parameter information
comes from the compiler's overload resolution. Hover information reports the compiler's type information.
**Definition (F12)** opens the declaration. **Symbol / Parameters** requests information at the cursor.

The selected suggestion appears as a faint suffix at the cursor. **Tab** accepts it and **Escape** dismisses it;
the suggestion list remains available for choosing another member. Typing more of the same member filters the
cached suggestions immediately. Changing the receiver or surrounding source requests fresh compiler results.

Queries run in a background process which keeps the workspace compiler ready between requests. Editing remains
available while a query runs, and results from an older source snapshot are discarded. Member-prefix typing
reuses the resolved declarations; other source changes update them before completion. Added or removed source
files restart the workspace compiler. A syntax error in unfinished code does not disable completion elsewhere.

In local Linux validation with the Gallery workspace (533 Beef source files), changing member prefixes took
77 ms median and 79 ms at the 95th percentile across 40 warm queries, including the adapter process and IPC.
The first query took 1.3 seconds; running a fresh compiler for each query took 1.16 seconds median. These are
measurements on the development machine, not latency guarantees. Declaration changes and diagnostics require
more compiler work than filtering a member prefix.

## Rename across the project

Place the cursor on an identifier and choose **Rename Symbol (F2)**. Enter the new name and preview the changes.
The compiler finds references to that symbol, including declarations and uses in other files. Unrelated
identifiers with the same spelling, comments and strings are excluded.

Before accepting the preview, the engine checks the changed source with Beef again. It refuses invalid names,
new compiler errors and changes that would capture another symbol or change which declaration a use refers to.
It also checks that the source has not changed since the preview. **Apply Rename** updates the affected editor
buffers; **Save All** writes them. **Undo Rename** restores the whole operation, provided those buffers have
not been edited again.

Renaming is limited to the project's source files. Declarations in the engine or other dependencies must be
changed in their owning workspace. Generated graph scripts are protected: convert the graph to a normal script
before applying a rename that would edit it. Scene/prefab serialized names, reflection lookups written as strings
and other asset references are not compiler symbols and are not rewritten by code rename.

## Errors and determinism warnings

Compiler errors and warnings, semantic-worker failures and the engine's determinism warnings appear in the
Console, with source locations that open the relevant script. Errors and warnings are shown only in the Console;
the code pane has no diagnostic markers or separate problem list. Compiler diagnostics are refreshed from
unsaved text after typing pauses; saving still runs the normal build and hot-reload checks.

The determinism checks remain enabled alongside Beef's diagnostics. In predicted `Update(TickInput, ...)` and
`Simulate(NetInput, ...)`, they flag unseeded randomness, frame-dependent time, clocks and direct key/mouse reads.
Use the supplied fixed delta and tick input, and the engine's deterministic random helpers. These warnings
highlight common mistakes; passing them is not a proof of deterministic gameplay. Replay and network state
checks remain necessary.

## Installation and platforms

Linux and Windows builds include the semantic worker. It uses the already-required Beef toolchain and corlib
sources; no separate language server configuration is needed. Linux packages include the worker's non-core
shared-library dependencies and notices. Windows uses the `IDEHelper64.dll` supplied beside `BeefBuild.exe`.
A missing or incompatible toolchain produces a Console diagnostic rather than silently substituting text-based
completion.

Source builds compile the worker as part of `build.sh` / `build.ps1`. On a source checkout, an unbuilt worker can
also be built on the first query and cached in the user's cache directory. Linux requires a C++17 compiler for
that build; Windows uses the existing clang-cl/MSVC build environment. Normal packaged use needs neither step.
The Windows worker's completion and reference queries have been exercised under Wine; native Windows UI and
macOS semantic-worker validation remain separate platform checks. The macOS semantic worker is not implemented.
