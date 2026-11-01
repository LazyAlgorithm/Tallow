# Screen effects and colour grading

After the scene is drawn, Tallow can run a few effects over the whole picture before it is tonemapped for the screen:

- **ambient occlusion**: darkens creases, corners and the ground right under things;
- **depth of field**: blurs what is nearer or further than the focus;
- **camera motion blur**: smears the picture as the camera turns or moves;
- **colour grading**: contrast, saturation, white balance, a colour filter, vignette and a colour lookup table.

They are scene settings, saved with the scene. A new scene uses none of the first three. Colour grading's defaults are the values the tonemap always used, so existing scenes look exactly as they did.

## In the editor

Select nothing to see **Scene Settings** in the Inspector. Below Lighting and Sky and Fog are two more sections. The Game view shows every change as it is made, in edit mode and while playing. Hover a setting for a short explanation.

**Screen Effects**

| Setting | |
|---|---|
| **Ambient Occlusion** | 0 is off; 1 is normal; up to 2. |
| **Occlusion Radius** | How far around each point, in metres, is looked at. Small radii shade fine detail; large ones shade broadly under big shapes. |
| **Depth Of Field** | 0 is off. At 1 the strongest blur is a circle 3% of the screen's height across; up to 2. |
| **Auto Focus** | Focus on whatever is in the middle of the screen. |
| **Focus Distance** | The distance, in metres, that is sharp (when not auto-focusing). |
| **Focus Range** | How deep the sharp band is. Things within half of it either side of the focus are sharp, and things a whole range beyond that are fully blurred. |
| **Motion Blur** | 0 is off; 0.5 is like a film camera; 1 smears the whole of a frame's movement. |
| **In Scene View** | Shows depth of field and motion blur in the Scene view too. This is an editor setting and is not saved. Ambient occlusion always shows there. |

**Color Grading**

| Setting | |
|---|---|
| **Contrast** | 1 leaves the picture alone. |
| **Saturation** | 1.05 by default (the old fixed value). 0 is grey. |
| **Temperature** | Above 0 is warmer (orange); below 0 is cooler (blue). |
| **Tint** | Above 0 leans magenta; below 0 leans green. |
| **Color Filter** | Multiplies the light of the whole picture, like a coloured filter on the lens. |
| **Vignette** | Darkening towards the corners (0.35 by default). |
| **Lookup Table** | A colour lookup table image (below). Drag one in from the Project window, or pick one with **...**. |
| **Lookup Strength** | How much of the table is used. |

**Make Neutral Lookup Table** saves `Grading/neutral_lut.png` in the project and uses it. **Reload** reads the image again after you change it outside the editor. **Reset Grading** puts the grading back to the defaults.

### Lookup tables

A lookup table is an image made of square tiles side by side. A table of size 16 is 256 × 16 pixels, and one of size 32 is 1024 × 32. Within each tile, red increases to the right and green increases downwards. Blue increases from one tile to the next. A neutral table changes nothing.

To grade with one:

1. Make a neutral table.
2. Take a screenshot of the game.
3. Open both in any image editor (Photoshop, Krita, GIMP, Affinity).
4. Adjust the two together with curves, levels, hue and colour balance. Avoid anything that moves pixels, such as blur.
5. Save the table over the original, and press **Reload**.

The grading is now part of the scene. Lookup tables are applied after the other grading, to the colours as they appear on screen.

## From code

Every setting is a field of `scene.Environment` and can change while the game runs. The scene's settings are each player's own picture, so nothing is sent over the network.

```beef
let env = Scene.Active.Environment;
// Aiming down the sights: blur the world around the target, a little more the further it is raised.
env.autoFocus = true;
env.depthOfField = pose.AimBlend * 0.8f;
// A damage flash: redder, less colour.
env.colorFilter = .(1, 0.6f, 0.6f);
env.saturation = 0.5f;
```

To try effects on a scene without editing it, start the game with `--effects` (on the web, add `?arg=--effects&arg=...` to the address):

```sh
./MyGame --effects "ao=1,radius=0.8,dof=0.6,autofocus=1,motion=0.5,contrast=1.1,temperature=0.2,lut=Grading/warm.png"
```

The names are `ao`, `radius`, `dof`, `focus`, `range`, `autofocus`, `motion`, `contrast`, `saturation`, `temperature`, `tint`, `vignette`, `lut` and `lutstrength`. `PostProcess.ApplySettings(list, env)` does the same from code.

