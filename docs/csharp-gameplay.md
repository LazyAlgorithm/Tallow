# C# gameplay integration (experimental branch)

C# is the intended **gameplay-facing scripting language** on `feature/csharp-gameplay`.
The engine and editor implementation can remain native Beef internally. No shipped
C# editor workflow may display Beef or generate `.bf` gameplay scripts once migration
is complete.

## Current implemented foundation

- Target .NET 11, C# 15, nullable-enabled managed projects.
- `Managed/Tallow.Build` generates `Tallow.Game` and assembly-definition projects.
- `*.tasmdef` JSON files describe trusted gameplay assembly boundaries:
  `{"name":"Gameplay","rootNamespace":"MyGame.Gameplay","references":["Core"]}`;
  `rootNamespace` is optional (default: the name) and is what new scripts in that folder
  use. Nested definitions own their own trees. Click one in the Project panel to edit it
  in the Inspector (references, checks, Apply/Revert).
- `Managed/Tallow.API` contains initial managed game types and callbacks.
- `Managed/Tallow.ManagedHost` and `Tests/CSharpGameplay` are managed smoke-test scaffolding.
- `Managed/Tallow.ManagedRuntime` exports trusted C# script lifecycle functions to native code.
- `native/tallow_dotnet_host.cpp` hosts .NET with hostfxr on desktop; WebAssembly has a no-runtime stub.
- `Engine/src/Scripting/CSharpRuntime.bf` provides a validated scene/entity-handle bridge.
- `Engine/src/Scripting/CSharpBehaviour.bf` forwards native component callbacks and tick input.
- `[Sync]` on a script field (public or private; numbers, bool, string, enums, vectors) shares
  the server's value with every client of a session when it changes, and with players who
  join later. Change it on the server; a client's own changes are overwritten.
- NuGet packages: list them in a folder's `.tasmdef`, one exact version each:
  `"packages": [{ "id": "Newtonsoft.Json", "version": "13.0.4" }]`. Scripts in that folder (and
  the main game assembly) can use them; built games ship them with `THIRD-PARTY-NOTICES.txt`.
  Package code is not checked by Tallow, so use packages you trust.
- `await` works on the game thread: `await NextFrame();`, `await Wait(2f);` (game time),
  `await Task.Delay(ms, Destroyed)`. Code after an await runs once a frame after LateUpdate
  and may use the engine. Waits end when the script is destroyed; pass `Destroyed` to other
  async calls. Avoid `ConfigureAwait(false)`: the engine must not be used off the game thread.
- More callbacks: `OnFrame()`, `OnValidate()` (a field changed in the Inspector during Play),
  `OnDrawGizmos(bool selected)` (draw with `Gizmos.Line/Sphere/Box`; `DebugDraw` draws in the
  game too), `OnNetworkEvent(name, value)` with `SendNetworkEvent(name, value)`, and the save
  hooks `OnSaving()`/`OnLoaded()`.
- `[Saved]` fields are kept in save games: `SaveGame.Save("slot")` and `SaveGame.Load("slot")`.
- An exception in a script is logged once in the Console (repeats count up), with the file
  and line it was thrown on; click it to open the script there. The script keeps running.
- Renaming a script class: the editor follows a class renamed inside its file by the file's
  `.tmeta` ID. When moving it to another file or namespace, add
  `[FormerlyNamed("OldNamespace.OldName")]` so scenes, prefabs and built games still find it.
- `[Rpc]` methods run across the network: `[Rpc(RpcTarget.Server)]` on the server only,
  `[Rpc]` (Everyone) on the server and every client. Call them with
  `Rpc(nameof(Fire), aim, power)`. The server may call any; a client only on an object it
  owns (its player), and an Everyone call then runs on it when the server sends it back.
  Parameters: int, float, bool, string, enums, Vector2/3/4, GameObject. Inside one,
  `RpcSender` is the caller's client id.
