# Roadmap

Status on 2026-10-13, and the work agreed and queued, in order.

**How to use this page.** Work happens on `dev` (Tallow and the games), and reaches `main` only once it is checked.
Each queued item is a checkbox: `[x]` done (with the date and the commit), `[~]` in progress (with notes on what is
built and what is left, so anyone can pick it up), `[ ]` not started. Tick an item in the same commit that finishes
it. Every engine feature is only done when it has:

- a way to adjust it in the editor (Inspector fields, a window or a tool), wherever that makes sense;
- a `docs/` page (or a README section), which is what the project website shows;
- networking, where the feature has anything that must be the same on every machine (and a note in its page saying
  so either way);
- a `Tests/` fixture, a line in the README feature list, and compatibility with existing scene and project files.

The website is the GitHub Pages site on this repository's `gh-pages` branch (one page, `index.html`). Its **Manual**
documents each feature in a section of its own (an `h2` with an id, linked from the Manual's sidebar; the site's
search picks it up). A feature on `dev` but not yet in `main` says so in its section.

## Done

- Terrain redesign (tiles, generators, LOD, undo); faster CI that caches the native libraries and compilers
- Ringfall: aim assist per weapon and per control type, auto-fire buffer
- Layers, tags and world states. World states now cover collision, drawing, shadows, lights, particles, sound and
  navigation, with a world state menu in the editor toolbar
- HTTPS downloads and zip extraction in the engine (`docs/http.md`)
- Built games: `windowWidth`, `windowHeight` and `escapeQuits` in `project.tallow`; engine releases carry
  `SHA256SUMS.txt`
- **Responsive UI and mobile controls** (2026-10-13, `dev` and `main`): the web canvas sized correctly (it was a
  1600×900 window on phones), SDL following resizes in fullscreen (a phone turned after play started was
  stretched), `@media` rules in UI stylesheets, text measured at the width it is drawn, touch controls in the
  screen's short side, dimmed buttons, sticks hidden until used, flicks (`AddSwipe`), phone 3D resolution by the
  short side. Ringfall: portrait and landscape layouts for every phone screen and the HUD, buttons-only touch
  controls around FIRE, mantling per input type. Docs: `responsive-ui-design.md`, `input.md` (touch), Ringfall's
  `mobile-controls-v2.md`. Website: Manual > Touch screens, Phones and tablets.
- **Tallow Hub** (github.com/LazyAlgorithm/tallow-hub): installs, updates and starts Ringfall and the engine,
  checks for and installs the tools they need after asking, beta badges and a beta-builds setting, and updates
  itself. Linux and Windows builds are on its Releases page. Tested on Linux: browsing, the tools dialog, installing
  the engine, starting it, settings. Windows built but not yet tried on a real Windows machine.

## Manual steps

1. **Add the `RELEASES_TOKEN` secret to the Ringfall repository** (Settings > Secrets and variables > Actions). It is
   a fine-grained personal access token with *Contents: Read and write* on `LazyAlgorithm/ringfall-releases`. Until
   it is there, Ringfall builds skip the public release (the run shows a notice), so the Hub shows "No release yet"
   for Ringfall. After adding it, push Ringfall to its `release` branch (or run its workflow) once.
2. Try the Hub on Windows: unzip TallowHub-Windows.zip from the tallow-hub Releases page and run TallowHub.exe.
3. Optional: try Tallow on a real Mac (E18, `docs/macos.md`); the Hub has no macOS build yet. macOS CI builds are paused
   (2026-10-27, `macos.yml` runs only by hand) until a Mac is available to check them.

## Queued

Work agreed and queued, in order (see *How to use this page* above for what "done" means).

## Shatterline engine features (general-purpose first)

- [x] E6 first-person viewmodel layer (2026-10-13, `dev`): Camera's Viewmodel Layer / Field Of View / Near Clip /
  Casts Shadows (Inspector, `[Layer]` drop-down), its own render pass over the world, an amber gizmo frustum,
  `docs/viewmodel.md`, `Tests/Viewmodel`. Networking: none needed (local camera only). Ringfall uses it.
  Website: Manual > First-person viewmodel.
