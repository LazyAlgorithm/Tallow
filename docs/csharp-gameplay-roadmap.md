# C# gameplay migration — actionable roadmap and handoff

Last updated: 2026-11-14 (review section and P6 added). Source branch: **feature/csharp-gameplay** of [LazyAlgorithm/Tallow](https://github.com/LazyAlgorithm/Tallow). Keep changes on this branch, **not** `ecs`, until acceptance tests pass. Also read [C# architecture and current implementation](csharp-gameplay.md).

## For a future ChatGPT conversation

Read this entire checklist, `docs/csharp-gameplay.md`, then inspect **current** GitHub branch HEAD, changed source, and recent C# CI runs before continuing. The user has been performing the full native BeefBuild and interactive editor tests locally on **Nobara Linux**; managed Linux/Windows GitHub CI does **not** compile the complete Beef editor. Fix any user-supplied build failures first, commit fixes to `feature/csharp-gameplay`, update this document, and supply the single pull/build/launch command. Do not infer feature completion solely from source changes or managed CI. Do not change the other branches or existing games.

### Constraints agreed with the user

- Keep the **native Tallow engine and editor in Beef**; gameplay uses **C# 15 / .NET 11 JIT**. Unity-like ergonomics, high ECS performance, determinism, and networking by default; optional access to lower-level behavior.
- **One precompiled editor and runtime** shared by all games. Editing or opening a C# project must **never** compile a game-specific native editor/engine with BeefBuild. .NET builds gameplay. BeefBuild stays for people developing the engine or invoking a legacy native workflow.
- A project must **open even with invalid C#**. Show errors in the Console and code editor. Block Play until the C# assembly compiles successfully.
- Success message **"C# assemblies compiled." disappears after 1 second**. Do not auto-dismiss failures, progress messages, or newer statuses.
- Use Roslyn as the source of truth for methods/classes/members/completion; do not maintain hand-written C# symbol lists. Strong C# syntax coloring, full diagnostics, parameter hints, and fast completion are expected.
- Public fields editable in Inspector and persisted in scenes/prefabs. C# source can be dragged onto a scene object or Inspector to attach the compiled component.
- Visual scripting stays and ultimately emits/interoperates with C# (without removing hand-authored C# or existing graphs).
- Do not expose a public untrusted assembly/mod loader: collectible AssemblyLoadContext does **not** provide sandbox security. Handle lifetimes and native pointers carefully.

## What is confirmed versus provisional

**User-confirmed in Nobara editor (before latest changes):**
- C# code compiled, a C# behavior attached to a scene object, and Play executed movement.
- Public Inspector fields appeared and **saved correctly** (the user explicitly confirmed this). Do **not** rework this functioning feature without cause.

**Implemented, still needs full editor test:**
- Precompiled editor launcher and development player paths; no per-project BeefBuild for C#.
- Background C# compilation and compile-failure recovery; error messages and Play gating.
- C# source drag/drop onto Hierarchy and Inspector, compiler-generated component catalog.
- C# vector arithmetic/global System.Numerics in generated project and Roslyn semantic context.
- Persistent Roslyn server and improved inherited/static/class completion; additional lexical C# highlighting and hints.
- C# source monitor, edit-triggered managed compile.
- One-second success notification; latest reported native Beef error (missing System.Diagnostics in `ScriptEditor.bf`) fixed in commit `0b0eb7e`. The prior error using reserved keyword `extension` in `ProjectFolderMonitor.bf` was fixed in `64d0eb0`.
- Shared managed runtime bootstrap for editor and local standalone game runner.
- `.tasmdef` assemblies, managed API, initial hostfxr bridge, and native-host Linux/Windows smoke tests.

**Important:** The earlier Roslyn `Vector3` operator false errors and autocomplete slowness were reported by user before the latest changes, but the latest editor-side improvements have **not** been confirmed locally. Managed regression tests alone do not establish editor behavior.

## Current stabilization progress (2026-11-13)

- **2026-11-13: Native-editor Linux CI added** to `.github/workflows/csharp-gameplay.yml` (commit `2a19d7e`), using a pinned Beef compiler, native libraries and a full Debug_Linux64 engine/editor/launcher build. **Pending actual CI result**; managed CI alone did not catch previous Beef parser failures.
- **2026-11-13: Script saves during an ongoing C# compile now queue a fresh build** before Play can activate, commit `2f3cf81`. This is a code-level race fix; requires Nobara integration test for save/edit/save during compile.
- **2026-11-13: Code-editor hint usability:** removed persistent signature tooltip under caret (`12f5aa3`), added **450 ms stationary symbol-hover delay, immediate dismiss on pointer leave/click/move, non-interactive hint window** in the bundled TextEdit patch (`2ede07b`). Tooltip behavior needs local native build and interactive verification.
- Existing Linux/Windows managed CI for C# gameplay remains green as of the previous completed runs; native CI's first completed run is the remaining verification gate.
- **Do not mark P0 complete** until the new native CI build passes and the user tests the full editor on Nobara.

## Latest work — reflection-driven C# API contract

- **2026-11-13:** Managed host smoke-test CI on both operating systems failed because its `TestBridge` lacked `IEngineBridge.TransformPoint`. Fixed in `1d470fe`; managed GitHub CI for that revision passed on both Linux and Windows. This restores the existing bridge's test contract but does not complete C# API parity.
- **2026-11-13:** First stage of `[CSharpExpose]` generator work: `Engine/src/Scripting/CSharpBindingManifest.bf` enumerates *compiled/reflected Beef symbols*, enforces type and method opt-in, validates a restricted static/value-only signature set, and emits a deterministically sorted manifest (`96ce894`). A headless launcher entrypoint `--csharp-api-manifest FILE` was added (`9878ea9`); native Linux CI has a positive/negative exposure test (`58afd98`). Full native CI validation is **still pending**.
- **Design decision:** The annotated Beef API is the **single public contract**, not an additional manual C# API to maintain. Generated bindings should favor direct typed native calls for ordinary methods and bulk/chunk ECS access for near-native throughput, never mandatory per-entity managed/native calls. See `docs/csharp-expose.md` (updated in `b804555`). Keep specialized interop as private implementation detail.
- **Still not implemented:** generated native entrypoints, generated managed wrappers, ABI compatibility/version checking, automatic Roslyn pickup of exposed APIs and the actual C# invocation test. The prototype manifest must **not** be represented as a working bridge yet.

- **Native build failure found locally:** Beef rejected directly deferring a cleanup mixin in new `CSharpBindingManifest.bf`. Wrapped `ClearAndDeleteItems!(records)` in a `defer { ... }` block in `58cf1a3`. Await full native rebuild confirmation; no C# binding generator completion claimed.
- **Performance increment:** Replaced O(all managed instances) `GetComponent<T>()` lookup in the .NET runtime with an entity-indexed list preserving attach order, maintaining the index across attach/detach/unload/shutdown (`44ebdef`). Existing native-host GetComponent integration test exercises this path; CI is pending.

## 2026-11-14 review of the branch against `ecs` (Claude)

Reviewed `7a7b6ca1..c6c17898` (356 commits). Fixed in `044f4937`, `cfac557f` and the
commit that adds this section; each fix was checked by a headless run of the real
player unless noted.

- Bool Inspector defaults: the catalog wrote `True`, the Inspector only read `true`/`1`.
- Saving a `.bf`/text file in a C# project set `mScriptsNeedReload`, which then blocked
  Play forever ("Script reload is unavailable") and started BeefBuild. Graph saves and
  Check Errors also fell through to BeefBuild. C# projects now never run BeefBuild.
- Adding a C# component from the Inspector **during Play** now calls `Configure`.
- Editing one field during Play re-applied every saved override, undoing runtime state.
- Bare C# ECS entities survived Stop; `SceneManager.Load` reused GameObject IDs within
  one session (stale handles could alias new objects). Both fixed.
- `.tasmdef` edits now trigger a compile; `fields.tsv` is cached instead of read per frame.
- Private `[ShowInInspector]` fields on a base class were never catalogued/restored.
- NaN/Inf ignored by Transform writes and the older Rigidbody calls; a script that throws
  every tick is logged once then periodically; hostfxr reads env vars as UTF-16 on Windows
  (CI-only verification); the explicit legacy native build applies the toolchain again;
  source checkouts no longer run the Python version check on every open.
- Code editor: `1f`/`2.5d`/`3m`/`4UL` suffixes colored as numbers; completion inside
  `[ ]` lists attribute classes by short name (Tallow, framework and user attributes,
  covered by Roslyn tests). Interactive editor confirmation still needed.
- New empty projects ship `Scripts/FirstPersonCharacter.cs` (C#) instead of a graph
  compiled to Beef, which the precompiled editor could not load.
- `Tests/CSharpExpose/fixture.tsv` had drifted from the engine manifest; native CI now
  fails when they differ.

**New test:** `tools/test_csharp_ingame.py` builds `Tests/CSharpInGame` and runs 45 checks
inside the real player with `--fixed-step` (new switch: one fixed tick per frame). Scene,
Jolt and Flecs are the engine's own, not the C++ ABI double. Passes on Nobara; added to
native Linux CI.

**Not fixed, deliberately left to roadmap items:** release builds hardcode
`Tallow.ManagedRuntime/bin/Debug` (P4 packaging); Windows may keep `Tallow.Game.dll`
locked after unload (P4 hot reload: load from a stream/shadow copy); graphs still compile
to Beef (P3).

## 2026-11-14 later: launcher dependencies, version pins, external edits, assembly definitions

- **Launcher dependency check** (`Editor/src/Project/DotNetCheck.bf`): runs on a worker
  thread when the launcher opens. Red/amber lines above the project list for a missing or
  old SDK, a missing runtime, a preview SDK, or a `Tallow.ManagedRuntime` older than its
  sources, with Download .NET / Copy install command / Build C# runtime / Check again.
  `--build-project` checks before compiling and rebuilds a stale runtime.
  `TallowLauncher --check-dependencies [--fix]` exits 2 when something blocks. Tested:
  healthy, stale (touched source), `--fix`, and no `dotnet` on PATH.
- **Version pins without Python** (`Editor/src/Project/EngineVersions.bf`): same files
  and verdicts as `tools/engine_versions.py`, tested against it with a temporary
  `tallow-version.json`: pin on create, same, upgrade-needed, `--upgrade` (lock rewrite
  and backup), newer project format refused, and a legacy `project.tessera` upgrade with
  the namespace rename (`TesseraIntro` and prose left alone).
- New empty projects no longer get `BeefSpace.toml`/`BeefProj.toml`; the legacy native
  build writes them when asked.
- **External script edits**: open documents check the file every 0.5 s. Unchanged here →
  reloaded (caret line kept); unsaved changes here → one warning, and saving is a
  deliberate overwrite. Before this, saving in Tallow silently overwrote an IDE's edit.
- **Assembly definition Inspector** (`Editor/src/Tools/AssemblyDefinitionEditor.bf`):
  click a `.tasmdef` in the Project panel. Name, Root Namespace, Assembly Definition
  References (add from a list that greys out cycles; remove; click to jump), live checks
  matching Tallow.Build (reserved/duplicate names, missing/self/duplicate references,
  cycles, two definitions in one folder, bad namespace), Apply/Revert, Scripts it owns,
  Referenced By. Renaming updates other definitions' references. Unknown keys are kept
  verbatim. New `rootNamespace` key is honoured by Tallow.Build (csproj RootNamespace) and
  by the editor's new-script templates. Not modelled yet (no compiler support): platform
  include/exclude, define constraints, version defines, precompiled/NuGet references,
  allow-unsafe (deliberately off).
- **Test:** `--script-files-test` in the editor runs 25 checks of the above in a scratch
  folder (`<config>/script-files-test`) and prints `SCRIPT FILES TEST PASSED`.

## P0 — stabilize, compile, test full precompiled native editor

Headless evidence (2026-11-14, Nobara, launcher built from this branch; **not** an
interactive editor test): `--create` makes a C# empty project; `--build-project` compiles
it with the .NET SDK only (1.2 s warm, no BeefBuild); a project with a CS0029 error fails
`--build-project` with the compiler message; `--game` before any build stops with
"gameplay assembly is missing" and exit code 1; after a build `--game` runs; a project
with no C# sources builds and runs with no false missing-DLL error.

- [x] Pull current HEAD and run full Nobara Linux **BeefBuild** of Tallow native/editor/launcher. Fix all compiler errors introduced by migration; add CI native editor builds to catch these without depending on the user's testing. Done (November 16, 2026): local BeefBuild of launcher/editor/player is clean, and CI's "Compile complete native Beef editor (Linux)" job builds it on every push.
- [x] Test launcher opening **existing, empty, and broken C# game projects**. Confirm same precompiled editor opens each and no per-project BeefBuild or native toolchain discovery blocks opening. Done (November 16, 2026): `tools/test_csharp_editor.py` (needs a display) opens a C# project cold and warm, a new `--create` project with its scripts deleted, and a broken one, with `--play-cycle-test`; output is checked for BeefBuild.
- [x] Validate the `--open PROJECT`, `--build-project PROJECT` (.NET only), `--game --project PROJECT`, and explicitly legacy `--build-native-project PROJECT` routes. Confirm direct project opening does not build a project-specific native binary. Done (November 16, 2026): `--build-project` (benchmarks), `--game --project` (in-game tests), `--editor --project` (editor checks) and `--build-native-project` (EcsBench) all used and working.
- [x] Test script-save and external editor changes: compilations must target current sources, no stale results or stale Play-enable flags. Check the C# source scanner after file create, move, rename, delete. Done (November 16, 2026): `--stale-build-test` (in `tools/test_csharp_editor.py`) checks which code each Play runs: a file saved by another program with Play pressed at once, an edit while a build runs, a moved file and a deleted file. The first and third ran the previous build (the editor only polled the disk every 0.5 s); Play now polls before deciding the build is current.
- [x] Ensure invalid C# (including errors without a source location) keeps scene/Inspector/Scripts editor usable, logs SDK errors in Console, and disables Play. Fix code in Tallow, compile, then Play. Done for errors with a location (November 16, 2026): the broken-project check sees the error with its file and line and Play stays off; fixing the file plays again. Errors without a location are logged by the same path (whole build log) but not separately tested.
- [x] Check Play/Stop/Play, repeated scenes, prefabs, missing .NET runtime, missing game DLL, game shutdown and cleanup. Verify no stale entity handles, duplicate callbacks, memory leaks or active managed instances after Stop. Done (November 16, 2026): `--play-cycle-test N` runs Play/Stop N times and checks every Stop detaches every C# script; 20 cycles of Samples/Sandbox pass (Play 15 ms, first 150 ms; Stop 41 ms; memory +7 MB over 20). It found that no game assembly was ever unloaded (`Rpc` method cache and callback masks keyed by game types kept every old game in memory); fixed, and the runtime now warns when unloaded games stay in memory.
- [x] Empty projects without scripts should start normally with no false "missing compiled game DLL" error; distinguish projects with no C# components from invalid managed gameplay. Done (November 16, 2026): checked by `tools/test_csharp_editor.py` (no build error, Play/Stop works).
- [x] Confirm compile-success toast clears after 1000 ms, but errors and newer status messages are never cleared by the timer. Done (November 16, 2026): the play-cycle test checks the notice is gone 1.5 s after the first build, and the broken-project run that the failure message is still showing after 1.5 s.
- [x] Confirm old/native Beef authoring remains explicitly accessible for compatibility but is not required on the C# path. Done (November 16, 2026): `--build-native-project` built the Beef EcsBench benchmark.

## Native C# generated API verification

- Initial end-to-end static-method binding stage passed full Linux native CI
  in run `43543795657` (commit `c9bd094`), alongside managed Linux/Windows.
- The generator now supports numeric scalar types, vectors, safe counted UTF-8
  input strings and annotated public static fields as properties with opt-in
  scalar setters. Real candidates: native `Noise`, `Log`, `Time`.
- Managed C# gameplay now also has initial session-validated `Scene` and
  `Prefab` facades for creation/lookup/instantiation, plus native-host tests.
- New `--csharp-api-verify SYMBOL` native CLI checks that a generated
  export is **actually resolvable in the linked Beef binary**, not merely
  present in generated text; CI also rejects a fake/unapproved symbol.
- **Not finished:** full instance-property bindings, string returns/ownership,
  custom engine-owned resources, Jolt/renderer/audio/animation, ECS query
  batches, network authority/prediction parity, all cross-platform builds.
  Latest native CI still must be checked before calling these safe additions
  production-ready.

## C# editor diagnostics: retain native visual warning categories

The C# language service now emits compiler diagnostics and a conservative set of
Tallow-specific gameplay hints into the **same editor squiggle renderer used by Beef**.
The optional 7th diagnostic field tags `optimization` and `determinism` without
changing the original six-field wire format.

- **Compiler error**: red; **ordinary compiler warning**: amber.
- **Performance hint**: cyan; currently detects proven managed reference/array
  allocations during networked ticks and repeated `GetComponent` inside loops.
  Value types such as `Vector3` are not treated as heap allocations.
- **Networking/determinism hint**: purple; currently detects unseeded
  `System.Random`, `Random.Shared`, wall-clock time, process clocks, and
  direct local input access during predicted `Update(TickInput, ...)` or
  `Simulate(NetInput, ...)`.
- Warning messages use `TAL-NET...` and `TAL-PERF...` identifiers, are advisory,
  appear inline with hover explanations and never block Play on their own.
- C# analysis uses Roslyn source symbols and syntax, so comments and quoted
  strings do not generate false network or allocation warnings.
- Native editor style, line squiggle colors, editor theme and legacy Beef
  warning checks remain untouched. C# lexical colors still use the same
  editor palette.
- **Validation pending:** automated Roslyn tests have been added, but CI and
  interactive Nobara editor verification are still required before considering
  the C# warning parity finished. Extend checks to deterministic math, ECS job
  scheduling, physics and managed allocation profiling as those APIs land.

## November 13 follow-up: autocomplete and warning cleanup

- **C# property completion:** filtered compiler-generated `get_*` and `set_*` method accessors, and event accessors, from Roslyn completion when the public property/event exists. Genuine methods with similar names remain available. Regression tests check `Transform.Position` and an actual `get_Answer()` method. Commits `bd4a496`, `fe219d1`.
- **Beef property completion:** added the equivalent member-aware filter to the Beef language-service response, retaining real methods and preserving property entries; added a regression case. Commits `36833d5`, `6e82270`, `d6c4fec`.
- **Managed warnings:** retained XML documentation output while suppressing existing CS1591 missing-comment noise (`8e1130f`). Replaced obsolete `FieldInfo.IsNotSerialized` with the equivalent `FieldAttributes.NotSerialized` flag in Inspector field loading (`427ba22`); no public API change or serialization behavior change intended.
- **Verification:** GitHub Actions for these changes were queued when recorded. Do not claim native build or interactive autocomplete validated until relevant CI and local Nobara tests finish.

## P1 — C# code editor / Roslyn integration

- [x] Check that `Transform.Position += Vector3.UnitX * Speed * deltaTime` and other `Vector2/3/4` operations compile in-game **without false Roslyn editor errors**; align SDK global usings and actual `.tasmdef` references.
  (Covered by the language-service tests: "gameplay Transform.Position += Vector3 * float operators".)
- [x] Complete semantic token coloring (classes, methods, fields, types, namespaces, attributes, generics, strings/interpolation, comments, keywords), rather than relying solely on lexical C# highlighting.
  Done November 16, 2026: the language service sends a `token` line (line, code-point column, kind, name) for every
  name the compiler places in the open file: type (attributes and constructors too), type parameter, method, member
  (field/property/event), variable (parameter/local), namespace, constant (const/enum member); `var` stays a keyword.
  Tokens are cached per member by its text, so typing in a method re-classifies that method only (body edit 74 ms
  p50 with tokens vs 83 ms before them). TextEdit draws them over its lexical colours at draw time, only where the
  glyphs still spell the name outside strings/comments, so stale spans after an edit fall back to lexical colours.
  Six new theme code colours (Method, Member, Variable, Namespace, Constant, TypeParameter), derived from a theme's
  syntax colours when a file does not list them; in Preferences. Strings, comments and keywords stay lexical.
  Tests: 3 Roslyn token tests (columns after an emoji), 3 TextEdit overlay checks, theme test for older files;
  seen in the editor and the themes checked by hand.
- [x] Completion from the compiler for ALL relevant accessible classes, methods, fields, properties, overloads, inherited/interface members, extension methods, generics, enums, namespaces, symbols in project assemblies and installed referenced libraries.
  Done November 16, 2026: the language service uses Roslyn's own `CompletionService` (`RoslynCompletion.cs`) from
  the Workspaces/Features assemblies the SDK already ships with dotnet-format; used only when they are byte-identical
  to the compiler's Roslyn (checked by hash in the .csproj), otherwise the old symbol lookup. Tallow.API is its own
  workspace project referenced by the game, so engine internals are hidden by the compiler, not by path filters.
  Context-aware keywords, named arguments, object initializer members, extension methods, attributes by short name,
  types from namespaces not imported (accepting adds the using). `[NonSerialized]` is added in attribute lists (.NET
  hides it). The service now compiles against the shared framework only (it offered its own Roslyn assemblies before).
- [x] Add accurate completion context/ranking, insertion text, auto imports, braces/parentheses, parameter/return type display and XML documentation. Do not suggest private/inaccessible or irrelevant static/instance members.
  - [x] (November 16, 2026) Ranking: exact-case prefix, any-case prefix, CamelCase humps (`gc` -> GetComponent), then
    Roslyn's priority/sort (preselects the expected enum type); up to 300 items, then `completion-more` and the
    editor asks again as the word grows. Items carry insert text, a dimmed detail (the namespace of an import), extra
    edits applied with the word as one undo (the using, `async Task` for `await`), and a description shown under
    the list for the selected item: signature with overload count and the XML `<summary>` (made from the semantic
    model; Roslyn's description service costs ~4 ms an item). Snippets are left out (no tab stops). Completion ~33 ms
    p50 after an edit (was 21 with the hand-written lookup; Roslyn's own list+encode ~7 ms, the rest the service's
    per-request work); service peak 458 MB (was 327: a second compilation for the workspace). Tests: 11 Roslyn
    tests, 12 TextEdit checks, editor `--completion-test` (step 7 of test_csharp_editor.py). Still open: the
    diagnostics compilation and the workspace could share one compilation.
  - Closed November 17, 2026: every part of the item is in (the two entries below and above). Sharing one
    compilation between diagnostics and the completion workspace is an optimisation, not a missing feature.
  - [x] (November 16, 2026) Accepting a method inserts `Name()` (caret after it when every overload is
    parameterless, inside otherwise); not when `(` or `<` already follows, after `+=`/`-=` (events, delegates),
    inside `nameof(...)`, using directives or doc comments, nor for generic methods (type argument first). Typing
    `)` steps over the inserted one. 5 Roslyn tests.
- [x] Implement robust overload-aware signature help and active argument highlighting; no overlapping code editor popups.
  - [x] (November 15, 2026) Roslyn answers `signature` with every overload (resolved first; constructors;
    before the closing parenthesis) and marks the parameter at the caret (\x01..\x02, by position or name);
    the code widget draws it above the caret line when no completion list is open. Waiting for the user to try
    it in the editor. Semantic colouring beyond type names was done since (November 16, above).
  - Closed November 17, 2026: signature help and the completion list never draw together (the list wins), and
    the completion description sits under the list, so popups no longer overlap.
- [x] Build persistent incremental Roslyn project state instead of recreating a compilation per request. Measure warm/cold latency and memory/CPU on Nobara/Windows; properly cancel stale requests, debounce typing, restart failed workers, and handle multiple files.
  Done November 16, 2026: one incremental compilation (November 14) plus per-file diagnostics kept while a file's
  tree is unchanged; an edit inside one method body checks only that file, any change another file could see
  (declarations, constants, field initializers, added/removed files) checks all again. The editor debounces
  diagnostics 1.5 s after typing, keeps one request in flight (superseded edits never queue), sends every open file
  as an overlay, backs off 10 s after a failed start and restarts a worker that stops answering. Benchmarked in B05
  (Nobara; Windows runs the same script in CI). 7 cross-file cache tests (81 Roslyn tests).
  - [x] (November 16, 2026) Measured: `tools/benchmark_csharp_language_service.py` drives the `--serve` process
    as the editor does on a copy of Tests/CSharpInGame (ApiChecks.cs, 1,500 lines): cold first request ~650 ms;
    completion, signature help and Go to Definition ~25-30 ms after an edit; diagnostics ~23 ms unchanged and
    ~210 ms after an edit (were 84 and 350 ms: problems were computed for every Tallow.API source too, and every
    tree was walked for type names on each request; now only the game's files are checked and names are cached
    per tree); peak ~290 MB. It also checks an error typed in is reported and nothing from Tallow.API is. In CI
    (3 runs). Windows numbers not taken yet.
- [x] Full diagnostics, warnings, source locations/underlines, click-through from Console; Go to Definition, Find References, Rename, and optionally integrated breakpoints/debugging.
  Closed November 17, 2026: diagnostics with underlines and Console click-through, Go to Definition, Find
  References and Rename are in (below and in P0). Breakpoints were optional: attaching an IDE debugger works
  (Tooling: Debugging); breakpoints in Tallow's own code editor stay a separate item there.
  - [x] (November 16, 2026) Go to Definition into engine API source opens it read-only (also any file outside the
    project; engine Beef sources only for Beef projects); rename/save/edit are refused there and the language service
    only answers definition/symbol/highlight for `Managed/Tallow.API`. Selecting a name highlights its other uses,
    first by text, then narrowed by the compiler to the same symbol in that file (`highlight` operation).
  - [x] (November 16, 2026) Find All References: Shift+F12, Navigate menu and the code widget's right-click menu.
    Every use across the project's scripts (unsaved edits included, unopened files too) in a References window,
    grouped by file with line:column and the line's text; clicking one opens it with the caret on the name. Uses of
    an engine API symbol in the engine's own C# source are listed and open read-only; a game symbol skips the engine
    source (it cannot use it). Rename already used the same answer. 2 Roslyn tests; editor `--references-test`
    (step 8 of test_csharp_editor.py).
- [x] Expand automated tests using actual Tallow.API/gameplay source, multi-assembly projects, inherited/static/extension completions and malformed mid-typing C#.
  - [x] (November 16, 2026) Multi-assembly projects: the language service now compiles each assembly as the build
    does (`GameAssemblies.cs`): Tallow.API on its own, each `.tasmdef` seeing Tallow.API and the assemblies it
    lists, Tallow.Game seeing all of them, the Roslyn completion workspace with the same projects. Errors the editor
    used to miss and only the build reported: a type from an assembly not referenced, another assembly's
    `internal` members, `internal` Tallow.API members, `unsafe` in game code. Each assembly's code generated by the
    last build (`.tallow-csharp/generated/<assembly>/*.g.cs`, typed ECS data extensions, with `using
    Tallow.Generated`) is now part of it: Tests/CSharpGameplay showed 14 false errors in the editor, now none (the
    same for Tests/CSharpInGame once built). A game edit leaves Tallow.API's compilation untouched; at 100 runs the
    benchmark is the same or faster (body edit 68 ms p50, was 77). 11 tests on a real project folder (an
    unreferenced assembly, adding the reference, internals, unsafe, completion and references across assemblies,
    generated code, removing the definitions).
  - [x] (November 16, 2026) Static members on a type name only, instance members on an instance only, members
    inherited from `Script` on `this.`, protected members on `base.`; half-typed code (open parentheses, generics,
    lambdas, initializers, strings and comments left open, a class without a name, an empty file): completion,
    diagnostics and signature help all answer; nothing is offered inside comments or strings; a member is still
    offered while another line has a syntax error. 8 tests (126 in all).

## Binding generation decision — explicitly curated API

**User preference confirmed:** Native Beef types/members should **not** all become C# APIs automatically. Only explicitly selected gameplay-safe surface is exported; keep engine internals invisible to normal C# authors. Keep hand-written adapters for systems that cannot be marshaled safely or efficiently.

- [x] Define Beef `[CSharpExpose]` marker (type plus individual public member, with no "expose all" default). File: `Engine/src/Scripting/CSharpExpose.bf` (commit `8d903af`). **Attribute only; not wired to generation yet.**
- [x] Record binding generator and marshalling rules in `docs/csharp-expose.md` (commit `f20bab4`).
- [x] Generate deterministic opt-in exposure manifest from actual Beef compiler/reflection symbols; validate signatures and emit actionable errors for unsupported attributes. Done (verified November 16, 2026): `TallowLauncher --csharp-api-manifest` writes it from Beef reflection over `[CSharpExpose]` members; Tallow.BindingGen rejects unsupported signatures (self-test: invalid-manifest cases).
- [x] Generate ABI-stable native entrypoints and C# wrappers together from manifest, with no duplicate manual C# declarations, preserving existing handwritten adapters. Done: one BindingGen run writes `CSharpBindings.Generated.bf` and `CSharpBindings.g.cs` with hashed `CSharpApi_<id>` symbols; handwritten adapters stay separate.
- [x] Verify an annotated method is callable from C#, appears in Roslyn, and a public unannotated member is omitted. Add CI tests for Windows/Linux. Done: BindingGen `--self-test` (deterministic, opt-in: unannotated members are not emitted) and `tools/check_csharp_host_abi.py` run in CI on Linux and Windows; every in-engine check calls generated wrappers.
- [x] Add safe automatic primitive/vector/enum mappings, checked GameObject/Transform handles and UTF-8 string lifetime handling. ECS/Jolt/networking require specialized safe adapters. Done: scalars, bool, Vector2-4/Quaternion/Color, enums, spans, hit records and UTF-8 strings (pinned per call; since November 16 encoded on the stack up to 128 characters).
- [x] Run generation only with engine builds; normal project C# edits compile with dotnet only. Track generated API version to prevent mismatch with precompiled runtime. Done: `tools/build.py` regenerates between its two native passes; game builds only run dotnet. The generated ABI hash is checked on first use (`GeneratedNativeApi.VerifyVersion`), so a game built against another engine fails loudly.

## P2 — gameplay API parity (largest workstream)

For every subsystem, expose a managed public API, safe native handle bridge, correct lifetime/serialization semantics, appropriate network/deterministic scheduling and automated tests. Work in small verified increments:

- [x] Core GameObject/Transform parenting, rotation/scale, scene/object creation/destruction, asset/prefab loading, lifecycle and event callbacks. Done (November 16, 2026): parenting, children, names, tags, layers, active state, create/find/destroy, prefabs and lifecycle callbacks were in place; added `Transform.TransformDirection`, `InverseTransformDirection` and `RotateAround`.
- [x] Component discovery and access: `GetComponent<T>`, `AddComponent<T>`, fields/properties, object/component references, multiple components, enabling/disabling. Done (November 16, 2026): added `GetComponents<T>` (every script of a type, or the built-in one; also a no-allocation `List<T>` overload), `GetComponentInParent<T>`, `GetComponentsInChildren<T>` and `RemoveComponent<T>()` / `RemoveComponent(script)`. Scripts and class components go at the end of the frame (`Scene.RemoveComponentLater`, so a script can remove itself safely), data components (Rigidbody, colliders) at once as in Beef. 11 in-engine checks.
- [x] Flecs ECS: managed data components, filters, typed queries, iteration, systems, group/tags, efficient bulk update, lifetime and thread safety while hiding complexity from typical gameplay.
  - [x] Closed November 17, 2026: `EcsSystem<T1, T2, T3>` (three data types; ownership by T1, as for two; 1
    in-engine check with a system over Charge, Drain and Spark). Systems in other phases are not a C# gap: Beef's
    `NativeSystem<T>` also runs only at the fixed tick, and per-frame ECS work is a `Scene.Query` from a script's
    LocalUpdate in both languages (B11/B12 measured it that way).
  - [x] Typed queries (November 15, 2026): `EcsEntity.Set/Get/TryGet/Has/Remove<T>`, `GameObject.Entity`,
    `EcsEntity.GameObject`, `Scene.Query<A[,B[,C]]>()` with `Count` and `ForEach((entity, ref a, ...) => ...)`
    (`Managed/Tallow.API/EcsData.cs`). The build's generated adapters register each struct's schema id with a
    module initializer (`EcsSchemas.Register<T>`). Native: `World.CanHoldManagedData` (bare C# entities and
    scene objects), `CountManagedData` / `CopyManagedDataPage` / `WriteManagedDataPage` over up to 4 schemas
    (rows packed in order, cached Flecs queries; host entries `Ecs.CountData/CopyDataPage/WriteDataPage`,
    `RemoveLocalData`, `EntityOfObject`, `ObjectOfEntity`). ForEach writes back only rows whose bytes changed,
    and skips entities that went or lost a schema meanwhile. `ecs-data.tsv` keeps fields in declaration order.
    Tests: 10 in-engine checks. Not saved with scenes. Done since (November 15, 2026): `[SyncPosition]` on a
    Vector3 of C# data (relevance, schema field "name:offset:size:p"; network check) and `EcsSystem<T1, T2>`
    (ownership by T1). Since: three data types (below).
  - [x] C# ECS systems, ownership and prediction (November 15, 2026): `class X : EcsSystem<T>` (found by the
    build, registered by the generated module initializer through `Ecs.DescribeSystem`) runs like a Beef
    `NativeSystem<T>`: a Beef `CSharpEcsSystem` adapter in the native system list calls the managed `RunSystem`
    entry (`tn_csharp_run_system`) once for all bare entities (in place, GameObjects' and client-owned ones
    skipped) or for one entity (owned/predicted/replayed). `EcsEntity.SetOwner`, `OwnerClientId`, `IsMine`.
    Unloading the game removes its systems. 3 in-engine and 3 network checks.
  - [x] Query filters and tags (November 15, 2026): `Query<...>().With<F>()` / `.Without<F>()` (up to 4 terms,
    kept in an allocation-free `EcsFilter`; Flecs Filter/Without terms on the cached query), and `[Component]`
    structs with no fields as tags. 4 in-engine checks.
  - [x] [Sync] replication of C# ECS data (November 15, 2026): C# ECS works in network sessions. Each game
    assembly describes its `[Component]` structs when it loads (`EcsSchemas.Register<T>(id, name, syncFields)` →
    `Ecs.DescribeData` → `DataComponents.DescribeManaged`, offsets measured with `Unsafe.ByteOffset`), so a C#
    struct with `[Sync]` fields joins `DataComponents.SyncedTypes` as `CSharp:<full name>` and the native ECS
    replication (NetworkManagerEcs.bf) sends it like a Beef one: bare entities the server makes arrive on clients,
    changes (ForEach in place included) follow, deletes go. A scene registers a described schema on first use, so
    a client can query data only the server sets; clients may read and write replicas' C# data. 4 network checks.
- [x] Jolt physics: rigid bodies, forces, collision/trigger callbacks, raycasts/shape casts, character controls, constraints/joints and physics queries. Done (verified November 16, 2026): Rigidbody fields (mass, gravity, kinematic, friction, bounciness, continuous collision; linear/angular damping, freeze rotation, allow sleeping and debris were missing until November 16 and are now in) and forces/torque/impulses, collision/trigger/stay/controller-hit callbacks, every Beef query (ray, sphere/capsule/box casts, overlaps, CheckSphere/CheckBox), CharacterController, hinge/suspension joints and `Joint.Connect`, soft bodies. Benchmarked in B13.
- [x] Every built-in component field from C# (November 16, 2026): an audit found the components with hand-written C# handles (AudioSource, NavigationAgent/Surface, CharacterController, CharacterMotor, Light, MeshRenderer, Animator, UIDocument, VoxelObject/Terrain, Rigidbody, colliders) were skipped whole by `tools/gen_csharp_components.py`, so ~150 Inspector fields (AudioSource volume/loop/spatial settings, agent turn speed and avoidance, step height, swim settings, terrain generation...) had no C# property. The generator now adds a partial declaration to each with the fields it does not cover (`NativeComponentTypes.GeneratedFields` lists them), and the in-game check round-trips all 412 fields. Collider `isTrigger` stays on `GetCollider().IsTrigger` (it rebuilds the body).
- [x] Native network features surfaced to C#: networked TickInput/actions, authority/ownership, spawning, replication, prediction/reconciliation, rollback, RPCs, lag compensation, relevancy and state sync, working by default.
  Done November 16, 2026, with sessions: `Network.Host/Serve/Join(address)` (how the next scene's Network Session
  starts), `Network.Leave`, `InSession`, `IsConnected`, `ClientIds`, `PlayerObject`, `IsRelevantTo`, and
  `Script.OnClientJoined/OnClientLeft` (ComponentEvent kinds 3-4, mask bits 27-28). 3 more network checks (32),
  1 offline check. Not surfaced on purpose: raw game messages (RPCs and network events cover them) and engine
  internals; ping does not exist in Beef either.
  - [x] (November 16, 2026) Lag compensation: `Script.BeginLagCompensation()` / `EndLagCompensation()`,
    `using (LagCompensated()) { ... }` and `LagCompensationTick` (Beef `NetworkManager.BeginLagCompensation`).
    2 network checks (active in the client's player tick on the server, ends; does nothing on a client).
  - [x] (November 16, 2026) Prediction state hooks: `Script.CapturePredictionState(ref PredictionState)`,
    `PreparePredictionState` and `RestorePredictionState` (Beef NetworkBehaviour's), through a new host entry point
    `PredictionState` and a callback-mask bit so only scripts that override them are called. Over a Rigidbody only the
    two spare vectors are taken back. Network check: a server-only bump of a C# motor's own counter reaches the client
    only through a rollback restore (30 network checks).
- [x] Rendering, materials, shaders/compute graphs, cameras, lighting, mesh/voxel/terrain, animation/IK, sequencer and modeling tools.
  Closed November 16, 2026, after a scripted comparison of every public Beef component method and static service
  against the C# API (below). The modelling tools are editor tools with no gameplay API in Beef either.
  - [x] (November 16, 2026) `MeshRenderer.SetMesh(positions, triangles, normals?, uvs?)` / `ClearMesh` draw a mesh
    built in code (`CSharpMeshes`: one engine-owned mesh per object, reused when rebuilt, freed once the object is
    removed or the game unloads). 1 in-engine check. No Beef Terrain component exists (Voxel Terrain is exposed).
  - [x] (November 16, 2026) Component actions closing the gaps a scripted comparison of every public Beef component
    method found: `Water.HeightAt/DepthOf/Covers/IsFloating`, `VoxelObject.CarveLocal/Fill/ResetShape`,
    `LineRenderer.ClearPositions`, `SkinnedMeshRenderer` layers (`PlayLayer/StopLayer`), parts (count, names,
    materials, colour, hidden, shadow-only) and `BoneAt`, `ComputeEffect.SetVector/SetColor`,
    `CharacterController.Swim`. 8 in-engine checks. Left out on purpose: editor/network internals
    (NetworkIdentity ticks, ApplyRemote, Refresh, ReflectionProbe capture hooks).
  - [x] (November 15, 2026) `MeshRenderer.Material` (networked switch), `SetMaterialValue/Float/Color` on the
    object's own copy, `TryGetWorldBounds`, `IsVisible`, `BackFaceCulling`, `Texture`. Script callbacks
    `OnSequenceEvent`, `OnDialogueEvent`, `OnTreeEvent` for the same object's runners (host entry
    `tn_csharp_component_event`, callback-mask bits 23-25).
  - [x] Animator (November 15, 2026): `Animator` value handle (Play, CrossFade, HasClip, CurrentClip,
    CurrentState, IsFinished, IsInTransition, NormalizedTime, StateTime, Speed, controller parameters and layer
    weights) over `CSharpAnimation` exposures; `GetAnimator()` and `GetComponentInChildren<T>()`. 7 in-engine
    checks; graph nodes come from the catalog.
- [x] Audio/voice, UI/GUI, asset management, navigation/behavior trees, world streaming/world states, persistence/save/load, gameplay time and platform APIs.
  Closed November 16, 2026 with `SaveSystem` (Save/Load handles, Exists, Delete, Slots), `VoiceChat` (microphone,
  Talk, speaking, mute, per-player volume) and `Assets` (Exists, ReadBytes, ReadText; packed files in a built game).
  3 more in-engine checks (327). World streaming is the `StreamingSource` component.
  C# behaviour tree nodes (November 17, 2026): a `BehaviorNode` class (public fields are its settings, `OnStart`,
  `OnTick` returning Running/Success/Failure, `OnEnd(aborted)`, `[BehaviorNode]` for title, category, condition and
  a stable `Key`) is registered by the build's generated module initializer and offered to the editor through
  `.tallow-csharp/behavior-nodes.tsv`. Each running node has its own instance (BTManagedNode on the Beef side, one
  new `BehaviorNode` host entry point). Trees keep nodes whose kind is not registered (they fail until it is)
  instead of dropping them on load. `Blackboard` reads and writes from scripts. 6 more checks (370). The settings
  are filled by reflection, which the parked NativeAOT stage would need generated instead.
  - [x] (November 16, 2026) Platform services over `CSharpPlatform` exposures (`Platform.cs`): `Gamepad` (buttons,
    axes, sticks, kind, name, Rumble), `Touch.Fingers`, `Screen.Fullscreen`, `Quality` (Level, Recommended, Set),
    `Achievements` (Unlock, IsUnlocked, SetProgress, Clear, stats), `Subtitles` (Show, Caption, Hide),
    `DialogueVariables` (Get/Set/Add, Evaluate), `Decals.Spawn/Clear` (pooled marks) and `Wind.At/Gusts`.
    Sessions: `Network.Host/Serve/Join/Leave`, client lists, `OnClientJoined/OnClientLeft`. 8 in-engine checks.
  - [x] UI documents with C# code-behind (November 15, 2026): onclick/onchange/onload call a C# script's
    method on the same object (taking nothing, a `UIElement` or the element's id; host entry
    `tn_csharp_ui_invoke`), and bind="field" reads and writes its public fields. `UIDocument`/`UIElement`
    handles (Find, Text, Visible, Value) over `CSharpUI` exposures. 6 in-engine checks (onload, headless).
  - [x] Audio one-shots (`Audio.PlayOneShot`, `PlayOneShot2D`), `InputActions`, `NetRandom`, `Time.GameTime`.
  - [x] Network prefabs (November 15, 2026): `Network.RegisterPrefab(name, path)`, `Scene.Spawn(prefab, position,
    rotation, ownerClientId)` and `Scene.Despawn` over `CSharpNetwork` exposures; 5 network checks (spawn for a
    client, ownership, despawn, client refusal). Fixed `NetworkManager.RegisterPrefabFile`, which built its factory
    from `Prefab.Instantiate` (shared the object a second time on the server and destroyed it on clients; the same
    code is on `ecs`).
  - [x] Spawning, layers, world states, navigation queries and joints (November 15, 2026): `SpawnPoints`
    (Next, Random, Place, TryGet, Count, StartWindow, BeginStart/EndStart, IsStartPhase), `GameObject.Team`,
    `Layers.Named/Name/Mask`, `WorldStates.Named/Name`, `Scene.WorldState/SetWorldState`, `NavigationSurface`
    (Find, SamplePosition, RandomPoint, Raycast, Rebuild), `Scene.CreateHinge/CreateSuspension` returning checked
    `Hinge`/`Suspension` handles (native joints stay behind a number + generation table, `CSharpJoints`), and
    `AudioSource` (Play, PlayOneShot, Pause/Resume/Stop, IsPlaying, Length, Time) with mixer settings and group
    volumes. 15 in-engine checks.
  - [x] (November 15, 2026) `Network.ChooseTeam` (server; host entry `tn_csharp_choose_team`, falls back to the
    session's even split when it throws), `Script.OnWorldStateChanged(from, to)` (only overriding scripts
    subscribe), `Scene.SetWorldState(int)` (`Scene.WorldState` is read-only: a script's `Scene` is a value, so a
    setter could not be called). Game unload clears C# ECS systems and the team chooser.
- [x] Inspector: add string, enum, arrays/lists, serializable nested types, asset/GameObject/component references, undo/redo, prefab overrides and validation. Current user-confirmed subset is numeric/bool/vectors and persistence.
  - [x] (November 15, 2026) Strings, enums and GameObject/Transform/component/script references were already done.
    Added `double`, `uint`, `long`, `Color` (colour picker) and `List<T>` / `T[]` of any of those kinds (kind
    `list:<kind>` in fields.tsv; value "count;item;item" with `;` and `\` escaped; editor rows with + and -).
  - [x] (November 15, 2026) Nested `[Serializable]` structs and classes of the game's own ("Outer.Inner" rows,
    four levels, defaults from an enclosing `new() { X = 1 }` first), `[Asset(AssetKind.Prefab)]` string/list
    fields (the Beef asset picker; column 8 "asset:<kind>"), and undo/redo of C# field edits (already covered by
    scene-snapshot undo; `--csharp-inspector-test`, run by `tools/test_csharp_ingame.py --editor`, needs a display).
    Not yet: prefab-override markers (the editor has none for Beef components either).
  - [x] (November 16, 2026) Lists and arrays of `[Serializable]` classes and structs: kind `list:record`, column 8
    the item's value-kind fields ("Name~kind~default~options" joined by '|', enum names by '/'); each item is
    "Name=value" parts joined by ';' and escaped again inside the list's own format, so renamed or missing item
    fields fall back to their defaults. The Inspector draws each item's fields with a label; + copies the last
    item (or the defaults). 3 in-engine checks (scene → fields, live read-back, catalog). Item fields that are
    themselves nested types, lists or references are not shown yet. The editor drawing is not visually checked.
  - [x] (November 16, 2026) A field's `///` doc comment (its `<summary>`, tags dropped, `<see cref>` names kept)
    is the Inspector label's tooltip: Tallow.Build writes `.tallow-csharp/field-docs.tsv` (class, field, text;
    nested "Outer.Inner" fields too) and the editor reloads it with the field catalog. 1 in-engine check.
  - Closed November 16, 2026: validation is `Script.OnValidate` (called after an Inspector edit, tested). Prefab
    overrides need an engine-wide per-instance override system; the editor has none for any component, so it is
    not a C# gap and is left to the editor roadmap.
- [x] High-quality XML API docs, editor tooltips, C# script templates, practical gameplay examples, and repeatable Beef-versus-C# parity tests.
  Closed November 17, 2026: every public Tallow.API member has a `///` summary (the 40 that had none were written;
  enum values like `KeyCode.A` are left to their names), kept so by `tools/check_csharp_api_docs.py` in CI. Hovering
  a name in the code editor now shows its summary under the signature (it was only in completion); a Roslyn test
  checks it (134). Templates (Create > C# Script, the project templates), gameplay examples (every doc's C#,
  compiled in DocSnippets.cs) and the Beef-versus-C# benchmarks (`Samples/EcsBench` against `Samples/CSharpBench`,
  docs/csharp-benchmark-plan.md) were done before.

## P3 — convert visual scripting and sample content

- [x] Preserve existing visual graphs and nodes while generating C# instead of native Beef gameplay code
  (November 15, 2026, stage 1). In a C# project the graph compiler writes `Name.cs` beside `Name.tgraph`
  (a `public partial class Name : Script` in the folder's script namespace). `GraphCSharp.FromBeef` turns the
  Beef node code over (types, `let`, `.(`, `scope`, vector/colour members, float maths, enum shorthand, null
  handles); nodes it cannot handle carry their own C# with `NodeDef.Cs(...)`. All 294 hand-written gameplay
  nodes plus the flow and overload test graphs compile with no errors or warnings (`--graph-node-test "*"` in a
  C# project, then Tallow.Build). New Tallow.API pieces for graph code (and games): `GraphRuntime`, `GraphHit`,
  `Audio`, `InputActions`, `NetRandom`, `Time.GameTime`, `Mathf.PI`, and C# 14 extension members
  (`Vector3.Up/Forward/Right...`, `.Normalized`, `Quaternion.Euler/AngleAxis/LookRotation`, `.EulerAngles`,
  `Quaternion * Vector3`). Dropping a graph on an object attaches its C# script; package export brings the
  `.cs`; the Project panel hides it; Convert to Script and View Generated Code use it. Headless:
  `TallowLauncher --graph-compile <graph> <namespace>`. Test: `Tests/CSharpInGame/src/Scripts/GraphProbe.tgraph`
  is compiled again by the in-engine test, compared with the checked-in `GraphProbe.cs`, and run (7 checks).
  Graph object variables are Inspector reference fields (see below). `--graph-compile` finds the project's
  subgraphs under `src/` as the editor does (GraphProbe calls `Doubled.tgraph`; a value subgraph that always
  returns no longer gets an unreachable `return default;`; a graph outside any project no longer crashes the walk
  up to `/`). For Each Data (ECS) nodes came in stage 2 (below).
- [x] Automatic C# type/method node discovery (stage 2, November 15, 2026): after every build (also a failed one)
  Tallow.Build writes `.tallow-csharp/graph-nodes.tsv` (`GraphNodeCatalog`, from the Roslyn compilation of the
  game and Tallow.API): a node per public property, field and method of Tallow.API's gameplay static classes,
  GameObject, Transform, Scene, Script, the physics handles and the game's own public types, with enum pins
  (members listed in the catalog). The editor loads it in C# projects; `--graph-node-test @api` sweeps them (236
  in the scratch project, all compile). The probe graph uses two of them at run time. Graph error source mapping: C# graphs end each node's
  statement with `// #<node id>`; a compile error in a graph's generated `.cs` is reported on the graph and node
  ("graph (node \"Print String\"): error CS..."), and clicking it in the Console opens the graph with that node
  selected (`--script-files-test` checks the mapping). C#-to-graph: a graph's custom events and variables are
  public members of its partial class, so C# calls them (`graph.Custom_Bump()`, checked in-engine) and other
  graphs get them as catalog nodes. Networking nodes (Is Owner, Is Server, In Session, Send Network Event,
  Network-Safe Random) compile to the Tallow.API equivalents. ECS nodes for C# `[Component]` structs (from
  `ecs-data.tsv`, same keys as the Beef ones): Has/Add/Remove Component, Get/Set per field, and For Each, which
  compiles to `Scene.Query<T>().ForEach` over active GameObjects (GraphProbe's Heal event is tested).
- [x] Permit graph-to-C# calls, C#-to-graph events/operations, automatic C# type/method node discovery, managed ECS & networking nodes, and correct graph errors/source mapping.
- [x] Convert the legacy starter projects, sample/voxel sandbox/showcase content, tutorial code and code-generation templates; newly created projects should not expose Beef to normal C# authors.
  Closed November 17, 2026: every project template (empty, common, showcase) and `Samples/Sandbox` is C#, new
  projects have no Beef files, and every gameplay doc's code is C# (kept compiling in DocSnippets.cs). Beef is left
  only where it is meant to be: `Samples/EcsBench` (the Beef side of the benchmarks) and docs about engine and editor
  tooling. Website tutorials are their own item (below, under Open questions).
  - [x] Voxel sandbox template (November 15, 2026): its scripts are C# (Editor/templates/common/Scripts:
    Spinner, FollowCamera, Digger, Hud, CharacterAnimation, SampleMenu); no Program.bf, GameSetup.bf or
    BeefProj. The player is a prefab (Prefabs/Player.tprefab, written by the first open, set as the Network
    Session's player prefab) instead of a code factory. New C# APIs for it: `GUI.Label/Box/Bar/Toggle/Slider`,
    `GUI.MouseOverControl`, `VoxelObject.Carve`, `VoxelTerrain.Find/ModifySphere`, `CharacterMotor.Yaw/Pitch`,
    `Scene.NetworkTick`. `tools/test_csharp_sample.py` creates the project and checks 10 things in play (CI).
  - [x] Built-in components from C# (November 15, 2026): `NativeComponent(gameObject, "Tallow.Light")` reads and
    writes any Inspector field by name as scene-file text (`CSharpNativeComponents`; references and lists
    excepted), and `AddComponent<T>()` now takes built-in handles as well as scripts. Typed handles on it:
    `Light`, `MeshRenderer`, `SphereCollider`, `BoxCollider`, Rigidbody `Mass`/`UseGravity`/..., CharacterController
    `Radius`/`PushStrength`, `UIDocument.Document`; plus `NavigationAgent`, `GameObject.Transient` and
    `CommandLine`. 8 in-engine checks (137).
  - [x] A script that throws every frame is reported once even when other failures come in between (before, any
    other error made it print again; the log only merged identical neighbours).
  - [x] Tallow Gallery (showcase) template (November 15, 2026): its gameplay is C# (Scripts/Gallery.cs, Visitor.cs,
    GalleryCrowd.cs); no Program.bf, GameSetup.bf or Beef project files. The scene's Network Session (Offline,
    no player prefab; --host/--connect override it) replaces the hand-made session start. The test switches
    (--view, --fire-test, --cut-test, --net-report, --self-test) are kept; `--author-scene` and the Beef scene
    builder are gone (in history up to c488b75f). The crowd's "system" half is one C# script over a packed
    array. New APIs: `Network.Report(scene)`, `Scene.ObjectCount`, `Scene.CountComponents(typeName)`,
    `VoxelTerrain.ChunkCount/PendingChunks`. Checked locally: --self-test (SHOWCASE_READY rooms=8 probes=2),
    the test switches, and a host plus a client sharing 43 objects. `tools/validate_showcase.py` (release
    packages) now plays it in the packaged player; not run here, as it needs a package.
    `tools/test_csharp_showcase.py` creates, compiles and plays it with the test switches (CI).
  - [x] Create > C# Script templates (November 15, 2026): the GUI / HUD template draws a working health bar and
    button with the C# GUI API; the ECS templates use `GameObject.Entity` and `Scene.Query`.
    `TallowLauncher --write-script-templates <folder>` writes one script per template without a window (also
    the editor's `--script-templates-test`); tools/test_csharp_sample.py compiles them all with no warnings.
  - [x] `Samples/Sandbox` (November 16, 2026): its Beef scripts (Program.bf, GameSetup.bf and 11 scripts) are
    gone; the template's C# scripts plus C# `Wanderer`, `NoiseMaker` and `BallLauncher`; scene components became
    C# script components with the same values; the player is `Prefabs/Player.tprefab` (Network Session player
    prefab), as in a new sample project. A leftover scratch `Test` object was removed. New APIs for it:
    `NavigationAgent.IsCrossingLink`, `AINoise.Make`, `Rigidbody.ContinuousCollision`; setting a new
    rigid body's `Velocity` makes its physics body at once (before, it was ignored until the next step). All 11
    scenes play headless with no errors (not looked at in a window). `Samples/EcsBench` stays Beef on purpose:
    it is the Beef side of the Beef-versus-C# benchmark.
  - [x] Docs (November 15–17, 2026): about 45 docs had Beef code. Converted, with every C# block kept compiling
    in `Tests/CSharpInGame/src/Scripts/DocSnippets.cs`: animator, physics-queries, character-controller, input,
    saving, scenes. APIs added for them: `Scene.CapsuleCastHit/BoxCastHit`, `SphereCastHit(..., ignoreBody)`,
    `CheckSphere/CheckCapsule/CheckBox`, `OverlapSphere/OverlapCapsule/OverlapBox` (objects, each once),
    `Rigidbody.BodyId`, `CharacterController.SetBox/SetCapsule/AirTime/IsOnSteepGround/GroundNormal/GroundVelocity`,
    `InputActions.CaptureBinding/BindingName/ToText/LoadText/Describe/FromGamepad/SetMapEnabled`,
    `Scene.LoadAdditive/Unload`, `GamePaths.PlayerData` (14 in-engine checks). Engine-only parts (physics capacity,
    custom SaveStorage, DataAsset classes) stay Beef and say so. Fixed on the way: C# `[Saved]`/`[Sync]` reference
    fields are no longer written (ids are local to a run and a machine). Website tutorials wait for the user.
