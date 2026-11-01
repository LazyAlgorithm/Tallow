# Physics layers, tags and world states

Three project-wide lists, set up in **Project Settings** and kept in `ProjectConfig.tconfig` at the root of the project's assets (`src/`), which ships with the game. A project without the file has one layer (Default), no tags and one world state.

## Physics layers

Name up to 32 layers. Each object is on one, chosen at the top of the Inspector (`gameObject.Layer` in code). The table under the layer names says which layers collide: untick a pair and bodies on those layers pass through each other, rigid bodies and character controllers alike. The table is read when a scene starts playing.

Ray and shape queries see every layer unless given a mask, one bit per layer:

```beef
let mask = ProjectConfig.Mask("Default", "Enemies");
if (Scene.Physics.Raycast(eye, forward, 100, out hit, mask)) ...
Scene.Physics.SphereCast(origin, 0.3f, direction, 20, out shapeHit, uint32.MaxValue, mask);
Scene.Physics.OverlapSphere(point, 2, hits, uint32.MaxValue, mask);
```

Changing `gameObject.Layer` while playing moves its bodies to the new layer at once. Debris (Rigidbody's Debris) is separate and still passes through everything that moves.

## Tags

Labels for objects, listed in Project Settings and given to objects in the Inspector (the **+** under Layer). Any number per object.

```beef
let player = Scene.FindWithTag("Player");            // the first active one
Scene.FindAllWithTag("Cover", list);                  // all of them, active or not
gameObject.AddTag("Searched"); gameObject.RemoveTag("Searched"); gameObject.HasTag("Enemy");
```

Tagged objects are kept in lists by tag, so finding them does not look at every object.

## World states

Versions of the same place that a game switches between: a past and a present, the real world and a dream, a powered and an unpowered station. List them in Project Settings. Every object is in all of them until the Inspector's **World States** ticks say otherwise; a parent left out of a state takes its children with it.

```beef
Scene.WorldState = ProjectConfig.WorldStateNamed("Echo");   // or Scene.SetWorldState("Echo")
Scene.WorldStateChanged.Add(new (from, to) => { ... });
```

Everything switches in that one call, in the same frame. An object outside the active state:

- **is not drawn** and casts no shadow, and its lights and particles are off;
- **is not heard**: its Audio Sources carry on playing silently, so they are in time when the state comes back;
- **does not collide** and is not seen by ray, shape and overlap queries;
- **is not walked on.** A Navigation Surface bakes the ground of one state. Give each state a surface of its own and
  put that surface's object in only that state; a surface in every state bakes whichever state the scene is in when
  it bakes. Agents with no surface set use the one in the active state, and find their way again when it changes.

`GameObject.InActiveWorld` says whether an object is in the active state, and `EffectiveWorldStates` which states it
is really in (its own, less any its parents are left out of).

In the editor, the toolbar's world state menu (shown once the project has more than one) picks the state the Scene and
Game views show, in edit mode and while playing. Hidden objects cannot be clicked in the Scene view.

## Saving

Scenes and prefabs keep each object's layer (`layer 3`), tags (`tags "Enemy" "Cover"`) and world states (`worlds FFFFFFFD`) only when they are set, so older scenes read exactly as before.

## Tests