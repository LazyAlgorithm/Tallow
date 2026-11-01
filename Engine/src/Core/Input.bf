using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Key identifiers. Values are SDL scancodes (USB HID usage ids), so they are layout independent.
enum KeyCode : int32
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

/// Polled input. In the editor, game input is only delivered while the Game view has focus.
static class Input
{
	const int KeyCount = 512;
	static bool[KeyCount] sKeys;
	static bool[KeyCount] sPrevKeys;
	static uint32 sButtons;
	static uint32 sPrevButtons;
	static Vector2 sMousePosition;
	static Vector2 sMouseDelta;
	static float sWheel;
	static float sPendingWheel;

	/// When false every query reports "not pressed".
	public static bool Enabled = true;

	static bool sLockWanted;
	static bool sLocked;

	/// Keeps the mouse inside the window and hides the pointer, for games that steer with the mouse (first-person
	/// views, flying cameras). While it is locked MouseDelta keeps reporting movement however far the mouse travels
	/// and MousePosition stays where it was. Set it true while the mouse controls the view and false whenever the
	/// player needs the pointer back, for example while a menu is open:
	///
	///   Input.LockCursor = !menuOpen;
	///
	/// It is released by itself when play stops. In the editor it only takes hold while the Game view is being
	/// played in and the toolbar's Lock Mouse button is on; Escape gives the pointer back there.
	public static bool LockCursor
	{
		get => sLockWanted;
		set
		{
			sLockWanted = value;
		}
	}

	/// True while the mouse really is locked to the window: asked for, and allowed.
	public static bool CursorLocked => sLocked;

	/// Set false to hold the lock off without the game having to know. The editor uses this so that a game can
	/// only take the mouse while its view is being played in.
	public static bool LockAllowed = true;

	/// True for a window event that the interface layer (menus, editor panels) should not be given because the
	/// mouse is locked to the game: movement, presses, the wheel and typing. Without this the hidden pointer would
	/// still hover over and click whatever lies under it. Releases always go through, so nothing is left held.
	public static bool HiddenFromInterface(uint32 eventType)
	{
		if (!sLocked)
			return false;
		switch (eventType)
		{
		case 0x300,0x303: return true; // key down, text input
		case 0x400,0x401,0x403: return true; // mouse motion, button down, wheel
		default: return false;
		}
	}

	static void ApplyLock()
	{
		let window = Application.Instance != null ? Application.Instance.Window : null;
		let want = sLockWanted && LockAllowed && window != null;
		if (want == sLocked)
			return;
		sLocked = want;
		if (window != null)
		{
			// Relative mode hides the pointer and reports movement without end; the grab keeps it from
			// reaching anything outside the window on desktops where relative mode alone does not.
			SDL.SDL_SetWindowRelativeMouseMode(window, want);
			SDL.SDL_SetWindowMouseGrab(window, want);
		}
		// Throw away the jump the switch itself produces, so the view does not lurch.
		float x = 0, y = 0;
		SDL.SDL_GetRelativeMouseState(&x, &y);
	}

	/// Where the mouse is in the window, in pixels from its top left.
	public static Vector2 MousePosition => sMousePosition;
	/// How far the mouse moved this frame, in pixels (also while the cursor is locked).
	public static Vector2 MouseDelta => Enabled ? sMouseDelta : .(0, 0);
	/// How far the wheel turned this frame: positive away from you.
	public static float MouseWheel => Enabled ? sWheel : 0;

	/// Whether a key is held.
	public static bool GetKey(KeyCode key) => Enabled && sKeys[(int)key];
	/// Whether a key went down this frame.
	public static bool GetKeyDown(KeyCode key) => Enabled && sKeys[(int)key] && !sPrevKeys[(int)key];
	/// Whether a key came up this frame.
	public static bool GetKeyUp(KeyCode key) => Enabled && !sKeys[(int)key] && sPrevKeys[(int)key];

	/// button: 0 left, 1 right, 2 middle.
	public static bool GetMouseButton(int button) => Enabled && (sButtons & ButtonMask(button)) != 0;
	/// Whether a mouse button (0 left, 1 right, 2 middle) went down this frame.
	public static bool GetMouseButtonDown(int button) => Enabled && (sButtons & ButtonMask(button)) != 0 && (sPrevButtons & ButtonMask(button)) == 0;
	/// Whether a mouse button came up this frame.
	public static bool GetMouseButtonUp(int button) => Enabled && (sButtons & ButtonMask(button)) == 0 && (sPrevButtons & ButtonMask(button)) != 0;

	/// "Horizontal" (A/D, arrows) and "Vertical" (W/S, arrows), each -1..1.
	public static float GetAxis(StringView name)
	{
		if (name == "Horizontal")
			return (GetKey(.D) || GetKey(.RightArrow) ? 1.0f : 0.0f) - (GetKey(.A) || GetKey(.LeftArrow) ? 1.0f : 0.0f);
		if (name == "Vertical")
			return (GetKey(.W) || GetKey(.UpArrow) ? 1.0f : 0.0f) - (GetKey(.S) || GetKey(.DownArrow) ? 1.0f : 0.0f);
		return 0;
	}

	// SDL: left = 1, middle = 2, right = 3; mask bit is (1 << (button - 1)).
	static uint32 ButtonMask(int button) => button == 0 ? 1 : (button == 1 ? 4 : 2);

