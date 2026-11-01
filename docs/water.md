# Water

The **Water** component makes a lake, a pool, a river or the sea. It draws the surface with waves, floats Rigidbodies in it, lets characters swim, and shows a camera under the surface the world through the water. All of it works in multiplayer without any code.

**GameObject > Water** makes one:

| Menu item | What it makes |
|---|---|
| Water | A 40 x 40 m pond, 4 m deep, in the Realistic look |
| Water (Low Poly) | The same in the Low Poly look |
| Ocean | Water to the horizon (Endless), 40 m deep, with a long swell |
| Ocean (Low Poly) | The same in the Low Poly look |

The surface is at the object's height. Move the object up and down to raise or lower the water, or turn and scale it to fit a pond. The water fills **Size** (X by Z) and reaches **Depth** below the surface. Selecting the object shows the box it fills.

## Two looks

| | Realistic | Low Poly |
|---|---|---|
| Surface | Smooth rolling waves with fine ripples drifting over them | Flat facets, each shaded by how it faces the sun |
| Under the surface | Seen through, bent by the waves (Refraction) and fading into the water's colour with distance (Clarity) | Bands of colour from Shallow to Deep |
| Reflections | The sky, the reflection probe it is in, and the scene on the screen (Screen Reflections) | The sky, sharply, a facet at a time |
| Sun | A glint that follows the waves | A sparkle on the facets that mirror the sun |
| Foam | Soft, broken foam at the shore, round things in the water, and on sharp crests | Crisp bands that wash in and out |
| Caustics | Bright lines of light on what is under the water | Off |

**Look** chooses how it is drawn. Choosing a look from the GameObject menu also sets colours, grid spacing and waves that suit it. In code, `water.UseLook(.LowPoly)` does the same.

## Settings

| Setting | What it does |
|---|---|
| **Size**, **Depth**, **Endless** | The rectangle the water covers and how deep it is. Endless water reaches the horizon in every direction and follows the camera; Size is not used. |
| **Wave Height** | Trough to crest, in metres, where all the waves meet. 0 is still water. |
| **Wave Length** | The distance between the longest waves' crests. Shorter waves are mixed in. |
| **Wave Direction**, **Wave Spread** | The way the waves travel (degrees round from +X towards +Z), and how far the shorter ones turn away from it. A low spread is a swell, a high one is choppy. |
| **Choppiness** | Sharpens crests and widens troughs. |
| **Wave Speed**, **Wave Seed** | How fast the waves move (1 is how deep water waves of that length move), and another arrangement of them. |
| **Flow** | The current, in metres a second along X and Z. It moves the ripples and foam, carries floating things and swimmers, and makes a river. |
| **Shallow Color**, **Deep Color**, **Clarity** | The water's colours, and how far you can see through it in metres. |
| **Refraction**, **Roughness** | How much the waves bend what is under them, and how blurred the reflections are. |
| **Foam**, **Shore Foam**, **Foam Color** | How much foam there is, and how far from the shore it reaches. |
| **Caustics**, **Screen Reflections** | Light patterns under the water, and the scene mirrored in it. |
| **Grid Spacing** | Metres between the surface's points near the camera. Low Poly looks best with big facets. |
| **Underwater Color**, **Underwater Visibility** | What a camera under the surface sees through: its colour, and how far it can see. |
| **Float Rigidbodies**, **Buoyancy**, **Water Drag**, **Water Angular Drag** | How things float (see below). |

## Floating

Every Rigidbody in the water floats with Jolt's buoyancy. Each physics step, Jolt works out how much of the body's collider is under the surface and pushes it up by that much. The surface is the wave's height and slope under the body's middle, so waves rock things.

- **Buoyancy** is how strongly things float. At 1 a thing neither floats nor sinks. At 2 about half of it is under, and at 0.5 it sinks. The default, 1.6, floats a crate with about 62% under.
- **Water Drag** is how quickly the water slows things moving through it and brings them to its Flow, about that many times a second for something fully under. More settles bobbing sooner. **Water Angular Drag** is the same for turning.
- A **Floater** component gives one object its own Buoyancy and drag: a cork at 4, a stone at 0.5. A disabled Floater does not float at all. With **Float Rigidbodies** off, only objects with a Floater float.
- `water.IsFloating(body)` and `floater.InWater` tell whether a body was in the water at the last step.

Kinematic bodies, characters and objects outside the rectangle are left alone. Below the water's Depth there is no water to push up.

