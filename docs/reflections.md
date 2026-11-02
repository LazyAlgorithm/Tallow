# Reflections: image-based lighting and reflection probes

Shiny surfaces mirror what is around them. Every scene has a **sky cube**: the sky drawn into a cube map, with blurrier copies down its mip levels for rougher surfaces. **Reflection probes** capture what can be seen from a point (a room, a hall, a cave) into a cube of their own, which the surfaces in their box mirror instead. A smooth metal shows a sharp picture of its surroundings, a rough one a soft blur, and a polished floor the walls beside it, brighter at a grazing angle.

Nothing needs setting up: outdoors, the sky is mirrored as it is. Indoors, add a probe to each room so that floors and metal mirror the room, not the sky. **Place Probes** in Window > Lighting does that for you: a probe boxed to each room with anything shiny in it, and more by doorways, shiny floors and on open ground (docs/probe-placement.md).

## Reflection probes

**GameObject > Reflection Probe** adds one at eye height. Size its box to the room (**Size**, in metres; it scales with the object but does not turn with it, so keep rooms lined up with the world's axes or use a few boxes).

| Setting | What it does |
|---|---|
| **Size** | The box it covers. |
| **Capture Offset** | Where it sees from, from the object (keep it out of the furniture: what it sees from inside a table is the table). |
| **Blend Distance** | How far outside the box its reflections fade into the sky's or the next probe's. Make the box the size of the room: things just outside it, and walls standing on its edge, still get it. |
| **Box Projection** | Lines reflections up with the box's walls, so they sit right wherever a surface is in the room. On for rooms, off for open places. |
| **Intensity** | Multiplies what it reflects. |
| **Importance** | Where boxes overlap the more important wins, then the smaller box (a cupboard's probe inside a room's). A thing takes a probe whose box holds its middle before one it only reaches into. |
| **Resolution** | The cube's size, 32 to 512 (0: the quality setting's, 128 at High). |
| **Refresh Interval** | While playing, captures again every this many seconds (0: never by itself). For a changing time of day or moving things; each capture draws the scene six times. |

A probe captures when it is first drawn, a few frames after the scene starts: six frames drawing its faces (one each, at its size) and one a level filtering them. In the editor it captures again by itself when it is moved or changed; **Capture Now** in its inspector (or `probe.Capture()` from code) captures it again after the room changed. Each draw uses one probe whose box it reaches (by its bounds), preferring one whose light reaches its middle, faded in for each pixel.

## The sky cube

Made again when the sky's colours or the sun change, from the same gradient as the sky itself, without the sun's disc (the sun's highlight comes from the sun as a light). It is 64 by 64; a frame to draw and one per level to filter.

## Scene settings

Under **Lighting** in the Scene Settings:

- **Reflections** (`reflectionIntensity`): how strongly surfaces mirror the sky and the probes, 1 as they are.
- **Ambient From Surroundings** (`ambientFromSurroundings`): ambient light from the cubes' blurriest levels instead of the Ambient Sky and Ground colours: the sky's light outdoors, and inside a probe's box the room's own light, coloured by its walls (image-based lighting). Ambient Intensity still scales it. Off by default, so scenes lit by their ambient colours stay as they were. Lightmapped surfaces keep their lightmaps.

## Quality

| Setting | Low | Medium | High | Ultra |
|---|---|---|---|---|
| **Reflection Probes** (`reflectionProbes`) | off (the sky only) | on | on | on |
| **Reflection Size** (`reflectionSize`) | 64 | 64 | 128 | 256 |

`--no-reflections` turns reflection cubes off altogether: surfaces mirror the ambient colours as they did before (also what happens on a graphics card that cannot draw into cube maps of 16-bit floats; the log says so).

## How it works

The shaders' lighting (`Engine/shaders/include/lighting.sh`, shared by meshes, custom shaders and decals) takes the mirrored direction, box-projects it for a probe, and reads the cube at the level for the surface's roughness; how much of it comes back follows Karis' fit of the split-sum lookup. Capturing uses bgfx views 160 to 199 (`Reflections.CaptureViewBase`): a RenderView in capture mode draws each face in HDR, a pass copies it into a source cube (whose mip levels the GPU makes), and a GGX importance-sampling pass filters each level of the probe's cube from it. The cubes are RGBA16F.

## Networking

Nothing to send: each machine captures its own probes from its own view of the scene. A dedicated server draws nothing and captures nothing.

## Compatibility

A probe captures twice the first time: on the second pass, shiny things in its own view mirror the room rather than the sky.

Scenes, materials and shaders are unchanged and load as before. Shiny and metal surfaces now mirror the sky (a little more light on smooth metals and glossy floors at a grazing angle); rough surfaces look the same. Indoor scenes with metals or polished floors want a probe per room. Custom shaders get reflections through the shared lighting with nothing to change.

## Limits

- Boxes are lined up with the world (not turned with the object).
- One probe per draw: a long object across two rooms gets the probe of the room its middle is in (fading to the sky outside it), not both.
- Probes are captured while the game runs, not baked into files; a scene with many probes takes a few frames per probe at the start (about ten at 128).
- What a probe captures stays as it was until it is captured again: things that move through a room are not in its reflections.
- Skinned characters, particles and the viewmodel are in captures as they were at that moment.

## Tests