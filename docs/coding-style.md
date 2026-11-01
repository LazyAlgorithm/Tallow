# Coding style

All Beef code in the engine, editor, launcher, tests and samples follows one style. Most of it is applied by a
tool, so you rarely need to think about layout:

```sh
python3 tools/format/format_code.py            # format every source file
python3 tools/format/format_code.py FILE...    # format just these
python3 tools/format/format_code.py --check    # list files that are not formatted (changes nothing)
```

The tool uses the Beef IDE's own formatter (the same as **Format Document** in the IDE), run once for each
platform so that code under every `#if` is reached. Before that it puts one statement on each line, writes out
chains such as `for (...) if (...) x;` with braces, and moves a control statement's body onto a line of its own;
afterwards it puts braces round a body that is itself a control statement, and blank lines after the `using`
lines, after `namespace`, and between the members of a type. It only changes whitespace (and adds braces), and it
puts every string literal back exactly as it was, so multi-line strings and generated-code templates are never
re-indented. A file where it would change anything else is left alone and named. It needs BeefBuild on `PATH`;
its formatter (`tools/format/BfFmt`) is built the first time.

`Engine/src/Platform/bgfx.bf` is generated from bgfx's own definitions and is left as bgfx writes it.

## Layout

- Tabs for indentation, braces on their own lines (Allman), one statement per line.
- Spaces around binary operators and after commas and keywords: `if (a == b)`, `Foo(x, y)`.
- A guard that only leaves may stay on one line: `if (mesh == null) return;` (or `continue;`, `break;`). Any
  other body goes on the next line.
- A body that is itself an `if`, `for` or `while` gets braces.
- A blank line between methods, properties and nested types.
- `using` lines, a blank line, the file-scoped namespace (`namespace Tallow;`), a blank line, then the types.

## Names

| What | Style | Example |
| --- | --- | --- |
| Types, methods, properties, events | PascalCase | `MeshRenderer`, `FindComponent`, `ActiveMesh` |
| Public fields of components and data assets (saved and shown in the Inspector) | camelCase | `castShadows`, `viewDistance` |
| Other public fields of plain classes and structs | either, matching the type's neighbours | `entry.bodyId`, `Time.DeltaTime` |
| Private and protected instance fields | `m` + PascalCase | `mComponents`, `mDirty` |
| Static fields | `s` + PascalCase | `sAll`, `sLayouts` |
| Constants (`const`, `static readonly`) | PascalCase | `MaxLights`, `DepthView` |
| Locals and parameters | camelCase | `gameObject`, `deltaTime` |

Do not give engine classes names a game is likely to use for its own (`Screen`, `Shell`): Beef puts a game's
code and the engine's in one program.

## Structure

- A method does one job, and reads as the steps of that job: when it grows past about 80 lines, or nests more
  than four levels deep, the steps become methods of their own, named for what they do (`RenderView.Render` is
  `GatherLights`, `GatherRenderers`, `DrawShadowCascades`, `DrawScene`... ). Values the steps share go in a small
  struct (`RenderView.Surface`, `CanvasView`, `AnimationWindow`'s `Timeline`) rather than in long parameter lists.
- An editor window's `Draw...` method opens the window and calls one method per part of it (toolbar, list,
  details); each part's method draws only that part.
- A type that has grown past about 800 lines is split by area into `extension` files named after it:
  `VoxelTerrain.bf` holds the fields and lifecycle, `VoxelTerrainStreaming.bf`, `VoxelTerrainSculpting.bf` and so
  on hold the rest. Each extension file starts with a `///` line saying what is in it.
- Numbers that mean something get a name: `const float ShadowBias = 0.0005f;`, `Gfx.TextureRenderTarget`, the
  zip record signatures in `Http`. A plain 0, 1, 0.5 or a layout size in an editor window can stay as it is.
- A list of cases that only differ in their data is a table, not a chain of `if`s (the Project panel's
  `sFileBadges`).

## Comments

- Every public type, and every public member whose name does not say it all, has a `///` comment saying what it
  is for, in plain words (with units: metres, degrees, seconds). A vector's `x` or an `operator +` needs none, and
  an overload set needs one comment, not one each. These comments are shown in the editor's code completion and
  on the generated visual-scripting nodes.
- Comments inside methods explain *why*, not what the next line does.
- British spelling is used throughout (colour, behaviour), except in names taken from other APIs.

## Performance habits

These are the patterns the engine relies on to stay fast in big scenes:

- Do not look through every component of a scene every frame. Use `Scene.FindComponent<T>()`,
  `Scene.ComponentsOfType(typeof(T))` or `Scene.FindComponents<T>(list)`, which read an index kept by class,
  or keep a static list of your own filled in `OnRegister` / `OnUnregister` (as `Foliage.All` does).
- Reflection is slow. `ComponentRegistry.GetFields` works out each class's fields once and caches them;
  call `ComponentRegistry.ClearFieldCache()` if you change classes at run time (script reload does).
- Look network objects up by id with `NetworkManager.FindIdentity`, not by searching `Identities`.
- Avoid `List.RemoveAt(0)` in a loop over a long list (each call moves everything after it); walk the list by
  index and `Clear` it afterwards.
- Something that is asked for every frame and can fail (a model that is not there) should remember the
  failure rather than try again every frame (see `Assets.GetMesh`).
- Work that only matters to what is drawn can wait while nothing draws it: `MeshRenderer.LastDrawnFrame` says when a
  renderer was last drawn in any view or shadow map (see `SkinnedMeshRenderer.ShouldSkin`).
