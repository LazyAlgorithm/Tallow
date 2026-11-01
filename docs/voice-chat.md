# Voice chat

Players in a network session can talk to each other. It is built in and off by default: tick **File > Project Settings > Voice Chat**, or set `VoiceChat.Enabled = true` from a script, and that is all a game has to do. The engine opens the microphone, compresses speech with Opus, sends it through the server and plays it on the other players' machines. It works over both transports (direct and Steam) and needs nothing installed.

A game with voice chat off never opens a microphone. A game with no network session has nobody to talk to, and does not open one either (except for the microphone test below).

## Open microphone or push to talk

| Setting | Default | What it does |
|---|---|---|
| `VoiceChat.Enabled` | off | Master switch. |
| `VoiceChat.PushToTalk` | off | Off: you are heard whenever you speak. On: only while the key is held. |
| `VoiceChat.PushToTalkKey` | `.V` | The key to hold. Any `KeyCode`. |
| `VoiceChat.PushToTalkAction` | `"Talk"` | An input action that is held to talk as well, so that the key can be changed in Window > Input Actions and a controller button works: the standard Talk action is V and d-pad down. Set `PushToTalkKey = .None` to use only the action. |
| `VoiceChat.Talk` | false | Set it true from your own code to talk without the key: a gamepad button, a touch button. |
| `VoiceChat.Activation` | 0.02 | Open microphone only: how loud you must be before sending starts (0 to 1). |
| `VoiceChat.ReleaseTime` | 0.5 s | Open microphone only: how long sending continues after you fall quiet. |

The first three are also in Project Settings (Voice Chat, Push To Talk, Push To Talk Key), which is what a new game starts with. All of them can be changed while the game runs, so an options menu can let each player choose:

```beef
VoiceChat.PushToTalk = pushToTalkBox;
VoiceChat.PushToTalkKey = chosenKey;        // for example from a "press a key" prompt
VoiceChat.Activation = sensitivitySlider;   // show VoiceChat.MicrophoneLevel beside it
```

The settings are not saved for you; store them with the rest of the player's options.

## Who hears whom

| Setting | Default | What it does |
|---|---|---|
| `VoiceChat.Proximity` | off | Off: everyone hears everyone, like a radio. On: a voice comes from the speaker's character, fades with distance and is gone beyond `MaxDistance`. |
| `VoiceChat.MinDistance`, `MaxDistance` | 2, 30 | With Proximity on: full volume within the first, silent beyond the second. |
| `VoiceChat.TeamOnly` | off | Players hear only their own team (see [Spawn points](spawn-points) for teams). |

Team and distance are decided by the **server**: speech is simply not sent to players who should not hear it, so a modified client cannot listen in on the other team or on a far-away conversation. Proximity and Team Only are in Project Settings too. With Proximity on, voices are ordinary positioned sounds, so they are occluded by walls, pick up reverb zones and use HRTF if it is on (see [Audio](audio)).

## Volume, muting and who is talking

```beef
VoiceChat.Volume = 0.8f;                 // other players' voices
VoiceChat.MicrophoneVolume = 1.5f;       // your microphone, before it is sent
VoiceChat.Muted = true;                  // stop sending without turning voice chat off
VoiceChat.Deafened = true;               // stop hearing others
VoiceChat.Mute(clientId, true);          // silence one player, on this machine only
Audio.SetGroupVolume(.Voice, 0.5f);      // the Voice mixer group applies as well

if (VoiceChat.IsSpeaking(clientId)) { /* draw a speaker icon over their head */ }
if (VoiceChat.IsTransmitting) { /* draw a microphone icon for yourself */ }
VoiceChat.OnSpeakingChanged.Add(new (clientId, speaking) => { /* update a player list */ });
```

A player's client id is `ownerId` on their Network Identity; the host's own player is 0.

## A microphone test for the options menu

```beef
VoiceChat.Enabled = true;
VoiceChat.Loopback = true;               // you hear yourself; works without a session
float level = VoiceChat.MicrophoneLevel; // 0 to about 1, for a meter
bool hasOne = VoiceChat.HasMicrophone;   // false: hide the microphone options
```

Turn `Loopback` off again when the player leaves the menu.

## What it costs

Speech is sent in 20 millisecond frames at 24,000 bits per second: about 3 KB/s for each person talking, and nothing while they are silent. `VoiceChat.Bitrate` changes it (12,000 is still clear speech; 64,000 is close to transparent). Voice travels on the unreliable channel so that a lost packet is never waited for. Each packet carries a low-quality copy of the one before it, so a single lost packet is rebuilt, and longer gaps are smoothed over.

The server relays speech and never decodes it, so a dedicated server spends almost nothing on voice. It turns away a client that sends far more than a microphone could.

## Limits

- **No echo cancellation or noise removal.** A player on speakers with an open microphone will send the game's sound back to everyone. Push to talk avoids it; so do headphones.
- **Through the server only.** There are no private channels, and no talking to players in a lobby before a session exists.
- **The default microphone** of the system is used; there is no device picker.
- **The microphone stays open** while voice chat is on and you are in a session, even with push to talk, so that the first word is not clipped. Nothing leaves the machine until you transmit.
- With Steam, this uses Tallow's own voice path, not Steam's voice API, so Steam's voice settings do not apply.

## Tests

`BeefBuild -workspace=Tests/Voice -config=Debug -run` runs a host and two clients in one process with no microphone or sound card: speech is handed in as samples and what would be played is counted and measured. It covers: off by default, speech reaching host and client but not the speaker, the compressed size, the played-back tone matching what was spoken, the activation level, push to talk, muting yourself and others, team only, proximity, 20% packet loss, a flooding client, malformed packets, deafen, switching off mid-game and the microphone test.
