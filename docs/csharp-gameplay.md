# C# gameplay integration (experimental branch)

C# is the intended **gameplay-facing scripting language** on `feature/csharp-gameplay`.
The engine and editor implementation can remain native Beef internally. No shipped
C# editor workflow may display Beef or generate `.bf` gameplay scripts once migration
is complete.

## Current implemented foundation

- Target .NET 11, C# 15, nullable-enabled managed projects.
- `tools/csharp_gameplay.py` generates `Tallow.Game` and assembly-definition projects.
- `*.asmdef` JSON files describe trusted gameplay assembly boundaries:
  `{"name":"Gameplay","references":[]}`; nested definitions own their own trees.
- `Managed/Tallow.API` contains initial managed game types and callbacks.
- `Managed/Tallow.ManagedHost` and `Tests/CSharpGameplay` are smoke-test scaffolding.

This is **not a complete integration**. The managed API currently covers only a
small subset of Tallow; the native engine bridge, editor compiler/semantic
integration, component registry, inspection, ECS systems and queries, visual
scripting, physics, networking, persistence, packaging, and Play-mode lifecycle
have not yet been implemented or validated for C#. Do not ship on this basis.

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

**Third-party / untrusted mod loading is disabled.** `*.asmdef` files are
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

## Build prototype

```bash
python3 tools/csharp_gameplay.py --project Tests/CSharpGameplay --generate-only
python3 tools/csharp_gameplay.py --project Tests/CSharpGameplay
```

Requires the .NET 11 SDK. Generated projects are local build artifacts under
the game's `.tallow-csharp` directory. Actual player execution and native
interop are not connected yet. No native editor or SDK builds have been
validated in the current environment.
