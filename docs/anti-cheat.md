# Anti-cheat

An optional part of the engine that watches network sessions for cheating. Tick **File > Project Settings > Anti-Cheat**, or set `AntiCheat.Enabled = true` from a script, and it works with no further code, on every system the engine runs on. It is off by default.

## What stops cheating before the anti-cheat does anything

The engine's networking is built so that the usual cheats have nothing to push against, with or without the anti-cheat:

- **The server moves every player.** A player's machine sends its controls; the server works out where that takes them, one step a tick. A changed game cannot move faster, teleport, fly or walk through walls, because it never says where it is.
- **The server decides what matters.** `[Sync]` values travel from the server only. Whatever your game decides on the server (damage, ammunition, score, who picked what up) cannot be decided by a player. *This part is up to you*: anything you let a player's machine decide can be cheated, and no anti-cheat makes that safe.

## What the anti-cheat adds

On the **server**, for every player:

| Finds | How | By default |
|---|---|---|
| Invalid controls | Impossible view angles. No unmodified game sends these. Movement past full tilt and numbers that are not numbers cannot be sent at all: controls travel packed, and the packing cannot express them. | Removed |
| Speed hack | The player's game getting through more ticks than the server's, twice in a row over five-second windows (15% leeway). They gain nothing by it (see above); this notices the attempt. | Removed |
| Message flood | More than `MessageLimit` (240) game messages in a second. Voice is not counted. | Removed |
| Changed game files | The player's asset pack is not the server's (see below). | Removed |
| No answer | The player's game does not answer the anti-cheat's question in `AnswerTime` (12 s): it has been cut out, or it is not this game. | Removed |
| Automated aim | Over at least 20 hits: more than half of them straight after turning 25° or more in a single tick and stopping dead; or nearly every shot a hit and nearly every hit a head shot. Needs the game to report shots and hits (below). | Logged |

On each **player's machine**, reported to the server:

| Finds | How | By default |
|---|---|---|
| Debugger | The system says one is attached to the game (Linux, Windows). | Logged |
| Injected library | A library forced into the game with `LD_PRELOAD` (Linux) or `DYLD_INSERT_LIBRARIES` (macOS), or loaded into it after it started from somewhere neither the system's nor the game's own libraries come from (Linux, Windows). Known overlays, recorders and drivers are let be (Steam's overlay, Discord, MangoHud, GameMode, OBS, graphics drivers). | Logged |
| Patched code | The game's own instructions in memory are no longer what was loaded: a hook or a patch written into them (or a debugger's breakpoint). Checked every few seconds (Linux, Windows). | Removed |
| Clock tampering | The clock the game runs on and one that speed tools rarely reach disagree by more than 8%, twice in a row. | Logged |
| Edited memory | A `GuardedInt` or `GuardedFloat` was changed from outside the game. | Removed |

A built game with the anti-cheat on also **closes its memory to other programs** when it starts (`AntiCheat.Harden()`): on Linux other programs of the same user can no longer attach to it or open its memory, and on Windows opening the process to read, write or start threads in it is denied. That is how memory editors, trainers and injectors get in, so the common ones simply fail. (To look into your own built game with a debugger, start it with `TALLOW_HARDEN=off` in its environment.) The library and code checks above run in built games only; the editor loads and patches code on purpose when it reloads scripts.

"Removed" means the player is told why, disconnected, and everyone can be told (`OnViolation`). "Logged" is for things honest players also trip: developers run debuggers, tools preload libraries, clocks hiccup, and some people really do aim that well. Change any of them:

```beef
AntiCheat.SetAction(.Debugger, .Kick);        // a competitive game might
AntiCheat.SetAction(.SuspiciousAim, .Ignore);
```

## Game files