	/// The application passes the wheel's movement in here as it happens.
	public static void OnWheel(float amount)
	{
		sPendingWheel += amount;
	}

	/// Called once per frame after events were pumped.
	public static void Poll()
	{
		ApplyLock();
		sPrevKeys = sKeys;
		sPrevButtons = sButtons;
		if (SimulateOnly)
		{
			// What the Simulate calls said stands; movement is for one frame, as from a real mouse.
			sMouseDelta = sPendingDelta;
			sPendingDelta = .(0, 0);
			sWheel = 0;
			sPendingWheel = 0;
		}
		else
		{
			int32 count = 0;
			let state = SDL.SDL_GetKeyboardState(&count);
			let n = Math.Min((int)count, KeyCount);
			for (int i < n)
				sKeys[i] = state[i];
			float x = 0, y = 0;
			sButtons = SDL.SDL_GetMouseState(&x, &y);
			sMousePosition = .(x, y);
			SDL.SDL_GetRelativeMouseState(&x, &y);
			sMouseDelta = .(x, y);
			sWheel = sPendingWheel;
			sPendingWheel = 0;
		}
		// A touch screen also moves the mouse and presses its button, for menus. While the on-screen controls are
		// up, fingers work those instead, so the pretend mouse must not also fire or turn the view.
		if (TouchControls.Active && (Touch.Touching || Time.RealTime - Touch.LastTouchTime < 0.5f))
		{
			sButtons = 0;
			sMouseDelta = .(0, 0);
		}
		Gamepad.Poll();
		NoteDevice();
		Touch.Update();
		InputActions.Update();
	}

	// ---- which device the player is using ----

	static bool sUsingGamepad;
	static bool sUsingTouch;

	/// True when the last thing the player used was the touch screen: the on-screen controls are showing.
	public static bool UsingTouch => sUsingTouch;

	/// True when the last thing the player touched was a controller, false when it was the keyboard or mouse. For
	/// showing the right button names, hiding the pointer, or helping a controller's aim.
	public static bool UsingGamepad => sUsingGamepad;

	static bool sTouchChecked;

	static void NoteDevice()
	{
		// A phone or tablet starts out with the touch controls; anything else with the keyboard and mouse.
		if (!sTouchChecked)
		{
			sTouchChecked = true;
			sUsingTouch = WebPlatform.IsTouchDevice;
		}
		// The mouse a touch screen pretends to be says nothing about a real mouse.
		let touchedLately = Touch.Touching || Time.RealTime - Touch.LastTouchTime < 0.5f;
		if (Touch.Touching)
		{
			sUsingTouch = true;
			sUsingGamepad = false;
		}
		else if (Gamepad.Active)
		{
			sUsingGamepad = true;
			sUsingTouch = false;
		}
		else if (!touchedLately && (sMouseDelta.LengthSquared > 4 || sButtons != 0 || sWheel != 0))
		{
			sUsingGamepad = false;
			sUsingTouch = false;
		}
		else
		{
			for (int i < KeyCount)
			{
				if (sKeys[i] && !sPrevKeys[i])
				{
					sUsingGamepad = false;
					sUsingTouch = false;
					break;
				}
			}
		}
	}

	/// True on the frame any key went down. key says which.
	public static bool AnyKeyDown(out KeyCode key)
	{
		key = .None;
		if (!Enabled)
			return false;
		for (int i < KeyCount)
		{
			if (sKeys[i] && !sPrevKeys[i])
			{
				key = (KeyCode)(int32)i;
				return true;
			}
		}
		return false;
	}

	// ---- pretending ----
	// For tests, replays and demos: say what the keyboard and mouse are doing. With no application running, call
	// SimulateStep at the start of each pretend frame; with one, the real devices are read over these every frame.

	/// In a running game: stop reading the real keyboard and mouse, so that only the Simulate calls count. An
	/// automated run of a game is then not disturbed by whoever is at the machine. Controllers are covered by
	/// Gamepad.Simulate.
	public static bool SimulateOnly;
	static Vector2 sPendingDelta;

	/// For automated runs: moves to the next frame of simulated input (see SimulateOnly).
	public static void SimulateStep(float deltaTime = 1.0f / 60)
	{
		sPrevKeys = sKeys;
		sPrevButtons = sButtons;
		sMouseDelta = .(0, 0);
		sWheel = 0;
		Gamepad.SimulateStep(deltaTime);
	}

	/// Call after the Simulate calls of a pretend frame, so that actions and the device in use catch up.
	public static void SimulateEnd()
	{
		Gamepad.SimulateEnd();
		NoteDevice();
		InputActions.Update();
	}

	/// For automated runs: holds or lets go of a key.
	public static void SimulateKey(KeyCode key, bool down) => sKeys[(int)key] = down;
	/// For automated runs: holds or lets go of a mouse button.
	public static void SimulateMouseButton(int button, bool down) => sButtons = down ? (sButtons | ButtonMask(button)) : (sButtons & ~ButtonMask(button));
	/// For automated runs: moves the mouse by an amount this frame.
	public static void SimulateMouseDelta(Vector2 delta)
	{
		sMouseDelta = delta;
		sPendingDelta = delta;
	}

	/// For automated runs: turns the wheel this frame.
	public static void SimulateMouseWheel(float amount) => sWheel = amount;
}
