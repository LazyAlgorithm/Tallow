using System;
using System.Collections;

namespace Tallow;

/// Server-owned Day / Night clock for network sessions (N4a, tallowengine.com/docs/day-night). A scene has no network
/// entity, so instead of [Sync] fields the server shares the clock in a reliable MsgEvent message named with a
/// control-character marker (like the C# RPCs'): it sends the settings when a session starts, to a client that joins,
/// and whenever one changes, then nothing. Every machine works the time out from the session's tick, as Water does:
/// time = startTime + (tick - startTick) / TickRate * speed. Offline scenes keep the local clock and send nothing.
static class DayNightNet
{
	/// The name that marks the clock's messages in MsgEvent (no ordinary event name starts with a control character).
	public const StringView MessageName = "\x02daynight";
	/// Bumped when the layout changes: older builds ignore a message they do not know.
	const uint8 Version = 1;
	/// How far the environment's time may drift from what the clock last wrote before it counts as someone setting it.
	const double TimeEpsilon = 1e-4;

	/// One session's clock, as the server owns it (a client fills it from the server's message).
	class ClockState
	{
		public NetworkManager network;
		public double startTime;
		public uint32 startTick;
		/// Hours a second (24 / (Day Length minutes * 60)).
		public float speed;
		public float dayLengthMinutes = 24;
		public bool paused, enabled;
		public float latitude, axisTilt, northDirection;
		public int32 dayOfYear;
		/// The time last written into the scene's environment, to tell the clock's own writes from someone else's.
		public double writtenTime;
		/// The time worked out from the last update, for carrying on when the tick base starts again.
		public double lastTime;
		public bool initialized;
		/// Client: the server's settings have arrived.
		public bool received;
		public bool warned;
		public int32 bytesSent;
		/// Bumped whenever the clock's mapping from ticks to time changes (it starts, is rebased, or a client takes the
		/// server's state): Day / Night events start again from the new time instead of crossing the gap (N4b).
		public int32 epoch;
	}

	static List<ClockState> sStates = new .() ~ DeleteContainerAndItems!(_);

	static ClockState Find(NetworkManager network, bool create)
	{
		for (let state in sStates)
			if (state.network == network)
				return state;
		if (!create)
			return null;
		let state = new ClockState();
		state.network = network;
		sStates.Add(state);
		return state;
	}

	/// The session ended (NetworkManager.Stop): forget its clock, so a new one starts from the scene's settings.
	public static void SessionStopped(NetworkManager network)
	{
		for (int i = 0; i < sStates.Count; i++)
		{
			if (sStates[i].network == network)
			{
				delete sStates[i];
				sStates.RemoveAt(i);
				return;
			}
		}
	}

	public static int32 BytesSent(NetworkManager network) => Find(network, false)?.bytesSent ?? 0;

	public static bool Warned(NetworkManager network) => Find(network, false)?.warned ?? false;

	/// Which mapping from ticks to time the clock is on (DayNightEvents starts again when it changes).
	public static int32 Epoch(NetworkManager network) => Find(network, false)?.epoch ?? 0;

	/// Hours wrapped into [0, 24).
	public static double Wrap(double hours)
	{
		var h = hours % 24.0;
		if (h < 0)
			h += 24;
		return h >= 24 ? 0 : h;
	}

	static float SpeedFrom(float dayLengthMinutes) => dayLengthMinutes > 0 ? 24.0f / (dayLengthMinutes * 60.0f) : 0;

	/// The session tick the shared clock runs on: the server's own, or the server's tick as a client knows it (its
	/// ServerTick). Using the same timeline on every machine means a client that joined late is on the server's time
	/// at once, not back at the clock's first day; the clock is the server's, so it is not part of a deterministic
	/// simulation (as the scene's physics is) that could not use this.
	public static double SharedTick(NetworkManager network) => network.ServerTick - 1;

	/// The time on the session's simulation clock, from the tick every machine simulates the same (the shared
	/// timeline above, so host and clients agree even when a client joined late).
	public static double SimulationTime(NetworkManager network) =>
		Clock(Find(network, false), SharedTick(network));

	/// The time to draw, from the server's tick as this machine knows it, eased between ticks.
	public static double ViewTime(NetworkManager network) =>
		Clock(Find(network, false), network.ServerTick - 1 + Time.InterpolationAlpha);

	/// The shared clock in hours since its start, not wrapped at midnight, so it only ever goes up while the clock
	/// runs. Every peer works out the same value from the same ticks; 0 before the server's settings arrive.
	public static double UnwrappedTime(NetworkManager network)
	{
		let state = Find(network, false);
		if (state == null || !state.initialized || !state.enabled)
			return 0;
		if (state.paused || state.speed <= 0)
			return state.startTime;
		return state.startTime + (SharedTick(network) - state.startTick) / Time.TickRate * state.speed;
	}

