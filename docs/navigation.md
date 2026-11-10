# Navigation

Add Navigation Surface from Add Component > AI. Its position is the minimum corner of the bake volume; Size is its extent. Set cell size, chunk size, agent radius/height, maximum step and slope. **Backend** (a choice in the Inspector, or `surface.backend` from code) says what walking agents walk over:

- **NavMesh** (the default): use this for walking. A search crosses a room in a few polygons rather than many cells, so it is much faster with lots of agents, and floors above each other work.
- **Grid**: walking over a grid of cells, the highest floor only. Kept for existing assets and for comparing; it is the same grid flying uses.

Enable **Flying** for a 3D grid of free space: flying always uses a grid, whatever the Backend (a NavMesh is floors only). Bake again after changing the Backend: a saved asset stays what it was baked as until then, and the Inspector says so. Grid walking samples the highest supporting floor at each X/Z cell; obstacles lower than Max Step do not block a cell, so the cells at the foot of a stair stay walkable. A flying agent is an upright capsule of Agent Height centred on the cell (a sphere when the height is twice the radius), so set the height to the craft's real height.

With the surface selected, the Scene view shows the bake volume as a box and, once baked or loaded, every walkable floor cell as a see-through blue overlay with a darker line on each side an agent cannot cross. A flight volume shows the free cells that touch something solid instead. A dimmer second box appears when the stored bake used different bounds from the current fields. Draw Navigation turns the overlay off; F frames the whole volume.

Click Bake & Save Navigation in the Inspector. The editor writes a binary `.tnav` asset (text assets from earlier builds still load, but have no diagonal links until baked again); the Baked Data field accepts a project asset. Baking uses a private Jolt query world and never starts gameplay. It includes active static colliders and, when enabled, static render meshes, including procedural RuntimeMesh geometry. Actors marked with NavigationAgent or Rigidbody are excluded, including their descendants.

Baked data loads in Awake. Leave Rebuild On Start disabled to avoid runtime baking. Enable it for a generated world, or call Bake after creating geometry. These methods work in standalone games.

Add Navigation Agent to an object and assign its Navigation Surface. Scripts can call `SetDestination(position, speed, stoppingDistance)` on the NavigationAgent and check `HasArrived` or `PathFailed`. Call `StopMovement()` to stop it.

NavigationAgent also supports script calls:

```beef
navigation.SetDestination(destination, speed, stoppingDistance);
if (!navigation.PathPending)
{
    if (navigation.PathFailed) { /* no reachable path */ }
    if (navigation.HasArrived) { /* reached snapped destination */ }
}
navigation.StopMovement();
```

Snap Distance bounds how far endpoints can be moved to a usable cell. Arrival refers to that snapped endpoint. Base Offset is the offset from the object's origin to its feet for walking, or its center for flying. For a capsule whose object origin is one meter above its feet, use `(0, -1, 0)`. Agents without a Rigidbody follow the path directly; kinematic bodies follow their transforms. Dynamic Rigidbody agents receive horizontal velocity for walking, and three-axis velocity for flight, only while they are following a path: an idle, failed or arrived agent leaves its body's velocity alone, so it can be pushed or dropped. Walking agents measure waypoint and arrival distance on the ground plane. Turn Speed limits how fast Face Movement turns (0 turns instantly). Configure gravity appropriately for flying bodies. An agent whose object has a `CharacterController` walks its path through the controller instead, so it climbs steps and stays on slopes. A dynamic Rigidbody agent still depends on the body's own ability to get over steps.

## The NavMesh backend

A NavMesh surface is baked with Recast and searched with Detour (1.6.0, in `third_party/recastnavigation`). The same static colliders and meshes the grid bakes from are cut into voxels a third of a Cell Size across (at least 1 cm; at most 10 cm high), and the floor the agent fits on (its radius, height, step and slope) becomes polygons. Floors above each other work: a bridge with a path under it, the storeys of a house.

