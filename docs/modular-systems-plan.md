# Modular engine systems and swappable physics

Status: plan, 2026-11-22. Applies to the 0.3.x C# gameplay line (`4ccb5560`).

The goal is a stable seam between Tallow and the libraries it is built on, so a system can be replaced by writing an
integration instead of editing the engine. Physics is the first system, because it is the one most likely to change
(Jolt today; Rapier3D later; Rapier2D when 2D gameplay arrives).

**Current scope: the abstraction and capability gating, with Jolt as the only backend.** Rapier is *not* being
added in this work. The Rapier sections below are a blueprint for a later integration and do not gate the current
phases. What must exist now:

1. A small module/provider infrastructure used by every swappable system.
2. Physics split into an engine-owned front end and a per-library backend.
3. Jolt behind that seam, with every physics consumer in the engine using it.
4. Capability reporting, so the editor and runtime refuse components a backend cannot implement.
5. Two per-project choices, one for 3D and one for 2D (only Jolt is selectable until another backend exists;
   the 2D list starts empty).
6. The 2D shape of the API, without building 2D gameplay yet.
7. The same treatment, later, for the other systems where it is worth it.

### Decisions locked (2026-11-22)

- **Two project-wide physics choices, not per scene.** A project selects a 3D physics engine (`physics3d`) and a
  2D physics engine (`physics2d`) independently. `Scene.Physics` uses the 3D choice and `Scene.Physics2D` uses
  the 2D choice; a scene does not override either. The intended lists are Jolt/Rapier3D under 3D Physics and
  Rapier2D/Box2D under 2D Physics, filled from the integrations available in the build (Jolt only today).
- **The selected backend for a dimension runs everything in that dimension.** No engine subsystem may quietly
  use another 3D library for navigation, water, soft bodies or ropes, and the same rule applies to 2D. If the
  selected backend cannot do a thing, that thing is unavailable (and its component cannot be added), not
  silently done by a second engine. The 3D and 2D choices are independent.
- **2D is a first-class parallel API, Unity-style.** `Physics2D`, `Rigidbody2D`, `BoxCollider2D`, 2D joints and
  2D queries are separate types from their 3D counterparts, not a mode on the 3D ones. A project can run a 3D
  world and a 2D world at the same time, each on its own selected backend.
- **Every offered backend must build on every supported platform** (Linux, Windows, macOS and web) from the start.
  A backend that only works on some platforms is not offered until it does.
- **Rapier later uses prebuilt binaries, and normal builds do not require Rust.** Rapier's official C bindings are
  built once per platform by a pinned CI job; the resulting static archives ship with the engine. Rust is a
  maintainer-only dependency for regenerating those archives, not a build requirement for Tallow or game projects.
- **Jolt stays the default backend.**
- **Soft bodies are not a Jolt-only feature by design.** Jolt and Rapier both have soft bodies (Rapier has more
  soft-body features). The capability flags decide per feature which backend can run it; they do not encode a
  permanent Jolt advantage.
- **Missing features are not addable components.** If a backend or this build does not have a feature, its
  component cannot be added; authored data for it is preserved and explained, not deleted.

## 1. What exists today

Facts that constrain the design (all paths relative to the repo root):

- `Scene.Physics` is a concrete `PhysicsWorld` (`Engine/src/Scene/Scene.bf:665`, constructed at `:782`).
  `PhysicsWorld` (`Engine/src/Physics/PhysicsWorld.bf:125`) is a Jolt wrapper: 66 public methods and 116
  `[CLink]` declarations in `Engine/src/Platform/Jolt.bf`.
- The engine logic and Jolt calls are interleaved in the same class: body bookkeeping, transform sync, layers,
  world states, debris and query validation sit next to `JPH_*`/`tn_*` calls.
- 26 engine files call `.Physics.`; the C# ABI has about 75 generated physics call sites. Physics is also used by
  navigation baking, IK/foot placement, audio occlusion, foliage, water, character motors and networking.
- Five native files use Jolt C++ directly, not just joltc: `native/tallow_physics.cpp`,
  `native/tallow_softbody.cpp`, `native/tallow_collision_profile.cpp`, `native/tallow_overlap_contacts.cpp` and
  `native/tallow_navigation.cpp`.
- Soft bodies and ropes bypass `PhysicsWorld` and hold `Scene.Physics.[Friend]mSystem` (a Jolt system pointer):
  `Engine/src/Physics/SoftBody.bf:414`, `Engine/src/Physics/Rope.bf:474`, `Engine/src/Water/Water.bf:481`.
- `CharacterController` exposes Jolt-specific types in its state (`Jolt.CharacterState`,
  `Jolt.CharacterHit`) at `Engine/src/Physics/CharacterController.bf:194,417` and `PhysicsWorld.bf:443,1172`.
- Jolt is built for cross-platform determinism (`native/CMakeLists.txt:57-80`), because networking predicts and
  rolls back physics. `NetworkManagerLockstep`/`History` use `SaveExact`/`RestoreExact`/`SaveShared`.
- Component discovery is compile-time reflection: `ComponentRegistry` includes every concrete `Component` class;
  `HandleComponents` holds handle structs; `DataComponents` holds `[Component]` structs. There is no capability
  or availability filter anywhere.
- Every component add path is separate: the Add Component popup (`Editor/src/Panels/InspectorPanel.bf:812`),
  the GameObject creation menu (`Editor/src/App/EditorLayout.bf:473`), scene quick-add
  (`Editor/src/Tools/SceneTools.bf:675`), `GameObject.AddComponent` (`Engine/src/Scene/GameObject.bf:313,350`),
  handle/data add, editor C# (`Editor/src/Scripts/CSharpEditorExtensions.bf:1061`), and C# gameplay
  (`Engine/src/Scripting/CSharpNativeComponentsApi.bf:46`).
- Scene files identify components by full type name (`Engine/src/Scene/SceneSerializer.bf`). An unknown type is
  preserved verbatim in `GameObject.MissingComponents` and shown as missing, so authored data is never destroyed.
- There is no general plugin/module system. Two real precedents already exist and should be copied:
  `NetTransport` (`Engine/src/Net/NetTransport.bf:33`, an abstract class with ENet/Steam/WebRTC implementations)
  and `SaveStorage` (`Engine/src/Saving/SaveStorage.bf:118`).
- Native libraries are static and listed in several places: `Launcher/BeefProj.toml`, `Player/BeefProj.toml`,
  `Editor/src/Project/Project.bf` (the link flags written into new game projects), `tools/build_player.py`,
  `tools/macos_link.py`, `tools/web/build_native.sh` and the CI workflows. Adding a native library touches all of
  them.

## 2. Design rules

1. **Game-facing API stays recognizable.** `Scene.Physics`, `Rigidbody`, `BoxCollider`, `Raycast`, `BodyState`,
   etc. keep their names and semantics. A backend swap must not require gameplay rewrites.
2. **The seam is in Beef, not in one giant C ABI.** Engine logic (transforms, entries, layers, world states,
   contact dispatch) stays shared and testable; each backend owns only its library's primitives and a thin native
   shim. This keeps the Jolt refactor mechanical and lets Rapier's C API be used directly.
3. **Capabilities are data.** A backend declares what its *integration* supports (not merely what the library
   offers). Components declare what they require. The editor and runtime consult the same data.
4. **Unsupported content is preserved, inert and explained.** A scene authored with a feature and opened under a
   backend that lacks it keeps those components; they do not simulate, and the Inspector says why. Nothing is
   silently deleted.
5. **Compile-time modules, runtime selection.** Backends are linked into the engine/game; a project chooses among
   them. This is source-level modularity, not dynamic DLL loading. Dynamic plugins are a separate, larger feature.
6. **No silent fallback anywhere.** If a project names a backend the build does not contain, the game fails at
   start-up with a clear message. The editor shows the same error and leaves physics disabled; it does not
   simulate with a different engine and pretend it is the selected one.
7. **2D is a separate world/API, not a mode on the 3D one.** Providers declare a dimension. `Scene.Physics` stays
   3D; `Scene.Physics2D` and `Rigidbody2D`/collider 2D names arrive later.
8. **A capability claim is tested.** Every declared capability has a conformance check. Declared and observed
   features are compared in development builds and CI.
9. **One physics engine runs each dimension of a project.** The selected 3D backend is used for all 3D bodies,
   queries, characters, joints, soft bodies, ropes, buoyancy and navigation geometry; the selected 2D backend
   does the same for 2D. No subsystem reaches around either to Jolt (or another library). A backend that lacks a
   feature cannot borrow it from another engine, and the 3D/2D choices do not have to be the same library.
10. **All platforms or not offered.** A backend is listed as available only when its library ships and works on
    every Tallow platform. "Desktop only" is not an offered backend.
11. **No new build toolchain for normal builds.** A backend may be integrated from prebuilt binaries; building
    Tallow or a game must not require the backend's source toolchain. Regenerating those binaries is a
    maintainer/CI task.

## 3. Module architecture

### 3.1 Module metadata and typed registries

There is one small metadata type, and one typed registry per system. The metadata is for discovery, editor UI and
diagnostics; the typed registry is what code actually calls.

```beef
enum ModuleKind : uint8
{
    Physics3D,
    Physics2D,      // reserved
    Audio,
    NetworkTransport,
    Navigation,
    Renderer,
    Platform,
}

class EngineModule
{
    public abstract StringView Id { get; }           // stable id: "Jolt", "Rapier3D", "ENet"
    public abstract StringView DisplayName { get; }
    public abstract ModuleKind Kind { get; }
    public abstract int32 IntegrationVersion { get; }
    public abstract StringView LibraryVersion { get; } // "vendored Jolt", "Rapier 0.36.1+c.0"
    public abstract bool Available { get; }           // linked and usable in this build
    public abstract uint64 Capabilities { get; }      // per-kind bit meanings
    public virtual bool Probe(out String reason) => true;
}
```

