# Rigging and weight painting

**Window > Rigging** turns a still model into a rigged one that a Skinned Mesh Renderer can animate, the way Mixamo does: place a few markers on the model, and the skeleton and skin weights are made for you. It also works for four-legged animals (cats, dogs, horses...) and for anything else, with bones you place yourself.

A person gets **Mixamo's bone names** (`Hips`, `Spine`, `LeftArm`, `LeftForeArm`, `LeftHand`, ...), so animations made for Mixamo characters play on it straight away, and it is recognised as a humanoid for retargeting (docs/retargeting.md).

## Rigging a model

1. Select an object that shows the model: a Mesh Renderer with a `.glb` or `.gltf`, or an editable model from the Model window (written out as `Models/<name>.glb` first). Rigging an object that already plays a `_Rigged.glb` made here picks up its still model again.
2. Open the **Rigging** tab (beside the Inspector; **Window > Rigging** brings it back if closed, and the editor reopens whichever windows were open last time) and press **Rig**. The model is shown on its own (untick **Show the model on its own** to see the scene round it), and the camera turns to face it: a person from the front, an animal from its side. **Front View** / **Side View** turns it back.
3. Work through the four steps at the top of the window.

### 1. Markers

The template is guessed from the model's shape (longer than it is tall: a four-legged animal). Change it if the guess is wrong:

| Template | Markers | Skeleton |
|---|---|---|
| **Humanoid** | Chin, Groin, Wrists, Elbows, Knees, and the tip of each finger (Thumb, Index, Middle, Ring, Pinky) | Mixamo's: hips, 1 to 3 spine bones, neck, head, shoulders, arms, legs, feet and toes, and the fingers (all five, thumb and mitten, or none: 65, 41 or 25 bones) |
| **Quadruped** | Nose, Head (where the neck meets the skull, under the ears), Neck, Tail Base, Tail Tip, Front and Back Paws, Elbows, Hocks, Ear Tips | Root, spine, chest, neck, head, jaw, ears, tail, and for each leg a shoulder blade (or thigh), upper leg, lower leg, wrist (or hock) and paw. Spine, neck and tail lengths, ears and jaw are settings |
| **Custom** | none | Bones you place yourself (step 2) |

Drag the markers onto the model in the Scene view; the skeleton follows as you drag. Hover a marker for a hint about where it goes (for example "the back of the knee, where the leg bends"). With **Symmetry** on, moving a left marker moves the right one too. With **Centre markers in the body when let go** on, a marker you let go is moved to the middle of the part it is on, along the way the camera looks, so markers placed on a flat front view end up inside the limb, as Mixamo's do. Paws, the nose, the tail tip, ear tips and fingertips stay on the surface.

Click a marker's name in the list to bring the camera close to it. Fingertip markers are drawn small and named only when you point at one; zoom in on a hand to place them. Each finger's bones run from its knuckle to its tip marker (the thumb's knuckle near the wrist), so moving a tip moves the whole finger. The fingertips are guessed from the hand's shape beyond the wrist: the thumb is the point sticking out furthest to the front, and the four fingers are the ends of four strips across the hand, from the first finger at the front to the little finger at the back.

An animal's head turns about its **Head** marker, so a long snout or a nose moved far out only makes the head longer; the ears and jaw hang from it. The neck's base is guessed over the front legs and the tail's base where the thin tail meets the rump, and the tail tip is followed to its end, even when the tail curls up over the back.

**Faces** says which way the model's front is (glTF's front is -Z). It is guessed from the feet for a person and from the longest side for an animal. **Guess Markers Again** starts over.

**Build Skeleton and Weights** goes on to step 3 with weights made.

### 2. Bones

Click a joint to pick its bone, and move it with the gizmo. The list shows every bone under its parent.

- **Symmetry** moves the bone on the other side too. **Move children** brings the bones below along.
- **Name**, **Joint** (its place) and **Bends the mesh** (bones that only hold others, like the ends of fingers, do not take weights).
- **Add Child Bone** and **Delete Bone** (its weight goes to its parent, and its children join the parent). **Shift+click** the model to add a bone there, joined to the picked one.
- **Mirror to the Other Side** copies this side's bones to the other side, making any that are missing (`Left...` to `Right...`, `_L` to `_R`, `.L` to `.R`).

Moving bones after the weights were made says so; **Make Weights Again** brings them up to date.

### 3. Weights

