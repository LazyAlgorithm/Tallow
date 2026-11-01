# Decals

A **decal** presses a picture onto whatever surfaces lie inside a box: posters and signs on walls, road markings, cracks, stains, scorch marks, bullet holes. The picture follows the shape of what it lands on (a step, a curved rock, a character standing in it), it is lit and shadowed like the surface under it, and it never needs the surface's model or UVs. There are two kinds:

- the **Decal** component, placed in the editor and saved with the scene;
- **spawned decals** (`Decals.Spawn`), made from code in large numbers and forgotten after a while: bullet holes, footprints, blood.

## Placing one in the editor

**GameObject > Decal** makes one where the Scene view is looking, stuck flat onto the surface in the middle of the view. Or add a **Decal** component to any object (it is under *Rendering*).

The Scene view draws the decal's box in orange, with a line along the way the picture is pressed (the object's blue, forward axis) and a line towards the picture's top. Move, turn and scale it with the usual tools; click inside its box in the Scene view to select it.

**Stick to Surface**, under the component's fields, moves the decal onto the surface its blue axis points at (or, with nothing there, the surface below it) and lays it flat there, keeping the picture the same way up as nearly as it can.

| Setting | |
|---|---|
| **Texture** | The picture. Its alpha decides where the decal shows, so use a PNG with a transparent background. Without one the decal is a solid rectangle in its colour. |
| **Color** | Multiplies the picture. Its alpha fades the whole decal. |
| **Size** | The box's width (X), height (Y) and depth (Z, along the projection), in metres, before the object's own scale. The depth is how far in front of and behind the decal's centre a surface may be and still get the picture: keep it small on walls so the picture does not appear on things standing in front of them. The picture softens out over the last tenth of the depth at each end. |
| **Opacity** | How strongly it covers what is under it. |
| **Metallic**, **Roughness** | The decal's own surface, lit like a material's. A wet patch is smooth (low roughness), a chalk mark rough. |
| **Angle Limit** | Surfaces turned more than this many degrees away from the decal do not get it (it fades out over the last 15 degrees). With the default of 70, a decal on a floor does not smear down the sides of a box standing on the floor. Raise it to wrap a decal round corners. |
| **Unlit** | Draws the picture as it is, ignoring light: glowing signs, holograms, markers. |
| **Order** | Where decals overlap, those with a higher order are drawn over those with a lower one. |

A decal is an ordinary object: parent it to a moving object (a door, a vehicle) and it moves with it, turn it off to hide it, put it in a prefab with the object it decorates.

## Spawning decals from code

```beef
// A bullet hole 12 cm across where a shot hit, gone after 20 seconds, turned at random.
Decals.Spawn(Scene, hit.point, hitNormal, "Textures/bullet_hole.png", 0.12f, 20, .White, (float)mRandom.NextDouble() * 360);

// A box of your own: any size and turn, pressed along its Z axis.
Decals.Spawn(Scene, Matrix4.TRS(position, rotation, .(2, 1, 0.5f)), "Textures/skid.png", 0, .(1, 1, 1, 0.8f));

Decals.Clear(Scene);      // remove them all (also done when the scene is cleared)
Decals.MaxSpawned = 512;  // how many a scene keeps; the oldest makes way for new ones (256 by default)
```

`Spawn(scene, position, normal, texture, size, lifetime, color, spin)` makes a decal `size` wide and high, pressed into the surface whose outward facing is `normal`, `size / 2` deep. With a `lifetime` (seconds) it fades over the last second and is then removed; with none it stays until newer decals push it out. `spin` turns the picture about the normal, so repeated marks do not all line up. Spawned decals are not objects: they cost no more than their draw, stay where they were made, and are drawn over the placed Decal components.

## Networking

A Decal component is part of its object: it is in the scene file every machine loads, and objects made while playing carry it like any other component. Change its fields on every machine (or from a synced field) as you would a light's.

Spawned decals are not sent over the network: they are effects, like sounds and particles. Make them on every machine, from code that runs on each, typically where the game already learns that something happened: the handler of the message that says a shot hit, or the code that plays the impact sound. A dedicated server, which draws nothing, can skip them.

## How it is drawn

After the solid scene is drawn, the renderer draws a depth pass (each pixel's distance from the camera; the same one ambient occlusion, depth of field and motion blur use, drawn once a frame for all of them). Each visible decal's box is then drawn over the picture: for every pixel the box covers, the shader finds the surface behind it from the depth pass, keeps it only if it lies inside the box, works out its facing from how its position changes between neighbouring pixels, and lays the picture over it with the scene's lighting, shadows and fog (`Engine/shaders/fs_decal.sc`, sharing `Engine/shaders/include/lighting.sh` with the mesh shader). Decals are drawn before see-through things and before the first-person viewmodel, so neither of them gets the picture.

Limits:

- Decals land on everything solid in their box, including moving objects and characters that pass through it. Keep boxes shallow, or use the angle limit, where that matters.
- The surface's facing comes from the depth pass, so it is flat per triangle: a decal on a normal-mapped surface does not follow the bumps, and lightmaps are not used for its lighting (it gets the scene's ambient light instead of the baked light).
- See-through objects, the sky and the viewmodel never get decals.
- Every decal is one draw. A few hundred on screen are fine; `RenderView.VisibleDecals` says how many the last frame drew.

## Tests