Per-system registries follow `NetTransport`'s shape:

```beef
static class PhysicsBackends
{
    public static void Register(PhysicsBackend backend);
    public static PhysicsBackend Find(StringView id);
    public static PhysicsBackend Find(StringView id, PhysicsDimension dimension);
    public static List<PhysicsBackend> All { get; }
    public static PhysicsBackend Default { get; }
}
```

Built-ins register from a static constructor (no native resources are created by a descriptor). A game or
integration can call `PhysicsBackends.Register(new MyBackend())` before the first `Scene` is constructed. An
attempt to replace an already-selected built-in is an error, not a silent override.

`EngineModules` is a thin facade over the typed registries for the editor's Modules page and for
`--list-modules`/`--list-modules --json` diagnostics.

### 3.2 Physics layering

```
engine + gameplay
      |
  PhysicsWorld            engine-owned front end, unchanged public API
      |
  PhysicsBackendWorld     one per world, implemented by each integration
      |
  native shim (tn_* / tnr_*)   thin C ABI, one per library
      |
  Jolt / Rapier
```

**`PhysicsWorld` front end keeps:**

- `Scene` link, `Gravity`, `LengthScale`, capacities and world-state bookkeeping.
- The `Entry` list, body-id tracking, `mByBody`, transform versions and pre/post-step transform sync.
- The layer/world-group code computation (shared `PhysicsLayerTable`; see 3.5).
- Debris bookkeeping, query argument validation, ray/shape/overlap public wrappers.
- Joint and character bookkeeping (generation numbers, `HasJoint`, `HasCharacter`).
- Contact-event dispatch to `Component.OnCollision*/OnTrigger*`.
- `Features`/`Supports(...)`, backend identity and diagnostics.
- Soft-body/rope/buoyancy extension lookup (nullable; see 3.7).

**`PhysicsBackendWorld` owns:**

- Library world creation/destruction and step.
- Shape creation and query-shape caches.
- Body create/destroy, pose/velocity, forces, sleeping, layers/groups, sensors, CCD, mass properties.
- Raw ray/shape/overlap/check queries (single and all-hits).
- Joint create/destroy, motors, joint readings.
- Character create/move/state/shape.
- Contact collection in engine-neutral records.
- Exact state snapshots and (where supported) shared/delta state.
- Optional soft-body/rope/buoyancy/navigation-geometry extensions.

The interface sketch (names indicative, not final):

```beef
enum PhysicsDimension : uint8 { Two, Three }

// A flags enum (Beef has no [Flags] attribute; helpers such as Has/Union live beside it).
enum PhysicsFeature : uint64
{
    None = 0,
    RigidBodies = (uint64)1 << 0,
    KinematicBodies = (uint64)1 << 1,
    Sensors = (uint64)1 << 2,
    ContinuousCollision = (uint64)1 << 3,
    Sleeping = (uint64)1 << 4,
    FreezeRotation = (uint64)1 << 5,
    Debris = (uint64)1 << 6,
    BoxShape = (uint64)1 << 7,
    SphereShape = (uint64)1 << 8,
    CapsuleShape = (uint64)1 << 9,
    CylinderShape = (uint64)1 << 10,
    ConvexHullShape = (uint64)1 << 11,
    MeshShape = (uint64)1 << 12,
    CompoundShape = (uint64)1 << 13,
    BallJoint = (uint64)1 << 14,
    SwingLimit = (uint64)1 << 15,
    HingeJoint = (uint64)1 << 16,
    HingeMotor = (uint64)1 << 17,
    SliderJoint = (uint64)1 << 18,
    SliderSpring = (uint64)1 << 19,
    CharacterController = (uint64)1 << 20,
    CharacterPush = (uint64)1 << 21,
    Raycast = (uint64)1 << 22,
    RaycastAll = (uint64)1 << 23,
    ShapeCast = (uint64)1 << 24,
    Overlap = (uint64)1 << 25,
    Check = (uint64)1 << 26,
    ContactEvents = (uint64)1 << 27,
    ContactStay = (uint64)1 << 28,
    TriggerEvents = (uint64)1 << 29,
    SoftBodies = (uint64)1 << 30,
    SoftBodyDents = (uint64)1 << 31,
    SoftBodyPressure = (uint64)1 << 32,
    SoftBodySkin = (uint64)1 << 33,
    Ropes = (uint64)1 << 34,
    RopePulleys = (uint64)1 << 35,
    RopeKnots = (uint64)1 << 36,
    BuoyancyRigidBodies = (uint64)1 << 37,
    BuoyancySoftBodies = (uint64)1 << 38,
    WorldStatesSeparated = (uint64)1 << 39,
    NavigationGeometry = (uint64)1 << 40,
    SaveRestoreExact = (uint64)1 << 41,
    SharedPhysicsState = (uint64)1 << 42,
    CrossPlatformDeterminism = (uint64)1 << 43,
    FixedBodyIds = (uint64)1 << 44,
    MultipleWorlds = (uint64)1 << 45,
    // 46..63 reserved for future 3D features
}
// 2D has its own PhysicsFeature2D enum (physics2d), not packed into the 3D bit space.

abstract class PhysicsBackend : EngineModule
{
    public abstract PhysicsDimension Dimension { get; }
    public abstract PhysicsFeatures Features { get; }
    public abstract PhysicsBackendWorld CreateWorld(PhysicsWorldSettings settings);
}

abstract class PhysicsBackendWorld
{
    public abstract PhysicsFeatures Features { get; }

    public abstract void Step(float deltaTime);
    public abstract uint32 CreateBody(PhysicsBodyDesc desc, ShapeDesc shape);
    public abstract void DestroyBody(uint32 bodyId);
    public abstract void GetBodyState(uint32 bodyId, out PhysicsBodyState state);
    public abstract void SetBodyState(uint32 bodyId, PhysicsBodyState state);
    // ... pose, velocities, forces, sleep, layer code, mass ...
    public abstract bool Raycast(Vector3 origin, Vector3 direction, float maxDistance,
        uint32 layerMask, uint32 ignoreBody, out PhysicsRayHit hit);
    // ... all-hits casts, overlaps, checks ...
    public abstract void* CreateJoint(PhysicsJointDesc desc);
    public abstract void DestroyJoint(void* joint);
    public abstract void* CreateCharacter(PhysicsCharacterDesc desc, ShapeDesc shape);
    // ... character state/move/shape ...
    public abstract int CollectContacts(List<PhysicsContactEvent> into);
    public abstract PhysicsSnapshot SaveState(PhysicsSnapshot reuse);
    public abstract bool RestoreState(PhysicsSnapshot state);
}
```

`PhysicsWorld` chooses a backend lazily, on first body/query, so `ProjectConfig` can load first. That matches the
current lazy `EnsureCreated`.

### 3.3 Neutral value types

Move Jolt-shaped values out of the Jolt namespace and into `Engine/src/Physics/PhysicsTypes.bf`:

- `CharacterState` and `CharacterHit` (today `Jolt.CharacterState`/`Jolt.CharacterHit`).
- `PhysicsContactEvent` (`objectA/objectB`, `bodyA/bodyB`, point, normal, relative speed, sensor, enter/stay/exit).
- `PhysicsBodyDesc` (motion type, sensor, friction, restitution, damping, gravity factor, sleeping, CCD, freeze
  rotation, mass, debris, user data, wanted id).
- `PhysicsJointDesc` and `PhysicsCharacterDesc`.
- `PhysicsSnapshot` (backend id + size + opaque bytes + `Free()`); replaces the static
  `PhysicsWorld.ExactSize`/`FreeExact` and makes a snapshot self-describing.

`ShapeDesc`, `BodyState`, `RaycastHit`, `ShapeCastHit`, `CompoundCylinder` and `CompoundHull` already are neutral.
They stay in place, split into `PhysicsShapes.bf` for readability.

### 3.4 Capabilities, detection and component requirements

Capabilities describe the **integration**, not the raw library. A library feature that the integration has not
wired up and tested is not available, even if the library documents it. This matters for soft bodies: Jolt and
Rapier both have them (Rapier has more soft-body features), so soft bodies are not a Jolt-only capability by
design; each soft-body behaviour is a separate flag that a backend advertises only after conformance. If a future
backend leaves one out, that behaviour's component cannot be added under that backend.

Detection has three inputs:

1. **Build facts**: the provider is linked; the native shim reports `tnr_available()` and compiled feature bits.
2. **Declared integration features**: constants in the provider, matched to the shim.
3. **Runtime probes**: optional functional checks run by the editor, a test switch or CI. A probe creates a tiny
   world, creates/destroys a soft body, steps a contact, snapshots and restores, etc. It is not run on every game
   start.

`PhysicsBackends.ProbeAll()` compares declared and observed features and returns a report. CI fails on a
mismatch. The editor shows the same report on the Modules page.

Components declare requirements in one table (a separate table is used because `ComponentRegistry` discovers by
base type, not by attribute, and because some requirements depend on field values):

```beef
static class PhysicsComponentRules
{
    // The minimum needed before the component may be added.
    public static PhysicsFeatures Required(Type type);
    // Fields can narrow it: SoftBody's Jelly mode needs pressure/bounce; Rope's pulleys need RopePulleys.
    public static bool Validate(Component component, PhysicsFeatures features, out StringView reason);
    public static bool CanAdd(Type type, Scene scene, out StringView reason);
}
```

The contract for the current work (Jolt) and any future backend:

