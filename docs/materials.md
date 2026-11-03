# Materials, shaders and compute

How a surface looks is a **material**. What draws it is a **shader**: the engine's standard one, or one you write. A **compute shader** runs your code on the graphics card for every pixel of a texture.

A Mesh Renderer with no material works as it always did, from its own Color, Metallic, Roughness and Texture fields. Nothing existing changes.

## Materials

**Project > + > Material** makes a `.tmat` file. Set it as the **Material** of a Mesh Renderer. It works on skinned models too, since they draw through a Mesh Renderer.

A material's settings are in the **Inspector**, in two places:

- click the `.tmat` file in the Project panel, and the Inspector shows the material;
- select an object, and the material its Mesh Renderer uses is shown under the object's components.

Every object naming the same material shares it: edit the material and they all change, live, in the editor and while playing. Changes are saved as you make them.

In the Project panel a material is shown as a ball drawn with it, so you can tell them apart at a glance.

| Setting | Meaning |
|---|---|
| Shader | Standard, or a `.tshader` file from the project. |
| Color, Texture | The base colour and the image it is multiplied by. |
| Metallic, Roughness | 0 to 1 each. A smooth metal mirrors the sky and ground colours. |
| Emissive, Emissive Intensity | Light the surface gives off by itself. |
| Flat Shading | The faceted low-poly look. Off for smooth surfaces and anything with a normal map. |
| Unlit | Ignore lighting: the colour as it is. |
| Double Sided | Draw both faces: leaves, cloth, flags. The back is lit as its own side. |
| Tiling, Offset | How many times the textures repeat across the mesh, and where they start. |
| Blend | Opaque; **Cutout** (holes where alpha is below Cutoff: fences, foliage); **Transparent** (blended, casts no shadow). |

Without a material, a Mesh Renderer's own **Back Face Culling** (on by default) does the same: turn it off to see a plane from both sides (a curtain, a flag). A material that is Double Sided draws both sides whatever the renderer says.

The renderer's own **Color** still tints the object on top of its material, so a hundred crates can share one material and differ in tint.

### Palette mode (optional)

For a low-poly look coloured from one shared set of colours, give a material a **Palette**: a 256-colour image, 16 x
16. **New Palette** in the material's Inspector makes one in `Textures/` with starting colours; click any colour in the
grid to change it, and the image is written when you let go, so nothing outside the editor is needed. Any other
16 x 16 (or 256 x 1) picture works too. Materials without a palette draw exactly as before.

In palette mode each face takes everything from its vertex colour, painted with **Palette faces** in the modeller
(docs/modeling.md):