Everything an agent does works the same on either backend: SetDestination, FindPath, FindPaths, SamplePosition, RandomPoint, Raycast, links and their events, obstacles, areas and avoidance. Detour's paths are already as straight as the floor allows, so Smooth leaves them alone. A search that runs out of its budget (`maxVisited` counts polygons here) or cannot reach the goal fails rather than returning part of the way; the grid's remembered routes are not used.

The mesh is cut into tiles of 64 voxels a side when it is wider than 256 voxels (one tile otherwise). Carving, areas and links are put on the tiles they touch, and `surface.Rebuild(changedBounds)` bakes again only the tiles round a box (include where the geometry was and where it is now). `Mesh.TileCount` and `Mesh.LastRebuiltTiles` say how many there are and how many the last change rebuilt; the Inspector shows both. A rebuild runs at once, on the calling thread, and still gathers all the scene's static triangles, so it suits a door or a wall, not a whole level changing every frame. When obstacles, areas and links cannot be put on the mesh (at most 62 different area costs at once), the surface logs an error once and agents keep using the mesh as it was.

Limits: 4 million voxels across and 4096 on a side, fewer than 65,535 vertices in a tile, and 65,535 polygons in one search. A `.tnav` asset of a NavMesh (`TNM1`) holds the settings and the static triangles, and the mesh is built from them again when it loads; obstacles, areas and links come from the scene, as on the grid.

On a NavMesh, `NavigationData.IsNavMesh` is true and `Mesh` is the mesh. `cells`, regions, chunks and cell costs belong to the grid; `Nearest` returns a polygon number (valid until its tile is rebuilt) rather than a cell. Use SamplePosition for a point on the floor and FindPath to ask whether somewhere can be reached.

## Straight paths

With **Smooth Path** (on by default) an agent goes straight wherever it can, at any angle, instead of along the grid's eight (or 26) directions: each point of the path is joined to the farthest later point it can see. A straight leg is allowed only where every point of it lies among usable cells that the bake linked to each other, so it keeps the same clearance from walls as the grid does, and (walking) only where the floor stays close to the line, so a long leg does not cut through a hill. Corners are kept where they are needed. `NavigationData.Smooth(path)` does the same for a path from `FindPath`. On a walking grid a line is checked piece by piece between the places it crosses a cell edge or a row of cell centres, and over a flat node in one step (`useLeafClearance = false` turns that off, for comparing). Call `Touch()` after changing cells from code.

## Jumps, ladders and teleporters: Navigation Links

A **Navigation Link** (Add Component > AI) is a way across that the grid does not have: a gap to jump, a ledge to drop off, a ladder, a teleporter, a door. It runs from its object to **End** (relative to the object, drawn in the Scene view as an arc). Each end must be within **Snap Distance** of a usable cell; the Inspector says whether both are, **Drop Ends to Ground** puts them on the floor below, and **End at View Centre** moves the end to where the Scene view's camera looks.

- **Kind**: **Jump** (an arc **Jump Height** above the higher end), **Climb** (straight there at a steady pace), **Teleport** (at once) or **Walk**. **Duration** is how long crossing takes.
- **Bidirectional**: off, agents only go from the object to End (a drop they cannot climb back up).
- **Cost Multiplier**: crossing costs the link's length times this, so a high value makes agents use it only when the way round is much longer.

Agents use links when they are the shorter way (turn **Use Links** off on an agent that cannot jump). While crossing, the agent moves itself (through its Character Controller or Rigidbody when it has one) and its `IsCrossingLink` and `CurrentLink` say so; `OnLinkStarted(link)` and `OnLinkFinished(link)` are for playing a jump or climb animation. `FindPath(from, to, path, legLinks)` returns, for each leg, the id of the link it crosses (`NavigationSurface.LinkOf(id)` is the component), or -1.

## Moving obstacles: Navigation Obstacles

