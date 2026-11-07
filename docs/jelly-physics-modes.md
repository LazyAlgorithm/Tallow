# Tallow Jelly Physics Modes — ECS Branch Change Log

This document describes the opt-in additions for three alternative jelly-ball setups.
The implementation targets GitHub's `ecs` branch. It does **not** include unpushed
local ECS roadmap work. Keep local changes and merge normally; do not hard-reset.

## Choose one mode per ball

### A. Real Jolt jelly (authoritative deformation)

- Ball object: `MeshRenderer`, `SoftBody` with `kind = Jelly`.
- No Rigidbody on the ball. Jolt soft-body vertices determine motion and collision.
- New public Beef API: `soft.Velocity` (world-space get/set), `soft.AddImpulse(Vector3)`,
  and `soft.AddForce(Vector3)`.
- `Velocity` is the mass-weighted average of movable vertex velocities; setting it adds
  an equal delta-V to each movable vertex and keeps its relative wobble.
- `AddImpulse` preserves existing wobble and distributes the total change in momentum
  using the current simulated mass. Pinned vertices remain pinned.
- `AddForce` is the same distribution for one `Time.FixedDeltaTime` step.
  Call it once per fixed tick, not once per rendered frame.
- Shell and DrivenJelly intentionally ignore these mutating APIs; use their Rigidbody.

Example (in a gameplay script, with a valid SoftBody):
```beef
soft.Velocity = .(0, 0, 2);
soft.AddImpulse(aim * shotStrength);
soft.AddForce(windForce);
```

### B. Cheap visual-only jelly — Rigidbody + JellyVisual

- Ball parent: `Rigidbody` + `SphereCollider` (or another appropriate collider).
- Uncollided mesh child: `MeshRenderer` + new `JellyVisual` component.
- No `SoftBody` component on this child.
- Normal rigid-body movement, hits, collision, rollback, and networking are unchanged.
- The visual child scales with speed and wobbles after abrupt velocity changes.
- Only the visual child's transform changes; **do not attach colliders to it**.
- Tune `stretchPerSpeed`, `maxStretch`, `kickPerSpeedChange`,
  `wobbleStrength`, `wobbleFrequency`, and `wobbleDamping`.
- This is simple squash/stretch, not vertex-level soft-body deformation.

### C. Rigidbody-driven Jolt elastic skin — SoftBodyKind.DrivenJelly

- Ball parent (or same object): `Rigidbody` + `SphereCollider`.
- Mesh object (may be a child): `MeshRenderer` + `SoftBody`, `kind = DrivenJelly`.
- The engine requires a live Rigidbody on the object or an ancestor.
- Rigidbody is solely responsible for gameplay movement and physical collisions.
- The skin uses Jolt's existing shell/skinning path to spring around its driven pose,
  without permanent dents. The soft body's external physical contacts are rejected
  so it cannot exert a second force on obstacles or the Rigidbody.
- Settings: `drivenFlex` (maximum skin deviation from reference),
  `drivenSpring` (spring-back per step), `drivenDamping` (velocity retention).
- Unlike Shell, DrivenJelly never creates a Rigidbody/ConvexCollider automatically,
  never permanently dents, never follows the body's dynamic center as a free jelly,
  and is excluded from soft-body collision proxies.
- It costs more than JellyVisual because Jolt simulates vertices and updates a
  dynamic mesh. Verify skin motion and mesh alignment in the interactive editor.

## Exact source changes

1. `Engine/src/Physics/SoftBody.bf`
   - Appended enum `SoftBodyKind.DrivenJelly` without changing existing enum values.
   - Exposed Velocity, AddImpulse, AddForce (real simulated soft bodies only).
   - Added drivenFlex, drivenSpring, drivenDamping editor settings.
   - Validates a parent/self Rigidbody for DrivenJelly, follows the existing
     Shell driver update, suppresses self-motion, wind and extra collision proxies.
   - Added native C ABI declarations / configuration matching the C++ struct.

2. `native/tallow_softbody.cpp`
   - Added `tn_soft_velocity`, `tn_soft_set_velocity`, `tn_soft_impulse`,
     and `tn_soft_force`, using vertex masses, Jolt body locks and body wake-up.
   - Extended the native configuration with `visualOnly`, `visualSpring`,
     and `visualDamping` in the same order as the Beef structure.
   - The shell skinning path can now provide a visual-only elastic mode:
     no collision response, no permanent dents, tunable spring and damping.

3. `Engine/src/Physics/JellyVisual.bf` (new)
   - Lightweight mesh-child scale animation driven by parent Rigidbody velocity.

4. `docs/jelly-physics-modes.md` (this document).

## Local merge and troubleshooting

After saving/committing your existing local work:

```sh
git fetch origin
git switch your-local-roadmap-branch
git merge origin/ecs
```

If you are *already* working on local `ecs`, use `git switch ecs` followed by
`git merge origin/ecs`. Resolve any conflict manually, particularly in
`SoftBody.bf`, `tallow_softbody.cpp`, or the physics pipeline.

If the Beef compiler complains of a missing `tn_soft_*` symbol, rebuild the
native library and engine together. These new exports require updated native
artifacts; an older native binary will not resolve them.

If the visual-only mode fails to appear, confirm:
- `JellyVisual` is on a **child** of a Rigidbody, not the parent collider.
- `DrivenJelly` has a live parent/self Rigidbody with a collider and a
  `MeshRenderer` with triangles.
- Visual-only physics uses one authoritative sphere collider, not a second
  collider on the jelly mesh.
- The SoftBodyKind numeric order is preserved (new value appended after Shell).

## Validation checklist (not yet executed)

- Build native Jolt bindings and the Beef engine in Linux Debug/Release and Windows.
- A Jelly sphere receives Velocity/AddImpulse/AddForce, wakes, settles, and
  has the expected total momentum change at varying mesh resolutions.
- Pins do not move and fully pinned soft bodies ignore motion calls.
- Shell and Cloth remain unchanged; existing Shell dents still behave correctly.
- JellyVisual on a Rigidbody child renders and restores its original scale
  when disabled; its mesh child has no collider.
- DrivenJelly on a Rigidbody child wobbles and returns to its rest shape;
  its rigid sphere alone collides, moves, and determines scored contacts.
- DrivenJelly does not register a free-body network identity or create collision
  proxies; parent Rigidbody moves identically with or without the visual skin.
- Check save/load of all new fields and component types; test spawn/despawn and
  hot reload to detect stale body handles.
- Run multiplayer (two clients, latency/jitter/loss) with shots, resets and
  course transitions. Compare authoritative ball positions and scoring.
- Measure total frame time, physics step cost, GPU draw calls and dynamic mesh
  bandwidth for 1/8/16 balls and 10k+ course props.

## Limitations

- No CI or interactive gameplay test was run as part of this GitHub-only edit.
- A large change on an unpushed local ECS branch may require manual merges.
- DrivenJelly is **visual physics**, not a physically deforming collision shape;
  in particular, the rigid collider cannot squeeze through smaller holes.
- JellyVisual is a cheap transform animation, not a true soft-body solver.
- An impulse/force on a full Jelly body can produce different vertex
  deformation on different multiplayer clients. Keep scoring server-authoritative.
- A fully accurate per-vertex hit-point impulse or rigid-body-style torque
  is not added in this change; those are separate features.
