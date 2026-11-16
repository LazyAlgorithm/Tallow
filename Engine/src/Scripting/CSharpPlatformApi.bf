using System;
using System.Collections;

namespace Tallow;

/// Engine services C# scripts use that are not components: gamepads, touch, the window, quality presets,
/// achievements and stats, subtitles, dialogue variables, decals and wind. Each wraps the Beef static class of the
/// same purpose with the binding generator's types (Managed/Tallow.API/Platform.cs gives C# its usual shape).
[CSharpExpose]
static class CSharpPlatform
{
	static int Pad(int32 pad) => Math.Clamp(pad, 0, Gamepad.MaxPads - 1);

	/// Copies text for C# (UTF-8); the text's length, which may be more than the buffer (call again with more room).
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	// ---- gamepads

	[CSharpExpose]
	public static bool GamepadConnected(int32 pad) => pad >= 0 && pad < Gamepad.MaxPads && Gamepad.IsConnected(pad);

	/// 0 Generic, 1 Xbox, 2 PlayStation, 3 Nintendo.
	[CSharpExpose]
	public static int32 GamepadKindOf(int32 pad) => (int32)Gamepad.Kind(Pad(pad));

	[CSharpExpose]
	public static int32 GamepadNameOf(int32 pad, Span<uint8> buffer) => Copy(Gamepad.Name(Pad(pad)), buffer);

	/// state 0 held, 1 pressed this frame, 2 released this frame.
	[CSharpExpose]
	public static bool GamepadButtonState(int32 button, int32 pad, int32 state)
	{
		if (button < 0 || button >= (int32)GamepadButton.Count)
			return false;
		let b = (GamepadButton)button;
		switch (state)
		{
		case 1: return Gamepad.GetButtonDown(b, Pad(pad));
		case 2: return Gamepad.GetButtonUp(b, Pad(pad));
		default: return Gamepad.GetButton(b, Pad(pad));
		}
	}

	[CSharpExpose]
	public static float GamepadAxisValue(int32 axis, int32 pad) =>
		axis >= 0 && axis < (int32)GamepadAxis.Count ? Gamepad.GetAxis((GamepadAxis)axis, Pad(pad)) : 0;

	[CSharpExpose]
	public static void GamepadRumble(float low, float high, float seconds, int32 pad) => Gamepad.Rumble(low, high, seconds, Pad(pad));

	// ---- touch

	[CSharpExpose]
	public static int32 TouchCount() => (int32)Touch.Fingers.Count;

	/// Finger index: values gets id, x, y, start x, start y, delta x, delta y, start time, down (1/0). False past the end.
	[CSharpExpose]
	public static bool TouchFinger(int32 index, Span<float> values)
	{
		if (index < 0 || index >= Touch.Fingers.Count || values.Length < 9)
			return false;
		let finger = Touch.Fingers[index];
		values[0] = (float)(finger.id & 0xFFFFFF);
		values[1] = finger.position.x;
		values[2] = finger.position.y;
		values[3] = finger.start.x;
		values[4] = finger.start.y;
		values[5] = finger.delta.x;
		values[6] = finger.delta.y;
		values[7] = finger.startTime;
		values[8] = finger.down ? 1 : 0;
		return true;
	}

	// ---- the window and quality

	[CSharpExpose]
	public static bool WindowFullscreen() => GameWindow.Fullscreen;

	[CSharpExpose]
	public static void SetWindowFullscreen(bool on) => GameWindow.Fullscreen = on;

	/// 0 Low, 1 Medium, 2 High, 3 Ultra, 4 Custom.
	[CSharpExpose]
	public static int32 QualityCurrent() => (int32)Quality.Level;

	[CSharpExpose]
	public static int32 QualityRecommended() => (int32)Quality.Recommended;

