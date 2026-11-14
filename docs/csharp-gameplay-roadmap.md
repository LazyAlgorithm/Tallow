# C# gameplay migration — actionable roadmap and handoff

Last updated: 2026-11-13. Source branch: **feature/csharp-gameplay** of [LazyAlgorithm/Tallow](https://github.com/LazyAlgorithm/Tallow). Keep changes on this branch, **not** `ecs`, until acceptance tests pass. Also read [C# architecture and current implementation](csharp-gameplay.md).

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

## P0 — stabilize, compile, test full precompiled native editor

- [ ] Pull current HEAD and run full Nobara Linux **BeefBuild** of Tallow native/editor/launcher. Fix all compiler errors introduced by migration; add CI native editor builds to catch these without depending on the user's testing.
- [ ] Test launcher opening **existing, empty, and broken C# game projects**. Confirm same precompiled editor opens each and no per-project BeefBuild or native toolchain discovery blocks opening.
- [ ] Validate the `--open PROJECT`, `--build-project PROJECT` (.NET only), `--game --project PROJECT`, and explicitly legacy `--build-native-project PROJECT` routes. Confirm direct project opening does not build a project-specific native binary.
- [ ] Test script-save and external editor changes: compilations must target current sources, no stale results or stale Play-enable flags. Check the C# source scanner after file create, move, rename, delete.
- [ ] Ensure invalid C# (including errors without a source location) keeps scene/Inspector/Scripts editor usable, logs SDK errors in Console, and disables Play. Fix code in Tallow, compile, then Play.
- [ ] Check Play/Stop/Play, repeated scenes, prefabs, missing .NET runtime, missing game DLL, game shutdown and cleanup. Verify no stale entity handles, duplicate callbacks, memory leaks or active managed instances after Stop.
- [ ] Empty projects without scripts should start normally with no false "missing compiled game DLL" error; distinguish projects with no C# components from invalid managed gameplay.
- [ ] Confirm compile-success toast clears after 1000 ms, but errors and newer status messages are never cleared by the timer.
- [ ] Confirm old/native Beef authoring remains explicitly accessible for compatibility but is not required on the C# path.

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

- [ ] Check that `Transform.Position += Vector3.UnitX * Speed * deltaTime` and other `Vector2/3/4` operations compile in-game **without false Roslyn editor errors**; align SDK global usings and actual `.tasmdef` references.
- [ ] Complete semantic token coloring (classes, methods, fields, types, namespaces, attributes, generics, strings/interpolation, comments, keywords), rather than relying solely on lexical C# highlighting.
- [ ] Completion from the compiler for ALL relevant accessible classes, methods, fields, properties, overloads, inherited/interface members, extension methods, generics, enums, namespaces, symbols in project assemblies and installed referenced libraries.
- [ ] Add accurate completion context/ranking, insertion text, auto imports, braces/parentheses, parameter/return type display and XML documentation. Do not suggest private/inaccessible or irrelevant static/instance members.
- [ ] Implement robust overload-aware signature help and active argument highlighting; no overlapping code editor popups.
- [ ] Build persistent incremental Roslyn project state instead of recreating a compilation per request. Measure warm/cold latency and memory/CPU on Nobara/Windows; properly cancel stale requests, debounce typing, restart failed workers, and handle multiple files.
- [ ] Full diagnostics, warnings, source locations/underlines, click-through from Console; Go to Definition, Find References, Rename, and optionally integrated breakpoints/debugging.
- [ ] Expand automated tests using actual Tallow.API/gameplay source, multi-assembly projects, inherited/static/extension completions and malformed mid-typing C#.

## Binding generation decision — explicitly curated API

**User preference confirmed:** Native Beef types/members should **not** all become C# APIs automatically. Only explicitly selected gameplay-safe surface is exported; keep engine internals invisible to normal C# authors. Keep hand-written adapters for systems that cannot be marshaled safely or efficiently.

- [x] Define Beef `[CSharpExpose]` marker (type plus individual public member, with no "expose all" default). File: `Engine/src/Scripting/CSharpExpose.bf` (commit `8d903af`). **Attribute only; not wired to generation yet.**
- [x] Record binding generator and marshalling rules in `docs/csharp-expose.md` (commit `f20bab4`).
- [ ] Generate deterministic opt-in exposure manifest from actual Beef compiler/reflection symbols; validate signatures and emit actionable errors for unsupported attributes.
- [ ] Generate ABI-stable native entrypoints and C# wrappers together from manifest, with no duplicate manual C# declarations, preserving existing handwritten adapters.
- [ ] Verify an annotated method is callable from C#, appears in Roslyn, and a public unannotated member is omitted. Add CI tests for Windows/Linux.
- [ ] Add safe automatic primitive/vector/enum mappings, checked GameObject/Transform handles and UTF-8 string lifetime handling. ECS/Jolt/networking require specialized safe adapters.
- [ ] Run generation only with engine builds; normal project C# edits compile with dotnet only. Track generated API version to prevent mismatch with precompiled runtime.

## P2 — gameplay API parity (largest workstream)

For every subsystem, expose a managed public API, safe native handle bridge, correct lifetime/serialization semantics, appropriate network/deterministic scheduling and automated tests. Work in small verified increments:

- [ ] Core GameObject/Transform parenting, rotation/scale, scene/object creation/destruction, asset/prefab loading, lifecycle and event callbacks.
- [ ] Component discovery and access: `GetComponent<T>`, `AddComponent<T>`, fields/properties, object/component references, multiple components, enabling/disabling.
- [ ] Flecs ECS: managed data components, filters, typed queries, iteration, systems, group/tags, efficient bulk update, lifetime and thread safety while hiding complexity from typical gameplay.
- [ ] Jolt physics: rigid bodies, forces, collision/trigger callbacks, raycasts/shape casts, character controls, constraints/joints and physics queries.
- [ ] Native network features surfaced to C#: networked TickInput/actions, authority/ownership, spawning, replication, prediction/reconciliation, rollback, RPCs, lag compensation, relevancy and state sync, working by default.
- [ ] Rendering, materials, shaders/compute graphs, cameras, lighting, mesh/voxel/terrain, animation/IK, sequencer and modeling tools.
- [ ] Audio/voice, UI/GUI, asset management, navigation/behavior trees, world streaming/world states, persistence/save/load, gameplay time and platform APIs.
- [ ] Inspector: add string, enum, arrays/lists, serializable nested types, asset/GameObject/component references, undo/redo, prefab overrides and validation. Current user-confirmed subset is numeric/bool/vectors and persistence.
- [ ] High-quality XML API docs, editor tooltips, C# script templates, practical gameplay examples, and repeatable Beef-versus-C# parity tests.

## P3 — convert visual scripting and sample content

- [ ] Preserve existing visual graphs and nodes while generating C# instead of native Beef gameplay code.
- [ ] Permit graph-to-C# calls, C#-to-graph events/operations, automatic C# type/method node discovery, managed ECS & networking nodes, and correct graph errors/source mapping.
- [ ] Convert the legacy starter projects, sample/voxel sandbox/showcase content, tutorial code and code-generation templates; newly created projects should not expose Beef to normal C# authors.
- [ ] Keep shader graph/compute graph/rendering functionality intact; never confuse visual **gameplay** source generation with native shader compilation.

## P4 — performance, reload, shipping exports, hardening

- [ ] Measure cold compile, warm single-file edit, no-op compile, incremental assembly build and edit-to-Play. Compare with legacy Beef workflow and relevant older/current Unity baselines without promising a specific speed.
- [ ] Incremental C# per-`.tasmdef` builds with correct dependency invalidation, diagnostics and simultaneous builds; avoid unnecessary full-game builds on every edit.
- [ ] Implement reliable collectible AssemblyLoadContext hot reload, cleanup of managed tasks/timers/events and native handles, Inspector field/state preservation, resource unload and no editor crash; test multiplayer determinism.
- [ ] Package precompiled per-platform player/engine plus C# assemblies, runtimeconfig, .NET runtime/dependencies, shaders and assets into independently redistributable Windows/Linux exports. Verify on machines without BeefBuild.
- [ ] Confirm no unsafe untrusted mod loading, directory escape, premature engine pointer exposure or unmanaged ownership errors.
- [ ] Extend CI beyond managed/.NET host smoke tests to native Beef editor/launcher builds, precompiled player startup and real C# in-scene integration tests on Linux and Windows.

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
