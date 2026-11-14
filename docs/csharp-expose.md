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



### Native entrypoint integrity

Every generated Beef entrypoint carries an internal `[CSharpApiExport]`
attribute. The native resolver returns pointers **only** for methods with that
marker as well as the expected symbol name. Generated C# wrappers cache
pointers after a one-time ABI version check; reconfiguration clears all
generated pointer caches before the next call. The native-host smoke tests
rebind the resolver in-process and verify subsequent calls reach the new
function, not the old cached pointer. This is a lifecycle guard, not an
untrusted-code sandbox.


### Read-only static field exposure (stage 1.5)

`[CSharpExpose]` on a public nonconstant **static Beef field** now emits a
real **read-only C# property**. The manifest records `field<TAB>owner<TAB>name<TAB>type<TAB>get`;
BindingGen emits a dedicated, typed C ABI getter and the managed
`public static T Name { get; }`-style expression property. No `get_*`
method appears in public C# completion. An unsafe pointer or managed object
field is rejected at engine build time. Mutable native fields remain read-only
to C# by default until explicit write authorization is implemented.

The first consumer is the engine's `Time` runtime counters: `DeltaTime`,
`UnscaledDeltaTime`, `RealTime`, `TimeScale`, `TickScale`, `FrameCount`,
`Tick`, `InterpolationAlpha`, and `SmoothedFps`. `Time.Time` cannot be a
C# member of the `Time` type (same name), so an alias scheme will be added
before exposing that one. This is not yet instance-property/scene-handle
support, and full parity is still pending native CI confirmation.


### Explicit field setters

The public attribute now has `Writable` (default false). A mutable static
scalar field annotated `[CSharpExpose(Writable = true)]` emits both native
get/set C ABI entrypoints and a standard C# property with `get` and `set`.
The first such field is `Time.TimeScale`. Compiler metadata validates that
only a public, mutable, static, non-generic field can opt into writes; vector
field setters are still deferred until their ownership/marshalling is tested.
Unmarked or read-only counters remain inaccessible for assignment from C#.
The standalone host integration asserts that assigning the generated C#
property reaches the native setter.


### Safe UTF-8 input marshalling

Selected Beef methods that accept `StringView` can now be annotated
`[CSharpExpose]` and become normal C# `string` parameters. The generator
lowers one native argument to a counted `char8*` plus `int32` byte length.
C# converts with `Encoding.UTF8` and pins its temporary byte array only
during the synchronous call; Beef sees a temporary `StringView`. The first
real exposed examples are `Log.Info`, `Log.Warning`, and `Log.Error`,
which copy messages into the engine's native Console.

Returning native strings, retaining borrowed pointers, and async callbacks
are deliberately unsupported until their ownership protocols are defined.
The integration test checks a non-ASCII string arrives intact over the C ABI.


### Managed scene and prefab facade (initial)

C# gameplay now exposes `Script.Scene` and `GameObject.Scene` as a
session-scoped handle, plus `Scene.CreateGameObject(name)`, `Scene.Find(name)`,
`Scene.InstantiatePrefab(path)`, and `Prefab.Instantiate(scene, path)`.
The native callbacks validate the active session, copy at most 4 KiB of UTF-8
input, and return only the new/found `GameObject.Id`; no Beef `GameObject*`,
Flecs pointer, or native ownership leaves the engine. Prefab creation calls
the existing Beef `Prefab.Instantiate` so server authority and replicated
ownership are preserved, including the possibility of a null client-side
return. A C++ native-host regression drives the C# facade and checks the
original names and paths. This first bridge does not yet implement hierarchy
parenting, full scene iteration, component querying, or all Unity-like APIs.


### One public API definition per exposed method

**Generated `[CSharpExpose]` wrappers are authoritative.** The old
handwritten `Managed/Tallow.API/Mathf.cs` method implementations have been
removed rather than shadowing/reimplementing the native engine math API.
Only the four C# compile-time numeric constants remain in a
`public static partial class Mathf`; the generator now emits
`public static unsafe partial class Mathf` so the constants and **generated**
methods share a single C# type.

The native-host fixture maps generated `Mathf.Clamp` by its exact ABI hash
and checks its result, instead of sending every unresolved generated symbol
to the `CSharpBindingFixture.Average` stub.

**Scope boundary:** `Script`, `GameObject`, `Scene`, and `Transform`
currently contain compatibility facades and trusted runtime callback plumbing.
Removing those before instance handles, lifecycle registration, property
metadata and ownership are supported by the generator would break gameplay.
The migration goal is to replace native-call bindings in those facades with
generated methods, keeping high-level C# types as lightweight ergonomics rather
than duplicating native implementations. Do not add new handwritten native
method mirrors; put `[CSharpExpose]` on the Beef source instead.

### Curated C# math exposure

C# uses `System.MathF` for conventional scalar math and `System.Math.Clamp`
for ordinary clamping, instead of generating managed-to-native calls for
`Min`, `Max`, `Clamp`, `Abs`, `Sqrt`, `Sin`, `Cos`, `Tan`, and `Floor`.
The same methods remain fully available to native Beef gameplay.

Only helpers with gameplay-specific API or semantics are annotated and
generated in C#: `Mathf.Clamp01`, `Lerp`, `MoveTowards`, `SmoothStep`,
`WrapAngle`, `FloorToInt`, and `Sign`. Beef's `Mathf.Sign(0) == +1`
differs from `MathF.Sign(0) == 0`. Constants `Deg2Rad`, `Rad2Deg`,
and the engine-specific tolerance `Epsilon` remain compile-time C# constants;
use `MathF.PI` for pi.

The fixture and native-host smoke tests are deliberately limited to these
approved annotations. CI rejects standard scalar math exports. This reduces
unnecessary P/Invoke call overhead in hot gameplay loops.