	/// Applies a preset (0 Low ... 3 Ultra) at once; save: kept for the next start. False for Custom or out of range.
	[CSharpExpose]
	public static bool QualitySet(int32 level, bool save)
	{
		if (level < 0 || level > (int32)QualityLevel.Ultra)
			return false;
		Quality.Set((QualityLevel)level);
		if (save)
			Quality.Save();
		return true;
	}

	// ---- achievements and stats (Steam when the game runs there, else saved locally)

	[CSharpExpose]
	public static bool AchievementUnlock(StringView id) => Achievements.Unlock(id);

	[CSharpExpose]
	public static bool AchievementUnlocked(StringView id) => Achievements.IsUnlocked(id);

	[CSharpExpose]
	public static void AchievementProgress(StringView id, int32 current, int32 max) => Achievements.SetProgress(id, current, max);

	[CSharpExpose]
	public static void AchievementClear(StringView id)
	{
		if (id.IsEmpty)
			Achievements.ClearAll();
		else
			Achievements.Clear(id);
	}

	[CSharpExpose]
	public static int32 StatGet(StringView name, bool localOnly) => Achievements.GetStat(name, localOnly);

	[CSharpExpose]
	public static void StatSet(StringView name, int32 value, bool localOnly) => Achievements.SetStat(name, value, localOnly);

	[CSharpExpose]
	public static int32 StatAdd(StringView name, int32 amount, bool localOnly) => Achievements.AddStat(name, amount, localOnly);

	// ---- subtitles

	/// A subtitle line (speaker may be empty) for seconds (0: worked out from its length); colour rgba. Its id.
	[CSharpExpose]
	public static int32 SubtitleShow(StringView speaker, StringView text, float seconds, Vector4 color) =>
		Subtitles.Show(speaker, text, seconds, .(color.x, color.y, color.z, color.w));

	/// A sound caption ("[door creaks]").
	[CSharpExpose]
	public static int32 SubtitleCaption(StringView text, float seconds) => Subtitles.Caption(text, seconds);

	[CSharpExpose]
	public static void SubtitleHide(int32 id) => Subtitles.Hide(id);

	[CSharpExpose]
	public static bool SubtitleShowing(int32 id) => Subtitles.IsShowing(id);

	[CSharpExpose]
	public static void SubtitlesClear() => Subtitles.Clear();

	// ---- dialogue variables (what dialogue conditions and Set nodes read and write)

	[CSharpExpose]
	public static float DialogueVariable(StringView name) => DialogueVariables.Get(name);

	[CSharpExpose]
	public static void SetDialogueVariable(StringView name, float value) => DialogueVariables.Set(name, value);

	[CSharpExpose]
	public static bool DialogueCondition(StringView condition) => DialogueVariables.Evaluate(condition);

	[CSharpExpose]
	public static void DialogueVariablesClear() => DialogueVariables.Clear();

	// ---- decals and wind

	/// A short-lived decal pressed onto surfaces at a point (bullet holes, footprints): texture path, size in metres,
	/// lifetime in seconds (0: until there are too many), colour rgba, spin in degrees. False without the scene.
	[CSharpExpose]
	public static bool DecalSpawn(uint64 session, Vector3 position, Vector3 normal, StringView texture, float size,
		float lifetime, Vector4 color, float spin)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null || texture.IsEmpty)
			return false;
		Decals.Spawn(scene, position, normal, texture, size, lifetime, .(color.x, color.y, color.z, color.w), spin);
		return true;
	}

	[CSharpExpose]
	public static void DecalsClear(uint64 session)
	{
		if (let scene = CSharpRuntime.PhysicsScene(session))
			Decals.Clear(scene);
	}

	/// The wind's velocity at a point (Wind Zones and the scene's wind), metres a second.
	[CSharpExpose]
	public static Vector3 WindAt(uint64 session, Vector3 position)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		return scene != null ? Wind.At(scene, position) : .Zero;
	}

	/// How gusty the wind is now, 0 to 1.
	[CSharpExpose]
	public static float WindGusts(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		return scene != null ? Wind.Gusts(scene) : 0;
	}
}
