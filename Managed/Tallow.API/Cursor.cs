namespace Tallow;

/// <summary>
/// Mouse pointer capture. The engine releases the pointer when play stops; in
/// the editor it is only captured while the Game view is being played in.
/// </summary>
public static partial class Cursor
{
    /// <summary>Hide the pointer and keep it inside the game window.</summary>
    public static bool Locked
    {
        get => IsLocked();
        set => SetLocked(value);
    }
}
