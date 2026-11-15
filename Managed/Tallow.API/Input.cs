using System.Numerics;

namespace Tallow;

/// <summary>
/// Keyboard keys. The numbers are the engine's own key codes; do not reorder.
/// Kept identical to the native enum by tools/check_csharp_enums.py.
/// </summary>
public enum KeyCode
{
    None = 0,
    A = 4, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    Alpha1 = 30, Alpha2, Alpha3, Alpha4, Alpha5, Alpha6, Alpha7, Alpha8, Alpha9, Alpha0,
    Return = 40, Escape, Backspace, Tab, Space,
    F1 = 58, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    Delete = 76,
    RightArrow = 79, LeftArrow, DownArrow, UpArrow,
    Minus = 45, Equals, LeftBracket, RightBracket, Backslash,
    Semicolon = 51, Apostrophe, Grave, Comma, Period, Slash, CapsLock,
    Insert = 73, Home, PageUp,
    End = 77, PageDown,
    LeftControl = 224, LeftShift, LeftAlt,
    RightControl = 228, RightShift, RightAlt
}

/// <summary>Mouse buttons for <see cref="Input"/>.</summary>
public enum MouseButton
{
    Left = 0,
    Right = 1,
    Middle = 2
}

/// <summary>
/// This machine's keyboard and mouse, for menus, cameras and other local
/// presentation (OnLocalUpdate, LateUpdate, OnGUI). Networked gameplay in
/// Update(TickInput, ...) must read its <see cref="TickInput"/> instead, so
/// that the server and prediction see the same controls.
/// </summary>
public static partial class Input
{
    /// <summary>Whether the key is down.</summary>
    public static bool GetKey(KeyCode key) => KeyHeld((int)key);
    /// <summary>True only on the frame the key went down.</summary>
    public static bool GetKeyDown(KeyCode key) => KeyPressed((int)key);
    /// <summary>True only on the frame the key came up.</summary>
    public static bool GetKeyUp(KeyCode key) => KeyReleased((int)key);

    public static bool GetMouseButton(MouseButton button) => MouseHeld((int)button);
    public static bool GetMouseButtonDown(MouseButton button) => MousePressed((int)button);
    public static bool GetMouseButtonUp(MouseButton button) => MouseReleased((int)button);

    /// <summary>Pointer position in window points.</summary>
    public static Vector2 MousePosition => GetMousePosition();
    /// <summary>Pointer movement since the previous frame.</summary>
    public static Vector2 MouseDelta => GetMouseDelta();
    /// <summary>Wheel movement this frame.</summary>
    public static float MouseWheel => GetMouseWheel();
    /// <summary>Whether the player last used a gamepad rather than keyboard and mouse.</summary>
    public static bool UsingGamepad => IsUsingGamepad();
}
