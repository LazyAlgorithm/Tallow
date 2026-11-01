# Modelling

Tallow has a modeller built into the editor, for low-poly props and for blocking out maps. Shapes are drawn straight
into the Scene view, then pushed, cut and bevelled in an edit mode, given materials, colours and texture coordinates,
and saved with the scene. Nothing has to leave the engine, but a model can be exported as `.glb` for Blender or other
tools.

Open **Window > Model** (or **GameObject > Model...**). It opens as a tab beside the Inspector; drag the tab to move it.

## Drawing shapes

Pick a shape at the top of the Model window: Box, Ramp, Stairs, Cylinder, Cone, Sphere, Torus, Arch, Plane, Prism,
Pipe or Corner Wall. Some take extra settings (sides, steps or rings, wall thickness, smooth).

- **Draw in Scene**: click on the ground or a surface and drag out the base, let go, move the pointer up for the
  height and click. A click without a drag puts down a shape of the Size in the window. Snapping (the toolbar's Snap,
  or Ctrl held) snaps the base and the height to the move step. Hold Shift on the last click to keep drawing; Escape
  stops.
- **Add in View** puts one of the window's Size where the Scene view is looking.

A drawn shape is an object with a **Mesh Renderer**, a **Model Mesh** (which holds the model) and a **Mesh
Collider**, so it is solid at once. Its origin is in the middle of its base.

Any object with an ordinary mesh can be turned into a model with **Make Editable Model** in the Model window.

## Edit mode

Select a model and press **Tab** over the Scene view (or tick **Edit Model**). The model's edges are drawn over it
(seams red, hard edges blue), and clicking picks parts of it instead of objects. The top left of the Scene view says
what is picked and which tool is running.

Almost everything has a key, and nothing needs the Model window:

- **Right-click** (without dragging) opens a menu of every tool for what is picked, with its key.
- **Space** finds a tool by name: type part of it and press Enter.
- **F1** opens a sheet of every shortcut, in a window that can be moved aside.
- **/** (or **Show only this model while editing** in the Model window) hides every other object's mesh in the Scene
  view while you edit, as the rigger does, so the model is easy to see and pick. It is on unless you turn it off, and
  remembered. The Game view and play mode are never affected.

While one model is shown on its own, only its gizmos are drawn too.

### Views

The **view selector** in the Scene view's top right corner works as Unity's: the X (red), Y (green) and Z (blue)
balls and their grey opposites show how the view is turned; click one to look at the scene from that side (the
front, back, left, right, top or below), about the selected object. Click the square in the middle, or the name under
it (Front, Top, Persp, Iso...), to switch between perspective and orthographic (no perspective, for lining things up).
Looking round with the right mouse button goes back to perspective. In an orthographic view the wheel zooms and the
middle button pans.

**Window > Model Views** (or **Open Model Views** in the Model window) is a window of four views, as 3ds Max has:
Top, Front and Left (orthographic) and Perspective. Each view's bar picks what it shows, **Frame** shows the selected
object in it, **Frame All** in all four, and **Fill Window** (or a double-click on the bar) gives it the whole window
(**Four Views** goes back). Everything you do with a model in the Scene view works in them: picking, edit mode and
every tool, keys and gizmos. The view the pointer was last over has the mouse (outlined); the others follow along.
In the orthographic views the middle button pans and the wheel zooms about the pointer; the Perspective view moves as
the Scene view does. The Scene view still works as before.

### Reference images

**Reference Images** in the Model window stands pictures of what you are making behind the model, square to a view:
a car's side in the Left view, its front in the Front view, its plan in the Top view. Pick the view, drag an image from
the Project window onto the picture field and press **Add Reference Image**. It is centred on the selected object and
as wide as it to start; **Middle**, **Width** (its height follows the picture), **Behind** (how far behind the middle it
stands, so the model is in front of it) and **Opacity** move and size it, the tick hides it, **Middle at Selection**
puts it back behind the selected object. Reference images are drawn only in the editor's views (never in the game or
the Game view), cannot be clicked, and are not saved in the scene: they are kept for the project with your editor
settings.

Every key can be changed in **Edit > Preferences > Modelling**: click a key and press the new one (with Ctrl, Shift or
Alt), **+** adds another key for the same action, **x** removes one, **Reset All** goes back to these. A key used by
two actions that could run at once is marked, with the other action named when you point at it (two that never apply
together, such as Merge for vertices and Collapse for edges on **M**, may share one). The window's buttons, menus, the
F1 sheet and the Scene view's hints show the keys you chose. Only the changes are saved, in `model_shortcuts.txt`
with the editor's other settings, so they are yours on this machine and not part of a project. The keys below are the
defaults.

### Picking

| | |
|---|---|
| **1**, **2**, **3** | Vertices, edges, faces |
| Click, Shift+click | Pick one, add or take one away |
| Drag, Ctrl+drag | Box: pick everything inside (only what can be seen, unless x-ray is on); Ctrl takes away |
| Alt+click | A loop: the vertices or edges along an edge loop, or (faces) the strip of faces across the edge |
| Ctrl+click | The shortest path from the last thing picked |
| **A**, **Alt+A**, **Ctrl+A** | All, none, toggle |
| **Ctrl+I** | Invert |
| **Ctrl+=**, **Ctrl+-** | Grow, shrink by one ring |
| **L** | Everything joined to what is picked |
| **H**, **Shift+H**, **Alt+H** | Hide the picked faces, hide the others, show them all again |
| **Home** | Point the camera at what is picked |

Hidden faces are not drawn or picked while editing (for working inside a model); they come back on leaving edit
mode. The selection is drawn in orange, thick, with a dot in the middle of each picked face; the last thing picked
is lighter, and what is under the pointer is lit blue. Parts behind the model are drawn faint.

### Tools that follow the pointer

Press the key, move the pointer, then click or press **Enter** to keep the change; **Escape** or a right-click puts
it back. While one runs:

- **X**, **Y**, **Z** hold it to an axis (press again for the model's own axis, a third time to free it);
  **Shift+X** etc. hold it to the plane across the axis.
- Typing a number gives the amount exactly (**-** turns the sign, Backspace takes a digit off): **G Z 2 Enter**
  moves 2 m up, **S X 0 Enter** flattens the selection, **R Y 90 Enter** turns it a quarter turn.
- Ctrl snaps to the toolbar's steps.

| | |
|---|---|
| **G**, **R**, **S** | Grab (move), rotate, scale |
| **G G** | Slide: G again while grabbing slides the picked edges along the faces beside them (a loop moves up or down its strip without changing the shape); in vertex mode, it slides vertices |
| **Shift+V** | Slide vertices: each picked vertex moves along whichever of its edges points most the way the pointer goes |
| **E** | Extrude: faces along their normal (E again: each face on its own), edges and vertices pulled out as new faces |
| **Alt+E** | Extrude each face on its own |
| **I** | Inset faces (I again: each face on its own) |
| **Ctrl+B** | Bevel the picked edges (or the edges of the picked faces or between the picked vertices); the wheel adds segments, which round the bevel off |
| **Ctrl+R** | Loop cut: point at an edge to see the cut round the strip of quads, the wheel or + and - set how many cuts, click to cut; a single cut then slides along until the next click |
| **K** | Knife: click points on edges, corners or inside faces, Enter or Space cuts; the cut goes through every edge the line crosses on the way, and bends at points inside a face. A cut must start and end on an edge or corner. Backspace takes the last point off |
| **Shift+D**, **Ctrl+D** | Copy the picked faces and move the copy |

The move handles (W) work too, with Shift as a move starts extruding faces or pulling open edges out.

**Proportional editing** (**O**, or in the Model window) makes nearby vertices that are not picked follow a move,
less the further they are; the wheel changes how far it reaches while a move runs. **Mirror edits X/Y/Z** (Model
window or the right-click menu's Options) moves the matching vertices on the other side of the model's origin too,
and keeps vertices on the middle line on it: model one half of something symmetrical and the other follows.

### Other keys

| | |
|---|---|
| **F** | Make a face from the picked vertices, or fill the hole round the picked edges |
| **J** | Connect two vertices of a face (cut it between them) |
| **M** | Merge vertices at their centre; collapse edges or faces to a point |
| **X**, **Delete** | Delete |
| **P** | Make the picked faces an object of their own |
| **Ctrl+T**, **Alt+J** | Triangulate; join triangles back into quads where they lie flat together |
| **Alt+N**, **Ctrl+N** | Flip the picked faces; make every face point outwards |
| **Shift+A** | Add a shape into the model (where the selection is); over the Scene view outside edit mode, add one as an object |

Every change is one step of the scene's undo (Ctrl+Z).

### Faces

**Extrude** pushes faces out along their normals by the Distance (negative pushes in); faces side by side move as one
block, **Extrude Each** moves each on its own. **Inset Each** / **Inset Together** shrink faces inwards leaving a ring
of faces round them. **Subdivide** cuts each face into four-sided faces; **Smooth Subdivide** also rounds the shape
off (Catmull-Clark). **Poke** puts a vertex in the middle of each face and makes a fan of triangles round it.
**Triangulate** and **Tris to Quads** go to triangles and back. **Solidify** gives faces a thickness (a plane becomes
a slab, an open shell a solid one). **Flip** turns faces round. **Detach** gives the faces vertices of their own so
they come away from the rest; **Make Separate Object** moves them into a new object. **Smooth Shading** / **Flat
Shading** choose how light falls across them. **Same Material** picks the faces in the same slots.

### Edges

**Bevel** cuts edges off with a flat face of the Width given, filling the corners where bevelled edges meet. With
more than one **Segment** the bevel is rounded: a strip of smooth faces curving round from one face to the other,
and smooth rounded corners where bevels meet. **Slide** moves the picked edges along the faces beside them. **Loop
Cut** cuts loops round a strip of four-sided faces through the picked edge (Cuts evenly spaced). **Select Loop** and
**Select Ring** pick the loop through an edge or the ring across it. **Bridge** joins two open chains of edges (with
the same number of edges) with faces; **Fill Hole** closes a loop of open edges with a face. **Split in Middle** puts a
vertex in the middle of each edge. **Dissolve** removes edges, joining the faces either side; **Collapse** joins each
edge's ends into one vertex. **Mark Seam** and **Hard Edge** mark edges for unwrapping and for shading (smooth faces do
not blend across a hard edge). **Select Sharp** picks the edges where the faces turn more than the angle.

### Vertices

**Slide** moves vertices along their own edges. **Merge at Centre** joins the picked vertices into one. **Weld** joins those closer than the distance. **Connect** cuts
a face between two of its corners. **Make Face** makes a face from three or more vertices. **Smooth** moves vertices
towards the average of their neighbours. **Put Object Origin Here** moves the object's origin to a vertex without
moving the model.

### The whole model

**Mirror X/Y/Z** copies the model across its origin and joins the halves (model one half of something symmetrical
with its middle on the origin, then mirror). **Array** repeats it, each copy moved by the Step. **Fix Normals** makes
every face point outwards. **Origin to Centre** / **Origin to Base** move the object's origin. **Join Flat Faces**
joins neighbouring faces that lie flat together. The window warns when a model is not closed (has holes).

### Booleans

Pick another object under **Boolean with another object**, then **Join**, **Cut out** or **Overlap** and **Apply
Boolean**. Cut out is how doors and windows go into walls: draw a box where the opening should be and cut it out of
the wall. The other object is removed unless **Keep the other object** is ticked. Both should be closed solids. The
other object can be any mesh, not only a model.

## Materials and colours

Every face has a material slot. Slot 0 uses the Mesh Renderer's material; slots 1, 2 and up use the materials listed
in **Model Mesh > Materials**, separated by `;`. Pick faces, set **Material slot** and press **Set**.

Faces have vertex colours, which multiply the material's colour and texture. **Colour Faces** colours the picked
faces. **Paint vertex colours** turns the pointer into a brush: drag over the model to paint (Radius and Strength set
the brush); Shift paints whole faces flat.

## Texture coordinates

New faces have **Auto** coordinates: the texture is laid on from the side each face looks at most, once a metre in
the world, so it stays the same size however a shape is stretched (with **World Scale UVs** on the Model Mesh; off, it
stretches with the object). With faces picked, **Texture on these faces** sets their metres a repeat, offset and turn.

The tools under **Texture coordinates** work on the picked faces, or on every face with none picked:

- **Auto (world)**: back to Auto.
- **Box**, **Planar**, **Cylinder**, **Sphere**: projections.
- **Unwrap at Seams**: each piece between seams is laid flat with as little stretching as possible (a conformal map)
  and the pieces are packed into the picture.
- **Smart Unwrap**: finds its own pieces (faces turned less than the Angle limit from each other) and packs them. Good
  for hard-edged low-poly models.
- **Pack**: packs the pieces as they are, at the same texture density.

The **UV Editor** (button, or **Window > UV Editor**) shows the coordinates over the model's texture (or a checker
without one), with how much of the picture is used twice (overlap) and the worst stretching:

- **Pieces** or **Points**: a click picks the piece under the pointer (faces joined in the picture) or one point
  (every corner of that vertex there). Shift+click adds or takes away; dragging on empty space draws a box. **All**
  and **None** pick everything or nothing.
- Dragging something picked moves what is picked; **Turn 90**, **Flip U/V**, **Bigger**, **Smaller** and **Fit** work
  on what is picked (or everything shown).
- **Pin** keeps the picked points where they are: **Unwrap** (here, or in the Model window) lays the rest of their
  piece flat round them and leaves pinned pieces where they are instead of packing them. Two or more pins hold a
  piece's size and turn too; one only holds its place. Pins are drawn red and saved with the model. **Unpin** frees
  them.
- **Stitch** joins pieces picked together: each is turned, scaled and moved so that it meets the piece picked first
  along the edges they share on the model, and the seams between them go.

### Palettes and atlases

Low-poly models are often coloured from a small palette picture, each face taking one colour. **New Palette Texture**
writes `Textures/<object>_palette.png` (64 colours) and gives it to the model. Tick **Palette grid** to lay the cells
over the picture (set the columns and rows for a picture of your own, such as an atlas), then pick pieces (or faces in
the Scene view) and **Ctrl+click** a cell: their coordinates go into it. **fill** sets how much of the cell they take:
0 puts every corner on the cell's middle for a flat colour; more keeps their shape, for an atlas.

## Painting textures

Tick **Paint** and pick **Texture** to paint the model's picture straight onto it in the Scene view. A model without a
texture gets one from **New Paint Texture** (`Textures/<object>_paint.png`, white, of the size given), and is unwrapped
first if its faces share parts of the picture (paint would show in two places). Then:

- Drag to paint, with the Colour, Radius (in metres on the model), Strength and Hardness (how soft the brush's edge
  is). Strokes run on across seams: the brush paints wherever it lies on the model, whichever part of the picture
  that is.
- **Shift+click** fills the face under the pointer; **Fill Picked Faces** fills the faces picked before painting.
- **Alt+click** picks up the colour under the pointer.
- Each stroke is written to the PNG when it ends, so other tools see it. **Undo Stroke** takes strokes back (the last
  16); the scene's undo does not, since the picture is a file of its own.

The painted picture is used however the model is drawn: by the Mesh Renderer, or by its material when that names the
picture.

## Levels of detail

**Make Levels of Detail** (Model window, outside edit mode) adds children named `<object>_LOD1` and on, each a copy of
the model with fewer faces (**Level n keeps** sets the share of triangles), and a **LOD Group** that draws the model
itself up close and the copies further away (docs/lod.md). Faces are taken away where the model is flattest first;
open borders stay where they are. The copies are models too, so they can be touched up by hand. After changing the
model, make them again: the old ones are replaced.

## Saving and exporting

The model is kept in the scene, inside its Model Mesh, so saving the scene saves it, and prefabs and duplicates carry
it. Objects with the same model share one mesh and are drawn together.

**Save as a file** writes it out:

- `.tmesh`, the engine's own text format, which keeps everything (faces, seams, hard edges, slots, Auto settings). A
  Mesh Renderer can name a `.tmesh` as its mesh like any model, and `file.tmesh#2` draws only material slot 2.
- `.glb`, binary glTF, with one material per slot, vertex colours and texture coordinates, for other tools.

## From code

The modeller's core is in the engine (`Engine/src/Modeling`), so games can build models while running:

```beef
let shape = MeshShapes.Create(.Stairs, .() { size = .(2, 1.5f, 3), steps = 8 });
defer delete shape;
var top = 0;  // pick faces by index, e.g. the one facing up
MeshOps.ExtrudeFaces(shape, .(&top, 1), 0.5f);
gameObject.AddComponent<MeshRenderer>().mesh.Clear();
gameObject.AddComponent<ModelMesh>().Set(shape);
```

`EditMesh` holds the faces, `MeshOps` the edits (and `MeshTools.bf` more of them: triangulate, poke, solidify,
smooth, collapse, make face, knife; `MeshSlide.bf` sliding; `MeshDecimate.bf` taking faces away), `MeshCsg` the
booleans, `MeshUV` the unwrapping, pins, stitching and palette cells, `TexturePaint` painting pictures,
`GlbWriter` the export. Faces wind clockwise seen from the front (as everywhere in the engine).

## Tests

`Tests/Modeling` checks every shape is closed and faces outwards, the text format, extrude, inset, bevel, loop cuts,
subdivision, mirror, array, bridge and fill, welding, booleans (volumes), unwrapping (no overlap, little stretch), the
`.glb` and `.tmesh` files, triangulating and back, poke, solidify, smoothing, collapsing, making a face and the knife
(across a face, round a corner and through a point inside a face), round bevels, edge and vertex sliding, pins
(in the text and when unwrapping), stitching, palette cells, painting and filling a picture, palette pictures and
decimation (closed, about the share asked for). The editor switch `--model-test` draws, edits, undoes, cuts and exports models in
the Scene view, runs the pointer tools with typed amounts (grab, cancel, extrude, inset, rotate, scale, mirrored and
proportional moves), the shortcut commands and hiding, round bevels, sliding, the knife inside a face, UV picking,
texture painting (written to the file and drawn) and levels of detail, and logs `MODEL-TEST PASS` or `FAIL`; with it,
`--model-help` shows the shortcut sheet, `--model-menu` opens the right-click menu and `--model-round` adds a box
bevelled round for the screenshot. `--model-window` opens the Model window and `--uv-editor` the UV Editor.

## Networking

Models are scene data: a Model Mesh's faces are saved in the scene, so every machine that loads the scene has the
same model, and painted pictures are files like any other texture. Nothing is sent while playing; games that build
models at run time from code do so on each machine (or send the `.tmesh` text themselves).

## Not done yet

- Painting layers, brushes with a picture, and painting normal or roughness maps (painting is one colour picture).
- Bevel profiles other than round (the curve is fixed), and a vertex-only bevel.
- Moving, turning or scaling with keys in the UV Editor (it uses the mouse and its buttons).
