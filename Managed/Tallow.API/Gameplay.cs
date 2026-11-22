using System.Numerics;
using System.Text;

namespace Tallow;

/// <summary>Reads text a host entry copies into a buffer (returning its whole length, or a negative for none).</summary>
internal static class NativeText
{
    internal delegate int Copier(Span<byte> buffer);

    internal static string? Read(Copier copy)
    {
        Span<byte> buffer = stackalloc byte[256];
        int length = copy(buffer);
        if (length < 0)
            return null;
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, copy(buffer));
        }
        return Encoding.UTF8.GetString(buffer[..length]);
    }
}

/// <summary>Where the game may write files on this machine.</summary>
public static class GamePaths
{
    /// <summary>The player's folder for this game (saves, settings, screenshots), ending in a slash.</summary>
    public static string PlayerData => NativeText.Read(CSharpWorld.CopyPlayerDataPath) ?? "";
}

/// <summary>Plays sounds.</summary>
public static class Audio
{
    /// <summary>Plays a sound once at a point in the world (Effects group).</summary>
    public static void PlayOneShot(string clip, Vector3 position, float volume = 1f) =>
        CSharpAudio.PlayOneShot(clip, position, volume);

    /// <summary>Plays a sound once, not placed in the world (Interface group): menus and UI.</summary>
    public static void PlayOneShot2D(string clip, float volume = 1f) => CSharpAudio.PlayOneShot2D(clip, volume);

    /// <summary>Headphone 3D (head-related transfer function) instead of plain left-right panning.</summary>
    public static bool Hrtf { get => CSharpAudio.GetSetting(0) != 0; set => CSharpAudio.SetSetting(0, value ? 1 : 0); }
    /// <summary>How strongly HRTF shapes sounds, 0..1.</summary>
    public static float HrtfStrength { get => CSharpAudio.GetSetting(1); set => CSharpAudio.SetSetting(1, value); }
    /// <summary>The listener's head size for HRTF, 0.5..1.5.</summary>
    public static float HrtfHeadSize { get => CSharpAudio.GetSetting(2); set => CSharpAudio.SetSetting(2, value); }
    /// <summary>HRTF treble in decibels, -12..12.</summary>
    public static float HrtfTreble { get => CSharpAudio.GetSetting(3); set => CSharpAudio.SetSetting(3, value); }
    /// <summary>Every sound's volume, 0..1.</summary>
    public static float MasterVolume { get => CSharpAudio.GetSetting(4); set => CSharpAudio.SetSetting(4, value); }

    /// <summary>A mixer group's volume, 0 to 1.</summary>
    public static float GetGroupVolume(AudioGroup group) => CSharpAudio.GetGroupVolume((int)group);
    /// <summary>Sets a mixer group's volume, 0 to 1 (music, voices, effects... each on its own).</summary>
    public static void SetGroupVolume(AudioGroup group, float volume) => CSharpAudio.SetGroupVolume((int)group, volume);
}

/// <summary>The mixer groups each sound plays in, each with its own volume (Audio.SetGroupVolume).</summary>
public enum AudioGroup
{
    Effects,
    Music,
    Voice,
    Ambience,
    Interface,
    Other
}

/// <summary>Something that makes sound from its object: a radio, an engine, footsteps.</summary>
[NativeComponent("Tallow.AudioSource")]
public readonly partial record struct AudioSource(GameObject GameObject) : IComponent
{
    /// <summary>Whether the object still has an Audio Source.</summary>
    public bool IsValid => CSharpAudio.HasSource(GameObject.SceneId, GameObject.Id);
    /// <summary>Plays its Audio Clip (set in the Inspector).</summary>
    public void Play() => CSharpAudio.SourcePlay(GameObject.SceneId, GameObject.Id, "");
    /// <summary>Plays another clip in its place.</summary>
    public void Play(string clip) => CSharpAudio.SourcePlay(GameObject.SceneId, GameObject.Id, clip);
    /// <summary>A sound on top of whatever is playing, from the same place; any number can overlap.</summary>
    public void PlayOneShot(string clip, float volumeScale = 1f) =>
        CSharpAudio.SourcePlayOneShot(GameObject.SceneId, GameObject.Id, clip, volumeScale);
    /// <summary>Holds the sound where it is.</summary>
    public void Pause() => CSharpAudio.SourceControl(GameObject.SceneId, GameObject.Id, 0);
    /// <summary>Goes on after a Pause.</summary>
    public void Resume() => CSharpAudio.SourceControl(GameObject.SceneId, GameObject.Id, 1);
    /// <summary>Stops the sound (Play starts it from the beginning).</summary>
    public void Stop() => CSharpAudio.SourceControl(GameObject.SceneId, GameObject.Id, 2);
    /// <summary>Whether it is playing now.</summary>
    public bool IsPlaying => CSharpAudio.SourceIsPlaying(GameObject.SceneId, GameObject.Id);
    /// <summary>The clip's length in seconds (0 until it has been played once).</summary>
    public float Length => CSharpAudio.SourceTime(GameObject.SceneId, GameObject.Id, 0);
    /// <summary>The playback position in seconds; setting it seeks.</summary>
    public float Time
    {
        get => CSharpAudio.SourceTime(GameObject.SceneId, GameObject.Id, 1);
        set => CSharpAudio.SourceSeek(GameObject.SceneId, GameObject.Id, value);
    }
    /// <summary>Changes the pitch while it plays, without rewriting the component's saved field.</summary>
    public bool SetPitch(float pitch) => CSharpAudio.SourcePitch(GameObject.SceneId, GameObject.Id, pitch);
    /// <summary>Changes the volume while it plays, without rewriting the component's saved field.</summary>
    public bool SetVolume(float volume) => CSharpAudio.SourceVolume(GameObject.SceneId, GameObject.Id, volume);
}

