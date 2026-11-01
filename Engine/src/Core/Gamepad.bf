using System;
using System.Collections;

namespace Tallow;

/// A controller's buttons, named by where they sit so that the same code works for every make: South is A on an
/// Xbox pad, Cross on a PlayStation pad and B on a Nintendo one.
enum GamepadButton : int32
{
	South, East, West, North,
	Back, Guide, Start,
	LeftStick, RightStick,
	LeftShoulder, RightShoulder,
	DpadUp, DpadDown, DpadLeft, DpadRight,
	/// The triggers, counted as pressed when pulled past half way.
	LeftTrigger, RightTrigger,
	Count
}

/// Whose controller it is, for showing the names printed on its buttons.
enum GamepadKind : int32
{
	Generic, Xbox, PlayStation, Nintendo
}

/// A controller's sticks and triggers.
enum GamepadAxis : int32
{
	LeftX, LeftY, RightX, RightY, LeftTrigger, RightTrigger,
	Count
}

/// Game controllers. Any controller SDL knows (Xbox, PlayStation, Switch, Steam Deck and most others) works, is
/// noticed when it is plugged in, and needs no set-up.
///
///   if (Gamepad.GetButtonDown(.South)) Jump();
///   let move = Gamepad.LeftStick;          // x right, y up, each -1 to 1, with the dead zone taken out
///   Gamepad.Rumble(0.4f, 0.8f, 0.2f);
///
/// Every call takes the controller's number as a last argument (0 is the first one found). For controls a player
/// can use from either a controller or the keyboard, see InputActions.
static class Gamepad
{
	/// The most controllers read at once.
	public const int MaxPads = 4;

	struct Pad
	{
		public void* handle;
		public uint32 id;
		public bool connected;
		/// Under the program's control (Simulate): the real controller in this place, if any, is not read.
		public bool simulated;
		public GamepadKind kind;
		public bool[(int)GamepadButton.Count] buttons, previous;
		public float[(int)GamepadAxis.Count] axes;
	}

	static Pad[MaxPads] sPads;
	static String[MaxPads] sNames = .(new .(), new .(), new .(), new .()) ~ { for (let name in _) delete name; };
	static int32 sScanIn;
	static bool sSimulated;
	// Menus: which way was pushed this frame, with a repeat while it is held.
	static int32 sNavDirection = -1, sNavHeld = -1;
	static float sNavTimer;

	/// How far a stick has to move before it counts, as a fraction of its travel. Worn sticks do not rest at zero.
	public static float StickDeadZone = 0.18f;
	/// Trigger pressure below this counts as not pressed.
	public static float TriggerDeadZone = 0.06f;

	/// How many controllers are connected.
	public static int Count
	{
		get
		{
			int count = 0;
			for (let pad in sPads)
			{
				if (pad.connected)
					count++;
			}
			return count;
		}
	}

	/// Whether a controller is connected.
	public static bool IsConnected(int pad = 0) => pad >= 0 && pad < MaxPads && sPads[pad].connected;
	/// What the controller calls itself, for example "Xbox Series X Controller". Empty if there is none.
	public static StringView Name(int pad = 0) => IsConnected(pad) ? (StringView)sNames[pad] : "";

	/// Xbox, PlayStation (DualShock and DualSense), Nintendo, or anything else.
	public static GamepadKind Kind(int pad = 0) => IsConnected(pad) ? sPads[pad].kind : .Generic;

	/// What is printed on a button of this kind of controller: South is "A" on an Xbox pad, "Cross" on a
	/// PlayStation one and "B" on a Nintendo one.
	public static void ButtonName(GamepadButton button, GamepadKind kind, String name)
	{
		switch (button)
		{
		case .South: name.Append(kind == .PlayStation ? "Cross" : (kind == .Nintendo ? "B" : "A"));
		case .East: name.Append(kind == .PlayStation ? "Circle" : (kind == .Nintendo ? "A" : "B"));
		case .West: name.Append(kind == .PlayStation ? "Square" : (kind == .Nintendo ? "Y" : "X"));
		case .North: name.Append(kind == .PlayStation ? "Triangle" : (kind == .Nintendo ? "X" : "Y"));
		case .Back: name.Append(kind == .PlayStation ? "Share" : (kind == .Nintendo ? "Minus" : "View"));
		case .Guide: name.Append(kind == .PlayStation ? "PS" : "Home");
		case .Start: name.Append(kind == .PlayStation ? "Options" : (kind == .Nintendo ? "Plus" : "Menu"));
		case .LeftStick: name.Append(kind == .PlayStation ? "L3" : "Left Stick");
		case .RightStick: name.Append(kind == .PlayStation ? "R3" : "Right Stick");
		case .LeftShoulder: name.Append(kind == .PlayStation ? "L1" : (kind == .Nintendo ? "L" : "LB"));
		case .RightShoulder: name.Append(kind == .PlayStation ? "R1" : (kind == .Nintendo ? "R" : "RB"));
		case .DpadUp: name.Append("D-pad Up");
		case .DpadDown: name.Append("D-pad Down");
		case .DpadLeft: name.Append("D-pad Left");
		case .DpadRight: name.Append("D-pad Right");
		case .LeftTrigger: name.Append(kind == .PlayStation ? "L2" : (kind == .Nintendo ? "ZL" : "LT"));
		case .RightTrigger: name.Append(kind == .PlayStation ? "R2" : (kind == .Nintendo ? "ZR" : "RT"));
		default:
		}
	}

