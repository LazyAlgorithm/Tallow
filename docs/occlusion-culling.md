# Occlusion culling

In a town or a building most of the scene is behind walls. A camera with **Occlusion Culling** on (a Camera setting) does not draw what is wholly hidden behind big solid things.

Each frame, before the camera draws, the biggest solid objects in view are drawn into a small depth picture on the CPU (256 by 144). Every object's box is then checked against it: if each pixel the box covers has something in front of the box's nearest point, the object is not drawn. Nothing is baked, so moving cameras, opening doors and objects made while playing all just work.

It errs on the side of drawing: an occluder counts only where it surely covers a pixel (its edges, and triangles reaching behind the camera, hide nothing), and only the depth of a triangle's farthest corner. So it never hides something that should show; at worst it draws a little that is hidden.

## Occluders

Each Mesh Renderer has **Occluder**:

| | |
|---|---|
| **Auto** (the default) | An occluder when it covers at least 8% of the screen's height, is solid (not see-through), does not move by itself (no Rigidbody, not skinned) and has at most 2000 triangles: walls, buildings, rocks, floors. |
| **Always** | An occluder whenever it is on screen and solid: a big moving door, a detailed building. |
| **Never** | Never: a fence, leaves or anything with holes the mesh's triangles do not show. |

Up to 30000 occluder triangles are drawn per frame, biggest on screen first (`OcclusionBuffer.TriangleBudget`, `MaxAutoTriangles`, `MinOccluderSize` change this). Everything is tested as an occludee, occluders too.

Shadows are not affected: a hidden object still casts its shadow.

## When to use it

It costs a little CPU time each frame (drawing a few thousand triangles into a small picture). It pays where walls hide a lot: towns, interiors, corridors, cliffs. In an open field it hides little; leave it off there. The Scene view's statistics show how much it hides.

## In the editor

**Window > Scene Occlusion Culling** turns it on for the Scene view's camera, and its statistics then show how many objects were hidden and by how many occluders. **Window > Occlusion Picture** shows the depth picture in the corner of the Scene view: occluders in blue, nearer brighter. The editor switch `--scene-occlusion` turns both on.

## Networking

Nothing to send: each machine culls for its own cameras. A dedicated server draws nothing.

## Limits

- Occluders are drawn with their full meshes; a building of many thousand triangles needs **Always** and counts against the budget.
- Parts of multi-material models are tested, but only single-mesh renderers are occluders.
- Orthographic cameras do not cull.

## Tests