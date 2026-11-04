# Lines and trails

Two components draw flat strips, the way Unity's Line Renderer and Trail Renderer do:

- **Line Renderer**: a line through a list of points. Use it for aim guides, laser beams, cables and paths on a map.
- **Trail Renderer**: a trail through where its object has been in the last few seconds, thinning and fading towards the tail. Use it for rockets, sword swings and balls in flight.

Both turn to face the camera (Alignment **View**), so they always show their full width. Alignment **Transform Z** lays one flat instead: it faces along its object's forward axis, like a line painted on the ground. Turn the object to face up (rotation 90, 0, 0) for that.

Each draws through a hidden child object that holds its mesh. That object isn't saved and doesn't show in the Hierarchy. So a trail can go on a ball's own object without replacing the ball's mesh.

## Line Renderer

| Field | What it does |
|---|---|
| Use World Space | On: the points are in the world. Off: they are relative to the object, and the line moves and turns with it. |
| Loop | Joins the last point back to the first. |
| Start Width, End Width | Width at the first and last point, in metres. |
| Start Color, End Color | Colour at the first and last point, blended between. An alpha below 1 makes the line see-through. |
| Alignment | View or Transform Z (see above). |
| Texture Mode | Stretch: the texture runs once along the whole line. Tile: it repeats every metre, so dashes keep their size as the line grows. |
| Material, Texture | What to draw it with. With neither, it draws in its colours. |
| Unlit, Cast Shadows | Lines are unlit and cast no shadows by default. |
| Glow | Makes it glow in its own colours, through bloom. |
| Children As Points | Draws the line through the object's children, in order, instead of the points a script set. This is how to lay one out in the editor. |

Scripts set the points. These are not saved with the scene.

```beef
let line = GetComponent<LineRenderer>();
line.SetPositions(scope Vector3[](start, end));    // replaces every point
line.PositionCount = 3;                            // grows or shrinks the list
line.SetPosition(2, tip);
let length = line.Length;
```

A golf-style aim guide is a two-point line from the ball along where the camera faces, longer as the shot charges:

```beef
var direction = camera.Transform.Forward;
direction.y = 0;
direction = direction.Normalized;
let start = ball.Position + direction * (ballRadius + 0.05f);
aim.SetPositions(scope Vector3[](start, start + direction * Mathf.Lerp(0.5f, 3, power)));
aim.startColor = .(1, 1, 1);
aim.endColor = Color.Lerp(.(1, 1, 1, 0), .(1, 0.2f, 0.1f, 0), power);
```

For a dotted line, give it a dash texture and Texture Mode Tile.

## Trail Renderer

| Field | What it does |
|---|---|
| Time | How long a point stays in the trail, in seconds. |
| Min Vertex Distance | How far the object moves before the trail gets a new point. Smaller is smoother but costs more. |
| Start Width, End Width | Width at the object and at the tail. |
| Start Color, End Color | Colour at the object and at the tail. The default fades to fully see-through. |
| Emitting | Off: no new points are added and the trail fades away. It starts again when turned back on. |
| Show In Editor | Also draws in the editor while not playing. |
| Alignment, Texture Mode, Material, Texture, Unlit, Cast Shadows, Glow | As for Line Renderer. |

Call `Clear()` after a teleport or respawn so the trail doesn't streak across the level. `PositionCount` and `GetPosition(i)` (oldest first) read the trail's current points.

## Limits

- Facing follows one viewer each frame: the game's camera, or the Scene view while editing. In the editor while playing, lines face the game camera, so in the Scene view they can look edge-on.
- Sharp corners narrow a little, because there are no extra corner vertices. There are no rounded end caps.
- A line or trail with any alpha below 1 is drawn see-through, after everything solid.
- Each is rebuilt on the CPU every frame. Hundreds of points are fine; tens of thousands are not.