/// <summary>The project's input actions (Project Settings > Input) on this machine. A networked script reads its
/// <see cref="TickInput"/> in Update instead, so the server and every client agree.</summary>
public static class InputActions
{
    /// <summary>Whether the action's button or key is down now.</summary>
    public static bool Held(string action) => CSharpInputActions.Held(action);
    /// <summary>Whether the action went down this frame.</summary>
    public static bool Pressed(string action) => CSharpInputActions.Pressed(action);
    /// <summary>Whether the action came up this frame.</summary>
    public static bool Released(string action) => CSharpInputActions.Released(action);
    /// <summary>A one-axis action's value (-1 to 1; a trigger 0 to 1).</summary>
    public static float Value(string action) => CSharpInputActions.Value(action);
    /// <summary>A two-axis action's value, such as Move (each axis -1 to 1).</summary>
    public static Vector2 Vector(string action) => CSharpInputActions.Vector(action);
    /// <summary>How far a pointer-like action (Look with a mouse) moved this frame.</summary>
    public static Vector2 Delta(string action) => CSharpInputActions.Delta(action);

    /// <summary>
    /// For a "press a key" prompt: on the frame a key, mouse button or controller button goes down, makes it
    /// binding number <paramref name="index"/> of the action (0 is the first; past the end adds one) and returns
    /// true. Works while input is switched off for a menu. Save the result with <see cref="ToText"/>.
    /// </summary>
    public static bool CaptureBinding(string action, int index) => CSharpInputActions.CaptureBinding(action, index);

    /// <summary>What a binding is called ("Space", "Mouse 1"...), or null when the action has no such binding.</summary>
    public static string? BindingName(string action, int index) =>
        NativeText.Read(buffer => CSharpInputActions.CopyBindingName(action, index, buffer));

    /// <summary>Every action's bindings as text, to keep with the player's settings.</summary>
    public static string ToText() => NativeText.Read(CSharpInputActions.CopyText) ?? "";

    /// <summary>Bindings saved with <see cref="ToText"/>, put back (when the game starts).</summary>
    public static void LoadText(string text) => CSharpInputActions.LoadText(text);

    /// <summary>Whether the action is being worked from a controller right now.</summary>
    public static bool FromGamepad(string action) => CSharpInputActions.FromGamepad(action);

    /// <summary>What to press for the action on the device in the player's hands ("E", or "B"): for prompts.</summary>
    public static string Describe(string action) =>
        NativeText.Read(buffer => CSharpInputActions.CopyDescription(action, buffer)) ?? "";

    /// <summary>Switches a whole map of actions ("Player", "Vehicle", "Menu") on or off.</summary>
    public static void SetMapEnabled(string map, bool enabled) => CSharpInputActions.SetMapEnabled(map, enabled);
}

/// <summary>Random numbers every machine agrees on, for networked scripts (System.Random is seeded differently
/// on each machine). Seeded from the object's network id, its exact position and rotation, and a salt of your own
/// for more than one draw a tick.</summary>
public static class NetRandom
{
    /// <summary>A number from 0 up to (not including) 1.</summary>
    public static float Value(Script script, int salt = 0) => Value(script.GameObject, salt);

    /// <summary>A number from 0 up to (not including) 1, the same on every machine for this object, tick and salt.</summary>
    public static float Value(GameObject gameObject, int salt = 0) =>
        CSharpGameplay.NetRandomValue(gameObject.SceneId, gameObject.Id, salt);

    /// <summary>A number from min up to max.</summary>
    public static float Range(Script script, float min, float max, int salt = 0) =>
        min + (max - min) * Value(script, salt);

    /// <summary>A whole number from min up to (not including) max.</summary>
    public static int Range(Script script, int min, int max, int salt = 0) =>
        max <= min ? min : min + Math.Min((int)(Value(script, salt) * (max - min)), max - min - 1);
}

/// <summary>Game time and the frame clock.</summary>
public static partial class Time
{
    /// <summary>Seconds of game time since play started. It follows TimeScale and stands still when that is 0.</summary>
    public static float GameTime => CSharpGameplay.GameTime();
}
