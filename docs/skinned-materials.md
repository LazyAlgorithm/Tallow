# Materials on skinned meshes

A rigged character usually has several materials: skin, cloth, armour, hair, each with its own textures. A **Skinned Mesh Renderer** draws such a model in parts, one per material in the file, each with that material.

## What a model gets by itself

When a rigged `.glb` / `.gltf` has **more than one material, or any textures**, each part is drawn with the material saved in the file:

| From the file | Becomes |
|---|---|
| Base colour factor | The vertex colours (as before), times the base colour texture |
| Base colour, normal, metallic-roughness, occlusion and emissive textures | The part's textures, wherever the file keeps them: inside a `.glb`, as `data:` addresses, or as image files beside the model |
| Metallic, roughness, normal scale, occlusion strength, emissive colour | The same settings on the part's material |
| Alpha mode (opaque, mask, blend), alpha cutoff, double sided | Opaque, Cutout or Transparent; Cutoff; Double Sided |

Parts are smooth-shaded (the file's normals are used). The textures are named after the model, `Models/hero.glb#image2`, so a `.tmat` can name them too.

A model with **one plain material and no textures** is one mesh drawn with its Mesh Renderer's settings (colour, metallic, roughness, texture), exactly as before.

## Your own materials

The Inspector lists the parts under the Skinned Mesh Renderer, by the file's material names. Type a `.tmat` path beside a part to draw it with that material instead; leave it empty for the file's own. Precedence, highest first:

1. the part's own `.tmat`;
2. a **Material** on the Mesh Renderer on the same object, which covers every part that has none of its own (so a scene that gave a skinned model one material still looks the same);
3. the material saved in the file.

The Mesh Renderer's **Color** still tints every part.

From code:

```beef
let skinned = GetComponent<SkinnedMeshRenderer>();
for (int i < skinned.PartCount)
    Log.Info(skinned.PartName(i));
skinned.SetPartMaterial(1, "Materials/armour_damaged.tmat");   // "" gives the part back the file's material
```

The choices are saved with the scene in the component's `materials` field, `Skin=Materials/skin.tmat;Armour=...`.

## Hiding and dyeing parts

A character customizer can put every choice in one model (each hat, hairstyle and coat a part of its own, by material
name) and pick what is shown and in what colours, so one skeleton animates them all:

```beef
skinned.SetPartHidden("Hat_Tricorn", true);              // Hidden Parts: not drawn, no shadow
skinned.SetPartColor("Coat", .(0.56f, 0.14f, 0.16f));    // Part Colors: multiplies the part's material colour
skinned.SetPartShadowOnly("Head", true);                 // Shadow Only Parts: a first-person player's own head
```

They are three fields, saved with the scene: `hiddenParts` and `shadowOnlyParts` (part names separated by `;`) and
`partColors` (`Coat=0.56 0.14 0.16;Hair=0.2 0.15 0.1`). Set the strings directly to change many parts at once; they are
applied on the next frame. On a Mesh Renderer, `MeshRenderer.Part` has the same three settings (`hidden`, `tint`,
`shadowOnly`) for any component that hands it parts.

## Networking

`SetPartMaterial`, called on the server or on the machine of the player who owns the object, is sent to every machine, the same way as `MeshRenderer.SetMaterial`. Materials chosen in the editor are part of the scene and need nothing sent.

## How it is drawn

The model's vertices are skinned once a frame into one buffer; each part is a mesh with indices of its own that draws those vertices (`Mesh.VertexSource`), so several materials cost no extra skinning or upload. `MeshRenderer.RuntimeParts` is the general form: any component can hand a renderer a list of meshes, each with a material, to draw in place of its one mesh.

## Tests