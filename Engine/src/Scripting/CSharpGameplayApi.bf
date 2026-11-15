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
