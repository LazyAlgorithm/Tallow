# Networking

Multiplayer is there when you want it and costs nothing when you do not: a game with no Network Session in its scene runs exactly as before, and nothing below needs to be set up or switched off.

Add a **Network Session** component (Add Component > Networking) to an object in the scene and the scene is multiplayer. The server runs the game from the controls each player sends, and tells everyone the result. Each player's own character responds at once on their machine and is corrected if the server disagrees.

## What is shared without any code

| What | How it behaves in a session |
|---|---|
| Physics bodies, character controllers, AI characters | Scene objects that move on their own get a Network Identity when the session starts, and their motion is shared. Turn **Auto Replicate** off on the session to choose by hand. |
| Navigation Agents and behaviour trees | Think on the server only. Clients see the movement. |
| Voxel terrain (`Brush`, `ModifySphere`) | Applied on every machine in the server's order. Chunks that are not loaded on a machine receive the strokes they missed when they stream in. |
| Voxel objects (`Carve`) | Carved on every machine. Pieces that break off are the same objects everywhere and can be carved in turn. |
| Character controller shape (`SetBox`, `SetCapsule`) | Decided by the server, shown everywhere. A player changing their own character sees it at once. |
| Animation (`Play` on an Animator or Skinned Mesh Renderer) | A clip started on the server, or by the player who controls the object, plays for everyone. |
| Sound (`Play`, `Stop`, `PlayOneShot` on an Audio Source) | The same rule as animation: from the server or the object's owner, everyone hears it. |
| Voice chat (`VoiceChat.Enabled`) | Players talk to each other; the server decides who hears whom (team only, proximity). See [Voice chat](voice-chat). |
| Animator Controller parameters and states (`SetFloat`, `SetTrigger`, ...) | From the server or the object's owner, every machine has the same values and is in the same state. See [Animator](animator). |
| Materials (`SetMaterial`, `SetMaterialFloat`, `SetMaterialColor` on a Mesh Renderer) | From the server or the object's owner, every machine draws the object the same way; late joiners get the current state. See [Materials](materials). |
| Network events (`SendNetworkEvent("name", value)`) | Runs `OnNetworkEvent` on that component on every machine. The server may send for any object, a client for one it owns. |
| Visual scripting graphs | Everything above applies to graphs as it does to code. **On Tick** makes a graph a Network Script. |
| `Prefab.Instantiate` | A prefab whose root has a Network Identity, created on the server, appears on every machine. On a client the call returns null, because the server's copy is the one that arrives. Prefabs without an identity stay local, which is right for effects. |
| `Scene.Destroy` | Destroying a shared object on the server removes it everywhere. A client cannot destroy one. |
| Soft bodies (`SoftBody`) | A free jelly or cloth is shared like a physics body. A shell's dents are made on the server and reach every machine, `Repair` and `SetDents` too. See [Soft bodies](soft-bodies). |
| Ropes (`Rope.Attach`, `AttachStart`, `AttachEnd`, `Release`, `LayAlong`, `Snap`, Break Force) | Tied, changed and snapped by the server on every machine; a client's call goes to the server for a rope or object it controls. |
| Water (`Water`) | Nothing sent for the waves: they run on the session's tick, so every machine draws and floats things on the same waves. The water gets a Network Identity by itself; its settings and level are the server's. See [Water](water). |
| Light and reflection probes, baked lighting | Nothing to send: every machine draws the same scene files. A dedicated server draws nothing, so it never captures or reads them. |
| Switching on and off (`SetActive`, a component's `Enabled`) | From the server, the object or component is switched on every machine; late joiners get it as it is now. A client may switch only how an object it owns looks and sounds (its lights, renderers, particle systems and audio sources): never whole objects or other components, so it cannot turn off its own collider or bring back a controller the server stopped. Anything else a client switches changes only its own copy. |
| Lights (colour, intensity, range, type, spot angles, shadows) | Changed while playing by the server, or by the client that owns the light's object (a torch on its player), they change on every machine; late joiners get them as they are now. |
| Particles (`ParticleSystem.Play`) | From the server or the object's owner, it plays on every machine. |
| Decals (`Decals.Spawn`) and one-shot sounds (`Audio.PlayOneShot`) | From the server, every machine presses the decal and plays the sound where it is. A game that already shares its shots and impacts itself is not doubled: an effect arriving from the server within half a second of the same one played on that machine (same picture or clip, near the same place) is played once. A client's own calls stay its own. |
| Fields marked `[Sync]`, and graph variables ticked **Networked** | The server's value is copied to every client when it changes. |
| Custom ECS `[Component] struct` data on networked GameObjects | Supported `[Sync]` fields are copied like script fields; the server also mirrors adding/removing those synchronized data components. |

A player who joins late receives all of it: the terrain and voxel edits so far, objects created and destroyed, current shapes, clips and synced values, and what is switched off and how the lights are set.

On a client, calls that the server must decide (`Brush`, `Carve`) are sent to the server and take effect a moment later, when the server passes them back.

## Writing a player: NetworkScript

Derive from `NetworkScript` and write what happens in one tick. The engine reads the controls, sends them, runs your code on the server and on the player's own machine, and corrects the player's machine when the two disagree.

```beef
[Component]
class Hover : NetworkScript
{
    public float speed = 5;
    [Sync] public int32 score;

    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Position += input.MoveDirection * speed * deltaTime;
        if (input.Pressed(.Jump))
            Transform.Position += .(0, 1, 0);
        if (IsServer && input.Pressed(.Use))
            score++;
    }
}
```

`TickInput` gives `Move` (WASD or arrows), `MoveDirection` (Move turned to face where the player looks), `Yaw`, `Pitch`, and buttons: `Held`, `Pressed` and `Released` for `.Jump` (Space), `.Sprint` (Shift), `.Crouch` (Ctrl), `.Fire` (left mouse), `.Use` (E), `.Reload` (R), `.Ability1` (Q), `.Ability2` (F) and `.Custom1` to `.Custom8`. Override `ReadInput` to fill the custom ones.

Three rules keep prediction working:

- Take controls only from the `TickInput`, never from `Input`. `Update` also runs on the server for another player's controls, and runs again after a correction.
- Move the object through its Transform, Rigidbody or Character Controller. Those are what get corrected. Other fields are not rewound; mark the ones clients need with `[Sync]` and change them on the server.
- `Update` can run more than once for the same tick on the player's machine. Do one-off things (sounds, spawning) inside `if (IsServer)` or `if (!IsReplaying)`.

Any script's `Update(TickInput input, float deltaTime)` works this way once its object has a Network Identity; `NetworkScript` adds one for you and gives the object its own mouse-look settings and `ReadInput`. On objects without an identity, `Update` runs once a frame with the local controls instead. Objects no player controls (untick **Player Controlled** on the Network Identity; objects spawned with `Adopt` start unticked) get empty controls, so NPCs never act on the host's keys. For per-frame work that is only for this machine (effects, UI), override `OnLocalUpdate()`.

With no session the same script runs every tick with the local controls. Put the script on the player prefab named in the session's **Player Prefab**; one is spawned for each player, at the scene's Spawn Points (see the spawn points page). **Team Count** on the session shares players out among teams.

`CharacterMotor` is a ready-made player built the same way on a Character Controller. `NetworkBehaviour` is the lower-level base class if you want to fill the input yourself.

## How it stays smooth

None of this needs setting up; it is what the session does with every object that has a Network Identity.

- **Your own objects are predicted.** They move on your machine the tick you press a key. The server sends back where it had them for that tick, and only if that differs from what your machine predicted does it go back and run the ticks since again. The difference is then eased away on screen rather than shown as a jump.
- **The server's physics bodies are predicted too.** A crate, a barrel, a ball or a dropped piece of rock is simulated on your machine, in step with your own player, so a crate you walk into moves the tick you touch it, and a crate falling or tumbling on its own is where the server will have it. The physics is deterministic, so a body that only physics moves needs no correction at all. When something your machine could not know about moves one (another player shoves it, a script on the server pushes it), the server's word is checked against what your machine had for that tick, and the bodies and your player go back and run the ticks since again, as for a wrong guess about your own player. See *Predicting physics* below.
- **Everything else is shown a moment in the past.** Other players and AI cannot be predicted, because your machine does not have their controls. They are drawn about two snapshots behind the newest news (a tenth of a second at the usual rate), moving evenly from one thing the server said to the next, so they glide however unevenly the news arrives. If a snapshot is lost they carry on as they were going for a few ticks. `InterpolationTicks` on `Scene.Network` changes how far behind; less is more up to date and less forgiving of a poor connection.
- **The client's clock follows the server.** A client runs its ticks a fraction faster or slower (never more than 5%) so that the server always has a tick or two of its controls in hand. That absorbs an uneven connection without adding more delay than the connection needs, and it adapts: a rough connection gets a deeper cushion, a clean one a thin one.
- **A moment's jitter loses nothing.** The transport (ENet) would normally start dropping unsent snapshots and voice at random when a round trip is suddenly slower than usual, as on Wi-Fi or a busy machine; Tallow turns that off for every connection, since the steps above already deal with late and lost news, and dropping it made other players stutter.
- **Between ticks, drawing is smoothed.** Mesh Renderers on an object another machine controls are drawn gliding from one tick to the next. For a camera or anything else you place yourself, `NetworkIdentity.VisualPosition` is where the object is drawn this frame.

### Predicting physics

A body is predicted when the server owns it and it is a dynamic Rigidbody (not kinematic). **Physics Prediction** on its Network Identity chooses:

| Setting | Predicted |
|---|---|
| Auto (the default) | When the object has no Network Behaviour (or Network Script) on it. A script that moves an object on the server alone would make every prediction wrong, and the host's player is such an object. |
| On | Always, script or not. Use it for a body whose script does not move it, such as a grenade that only counts down to going off. |
| Off | Never: shown a moment in the past, as other players are. |

When a player takes an object over (`SetOwner`), it becomes theirs to predict, and everyone else shows it in the past until it is the server's again.

`PredictPhysics` on the session (`Scene.Network`, on by default) turns it all off. Set on the server, it decides for every client. Set on a client, that client shows the bodies in the past whatever the server sends.

What it changes:

- A predicted body is sent with its exact position, turn and speeds, 52 bytes instead of 12, but only while it moves. A body at rest is sent once, and then only in the two-second refresh.
- A body found wrong in three snapshots running is being moved by something your machine cannot know about: another player leaning on it, or a script on the server carrying it (a sticky grenade on a player). It is shown in the past, with whatever moves it, for two seconds, then predicted again.
- A body resting on both machines but a little apart (where a shove came to rest) is put where the server has it, with no replay.
- Lag compensation leaves predicted bodies where they are. The player saw them where they are now, as they see their own player.
- A correction runs the scene's physics again for each tick since (a round trip's worth). That replay happens only when something differs.
- A script that eases its own corrections (in `PreparePredictionState` / `RestorePredictionState`) sees a predicted body's rewind with `Replaying` set, as the replay itself is. Add `NetworkIdentity.SmoothOffset` to where it draws the body instead: that is what is left of the correction after the replay.
- `--netstats` shows how many bodies a client predicts and how far off the worst was. `PhysicsRollbacks` counts the corrections made for bodies alone.

