# Opt-in Beef → C# API bindings

**State:** the Beef `[CSharpExpose]` marker is defined in `Engine/src/Scripting/CSharpExpose.bf`. **No binding generator consumes it yet**, so it does not make an annotated API callable from C# by itself. This document is the implementation contract for the generator. Existing manually bridged gameplay APIs remain unchanged.

## Goal

Tallow's editor and engine remain **precompiled Beef**; the gameplay API presented to C# developers is curated. A new Beef method is **not exported merely because it is public**. An engine developer deliberately marks a type and its chosen public members. Ordinary engine internals, Flecs details, GPU and networking implementation code remain hidden from gameplay authors, and need no duplicate hand-written C# method declarations once the generator works.

### Example (Beef)

```beef
[CSharpExpose]
class PlayerMovement
{
    // Visible in generated C# and Roslyn autocomplete.
    [CSharpExpose]
    public void Move(Vector3 direction, float speed) { /* existing native logic */ }

    [CSharpExpose]
    public bool IsGrounded { get => /* native state */; }

    // Beef-only internal implementation detail.
    void RebuildPredictionBuffers() { /* internal */ }
}
```

Intended public C# signature:

```csharp
public sealed class PlayerMovement
{
    public void Move(Vector3 direction, float speed);
    public bool IsGrounded { get; }
}
```

Those C# declarations are *illustrative*, **not yet generated**. Even when a class is marked `[CSharpExpose]`, **every member must independently opt in**. There must be no implicit "expose all public" default. The type annotation establishes the namespace and public API owner, and a member annotation authorizes one method, property or field.

## Binding generator contract

1. At **native engine build time**, discover annotated types and members using Beef reflection/compiler metadata. Work from actual resolved symbols, not regex matching Beef source. Export a deterministic manifest sorted by fully qualified owner/type and complete member signature.
2. Reject non-public members, missing type-level opt-in, unsupported signatures, ambiguous overloaded names, unsafe generics, raw pointers, unowned native objects and unsupported reference/out parameters with actionable build diagnostics. Do **not** silently omit exposed members; a broken explicit API contract must fail the generator.
3. Generate *both sides* of the binding from that one manifest: ABI-stable C-callable native wrappers (or checked dispatch IDs) and `Tallow.API` C# wrappers with matching names, parameters, overloads, properties and XML docs. Keep a deterministic ABI version/checksum to reject mismatched engine and managed APIs.
4. Use a strict value-type mapping for primitive scalars, vectors, quaternions, enums and POD structs. For scene-owned objects, generate **opaque scene/entity IDs**, not pointers. Check session/liveness at every native call. UTF-8 strings are copied across the boundary, with explicit ownership and lifetime rules.
5. Support C# errors and exceptions gracefully. Generate no reflection-based arbitrary method invocation in shipped games and no untrusted assembly loading.
6. Integrate the generated C# sources/reference assembly into Roslyn so new exposed methods appear in completion, diagnostics, parameter hints and docs automatically.
7. Run the generator when **the engine is rebuilt or exposed API changes**, not whenever a developer edits or compiles C# gameplay. Project builds remain `dotnet` only.
8. Continue to support **hand-written adapters** for complex systems (ECS queries, Jolt callbacks, graphics resources, network authority/rollback) and for manually optimized performance paths. The generator must not overwrite or duplicate existing hand-written public members.

### Rollout order

- **Stage 0 (now):** declarative Beef attribute and this opt-in contract only, no change to public C# API.
- **Stage 1:** emitter and manifest validator for static methods taking/returning primitive scalars and numeric vectors; generate native and C# sides from one set of annotated declarations. Add Linux/Windows native-host tests and compiler-backed diagnostics.
- **Stage 2:** checked GameObject/Transform handles, instance methods, public properties, safe enums and UTF-8 strings. Reuse existing C# `IEngineBridge` and native callback conventions wherever possible.
- **Stage 3:** more complex types and subsystem-specific hand-written adapters, generated documentation, signature/version compatibility, performance regression tests and automated binding coverage reports.

## Acceptance test

Annotate one new *safe* native method, rebuild Tallow engine **once**, and verify its generated C# method and IntelliSense entry appear without hand-editing `Tallow.API`; call it from C# and verify native execution in Windows and Linux tests. An unannotated public Beef method on that type must **not** appear in C#, and an invalid annotation must fail binding generation with a specific error.

## Notes

`[CSharpExpose]` is a **public API design tool**, not a security sandbox. C# gameplay is trusted and runs within the same native process. Hiding internal symbols from the generated C# API does not by itself protect native memory against malicious code.

Native Beef code changes still require a native engine rebuild. Routine C# gameplay edits do not.
