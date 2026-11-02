# Tallow

<img src="icon.png" width="96" alt="Tallow icon">

A 3D game engine and editor written in [Beef](https://www.beeflang.org), supporting a broad range of 3D game styles, from stylized worlds to realistic environments, with voxel terrain and server-authoritative multiplayer.

## Build and run

See [Building from source](docs/building-from-source.md) for prerequisites and complete Linux and native Windows instructions. Python 3.11+, CMake, Ninja, a C/C++ compiler and the Beef toolchain are required; Windows also needs the MSVC libraries/Windows SDK and clang-cl.

Linux:

```sh
./build.sh --config Debug
./build/Debug_Linux64/TallowLauncher/TallowLauncher
```

Windows, from an x64 Visual Studio developer shell:

```bat
python tools/build.py --config Debug
build\Debug_Win64\TallowLauncher\TallowLauncher.exe
```

Opening a project compiles its scripts and starts its editor. `Samples/Sandbox` is a ready-made voxel playground. Choose **Tallow Gallery (showcase of eight areas)** to create the complete editable showcase. The repository and generated projects support paths containing spaces.

## Portable editor packages (early beta)

After building the native dependencies, create a clean editor folder with:

```bash
python3 tools/package_engine.py --platform linux --folder dist/Tallow-Linux
python3 tools/package_engine.py --platform windows --folder dist/Tallow-Windows
```

Windows builds from Linux use the toolchain prepared by `tools/windows/setup.sh`.
On Windows, use `python` instead of `python3` and build the Windows native libraries first.
The editor's Build window also uses this packager when **Build: Editor** is selected.

Start `Tallow` on Linux or `Tallow.exe` on Windows directly from the package folder.
The folder can be moved: it includes assets, templates, shaderc, and the engine/editor
source and native archives needed to compile project scripts. It excludes native
dependency source, tests, samples, website files, object files, and debug symbols.
BeefBuild and Python 3.11+ remain prerequisites for editing and building projects;
Windows also needs Microsoft C++ Build Tools. System graphics drivers are required.
`--skip-build --config Debug` explicitly packages a previously built debug launcher;
normal packages build a fresh Release launcher and stop if the compiler fails.

## Editor

| Panel | What it does |
| --- | --- |
| Hierarchy | Object tree. Drag to re-parent, right-click to create, duplicate or delete. Folders (GameObject > Folder) group objects without having a transform or components. |
| Scene | Right-drag to fly (WASD, Q/E, Shift; the wheel sets the speed), middle-drag to pan, wheel to dolly, F to frame. W/E/R/T switch Move/Rotate/Scale/All; the toolbar's Snap (or holding Ctrl) snaps to steps you set. End drops the selection onto the surface under it, [ and ] turn it, Space opens Quick Add. New and dropped objects stand on the surface under the mouse. Window > Dragging a prefab or model over the view shows it there before it is dropped; see `docs/map-building.md` and `docs/drag-and-drop.md`. |
| Game | What the first enabled Camera sees. Click it while playing to send input to the game. A game that locks the mouse (`Input.LockCursor`) keeps it inside this view; Esc frees it, and the toolbar's Lock Mouse button turns locking off altogether. |
| Inspector | Components and their public fields. With nothing selected it shows the scene's lighting, sky and fog. |
| Project | Folder tree and icon grid. Materials and shaders are shown as a ball drawn with them, and models and prefabs as a rendered picture of themselves. Click a material to edit it in the Inspector; double-click a prefab to edit it on its own. Drag models into the Scene or Hierarchy, images onto a Texture field, items onto folders to move them, and files from your desktop into the window to import them. |
| Scripts | Code editor (Visual Studio dark or light style, following the theme): syntax colouring, bracket matching, foldable blocks, find/replace, completion that knows the engine and your scripts (type `Audio.` or `myLight.` for its members), undo/redo. Double-click a script in Project to open it. Saving compiles in the background and marks errors on their lines. |
| Behavior | Behaviour trees for AI, drawn like graphs and shown live while the game plays; see `docs/behavior-trees.md`. |
| Graph | Visual scripting. Right-click to add nodes, drag between pins to connect, Alt+click a pin to disconnect, Delete removes a node, middle-drag pans, the wheel zooms at the mouse. Save also compiles the graph into a Beef component. |
| UI | Visual editor for `.tui` interface documents: element tree, live preview, properties and stylesheet. |
| Console | Engine and script log. |

Edit > Preferences picks the editor's theme (Tallow Blue by default, Dark, Light, High Contrast, Forest, Ember, Plum or your own), with a live picker for every colour and `.ttheme` import and export; see `docs/themes.md`.

In the Hierarchy, the eye beside an object hides it from the Scene view alone, and the lock keeps clicks in the Scene view from selecting it (drag down the column to set many at once); see `docs/scene-visibility.md`.

FBX, OBJ, DAE, STL, PLY, 3DS and `.blend` files work like `.glb` models: the editor converts them to glTF behind the scenes, with import settings in the Inspector, and builds ship the converted copies; see `docs/model-import.md`.

Large open worlds stream: tick Stream This Scene and the scene is saved as a grid of cells that load round the players in the background, with merged stand-ins in the distance, a floating origin and a World Map in the editor; see `docs/world-streaming.md`.

Play, Pause and Step are in the toolbar. Play mode never changes the saved scene. Ctrl+Z / Ctrl+Y undo and redo scene edits.
Script edits reload automatically while the editor runs (see the script reload page). `File > Reload Scripts` (Ctrl+R) forces a reload, `File > Full Rebuild & Restart` is needed after engine or project-settings changes, and `File > Build Game (Release)` makes a release executable.

### Terrain tools

GameObject > Voxel Terrain adds one flat 128 m tile. Pick **Tiles** under Terrain Tools in the Inspector to add tiles beside it (or apart from it), move and remove them; pick Raise, Lower, Smooth, Flatten or Paint and drag in the Scene view to sculpt across tiles as one surface. Undo covers both. A game supplies its own generator classes to shape ground or bake into chosen tiles; Endless mode generates around the camera without end. Sculpting is saved one file per tile in a folder beside the scene. See `docs/terrain.md`.

## Writing components

```beef
using Tallow;
namespace MyGame;

[Component]                      // required on every component class
class Spinner : Component
{
    public Vector3 degreesPerSecond = .(0, 45, 0);   // public fields are saved and shown in the Inspector

    public override void Update()
    {
        Transform.Rotate(degreesPerSecond * Time.DeltaTime);
    }
}
```

Callbacks: `Awake`, `OnEnable`, `Start`, `FixedUpdate` (60 Hz), `Update`, `LateUpdate`, `OnGUI`, `OnDisable`, `OnDestroy`.
Field attributes: `[ShowInInspector]`, `[HideInInspector]`, `[NonSerialized]`, `[Range(min, max)]`.
Supported field types: `float`, `int32`, `bool`, `Vector2`, `Vector3`, `Quaternion`, `Color`, `String`, and enums marked `[Reflect(.All)]`.

A Quit button calls `Application.Quit()` (or sets `Application.Instance.Running = false`, which does the same): a built game closes, and in the editor Play stops and the editor stays open. Nothing in the game has to check which it is running in. `Application.Instance.Close()` always ends the program, editor included.

Code style: see `docs/coding-style.md`; `python3 tools/format/format_code.py` formats the code.

## What is in the engine

- **Rendering** (bgfx): forward HDR pipeline with 4x MSAA, a sun with four shadow cascades, up to 256 point and spot lights in view sorted into clusters, with real-time shadows from the nearest point and spot lights (see `docs/lighting.md`), baked lighting with bounced light in lightmaps and light probes, made by the editor's Lighting window (see `docs/baked-lighting.md`), light and reflection probes placed automatically where they make sense (see `docs/probe-placement.md`), metallic/roughness shading, per-triangle flat shading for the low-poly look, procedural sky, fog, bloom (a glow around bright and emissive things; set Bloom and Bloom Threshold in the scene's lighting settings, or `Scene.Environment.bloom` from code; off by default), tonemapping, see-through objects (give a Mesh Renderer a color alpha below 1), automatic instancing of identical mesh/material pairs, frustum culling, glTF/GLB models and textures.
- **Materials, shaders and compute**: materials (`.tmat`) shared between objects and edited live in the Inspector; shader graphs for making shaders without code (a live preview on every node, subgraphs, custom-code nodes, normal and occlusion outputs); a metallic-roughness PBR shader with normal, metallic-roughness, occlusion and emissive maps; your own surface shaders (`.tshader`) that keep the engine's lighting, shadows and fog; and compute shaders (`.tcompute`) that run per pixel on the graphics card, usable with no script through the Compute Effect component, and compute graphs that build them from nodes with a running preview. See `docs/materials.md`.
- **Layers, tags and world states**: named physics layers with a collision table and layer masks on every query; tags with fast lookup; world states (versions of one place) that hide, silence, disable collision and swap navigation for whatever is outside the active one, switched in one call. See `docs/layers-and-tags.md`.
- **Downloads and zips**: HTTPS downloads with progress using the system's own libraries (WinHTTP, libcurl), and a zip reader. See `docs/http.md`.
- **Voxels**: `VoxelTerrain` is a grid of hand-placed tiles (or endless, streamed around the camera and each player) of 32-cell chunks with level of detail, generated and meshed on worker threads with dual contouring (or marching cubes, or blocky cubes), smooth or flat shaded, editable at runtime with `Brush` / `ModifySphere`. `VoxelObject` is a destructible object: a built-in shape or any closed model (Shape Mesh), drawn with the Mesh Renderer's material outside and, where carving exposes it, with an Interior Material or an inside made from the outside's material. `Carve` it and disconnected pieces break off as physics bodies. See `docs/voxel-objects.md`.
- **Physics** (Jolt, deterministic build): `Rigidbody`, box/sphere/capsule/convex/mesh colliders, raycasts and shape casts, and a `CharacterController` (capsule or rounded box) that walks up steps and slopes; see `docs/character-controller.md`.
- **AI**: polygon NavMesh walking with tiled updates, volume-grid flight, straight any-angle paths, jump and ladder links, moving obstacles with carving, costly or forbidden areas and agents steering round each other (`docs/navigation.md`), and behaviour trees with patrol, chase, sight, hearing, events, subtrees and blackboard nodes (`docs/behavior-trees.md`).
- **Scenes at run time**: `SceneManager.LoadAdditive` adds another scene file to the one that is playing (levels kept in their own scenes, each editable by itself), `Unload` takes it out, and `SceneManager.Load` changes scene. See `docs/scenes.md`.
- **Maps**: a game's own map editor saves a level (with its terrain sculpting and any models the player brought in) as one `.tmap` file with `MapFiles.Export`; a game finds map files in its `Maps` folder with `MapFiles.Find`, which checks each one (whole, made for this game, nothing it uses missing, and what the game's `MapRules.txt` asks for, such as 4 spawn points or at most 500 physics items), and plays one with `MapFiles.Mount` and `SceneManager.LoadAdditive`. `MapSharing` sends the host's map to players who lack it or have another version (checked by hash). Saving a scene in the editor that breaks the rules opens a warning. See `docs/maps.md`.
- **Joints and debris**: the **Joint** component holds two rigid bodies together at a point, freely or with a swing limit (chains, doors, ragdolls); `Joint.Connect` does it from code. A Rigidbody with **Debris** on rests on scenery but is ignored by everything that moves and by rays and shape queries (corpses, dropped items). See `docs/joints.md`.
- **Soft bodies**: the **Soft Body** component simulates a Mesh Renderer's mesh as cloth (flags, capes, curtains, pinned to the object and blown by Wind Zones), jelly (squashes and springs back) or a shell (dents where it is hit and stays dented: car crashes), colliding with colliders, rigidbodies and characters, pushing them and pushed back. Pins and stiffness are painted on the mesh in the Scene view; pinned cloth follows networked objects, and free soft bodies follow the server. See `docs/soft-bodies.md`.
- **Water**: the **Water** component makes ponds, pools, rivers and the sea in a Realistic look (refraction, clarity, screen reflections, caustics, shore foam) or a Low Poly one (flat facets, colour bands, sparkle). Gerstner waves float Rigidbodies with Jolt's buoyancy (a Floater sets an object's own), Character Controllers swim, and a camera in the water sees through it, cut exactly at the waterline. Waves run on the session clock, so every player sees the same water with nothing sent. See `docs/water.md`.
- **Ropes**: the **Rope** component hangs, sags, swings and drapes, with each end tied to any object on its own (or left free); it holds up, swings, tows and lifts rigidbodies (`Rope.Attach(helicopter, crate)`), and reports how hard it pulls. See `docs/soft-bodies.md`.
- **Spawn points**: `SpawnPoint` components with teams and start-only points; `SpawnPoints.Next`, `Random` and `Place` choose one, and network sessions use them for joining players. See `docs/spawn-points.md`.
- **Audio** (miniaudio, built in): `AudioSource` on anything that makes sound and an `AudioListener` for the ears, with stereo panning or optional, tunable HRTF for headphones (MIT KEMAR measurements), distance rolloff, Doppler, directional cones, occlusion behind colliders, air absorption, reverb zones, six mixer groups and streaming. WAV, OGG, MP3 and FLAC. See `docs/audio.md`.
- **Voice chat** (Opus, built in): off by default; turn it on and players in a session can talk, with an open microphone or push to talk on a key you choose, proximity and team-only voice decided by the server, per-player muting and a microphone test. See `docs/voice-chat.md`.
- **Particles**: `ParticleSystem` draws each system as one instanced call and previews in the editor.
- **Sequencer (cutscenes)**: timelines that move objects, cut and blend between camera shots, play animations, sounds and subtitles, show and hide things, fade the screen and fire events, edited on a timeline in the editor's **Sequencer** tab with a live preview; the **Sequence Player** plays, pauses and skips them, keeps its place in saves and can play one in time for every player in a session. See `docs/sequencer.md`.
- **Dialogue and subtitles**: branching conversations in `.tdialogue` files, written in the editor's **Dialogue** tab and tried there with a preview; the **Dialogue Runner** shows each line as a subtitle with its voice, the answers as buttons, hands events to the game, keeps its place in saves and can be shared by everyone in a co-op session. Any sound with an `.srt` file beside it is subtitled too, with captions and settings for the player. See `docs/dialogue.md`.
- **Decals**: the **Decal** component presses a picture onto whatever lies in its box (posters, signs, cracks, scorch marks), lit and shadowed like the surface, with an angle limit, draw order and **Stick to Surface** in the Inspector; `Decals.Spawn` makes short-lived ones from code (bullet holes, footprints) in a pool that recycles the oldest. See `docs/decals.md`.
- **Modelling**: the editor's **Model** window draws low-poly shapes (box, ramp, stairs, cylinder, arch, pipe...) straight into the Scene view, and Tab edit mode picks vertices, edges and faces to move, extrude, inset, bevel, loop-cut, bridge, fill, merge, subdivide or mirror; booleans cut doorways out of walls; round bevels, edge and vertex slides, and a knife that cuts through points inside faces; faces take material slots and vertex colours (painted with a brush), or textures painted straight onto the model; texture coordinates are world-aligned by default, or projected, unwrapped at seams or smart-unwrapped and packed, with a UV Editor that picks pieces and points, pins, stitches and puts faces into palette or atlas cells; levels of detail are made from a model in one press. Models live in the scene (the **Model Mesh** component), are solid at once, and save as `.tmesh` or export as `.glb`. See `docs/modeling.md`.
- **Drawing less**: LOD Groups (levels from `_LOD` children or simplified at load, per camera by screen size), occlusion culling behind big solid objects, and GPU skinning of rigged models with a compute shader. See `docs/lod.md`, `docs/occlusion-culling.md` and `docs/gpu-skinning.md`.
- **Reflections**: the sky and reflection probes mirrored by shiny surfaces, and image-based ambient light. See `docs/reflections.md`.
- **Textures**: mip levels and anisotropic filtering for every texture, and compressed (BC1 / BC3) copies in built games. See `docs/textures.md`.
- **macOS**: Apple silicon Macs build and run the engine, editor and games with Metal, checked on every push by a macOS CI job. See `docs/macos.md`.
- **Profiler**: Window > Profiler shows where each frame's time goes (every system and script, job threads, GPU passes) with counters for rendering, memory, physics, networking and more; it attaches to a running build or server, saves captures, compares memory snapshots and exports text reports for debugging. See `docs/profiler.md`.
- **Quality presets**: Low, Medium, High and Ultra set every graphics setting at once, remembered for the player, with a suggestion for the machine. See `docs/quality.md`.
- **Mouse lock**: `Input.LockCursor = true` keeps the mouse inside the window and hides the pointer while the mouse steers the view; `Input.MouseDelta` goes on reporting movement. Set it false while a menu is open. While it is locked, menus and editor panels are not sent the mouse or the keyboard, so nothing under the hidden pointer is hovered or clicked. It is released when play stops, and `Input.CursorLocked` says whether it has really taken hold.
- **Game UI**: override `OnGUI` and use `GUI.Label`, `GUI.Button`, `GUI.Bar`, `GUI.Box`, `GUI.Toggle`, `GUI.Slider`.
- **Saving**: mark fields `[Saved]` (numbers, text, vectors, colours, references to scene objects, your own structs and classes, and arrays, lists, queues, sets and dictionaries of them, nested) and call `SaveSystem.Save("name")` / `Load("name")`: scene objects destroyed, objects spawned while playing and their positions and velocities (Saved Transform) come back too. Optional loading at start, before any `Awake`; saves go to files in `GamePaths.PlayerData` or a storage of your own (a server). **Data assets** (`.tdata`) are shared data files edited in the Inspector, with `[Saved]` fields kept per player. See `docs/saving.md`.
- **Prefabs**: right-click an object > Save as Prefab, then drag the `.tprefab` into a scene, double-click it to open it alone for editing (a bar in the Hierarchy has Save, Revert and Back to Scene; the scene waits as you left it; the editor switches to the Scene view, where its own camera flies round the prefab, since a prefab has no camera for the Game view), or call `Prefab.Instantiate(scene, "path.tprefab", position, rotation)`. `NetworkManager.RegisterPrefabFile` spawns one over the network.
- **Game messages**: `NetworkManager.RegisterMessage` plus `SendToServer` / `SendToAll` / `SendToClient` carry reliable game events; `SetOwner` hands an object to a client.
- **Multiplayer, built in and optional**: with a `NetworkSession` in the scene, physics bodies, character controllers, AI, voxel edits, animation, prefab spawning and `[Sync]` fields are shared with no extra code, over UDP or Steam; without one nothing changes. Write a player by deriving from `NetworkScript` and filling in one tick. See `docs/networking.md`.
- **Input actions and controllers**: the game asks for "Jump" or "Move" and the project's `Input.tinput` (Window > Input Actions) says which keys, mouse buttons and controller buttons mean it, so one script works from keyboard and mouse and from any controller. Xbox, PlayStation and Switch pads work with no set-up, with rumble and the right button names; UI documents are worked with the d-pad and a button; `NetworkScript` players use a controller with no code. See `docs/input.md`.
- **Anti-cheat** (optional): on top of networking in which the server moves every player and decides what matters, a Project Settings switch adds watching for invalid controls, speed hacks, message floods, changed game files, debuggers, injected libraries, edited memory (`GuardedInt`) and automated aim, with logging, removal and bans. It runs inside the game, not in the kernel; `docs/anti-cheat.md` says what that means.
- **Steam** (optional): achievements with `Achievements.Unlock("ID")`, an Achievements window, Workshop content with `Workshop.MountInstalled()`, `Browse` and `Publish`, and a Steam transport for multiplayer; see `docs/steam.md`. `Assets.AddSearchPath` mounts any mod folder without Steam.
- **Screen effects and colour grading**: ambient occlusion, depth of field (with auto-focus), camera motion blur, and grading with contrast, saturation, white balance, a colour filter, vignette and colour lookup tables, all in Scene Settings and saved with the scene. Players can turn effects off and set brightness through `ScreenEffects`. See `docs/post-processing.md`.
- **Materials on skinned meshes**: a rigged model with several materials or any textures is drawn in parts, each with the material saved in the file (base colour, normal, metallic-roughness, occlusion and emissive textures, from inside a `.glb`, `data:` addresses or files beside it), or a `.tmat` per part chosen in the Inspector or with `SetPartMaterial` (networked). See `docs/skinned-materials.md`.
- **Loading in the background**: `SceneManager.LoadAsync` / `LoadAdditiveAsync` read a scene and the models and textures it names (through its prefabs and materials) on loading threads, with `Progress`, and `allowActivation` to hold it ready; `AssetLoader.Preload` does the same for any models and textures. The **Scene Loader** component does it without code, with a `progress` field for a loading bar. See `docs/loading.md`.
- **Foliage and wind**: a **Foliage** component is one kind of plant painted over the ground with a brush (grass, bushes, trees; built-in models or your own), drawn instanced so that tens of thousands cost little, each with its own turn, size and shade. **Wind Zone** components (over the whole scene, or inside a sphere) bend Foliage and any Mesh Renderer with **Wind Sway**, on the graphics card, shadows included. Grass parts round characters (every Character Controller, and anything with a **Foliage Bender**), other players' too, with nothing sent over the network. Plants follow the terrain when it is sculpted and are removed when buried or left hanging. See `docs/foliage.md`.
- **Typing numbers**: every number field in the editor can be typed into as well as dragged: click a field without dragging (or double-click it) to type, and double-click a slider. Enter keeps the value, Escape leaves it.
- **Animation layers and blend trees**: an Animator Controller can have layers above its Base Layer, each a state machine with a weight, Override or Additive blending and a bone mask (the upper body aiming while the legs run, a recoil added on top), and states can be 1D or 2D blend trees (walk to run by speed, strafing by direction), all edited in the Animator window. See `docs/animator.md`.
- **Inverse kinematics**: **Limb IK** holds a hand or foot on a target (two hands on a weapon, each able to let go and take hold again by itself with `LetGo` / `Grab`), **Look At IK** turns a head with the neck and spine, **Foot Placement** keeps feet on uneven ground and lowers the hips, and **Hand Pose** curls fingers with a slider each and ready-made shapes (Grip, Trigger, Fist, Point...). IK is a layer over the clips, with a weight, and gives the pose back untouched; it runs in the editor too, and **Key IK** in the Animation window bakes it into a clip. Rigged models take part with **Expose Bones** on the Skinned Mesh Renderer, which makes an object for every bone. See `docs/ik.md`.
- **Rigging and weight painting**: **Window > Rigging** rigs a still model the way Mixamo does: drag a few markers onto it (chin, wrists, elbows, knees and groin for a person; nose, neck, tail, paws, elbows, hocks and ears for a cat, dog or horse) and a skeleton is built, with Mixamo's bone names for people so Mixamo animations play on them. Weights are made automatically (bone heat, smooth across joints and never torn at seams) and can be painted (add, subtract, smooth, set; mirrored; flexing while you paint), bones can be moved, added and mirrored for any other creature, poses tried, and a rigged `.glb` written and put on the object. See `docs/rigging.md`.
- **Posing characters in the editor**: a selected rigged model's bones are drawn in the Scene view through the mesh (click one to select and turn it), the Animation window's **Rig** menu sets up an IK rig for a humanoid in one press (hand and foot targets, elbow and knee poles, a look target, all drawn as handles), snaps targets to the bones, bakes IK into keys and copies a model's own clips into editable ones, and **Hand Posing** gives finger shapes and curl sliders that key the fingers. See `docs/retargeting.md`.
- **First-person viewmodel**: put a player's arms and weapon on a layer and pick it as the Camera's **Viewmodel Layer**: they are drawn after the world, over it, with their own field of view and near clip, so a gun never pokes into a wall and keeps its shape at any field of view. An amber frustum in the Scene view shows where to place them. A **Viewmodel Pose** moves them: hip to aim (to the middle of the screen), walk bob, sway and recoil, worked out from the camera's movement. See `docs/viewmodel.md`.
- **Shadow-only meshes**: `MeshRenderer.shadowOnly` casts a mesh's shadow without drawing it, for the parts of a first-person player's own body that must not get in front of the camera.
- **Networking internals** (ENet): add a `NetworkSession` to a scene. The server simulates from client inputs and sends snapshots holding only what changed, packed small; clients predict their own objects and the server's physics bodies (deterministic, so a body only physics moves needs no correction), rewinding and replaying when a snapshot disagrees, and show everything else a moment in the past, moving evenly between snapshots. A client's tick clock follows the server's, and `BeginLagCompensation` / `EndLagCompensation` let the server judge a shot against what the shooter saw. Put movement in `NetworkBehaviour.Simulate`. `CharacterMotor` is a ready-made networked character that drives a `CharacterController`.