### Shots and lag compensation

A player aims at what they see, and what they see of everyone else is the past: the time their controls take to reach the server, plus the moment's delay above. Left alone, the server would judge a shot against where the target is now, and shots at anyone moving would miss.

So when the server runs a player's tick, it knows what moment that player was looking at. Wrap the ray cast in the pair below and, for its length, every other networked object is back where that player saw it:

```beef
public override void Update(TickInput input, float deltaTime)
{
    if (IsServer && input.Pressed(.Fire))
    {
        let rewound = BeginLagCompensation();
        RaycastHit hit;
        let struck = Scene.Physics.Raycast(Transform.Position, input.LookRotation * Vector3.Forward, 100, out hit);
        if (rewound)
            EndLagCompensation();
        if (struck)
            hit.gameObject.GetComponent<Health>()?.Hurt(25);   // after ending: everything is back in its place
    }
}
```

It returns false and does nothing where it does not apply: with no session, for the host's own player and for the server's own objects, who see things as they are. Physics bodies clients predict are not moved back either: the player saw them where they are now. It never looks back further than `MaxRewindTicks` (24 ticks, 0.4 seconds).

### What is sent

As little as will do the job:

- **Controls**, client to server, every tick: 9 bytes for a tick, 1 byte for a tick the same as the one before, with the two ticks before repeated in each packet so that a lost packet costs nothing. About 1 to 2 kB a second.
- **Snapshots**, server to each client, 20 a second by default (`Snapshot Interval` on the session): only the objects that have changed since the last one, at 12 to 15 bytes each (position to 2 mm, rotation to a fraction of a degree), the client's own objects in full when they change, and moving bodies the client predicts at 52 bytes, exactly. An object at rest costs nothing. Everything is repeated once every two seconds in case the last word on something was lost.
- **`[Sync]` values and events**, reliably, only when they change.

