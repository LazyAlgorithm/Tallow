# Shape casts and overlaps

Tallow now exposes Jolt's swept sphere, capsule and box queries through `Scene.Physics`. Queries run on the scene thread. Distances are world units; direction is normalized internally.

```beef
ShapeCastHit hit;
if (Scene.Physics.SphereCast(Transform.Position, 0.5f, Vector3.Down, 5, out hit))
    Log.Info(scope $"Hit {hit.gameObject.Name} after {hit.distance} meters");

// Ignore the player's own rigidbody when probing the ground.
let body = GetComponent<Rigidbody>();
if (body != null && body.HasBody)
    Scene.Physics.SphereCast(Transform.Position, 0.25f, .Down, 2, out hit, body.BodyId);

// Endpoints are hemisphere centers, not the outer tips of the capsule.
Scene.Physics.CapsuleCast(.(0, 0.5f, 0), .(0, 1.5f, 0), 0.5f, .Forward, 10, out hit);

// Size means full width/height/depth; rotation determines box orientation.
Scene.Physics.BoxCast(Transform.Position, .(1, 2, 1), Quaternion.Euler(0, 45, 0), .Forward, 10, out hit);
```

`ShapeCastHit` includes gameObject, bodyId, point, normal, distance and penetrationDepth. The contact point is on the target shape; the normal points outward from the target. Starting overlaps return zero travel and their penetration depth. Capsule casts with coincident endpoints act as sphere casts. Invalid sizes, non-finite input, zero directions and nonpositive cast distances return no hit. Empty worlds return no hit.

`OverlapSphere(origin, radius, hits)`, `OverlapCapsule(point1, point2, radius, hits)` and `OverlapBox(origin, size, orientation, hits)` accept `List<ShapeCastHit>`, clear it and return the number of contacts. They also accept optional `ignoreBody`. A mesh or compound may report multiple contacts for one object. These contacts are not guaranteed to be sorted or unique by body.

When only whether something is there matters, use `CheckSphere(origin, radius)`, `CheckCapsule(point1, point2, radius)` or `CheckBox(origin, size, orientation)` (as Unity's `Physics.CheckSphere`). They take the same optional `ignoreBody` and `layerMask`, return a bool rather than a contact list, and can stop at the first accepted hit. Their advantage depends on query geometry and the number of contacts. The navigation baker uses them for each cell's clearance.

Query shapes and overlap buffers are reused, avoiding native shape allocation for each repeated query with the same dimensions. Changing dimensions replaces that kind's cached query shape. The query tree is optimized once after bodies are added, including for queries before the first simulation tick. Existing transforms still follow Tallow's normal physics synchronization behavior: stepping flushes transform edits into Jolt; shape queries do not scan all transforms on each call.

The wrappers use JoltC's shape collectors through `native/tallow_physics.cpp`. This changes the native static library; rebuild it and rebuild/reload project executables before calling the new API:

```sh
cmake --build build/native --target tallow_native -j 4
BeefBuild -workspace=Tests/ShapeQueries -config=Debug -run
```

Tests cover closest contacts, direction normalization, maximum distance, ignored bodies, capsule orientation (any axis) and degeneracy, aligned capsules touching each face from outside, candidate skipping checked against exact geometry, rotated boxes, starting overlap, invalid inputs, empty worlds, overlap mappings, and buffer growth beyond 64 contacts.

Overlap contacts use analytic sphere–box flat-face/interior calculations and capsule–box calculations for a capsule along one of the box's axes (its middle inside the box, or reaching a face from outside, measured from the point of its segment nearest the box) where supported. Clearly separated sphere–box pairs are rejected by a distance bound. Tangent, edge/corner, oblique capsule and unsupported configurations retain Jolt's registered solver. These paths affect overlap queries; simulation and casts continue through their existing solvers. Filters, body IDs and compound subshape IDs are retained. `PhysicsWorld.useAnalyticOverlapContacts = false` selects the generic solver for diagnostics.

Jolt picks a query's candidate bodies by bounding box, so a sphere also gets the bodies off its diagonals. Sphere and capsule queries (overlaps and checks) skip any body whose bounds are farther from the sphere's centre, or the capsule's segment, than the radius before working out contacts. A body the query ignores is skipped before Jolt locks it. In the benchmark's grid of boxes this keeps a 0.75 m sphere to the 6 boxes it touches rather than 18.

Aligned box–box overlaps also use analytic contacts when both boxes share a flat contact patch. Their normals and surface points describe that patch; penetration depth follows the aligned geometry and may differ from Jolt's approximate GJK/EPA estimate. Near tangency, rounded edge/corner contacts and oblique orientations retain the generic solver. The diagnostic `useAnalyticOverlapContacts` switch covers this path too.

## Simulation capacity

Configure native Jolt capacity before the world's first body or query creates it:

```beef
bool configured = scene.Physics.ConfigureCapacity(16384, 262144, 131072);
```

Arguments are maximum bodies, body pairs and contact constraints. Configuration returns false for nonpositive values or an already-created world. Defaults remain 16,384 / 65,536 / 16,384; increasing limits costs memory. `BodyCapacity`, `BodyPairCapacity` and `ContactCapacity` expose the configuration. Capacity does not grow automatically.

After stepping, `LastStepError` exposes Jolt's error mask: manifold-cache overflow = 1, body-pair-cache overflow = 2, contact-constraint overflow = 4. Each newly observed bit is logged. A nonzero mask means the simulation may have omitted contacts and should not be treated as a valid performance result. Body creation beyond the body pool returns the invalid ID without tracking a nonexistent body.