- Physics callbacks: `OnCollisionEnter/Stay/Exit(Collision)` (other object, point, normal out
  of the other object, closing speed) and `OnTriggerEnter/Stay/Exit(GameObject)` for colliders
  with `isTrigger` (`GetCollider().IsTrigger` reads or switches it while playing; that is a
  local change). `OnControllerHit(ControllerHit)` reports what this object's character
  controller ran into on each move (ground too; not during prediction replays). Stay runs
  every physics step while the two touch and either is awake. Enter
  and Exit run once per pair of objects, after the tick's physics step, on every machine that
  simulates the tick (check `Scene.IsServer` before changing authoritative state); never
  during prediction replays.
- The editor's Add Component > Scripts menu reads the compiled component catalog
  and adds managed classes through the native adapter.
- Public C# float/int/bool/Vector2/3/4 fields are editable in the Inspector,
  saved in scenes/prefabs, and applied before Awake. Numeric [Range] draws sliders.
- Drag a compiled .cs file onto a scene object or its Inspector to attach its
  managed component (with a type picker when a file declares multiple components).
- The Launcher now opens the same precompiled Tallow editor/engine for all
  C# projects. Opening projects or pressing Play does not rebuild native code.
- Editor startup compiles gameplay on a worker thread. Compile errors appear
  in the Console and block Play, not access to the editor and its script tabs.
- C# completion and diagnostics use Roslyn, including SDK framework and
  automatically discovered gameplay API symbols. A persistent worker eliminates
  repeated .NET process launches; the C# 15 lexical colorizer is separate from Beef.
- The precompiled launcher also supports a development game-runner mode that
  loads trusted C# assemblies without building a separate native executable.
- C# gameplay projects import System.Numerics globally: Vector3 addition,
  subtraction and multiplication work without an extra `using` directive.
- The native host searches DOTNET_ROOT, the installed dotnet executable,
  Fedora/Nobara's /usr/lib64/dotnet, and other standard .NET installation roots.
- `Tests/NativeCSharpHost` verifies C# movement, callbacks, and network button edges in native processes.

This is **not a complete integration**. The managed API covers only a small
subset of Tallow. Native and managed lifecycle smoke tests pass on Linux and
Windows; users have successfully opened the full Linux editor and run attached
C# components, including saving Inspector values. The precompiled editor
entrypoint and standalone game mode are newer and still require full local
Beef editor builds and Play/Stop testing. ECS systems/queries, physics,
networking parity, final game export packaging, persistent-state hot reload,
C# visual-script generation, and compiler-accurate semantic syntax coloring
remain incomplete. Do not ship production games on this basis.

## Gameplay parity requirement

Existing native gameplay behavior is the compatibility specification. Before
C# can replace gameplay Beef, tests must cover lifecycle and inspector state;
ECS components and queries; transforms and hierarchies; prefabs; asset access;
physics and collisions; animation; audio; rendering and shaders; UI; input;
AI/navigation; voxel and compute facilities; networking, prediction and
rollback; save/load; shader and visual-graph integration; and platform builds.
Missing C# APIs are failures, not optional features.

All native references crossing the boundary must use validated handles; game
assemblies must never own native GameObject/component allocations. Tallow
manages entity lifetime. Managed memory is collected by .NET.

## Security and mod policy

**Third-party / untrusted mod loading is disabled.** `*.tasmdef` files are
organizational boundaries for trusted game source, not permission boundaries.
`hostfxr`, Roslyn, syntax-tree analyzers and `AssemblyLoadContext` do not
sandbox untrusted .NET code. ALC is a reload/dependency isolation mechanism,
not a security boundary. Source restriction or disabled unsafe blocks are not
an adequate substitute for enforcement.

A future mod system is permitted only after a separate, reproducibly secured
execution boundary is designed and independently tested (for example a
restricted OS process with IPC, filesystem/network/CPU/memory restrictions,
or a dedicated capability-controlled WebAssembly runtime). Do not expose a
user-installable assembly loader or mod manifest in shipping editor/player
builds before that review.

## Build prototype (Python-free managed tooling)

