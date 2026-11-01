# Animator and Animation windows

Animation in Tallow has three parts, arranged as in Unity:

- an **Animation Clip** (`.tanim`) is keyframes: how the children of an object move over time;
- an **Animator Controller** (`.tcontroller`) is a state machine: which clip plays, and when to change;
- the **Animator** component runs them on an object.

**Window > Animation** edits clips on a timeline. **Window > Animator** edits controllers as a graph. Both are also opened by double-clicking the asset in the Project panel.

## The Animator window

Create a controller with **Project > + > Animator Controller**, then set it as the **Controller** of an object's Animator. Selecting an object whose Animator has a controller shows that controller.

| In the window | What it is |
|---|---|
| Orange box | The default state, entered from **Entry** when the Animator starts. |
| Grey boxes | Other states. Each plays one clip. |
| **Any State** | Stands for whatever state is current: a transition from it can fire at any time. |
| Arrows | Transitions. Two between the same states run side by side. |
| Left panel | Parameters, and the settings of the selected state or transition. |

- **Right-click the canvas:** Create State.
- **Right-click a state:** Make Transition (then click the state it goes to), Set as Default State, Delete.
- **Click** a state or an arrow to edit it. **Delete** removes the selection. Drag states to arrange them. Middle-drag pans and the wheel zooms.

Changes are saved as you make them.

A **state** has a name, a clip, a speed and a loop setting. The clip is a `.tanim` file, or the name of a clip inside the object's skinned model (those are listed too when such an object is selected).

A **transition** has:

- **Conditions**, all of which must hold: a parameter compared with a value (greater than, less than, equals, not equal), a boolean that is true or false, or a trigger.
- **Has Exit Time** and **Exit Time**: wait until the state has played that fraction of its clip (1 is the end).
- **Duration**: seconds of cross-fade into the next state.

A transition with no condition and no exit time never fires, as in Unity.

**Parameters** are Float, Int, Bool or Trigger. A trigger stays set until a transition uses it, then clears itself.

### While the game runs

With an object selected, its current state turns blue with a bar showing progress through the clip, and the parameter list shows that Animator's live values. Editing a value there sets it on the running object, and **fire** sets a trigger, so a state machine can be tried without writing a script. Editing the controller while playing takes effect at once.

## The Animation window

Select an object with an Animator, or a child of one. If it has none, the window says so and its **Create** button adds an Animator and a first clip. The window is laid out like Unity's:

| Where | What |
|---|---|
| Top left | **Preview**, **Record** (the red dot), first / previous key, **Play**, next / last key, and the frame number at the time marker. |
| Second row | The clip (with **Create New Clip...** at the bottom of the list), the sample rate, **Add Key**, and **Auto Key**. |
| Left list | The children the clip moves. Unfold one to see its **Position**, **Rotation** and **Scale** at the marker. **Add Property** adds a child. |
| Right | The ruler in `seconds:frames`, a summary row with every key, and a row of key diamonds for each line of the list. |
| Bottom | The clip's **Length** and **Loop**, and **Frame All** to fit the clip in view. |

- **Moving in time:** click or drag the ruler. The object is posed at that time in the Scene view. The marker snaps to frames of the clip's sample rate (60 by default, saved with the clip).
- **Zooming:** scroll over the timeline to zoom, middle-drag to pan. The ruler's labels follow the zoom.
- **Keys:** click a diamond to select it and go to its time, drag it to retime it, right-click it or press Delete to remove it. A key holds position, rotation and scale together, so the three rows of a child share their diamonds.
- **Typing values:** change a number in the left list and a key is written at the marker.
- **Record:** while it is on, moving, turning or scaling a child (with the gizmo or the Inspector) writes a key at the marker. The ruler is tinted red.
- **Auto Key:** the same, but it stays on: whenever a clip is open, anything you move is keyed, without arming Record each time. The choice is remembered between sessions. The button is amber while it is on.
- Keying a child the clip did not move before adds it to the list. If the marker is not at the start, it also gets a key at time 0 holding its untouched pose, so it moves *to* the new key instead of sitting in the new pose for the whole clip. A key placed past the end lengthens the clip.
- **Add Key** keys the selected child where it is now, or every listed child when the Animator's own object is selected.
- **Preview** off puts the object back in its scene pose until the marker is moved again.
- Clicking a name in the list selects that child in the scene. Right-click a name for **Remove Properties**.
- **Rigged characters:** with Expose Bones on, the bones are drawn in the Scene view (click one to select and turn
  it). The footer's **Rig** menu sets up an IK rig, snaps IK targets to the bones, bakes IK into keys, and copies one
  of the model's own clips (retargeted ones too) into the open clip to edit it. **Hands** opens Hand Posing for finger
  shapes and curls. See `docs/retargeting.md`.
