# Steam and achievements

Steam support is built in and optional. The Steamworks library is loaded only when the game asks for it, so a project that never mentions Steam runs without it, and the same build runs with or without the Steam client.

## Setting up

1. Open **File > Project Settings** and enter your **Steam App ID**. Use `480`, Valve's public test app, until you have your own. Leave it at 0 for a game that does not use Steam.
2. Have the Steam client running and signed in.
3. For a release, put the `libsteam_api` file from the Steamworks SDK beside the game's executable. During development the engine also finds the copy inside a local Steam installation.

```beef
if (Steam.Start())                              // connects with the project's App ID; false if Steam is not there
    Log.Info(scope $"Signed in as {Steam.UserName} ({Steam.UserId})");
```

`Steam.Start()` is safe to call any time; the engine calls it for you when achievements or the Steam transport are used. `Steam.Error` says why it failed.

## Achievements

One call unlocks an achievement:

```beef
Achievements.Unlock("FIRST_WIN");
```

| Call | What it does |
|---|---|
| `Unlock(id)` | Unlocks it. Returns true the first time, false if the player already had it. |
| `IsUnlocked(id)` | Whether the player has it. |
| `SetProgress(id, current, max)` | Shows progress, and unlocks when current reaches max. |
| `AddStat(name, amount)`, `SetStat`, `GetStat` | Whole-number counters such as kills or games played. |
| `Clear(id)`, `ClearAll()` | Take them away again, for testing. |
| `OnUnlocked` | An event raised with the id when one is unlocked. |

The same code works everywhere:

- **Under Steam** the achievement goes to the player's Steam account and Steam shows its own pop-up.
- **Without Steam** (in the editor, or a build with no App ID) progress is kept in a small file on the player's machine and the engine draws a pop-up in the game. Set `Achievements.ShowToasts = false` to draw your own.

### Local-only achievements

Each achievement can have **Local only** checked in Window > Achievements. These IDs always use local saves and the in-game popup, even while Steam is connected. Unlock, query, progress and per-ID reset do not call Steam. They never need a Steamworks entry. New editor entries default to Local only; existing files and Steam imports keep their previous behavior.

The definition format accepts independent `hidden` and `local-only` flags:

```text
achievement "TOYBOX_TROUBLE" "Toybox Trouble" "Hit 25 physics props." local-only
```

For counters used only by local achievements, pass `localOnly: true` to `GetStat`, `SetStat` or `AddStat` (third parameter for AddStat). Otherwise counters retain their normal Steam/local backend behavior. Clearing Local only later does not upload previous local unlocks: create the matching Steamworks ID first, then a future unlock uses Steam. Global Lock All still resets both Steam and local progress when connected.

### The Achievements window

**Window > Achievements** lists the project's achievements: an id, a name, a description and whether it is hidden until earned. **Save** writes them to `Achievements.tach` in the project, which ships with the game.

- **Unlock** and **Lock** on each row let you try the game's reaction without playing to that point.
- **Import from Steam** adds the achievements your app already has on Steam.
- **Lock All** clears everything, after asking.

When the editor is connected to Steam, the test buttons change the signed-in account for that app. With App ID 0 they only touch the local file.

Steam does not let a game create achievements: each one must also be made on the Steamworks site, with exactly the same id. Steam keeps its own names, descriptions and icons; the ones here are used for the pop-up when the game runs without Steam. Stats used with `AddStat` must likewise exist on the Steamworks site.

## Multiplayer over Steam

Set **Transport** to **Steam** on the Network Session. Players are then reached by Steam ID through Steam's relay network, so nobody forwards a port or shares an IP address.

- The host's Console prints the number to join with: `Others join with --connect 7656119...`
- A client puts that number in the session's **Address**, or starts with `--connect <steam id>`.
- **Steam App Id** on the session overrides the project's; with neither set, 480 is used.

Everything else about networking is the same on either transport.

## Friends, presence and invitations

For "play with a friend" without typing numbers. All of these do nothing, and return nothing, without Steam.

| Call | What it does |
|---|---|
| `Steam.FriendCount`, `Steam.FriendAt(index)` | The signed-in player's friends, as Steam IDs. |
| `Steam.FriendName(id, name)`, `Steam.FriendOnline(id)` | A friend's name, and whether they are signed in. |
| `Steam.IsFriend(id)` | Whether a Steam ID is one of the player's friends: for a friends-only match. |
| `Steam.SetPresence(key, value)` | Publishes a piece of text about what this player is doing. Friends running the same game can read it. Steam itself shows the `status` key in the friends list and offers a Join button when `connect` is set. |
| `Steam.FriendPresence(id, key, value)` | Reads what a friend published. Empty when they are not in this game. |
| `Steam.ClearPresence()` | Removes everything this player published (also done at shutdown). |
| `Steam.Invite(friend, connect)` | Sends a Steam invitation. `connect` is handed to the friend's game when they accept: use the host's Steam ID. |
| `Steam.TakeJoinRequest(connect)` | True once after the player accepted an invitation, or pressed Join in the friends list, while the game was running. |

A host that publishes its Steam ID lets friends find and join its match:

```beef
// Host, every couple of seconds:
Steam.SetPresence("connect", scope $"{Steam.UserId}");
Steam.SetPresence("status", "Deathmatch on Foundry");

// Friend, on the Join screen:
for (int i < Steam.FriendCount)
{
    let friend = Steam.FriendAt(i);
    let host = scope String();
    Steam.FriendPresence(friend, "connect", host);
    if (!host.IsEmpty) { /* list this friend; to join, start a client with the address set to host */ }
}

// Either, every frame:
let host = scope String();
if (Steam.TakeJoinRequest(host)) { /* join host */ }
```

