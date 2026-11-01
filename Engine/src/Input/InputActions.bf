using System;
using System.Collections;

namespace Tallow;

/// What an action gives: a button (down or not), an axis (-1 to 1) or a direction (two axes).
enum InputActionKind : int32
{
	Button, Axis, Vector
}

/// What a binding reads.
enum InputBindingKind : int32
{
	/// A key.
	Key,
	/// A mouse button: 0 left, 1 right, 2 middle.
	MouseButton,
	/// The mouse wheel, one way: +1 up, -1 down.
	MouseWheel,
	/// Mouse movement (directions only).
	MouseDelta,
	/// A controller button, or a trigger used as one.
	PadButton,
	/// One controller axis: a stick's left-right or up-down, or a trigger.
	PadAxis,
	/// A controller stick (directions only): 0 left, 1 right.
	PadStick,
	/// The controller's d-pad as a direction.
	PadDpad,
	/// Two keys as an axis: the first is -1, the second +1.
	KeyAxis,
	/// Four keys as a direction: up, down, left, right.
	Keys,
	/// An on-screen control on a touch screen (see TouchControls): a button's press, a stick's direction or a look
	/// area's movement. Which one is index (TouchControls.NameId).
	Touch
}

/// One way of working an action: a key, a button, a stick... An action can have any number.
struct InputBinding
{
	/// What kind of input this binding reads.
	public InputBindingKind kind;
	/// Keys: up or the only key, then down, left, right. KeyAxis: negative, positive.
	public KeyCode key, key2, key3, key4;
	/// Mouse button number, wheel direction, or which stick.
	public int32 index;
	/// The controller button (PadButton).
	public GamepadButton button;
	/// The controller axis (PadAxis).
	public GamepadAxis axis;
	/// Multiplies what the binding gives. For InputActions.Delta it is how fast a stick or keys turn: units a second.
	public float scale = 1;
	/// Flips the binding: an axis the other way round, a direction's up and down.
	public bool invert;

	/// Whether this reads a controller.
	public bool IsGamepad => kind == .PadButton || kind == .PadAxis || kind == .PadStick || kind == .PadDpad;

	/// A binding to a key.
	public static InputBinding Key(KeyCode key) => .() { kind = .Key, key = key };
	/// A binding to a mouse button: 0 left, 1 right, 2 middle.
	public static InputBinding Mouse(int32 button) => .() { kind = .MouseButton, index = button };
	/// A binding to a controller button.
	public static InputBinding Pad(GamepadButton button) => .() { kind = .PadButton, button = button };
	/// A binding to a controller stick (the left, or the right).
	public static InputBinding Stick(bool right, float scale = 1) => .() { kind = .PadStick, index = right ? 1 : 0, scale = scale };
	/// W, S, A and D as a direction.
	public static InputBinding WASD => .() { kind = .Keys, key = .W, key2 = .S, key3 = .A, key4 = .D };
	/// A binding to an on-screen control made with TouchControls.
	public static InputBinding TouchControl(StringView name) => .() { kind = .Touch, index = TouchControls.NameId(name) };
}

/// Something the player can do ("Jump", "Move", "Fire"), whatever they do it with.
class InputAction
{
	/// The action's name, as scripts ask for it.
	public String name = new .() ~ delete _;
	/// Whether it gives a button, an axis or a direction.
	public InputActionKind kind;
	/// Every way of working it.
	public List<InputBinding> bindings = new .() ~ delete _;

	// This frame.
	/// How far it is pushed now (0 to 1, -1 to 1 for an axis), and last frame.
	public float value, previous;
	/// A direction action's direction now, and its movement this frame (for looking around).
	public Vector2 vector, delta;
	/// The binding that is doing the most this frame is on a controller.
	public bool fromGamepad;

	/// Whether a button action is held.
	public bool Held => value > 0.5f;
	/// Whether a button action went down this frame.
	public bool Pressed => value > 0.5f && previous <= 0.5f;
	/// Whether a button action came up this frame.
	public bool Released => value <= 0.5f && previous > 0.5f;
}

/// A named group of actions that is switched on and off together: "Player", "Vehicle", "Menu".
class InputMap
{
	/// The map's name.
	public String name = new .() ~ delete _;
	/// Whether its actions are read (see InputActions.SetMapEnabled).
	public bool enabled = true;
	/// The map's actions.
	public List<InputAction> actions = new .() ~ DeleteContainerAndItems!(_);

