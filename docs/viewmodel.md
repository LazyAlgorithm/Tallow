# First-person viewmodel

In a first-person game the player's own arms and weapon (the **viewmodel**) hang just in front of the camera. Drawn with the rest of the world they cause two problems: walk up to a wall and the gun pokes through it, and change the field of view (a setting, or zooming) and the arms stretch or shrink with it. Tallow draws them in a pass of their own instead: after the world, over it, with their own field of view and a near clip right at the eye.

## Setting it up

1. **A layer.** In **Project Settings**, name a layer `Viewmodel`. In the collision table, untick it against every layer (the arms and gun are drawn, not physical; anything on the layer that has a collider then touches nothing).
2. **The arms and weapon.** Make them children of the camera's object and put them on the Viewmodel layer (the **Layer** menu at the top of the Inspector). Children of an object do not change layer with it, so set each part, or set the layer from code.
3. **The camera.** In the Camera's Inspector set:

| Setting | |
|---|---|
| **Viewmodel Layer** | The layer drawn as the viewmodel. *None* (the default) turns the pass off: every layer is drawn with the world, as before. |
| **Viewmodel Field Of View** | The viewmodel's own field of view, 10 to 120 degrees. The arms keep the same size and shape on screen whatever the world's field of view is. |
| **Viewmodel Near Clip** | How close to the eye the viewmodel can come before it is cut off (0.01 m by default). |
| **Viewmodel Casts Shadows** | Off by default: a gun held at the eye throws an odd shadow, and other players see the full body anyway. The viewmodel always *receives* the world's shadows and lights. |

With the camera selected, the Scene view shows the viewmodel's view out to an arm's length as an amber frustum, next to the camera's own (white): place the arms and weapon inside the amber one. The Game view shows the result, in edit mode and while playing. The Scene view itself draws the viewmodel where it really is, so it can be selected and moved like anything else.

From code:

```beef
let camera = Session.Camera.GetComponent<Camera>();
camera.viewmodelLayer = ProjectConfig.LayerNamed("Viewmodel");
camera.viewmodelFieldOfView = 60;
weapon.Layer = camera.viewmodelLayer;   // for each part of the arms and weapon
```

## Moving it: Viewmodel Pose

Add a **Viewmodel Pose** to the object that holds the arms and weapon (the child of the camera). It moves that object every frame:

- **Hip and aim poses.** The weapon rests at the hip pose and, while `aiming` is true, comes up to the aim pose: by default in the middle of the screen with the sights on the crosshair. **Aim Speed** sets how quickly (the whole way in 1 / Aim Speed seconds). `AimBlend` (0 to 1, eased) lets the game narrow its field of view or show a scope in step.
- **Walk bob.** Worked out from how fast the camera moves over the ground: **Bob** is the side-to-side and up-and-down at **Bob Full Speed**, once each **Bob Stride** metres.
- **Sway.** The weapon lags a little behind when the view turns: **Sway** degrees for each 100 degrees a second, up to **Sway Limit**.
- **Aim Steadiness** takes that much of the bob and sway away while aiming.
- **Recoil.** `Kick(amount)` pushes the weapon back (**Recoil Back**) and tips the muzzle up (**Recoil Pitch**); it settles by itself (**Recoil Recovery**).

The only code a game needs:

```beef
pose.aiming = InputActions.Held("Aim");
if (fired) pose.Kick(1);
```

**In the editor**, **Preview** (0 to 1) shows the pose part way from hip to aim while not playing. To set a pose, move the object until the weapon looks right in the Game view and press **Use current place as Hip** or **Use current place as Aim** under the component.

## How it is drawn

After the world's solid and see-through objects, the depth buffer is cleared and the viewmodel layer's objects are drawn with the camera's position and direction but the viewmodel's projection (`CameraData.viewmodelProjection`): solid parts first, then see-through parts back to front. Nothing in the world can hide them, and they are lit, fogged and shadowed like everything else, with bloom and tonemapping applied to the whole picture afterwards. They are not frustum-culled (they are a few objects at the eye). `RenderView.DrawsAsViewmodel(camera, gameObject)` says whether an object goes into the pass.

Each camera's render now uses eleven bgfx views from its `ViewBase` (shadows 0 to 3, scene 4, see-through 5, viewmodel 6, bloom 7 to 9, tonemap 10).

## Networking

Nothing to share: the viewmodel is drawn, and its pose worked out, only on each player's own machine. Other players see that player's full body and weapon, which are networked as usual. A typical player prefab keeps the world body (shown to others, `MeshRenderer.shadowOnly` for its owner) and the viewmodel (made or shown only for the local player) apart.

## Notes

- An orthographic camera never draws a viewmodel pass.
- Scenes and prefabs saved before these settings existed load with no viewmodel, exactly as before.
- A component of your own can show an integer as a choice of the project's layers with `[Layer]`, as the Camera does for Viewmodel Layer.

## Tests

`BeefBuild -workspace=Tests/Viewmodel -config=Debug -run` checks the camera's settings and projection, which objects go into the pass, the Inspector's layer choice, and saving. The pass itself needs a graphics card; check it by eye in the Game view.