- [x] Keep shader graph/compute graph/rendering functionality intact; never confuse visual **gameplay** source generation with native shader compilation.
  Closed November 17, 2026: shader and compute graphs are generated by `Editor/src/Graph/ShaderGraphCode.bf`, which
  the C# work never touched (only the gameplay graph compiler, `NodeGraph.Compile`, gained C# output). B16 measured
  shader-graph materials and the ripple compute graph set up from C#: the same draws and dispatches as from Beef.

## P4 — performance, reload, shipping exports, hardening

- [x] Measure cold compile, warm single-file edit, no-op compile, incremental assembly build and edit-to-Play. Compare with legacy Beef workflow and relevant older/current Unity baselines without promising a specific speed.
  - [x] (November 18, 2026) Edit-to-Play in the editor (`tools/run_save_to_play_bench.py`, editor
    `--save-to-play-test N`; Samples/Sandbox): **save, then Play 1.09 s** (median of 5; the build 1.01 s, Play itself
    5 ms). Fixed on the way, which halved it from 2.58 s: the editor's file monitor took the editor's own save for an
    outside change and queued a second full build, and each build also ran a no-op `dotnet build` of the engine's
    Tallow.ManagedRuntime (now only when its sources are newer, `Terminal.ManagedRuntimeCurrent`).
  - [x] (November 16, 2026) Benchmarks B02/B03/B08 measured, B06/B13 first pass (results and fixes in
    `docs/csharp-benchmark-plan.md`): `GetComponent<T>` 10× faster and allocation-free (generated bindings encode
    strings on the stack, native `Has` and type-name lookups no longer scan), built-in component field reads
    allocation-free. New `CSharpBench`/`EcsBench` modes: getcomponent, physics, lifecycle.
