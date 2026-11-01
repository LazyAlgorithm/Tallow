# Scenes at run time

A project can have as many scenes as it likes (Project > + > Scene, or File > Save Scene As). The start scene is the one that opens with the game; `SceneManager` brings the others in while it runs.

## Adding a scene to the one that is running

```beef
let level = SceneManager.LoadAdditive(Scene, "Scenes/Harbour.tscene", true);
// ... play ...
SceneManager.Unload(level);
```

`LoadAdditive` reads a scene file and adds everything in it to the scene you give it. It returns one object, named after the file, with the file's top-level objects as its children, so the whole thing can be moved, searched or removed as a unit. Components wake up at once if the scene is playing. Pass `true` as the third argument to take the file's sky, fog and ambient light as well; leave it out to keep the current ones.

This is the way to keep levels in their own scene files, each of which can be opened, lit and edited in the editor by itself, while one small scene holds the camera, the menus and the rules of the game. The same file can be added more than once: objects get fresh ids each time.

`Unload` removes what was added, immediately. The object it is given is the one `LoadAdditive` returned.

## Changing scene

```beef
SceneManager.Load("Scenes/Credits.tscene");
```

The change happens at the start of the next frame: the running scene is stopped (components get `OnDisable` and `OnDestroy`), emptied, and the new file is loaded and started in its place. Nothing is carried over, so keep what must survive in static fields. `SceneManager.Current` is the scene last changed to, and `SceneManager.Pending` the one waiting.

In the editor this only happens in play mode, and stopping play still brings back the scene you were editing.

## Multiplayer

Scene files are not sent over the network. Every machine has the game's files, so every machine loads the scene for itself: share *which* scene is in play (a `[Sync]` field or a game message does it) and call `LoadAdditive` on each machine when it changes. Objects in an added scene are ordinary local objects; things that must be shared are spawned by the server in the usual way.

`SceneManager.Load` closes a network session in the scene it replaces.

## Limits

- Loading is not spread over frames: a large scene causes a pause while it loads.
- Objects in an added scene are not saved with the scene they were added to.