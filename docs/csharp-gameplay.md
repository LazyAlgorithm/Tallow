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
- C# gameplay projects import System.Numerics globally: Vector3 addition,
  subtraction and multiplication work without an extra `using` directive.
- The native host searches DOTNET_ROOT, the installed dotnet executable,
  Fedora/Nobara's /usr/lib64/dotnet, and other standard .NET installation roots.
- `Tests/NativeCSharpHost` verifies C# movement, callbacks, and network button edges in native processes.

This is **not a complete integration**. The managed API covers only a small
subset of Tallow. The initial bridge and standalone native/managed lifecycle
tests now exist, along with editor C# syntax and Roslyn requests. The
editor has an initial Play/Stop managed runtime initialization and assembly
unload path, and a native adapter for compiled C# components. The entire
editor-side workflow is still experimental and requires local testing.
Managed field editing and serialization, ECS systems/queries, physics,
networking parity, export packaging, true hot reload, and C# visual-script
generation remain incomplete. Do not ship on this basis.

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

C# editor diagnostics and completion run Roslyn directly via `dotnet` without
Python intermediaries. Some unrelated engine/build systems still depend on
Python until separately migrated. The native C# runtime bridge has passed standalone hostfxr smoke tests on
Linux and Windows. Normal editor Play startup, cross-assembly field reflection,
full gameplay parity, and safe managed reload remain unfinished.

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