A still scene costs about 0.3 kB a second per client; a five-player firefight a few kB. The editor's status bar and `--netstats` show the real figures for your game.

## Shared values

```beef
[Component]
class Health : Component
{
    [Sync] public int32 health = 100;
    [Sync] public String title = new .("Rookie") ~ delete _;
}
```

`[Sync]` works on numbers, bool, enums, vectors, colours and String, on any component of an object with a Network Identity. The server's value wins: change it on the server. In a graph, tick **Networked** on a variable in the Variables panel.

## Game events

For anything else, send a message. See the chat example in the networking tutorial: `NetworkManager.RegisterMessage`, then `SendToServer`, `SendToAll` or `SendToClient`. Message ids from 240 up are kept for the engine.

## Running a session

| Option | Meaning |
|---|---|
| `--host` | Server and player in one. |
| `--server` | Dedicated server with no window. |
| `--connect <address>` | Join a server: an IP address, or the host's Steam ID with the Steam transport. |
| `--port <n>` | Use a different port (Direct transport). |
| `--lag <ms>`, `--jitter <ms>`, `--loss <percent>` | Simulate a bad connection for testing: a delay on everything this machine sends, up to that much more at random per packet, and a share of packets lost. Use the same values on both machines. |
| `--netstats` | Print a line of figures every second: bytes sent and received, corrections, how many ticks of controls the server has waiting. |