- [x] E7 materials on skinned meshes (2026-10-13, `dev`): the glTF loader reads each material whole and decodes
  its images (in a .glb, data: addresses, files beside it); a rigged model with several materials or textures is
  drawn in parts sharing one skinned vertex buffer (`Mesh.VertexSource`, `MeshRenderer.RuntimeParts`), each with
  the file's material or a `.tmat` per part (Inspector list, `SetPartMaterial`, networked). `docs/skinned-materials.md`,
  `Tests/SkinnedMaterials` (with a model generator). Website: Manual > Materials on skinned meshes.
  Not yet: static (unrigged) models still take one material from their Mesh Renderer; the same parts would do it.
- [x] E6b viewmodel pose (2026-10-13, `dev`): the Viewmodel Pose component (hip and aim poses, aim speed, walk bob
  and sway from the camera's movement, steadier when aiming, recoil with `Kick`), Preview slider and "Use current
  place as Hip / Aim" buttons in the Inspector, `docs/viewmodel.md`, `Tests/Viewmodel`. Networking: none needed.
  Website: Manual > First-person viewmodel.
- [x] E10 post-processing (2026-10-13, `dev`): ambient occlusion, depth of field (with auto-focus), camera motion
  blur and colour grading (contrast, saturation, temperature, tint, colour filter, vignette, lookup tables) as scene
  settings, from a depth pass that leaves the viewmodel alone. Inspector: Scene Settings > Screen Effects and Color
  Grading (Make Neutral Lookup Table). Players' settings: `ScreenEffects` (off on phones). RenderViews now use 17 view
  ids. `docs/post-processing.md`, `Tests/PostProcessing`. Website: Manual > Screen effects.
- [x] E9 async scene and asset loading (2026-10-14): `SceneManager.LoadAsync` / `LoadAdditiveAsync` (stages, Progress,
  allowActivation, Activate), `AssetLoader.Preload` and batches; models, rigged models and textures read and decoded
  on two loading threads, sent to the graphics card within `AssetLoader.UploadBudget` a frame (inline in a browser);
  what a scene names found through its prefabs, scenes and materials. The Scene Loader component (Inspector, scene
  picker, `progress` for a loading bar). Networking: none needed (every machine loads for itself). `docs/loading.md`,
  `Tests/AsyncLoading`. Website: Manual > Loading in the background.
- [x] E4 animation layers and blend trees (2026-10-14): controller layers (each a state machine; weight, Override or
  Additive, a bone mask by name), 1D and 2D freeform blend trees (gradient band weights, clips kept in step), for
  `.tanim` clips and for rigged models' clips with Expose Bones; controllers without them run as before. Animator
  window: Layers list with weight (live), blending and mask; Clip or Blend Tree per state with parameters, clips,
  thresholds or positions and a live diagram. `SetLayerWeight`, `StateIndexOn`, `NormalizedTimeOn`. Networking:
  layer weights follow the owner (states and parameters already did). `docs/animator.md`, `Tests/AnimationLayers`.
  Website: Manual > Animation layers and blend trees.
- [x] E5 inverse kinematics (2026-10-13, `dev` and `main`):
  Limb IK (two-bone arms and legs with a pole, the hand locked to a target's rotation with an offset and a grip
  point, `LetGo` / `Grab` / `SetTarget` so that each arm is freed and returned by itself), Look At IK (head, neck
  and spine sharing the turn, within a limit), Foot Placement (feet on uneven ground, hips lowered, feet tilted),
  Hand Pose (a curl slider for each finger, spread, trigger, ready-made shapes), and `IKSolver` for code (two-bone,
  chains of any length, look-at). A layer over the Animator's pose with a weight, solved after every LateUpdate and
  in the editor; `Expose Bones` on the Skinned Mesh Renderer makes bone objects so that rigged models take part.
  Inspector tools (find hands and feet, Make Target And Pole, Keep Hand's Rotation, shape buttons), Scene view
  gizmos, **Key IK** in the Animation window and recording that ignores IK. Networking: weights and hand shapes
  follow the owner; targets are ordinary objects; the rest is worked out on each machine. `docs/ik.md`, `Tests/IK`.
  Website: the Manual section is still to be written (it lives on `gh-pages`).
  Not yet: joint limits, stretch, a component for chains longer than two bones, fingers wrapping round a shape.
- [x] Terrain: dual contouring, finer ground, brush preview (2026-10-13): Style **Contoured** (one point a cell,
  quads between; seamless across chunks, with level of detail and full-detail collision) and **Contour Sharpness**;
  new terrains are contoured, half-metre voxels, smoothly shaded, with **Flat Shading** for the faceted look and
  Style Smooth for marching cubes; a preview mesh under the brush in the Scene view; generation settings taken out
  of the editor (a terrain there is its tiles; generators are the game's code). `docs/terrain.md`, `Tests/Terrain`.
- [x] Foliage and wind (2026-10-13): the Foliage component (painted, instanced plants; built-in grass, bush, tree
  and pine) with its brush in the Inspector, Wind Zone components (global and sphere), `Wind Sway` on Mesh
  Renderers, bending in the mesh vertex shader. `docs/foliage.md`, `Tests/Foliage`. Networking: scene data, the
  same everywhere; `Wind.At` for code. Not yet: plants with colliders.
- [x] Editor: number fields can be typed into (click, or double-click a slider); the UI tab shows the whole document
  scaled to fit, with named placeholders for canvases (`preview`, `preview-src`).
- [x] Destructible objects from any model (2026-10-13): Voxel Object Shape **Mesh** fills a closed model in as solid
  material, keeping its size, colours and texture coordinates; the outside takes the Mesh Renderer's material and
  the inside an Interior Material or one made from the outside's. `docs/voxel-objects.md`, `Tests/VoxelObject`.
- [x] Foliage follow-ups (2026-10-13): a Foliage tool in the Terrain Tools, undo and redo for brush strokes (applied
  in place), shadows and the depth pass bending in the wind with the plants.
- [x] Foliage: parting round players and following sculpting (2026-10-13): plants bend away from every Character
  Controller and from Foliage Bender components (eight nearest the camera, in the shared wind shader; nothing sent
  over the network), and plants on a terrain ride sculpted ground up and down, removed when buried or left with
  nothing under them, each judged from its own foot so that caves are left alone. `docs/foliage.md`,
  `Tests/Foliage`, `Tests/Terrain`.
- [x] E5b animation retargeting (2026-10-24): play clips made for one rig on another (a shared humanoid bone map,
  matched by name with a Bone Map window to fix the matches, bone lengths, rolls, rest poses and facings allowed to
  differ, hips movement scaled by leg length); the Animator plays any retargeted clip, and networking already sends
  clip and state, not bones. With it, at the user's request: bones drawn and clickable in the Scene view, an IK rig in
  one press with handles, IK snapping and baking, model clips copied into editable ones, and Hand Posing for fingers.
  `docs/retargeting.md`, `Tests/Retargeting`, editor `--rig-test`.
- [x] E11 decals (2026-10-24, `dev` ec61835): a Decal component projects a picture onto the solid scene inside its box (lit,
  shadowed and fogged like the surface, with an angle limit, opacity, unlit and draw order), sharing the depth pass
  with the screen effects and the mesh shader's lighting (`Engine/shaders/include/lighting.sh`); GameObject > Decal,
  Stick to Surface and box picking in the editor; `Decals.Spawn` for pooled short-lived decals, made on every machine
  rather than sent. `docs/decals.md`, `Tests/Decals`, decals in the Sandbox Main scene.
- [x] E12 dialogue and subtitles (2026-10-25, `dev` ff0cb48): `.tdialogue` conversations (speakers, nodes of lines, answers,
  variables, events, jumps and conditions) edited in a Dialogue tab with a preview, played by a Dialogue Runner
  (subtitled lines with voice recordings, answer buttons, keyboard and controller input, kept in saves); Subtitles
  for any sound with an `.srt` beside it or from code, with player settings and captions; a Shared conversation is
  run by the server for everyone. `docs/dialogue.md`, `Tests/Dialogue`, a guide in the Sandbox Main scene.
- [x] E13 sequencer (cutscenes) (2026-10-25, `dev` d1afaf9): `.tsequence` timelines with Transform, Camera (shots and blends),
  Animation, Audio, Show / Hide, Event, Subtitle and Fade tracks, edited on a timeline in the Sequencer tab (scrub
  and play preview on the scene, look through shots, K to key the selected object), played by a Sequence Player
  (pause, skip, seek, loop, restore, saving; `Scene.CameraOverride` / `ViewCamera`); Shared sequences are timed
  by the server for everyone. `docs/sequencer.md`, `Tests/Sequencer`, an intro cutscene in the Sandbox.
- [x] E14 navigation upgrades (2026-10-25, `dev` 424c265): any-angle path smoothing that keeps the grid's clearance; Navigation
  Links (jump, climb, teleport, walk; one-way; cost; agents cross them with events); Navigation Obstacles that carve
  the grid while still and are steered round while moving; Navigation Areas (costly or blocked); local avoidance
  between agents with priorities; SamplePosition, RandomPoint, Raycast, RemainingDistance; Inspector tools and
  gizmos, `--bake-navigation`. `docs/navigation.md`, `Tests/Navigation`, `Scenes/Navigation.tscene` in the Sandbox.
- [x] E15 behaviour tree upgrades (2026-10-25, `dev` fc15e1a): Run Subtree (other files run in place, shared blackboard, shown live,
  Open / New Subtree File, loops refused), tree files read once and shared by all runners; Event Received and Send
  Event (`SendEvent`, `OnTreeEvent`); hearing (`AINoise.Make`, Heard Noise); `#Tag` targets; Can See Sight Points;
  Set / Compare Number, Remember Position, Start Values; Chance, Random Selector, Run Once; Wander on reachable
  points; Ctrl+D duplicate in the Behavior tab. `docs/behavior-trees.md`, `Tests/BehaviorTree`, a guard in the
  Sandbox Navigation scene.
- [x] E16 LOD, occlusion culling, GPU skinning (2026-10-25, `dev` e735b28): LOD Groups pick a level per camera from screen height
  (levels from `_LOD<n>` children or meshes simplified at load, Cull Below, `LODGroup.Bias`, Preview and
  `--lod-level`); occlusion culling per camera from a small CPU depth picture of the biggest solid occluders
  (Auto / Always / Never per renderer, conservative edges, Scene view toggle, statistics and picture); GPU skinning
  with a compute shader writing the vertex buffers every pass uses, bounds from joints, CPU fallback and
  `--cpu-skinning`. `docs/lod.md`, `docs/occlusion-culling.md`, `docs/gpu-skinning.md`, `Tests/Culling`,
  `Tests/GpuSkinning` (with `run.py`), Sandbox `Scenes/Culling.tscene` and `Scenes/Skinning.tscene`.
- [x] E20 quality presets (2026-10-25, `dev` 04e4ed8): `Quality` with Low / Medium / High / Ultra (High is the old defaults) setting
  render scale, antialiasing, shadows (on, map size, distance), screen effects, LOD bias, foliage distance, GPU
  skinning and vsync at once; Custom when changed one by one; the player's choice saved in `graphics.cfg` and applied
  at start; `Quality.Recommended` for the machine; `--quality`; editor Window > Graphics Quality. `docs/quality.md`,
  `Tests/Quality`.
- [x] E18 macOS (2026-10-25, `dev` 82d4c91): Tallow builds, tests and runs on Apple silicon with Metal: a macOS CI job builds Beef
  from source, the native libraries, every headless fixture (all pass; `tools/run_tests.py`), the packaged editor
  and the Sandbox drawing with Metal (GPU skinning included); `tools/macos_link.py` link settings for every project;
  `build_player.py` / `package_engine.py --platform macos` and a macOS target in File > Build on a Mac; macOS
  versions of the anti-cheat guard's checks. `docs/macos.md`. Not yet run on a real Mac by a person.
- [ ] E19, E21 (not described yet: to be agreed)

## Higher-quality rendering (after the above, one at a time)

1. [x] Texture mipmaps and GPU texture compression (2026-10-25, `dev` 500ca7c): mip levels for every texture (colour averaged in
   linear light, data as stored, normal maps as directions; kinds from material slots, model materials and names),
   anisotropic filtering; builds add BC1 / BC3 `.ktx` copies with mips (`tools/compress_textures.py`, texturec),
   used in place of the pictures; Texture Detail and Anisotropic Filtering quality settings; Build window Compress
   textures. `docs/textures.md`, `Tests/Textures` (with `run.py`), Sandbox `Scenes/Textures.tscene`.
2. [x] Image-based lighting and reflection probes (2026-10-25, `dev` 7c7853f): a sky cube made from the scene's sky and
   Reflection Probe components (box, blend distance, box projection, importance, size, refresh), captured over a
   few frames and GGX-filtered into rougher mip levels; the shared lighting mirrors them for every surface (split-sum
   fit), with Ambient From Surroundings for image-based ambient light; Reflections scene setting, Reflection Probes
   and Reflection Size quality settings, `--no-reflections`. `docs/reflections.md`, `Tests/Reflections` (with
   `run.py`), Sandbox `Scenes/Reflections.tscene`.
3. [x] Shadows from point and spot lights, and more lights per view (done locally 2026-10-27, not pushed): clustered
   lights (`LightClusters`: 16 x 9 x 24 clusters per view, up to 256 point and spot lights in view, the nearest kept,
   32 per pixel; lights, shadow tiles and lists in one float texture per view read by `include/lighting.sh`); point
   light shadows (six cube-face tiles) and spot light shadows in one shared atlas drawn in a single view with a scissor
   per tile (a RenderView now uses 19 bgfx views, not 34); Quality's Shadowed Lights (2 / 4 / 8 / 16),
   `--shadowed-lights`; the Scene view counts lights and shadow tiles; the editor compiles custom shaders again when
   the engine's shader files are newer. `docs/lighting.md`, `Tests/Lighting` (with `run.py`), Sandbox
   `Scenes/Lighting.tscene`. Still to do: push to `dev` and a Manual section on the website, when the user says.
4. [x] Baked lighting and global illumination (done locally 2026-10-27, not pushed): `LightBaker` (CPU, rays traced in a
   native BVH, `native/tallow_bake.cpp`): lightmaps for Mesh Renderers with Baked Lighting ticked (sky, Baked Only
   lights with shadows, bounced light and glow, remembered hits so each bounce is lookups, an edge-aware smoothing
   pass, RGBM PNGs) and a light probe grid (first-band spherical harmonics in a 3D texture, blended per pixel) for
   everything else; lightmap coordinates made by the engine the same way every time (`LightmapUV`, with copies for
   objects stretched unevenly); the editor's Window > Lighting (bakes in the background, settings saved with the
   scene), `--bake-lighting`, `--lighting-window`, `--no-baked-lighting`. `docs/baked-lighting.md`, `Tests/Baking`
   (with `run.py`), Sandbox `Scenes/BakedLighting.tscene` (baked).

## Editor

- [x] Built-in 3D modeller (asked for 2026-10-26: "make a game entirely in the engine"), for low-poly props and maps.
  Done locally 2026-10-26 (not pushed): `Engine/src/Modeling` (EditMesh, MeshShapes, MeshOps, MeshCsg, MeshUV,
  GlbWriter, the Model Mesh component, `.tmesh` assets), the editor's Model window, Tab edit mode, shape drawing,
  vertex colour painting and UV Editor (`Editor/src/Modeling`), `docs/modeling.md`, `Tests/Modeling`, `--model-test`.
  Second pass, also local: a key for every tool, a right-click tool menu, Space search and an F1 sheet; tools that
  follow the pointer (grab/rotate/scale with axis holds and typed amounts, extrude, inset, bevel, loop cut and slide,
  knife); proportional editing and live mirroring; Alt+click loops, Ctrl+click paths, grow/shrink/invert, hiding;
  poke, triangulate and back, solidify, smooth, collapse, make face; restyled selection (thick outlines, active and
  hovered elements, face dots, depth-tested fills).
  Third pass, also local (2026-10-26): rounded bevels (segments, smooth fans in the corners), edge slide (G G) and
  vertex slide (Shift+V), knife points inside faces; the UV Editor picks pieces or points, pins (kept by unwrapping,
  saved as `pin` lines in `.tmesh`) and stitches; palette and atlas cells (Ctrl+click, New Palette Texture); texture
  painting in the Scene view (`TexturePaint`, `Assets.ReplaceTexture`); Make Levels of Detail (`MeshOps.Decimate`,
  `_LOD<n>` children, and a LOD Group now treats its own renderer as level 0 when nothing is `_LOD0`). Tests: 25 new
  checks in `Tests/Modeling`, 9 in `--model-test`, one in `Tests/Culling`.
  Everything in the plan below is now in. Still to do before it counts as shipped: push to `dev` and a Manual
  section on the website (`gh-pages`), when the user says. The plan was:
  one editable-mesh core used in two places:
  - **Scene view whiteboxing**: block-out shapes (box, wedge/ramp, stairs, cylinder, arch, door and window cut-outs)
    drawn straight onto the grid or a surface, face pushing/pulling with snapping, boolean subtract/merge, world-aligned
    texturing that stays put as shapes are resized, collision made automatically, and "Convert to Model" to finish
    one in the Model window.
  - **Model window**: vertex/edge/face/object modes; extrude, inset, bevel, loop cut, knife, bridge, fill, merge/weld,
    split, subdivide, mirror (live symmetry), array; primitives; pivot, origin and transform tools; smooth/flat
    shading and hard edges; per-face materials; undo throughout.
  - **UVs and texturing**: mark seams, unwrap (angle-based / conformal), box, planar and cylinder projection, a UV
    editor (move, scale, rotate, pin, stitch, pack, checker preview), atlas/palette texturing in the Synty style,
    texture painting on the model, and vertex colours.
  - Saved as `.tmesh` source plus an exported `.glb`, with LODs and colliders from the existing tools; docs, tests.
- [x] Themes: theme files, built-in themes (dark, light, high contrast, Tallow blue), a Theme page in Preferences
  with live colour pickers, import and export. Done locally 2026-10-27 (not pushed): `Editor/src/App/EditorTheme.bf`,
  Edit > Preferences (`Editor/src/Tools/PreferencesWindow.bf`), `.ttheme` files, light code editor colours,
  `docs/themes.md`, `Tests/Themes`, `--theme`, `--preferences`, `--theme-test`. Later the same day: Tallow Blue
  made the default; Forest, Ember and Plum added.

- [x] Rigging and weight painting, Mixamo-style, for people and four-legged animals (requested 2026-10-27, before the
  shader graph). Done locally 2026-10-27 (not pushed): Window > Rigging (`Editor/src/Animation/RigEditor.bf`), markers
  for Humanoid (Mixamo bone names, 25/41/65 bones) and Quadruped (spine, neck, tail, ears, jaw), Custom rigs, bone
  editing with symmetry, bone-heat automatic weights (`native/tallow_rig.cpp`), a weight painting brush (add,
  subtract, smooth, set, mirror), posing, `.trig` rig files and `_Rigged.glb` export (`Engine/src/Rigging/`),
  `docs/rigging.md`, `Tests/Rigging`, `--rigger`, `--rigger-step`, `--rigger-test`.

- [x] Rigging follow-ups (2026-10-27, local): CC0 test models by Quaternius in the Sandbox (person, husky, pug),
  fingertip markers for people, a Head marker for animals, quadruped neck/tail guesses from the body's shape, joints
  centred in legs, one rest facing for every exported skeleton (clips shared between rigs made here), Model and
  Rigging docked beside the Inspector in the default layout (`--reset-layout`).
- [x] Modeller follow-ups (2026-10-27, local): Show Only This Model in edit mode (on by default, `/`), and every
  modelling shortcut editable in Edit > Preferences > Modelling (`Editor/src/Modeling/ModelShortcuts.bf`).
- [x] Modelling views (2026-10-27, local): only the edited model's gizmos with Show Only, reference images (front,
  back, sides, top, bottom; editor views only), the Scene view's view selector (axes, perspective/orthographic), and
  Window > Model Views: four views (Top, Front, Left, Perspective) to model in, as 3ds Max has.
- [ ] Hierarchy visibility and locks (requested 2026-10-27): an eye beside each object in the Hierarchy hides it in
  the Scene view only (not disabled, still in the game and the Game view), as Unity's; holding the button down and
  dragging over others hides (or shows) each one passed over; on a parent it takes the children too. A lock beside it
  makes an object unpickable in the Scene view (still selectable in the Hierarchy), with the same drag. Both are kept
  per user, not in the scene.
- [ ] Model format conversion (requested 2026-10-27): FBX, OBJ, DAE, STL, PLY, 3DS... and `.blend` files used
  directly in the project, as Unity does. Each is converted behind the scenes to a cached `.glb` on import and again
  when the source changes (ufbx or assimp in the editor; Blender run in the background for `.blend`, so it must be
  installed). Everything that reads models (skinning, materials, retargeting, LODs, rigging) keeps one path, and
  builds ship the converted models. Rigged models' bones, clips and materials carry over; an Inspector page shows the
  import settings (scale, axes, which clips, materials). Mesh Renderers also use a glTF's own textures (only Skinned
  Mesh Renderers do now).