**Automatic weights** use "bone heat", as Blender and Mixamo do: each bone warms the parts of the model it is nearest to and can see (no part of the model in between, so an arm does not move the side it hangs beside), and the warmth spreads over the surface, so weights fall off smoothly across joints. Vertices in the same place (seams where a texture is cut) are weighed as one, so seams never tear. Each vertex keeps its four strongest bones, adding up to 1.

Then paint them. The model is coloured by the picked bone's weight, from blue (none) through green and yellow to red (all). **Show** can colour every bone in its own colour instead.

| Brush | Does |
|---|---|
| **Add** | Gives the picked bone more of each vertex under the brush (the others give it up in proportion) |
| **Subtract** | Takes it away; the other bones there take it up (the bone's parent, where it was the only one) |
| **Smooth** | Evens weights out with the vertices round them |
| **Set to value** | Sets the picked bone's share to **Value** |

**Size** and **Strength** set the brush. **Ctrl+click** the model picks the bone that moves that spot most. **Mirror** paints the other side too (the window says how much of the model has a mirror image). **Flex while painting** swings the bones while you paint, to see the result at once. **Smooth All**, **Clean Up** (four bones each, none under 1%), **Mirror Left to Right** / **Right to Left** and **Make Weights Again** work on the whole model. **Ctrl+Z** undoes each stroke and change.

### 4. Pose

Click a joint and turn it with the rotate gizmo (or type its **Turn**) to see how the model bends. **Flex every bone** swings them all. Poses are only for trying and are not saved; **Reset Pose** puts the model back.

## Saving

- **Export Rigged Model** writes `<model>_Rigged.glb` beside the model: the model with its materials and textures, the skeleton, and the weights. Every skeleton made here faces the same way at rest (its top bone turns it to face the way the model does), so a clip made on one rigged person or animal plays the same on any other made here: people through their Mixamo bone names (and any other humanoid through retargeting, docs/retargeting.md), animals by their shared bone names (bones one animal has and another lacks, such as extra tail bones, stay at rest). Change the name in **Rigged model** to write it somewhere else.
- **Export and Use on This Object** also gives the object a Skinned Mesh Renderer playing it and an Animator, with **Expose Bones** on, so the bones are objects under it in the Hierarchy and Inspector, ready to pose, key in the Animation window, curl with Hand Posing (the Animation window's **Hands**) and drive with IK. Give that a **Clip**, or a **Clip Library** of animations made for the same bones (Mixamo's, for a person), to see it move.

The rig itself (template, settings, markers, bones and painted weights) is kept beside the model as `<model>.trig`, saved when you stop rigging or close the editor, so it can be picked up again. If the model changes, the rig keeps its markers and bones and says to make the weights again.

## From code

The rigger is in the engine (`Engine/src/Rigging/`), so tools and tests can use it without the editor:

```beef
let rig = scope Rig();
let problem = scope String();
if (!rig.LoadSource("Models/Wolf.glb", problem))
	Log.Error(problem);
rig.template = RigTemplates.GuessTemplate(rig);
RigTemplates.GuessMarkers(rig);
let triangles = scope List<uint32>();
rig.Triangles(triangles);
let rays = scope RigRays(rig.positions, triangles);
RigTemplates.CentreMarkers(rig, rays);
RigTemplates.Build(rig);
AutoWeights.Make(rig);
RigExport.Write(rig, "Models/Wolf_Rigged.glb", problem);
rig.Save("Models/Wolf.trig");
```

`WeightPainter` paints (`Dab`, `SmoothAll`, `MirrorWeights`), `WeightTools` normalises and limits weights, and `Rig.Posed` skins the model in a pose. The heat solve runs in the native library (`native/tallow_rig.cpp`), on every core.

## Checks

- `Tests/Rigging` (`BeefBuild -config=Debug -run` there) builds a person and a dog from tubes (and reads the Sandbox's real person, for its hands) and checks the guesses, the skeletons, the weights (smooth across joints, no tearing at seams, the same every run), posing, painting, mirroring, the `.trig` file, and that the exported model loads as a rigged model with the right bones (the person as a humanoid).
- The editor's `--rigger-test` rigs the Sandbox's **Rig Test Person**, **Rig Test Dog** and **Rig Test Pug** (free CC0 models by Quaternius, in `Samples/Sandbox/src/Models/Rigging`, see the LICENSE.txt there) from start to finish and prints `RIG TEST PASSED`.
- `--rigger "<object>"` starts rigging an object, `--rigger-step markers|bones|weights|pose` opens a step and `--rigger-look "<marker>"` brings the camera to a marker (with `--screenshot`, to look at it). `--reset-layout` does what Window > Reset Layout does.