| Byte | Meaning |
|---|---|
| Red | The palette entry, 0 to 255. |
| Green | Glow, 0 to 255, times the material's **Glow Strength**. It shows with bloom; it does not light other things. |
| Blue | Roughness (top five bits, 0 to 31) and metallic (low three, 0 to 7); on a see-through face, its opacity. |
| Alpha | Flags: 1 unlit, 2 see-through, 4 double sided, 8 cutout (holes where the palette colour's alpha is below half), 16 hologram, 32 pulsing glow, 64 dissolve. |

A face never painted (plain white) is entry 255 with no glow or flags. Colour, Texture and the maps are not used.

- **A palette for each world state.** With more than one world state, the Inspector has a palette for each (**New
  palette for ...** copies the main one to change): the same faces are coloured from that state's palette, so two
  realities of one place share one mesh.
- **See-through and double-sided faces** are drawn apart from the rest of the mesh automatically, each kind with its
  own blending and culling, so one model can mix glass, signs and solid walls.
- **Dissolve** (0 to 1) eats away faces flagged Dissolve: animate it from a script for a shift or a death.
- The palette is drawn with no mip levels, compression or filtering, so neighbouring colours never bleed, at any
  texture quality.

### PBR maps

The standard shader is a metallic-roughness PBR shader. Four optional maps add detail:

| Map | What it holds |
|---|---|
| Normal Map | Bumps and grooves without more triangles: an ordinary tangent-space normal map. Normal Strength scales it. |
| Metallic-Roughness | Roughness in green, metallic in blue (the glTF layout). Multiplied by the two sliders, so set them to 1 to use the map as it is. |
| Occlusion | Darkened creases, in red. The same image as the metallic-roughness map can be used, as glTF packs them. |
| Emissive Map | Which parts glow. Multiplied by Emissive and its intensity. |

Meshes need no tangents: the shader works them out per pixel. `Materials/brass.tmat` in new projects is a worked example (hammered brass).

### From scripts

```beef
let renderer = GetComponent<MeshRenderer>();
renderer.SetMaterial("Materials/brass.tmat");          // use another material

// Change this object only: it gets its own copy the first time.
renderer.SetMaterialColor("color", .(1, 0, 0, 1));
renderer.SetMaterialFloat("roughness", 0.2f);
renderer.SetMaterialFloat("speed", 4);                  // a custom shader's property

// Change the shared material: every object using it changes.
let shared = renderer.SharedMaterial;
shared.emissiveIntensity = 3;
shared.Changed();                                       // after setting plain fields
shared.SetColor("glow", .(0, 1, 0.5f, 1));              // shader properties need no Changed()
```

`renderer.Material` is this object's own copy (made on first use), `renderer.SharedMaterial` the shared one. `Material.Load(path)`, `Clone()` and `Save(fullPath)` are there for tools.

## Writing a shader

**Project > + > Shader** makes a `.tshader` file and opens it in the code editor. Saving compiles it; objects using it change at once, and mistakes are listed in the Console.

A shader file says what the surface looks like. It does not do lighting: the engine puts your code into its own lit shader, so sun, shadows, point and spot lights, fog and the PBR maps all still apply.

```glsl
property float speed = 2
property color glow = 1 0.5 0.2 1
property texture detail

surface {
    float pulse = 0.5 + 0.5 * sin(time * speed - worldPosition.y * 6.0);
    albedo *= texture2D(detail, uv * 4.0).rgb;
    emissive += glow.rgb * pulse;
}

vertex {
    position += normal * sin(time * speed + position.y * 6.0) * 0.02;
}
```

**Properties** appear in the Inspector of every material using the shader, and are set from scripts by name. Types are `float`, `color`, `vector` (four numbers) and `texture`, each with an optional default. A shader may declare up to eight values and two textures. A property cannot take the name of something the code already reads or changes (`uv`, `time`, `albedo` and the rest below).

**`surface { }`** runs for every pixel.

| Read | |
|---|---|
| `uv` | Texture coordinates, after the material's tiling and offset. |
| `worldPosition`, `worldNormal` | Where the pixel is, and which way the surface faces. |
| `vertexColor` | The mesh's vertex colour times the object's tint. |
| `time` | Seconds, running in the editor as well as in play. |
| `texture2D(mainTexture, uv)` | The material's texture. Your own texture properties are sampled the same way. |

| Change | Starts as |
|---|---|
| `albedo` | Texture times colour, already converted to linear. |
| `alpha` | Texture alpha times colour alpha. |
| `metallic`, `roughness` | The material's sliders. |
| `emissive` | The material's emissive colour times intensity. |
| `occlusion` | 1: how much ambient light reaches the surface (the occlusion map multiplies it afterwards). |
| `surfaceNormal` | `vec3(0, 0, 1)`: a normal in the surface's own directions (x along U, y along V, z out of it), added to the material's normal map. |

**`vertex { }`** is optional and runs for every point of the mesh: change `position` (in the mesh's own space); read `normal`, `uv` and `time`.

The code inside the blocks is GLSL as bgfx writes it: use `vec3_splat(1.0)` for a vector of one value and `mul(matrix, vector)` for matrix products.

Compiled programs are written to `Shaders/Compiled/` in the project, for Vulkan, OpenGL, OpenGL ES and Metal. They are assets like any other and ship with the game, which never compiles shaders itself. The editor recompiles any shader whose source, or the engine's own shader files, are newer when it starts and before Build Game, so a change to the engine's lighting reaches every custom shader.

## Shader graphs

**Project > + > Shader Graph** makes a shader without writing code. It opens in the Graph tab, with shader nodes in the add-node menu, and starts with a small working graph.

- **Surface Output** is where the graph ends: Albedo, Alpha, Metallic, Roughness, Emissive, Vertex Offset, Normal and Occlusion. Whatever you leave unconnected keeps the value the material gives, so a graph that only connects Emissive adds a glow to an otherwise ordinary material.
- **Shader Input:** Time, UV, World Position, World Normal, View Direction, Vertex Color, and what the material itself provides (Material Albedo, Material Alpha).
- **Shader Properties:** Number Property, Color Property, Texture Property and Normal Map Property become settings in the Inspector of every material that uses the shader, under the name you give them. Material Texture samples the material's own texture.
- **Shader Math, Shader Vectors, Shader UV:** arithmetic, blend, clamp, step, remap, modulo, dot, length, reflect, splitting a colour or vector into its parts and combining them, tiling, scrolling, rotating, polar coordinates and a triplanar texture (the material's texture laid on from three sides, for ground and rock without good texture coordinates).
- **Shader Effects:** Pulse, Bands, Rim (Fresnel), Noise, Smooth Noise, Cells (Voronoi), Checker, Gradient, Posterize and Desaturate.
- **Shader Normals:** Normal Map Property, Normal From Height (bumps from any number: noise, cells, a texture's channel), Blend Normals and Normal Strength. Their result goes into the output's **Normal**, which is in the surface's own directions (x along U, y along V, z out of it) and adds to the material's own normal map.
- **Shader Code:** Custom Code (Number, Vector or Color) runs a line of shader code typed into the node. Its inputs are `a` and `b` (numbers), `v` (a vector) and `c` (a colour). Type an expression (`a * a + b`), or statements that set `result` (`result = c; result.g = a * 0.5;`).

Numbers, vectors and colours plug into each other: a number fills every part of a vector, and a colour into a number pin gives its first channel. New nodes start with values that show something (a noise's scale of 8, a remap from 0-1 to 0-1), not zeros.

Each node is worked out once, however many nodes read it, so a noise feeding Roughness, Metallic and a normal costs one noise.

**Previews.** Each node shows its value on a small ball under its pins, and the canvas's bottom right corner shows the whole surface, lit. They update a moment after the graph stops changing (the editor compiles a preview shader in the background, for its own graphics backend only) and move with Time. **Hide Previews** on the toolbar makes the nodes compact again. If the graph cannot compile, the toolbar says why after "Preview:".

**Subgraphs.** **Project > + > Shader Subgraph** makes a reusable piece of shader graph. **Subgraph Input** nodes (Number, Vector 2, Vector, Color) become its node's input pins in other shader graphs, with a Preview value used while you edit the subgraph itself; **Subgraph Output** nodes become its outputs. Subgraphs appear under *Shader Subgraphs* in the add-node menu. Double-click a subgraph's node to open it. Saving a subgraph compiles again every shader graph that uses it. Subgraphs can use other subgraphs, and their Property nodes become properties of the shader using them.

**Save** writes the graph, generates a `.tshader` file beside it and compiles it. Pick it as a material's **Shader** like any other. The generated file is hidden in the Project panel, as a script graph's code is; it is the same format a hand-written shader uses, so a graph can be outgrown: copy the generated file and carry on in code.

Colours given to Albedo and Emissive are taken as you see them in the colour picker (the graph converts them for lighting). The two "vertex only" inputs, Object Position and Object Normal, are for Vertex Offset.

The functions behind the effect nodes (`tsg_noise`, `tsg_cells`, `tsg_rotate`, `tsg_polar`, `tsg_triplanar`, `tsg_unpackNormal`, `tsg_heightNormal`) are in `Engine/shaders/include/shadergraph.sh`, and hand-written shaders can call them too.

## Compute shaders

**Project > + > Compute Shader** makes a `.tcompute` file. Its code runs on the graphics card once for every pixel of a texture, each step: fast enough for ripples, fire, cellular automata or noise that a script could never do per pixel.

```glsl
property float speed = 1
property color ink = 0.2 0.6 1 1

compute {
    // Fade what was there, and draw a ring that grows from the middle.
    float ring = abs(distance(uv, vec2(0.5, 0.5)) - fract(time * speed * 0.2) * 0.7);
    result = result * 0.96 + ink * smoothstep(0.02, 0.0, ring);
    result.a = 1.0;
}
```

| Read | |
|---|---|
| `uv` | This pixel's place in the texture, 0 to 1. |
| `pixel`, `size` | The same in whole pixels, and the texture's size. |
| `time` | Seconds. |
| `previous(uv)` | The texture as it was before this step, anywhere in it. This is what makes simulations possible. |
| `neighbour(dx, dy)` | The texture before this step, so many pixels across and up from this one: `neighbour(1, 0)` is the pixel to the right. |

The shader graph functions (`tsg_noise`, `tsg_cells` and the rest, in `Engine/shaders/include/shadergraph.sh`) work here too.

Write `result`, which starts as this pixel's previous value. Add the line `precision high` to keep values as 16-bit floats instead of 8-bit colours, for simulations that need numbers outside 0 to 1.

**Without a script:** add a **Compute Effect** component to an object with a Mesh Renderer, and pick the file. It runs the shader every frame and shows the result as the object's texture. Fields: Width, Height, Steps Per Frame, Every Frame.

**From a script:**

```beef
let effect = GetComponent<ComputeEffect>();
effect.SetFloat("speed", 3);
effect.SetColor("ink", .(1, 0.3f, 0.1f, 1));
effect.everyFrame = false;
effect.Step();                         // run it once, when you choose

// Or without the component:
let shader = ShaderAsset.Load("Shaders/ripple.tcompute");
let texture = new ComputeTexture(512, 512);
if (Compute.Supported)
    Compute.Run(shader, texture);
renderer.TextureOverride = texture.Texture;
```

`Compute.Supported` is false on a dedicated server and on graphics cards without compute shaders; `Run` and `Step` then do nothing and return false.

### Compute graphs

**Project > + > Compute Graph** makes a compute shader from nodes: a shader graph that ends in a **Compute Output** node instead of a Surface Output. Saving it writes a `.tcompute` file beside it (hidden in the Project panel, as a shader graph's `.tshader` is), which a Compute Effect or `Compute.Run` uses like a hand-written one. It starts as drifting spots of ink that leave fading, spreading trails.

- **Compute Output** takes one colour: the pixel's new value (`result`). Leave it unconnected and the texture stays as it was.
- **Compute Input:** Previous (this pixel before the step), Previous At UV, Neighbour (so many pixels across and up), Neighbours Sum (the eight around it: count living cells for a Game of Life) and Neighbours Average (the four beside it: spreading, blurring, ripples), Pixel and Texture Size. UV and Time are under Shader Input.
- Everything that is only numbers works as it does in a shader graph: math, vectors, UV, noise, cells, gradients, custom code, Number and Color Properties, and subgraphs.
- Nodes that need a surface being drawn (World Position and Normal, View Direction, Rim, Vertex Color, the material's albedo and texture, texture and normal map properties, Triplanar, Normal From Height) say so if a compute graph uses them, and the compute inputs say so in a surface shader graph.

**Previews.** The canvas's corner runs the graph for real on a 256 by 256 texture, a step every frame, so a simulation can be watched as it is built; each node shows that texture seen through it. Changing the graph keeps the texture, so the simulation carries on with the new rules.

## Multiplayer

`SetMaterial` and `SetMaterialValue` (with `SetMaterialFloat` and `SetMaterialColor`) are shared like animation: called on the server, or by the player who owns the object, every machine follows, and players who join later get the current state. Editing a shared material from a script, and compute effects, are local to each machine: they are visual, and run from the same inputs everywhere.

## Visual scripting

All of it has nodes, generated from the engine source: **Engine > Render > Mesh Renderer** (Set Material, Set Material Float, Set Material Color), **Material**, **Compute Effect** (Set Float, Step) and the rest.

## Limits

- **Shader graph previews** show properties at their defaults, and texture properties as plain white.
- **Compute graphs** write 8-bit colours: for `precision high`, copy the generated `.tcompute` and add the line. They read only their own texture.
- **No environment maps.** Reflections use the scene's sky and ground colours, not an image of the surroundings, so a mirror-smooth metal shows a gradient, not the world.
- **Shadows ignore the vertex block and cutouts.** An object moved by its shader's `vertex` code casts the shadow of its unmoved shape, and a Cutout material casts a solid one.
- **Eight values and two textures** per custom shader, and it cannot replace the lighting itself.
- **Transparent** objects are sorted by their centres, so large overlapping ones can draw in the wrong order.
- **Compute shaders write one texture.** There are no compute buffers, and reading a compute texture back into a script is not supported.
- Voxel terrain and particles use their own colours, not materials. (Voxel objects take materials, outside and in: `docs/voxel-objects.md`.)
- Direct3D is not compiled for (see [Building for Windows](windows)).

## Tests

## Glowing in a model's own colours

A Mesh Renderer's **Emissive** colour and **Emissive Intensity** make the whole object glow in one colour. Tick **Emissive From Color** and the glow is multiplied by the surface's own colour instead (its vertex colours and texture): the bright parts of a model glow in their own colour and the dark parts stay dark. Set Emissive to white to keep the colours as they are. A model with a lit blade and a steel handle, say, needs no second mesh and no emissive map:

```beef
let renderer = GetComponent<MeshRenderer>();
renderer.emissive = .White;
renderer.emissiveFromColor = true;
renderer.emissiveIntensity = 2;
```

Custom shaders get it too: `emissive` arrives already multiplied.