Run a built game with `--server` (dedicated, no window), `--host`, or `--connect <address>`; `--port <n>` changes the port.

### Testing multiplayer on one machine

Start the same game executable twice; no second build is needed:

```bash
./MyGame --host                      # window 1
./MyGame --connect 127.0.0.1         # window 2
```

Add `--lag <ms>` to hold back everything that copy sends, `--jitter <ms>` to hold each packet back by up to that much more at random, and `--loss <percent>` to drop that share of its inputs and snapshots; `--netstats` prints the traffic and corrections every second. Use the same values on both to simulate a real connection, for example `--lag 60 --loss 3` on each gives about 120 ms round trip with 3% loss each way.

## Visual scripting

Create a graph with Project > + > Graph. Each graph compiles to an ordinary Beef component with the graph's name (the generated `.bf` is hidden in the Project window; right-click the graph for View Generated Code or Convert to Script). Save in the Graph tab saves the graph and compiles it; the editor's automatic script reload then picks the component up, so add it to objects like any other component without rebuilding.

Any public static method can be a node:

```beef
[GraphLibrary]
static class MyNodes
{
    [GraphNode] public static float Pulse(float time, float speed) => Math.Sin(time * speed) * 0.5f + 0.5f;
    [GraphNode] public static void Shout(String text) => Log.Info(text);
}
```