```bash
dotnet run --project Managed/Tallow.Build/Tallow.Build.csproj -- --project Tests/CSharpGameplay --engine-root .
dotnet build Managed/Tallow.LanguageService/Tallow.LanguageService.csproj
dotnet run --project Managed/Tallow.ManagedHost/Tallow.ManagedHost.csproj -- Tests/CSharpGameplay/.tallow-csharp/bin/Tallow.Game/Tallow.Game.dll
```

Requires the .NET 11 SDK. Generated projects are local build artifacts under
the game's `.tallow-csharp` directory. Automated Linux and Windows managed
smoke tests are defined in `.github/workflows/csharp-gameplay.yml`.

C# editor diagnostics, symbols and completion use a persistent Roslyn/.NET
process without Python intermediaries. The first C# language-service request
builds the worker; later requests reuse it. Some native engine build tools,
project-version tools, samples, and visual-script generation still use Beef
or Python. Standalone hostfxr smoke tests and persistent Roslyn tests pass
on Linux and Windows. Full C# gameplay parity and shipping export remain
unfinished.

## Precompiled editor and development player

From an engine checkout, build Tallow **once** with `./build.sh --config Debug`.
Subsequent managed game projects reuse the existing native binary:

```bash
# Open any C# project directly in the precompiled editor.
./build/Debug_Linux64/TallowLauncher/TallowLauncher --open /path/to/MyGame

# Compile only C# gameplay and assembly definitions (no BeefBuild).
./build/Debug_Linux64/TallowLauncher/TallowLauncher --build-project /path/to/MyGame

# Run a successfully compiled game in the same precompiled engine.
./build/Debug_Linux64/TallowLauncher/TallowLauncher --game --project /path/to/MyGame

# Only for developers who explicitly need the old native game build:
./build/Debug_Linux64/TallowLauncher/TallowLauncher --build-native-project /path/to/MyGame
```

The launcher uses the precompiled `TallowLauncher` executable to host its
editor and local game runtime. A game does **not** need its own Beef-built
executable. The editor performs C# gameplay builds in the background, keeps
the project open when compilation fails, and blocks Play until the build
succeeds. SDK errors and compiler diagnostics go to the editor Console.
C# changes made in external editors are detected by the source monitor.

This is a **development runner**, not yet a finished independently
redistributable game export. Release packaging still needs managed runtime
staging, matching native artifacts, and platform verification. The old
Voxel sandbox/showcase templates still contain native Beef scripts and have
not been converted to C#; new projects default to the empty template.

## Local editor test (Linux)

After pulling this branch and building the editor, create a C# script:

```csharp
using Tallow;

namespace MyGame_c;

[Component]
public class NewScript : Script
{
    public float Speed = 1.0f;

    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Position += Vector3.UnitX * Speed * deltaTime;
    }
}
```

Save, compile, select a Cube in the scene, and use **Add Component > Scripts >
New Script** (or search its class name). Then press Play. Merely creating a
script file does not automatically attach it to a scene object.
Unlike editing a reference to a class instance, modifying a local copy of a
Vector3 property needs a write-back to `Transform.Position`.

If the native runtime cannot find hostfxr, inspect the editor Console and
`dotnet --list-runtimes`. On Fedora/Nobara, the runtime is often under
`/usr/lib64/dotnet`. The branch now supports that location.


## C# Inspector field convention

Tallow does not use Unity-style `[SerializeField]`. Public instance fields
of supported types automatically appear in the Inspector and persist.
Private fields use `[ShowInInspector]` to display and persist or
`[HideInInspector]` to persist without displaying. `[NonSerialized]`
explicitly excludes a field; unannotated private fields are implementation
state and are not persisted. `[SerializedFieldId]` is an optional advanced
identity hint for field renames, **not** an opt-in to persistence and not
needed for normal gameplay.

## Shipping code protection policy (planned, not implemented)

Tallow's C# editor and iterative Play workflow stay .NET JIT for compilation,
Roslyn diagnostics, managed hot reload and quick iteration. The **default
shipping export** will be **NativeAOT** native machine code with platform Release
optimizations and trimming, with a developer-selectable **JIT compatibility**
export for debugging. AOT export failure must never silently create a managed
IL release instead. Both modes must use identical gameplay source, native
Flecs/Jolt engine and generated binding ABI.

