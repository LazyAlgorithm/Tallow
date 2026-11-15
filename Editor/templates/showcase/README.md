# Tallow Gallery

Create **Tallow Gallery** in Tallow's new-project window, or run `Tallow --create /path/to/MyGallery --showcase`.

Open `src/Scenes/Gallery.tscene` in the editor: every room is a set of ordinary objects you can move, retune or delete. Press Play to walk round it. WASD walks, the mouse looks, Shift hurries, Space jumps, E shoves what you are looking at, left click fires a ball, right click cuts or digs, Q raises the ground, Escape frees the mouse.

- **Courtyard**: sun and shadows, a cloth flag in the wind, fire particles, a decal on the paving.
- **Hall of Reflections**: a polished metal floor and spheres from mirror to brushed steel. Its reflection probe's box is exactly the room, which is what lines reflections up with the walls. See `docs/reflections.md`.
- **Room of Lights**: orbiting point lights with shadows, a spot light, and emissive tubes through bloom.
- **Physics Yard**: a crate stack, dominoes and a wrecking ball on a rope.
- **Pool Garden**: built-in water, grass and bushes that sway, and a walking skinned character.
- **Voxel Quarry**: balls blast chunks out of rock, a pillar, a boulder and a van, and right click cuts through them.
- **Terrain Field**: voxel ground you can dig and raise as you play; collision follows.
- **Soft Body Lab**: fire balls at steel shells to dent them for good, jelly that wobbles and ignores the wind (Wind Drag 0), a cloth curtain, and robots that path round it all on a NavMesh.

**Together:** run the built game with `--host` on one machine and `--connect <host address>` on another (`--port <n>` on both to change from 7777). The physics yard, the robots, the water and the voxels are shared, as the engine shares whatever moves by itself; each player walks round as their own visitor, and what they fire stays on their machine.

The gameplay is C#. `src/Scripts/Gallery.cs` is what moves while playing (the lights, the walking figure, the robots, firing, cutting and the room names); `Visitor.cs` walks and looks; `GalleryCrowd.cs` shows one script per object beside one script over packed data. The scene itself is ordinary saved objects. (The Beef code that first built it is in the engine's history, `Editor/templates/showcase/src/Scripts/Gallery.bf` up to commit c488b75f.)

The rigged character is derived from Quaternius's CC0 asset; see `src/Models/LICENSE.txt`. Other assets are generated for this sample.