A **Navigation Obstacle** marks something that moves and that agents must keep out of: a crate, a car, a gate. Its **Shape** is a box or an upright cylinder of **Size** (in metres, whatever the object's scale; **Fit to Object** sizes it to what the object draws), offset by **Center**. Objects with one are left out of bakes.

- **Carve**: while it stands still, it cuts its shape (plus the agents' radius) out of the grid, so agents plan paths round it, and a path that only went through it fails. With **Carve Only Stationary** (the default) it carves once it has stood still for **Stationary Time**, and while it moves the hole is filled in and agents steer round it instead (see Avoidance); this keeps a moving obstacle from making every agent plan again each frame.
- Off: it is never carved, only steered round.

Carved cells are shown red on the selected surface. In the editor an obstacle is shown carved where it stands.

## Costly and forbidden ground: Navigation Areas

A **Navigation Area** is a box (**Size**, centred on its object) whose cells cost **Cost** times their length to cross: mud, water, a room with a guard. Agents go round it when the way round costs less, and through it when it does not. **Blocked** makes it a place agents never enter. Areas are shown purple (blocked: red) on the selected surface.

Obstacles, areas and links are put on the grid by the surface when any of them changes (each frame it checks), and agents plan again. They are not saved in the `.tnav` asset: they come from the scene.

## Avoidance

With **Avoid Others** (on by default) an agent steers round other agents on the same surface and round obstacles that are not carved (moving ones): each frame it picks, from velocities near the one it wants, the closest that does not run into anything in the next second and a half and that stays on the surface. Two agents meeting each take half the turn; one with a lower **Avoidance Priority** gives way more to one with a higher priority. **Radius** is how wide the agent is for this. Agents that are pushed far off their path by others plan again.

A scene's agents move together (`Scene.NavigationAgents`), once a frame for agents moved by their transform and once a fixed tick for agents with a Character Controller or Rigidbody. Where every switched-on agent and moving obstacle is, and how fast it goes, is copied into packed arrays and sorted into 4-metre squares, so an agent looks only at the ones near it (`NavigationAgent.UseSpatialAvoidance = false` looks at every agent, for comparing). Agents follow their paths oldest first; then the steering runs on the job threads in tiles wider than any agent looks round, agents in one tile one after another, oldest first, each seeing where the ones before it are going, as when every agent moved in its own update. Tiles far enough apart run at once, so a crowd behaves as it did on one thread and the result does not depend on how many threads there are. `agent.Runtime.Frame()` and `Tick()` still move one agent on its own, steering round the others as they are at that moment.

## Queries

```beef
let data = surface.Data;
if (data.SamplePosition(point, 2, let onFloor)) { /* the nearest usable point within 2 metres */ }
if (data.RandomPoint(center, 10, random, let goal)) agent.SetDestination(goal, 3, 0.2f);   // wandering
if (!data.Raycast(eyes, target, let blocked)) { /* an agent could not walk straight there; it stops at blocked */ }
```

`RandomPoint` picks only points reachable from the centre. `NavigationAgent.RemainingDistance` and `Velocity` say how far it still has to go and how fast it means to move; selected in play mode, an agent draws its path (link legs in orange).

Inside a scene's Update, an agent's new path is found after every component has run, together with the others' on the job threads. `PathPending` is true until then; reading `PathFailed`, `HasArrived` or `Path` before it finds that path at once, alone, so check `PathPending` first. The behaviour tree's movement tasks do, and stay Running until the path is there.

## Changes and chunks

After changing or regenerating mesh geometry, rebuild the affected bounds:

```beef
surface.Rebuild(changedBounds);
```

Include both the old and new bounds when moving/removing geometry. Sampling expands to intersecting chunks, with neighboring cell links refreshed. A revision change makes agents replan. Otherwise an agent searches only when its destination changes or it is pushed off its path, never more often than Repath Interval; a failed search is retried about once a second. The Inspector's Rebuild Changed Chunks controls expose the same operation; SaveData persists runtime changes when desired. Runtime rebuilds do not save automatically.

Chunk sampling is local, and a rebuild copies only the geometry whose bounds reach the rebuilt chunks into its temporary collision world. This implementation does not stream collision geometry or load/unload navigation chunks. Rebuilds and path searches are synchronous, so large updates should be scheduled over successive frames. Grids are limited to one million cells.

## Path search

Walking cells link to eight neighbours (four sides and four diagonals); flying cells link to all 26 neighbours. Every link was swept with the agent's shape at bake time, so a diagonal exists only where the agent fits.

On a grid, paths are found over **navigation nodes**: blocks of cells an agent can cross in a straight line (all usable, at one cost and linked inside). A walking chunk is split like a quadtree, but at the first place its cells change (a wall, a ledge, a costly area) rather than at its middle, so a wall off the middle does not cut a long corridor into a staircase of single cells. A flying grid grows boxes along X, Z and Y. A search crosses each node in a straight line, choosing the cheapest place along each shared edge, and a walking path is then pulled tight through those edges (a funnel), keeping to the part of each edge that is linked all the way so it stays clear of ledges. After a change, only the chunks whose cells changed get new nodes.

A search remembers the last 64 routes it found (`routeCacheCapacity`, at most 256, for routes of up to 256 points), by start and goal cell and what was asked for, and copies one back when asked again; any change to the grid forgets them. `LastVisited` is 0 for a remembered route. Agents and FindPaths keep the smoothed route; `FindPath(from, to, path, legLinks, snapDistance, withLinks, smooth)` does the same for scripts.

`NavigationData.useNodes = false` searches cell by cell instead, giving a point per cell for `Smooth` to straighten (the step cost is its length, the estimate the octile distance over the grid). Either way the open list is a binary heap, and `FindPath` stops after a visit budget (200,000 by default, counting nodes or cells) and sets `BudgetExceeded` when that, rather than a blocked route, is why it failed. `FindPaths` finds many paths at once on the job threads (agents asking in the same frame are batched this way after the frame's Update).

Cells are also labelled by connected region after each bake. A goal snaps to the nearest cell in the start's region within Snap Distance, and a goal with no such cell fails immediately without a search. An endpoint that lies inside a usable cell uses that cell, so a point beside a thin wall is not moved across it. The agent merges points in a straight line into one leg.

## Multiplayer

Navigation runs on the server (and in single-player games): agents find paths and move there, and their objects' positions reach the other machines like any moving object's. A client's copy of an agent does nothing by itself. Links, obstacles and areas are read from the server's scene; `OnLinkStarted` and `OnLinkFinished` happen on the server, so an animation played from them should go through an Animator (whose state is sent) or a network event.

## Current limits

A walking grid has one floor height per X/Z cell, so floors above each other (bridges with a path under them, caves) need the NavMesh backend, or separate surfaces joined with Navigation Links. Flying navigates all three axes. There is no streaming yet. Avoidance is local steering between nearby agents, not a planner for large crowds: very dense groups in narrow corridors can still jam. A link that is a shortcut (a teleporter) makes the search's estimate too low, so a search through one can visit more cells than usual. Smaller cells improve detail at higher memory/bake cost; baked data is specific to the configured agent clearance.

CPU tests cover any-angle smoothing (straight in the open, keeping its clearance round a wall), raycasts, SamplePosition and RandomPoint, carving obstacles (blocking, a smaller one walked round, freeing the cells, carving only when still), costly and blocked areas, links (joining an island, one-way, the jump arc, an agent jumping across with its events, agents that may not use links) and two agents passing each other with avoidance, as well as baking without Play, wall avoidance, saved-data loading in both formats, changed-chunk shortcuts, unchanged distant cells, diagonal 3D flight within a small search budget (over the nodes and cell by cell), node paths that go round a ledge open only at its ends, a block that rebuilds only its chunk's nodes, every leg of 20 maze paths keeping to the grid at about the cell search's length, unreachable regions, allocation bounds, replanning, arrival at snapped destinations, a flying agent, and a dynamic-body agent that is left alone when idle.

The Sandbox sample's `Scenes/Navigation.tscene` has wandering agents, a wall, a mud area, a crate a looping sequence moves back and forth, and a jump link to an island (`Sandbox --scene Scenes/Navigation.tscene`; in the editor, `--bake-navigation` bakes the scene's surfaces on load to show the grid).
