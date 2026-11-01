# Saving

Mark what to keep with `[Saved]`, then call `SaveSystem.Save()` and `SaveSystem.Load()`. Everything else is taken care of.

```beef
[Component]
class Player : Component
{
    [Saved] public int32 coins;
    [Saved] public Vector3 checkpoint;
    [Saved] public List<int32> unlockedLevels = new .() ~ delete _;
    [Saved] public float[4] bestLaps;
    [Saved("hp")] public float health;   // stored under "hp": rename the field later without breaking saves
    public float speed;                   // not saved
}

SaveSystem.Save();          // the "default" slot
SaveSystem.Save("Castle");  // or any name a player types
SaveSystem.Load("Castle");
```

## What can be saved

| Kind | Types |
|---|---|
| Numbers and text | `bool`, every integer size, `float`, `double`, `char8/16/32`, `String`, enums |
| Engine types | `Vector2`, `Vector3`, `Vector4`, `Int3`, `Quaternion`, `Color`, `Matrix4` |
| Scene references | `GameObject`, `Transform`, any component: saved as which object it is, and pointed at the right one again on loading |
| Your own types | structs and classes whose fields are marked `[Saved]` (a derived class keeps its base's) |
| Collections | `T[]`, `T[,]`, `T[,,]`, `T[,,,]`, sized arrays `T[N]`, `List`, `Queue`, `HashSet`, `LinkedList`, `Dictionary`, nested any way (`List<Dictionary<String, Vector3[]>>`) |

The code that saves and loads each field is written by the compiler from the field's type when the game is built: there is no reflection while saving, and a field of a type that cannot be saved is a compile error that names it. Collections of objects own them: loading deletes what a collection held and makes new objects (references to scene objects excepted).

A save keeps values by name, not by position, so saves from older versions of a game load: a field the save does not have keeps its default, and a saved value with no field left for it is skipped.

## Saving and loading a scene

`Save` gathers every `[Saved]` field of every component in the scene. `Load`:

1. changes to the saved scene, if another one is playing, and carries on once it has started;
2. takes away scene objects that had been destroyed when the game was saved;
3. makes again the objects that were made while playing, from a prefab file or a registered network prefab, if they have something saved (a `[Saved]` field or a Saved Transform): dropped items, placed blocks;
4. puts every field back, and points references at the objects as they are now;
5. calls `OnLoaded()` on each component it loaded, to rebuild what it makes from its fields. `OnSaving()` is called just before a save reads them.

Objects are known by their id in the scene file, and objects made while playing by the id they had and their place under it, so the same scene and prefabs always match up. Objects that belong to a connected player (their Network Identity has an owner) are left out: they are the player's, not the save's.

In a network session only the server saves and loads; what it loads reaches the clients through the usual networking.

## Position and movement: Saved Transform

`[Saved]` cannot go on the engine's Transform, so add a **Saved Transform** component to objects whose place should be kept. Choose what to keep, for less to store: position X, Y and Z separately, rotation, scale. With a Rigidbody or Character Controller it also keeps velocity and spin, so an object that was falling or rolling when the game was saved carries on when it is loaded. An object made while playing with a Saved Transform is made again where it was.

## Slots and storage

Slots are names: "default", "slot 2", "My Castle: v2". `SaveSystem.Exists(name)`, `Delete(name)` and `ListSlots(list)` manage them.

`SaveSystem.Storage` decides where saves go. The default, `FileSaveStorage`, keeps one file per slot in `GamePaths.PlayerData + "saves/"`, writing to a temporary file first so a crash never leaves half a save, and turning any name into a file name it can turn back. `MemorySaveStorage` keeps them in memory. For a server, a cloud service or a platform's own saves, derive from `SaveStorage`:

```beef
class ServerStorage : SaveStorage
{
    public override void Write(SaveTask task)
    {
        // Send task.data (bytes) under task.slot, then, from any thread:
        task.Finish(true);          // or task.Fail("why")
    }

    public override void Read(SaveTask task)
    {
        // Fetch into task.data, then:
        task.Finish(true, true);   // succeeded, and the slot had a save
    }
}

SaveSystem.Storage = new ServerStorage();   // in GameSetup.Register
```

`Save` and `Load` return a `SaveHandle` to ask about later (`Done`, `Succeeded`, `Found`, `Error(text)`), and the `SaveSystem.Saved` and `SaveSystem.Loaded` events fire when they finish.

To keep saves your own way, `SaveSystem.Capture()` returns the scene's saved state as a `SaveNode` tree and `SaveSystem.Apply(node)` puts one back. A tree turns into compact checksummed bytes (`ToBytes`, `FromBytes`: a changed or damaged save is refused) or readable JSON (`ToText`, `FromText`).

## Loading at start

Tick **Load Save At Start** in Project Settings (and choose the slot), or set `SaveSystem.LoadAtStart = true` in `GameSetup.Register`. The save is put back as the first scene starts: after its objects are made and before any script's `Awake`, so scripts only ever see loaded values. With a storage that answers later, the scene waits for it, up to `SaveSystem.StartTimeout` seconds, and starts with its defaults if it does not come.

## The player's folder: GamePaths

`GamePaths.PlayerData` is the folder for the player's own files on every platform, ending in a slash:

| Platform | Folder |
|---|---|
| Windows | `%APPDATA%\Tallow\<Game>\` |
| Linux | `~/.local/share/Tallow/<Game>/` |
| macOS | `~/Library/Application Support/Tallow/<Game>/` |
| Web | the browser's storage for the page, kept between visits |

```beef
let path = scope $"{GamePaths.PlayerData}notes.txt";
```

`<Game>` is the project's name; `company = ...` in the build's manifest replaces "Tallow". The game's own folder is for reading only.

## Data assets

A data asset is a file of data every script shares: settings, a table of weapons, the levels in order. Write a class, make the file, fill it in, and read it from anywhere:

```beef
[DataAsset]
class GameSettings : DataAsset
{
    public float maxFieldOfView = 95;           // set in the Inspector: the same for every player
    [Saved] public float volume = 0.8f;           // each player's own
    [Saved] public String name = new .("Player") ~ delete _;
}

let settings = DataAsset.Get<GameSettings>();   // loaded once, shared by every script
settings.volume = 0.5f;
settings.Save();                                // keeps this player's [Saved] fields
```

- **Making one:** Project panel, **+ > Data Asset**, choose the class. Click the `.tdata` file to edit it in the Inspector; changes are written to the file at once.
- **Finding it:** `DataAsset.Get<T>()` returns the project's asset of that class (the first file made from it); `Get<T>(path)` a particular one; `DataAsset.FilesOf(type, list)` all of them. A class with no file still works, with the values written in the code.
- **The player's copy:** fields marked `[Saved]` are the player's to change. `Save()` keeps them in `GamePaths.PlayerData + "data/"` (or `DataAsset.Storage`), and the next `Get` puts them over the file's values and calls `OnLoaded()`. `Revert()` forgets them and goes back to the file. The Inspector's **Forget my saved copy** does the same on your machine.
- **In the editor:** stopping play and reloading scripts drop loaded assets, so the next Play reads the files afresh. `DataAsset.CacheVersion` changes when that happens, for code that keeps an asset.

Data assets are kept apart from `SaveSystem` saves on purpose: loading an old save does not undo a player's settings.

## Tests