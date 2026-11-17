# Spawn points

A **Spawn Point** marks a place where a player or anything else may appear. Put as many in the scene as you like, and ask `SpawnPoints` for one when you need it.

## Placing them

Choose **GameObject > Spawn Point**, or add the **Spawn Point** component (World group) to any object. The object's position is where to appear, and the way it faces is the way to face. In the Scene view each point shows a ring, a post the height of a person and an arrow, in its team's colour.

| Field | Meaning |
|---|---|
| Team | Which team may use the point. 0 means any team. |
| Start Only | Only for the start of the game. Each start-only point is used once, while the start phase lasts; after that players appear at the ordinary points. Shown with a second, inner ring. |
| Clear Radius | A point with a character or moving body this close is passed over while another is free. |

## Asking for one

```csharp
GameObject? point = SpawnPoints.Next(Scene);           // the one used longest ago
GameObject? random = SpawnPoints.Random(Scene, team);  // a random one for a team
SpawnPoints.Place(player, team);                       // move an object there, facing the point's way
```

`Next` goes round the points in turn. `Random` picks among the ones that qualify. Both return null when the scene has no spawn points, and asking counts as using the point. `Place` works for an object with a Character Controller, a Rigidbody or neither, and returns the point it used. `TryGet(scene, team, random, out position, out rotation)` gives just the numbers.

A point is chosen in this order of preference:

1. During the start phase, a start-only point for the team that has not been used yet.
2. An ordinary point for the team with nobody standing on it.
3. An ordinary any-team point with nobody standing on it.
4. The same two again, ignoring whether someone is standing there.

A team is not given another team's point while it has one of its own or a shared one. Asking with team 0 makes every point available.

## The start of the game

The start phase opens when the scene starts playing and closes by itself after `SpawnPoints.StartWindow` seconds (5 by default). Players who arrive later, and players who respawn, get the ordinary points.

For a game with rounds, control it yourself:

```csharp
SpawnPoints.StartWindow = 0;          // never closes by itself
SpawnPoints.BeginStart(Scene);        // new round: start points can be used again, once each
// ... place everyone ...
SpawnPoints.EndStart(Scene);          // from here on, ordinary points only
```

If there are more players than start-only points, the rest go to ordinary points.

## Multiplayer

A network session uses the scene's spawn points by itself: each player who joins is created at the next point for their team, facing the point's way. Nothing needs to be written for that. Scenes with no Spawn Point components keep the older behaviour of spawning beside an object named `SpawnPoint`.

Set **Team Count** on the Network Session to share players out among teams as they join, each going to the smallest team. A player's team is the Team of their Network Identity, set by the server and known on every machine:

```csharp
int team = GameObject.Team;           // 1, 2, ... or 0 when there are no teams
```

To decide teams yourself, set `Network.ChooseTeam` on the server to a function that takes a client id and returns a team.

To respawn a player, call `Place` on the server; the move reaches every machine through the usual sync:

```csharp
if (Scene.IsServer)
    SpawnPoints.Place(GameObject, GameObject.Team, random: true);
```

To spawn something of your own at a point from any server code (a registered networked prefab):

```csharp
if (SpawnPoints.TryGet(Scene, team, false, out Vector3 position, out Quaternion rotation))
    Scene.Spawn("Guard", position, rotation);
```

## Limits

- "Occupied" looks at character controllers and moving rigid bodies near the point, not at static scenery.
- Teams are numbers; there are no team names or colours beyond the editor's gizmo colours (1 red, 2 blue, 3 green, 4 yellow).

CPU tests cover taking points in turn, random choice, skipping occupied points, team points and the shared fallback, the start phase opening, closing and reopening, placing a character, and players of two teams joining a network session at their own points.
