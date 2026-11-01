# Inverse kinematics

Inverse kinematics (IK) poses a limb from where its end should be: you say where the hand goes and the arm works
out the elbow. Tallow has four IK components, a set of solver functions under them, and tools for them in the
Inspector and the Animation window.

| Component | What it does |
|---|---|
| **Limb IK** | Holds a hand or foot on a target: hands on a weapon, a hand on a handle, a foot on a pedal |
| **Look At IK** | Turns a head, or a head with the neck and spine, towards a target |
| **Foot Placement** | Keeps both feet on uneven ground and lowers the hips to suit |
| **Hand Pose** | Curls and spreads the fingers with a slider each, and has ready-made shapes |

## How it fits with animation

IK is a layer on top of the pose. Every frame the clips play first (the Animator, a rigged model's own clips), then
scripts run their `Update` and `LateUpdate`, and then IK is worked out, in this order: Foot Placement, Look At IK,
Limb IK, Hand Pose. So a walk cycle plays underneath while the hands stay on a rifle that sways and recoils.

Each component remembers the pose its bones had before it touched them and starts from that pose every frame. That
means:

- **Weight** blends between the animation (0) and the IK (1), and can be changed at any time.
- Disabling or removing a component gives the bones back exactly as they were.
- A saved scene holds the pose from before IK, so nothing drifts from save to save.
- IK works in the editor as well as in the game (except Foot Placement, which needs the physics world of a running game).

## Which characters it works on

IK works on bones that are objects in the Hierarchy.

- A character **built from objects** (each limb an object with a mesh on it) already is that.
- A **rigged model** (a `.glb` with a skeleton) needs **Expose Bones** ticked on its Skinned Mesh Renderer. That
  makes an object for every bone, under the renderer, and bends the mesh from those objects. The model's own clips
  still play, underneath. The bone objects are ordinary objects saved with the scene, so you can parent things to
  them (a weapon to a hand) and drag them into the fields below. An Animator can play `.tanim` clips on them and the
  Animation window can key them.

## Hands on a weapon

This is what Limb IK is for. One Limb IK is one arm, so a two-handed weapon takes two.

1. On the weapon, make two empty objects where the hands belong, say `GripRight` and `GripLeft`.
2. On the character, add a **Limb IK**. With **Tip** empty, the Inspector lists the hands and feet it finds below
   the object: press the right hand. (Or drag the hand bone into Tip.)
3. Drag `GripRight` into **Target**. The arm bends to put the hand there.
4. Add a second Limb IK for the left hand and `GripLeft`.
5. If an elbow points the wrong way, make an empty object out to the side and a little behind, and drag it into
   **Pole**. The elbow points towards it. Without a pole, a humanoid's limb bends the way its clip bends it, and
   when it is straight (a T or A pose) the natural way: elbows back, knees forward (`NaturalBend()`).
6. To turn the hand on the grip: set **Weight** to 0, rotate the hand until it looks right, press **Keep Hand's
   Rotation**, and bring Weight back to 1. That fills in **Rotation Offset**. **Rotation Weight** 1 locks the hand to
   the target's rotation; 0 leaves the wrist to the animation.
7. If the wrist, not the palm, is landing on the grip, set **Grip Point** to where the palm is in the hand's own
   space.

**Make Target And Pole** (shown while Target is empty) makes both objects for you, starting where the hand and elbow
already are, for limbs that are not following a weapon.

### Letting go with one hand

Each arm is its own component, so each can be released by itself:

```beef
// The left hand leaves the rifle to throw a grenade; the right hand stays on the grip.
leftArm.LetGo(0.15f);
animator.SetTrigger("Throw");
// ... when the throw is over:
leftArm.Grab(0.2f);
```

`LetGo` fades that limb's weight to 0 over the seconds given, so the arm goes back to whatever its animation is
doing; `Grab` fades it back. `FadeWeight(value, seconds)` goes to any weight. `SetTarget(other, seconds)` moves the
hand to another target without a jump, for changing weapons. `IsHolding` and `Reach` (above 1: the target is out of
reach and the arm is straight) are there to read.

Keep the two arms in public `LimbIK` fields on your own component and drag each one in from the Inspector:

```beef
public LimbIK leftArm;
public LimbIK rightArm;
```

## Fingers

Add a **Hand Pose** to the hand bone (or put it anywhere and drag the hand into **Hand**).

- **Thumb, Index, Middle, Ring, Pinky**: 0 is straight, 1 is fully curled.
- **Spread**: above 0 fans the fingers apart, below 0 presses them together.
- **Trigger**: squeezes the index finger a little further, for pulling a trigger.
- **Shape** and the row of buttons: Open, Relaxed, Fist, Grip, Trigger, Point, Pinch, Thumbs Up. Picking one sets the
  sliders; moving a slider afterwards makes the shape Custom.

For a hand on a rifle, use **Trigger** on the firing hand and **Grip** on the other.

The fingers are found by name among the hand's children: thumb, index (or pointer), middle, ring, pinky (or little).
When no name matches, five children are taken as thumb to pinky in order and fewer as the fingers from the index
on. A child named only "finger" (POLYGON characters' middle, ring and little fingers, which are one chain) takes the
first free slot from the middle finger on. A finger is that child and the bones below it, up to four. The Inspector says what was found.

Which way to curl is worked out from the knuckles and the hand's side, read from its name (`hand_l`, `RightHand`,
`Hand.L`...); a hand whose name gives no side uses the thumb to tell the palm from the back of the hand. The
straight pose is the fingers' pose when the Hand Pose is added: add it with the fingers straight (Hand Posing's
**Pose Fingers** does this for you). If the fingers curl backwards, tick **Flip Curl**; if only the thumb is wrong,
**Flip Thumb**.