**Soft bodies and ropes** float too. Jelly, cloth and ropes float vertex by vertex: every point under the surface is pushed up by Buoyancy and slowed and carried by Water Drag and Flow, so a jelly bobs and squashes on the waves, cloth lies on the surface and drifts, and a rope floats along it. A Floater sets their own Buoyancy and drag in the same way (its Angular Drag is only for Rigidbodies). A shell floats on its object's Rigidbody. The surface is sampled on a grid of at most 8 x 8 points over each body and the vertices are worked out natively, so a 1,000-point cloth costs little more than a small one. `water.IsFloating(softBody)` and `water.IsFloating(rope)` tell whether any of it was in the water. Do not add a Rigidbody to a jelly or cloth to float it: the two would fight over the object.

## Swimming

A **Character Controller** swims in water deeper than its **Swim Depth** (1.2 m over the feet by default). `SimpleMove` then floats it with its head out of the water, moves it at **Swim Speed** (0.6 of the speed it is given), and lets the current carry it. A jump swims up, and out at an edge. In shallower water it wades on the bottom.

- `controller.Swim(velocity, Time.FixedDeltaTime)` swims in any direction, for diving towards where the player looks. With no up or down in it, the character floats back to the surface. Out of the water it walks like `SimpleMove`.
- `controller.IsSwimming` is for animations. It also works for other players' characters in a network session, which this machine does not move.
- **Can Swim** off makes a character walk on the bottom.

## Under the water

When the camera is in the water, the picture shows the water's **Underwater Color**, thickening with distance (**Underwater Visibility**) and darkening with depth, with caustics on what is under the surface. Each pixel is tested against the waves where it meets the camera's lens, so with the camera half in the water the picture is cut exactly at the waterline, with a thin dark edge along it. Seen from below, the surface shows the world above through a window overhead, and mirrors the water round it.

`renderView.CameraWater` is the water the camera was in during the last frame. Games use it for muffled sound or a breath meter.

## Game code

```beef
// Is this point under water, and how deep?
let water = Water.At(Scene, point);
if (water != null && water.Contains(point))
    Log.Info(scope $"{water.DepthOf(point)} m under");

// The surface over a point: its height, which way it faces and how fast the water there moves.
if (water != null && water.SurfaceAt(point, let height, let normal, let velocity))
    boat.Transform.Position = .(point.x, height, point.z);
```

`SurfaceAt` uses the waves' simulation clock, so the server and a client predicting the same tick get the same answer. `Water.ViewTime(scene)` is the clock the waves are drawn with.

## Multiplayer

Nothing needs sending for the waves. They are worked out from the settings and a clock every machine shares: the session's tick (the server's, on a client). Every player sees the same waves, and things float on the server as they are drawn everywhere. The water object gets a Network Identity when a session starts, and its settings are `[Sync]`. So the server's changes (a storm that raises Wave Height, a current turned on) and its water level (move the object for a flood or a draining lock) reach every client and players who join later. Floating Rigidbodies are shared like any other.

## Quality

Screen Reflections follow the **Reflection Probes** quality setting (`ScreenEffects.WaterReflections`). Off, water mirrors only the sky and probes, which the Low preset does.

## How it works

`Water.bf` sums four Gerstner waves made from the settings and the seed by a small generator that runs the same on every machine. Each wave's phase is worked out in double precision, so the waves stay smooth however long a session runs. `SurfaceAt` steps back from the waves' sideways swing to the point of still water that ends up over the one asked about, then adds up the height, slope and the water's own movement there.

The renderer (`RenderViewWater.bf`) works in this order:

1. After the solid scene and decals, it copies the picture.
2. It draws each visible water as a grid of still water moved by the same waves (`vs_water.sc`, `include/water.sh`). A lake's grid covers its rectangle. Endless water's grid follows the camera, with cells that grow towards the horizon.
3. The surface shader (`fs_water.sc`) reads the copy for what is under the surface, and the depth pass for how far it is through the water to it.
4. After the see-through objects, a camera in the water has the picture copied again. A full-screen pass (`fs_underwater.sc`) fogs every pixel whose part of the lens is under the surface.

Waves too short for a grid's spacing fade out of the drawing. On endless water, each wave also fades out at 30 of its own lengths away.

## Limits

- One water at a time is used for the underwater view: the highest one the camera is in.
- Things float by their middle's spot on the surface. A long ship is tilted by the slope under its middle, not by the waves along its length. Give a long ship several Floater objects, or a script that samples `SurfaceAt` at its ends.
- A lake's grid has at most 255 points along a side, so on a very large lake the points are further apart than Grid Spacing, and its shortest waves are not drawn (they still move things).
- Flow is one current for the whole water. Rivers that bend and run downhill are on the roadmap (flowing water).
- Objects do not make waves or ripples yet (water physics, on the roadmap).

## Tests