	/// The session tick at which the shared clock reaches `hours` (an UnwrappedTime value): the tick nearest the
	/// crossing. Worked out from the server's settings only, so host and clients get the same number, late joiners
	/// included.
	public static int64 EventTick(NetworkManager network, double hours)
	{
		let state = Find(network, false);
		if (state == null || !state.initialized || !state.enabled || state.paused || state.speed <= 0)
			return (int64)SharedTick(network);
		let tick = state.startTick + (hours - state.startTime) / state.speed * Time.TickRate;
		// The tick the crossing falls nearest: worked out from the server's settings alone, so every machine gets the
		// same number (the hour's own tick when it lands on one).
		return (int64)Math.Round(tick);
	}

	static double Clock(ClockState state, double tick)
	{
		if (state == null || !state.initialized)
			return 0;
		if (!state.enabled || state.paused || state.speed <= 0)
			return Wrap(state.startTime);
		return Wrap(state.startTime + (tick - state.startTick) / Time.TickRate * state.speed);
	}

	/// Called once a frame in a network session instead of stepping the local clock.
	public static void Update(Scene scene, NetworkManager network)
	{
		let state = Find(network, true);
		if (network.IsServer)
			UpdateServer(network, state, scene.Environment);
		else
			UpdateClient(network, state, scene.Environment);
	}

	static void UpdateServer(NetworkManager network, ClockState state, SceneEnvironment env)
	{
		if (!state.initialized)
		{
			Take(network, state, env);
			Write(network, state, env);
			SendState(network, state, -1);
			return;
		}
		var changed = false;
		var rebase = false;
		var userSet = false;
		if (network.Tick < state.startTick)
		{
			// The tick base started again (this machine took over as host): carry on from the time it was showing.
			state.startTime = Wrap(state.lastTime);
			state.startTick = network.Tick;
			changed = true;
			state.epoch++;
		}
		let now = Clock(state, network.Tick);
		if (env.dayNight != state.enabled)
		{
			state.enabled = env.dayNight;
			changed = true;
			rebase = true;
			state.epoch++;
		}
		if (env.dayNightPaused != state.paused)
		{
			state.paused = env.dayNightPaused;
			changed = true;
			rebase = true;
			state.epoch++;
		}
		if (env.dayLengthMinutes != state.dayLengthMinutes)
		{
			state.dayLengthMinutes = env.dayLengthMinutes;
			state.speed = SpeedFrom(env.dayLengthMinutes);
			changed = true;
			rebase = true;
			state.epoch++;
		}
		// Someone set the time itself (the editor's scrub, a script, the C# setter): carry on from there.
		if (Math.Abs(env.timeOfDay - state.writtenTime) > TimeEpsilon)
		{
			state.startTime = Wrap(env.timeOfDay);
			state.startTick = network.Tick;
			changed = true;
			userSet = true;
			state.epoch++;
		}
		if (state.latitude != env.latitude || state.axisTilt != env.axisTilt || state.northDirection != env.northDirection ||
			state.dayOfYear != env.dayOfYear)
		{
			state.latitude = env.latitude;
			state.axisTilt = env.axisTilt;
			state.northDirection = env.northDirection;
			state.dayOfYear = env.dayOfYear;
			changed = true;
		}
		if (rebase && !userSet)
		{
			// A setting changed: keep the time where it was, going on at the new pace.
			state.startTime = now;
			state.startTick = network.Tick;
		}
		state.lastTime = Clock(state, network.Tick);
		Write(network, state, env);
		if (changed)
			SendState(network, state, -1);
	}

	static void UpdateClient(NetworkManager network, ClockState state, SceneEnvironment env)
	{
		if (!state.received)
			return;
		var ignored = false;
		if (env.dayNight != state.enabled)
		{
			env.dayNight = state.enabled;
			ignored = true;
		}
		if (env.dayNightPaused != state.paused)
		{
			env.dayNightPaused = state.paused;
			ignored = true;
		}
		if (env.dayLengthMinutes != state.dayLengthMinutes)
		{
			env.dayLengthMinutes = state.dayLengthMinutes;
			ignored = true;
		}
		if (Math.Abs(env.timeOfDay - state.writtenTime) > TimeEpsilon)
			ignored = true; // Taken from the clock below.
		if (state.latitude != env.latitude || state.axisTilt != env.axisTilt || state.northDirection != env.northDirection ||
			state.dayOfYear != env.dayOfYear)
			ignored = true; // Taken from the server below.
		state.lastTime = Clock(state, network.Tick);
		Write(network, state, env);
		if (ignored && !state.warned)
		{
			state.warned = true;
			Log.Warning("Day/Night is the server's in a network session: changes made here are ignored.");
		}
	}

