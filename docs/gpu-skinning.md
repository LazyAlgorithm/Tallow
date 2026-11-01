# GPU skinning

Bending a rigged model's vertices to its skeleton every frame is most of what an animated character costs. With **GPU skinning** (on by default, the Skinned Mesh Renderer's **Gpu Skinning**) a compute shader does it on the graphics card, writing straight into the vertex buffer every pass draws from: the scene, shadows, the depth pass of screen effects, decals and custom material shaders all see the bent model, and none of their shaders needs a skinned version. The CPU only works out each joint's matrix, as before, and the model's box from its joints.

Crowds benefit most: a model of 5000 vertices costs the CPU about the same as one of 500.

Where the graphics card cannot run compute shaders (the web build, very old cards) models are bent on the CPU, as before, without anything to set. The log says which: `Skinning: on the GPU`.

## When to turn it off

With GPU skinning the bent vertices exist only on the graphics card; `Mesh.Vertices` on the CPU stays in the rest pose. Turn **Gpu Skinning** off for a model whose bent vertices code reads (cutting a mesh where it is hit, baking a pose). In the editor, clicking a character in the Scene view picks it by its rest pose.

`GpuSkinning.Enabled = false` turns it off for every model (a setting, or to compare); `--cpu-skinning` does it from the command line. The Inspector says, under a Skinned Mesh Renderer, whether its vertices are bent on the GPU or the CPU.

## Bounds

## Networking

Nothing changes: clips and states are sent, not bones or vertices, and each machine bends its own models. A dedicated server bends nothing.

## Tests