# Baked lighting: lightmaps and light probes

Real-time lights (docs/lighting.md) light what faces them. Light that bounces, such as a sunlit floor lighting the ceiling above it, a red wall tinting the floor beside it, or a room going darker away from its window, is too slow to work out every frame. **Baked lighting** works it out once in the editor and saves it:

- **Lightmaps.** Each object that never moves gets a picture of the light reaching every part of its surface: from the sky (darker in corners and under things), from lights marked **Baked Only**, and bounced off everything else.
- **Light probes.** A grid of points through the scene, each holding the light arriving from every direction, with closer ones inside **Light Probe Volumes**. Things that move (players, props, pickups) and anything without a lightmap take their ambient light from the probes round them, so they match the room they are in.

Real-time lights keep working as before: their direct light and shadows are still drawn live, and only their bounce is baked.

## Baking a scene

1. Tick **Baked Lighting** on the Mesh Renderers of things that never move: floors, walls, rocks, buildings. In the **Window > Lighting** window, **Tick Baked Lighting on Selected** ticks an object and everything under it.
2. Optionally, tick **Baked Only** on lights whose light should be fully baked (lamps, glowing windows). On baked surfaces they cost nothing at run time, and their shadows are baked in at lightmap detail.
3. Press **Bake** in the Lighting window. The editor keeps running while it bakes on the machine's spare cores, with a progress bar and **Cancel**. When it finishes, the scene points at its lightmaps and probes. **Save the scene** to keep them.

The results go beside the scene, in a folder named after it: `Scenes/Level1.tscene` bakes into `Scenes/Level1_Baked/` (`Lightmap-0.png`, `Lightmap-1.png`, ... and `Probes.tprobes`). Builds pack them like any other asset. Bake again after moving baked objects or changing lights. **Clear Baked Lighting** takes it away (the files stay).

**Show Baked Lighting** in the Lighting window (and `--no-baked-lighting` for a run) turns lightmaps and probes off, to compare.

## Settings

The settings are saved with the scene, so everyone baking it gets the same result.

| Setting | What it does |
|---|---|
| **Texels per Metre** | Lightmap detail: how many texels for each metre of surface. 8 suits rooms and buildings; 2 to 4 for big terrain-like floors; 16 or more for small, detailed props. |
| **Rays per Texel** | How many directions each texel looks in to gather light. More is smoother and slower. A smoothing pass removes most of the remaining speckle. |
| **Bounces** | How many times light bounces. 2 or 3 is usually enough; 0 is the sky and Baked Only lights alone. |
| **Light Probes**, **Probe Spacing** | Whether probes are baked, and how far apart they are (in metres) on a grid over the baked objects. Light Probe Volumes add closer probes where they are needed. |

## Light Probe Volumes

The scene's grid is even all over, so one spacing has to suit both open ground and the corner of a room. A **Light Probe Volume** (GameObject > Light Probe Volume) is a box with probes of its own, closer together: put them in rooms, doorways, under roofs and round lamps, and keep the scene's Probe Spacing wide. A thing whose middle is in a volume takes its light from the volume's probes, fading into the scene's grid towards the box's edges; where volumes overlap, the smallest wins. **Place Probes** in the Lighting window places them (and reflection probes) where light changes: see docs/probe-placement.md.

A small scene bakes in a second or two. A large one at high detail can take a minute or more.

## What is baked

