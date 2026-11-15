using System;

namespace Tallow;

/// Sounds for C# scripts (Tallow.API's Audio).
[CSharpExpose]
static class CSharpAudio
{
	/// Plays a sound once at a point in the world (Effects group).
	[CSharpExpose]
	public static void PlayOneShot(StringView clip, Vector3 position, float volume) => Audio.PlayOneShot(clip, position, volume);

	/// Plays a sound once, not placed in the world (Interface group).
	[CSharpExpose]
	public static void PlayOneShot2D(StringView clip, float volume) => Audio.PlayOneShot2D(clip, volume);
}

/// The project's input actions for C# scripts (Tallow.API's InputActions). These read this machine's devices: a
/// networked script reads its TickInput in Update instead.
[CSharpExpose]
static class CSharpInputActions
{
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// For a "press a key" prompt: on the frame a key, mouse button or controller button goes down, makes it the
	/// action's binding number `index` (0 is the first; past the end adds one). False on other frames or for an
	/// unknown action. Works while Input.Enabled is false.
	[CSharpExpose]
	public static bool CaptureBinding(StringView action, int32 index)
	{
		if (index < 0 || InputActions.Find(action) == null)
			return false;
		if (!InputActions.Capture(let binding))
			return false;
		return InputActions.SetBinding(action, index, binding);
	}

	/// What binding number `index` of the action is called ("Space", "Mouse 1", "Pad A"); -1 when it has none.
	[CSharpExpose]
	public static int32 CopyBindingName(StringView action, int32 index, Span<uint8> buffer)
	{
		let found = InputActions.Find(action);
		if (found == null || index < 0)
			return -1;
		let bindings = (found.bindings.IsEmpty && found.standard != null) ? found.standard.bindings : found.bindings;
		if (index >= bindings.Count)
			return -1;
		let name = scope String();
		InputActions.BindingName(bindings[index], name);
		return Copy(name, buffer);
	}

	/// Every action's bindings as text, to keep with the player's settings (InputActions.ToText).
	[CSharpExpose]
	public static int32 CopyText(Span<uint8> buffer)
	{
		let text = scope String();
		InputActions.ToText(text);
		return Copy(text, buffer);
	}

	[CSharpExpose]
	public static void LoadText(StringView text) => InputActions.LoadText(text);

	/// Whether the action is being worked from a controller right now.
	[CSharpExpose]
	public static bool FromGamepad(StringView action) => InputActions.FromGamepad(action);

	/// What to press for the action on the device in the player's hands ("E", "B"), for prompts.
	[CSharpExpose]
	public static int32 CopyDescription(StringView action, Span<uint8> buffer)
	{
		let text = scope String();
		InputActions.Describe(action, text);
		return Copy(text, buffer);
	}

	/// Switches a whole map of actions ("Player", "Menu") on or off.
	[CSharpExpose]
	public static void SetMapEnabled(StringView map, bool enabled) => InputActions.SetMapEnabled(map, enabled);

	[CSharpExpose]
	public static bool Held(StringView name) => InputActions.Held(name);
	[CSharpExpose]
	public static bool Pressed(StringView name) => InputActions.Pressed(name);
	[CSharpExpose]
	public static bool Released(StringView name) => InputActions.Released(name);
	[CSharpExpose]
	public static float Value(StringView name) => InputActions.Value(name);
	[CSharpExpose]
	public static Vector2 Vector(StringView name) => InputActions.Vector(name);
	[CSharpExpose]
	public static Vector2 Delta(StringView name) => InputActions.Delta(name);
}

/// Smaller engine services for C# scripts: game time and NetRandom.
[CSharpExpose]
static class CSharpGameplay
{
	/// Seconds of game time since play started (Time.Time); follows TimeScale.
	[CSharpExpose]
	public static float GameTime() => Time.Time;

	/// NetRandom.Value for an object: every machine in step gets the same number. 0 for a missing object.
	[CSharpExpose]
	public static float NetRandomValue(uint64 session, uint64 entity, int32 salt)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		return obj != null ? NetRandom.Value(obj, salt) : 0;
	}
}
