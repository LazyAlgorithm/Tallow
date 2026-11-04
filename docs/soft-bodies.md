# Soft bodies

A **Soft Body** (Add Component > Physics) makes an object's Mesh Renderer soft. Its mesh is simulated, vertex by vertex, as one of three kinds:

- **Cloth**: a sheet that hangs, folds and blows (flags, capes, curtains, sails, tablecloths).
- **Jelly**: a closed shape that squashes and springs back (jelly, rubber balls, cushions, soft tyres).
- **Shell**: a body that keeps its shape on its object and dents where it is hit, and stays dented (car bodies, crates, metal panels). See [Dents](#dents).

Jolt steps soft bodies on the job threads with the rest of the physics.

Soft bodies fall, fold over and rest on colliders, and they push rigidbodies and are pushed by them: a crate dropped on a jelly sinks into it and is held up. Characters walk through cloth and push it aside. Their sweep ignores soft bodies, and their inner body pushes them. Soft bodies also meet each other: cloth drapes over a jelly, and one jelly rests on another.

| Field | Meaning |
|---|---|
| Kind | Cloth or Jelly. |
| Mass | The whole body's weight in kilograms, shared by the vertices that are not pinned. |
| Stiffness | How hard it resists stretching: 1 barely stretches, 0 like elastic. |
| Bend Stiffness | How hard it resists bending: 0 folds freely (silk), 1 holds its shape (leather, rubber). |
| Pressure | Jelly: how hard the air inside pushes out, in pascals, whatever its size. 0 keeps its shape by its edges alone, 10 (the default) a jelly cube, 50 a little puffed up, 200 and more blows it up into a ball (a rubber ball: 300). |
| Damping | How fast it loses speed, like moving through thick air. |
| Wobble Damping | Jelly: how fast its wobbling dies away, without slowing it as a whole. 0 wobbles on, 10 settles at once. |
| Dent Depth | Shell: how far one impact can push the surface in, in metres. |
| Spring Back | Shell, From Surface: how far the surface springs back from, in metres (default 0.03). Pushed in further, it stays dented. |
| Dent Speed | Shell: how fast something must hit it to dent it, in metres a second (default 3, about 11 km/h). |
| Dent Mode | Shell: From Impacts (its object's collider takes the hits) or From Surface (the shell is pushed in itself). See Dents. |
| Friction, Gravity Scale | As on a Rigidbody. |
| Bounciness | How much it bounces when it lands, as on a Rigidbody: it leaves the ground at this share of the speed it hit at. 0 lands with a squash and a wobble but no hop, 0.5 bounces back about a quarter of the height it fell, 1 bounces back nearly as high. A jelly bounces as a whole, once it has stopped squashing in, so it keeps its wobble. Cloth bounces point by point where it touches. In a Wind Zone, a light jelly also meets air drag, so it falls (and bounces) slower. |
| Thickness | How far from its surface it keeps other things, in metres. |
| Wind Drag | How much Wind Zones push it (0 not at all; cloth and jelly, not shells). Wind blows on each face by how squarely it faces the wind, drags along faces it slides past, and is gusty from place to place across the cloth (more with the Wind Zone's Gusts), so a flag streams out and flaps. |
| Iterations | Solver passes each step: more is stiffer and costs more. |
| Pins | The vertices held to the object, by number (`0-12 40 41`). Painted in the editor. |
| Stiffness Map | Where it is softer than Stiffness says, by vertex (`12=0.5 13=0.25`). Painted in the editor. |

The mesh is simulated with its seams joined. A mesh splits a vertex where its texture or shading has a seam, and the simulation must not tear there. Vertex numbers in Pins and Stiffness Map count the joined vertices. The renderer draws a copy of the mesh that follows the simulation, with its normals and bounds updated every frame.

A jelly cube with the defaults keeps its shape, squashes a little when it lands, hops once at most and settles. For a firmer one raise Bend Stiffness; for a wobblier one lower Wobble Damping. A ball needs its air: a low-poly sphere with little pressure sags.

## Dents

A **Shell** holds every vertex on its place on its object, so it rides along with the object's Rigidbody (on the same object or a parent) and ignores that body's own collider. Where it is hit hard enough, it dents and stays dented. **Dent Mode** picks what dents it:

- **From Impacts** (the default): the object's collider takes every hit, so players, props and walls stop at the surface and nothing pushes into the shell. A hit on the collider at **Dent Speed** or faster, by something static or dynamic, presses the shell in around where it landed: deeper the faster it was (the full **Dent Depth** at four times Dent Speed) and the heavier what hit it (fully with a tenth of the car's mass or more, or a wall), spreading wider the faster it was. Characters, moving platforms and light things (a ball) do not dent it. Repeated hits dent further, up to three times Dent Depth.
- **From Surface**: the shell meets things itself and is pushed in where it touches them, so it can fold round a post. Its collider sits a little inside the mesh (by about Dent Depth), and things can press into the shell that far before the collider stops them. A push at Dent Speed or faster, in further than **Spring Back**, stays as a dent; anything less springs back.

Set it up like this:

1. The car (or crate) has its Rigidbody and a collider (a Rigidbody only moves with a collider: a shell adds a Convex Collider round the mesh to an object without one, and a Rigidbody of the Soft Body's Mass to one without that, so it falls and hits things): the shape of the mesh for From Impacts; a little inside it at the front, back and sides for From Surface. Wheels or the collider's underside hold a car up.
2. Add a Soft Body, Kind Shell. The mesh needs enough vertices to dent: a few hundred for a car body.

With a **Convex Collider** on the shell's object (not a Mesh Collider: those only work on things that do not move), the collider follows the dents: a fifth of a second after the denting stops, it is wrapped round the dented shape again, so a crushed front or corner is where things stop. Being convex, it follows dents that change the outline (a flattened front, a crumpled corner); a dent in the middle of a door is still met at the door's original surface. A Box Collider stays as it is.

The Sandbox's player has a **Ball Launcher**: F shoots a 10 kg ball at 30 m/s where the screen's middle points, enough to dent a 100 kg shell cube about 13 cm.

If it dents too easily, raise **Dent Speed** (6 or so for a sturdy truck: only real crashes dent it); lower **Dent Depth** for shallower dents.

From code:

```beef
let shell = car.GetComponent<SoftBody>();
shell.DeepestDent();             // metres, for damage
let dents = scope List<Vector3>();
shell.GetDents(dents);           // save or send these
shell.SetDents(dents);           // and put them back
shell.Repair();                  // good as new
```

Dents are each machine's own, as soft bodies are. To show the same dents everywhere, send `GetDents` from the server when they change (after a crash) and `SetDents` them on clients.

## Flags

A flag needs no scripting:

1. Make a plane (a builtin plane, or a modelled one with a few rows of faces, 8 × 8 is plenty) on a pole, and give its Mesh Renderer **Back Face Culling** off so both sides show.
2. Add a **Soft Body** (Cloth), and **Paint Pins** along the side at the pole.
3. Add a **Wind Zone** (Global) to the scene, turned the way the wind blows. Strength 1 is a breeze, 3 a strong wind; Gusts sets how much it comes and goes.

It streams out from the pole and flaps. **Wind Drag** on the Soft Body sets how much the wind moves it.

## Pins

Pinned vertices stay where they are on the object and move with it. Moving, turning or animating the object carries them, and the rest of the cloth swings after them. A cape is cloth pinned along its top edge on an object that is a child of the character's chest bone. A flag is pinned along one side to a pole, and a curtain along its top to a rail.

A soft body with no pins is free. It moves its object: the object's position follows the middle of the body. If a script moves the object, the body goes with it.

## Painting pins and stiffness

Select the object. Under the Soft Body in the Inspector are **Paint Pins** and **Paint Stiffness**. With one picked, the mesh's vertices show in the Scene view (pinned ones orange; with Paint Stiffness, soft ones red), and a brush follows the mouse over the mesh.

- **Paint Pins**: drag to pin vertices; Shift+drag unpins them.
- **Paint Stiffness**: drag to give vertices the Stiffness value on the brush; Shift+drag sets them back to the body's own.

Brush Size is a share of the mesh's size. A stroke is one step of undo. **Clear Pins** and **Clear Stiffness** start again.

## From code

```beef
let curtain = rail.AddComponent<SoftBody>();
curtain.pins.Set("0-10");        // the top row of an 11 x 11 sheet
curtain.windDrag = 2;

// After changing fields while playing:
curtain.Rebuild();

// Where its vertices are now, in the world:
for (let p in curtain.Positions) { ... }

// Put them somewhere (as many positions as SimulatedVertexCount):
curtain.SetPositions(saved);

// What it touched since this was last asked (physics body ids):
let touched = scope List<uint32>();
jelly.TouchingBodies(touched);
```

## Ropes

The **Rope** component is a rope, cable or chain-like line: a chain of short stiff lengths (Jolt's Cosserat rods) that keep their length and resist bending and twisting where they meet. It sags, swings, drapes over things and is pushed about by what moves through it, and draws itself as a tube with the object's Mesh Renderer (added if there is none).

Each end is tied on its own:

- **Start Attached To**: what the first end is on. Empty: this object holds it, or nothing does with **Hold Start** off.
- **End Attached To**: what the other end is on. Empty: it hangs free.
- **Start Offset** / **End Offset**: where on each object, relative to it. Left at zero, the rope ties onto the object's surface where it faces along the rope (from its Box Collider, or its mesh): the top of a crate hanging from it, the front of a car being towed.

Any object will do: a player, a vehicle, a bone's child, a crate, an empty. An end follows its object wherever it goes. When either end is on a dynamic Rigidbody, the rope also pulls on it: the ends can get no further apart than **Length** (and it goes slack when they come closer), so it holds a crate up, swings it, and is pulled tight by it. A rope between two objects without Rigidbodies (or kinematic ones) just hangs between them.

| Field | Meaning |
| --- | --- |
| Length | How long it is, in metres. |
| Thickness | How thick it is (it keeps this far from other things, and is drawn this thick). |
| Mass | The whole rope's weight. |
| Segments | How many lengths it is made of; 0 is about one per 10 cm. |
| Bend Stiffness | 0 a limp rope, 1 a stiff cable. |
| Damping, Friction | As on a Rigidbody. |
| Knot Stiffness | How firmly a body on an end is held in line with the rope, as a knot does: tipped back and kept from spinning round. 0 lets it turn freely about where it is tied. Only acts while the rope pulls. |
| Wraps Around | The pull goes round what the rope lies over instead of straight between the ends: a rope over a beam or branch works as a pulley. |
| Break Force | Pulled harder than this (newtons), it snaps in two, each half staying on its end. 0 never. |
| Wind Drag | How much Wind Zones push it. |
| Iterations | Solver passes each step; more is firmer. |

Towing and lifting from code:

```beef
// A helicopter picks up a crate: the rope is tied under one and on top of the other.
let sling = Rope.Attach(helicopter, crate, .(0, -0.5f, 0), .(0, 0.4f, 0), 6);
// A truck tows a car, with as much rope as is between them now (plus a little slack).
let tow = Rope.Attach(truck, car, .(0, 0.4f, -2.2f), .(0, 0.4f, 2.1f));

if (sling.IsTaut && sling.Pull > 5000)
	sling.Release();        // drop it: the far end lets go and hangs free

// A rope laid over a beam (it is as long as the path), pulling round it.
let hoist = Rope.Attach(counterweight, cargo);
hoist.wrapsAround = true;
hoist.LayAlong(scope Vector3[](counterweight.Transform.Position, beamLeft, beamRight, cargo.Transform.Position));

let other = sling.Snap();       // snap it now (Break Force does this by itself); other is the half on the crate

tow.AttachEnd(trailer.Transform, .(0, 0.5f, 2));   // tie the far end to something else
tow.AttachStart(player.Transform);                  // or the near end
Scene.Active.Destroy(tow.GameObject);               // or let go of both
```

`Points` has where each point of the rope is now, from start to end. When an object an end is tied to is destroyed, that end lets go.

The pull acts along the straight line between the two ends, unless **Wraps Around** is on: then it runs through the first and last places where the rope presses on something (the rope on top of a beam, not one lying along the floor), so lifting one end lowers the other. What it wraps round must hold still (static, or kinematic); a body it lies over is pressed by the rope but not pulled by the pulley. In multiplayer ropes are shared without code: see Networking below.

## Stiffness and fine meshes

## In water

Jelly, cloth and ropes float in Water vertex by vertex: each point under the surface is pushed up by the water's Buoyancy and slowed and carried by its drag and Flow, so a jelly bobs and squashes on the waves, cloth lies on the surface and drifts, and a rope floats along it. A **Floater** on the object sets its own Buoyancy and drag (0.5 sinks it) or, disabled, stops it floating. A shell floats on its object's Rigidbody, like any Rigidbody. The surface is sampled on a small grid over each body (at most 8 by 8), so the cost hardly grows with the vertex count: well under a millisecond a step for a scene of several floating soft bodies in a Debug build. See [Water](water.md).

## Networking

Everything here works in a network session without code. Each machine simulates its own soft bodies and ropes, and what has to agree comes from the server:

| What | In a session |
|---|---|
| Pinned cloth (flags, capes) | Follows its object, so when the object is networked (a player, a ship, a door) it looks the same everywhere without sending anything about it. |
| A free soft body (a jelly, loose cloth) | Its object gets a Network Identity when the session starts, like a Rigidbody's. Clients simulate it too, and each step it is drawn towards where the server has the object (or jumps there when more than 2 m away). Squashing and wobbling are each machine's own, so they can differ in detail. |
| A shell's dents | Made on the server: a crash there dents the shell on every machine once it settles (a fifth of a second), a quarter of a millimetre apart at most. A client's shell does not dent by itself, so a hit only one player sees leaves no dent. `SetDents` and `Repair` on the server reach every machine; on a client they go to the server, for an object that player controls. Players who join later get the dents as they are. |
| Ropes | `Rope.Attach`, `AttachStart`, `AttachEnd` (and `Release`), `LayAlong` and `Snap` on the server happen on every machine, and Break Force snaps a rope when the server's pulls past it. On a client they go to the server, for a rope, or an object it is tied to, that player controls (`Attach` and `Snap` return null there: the server's rope arrives). Players who join later get the ropes as they are. Tie ropes to networked objects (a Rigidbody, a player): the rope follows them on every machine. |

## Limits

- Cloth does not tear.
- A wrapped rope's pull is worked out from where it touches each step. Something swung hard into what it wraps round can knock it off, as with a real rope.
- Pins hold vertices to their object, not to a bone directly. Put the soft body on an object parented to the bone.
- Soft bodies meet each other through a proxy: a closed body (jelly, shell) near another soft body gets a copy of its surface, rebuilt each step, that other soft bodies collide with (rays, shape queries, rigid bodies and characters ignore it). Of two closed bodies, only one is pushed by the other: the one underneath does not feel the weight of one resting on it. Cloth does not meet cloth.
- A sphere with poles (many thin faces meeting at a point) shivers at very high pressures (300 and more); more Iterations calm it, or use an evenly meshed sphere.
- A soft body is one mesh: a Mesh Renderer's own mesh, a builtin or a model's. Big meshes cost more. Keep cloth to a few hundred vertices, and use a low-poly copy for something that only needs to wobble.
- A soft body at rest goes to sleep like a Rigidbody (`IsSleeping`), and is woken when something touches it or, for a shell, when its object moves.