| Feature | Jolt now | Future backend contract |
|---|---|---|
| Rigid/kinematic/static bodies, sensors, forces, sleeping, CCD, freeze rotation, debris | yes | advertise only when implemented and tested |
| Box/sphere/capsule/cylinder/convex/mesh/compound shapes | yes | per shape flag |
| Ball/spherical, swing limit, hinge + motor, slider + spring | yes | per joint flag |
| Character controller, step-up/down, slopes, push | yes | per feature |
| Ray, all-ray, shape cast/all, overlap, check | yes | per query flag |
| Contact enter/exit/stay, triggers | yes | per event flag; stay needs pair tracking |
| 32 layers, collision matrix, separated world states | yes | full rule set, not a reduced 16-layer compromise |
| Soft bodies (cloth/jelly/shell), dents, pressure, skin, bounce | yes | both engines have soft bodies; each behaviour is a separate flag, verified |
| Ropes, pulleys, knots, wrap, wind | yes | per feature; if a backend cannot do it, `Rope` is unavailable there |
| Buoyancy (rigid / soft) | yes / yes | per feature; the selected backend does it, no Jolt fallback |
| Exact save/restore | yes | required before advertising networked prediction |
| Shared/delta state for lockstep | yes | required before advertising lockstep |
| Cross-platform determinism | yes | required before advertising prediction/lockstep |
| Fixed body ids | yes | required for lockstep |
| Navigation geometry | yes | required; navigation runs on the selected backend |
| Multiple worlds | yes | expected |
| Linux, Windows, macOS, web | yes | **required for the backend to be offered at all** |

Component gate map for the current built-ins:

