# Retargeting and posing characters

Clips made for one humanoid play on another: a Mixamo run on a Synty character, a Basic Motions walk on your own
rig. The bones may be named differently, have different lengths, rolls and rest poses (an A pose and a T pose), and
face different ways. The editor also lets you pose and key a character's bones directly, with bone shapes in the
Scene view, a one-press IK rig, and finger posing.

## Playing another character's clips

Put the other file in the Skinned Mesh Renderer's **Clip Library** (several, separated by `;`). Its clips are added
to the model's own and listed in the Inspector, marked *(library)*. Play them like any other clip: `Play("Run")`, the
Clip field, or a state in an Animator Controller.

How a library is fitted depends on its skeleton:

- **The same skeleton** (most humanoid bones named the same, such as the Basic Motions pack on POLYGON characters):
  bones are matched by name, and each bone turns from its own rest pose as the library's bone turns from its rest
  pose. This is how clip libraries always worked.
- **Another humanoid**: bones are matched through both models' **bone maps**. Each of your bones is first swung to
  point the way its counterpart points at rest, so an A-posed clip hangs a T-posed character's arms. Then it turns as
  its counterpart turns, measured in the model's space, so bone rolls do not matter. The library is turned to face
  the way your character faces.

Either way the hips' movement is scaled by leg length: a character with half the legs takes half the stride and bobs
half as high. Bones the library lacks, and helper joints, stay at rest. Your character keeps its own bone lengths.

From code, `model.ImportClips(library, path)` does the same for any `SkinnedModel`, and `model.ModeFor(library)` says
which way it fits (`.SameSkeleton` or `.Humanoid`).

## Bone maps

Every rigged model has a `HumanMap`: which of its joints is each humanoid bone (Hips, Spine, Chest, UpperChest, Neck,
Head, and for each side Shoulder, UpperArm, LowerArm, Hand, UpperLeg, LowerLeg, Foot, Toes and three segments of
each finger). It is matched by name. These naming styles are recognised:

| Rig | Examples |
|---|---|
| Mixamo | `mixamorig:LeftUpLeg`, `mixamorig:LeftForeArm`, `mixamorig:LeftHandIndex1` |
| Synty POLYGON | `Pelvis`, `Thigh_L`, `calf_l`, `UpperArm_L`, `lowerarm_l`, `indexFinger_01_l` |
| Unreal | `pelvis`, `thigh_l`, `calf_l`, `upperarm_l`, `hand_l` |
| Blender / Rigify | `thigh.L`, `forearm.R`, `DEF-upper_arm.L` |
| Others | `jnt_left_upleg`, `Bip01 L Thigh`, `LeftHand` |

Twist and roll bones, IK targets (`ik_hand_l`), end points (`HeadTop_End`) and weapon sockets are skipped. A model
with no hips is not treated as a humanoid, and its libraries are matched by name.

To fix a match, press **Bone Map...** under the Skinned Mesh Renderer in the Inspector. The window lists every bone
with a drop-down of the model's joints. Changes apply at once, so clips retargeted onto the model (or from it)
update while you watch. **Save** writes `Models/hero.bonemap` beside `Models/hero.glb`. That file goes into builds
with the model. **Match by Name** starts again; **Revert** goes back to the saved file.

The file is plain text, one bone a line, and a bone left empty has no joint:

```
LeftUpperArm = UpperArm_L
LeftMiddle1 = finger_01_l
LeftToes =
```

Bones the file leaves out are matched by name. From code: `model.HumanMap[.LeftHand]` is the joint's name,
`model.FindJoint(...)` its number, `model.SetHumanMap(map)` uses another map, and
`SkinnedModel.ReloadBoneMaps()` reads every file again.

## Posing bones in the editor

Turn on **Expose Bones** on the Skinned Mesh Renderer (or **Rig > Expose Bones** in the Animation window). Then, while
the character, its Animator's object or one of its bones is selected:

- **Bone shapes** are drawn over the model in the Scene view, seen through the mesh: blue on the left, red on the
  right, yellow down the middle, orange for the selected bone. They are editor-only and never saved or drawn in the
  game. The toolbar's **Bones** button hides them.
- **Click a bone** to select it. Bones are picked ahead of the meshes around them. Picking a bone other than the root
  switches the Move handle to **Rotate**, since bones are posed by turning them.
- With **Record** or **Auto Key** on in the Animation window, turning a bone keys it at the time marker.

The Animation window's footer has a **Rig** menu:

| Item | What it does |
|---|---|
| Expose Bones | Makes the bones objects, so they can be posed and keyed. |
| Show Bones in the Scene View | The same as the toolbar's Bones button. |
| Set Up IK Rig | For a humanoid: a target for each hand and foot (each holding a Limb IK), a pole for each elbow and knee, and a look target with a Look At IK for the head. They go below the Animator's object, where the character is now, so nothing moves until they do. |
| Snap IK Targets to Bones | Moves every target to where the clip alone puts its hand or foot at the marker, and every pole out from its joint. |
| Bake IK Into Keys | Keys the pose IK makes on every frame of the clip (30 a second at most) into the bones it moves. The clip then plays it with no IK. |
| Copy Model Clip Into This Clip | Keys every bone a model clip moves (retargeted ones too) on every frame, into the open clip, so it can be edited here. |

### Animating with IK

1. **Rig > Set Up IK Rig.** Green boxes appear on the hands and feet, pink diamonds at the elbows and knees, and a
   yellow diamond in front of the head.
2. Turn on **Record** (or Auto Key), move the time marker, and drag a box. The arm or leg follows, and the box is
   keyed. A box's turn is the hand's or foot's turn. Move a diamond to swing the elbow or knee.
3. Play the clip: the targets move and IK moves the limbs, in the editor and in the game.
4. To keep the pose without IK in the game, **Rig > Bake IK Into Keys**, then set the IK components' Weight to 0 or
   remove them.

To start from a clip that already moves the limbs, open it, press **Snap IK Targets to Bones** at each key you want to
change, and adjust from there.

### Hands and fingers

The footer's **Hands** button opens **Hand Posing**, with a column for each hand:

- **Pose Fingers** adds a Hand Pose to the hand bone, with the straight pose taken from the model's own rest pose
  (not the clip's, so an idle's half-closed hand does not make every shape curl too far).
- Ready-made shapes: Open, Relaxed, Fist, Grip, Trigger, Point, Pinch, Thumbs Up.
- A slider for each finger (0 straight, 1 curled) and **Spread**. A finger the hand lacks is greyed out. POLYGON
  hands, whose middle, ring and little fingers are one chain named `finger_01...`, curl that chain with **Middle**.
- **Key Fingers** keys every finger bone at the marker. With Record or Auto Key on, finishing a change keys it by
  itself.
- **Copy to Other Hand** gives the other hand the same shape and curls (and keys them while recording).

After keying, the Hand Pose's Weight goes to 0, so the clip's keys are what shows as the marker moves. Posing again
turns it back up. In the game a Hand Pose works as before (see `docs/ik.md`).

## Multiplayer

Nothing extra is sent. Retargeting happens on each machine as models load, and the Animator already sends clip and
state, not bones. Bone maps are files in the game, the same everywhere.

## Limits

- Only humanoids are retargeted between differently named skeletons. Other skeletons (animals, vehicles) are matched
  by name only.
- Retargeting fits rotations and the hips' movement. It does not keep feet planted or hands on props when proportions
  differ a lot: put a Foot Placement or Limb IK on top for that.
- Copied and baked clips hold a key on every frame, which is accurate but dense to edit by hand.

## Tests