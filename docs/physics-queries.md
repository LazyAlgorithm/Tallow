# Rays, shape casts and overlaps

Tallow exposes Jolt's rays and swept sphere, capsule and box queries to scripts through `Scene`. Queries run on the scene thread. Distances are world units; direction is normalized internally.

```csharp
if (Scene.SphereCastHit(Transform.Position, 0.5f, -Vector3.UnitY, 5f) is PhysicsHit hit)
    Log.Info($"Hit {hit.HitObject?.Name} after {hit.Distance} meters");

// Ignore the player's own rigidbody when probing the ground.
var body = GetComponent<Rigidbody>();
if (body.HasBody)
    Scene.SphereCastHit(Transform.Position, 0.25f, -Vector3.UnitY, 2f, uint.MaxValue, body.BodyId);

// Endpoints are hemisphere centers, not the outer tips of the capsule.
Scene.CapsuleCastHit(new Vector3(0, 0.5f, 0), new Vector3(0, 1.5f, 0), 0.5f, Vector3.UnitZ, 10f);

// Size means full width/height/depth; rotation determines box orientation.
Scene.BoxCastHit(Transform.Position, new Vector3(1, 2, 1), Quaternion.Euler(0, 45, 0), Vector3.UnitZ, 10f);
```

A `PhysicsHit` has `HitObject`, `BodyId`, `Point`, `Normal`, `Distance` and `PenetrationDepth`; a miss is null.
`Scene.RaycastHit(origin, direction, maxDistance)` gives the same for a ray, with the surface's normal where it hit.
Each cast also takes a layer mask. The contact point is on the target shape; the normal points outward from the target. Starting overlaps return zero travel and their penetration depth. Capsule casts with coincident endpoints act as sphere casts. Invalid sizes, non-finite input, zero directions and nonpositive cast distances return no hit. Empty worlds return no hit.

`Scene.OverlapSphere(center, radius)`, `OverlapCapsule(point1, point2, radius)` and `OverlapBox(center, size, orientation)` return the objects touching the shape, each once (in no particular order). They also take an optional layer mask and a body to ignore. `OverlapSphereContacts`, `OverlapCapsuleContacts` and `OverlapBoxContacts` take the same arguments and give every contact as a `PhysicsHit` instead: where it touches, the surface's normal, how deep it goes, and the part or triangle. A mesh or compound may give several for one object.

## Every hit, and what was hit

```csharp
// A bullet that goes through thin walls: every object along the ray, nearest first, each once.
foreach (PhysicsHit hit in Scene.RaycastAll(muzzle, aim, 200))
{
    Decals.Spawn(Scene, hit.Point, hit.Normal ?? -aim, $"Textures/hole_{hit.Surface}.png", 0.1f, 30);
    if (hit.Surface == "Metal") break;          // metal stops it
}

// A shotgun: twelve pellets in one call, each its closest hit or null.
RayQuery[] pellets = new RayQuery[12];
for (int i = 0; i < pellets.Length; i++)
    pellets[i] = new RayQuery(muzzle, Spread(aim, i), 60);
var hits = new PhysicsHit?[pellets.Length];
Scene.RaycastBatch(pellets, hits);
```

- `RaycastAll`, `SphereCastAll`, `CapsuleCastAll` and `BoxCastAll` give every object along the query, nearest first, each once (where the query first touches it). Debris is passed through, as with the closest-hit queries.
- `RaycastBatch(rays, results)` and `SphereCastBatch(spheres, results)` run many closest-hit queries in one call (pellets, an AI's sight lines, sensors), cheaper than one call each from C#.
- `hit.Surface` is what the object is made of: the **Surface** a collider names in the Inspector ("Metal", "Wood", "Glass"; empty when it names none), for footsteps, bullet holes and impact sounds.
- `hit.Part` says which part of a Compound Collider was hit (its boxes, then cylinders, then hulls, in the order added) and `hit.Triangle` which triangle of a Mesh Collider's mesh (its first index is 3 times it), so a game can tell a car's door from its roof or look up its own data per triangle. Both are -1 for other shapes.

After changing a collider's shape from code (a Mesh Collider's mesh edited or replaced, a box resized), `GameObject.RefreshColliders()` (or `MeshCollider.Refresh()`) builds its collision again, and its Rigidbody's body if it has one.

