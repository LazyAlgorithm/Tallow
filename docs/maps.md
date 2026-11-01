# Maps

A map is a scene saved into one `.tmap` file. A game looks for map files in a folder and plays them without being
built again, so players can make levels and hand them to each other as single files. Maps are made in the game
itself, by a map editor the game provides (Tumble Toys: Aviation has one, under Create), which saves with
`MapFiles.Export`.

## Saving a map

```beef
// level: what SceneManager.LoadAdditive returned when the map editor opened the base scene or the map.
let problems = scope List<String>();
defer { ClearAndDeleteItems!(problems); }
MapFiles.Export(Scene, level, "Maps/Harbour.tmap", mapId, "Harbour", "A player", "A hill by the sea.", problems);
```

| Argument | Meaning |
|---|---|
| group | The objects to save: everything under it, each child as a root, with the scene's environment. `null` saves the whole scene. |
| keepId | The map's Id. Pass the Id of the map being saved again, so players who have it get the new version instead of a second map; empty gives a new one. |
| name, author, description | Shown by the game (the name in its menu). |

The map holds the scene and the scene's own data:

- each Voxel Terrain's sculpting folder;
- every file the scene names under `.maps/<Id>/`, such as a model the player brought into the map. A map editor
  keeps such a file in memory with `AssetPack.AddMemoryFile("<project>/.maps/<Id>/models/boat.glb", bytes)` and
  names it from a Mesh Renderer (`.maps/<Id>/models/boat.glb`, or `#2` for one part; its pictures are
  `boat.glb#image0` and so on). Export copies it into the map, and changes the paths to the map's Id.

Everything else the map uses comes from the game: models, prefabs, materials, textures, sounds and scripts. A map
names them, so the game's own art never leaves it, and a map can only use what the game has. A map never carries
code. `problems` lists any file the scene names that the project lacks.

## What a map needs

A game says what a scene must have to be played as one of its maps in `src/MapRules.txt`:

```
# need <count> <component> ["what they are"]
# need <count> <component> <field> <compare> <number> ["what they are"]
# most <count> <component> ... (a limit instead of a need)
need 4 Tallow.SpawnPoint "Spawn Points (one for each player)"
need 24 MyGame.Ring "rings"
need 3 MyGame.Ring raceOrder >= 0 "race gates (rings with a Race Order)"
most 500 Tallow.Rigidbody "physics items"
ignore Scenes/MainMenu.tscene
```

A field test compares the field's number (a bool is 1 or 0) with `=`, `!=`, `<`, `<=`, `>` or `>=`. A component
whose field is not in the scene file has the field's default value. A `most` rule fails a map with more than the
count: "It can have at most 500 physics items and has 612." The rules are applied in three places:

- **When you save a scene** (Ctrl+S, File > Save Scene, Save Scene As), the editor shows the **Map Warning** window
  if the scene breaks a rule, listing what is missing: "It needs at least 4 Spawn Points (one for each player) and
  has 2." The scene is still saved. For a scene that is not meant to be a map, **This scene is not a map** adds an
  `ignore` line for it to `MapRules.txt`, and saving it no longer warns.
- **A game's map editor** shows what the map still lacks with `MapRules.Check` on the saved text
  (`SceneSerializer.SaveGroup`).
- **`MapFiles.Find`** gives a map that breaks a rule a problem for each rule it breaks, so the game does not list it.

A game without `MapRules.txt` accepts any scene as a map. `MapRules.Check(sceneText, problems)` applies the rules
to any scene text, and `MapRules.Count` counts what one rule counts.

## Finding and playing maps

```beef
let maps = scope List<MapFileInfo>();
defer { ClearAndDeleteItems!(maps); }
MapFiles.Find(MapFiles.Folder(.. scope .()), maps);
for (let map in maps)
{
    if (map.Ok)
        Log.Info(map.Name);  // list it in the menu
    else
        Log.Warning(scope $"{map.File}: {map.Problems[0]}");
}

// To play one: mount it, then load its scene as any other.
if (MapFiles.Mount(map))
    SceneManager.LoadAdditive(Scene, map.ScenePath(.. scope .()), true);
```