| Component / API | Required feature(s) |
|---|---|
| `Rigidbody` | `RigidBodies`; fields add `KinematicBodies`, `ContinuousCollision`, `Sleeping`, `FreezeRotation`, `Debris` |
| `BoxCollider`, `SphereCollider`, `CapsuleCollider` | `BoxShape`, `SphereShape`, `CapsuleShape` |
| `MeshCollider`, `ConvexCollider`, `CompoundCollider` | `MeshShape`, `ConvexHullShape`, `CompoundShape` (+ `CylinderShape` for compound cylinders) |
| `CharacterController` | `CharacterController` (+ `CharacterPush` when it pushes bodies) |
| `Joint` | `BallJoint`; `swingLimit > 0` adds `SwingLimit` |
| Hinge/slider/motor APIs (code and C#) | `HingeJoint`, `SliderJoint`, `HingeMotor`, `SliderSpring` |
| `SoftBody` | `SoftBodies`; mode/field checks add `SoftBodyDents`, `SoftBodyPressure`, `SoftBodySkin` |
| `Rope` | `Ropes`; the pulley/knot/wrap/wind options add their own flags |
| `Water` / `Floater` | `BuoyancyRigidBodies`, `BuoyancySoftBodies` |
| `NavigationSurface` / `NavigationAgent` / baker | `NavigationGeometry` (the selected backend must supply bake geometry) |
| `Physics.Raycast*`, casts, overlaps, checks (Beef and C#) | `Raycast`, `RaycastAll`, `ShapeCast`, `Overlap`, `Check` |
| Network prediction / lockstep | `SaveRestoreExact`, `SharedPhysicsState`, `CrossPlatformDeterminism`, `FixedBodyIds` |

`PhysicsComponentRules.Validate` evaluates field-dependent requirements; `CanAdd` evaluates the minimum. If a
feature is missing, the component is not offered; if a scene already has it, it stays in the file and is inert.

### 3.5 Layers and world states as a shared table

`PhysicsWorld` computes an object code per body:

```
group (world-state mask, 0 = all) | motion class (static/moving/debris) | project layer
```

Jolt maps that to its object layers. Rapier's `InteractionGroups` are only 16+16 bits, too small for 32 layers
plus classes plus groups. Rapier exposes `R3PhysicsHooks.filter_contact_pair` and `R3QueryPredicate`, so the shim
can apply the full rule set if it receives the collision matrix once per world:

- At world creation, `PhysicsWorld` sends the 32x32 collision matrix (4 KB) and the world-group rules.
- Each collider gets the packed object code in its user data.
- The contact hook and query predicate compare codes using the same rules as Jolt.
- The rules live in one shared `PhysicsLayerTable` implementation, used to build both backends' filters, so the
  two cannot drift.

### 3.6 Selection and configuration

There are **two project-wide choices**, one per dimension. Project Settings > Physics shows two lists filled
from the providers available in this build:

```text
Physics
  3D Physics
    (•) Jolt          default
    ( ) Rapier3D      later
  2D Physics
    ( ) Rapier2D      later
    ( ) Box2D         later candidate
```

The list is data-driven, not hard-coded: a provider appears only once it is integrated, available in this build,
and supported on every platform. The names above are the intended set; until then the lists show what exists
(today: Jolt only under 3D Physics, an empty 2D Physics list).

- `ProjectConfig.tconfig` gains `physics3d <id>` and `physics2d <id>`.
  - A missing `physics3d` means `Jolt`, preserving existing projects.
  - A missing `physics2d` selects the first available 2D provider (Rapier2D when it ships). If no 2D provider is
    available, 2D physics is off: no 2D world is created and no 2D component can be added.
- `ProjectConfig.Physics3DBackendId` / `Physics2DBackendId` are parsed, written and versioned with the file.
- `--physics3d <id>` and `--physics2d <id>` override them for the Launcher, editor and headless tests (plus a
  combined `--physics <id>` shorthand for `physics3d`, for convenience).
- Project Settings > Physics has two groups:
  - **3D Physics**: the available 3D providers (Jolt today).
  - **2D Physics**: the available 2D providers. It is empty/disabled until a 2D backend exists; Jolt is never
    listed there.
  Each shows the provider's library version and capability list. Layers and the collision matrix stay where they
  are; the 2D collision matrix is separate (see 3.8).
- Backend-specific tuning is stored under namespaced keys (`physics3d.jolt.<name>`,
  `physics2d.rapier2d.<name>`) and read by that provider. A provider may describe its options for a generic
  editor UI later.
- A project has one selected 3D backend and one selected 2D backend. Every scene, and every world the project's
  gameplay uses in that dimension, uses the project's choice; a scene does not override it. Tools and tests may
  create a world with another backend (for conformance and comparison), but that is not a project setting.

Changing either choice is a project-level operation: it applies on the next Play, like layer changes. The editor
shows the affected components before applying it.

### 3.7 Soft bodies, ropes, buoyancy and navigation

These are optional extensions rather than core primitives:

```beef
abstract class PhysicsSoftBodyExtension
{
    // create/read/write vertices, pins, dents, pressure, wind, skin, proxies, bounce
}
abstract class PhysicsRopeExtension { /* Cosserat rods, ties, pulleys, wrap, wind */ }
abstract class PhysicsBuoyancyExtension { /* rigid and soft-body floating */ }
abstract class PhysicsGeometryExtension { /* static collision triangles for nav baking */ }
```

`PhysicsBackendWorld` exposes nullable properties (`SoftBodies`, `Ropes`, `Buoyancy`, `Geometry`). Their presence
sets the matching capability bits. These are part of the backend contract, not a Jolt escape hatch: Jolt
implements all four now, and a later backend implements whichever of them it can. The selected backend's
extensions are the only path to these systems — `SoftBody`, `Rope`, `Water` and `Floater` stop touching
`[Friend]mSystem` and call the extension. If a backend does not implement one, the corresponding component is
unavailable; nothing is delegated to Jolt behind its back.

Navigation is decoupled first, because it is needed for any backend: `native/tallow_navigation.cpp` stops taking
a `JPH_PhysicsSystem*` and takes a triangle buffer. `NavigationSurface.Bake` asks the selected world's
`Geometry` extension for triangles and passes them in. Recast/Detour no longer links Jolt.

### 3.8 2D readiness: what the abstraction buys, and what it does not

**What becomes easy**

- Every provider declares `PhysicsDimension`; `PhysicsBackends.Find(id, dimension)` and `EngineModules` expose
  it, so "Rapier3D" and "Rapier2D" are just two providers. The editor can list them separately.
- A 2D backend is another integration: it uses the same registry, capability gating, prebuilt-archive rules,
  all-platform gate and conformance harness. Adding Rapier2D, Box2D or another 2D engine does not require
  editing the engine.
- Capability filtering already works: 2D components can be omitted/refused exactly like 3D ones, and a
  backend that lacks, say, 2D soft bodies gates only that feature.
- 2D does not have to be forced through `Vector3`. `Scene.Physics2D` gets `Vector2`/angle types, and 2D
  components are separate types (`Rigidbody2D`, `BoxCollider2D`, `CircleCollider2D`, ...). A 3D and a 2D world
  can coexist in the same scene, each with its own selected provider.
- The networking policy (snapshots, fixed ids, determinism flags) is already expressed as capabilities, so 2D
  prediction/lockstep can be gated and tested the same way.
- Layers, collision matrix and world states are dimension-neutral in concept; the shared `PhysicsLayerTable`
  can serve both front ends.

**What is still real work**

- A `Physics2DWorld` front end: entries, transform sync, contact dispatch, query wrappers. Factor the shared
  bookkeeping into a dimension-neutral base/helpers now, or this becomes a near-duplicate of the 3D front end.
- The 2D shape/query/contact value types and descriptors (`Shape2D`, `RaycastHit2D`, etc.). Do not reuse
  `ShapeDesc` with `Vector3` and a zeroed third component.
- New components and their editor surface: `Rigidbody2D`, box/circle/capsule/polygon/edge colliders, 2D
  character controller, 2D joints, 2D queries, gizmos, inspectors, C# wrappers and generated bindings.
- Tick pipeline integration (`Tick.Physics2D`), scene serialization defaults, prefab support and tests.
- Rendering/authoring 2D is **outside** physics: sprites, orthographic camera, 2D editor mode, tilemaps and UI
  are separate features. Physics modularity does not provide them.
- A 2D conformance set and, if networking is claimed, a 2D determinism/rollback matrix.
- Prebuilt Rapier2D archives for every platform, including web. Jolt cannot be a 2D backend.

**Selection semantics (decided)**

A project has two independent project-wide choices: `physics3d` and `physics2d`. They do not have to be the same
library. Jolt can be the 3D backend while Rapier2D is the 2D backend. "Per project" means no per-scene switch;
it does not force one library across both dimensions. The 2D choice becomes selectable when a 2D backend is
available (defaulting to the first available, Rapier2D); until then the 2D list is empty and 2D components are
unavailable.

**Unity-style 2D surface**

The 2D API mirrors Unity's naming and mental model:

- `Physics2D`: queries and settings. `Raycast`, `RaycastAll`, `CircleCast`, `BoxCast`, `CapsuleCast`,
  `OverlapPoint`, `OverlapCircle`, `OverlapBox`, `OverlapCapsule`, `CheckCircle`, `CheckBox`, and project-level
  gravity/iteration settings.
- `Rigidbody2D`: `BodyType` (Dynamic/Kinematic/Static), mass, gravity scale, linear/angular damping, freeze
  rotation, collision detection and sleeping.
- `Collider2D` plus `BoxCollider2D`, `CircleCollider2D`, `CapsuleCollider2D`, `PolygonCollider2D`,
  `EdgeCollider2D` and later `CompositeCollider2D` where the backend supports them.
- `PhysicsMaterial2D` for friction and bounciness.
- 2D joints: `HingeJoint2D`, `FixedJoint2D`, `SpringJoint2D`, `DistanceJoint2D`, `SliderJoint2D`,
  `WheelJoint2D`. Each is capability-gated; a backend offers only the joint types it implements.
- `Collision2D` for 2D contact callbacks.
- A 2D kinematic character controller is optional; Unity does not have one built in, so do not assume it.

This is the **physics** side of "2D versions of each item". Rendering and authoring equivalents (sprites, a 2D
camera, tilemaps, 2D editor mode) are separate work; the naming convention can extend to them later, but the
physics abstraction does not provide them.

Layers and world states use the same project layer names, but 2D needs its own collision matrix
(`ProjectConfig` gains a second 32x32 matrix when 2D lands), as Unity keeps 2D and 3D layer collisions separate.

**Effort shape**

Once a Rapier3D integration exists, a Rapier2D backend is a comparatively small delta: the same C bindings built
with `RAPIER_DIMENSION=2`, an `r2` native shim, and 2D shape/query mappings. The bulk of 2D is the engine-facing
API, components, editor and C# surface. The current abstraction work is what prevents that bulk from also
requiring a redesign of the physics core.

**What to do now to keep it cheap**

- Keep `PhysicsDimension` on providers and key the registry by it.
- Keep the 2D world/API separate; never let `Scene.Physics` be the only place a world can live.
- Factor reusable bookkeeping (entries, layers, world states, contact dispatch) into helpers that do not know
  about 3D math.
- Do not put `Vector3` into neutral shapes/queries that a 2D front end would be tempted to reuse.
- Give 2D its own `PhysicsFeature2D` enum/bit space; do not pack 2D features into the remaining bits of the 3D
  enum.
- Write new systems (navigation, water, tools) against a world parameter, not `Scene.Physics` directly.
- Add the `physics2d` project setting now, with an empty provider list; do not expose 2D components until a 2D
  backend is offered.

### 3.9 Writing an out-of-tree integration

The intended workflow:

1. Add a Beef project/folder that references the Tallow engine project and implements `PhysicsBackend` +
   `PhysicsBackendWorld` (or an extension interface for a narrower integration).
2. Implement the native shim in C/C++/Rust against the library's C ABI, exporting a small `tn_<name>_*` surface.
   Ship the library as a prebuilt archive per platform if its source toolchain should not become a Tallow build
   dependency; normal builds must not require that toolchain.
3. Register the provider before the first scene: `PhysicsBackends.Register(new MyBackend());` from the game's
   startup code or a static constructor.
4. Name it in `ProjectConfig.tconfig` (`physics3d MyBackend` or `physics2d MyBackend2D`) or select it in
   Project Settings.
5. Link the native library in the game project's link flags (and in the editor/player build if they should show
   it).

The plan includes `Tests/CustomPhysicsBackend`, a deliberately tiny backend with a stub native library, built by
CI, to prove this works without editing engine files. It also proves capability gating: it claims only rigid
bodies and box/sphere shapes, so SoftBody/Rope must disappear in its projects.

## 4. Refactoring Jolt into a backend

This phase must not change behaviour. The front end must end up with no Jolt-specific fallback: every current
Jolt use (bodies, queries, characters, joints, soft bodies, ropes, buoyancy, navigation geometry and exact state)
moves behind the Jolt backend, and the generic engine calls only the neutral interfaces. The split is:

```
Engine/src/Physics/
    PhysicsWorld.bf              front end
    PhysicsBackend.bf            provider + world interfaces, settings
    PhysicsTypes.bf              BodyState, hits, contacts, character, snapshots
    PhysicsShapes.bf             ShapeDesc and shape helpers
    PhysicsFeatures.bf           flags and helpers
    PhysicsLayerTable.bf         shared layer/world-state rules
    PhysicsComponentRules.bf     requirements and validation
    PhysicsSnapshot.bf
    Backends/Jolt/
        JoltPhysicsBackend.bf
        JoltPhysicsWorld.bf      body/shape/query/joint/character/state primitives
        Jolt.bf                  moved from Platform/Jolt.bf
        JoltExtensions.bf        soft bodies, ropes, buoyancy, geometry
    Backends/Rapier/
        ...
```

Specific moves:

1. `CreateShape`, query-shape caches, `EnsureCreated`, `CreateBody`, `DestroyBody`, velocities/forces, sleeping,
   joints, characters, `Step`, `SaveExact`/`RestoreExact`/`SaveShared`, raw queries and contact collection move
   into `JoltPhysicsWorld`. Everything that tracks objects, transforms, layers, world states or dispatches
   callbacks stays in `PhysicsWorld`.
2. Jolt init (`JPH_Init`, job system) becomes Jolt-backend state. It stays process-wide, as today, and gets a
   process-shutdown hook; do not tear Jolt down between scenes unless re-initialisation is verified, because
   `JPH_Shutdown` is not called anywhere today.
3. `PhysicsWorld.[Friend]ObjectLayer` uses in `SoftBody`/`Rope` become a public `PhysicsWorld.ObjectCode(Transform,
   motionClass)`, or the extension receives the code from the front end.
4. `Jolt.CharacterState`/`Jolt.CharacterHit` become `CharacterState`/`CharacterHit`; `CharacterController` is
   edited to match.
5. The static snapshot helpers become `PhysicsSnapshot` objects; `NetworkManagerLockstep` and the history/server
   managers are updated to store and free them. This removes the last reason to name `PhysicsWorld` statically.
6. `Water` stops using `[Friend]mSystem`: rigid buoyancy goes through `PhysicsBuoyancyExtension`, soft-body float
   through the soft-body extension. `Floater` requires `BuoyancyRigidBodies`.
7. `tallow_navigation.cpp` takes triangles; `NavigationMesh.Bake` uses the geometry extension. Jolt and Rapier
   both provide triangles.
8. `PhysicsWorld.useAnalyticOverlapContacts` becomes a Jolt backend option; the generic world keeps a neutral
   quality hint only if needed.
9. `LastStepError` becomes a neutral step result (`overCapacity`, missing contacts, backend message), with Jolt's
   bit meanings mapped into it. `LastStepMilliseconds` stays engine-level.

Compatibility breaks (small, contained):

- `PhysicsWorld` is no longer directly constructible as a Jolt world; `Scene.Physics` still works.
- `PhysicsWorld.ExactSize`/`FreeExact` static helpers are replaced by `PhysicsSnapshot.Free()`.
- `Jolt.CharacterState`/`CharacterHit` names change.
- Code that reached into `PhysicsWorld.mSystem` no longer compiles (it should not have).
- Public engine code that named `PhysicsWorld` as a concrete type continues to work.

## 5. Rapier3D (deferred integration blueprint)

**Status: Rapier3D is integrated (2026-11-22) behind the seam, as a provider offered only where its prebuilt
archive exists.** It follows the locked decisions: prebuilt binaries, no Rust for normal builds, and every platform
supported before it is offered in releases (only Linux x86_64 has an archive in this tree). See "Rapier3D
integration" under section 9 for what is advertised and what remains.

References used for this section:

- [Rapier C getting started](https://www.rapier.rs/docs/user_guides/c/getting_started_c/)
- [Rapier C bindings README](https://github.com/dimforge/rapier/tree/master/bindings/c)
- [Rapier determinism](https://www.rapier.rs/docs/user_guides/bevy_plugin/determinism/)

Use Rapier's official C bindings (`bindings/c` in `dimforge/rapier`), pinned to the version in its `VERSION` file
(0.36.1+c.0 at the time of writing). They are C11 with optional C++17 RAII helpers and cover everything this
design needs: 2D/3D, f32/f64, rigid bodies, colliders, joints, character controllers, queries, collision and
contact-force events, contact manifolds, soft bodies, world snapshots and `enhanced-determinism`.

### 5.1 Build: prebuilt archives, no Rust in normal builds

Rapier is shipped as prebuilt static libraries, like a vendored native dependency. The Rust code and flags are
identical to a source build, so runtime performance is the same; the only difference is who runs Cargo. The
prebuilt archive adds link size, not a wrapper or a trampoline around the physics calls.

- A pinned maintainer/CI job (not a normal developer build) checks out the Rapier source at the tag recorded in
  `third_party/rapier/VERSION`, builds `bindings/c` with a pinned `rust-toolchain.toml` and `Cargo.lock`, and
  produces one static archive per target:
  - Linux x86_64
  - Windows x86_64 (MSVC ABI)
  - macOS arm64 and x86_64
  - web `wasm32-unknown-emscripten`, threaded and non-threaded
- The archives, headers, checksums, source tag, `Cargo.lock`, build flags and a provenance note ship with the
  engine (in the repo under `third_party/rapier/prebuilt/`, or in the engine release artifact if repo size is a
  problem). Normal builds download nothing.
- Add `option(TALLOW_RAPIER_PREBUILT "Use the shipped Rapier archives" ON)`. It imports the per-target archive
  and headers directly; it does **not** invoke Rapier's CMake (which unconditionally requires Cargo).
- Keep a maintainer-only `TALLOW_RAPIER_FROM_SOURCE` path for regenerating the archives. It is the only path that
  needs Rust; it is not in `tools/setup_dependencies.*`, `tools/build.py`'s tool check, or the normal CI flow.
  Document it in `docs/building-from-source.md` as a maintainer task.
- Build `native/tallow_physics_rapier.cpp` against the vendored headers and link the prebuilt archive, exporting
  `tnr_*` functions and `tnr_available()`.
- Always link one archive at a fixed path: when the option is OFF, build a stub archive with the same symbols
  where `tnr_available()` returns false. This keeps every link list valid regardless of the option and keeps the
  Beef provider compiling. The real Rapier archive is an additional link input when ON.
- Link dependencies of the prebuilt archive:
  - Linux/macOS: threads, `dl`, `m`; macOS also Security and CoreFoundation.
  - Windows: `ws2_32 userenv bcrypt ntdll advapi32`, plus what the engine already lists.
  - Update `Launcher/BeefProj.toml`, `Player/BeefProj.toml`, `Editor/src/Project/Project.bf` (new projects!),
    `tools/build_player.py`, `tools/macos_link.py`, the web build scripts and the CI cache keys.
- Build the archive jobs with:
  - `RAPIER_DIMENSION=3`, `RAPIER_PRECISION=32`
  - `RAPIER_SHARED=OFF`
  - `RAPIER_BUILD_TESTS=OFF`, `RAPIER_BUILD_EXAMPLES=OFF`
  - `RAPIER_ENABLE_PARALLEL=OFF` initially (smallest deterministic feature set; revisit with evidence)
  - `RAPIER_SIMD_LANES=4` (8 lanes is incompatible with enhanced determinism)
  - `RAPIER_FEATURES=enhanced-determinism`
- Build every target in one job with the same toolchain, crate versions and features. That is what makes later
  cross-platform determinism claims credible. `r3CheckAbi` plus a recorded header/archive hash catch a mismatch.
- Add Rapier, its Rust dependencies and Cargo licenses to `tools/make_licenses.py`,
  `THIRD_PARTY_LICENSES.txt` and `LICENSES_AND_RELEASE.md` from the vendored lockfile.

### 5.2 Native shim

Keep the Beef backend free of Rapier struct layouts: a C++ shim exposes engine-shaped calls.

- Worlds: create/settings/gravity/step, matrix + hook installation, event collector.
- Bodies: create from `PhysicsBodyDesc` + shape description, destroy, pose, velocities, forces/impulses,
  sleeping, mass, CCD, lock rotations, user data, layer/object code.
- Shapes: ball/cuboid (round), capsule, cylinder, convex hull, trimesh; compound parts become multiple colliders
  on one body. Collider user data carries the engine part index and object code.
- Queries: ray/shape casts, all-hits, overlaps, checks, with `R3QueryPredicate` applying the shared layer/world
  rules; debris skipping stays in the front end where it is today.
- Joints: spherical/revolute/prismatic/spring mapping, motors, limits, readings; opaque joint handles allocated
  by the shim.
- Characters: kinematic character controller settings, move, ground state, collisions; push dynamic bodies with
  impulses using mass and push strength.
- Contacts: collision events start/stop plus pair tracking for stay; manifold/solver contacts for point, normal
  and relative speed; sensors separated.
- Snapshots: `r3SerializeWorld`/`r3DeserializeWorld`, ABI/version-checked; engine body ids are re-mapped from
  user data after restore.
- Navigation: collect static collision triangles.
- Error handling: every call checks `R3Status`/last error; Rust panics are caught at the shim boundary and become
  a failed status, never an unwind across C.

`r3CheckAbi` runs at provider init. A mismatch makes the provider unavailable with a clear message.

### 5.3 Mapping notes

- Engine body ids stay `uint32`; the backend keeps a map to Rapier handles. `FixedBodyIndex` assigns engine ids;
  collider/body user data makes the map reconstructible after a snapshot.
- Friction/restitution are collider properties in Rapier; apply the Rigidbody's values to every collider of the
  body (including compound parts).
- Rapier's trimesh colliders can be dynamic, but Tallow currently forces mesh shapes static for Jolt parity. Keep
  that rule in the shared front end so both backends behave the same.
- Jolt's analytic overlap contacts and solver tuning have no exact Rapier equivalent. They become backend options,
  not promises of identical contact data.
- Result parity is semantic, not bit-identical. Same scene and inputs should produce recognisably equivalent
  gameplay; it will not produce identical trajectories. Do not switch a shipped game's backend casually; record
  the backend in saves/replays where determinism matters.

### 5.4 Determinism and networking

- Enable `enhanced-determinism`; keep parallel off and SIMD at 4 lanes until a matrix of builds proves either can
  be enabled without changing results.
- Pin Rapier, Rust, Cargo features and RNG; builds that do not match are incompatible for lockstep.
- Add golden state-hash tests per platform. If Rapier cannot meet the same cross-platform hash on every target,
  it must not advertise `CrossPlatformDeterminism`; dependent networking modes are then blocked in the editor.
- `SaveExact`/`RestoreExact` map to whole-world snapshots first. `SaveShared(firstIndex)` (the smaller lockstep
  sync) can start as a whole snapshot and become per-body later; advertise `SharedPhysicsState` only when the
  bandwidth/correctness tests pass.
- Jolt remains the default backend for networked projects until the Rapier matrix is green.

### 5.5 Web

The Rapier C bindings' WASM path is unproven (Rapier's JS packages use `wasm-bindgen`, not the C ABI). Web is
part of the platform gate, not an optional extra: the archive job must build the FFI crate for
`wasm32-unknown-emscripten` (threaded and non-threaded) and link it into the web player. If it cannot, Rapier is
not offered as a selectable backend at all; the stub keeps the engine linking and the provider stays unlisted.
"Do not add Rapier until it supports every platform" is the rule; a desktop-only Rapier is not acceptable.

### 5.6 2D backends: Rapier2D and Box2D (later)

The 2D Physics list is filled the same way as the 3D one. The intended entries:

- **Rapier2D**: the same official C bindings built with `RAPIER_DIMENSION=2`, shipped as prebuilt archives for
  every platform (including web). Rust stays maintainer-only. The integration shares the provider/registry/
  capability code with Rapier3D and has a separate `r2` native shim and `Vector2`-shaped 2D world.
- **Box2D**: a C++ library built from source like the other native dependencies (no new toolchain). It is a
  smaller integration target for rigid bodies, 2D colliders, joints, queries and contacts. Its feature set is
  declared through `PhysicsFeature2D`; anything it does not implement (for example some joint types, soft
  bodies, buoyancy) is simply unavailable under a Box2D project.

Both must pass the 2D conformance suite and the all-platform gate before they appear in the 2D Physics list.
The Unity-style 2D component names are the same regardless of which 2D backend is selected; only the
capability-gated subset changes.

## 6. Component availability

### 6.1 One rule, every add path

Add `Engine/src/Scene/ComponentAvailability.bf`:

```beef
static class ComponentAvailability
{
    public delegate bool Rule(Type type, Scene scene, out StringView reason);
    public static void AddRule(Rule rule);
    // Class components and handles/data are added by type; handles also check in their own lifecycle.
    public static bool CanAdd(Type type, Scene scene, out StringView reason);
    public static bool IsAvailable(Component component, out StringView reason);
}
```

Availability has two parts, and both must be true:

1. **The feature exists in this build.** The module/native code is compiled in. A feature left out of an optional
   build is not addable even if the selected backend could do it. Today everything is compiled in; the rule exists
   so smaller builds work later.
2. **The selected backend implements it.** The capability bit is set and has passed conformance.

If a component type is not compiled at all, it is absent from `ComponentRegistry`/`HandleComponents` and
`NativeComponentTypes`, so it cannot be added or loaded. For an optional build, wrap the component class and its
bindings in the build flag (rather than relying on the runtime guard alone), so reflection never lists it. If the
type is compiled but its backend feature is missing, the guard refuses it and explains why.

Physics registers a rule backed by `PhysicsComponentRules`, using the project's selected backend (not a scene
override). Every add path calls it:

- `GameObject.AddComponent(Type)` and `AddComponent<T>()`
- `GameObject.AddData(Type)`
- `HandleComponents.Add`
- `SceneSerializer`/`AddSavedComponent` (load always succeeds; see 6.2)
- `EditorHost.AddComponent` / `CSharpEditorExtensions.HostAddComponent`
- `CSharpNativeComponents.Add`
- Add Component popup, GameObject creation menu, scene quick-add

The UI calls the same predicate for filtering, so there is no path that can create an unsupported component by
accident. Returning false from the guard is a warning with the reason, not a crash.

### 6.2 Adding, loading and switching

- **Add Component**: unsupported entries are omitted from the list by default, so they are not offered as
  components at all. An editor preference ("Show unavailable components") can show them disabled with the reason
  ("SoftBody needs soft bodies; this backend does not provide them"); even then the guard refuses the add. The
  same rule applies to the GameObject creation menu and scene quick-add.
- **Scene load**: the component is loaded, because the type exists and the data is valid; it is marked
  unavailable and does not simulate. The Inspector shows a banner with the reason and a "Remove" action. The
  authored `enabled` flag is not changed, so switching back restores the original state.
- **Runtime**: each physics component checks availability in creation/Start (`Rigidbody`, `CharacterController`,
  `Joint`, `SoftBody`, `Rope`, `Water`/`Floater`) and logs once per component type. `OnValidate` reports the same
  in the editor.
- **Backend switch**: Project Settings applies the change on the next Play and shows the list of components that
  will become unavailable. Nothing is deleted.
- **C#**: `Physics.BackendId`, `Physics.Supports(PhysicsFeature)`, and a C# `PhysicsFeature` enum (checked by
  `tools/check_csharp_enums.py`). `GameObject.AddComponent<T>()` returns false/null through the existing native
  guard. C# scripts can query features before using backend-specific behaviour.
- **Export/map validation**: `MapFiles` and the build/export step warn about components that the selected
  backend cannot run, with file/object names. A strict project option can make this an error; default is a
  warning so a project can be authored for multiple backends.

### 6.3 Capability drift

The Add Component list and the runtime warning must agree with the backend. They do because both read the same
`PhysicsFeatures`. Conformance tests verify that every advertised feature actually works; a mismatch is a test
failure, not a user-facing surprise.

## 7. Editor UX

- **Project Settings > Physics** (new page in `Editor/src/Project/ProjectSettings.bf`):
  - Backend dropdown (available providers only), library version, dimension.
  - Capability list with supported/unsupported marks.
  - Layer/collision-matrix link to the existing page.
  - "Run self-test" (development builds) and a link to the last report.
  - "Affected components" list when a backend is selected, before applying.
- **Project Settings > Modules** (new lightweight page): every `EngineModule` across systems, its id, version,
  availability and capability summary. This is the seed of the general modular story.
- **Inspector**: unsupported components get a banner at the top with the reason and Remove; their fields remain
  editable/saved (so the author can prepare for another backend) but tools that would create native state are
  disabled.
- **Add Component**: unavailable entries are omitted by default, with an optional "Show unavailable components"
  editor preference that shows them disabled with reasons; category "Physics" already exists
  (`InspectorPanel.ComponentCategory`).
- **Scene view**: no new gizmos required; existing collider/joint gizmos only draw when the component is
  available.

## 8. Testing and conformance

Add a headless conformance scene and a test switch (following existing `--test*` switches) so each backend runs
the same checks:

1. **Bodies/shapes**: drop boxes/spheres/capsules/convex/mesh/compound onto a floor; settle; verify no tunnel,
   expected contact count, sleep.
2. **Queries**: ray, all-rays, sphere/capsule/box casts, overlaps, checks; compound part index and mesh triangle
   index; layer masks and ignored bodies.
3. **Joints**: ball, swing limit, hinge + motor, slider + spring; expected ranges.
4. **Characters**: step up/down, slopes, ground state, jump grace, push a crate.
5. **Contacts**: enter/stay/exit and trigger events for a pair; sensor separation.
6. **Layers/world states**: 32-layer matrix and separated world groups; queries respect them.
7. **Snapshots**: exact save/restore determinism over N ticks; randomize bodies between save and restore.
8. **Extensions**: soft body/rope/buoyancy only if the backend advertises them.
9. **Gating**: a limited test backend hides SoftBody/Rope; loading a scene with them keeps data and disables.
10. **C#**: the same scene driven through the C# API; AddComponent refuses unsupported types.

Test harness:

- `tools/run_physics_conformance.py` launches the headless launcher with `--physics3d <id> --test-physics` (or
  `--physics2d <id>` for a 2D suite) and prints PASS/FAIL per feature. CI runs it for Jolt and the limited test
  backend; every future backend runs the same suite before it is offered.
- Determinism: a scripted scene prints a state hash per tick; the CI matrix compares Linux, Windows, macOS and
  web builds. `tools/run_rollback_bench.py` runs the networking path against each backend that advertises the
  required capabilities.
- Performance: extend `tools/run_csharp_bench.py` physics/raycast/character/pile modes with `--backend`. Record
  the Jolt baseline now; add a per-backend report (p50/p95/p99, memory) when a second backend exists. Benchmark
  results are documentation, not pass/fail, except for obvious regressions in Jolt.
- Editor: add an editor self-test for Add Component filtering, the compatibility banner, and the backend-switch
  report (the existing `Editor/src/Tools/*Test.bf` pattern).
- Out-of-tree: `Tests/CustomPhysicsBackend` builds and registers a minimal backend without engine edits. This is
  the acceptance test for "write an integration instead of changing the engine".
- Native ABI (when a second backend exists): a small C test calls its ABI/version check and `tnr_available`, so a
  mismatched prebuilt archive is caught before gameplay. For Rapier this is `r3CheckAbi`.

## 9. Phases

Work in order. Each phase ends with a working engine, formatted code, and the tests below passing. Jolt
behaviour is the invariant for every refactor phase.

Current work ends after Phase 3. No Rapier or second backend is added in this work.

### Phase 0 - Baseline and feature map (S)

- Record Jolt behaviour: the conformance scene, benchmarks (physics/raycast/character/pile/softbody), and the
  networking rollback baseline.
- Map every physics consumer and every feature to its component(s) and capability bit. This is the list the
  gating work is built from.
- No engine code changes beyond test scaffolding.

**Exit:** baseline numbers and behaviour are recorded; every physics consumer and every gateable feature is
listed; the capability enum and component table are reviewed.

### Phase 1 - Module + physics seam, Jolt only (L)

- Add `EngineModule`, typed registry, capabilities, `PhysicsBackend`/`PhysicsBackendWorld`.
- Split `PhysicsWorld` into front end + Jolt backend; move neutral types; snapshots become objects.
- Put every Jolt use behind the Jolt backend: bodies, queries, characters, joints, soft bodies, ropes,
  buoyancy, navigation geometry and exact state. Nothing outside `Physics/Backends/Jolt` may call Jolt.
- Jolt stays process-wide; it is not torn down between scenes.
- Add `Tests/CustomPhysicsBackend` with a trivial backend.
- No user-visible behaviour change; Jolt remains the only built-in and runs everything.

**Exit:** Jolt scenes, networking and benchmarks behave as before; the test backend registers and creates a
world without engine edits; no code outside `Physics/Backends/Jolt` names a Jolt type or API (comments and user
docs may still mention it); navigation, water, soft bodies and ropes all work through the seam.

### Phase 2 - Per-project selection, capabilities and gating (M)

- ProjectConfig `physics3d` and `physics2d` keys (both project-wide; no per-scene override),
  `--physics3d`/`--physics2d` overrides, provider listing, `Physics.Supports` and `Physics2D.Supports` in Beef
  and C#.
- `ComponentAvailability` checks both "feature exists in this build" and "selected backend supports it"; all
  add-path guards, editor filtering/banners, compatibility report, map/export warnings.
- Test backend advertises a reduced feature set, proving gating before Rapier exists. The 2D provider list is
  empty, so 2D components are unavailable.
- Project Settings > Physics has two groups (3D Physics with Jolt; 2D Physics empty for now), each showing the
  selected backend and capability list; Jolt remains default for 3D.

**Exit:** a limited-backend project cannot add SoftBody/Rope; loading such a scene keeps data, disables it and
explains; C#, editor scripts and every menu path obey the guard; the selected backend runs every physics
system, with no hidden Jolt work.

### Phase 3 - 2D shape (S/M)

- Add `PhysicsDimension` to provider metadata; key the registry by dimension; keep `Scene.Physics` explicitly
  3D.
- Factor the shared bookkeeping (entries, transform sync, layers, world states, contact dispatch) into helpers
  that do not depend on 3D math, so the 2D front end does not duplicate it.
- Add the `Physics2DWorld` front-end skeleton and reserve the Unity-style 2D names (`Physics2D`,
  `Rigidbody2D`, `BoxCollider2D`, `CircleCollider2D`, `HingeJoint2D`, ...). No 2D gameplay components or 2D
  backend yet; the 2D project choice is present but empty.
- Reserve a separate 2D collision matrix and the `PhysicsFeature2D` capability space.
- Ensure no `Vector3`/`Quaternion` types leak into the 2D API.

**Exit:** dimension-aware registry compiles; the two project-wide choices exist (`physics3d` selectable,
`physics2d` empty); the Unity-style 2D API skeleton and naming map exist with no gameplay exposure; the shared
bookkeeping helpers are reusable; the future Rapier2D (or other) integration has a place to plug in without
changing the 3D design.

### Phase 1/2 progress (2026-11-22)

Implemented on `feature/physics-modularity`:

- `EngineModule`/`EngineModules`, `PhysicsFeature`/`PhysicsFeatures`, `PhysicsBackend`/`PhysicsBackendWorld`
  and the `PhysicsBackends` registry.
- `PhysicsWorld` is now the engine front end (entries, transforms, layers, world states, contacts, bookkeeping);
  `JoltPhysicsBackendWorld` owns every Jolt primitive. `Jolt.bf` moved under `Physics/Backends/Jolt/`; no code
  outside that folder names a Jolt type.
- Per-project `physics3d`/`physics2d` in `ProjectConfig.tconfig`, `--physics3d`/`--physics2d` overrides, a
  Project Settings physics section with two provider lists and a capability list. Only Jolt is available; the
  2D list is empty.
- `PhysicsDimension` on providers and a dimension-keyed registry, so a 2D provider can be added without changing
  the 3D design.
- `ComponentAvailability` + `PhysicsComponentRules` gate the Add Component menus, every add path, scene loading
  (data is preserved), the runtime component lifecycles, and the C# API. `Physics.Features`/`Physics.Supports`
  are exposed to C# with a matching `PhysicsFeature` enum. Unavailable components show an Inspector banner
  explaining why; `StartPlay` recreates the world when the project's backend changed.
- `JoltLimitedPhysicsBackend` (test-only) advertises no soft bodies or ropes, proving the gate. Headless checks:
  `--test-physics-gating` and `--test-physics-basic` (bodies, step, raycast, exact snapshot restore).
- `PhysicsRagdollExtension`, `PhysicsVehicleExtension` and their Jolt implementations are now wired; the
  `Ragdoll` and `Vehicle` components use them (see the conversion-complete section below).

### Networking through the backend (2026-11-22)

- `PhysicsBackendWorld` now tracks the bodies each backend makes and provides default snapshots
  (`SaveState`/`RestoreState`/`StateSize`/`FreeState`/`StateToBytes`/`StateFromBytes`/`SaveShared`) from body
  poses, velocities and sleep state. A new backend that implements the required body primitives is saved, rolled
  back, serialized and sent to other machines with no networking code of its own. Jolt overrides all of them with
  its exact native state, as do future backends whose library has native snapshots.
- Lockstep is gated on `PhysicsWorld.CanLockstep` (`SaveRestoreExact`, `SharedPhysicsState`, `FixedBodyIds`,
  `CrossPlatformDeterminism`): a backend with only the generic snapshots plays the other networked modes but
  refuses lockstep with a clear message (both when a session starts with it and when a client is told the server
  runs it).
- `--test-physics-snapshots` proves the default path with a backend that only implements bodies (save, restore,
  bytes, shared state, a damaged snapshot refused, lockstep refused).

### Physics conversion complete (2026-11-22)

- Soft bodies, ropes, water's soft-body float and navigation's geometry all go through neutral extensions:
  `PhysicsSoftBodyExtension`, `PhysicsGeometryExtension` and the backend's buoyancy call. No `mSystem` (Jolt world
  pointer) or direct Jolt type escapes the Jolt backend.