Engine (Beef) code has the same through `Scene.Physics`: `RaycastAll`, `SphereCastAll`, `CapsuleCastAll` and `BoxCastAll` into a list, `RaycastHit.normal`, `part` and `triangle` (and `ShapeCastHit.part` and `triangle`), `Collider.surface` and `Collider.SurfaceOf(gameObject)`, and `Collider.Refresh()`.

When only whether something is there matters, use `Scene.CheckSphere(center, radius)`, `CheckCapsule(point1, point2, radius)` or `CheckBox(center, size, orientation)`. They take the same optional layer mask and body to ignore, return a bool rather than a list, and can stop at the first accepted hit. Their advantage depends on query geometry and the number of contacts. The navigation baker uses them for each cell's clearance.

Query shapes and overlap buffers are reused, avoiding native shape allocation for each repeated query with the same dimensions. Changing dimensions replaces that kind's cached query shape. The query tree is optimized once after bodies are added, including for queries before the first simulation tick. Existing transforms still follow Tallow's normal physics synchronization behavior: stepping flushes transform edits into Jolt; shape queries do not scan all transforms on each call.

The wrappers use JoltC's shape collectors through `native/tallow_physics.cpp`. This changes the native static library; rebuild it and rebuild/reload project executables before calling the new API:

Tests cover closest contacts, direction normalization, maximum distance, ignored bodies, capsule orientation (any axis) and degeneracy, aligned capsules touching each face from outside, candidate skipping checked against exact geometry, rotated boxes, starting overlap, invalid inputs, empty worlds, overlap mappings, and buffer growth beyond 64 contacts.

Overlap contacts use analytic sphere–box flat-face/interior calculations and capsule–box calculations for a capsule along one of the box's axes (its middle inside the box, or reaching a face from outside, measured from the point of its segment nearest the box) where supported. Clearly separated sphere–box pairs are rejected by a distance bound. Tangent, edge/corner, oblique capsule and unsupported configurations retain Jolt's registered solver. These paths affect overlap queries; simulation and casts continue through their existing solvers. Filters, body IDs and compound subshape IDs are retained. `PhysicsWorld.useAnalyticOverlapContacts = false` selects the generic solver for diagnostics.

Jolt picks a query's candidate bodies by bounding box, so a sphere also gets the bodies off its diagonals. Sphere and capsule queries (overlaps and checks) skip any body whose bounds are farther from the sphere's centre, or the capsule's segment, than the radius before working out contacts. A body the query ignores is skipped before Jolt locks it. In the benchmark's grid of boxes this keeps a 0.75 m sphere to the 6 boxes it touches rather than 18.

Aligned box–box overlaps also use analytic contacts when both boxes share a flat contact patch. Their normals and surface points describe that patch; penetration depth follows the aligned geometry and may differ from Jolt's approximate GJK/EPA estimate. Near tangency, rounded edge/corner contacts and oblique orientations retain the generic solver. The diagnostic `useAnalyticOverlapContacts` switch covers this path too.

## Simulation capacity

Engine code (not game scripts) can configure native Jolt capacity before the world's first body or query creates it:

```beef
bool configured = scene.Physics.ConfigureCapacity(16384, 262144, 131072);
```

Arguments are maximum bodies, body pairs and contact constraints. Configuration returns false for nonpositive values or an already-created world. Defaults remain 16,384 / 65,536 / 16,384; increasing limits costs memory. `BodyCapacity`, `BodyPairCapacity` and `ContactCapacity` expose the configuration. Capacity does not grow automatically.

After stepping, `LastStepError` exposes Jolt's error mask: manifold-cache overflow = 1, body-pair-cache overflow = 2, contact-constraint overflow = 4. Each newly observed bit is logged. A nonzero mask means the simulation may have omitted contacts and should not be treated as a valid performance result. Body creation beyond the body pool returns the invalid ID without tracking a nonexistent body.