- [x] Incremental C# per-`.tasmdef` builds with correct dependency invalidation, diagnostics and simultaneous builds; avoid unnecessary full-game builds on every edit.
  - [x] (November 15, 2026) Verified: each `.tasmdef` is its own MSBuild project, so an edit inside one rebuilds
    only its DLL, and a public API change also rebuilds the assemblies referencing it (reference assemblies).
    `tools/benchmark_csharp_compiles.sh` now has `leaf-edit` and `api-edit` phases that fail if other DLLs are
    rebuilt. Fixed overhead dominated (every phase ~1.2 s on the test fixture): the editor and launcher ran
    `dotnet run --project Tallow.Build.csproj`, re-checking the tool each compile; they now start its built DLL
    when it is newer than its sources (`Terminal.AppendBuildTool`): a launcher build went from ~1.6 s to 0.85 s
    (Tallow.Build: ~0.35 s generating, ~0.25 s `dotnet build`, the rest the catalogs).
  - [x] (November 17, 2026) Simultaneous builds: Tallow.Build holds `.tallow-csharp/build.lock` (exclusive) for a
    build, so the editor, the launcher and a command line building the same project at once take turns instead of
    writing the same generated projects and obj folders together (the second prints that it is waiting, up to five
    minutes). The lock goes with the process if it dies.
- [x] Game assemblies (and their .pdb symbols) load from in-memory copies, so Windows no
  longer holds `Tallow.Game.dll` and asmdef DLLs locked after Play and the next compile can
  replace them. Verified on Windows November 18, 2026: CI's native Windows job (Debug Win64 editor build, the
  Beef leak check on) runs the in-engine, network, hot-reload, Voxel sample and Gallery suites, all passing (run
  44250231183). Fixed to get there: a crash dialog that hung unattended runs, a graph-catalog leak, `Platform=x64`
  output folders, leak-check false positives for component text kept in Flecs, and DataAsset backslash paths.
- [x] Implement reliable collectible AssemblyLoadContext hot reload, cleanup of managed tasks/timers/events and native handles, Inspector field/state preservation, resource unload and no editor crash; test multiplayer determinism.
  - [x] (November 15, 2026) Hot reload while playing: saving a C# file during Play (reload mode not Manual)
    compiles, then between frames `CSharpRuntime.ReloadGame` loads the new Tallow.Game in a new collectible context
    first (the old keeps running if that fails), moves each running script to its class in the new code under the
    same instance ID (`ScriptTable.Replace`), restores every field the Inspector format can carry (private and
    auto-property fields too; not `[NonSerialized]`/readonly; new fields keep their initializers; references to
    scripts point at the new instances), and unloads the old context. Awake/Start do not run again; callback
    lists are rebuilt (a newly overridden Update runs); ECS systems are made again by the new assembly (same data);
    a script whose class is gone gets OnDisable/OnDestroy in the old code and stops (warning names it). Host entry
    `tn_csharp_reload_game`. Test: `tools/test_csharp_reload.py` (Tests/CSharpReload v1 -> v2/Scripts, 13
    checks, in CI). Not yet: the team chooser and pending awaits are dropped (set again after a reload), fields of
    types the Inspector cannot write (dictionaries, arbitrary classes) restart at their initializers, a reload
    only changes this machine's code in a networked session, the editor path (save -> compile -> reload) is not
    automated (needs a display).
  - [x] (November 16, 2026) Fields are carried as objects, not Inspector text (`ReloadMigrator`): dictionaries
    (with a system comparer), sets, queues, stacks, arrays, readonly collections, tuples, game classes and structs
    matched by full name in the new assemblies field by field (a new field keeps its initializer, the new
    constructor runs), shared objects and cycles copied once, enums by member name, int <-> float conversions,
    lists of scripts pointing at the new instances. Delegates, tasks and timers of the old code start again quietly;
    a field whose type changed or was removed starts again and a warning names it. Floats are now exact (no text
    round trip). `TALLOW_RELOAD_UNLOAD_CHECK=1` checks the old code unloads. Editor path automated:
    `--hot-reload-test FOLDER` (types v2 into the code editor and saves during Play; ~2.1 s save-to-reload here),
    step 6 of `tools/test_csharp_editor.py`. Reload test now 27 checks. Networked sessions: see November 18 below.
  - [x] (November 16, 2026) Delegates to named methods carry over: each method is found by name and parameter
    types in the new code, bound to the new instance (`ReloadMigrator.Rebind`), so events and callbacks kept in
    fields call the new code; `Network.ChooseTeam` is kept the same way. Lambdas and local functions still start
    again (their compiler-made names can move to another lambda between versions; a chooser lambda warns to set
    it again). Reload test 29 checks (editor path 27).
  - [x] (November 18, 2026) Awaits across a reload: an async method's state belongs to the code it was compiled from,
    so the old code's awaits cannot carry on in the new code (no engine moves them). They now end cleanly and are
    named: the reload sets the old continuations and game-time waits aside first (`GameThread.Detach`), puts them
    back when the new code fails to load (the old code keeps running with its loops), and otherwise ends them without
    running old catch/finally blocks on moved objects; the Console names the scripts ("awaits of the old code ended
    (Spawner x2)"). New `Script.OnReload()` runs in the new code on every moved script, fields already carried over,
    to start async loops again. API hooks (scene-load polling, anti-cheat, voice, host changes) now survive a reload
    (they were cleared with the awaits). Reload test 33 checks (editor path 30).
  - [x] (November 18, 2026) Hot reload in a network session. Code is never sent over the network: every machine builds
    its own, and Tallow.Build writes the code's ID beside Tallow.Game.dll (`Tallow.Game.codeid`: SHA-256 of each game
    assembly's name, references, packages and sources relative to src, line endings ignored, so other folders,
    Release builds and Windows/Linux checkouts of the same sources agree). The host sends its ID to each client on
    join and after each hot reload (`CSharpNetReload`, engine message 235). A client that builds a change keeps it
    until the host reloads the same code, then follows at once; one that builds the code the host already runs reloads
    immediately; a client on other code is warned once per change (also at join). Clients reload when the host's
    message arrives, a few ticks after the host (snapshots and lockstep resyncs cover the gap). A build without an ID
    keeps the old "this machine only" warning. Test: `tools/test_csharp_network_reload.py` (server + 2 clients, 7
    checks, in CI): the early client waits, follows, runs version 2, the server's [Sync] value comes from version 2,
    a late joiner on version 1 is warned. Launcher `--csharp-reload-after S` reloads on real time (headless runs
    frames uncapped).
  - [x] (November 16, 2026) File > Reload Scripts (Ctrl+R) and the code editor's Compile & Reload now hot-reload a
    C# game during Play (they only compiled before; the menu said "Native C# Play integration is in progress"),
    also with the reload mode Manual, where a save does not reload. Editor step 6b (`--hot-reload-manual`).