Call `Steam.Update()` once a frame while no network session is running, so that Steam can deliver the request.

Two things to know about invitations while a game uses the test App ID 480: Steam calls the game "Spacewar", and a friend who accepts an invitation without the game already open is offered Spacewar by Steam, not your game. So have the friend start the game first. Reading friends' presence does not have that problem, which is why the example above lists friends' games in the game itself. With your own App ID, Steam starts your game for them.

## Shipping with Steam

A game with a Steam App ID needs Valve's Steamworks library beside its executable: `libsteam_api.so` on Linux, `steam_api64.dll` on Windows. File > Build... copies it from the project folder if one is there, and otherwise from a Steam installation on the build machine (which has the Linux one only), and writes `steam_appid.txt`. For Windows, put `steam_api64.dll` from the Steamworks SDK in the project folder. Libraries from before 2023 work too. A build without the library still runs; it just has no Steam.

## Workshop: content made by players

A Workshop item is a folder of files a player publishes: scenes, prefabs, models, textures, behaviour trees. `Workshop` covers the whole round trip.

**Using what players subscribed to.** One call at start-up makes every installed item's files loadable like the game's own:

```beef
let count = Workshop.MountInstalled();
Log.Info(scope $"{count} Workshop item(s) loaded.");
```

After that, an item containing `Scenes/Arena.tscene` can be opened as `"Scenes/Arena.tscene"`, and a file with the same path as one of the game's replaces it. `Workshop.Mounted` lists the folders, for games that want to show what each item adds. Call `MountInstalled` again after the player subscribes to something.

Underneath, this uses `Assets.AddSearchPath(folder)`, which works for any folder, so a `Mods` directory beside the game can be supported the same way without Steam.

**Browsing and subscribing.** Results arrive a moment later, on the main thread:

```beef
Workshop.Browse(.Popular, 1, "", new (items, ok) =>
{
    for (let item in items)
        Log.Info(scope $"{item.title} ({item.id})");
});

Workshop.Subscribe(item.id);        // Steam downloads it in the background
if (Workshop.IsInstalled(item.id)) Workshop.MountInstalled();
```

`Browse` takes `.Popular`, `.Newest`, `.Trending` or `.Search` with search text, and returns 50 items a page. Each item has an `id`, `title`, `description`, `tags`, `previewUrl` and `owner`. `BrowseMine` lists what the signed-in player has published. `IsSubscribed`, `IsInstalled`, `IsDownloading`, `NeedsUpdate`, `GetFolder`, `Download` and `Unsubscribe` cover the rest.

**Publishing.** Give it a folder:

```beef
Workshop.Publish(folder, "My arena", "A small arena for four players.", previewPng, "level,arena", .Public, 0,
    new (id, ok, message) => Log.Info(ok ? scope $"Published as {id}" : message));
```

Pass the id from an earlier publish instead of `0` to update that item. `Workshop.PublishProgress` (0 to 1) and `IsPublishing` are there for a progress bar. Visibility is `.Public`, `.FriendsOnly`, `.Private` or `.Unlisted`.

What to know:

- The Workshop must be enabled for your app on the Steamworks site, and each player must accept Steam's Workshop agreement once before their first upload appears.
- Scripts are not content. A built game cannot load new code, so an item that adds behaviour must do it with data the game already understands: scenes, prefabs, behaviour trees.
- Without Steam, `Workshop.Available` is false, `MountInstalled` mounts nothing and requests call back at once with `ok` false.

## Using more of Steamworks

`Steam.Symbol("SteamAPI_...")` returns any function from the SDK's flat API as a pointer, and `Steam.Library` is the loaded library, so features that are not wrapped here (lobbies, leaderboards, the workshop) can be bound without changing the engine. Call `Steam.Update()` once a frame only if you run your own loop; the engine's loop already does.

## Limits

- Wrapped today: start-up, the user's name and id, achievements and integer stats, the Workshop, and the networking sockets behind the Steam transport. Lobbies, invites, leaderboards and cloud saves are not wrapped.
- The Workshop has no editor window yet; publishing is a call from your own game or tool.
- A client needs the host's Steam ID; there is no in-game friend list or invite yet.
- Tested on Linux with the Steam client running: start-up, reading the test app's achievements, and a full game session between two sessions on one account. Browsing and searching the Workshop were checked against the test app's real items. Unlocking an achievement on Steam, subscribing to or publishing a Workshop item, and play between two different accounts have not been tried.

## Editor runtime location

Download the Steamworks runtime from Valve's SDK: <https://partner.steamgames.com/doc/sdk>. Linux x86_64 uses `sdk/redistributable_bin/linux64/libsteam_api.so`; Windows x64 uses `sdk/redistributable_bin/win64/steam_api64.dll`. Installing the Steam client alone does not place this library inside a Tallow project.

Put the platform library in `<project>/Libraries/` (or the project root). The editor searches that location, and game packaging copies the library beside the executable. Restart the editor after adding a previously missing library. Live achievements also require a running Steam client, the correct App ID and achievements configured/published in Steamworks. Local achievements can be edited without a connected Steam session.

Regression: build `Tests/Achievements`, then run `python3 tools/test_steam_library_lookup.py <AchievementTests executable>`. It uses a fake local runtime and does not connect to Steam or change account achievements.

`Steam.FriendAppId(friendId)` uses `ISteamFriends::GetFriendGamePlayed` to identify a friend's current game independently of rich presence. It returns 0 when unavailable, when the friend is not playing, or when an older runtime lacks the query. Filter with `Steam.FriendOnline` before presenting invitations. API layout and fallback tests use an in-process fake backend in `Tests/Achievements`; no Steam account is contacted.
