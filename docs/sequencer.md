# Sequencer (cutscenes)

A **sequence** is a timeline: tracks that move objects, cut between camera shots, play animations and sounds, show and hide things, fade the screen, show subtitles and tell the game when something happens. Use one for a cutscene, a door that opens in stages, a lift, a level's intro flyover, or anything else that runs to a clock.

- a sequence is a `.tsequence` file, edited in the editor's **Sequencer** tab;
- a **Sequence Player** component plays one in the game.

## Making one

**Project > + > Sequence** makes a file and opens it in the **Sequencer** tab (double-click a `.tsequence` file to open it again; **Window > Sequencer** shows the tab).

- **+ Track** adds a track. A track that works on an object (Transform, Animation, Audio, Show / Hide) starts on the object selected in the Hierarchy; right-click a track to change its object, move it up or delete it. **on** / **off** leaves a track out while you work.
- Each track's keys are diamonds along the ruler. **Double-click** a row to add a key there, **drag** a key to move it (keys snap to the frame rate, *fps*), click one to change it in the panel underneath, **Delete** removes it.
- **Click or drag the ruler** to move the playhead. The scene's objects go where the sequence has them at that time, and with **Look Through Shots** the Scene view's camera goes to the camera shot. **Play** plays it (sounds and subtitles too), **Stop Preview** puts everything back as it was. Starting the game or saving the scene puts it back first, so a preview never ends up saved in the scene.
- **K** (or **Key Selected Object Here**) keys the selected object where it stands, at the playhead, on its Transform track (made if needed). So: move the playhead, move the object with the gizmo, press K; repeat.
- Ctrl+wheel zooms the timeline in; the wheel then scrolls it. **Length** is how long the sequence runs (it also runs to its last key, if that is later).

| Track | Each key |
|---|---|
| **Transform** | Where the object is (local position), its turn and optionally its size. Between keys it moves *smoothly* (slow at both ends), *linearly* or not at all until the next key (*step*): set on the key it leaves. |
| **Camera** | A **shot**: an object whose position, facing and field of view the camera takes from that time (an empty object is fine; a Camera on it gives its field of view). **Blend** moves the camera from the shot before over that many seconds instead of cutting. A new key on this track makes a shot object where the Scene view's camera is; **Move Shot To Scene View** moves one. Shot objects can have their own Transform track, for camera moves. |
| **Animation** | An Animator state (or a clip of the object's model) to play, with a fade from the one before. |
| **Audio** | A sound: from the object's Audio Source if it has one (so its subtitle file is shown, see `docs/dialogue.md`), otherwise at the object, or in both ears with no object. |
| **Show / Hide** | Whether the object is shown from that time. |
| **Event** | A name and a number for the game: start the boss, open the gate, give a reward. |
| **Subtitle** | A line, with who says it, shown for a time (or for long enough to read it). |
| **Fade** | How far the screen is covered by the track's colour (0 clear, 1 covered), eased to the next key. |

Objects are found by name, or by a path of names (`Ship/Hatch`): under the Sequence Player's object first, then anywhere in the scene. So a cutscene can bring its own shot objects as children of its player, and still move the scene's characters.

### The file

```
sequence length 8 framerate 30
track camera
	shot 0 "Shot Wide"
	shot 3 "Shot Close" blend 1.5 fov 40
track transform "Shot Wide"
	key 0 position 0 3 -10 rotation 10 0 0
	key 3 position 2 3 -6 rotation 12 -15 0 ease linear
track animation "Hero"
	play 0.5 "Wave" fade 0.2
track audio "Hero"
	sound 0.5 "Voice/hello.ogg" volume 0.9
track active "Gate"
	set 0 on
	set 6 off
track subtitle
	line 0.5 "Hero" "Over here!" length 2
track event
	event 6 GateOpened 1
track fade color 0 0 0
	key 0 1
	key 1 0
```

A track's line names its object (none: the Sequence Player's own); `muted` leaves it out. Lines starting with `#` are comments (the Sequencer tab does not keep them when it saves). Mistakes are reported by line in the tab's toolbar and the Console.

## Playing it: the Sequence Player

Add a **Sequence Player** (under *Animation*) to an object and pick its **Sequence**. In play mode the Inspector has Play, Pause, Skip and the time.

| Setting | |
|---|---|
| **Play On Start** | Starts when the scene starts. Otherwise call `Play()` (from a trigger, a dialogue event, the end of a level). |
| **Loop** | Starts again when it ends (a lift, a patrol, a machine). |
| **Speed** | 1 is as made. |
| **Skippable** | Enter, a controller's Start button, or a project input action named `Sequence Skip`, skips it. |
| **Restore When Done** | When it stops or ends, the objects it moved, showed or hid go back as they were. Off: they stay where it left them (the door stays open). |
| **Use Camera Shots** | While it plays and has a shot, the game is seen through the shots; afterwards through its own camera again. Off: the game's camera is left alone (for sequences that only move things). |
| **Shared**, **Only Owner Controls** | See Networking. |

```beef
let cutscene = GetComponent<SequencePlayer>();
cutscene.OnEvent.Add(new (name, value) =>
{
	if (name == "GateOpened")
		gate.Open();
});
cutscene.OnFinished.Add(new () => player.controlsEnabled = true);
player.controlsEnabled = false;
cutscene.Play();
```

`Pause()`, `Resume()`, `Stop()`, `Skip()` and `Seek(seconds)` control it; `State`, `Time`, `Length` and `ScreenFade` say where it is. **Skip** jumps to the end as if it had played: objects end where they would, characters play their last animation, events passed over still happen (so the gate still opens), and sounds and subtitles stop. **Seek** moves to a time without the events in between. `OnFinished` is called when it ends or is skipped. `SequencePlayer.PlayingCount` says how many are playing, for a game that turns its controls and interface off during cutscenes.

The camera: a Sequence Player with camera shots makes a camera of its own (a child, *Sequence Camera*) and the game is seen through it while a shot is on (`Scene.CameraOverride`; `Scene.ViewCamera` is the camera the game is seen through). The listener goes with it, so sounds are heard from the shot. The scene's camera keeps its place and comes back at the end.

A save (SaveSystem) keeps where a Sequence Player was; after loading it carries on from there, without repeating what had already happened.

## Networking

By default each machine plays its own sequences: right for a single-player game, or for something only one player sees (their own intro).

Tick **Shared** for one sequence every player sees at the same time, as in a co-op cutscene or a lift everyone rides. The server decides: it starts, pauses, skips and ends it, and every machine plays it from the server's clock, so they stay within a frame or two of each other; a player who joins part way sees it from where it is. Any player can pause or skip it (only the object's owner, with **Only Owner Controls**), which does so for everyone. Events happen on the server only (`OnEvent` fires there), where the game decides what they do; `OnFinished` is called on every machine. Movements, shots, sounds, subtitles and fades are played on each machine from the sequence, not sent. The object gets a Network Identity by itself when the session starts.

Objects a shared sequence moves should not also be moved by the network (a networked rigidbody or player): give the sequence its own objects, or stop their physics while it plays.

## Limits

- No undo in the Sequencer tab; the file is text, so version control keeps its history.
- Transform keys are local position and rotation; there are no curves to edit beyond the three eases.
- An Animation track starts states; it does not scrub the animation itself in the editor's preview.

## Tests