	/// An action by name, or null.
	public InputAction Find(StringView actionName)
	{
		for (let action in actions)
		{
			if (action.name == actionName)
				return action;
		}
		return null;
	}
}

/// Input actions: the game asks for what the player means ("Jump"), and a list kept in the project says which keys,
/// mouse buttons and controller buttons mean it. One piece of game code then works from keyboard and mouse and
/// from any controller, and the controls are changed without touching code.
///
///   if (InputActions.Pressed("Jump")) ...
///   let move = InputActions.Vector("Move");      // x right, y forward/up; length at most 1
///   let look = InputActions.Delta("Look");       // how far to turn this frame: mouse movement, or a stick over time
///   let gas = InputActions.Value("Throttle");    // 0 to 1, or -1 to 1 for an axis
///
/// The list is the project's `Input.tinput` file, edited in the editor under Window > Input Actions. A project
/// without one has the engine's standard actions (Move, Look, Jump, Sprint, Crouch, Fire, Use, Reload, Ability1,
/// Ability2, Submit, Cancel), and those stay available under their names in a project that does not define them.
///
/// Directions use one convention everywhere: x is right and y is up (or forward), also for mouse movement.
static class InputActions
{
	/// The project's input file, in its assets.
	public const String FileName = "Input.tinput";

	static List<InputMap> sMaps = new .() ~ DeleteContainerAndItems!(_);
	static List<InputMap> sStandard = new .() ~ DeleteContainerAndItems!(_);
	static Dictionary<String, InputAction> sLookup = new .() ~ DeleteDictionaryAndKeys!(_);
	static bool sLoaded;
	static bool sStale = true;

	/// The engine's own actions, as text in the format of Input.tinput. New projects start from this.
	public const String StandardText = """
		map Player
		action Move vector
		bind keys W S A D
		bind keys UpArrow DownArrow LeftArrow RightArrow
		bind stick left
		action Look vector
		bind mousedelta
		bind stick right scale 1400
		action Jump button
		bind key Space
		bind pad South
		action Sprint button
		bind key LeftShift
		bind pad LeftStick
		action Crouch button
		bind key LeftControl
		bind pad East
		action Fire button
		bind mouse 0
		bind pad RightTrigger
		action Use button
		bind key E
		bind pad North
		action Reload button
		bind key R
		bind pad West
		action Ability1 button
		bind key Q
		bind pad LeftShoulder
		action Ability2 button
		bind key F
		bind pad RightShoulder
		action Talk button
		bind key V
		bind pad DpadDown
		map Menu
		action Submit button
		bind key Return
		bind pad South
		action Cancel button
		bind key Escape
		bind pad East

		""";

	/// The project's maps, for the editor and for games that list the controls. Changing them calls for Changed().
	public static List<InputMap> Maps
	{
		get
		{
			EnsureLoaded();
			return sMaps;
		}
	}

	/// After adding, removing or renaming actions through Maps.
	public static void Changed() => sStale = true;

	static String sLoadedFor = new .() ~ delete _;

	static void EnsureLoaded()
	{
		// A project opened after the first look: its file has not been read yet.
		if (sLoaded && sLoadedFor != Assets.ProjectPath)
		{
			ClearAndDeleteItems!(sMaps);
			ClearAndDeleteItems!(sStandard);
			sLoaded = false;
		}
		if (sLoaded)
			return;
		sLoaded = true;
		sLoadedFor.Set(Assets.ProjectPath);
		ParseInto(sStandard, StandardText);
		let text = scope String();
		if (!Assets.ProjectPath.IsEmpty && Assets.ReadText(FileName, text))
			ParseInto(sMaps, text);
		sStale = true;
	}

	/// Reads the project's Input.tinput again (the editor does after saving it).
	public static void Reload()
	{
		ClearAndDeleteItems!(sMaps);
		ClearAndDeleteItems!(sStandard);
		sLoaded = false;
		sStale = true;
		EnsureLoaded();
	}

	/// Replaces the project's actions with ones given as text, in the format of Input.tinput.
	public static void LoadText(StringView text)
	{
		EnsureLoaded();
		ClearAndDeleteItems!(sMaps);
		ParseInto(sMaps, text);
		sStale = true;
	}

	static bool ParseKey(StringView word, out KeyCode key)
	{
		key = .None;
		if (Enum.Parse<KeyCode>(word, true) case .Ok(let parsed))
		{
			key = parsed;
			return true;
		}
		return false;
	}

