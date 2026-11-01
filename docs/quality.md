# Graphics quality presets

Players have machines from phones to big desktops. **Quality** gathers every graphics setting that trades looks for speed into four presets, **Low**, **Medium**, **High** and **Ultra**, applies them to the engine at once, and remembers the player's choice between runs. A game's options screen needs only a few lines.

**High** is what the engine always did, so a project that never touches Quality looks as before (apart from point lights, which now cast shadows too: docs/lighting.md).

## What each preset sets

| Setting | Low | Medium | High | Ultra | What it does |
|---|---|---|---|---|---|
| Render Scale | 0.7 | 0.85 | 1 | 1 | Share of the window's resolution the 3D scene is drawn at; the interface stays sharp (`RenderView.RenderScale`). |
| Antialias | off | on | on | on | Multisampled edges (`RenderView.Antialias`). |
| Shadows | on | on | on | on | Sun, point and spot light shadows (`RenderView.ShadowsEnabled`). |
| Shadowed Lights | 2 | 4 | 8 | 16 | How many point and spot lights cast shadows in a view, the nearest first; a point light costs six spot lights (`RenderView.MaxShadowedLights`, docs/lighting.md). |
| Shadow Map | 1024 | 2048 | 4096 | 4096 | Shadow map size in pixels; smaller is blurrier and cheaper (`RenderResources.SetShadowAtlasSize`). |
| Shadow Distance | ×0.5 | ×0.75 | ×1 | ×1.5 | Times each scene's Shadow Distance (`RenderView.ShadowDistanceScale`). |
| Ambient Occlusion, Depth of Field, Motion Blur | off | AO only | on | on | The costly screen effects (`ScreenEffects`); a scene's own settings still decide whether it uses them. |
| Detail Distance | ×0.6 | ×0.8 | ×1 | ×1.5 | How far away LOD Groups keep detail (`LODGroup.Bias`, docs/lod.md). |
| Foliage Distance | ×0.5 | ×0.75 | ×1 | ×1.5 | Times each Foliage's View Distance (`Foliage.DistanceScale`). |
| GPU Skinning | on | on | on | on | Bend characters on the graphics card (`GpuSkinning.Enabled`, docs/gpu-skinning.md). |
| Vsync | on | on | on | on | Wait for the screen's refresh (`Gfx.SetVsync`). |
| Texture Detail | half | full | full | full | Leaves out each texture's largest mip level: a quarter of the memory (`Textures.SkipLevels`, docs/textures.md). For textures loaded afterwards. |
| Anisotropic Filtering | off | on | on | on | Sharper textures on slanted surfaces (`Gfx.SetAnisotropic`). |
| Reflection Probes | off | on | on | on | Rooms mirrored by their reflection probes; off, shiny surfaces mirror only the sky (docs/reflections.md). |
| Reflection Size | 64 | 64 | 128 | 256 | A reflection probe's cube, in pixels (probes that do not choose their own). |

Changing any one setting from a preset makes the level **Custom**.

## In a game

```beef
// Options screen
if (pressedLow) Quality.Set(.Low);
Quality.Current.motionBlur = toggle;  // one setting
Quality.Apply();
Quality.Save();                       // remembered for the next run

// First run: nothing saved yet
if (!File.Exists(scope $"{GamePaths.PlayerData}{Quality.FileName}"))
	Quality.Set(Quality.Recommended);
```

At start the engine applies the player's saved settings by itself (`graphics.cfg` in the player data folder, one `name=value` a line). **Quality.Recommended** suggests Low on phones, Medium on built-in (Intel) graphics and in a browser, and High otherwise. `Quality.Level` says which preset is in use, for showing it in a menu.

The switch `--quality low|medium|high|ultra` sets a preset for one run (not saved), for checking how a game looks and runs on each.

## In the editor

**Window > Graphics Quality** shows the presets and every setting, applied at once to the Scene and Game views, to see what a player's Low or Ultra looks like while building a level. The editor does not read or write the player's saved settings. The editor switch `--quality-window` opens it.

## Networking

Nothing to send: quality is each player's own, and it changes only how things are drawn, never physics, gameplay or what the server decides. A dedicated server draws nothing.

## Compatibility

Projects and scenes are unchanged; with no `graphics.cfg` every setting is what it was before.

## Tests