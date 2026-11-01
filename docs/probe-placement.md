# Placing light and reflection probes automatically

Reflection probes (docs/reflections.md) and light probes (docs/baked-lighting.md) work best where they fit the scene: a reflection probe boxed to each room, closer light probes where light changes over a short way. **Place Probes** looks at the scene and puts them there for you. What it places are ordinary objects: keep them, move them, resize them or delete them.

## Placing

1. Open **Window > Lighting**. Under **Place Probes**, choose what to place (the settings are below).
2. Press **Preview Placement**. The editor looks at the scene in the background (a second or so for most scenes) and draws what it would place in the Scene view: reflection probes as blue boxes, with a cross where each sees from, light probe volumes as amber boxes. The window lists how many of each, and where it left probes out.
3. Press **Place** to make them, or **Discard**. Placing is one step of undo.
4. Press **Bake** to fill the light probe volumes. Reflection probes capture by themselves.

The probes go under a **Placed Probes** object, each tagged **Placed Probe**. Placing again takes away the probes with that tag and places new ones; nothing else in the scene is touched. To keep a placed probe when placing again, take the tag off it (in the Inspector). Where a probe or volume of your own (one without the tag) already covers a place, nothing is placed there. **Remove Placed Probes** takes them all away.

Placing also sets the scene's **Probe Spacing**, which is how far apart the scene's own light probes are in open space (above **Place Probes** in the window). The volumes add closer probes only where they are needed.

From the command line, `--place-probes` places them in the scene the editor opens, without a preview, and logs a `PLACE:` line; with `--bake-lighting` it places first, then bakes, and `--save-scene` saves the result.

## What goes where

| Where | Reflection probe | Light probe volume |
|---|---|---|
| A room (a covered place walled in on most sides) | one, boxed to its walls, with box projection, seeing from about eye height | one over the room |
| Under a roof with open sides (a porch, a canopy, under a bridge) | one, boxed to the roof, without box projection | one under the roof |
| A doorway or an opening from a room to the open | a small one across it, more important than the rooms' | (the rooms' volumes reach it) |
| A shiny floor in the open (a puddle, a polished plaza) | one over it, seeing from just above it | |
| Open ground with something standing on it | one for each square of **Open Probe Size**, without box projection | |
| Where light changes over a short way: by walls, at the edge of shadow, round a lamp | | volumes with probes **Detail Spacing** apart |
| Open space | | the scene's own grid, **Probe Spacing** apart |

Reflection probes are left out where nothing would mirror them: in a room with nothing metallic or smooth in it, the sky's reflection is close enough. (Turn **Only Where Something Is Shiny** off to place them everywhere.)

## Settings

| Setting | What it does |
|---|---|
| **Reflection Probes** | Whether to place reflection probes. |
| **Only Where Something Is Shiny** | Leaves out places where nothing is metallic (0.5 or more) or smoother than **Shiny Roughness**. Moving things count where they are. |
| **Doorways** | A small probe in each doorway and opening. |
| **Open Probe Size** | The squares, in metres, that open ground is split into, one probe each. |
| **Light Probe Volumes** | Whether to place light probe volumes. |
| **Detail Spacing** | How far apart a volume's probes are, in metres. |
| **Light Change / m** | How quickly light has to change, per metre, for a volume. Lower places more. |

All volumes together keep under 20,000 probes: when there would be more, the biggest volumes' probes are spread further apart.

## Light Probe Volumes

A **Light Probe Volume** (**GameObject > Light Probe Volume**) is a box of light probes closer together than the scene's grid. Placing makes them, and you can add your own.

| Setting | What it does |
|---|---|
| **Size** | The box, in metres (it scales with the object but does not turn with it). |
| **Spacing** | How far apart its probes are. Up to 64 along each side. |
| **Blend Distance** | How far inside its box its light fades in from the scene's grid round it. |

A moving thing (or anything without a lightmap) whose middle is in a volume's box takes its ambient light from that volume's probes, fading into the scene's grid towards the box's edges. Where boxes overlap, the smallest wins. Selecting a volume shows its probes as small crosses. Bake again after adding or changing one.

## How it works

`ProbePlacer` (`Engine/src/Lighting/ProbePlacer.bf`) copies the triangles of the scene's still, solid objects (Mesh Renderers that are not see-through and have no moving Rigidbody on them or above them) and traces rays in the light baker's BVH (`native/tallow_bake.cpp`).

1. **Cells.** The scene's box is cut into cells of half a metre (larger for big scenes, to keep under 400,000). Cells a triangle passes through are surfaces, and remember whether the surface is shiny and faces up.
2. **Looking round.** Each other cell sends 42 rays. If most hit the backs of faces, the cell is inside something solid. Otherwise it records how much sky it sees, how much of the way round it is walled in within 40 m, how far up and down the nearest surfaces are, and how much light reaches it: the sky's share plus each point and spot light in range that it can see. A cell with a surface within 6 m below it is somewhere things can be; one with a surface above it is covered.
3. **Places.** Each covered cell's distance to the nearest surface is worked out (a chamfer distance transform). Covered space is split into places with a watershed: from the most open cells inwards, level by level, each cell joins the place next to it. Where two places meet at a narrowing (a doorway is where the distance to the walls dips) they stay apart, and the cells where they met mark the doorway. Places that meet broadly are one. A place's box leaves out its outermost few cells (the doorway it reached into), and each side is moved out to the wall just beyond it with rays. A place is a room when most of its cells are walled in.
4. **Probes.** Reflection probes and volumes are made for each place, doorway, shiny floor and square of open ground as in the table above. Cells where light changes faster than **Light Change / m** (outside the rooms' volumes) are grouped into connected patches. A patch that fills too little of its box (a ring round a building) is split across its longest side until each piece fills its own. Each piece becomes a volume.

The light baker (`LightBaker`) bakes a grid for each Light Probe Volume beside the scene's own grid, all in the scene's `Probes.tprobes` file. When drawing, all the grids share one 3D texture; each draw gets its volume (picked once per draw by its middle) and the scene's grid, and blends them per pixel (`probeAmbient` in `include/lighting.sh`).

## Limits

- Rooms are boxes lined up with the world's axes: an L-shaped room gets one box round all of it, and a room turned at an angle a box round it. Split such rooms by hand, or add probes of your own there (placing leaves them alone).
- Voxel terrain, terrain, foliage and see-through objects are not looked at. Open ground made of them gets no probes from placing.
- One volume per draw: a thing whose middle is outside every volume is lit by the scene's grid alone.
- Light probes inside walls still take their neighbours' light (as in the scene's grid): keep walls thicker than Detail Spacing, or lower it, where light must not leak through.
- How fast light changes is judged from the sky and the point and spot lights before baking, not from bounced light.

## Tests