- [~] Package precompiled per-platform player/engine plus C# assemblies, runtimeconfig, .NET runtime/dependencies, shaders and assets into independently redistributable Windows/Linux exports. Verify on machines without BeefBuild.
  Linux done: `Player/` is the engine without the editor (its own Beef workspace, since one
  workspace shares generic code with the editor), exporting its generated API symbols.
  `tools/build_player.py` builds a C# project (no BeefProj) with it: Release assemblies via
  `Tallow.Build --configuration Release --output`, `Managed/Runtime` + `Managed/Game`, and the
  .NET runtime bundled in `dotnet/` (73 MB; `--no-bundle-dotnet` to skip), which the host then
  uses exclusively. Engine packages carry the prebuilt player and the built managed runtime;
  a game exported from a package with no BeefBuild on PATH passed all 82 in-engine checks.
  `tools/test_csharp_export.py` (CI) checks the CLR came from the bundle. Fixed on the way:
  hostfxr folders with pre-release names were skipped.
  - [x] (November 16, 2026) Windows export. Built on Linux, `build_player.py --platform windows`
    bundles Microsoft's Windows x64 .NET runtime of exactly the version the game compiled
    against (from the official release list, SHA-512 checked, cached once in
    `~/.cache/tallow/dotnet-runtime/`; 82 MB). A C# game needs only the precompiled
    `TallowPlayer.exe`: with it present (Linux engine packages now carry it when it was built)
    no Wine, Windows Beef or native-win libraries are needed, and the editor's Build window
    offers Windows for C# games. `test_csharp_export.py --platform windows` builds it and runs
    it under Wine: 311 checks pass on the bundled runtime, as on Linux; the editor's Build
    window (`--build-window --build-windows --build-now`) made the same build. Fixed on the way:
    the editor's Build wrote Beef build files into C# projects first, so `build_player.py`
    took them for Beef projects (a project is now Beef only with `.bf` sources); a build asked
    for during the opening script check now starts when the check ends instead of being
    dropped. Not done: a run on a real Windows machine (only Wine so far), a Windows export
    in CI (needs the Windows player built there), macOS/web, trimming the bundled runtime.
- [x] Confirm no unsafe untrusted mod loading, directory escape, premature engine pointer exposure or unmanaged ownership errors.
  - [x] (November 15, 2026) Review. Fine as it was: only `Tallow.Game.dll` is loaded by name, from the editor's
    build folder or a built game's Managed folder (no mod loader); the native resolver and function pointers are
    internal (Tallow.API grants internals to Tallow.ManagedRuntime only); every native call that fills a C# buffer
    clamps to the span's length and returns the full length; ECS byte copies require the schema's exact size and
    pages are capped; save slot names become file names with separators and leading dots escaped; Tallow.Build
    checks .tasmdef names, package ids/versions and that sources stay inside their folder. Fixed: `Engine.Bind`
    was public (a script could replace the engine bridge for every other script; now internal, in-game check);
    assembly references are only resolved for plain names (never a path); a [Sync] value received from the server
    or a [Saved] value read from a save that holds a line break is refused (it would have become extra
    "name\tvalue" lines setting fields that are not [Sync]/[Saved]). Game C# itself is trusted, full-trust .NET:
    a script can use System.IO; nothing here is a sandbox.
- [x] Extend CI beyond managed/.NET host smoke tests to native Beef editor/launcher builds, precompiled player startup and real C# in-scene integration tests on Linux and Windows.
  - [x] Linux: the native-editor-linux job compiles the engine, editor and launcher with the pinned Beef compiler
    and runs the in-engine suites (in-game, network, hot reload, sample, Gallery) and a release export played on its
    own bundled .NET.
  - [x] Windows (November 17, 2026): native-editor-windows builds natively as the release workflow does (clang-cl,
    Beef's Windows build) and runs the same in-engine suites, including hot reload (game DLLs loaded from memory, so
    not held locked). Passing since run 44250231183 (November 18, 2026).

## Migration benchmark backlog — run locally on Nobara

The benchmark definitions, workloads, evidence format, and priority order are
in [**C# migration benchmark plan**](csharp-benchmark-plan.md). B01–B05 and
B07–B17, B18 (multiplayer sync: the same state hash, bandwidth and errors in both languages at 2–16 peers, 0–200 ms
and 0–5% loss; C# server ticks 2–3% slower) and B23 (a 45-minute host/client soak: flat memory, no leaks, no errors)
are measured (November 16–17, 2026); B06 (100 Play/Stop cycles up to 10,000 scripts; waking 10,000 scripts went
from 531 to 45 ms), B20 (the same replay hash in both languages, rollback alike), B21 (graphs: same output, same
event order, C# at the hand-written ratio), B22 (exports run sandboxed with no Beef, SDK or compiler; Windows under
Wine) and edit-to-Play (1.09 s after two editor fixes) on November 18; B19 belongs to ShatterLock. B24–B30 belong to the parked
NativeAOT stage (P5). Include real frame-time p50/p95/p99, CPU and Jolt
costs, managed GC allocations, RSS, compile/edit-to-Play timings, and raw logs.
Benchmark both C# and native Beef on the *same Flecs/Jolt scenes* rather than
comparing unrelated scripts. Physics tests must record sleeping bodies. The
native-host `--benchmark` is an interop microbenchmark, **not** an FPS claim.

**Do not block migration coding on unavailable hardware:** implement and test
each native/managed feature independently, then mark relevant benchmark cases
complete after the user supplies full-editor or game results. Avoid destructive
Git resets, edits to user projects, or claims that the complete conversion has
passed until acceptance cases and cross-platform export/visual scripting pass.

## Required acceptance test before merging into ECS/main

1. A user without BeefBuild opens Tallow precompiled editor and new C# project, creates a script, attaches via menu or drag/drop, edits a public field, saves/reopens, and runs Play.
2. C# `Vector3` operators compile and autocomplete/highlight correctly; inherited API methods appear automatically.
3. Broken C# project always opens for repair; compiler errors appear in Console and code editor; Play waits until a successful .NET build.
4. Compile-success banner disappears in one second without hiding failures.
5. Enter/exit Play repeatedly and standalone `--game` without crashes, stale data or leaked CLR state.
6. ECS, Jolt, networking, visual scripting, and export parity meet tested native behavior.
7. Windows/Linux release export runs with **precompiled** engine/runtime without requiring BeefBuild/Python for ordinary gameplay development.

## Commands / sources

Local checkout: `~/GitWorktrees/tallow-csharp`. Build once after **engine changes**:

```bash
cd ~/GitWorktrees/tallow-csharp &&
git pull --ff-only origin feature/csharp-gameplay &&
./build.sh --config Debug --jobs 8 &&
./build/Debug_Linux64/TallowLauncher/TallowLauncher
```

After editor has been built, project operations should not run BeefBuild:

```bash
./build/Debug_Linux64/TallowLauncher/TallowLauncher --open /path/to/MyGame
./build/Debug_Linux64/TallowLauncher/TallowLauncher --build-project /path/to/MyGame
./build/Debug_Linux64/TallowLauncher/TallowLauncher --game --project /path/to/MyGame
```

Managed checks from repository root:

```bash
dotnet build Managed/Tallow.LanguageService/Tallow.LanguageService.csproj
dotnet run --project Managed/Tallow.Build/Tallow.Build.csproj -- --project Tests/CSharpGameplay --engine-root .
```

CI: `.github/workflows/csharp-gameplay.yml`. Main implementation: `Managed/Tallow.API`, `Managed/Tallow.Build`, `Managed/Tallow.ManagedRuntime`, `Managed/Tallow.LanguageService`, `native/tallow_dotnet_host.cpp`, `Engine/src/Scripting/CSharpRuntime.bf`, `Engine/src/Scripting/CSharpBehaviour.bf`, `Editor/src/Scripts`, `Editor/src/Panels`, `Launcher/src/Program.bf`.

**Maintenance rule:** As work is verified, check items off and add exact commit SHA/test evidence, distinguishing CI-only success from actual full editor/Nobara confirmation. Continue highest-priority unchecked item in a new chat; don't start over.

## C# physics and soft-body bridge (initial)

- `Physics` is an annotated Beef API class using the **same** Jolt world,
  existing ECS-backed `Rigidbody` handles and original `SoftBody` components.
- Every native method takes the opaque Play-session ID and GameObject ID,
  validates both in `CSharpRuntime`, and returns value types only. Nothing
  retains a Jolt/body/vertex pointer or constructs a managed physics world.
- C# gameplay can call `GetRigidbody()` or `GetSoftBody()` on a Script or
  GameObject and receive a light value handle. Supported operations: velocity
  get/set, impulses, one-tick forces, soft-body pressure (with native rebuild),
  shell dent repair / depth, and a first raycast-distance query.
- `SoftBody` includes free jelly and cloth, dentable shells and DrivenJelly.
  The native implementation refuses impulse/force calls for Shell/DrivenJelly
  instead of silently reporting success. Server-authoritative shell repair
  follows the existing Beef/network path.
- **ECS caveat:** Rigidbody is already ECS-backed; SoftBody is currently a
  native class component and is **not** silently converted to Flecs. Dedicated
  ECS batching and structured RaycastHit results still need generator support.
- Added managed/Roslyn compile tests for the generated API and a gameplay
  sample. Linked native Beef CI verification remains necessary.

- Added standalone native-host physics ABI validation for the generated Rigidbody force, free SoftBody impulse, pressure get/set and raycast-distance calls. It validates scene IDs, vector component order and native callback dispatch; it does not replace linked Jolt integration tests.

### Native ray and sphere contacts (next physics increment)

Native Jolt raycasts and sphere casts now expose **point + distance in one
query** through generated `Vector4` value ABI, decoded by the C# scene facade
as nullable `PhysicsContact`. An invalid/missing hit is represented by a
negative distance. No native object pointers cross the API. The richer
`RaycastHit` fields (collider entity, normal, shape body id) await generated
structured-result support; no normals are fabricated. Both operations
accept layer masks. The C# SoftBody value handle also has read-only
`Kind` (Cloth/Jelly/Shell/DrivenJelly), `SimulatedVertexCount`, and
`IsSleeping` metadata. Native-host ABI checks cover contact component order
and the soft-body mode/vertex data.

### Structured native Jolt hit ABI

`[CSharpExpose]` now supports **one explicitly approved, blittable result
struct**: `PhysicsQueryHit` (48 bytes on both managed platforms). Generated
Beef wrappers write the result by pointer; generated C# wrappers allocate it
on the stack and return the value. No raw native pointers or owned objects
cross into managed gameplay. The public `Scene.RaycastHit` and
`Scene.SphereCastHit` facades decode it into nullable `PhysicsHit` values
with position, distance, nullable hit `GameObject`, optional surface normal,
penetration depth and body ID. **Ray normal is intentionally null** because
the current Beef `RaycastHit` doesn't report one; sphere sweeps carry Jolt's
actual contact normal. The generator rejects arbitrary unmanaged structures
and structured parameters until per-type reflection/layout validation exists.

- The managed native-host smoke now checks 48-byte struct packing and real data/nullable flags: ray hits carry their collider entity but no invented normal, sphere hits carry the Jolt normal, penetration and body ID. Native CI also verifies both generated Beef symbols are actually callable.

### Indexed collider inspection and soft-body tuning

C# gameplay now sees the engine's original **class** colliders as
`GameObject.ColliderCount` and nullable `GetCollider(index)` value handles,
with box/sphere/capsule dimensions and local centers. The handles retain
collider attachment order, including duplicate kinds stacked on one object,
and only contain the session-scoped GameObject ID and an index. They do
not turn class colliders into ECS handles or expose native pointers.
The native API also supports soft-body `Stiffness` (0–1) and
`WobbleDamping` (0–20) getters/setters using `[CSharpExpose]`.
Parameter updates require native `SoftBody.Rebuild()`, so they are intended
for deliberate configuration, not for changing every physics tick.

- A native-host ABI regression checks collider index order and per-shape dimensions (including invalid indexes), along with validated native soft-body stiffness and wobble-damping updates and rejection of invalid settings.

### ECS-backed native joints from C#

The existing `Joint` handle in Beef is an ECS `ComponentHandle<JointData>`
backed by Jolt constraints. C# now exposes `GameObject.GetJoint()` and a
lightweight nullable `Joint` facade with `IsConnected`, `ConnectedTo`, and
`SwingLimit` (0–179 degrees); setting the swing limit calls the real
native `Joint.Rebuild()`. `Joint.Connect(rigidbodyA, rigidbodyB, anchor,
axis, limit)` delegates directly to Beef `Joint.Connect` after validating
both objects are in the same active scene and have Rigidbody handles. Joint
creation is **local to the machine** in the current native engine;
multiplayer games must coordinate creation explicitly. The C# API does not
claim automatic replication of dynamically created joints.

- The native-host Jolt joint binding smoke checks ECS JointData connection status, target Rigidbody entity, bounded swing-limit changes and a two-vector native Connect call. The C++ host validates exact vector component order and rejects self-joints; it does not imply automatic network replication.

### Native Rigidbody angular-motion parity (2026-11-13)

- The existing ECS-backed Beef Rigidbody now supplies C# with world-space
  angular velocity get/set, torque, force at a world point, velocity at a
  world point (including spin), and Sleep. All six operations use explicitly
  annotated `Tallow.Physics` methods and generated native/managed ABI,
  never new handwritten P/Invoke bindings. Native code validates the active
  Play session, entity, presence of a physics body, and finite vector inputs
  for new mutations. The lightweight C# value handle never owns a Jolt pointer.
- The fixed C# exposure fixture, managed gameplay integration smoke, and
  C++ native-host dispatcher verify component order, vector argument order,
  pointer-based vector return values, and effect counts. This is ABI smoke,
  **not** a complete linked Jolt/Beef physics simulation test. Full native
  CI and interactive Nobara verification remain required.

### Native Jolt character controller through C# (2026-11-13)

- The original Flecs `CharacterController` handle and Jolt virtual character
  can now be accessed through `GameObject.GetCharacterController()` and
  `Script.GetCharacterController()`. A lightweight managed value handle exposes
  valid/active state, grounded/jump conditions, velocity, `Move`, `SimpleMove`
  (native gravity/steps/slopes/jump), and `Teleport` (respawn/network corrections).
- All eight native operations are explicitly `[CSharpExpose]` and generated
  from the Beef reflection manifest; native calls validate session, ECS
  component and active simulation, and reject invalid time/NaN vectors.
  Movement from `Update(TickInput, deltaTime)` shares the native networked
  script scheduling, but **this does not establish C# rollback or network
  authority parity**. Validate those paths separately.
- A managed gameplay smoke and C++ host callback test cover vector arguments,
  state reads, and each operation. These tests do **not** simulate real Jolt
  collision/step/gravity; full linked native and Nobara editor verification
  remain outstanding.

### Generated ECS bulk read milestone (2026-11-13)

- `[CSharpExpose] Tallow.Ecs` now provides `CountRigidbodies(session)`,
  `IsAlive(session, flecsEntityId)`, and
  `CopyRigidbodyMasses(session, offset, Span<ulong> ids, Span<float> masses)`.
  The native source is a cached `World.EntitiesWith<RigidbodyData>()`
  query over packed Flecs chunks, not a managed-per-entity bridge.
- IDs are **Flecs entity IDs, not GameObject.Id**. Native pointers and Jolt
  handles stay private. Copies are limited by the shorter destination buffer,
  and stale sessions / negative offsets / empty buffers return zero.
  Pagination can change if structural mutations happen between pages;
  for large bulk reads prefer one count and one appropriately sized buffer.
- Added generator span ABI tests, managed gameplay smoke and native host
  tests for complete, partial, short, empty, stale-session and negative-offset
  cases. This remains a **read-only, RigidbodyData-specific first step**,
  not general C# ECS component registration or writable chunk systems.
  Full Linux Beef/Jolt and interactive Nobara validation are outstanding.

### Managed lifecycle callback batching (2026-11-13)

- An optional ordered `DispatchBatch` entrypoint now connects the Beef
  runtime, C++ hostfxr shim, and .NET managed runtime. It validates a full
  batch of up to 4096 instance IDs before invoking any callbacks, reuses the
  same event implementation as single-object `Dispatch`, and retains no pointers.
- A native-host integration smoke checks two per-instance FixedUpdate and
  LateUpdate calls in one transition, empty and null buffers, detachment
  and invalidated IDs. The `SleepRigidbody` resolver's original
  two-parameter signature hash was verified and retained.
- **Not yet connected to automatic Scene scheduling.** A component can
  disable or destroy the next component during its update. The scheduler
  must preserve those existing per-callback checks and profiling behavior
  before grouping work. Current scheduling and networking are unchanged.

### Prevent stale generated C# symbol IDs (2026-11-13)

- Added `tools/check_csharp_host_abi.py`, run in both Linux and Windows
  managed CI. It hashes the opt-in fixture using the same deterministic
  signature format as BindingGen and rejects missing or stale native-host
  `CSharpApi_*` resolver IDs. Covers methods and explicitly writable fields,
  with known cases for the previously incorrect Rigidbody sleep symbol and
  the new counted Flecs Span API.
- Host test ABI verification runs before managed code generation/build,
  so a copy-pasted outdated symbol ID is surfaced early.

### Correction: verified Rigidbody sleep ABI hash

- An intermediate batching commit mistakenly changed the native-host
  `SleepRigidbody` symbol ID after hashing a truncated signature. The
  complete fixture includes both `session:ulong` and `entity:ulong`;
  its original correct ID is `9e37fa4f1b5124ae`. Restored that ID,
  fixed the new CI hash guard, and cross-checked every native-host
  symbol against the complete fixture.

### Batched network-input update ABI (November 14, 2026)

- A new `tn_csharp_update_input_batch` native/managed entrypoint dispatches
  **distinct** `TickInput` (move, look, button state, previous buttons) and
  delta time for each C# script in an ordered batch. This avoids accidentally
  reusing one player's state for another. The 32-byte C/Beef/.NET record
  remains value-only, with no pointers to native entities or Jolt objects.
- The .NET dispatcher shares the same `RunInputOne` path as individual
  `UpdateInput`, rejects stale initial batches before calling any script,
  and skips an instance detached by an earlier callback in that same batch.
  Native host smoke checks the independent input edge state and two different
  delta times, plus empty, null, negative/oversized and stale cases.
- This **does not enable automatic scheduling or prediction yet**. The native
  Scene and NetworkManager keep checking ownership, enabled state and replay
  order on their existing path; a future ECS dispatcher must preserve those
  checks before grouping scripts. Avoid assuming batching improves throughput
  without benchmark results.

### Scene-scoped, friendly C# Flecs handles (November 14, 2026)

- Added `EcsEntity(SessionId, Id)`, whose `IsAlive` calls the annotated
  native Flecs lookup, and `Scene.GetEcsEntity(flecsId)`. Flecs IDs are
  generation-aware and deliberately not interchangeable with GameObject.Id.
- `Scene.RigidbodyEntityCount` and `Scene.CopyRigidbodyMasses` provide
  convenient access to the existing generated `Ecs` bulk API without
  manually passing native session IDs. The gameplay host smoke now covers
  these user-facing methods, including stale session safety.
- These are managed convenience wrappers over generated opt-in methods;
  they neither duplicate P/Invoke bindings nor expose native pointers.

### Network batch ABI hardening

- The native .NET host and C++ smoke now have compile-time layout
  assertions for the 24-byte TickInput and 32-byte batch record, including
  nested input and delta-time offsets. Managed configuration checks matching
  `sizeof` layouts before binding a native bridge. These fail fast if
  compiler/platform packing changes silently.

### November 14 CI native compiler and managed smoke repairs

- Run `43565593383` (HEAD `05f0d68`) exposed Beef errors:
  invalid `as Collider != null` syntax, reserved local name `box` in a
  collider pattern, and an implicit Flecs query count `int` to `int32`
  conversion. Those three source problems have been corrected.
- Generated C# bindings, managed gameplay compilation, and all 43 Roslyn
  integration tests passed on Linux and Windows. The managed-only test host
  then tried to run newly added native Jolt/Flecs smoke components without
  a native symbol resolver. Those two tests are now handled exclusively
  by the **in-process native-host** suite.
- Full native editor compilation and native-host smoke still need CI
  confirmation after these fixes; no unverified pass is claimed here.

### Lifecycle-safe batch destruction regression (November 14, 2026)

- `DispatchBatch` validates the initial instance set, then checks each
  instance again before invoking it. This matches `UpdateInputBatch` and
  avoids calling an instance detached by an earlier callback.
- The native-host smoke now uses reentrant `tn_csharp_detach` on the
  second instance during the first instance's Transform write and verifies
  exactly one `FixedUpdate` runs. The test is isolated from the normal
  scene scheduler, which continues to invoke callbacks individually.
- This closes the detached-instance case only. Dynamic component enable/
  disable, native callback-list mutation, profiler ordering, network
  ownership, replay and performance measurements must be preserved before
  automatically scheduling whole batches.
### Informational CI measurements (November 14, 2026)

- Linux and Windows hostfxr smoke tests invoke the optional dispatch
  microbenchmark after correctness tests. Results are printed into the job
  logs, with **no pass/fail performance threshold**: hosted runner hardware
  and runtime JIT behaviour vary. Compare only similar runners and always
  corroborate with in-editor frame/tick benchmarks.


### Windows persistent Roslyn queue race (November 14, 2026)

- An intermittent Windows CI failure on `2eb04a5` showed the service
  reading `request.tsv` while the test writer still held it open, causing
  a spurious sharing-violation error in a changed-source diagnostic test.
- Native editor and managed test client now publish all queue requests as
  `request.pending` followed by an atomic same-directory rename to
  `request.tsv`. Existing overlay snapshots are completed before the rename.
- The C# server also retries Windows sharing/lock violations from older
  clients instead of confusing a temporary file race with a source error.
  Behavior for real compiler diagnostics is unchanged.

### Batched C# callback lookup overhead (November 14, 2026)

- The first Linux no-op microbenchmark measured 2.81 ms for 128,000
  individually dispatched callbacks versus 3.53 ms for the same batch
  count (ratio 0.79x). Batching was slower in this narrow test.
- One cause was redundant dictionary work: initial validation, then
  `ContainsKey` and a second `TryGetValue` for every callback. The
  managed runtime now resolves each surviving script **once** per batch
  element after the initial validation and passes it to the same shared
  lifecycle/input handlers used by scalar dispatch.
- This retains all-or-nothing validation for initially stale handles,
  skips instances detached during a previous callback, and avoids raw
  native pointers. Compare new CI timings, but do not infer improved
  real-game FPS or turn on automatic Scene scheduling from this alone.

### Native export verification for runtime C# AddComponent<T>

- Native editor CI now confirms the generated C# signature for
  `CSharpComponents.Add` and verifies its exported symbol with the
  **linked Beef launcher**, not only the C++ mock in hostfxr smoke.
  This catches the case where fixture bindings compile but real engine
  reflection omits the annotated native method.

### Native-owned C# component enable/disable controls (November 14, 2026)

- Gameplay `Script.Enabled` and `Script.IsActiveAndEnabled` now reflect
  the **specific** native `CSharpBehaviour`, not a local managed flag.
  Read state uses -1 for stale scene/adapter and raises a disposed error
  instead of silently treating invalid handles as disabled.
- The `[CSharpExpose]` `CSharpComponents.EnabledState`,
  `ActiveState` and `SetEnabled` methods find the exact native adapter
  by managed instance ID and validated session/object. Setting Enabled
  uses `Component.Enabled`, preserving native OnEnable/OnDisable and
  NetworkSync state notifications. No handwritten native C# binding.
- The native host simulates native enabled-state callbacks and validates
  initial enable, repeated disable idempotence, and re-enable. The actual
  Linux editor build checks all three reflected native API symbols.
- This is a lifecycle parity milestone; automatic managed callback batching
  still requires ordered per-callback native eligibility/profiler checks,
  reconciliation with network replay and performance validation.

### Native GameObject activation in C# gameplay (November 14, 2026)

- Added `GameObject.ActiveSelf`, `GameObject.ActiveInHierarchy`
  and `GameObject.SetActive(bool)` backed solely by three generated
  `[CSharpExpose]` wrappers in `CSharpSceneObjects`.
- Native `GameObject.SetActive` remains responsible for Flecs
  `InactiveSelf` tags, hierarchy activation notifications,
  native OnEnable/OnDisable and `NetworkSync.ActiveChanged`.
  A destroyed or stale object gives a disposed error on the C# side.
- The native-host regression checks disable/re-enable idempotence and
  callback order. Native Linux editor CI verifies that all generated
  active-state symbols exist in the linked precompiled engine.

### Native-eligible managed lifecycle batching (November 14, 2026)

- New **separate**, scheduler-only `tn_csharp_dispatch_checked_batch`
  supports ordered FixedUpdate and LateUpdate groups (max 4096).
  Initial IDs are validated before dispatch; then a native
  `can_dispatch(scene, object, instance, phase)` callback rechecks the
  specific `CSharpBehaviour` for registration, Start, Enabled and active
  hierarchy **immediately before each script**. A previous script may
  disable or detach a later sibling, which is then skipped.
- The engine's native callback locates the matching adapter by managed
  instance ID (not type), and validates the current scene session.
  Managed code receives only ordinary opaque IDs; no native object pointer
  is exposed to C# scripts. Awake/Start/Enable/Disable are deliberately
  excluded and retain the regular callback loop.
- Native-host smoke tests verify ordered Fixed/Late callbacks, skipping
  a sibling disabled mid-batch, invalid phases/pointers, and initial stale
  instance rejection. This establishes eligibility semantics, **not**
  automatic scene batching: integrating the Scene iteration and preserving
  callback-list mutation/profiler order remains separate work. Native
  eligibility checks also have an interop cost that needs measurement.

### Unified C# component lookup (November 14, 2026)

- Added public `IComponent` marker implemented by managed `Script`,
  `Transform`, and the existing native session-safe `Rigidbody`,
  `SoftBody`, `CharacterController`, `Joint`, and `ColliderHandle`
  proxies. `GameObject.GetComponent<T>()` / `Script.GetComponent<T>()`
  now accept either family through the same strongly typed API.
- `TryGetComponent<T>(out T)` gives a consistent absence signal for
  native **struct** handles as well as C# reference scripts. Missing
  value handles are default/invalid (inspect `IsValid`), not nullable
  references; this is a necessary difference from Unity's all-class
  component model. `GetCollider(index)` still handles stacked colliders.
- Native component resolution uses the **already generated** session-
  checked physics APIs. No handwritten P/Invoke/API bindings or duplicate
  ECS/Jolt objects. Unsupported component kinds fail explicitly rather
  than pretending a missing component is present.
- The in-process native smoke tests both Script and Rigidbody with the
  same generic lookup, other supported native handles, Transform, and
  missing/stale objects. Native scene/UI integration still needs a local
  editor check; automatic mapping of future exposed native component
  types will require expanding the handle contract.

### C# Inspector visibility and private serialization (November 14, 2026)

- C# gameplay now understands `[ShowInInspector]` on private fields,
  the compatibility spelling `[ShowInInspecter]`, `[HideInInspector]`
  (public or private). Tallow does not use Unity-style `[SerializeField]`.
  A private annotated field is written to the managed field catalog and
  restored before `Awake` using reflection; arbitrary private fields
  are **not** deserialized. `[NonSerialized]` overrides all inclusion
  annotations. Only existing scalar/vector Inspector value types are
  supported in this stage.
- The `fields.tsv` catalog adds a seventh, optional hidden flag;
  older six-column manifests remain visible. The Inspector omits
  `HideInInspector` rows, and seeds hidden serialized defaults into
  the native scene component's existing `fieldOverrides` when first
  inspected. These overrides persist through standard scene/prefab
  serialization instead of depending on the runtime GC instance.
- A native-host smoke script verifies all combinations (private visible,
  private hidden, public hidden, alias spelling, serialized private,
  NonSerialized rejection, unannotated private rejection) via
  `tn_csharp_apply_fields` before `Awake`. A catalog CI check will
  ensure field visibility matches runtime reflection.
- Runtime changes to hidden fields are **not** automatically written back
  to authoring scene files during Play, matching the existing editor
  Play/Stop model. Automatic serialization of arbitrary managed object
  graphs and of collections remains future work.
- [x] Inspector object reference fields (November 15, 2026): public `GameObject`, `Transform`, built-in component
  handle (marked `[NativeComponent("Tallow.Light")]` etc.) and C# script fields are catalog kind `object`, with
  column 8 `GameObject` / `Transform` / `native:<type>` / `script:<class>`. The Inspector draws an object slot (drag
  from the Hierarchy, or **...** lists the objects that fit). `CSharpBehaviour` keeps them in `referenceNames` +
  `referenceTargets` (a `List<GameObject>`), so the serializer remaps ids for scenes and prefab copies; they are
  applied as `#id` after `fieldOverrides`, and referenced C# scripts are attached first. Engine fix found on the
  way (the same code is on `ecs`): a component removed on its own left its `mReferenceLists` entries, and
  `DestroyTree` read lists of components that had gone with their object — a crash once a common component had a
  list of references. Tests: 9 in-engine checks + 4 catalog rows, 7 editor checks in `--script-files-test`.

### C# syntax highlighting and nullable completion (November 14, 2026)

- The Roslyn source snapshot now emits declared class/record/struct/enum/
  interface/delegate identifiers from game and engine API source as
  `type` records. The editor's C# widget uses these to recolor
  `Rigidbody`, `SoftBody`, and new user-defined types without manual
  API type-name lists. Per-document double-buffered language definitions
  refresh TextEdit's lexical colors when the known type set changes.
- Completion treats `body?.AddF` as Roslyn's
  `ConditionalAccessExpressionSyntax` instead of incorrectly falling
  through to unrelated global keywords. Nullable native value handles
  resolve `Nullable<T>` to underlying `T` for conditional member access;
  ordinary dot access maintains C# semantics.
- Regression tests cover direct and conditional Rigidbody completion,
  elimination of irrelevant global suggestions, and compiler-discovered
  native/user type symbols. Visual editor behavior needs manual testing.


### C# completion accessibility tightening (November 14, 2026)

- The Roslyn completion merge now checks symbol accessibility for every
  suggestion, including inherited members found by the direct `GetMembers()`
  fallback. This prevents private base/other-class fields and methods from
  appearing, while preserving accessible protected and own-class private
  gameplay members. It retains the existing explicit filter for private
  engine-generated binding internals.
- Added regression cases for protected/public inherited members, private base
  exclusion, other-instance private exclusion, and existing own-private
  completion. Managed CI and interactive Nobara validation are still needed;
  do not infer runtime/editor success from this source change alone.


### Atomic C# Inspector value application (November 14, 2026)

- Parsing of the native scene/prefab C# field overrides is now transactional:
  a malformed persisted value cannot silently apply earlier fields and then
  leave a half-updated managed Script before Awake. Unsupported/removed fields
  still follow the existing skip policy. Finite float validation matches the
  existing vector coordinates rule.
- The in-process C++ host smoke deliberately sends one valid field followed
  by an invalid integer and independently tries an infinite float after a
  valid override set. It then runs the existing Awake state assertions to
  detect any partial write. Requires managed Linux/Windows CI verification
  and an actual Nobara editor save/reopen test (benchmark B09).


### Persistent incremental Roslyn compilation (November 14, 2026)

- The existing persistent C# worker cached parsed trees but recreated its
  compilation for every completion/diagnostic query. It now retains one
  immutable `CSharpCompilation` and incrementally replaces/adds/removes
  changed syntax trees, preserving unchanged API/game semantic caches and
  stable implicit framework and System.Numerics imports.
- Persistent-service tests now add a broken C# file and then delete it to
  verify diagnostics correctly invalidate, in addition to existing
  changed-source/recovery tests.
- **Pending tests:** full interactive editor verification. (B05 measured November 16, 2026; Linux/Windows CI run
  the Roslyn tests and the latency script.)
  Project-level assembly-definition semantics remain future work.


### Enum-valued C# Inspector fields (November 14, 2026)

- The compiler-built C# field catalog now includes enum types for public,
  [ShowInInspector] and [HideInInspector] fields, with
  declaration-order member names in optional column eight. The existing
  scalar/vector catalog format and hidden-field persistence remain intact.
- The native Inspector renders an enum dropdown and persists a selected
  member name. The .NET loader parses enums before Awake with the same
  transactional semantics as numeric fields, rejecting invalid names for
  ordinary enums; explicitly flagged enums can also decode combined values.
  The editor currently shows declared options (not arbitrary flag bitsets).
- Added fixture assertions, host tests for valid and invalid enum overrides,
  and catalog CI checks. **Pending** managed/Linux native builds and editor
  Play/Stop validation; strings, arrays, object references and general
  nested serialized types still need conversion.


## P6 — gaps the earlier phases did not cover (added 2026-11-14)

A full conversion also needs these. Ordered roughly by when they block users.

**Authoring basics (before calling P2 done)**
- [x] Script exception policy: a throwing script keeps running (decided: the same failure
  every frame is still one Console entry, counting up, rather than a silently disabled
  component). The entry reads "System.X: message (in Update, Game.Player.Update(...) at
  Player.cs:12)", carries the whole trace under "Stack traces / details", and clicking it
  opens the game's file at that line (the first frame outside Tallow's own assemblies).
  Batched dispatch (lifecycle, checked and input batches) now runs every script in the
  batch and reports the first failure after, instead of stopping at the throwing one.
  Test: `Thrower` in `Tests/CSharpInGame` (keeps updating; logged once with its line).
