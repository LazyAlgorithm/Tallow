# Terrain

**GameObject > Voxel Terrain** adds a terrain: one flat square **tile**, 128 m across, ready to shape. Add more tiles beside it (or apart from it) with the **Tiles** tool, sculpt and paint across them as one surface, and save. It is made of voxels, so caves, overhangs and digging at run time all work.

## Tiles

Every terrain is one grid of square tiles, all the same size. Select the terrain and pick **Tiles** under Terrain Tools in the Inspector; the Scene view then shows the grid:

| In the Scene view | Does |
|---|---|
| Click a **+** | Adds a flat tile beside the others |
| Ctrl+click an empty place | Adds a tile apart from the others (tiles may be spaced out on the grid) |
| Click a tile | Selects it |
| Shift+click an empty place | Moves the selected tile there, with its sculpting |

With a tile selected, the Inspector moves it one place at a time, or removes it (leaving a hole). Undo and redo cover adding, moving and removing tiles, and every sculpting or painting stroke. Pressing **F** frames all the tiles.

While a brush is picked, the Scene view shows a **preview** under the mouse: the brush's edge lying on the ground as it is, and a see-through mesh of the shape the brush is about to give it (raised, lowered, levelled to the Flatten height, evened out, or tinted with the paint layer). It shows where and which way; how far the ground moves depends on how long the brush is held. **Preview** in the Terrain Tools turns it off, leaving a plain circle.

Where tiles meet, the ground simply carries on: brushes, smoothing and paint work across the edge, and the two sides match sample for sample. The ground ends, as a sheer side, only at the outer edge of the tiles and around holes.

| Field | Default | Meaning |
|---|---|---|
| Tile Size | 8 | Chunks along each side of a tile. A chunk is 32 voxels, so 8 at voxel size 0.5 is 128 m. Choose it before sculpting. |
| Flat Height | 0 | The height new ground starts at, above the object. |
| Min Chunk Y, Max Chunk Y | -1, 2 | How far down and up the terrain reaches, in chunks: with the defaults, 32 m below the object to 96 m above. |
| Voxel Size | 0.5 | Metres per voxel. Smaller is finer and costs more. |
| Stream Tiles | off | Load only the tiles within View Distance of the camera (and of each player, on a server). Off: all of them, all the time. |
| Lod Distance | 4 | Level of detail, below. |

In code: `AddTile(x, z)`, `RemoveTile(id)`, `MoveTile(id, x, z)`, `GetTiles(list)`, `TileAt(x, z)`. A tile keeps its id wherever it goes; its sculpting is filed under it.

## Saving

Saving the scene writes the sculpting to a folder beside it (`Scenes/<scene>_<object>.terrain`), one file per tile that has any, and removes the files of tiles that are gone. Only tiles with sculpting have files, so a large flat terrain costs nothing. In a build, a scene's own pack carries its terrain folder.

Scenes from before tiles open as tiles: their rectangle (the old `sizeX` and `sizeZ`) becomes tiles as large as fit it exactly, and their single `.voxels` file moves into the per-tile folder on the next save.

## Generators

What ground looks like before anyone sculpts it is the game's own business. Write a generator class:

```beef
[TerrainGenerator]
class Islands : TerrainGenerator
{
    public override float Density(float x, float y, float z)
    {
        // More than zero is solid, less is air; the surface is where it crosses zero.
        let hill = Noise.Fbm(x * 0.01f, 0, z * 0.01f, 7, 4) * 30;
        return hill - y;
    }

    // Optional: painted layers (1 grass, 2 rock, 3 sand, 4 snow, 5 dirt, 0 automatic).
    public override bool Paints => true;
    public override uint8 Paint(float x, float y, float z) => y < 1 ? 3 : 0;
}
```

Then either:

- `terrain.generator = "MyGame.Hills"` (the class's full name), set from the game's code: every chunk nobody has sculpted comes from it, in all tiles, as long as the game runs. Sculpting on top is kept as usual.
- `terrain.ApplyGenerator(generator, tileId)`: bakes a generator into one tile, as if it had been sculpted that way. The edge it shares with other tiles takes the new ground too, so there is no gap.

The editor has no generation settings: there a terrain is its tiles, flat until sculpted. The sample noise's `seed`, `terrainScale` and `caveAmount` are still fields (saved in scenes and set from code) but are not shown in the Inspector.

Coordinates are metres in the terrain's own space. `Density` and `Paint` run on worker threads, several at once: read only data that does not change while the terrain is generating, and copy what you need in `Begin(terrain)`, which runs on the main thread first. `terrain.SetGenerator((x, y, z) => ...)` does the same with a function from code, and `terrain.ApplyGenerator(generator, tileId)` is the bake.

Tallow's own noise is the sample `NoiseTerrainGenerator`; nothing uses it unless you choose it, except an Endless terrain with no generator of its own.

## Endless terrain

Set **Mode** to **Endless** for ground generated around the camera without end, by the terrain's generator (the sample noise if it has none: `seed`, `terrainHeight`, `terrainScale` and `caveAmount` shape it). This is what the open-world sample scene uses. Scenes saved before terrains had a mode keep their endless terrain.

## Style: Smooth, Contoured or Blocky

**Style** chooses how the samples become a surface.

- **Smooth** is marching cubes. Each cell is cut by triangles through the points where the surface crosses its edges. Gentle slopes come out with small steps and thin triangles.
- **Contoured** is dual contouring. Each cell the surface passes through gets one point, and the points are joined into a regular grid of quads. Slopes come out rounder and more even, with no slivers. **Contour Sharpness** places the points: at 0 each sits in the middle of where the surface crosses its cell, which gives the softest ground; at 1 it sits where the slopes around it meet, which keeps ridges, ledges and the corners of flattened areas crisp. The default is 0.35.
- **Blocky** is one cube per solid cell.

A new terrain is **Contoured**, with a **Voxel Size** of half a metre and smooth shading, which together pass for ordinary rolling terrain. To go without dual contouring set Style to **Smooth**. **Flat Shading** shades every triangle flat, for a faceted, low-poly look (Blocky ground is always flat). A Voxel Size of 1 is coarser, takes a quarter of the memory for the same ground and is quicker to sculpt across large areas; choose it before sculpting.

Smooth and Contoured make their surface from the same samples, so switching between them moves nothing: sculpting, painting, saving, collision, raycasts and networking are the same. Contoured chunks meet without seams because each chunk makes the outermost ring of points from its neighbours' samples, exactly as the neighbour does; after a sculpting stroke the chunks around the changed one are built again for that reason, so a stroke rebuilds a few more chunks than in Smooth. Around cave mouths and very thin walls a contoured surface can show a stray thin triangle.

## Streaming and level of detail

Endless terrains, and tiled ones with **Stream Tiles**, keep the chunks within **View Distance** (in chunks) of the camera. A game can give more places to keep loaded: a server fills `VoxelTerrain.Viewers` with each player's position every frame, so everyone has ground under them.

Chunks further than **Lod Distance** chunks from the camera are drawn with half the detail, beyond twice that a quarter, beyond four times an eighth. Each chunk has a skirt along its sides so chunks of different detail meet without gaps. Collision always uses the full detail, so physics far from the camera is as exact as near it. 0 turns it off. Smooth and Contoured styles.

## Editing at run time

`terrain.ModifySphere(point, radius, amount)` digs (negative) or builds (positive), and `terrain.Brush(...)` gives the other brushes. In a network session both are shared automatically; see [Networking](networking). `terrain.Raycast(ray, distance, out point)` and `DensityAt(point, out density)` read the ground without physics.

## Keeping sculpting somewhere of your own

`terrain.SaveEdits(List<uint8>)` and `LoadEdits(Span<uint8>)` write and read all the sculpting as bytes, by where each chunk is, for a game that keeps its terrain inside something else (a map file it sends to other players, say); call `Regenerate()` after loading into a terrain that already exists. `SaveEdits(path)` and `LoadEdits(path)` do the same with a file.

## Undo from code

`BeginEditRecord()` and `EndEditRecord()` around any sculpting return what changed, and `ApplyEditRecord(record, undo)` puts it back or forward. The editor uses these for its undo.

## Limits

- The edge of the tiles is a sheer side, not a skirt.
- Moving a sculpted tile next to other sculpted ground can leave a step along the edge where their shapes differ; smooth over it.
- Tile Size and Voxel Size are best chosen before sculpting.

## Tests