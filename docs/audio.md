# Audio

Sound works the way it does in Unity: each thing that makes sound has an **Audio Source**, and one **Audio Listener** is the player's ears. The engine is miniaudio, compiled into Tallow, so nothing needs installing; it finds PipeWire, PulseAudio or ALSA by itself when the first sound plays. A game that plays no sound never opens the sound card.

Sound files are WAV, OGG, MP3 or FLAC, kept anywhere in the project. Double-click one in the Project panel to hear it.

## Audio Source

Add one with **GameObject > Audio Source**, or Add Component > Audio. Pick an **Audio Clip** and press **Preview** in the Inspector to hear it without entering play mode; outside play mode the Scene view's camera is the listener, so you can fly around a source to judge it.

| Field | Meaning |
|---|---|
| Audio Clip | The sound file. |
| Group | The mixer group it plays into: Effects, Music, Voice, Ambience, Interface or Other. |
| Volume, Pitch | Loudness and playback speed. |
| Loop, Play On Start | Repeat, and start with the scene. |
| Stream | Read the file a little at a time. For music and long ambience. |
| Spatial | Come from the object's position. Off is plain stereo, for music and interface sounds. |
| Min Distance, Max Distance | Full volume inside the first; no quieter beyond the second. |
| Rolloff | How it fades in between: Inverse (natural), Linear (to silence at Max Distance) or Exponential. |
| Doppler | Pitch shift as it moves past. 0 turns it off. |
| Occlusion | Muffle and quieten the sound when something with a collider is between it and the listener. |
| Air Absorption | Dull distant sounds slightly. |
| Reverb Send | Reverb the source always has, on top of any reverb zone. |
| Cone Angle, Cone Outer Volume | Make it directional: full volume inside the cone in front of the object, the outer volume behind. 360 is all directions. |

With the source selected, the Scene view shows its minimum and maximum distance as spheres.

```beef
let source = GetComponent<AudioSource>();
source.Play();                              // the Audio Clip
source.Play("Sounds/alarm.ogg");            // a different one
source.PlayOneShot("Sounds/step.wav");      // on top of whatever is playing; any number can overlap
source.Pause(); source.Resume(); source.Stop();
if (source.IsPlaying) { }
```

`Length` and `Time` give the clip's length and the playback position in seconds; setting `Time` seeks.

## Audio Listener

Put an **Audio Listener** on the camera or on the player's head. If the scene has none, the first Camera is used, so a simple game needs nothing.

## Sounds without an object

```beef
Audio.PlayOneShot("Sounds/explosion.wav", position);     // at a place in the world
Audio.PlayOneShot2D("Sounds/click.wav");                 // no position: interface sounds
```

These play once and are freed when they finish.

## Headphone 3D (HRTF)

HRTF is off until you turn it on; until then direction is ordinary left-right panning. Turned on, each positioned sound is filtered through the responses measured at the two ears of a dummy head for the direction it comes from. That gives the brain what it uses to place a sound in real life: the sound reaches the nearer ear first (by up to about 0.7 milliseconds), is louder there, and is coloured differently depending on whether it is in front, behind, above or below. On headphones a sound behind you sounds behind you.

```beef
Audio.Hrtf = true;       // headphone 3D; can be switched while sounds play
Audio.Hrtf = false;      // ordinary left-right panning (the default)
```

It is made for headphones. Over speakers the two ears each hear both speakers, which undoes the effect and can make sounds seem coloured, so put the choice in your options menu ("Headphones" and "Speakers"). **File > Project Settings > Headphone 3D Audio** makes the game start with it on; it is unticked in a new project.

### Tuning

The measurements come from one standard head, and players' ears and headphones differ. Three settings let a player adjust it; all of them can change while sounds play, so they can sit on sliders in an options menu.

| Setting | Range | Default | What it does |
|---|---|---|---|
| `Audio.HrtfStrength` | 0 to 1 | 1 | How much of the effect is used. 0 sounds like panning, 1 is fully binaural. Lower it if the full effect is tiring or too coloured. |
| `Audio.HrtfHeadSize` | 0.5 to 1.5 | 1 | Scales the delay between the two ears. Raise it if sounds seem to sit too near the middle, lower it if they jump too far to the side. |
| `Audio.HrtfTreble` | -12 to 12 dB | 0 | Brightens or dulls the HRTF sound. A few decibels up helps on headphones where it sounds muffled. |

```beef
// In an options menu:
Audio.Hrtf = headphones;
Audio.HrtfStrength = strengthSlider;      // 0..1
Audio.HrtfHeadSize = headSizeSlider;      // 0.5..1.5
Audio.HrtfTreble = trebleSlider;          // -12..12
```

Values outside a range are clamped. The settings are not saved for you; store them with the rest of your options and set them again at start-up. A good menu plays a sound circling the player while they adjust.

The measurements are the MIT Media Lab's KEMAR set (Gardner and Martin, 1994), which is built into the engine; nothing is loaded from disk. A sound moving round the listener glides from one measured direction to the next.

## Volumes

```beef
Audio.MasterVolume = 0.8f;
Audio.SetGroupVolume(.Music, 0.5f);
Audio.SetGroupVolume(.Effects, 1.0f);
```

Every source plays into its group, and every group into the master, so an options menu is three sliders.

## Reverb zones

Add an **Audio Reverb Zone** where there should be an echo: a hall, a cave, a tunnel. While the listener is inside, spatial sounds gain reverb, fading in across the zone's edge.

| Field | Meaning |
|---|---|
| Radius, Fade | How far it reaches, and the width of the band at the edge over which it fades in. |
| Amount | How much reverb at full strength. |
| Room Size | Small room to large hall. |
| Damping | 0 bright and ringing, 1 dull and soft. |

## Subtitles

A sound with a subtitle file beside it (`Voice/intro.ogg` and `Voice/intro.srt`) shows its lines while it plays, and an Audio Source's **Subtitles** box turns that off. Conversations and the subtitle settings are on the Dialogue page (`docs/dialogue.md`).

## Multiplayer

`Play`, `Stop` and `PlayOneShot` on an Audio Source are shared like animation: called on the server, or by the player who controls the object, everyone hears it. Called on a client for an object it does not control, only that client hears it. `Audio.PlayOneShot` is always local.

## How good is it

What you get from a plain build: stereo panning, optional HRTF for headphones, distance attenuation with three rolloff curves, Doppler, directional cones, per-source low-pass used for occlusion and air absorption, a stereo reverb, six mixer groups, streaming, and any number of overlapping one-off sounds.

What it is not:

- **One head for everyone.** The HRTF is measured on a standard dummy head. It works well for most people, but ears differ, and a few listeners find front and back harder to tell apart than others do. It covers directions from 40 degrees below the horizon upward; sounds further below use the lowest measurement.
- **No room in the HRTF.** Sounds are placed in direction and distance, but walls only matter through occlusion and reverb zones; there are no reflections computed from the level's shape.
- **Occlusion is one ray** from the listener to the source, ten times a second, eased between answers. A sound is either blocked or not; there is no partial blocking by thin objects and no sound bending round corners.
- **Reverb comes from where the listener stands**, not from the room the source is in, and one zone applies at a time.
- A dedicated server (no window) plays nothing.

CPU tests listen to the engine's own mix with no sound card and measure it: left and right, distance, each rolloff, HRTF (off by default, the near ear louder and about 0.7 ms earlier, front, back, above and below each coloured differently, strength, head size and treble, no clicks as a sound circles or the settings are dragged), volumes and groups, looping, one-off sounds, a missing file, occlusion by a wall, air absorption, reverb tails, the camera as listener, and sounds shared over a network session.