- [x] Remaining `Component` callbacks for C#: `OnFrame`, `OnNetworkEvent` (with
  `Script.SendNetworkEvent`, host entry `tn_csharp_network_event`), `OnDrawGizmos(selected)`,
  `OnValidate` (also after an Inspector edit during Play), `OnSaving`/`OnLoaded`, and
  `[Saved]` fields: `CSharpBehaviour.SaveFields` keeps each under its own name (ReadFields
  mode 4, applied back through ApplyFields). New C# APIs to use them: `SaveGame`
  (Save/Load/Exists/Delete, `SaveTask`), `DebugDraw` and `Gizmos` (Line/Sphere/Box) with a
  `Color` struct. Edit-mode limits: C# scripts are only loaded during Play, so OnFrame,
  OnDrawGizmos and OnValidate reach them only then. Tests: in-engine (OnFrame, offline
  event, draw calls, save/load round trip, 95 checks), network (client event to the
  server and back, 12 checks). OnValidate and OnDrawGizmos are tested by `RunFieldTest`
  (`--csharp-field-test`), which makes the editor's calls on the running script: OnValidate
  once after an Inspector edit with the new value set, not after a refused edit, and
  OnDrawGizmos with the selected flag while drawing lines, spheres and boxes (4 checks).
- [x] Main-thread async: `GameSynchronizationContext` (Tallow.API `GameThread.cs`) is set on
  the game thread when a game loads and pumped once a frame after LateUpdate
  (`Frame.CSharpAsync`, host entry `tn_csharp_pump`). Script gains `NextFrame()`,
  `Wait(seconds)` on game time, and a `Destroyed` token that cancels both when the script
  goes (object destroyed, scene unloaded, Play stopped). Unloading the game closes the
  context and cancels game-time waits, so nothing from the old assembly runs again;
  Task.Delay without the token still holds the old context until its timer fires.
  `async void` exceptions are reported with their line; cancellations are not.
  Decided: no coroutines; `async` covers them. Test: `AsyncProbe`/`AsyncDoomed` in
  `Tests/CSharpInGame` (frame counts, thread, cancellation, exception report; 101 checks).
- [x] Collision/trigger callbacks (engine-wide; there were none, for Beef either):
  `OnCollisionEnter/Exit(Collision)` and `OnTriggerEnter/Exit(GameObject)` on Beef
  `Component` and C# `Script`; `Collider.isTrigger` makes a Jolt sensor (kinematic when
  there is no Rigidbody, so it sees character controllers and sleeping bodies; it ignores
  static scenery). Per pair of objects, not per sub-shape/contact point. Each step lists
  touching pairs from added+persisted contacts (lock-free append from job threads);
  after the real tick the list is compared with the pairs last reported, so prediction
  replays never fire callbacks and a rollback restoring Jolt's contact cache cannot
  desync it. A pair that stops reporting only because a body fell asleep stays entered
  while bounds overlap. `PhysicsWorld.ContactEvents = false` turns recording off.
  In-engine test: ball through a trigger onto the ground, asleep, teleported, landing
  again (12 checks).
- [x] `OnCollisionStay`/`OnTriggerStay` (every step while touching and awake; the native diff
  now records every pair's manifold, not only new ones) and `ColliderHandle.IsTrigger`
  get/set from C# (rebuilds the body; a Rigidbody keeps its state). 9 more in-engine checks.
- [x] Character-controller hits: `OnControllerHit(ControllerHit)` (object, point, normal
  towards the character, move speed) on Beef components and C# scripts, from Jolt's active
  character contacts after each Move (ground included, triggers not, one per body, never
  during prediction replays). 4 in-engine checks with a character walking into a wall.
- [x] `[Sync]` on **Script** fields: a running script's `[Sync]` fields (public or private;
  int, float, bool, string, enums, vectors) join the object's NetworkSync slots after the
  native ones, are read once per script per snapshot, sent when changed with the engine's
  field message, applied on clients through the validated managed loader, and sent whole to
  late joiners. `tools/test_csharp_network.py` runs a real headless server and client
  (5 checks; in native CI).
- [x] An RPC attribute for C# scripts: `[Rpc(RpcTarget.Server|Everyone)]` methods called with
  `Rpc(nameof(Method), args…)`. Arguments are int, float, bool, string, enums, vectors and
  GameObject; the target checks the method is an `[Rpc]` of that kind and parses them before
  calling. Clients may only call on objects they own (checked on both sides); `RpcSender`
  gives the caller's client id. Without a session it runs at once. They ride the engine's
  event message. Covered by `tools/test_csharp_network.py` (10 checks) and the in-engine test.
- [x] Engine fix found on the way: components of a prefab instantiated during play got Awake
  before their saved fields were read (every component, Beef too). The loader now holds
  their wake until the whole text is in.
- [x] Live Inspector values during Play: the Inspector's C# fields show the running
  script's values (managed `ReadFields`, same text format as the scene), edits still go to
  the running script, and a "Debug: all fields (live)" section lists every instance field
  (private ones and collections included, with types) read-only, refreshed each frame.
  Tested natively in the in-engine run (`--csharp-field-test`, 9 checks).
- [x] Script identity: C# Script components also store `scriptAsset`, the `.tmeta` ID of
  the class's file (recorded when added, filled in for older scenes). `[FormerlyNamed("Old.Name")]`
  on a class maps old names in the generated registry, so scenes, prefabs and built games
  still get the class (fields restored; the Beef side takes the new name and warns to save).
  The editor repairs open scenes after each compile and on open: a former name, or else the
  only script left in the recorded file (a class renamed without the attribute). Tests: one
  in-engine check, six in `--script-files-test`. Fixed on the way: the registry generator's
  Roslyn compilation lacked the SDK's implicit usings, so attribute arguments did not bind.
- [x] Scene safety: unknown `component` and `data` blocks (and their `field` lines) are
  kept verbatim on the object (`GameObject.MissingComponents`), written back on save,
  copied with duplicates/prefabs, warned about once per type, and shown in the Inspector
  as "Missing: <type>" with a Remove button. Opening an old Beef project in the C# editor,
  or a scene whose script failed to compile, no longer loses data. Covered by
  `--script-files-test` (load, save, reload, save again).

**Tooling and environment**
- [x] External IDEs: `<Project>.slnx` generated by every C# build; open scripts follow
  edits saved by another program. (Tallow.API XML docs in the IDE: still to ship.)
- [~] Debugging, in two steps. (1) Attach — done: Window > C# Debugging shows the editor's
  process ID, whether the hosted CoreCLR accepts debuggers (its `clr-debug-pipe` is
  checked; verified it appears within 3 s of start), writes a VS Code `.vscode/launch.json`
  attach config (never overwrites an existing one), and gives Rider/Visual Studio steps.
  Tallow.Build writes `<Project>.slnx` listing every generated assembly so IDEs open the
  game's C# directly (`dotnet build` of it verified); new projects ignore `.tallow-csharp/`
  and `*.slnx`. Game assemblies are built Debug with symbols. Not verified here: a real
  netcoredbg/vsdbg session (no debugger installed on this machine). (2) Built-in: breakpoints in
  Tallow's own code editor need a DAP client talking to netcoredbg (MIT) as a child
  process; gutter breakpoints, a paused-state toolbar and a locals/watch panel. Larger
  job (est. 2–3 weeks); the editor UI cannot draw while its own thread is stopped, so the
  debugger must run gameplay on a separate thread or the UI must pump from the DAP
  client's wait loop.
