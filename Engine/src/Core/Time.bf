using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Frame and simulation timing. The simulation runs on a fixed tick so physics and
/// networking stay deterministic; rendering interpolates between ticks.
static class Time
{
	/// Fixed updates (FixedUpdate, physics and network ticks) a second.
	public const int32 TickRate = 60;
	/// Seconds between fixed updates.
	public const float FixedDeltaTime = 1.0f / TickRate;

	/// Seconds since the previous rendered frame, scaled by TimeScale.
	public static float DeltaTime;
	/// Seconds since the last frame, whatever TimeScale is (for pause menus).
	public static float UnscaledDeltaTime;
	/// Seconds of game time since play started. It follows TimeScale, and stands still when that is 0.
	public static float Time;
	static double sPlayed;
	/// Seconds since the program started, whether or not the game is playing or paused. Shaders use this for
	/// "time", so that animated materials move in the editor too.
	public static float RealTime;
	/// How fast game time runs: 1 is normal, 0.5 slow motion, 0 paused.
	public static float TimeScale = 1.0f;
	/// How fast simulation ticks come round compared with real time. A network client moves this a few percent
	/// either side of 1 to stay in step with the server; each tick still simulates FixedDeltaTime.
	public static float TickScale = 1.0f;
	/// Frames since the program started.
	public static int64 FrameCount;
	/// Number of fixed simulation ticks executed.
	public static int32 Tick;
	/// 0..1 position of the current frame between the last two fixed ticks.
	public static float InterpolationAlpha;
	/// Frames a second, averaged over the last second or so.
	public static float SmoothedFps;

	/// Back to the start of play.
	public static void Restart()
	{
		sPlayed = 0;
		Time = 0;
	}

	/// Game time moves on by a frame. Added up in a double: a float stops gaining short frames after a day or so.
	public static void Advance(float seconds)
	{
		sPlayed += seconds;
		Time = (float)sPlayed;
	}
}