| | On a baked surface (lightmap) | On anything else (probes) |
|---|---|---|
| Sky (the scene's ambient colours) | baked, with corners and covered places darker | baked |
| A Baked Only light's direct light | baked, with its shadows | drawn live |
| Other lights' direct light, and the sun's | drawn live, with live shadows | drawn live |
| All lights' bounced light, and glowing surfaces | baked | baked |

The sun (the directional light that casts shadows) is always drawn live, even when marked Baked Only; its bounce is baked. Surfaces with an emissive colour, and unlit ones, light the things round them.

The colour that surfaces bounce is their Color times their material's colour, their texture's average colour and their vertex colours.

Baked surfaces still mirror reflection probes and the sky (docs/reflections.md). **Ambient From Surroundings** applies only to surfaces with neither a lightmap nor probes.

## Lightmap coordinates

A lightmap needs a second set of texture coordinates in which no two triangles overlap. The engine makes them itself, the same way every time, so a game makes them again when it loads and they match what the editor baked:

- Triangles that touch and face within 60 degrees of each other are laid flat together as one chart, and the charts are packed into a square with a gap round each.
- An object that stretches its mesh unevenly (a cube scaled into a wall) gets a copy of the mesh laid out for that stretch, so that the broad faces get the texels rather than the thin edges. Objects stretched alike share a copy.
- A model whose file has its own second coordinates (glTF `TEXCOORD_1` on every part) keeps them.
- A model with several materials is laid out as one, all its parts together.

## In code

```beef
renderer.bakedLighting = true;          // take part in the next bake
light.bakedOnly = true;                 // its direct light goes into lightmaps

// Baking from code, as the editor does (the editor's Lighting window is the usual way):
let settings = scope BakeSettings();
settings.FromScene(scene.Environment);
let baker = scope LightBaker(scene, settings);   // on the main thread
baker.Run();                                     // any thread; baker.Progress, baker.Cancel
baker.Apply(scene, LightBaker.FolderFor(scene, .. scope .()), report);
```

`RenderView.UseBakedLighting = false` turns baked lighting off everywhere. `LightProbes.Get(path).Sample(position, normal)` reads probes on the CPU (as a draw whose middle is at that position would).

## How it works

`LightBaker` (`Engine/src/Lighting/LightBaker.bf`) copies the baked renderers' triangles into the world, with their colours, and builds a bounding volume hierarchy over them in the native library (`native/tallow_bake.cpp`), which traces the rays. Each object gets a square of the lightmap sized for Texels per Metre, and each texel a point and a normal on the surface. Then:

1. **Direct light** at each texel from every light, with a shadow ray to each.
2. **Gathering.** Each texel sends Rays per Texel rays over its hemisphere (stratified and cosine-weighted). A ray that leaves the scene brings the sky's light. One that hits something remembers which texel it hit. One that hits the back of a face marks the texel as inside something (under a wall standing on the floor); such texels are filled in from their neighbours later.
3. **Bounces.** Each pass works out the light leaving every texel (its colour times all the light on it, plus its glow) and gathers it again through the remembered hits, so every bounce after the first costs only lookups.
4. **Smoothing.** An edge-aware blur of the gathered light, only between texels of the same object that face the same way and lie close together in the world.
5. **Lightmaps.** Baked Only lights plus the gathered light. Texels round each chart are filled outward so filtering never pulls in black, and the result is stored as RGBM PNGs (colour × alpha × 8).
6. **Probes.** Each probe sends rays all round, and what they see is kept as a constant plus a direction for each of red, green and blue (spherical harmonics to the first band). Probes inside walls take their neighbours' light. The scene's grid and each Light Probe Volume's are saved as text (`.tprobes`: a `grid` section each, the scene's first), uploaded together as one 3D texture (each grid a block of x by y by three z: red, green, blue), and blended per pixel in `include/lighting.sh`: a draw's volume, picked by its middle, fading into the scene's grid.

Light is kept in the units of the shader's ambient term. The sky sends `ground + (sky − ground) × (0.5 + 0.75 × d.y)` from direction d, which lights an open surface exactly as the scene's two ambient colours do, so baked and unbaked surfaces match in the open.

## Limits

- Things that move, voxel terrain, terrain, foliage, particles and see-through objects are not baked and block no light in the bake. They are lit by the probes.
- A lower level of detail (docs/lod.md) of a baked object is lit by the probes, not its lightmap.
- Specular highlights from baked lights are not baked (only their diffuse light).
- Lightmaps are 8-bit RGBM, up to 8 times the brightest a white surface gets from light alone.
- Probes are grids: a thin wall between two rooms can let one room's light into the other's probes, so keep the probes (the scene's Probe Spacing, or a Light Probe Volume's Spacing) closer than the walls are apart.

## Tests