- There is no Curves view: keys are blended in straight lines.

Keys are offsets from the pose the object has in the scene, matched to children **by name**. One clip therefore works on any character whose children have the same names. When the window closes, or another object is selected, the object returns to its scene pose, so a previewed pose is never saved into the scene by accident.

## From scripts

```beef
let animator = GetComponent<Animator>();
animator.SetFloat("speed", velocity.Length);
animator.SetBool("grounded", controller.IsGrounded);
animator.SetInteger("lives", lives);
animator.SetTrigger("jump");

if (animator.CurrentState == "Jump" && animator.NormalizedTime > 0.5f) { /* past the top of the jump */ }
animator.Play("Idle");            // jump straight to a state
animator.CrossFade("Run", 0.3f);  // or fade to it
```

Also `GetFloat`, `GetBool`, `GetInteger`, `ResetTrigger`, `IsInTransition`, `StateTime` and `CurrentStateIndex`. Setting a parameter the controller does not have is ignored.

An Animator with **no controller** works as it always did: list clip files in **Clips**, and call `Play("Walk")`.

Controllers can be built in code as well (`AnimatorController.AddState`, `AddParameter`, `AddTransition`, `AddCondition`, `Save`), which is what the tests do.

## Clips from another file

A Skinned Mesh Renderer plays the clips in its model's file, and also those in each file its **Clip Library** names
(`clipLibrary`, separated by `;`). A library made for the same skeleton is matched by name: each bone turns as the
library's bone turns from its own rest pose, and only bones that the clip moves, such as the hips, take the clip's
movement, so a taller or shorter character keeps its own proportions. A library made for **another humanoid**
(Mixamo clips on a Synty character, say) is retargeted through both models' bone maps, with different names, rolls,
rest poses and facings allowed. Either way the hips' movement is scaled by leg length. Bones the library lacks stay
at rest. A clip with the same name as one in the model itself is not replaced. See `docs/retargeting.md`.

From code, `SkinnedModel.ImportClips(library, path)` does the same for any model.

## Layers

A controller starts with one layer, the **Base Layer**, which moves the whole body. More layers are each a state
machine of their own, laid over the ones below. Use them to play something else on part of the body (the upper body
aiming or reloading while the legs walk) or to add a movement on top of whatever is playing (a recoil, a breath, a
flinch).

In the Animator window the **Layers** list is at the top left. **+** adds a layer; click one to show its states on
the canvas. States, transitions and the Entry arrow belong to the layer shown, and Any State transitions made there
belong to that layer too. For the selected layer:

| Field | What it does |
|---|---|
| Weight | How much of the layer is used, 0 to 1. Change it from code with `SetLayerWeight`. |
| Blending | **Override** replaces the pose of the bones the layer's clips move, by its weight. **Additive** adds what its clips do (measured from each clip's first frame) to the pose below. |
| Mask | The bones the layer may move: each named bone and everything below it, separated by `;` (`spine_02` for the upper body). Empty: every bone. |

A layer only moves the bones its own clips move, so an upper-body layer with no clip playing (an empty "Arms Free"
state) leaves the body to the layers below. Each layer starts in its default state (right-click > Set as Default
State on that layer).