A built game's assets are in an asset pack (see [Building a standalone game](standalone-player)). The anti-cheat reduces the pack's game content (everything under `Assets/`: each file's name and checksum) to one number, the same on Linux and Windows for the same project. The server sends each player a random number; the player's game answers with what its own content makes of it; a wrong answer means different files. The fingerprint itself never travels.

- Both sides must be running from a pack. A game run from loose files (in the editor, or built with packing off) has nothing to compare, and the check is skipped when the *server* is like that. A packed server does not accept a player running from loose files.
- The pack already refuses to load a file that was edited inside it; this catches a whole different pack.

## Telling it about shots

The aim check needs to know when a player fires and hits. On the server:

```beef
AntiCheat.ReportShot(clientId);                 // every pull of the trigger
AntiCheat.ReportHit(clientId, headshot);        // when it hit another player
```

`AntiCheat.AimStats(clientId, out shots, out hits, out headshots, out snapHits)` gives the numbers behind it. Report what your own server code catches the same way, and the same rules apply:

```beef
if (price > player.money)
    AntiCheat.Report(clientId, .MemoryTampering, "bought something with no money");
```

## Guarded values

For numbers a player's machine is trusted with (in a single-player game, or where the server does not decide them):

```beef
GuardedInt coins = 100;
coins += 5;
int32 shown = coins;
GuardedFloat health = 100;
```

The number is kept scrambled, so a memory editor does not find it by searching for its value, with a check beside it, so a write is noticed: the anti-cheat is told and the real value comes back. Where the server decides a value, nothing on a player's machine needs guarding.

## What was found, and bans

```beef
AntiCheat.OnViolation.Add(new (clientId, kind, detail) =>
    {
        // Show it, save it, or ban: clientId is the session's number for the player.
    });
for (let violation in AntiCheat.Violations) { /* the last 256, newest last */ }
```

On a removed player's machine `AntiCheat.KickReason` says why; show it instead of "connection lost".

Bans are kept by whatever your game knows a player by (a Steam ID, an account name, an address): `AntiCheat.Ban(key)`, `IsBanned(key)`, `Unban(key)`, and `BansToText` / `BansFromText` to keep the list in a file. Ask `IsBanned` when someone joins and `Kick` them (see [Networking](networking)).

## What it cannot do

Be clear about this before relying on it.

- **It runs inside the game, with the player's permissions.** Commercial anti-cheats (Easy Anti-Cheat, BattlEye, Vanguard) load a driver into the operating system's kernel and watch the game from outside. This does not. A cheat that runs in the kernel, on a second machine, or simply patches these checks out of the game cannot be seen from in here, and anyone determined enough can do the last of those. The server-side checks do not depend on the player's machine and are the part that holds.
- **Reading memory cannot be detected, only made harder.** Nothing tells a program that its memory was read. Hardening shuts out ordinary programs run by the same user, and guarded values hide numbers from a search; a tool run as root or administrator, or a driver, reads whatever it likes and the game never knows. Writing is different only when it lands on something checked: a guarded value or the game's code. Other values a player's machine holds can be changed unseen, which is why the server should decide what matters.
- **Injection that leaves no library behind.** The library check sees files loaded into the game. Code written straight into memory with no file ("manual mapping") is not a library and is not seen, unless it patches the game's own code, which is.
- **Wall hacks and radar.** The server sends every player the positions of the others, and a changed game can draw them. Stopping that means not sending what a player cannot see, which the engine does not do yet.
- **Aim bots that look human.** The aim check catches the crude ones: instant turns, perfect records. One that turns smoothly and misses on purpose looks like a good player, to this and to every other statistical check.
- **A changed executable.** The file check covers the asset pack, not the program itself (a Linux server cannot know what a Windows program should look like).
- **Input devices and macros** outside the computer.

What it does do is make the common tools fail or announce themselves: speed tools, memory editors, packet edits, swapped asset packs, preloaded hooks. For a game played among friends that is the realistic threat. For ranked competitive play, plan on a commercial kernel-level service as well; they exist for Linux and Windows and can sit beside this.

## Testing it

`python3 Tests/AntiCheat/run.py` runs an honest player and then one cheat at a time against a real loopback session. `AntiCheat.TestFlags`, `TestSilent` and `TestFingerprint` make a player's machine misbehave on purpose.
