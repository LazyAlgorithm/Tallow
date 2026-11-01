# Model import: FBX, OBJ, DAE, STL, PLY, 3DS and .blend

Put a model file in the project's `src` folder (or drag it into the Project panel) and use it like a `.glb`: drop it
in the scene, name it in a Mesh Renderer's Mesh or a Skinned Mesh Renderer's Model. Scenes keep the file's own name
(`Models/knight.fbx`).

Behind the scenes the editor converts each one to glTF, the one format everything else reads: skinning, materials,
retargeting, LODs, rigging. It converts a file when it first sees it, and again when the file or its import settings
change. The converted copy is kept in `<project>/.cache/models/<path>.glb`, and nothing in `src` changes. Ignore
`.cache` in version control: it is made again on any machine.

| Format | Converted by |
| --- | --- |
| `.fbx`, `.obj`, `.dae`, `.stl`, `.ply`, `.3ds` | `tallow_modelconv`, Tallow's converter (built on the Assimp library, with the native libraries) |
| `.blend` | Blender, run in the background, so it must be installed |

`tallow_modelconv` brings FBX units to metres, keeps rigs (bones, skin weights, up to four bones a vertex), clips,
materials and the pictures they use (put into the `.glb`). A rigged model read as a plain mesh (a Mesh Renderer)
stands where its bones put it at rest, so it is the same size as on a Skinned Mesh Renderer.

Blender is found on the `PATH`, in its usual install folder (Windows and macOS), or at the path in the
`TALLOW_BLENDER` environment variable. A source checkout of the engine whose native libraries were built before the
converter was added falls back to Blender, or to Assimp's `assimp` tool if it is installed (OBJ, STL, PLY, DAE, 3DS).

## Import settings

Click the model in the Project panel. The Inspector shows:

- **Scale**: multiplies the whole model.
- **Z axis is up**: for files made with Z up (3ds Max and many STL, PLY and 3DS files). Turns the model a quarter
  about X so that it stands up.
- **Materials**: off leaves the file's materials and pictures out. The renderer's own fields or Material decide the
  look.
- **Animations**, with a box for each clip: which clips come in.

**Apply** writes them beside the file as `<file>.import` (hidden in the Project panel) and converts it again. Changing a
setting re-runs only that step, not the whole conversion. **Reimport** converts from scratch. A file that fails
says why in the Inspector and in the Console.

The settings step is the same whichever converter ran: `tn_model_import_settings` (`native/tallow_modelimport.c`)
rewrites the converted `.glb`.

## Materials on Mesh Renderers

A Mesh Renderer showing a model with materials of its own (several materials, or pictures) draws each with its own
material and textures, as a Skinned Mesh Renderer does. This applies to any glTF, not only converted ones. To draw the
whole model with the renderer's own fields instead, turn off **Use Model Materials**, or set a Material or a Texture
on the renderer. The renderer's Color still tints every part.

## Builds

`tools/build_player.py` converts what is out of date (`tools/convert_models.py`, with the same converters, cache and
settings, using `tallow_modelconv` and `tallow_modelsettings` from the native build; engine packages include both). It puts each model in the game as `<file>.glb`, and
leaves the source file and its `.import` out. The engine looks for that name when a scene names the source file.
A build on a machine without a needed converter (Blender for a `.blend`) stops and names the file.

`python3 tools/convert_models.py <project>` converts a project's models without building.

Maps made in a game's map editor carry the files they use. Use `.glb` models there, as a game has no converter.

## Test switch

`--model-import-test [--model-import-fbx <rigged .fbx>]` writes an OBJ, an STL, a DAE and (with Blender) a `.blend`
into the project. It converts them and checks size, Scale, Z up, a Mesh Renderer showing one, two materials with a
picture, Use Model Materials, and an edited file being converted again in the background. With an FBX it also checks
bones, real-world size, clip choice, and leaving out animations and materials. It then removes what it made and logs
`MODEL-IMPORT-TEST PASS` or `FAIL`.

## The bundled Assimp

`third_party/assimp` is Assimp 6.0.2 with its `test`, `samples`, `doc`, `port` and `fuzz` folders left out (the build
does not use them). One change: the "©" in `include/assimp/revision.h.in` is written "(c)", as the Windows resource
compiler takes plain ASCII only. Only the FBX, OBJ, Collada, STL, PLY, 3DS and glTF readers and the glTF writer are
built (`native/CMakeLists.txt`).