	/// Pretend controllers can be given a kind, to see the other makes' button names.
	public static void SimulateKind(GamepadKind kind, int pad = 0) => sPads[pad].kind = kind;

	/// Whether a controller button is held.
	public static bool GetButton(GamepadButton button, int pad = 0) => Input.Enabled && IsConnected(pad) && sPads[pad].buttons[(int)button];
	/// True only on the frame the button went down.
	public static bool GetButtonDown(GamepadButton button, int pad = 0) => Input.Enabled && IsConnected(pad) && sPads[pad].buttons[(int)button] && !sPads[pad].previous[(int)button];
	/// Whether a controller button came up this frame.
	public static bool GetButtonUp(GamepadButton button, int pad = 0) => Input.Enabled && IsConnected(pad) && !sPads[pad].buttons[(int)button] && sPads[pad].previous[(int)button];

	/// One axis as the controller reports it: sticks -1 to 1 (down and right are positive), triggers 0 to 1. No dead
	/// zone is applied; LeftStick, RightStick and the trigger properties do that.
	public static float GetAxis(GamepadAxis axis, int pad = 0) => Input.Enabled && IsConnected(pad) ? sPads[pad].axes[(int)axis] : 0;

	static Vector2 Stick(int pad, GamepadAxis x, GamepadAxis y)
	{
		if (!Input.Enabled || !IsConnected(pad))
			return .(0, 0);
		// Up is positive, as on a graph. The dead zone is a circle, and what is outside it is stretched to start at
		// zero so that small movements are not lost.
		let raw = Vector2(sPads[pad].axes[(int)x], -sPads[pad].axes[(int)y]);
		let length = raw.Length;
		if (length <= StickDeadZone)
			return .(0, 0);
		let scaled = Math.Min((length - StickDeadZone) / (1 - StickDeadZone), 1);
		return raw / length * scaled;
	}

	/// The left stick: x is right, y is up, and the length is at most 1.
	public static Vector2 LeftStick => Stick(0, .LeftX, .LeftY);
	/// The first controller's right stick, -1 to 1 on each axis.
	public static Vector2 RightStick => Stick(0, .RightX, .RightY);
	/// A controller's left stick.
	public static Vector2 GetLeftStick(int pad) => Stick(pad, .LeftX, .LeftY);
	/// A controller's right stick.
	public static Vector2 GetRightStick(int pad) => Stick(pad, .RightX, .RightY);

	static float Trigger(int pad, GamepadAxis axis)
	{
		let value = GetAxis(axis, pad);
		return value <= TriggerDeadZone ? 0 : (value - TriggerDeadZone) / (1 - TriggerDeadZone);
	}

	/// How far a trigger is pulled, 0 to 1.
	public static float LeftTrigger => Trigger(0, .LeftTrigger);
	/// How far the first controller's right trigger is pulled, 0 to 1.
	public static float RightTrigger => Trigger(0, .RightTrigger);
	/// How far a controller's left trigger is pulled, 0 to 1.
	public static float GetLeftTrigger(int pad) => Trigger(pad, .LeftTrigger);
	/// How far a controller's right trigger is pulled, 0 to 1.
	public static float GetRightTrigger(int pad) => Trigger(pad, .RightTrigger);

	/// The d-pad as a direction: x right, y up.
	public static Vector2 Dpad => .((GetButton(.DpadRight) ? 1 : 0) - (GetButton(.DpadLeft) ? 1 : 0), (GetButton(.DpadUp) ? 1 : 0) - (GetButton(.DpadDown) ? 1 : 0));

