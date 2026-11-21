# World text

The World Text component puts text in the world, in either of two ways:

- **World** mode: letters in the scene, drawn like a mesh, so walls hide them and they get smaller with distance. Use it for signs over a door, names floating over a character, labels on a wall, a "Night 1" title marking a place. With **Depth** they are solid, with fronts, backs and walls: a real 3D model of the words.
- **Screen** mode: a name tag. A point in the world with text drawn flat on the screen at a size in pixels: always readable, over the scene and under the game's own interface. Use it for player names, damage numbers, markers and quest markers.

Add it with **Add Component > Rendering > World Text**.

## Fonts

With Font empty, text is drawn in the engine's own font: Roboto, the same font the interface uses, so labels match menus. To use another face, put a `.ttf` or `.otf` file in the project and type its path (or drop it on the field). Every size of every font is rasterized at the size it is drawn, so text stays sharp close up.

World text can use lines: put `\n` between them in the Inspector's text box (or in a scene file as `\n` in the quoted text; a script sets them with a C# string, `"Line one\nLine two"`). Each line is laid out and aligned like the block.

## Fields

| Field | What it does |
|---|---|
| Text | The words. The Inspector's box takes several lines. |
| Font | A `.ttf` or `.otf` in the project. Empty: the engine's own font (Roboto). |
| Mode | **World**: letters in the scene. **Screen**: a name tag drawn on the screen. |
| Color | The text's colour. An alpha below 1 makes it see-through. |
| Size | How big: the height of a line in metres in the scene, or the font size in screen pixels on the screen. |
| Depth | How far the letters stick out, in metres: 0 keeps them flat, as paper; anything more makes solid letters with faces, backs and side walls, a full 3D model. The depth is centred on the object's position, so the front is half the depth towards the viewer. Screen labels stay flat. |
| Alignment | Which part of the text sits on the object's position: Left, Center or Right. Lines align with it inside the block too. |
| Double Sided | Draws the backs of the letters too. Off: only from the front, like a sign on a wall (the front faces the way -Z does, so a camera in front of an object with no rotation reads it). |
| Unlit | On: drawn in its own colour, whatever the lights do. Off: takes the scene's light like a painted sign. |
| Glow | Adds the text's own colour to the glow through bloom. 0 is none. |
| Cast Shadows | Whether scene text casts a shadow. Solid letters can; flat text rarely looks right. |
| Facing | **Transform**: follows the object's rotation. **Camera**: turns about its up axis to face the viewer, like a name plate. |
| Pixel Density | Advanced. Texture pixels per metre of scene text. Higher is sharper close up and uses more memory per label. |
| Show In Editor | Whether scene text is drawn in the editor while not playing. |
| Screen Offset | A name tag's position on the screen, in pixels, from where its object is (positive x right, positive y down). |
| Max Distance | A name tag's furthest distance in metres (0: no limit). Past it the label is not drawn. |
| Shadow | A name tag's dark shadow, so it stays readable over bright scenery. |

Scene text draws through a hidden child object that holds its quad and texture, like a line's strip: it is not saved with the scene and does not show in the Hierarchy. A name tag draws nothing at all until the game or the editor's Game view calls `GUI.Run`, so it does not show in the Scene view.

## Scripts

```csharp
GameObject sign = Scene.CreateGameObject("Sign");
sign.Transform.Position = new Vector3(4, 2, 10);
WorldText label = sign.AddComponent<WorldText>();
label.Text = "Night 1";
label.Size = 0.5f;                         // metres of line height
label.Depth = 0.12f;                       // solid letters, a full 3D model
label.Color = new Color(1f, 0.95f, 0.75f);
label.Alignment = WorldTextAlign.Center;
label.Facing = WorldTextFacing.Camera;     // turns to the viewer

// A name tag over a player: 22 pixels tall, centred, never further than 40 m.
WorldText tag = nameTagObject.AddComponent<WorldText>();
tag.Mode = WorldTextMode.Screen;
tag.Text = "Player One";
tag.Size = 22f;
tag.MaxDistance = 40;
tag.ScreenOffset = new Vector2(0, -16);
```

The size the text takes, for laying out a background box or a neighbouring label:

```csharp
Vector2 extent = label.Measure();   // metres in the scene, pixels on the screen
```

Changing Text, Font, Size, Depth, Alignment, Unlit or Pixel Density makes new geometry (and a new texture) the next frame, so text can be updated every frame (a score, a timer) at the cost of rebuilding it. Colours and Glow cost nothing. Solid text rebuilds a mesh of the letters' outlines, which is more work than a flat quad: update it a few times a second rather than every frame if there are many labels.

## Notes

- Scene text is drawn with the scene's own pass, so occluding objects hide it correctly. Screen text always draws over the scene (that is its point), and under the game's own interface.
- A name tag is hidden behind the camera, past the camera's far clip, and beyond Max Distance.
- Textures are made at the text's size the first time it is drawn and kept until the text changes or the component goes away.
- The default font comes from the engine, so a game needs no font file to show words; a project font is a single file dropped into the project's assets.
