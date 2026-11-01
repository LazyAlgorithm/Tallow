# Textures: mipmaps and compression

Every texture the engine loads gets **mip levels**, smaller copies of itself down to 1 by 1. A surface far away or seen at a slant samples a level whose pixels match the screen's, so it stays even rather than breaking into moiré and shimmering as the camera moves. **Anisotropic filtering** keeps such surfaces (a floor, a road, a wall seen along) sharp.

A built game also gets **compressed copies** of its pictures, in formats the graphics card reads as they are: a quarter to an eighth of the video memory, and quicker to load, since nothing is decoded.

Nothing needs setting up; a project's pictures are used as they are.

## Mip levels

Mip levels are made when a texture is loaded, from what it holds:

| Kind | Which | Averaged |
|---|---|---|
| Colour | Albedo, emissive and interface pictures; anything not below | In linear light, as the eye sees it: a black and white checker shrinks to a mid grey, not a dark one |
| Data | A material's metal / roughness and occlusion maps, lightmaps | As stored |
| Normal | A material's normal map, a model's normal images, and pictures named with "normal" (`rock_normal.png`) | As directions, made unit length again |

`--no-mipmaps` loads textures without them, to compare (the Sandbox's `Scenes/Textures.tscene`, a checker floor, shows the difference).

## Compressed copies

**File > Build** (and `tools/build_player.py`) makes `<picture>.ktx` beside each picture: **BC1** for opaque ones and **BC3** for see-through ones, with all their mip levels, made by bgfx's `texturec` (which the editor package ships). The engine loads the `.ktx` in place of the picture; the picture stays in the build for code that reads its pixels (colour grading lookups, the window icon).

Left alone:

- normal maps (these formats store colours as 5-6-5 bits, which bands directions badly);
- pictures under `UI/` and `Fonts/` (the project setting `textureCompressExclude = UI/*;Fonts/*` in `project.tallow`, `;`-separated patterns);
- images inside glTF / GLB models;
- web builds (browsers do not all read the same compressed formats).

The Build window's **Compress textures** turns it off for a project (`compressTextures = 0`), and `--no-texture-compression` for one build. `python3 tools/compress_textures.py <folder>` compresses a folder by hand. A running game's log ends with how many textures it made, how many were compressed and their size on the graphics card. `--no-compressed-textures` ignores the `.ktx` files, to compare.

BC7, which looks better than BC1, is not used: bimg's BC7 encoder takes most of a minute for one 512 by 512 picture.

## Quality

Two quality settings (docs/quality.md) belong here:

| Setting | Low | Medium, High, Ultra |
|---|---|---|
| **Texture Detail** (`textureDetail`) | half (the largest level left out: a quarter of the memory) | full |
| **Anisotropic Filtering** (`anisotropic`) | off | on |

Texture Detail applies to textures loaded after it changes; the editor's **Window > Graphics Quality** shows it, and how many textures there are and their size.

## In code

```beef
let handle = Textures.Create(pixels, width, height, .Data);   // RGBA8 pixels, with mip levels
Textures.Hint("Textures/mask.png", .Data);                    // before it is loaded
let kind = Textures.KindOf("Textures/rock_normal.png");       // .Normal
```

## Networking

Nothing to send: textures are drawn by each machine for itself. A dedicated server loads none.

## Compatibility

Projects, scenes and materials are unchanged. Distant textures look smoother than before. Built games are larger by the `.ktx` copies (about the size of the pictures again) and use far less video memory.

## Limits

- Mip levels of large textures loaded in the background are made on the main thread when the texture is added.
- A colour texture whose kind cannot be told (a mask with an ordinary name) is averaged as colour; `Textures.Hint` says otherwise.

## Tests