	/// True on the frame any button of any controller went down. button says which.
	public static bool AnyButtonDown(out GamepadButton button)
	{
		button = .South;
		if (!Input.Enabled)
			return false;
		for (int p < MaxPads)
		{
			if (!sPads[p].connected)
				continue;
			for (int b < (int)GamepadButton.Count)
			{
				if (sPads[p].buttons[b] && !sPads[p].previous[b])
				{
					button = (GamepadButton)b;
					return true;
				}
			}
		}
		return false;
	}

	/// Shakes the controller: the heavy (low) and light (high) motors from 0 to 1, for a number of seconds.
	/// Does nothing on a controller that cannot.
	public static void Rumble(float low, float high, float seconds, int pad = 0)
	{
		if (!IsConnected(pad) || sPads[pad].handle == null || sPads[pad].simulated || !RumbleEnabled)
			return;
		SDL.SDL_RumbleGamepad(sPads[pad].handle, (uint16)(Mathf.Clamp01(low) * 65535), (uint16)(Mathf.Clamp01(high) * 65535), (uint32)(Math.Max(seconds, 0) * 1000));
	}

	/// A player's choice: false turns every Rumble call into nothing.
	public static bool RumbleEnabled = true;

	/// For menus: the direction pushed this frame on the d-pad or left stick (0 up, 1 right, 2 down, 3 left), or -1.
	/// Holding a direction repeats it, as holding an arrow key does.
	public static int NavDirection => Input.Enabled ? sNavDirection : -1;

	// ---- pretending ----

	/// Makes controller `pad` appear connected and under the program's control, for tests, replays and demos: the
	/// Simulate calls then say what it is doing. A real controller in that place is ignored until StopSimulating.
	public static void Simulate(int pad = 0)
	{
		sSimulated = true;
		if (!sPads[pad].simulated)
		{
			// Start from rest, whatever a real controller here was doing.
			sPads[pad].buttons = default;
			sPads[pad].axes = default;
		}
		sPads[pad].simulated = true;
		sPads[pad].connected = true;
		sNames[pad].Set("Simulated controller");
	}

	/// For automated runs: holds or lets go of a button on a pretend controller.
	public static void SimulateButton(GamepadButton button, bool down, int pad = 0)
	{
		sPads[pad].buttons[(int)button] = down;
		if (button == .LeftTrigger || button == .RightTrigger)
			sPads[pad].axes[(int)(button == .LeftTrigger ? GamepadAxis.LeftTrigger : GamepadAxis.RightTrigger)] = down ? 1 : 0;
	}

	/// Sticks: x right, y up, as LeftStick reports them.
	public static void SimulateStick(bool right, Vector2 value, int pad = 0)
	{
		sPads[pad].axes[(int)(right ? GamepadAxis.RightX : GamepadAxis.LeftX)] = value.x;
		sPads[pad].axes[(int)(right ? GamepadAxis.RightY : GamepadAxis.LeftY)] = -value.y;
	}

	/// For automated runs: moves a stick or trigger of a pretend controller.
	public static void SimulateAxis(GamepadAxis axis, float value, int pad = 0)
	{
		sPads[pad].axes[(int)axis] = value;
		if (axis == .LeftTrigger || axis == .RightTrigger)
			sPads[pad].buttons[(int)(axis == .LeftTrigger ? GamepadButton.LeftTrigger : GamepadButton.RightTrigger)] = value > 0.5f;
	}

	/// For automated runs: goes back to reading real controllers.
	public static void StopSimulating()
	{
		sSimulated = false;
		for (var pad in ref sPads)
		{
			if (pad.handle == null)
				pad = default;
			else if (pad.simulated)
			{
				// The real controller that was being stood in for takes over again.
				pad.simulated = false;
				pad.buttons = default;
				pad.axes = default;
			}
		}
		Rescan();
	}

	/// Whether anything on a controller is being pressed or pushed right now.
	public static bool Active
	{
		get
		{
			for (int p < MaxPads)
			{
				if (!sPads[p].connected)
					continue;
				for (let down in sPads[p].buttons)
				{
					if (down)
						return true;
				}
				if (Stick(p, .LeftX, .LeftY).LengthSquared > 0.09f || Stick(p, .RightX, .RightY).LengthSquared > 0.09f)
					return true;
			}
			return false;
		}
	}

	// ---- the engine's side ----