- `PhysicsRagdollExtension` and a Jolt `JPH_Ragdoll` implementation exist; the engine `Ragdoll` component builds
  parts from a Skinned Mesh Renderer's skeleton and drives the bones from the simulated pose. The capability is
  `Ragdolls`; other backends can build the same parts from articulations or ordinary joints.
- `PhysicsVehicleExtension` and Jolt implementations of all three kinds exist: **wheeled**, **motorcycle** and
  **tracked**. The capability bits are per kind (`WheeledVehicles`, `MotorcycleVehicles`, `TrackedVehicles`), so a
  future backend can implement only the kinds it offers; the Vehicle kind dropdown lists just those. The engine
  `Vehicle` component exposes the chassis, wheels (position, radius, width, suspension, steering, brakes, driven),
  engine, gears, anti-roll bars, motorcycle lean and tracked track settings as saved Inspector fields. The Drivable
  Car template is the wheeled kind.
- The Drivable Car project template adds the Kenney `sedan-body.glb` and `wheel-default.glb` (CC0), CC0 GGBot
  engine sounds, a chase camera and a `CarController` C# script. The launcher templates are now a dropdown:
  Empty, First person, Third person, Drivable car, Tallow Gallery (the voxel sandbox is gone).

Remaining before Rapier:

- Add the Project Settings self-test button, C# enum parity check for `PhysicsFeature`, and the integration and
  capability docs.

