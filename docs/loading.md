# Loading in the background

Big scenes, models and textures can be loaded while the game keeps running: behind a loading screen, a level got
ready while the player is still in the menu, or a part of the world brought in as the player nears it.

Reading files and decoding models and pictures is done on loading threads. What has to happen on the main thread
(sending meshes and textures to the graphics card) is done a little each frame, within **AssetLoader.UploadBudget**
milliseconds (4 by default), so the frame rate holds while it loads. In a browser, which has no threads here, all of
it is done on the main thread within the same budget.

## Without code: the Scene Loader component

Add a **Scene Loader** to any object and pick a **Scene**.

| Field | What it does |
|---|---|
| Scene | The scene file to load |
| Additive | Add it to the running scene. Off: the game changes to it once it has loaded. |
| Apply Environment | With Additive: take its sky, fog and ambient light too |
| Load On Start | Start loading as the game starts; otherwise call `Begin()` |
| Activate When Ready | Off: a finished load waits at 0.9 until `Activate()` is called, for "press any key to continue" |

Its `progress` field goes from 0 to 1, so a loading bar is a UI Document `<bar bind="progress" />` on the same
object. `Finished` is true once it is done; `Group` holds what an additive load added.

## From code

```beef
// Change scene behind a loading screen:
let load = SceneManager.LoadAsync("Scenes/Harbour.tscene");
// every frame until it is done:
loadingBar.value = load.Progress;

// Bring part of the world in without stopping:
mDocks = SceneManager.LoadAdditiveAsync(Scene, "Scenes/Docks.tscene");
// later: if (mDocks.IsDone) ... mDocks.Group holds it; SceneManager.Unload(mDocks.Group) takes it out

// Hold a finished load until the player is ready:
load.allowActivation = false;
... when load.CurrentStage == .Ready and a key is pressed: load.Activate();

// Get things ready before they are needed (a weapon about to be picked up):
let batch = AssetLoader.Preload("Models/rocket_launcher.glb", "Textures/launcher.png");
// batch.Progress, batch.IsDone; delete it when done with it (what it loaded stays loaded)
```

A load goes through **Reading** (the file, and finding what it names), **Loading** (the models and textures it names),
**Ready** (only when `allowActivation` is off) and **Done**, or **Failed** if the file is not there. **Progress** is a
tenth for reading, up to 0.9 for loading, and 1 when done. `AssetCount` and `AssetsLoaded` say how many things it
names and how many are in.

What a scene names is found by reading it: every model (Mesh Renderers' meshes, Skinned Mesh Renderers' models) and
every picture in it, and in the prefabs, scenes and materials it names, two levels deep. Things that are loaded
already count at once. Anything a script loads by a name made up while it runs is not found this way: preload it with
`AssetLoader.Preload`.

A `SceneLoad` belongs to SceneManager and is let go the frame after it is done, so read what you need from it then.

## Multiplayer

Every machine loads scenes for itself, as it does its start scene; nothing about loading is sent. A machine that is
slower to load simply gets there later. Objects that are shared over the network arrive the same way as ever once
the scene is in.

## Limits

- Things are loaded one model or picture at a time on two loading threads; a model with many pictures waits for all
  of them.
- Sounds are not preloaded (they are read when first played).
- Changing scene with `LoadAsync` swaps the whole scene in one frame once everything is loaded, as `Load` does;
  the swap itself is not spread over frames.