Curls are measured from the fingers' straight pose, which is remembered the first time the hand is found. If the
hand was not flat at that moment: set Weight to 0, straighten the fingers, and press **Use Current Pose As
Straight**.

From code:

```beef
hand.SetShape(.Grip);          // blended over Blend Time
hand.SetShape(.Open, 0.3f);    // or over the seconds given
hand.trigger = pull;           // 0 to 1, every frame
hand.Curl(1, 0.5f);            // one finger: 0 thumb ... 4 pinky
```

## Looking

**Look At IK**: drag the head into **Bone** and something into **Target**. **Bones** is how many bones share the
turn, counting the head and going up through its parents: 1 turns only the head, 3 brings the neck and chest with
it. **Max Angle** keeps the turn within that many degrees of where the animation has the head. **Forward** is the
direction of the head bone, in its own space, that the face looks along; change it if the head turns its ear to the
target. **Smooth** makes the gaze trail a moving target.

With no Target, `LookAt(point)` from code looks at a point in the world: where the camera is aiming, for an upper
body that follows the view.

## Feet on the ground

Add **Foot Placement** to the character's root, the object that moves over the ground. **Find Feet And Hips** fills
the fields in from the bones' names, or drag them in: the two feet, and the hips or pelvis bone. The legs are the two
bones above each foot.

While the game runs, each foot is set down on what is under it, the hips drop so that the lower foot can reach, and
with **Tilt** the feet lean with the slope (no more than **Max Tilt**). A foot the clip lifts for a step is still
lifted by the same amount. **Step Up** and **Step Down** are the highest and deepest steps the feet deal with.
**Smooth** is how quickly they settle.

The ground is found with the physics world, so it needs colliders. The character's own colliders are ignored. Set
**Ground Layer** to count only one layer as ground.

## Animating with IK in the editor

IK runs in the editor, so it can be used to make clips. For a humanoid, **Rig > Set Up IK Rig** in the Animation
window makes the targets, poles and components in one press, and the Scene view draws the targets as handles you can
click. **Hands** opens Hand Posing for the fingers. Both are described in `docs/retargeting.md`.

- **Animate the targets.** A target that is a child of the Animator's object is keyed like any other child: turn on
  Record, move the marker, move the target. The clip then moves the target and IK moves the arm, in the editor and
  in the game.
- **Bake the pose.** Pose the character with targets and Hand Pose, then press **Key IK** in the Animation window. It
  writes a key at the marker on every bone IK is moving, holding the pose IK gave it. The clip then plays that pose
  with no IK component needed.
- **Recording is not fooled by IK.** With Record or Auto Key on, a bone is only keyed when you move it by hand, not
  because IK is bending it.

## From code

The solver functions are in `IKSolver`, for anything the components do not cover. Call them from `LateUpdate`:

```beef
IKSolver.TwoBone(upper, middle, tip, targetPoint, usePole, polePoint);   // an arm or a leg
IKSolver.Chain(bones, tip, targetPoint);                                // a tail, a tentacle, a finger
IKSolver.LookAt(bones, localForward, targetPoint, weight, maxDegrees);  // a head and spine
IKSolver.FromTo(directionA, directionB);                                // the turn from one direction to another
```

`IKSystem.Solve(scene)` runs every IK component at once, if you need the result earlier than the end of the frame.

## Multiplayer

IK is worked out on each machine from what that machine has; no bones are sent.

- `LetGo`, `Grab` and `FadeWeight` on any IK component, and `SetShape` on a Hand Pose, are followed on every machine
  when called on the server or by the player who owns the object.
- A target moves on other machines if it is shared like any other object (a Network Identity on it or above it). A
  grip that is a child of a weapon follows the weapon.
- `SetTarget`, `LookAt(point)`, the finger sliders and `trigger` are not sent: set them on every machine, from state
  that is already shared (which weapon is equipped, where the player is aiming).
- Foot Placement uses the ground on each machine and needs nothing sent.

## Limits

- Limbs are two bones. Longer chains use `IKSolver.Chain` from code; there is no component for them yet.
- Limbs do not stretch, and bones have no joint limits: an elbow can be bent any way a target asks. Use a Pole to
  keep it sensible.
- Foot Placement does not plant feet against sliding, and the slope under a foot is estimated from three points.
- Hand Pose does not wrap fingers round a shape by itself: choose a shape, or set the curls.
- A rigged model with Expose Bones is skinned on the processor from its bone objects, as rigged models already are.
- Turning Expose Bones off does not delete the bone objects: delete them yourself.