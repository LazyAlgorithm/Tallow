# C# gameplay integration (experimental branch)

C# is the intended **gameplay-facing scripting language** on `feature/csharp-gameplay`.
The engine and editor implementation can remain native Beef internally. No shipped
C# editor workflow may display Beef or generate `.bf` gameplay scripts once migration
is complete.

## Current implemented foundation

- Target .NET 11, C# 15, nullable-enabled managed projects.
- `Managed/Tallow.Build` generates `Tallow.Game` and assembly-definition projects.
- `*.tasmdef` JSON files describe trusted gameplay assembly boundaries:
  `{"name":"Gameplay","references":[]}`; nested definitions own their own trees.
- `Managed/Tallow.API` contains initial managed game types and callbacks.
- `Managed/Tallow.ManagedHost` and `Tests/CSharpGameplay` are managed smoke-test scaffolding.
- `Managed/Tallow.ManagedRuntime` exports trusted C# script lifecycle functions to native code.
- `native/tallow_dotnet_host.cpp` hosts .NET with hostfxr on desktop; WebAssembly has a no-runtime stub.
- `Engine/src/Scripting/CSharpRuntime.bf` provides a validated scene/entity-handle bridge.
- `Engine/src/Scripting/CSharpBehaviour.bf` forwards native component callbacks and tick input.
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