	/// Takes the session's starting values from the scene (the server's, or a client's before its first message).
	static void Take(NetworkManager network, ClockState state, SceneEnvironment env)
	{
		state.startTime = Wrap(env.timeOfDay);
		state.startTick = network.Tick;
		state.speed = SpeedFrom(env.dayLengthMinutes);
		state.dayLengthMinutes = env.dayLengthMinutes;
		state.paused = env.dayNightPaused;
		state.enabled = env.dayNight;
		state.latitude = env.latitude;
		state.axisTilt = env.axisTilt;
		state.northDirection = env.northDirection;
		state.dayOfYear = env.dayOfYear;
		state.lastTime = state.startTime;
		state.initialized = true;
		state.epoch++;
	}

	/// Puts the clock's settings in the environment (the time first thing: whoever changed it is overruled).
	static void Write(NetworkManager network, ClockState state, SceneEnvironment env)
	{
		env.timeOfDay = (float)Clock(state, network.ServerTick - 1 + Time.InterpolationAlpha);
		env.dayNight = state.enabled;
		env.dayNightPaused = state.paused;
		env.dayLengthMinutes = state.dayLengthMinutes;
		env.latitude = state.latitude;
		env.axisTilt = state.axisTilt;
		env.northDirection = state.northDirection;
		env.dayOfYear = state.dayOfYear;
		state.writtenTime = env.timeOfDay;
	}

	/// Server: a client joined; tell it the clock as it is now (and start the clock first if this is the first client).
	public static void ClientJoined(NetworkManager network, int32 clientId)
	{
		if (!network.IsServer)
			return;
		let state = Find(network, true);
		if (!state.initialized)
		{
			Take(network, state, network.Scene.Environment);
			Write(network, state, network.Scene.Environment);
		}
		SendState(network, state, clientId);
	}

	static void WriteState(NetWriter writer, ClockState state)
	{
		writer.WriteString(MessageName);
		writer.Write(Version);
		writer.Write((uint8)(state.enabled ? 1 : 0));
		writer.Write((uint8)(state.paused ? 1 : 0));
		writer.Write(state.startTime);
		writer.Write(state.startTick);
		writer.Write(state.speed);
		writer.Write(state.dayLengthMinutes);
		writer.Write(state.latitude);
		writer.Write(state.axisTilt);
		writer.Write(state.northDirection);
		writer.Write(state.dayOfYear);
	}

	static void SendState(NetworkManager network, ClockState state, int32 clientId)
	{
		let payload = scope NetWriter();
		WriteState(payload, state);
		if (clientId < 0)
			network.SendToAll(NetworkSync.MsgEvent, payload);
		else
			network.SendToClient(clientId, NetworkSync.MsgEvent, payload);
		state.bytesSent += (int32)payload.Data.Count;
	}

	/// Whether this MsgEvent payload is the Day / Night clock's (its first thing is the marker name, not an object).
	public static bool IsStateMessage(ref NetReader reader)
	{
		if (reader.Remaining < 1)
			return false;
		var probe = NetReader(reader.Start + reader.Position, reader.Remaining);
		let name = scope String();
		probe.ReadString(name);
		return probe.Ok && name == MessageName;
	}

	/// Client: the server's clock settings. A message from anyone else (or on the server) is left alone.
	public static void ReadState(ref NetReader reader)
	{
		let network = NetworkManager.Dispatching;
		if (network == null || network.Mode == .Offline || network.IsServer)
			return;
		let name = scope String();
		reader.ReadString(name);
		if (!reader.Ok || name != MessageName)
			return;
		if (reader.Read<uint8>() != Version)
			return;
		var enabled = reader.Read<uint8>() != 0;
		var paused = reader.Read<uint8>() != 0;
		let startTime = reader.Read<double>();
		let startTick = reader.Read<uint32>();
		let speed = reader.Read<float>();
		let dayLengthMinutes = reader.Read<float>();
		let latitude = reader.Read<float>();
		let axisTilt = reader.Read<float>();
		let northDirection = reader.Read<float>();
		let dayOfYear = reader.Read<int32>();
		if (!reader.Ok || !startTime.IsFinite || !speed.IsFinite || !dayLengthMinutes.IsFinite || !latitude.IsFinite ||
			!axisTilt.IsFinite || !northDirection.IsFinite || speed < 0 || dayLengthMinutes < 0 || Math.Abs(latitude) > 90 ||
			Math.Abs(axisTilt) > 90)
			return;
		let state = Find(network, true);
		state.startTime = Wrap(startTime);
		state.startTick = startTick;
		state.speed = speed;
		state.dayLengthMinutes = dayLengthMinutes;
		state.paused = paused;
		state.enabled = enabled;
		state.latitude = latitude;
		state.axisTilt = axisTilt;
		state.northDirection = northDirection;
		state.dayOfYear = dayOfYear;
		state.received = true;
		state.initialized = true;
		state.epoch++;
		state.lastTime = Clock(state, network.Tick);
		// Take it straight away, so the sky is right from this frame (not just from the next update).
		Write(network, state, network.Scene.Environment);
	}
}