- [ ] World streaming (asked about 2026-10-27): one large open world built in the editor as one scene, split
  automatically into grid cells that load and unload around the player (and every player, on a server) with no code,
  in the style of Unreal's World Partition. Cells load in the background and are added over several frames so there
  is no hitch; far cells show merged low-detail stand-ins; a floating origin keeps precision far from the centre;
  terrain, foliage, navigation and baked lighting stream per cell; objects can opt out (always loaded) and Streaming
  Sources can be added (a camera, a vehicle). The editor loads only the cells round the view, with a map to pick
  others. Builds on what exists: background loading, additive scenes, and voxel terrain's chunk streaming.
- [ ] Profiler (requested 2026-10-27): like Unity's Profiler window, with more profilers, covering every part of the
  engine. A timeline of frames (CPU, GPU, frame time) to scrub and pause on, a hierarchy and flame chart of the picked
  frame (every system and every script method, with calls, self and total time, allocations), and modules for
  rendering (draws, instances, triangles, passes, shadow tiles, GPU time per pass), memory (by kind and by asset,
  snapshots to compare), physics, animation and skinning, audio, networking (bytes and messages per channel,
  prediction and rollback), navigation and AI (behaviour trees), UI, particles, scripts and hot reload, asset loading
  and streaming, the job system's threads, and garbage. Profile the editor, play mode, or a running build over the
  network (a dedicated server too); save and load captures; `Profiler.Begin/End` markers and counters for game code.

## Last

- [ ] Shader graph: materials' shaders built from nodes, on the existing node editor
- [ ] Visual compute shaders: compute shaders built from nodes
- [ ] Soft bodies (requested 2026-10-27, last): cloth (flags, capes, curtains, sails; pinned to bones or objects,
  wind, collision with colliders and characters, tearing optional) and deformable bodies (jelly, rubber, soft tyres,
  dented metal) that push and are pushed by rigidbodies. Simulated on the job threads (Jolt has soft bodies), with
  an editor for pins and stiffness painted on the mesh, and networking like the predicted physics props.
