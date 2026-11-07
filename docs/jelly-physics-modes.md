# Jelly physics for Jelly Golf

This integration has two **Jolt** approaches. It deliberately does not add a scale-based or preanimated jelly component.

## 1. Full soft-body Jelly — physical deformation

**Setup:** Put a `MeshRenderer` and `SoftBody` on the ball, then select `kind = Jelly`. A separate Rigidbody is not needed. Jolt simulates the actual soft-body vertices, contacts, and motion.

The existing `SoftBodyKind.Jelly` remains unchanged, but the `SoftBody` class now has:
- `Velocity` (get/set): mass-weighted velocity of the movable vertices; a setter shifts all movable velocities equally without erasing their relative wobble
- `AddImpulse(Vector3)`: changes the body's total momentum, preserving its current wobble
- `AddForce(Vector3)`: applies a force over one fixed timestep; call it once per fixed tick

Example Beef gameplay code (with a valid reference to the ball's `SoftBody`):

```beef
soft.AddImpulse(aimDirection * shotStrength);
```

**Tradeoff:** This is physically deformable and more costly; its body and contacts, not a rigid sphere, decide how the ball moves. Multiplayer shot/scoring rules should remain server-authoritative.

## 2. DrivenJelly — a physically simulated visual skin

**Setup (no animation clips or rigs):**

```text
GolfBall (GameObject)
  Rigidbody
  SphereCollider
  NetworkIdentity (when needed for multiplayer)
  BallMesh (child GameObject, no Collider)
    MeshRenderer (closed, triangulated ball mesh)
    SoftBody (kind = DrivenJelly)
```

You can also put the `SoftBody` on the Rigidbody object itself, with a MeshRenderer there. The Rigidbody must have a Collider on **the same GameObject** as the Rigidbody; the SoftBody may be on that object or a child.

The Rigidbody controls positions, rigid collisions, bounces, rolling, and ordinary network prediction. Jolt updates the individual surface vertices and springs them back to the driver's moving shape. The skin does not collide independently with objects, does not permanently dent, and does not change the rigid ball's gameplay physics.

**Inspector tuning** (default values):
- `drivenFlex = 0.2`: the maximum allowed surface lag/deviation in metres
- `drivenSpring = 0.25`: how strongly the mesh returns toward its shape each fixed step
- `drivenDamping = 0.75`: how much relative vertex velocity survives each step

`SoftBody` also has the usual solver settings (`mass`, `stiffness`, `iterations`, etc.). A clean sphere mesh with sufficient vertices is needed to see the motion clearly. This mode needs no authored animations, weight painting, or rigging.

**Startup fix:** Tallow creates normal Rigidbody bodies during `Rigidbody.SyncAll`, after components' `Start`. DrivenJelly now calls `Rigidbody.EnsureBody()` if its driver has not been created yet. This avoids its previous failure to initialize at an ordinary scene launch.

## Which should the game use?

Use `DrivenJelly` for the default multiplayer golf ball when visually detailed wobble and ordinary predictable Rigidbody behavior matter. Use full `Jelly` for bonus modes or objects where jelly deformation should change the physical simulation.

Both modes simulate vertices; their computational costs vary with vertex count, mesh topology, solver settings, and simultaneous balls. This is **not** a benchmark or guarantee.

## Validation on Linux / Windows

1. Build the engine and native library together: `./build.sh --config Debug --jobs 8` on Linux, or the corresponding Windows build process.
2. Place a SphereCollider and Rigidbody on a parent, MeshRenderer and DrivenJelly SoftBody on an uncollided child, and start play. Confirm the soft-body component has a body from the first tick.
3. Hit and roll the ball; verify the surface flexes and returns to its rest shape while the rigid sphere determines its motion.
4. Switch to full `Jelly`, then test `Velocity`, `AddImpulse`, and `AddForce` using a closed mesh.
5. Check that existing `Cloth` and `Shell` behavior remains unchanged; test a networked rigid ball with latency/jitter/loss.
6. Profile with realistic ball counts (1, 8, 16+) and meshes. **Interactive behavior and multiplayer correctness are not verified just by source review or a successful build.**

Only `Engine/src/Physics/SoftBody.bf`, `native/tallow_softbody.cpp`, and this guide are changed by this jelly transplant. No `JellyVisual` component is included.