Parameters become inputs and the return value the output (float, int32, bool, Vector3, String). Methods that return nothing are action nodes with flow pins.

### Everything code can do

You do not have to write those by hand. The add-node menu has two more entries, filled in by reading source files:

- **Engine**: every public method, property and field of the engine, grouped by area (AI, Animation, Audio, Net, Physics, ...) and then by class. About 1,550 nodes: play a sound, cast a ray, move a character controller, set an Animator parameter, unlock an achievement, find a spawn point.
- **Game**: the same for your own scripts, by class.

Nothing lists these by hand, so an engine feature added later, or a script you write, has nodes as soon as it is saved. Every generated node is compiled as real code by the test suite.

- A method on a component has an input for the component. Left unconnected it means **this object's own** (shown as "self"), so *Audio Source: Play* with nothing plugged in plays this object's sound.
- Each component class also has **Get From Object** and **Add To Object**.
- A method that returns a value and does something (a ray cast) is an action with a **Result** output; `out` parameters are outputs too.
- Pins carry numbers, whole numbers, booleans, text, vectors, rotations, colours, enum values (picked from a list) and objects. A whole number plugs into a number pin and back.

Also built in: **For Loop** and **While Loop**, comparisons and logic, whole-number maths, vector and rotation helpers, **Key Held / Pressed / Released** for any key, logging, and events for the rest of a component's life (On Awake, On Enable, On Disable, On Destroy, On GUI).