- [x] Live variable inspection without breakpoints: see "Live Inspector values" above.
- [~] .NET SDK acquisition: the launcher now checks the SDK and runtime (major 11) as it
  starts, warns on a preview SDK, shows install commands and a download button, rebuilds
  a stale `Tallow.ManagedRuntime`, and `--check-dependencies [--fix]` does the same on the
  command line. Still open: Manager-side install of a pinned SDK.
  Released SDK (November 18, 2026): the branch builds with **.NET SDK 11.0.100** (runtime 11.0.0), not RC1.
  `global.json` requires 11.0.100 or a later feature band and no previews (`dotnet` in the repo stops on an RC).
  The dotnet on PATH is used when it has a released 11.0.100+ SDK (one install is enough); otherwise the launcher
  and editor (`DotNetSdk.Apply`) and the Python tools (`tools/dotnet_sdk.py`, imported by build, export and test
  scripts) route to Tallow's own copy. JIT exports now bundle runtime 11.0.0. All suites pass on it (in-game 439,
  export 420 JIT and NativeAOT, reload 33, network 32, network reload 7, Gallery, sample 10, web 405).
  Version check: the launcher's .NET check (`DotNetCheck`, also `--check-dependencies`) now requires a released
  SDK 11.0.100+ and runtime 11.0.0+ (`DotNetSdk.PinnedVersion` / `PinnedRuntime`), not just major 11; a preview or
  older one is a problem naming both versions, with the Install / Download / Copy install command buttons. The
  Python tools print the same warning when neither Tallow's copy nor the PATH dotnet is the target.
  - [x] Install a pinned, released .NET 11 SDK into a Tallow-owned per-user folder shared by
    engine versions (for example `~/.local/share/Tallow/dotnet` on Linux or
    `%LOCALAPPDATA%\\Tallow\\dotnet` on Windows). Detect a compatible cached version on
    startup; otherwise download and verify the platform/architecture-specific SDK,
    stage it atomically, and report progress and actionable errors. No administrator
    privileges or global `dotnet` installation should be required.
    Done November 16, 2026 (`Editor/src/Project/DotNetSdk.bf`): SDK 11.0.100 pinned with the SHA-512 of
    Microsoft's archive for linux/win/osx x64 and arm64 (from the official release metadata). Each version is a
    complete dotnet root in `<data>/Tallow/dotnet/<version>` (`~/.local/share`, `%LOCALAPPDATA%`,
    `~/Library/Application Support`; `TALLOW_DOTNET_HOME` overrides), downloaded with curl, checked with the
    system's sha512sum/shasum/certutil, unpacked with tar into a staging folder beside it and renamed into place;
    a killed install's staging folder is cleared later. Launcher: an "Install .NET 11.0.100 for Tallow" button
    beside the download/copy buttons (shown for a missing, old or preview SDK; not clicked by hand yet) and
    `TallowLauncher --install-dotnet [--from-archive FILE]`. `tools/test_dotnet_install.py` (5 checks, local only:
    it downloads; ~10 s here).
  - [~] Route every ordinary C# editor, language-service, project-build and game-export
    invocation through the selected SDK executable and runtime root. Pin/roll forward
    deliberately so multiple Tallow versions can share the cache without silently
    switching a project to an incompatible SDK. Test first-run download, offline reuse,
    interrupted download, corrupt archive, update and clean Linux/Windows machines.
    (November 16, 2026) When the pinned SDK is installed, the launcher and editor put its root first on PATH and in
    DOTNET_ROOT as they start (`DotNetSdk.Apply`), so every `dotnet` they or the export scripts start, and the
    editor's hosted runtime (the host reads DOTNET_ROOT first), use it; otherwise the SDK on PATH as before. Checked:
    `--check-dependencies` reports 11.0.100 instead of the machine's RC1, and `test_csharp_sample.py` (create,
    compile, play) passes through it. Tested: corrupt archive, interrupted install, reuse. Not yet: clean
    Windows/macOS machines, an SDK update path (a new pin installs beside the old one).
  - [~] Offer an offline engine package with the same SDK pre-staged for users who want
    one download and no first-run network access. Keep the default engine download
    smaller by using the shared per-user cache.
    (November 16, 2026) The install side exists: `--install-dotnet --from-archive FILE` installs from a copy of
    the same archive (same SHA-512 check). Packaging that archive into an offline engine download is not done.
- [~] Python-free ordinary use: version check, verify, pin and upgrade are Beef
  (`Editor/src/Project/EngineVersions.bf`), so creating, opening and upgrading projects
  no longer need Python. Still Python: player export (`tools/build_player.py`), engine
  packaging (`tools/package_engine.py`), the web export preview server (`python3 -m
  http.server`), and the legacy Beef language service.
- [~] Third-party managed libraries/NuGet references in `.tasmdef`:
  `"packages": [{ "id": "Newtonsoft.Json", "version": "13.0.4" }]`, exact versions only
  (`PackageReference` with `[v]`). Their assemblies are copied beside the game's and the
  runtime resolves them there (editor and built games). After each build Tallow.Build
  writes `.tallow-csharp/third-party.tsv` (id, version, licence, URL from the .nuspec,
  transitive packages included) and `package-references.tsv`, which the editor's code
  service references; game builds ship `THIRD-PARTY-NOTICES.txt` at the game's root.
  Trust: packages run with the game's full trust; Tallow's script rules (no unsafe code)
  are not applied to them, and the build says so. Tests: `Tests/CSharpInGame/src/Json`
  (Newtonsoft round trip in the player, 106 checks), the export test checks the notices.
  Not yet: native libraries inside packages (`runtimes/*/native`), an Inspector UI for the
  list (edit the .tasmdef text; the page keeps the key), and trimming/AOT rules (with the
  NativeAOT work). Code-service test with a package done (November 16, 2026): unknown before
  `package-references.tsv` lists it, known (diagnostics and completion) once listed, 3 tests.
- [x] Profiler: C# scripts are timed per class ("Game.Player.Update()", Scripts) instead of
  all sharing "CSharpBehaviour.Update()"; "C# await continuations" times the async pump;
  Memory counters "C# allocated this frame", "C# heap", "C# garbage collections this frame"
  and "C# GC pause this frame" come back from the pump (`tn_csharp_gc_stats`). Test: the
  in-engine run writes `--profile-report` and checks the rows (105 checks).
- [~] Packages (`.tpackage`) that carry C# source: `.cs` files count as scripts (import
  and removal recompile), a scene or prefab's C# component (`field scriptType`) brings its
  `.cs` file, and a `.cs` file brings its folder's nearest `.tasmdef`. `.cs` files keep their
  `.tmeta` IDs, so an import finds them where they were moved. Test: `--packages-test`
  step 6. Not yet: prebuilt managed assemblies in packages (with the NuGet/third-party
  library item, which needs the trust rules first).
- [x] Editor extensibility (November 17, 2026; the user wants custom inspectors and editor windows): editor
  scripts are any `.cs` in a folder named `Editor` under src/, compiled by Tallow.Build into `Tallow.Game.Editor`.
  That assembly references the game's assemblies and `Managed/Tallow.Editor`, and nothing references it, so game
  builds leave it out. The editor loads it after each successful compile into its own collectible context, apart
  from Play's game context. Tallow.Editor is loaded beside Tallow.API through `NativeEntrypoints.EditorConfigure`,
  found by reflection on first use (`tn_csharp_editor_configure`), so games never load it. What is in:
  - `[CustomInspector(typeof(T))] : Inspector`: `Field`, `DrawDefaultInspector`, `Target.Get/Set*` go through the
    Inspector's own field path, so undo, saving, OnValidate and Play behave as they do there.
  - `[EditorWindow("Path")] : EditorWindow` in a Tools menu; its open state is kept across reloads and restarts.
  - `[MenuItem("Path")]` static commands.
  - `[PreferencesPage("Title")]` Preferences tabs: a settings class drawn from its fields, or a `PreferencesPage`
    that draws itself.
  - `EditorPrefs` (per user) and `ProjectPrefs` (ProjectSettings/EditorPrefs.json) as JSON.
  - `EditorGUI` widgets drawn with the editor's ImGui. Scopes left open or an exception unwind safely, and a
    failure is reported once.
  - Create > C# Script > Editor templates (Custom Inspector, Editor Window, Tools Menu Command, Preferences Page).
  - The language service compiles editor folders as their own assembly against Tallow.Editor.

  Tests: `tools/test_csharp_editor_extensions.py`, a display test with 32 checks, which includes a broken window, a
  reload and a game build with no editor scripts; LS tests (139); the template test compiles the four editor
  templates.

### Editor scripts work on the scene (November 18, 2026)

- The three gaps listed here for editor scripts are filled, each tested end to end by
  `tools/test_csharp_editor_extensions.py` (32 checks, display needed):
  - **Scene editing in Edit mode:** `Tallow.Editor.EditorScene` / `EditorObject` / `EditorComponent`
    (`Managed/Tallow.Editor/EditorScene.cs`, host functions in `Editor/src/Scripts/CSharpEditorExtensions.bf`):
    selection, find by path or name, roots and children, create the editor's built-in objects (where the editor puts
    them or under a parent; `uint.MaxValue` is the "as the menu does" sentinel), duplicate, delete (immediately, not
    queued, so the script can carry on), rename, world position, Euler rotation and local scale, and components by
    full type name for class components and built-in handles alike, their fields read and written with
    `SceneSerializer.WriteValue`/`ReadValue` (strings unquoted for scripts). Every mutation marks the scene dirty,
    so the snapshot undo makes a command one step; mutations are refused during Play. The test's Tools command does
    all of it, the editor checks the result in its own scene (an object at the position set, a Light at intensity
    2.5) and takes it back with Undo.
  - **Inspectors for built-in components:** `[CustomInspector(typeof(Light))]` on a `ComponentInspector` subclass
    (`Managed/Tallow.Editor/Extensions.cs`, EditorHost `findComponentInspector`/`drawComponentInspector`); the
    InspectorPanel routes class components and handles that have one through it, `Field(name)` draws a single field
    with the editor's own widget (host `componentField`/`componentDefault` over the same `FieldRef`s), edits run the
    component's OnValidate and mark the scene dirty. The test's Light Inspector must draw for the probe cube and
    read the component's own intensity.
  - **Scene view overlays:** any concrete `SceneViewOverlay` subclass gets `OnSceneViewGUI()` each frame the Scene
    view draws (called from `DrawSceneView`, so the gizmo batches it fills are rendered that same frame), with
    `SceneView.IsVisible/IsMouseOver/IsClicked/IsMouseDown/MousePoint/Ray/Pick/PickUnderMouse` (host functions read
    the state captured in DrawSceneView and the editor camera's ray/pick) and `Line/Sphere/Box` drawing through the
    existing `Tallow.Gizmos` API. The test focuses the Scene tab (the default layout leaves it behind Game) and a
    probe overlay reports that it ran, saw the view and got a ray.
  - **The modelling API in Edit mode** (November 18, 2026): `Tallow.Editor.EditorModel` reads an object's Model Mesh
    into an `EditMesh` and writes one back (host `modelRead`/`modelWrite` over new
    `CSharpModeling.ReadFromObject`/`ApplyToObject`), adding a Mesh Renderer when needed and marking the scene dirty
    (so the snapshot undo covers a modelling command). The managed `EditMesh` wrapper needed the C# API's symbol
    resolver, which was never bound in Edit mode: Tallow.Editor's Configure now binds `GeneratedNativeApi` with
    `CSharpRuntime.ResolveApiEntry` (the same resolver a game gets, without scene callbacks), so editor scripts can
    use scene-free Tallow.API calls - the modelling API, `Gizmos`/`DebugDraw` - which also fixes Scene view overlay
    gizmos (they had been throwing "resolver has not been bound" and being reported once). The probe applies a box,
    reads it back, extrudes its top and writes it again; the editor checks the scene's Model Mesh has faces.
    Create > C# Script > Editor also offers the two new kinds (Built-in Component Inspector, Scene View Tool).
- Not yet: Tallow.API's scene objects (`GameObject`/`Transform`/components through their own API) on the edited scene
  (they need scene callbacks; EditorScene is the Edit-mode API), and carving terrain from C# in Edit mode.
- Gotchas: the managed table's function pointers must be filled in `EditorHost.Configure` (a missing one is a null
  call, and the editor segfaults), and host-table changes bump its version (4 now) on both sides; the editor's
  snapshot undo needs `MarkDirty`, not `Destroy`, for script deletions.

**Editor tools (Beef editor work done on this branch alongside the migration)**
- [x] Editor windows can be dragged out of the main window (ImGui viewports, November 15, 2026; 23bcff1e,
  5b90c1e0). Extra windows use `BGFX_SWAP_CHAIN_NO_VSYNC` (per-window FIFO froze the editor under XWayland); OS
  title bars, F11 fullscreens the focused window, a Preferences toggle (windows.cfg). Display test
  `--viewport-test`. Left (the user wants it fixed later): lag and dropped input while a window crosses the main
  window's edge. Global `ConfigViewportsNoAutoMerge` was tried and rejected (every floating panel became an OS
  window); it needs NoAutoMerge per window, only for windows dragged out.
- [x] Modeller made easier to use (November 16, 2026; the user asked for it to be "way more user friendly": fast
  whiteboxing first, the full toolset for complex models). The Model window has five tabs in the order a model is
  made (Blockout, Edit, Paint, Texture, Model; `Editor/src/Modeling/ModelWindow.bf`). Edit shows Essentials or All
  Tools, with search and Exact amounts. Every button has its key and a tooltip, and is greyed out with the reason
  when it cannot run. Keep drawing and Cut a Hole are on the Blockout tab. A bar over the Scene view and Model
  Views (`ModelToolbar.bf`) has the same tools, with a hint line at the bottom of the view. Drawn shapes snap to
  other objects' corners, edges and edge middles (`ModelSnap.bf`; Alt draws freely). This applies to drawing only,
  not to the edit-mode tools or the object gizmo. The ImGui binding gained tab bars, `BeginTooltip` and
  `DrawString`. Screenshots: `--model-test --model-window --model-tab <name> [--model-all-tools] [--model-idle]`
  with `XDG_DATA_HOME=<scratch>`. Not tried by hand yet: clicking the Scene view bar.
- [x] Architect (building) system (November 17, 2026; the user asked for "a super easy way to create buildings
  including interiors"): `docs/buildings.md`. The `Building` component (`Engine/src/Modeling/Building.bf`) keeps a
  plan as text: rooms as grid rectangles per storey, doors, windows and openings on grid lines, and stairs.
  `BuildingGenerator` makes it into the object's Model Mesh. Walls go wherever two rooms, or a room and the outside,
  meet, with posts at corners, T-junctions and ends. Holes are cut for openings. Each level gets one slab (floor
  above, ceiling below, roof where nothing is above) with holes over stairs, and stairs are solid steps. The tools
  (`Editor/src/Modeling/BuildingEditor.bf`) are on the Model window's new Building tab and a Scene view bar: Room
  (Shift adds to the picked room), Erase, Door, Window, Opening and Stairs, with keys 1-6. Doors and windows snap
  along the wall, stay clear of posts and can be dragged and removed. Storeys go up and down, with the storey below
  as an outline. A Scene view cut-away (See All / Cut Away / Low Walls) uses `ModelMesh.ShowInstead`, which draws
  another mesh without changing the saved one. Bake to Model drops the plan. Created from GameObject > Building, the
  Scene view bar or the tab. Test: editor `--building-test` (display; 31 checks with rays through walls, doors,
  windows, floors, roofs, stairs holes, cut-away, undo, erase and plan text round trip; `--building-storey N`
  `--building-cutaway 0-2` for screenshots). Not yet: walls at angles other than 90 degrees, roof shapes other than
  flat, railings, and clicking through the tools by hand.
- [x] Terrain cracks while digging (November 17, 2026; the user saw wrong triangles "esp when digging"). Mesh
  workers read a chunk's own samples and paint while the brush wrote them on the main thread, so a mesh could mix
  old and new samples (cracks in Smooth meshes mid-stroke, until the next rebuild) and paint could be freed under a
  worker. Workers now copy them under `mMonitor`; `ApplyStroke` and `TakeSharedEdges` write under it. Checked by
  dumping every chunk build during a scripted dig: cracked builds 4 → 0 over three runs, and the stitched terrain
  is watertight in both styles. Still open: in endless terrain with caves about 0.1% of triangles face against
  their vertex normals, on rock about a voxel thick.
- [x] CI repair (November 17, 2026): the three pushes since the Steam/anti-cheat work failed because
  `Tests/CSharpExpose/fixture.tsv` lagged behind the engine manifest (148 new API lines), so the managed job lacked
  `CSharpSteam`/`CSharpAntiCheat` and the native job's drift check failed. Fixture refreshed.
- [x] Shared materials from C# (November 17, 2026): `Material` (`Managed/Tallow.API/Materials.cs`) names a .tmat
  by path: `Material.Load`, `Material.Create(name, copyOf)`, `MeshRenderer.SharedMaterial`; every Inspector field
  as a property, `MaterialBlend`, and `SetFloat/SetColor/SetVector/SetTexture` for custom shader properties.
  Changes are local and affect every object using the material. Host: `CSharpMaterials`
  (`Engine/src/Scripting/CSharpMaterialsApi.bf`) over the new `Material.SetNamedValue/GetNamedValue/NamedText`,
  which `RenderProxy.ApplyMaterialValue` now uses too. 8 in-game checks (378); docs/materials.md converted.
  Saving a material to a file stays editor code.
- [x] Compute without the component (November 17, 2026): `ComputeShader` (path, `SetFloat/SetColor/SetVector`,
  `HighPrecision`, `Run(texture, steps)`), `ComputeTexture` (`ShowOn(renderer)`, which keeps the renderer on the
  newest image as steps swap them; `StopShowing`; `Dispose`) and `Compute.Supported`
  (`Managed/Tallow.API/Compute.cs`). Host: `CSharpCompute` keeps them by number and frees what is left at game
  unload. 5 headless checks (383); run for real in a window on a scratch Sandbox (150 of 150 steps, ripple drawn on
  a crate). docs/materials.md converted.
- [x] Save storage of the game's own, and `[GameStart]` (November 17, 2026): C# `SaveStorage` (Write/Read with a
  `SaveRequest` finished once from any thread; optional Exists/Delete/List), `SaveGame.Storage` (null: files) and
  `SaveGame.Slots()`. Host: `CSharpSaveStorage` forwards through the new host entry `tn_csharp_save_storage` (op
  0-4; managed `NativeEntrypoints.SaveStorage`, WebHost registration, stub), tasks kept by number in
  `CSharpSaves` until `FinishTask`; at unload or hot reload saves go back to files and pending ones fail.
  `[GameStart]` static methods are registered by Tallow.Build in each assembly's module initializer and run after
  the game loads (before the first scene and any Awake; again after a reload); the runtime now runs the module
  initializers of every referenced game assembly at load (their systems, nodes and starts were registered only on
  first use). 10 in-game checks (393). docs/saving.md and docs/csharp-gameplay.md. Not tried: Load Save At Start
  with a C# storage that answers later.
- [x] C# data assets (November 17, 2026): `DataAsset` classes in C# (`Get<T>()`, `Get<T>(path)` making a derived
  class from its file, `FilesOf<T>()`, `[Saved]` fields with `Save`/`Revert`/`OnLoaded`, `ToFileText`,
  `ClearCache`, `Rescan`). The .tdata file is `dataasset <Class>` plus `field Name\tvalue` lines in the Inspector's
  text, read and written by the runtime's field codec (now usable on any object, not only scripts); players' copies
  go through the engine's `DataAsset.Storage` (new `CSharpDataAssets` API, `DataAsset.FilesOfName`/`ForgetIndex`).
  Tallow.Build lists the classes in `.tallow-csharp/data-assets.tsv` (with a "saved" mark) and their fields in
  fields.tsv (object references left out); the Project panel's **+ > Data Asset** offers them and the Inspector edits
  their files from the catalog. Loaded assets are dropped at unload and hot reload. 10 in-game checks (403; 386 in
  the exported game) and 3 editor checks. docs/saving.md converted. Not done: C# code cannot set the data asset
  storage (players' copies are files, or whatever engine code sets). (November 18, 2026: every DataAsset class is
  registered by the build with a generated constructor (`Tallow.DataAssetRegistry`), so loading a file that names a
  derived class no longer scans assemblies or reflects over constructors, and the class list is known under
  NativeAOT.)
- [x] C# profiler markers and counters (November 17, 2026): `ProfilerMarker` (Begin/End, `Auto()` scope),
  `ProfilerCounter` (Set/Add, unit), `ProfilerCategory` (enum check), `Profiler.Enabled`/`NameThread`, over the new
  `CSharpProfiler` API; names register on first use. The in-game run's profile report must show the test's marker
  under AI and its counter with its unit (405 checks). docs/profiler.md converted.
