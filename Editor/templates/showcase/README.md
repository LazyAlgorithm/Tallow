# Exhibition Campus sample

Create **Exhibition Campus** in Tallow's new-project window, or run `Tallow --create /path/to/MyCampus --showcase`.

Open `src/Scenes/Campus.tscene` in the editor: the complete 24-exhibit campus is saved and editable before Play. Move grouped objects, change components, then save. The Director binds the existing scene without regenerating it. Move the Visitor spawn object to change the entrance. Keep ExhibitStation markers and referenced components when rearranging exhibits. Soft-body meshes, sculpted terrain and rope previews are included.

WASD walks, hold right mouse to look, Shift sprints, Space jumps/swims, E operates an exhibit, R resets it, left mouse pushes/carves, M/Escape opens the directory, Tab toggles overview, and F3 shows diagnostics.

The directory links to 24 live demonstrations: character movement; materials; lights; decals; rigid bodies; joints/platforms; cloth, jelly and dentable shells; loaded ropes; tiled walking navmesh; flying navigation; voxel destruction; finite/endless water and buoyancy; wind/foliage; animation/skinning; particles; spatial sound; dialogue; sequences; networking; UI/save-load; sculpted terrain; IK; probes/LOD; custom shaders.

For multiplayer, run the project with `--host --port 27960`, then another instance with `--connect HOST_IP --port 27960`. Visitors can request exhibit actions through the host and see animated character models for other players. New visitors receive shared state and spawned impactors. Use the same build and scene on every machine; static editor assets are not transferred over the network. UDP 27960 must be reachable. Voice is off until explicitly enabled at the multiplayer station. This sample is not a player-capacity or security benchmark.

Build standalone players using File > Build, or `python3 ENGINE/tools/build_player.py PROJECT --output OUTPUT`. Development validation flags: `--self-test --frames 1500`, `--walk-test --frames 2000`; optional `--tour-test` integration checks require a host, an interacting client, and a later `--observer` client. The developer-only `--author-scene` command replaces the scene with its original generated layout; normal startup never calls it.

The rigged character is derived from Quaternius's CC0 asset; see `src/Models/LICENSE.txt`. Other assets are generated for the sample or reused from Tallow's common sample content.