	static void Scan()
	{
		int32 count = 0;
		let ids = SDL.SDL_GetGamepads(&count);
		// Gone ones first, so that their places are free.
		for (var pad in ref sPads)
		{
			if (pad.handle == null)
				continue;
			bool present = false;
			for (int32 i < count)
				present |= ids != null && ids[i] == pad.id;
			if (!present || !SDL.SDL_GamepadConnected(pad.handle))
			{
				SDL.SDL_CloseGamepad(pad.handle);
				Log.Info("Controller disconnected.");
				pad = default;
			}
		}
		for (int32 i < count)
		{
			if (ids == null)
				break;
			bool known = false;
			for (let pad in sPads)
				known |= pad.handle != null && pad.id == ids[i];
			if (known)
				continue;
			for (int p < MaxPads)
			{
				if (sPads[p].handle != null || (sSimulated && sPads[p].connected))
					continue;
				let handle = SDL.SDL_OpenGamepad(ids[i]);
				if (handle == null)
					break;
				sPads[p] = default;
				sPads[p].handle = handle;
				sPads[p].id = ids[i];
				sPads[p].connected = true;
				let type = SDL.SDL_GetGamepadType(handle);
				sPads[p].kind = (type == 2 || type == 3) ? .Xbox : ((type >= 4 && type <= 6) ? .PlayStation : ((type >= 7 && type <= 10) ? .Nintendo : .Generic));
				sNames[p].Clear();
				let name = SDL.SDL_GetGamepadName(handle);
				if (name != null)
					sNames[p].Append(name);
				Log.Info(scope $"Controller connected: {sNames[p]}");
				break;
			}
		}
		if (ids != null)
			SDL.SDL_free(ids);
	}

	/// Asks for the controllers to be looked for again at the next Poll (one was plugged in or pulled out).
	public static void Rescan() => sScanIn = 0;

	/// Called once a frame by the application, after events were pumped.
	public static void Poll()
	{
		if (--sScanIn <= 0)
		{
			sScanIn = 120;
			Scan();
		}
		for (var pad in ref sPads)
		{
			pad.previous = pad.buttons;
			if (pad.handle == null || pad.simulated)
				continue;
			for (int32 b < 15)
				pad.buttons[b] = SDL.SDL_GetGamepadButton(pad.handle, b);
			for (int32 a < (int32)GamepadAxis.Count)
				pad.axes[a] = Math.Max(SDL.SDL_GetGamepadAxis(pad.handle, a) / 32767.0f, -1);
			pad.buttons[(int)GamepadButton.LeftTrigger] = pad.axes[(int)GamepadAxis.LeftTrigger] > 0.5f;
			pad.buttons[(int)GamepadButton.RightTrigger] = pad.axes[(int)GamepadAxis.RightTrigger] > 0.5f;
		}
		UpdateNavigation(Time.UnscaledDeltaTime);
	}

	/// A simulated frame: what was down becomes what was down before. Call it before the Simulate calls of a frame
	/// when no application is running (tests).
	public static void SimulateStep(float deltaTime = 1.0f / 60)
	{
		for (var pad in ref sPads)
			pad.previous = pad.buttons;
		sStepTime = deltaTime;
	}

	static float sStepTime;

	/// The end of a simulated frame, once the Simulate calls have said what the controller is doing.
	public static void SimulateEnd() => UpdateNavigation(sStepTime);

	static void UpdateNavigation(float deltaTime)
	{
		// The d-pad, or the left stick pushed most of the way, of any controller.
		int32 direction = -1;
		for (int p < MaxPads)
		{
			if (!sPads[p].connected)
				continue;
			let stick = Stick(p, .LeftX, .LeftY);
			if (sPads[p].buttons[(int)GamepadButton.DpadUp] || stick.y > 0.6f)
				direction = 0;
			else if (sPads[p].buttons[(int)GamepadButton.DpadRight] || stick.x > 0.6f)
				direction = 1;
			else if (sPads[p].buttons[(int)GamepadButton.DpadDown] || stick.y < -0.6f)
				direction = 2;
			else if (sPads[p].buttons[(int)GamepadButton.DpadLeft] || stick.x < -0.6f)
				direction = 3;
			if (direction >= 0)
				break;
		}
		sNavDirection = -1;
		if (direction != sNavHeld)
		{
			sNavHeld = direction;
			sNavDirection = direction;
			sNavTimer = 0.4f;
		}
		else if (direction >= 0)
		{
			sNavTimer -= deltaTime;
			if (sNavTimer <= 0)
			{
				sNavDirection = direction;
				sNavTimer = 0.12f;
			}
		}
	}

	/// Closes every controller.
	public static void Shutdown()
	{
		for (var pad in ref sPads)
		{
			if (pad.handle != null)
				SDL.SDL_CloseGamepad(pad.handle);
			pad = default;
		}
	}
}