### Rapier3D integration (2026-11-22)

Rapier is now a second 3D provider behind the same seam. It follows section 5's locked decisions: prebuilt archives,
no Rust in normal builds, and the provider is listed only when the archive for the target exists and `r3CheckAbi`
passes. The rest of the engine is unchanged; `PhysicsBackends` registers it after Jolt when it is available.

**Build and link**

- `native/CMakeLists.txt`: `option(TALLOW_RAPIER)` (default ON). The archive is taken from
  `third_party/rapier/prebuilt/<platform>/` (`linux-x86_64`, `windows-x86_64`, `macos-x86_64`, `web-wasm32`) and
  copied to `build/<native>/rapier/`. `RAPIER_STATIC`, `RAPIER_DIM3` and `RAPIER_F32` are compile definitions.
- `native/tallow_rapier.cpp` is compiled against the vendored headers; `native/tallow_rapier_stub.c` takes its
  place when the archive is absent, keeps every symbol the Beef provider links and reports
  `tn_rapier_available() = 0`. An empty placeholder archive is built at the same fixed path so the Beef link lists
  stay valid.
- `Launcher/BeefProj.toml`, `Player/BeefProj.toml` and the editor's generated project link flags include
  `build/native/rapier/librapier3d_ffi.a` inside the existing `--start-group`.