- [x] C# terrain generators (November 17, 2026): `TerrainGenerator` (Density, Paints/Paint with `TerrainLayer`,
  Begin on the game thread, optional batch `Fill(TerrainSamples)`), `VoxelTerrain.SetGenerator`/`ApplyGenerator`/
  `Regenerate`/`AddTile`/`TileIds`/`DensityAt`/`Raycast`/`IsValid`, and AddComponent<VoxelTerrain>. Host entry
  `tn_csharp_terrain_generator` (op 0 chunk cube, 1 Begin, 2 release, 3 scattered points); the engine's
  `TerrainGenerator` gained `FillsChunks`/`Fill`/`FillPoints`, used by chunk generation, Apply Generator and the
  meshing's edge samples, so a C# generator is called once per chunk and once per missing edge set (the first
  try called it 1.78M times per test run, one call per edge sample; now 256 fills for 256 chunks). A generator
  that throws is reported once and its chunks are empty; unload and hot reload stop C# generators (flat ground at
  0 after that until set again). 7 in-game checks (412; 393 exported). docs/terrain.md converted.
- [x] C# texture creation (November 17, 2026): `Texture` (name, size, `TextureKind`, `Pixels`, Get/SetPixel, Fill,
  `Apply` to the graphics card with mip levels, `Load` a copy of an image file, `Hint`, `KindOf`, `Dispose`) over
  the new `CSharpTextures` API; the name goes where a texture path goes. Engine: `Assets.RemoveTexture`, and
  `ReplaceTexture` takes a kind. Released when the game's code goes. Also `ComputeShader.IsCompiled` (Run does
  nothing until the editor has compiled the shader), found when the in-game run was tried in a window: the compute
  check now passes headless and windowed. 9 in-game checks (421; 402 exported); windowed run: Apply true, no
  failures. docs/textures.md converted.
- [x] C# async scene loading (November 17, 2026): `SceneManager.LoadAsync`, `Scene.LoadAdditiveAsync`, `SceneLoad`
  (Stage/`SceneLoadStage`, Progress, asset counts, AllowActivation/Activate, Group, awaitable `Completion`) and
  `AssetLoader.Preload` with `Preload` (Progress, Total/Loaded, Dispose), over the new `CSharpScenes` API. The
  engine's `SceneLoad` hands its final state to `CSharpScenes` when SceneManager deletes it, so C# reads Done/Failed
  and Group after the engine is finished with it. 9 in-game checks (430; 411 exported), enum check for the stage.
  docs/loading.md converted. This closes the C# feature gaps listed on November 17.
- [x] C# modelling at run time (November 17, 2026): `EditMesh` (Shape with `MeshShape`, empty, From an object, FromText/
  ToText, vertices and faces, FacesFacing, Extrude/Inset/Subdivide/Triangulate/Poke/Solidify/Flip/Delete/Duplicate,
  Mirror, Repeat, MoveOrigin, Append, `Combine` with `MeshBoolean`, face colour/material/smooth, ApplyTo) over the
  new `CSharpModeling` API (meshes by handle, freed when the game stops). 9 in-game checks (439; 420 exported). docs/modeling.md
  converted; the Beef blocks left in docs are editor and engine tooling (HTTP for the launcher, physics capacity,
  asset IDs, baking, rigging, themes, the Beef reload page).

**Platforms, content, migration**
- [x] Web: a C# web player is a .NET browser app (Mono, wasm-tools workload) whose WebAssembly is
  relinked with the engine and the precompiled player (`tools/web/csharp_web.py`; `setup` once).
  `Tallow.ManagedRuntime.WebHost` registers the entrypoints and starts the player; the game loads
  from the page's bundle (no hot reload in a browser). `tools/test_csharp_web.py`: the in-game
  checks pass in headless Chromium with WebGL 2. Left: browser multiplayer from C# (WebRTC,
  tallow-net.js) untested; the bundle is about 18 MB before the server compresses it.
- [ ] macOS (hostfxr `.dylib` path exists, untested): decide support.
- [ ] Existing Beef games (Ringfall, Polystrike, Tumble Toys, Zombie Tag and others): decide
  between indefinite legacy Beef gameplay in the same editor and a conversion tool or
  guide. Today the precompiled editor drops their components (see Scene safety above).
- [ ] Website documentation and tutorials still teach Beef gameplay; convert them with
  the samples (P3).
- [x] Windows Debug leaks: Beef's realtime leak check (on by default in Debug Win64 builds only) stopped
  `TallowLauncher --graph-compile` at exit with 161 unfreed strings (CI run 44237153082, November 18, 2026): the
  C# enum member names of the graph node catalog (`NodeLibrary.sCSharpEnums` freed its lists, not their strings).
  Fixed; Linux builds do not run this check, so the Windows CI job is the one that finds such leaks.
- [ ] Branch upkeep: merge `ecs` into this branch regularly so the final merge stays
  reviewable. (Checked November 18, 2026: `ecs` has no commits this branch lacks; it last merged at 7a7b6ca1.)

**Visual scripting decision (recorded for P3):** keep compiling graphs to source and
retarget the existing graph compiler from Beef to C#, rather than writing a Beef-side
interpreter. One execution model keeps graphs on the same scheduling, networked tick,
prediction and NativeAOT path as hand-written C#; graphs can call user C# methods and
be called from C# without a reflection bridge; Roslyn gives graph errors with source
mapping. An interpreter's only clear advantage is editing a graph during Play without a
compile; revisit that as an optional feature after P3 if the ~1 s compile is too slow.

## P5 — NativeAOT shipping profile and source protection (default for release; November 14, 2026)

**Started November 18, 2026 (user: "Start on NativeAOT"; the user tests on Windows after).** Status below each item;
the first working export is described in "First NativeAOT export" at the end of this section. This stage is last in implementation order, after gameplay parity, visual scripting conversion, portable players and the benchmark gates. "Export Game" must default to **NativeAOT**. An explicitly selected **JIT development/compatibility export** may remain for troubleshooting, but release exports must never silently fall back from AOT to distributable IL assemblies on failure.

### Architecture: distinct development and shipping hosts

