# Tallow Gallery

Create **Tallow Gallery** in Tallow's new-project window, or run `Tallow --create /path/to/MyGallery --showcase`.

Open `src/Scenes/Gallery.tscene` in the editor: every room is a set of ordinary objects you can move, retune or delete. Press Play to walk round it. WASD walks, the mouse looks, Shift hurries, Space jumps, E shoves what you are looking at, left click fires a ball, Escape frees the mouse.

- **Courtyard**: sun and shadows, a cloth flag in the wind, fire particles, a decal on the paving.
- **Hall of Reflections**: a polished metal floor and spheres from mirror to brushed steel. Its reflection probe's box is exactly the room, which is what lines reflections up with the walls. See `docs/reflections.md`.
- **Room of Lights**: orbiting point lights with shadows, a spot light, and emissive tubes through bloom.
- **Physics Yard**: a crate stack, dominoes and a wrecking ball on a rope.
- **Pool Garden**: built-in water, grass and bushes that sway, and a walking skinned character.
- **Soft Body Lab**: fire balls at steel shells to dent them for good, jelly that wobbles and ignores the wind (Wind Drag 0), a cloth curtain, and robots that path round it all on a NavMesh.

`src/Scripts/Gallery.bf` holds what moves while playing, and the code that first built the scene: empty the scene down to the Gallery object and run with `--author-scene` to build and save it again.

The rigged character is derived from Quaternius's CC0 asset; see `src/Models/LICENSE.txt`. Other assets are generated for this sample.
