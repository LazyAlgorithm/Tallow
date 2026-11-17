# Buildings

The Building tools block out buildings with their rooms, the quick way: drag rooms out on a grid and the walls build
themselves, click doors and windows onto walls and they are cut out of them, add storeys and stairs between them. A
building is an ordinary object, drawn, solid (its Mesh Collider) and saved with the scene, and can be turned into an
ordinary model at any time to shape further with the [modeller](modeling.md).

## Making one

**GameObject > Building**, **Building** on the Scene view's bar (it is there with a model selected or the Model window
open), or **New Building** on the Model window's **Building** tab. The building is put on the ground where the Scene
view is looking, selected, with the **Room** tool on.

With a building selected, its bar is over the Scene view and the Model window shows its **Building** tab. Both have
the same tools, and a line at the bottom of the view says what the mouse does at that moment.

## Tools

| Tool | Key | What it does |
|---|---|---|
| **Room** | 1 | Drag out a room on the grid. Walls go round it, with one wall between rooms that touch. **Shift**+drag adds squares to the picked room (an L-shaped room, or an open plan with no wall). A click on a room picks it; a right-click removes it. |
| **Erase** | 2 | Drag over squares to take them out of the rooms. The walls close up round what is left. |
| **Door** | 3 | Click a wall to put a door in it. Point at a door to see it outlined; click it to pick it and drag it along the wall (or onto another wall); right-click or Delete removes it. |
| **Window** | 4 | The same for windows, which sit on a sill above the floor. |
| **Opening** | 5 | The same for a wide gap with no door: an archway between two rooms. |
| **Stairs** | 6 | Drag from the foot of the stairs towards the top (at least two squares long). They climb to the storey above and cut a hole in its floor. Right-click stairs to remove them. |

The keys work while a tool is on; **Esc** (or **Done**) goes back to picking and moving objects. Doors and windows
snap along the wall every half square (hold **Alt** not to) and are kept clear of corners and walls that meet theirs;
a wall too short for one says so. Their sizes are set on the Building tab before they are put in, and a picked one's
width, height and sill can be changed there afterwards.

Every change is one step of the scene's undo.

## Storeys

The arrows beside the storey's name (**Ground Floor**, **Floor 1**...) go down and up. One above the top storey
starts a new one: the storey below is drawn as a blue outline to line its rooms up with. Each storey's floor is the
ceiling of the one below; where nothing is above a room, it has a roof.

## Seeing inside

While a building is selected, the Scene view cuts it away so its rooms can be seen into. The button on the bar
switches between:

- **See All**: the whole building.
- **Cut Away**: the storeys above the one being worked on, and its ceiling, are hidden.
- **Low Walls**: the same, and its walls are cut low, to see the whole plan from above.

Only the Scene view is affected: the game, the Game view and the building's collider always have the whole building.

## The Building tab

- **Storey**: the storey worked on, and what is shown.
- **Tools**: as on the bar.
- **Picked Door / Window**, or the sizes new ones get.
- **Rooms** of this storey: each room's colour (its floor's, with **Room colours on floors** on), and for the picked
  room its name and a button that removes it.
- **Building**: the height of a storey, the thickness of walls and floors, and the grid's square size (changing it
  scales the whole plan). The same settings, and the wall, floor, ceiling and roof colours, are in the Inspector on
  the **Building** component.
- **Bake to Model** keeps the walls as an ordinary model and drops the plan, to shape it with the model tools. After
  that the Building tools no longer work on it.

## How it is made

The **Building** component keeps the plan as text: rooms (each on one storey, made of grid rectangles laid in
order, so a later one paints over an earlier one), doors and windows (on a grid line, with a middle, width, height
and sill) and stairs. Whenever the plan or a setting changes, the walls are made again into the object's **Model
Mesh**:

- a wall wherever two different rooms, or a room and the outside, meet on the grid, centred on the line between them;
  a post where walls meet, turn or end, and straight pieces between posts;
- holes for the doors, windows and openings, leaving the wall under a window and over a door;
- one slab at each storey's level: the floor of the rooms on it (in their colours), the ceiling of the rooms below
  and the roof over rooms with nothing above, with a hole over stairs;
- stairs as solid steps about 19 cm high.

Faces have Auto texture coordinates, a metre to a repeat, so a material put on the Mesh Renderer tiles evenly.
Changing the building's settings from game code (C# `Building`) changes the values only; the walls are made in the
editor.
