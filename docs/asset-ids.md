# Asset IDs

Every asset in a project's Assets folder has an ID that never changes, kept in a small file beside it:

```
Models/crate.glb
Models/crate.glb.tmeta     id 3f2a9c51e07b4d6a8e1f20c4b9d73a55
```

The editor makes the `.tmeta` the first time it sees a file. Commit `.tmeta` files with the assets: they are how the
editor knows a file is the same asset after it has moved, and how a package's assets are recognised in every project
they go into (`docs/packages.md`). The Project window does not show them, and builds leave them out.

Scripts (`.bf`) have no `.tmeta`: scenes find components by class name, not by file.

## Moving and renaming

Scenes, prefabs, materials, UI documents and scripts name assets by their path (`"Models/crate.glb"`), which is what
the game loads. When an asset moves, every file that names it is changed to the new path:

- **In the Project window** (drag onto a folder, or Rename): at once. Its `.tmeta`, `.import` and `.bonemap` go with
  it. A folder takes everything in it, and paths inside it change too. The open scene, prefab, graph, scripts and other
  editors follow, and so does `startScene` in `project.tallow`.
- **Outside the editor** (a file manager, `git mv`, a pull of someone else's move): the next time the editor looks,
  about a second later. A file that moved with its `.tmeta` is found by its ID. A file whose `.tmeta` was left behind
  is matched to it by name, and the `.tmeta` is moved after it.

Changed are quoted paths (`"Models/crate.glb"`, and `"Models/hero.glb#Armature"` for a part of a model), lists of
paths separated by `;` (an Animator's clips), and `key = path` lines in `project.tallow`. A path a script builds
while it runs (`scope $"Models/{name}.glb"`) cannot be seen, so it is not changed.

The Console says what moved and how many files were changed.

## Copies, deletes, references

- A file copied with its `.tmeta` (in a file manager) gets an ID of its own; the original keeps its ID.
- **Delete** in the Project window takes the `.tmeta` and side files with the asset, and the window lists the files
  that still name it before you confirm.
- **Find References** (right-click an asset) lists the files that name it in the Console.

## Where the IDs are kept

- `<file>.tmeta`: `id` and 32 hexadecimal digits.
- `<project>/.cache/asset-ids.txt`: where each ID was last seen, which is how a move made outside the editor is
  recognised. It is rebuilt when missing; `.cache` is not committed.

Opening an older project gives every asset a `.tmeta` the first time, so the first commit afterwards has a `.tmeta`
beside each asset.

## Tests

`--asset-ids-test` checks it all in a folder of its own (moves in and outside the editor, with and without the
`.tmeta`, folders, copies, deletes, `;` lists, the open scene) and logs `ASSET-IDS-TEST PASS` or what failed.

## From code (editor)

```beef
AssetDatabase.GetId("Models/crate.glb", id);     // the ID of an asset
AssetDatabase.GetPath(id, path);                 // where it is now
AssetDatabase.Move(fromFull, toFull, moves);     // move with side files and references
AssetDatabase.FindReferences("Models/crate.glb", files);
AssetDatabase.Refresh();                         // look again (new files, moves outside the editor)
```