`MapFiles.Folder` is the `Maps` folder in `GamePaths.GameFolder`. That is the folder beside a built game's program, or
the project's folder when the game runs from the editor. `Find` looks at every `.tmap` file in a folder and returns
them sorted by name, broken ones included, each with `Problems` saying why it cannot be played:

- the file is not a map, or is damaged (each file inside has a checksum, so a changed or cut-short map is caught here,
  not halfway through loading);
- it was made for another game (`Game`, the project's name when it was exported);
- it was made with a newer version of the engine;
- it uses a component the game does not have, or names a file the game does not have;
- it is the same map (the same `Id`) as one listed already, such as a renamed copy.

A game adds its own checks with `map.AddProblem`, and can count what is in the map with
`map.CountComponents("Tallow.SpawnPoint")`. `Mount` reads the map's files into memory, where they are found before
the game's own files. `Unmount` frees them and forgets the models and textures loaded from them; unload the map's scene first.
`Mount(map, true)` mounts a map that breaks a rule, for a map editor opening a map that is not finished.

`Id` stays the same when the file is renamed or copied, so players with the same map have the same `Id`. `Hash` is
the whole file's hash (16 hex digits): the same `Id` with another `Hash` is another version of the map.

## Sharing maps in a game

`MapSharing` sends a map from the host to a player who lacks it, or whose copy is another version:

```beef
// Host, for each map it found:
MapSharing.Offer(map);
// Player, told the host's map Id and Hash (in the session context, or [Sync] fields):
if (!MapSharing.Have(id, hash))
    MapSharing.Request(Scene.Network, id, hash);
// Then each frame: MapSharing.State (Asking, Downloading, Done, Failed) and Progress.
// Once Done, find the maps again and load it. Call MapSharing.Reset() when leaving a game.
```

The file comes in 16 KB pieces, eight at a time: each piece is acknowledged before more are sent, so a slow
connection is not flooded and Steam's send buffer never overflows. The player checks the whole file's hash before
writing it into its Maps folder (`MapSharing.Folder`), replacing an older version of the same map wherever it is.
Maps over `MapSharing.MaxBytes` (64 MB) are refused. A downloaded map is checked by `MapFiles.Find` like any other
before it is played.

## The file

A `.tmap` file is an asset pack in the format the engine's own packs use (`native/tallow_pack.c`). It holds
`map.txt` (the name, author, description, game and `Id`), `map.tscene`, and the terrain sculpting folders. While it
is mounted its files appear in the project's `.maps/<Id>/` folder. `tools/pack_assets.py --list` and `--verify`
read it. `PackFile` reads and writes one such pack from Beef.

## Limits

- A map carries no assets of its own: new models, materials or scripts reach players with the next build of the game.
- Lightmaps baked for the scene are not carried with it.
- Mounting reads the whole map into memory. Maps are small (a sculpted terrain tile is about 70 KB), but a map is not
  streamed.

CPU tests (`Tests/Maps`) cover:

- exporting a sculpted level, finding it, reading its details, counting its components;
- mounting it, loading it into a running scene with its sculpting, and unmounting it;
- refusing eight kinds of bad map: junk, damaged, another game's, a missing file, an unknown component, a newer
  format, a duplicate, and mounting a refused one;
- `MapRules.txt`: reading it, counting with and without field tests (a field left out takes its default), the
  message for a missing requirement, `Find` refusing a map that breaks a rule, `ignore`, and a `most` limit;
- each map's hash and size;
- saving a level loaded into a running game, with a model of its own carried inside it and loaded from it once
  mounted;
- a host and a player in one process: a missing map downloaded whole, an older version replaced, a 3 MB map in
  pieces, and a map the host lacks failing with a reason.
