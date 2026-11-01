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

Query shapes and overlap buffers are reused, avoiding native shape allocation for each repeated query with the same dimensions. Changing dimensions replaces that kind's cached query shape. The query tree is optimized once after bodies are added, including for queries before the first simulation tick. Existing transforms still follow Tallow's normal physics synchronization behavior: stepping flushes transform edits into Jolt; shape queries do not scan all transforms on each call.

The wrappers use JoltC's shape collectors through `native/tallow_physics.cpp`. This changes the native static library; rebuild it and rebuild/reload project executables before calling the new API:

```sh
cmake --build build/native --target tallow_native -j 4
BeefBuild -workspace=Tests/ShapeQueries -config=Debug -run
```

Tests cover closest contacts, direction normalization, maximum distance, ignored bodies, capsule orientation and degeneracy, rotated boxes, starting overlap, invalid inputs, empty worlds, overlap mappings, and buffer growth beyond 64 contacts.
