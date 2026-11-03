# Destructible objects

A **Voxel Object** is an object that can be carved: `Carve(point, radius)` removes material where something hits
it, and parts that are cut loose break off and fall as physics objects of their own, which can be carved in turn.
A boulder, a wall, a statue, a crate, a pillar.

## Making an object destructible

**A built-in shape.** Add a Voxel Object and choose **Shape**: Sphere, Box or Cylinder, of edge length **Size**.

**Any model.** Select an object that is drawn with a model, add a Voxel Object, and press **Make This Model
Destructible** in its Carving tools. That sets Shape to **Mesh** and **Mesh** to the model. The model keeps its own
size, colours and texture coordinates.

The model is filled in as solid material, so it must be **closed**, like a real object: no open sides and no single
sheets. The engine tells inside from outside by counting how many times a line through the model crosses its
surface.

What you get is the model re-made from a grid of **Resolution** cells along its longest side (8 to 48). Parts
thinner than a cell are lost and sharp edges are softened by up to about half a cell. Raise Resolution for fine
models; a long thin model wastes most of a cubic grid, so build long things from several objects.

## Materials

The **outside** is drawn with the object's **Mesh Renderer**: put a material on it as on anything else. A model's
own texture coordinates carry over, so a textured model stays textured.

The **inside**, the surfaces that carving exposes, is one of three things:

- **Interior Material** when you name one: the wood inside a painted crate, the concrete inside a plastered wall.
- Otherwise, when the Mesh Renderer has a material, an inside **made from it**: the same textures carried through
  the solid, tinted by **Interior Color** and a little rougher. A stone statue is stone all the way through without
  a second material.
- Otherwise plain **Interior Color**.

Inside surfaces have no texture coordinates of their own, so they are given them from the object's own space, seen
along whichever axis each surface faces most. **Interior Tiling** is how many times the texture repeats in each unit.

Pieces that break off are made of the same stuff: the same model, the same materials outside and in.

| Field | What it does |
|---|---|
| Shape, Mesh | Sphere, Box, Cylinder, or Mesh with a model |
| Resolution | Grid cells along each side, 8 to 48. Higher is finer and slower to re-make after each carve. |
| Size | Edge length of the grid for the built-in shapes. A model keeps its own size. |
| Color | The built-in shapes' colour. A model uses its own colours. |
| Interior Color | The inside's colour, or its tint when the inside is made from the outside's material |
| Interior Material, Interior Tiling | A material for the inside, and how often its texture repeats |
| Break Off Pieces, Minimum Piece Size | Whether cut-off parts fall as their own objects, and how small a part just vanishes |
| Anchored | On: the object stays put (a wall, a cliff) and only cut-off pieces fall. Off: it becomes a physics body the first time it is carved. |
| Palette Entry, Interior Palette Entry | With a palette material (docs/materials.md): the palette entry of the outside and of carved surfaces (-1: Color and Interior Color as they are). Each triangle then takes one entry, so entries never blend at a cut. |
| Debris Pieces | Pieces that break off rest on the ground, but characters walk through them and rays and shots pass through them. |
| Piece Lifetime | Seconds before a piece that broke off is removed (by the server in multiplayer); 0 keeps them. |

## Carving

```beef
// Where a shot lands:
if (hit.gameObject.GetComponent<VoxelObject>() case let voxels && voxels != null)
	voxels.Carve(hit.point, 0.4f);
```

In the editor, **Carve in Scene** carves with the mouse and **Reset Shape** puts the untouched shape back.

Collision: with a Mesh Collider and no Rigidbody the object has exact triangle collision. The physics engine cannot
move triangle meshes, so pieces that break off, and an object that is not Anchored once it is carved, collide with
a convex hull wrapped round them.

In multiplayer a carve happens on every machine: called on a client it goes to the server first and comes back to
everyone. Pieces are the same objects everywhere.
They take the object's world states and physics layer.

## Limits

- The model must be closed. An open model comes out with stripes of solid and empty, or as nothing.
- The grid is a cube, so thin and very long models lose detail.
- Texture coordinates are taken from the nearest point of the model for each grid sample: fine for tiling textures
  and painted colours, smeared where a texture has fine detail or where two parts of it meet.
- A model with several materials is drawn with one outside material.
- The whole grid is re-made on every carve; at Resolution 48 that is the slowest it gets.