- `native/tallow_rapier.h` is the narrow C ABI: worlds, bodies, shapes, queries, joints, characters, contact events,
  navigation geometry, soft bodies, vehicles and the provider probe. Rapier handles and descriptors never leave the
  shim.

**Implemented and advertised** (`RapierPhysicsBackend.AllFeatures`)

- Rigid, kinematic and sleeping bodies; sensors; CCD; freeze rotation; debris filtering; fixed body ids; multiple
  worlds; separated world states.
- Box, sphere, capsule, cylinder, convex hull, mesh and compound shapes (a compound is one collider per part, which
  also gives per-part hit detail).
- Raycasts (single and all-hits), shape casts (single and all), overlaps, checks, and part/triangle hit detail.
- Contact begin/stay/end and sensor trigger events. Contacts are rebuilt from the narrow phase's pair lists every
  tick, so pairs that begin during the broad-phase refresh before a step are still reported.
- Ball (with swing limits), hinge (with a motor and angle reading) and slider (with a spring and position reading)
  joints.
- The kinematic character controller: slide, slopes, autostep, snap-to-ground, ground state, ground body/velocity,
  what it ran into, shape changes and pushing dynamic bodies. The shape's local centre is applied to the swept pose,
  which keeps a component-style capsule (centre raised above the transform) standing on the floor.
- Rigid-body buoyancy.
- Navigation geometry: every static collider's shape is tessellated at its pose (`r3SharedShape_ToTrimesh`).
- Ragdolls: ordinary dynamic bodies joined by ball joints, exposed through `PhysicsRagdollExtension`.
- Wheeled vehicles: Rapier's ray-cast vehicle controller with a small automatic gearbox over the declared ratios.
  Rapier's suspension force is `stiffness * compression * chassisMass`, so the stiffness is derived from the wheel's
  ride frequency (`(2*pi*f)^2 / 4`) with damping `zeta * pi * f / 2`; engine force includes the 3.5 final drive that
  Jolt's differentials use. The suspension ray spans the engine's maximum length plus the wheel radius (Rapier does
  not add the radius itself). Motorcycles and tracked vehicles are not implemented and are not advertised; the
  Vehicle component only offers the wheeled kind under Rapier.
- Soft bodies at Jolt parity: Cloth, Jelly (volume preservation driven by the engine's gas amount), Shell (rides its
  object, keeps impact dents from the object's contacts with Dent Speed/Depth/spring-back, and re-wraps its convex
  hull from the dent revision), and DrivenJelly (a skin that lags behind its rigidbody and springs back). Positions
  follow Jolt's convention: creation positions are relative to the body centre, every read/write/move is
  world-space. Cloth and shells use explicit structural edges (no shape matching) so they fold and dent. Soft-body
  buoyancy samples the water grid and lifts/drags submerged particles. Ropes are particle chains with ties as
  Rapier rope joints, pull force from the joint impulse, and physical wind; knots are the engine's own torque.
  Rope pulleys are not implemented and are not advertised.
- Rapier soft-body tearing is a software capability bit (`SoftBodyTearing`) and a Soft Body toggle that is hidden
  entirely on Jolt. Overstretched edges are torn through Rapier's tear pass (with its tear events); the toggle is
  off by default.

**Networking**

- Rapier uses its own whole-world snapshot (`r3SerializeWorld`/`r3DeserializeWorld`): bodies, colliders, joints,
  soft bodies and their deformation. Restoring makes a new native world and re-binds every handle the shim holds
  (bodies and their colliders, soft-body roots, character bodies and colliders, impulse joints by body pair, and
  vehicle controllers rebuilt on the new chassis); rope ties are dropped and the engine ties them again. The snapshot
  is wrapped in a magic/version header for `StateFromBytes`.
- `SaveShared` is the same exact whole-world snapshot for now (the plan allows this first form); it is correct but
  heavier than a per-body diff. It is exact enough for lockstep and much simpler than per-body remapping.
- `SaveRestoreExact`, `SharedPhysicsState`, `FixedBodyIds` and `CrossPlatformDeterminism` are advertised, so
  `PhysicsWorld.CanLockstep` is true. Cross-platform determinism is verified by a fixed-scene state hash over the
  raw float bits: Linux x86_64 and the Windows x86_64 build (run under Wine) both produce `0C8328CBC10D45D6`
  after 240 steps. Both archives are built from the same Rapier source with `enhanced-determinism`, SIMD 4 and
  parallel off.

**Tests**

- `--test-physics-rapier` (conformance): all-hits raycasts and layer masks, shape casts, overlaps/checks, contact and
  trigger enter/stay/exit, ball/hinge-motor/slider-spring joints, the character controller (plain and centred
  capsules), buoyancy, and Rapier-specific object-code filtering.