```beef
animator.SetLayerWeight("Upper Body", aiming ? 1 : 0);
let reloading = animator.StateIndexOn(1);   // the state a layer is in
```

## Blend trees

A state can play several clips at once, mixed by parameters, instead of one clip: walk and run by speed, or
strafing by sideways and forward speed. Select the state and choose **Blend Tree** instead of **Clip**.

- **1D** mixes along one parameter. Each clip has the value where it plays alone; between two values the two clips
  either side are mixed by how near the parameter is to each.
- **2D** mixes over two parameters (X and Y). Each clip has the X, Y where it plays alone, anywhere on the plane:
  forward at (0, 1), left at (-1, 0), and so on, with a standing clip at (0, 0). The weights come from gradient band
  interpolation, as Unity's Freeform Cartesian.

All the clips play in step, at the same point of their own length, so feet stay together when walking turns to
running; the state is as long as its clips by their weights. The picture under the clip list shows each clip as a
dot as big as its share and the parameters as a cross, live while the game plays.

Layers and blend trees work with `.tanim` clips, and with a rigged model's own clips when its Skinned Mesh Renderer
has **Expose Bones** on (the Animator then poses the bone objects itself). A controller with neither works exactly
as before.

## Multiplayer

Nothing to set up. Parameters and layer weights set on the server, or by the player who owns the object, reach every machine; that machine alone decides the transitions, on every layer, and the others follow it into each state. A client setting parameters on an object it does not own changes nothing.

## Visual scripting

Every method above is a node under **Engine > Animation > Animator** in a graph's add-node menu (Set Float, Set Trigger, Current State, Normalized Time and so on), generated from the engine source like all other nodes.

## Limits

- **No curves view.** The timeline is a dopesheet: keys are interpolated linearly, and there are no tangents to edit.
- **Transforms only.** Clips animate the position, rotation and scale of child objects. They do not animate other properties (a light's colour, a material), and there are no animation events.
- **No sub-state machines**, and blend trees cannot hold other blend trees.
- Layers and blend trees on a rigged model need **Expose Bones**; without it a state names one of the model's clips and the model plays it itself, as before.
- Masks are by bone name and take a bone with everything below it; there is no way to leave out one bone in the middle.
- **Skinned models** play their own clips: a state can name one, but those clips are not edited in place. **Rig > Copy Model Clip Into This Clip** copies one into a `.tanim` that can be.
- Undo does not cover edits made in these two windows.

## Performance

An Animator keeps, for each clip, which track moves each bone, so a frame doesn't look bone names up among the clip's tracks. Keys are found by halving. All the bones are posed first, then the topmost posed bone of each branch tells the transforms below it once (`Transform.SetLocalPoseDeferred` and `PoseChanged`). Before, every bone told everything below it, which cost a lot on long chains. 1,000 Animators of 32 chained bones: one clip 22 ms to 2.8 ms, three layers 44 ms to 14 ms. Code that adds or removes a clip's tracks directly calls `clip.TracksChanged()`; `AddTrack` does it already.

## Tests

`BeefBuild -workspace=Tests/Animator -config=Debug -run` (30 checks): key ordering and interpolation, the auto-keying rules, saving and loading clips and controllers, clips from before scale existed, conditions, triggers, exit time, Any State, cross-fade blending, state speed, editing a controller while it runs, previewing, and an unanimated child below a posed chain following it. `BeefBuild -workspace=Tests/AnimationLayers -config=Debug -run` (22 checks): 1D and 2D blend tree weights, blend trees in step, saving and loading layers, masks, blending and blend trees, controllers from before layers, a masked upper-body layer, layer weights, an additive recoil on top of other layers, triggers used up, and 2D blending by direction. `Tests/SkinnedMaterials` checks clip libraries: clips added once, each bone's turn from rest, and which bones move. `Tests/Retargeting` checks retargeting between humanoids (see `docs/retargeting.md`). The Network fixture checks parameters and states across machines.
