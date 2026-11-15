using System.Numerics;

namespace Tallow;

/// <summary>Plays sounds.</summary>
public static class Audio
{
    /// <summary>Plays a sound once at a point in the world (Effects group).</summary>
    public static void PlayOneShot(string clip, Vector3 position, float volume = 1f) =>
        CSharpAudio.PlayOneShot(clip, position, volume);

    /// <summary>Plays a sound once, not placed in the world (Interface group): menus and UI.</summary>
    public static void PlayOneShot2D(string clip, float volume = 1f) => CSharpAudio.PlayOneShot2D(clip, volume);
}

/// <summary>The project's input actions (Project Settings > Input) on this machine. A networked script reads its
/// <see cref="TickInput"/> in Update instead, so the server and every client agree.</summary>
public static class InputActions
{
    public static bool Held(string action) => CSharpInputActions.Held(action);
    public static bool Pressed(string action) => CSharpInputActions.Pressed(action);
    public static bool Released(string action) => CSharpInputActions.Released(action);
    public static float Value(string action) => CSharpInputActions.Value(action);
    public static Vector2 Vector(string action) => CSharpInputActions.Vector(action);
    public static Vector2 Delta(string action) => CSharpInputActions.Delta(action);
}

/// <summary>Random numbers every machine agrees on, for networked scripts (System.Random is seeded differently
/// on each machine). Seeded from the object's network id, its exact position and rotation, and a salt of your own
/// for more than one draw a tick.</summary>
public static class NetRandom
{
    /// <summary>A number from 0 up to (not including) 1.</summary>
    public static float Value(Script script, int salt = 0) => Value(script.GameObject, salt);

    public static float Value(GameObject gameObject, int salt = 0) =>
        CSharpGameplay.NetRandomValue(gameObject.SceneId, gameObject.Id, salt);

    /// <summary>A number from min up to max.</summary>
    public static float Range(Script script, float min, float max, int salt = 0) =>
        min + (max - min) * Value(script, salt);

    /// <summary>A whole number from min up to (not including) max.</summary>
    public static int Range(Script script, int min, int max, int salt = 0) =>
        max <= min ? min : min + Math.Min((int)(Value(script, salt) * (max - min)), max - min - 1);
}

public static partial class Time
{
    /// <summary>Seconds of game time since play started. It follows TimeScale and stands still when that is 0.</summary>
    public static float GameTime => CSharpGameplay.GameTime();
}
