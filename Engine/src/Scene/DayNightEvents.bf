using System;
using System.Collections;

namespace Tallow;

/// Day / Night events (N4b): the moments the shared clock crosses sunrise, sunset and each whole hour, queued for C#
/// (`Managed/Tallow.API/DayNight.cs`) to raise. `DayNight.Update` looks for them in the time both peers' clocks agree
/// on (`DayNight.SimulationTime`), and the tick is worked out from the server's clock settings (`DayNightNet.EventTick`)
/// rather than from when the frame happened to run, so every machine finds the same tick, a late joiner included.
/// Offline scenes keep their own clock and their own ticks.
static class DayNightEvents
{
	/// Kinds as C# sees them: the sun crossed the horizon upwards, downwards, or a whole hour began.
	public const int32 Sunrise = 0;
	public const int32 Sunset = 1;
	public const int32 Hour = 2;

	/// Events kept before the oldest are dropped.
	const int32 MaxQueued = 256;
	/// A clock that moves further than this in one update jumped (it was set, or a client joined) rather than ran.
	const double MaxJumpHours = 48;
	/// How far the clock's tick-shown time may differ from where the ticks say it should be before it counts as a jump.
	const double JumpEpsilonHours = 1.0 / 60.0;
	/// The most ticks one update may cross and still be the clock running (a client joining maps its tick to the
	/// server's, which is a jump however far ahead the server was).
	const double MaxTickStep = 240;
	/// Crossing search step: short enough that the sun cannot rise and set within one step at any latitude.
	const double StepHours = 10.0 / 60.0;
	const int32 MaxSteps = 288;

	class State
	{
		public Scene scene;
		/// The shared clock when last seen, in hours, not wrapped at midnight (it only goes up while the clock runs).
		public double time;
		/// The session tick (or the simulation tick offline) the last look was at. Not a whole number on a client:
		/// its ServerTick is an estimate.
		public double tick;
		public bool started;
		/// The clock's mapping (DayNightNet.Epoch) the last look was on: a new one (it started, was rebased, or a
		/// client took the server's state) means the time jumped and nothing crossed by running.
		public int32 epoch;
		public List<int64> queue = new .() ~ delete _;
	}

	static List<State> sStates = new .() ~ DeleteContainerAndItems!(_);

	static State Find(Scene scene, bool create)
	{
		for (let state in sStates)
			if (state.scene == scene)
				return state;
		if (!create)
			return null;
		let state = new State();
		state.scene = scene;
		sStates.Add(state);
		return state;
	}

	/// The scene is unloading: forget its clock and whatever it had queued.
	public static void Forget(Scene scene)
	{
		for (int i = 0; i < sStates.Count; i++)
		{
			if (sStates[i].scene == scene)
			{
				delete sStates[i];
				sStates.RemoveAt(i);
				return;
			}
		}
	}

	/// The next event heard since the last take: -1 when there is none, else the tick in the low 32 bits, the kind
	/// in bits 32-33, and for an hour event the hour (0 to 23) in bits 34-38.
	public static int64 Take(Scene scene)
	{
		let state = Find(scene, false);
		if (state == null || state.queue.IsEmpty)
			return -1;
		return state.queue.PopFront();
	}

	/// How many events are waiting (for tests).
	public static int32 Count(Scene scene)
	{
		let state = Find(scene, false);
		if (state == null)
			return 0;
		return (int32)state.queue.Count;
	}

	static int64 Pack(int32 kind, int32 hour, int64 tick) =>
		(int64)(uint32)tick | ((int64)(uint32)kind << 32) | ((int64)(uint32)(hour & 31) << 34);

	static void Emit(State state, int32 kind, int32 hour, int64 tick)
	{
		if (state.queue.Count < MaxQueued)
			state.queue.Add(Pack(kind, hour, tick));
	}

	static double TickOf(Scene scene)
	{
		let network = scene.Network;
		return network != null && network.Mode != .Offline ? DayNightNet.SharedTick(network) : (double)Time.Tick;
	}

	/// The tick a crossing at `hours` (an unwrapped time) happened on, the same number on every machine.
	static int64 EventTick(Scene scene, double hours)
	{
		let network = scene.Network;
		if (network != null && network.Mode != .Offline)
			return DayNightNet.EventTick(network, hours);
		return Time.Tick;
	}

	/// The sun's height above the horizon at an unwrapped time, in degrees.
	static double ElevationAt(SceneEnvironment env, double hours) => DayNight.SunElevationAt(env, hours);