The session's **Transport** chooses how machines reach each other: **Direct** (UDP to an address and port) or **Steam** (see the Steam page).

## Limits

- Objects created at run time by code, other than through a prefab with a Network Identity, exist only on the machine that created them.
- A client's `Brush` and `Carve` wait for the server, so digging has one round trip of delay on clients.
- Other players are seen about a tenth of a second in the past, plus the connection's delay. That is what makes them move evenly; lag compensation (above) is what makes shots at them land.
- A physics body pushed by another player, or by a script on the server, moves on your machine when the server says so: a round trip after the push, run forward to now. Bodies only physics moves, and bodies your own player pushes, move at once.
- Physics bodies that are not networked (local debris, ragdoll parts) are not rewound when a correction runs the physics again; they carry on from where they were.
- `[Sync]` goes one way, from the server. Values are sent when they change, at the snapshot rate.
- UI is local (each player's own screen), and so are `Audio.PlayOneShot2D` interface sounds.
- Switches, lights and effects are shared for objects every machine has: ones in the scene when the session started, and spawned objects with everything their prefab made. Objects a machine makes for itself later are its own, even under a networked object (a first-person body built under the player, an effect pool).
- Other settings of built-in components changed while playing (a particle system's rate, a camera's field of view) are not shared; use `[Sync]` fields on a script of your own and set them from there.
- Animation on an object nobody owns is shared only when the server starts it.

## Deciding who may play

The server can send a client away: `Scene.Network.Kick(clientId)`. Their objects go as if they had left, and on their machine the session reports that it is no longer connected. Use it for private matches (check who joined in `OnClientJoined`, or when they send their name) and for removing a player. To tell them why, send your own message a moment before: what is sent in the same instant may not arrive.

## Host migration

Set `HostMigration = true` on the `NetworkManager` (on every machine, before starting) and a session survives its host leaving. The server keeps every client up to date with a roster. When the host goes, every machine reads the same roster: the first player on it who can be reached becomes the host and keeps the scene, and the others reconnect and take back their client ids and objects. The departed host's own player object is removed; bots and the rest of the world stay.

It is off by default because a game has to rebuild whatever only its server held:

- `OnBecameHost` runs on the machine that took over. Recreate server-only state there: timers, callbacks such as `OnClientJoined`, AI that only ran on the server.
- `OnHostChanged(address)` runs on every remaining machine, with the new host's Steam ID or address (empty on the new host).
- `IsMigrating` is true from losing the host until play resumes. `IsConnected` stays true meanwhile; if nobody can take over it goes false, so handle that as a lost connection.

Over Steam this needs nothing further. Over Direct, the new host opens the same port, so players other than the new host can only return if that port is reachable: on a LAN, or forwarded. Each candidate gets six seconds before the next is tried. States a late joiner would normally be sent (`NetworkSync` replays) are not carried over to the new host.
