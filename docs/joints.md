# Joints and debris

## Joints

A **Joint** (Add Component > Physics) holds two rigid bodies together at a point. They can turn about the point but cannot come apart: a link in a chain, a lamp on a cable, a limb on a body.

| Field | Meaning |
|---|---|
| Connected To | The other body. It needs a Rigidbody too. Make that one kinematic to hang things from a point that does not move. |
| Anchor | Where the two are joined, relative to this object. |
| Axis | The direction the swing limit is measured from, relative to this object. |
| Swing Limit | How far, in degrees, the bodies may swing away from the axis: a shoulder or a hip. 0 is a free ball joint. |

From code:

```beef
// Hang a weight from a post, joined at the post.
Joint.Connect(weight.GetComponent<Rigidbody>(), post.GetComponent<Rigidbody>(), post.Transform.Position, .Down);

// A forearm on an upper arm that bends no more than 70 degrees.
Joint.Connect(forearm, upperArm, elbowPosition, upperArm.Transform.Up * -1, 70);
```

`Joint.Connect` adds a Joint component to the first body and returns it. Destroying either object removes the joint; `IsConnected` says whether it is in place. After changing a joint's fields while playing, call `Rebuild()`.

A ragdoll is a handful of small bodies joined this way: give each limb a box collider and a Rigidbody, join them at the shoulders, elbows, hips and knees with swing limits, and let go.

## Hinges and suspensions

Two more joints are made from code, through `Scene.Physics`. They take body ids (`rigidbody.BodyId`), with the anchor and axes in world space, and return a handle.

| Call | Makes |
|---|---|
| `CreateHinge(bodyA, bodyB, anchor, axis, childAxis, childNormal)` | A hinge turning about `axis` through `anchor`; `childAxis` and `childNormal` fix how the second body sits on it. A door, a wheel, an arm. |
| `SetHingeMotor(hinge, speed, torque, angle, mode)` | Drives a hinge with up to `torque`: mode 0 off, 1 spins it at `speed` radians a second, 2 turns it to `angle` radians. |
| `HingeAngle(hinge)` | How far it has turned, in radians. |
| `CreateSuspension(bodyA, bodyB, anchor, childAnchor, axis, childAxis, childNormal, travel)` | A slider along `axis`, `travel` metres either way: a wheel's suspension. |
| `SetSuspensionSpring(joint, stiffness, damping)` | Its spring, in newtons a metre and newton-seconds a metre. |
| `SuspensionPosition(joint)` | How far along its travel it is. |
| `DestroyJoint(joint)` | Removes it; safe after one of its bodies has gone. |

```beef
// A wheel on an axle along Z, spun at 3 radians a second with up to 100 N·m.
let hinge = Scene.Physics.CreateHinge(car.BodyId, wheel.BodyId, wheel.Transform.Position, .(0, 0, 1), .(0, 0, 1), .(1, 0, 0));
Scene.Physics.SetHingeMotor(hinge, 3, 100);
```

Bodies joined by a hinge or a suspension do not collide with each other, so a wheel can sit inside its arch. Destroying either body removes the joint.

A **Compound Collider** can be built from cylinders and convex hulls as well as boxes: `AddCylinder(center, radius, halfHeight, rotation)` and `AddHull(center, points, rotation)` (the hull round four or more points), in the object's own space. Call `Rigidbody.RebuildBody` afterwards.

Joints are local to the machine they are on. In multiplayer the bodies are shared like any others, so create the same joints on every machine; joints saved in a scene or prefab already are.

## Debris

Turn **Debris** on in a Rigidbody for things that should lie about without getting in the way: corpses, dropped weapons, rubble. Debris rests on scenery and is drawn like anything else, but:

- characters and ordinary bodies pass straight through it, and so do other pieces of debris;
- rays, shape casts and overlaps ignore it, so it never blocks a shot or a line of sight.

`Scene.Physics.IsDebris(bodyId)` tells you whether a body is debris.

## Limits

- Only the ball joint is a component and is saved in scenes; hinges and suspensions are made from code each time, and only the hinge has a motor.
- A swing limit is held by the solver, not exactly: a hard knock can carry a limb a little past it before it is pulled back.
- Because nothing can query debris, picking it up or shooting it has to be done by distance from its object, not by ray.