- [x] Keep today's precompiled Beef editor and .NET 11 JIT collectible `AssemblyLoadContext` for edit/compile/Play; no native compilation for ordinary script edits.
- [x] Build a **shipping-only** generated C# entrypoint that statically includes the game's trusted `.tasmdef` assemblies, `Tallow.API` and relevant managed runtime implementations, then `dotnet publish -c Release -r <RID> -p:PublishAot=true` as a **NativeAOT player executable or shared native module**, depending on the cross-platform engine linkage design. **Do not call the current `LoadGame` / `Assembly.LoadFile` ALC route** in NativeAOT: dynamic managed assembly loading is unsupported there.
- [x] Decide and test how the Beef native player binds a generated AOT artifact through the **same versioned, checked C ABI and callbacks** as JIT. An AOT native shared library can export `[UnmanagedCallersOnly(EntryPoint = "...")]` functions, but its unloading via `dlclose`/`FreeLibrary` is unsupported. Keep AOT libraries for the lifetime of the shipped process; use complete process restart to load different games. Do not initialize both independent CLR and NativeAOT runtimes for the same gameplay module.
- [x] The current hostfxr shim and collectible context stay editor/JIT-only. Add native AOT entry resolution, ABI version/handshake checks, failure diagnostics and correct native dependency staging **without creating a second engine gameplay implementation**.
- [~] Compile and validate Linux x64 and Windows x64 NativeAOT exports on matching build hosts (and each later supported RID on its supported toolchain). No source, gameplay `.dll`, portable IL or Roslyn compiler assets in the default shipped package; native engine binary/assets are packaged separately as required.
- [~] Preserve explicitly selectable JIT export with the exact same generated gameplay bindings and schedules. UI must show "NativeAOT (recommended, default)" and "JIT (compatibility/debug)" plus any failed AOT preflight issues; no implicit switching.
  NativeAOT is the default (November 18, 2026, user's call): a C# project without `csharpRuntime` exports as
  NativeAOT for Linux and Windows; `csharpRuntime = jit` (Build window: "JIT (compatibility/debug)") chooses JIT.
  Web and macOS builds run JIT. JIT benchmarks and the JIT layout tests pass `--csharp-runtime jit`. A missing
  native toolchain (Visual Studio C++ / clang) fails with how to install it or choose JIT.

### Static registration, metadata and security

- [~] Replace runtime `Assembly.GetTypes`, `Activator.CreateInstance` and unrestricted `FieldInfo.SetValue` for AOT export with **build-generated component registration**, typed constructors/factories, field setter/getter delegates and `[ShowInInspector]`/`[HideInInspector]` metadata and stable serialized **field IDs**. Generate this from the same Roslyn semantic source and retain the JIT-path serialization contract; include migration/version handling for renames, IDs and old scene/prefab data.
  November 18, 2026: the field half is done. Tallow.Build writes `Tallow.FieldTables.g.cs` per assembly: one
  `ManagedField` per instance field of every class and struct the game declares (scripts, data assets,
  `[Serializable]` records and their bases), with a generated getter and setter, the Inspector/`[Saved]`/`[Sync]`/
  `[NonSerialized]` flags read from the attributes, and a `[UnsafeAccessor]` member per private field (structs are
  changed through the boxed instance). It also registers a default-value constructor per type, a `List<T>` factory
  per list element and a `TryGetComponent<T>` lookup per reference field. `ReadFields`, `FieldText`, `ApplyText`,
  nested paths, list items and reference fields use those tables; a type from a package (which the build cannot
  describe) still goes through one reflection fallback, suppressed in the source. Hot reload clears the tables with
  the other caches before the new code registers its own. November 18, 2026 (later): the rest of this bullet is
  done too — callback masks, `UiInvoke`, `[Rpc]` resolution, behaviour-node fields and `ComponentLookup<T>` — see
  "Generated callback, [Rpc], UI and behaviour-node tables" below.
- [~] Do not discover arbitrary reflection metadata at runtime; make required remaining reflection explicit with source generation and trim/AOT annotations. Fail the export on actionable IL2026/IL207x/IL3050-style relevant trim/AOT diagnostics; add a tracked allowlist for justified third-party diagnostics only after review. No user-provided or arbitrary assembly/mod loader in the shipping runtime.
  Export on warnings done November 18, 2026 (`tools/csharp_native.py`): the ILCompiler's warnings are sorted by the
  method they come from. In the game's own code (namespaces its `src/` declares): the export stops, names them and
  says how to fix them (or keep one with `[UnconditionalSuppressMessage]` and a justification, the standard .NET
  way; Tests/CSharpInGame keeps its Newtonsoft round trip and handle check so). In the engine: each must be in
  `tools/nativeaot_allowlist.txt` with its reason (five entries today, 27 warnings: hot reload and the collectible
  load context, JIT only; the editor; everything else — fields, callbacks, `[Rpc]`, UI handlers, behaviour-node
  settings, component lookups — is generated code, with one reflection fallback for types from packages, suppressed
  in the source), and an unreviewed one stops the export. November 18, 2026: `IComponent` now
  declares `GameObject` (every handle and `Script` already had it), so `FormatReference` reads it directly, and the
  Inspector's list-element probe asks which value kinds it formats instead of making a default instance;
  `InspectorElementType` and `FormatReference` left the allowlist (three warnings fewer). Data asset classes are now
  registered by the build (`Tallow.DataAssetRegistry`, a generated constructor each, in a module initializer), so
  `DataAsset.Load`/`Revert` no longer scan assemblies with `GetTypes` or construct through `Activator`; those four
  warnings left the allowlist too. The generated field tables took the last twelve field-path warnings out
  (`ReadFields`, `FieldText`, nested paths, `ApplyText`, list items, references), so the Inspector, saves, `[Sync]`
  and nested records no longer reflect over game types at all; only the package-type fallback does, suppressed in
  source. Tests/CSharpInGame: 47 trim/AOT warnings in all, 0 in the game. Inside third-party packages and .NET: reported per group, not failing (the author cannot change
  them; the game's own calls into a package's unsafe APIs are game warnings and do stop it).
  `build_player.py --aot-warnings report` exports anyway. The export test adds unsuppressed `MakeGenericType` to
  the game and checks that the export stops, names the method and leaves no library, JIT assemblies or .NET
  behind. Generated code has since replaced the rest of the engine's reflection over game types (see "Generated
  callback, [Rpc], UI and behaviour-node tables"), so only the JIT-only and editor paths remain.
- [x] Use the existing curated `[CSharpExpose]` Beef reflection manifest for engine-to-managed APIs; generate bindings at engine build time, verify signature hashes and keep editor JIT/AOT exports on one public API contract. Avoid handwritten duplicated P/Invoke.
- [~] Enable Release + `PublishAot=true`, appropriate platform RID, native optimization and trimming. Validate each compiler/linker option on actual host OS; do **not** turn on `IlcInstructionSet` options that change supported hardware or fast-math flags that change deterministic physics/gameplay semantics.
- [x] Ship stripped binaries and retain matching **private** debug artifacts: Linux `.dbg`, Windows `.pdb` and exact build identifiers/map files, stored outside public download folders. Do not equate stripping symbols with complete tamper resistance: native code is harder to inspect than IL but still reverse-engineerable. Don't remove necessary exported ABI symbols or crash-unwinding data.
  Done November 18, 2026 (`tools/ship_symbols.py`, JIT and NativeAOT exports): a Release export's player is
  stripped of debug information (Linux `objcopy`: `<exe>.dbg` plus a `.gnu_debuglink`; Windows: the linker's
  `.pdb` is copied) and `<output>-symbols/` beside the build (never inside it) holds the symbols, a numeric name
  map of the game library and `build-info.txt`: project, config, platform, runtime, engine commit, game code ID,
  each shipped module's SHA-256 and its exact identifier (ELF GNU build ID; PE PDB GUID and age), and the hashes
  and sizes of the symbol files. Linux player 61 MB → 24 MB; the NativeAOT Linux package 66.7 MB → 43 MB.
  `tools/test_csharp_crash.py` checks it end to end (see B30 below).
- [x] Ensure the release packaging excludes source maps, developer logs, managed game DLLs, API debug metadata and secrets. No embedded credentials; separate developer symbol archive not staged into release.

### JIT versus AOT identical gameplay contract (must pass before release-default toggle)

- [x] Use the **same game source**, C# compiler/TFM, public generated binding signatures, serialized field contracts, native Flecs/Jolt/ENet engine, fixed-tick ordering and network input/authority paths for both profiles. Only deployment/runtime differs; do not maintain separate AOT gameplay scripts.
- [~] Validate default field values, construction/Awake/Start/Enable/Disable/Destroy, component ordering, script attach/detach, scene/prefab load, ECS updates, physics impulses/soft bodies and collision events under both runtimes.
- [ ] Determinism replay: run fixed-seed input streams through JIT and AOT on the same CPU and platform, assert per-tick state hashes for integer/state-machine logic, compare float/vector/Jolt positions with documented tolerances, verify identical server-authoritative results and rollback/desync behavior. Repeat Windows/Linux; JIT/AOT or hardware may legitimately differ at floating-point/ordering edges: fix simulation nondeterminism and quantize where required, **never claim bit-identical floats without evidence**.
- [x] Ban unseeded RNG, wall-clock gameplay time, unordered parallel writes, locale-sensitive parsing and non-deterministic serialization for predicted network state; ensure pre-existing editor hints and release validators flag these.
  Done November 18, 2026: the code editor's determinism hints (GameplayDiagnostics, purple) gained TAL-NET006
  (Parallel/Task.Run/ThreadPool work in a tick), TAL-NET007 (float/double/decimal Parse or Convert without a
  culture), TAL-NET008 (string/object hash codes, System.HashCode), DateTimeOffset/DateTime.Today and Stopwatch
  clocks, and now cover ECS systems' Update(..., TickInput, ...). Tallow.Build links the same file and lists them
  when it builds a game for release (`path(line): warning TAL-NET...`); warnings, as in the editor, not errors.
  Tests: 5 new language-service checks (139 pass); the export test adds a script with two and checks they are
  listed and the build carries on.
- [x] Verify AOT and JIT callbacks use identical versioned structs, `UnmanagedCallersOnly` exports with strictly blittable types (not `bool`/managed strings), C calling conventions and resource ownership.
- [ ] Run B24–B30 in [benchmark plan](csharp-benchmark-plan.md), including GC, startup, input replay, network peers, binaries, trim root stability and symbol retention. Ship NativeAOT by default **only after** both runtime profiles pass complete cross-platform tests; until then existing JIT development/play workflow stays functional.

### C# web test repaired (November 18, 2026)

The browser game stopped at start since the behaviour-tree nodes (c2e533a0): .NET's WebAssembly interpreter calls
native code with at most 12 integer argument slots (mono interp.h `INTERP_ICALL_TRAMP_IARGS`) and exits on more
(`interp.c:1502 build_args_from_sig`), and `CSharpBehaviorNodes.Register` took 13 (each string is a pointer and a
length). Tallow.BindingGen now packs a binding's strings into one array of (pointer, length) pairs
(`NativeStringArg` / Beef `CSharpStringArg`) when its signature would go over, the same ABI on every platform
(3 bindings: Register, Export, WorkshopPublish), and fails generation if one still would. Two newer checks assumed
threads (a save finished from another thread, terrain Fill on workers) and now allow the browser's single thread;
the zero-allocation check measures past the interpreter's tier-up there. `test_csharp_web.py`: 405 checks pass.

### First NativeAOT export (November 18, 2026)

- **Design.** `tools/csharp_native.py` (called by `tools/build_player.py --csharp-runtime native`, or
  `csharpRuntime = native` in project.tallow, or the editor's Build window) writes a small publish project that
  references Tallow.ManagedRuntime and the game's compiled Release assemblies (the same ones a JIT export ships,
  all `TrimmerRootAssembly`) plus one generated file exporting `tallow_native_register`, and runs
  `dotnet publish -r linux-x64|win-x64 -p:PublishAot=true` (`NativeLib=Shared`). The package gets
  `Managed/Native/libTallowGame.so` / `TallowGame.dll` and `Tallow.Game.codeid` only: no `dotnet/`, no `Managed/Game`
  or `Managed/Runtime`, no IL, no .pdb/.dbg. Native symbols and the trim/AOT warning report go to
  `<output>-symbols/` beside the build.
- **Binding.** The precompiled player (unchanged Player/, same exe for JIT and AOT) sees `Managed/Native/` and calls
  `tn_csharp_init_native` (native/tallow_dotnet_host.cpp) instead of hostfxr: it loads the library for the life of the
  process, calls `tallow_native_register(register, TN_CSHARP_NATIVE_ABI, error, capacity)`, and the library's
  `NativeHost.Register` hands over the same entrypoint table the JIT host binds by name (`NativeEntrypoints.Table()`,
  also used by WebHost now) after checking the ABI version (mismatch: a message naming both versions). It refuses to
  start beside a running CLR. `LoadGame` takes the compiled-in generated registry (no ALC, no Assembly.Load);
  `ReloadGame` refuses.
- **Module initializers** run when the library is first called, before the engine binds: the two that call the engine
  (`EcsSchemas.Register`, `EcsSystems.Register`) now queue that call (`GeneratedNativeApi.WhenBound`), replayed in
  order by `Bind`. JIT behaviour unchanged (bound already).
- **Generic code made by reflection.** Tallow.Build generates `Tallow.AotRoots.g.cs` in each assembly: a never-called
  method naming `List<T>`, `T[]` and `TryGetComponent<T>` for every Inspector field type of every script (and of the
  [Serializable] classes/structs they hold), so the AOT compiler builds what `ParseList`/`ParseReference` look up.
  New `GameObject.AddComponent(Type)` / `Script.AddComponent(Type)` (the generic one now calls it) needs no generic
  code at run time. `BehaviorNodes` no longer reads `MetadataToken` (unsupported in NativeAOT; field order kept).
- **Windows from Linux.** ILCompiler targets win-x64 on Linux with `DisableUnsupportedError`,
  `IlcUseEnvironmentalTools`, `lld-link` and the xwin SDK/CRT in `TALLOW_WIN` (a `Synchronization.lib` alias for the
  case-sensitive file system; `EnableSourceLink=false`, lld-link has no /SOURCELINK). On Windows it is the normal
  MSVC link. `python3 tools/csharp_native.py check` reports what this machine can build. November 18, 2026: the
  field tables made the game's symbol set large enough to hit a crash in the Linux lld 22.1.8 Windows PDB writer
  (`GSIHashStreamBuilder::finalizeBuckets`); when the link dies with a segmentation fault, the export links again
  with the Windows `lld-link` Beef's toolchain carries, under Wine, reading the analysis warnings from both runs
  (the retry reuses ILCompiler's cache). A machine without that toolchain still links with the system lld.
- **Results.** `tools/test_csharp_export.py --runtime native`: Tests/CSharpInGame (with a NuGet package,
  Newtonsoft.Json) passes all **421** in-engine checks on Linux and, cross-built, on Windows under Wine (the same
  count as the JIT export). The editor's Build window made the same Windows build (`--build-window --build-windows
  --build-native-aot --build-now DIR`; 420 under Wine). Library 17 MB (vs. 73-82 MB of bundled .NET plus IL for JIT).
  Trim/AOT analysis: 72 (Linux) / 77 (Windows) warnings, nearly all reflection over the rooted assemblies and in
  ReloadMigrator/ALC code a NativeAOT game never runs, plus Newtonsoft.Json's own; listed in the report, not yet
  failing the export.
- **CI.** Linux job: `test_csharp_export.py --runtime native`; Windows job: the same, built natively with MSVC.
- **Not done yet:** a run on a real Windows machine (the user's test); NativeAOT became the default before it, at
  the user's request; B24's acceptance switch and B30's Windows half; the Windows/cross-OS halves of B25-B28
  (Linux halves measured: docs/csharp-benchmark-plan.md; Windows halves under Wine: B25-B27, see the same file);
  macOS.

### Generated callback, [Rpc], UI and behaviour-node tables (November 18, 2026)

- The runtime no longer reflects over game types on the paths it takes every frame or on every network call.
  Tallow.Build writes these into the same per-assembly `Tallow.FieldTables.g.cs` module initializer as the field
  tables:
  - `ManagedCallbacks`: the lifecycle callbacks each `Script` class declares (EarlyUpdate/Update/LateUpdate,
    FixedUpdate, LocalEarlyUpdate/Update/LateUpdate, OnGUI, OnWorldStateChanged, sequence/dialogue/tree events,
    OnClientJoined/Left and the three prediction-state hooks). The engine's per-class callback mask is a table
    lookup now, not `Type.GetMethod` for nineteen signatures. A class described with no callbacks is as important
    to know as one with them.
  - `ManagedUi`: a `.tui` handler's three shapes (no argument, `UIElement`, `string` id) as direct calls through
    `[UnsafeAccessor]` members, private methods included.
  - `ManagedRpcs`: every `[Rpc]` method with its target, parameter types and a direct call. An invalid one
    (generic, returning a value, a parameter type an RPC cannot carry) is registered with the error the reflected
    lookup would give, and overloading is still refused when the RPC is called; an `[Rpc]` inherited by an
    override counts, as it did through the attribute's `Inherited`.
  - Behaviour-tree node settings: `BehaviorNodes` takes a node class's fields in declaration order from the field
    tables (public, writable, of a setting type), base classes included, instead of listing its own.
- A type from a package (no game assembly describes it) keeps the reflection fallback for its own members, marked
  `[UnconditionalSuppressMessage]` with its reason; the lookup then carries on with the rest of the hierarchy, so a
  game class derived from a package class finds the package class's handlers, RPCs and (for behaviour nodes) its
  settings fields. A callback mask is generated for the class from its symbols, so it counts the package base's
  callbacks already. `tools/nativeaot_allowlist.txt` is down to five entries, all
  paths a NativeAOT game never runs: hot reload and the collectible load context (JIT only) and the editor. The
  NativeAOT export reports 27 engine warnings, 0 unreviewed (was 46 at 718a5ece).
- Checks: in-game 442 (new: the generated callback mask and the generated `[Rpc]` table), network 32 (RPCs across
  a session, every argument kind, private methods), reload 33 (the tables clear and re-register), JIT export 423
  and NativeAOT export 423 on Linux and on Windows (under Wine), language service 139, sample, showcase and the
  trusted smoke test.

### Release symbols, build identifiers and reading a crash (November 18, 2026)

- `tools/ship_symbols.py`, called by `tools/build_player.py` for every C# Release export (JIT and NativeAOT):
  the package's player keeps no debug information, and `<output>-symbols/` beside the build (never inside it)
  keeps what reads a crash. Linux `objcopy` writes `<exe>.dbg`, strips the debug sections and adds the
  `.gnu_debuglink`; Windows copies the linker's `TallowPlayer_lld.pdb`. `build-info.txt` names the project, config,
  platform, runtime, engine commit and game code ID, and for the player and the game library the SHA-256, size and
  exact debugger identifier (ELF GNU build ID; PE PDB GUID and age), plus every kept symbol file's SHA-256 and
  size. `libTallowGame.so.dbg.map` is an address-sorted, demangled name map for tools without DWARF. Unwind data
  and exported ABI symbols are untouched; the package holds no `.dbg`, `.pdb`, `.map` or `.debug_*` section.
- Player 61 MB -> 24 MB on Linux; the NativeAOT Linux package 66.7 MB -> 43 MB. The private symbols are bigger
  (Linux NativeAOT: player `.dbg` 44 MB, library `.dbg` 31 MB, code-symbol map 7 MB; Windows: the 41 MB `.pdb`),
  kept beside the build and never uploaded with it.
- `--crash-test` (Application, test only): at frame 100 the game writes through a null address read from a
  volatile field, so the release optimiser cannot remove it (a plain null store is undefined behaviour and was
  removed; the first attempt exited cleanly). It is documented as a test switch and does nothing unless given.
- `tools/test_csharp_crash.py` (local: needs gdb and a full NativeAOT build) builds Tests/CSharpInGame as a Linux
  NativeAOT export and checks (5 checks pass): the package ships no symbols or debug sections; the private folder
  holds the player `.dbg`, the library `.dbg`, its map and `build-info.txt`; the recorded SHA-256s and the
  library's GNU build ID match the shipped files and the code ID is recorded; the package runs in an empty
  environment (no .NET, Beef or `dotnet` on `PATH`) and passes its 421 in-game checks; and a `--crash-test` run
  under gdb is a SIGSEGV whose `bf::Tallow::CrashReports::DeliberateCrash()` frame and callers are named **only**
  through the private `.dbg`. Windows writes the `.pdb` by the same path; a Windows crash was not symbolicated
  here (that half of B30 needs Wine's debugger or a real Windows machine).

**Why a separate player:** Microsoft's NativeAOT compiler does not support dynamically loading managed assemblies, and a NativeAOT **shared library** cannot be unloaded. Neither is compatible with the editor's current JIT collectible AssemblyLoadContext. NativeAOT itself is not a security boundary against code reverse engineering or memory inspection. See Microsoft's NativeAOT deployment / native library / interop docs:
https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/
https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/libraries
https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/interop



### NativeAOT serialization groundwork — generated stable IDs (November 14, 2026)

- Added optional `[SerializedFieldId("motion-state-v1")]` on C# fields.
  During normal C# project compilation, Roslyn now emits a separate
  `.tallow-csharp/fields-aot.tsv` **build-only** catalog containing a stable
  128-bit field ID, component type name, source field name, data kind and hidden
  marker. The ID is SHA-256 truncated to 128 bits over a versioned namespace,
  component's qualified name and either the explicit attribute ID or original
  field name. Explicit IDs preserve the identity on *field* renames within the
  same component. Moving a field to another component changes its ID.
- Duplicate/invalid IDs fail catalog generation. The JIT editor's existing
  scene/prefab name-based overrides and `fields.tsv` are **unchanged**; this
  is not yet AOT generated getter/setter registration. The shipping compiler
  must consume the generated IDs and implement backward-compatible migration
  from legacy names before enabling the new scene format. No text manifest
  should ship with protected NativeAOT exports.
- Added fixture [SerializedFieldId] usage and Linux/Windows build-step CI
  checks for the generated catalog. **Validation pending** actual managed CI,
  JIT Inspector regression, and later NativeAOT field delegate generation.


### AOT serialized field identity tests (November 14, 2026)

- The Linux/Windows managed build workflow now copies the C# Inspector
  fixture into a disposable directory, renames an explicitly identified
  enum field and re-builds it. The generated AOT ID must remain identical.
- CI also applies the same explicit ID to a second field and requires a
  descriptive duplicate-identity build failure.
- These tests verify source-generation stability only. The existing JIT
  scene serializer still uses field names and AOT factory/setter generation
  is not yet implemented. Cross-runtime scene migration is still pending.


### C# code editor CI repair and Inspector string fields (November 14, 2026)

- A completed earlier Linux/Windows GitHub Actions run failed Roslyn's
  "private user gameplay members still appear in their own class" test.
  The accessibility check was being evaluated at the **EOF caret position**
  while typing incomplete `this.se` expressions. The language service now
  checks inside the source span, preserving private members of the enclosing
  class without exposing private base/other-class members (commit `7279646`).
  A subsequent intermediate Linux managed CI passed its Roslyn suite and
  C# gameplay/Inspector catalog tests; the latest Linux/Windows/full native
  build still needs independent confirmation.
- Added **single-line string** public/private/hidden Inspector values using
  the same Tallow `[ShowInInspector]` and `[HideInInspector]` policy as
  scalar fields. The compiler generates string field rows/defaults, the Beef
  Inspector offers a single-line text input, and the managed runtime restores
  text values before `Awake`. Source defaults containing tab/newline/NUL
  are rejected with a build diagnostic until escaped string serialization
  exists. String editing explicitly rejects these separators too.
- Host smoke verifies public/private/hidden text, [NonSerialized] exclusion
  and malformed tabbed content; the Linux/Windows field catalog checks
  string kinds and visibility. Strings with embedded newlines/tabs, collections,
  nested objects, object references and asset references are **still pending**.
- Critical lifecycle fix: `CSharpBehaviour.Awake` now detaches a managed
  instance when restoring serialized overrides fails or the managed `Awake`
  dispatch fails. A partially initialized script cannot proceed to enabled,
  Start or networked callbacks. Editor `WriteEditorField` now rejects
  unrepresentable separators, validates runtime application **before** it
  commits the new value, and reports success to dirty-state tracking rather
  than silently persisting bad data. User's native scene test remains needed.


### Generated C# component factories across assembly definitions (November 14, 2026)

- The C# project generator now parses trusted game and `.tasmdef` source
  through Roslyn before compilation and creates one **direct constructor
  factory per assembly**, plus a central `TallowGeneratedGameRegistry`
  in the main game assembly. The main registry calls each assembly factory
  explicitly, without scanning assemblies or dynamically constructing
  types at call time. Factories support internal gameplay classes within
  their own assemblies and fail early on unsupported inaccessible types
  or missing accessible parameterless constructors.
- Generated files live **only** under `.tallow-csharp/generated`, not in
  the game source folder; no-op builds preserve generated timestamps.
  Normal editor JIT hot reload and existing `[Component]` scene naming
  continue unchanged. This is **NativeAOT registration groundwork**, not
  a completed AOT export or a generic Flecs data component bridge.
- The managed host smoke calls the generated main registry to instantiate
  `Gameplay.MoveRight` defined in a referenced `.tasmdef` assembly and
  confirms missing names return null. CI Linux/Windows compilation and
  in-editor Nobara tests are still required.


### Shared JIT/NativeAOT C# component factory contract (November 14, 2026)

- Introduced `IGameplayComponentRegistry` in Tallow.API. The Roslyn
  prebuild generator emits a strongly typed, explicit component-name list
  and direct factory methods across trusted gameplay `.tasmdef` assemblies.
- The development `Tallow.ManagedRuntime` now binds the **one generated
  registry** through the trusted game's assembly rather than calling
  `Assembly.GetTypes` on every game dependency and `Activator.CreateInstance`
  for every component. The JIT editor keeps its trusted collectible
  `AssemblyLoadContext` for hot reload; native GameObject/scene
  ownership and callback scheduling are unchanged.
- On Play/Stop or failed game activation, runtime clears the generated
  registry reference **before** unloading the JIT game assembly, preventing
  an inadvertent long-lived ALC root. Old gameplay DLLs that predate
  generated registries require a rebuild; the editor reports this.
- The same interface/factory implementation is now a candidate to be
  statically rooted by the future NativeAOT shipping player. **AOT export
  is still not built** and generated field setters, custom Flecs ECS
  layout registration, cross-platform real editor tests and benchmark
  parity remain pending.


### C# ECS data schema discovery — bridge groundwork (November 14, 2026)

- The normal C# game build now scans `[Component]` structs using Roslyn and
  writes a build-only `.tallow-csharp/ecs-data.tsv` description: qualified
  type, field name, scalar/vector kind, and whether a field uses `[Sync]`.
  Each type has an explicit `@layout=candidate` or `unsupported` record.
  Only non-generic unmanaged structs containing supported mutable scalar,
  vector and quaternion fields qualify as candidates.
- A candidate is **NOT YET a registered native Flecs component**. The
  shipping/native C# bridge must still validate actual C# ABI layout,
  alignment, field offsets, network marshaling and lifetime, then provide
  typed reads/writes through the engine's existing Flecs World. This pass
  does not write RigidbodyData behind Jolt's back or claim replication.
- Added C# test structs with supported `[Sync] Vector3` and ordinary float
  and int fields, plus a managed `string` reference that must be marked
  unsupported. Linux/Windows CI checks the generated schema. The next
  workstream is native layout registration and bounded bulk set/query
  operations, then true synced C# data replication and deterministic replay.
- All benchmarks requiring writable C# Flecs data (B12, related B18/B20)
  remained **blocked** at the time (B12 is done since November 15, 2026:
  in-place `ForEach` over Flecs columns), and the new schema must never be shipped as
  reflective gameplay source metadata in default NativeAOT packages.


### Deterministic C# build outputs and no-op compile behavior (November 14, 2026)

- The game/assembly-definition project generator no longer rewrites an
  unchanged generated `.csproj`. It compares the deterministic in-memory
  XML bytes before writing, preventing spurious MSBuild invalidation of
  dependent C# assemblies.
- The component, Inspector field, source-mapping, stable AOT field-ID and
  ECS candidate manifests are now only atomically replaced when their
  textual contents actually differ. This avoids triggering needless editor
  catalog reloads during no-op game builds while preserving atomic updates.
- The generated static C# factory source already preserves timestamps
  when unchanged. Together these changes target benchmark B03 (no-op and
  warm edit), but **no speedup is claimed until measured** on Nobara.
- Linux/Windows managed CI must confirm this output policy compiles
  consistently. Engine native builds and interactive editor performance
  remain separate acceptance tests.


### Bounded local Flecs entity lifecycle from C# (November 14, 2026)

- Added [CSharpExpose]-generated `Ecs.CreateLocalEntity`,
  `Ecs.CreateLocalEntities` (one bounded native call with a caller-owned
  Span<ulong>) and `Ecs.DeleteLocalEntity`. These operate directly on the
  active scene's existing native Flecs World; no shadow C# ECS and no Jolt
  state writes. The managed `Scene` and `EcsEntity` types expose familiar
  `CreateLocalEcsEntity`, `CreateLocalEcsEntities` and `DestroyLocal`.
- Native guards reject stale sessions, entity zero/dead IDs, deletion of
  entities linked to a GameObject, and **networked scenes**. This is
  deliberately a local-only bare-entity feature, not networked entity
  spawning or an implementation of writable typed C# ECS columns.
- Native host smoke covers single and bulk creation, generation-aware
  is-alive lookup, deletion/duplicate cleanup, invalid session and forbidden
  deletes. CSharpExpose manifest and ABI hash checks cover the new methods.
  Managed CI and a full Beef Linux build are needed before treating this
  increment as verified.
- Future priority: full source-generated C# ECS layout/offset registration
  with an exact-size/alignment handshake; typed batched writes through
  Flecs's staged World; [Sync] replication and rollback across networked
  scenes, and benchmark B12/B18/B20 validation. Never silently treat a
  local-only entity as replicated gameplay.


### Native-ABI byte spans for future typed ECS data (November 14, 2026)

- The narrow, generated CSharpExpose ABI now accepts explicitly declared
  `Span<uint8>` (`System.Span<byte>`) parameters. The binding generator
  creates a counted `uint8*` native input/output buffer with guarded null/
  negative lengths and a pinned C# `byte*` for one synchronous call.
- A generator self-test verifies the Beef and C# signatures and ownership
  rules. No new gameplay API uses this buffer yet, and no arbitrary C# structs
  are written to Flecs. Future component registrations must still validate
  sizeof/alignment/schema, scene session, authority and layout compatibility.
  `Span<byte>` is not an invitation to expose unrestricted native pointers.


### Local-only C# Flecs component round-trip binding

The existing World-level offline-only schema registration, opaque
`Span<uint8>` transfer and component presence operations now have matching
`[CSharpExpose]` fixture signatures, native-host ABI symbols and managed
`Scene.RegisterLocalEcsData` / `EcsEntity.SetLocalData` /
`EcsEntity.TryCopyLocalData` / `EcsEntity.HasLocalData` accessors.
The native-host smoke exercises registration reuse, incompatible size/alignment,
stale sessions, forbidden native-owned entity IDs, absent components, exact
byte round trips, short buffers and deletion cleanup. The host is a controlled
ABI double, not a real-Flecs correctness benchmark.

These APIs are **experimental offline-only opaque data transport**, not
authoring-friendly typed ECS, networked replication or a supported way to
manually create native Jolt data. Source-generated C# field-layout validation
and typed `[Component]` adapters are still required before general gameplay
and NativeAOT player use. `[Sync]` does not yet replicate these fields.


### Source-generated typed offline C# ECS data adapters

- The trusted gameplay builder now emits `Tallow.EcsLocalData.g.cs`
  per assembly for eligible `[Component]` unmanaged structs containing
  supported primitive/Vector fields. Generated C# extension methods
  `EcsEntity.SetLocalData(in T)` and `EcsEntity.TryGetLocalData(out T)`
  transfer one struct to/from the existing native Flecs opaque data storage
  via the counted, pinned byte-span ABI. They do not require handwritten
  per-component bindings, unsafe C# gameplay, runtime reflection or scanning.
- Generated schema IDs hash assembly, full type name, field names/types and
  declared attributes so same-size declaration edits cannot silently reuse
  a native Flecs ID. Registration passes the actual C# `Unsafe.SizeOf<T>()`
  and byte alignment 1: this is an **opaque byte column**, not yet a
  natively introspectable field layout. Field-level native offsets still
  require explicit generated layout verification in the following phase.
- Calls reject networked scenes, dead or foreign Flecs entities, bad
  sessions and mismatched buffer lengths on the native side. Unmanaged
  struct byte buffers remain local-only and must not be interpreted as
  deterministic, cross-platform network payloads. [Sync] is not wired yet.
- The native-host managed smoke tests typed VelocityData round trips and
  deletion; CI checks that unsupported managed-reference structs have no
  generated extension. Verify all jobs before considering this complete.


### C# Script discovery no longer requires [Component]

- All non-abstract, non-generic classes deriving from `Tallow.Script`
  are discovered by the trusted Roslyn factory generator and Inspector
  catalog through inheritance. Neither the build catalog nor static
  JIT/NativeAOT registry requires `[Component]` for these classes.
- `GameObject.AddComponent<T>()` likewise accepts any concrete,
  non-generic `Script` subtype; the trusted generated registry and
  native object/session checks still enforce attachment validity.
- `[Component]` remains the explicit annotation for standalone C#
  `struct` ECS data components; ordinary struct types are **not**
  automatically registered. The attribute is tolerated on existing script
  classes for compatibility but is not needed going forward.
- Smoke tests use unannotated `Gameplay.MoveRight` and
  `Gameplay.AddComponentSmoke` to cover cross-assembly static
  registry discovery, Inspector catalog and runtime component attachment.


### Cached native Flecs query pages for offline C# data (November 14, 2026)

- The existing opaque C# schema registry now owns cached read-only Flecs
  queries that are released before the native World. The new
  `Ecs.CountLocalData` and `Ecs.CopyLocalDataPage` exports iterate
  actual Flecs tables to copy contiguous native column data and Flecs entity
  IDs into bounded, caller-owned buffers in one interop call per page.
- Native limits: 4096 entity IDs and 4 MiB of bytes per call; negative
  page offsets and missing schema IDs are rejected. A partially consumed
  Flecs iterator is explicitly finalized on early exit.
- Source-generated
  `Scene.CopyLocalDataPage(offset, Span<ulong>, Span<T>)`
  helpers provide type-safe, allocation-free page reads for eligible
  unmanaged [Component] structs. Page order can change after ECS structural
  mutations; callers must not assume stable offsets across such changes.
- This remains offline-only; networked [Sync] data, authoritative
  spawning, rollback and true performance measurements are pending.
  The C++ test host verifies generated span marshalling and output sizes;
  full real-world Flecs behavior still needs editor-in-scene tests.


### In-place C# ECS ForEach (November 15, 2026)

- `Scene.Query<T1[,T2[,T3]]>().ForEach` no longer copies rows out and back:
  `Ecs.BeginDataIteration` / `NextDataTable` / `RefreshDataTable` /
  `EndDataIteration` hand C# each matching Flecs table's column addresses,
  entity ids and table version, and the action gets `ref`s straight into the
  columns (one native call per table). The page-copy exports
  (`CopyDataPage`, `WriteDataPage`, `WriteDataPageOrdered`) are removed.
- While a ForEach runs, C# structural changes (new data, `Remove`, creating
  or deleting bare entities) go to a Flecs stage of their own
  (`ecs_stage_new`; stage 0's queue is flushed by any immediate change) and
  merge when the outermost ForEach ends, even when the action throws. Engine
  work (GameObjects made, moved or destroyed in the action) stays immediate;
  if it moves rows of the table being walked, the table version changes and
  C# re-reads the columns. New values for data an entity already has are
  written at once (Flecs's own deferred-set behaviour).
- In-game checks cover visits, queued vs immediate writes, GameObjects made
  and destroyed in the action, exceptions and nesting (216 pass).
- 50k entities, Release: C# 2.08 ms vs Beef 1.53 ms (was 4.98 ms).
- Next for scale: the GameObject Transform path (one native call per
  get/set), the `TieredPGO` decision for the game runtime, then networked
  [Sync] ECS data.
