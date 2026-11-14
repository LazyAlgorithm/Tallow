# Opt-in Beef → C# API bindings

**State (2026-11-13):** stage-1 `[CSharpExpose]` reflection and native/C# wrapper generation are wired into the full engine build. GitHub Linux native CI has confirmed the annotated `CSharpBindingFixture.Average` method appears in both wrappers while its unmarked `NativeOnly` method is not exposed. The generator also has managed Linux/Windows smoke coverage. The first real exposed engine APIs are deterministic `Noise.Perlin` and `Noise.Fbm` (pending native CI on their annotations). **Only a small, safe static-method subset is supported so far**; instance methods, properties, resource handles, advanced ECS and full engine API parity remain incomplete.

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

- **Stage 0 (complete):** declarative Beef attribute and opt-in contract.
- **Stage 1 (implemented, expanding):** deterministic compiler-reflected manifest and native/C# wrappers for public static methods using safe scalar and vector values; validated with Linux native editor and Linux/Windows managed tests. New real-world annotations still require native CI verification.
- **Stage 2:** checked GameObject/Transform handles, instance methods, public properties, safe enums and UTF-8 strings. Reuse existing C# `IEngineBridge` and native callback conventions wherever possible.
- **Stage 3:** more complex types and subsystem-specific hand-written adapters, generated documentation, signature/version compatibility, performance regression tests and automated binding coverage reports.

## Acceptance test

Annotate one new *safe* native method, rebuild Tallow engine **once**, and verify its generated C# method and IntelliSense entry appear without hand-editing `Tallow.API`; call it from C# and verify native execution in Windows and Linux tests. An unannotated public Beef method on that type must **not** appear in C#, and an invalid annotation must fail binding generation with a specific error.

## Notes

`[CSharpExpose]` is a **public API design tool**, not a security sandbox. C# gameplay is trusted and runs within the same native process. Hiding internal symbols from the generated C# API does not by itself protect native memory against malicious code.

Native Beef code changes still require a native engine rebuild. Routine C# gameplay edits do not.

## Single source of truth and hot-path performance (decision 2026-11-13)

The user requires **one authoring surface** for public gameplay APIs: approved Beef declarations annotated with `[CSharpExpose]`. Once migration is finished, do **not** maintain manually synchronized Beef and C# versions of the public API. Complex low-level adapters may exist behind the generated public API, but should not require independent public signatures or hand-written duplicate API documentation. The generator is responsible for public declarations, wrappers, versioning, and Roslyn discovery.

Every native-backed C# property/method may cross the ABI boundary. This is an acceptable cost for occasional operations but not for 10,000+ entity component loops. The generated API must distinguish:
- **Native entrypoints:** direct, statically typed, ABI-checked function pointers or C-callable wrappers; no generic reflection dispatch or boxing per call.
- **Managed pure helpers:** math and local cached data that never need to cross the boundary.
- **Bulk ECS operations:** native establishes a validated, short-lived typed batch view or copies a compact batch; C# runs an entire system/chunk locally and commits changes in one batch when required. No per-entity GetComponent/SetComponent callback loop as the only API. Test memory moves, lifetime, synchronization, cross-thread use and rollback; never expose persistent raw pointers to scene-owned storage.
- **Managed scheduling:** the current native `CSharpBehaviour` forwards component callbacks individually. Profile that cost; for large C# scenes, plan native-to-managed dispatch once per update phase/tick (or bounded batches) and execute eligible managed scripts/systems in deterministic order inside .NET. Preserve component enable/disable, networking authority, scene lifecycle, script order, and native callbacks. This avoids one native-to-managed boundary crossing per C# script merely to invoke `Update`.
- **Bulk native commands:** physics queries, spawning and transforms can submit command/query batches when high-volume usage warrants it.

Benchmark per-call boundary latency and chunk throughput alongside full-game frame time, allocations, GC pause percentiles, and deterministic network replay. Only call the migration 'near native' after measured Beef-vs-C# comparisons, not theoretical estimates. A C# compile/edit should never regenerate the native API or rebuild Beef.

### Manifest prototype

`TallowLauncher --csharp-api-manifest /tmp/tallow-csharp-api.tsv` runs a native reflection scan over compiled Beef types. It validates *annotated* stage-1 static method signatures (void/bool/int32/float and Vector2/3/4), rejects invalid annotated fields rather than silently omitting them, sorts signature records, and includes an annotated fixture `CSharpBindingFixture.Average` while excluding its unannotated `NativeOnly`. It is covered by a native Linux CI smoke check. **The manifest is only a foundation; it is not yet wired into the managed runtime or a native ABI wrapper generator**, and no existing hand-written public bridge was removed. The remaining generator work is tracked in the main roadmap.