### Multiplayer in graphs

A graph calls the same engine functions as code, so what is shared automatically from code is shared from a graph: sounds, animation, voxel edits, spawning. For the rest:

- **Networked** on a variable shares its value from the server.
- **On Tick** (under Network) turns the graph into a Network Script: its outputs are the player's synced controls (Move, Move Direction, Yaw, Jump, Fire...), and the engine handles sending input, prediction and correction. Nothing else has to be set.
- **Send Network Event** runs the matching **On Network Event** on every machine. The server can send for any object; a client only for one it owns.
- **Is Server**, **Is Mine** and **In Session** for the cases that must differ.

### Variables

The Variables panel in the top right of the Graph tab (toolbar: Variables / Hide Variables) declares values the graph keeps between frames. Click + Add, then give the variable a name, a type (Number, Vector, Boolean or Text) and a default. Get and Set place nodes that read and write it; variable nodes are also under Variables in the add-node menu, bound by their Name value.

Each variable compiles to a public field of the graph's component, so once the graph is saved and scripts have reloaded it appears in the Inspector and can be set per object and saved with the scene like any script field. The default in the panel is only the value new components start with. Renaming a variable renames its nodes but is a new field to scenes that already saved the old name; changing its type drops links that no longer fit; removing it removes its nodes. A subgraph's variables live on the component of the graph that uses it, and share a field with a host variable of the same name.