	/// A "bind <kind> <what> [scale N] [invert]" line, split into words.
	static bool ParseBinding(List<StringView> words, out InputBinding binding)
	{
		binding = .();
		bool ok = true;
		int used = 2;
		switch (words[1])
		{
		case "key":
			binding.kind = .Key;
			ok = words.Count > 2 && ParseKey(words[2], out binding.key);
			used = 3;
		case "mouse":
			binding.kind = .MouseButton;
			binding.index = words.Count > 2 ? Math.Clamp(SceneSerializer.ParseInt(words[2]), 0, 2) : 0;
			used = 3;
		case "wheel":
			binding.kind = .MouseWheel;
			binding.index = (words.Count > 2 && words[2] == "down") ? -1 : 1;
			used = 3;
		case "mousedelta":
			binding.kind = .MouseDelta;
		case "pad":
			binding.kind = .PadButton;
			ok = words.Count > 2 && Enum.Parse<GamepadButton>(words[2], true) case .Ok(out binding.button);
			used = 3;
		case "padaxis":
			binding.kind = .PadAxis;
			ok = words.Count > 2 && Enum.Parse<GamepadAxis>(words[2], true) case .Ok(out binding.axis);
			used = 3;
		case "stick":
			binding.kind = .PadStick;
			binding.index = (words.Count > 2 && words[2] == "right") ? 1 : 0;
			used = 3;
		case "dpad":
			binding.kind = .PadDpad;
		case "keyaxis":
			binding.kind = .KeyAxis;
			ok = words.Count > 3 && ParseKey(words[2], out binding.key) && ParseKey(words[3], out binding.key2);
			used = 4;
		case "touch":
			binding.kind = .Touch;
			ok = words.Count > 2;
			if (ok)
				binding.index = TouchControls.NameId(words[2]);
			used = 3;
		case "keys":
			binding.kind = .Keys;
			ok = words.Count > 5 && ParseKey(words[2], out binding.key) && ParseKey(words[3], out binding.key2) && ParseKey(words[4], out binding.key3) && ParseKey(words[5], out binding.key4);
			used = 6;
		default:
			ok = false;
		}
		if (!ok)
			return false;
		for (int i = used; i < words.Count; i++)
		{
			if (words[i] == "scale" && i + 1 < words.Count)
				binding.scale = SceneSerializer.ParseFloat(words[++i]);
			else if (words[i] == "invert")
				binding.invert = true;
		}
		return true;
	}

