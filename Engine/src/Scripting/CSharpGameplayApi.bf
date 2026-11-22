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

	static bool FindSource(uint64 session, uint64 entity, out AudioSource source)
	{
		source = default;
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || !obj.HasComponent<AudioSource>())
			return false;
		source = obj.GetComponent<AudioSource>();
		return true;
	}

	[CSharpExpose]
	public static bool HasSource(uint64 session, uint64 entity) => FindSource(session, entity, ?);

	/// Plays the source's Audio Clip, or (non-empty) another clip in its place.
	[CSharpExpose]
	public static void SourcePlay(uint64 session, uint64 entity, StringView clip)
	{
		if (!FindSource(session, entity, let source))
			return;
		if (clip.IsEmpty)
			source.Play();
		else
			source.Play(clip);
	}

	/// A sound on top of whatever the source is playing; any number overlap.
	[CSharpExpose]
	public static void SourcePlayOneShot(uint64 session, uint64 entity, StringView clip, float volumeScale)
	{
		if (volumeScale.IsFinite && FindSource(session, entity, let source))
			source.PlayOneShot(clip, volumeScale);
	}

	/// 0 pauses, 1 resumes, 2 stops.
	[CSharpExpose]
	public static void SourceControl(uint64 session, uint64 entity, int32 action)
	{
		if (!FindSource(session, entity, let source))
			return;
		switch (action)
		{
		case 0: source.Pause();
		case 1: source.Resume();
		case 2: source.Stop();
		default:
		}
	}

	[CSharpExpose]
	public static bool SourceIsPlaying(uint64 session, uint64 entity) => FindSource(session, entity, let source) && source.IsPlaying;

	/// 0 the clip's length, 1 the playback position (seconds); 0 with no clip loaded.
	[CSharpExpose]
	public static float SourceTime(uint64 session, uint64 entity, int32 which)
	{
		if (!FindSource(session, entity, let source))
			return 0;
		return which == 0 ? source.Length : source.Time;
	}

	/// Sets a playing source's pitch directly (0.1 to 3). This is for values that change every frame, such as an
	/// engine note; setting the Pitch field from C# would rewrite scene text each frame.
	[CSharpExpose]
	public static bool SourcePitch(uint64 session, uint64 entity, float pitch)
	{
		if (!pitch.IsFinite)
			return false;
		if (!FindSource(session, entity, let source))
			return false;
		source.Data.pitch = Mathf.Clamp(pitch, 0.1f, 3);
		return true;
	}

	/// Sets a playing source's volume directly (0 to 1), without rewriting its field.
	[CSharpExpose]
	public static bool SourceVolume(uint64 session, uint64 entity, float volume)
	{
		if (!volume.IsFinite)
			return false;
		if (!FindSource(session, entity, let source))
			return false;
		source.Data.volume = Mathf.Clamp01(volume);
		return true;
	}

	/// Seeks the source's clip to a position in seconds.
	[CSharpExpose]
	public static void SourceSeek(uint64 session, uint64 entity, float seconds)
	{
		if (seconds.IsFinite && FindSource(session, entity, let source))
			source.Time = Math.Max(seconds, 0);
	}

	/// The mixer's settings: 0 HRTF on (1) or off (0), 1 HRTF strength, 2 head size, 3 treble, 4 master volume.
	[CSharpExpose]
	public static float GetSetting(int32 which)
	{
		switch (which)
		{
		case 0: return Audio.Hrtf ? 1 : 0;
		case 1: return Audio.HrtfStrength;
		case 2: return Audio.HrtfHeadSize;
		case 3: return Audio.HrtfTreble;
		case 4: return Audio.MasterVolume;
		default: return 0;
		}
	}

	[CSharpExpose]
	public static void SetSetting(int32 which, float value)
	{
		if (!value.IsFinite)
			return;
		switch (which)
		{
		case 0: Audio.Hrtf = value != 0;
		case 1: Audio.HrtfStrength = value;
		case 2: Audio.HrtfHeadSize = value;
		case 3: Audio.HrtfTreble = value;
		case 4: Audio.MasterVolume = value;
		default:
		}
	}

	[CSharpExpose]
	public static float GetGroupVolume(int32 group) =>
		(group >= 0 && group <= (int32)AudioGroup.Other) ? Audio.GetGroupVolume((AudioGroup)group) : 0;

	[CSharpExpose]
	public static void SetGroupVolume(int32 group, float volume)
	{
		if (group >= 0 && group <= (int32)AudioGroup.Other && volume.IsFinite)
			Audio.SetGroupVolume((AudioGroup)group, volume);
	}
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
	public static int32 NetworkSlot(StringView name) => (int32)TickInput.ActionSlot(name);

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
