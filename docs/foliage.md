# Foliage and wind

**Foliage** covers ground with plants: grass, flowers, bushes, rocks, trees. **Wind Zones** make them, and anything
else you choose, bend in the wind.

## Foliage

A Foliage component is one kind of plant, many times over. Every plant of a component is the same model, and the
graphics card draws them all together (instancing), so tens of thousands cost little. Each plant has its own turn,
size and shade, so they do not look stamped out.

On a terrain:

1. Select the terrain and press **Foliage** in its **Terrain Tools** (the second row, beside Tiles).
2. Press **+ Grass**, **+ Bush**, **+ Tree** or **+ Pine**. Each adds a kind of plant, ready to paint.
3. Drag over the ground in the Scene view. Hold **Shift** to erase. **Ctrl+Z** undoes a stroke.
4. The kinds of plant are listed in the tool: press one to paint that kind. Each is a **Foliage** component on the
   terrain, further down the Inspector, where its model, density, sizes and sway are set.

On anything else, or to use a model of your own: add a **Foliage** component, choose its **Mesh**, and press
**Paint** in the component.

**Fill Terrain** paints every terrain tile at once. **Clear** removes every plant of that component.

| Field | What it does |
|---|---|
| Mesh | The plant. Its foot must be at the model's origin: that is where it stands on the ground and what it bends from. |
| Material | A `.tmat` for the plants. Empty uses the model's own colours, two-sided and smoothly shaded. |
| Color, Color Variation | A tint for all of them, and how much they differ in shade from one to the next. |
| Min Scale, Max Scale | Each plant's size is somewhere between these. |
| Sway | How far the plants bend in the wind: 1 for grass, about 0.3 for bushes and trees, 0 for rocks. |
| Cast Shadows | Worth it for trees. A field of grass is better without. |
| View Distance | Plants further than this from the camera are not drawn. They thin out over the last third rather than stopping at a line. |
| Density | The brush: plants to each square metre painted. Grass wants 4 to 12; trees about 0.01. |
| Max Slope | The brush: ground steeper than this many degrees is left bare. |

The brush finds the ground on a Voxel Terrain (the object's own, else the scene's). With no terrain it paints on
level ground at the object's height; while the game is playing it uses colliders.

Plants are scenery. They have no colliders, they are saved with the scene, and they are the same on every machine.

From code:

```beef
let grass = GetComponent<Foliage>();
grass.Paint(point, 6);          // what the brush does: Density plants to the square metre, in a 6 m circle
grass.Erase(point, 3);          // removes the plants in a circle
grass.Add(point);               // one plant; Add(point, turnDegrees, scale) to choose
grass.Clear();
```

`Paint`, `Erase`, `Add` and `Clear` change only the machine they are called on: call them on every machine for a
change everyone should see.

### How many

All the plants of one component that are in view go to the graphics card in one draw. What costs is the number in
view at once, so set **View Distance** by kind: grass 60 to 90 m, bushes 150, trees 300 or more. Something like fifty
thousand plants in view is comfortable on a desktop graphics card; a phone wants far fewer and a shorter distance.

## Wind

Add a **Wind Zone** to an object. The wind blows the way the object faces (its blue arrow).

| Field | What it does |
|---|---|
| Shape | **Global** blows over the whole scene. **Sphere** blows inside a radius round the object, strongest in the middle and fading to nothing at the edge. |
| Strength | 0 is still air, 1 a breeze, 3 a strong wind, 6 a gale. |
| Gusts | How much the wind comes and goes, from steady (0) to gusty (1). The gustiest Global zone sets it for the scene. |
| Radius | How far a Sphere zone reaches. |

Zones add up: a Global zone for the day's weather, and Sphere zones for a gusty valley, a fan, a helicopter's
downdraught or the blast of something passing. Move, turn or animate a zone like any object.

What bends:

- **Foliage**, by its **Sway**.
- Any **Mesh Renderer** with **Wind Sway** above 0: a flag, a hanging sign, a tree placed by hand, reeds. It bends
  about its own origin, more the higher up, so put the origin at its foot.

The bending is done on the graphics card, so it costs the same for one plant as for fifty thousand. Shadows bend with what casts them, and so does the depth that ambient occlusion and depth of field work from. The four Sphere
zones nearest the camera take part; Global zones always do.

From code, `Wind.At(Scene, position)` is the wind at a point (a direction whose length is the strength), for
anything that should drift with it: smoke, a sail, a paper bag.

Wind is the same on every machine when the zones are. Zones saved in a scene are; a zone moved by a script moves on
other machines if its object is shared (a Network Identity).

## Plants and players

Grass parts round a player's feet and closes again behind them.

- **Characters need nothing.** Every object with a **Character Controller** pushes plants aside by itself, sized
  from the controller.
- For anything else that moves through plants (a creature, a vehicle, a rolling boulder), add a **Foliage Bender**.
  **Radius** is how far it reaches, **Strength** how hard it pushes (1 lays grass well over, 0.3 only brushes it),
  and **Offset** where it is centred in the object's own space, its feet as a rule.
- Put a Foliage Bender on a character to change how it pushes, or with Strength 0 to stop it.

What bends is what sways: Foliage by its **Sway**, and any Mesh Renderer with **Wind Sway** above 0. Stiff plants
with a low Sway give way less; a Sway of 0 does not move at all. Plants only give way to something at about their
own height, so someone on a bridge does not part the grass below.

In multiplayer nothing is sent for this. Each machine bends its own plants round the objects it has, and it has
every player, so other players part the grass on your screen as they do on their own. The eight nearest the camera
take part.

## Plants and sculpting

Plants on a terrain follow its ground when it is sculpted, in the editor and in the game (on every machine in
multiplayer, since every machine applies the same strokes):

- ground that rises or sinks carries its plants with it;
- a plant that ends up buried deeper than the stroke could have raised the ground is removed;
- so is one left with no ground under it within the brush's reach.

So nothing is left where nobody can reach it. Each plant is judged from where it stands: the ground is looked for
straight up or down from its own foot, not from the sky. Grass on a cave floor stays on the cave floor when the
hill above it is reshaped, and goes only when its own floor moves away or the cave is filled in. The Paint brush,
which only colours the ground, moves nothing.

Undoing a sculpting stroke puts the ground back and the plants back on it. Plants the stroke removed come back
with one more **Ctrl+Z**, which undoes the change to the plants themselves.

## Limits

- Plants do not collide and cannot be walked into; put colliders on trees that must block the player.
- Custom shaders made before this version bend only after they are compiled again.