	/// Where between `a` and `b` the sun crossed the horizon (a bisection on its height, the same sum on every peer).
	static double ZeroCrossing(SceneEnvironment env, double low, double high, double elevationLow)
	{
		var a = low;
		var b = high;
		var elevationA = elevationLow;
		for (int i = 0; i < 12; i++)
		{
			let mid = (a + b) * 0.5;
			let elevation = ElevationAt(env, mid);
			if ((elevation > 0) == (elevationA > 0))
			{
				a = mid;
				elevationA = elevation;
			}
			else
				b = mid;
		}
		return (a + b) * 0.5;
	}

	/// Called by DayNight.Update after the clock moved: `elapsedHours` is how far the scene's own clock ran (negative
	/// for a network clock, whose time is worked out from the session's ticks).
	public static void Update(Scene scene, double elapsedHours)
	{
		let env = scene.Environment;
		let state = Find(scene, true);
		let network = scene.Network != null && scene.Network.Mode != .Offline ? scene.Network : null;
		let clockNow = network != null ? DayNightNet.UnwrappedTime(network) : env.timeOfDay;
		let epoch = network != null ? DayNightNet.Epoch(network) : 0;
		if (!scene.IsPlaying || !env.dayNight)
		{
			// Not running: take the time as the new starting point, so starting play does not fire a day of events.
			state.started = false;
			state.epoch = epoch;
			state.time = clockNow;
			state.tick = TickOf(scene);
			return;
		}
		if (!state.started || epoch != state.epoch)
		{
			// A new clock mapping (the server's state arrives, or the clock is rebased): the time jumped, so nothing
			// crossed by running. Start again from where it now is.
			state.started = true;
			state.epoch = epoch;
			state.time = clockNow;
			state.tick = TickOf(scene);
			return;
		}
		let prev = state.time;
		double now;
		if (network != null)
		{
			now = clockNow;
			let speed = env.dayNightPaused || env.dayLengthMinutes <= 0 ? 0 : 24.0 / (env.dayLengthMinutes * 60.0);
			let tick = DayNightNet.SharedTick(network);
			let tickStep = tick - state.tick;
			let ran = tickStep / Time.TickRate * speed;
			state.tick = tick;
			// The server's clock writes its start wrapped into [0, 24): take the day that keeps the clock going on.
			let days = Math.Round((now - (prev + ran)) / 24.0);
			let adjusted = now - days * 24.0;
			// Ticks that leap (a client's tick mapped onto the server's on joining, a snapshot roll-back) are a jump,
			// however well the time then matches the new tick.
			if (tickStep < 0 || tickStep > MaxTickStep || Math.Abs(adjusted - (prev + ran)) > JumpEpsilonHours)
			{
				// A jump (the time was set, the server rebased, a client took the clock): nothing crossed by running.
				state.time = adjusted;
				return;
			}
			now = adjusted;
		}
		else
		{
			now = prev + (elapsedHours > 0 ? elapsedHours : 0);
			// Someone set the scene's own time this frame (a scrub, a script): start again from it.
			let shown = (double)env.timeOfDay;
			var shownNear = shown + Math.Round((prev - shown) / 24.0) * 24.0;
			var difference = now - shownNear;
			if (Math.Abs(difference) > JumpEpsilonHours && Math.Abs(Math.Abs(difference) - 24.0) > JumpEpsilonHours)
			{
				state.time = shownNear;
				state.tick = TickOf(scene);
				return;
			}
			now = shownNear + Math.Round((now - shownNear) / 24.0) * 24.0;
		}
		let span = now - prev;
		state.time = now;
		if (span <= 0 || span > MaxJumpHours)
			return;
		// Walk the span in short steps, so the sun cannot rise and set between two looks and each whole hour is met
		// in order. Crossing times become the tick the shared clock reached them on, the same on every machine.
		let steps = Math.Clamp((int32)Math.Ceiling(span / StepHours), 1, MaxSteps);
		var a = prev;
		var elevationA = ElevationAt(env, a);
		for (int s = 1; s <= steps; s++)
		{
			let b = s == steps ? now : prev + span * s / steps;
			var hour = (int64)Math.Floor(a) + 1;
			while ((double)hour <= b)
			{
				let hourShown = (int32)((hour % 24 + 24) % 24);
				Emit(state, Hour, hourShown, EventTick(scene, (double)hour));
				hour += 1;
			}
			let elevationB = ElevationAt(env, b);
			if (elevationA < 0 && elevationB >= 0)
				Emit(state, Sunrise, 0, EventTick(scene, ZeroCrossing(env, a, b, elevationA)));
			else if (elevationA >= 0 && elevationB < 0)
				Emit(state, Sunset, 0, EventTick(scene, ZeroCrossing(env, a, b, elevationA)));
			a = b;
			elevationA = elevationB;
		}
	}
}
