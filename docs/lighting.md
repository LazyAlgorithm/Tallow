# Lights and shadows: many lights, point and spot light shadows

A scene can have hundreds of point and spot lights: street lamps, a row of torches, the glow of every pickup. Each view keeps the 256 nearest it can see and sorts them into **clusters**, so a pixel only works through the few lights that reach it. The nearest lights that cast shadows get them: a spot light through its cone, a point light all round it.

Nothing needs setting up. Add lights (**GameObject > Light**), give point and spot lights a **Range** that fits, and tick **Cast Shadows** on the ones whose shadows matter.

## Lights

| Setting | What it does |
|---|---|
| **Type** | Directional (like the sun: everywhere, from one direction), Point (from a point, all round) or Spot (from a point, in a cone). |
| **Color**, **Intensity** | The light's colour and how bright it is. |
| **Range** | How far a point or spot light reaches, in metres. A light lights nothing past it, and costs nothing there: keep ranges as small as looks right. |
| **Inverse Square** | Physical falloff (intensity per square metre) instead of the default softer curve. |
| **Spot Angle**, **Inner Spot Angle** | A spot light's cone, and where its edge starts to fade (80% of the cone by default). |
| **Cast Shadows** | Whether it casts shadows. A point light's cost six spot lights' (one for each face of a cube). |
| **Shadow Strength** | How dark its shadows are: 1 fully dark, 0 none. |

The **sun** is the directional light that casts shadows (or the first one, if none does); it has four shadow cascades of its own. Other directional lights light every pixel, without shadows (up to 8).

## How many

| | |
|---|---|
| Point and spot lights in a view | 256, the nearest kept (the editor's Scene view counts them, and any left out) |
| Lights reaching one pixel | 32, the nearest |
| Point and spot lights with shadows in a view | Quality's **Shadowed Lights**: 2 at Low, 4 at Medium, 8 at High, 16 at Ultra (`RenderView.MaxShadowedLights`) |
| Shadow tiles | 64 (a spot light takes one, a point light six) |

"Nearest" is by how far the edge of a light's reach is from the camera, so a big light the camera stands in comes before a small one beside it. The lights with shadows change as the camera moves; give the shadows that matter most (the room's lamp, the player's torch) the lights that are nearest where they are seen.

`--shadowed-lights <n>` overrides the quality setting for one run (0: no point or spot shadows), to compare.

## Shadows

Point and spot lights share one shadow atlas, the size of the sun's (Quality's **Shadow Map**). It is cut into a grid by how many tiles are in use: 2 × 2 for up to four (2048 pixels each at 4096), 4 × 4 for up to sixteen (1024) and 8 × 8 beyond (512). A spot light's tile is its view down the cone. A point light has six, the faces of a cube round it, each a little wider than 90 degrees so that the soft edge of a shadow never reaches past a face. The shadow is tested with four filtered taps and pushed off the surface by about one texel where it lands, which keeps it free of acne at any distance.

What casts into a tile is everything that casts shadows within the light's reach, even out of the camera's view: a wall behind the player still stops a far lamp's light.

Lightmapped surfaces skip lights marked **Baked Only** (their light is in the lightmap: docs/baked-lighting.md), and a light's baked shadow mask channel still applies, as before.

## In code

```beef
let lamp = go.AddComponent<Light>();
lamp.type = .Point;
lamp.range = 8;
lamp.intensity = 4;
lamp.castShadows = true;

RenderView.MaxShadowedLights = 4;   // or Quality.Current.shadowedLights, then Quality.Apply()
```

A `RenderView` reports its last frame's `LightCount`, `LightsDropped` and `ShadowTiles`.

## How it works

`LightClusters` (one per `RenderView`) picks the view's lights each frame: the directional ones first, then point and spot lights in the camera's view, nearest first. The view is cut into 16 × 9 cells across the screen and 24 slices in depth (closer slices thinner, so each holds a similar share of the scene). Each light is added to the clusters its sphere's box can touch, and each cluster gets the list of its lights. Lights, shadow tiles and lists go to the graphics card in one float texture per view (`s_lightData`, 64 texels wide); `include/lighting.sh` finds a pixel's cluster from where it is and walks its list. The shadow tiles are drawn in one pass, each through its own matrix and kept to its part of the atlas by a scissor, so a view uses 19 bgfx views however many shadows it has (docs/post-processing.md).

Custom surface shaders (`.tshader`) get all of this from the engine's shader: the editor compiles a project's shaders again when the engine's shader files are newer than them, at start-up and before a build.

## Compatibility

- Before this, a view drew the first 16 lights in the scene and only spot lights cast shadows. **Point lights with Cast Shadows ticked (the default) now cast shadows**, up to the quality setting's count. Untick it on point lights that do not need them.
- Shaders compiled for a project before this lose their point and spot lights until compiled again (the editor does this by itself at start-up).

## Limits

- Lights past the 256 nearest in view, and past the 32 nearest at one pixel, are left out (the far ones, which matter least).
- Shadows from point and spot lights are hard-edged apart from their filtering; there are no soft shadows that widen with distance.
- See-through objects do not cast shadows (as with the sun).

## Tests