## Players' settings

A game's settings menu usually lets each player turn effects off, tone down motion blur and set the brightness. These are static fields of `ScreenEffects`, and they apply on top of whatever the scene asks for:

| Field | |
|---|---|
| `ScreenEffects.AmbientOcclusion` | Turns ambient occlusion off when false. |
| `ScreenEffects.DepthOfField` | Turns depth of field off when false. |
| `ScreenEffects.MotionBlur` | Turns motion blur off when false. |
| `ScreenEffects.MotionBlurAmount` | Scales the scene's motion blur (0 to 2; 1 as the scene has it). |
| `ScreenEffects.Brightness` | Multiplies the scene's exposure (0.25 to 4; 1 leaves it alone). |

`Gfx.UseMobileQuality()` turns the first three off, because each costs a second pass over the scene's solid objects plus a few full-screen steps. A phone game that wants them can turn them back on afterwards. Colour grading is always on, because it costs nothing.

The engine does not save these fields. Keep them with your game's own saved settings and copy them across whenever they change:

```beef
[Component]
class Settings : Component
{
    [Saved] public bool ambientOcclusion = true;
    [Saved] public bool motionBlur = true;
    [Saved] public float motionBlurAmount = 1;
    [Saved] public float brightness = 1;

    public void Apply()
    {
        ScreenEffects.AmbientOcclusion = ambientOcclusion;
        ScreenEffects.MotionBlur = motionBlur;
        ScreenEffects.MotionBlurAmount = motionBlurAmount;
        ScreenEffects.Brightness = brightness;
    }
}
```

## How it is drawn

When the scene uses ambient occlusion, depth of field or motion blur (or a decal is in view: `docs/decals.md`), a **depth pass** draws the solid objects a second time with a very cheap shader. It records each pixel's distance in front of the camera at the scene's resolution. The viewmodel (`Camera.viewmodelLayer`) is marked so that every effect leaves it alone: it gets no occlusion, it stays in focus, and it is never smeared. The sky is marked as far away. The effects then run in order, each reading the picture so far:

1. **Ambient occlusion** is worked out at half size. It takes twelve samples in the half-ball above each surface (the surface's facing comes from its neighbours' depths). It is then blurred without crossing from one surface to another, and the picture is darkened by it.
2. **Depth of field** is a 24-tap round blur at half size. In it, each nearby pixel counts only as far as its own blur reaches, so a sharp subject does not smear into the background behind it. The blur is then blended with the sharp picture by how out of focus each pixel is.
3. **Motion blur** puts each pixel's surface back through last frame's camera to find where it was, and averages eight samples along the way it moved. The smear is limited to 6% of the screen. A camera cut of more than 5 metres in one frame (a respawn, say) is not smeared. This is camera motion blur: moving objects seen by a still camera are not blurred.

Bloom and the tonemap read the result. Colour grading happens in the tonemap:

1. White balance and the colour filter are applied in HDR.
2. Then the ACES tonemapping curve, saturation, vignette and gamma.
3. Then contrast.
4. The lookup table comes last.

None of this runs, and nothing is allocated for it, until a scene asks for one of the effects.

Each RenderView now uses `RenderView.ViewCount` (19) bgfx view ids from its `ViewBase`:

| Views | Pass |
|---|---|
| 0 to 3 | sun shadows |
| 4 | point and spot light shadows (every tile, docs/lighting.md) |
| 5 | scene |
| 6 | depth |
| 7 | decals |
| 8 | see-through |
| 9 | viewmodel |
| 10 and 11 | ambient occlusion |
| 12 and 13 | depth of field |
| 14 | motion blur |
| 15 to 17 | bloom |
| 18 | tonemap |

A game that makes its own RenderViews should space their `ViewBase`s at least `RenderView.ViewCount` apart.

Each RenderView can leave effects out with `ShowAmbientOcclusion`, `ShowDepthOfField` and `ShowMotionBlur`. The editor's Scene view uses these, and so do the asset previews.

## Notes

- Cut-out (alpha-tested) objects such as leaves count as solid in the depth pass.
- See-through objects and particles are not in the depth pass. The effects treat them as part of what is behind them.
- An orthographic camera works with all of the effects.

## Tests

- the settings and their defaults;
- saving, and that old scenes load as they were;
- the depth of field's blur amounts;
- lookup tables (neutral and recoloured);
- the players' settings and phone quality.

The passes themselves need a graphics card; check them by eye in the Game view.
