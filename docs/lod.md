# Levels of detail (LOD Groups)

Far away, an object can be drawn with fewer triangles and nobody can tell; when it is only a speck it need not be drawn at all. An **LOD Group** (Add Component > Rendering) does this for the object it is on and everything under it.

The level is picked for each camera from how much of the screen's height the object covers (its bounding sphere's diameter over the view's height at its distance). So it works the same at any resolution and field of view, a zoomed-in scope sees the full detail, and split-screen players each get their own level.

## Where the levels come from

**Children** (the default): objects under the group named `..._LOD0`, `..._LOD1`, `..._LOD2` and `..._LOD3` are the levels, the way most modelling tools and asset packs name them (`Rock_LOD0`, `Rock_LOD1`). Only the level picked is drawn. A renderer without such a name (a decal, a shadow blob) is drawn at every level, except the group object's own renderer when nothing is named `_LOD0`: that one is level 0 (the modeller's **Make Levels of Detail** builds groups that way). The group finds its renderers again by itself when objects are added under it.

**Generated**: every renderer under the group is simplified when it is first drawn far away, into **Generated Levels** levels (2 to 4) keeping **Level 1 Triangles**, **Level 2 Triangles** and **Level 3 Triangles** of its triangles (half, a fifth and a twelfth by default). Simplifying merges vertices that lie close together and face much the same way, so hard edges of low-poly models stay hard and thin walls do not close up. It suits rocks, trees and props; for hero objects, models made with their own LOD meshes look better. Skinned characters are not simplified.

## When each level is drawn

| Setting | |
|---|---|
| **Level 1 Below**, **Level 2 Below**, **Level 3 Below** | Below this share of the screen's height (0.4 is 40%), that level is drawn. Levels the group does not have are skipped. |
| **Cull Below** | Below this share nothing is drawn, and it casts no shadow (0: always drawn). |

`LODGroup.Bias` changes it for every group: 2 keeps detail twice as far, 0.5 drops it at half the distance. A quality setting in the game's options should set it.

Shadows come from the level the camera sees.

## In the editor

Select the group: the Inspector shows each level's renderers and triangles, and how much of the Scene view it covers and the level that gives. **Preview** draws every LOD Group at one level, in the Scene and Game views, until **Auto** is pressed; the switch `--lod-level <n>` does the same from the command line. The Scene view's statistics count the renderers left out for being too small.

## Networking

Nothing to send: each machine picks levels for its own cameras. A dedicated server draws nothing.

## Code

```beef
let group = rock.AddComponent<LODGroup>();
group.source = .Generated;
LODGroup.Bias = settings.highDetail ? 1.5f : 1;
let level = group.LevelFor(camera.GetCameraData(aspect));   // 0 full detail, -1 not drawn
```

`MeshSimplifier.Simplify(mesh, 0.25f)` makes a simplified copy of any mesh.

## Limits

- Levels switch at once; there is no cross-fade, so a big change of shape can be seen to pop.
- Generated levels come from vertex merging, not edge collapsing: fine at a distance, rough up close.

## Tests