- The existing suite passes on both backends: `--test-physics-basic`, `--test-physics-snapshots`,
  `--test-physics-gating`, `--test-physics-ragdoll`, `--test-physics-vehicle`, `--test-physics-vehicle-kinds`
  (kinds the backend advertises; Jolt still runs all three), `--test-physics-softbody`.
- `--test-physics-vehicle-kinds` now skips kinds a backend does not advertise instead of requiring Jolt's three.
- `--test-car-scene <project>/src/Scenes/Main.tscene` loads a saved Drivable Car scene and drives it for three
  seconds; the stock car travels 17.9 m under Rapier and 21.3 m under Jolt.
- `--test-physics-softbody-kinds` covers jelly pressure, shell dents, driven skin, soft-body buoyancy and tearing;
  `--test-physics-rope` covers a rope body and a tie carrying a load. Both pass on Linux and Windows.
- The soft-body world-space convention and wind scaling were fixed after the Gallery's flag/cloth stretched across
  the sky: reads/writes/moves are world-space like Jolt, and wind is a density/area-scaled impulse instead of a raw
  per-step velocity kick. The Soft Body Lab and the Courtyard flag now render normally under Rapier.

**Open gates**

- Linux x86_64 and Windows x86_64 archives exist and are tested (the archives are gitignored). `tools/build_rapier.py
  --platform windows` cross-builds the Windows archive with Rust's `x86_64-pc-windows-msvc` target, `lld-link` and
  the engine's xwin CRT/SDK; the Windows link lists also add `userenv ntdll bcrypt synchronization` for Rust's std.
  The Windows launcher, player and every Rapier test (conformance, soft-body kinds, ropes, vehicles, the car scene)
  pass under Wine, including the same determinism hash. macOS and web archives still need a build (web needs
  Emscripten); until then the provider is unlisted there, never a link error.
- Rope pulleys, motorcycles and tracked vehicles remain unimplemented and unadvertised. A saved car with an empty
  gear-ratio list now falls back to a usable gear (it used to read past the list).

### Later work (not in this plan)

- **Rapier3D platform gate**, per section 5: Windows, macOS and web archives, then the conformance and golden-hash
  matrix, before the provider is offered in releases on those platforms.
- **Other systems**, per the section below.

### Later: apply the pattern to other systems (M/L)

Ordered by value and risk:

1. **Network transport** (already abstract): register `NetTransport` implementations as modules, expose the
   choice in Project Settings, add capabilities (Steam, WebRTC, compression).
2. **Audio**: extract `AudioBackend` from `Audio`/`AudioSource`/`VoiceChat` over the existing `tn_audio_*` ABI;
   miniaudio is the built-in. Capabilities: HRTF, reverb, streaming, voice capture, Opus.
3. **Save storage** (already abstract): register as a module; no behaviour change.
4. **Navigation**: after the geometry decoupling, a `NavigationBackend` for Recast/Detour; defer alternative
   navmesh solvers until there is a second implementation.
5. **Input/platform**: split SDL's time/path utilities from window/input first; do not attempt a second window
   backend yet.
6. **Renderer, UI/ImGui, ECS/Flecs**: do not modularize now. bgfx already selects D3D/Vulkan/Metal/GL/WebGL;
   a second renderer would require replacing most of `Engine/src/Render` and the public resource APIs. Flecs is
   the authoritative store. Record the decision rather than pretending these are cheap.

**Exit:** audio and network transport are selectable modules through the same framework; the plan for the
remaining systems is explicitly "not now" with reasons.

## 10. Other systems, honestly assessed

| System | Current seam | Modularity | When |
|---|---|---|---|
| Network transport | `NetTransport` abstract class | Low effort; already there | Later |
| Save storage | `SaveStorage` abstract class | Low; already there | Later |
| Audio | flat `tn_audio_*` ABI, 13 call sites | Low-medium; reimplement ~20 calls | Later |
| Navigation | `tn_nav_*` mesh ABI, one Beef file | Medium after geometry decoupling | Later |
| Asset import | `tallow_assets.c` + tool-only Assimp | Low for importers; rendering-coupled outputs | Later |
| Input | SDL-shaped keys/events | Medium; SDL event leaks into hooks | Later |
| Platform/window | SDL in 21+ files as utility | Medium-high; split utilities first | Later |
| Scripting | `tn_csharp_*` ABI + entrypoints | Medium-high; woven into lifecycle/net/UI | Not soon |
| Renderer | bgfx in 25 engine files / 720 calls | Very high; keep bgfx's own backend selection | Not now |
| UI | ImGui in 87 editor files | Very high; editor is an ImGui app | Not now |
| ECS | Flecs wrapper, authoritative storage | High; replacing it re-implements the runtime | Not now |
| Water/Voxel | physics consumers | Not modules; depend on physics capabilities | Gated now |

## 11. Risks

- **Rapier on web.** The C ABI/Emscripten path is unproven. Web is part of the all-platform gate: if the
  prebuilt archive cannot be built and pass conformance for the web player, Rapier is not offered at all.
- **Prebuilt archive provenance.** Rust is maintainer-only, but the shipped archives must match the vendored
  headers and be built from the recorded source/tag/toolchain. Checksums, `r3CheckAbi` and one pinned build job
  per release are the controls. A mismatch must make the provider unavailable, never crash.
- **All-platform archive matrix.** Rapier must be built for Linux, Windows, macOS and web (threaded and
  non-threaded) before it is selectable. Missing a target blocks the integration; it is not a "later platform"
  problem.
- **Determinism.** Rapier's `enhanced-determinism` is version- and build-sensitive. Lockstep requires pinning
  Rust/crates/features and hashing state across platforms. If it fails, do not advertise the capability.
- **Performance/semantics.** Solver differences change feel. Publish benchmarks and per-backend tuning; do not
  promise identical gameplay.
- **Soft bodies/ropes.** Both engines have soft bodies, but Tallow's cloth/jelly/shell modes, dents, pressure,
  skin and Cosserat ropes have specific semantics. Each is a separate capability flag; a backend advertises only
  what it implements and passes. Do not assume parity from a library feature list, and do not make a feature
  Jolt-only in the architecture.
- **Capability drift.** A claim without a conformance test becomes a lie. Every bit must have a test.
- **API churn.** Rapier's C bindings are 0.x. Pin, vendor, and treat upgrades as a project.
- **Build surfaces.** Native link lists are duplicated in six places (including generated game projects and the
  Windows/macOS/web paths). Missing one produces link errors only on that platform. The stub archive keeps the
  option off/on safe, but the archive path still has to be added everywhere.
- **Repo/build size.** Rapier plus vendored Cargo dependencies is large; CI and source tarballs grow.
- **Networking bandwidth.** Whole-world Rapier snapshots may be too large for `SaveShared`; measure before
  advertising lockstep.
- **Authoring semantics.** Loading unsupported components must not silently alter saves. Keep `enabled` and the
  serialized data untouched.
- **Two implementations of layer filtering.** Jolt's table and Rapier's hooks must be generated from the same
  `PhysicsLayerTable`; add a shared test that compares expected collision pairs, not just gameplay outcomes.

## 12. Decisions

Resolved (2026-11-22):

1. **Rapier ships as prebuilt binaries; Rust is not required for normal builds.** Maintainer/CI only.
2. **Every offered backend must build on every supported platform, web included, from the start.** No
   desktop-only backend.
3. **Backend selection is per project, not per scene.**
4. **The selected backend runs all physics.** No hidden Jolt work under another backend.
5. **Jolt stays default.**
6. **Soft bodies are a capability, not a Jolt monopoly.** Both engines have them; each behaviour is tested and
   gated individually.
7. **Components for features that do not exist cannot be added.** Authored data is preserved and explained.

Remaining implementation choices (not blockers):

- Where the prebuilt Rapier archives live: committed under `third_party/rapier/prebuilt/` or shipped only with
  the engine release artifact. Both avoid a Rust requirement; the trade-off is repository size vs offline builds.
- Whether to compile unavailable component code out of optional builds later (binary size), or keep all
  component types compiled and gate them at add/load time. The plan does gating now and leaves compile-out as a
  later optimization.
- How strict export validation is (warning vs error) for scenes containing components the selected backend
  cannot run. The plan defaults to a warning plus a strict option.

## 13. Definition of done (current work)

- Physics is a front end plus a backend; Jolt is the only built-in backend and runs **everything**: bodies,
  queries, characters, joints, soft bodies, ropes, buoyancy and navigation geometry.
- Every engine and gameplay call site goes through `PhysicsWorld`/the neutral extensions; only
  `Physics/Backends/Jolt` names a Jolt type or API.
- A project selects its 3D and 2D backends independently in Project Settings or `ProjectConfig.tconfig`
  (`physics3d`, `physics2d`; per project, no scene override); `--physics3d`/`--physics2d` override them for
  tests. Jolt is the only 3D option today and the default; the 2D list is empty until a 2D backend ships.
- The Add Component menus, every add guard, scene loading, C#, editor scripts and export validation all consult
  one availability rule that checks both **build presence** and **backend support**.
- A test backend with a reduced feature set proves components cannot be added, scenes keep their data, and the
  Inspector explains the missing feature. No authored data is deleted.
- `Tests/CustomPhysicsBackend` registers and runs without engine edits.
- Jolt behaviour, benchmarks and networking are unchanged by the refactor.
- The 2D dimension-aware provider registry and `Physics2DWorld` skeleton exist, with no 2D gameplay exposure.
- Docs exist: this plan, an integration guide, a capability/component map, and updates to
  `physics-queries.md`, `character-controller.md`, `soft-bodies.md`, `water.md`, `networking.md`,
  `building-from-source.md` and the C# gameplay docs.
- The Rapier blueprint records the prebuilt, no-Rust, all-platform path; nothing from it is required now.