The current .NET gameplay host loads trusted game DLLs into a collectible
AssemblyLoadContext, which NativeAOT cannot do. NativeAOT export needs a
separate statically compiled game entrypoint and native-player host; do not
set PublishAot on the existing runtime and call it complete. NativeAOT shared
libraries cannot be unloaded; keep them alive until player process exit.
AOT-facing registration, component factories and Inspector field serializers
will be generated from Roslyn rather than runtime reflection.

Public packages should have no gameplay IL, debug PDB/DBG or developer source
files. Retain separate private matching crash symbols and ABI exports. JIT/AOT
cross-runtime deterministic replay, mixed-client network tests, Inspector and
ECS/Jolt parity, and Windows/Linux actual release exports are mandatory before
claiming the shipping profile works. See [roadmap](csharp-gameplay-roadmap.md)
and [benchmark cases B24–B30](csharp-benchmark-plan.md).


## C# Inspector supported types and limitations (November 14, 2026)

The C# Inspector field catalog now handles `float`, `int`, `bool`,
`Vector2`, `Vector3`, `Vector4`, enums and **single-line `string`**
fields. Public fields appear automatically. The native `[ShowInInspector]`
and `[HideInInspector]` conventions apply equally to string fields.
`[NonSerialized]` overrides these annotations.

Strings can contain spaces and ordinary Unicode text. Tabs, newlines,
carriage returns and NUL cannot be represented by the current line-based
`fieldOverrides` format: the catalog rejects such source initializer
constants and the native Inspector rejects edits containing delimiters.
A later escaped or binary format will be required for arbitrary strings.
Collections (arrays and lists) are not yet serialized.

### Object reference fields

A public field of type `GameObject`, `Transform`, a built-in component
(`Light`, `Rigidbody`, `MeshRenderer`, `Animator`, `NavigationAgent`, ...)
or another C# script shows an object slot in the Inspector. Drag an object
from the Hierarchy onto it, or press **...** to pick from the objects that
fit (for a `Light` field, the objects with a Light; for a script field, the
objects with that script). Nullable fields (`GameObject?`, `Door?`) work the
same way.

```csharp
public class DoorSwitch : Script
{
    public GameObject Door;
    public Light Lamp;
    public DoorSwitch? Next;
}
```

References are saved as a list of objects on the component, so they keep
pointing at the right object when a scene loads, and inside a prefab each
copy points at its own objects. Before a script's `Awake` runs, its
references are set; a referenced C# script whose object comes later in the
scene is brought up first, so its own `Awake` has run too. A reference to an
object that was deleted is null (or the empty handle, whose `IsValid` is
false, for a built-in component field). Graph object variables are fields of
these types, so they are set the same way.

When field restoration fails, the native C# adapter no longer proceeds with
`Awake`; when editing during Play, a failed field batch leaves the previous
saved override unchanged. This still requires full Nobara editor verification.

## ECS data and queries

A `[Component]` **struct** is ECS data: it lives in the engine's Flecs world,
packed with every other entity's, instead of in a script per object. Its
fields can be `bool`, `int`, `uint`, `long`, `ulong`, `float`, `double`,
`Vector2/3/4` or `Quaternion`.

```csharp
[Component]
public struct Mover
{
    public Vector3 Velocity;
    public float Drag;
}

public class Movers : Script
{
    public override void Start()
    {
        // On a GameObject's entity, or on a bare entity with no GameObject at all.
        GameObject.Entity.Set(new Mover { Velocity = Vector3.UnitX, Drag = 0.1f });
        Scene.CreateLocalEcsEntity().Set(new Mover { Velocity = Vector3.UnitZ });
    }

    public override void Update(TickInput input, float deltaTime)
    {
        Scene.Query<Mover>().ForEach((EcsEntity entity, ref Mover mover) =>
            mover.Velocity *= 1f - mover.Drag * deltaTime);
    }
}
```