	static void ParseInto(List<InputMap> maps, StringView text)
	{
		InputMap map = null;
		InputAction action = null;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			List<StringView> words = scope .();
			for (let word in line.Split(' ', .RemoveEmptyEntries))
				words.Add(word);
			if (words[0] == "map" && words.Count > 1)
			{
				map = new InputMap();
				map.name.Set(words[1]);
				maps.Add(map);
				action = null;
			}
			else if (words[0] == "action" && words.Count > 1)
			{
				if (map == null)
				{
					map = new InputMap();
					map.name.Set("Player");
					maps.Add(map);
				}
				action = new InputAction();
				action.name.Set(words[1]);
				if (words.Count > 2)
					action.kind = words[2] == "vector" ? .Vector : (words[2] == "axis" ? .Axis : .Button);
				map.actions.Add(action);
			}
			else if (words[0] == "bind" && words.Count > 1 && action != null)
			{
				if (ParseBinding(words, let binding))
					action.bindings.Add(binding);
				else
					Log.Warning(scope $"Input actions: could not read \"{line}\".");
			}
		}
	}

	/// The project's actions as text: what is written to Input.tinput.
	public static void ToText(String text)
	{
		EnsureLoaded();
		for (let map in sMaps)
		{
			text.AppendF("map {}\n", map.name);
			for (let action in map.actions)
			{
				text.AppendF("action {} {}\n", action.name, action.kind == .Vector ? "vector" : (action.kind == .Axis ? "axis" : "button"));
				for (let binding in action.bindings)
				{
					text.Append("bind ");
					switch (binding.kind)
					{
					case .Key: text.AppendF("key {}", binding.key);
					case .MouseButton: text.AppendF("mouse {}", binding.index);
					case .MouseWheel: text.AppendF("wheel {}", binding.index < 0 ? "down" : "up");
					case .MouseDelta: text.Append("mousedelta");
					case .PadButton: text.AppendF("pad {}", binding.button);
					case .PadAxis: text.AppendF("padaxis {}", binding.axis);
					case .PadStick: text.AppendF("stick {}", binding.index == 1 ? "right" : "left");
					case .PadDpad: text.Append("dpad");
					case .KeyAxis: text.AppendF("keyaxis {} {}", binding.key, binding.key2);
					case .Keys: text.AppendF("keys {} {} {} {}", binding.key, binding.key2, binding.key3, binding.key4);
					case .Touch: text.AppendF("touch {}", TouchControls.NameOf(binding.index));
					}
					if (binding.scale != 1)
						text.AppendF(" scale {}", binding.scale);
					if (binding.invert)
						text.Append(" invert");
					text.Append('\n');
				}
			}
		}
	}

	static void Rebuild()
	{
		sStale = false;
		for (let key in sLookup.Keys)
			delete key;
		sLookup.Clear();
		// The project's own first; the engine's standard ones fill in whatever names are left.
		void Add(List<InputMap> maps)
		{
			for (let map in maps)
			{
				for (let action in map.actions)
				{
					if (!sLookup.ContainsKeyAlt<StringView>(action.name))
						sLookup[new String(action.name)] = action;
					let full = scope $"{map.name}/{action.name}";
					if (!sLookup.ContainsKeyAlt<StringView>(full))
						sLookup[new String(full)] = action;
				}
			}
		}
		Add(sMaps);
		Add(sStandard);
	}

	/// An action by name ("Jump"), or by map and name ("Vehicle/Brake") when two maps use the same name. Null if
	/// there is none.
	public static InputAction Find(StringView name)
	{
		EnsureLoaded();
		if (sStale)
			Rebuild();
		if (sLookup.TryGetValueAlt(name, let action))
			return action;
		return null;
	}

	static InputMap MapOf(InputAction action)
	{
		for (let map in sMaps)
		{
			if (map.actions.Contains(action))
				return map;
		}
		return null;
	}

	static InputAction Live(StringView name)
	{
		if (!Input.Enabled)
			return null;
		return Find(name);
	}

	/// The action is down: its key or button is held, or its trigger is past half way.
	public static bool Held(StringView name) => Live(name)?.Held ?? false;
	/// True only on the frame the action went down.
	public static bool Pressed(StringView name) => Live(name)?.Pressed ?? false;
	/// Whether a button action came up this frame.
	public static bool Released(StringView name) => Live(name)?.Released ?? false;
	/// How far: 0 to 1 for a button (a trigger gives everything in between), -1 to 1 for an axis.
	public static float Value(StringView name) => Live(name)?.value ?? 0;
	/// A direction: x right, y up or forward, no longer than 1. Keys, sticks and the d-pad.
	public static Vector2 Vector(StringView name) => Live(name)?.vector ?? .(0, 0);
	/// How far to move or turn this frame: mouse movement as it comes, plus sticks and keys multiplied by their
	/// binding's scale and the time the frame took. Use it for looking around.
	public static Vector2 Delta(StringView name) => Live(name)?.delta ?? .(0, 0);
	/// Whether the action is being worked from a controller right now.
	public static bool FromGamepad(StringView name) => Live(name)?.fromGamepad ?? false;

	/// Switches a whole map on or off: a "Vehicle" map while driving, "Menu" while a menu is open. Actions of a map
	/// that is off read as untouched.
	public static void SetMapEnabled(StringView mapName, bool enabled)
	{
		EnsureLoaded();
		for (let map in sMaps)
		{
			if (map.name == mapName)
				map.enabled = enabled;
		}
	}

	/// Whether a map's actions are read.
	public static bool IsMapEnabled(StringView mapName)
	{
		EnsureLoaded();
		for (let map in sMaps)
		{
			if (map.name == mapName)
				return map.enabled;
		}
		return false;
	}

	// ---- telling the player ----

	/// A key's name, as a player would know it.
	public static void KeyName(KeyCode key, String name)
	{
		switch (key)
		{
		case .Alpha0,.Alpha1,.Alpha2,.Alpha3,.Alpha4,.Alpha5,.Alpha6,.Alpha7,.Alpha8,.Alpha9:
			name.AppendF("{}", key == .Alpha0 ? 0 : (int32)key - (int32)KeyCode.Alpha1 + 1);
		case .LeftControl,.RightControl: name.Append("Ctrl");
		case .LeftShift,.RightShift: name.Append("Shift");
		case .LeftAlt,.RightAlt: name.Append("Alt");
		case .UpArrow: name.Append("Up");
		case .DownArrow: name.Append("Down");
		case .LeftArrow: name.Append("Left");
		case .RightArrow: name.Append("Right");
		case .Return: name.Append("Enter");
		case .Escape: name.Append("Esc");
		default: name.AppendF("{}", key);
		}
	}

	/// A binding in words a player would use: "Space", "Left Mouse", "A" (or "Cross" on a PlayStation controller).
	public static void BindingName(InputBinding binding, String name)
	{
		let kind = Gamepad.Kind();
		switch (binding.kind)
		{
		case .Key: KeyName(binding.key, name);
		case .MouseButton: name.Append(binding.index == 0 ? "Left Mouse" : (binding.index == 1 ? "Right Mouse" : "Middle Mouse"));
		case .MouseWheel: name.Append(binding.index < 0 ? "Wheel Down" : "Wheel Up");
		case .MouseDelta: name.Append("Mouse");
		case .PadButton: Gamepad.ButtonName(binding.button, kind, name);
		case .PadAxis:
			switch (binding.axis)
			{
			case .LeftTrigger: Gamepad.ButtonName(.LeftTrigger, kind, name);
			case .RightTrigger: Gamepad.ButtonName(.RightTrigger, kind, name);
			case .LeftX,.LeftY: name.Append("Left Stick");
			default: name.Append("Right Stick");
			}
		case .PadStick: name.Append(binding.index == 1 ? "Right Stick" : "Left Stick");
		case .PadDpad: name.Append("D-pad");
		case .KeyAxis:
			KeyName(binding.key, name);
			name.Append(" / ");
			KeyName(binding.key2, name);
		case .Keys:
			KeyName(binding.key, name);
			name.Append(' ');
			KeyName(binding.key3, name);
			name.Append(' ');
			KeyName(binding.key2, name);
			name.Append(' ');
			KeyName(binding.key4, name);
		case .Touch:
			let control = TouchControls.FindById(binding.index);
			if (control != null && !control.label.IsEmpty)
				name.Append(control.label);
			else
				name.Append(TouchControls.NameOf(binding.index));
		}
	}

	/// What to press for an action, for the device the player is using: "E" on the keyboard, "Y" on a controller.
	/// Empty if the action has no binding for that device.
	public static void Describe(StringView actionName, String text)
	{
		let action = Find(actionName);
		if (action == null)
			return;
		for (let binding in action.bindings)
		{
			if (binding.kind == .Touch ? Input.UsingTouch : (binding.IsGamepad == Input.UsingGamepad && !Input.UsingTouch))
			{
				BindingName(binding, text);
				return;
			}
		}
	}

	// ---- changing bindings while the game runs ----

	/// For a "press a key" prompt: true on the frame a key, mouse button or controller button goes down, with the
	/// binding it would make. Works while Input.Enabled is false, so that a menu can use it.
	public static bool Capture(out InputBinding binding)
	{
		binding = .();
		let enabled = Input.Enabled;
		Input.Enabled = true;
		defer
		{
			Input.Enabled = enabled;
		}
		if (Gamepad.AnyButtonDown(let button))
		{
			binding = .Pad(button);
			return true;
		}
		if (Input.AnyKeyDown(let key))
		{
			binding = .Key(key);
			return true;
		}
		for (int32 i < 3)
		{
			if (Input.GetMouseButtonDown(i))
			{
				binding = .Mouse(i);
				return true;
			}
		}
		return false;
	}

	/// Replaces one of an action's bindings (index counts from 0), or adds one when the index is past the end.
	/// False if there is no such action. Save the result with ToText.
	public static bool SetBinding(StringView actionName, int index, InputBinding binding)
	{
		let action = Find(actionName);
		if (action == null || index < 0)
			return false;
		if (index < action.bindings.Count)
			action.bindings[index] = binding;
		else
			action.bindings.Add(binding);
		return true;
	}

	// ---- every frame ----

	static float ButtonValue(InputBinding binding)
	{
		switch (binding.kind)
		{
		case .Key: return Input.GetKey(binding.key) ? 1 : 0;
		case .MouseButton: return Input.GetMouseButton(binding.index) ? 1 : 0;
		case .MouseWheel: return (Input.MouseWheel * binding.index > 0) ? 1 : 0;
		case .PadButton:
			if (binding.button == .LeftTrigger)
				return Gamepad.LeftTrigger;
			if (binding.button == .RightTrigger)
				return Gamepad.RightTrigger;
			return Gamepad.GetButton(binding.button) ? 1 : 0;
		case .PadAxis: return AxisValue(binding);
		case .KeyAxis: return (Input.GetKey(binding.key2) ? 1 : 0) - (Input.GetKey(binding.key) ? 1 : 0);
		default: return 0;
		}
	}

	static float AxisValue(InputBinding binding)
	{
		float value;
		switch (binding.axis)
		{
		case .LeftX: value = Gamepad.LeftStick.x;
		case .LeftY: value = Gamepad.LeftStick.y;
		case .RightX: value = Gamepad.RightStick.x;
		case .RightY: value = Gamepad.RightStick.y;
		case .LeftTrigger: value = Gamepad.LeftTrigger;
		default: value = Gamepad.RightTrigger;
		}
		return binding.invert ? -value : value;
	}

	static void UpdateAction(InputAction action, bool enabled, float deltaTime)
	{
		action.previous = action.value;
		action.value = 0;
		action.vector = .(0, 0);
		action.delta = .(0, 0);
		action.fromGamepad = false;
		if (!enabled)
			return;
		float strongest = 0;
		for (let binding in action.bindings)
		{
			float amount = 0;
			switch (binding.kind)
			{
			case .Touch:
				let control = TouchControls.FindById(binding.index);
				if (control != null && TouchControls.Active)
				{
					switch (control.kind)
					{
					case .Stick:
						var direction = control.vector;
						if (direction.LengthSquared > 1)
							direction = direction.Normalized;
						if (binding.invert)
							direction.y = -direction.y;
						action.vector += direction;
						action.delta += direction * binding.scale * deltaTime;
						amount = direction.Length;
					case .Look:
						// Like the mouse: pixels moved, up positive.
						let moved = control.delta;
						action.delta += Vector2(moved.x, binding.invert ? moved.y : -moved.y) * binding.scale;
						amount = moved.LengthSquared > 0 ? 0.001f : 0;
					case .Button,.Swipe:
						if (control.value > Math.Abs(action.value))
							action.value = control.value;
						amount = control.value;
					}
				}
			case .MouseDelta:
				// Up is positive, as for sticks.
				let moved = Input.MouseDelta;
				action.delta += Vector2(moved.x, binding.invert ? moved.y : -moved.y) * binding.scale;
				amount = moved.LengthSquared > 0 ? 0.001f : 0;
			case .PadStick,.PadDpad,.Keys:
				Vector2 direction;
				if (binding.kind == .PadStick)
					direction = binding.index == 1 ? Gamepad.RightStick : Gamepad.LeftStick;
				else if (binding.kind == .PadDpad)
					direction = Gamepad.Dpad;
				else
					direction = .((Input.GetKey(binding.key4) ? 1 : 0) - (Input.GetKey(binding.key3) ? 1 : 0), (Input.GetKey(binding.key) ? 1 : 0) - (Input.GetKey(binding.key2) ? 1 : 0));
				if (direction.LengthSquared > 1)
					direction = direction.Normalized;
				if (binding.invert)
					direction.y = -direction.y;
				action.vector += direction;
				action.delta += direction * binding.scale * deltaTime;
				amount = direction.Length;
			default:
				let raw = ButtonValue(binding) * (binding.kind == .PadAxis ? 1 : (binding.invert ? -1 : 1));
				if (action.kind == .Axis)
					action.value += raw * binding.scale;
				else if (Math.Abs(raw) > Math.Abs(action.value))
					action.value = raw;
				amount = Math.Abs(raw);
			}
			if (amount > strongest)
			{
				strongest = amount;
				action.fromGamepad = binding.IsGamepad;
			}
		}
		if (action.kind == .Axis)
			action.value = Math.Clamp(action.value, -1, 1);
		if (action.vector.LengthSquared > 1)
			action.vector = action.vector.Normalized;
		// A direction also counts as held while it is pushed, so that Held("Move") makes sense.
		if (action.kind == .Vector)
			action.value = action.vector.Length;
	}

	/// Called once a frame by the engine, after the devices were read.
	public static void Update()
	{
		EnsureLoaded();
		let deltaTime = Time.UnscaledDeltaTime;
		for (let map in sMaps)
		{
			for (let action in map.actions)
				UpdateAction(action, map.enabled, deltaTime);
		}
		for (let map in sStandard)
		{
			for (let action in map.actions)
				UpdateAction(action, true, deltaTime);
		}
	}
}