## Interfaces (UI documents)

A `.tui` file is HTML-like markup; its CSS-like stylesheet is either a `<style>` block inside it or a `.tcss` file of the same name beside it (the UI tab's Open CSS button creates that file):

```html
<style>
.card { width: 320; padding: 20; gap: 10; background-color: #1b2028f2; border-radius: 8 }
</style>
<panel class="card" onload="OnOpen">
    <text style="font-size: 24">My Game</text>
    <input bind="playerName" />
    <button onclick="OnPlay">Play</button>
</panel>
```

Put a **UI Document** component and your own component on the same object. `onclick` / `onload` name methods on that component (optionally taking the `UIElement`), and `bind` names one of its public fields. Set the UI Document's **Reference Height** (1080, say) to have the document scale with the window, so it looks the same at any resolution; left at 0, sizes are real pixels. From code, `GetComponent<UIDocument>().Find("id")` returns an element whose `text`, `visible` and styles you can change. Tags: panel, text, button, image, input, bar, slider, toggle and canvas. A `slider` (attributes `min`, `max`, `step`) and a `toggle` call `onchange` with the element, whose `value` is the new setting, or write straight into a `bind` field. A `canvas` calls `ondraw` every frame so that code can draw into its rectangle (`screenX`, `screenY`, `screenWidth`, `screenHeight`): a radar, a graph. In the UI tab a canvas shows as a tinted box with its name and size, so it can be placed like anything else; `preview="Motion tracker"` gives it a plainer name there and `preview-src="UI/tracker.png"` a picture, both ignored while the game runs. The UI tab lays a document out for the screen size chosen in its toolbar (it starts on the Reference Height of a UI Document in the scene that shows it) and draws the whole of it scaled to fit the panel. `repeat="8"` on an element makes eight copies of it, with `{i}` and `{n}` in its attributes and text replaced by each copy's number, for lists and grids. `SetClass("selected", true)` switches a class on an element from code. Layout: flex-direction, gap, padding, margin, width/height (px or %), flex-grow, align-items, justify-content, and position: absolute with left/top/right/bottom. Rules in an `@media (orientation: portrait) { ... }` block (also `min-/max-width`, `min-/max-height`, `min-/max-aspect-ratio`, in the document's layout units) apply only while the document's area matches, so one document can rearrange itself for a portrait phone; give the parts that move an id or class, since a `style=""` attribute wins over the stylesheet. `UIDocument.SetVariant("phone", 600, 1100)` reads every document from a `phone/` folder beside it where one exists, designed for that height and width (the tighter of the two fits); `docs/responsive-ui-design.md` has the whole approach. Stylesheets may hold `/* comments */`. `font-family: Fonts/Title.ttf` (a .ttf or .otf in the project, inherited like `font-size`) sets the type; from code, `UIFonts.Push("Fonts/Title.ttf", 48)` then `ImGui.PopFont()` draws a component's own interface in it, and `ImGui.DrawImage` takes a tint to fade or colour a picture. An object can carry several UI Documents (a heads-up display, a menu for each screen): they are drawn in the order of the components, and a disabled one is neither drawn nor clickable, so showing a screen is `document.Enabled = true`. See `UI/sample_menu.tui` and `Scripts/SampleMenu.bf` in any new project.

## Animation

- **Rigged models** (Blender: export glTF 2.0 `.glb` with the armature and animations): drag the file into the Scene, or add a **Skinned Mesh Renderer** and set its model. Clips in the file are listed in the Inspector; call `Play("Run")` from code. **Clip Library** names other `.glb` files whose clips the model can play too: matched by bone name for the same skeleton, and **retargeted** through each model's humanoid bone map for any other humanoid (Mixamo, Synty, Unreal, Rigify names; different rest poses, rolls, sizes and facings), with a Bone Map window to fix matches (`docs/retargeting.md`). Skinning runs on the CPU, up to four bones per vertex.
- **Bone hierarchies of rigid parts**: the **Animator** component plays `.tanim` clips on child objects by name (the sample character in `Prefabs/character.tprefab`).
- **Animator Controllers** (`.tcontroller`): a state machine of clips with parameters, conditions, exit times and cross-fades, edited in **Window > Animator** and watched live while the game runs. Scripts call `SetFloat`, `SetBool`, `SetTrigger`.
- **Window > Animation**: a timeline for making clips, laid out like Unity's: transport buttons and a property list on the left, a zoomable frame ruler and key diamonds on the right, and Record or Auto Key to key whatever you move.

See `docs/animator.md`. Animator parameters and states are shared in multiplayer with no setup.

## Projects

The Project window shows the project's `Assets` folder (on disk: `src/`). Scripts anywhere inside it are compiled; models, textures, scenes and prefabs live beside them. The Beef workspace files are generated on every build.

Libraries: put a Beef library folder in the project's `Libraries/` folder, or use File > Project Settings to download one from a Git address, reference a folder, or add linker flags for C libraries.

Sample: `Samples/Sandbox` (voxel world, networking).

## Layout

```
Engine/      runtime library and shaders
Editor/      editor, project system, project templates
Launcher/    project hub executable
native/      CMake build of third-party code plus the small C/C++ shim
third_party/ bgfx, SDL3, Jolt (JoltC), Recast/Detour, ENet, Dear ImGui (cimgui), ImGuizmo, cgltf, stb, miniaudio, KEMAR HRTF data, Opus
Samples/     example projects
Tests/       CPU regression fixtures
website/     project website for XAMPP (PHP + MariaDB): docs, tutorials, screenshots
```

Each type has its own file, or shares one with the small types that only it uses, so a class is found by its name.

`Engine/src`:

| Folder | Contents |
|---|---|
| Core | Application loop, GameApp, Log, Time, Input |
| Scene | Scene, GameObject, Transform, Component, the component registry, serializer, scene manager, prefabs, spawn points |
| Math | Vectors, Quaternion, Matrix4, Color, Mathf, bounds/ray/frustum |
| Render | RenderView, Camera, Light, MeshRenderer, Material and ShaderAsset, Compute, Mesh, Primitives, particles, debug and gizmo drawing |
| Animation | AnimationClip, Animator, AnimatorController, SkinnedModel, SkinnedMeshRenderer, HumanBones (HumanBone, BoneMap); `IK/`: IKSolver, IKSystem, LimbIK, LookAtIK, FootPlacement, HandPose |
| Physics | PhysicsWorld and its queries, Colliders, Rigidbody, Joint, SoftBody, CharacterController |
| Audio | Audio engine, AudioSource, AudioListener, AudioReverbZone |
| AI | Navigation data, baker, surface, agent, links, obstacles and areas; behaviour tree data, nodes and runner |
| Net | NetworkManager, identities, serialization, session, transports, automatic sync, tick scripts, character motor |
| UI | UI documents and elements, immediate-mode GUI |
| Voxel | Voxel terrain (tiles or endless), terrain generators and voxel objects |
| Scripting | Script hot reload, graph node attributes |
| Assets | Asset cache and path resolution |
| Platform | Bindings: bgfx, SDL3, Dear ImGui, Jolt, ENet, Steam; achievements; Workshop |

`Editor/src`:

| Folder | Contents |
|---|---|
| App | EditorApp (state and lifecycle) and its parts: scene operations, prefab editing, building, layout and menus, popups; undo; icons; the shared entry point |
| Panels | Hierarchy, Inspector, Console, Project, Game view, Scene view |
| Project | Project files, generator and templates, settings, recent projects, folder monitor, shell helper |
| Graph | Visual scripting: graph editor, canvas, node library, graph model and compiler |
| Behavior | Behaviour tree editor and live debugging view |
| Animation | Animator window (state machines), Animation window (clip timeline), RigTools (Rig menu, Hand Posing) |
| Scripts | Code editor, the code index it and the graphs read from source (ApiIndex), script reload, script-to-component lookup |
| Tools | Terrain tools, navigation tools, achievements window, material inspector, shader compiler, asset previews |
| UI | UI document editor |

### Shipping

- **A game:** File > Build... (choose Linux or Windows, whether it starts fullscreen, and a folder; `GameWindow.Fullscreen` switches while the game runs), or `python3 tools/build_player.py <project> [--platform windows] --output <folder>`. The result is a folder with one executable, its asset packs (`game.tpak`: the project's assets and the engine's shaders, compressed, scrambled and checksummed rather than loose files, plus a pack for each scene's own files so that an update to one map changes one small file) and `THIRD_PARTY_LICENSES.txt`, and nothing else: it can be moved or sent to somebody. See `docs/standalone-player.md`.
- **The editor, for another machine:** File > Build... with Build set to Editor, or `tools/package_engine.sh --platform linux|windows --folder <folder>`: a folder with the launcher, the engine and editor source, the native libraries and the tools.
- **The engine:** `tools/package_engine.sh [folder]` packs a built copy (launcher, engine and editor source, prebuilt native libraries, samples, tools, docs) into one archive for another Linux x64 machine. That machine needs the Beef toolchain, because each project compiles its scripts with the engine, and Python 3.11+ for Build Game. A project that names an engine folder which is not there finds the engine again by itself.
- **Licences:** `tools/make_licenses.py` gathers the licence of every bundled library into `THIRD_PARTY_LICENSES.txt`; `build.sh` runs it, and every packaged game gets a copy.
- **Windows:** games and the editor are built for Windows from Linux, after a one-time `tools/windows/setup.sh`; see `docs/windows.md`. Built games run on Windows machines; the editor has been checked under Wine only.

### Website

`website/` is a small PHP site with a MariaDB database. `sudo website/setup.sh` copies it to XAMPP's `htdocs/tallow` (legacy local deployment path), creates the `tallow_site` (legacy database name) database and loads the content; it is then at `http://localhost/tallow/`. Documentation pages are imported from this README and `docs/`, tutorials from `website/content/tutorials/*.md`, and the page list is `website/content/manifest.php`. After editing any of them, `website/update.sh` reloads the content without sudo; changes to the site's own PHP, styles or images need `website/setup.sh` again (no sudo after the first run, which hands the installed folder to your user).

## Platforms

Developed and tested on Linux x64 with Vulkan. Windows x64 builds (games and the editor) are cross-compiled on Linux and use Vulkan; see `docs/windows.md`. macOS on Apple silicon builds natively with Metal and is checked in CI; see `docs/macos.md`. The dependencies also support Android and iOS, and shaders are already compiled for Vulkan, OpenGL, OpenGL ES and Metal, but those platforms still need their own link settings and have not been built. Direct3D shaders must be compiled on Windows (`tools/compile_shaders.sh`).

## Known limits

- The OpenGL backend crashes at startup on NVIDIA drivers under a Wayland desktop (inside the driver's EGL layer); Vulkan is the working backend on Linux.
- The Windows editor has been run under Wine only (built games run on Windows machines), and Windows uses Vulkan only (no Direct3D shaders). `docs/windows.md` lists what is not done.
- Audio occlusion is a single ray and there are no computed reflections; see `docs/audio.md`.
- Objects already placed from a prefab are copies: editing the prefab changes what is placed from then on, not what is already in a scene.
- Materials have no environment maps (metals mirror the sky and ground colours), and shadows ignore a shader's vertex movement and cutouts; see `docs/materials.md`.
- Skinned models are deformed on the CPU, which suits low-poly characters but not crowds of detailed ones; morph targets are not supported.
- Graphs cannot use lists, delegates or generic methods, graph variables cannot hold object references, and UI documents have no scrolling, text wrapping or animations (a canvas can draw anything they lack).
- Automatic script reload works in Linux and Windows x64 Debug editors, and engine changes need Full Rebuild & Restart. Every component class needs `[Component]`.
- Undo covers objects, components, fields, scene settings, terrain tiles and sculpting, but not voxel carving.
- Network: a physics body another player pushes moves on a client when the server says so (a round trip later, run forward to now), and there is no encryption or NAT traversal of the engine's own (the Steam transport provides both).
- Only the ball joint is a component; hinges (with a motor) and spring suspensions are made from code through `Scene.Physics` (see `docs/joints.md`). A hard knock can push a limb a little past its swing limit.
- Script completion works out a variable's type from its declaration or assignment on one line; it does not follow chains (`a.b.`) or infer from method return types.
- Built games still link the editor code.

### Tallow Gallery sample

Choose **Tallow Gallery (showcase of eight areas)** when creating a project, or use `Tallow --create /path/to/MyGallery --showcase`. Everything you walk through is an ordinary object in a saved scene, so you can open and change it before pressing Play: reflections and probes, lights and shadows, physics, ropes, water, a walking skinned character, cloth, jelly, dentable shells, destructible voxel objects, editable terrain and robots on a NavMesh. See [the sample guide](Editor/templates/showcase/README.md) for controls. The template is included in distributed engine packages, including Tallow Manager downloads.