- `EcsEntity.Set`, `Get`, `TryGet`, `Has` and `Remove` work on one entity;
  `GameObject.Entity` is an object's entity and `EcsEntity.GameObject` the
  other way (null for a bare entity).
- `Scene.Query<A>()`, `Query<A, B>()` and `Query<A, B, C>()` give the
  entities with all of them: `Count`, and `ForEach` with a `ref` to each. The
  data is copied out in pages and the rows the action changed are written back
  after it, so it costs a few calls per thousand entities, not one per entity.
- In `ForEach` you may create and destroy entities and add or remove data. An
  entity that has gone (or lost one of the components) by the end is not
  written back, and entities made during it are visited next time.
- ECS data is for offline play for now: it is not saved with the scene and not
  replicated (`[Sync]` on its fields is not sent yet). Bare entities are
  deleted when Play stops.
- Visual script graphs get the same nodes for each struct: Has, Add and Remove
  Component, Get and Set of each field, and **For Each**, which visits the
  active GameObjects that have it.

## Spawning networked objects

A prefab whose root has a Network Identity is shared. On the server, `Scene.Spawn` makes it on every machine and
can hand it to a player; `Scene.Despawn` removes it everywhere. Give prefab files short names once at startup,
with the same names on the server and the clients.

```csharp
public override void Start() => Network.RegisterPrefab("crate", "Prefabs/Crate.tprefab");

void DropCrateFor(GameObject player)
{
    if (Scene.IsServer)
        Scene.Spawn("crate", player.Transform.Position + new Vector3(0, 2, 0), player.OwnerClientId);
}
```

A despawned object reads as gone straight away (`IsValid` is false); its scripts' `OnDestroy` runs at the end
of the frame.

## UI documents with C# code-behind

Put a UI Document and a C# script on the same object. The document's `onclick="Method"`, `onchange` and
`onload` call that script's method of the name (it can take nothing, a `UIElement`, or the element's id as a
string), and `bind="field"` shows and edits the script's public field. From code, `GetComponent<UIDocument>()`
gives the document; `Find("id")` an element, with `Text`, `Visible` and `Value`.

```csharp
public class MainMenu : Script
{
    public string playerName = "Player";

    void OnPlay(UIElement button) =>
        GetComponent<UIDocument>().Find("status")?.SetText($"Have fun, {playerName}!");
}
```

## Visual scripting graphs in C# projects

A `.tgraph` in a C# project compiles to C#: Compile in the graph editor writes `Name.cs` beside the graph, a
`public partial class Name : Script` in the namespace a new C# script in that folder would get. Drop the graph on
an object to add it (its compiled script is what runs); the generated file is hidden in the Project panel and
travels with the graph in packages. Do not edit it: compile the graph again instead, or use Convert to Script to
keep the code and drop the graph. Because the class is `partial`, a hand-written `partial class Name` in another
file can add methods the graph's nodes cannot express.

The node list in a C# project leaves out nodes that only exist for Beef (the engine's Beef API, Beef
`[GraphNode]` methods, ECS For Each Data). In their place, every public property, field and method of
Tallow.API's gameplay types and of your own public C# types becomes a node (under Engine and My Scripts), as
long as a pin can carry its parameters and result: numbers, bools, text, vectors, rotations, colours, enums,
GameObject, Transform, the physics handles and your scripts. The build writes the list
(`.tallow-csharp/graph-nodes.tsv`) even when the game does not compile, so a graph can be finished first. Object variables of GameObject and physics handle types are handles
(never null): Is Valid asks whether the object still exists.

To compile a graph without the editor (tests, build scripts):
`TallowLauncher --graph-compile path/Name.tgraph GameNamespace`.

## Shipping a C# game

`python3 tools/build_player.py <project> --output <folder>` (or File > Build) builds a C#
project into a folder that runs on its own: the engine's precompiled player renamed to the
game, `game.tpak`, `Managed/` (Tallow's runtime and the game's Release assemblies) and
`dotnet/`, a copy of the .NET runtime, so players need not install .NET. Pass
`--no-bundle-dotnet` for a smaller build that needs .NET installed. Linux only so far.
