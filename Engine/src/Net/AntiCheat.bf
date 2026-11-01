using System;
using System.Collections;

namespace Tallow;

/// What the anti-cheat can find.
enum CheatKind : int32
{
	/// Controls no honest game sends: an impossible view angle. (Movement past full tilt and numbers that are
	/// not numbers cannot be sent at all: controls travel packed, and the packing has no way to write them.)
	InvalidInput,
	/// The player's game is running faster than the server's: a speed hack. (The server moves every player itself,
	/// one step a tick, so they gain nothing; this notices the attempt.)
	SpeedHack,
	/// Far more messages than a game sends.
	MessageFlood,
	/// The player's game files are not the server's.
	ModifiedFiles,
	/// The player's game does not answer the anti-cheat's questions: it has been taken out, or it is not this game.
	NoResponse,
	/// A debugger is attached to the player's game.
	Debugger,
	/// A library has been forced into the player's game.
	InjectedCode,
	/// The clock the player's game runs on is being stretched.
	ClockTampering,
	/// A guarded value was changed from outside the game (a memory editor).
	MemoryTampering,
	/// Aim no hand produces, over many shots: turning a long way in an instant onto a target, time after time.
	SuspiciousAim,
	Count
}

/// What is done about each kind.
enum CheatAction : int32
{
	/// Not looked for.
	Ignore,
	/// Written to the log, counted and reported to OnViolation.
	Log,
	/// The same, and the player is told why and removed from the session.
	Kick
}

/// One thing the anti-cheat found.
class CheatViolation
{
	public int32 clientId;
	public CheatKind kind;
	public String detail = new .() ~ delete _;
	public float time;
}

/// Anti-cheat for network sessions. Off until the game turns it on (here, or with the Anti-Cheat box in Project
/// Settings); it then works with no further code, on every system the engine runs on.
///
/// The engine's networking already denies cheats their usual ground: the server moves every player itself from
/// their controls, one step a tick, so a changed game cannot move faster, teleport or fly, and whatever the game
/// decides on the server (damage, ammunition, score) cannot be decided by a player. The anti-cheat adds watching:
///
///   on the server   controls no honest game sends; a game running fast; floods of messages; aim statistics;
///                   whether each player's game files match the server's; whether their game answers at all
///   on each player  a debugger attached; a library forced or loaded into the game; the game's own code changed
///                   in memory; a stretched clock; guarded values changed from outside (GuardedInt, GuardedFloat) -
///                   each reported to the server. A built game also closes its memory to other programs (Harden).
///
/// What is found goes to the log, to Violations and to OnViolation, and by SetAction is ignored, logged, or gets
/// the player removed. It is not a kernel-level anti-cheat and does not claim to be one: read docs/anti-cheat.md
/// for what it cannot see.
static class AntiCheat
{
	public const uint8 MsgAntiCheat = 243;
	const uint8 MessageChallenge = 1, MessageAnswer = 2, MessageNotice = 3, MessageReport = 4;
	const uint32 FlagDebugger = 1, FlagInjected = 2, FlagClock = 4;

	[CLink] static extern uint32 tn_guard_environment();
	[CLink] static extern void tn_guard_clocks(double* engine, double* independent);
	[CLink] static extern uint32 tn_pack_fingerprint();
	[CLink] static extern int32 tn_guard_harden();
	[CLink] static extern char8* tn_guard_new_module();
	[CLink] static extern int32 tn_guard_code_changed();
	/// For tests: writes over a byte of the program's own code, or puts it back.
	[CLink] public static extern int32 tn_guard_test_patch(int32 patch);

	/// Watch this process itself while it is a player in a session: libraries loaded into it from outside, and
	/// its own code being changed in memory. A built game with the anti-cheat on does (see Harden); the editor
	/// does not, because reloading scripts does both of those things on purpose.
	public static bool ProcessChecks;

	/// Closes this process to other programs run by the same user and turns ProcessChecks on. Memory editors and
	/// debuggers attach to a game, or open its memory, to read and change it: after this the system refuses them
	/// (on Linux and Windows; a program run as root or administrator can still get in). A built game whose project
	/// has the anti-cheat on calls this when it starts. Do not call it in something you want to debug.
	public static bool Harden()
	{
		ProcessChecks = true;
		// A way out for looking into a built game with a debugger: TALLOW_HARDEN=off in its environment.
		let choice = scope String();
		Environment.GetEnvironmentVariable("TALLOW_HARDEN", choice).IgnoreError();
		if (choice == "off")
			return false;
		sHardened = tn_guard_harden() != 0;
		return sHardened;
	}

	[CLink] static extern void tn_guard_release();
	static bool sHardened;
	static int32 sMaintainIn;

	/// Called by the application as it shuts down: the process is opened up again so that the libraries it is
	/// closing can finish.
	public static void Release()
	{
		if (sHardened)
			tn_guard_release();
		sHardened = false;
	}

	/// Called every frame by the application. Some libraries a game loads (graphics drivers, sound servers) open
	/// the process up again when they start, so a hardened game keeps closing itself.
	public static void Maintain()
	{
		if (sHardened && --sMaintainIn <= 0)
		{
			sMaintainIn = 20;
			tn_guard_harden();
		}
	}

	/// Master switch. Off, nothing is checked, asked or sent.
	public static bool Enabled;

	static CheatAction[(int)CheatKind.Count] sActions = .(.Kick, .Kick, .Kick, .Kick, .Kick, .Log, .Log, .Log, .Kick, .Log);

	/// What is done about a kind of cheating. The standard choices remove a player for what only a changed game
	/// does (invalid controls, a fast game, floods, different files, no answer, edited memory) and only log what
	/// honest players can also trip (a debugger, a preloaded library, an odd clock, remarkable aim).
	public static void SetAction(CheatKind kind, CheatAction action) => sActions[(int)kind] = action;
	public static CheatAction GetAction(CheatKind kind) => sActions[(int)kind];

	public delegate void ViolationHandler(int32 clientId, CheatKind kind, StringView detail);
	/// Called on the server for everything found (unless its action is Ignore): to show it, keep it, or ban.
	public static Event<ViolationHandler> OnViolation ~ _.Dispose();
	/// The last things found on this machine as a server, newest last. At most 256 are kept.
	public static List<CheatViolation> Violations = new .() ~ DeleteContainerAndItems!(_);
	/// On a player's machine: why the server's anti-cheat removed it, or empty. The game shows this instead of
	/// "connection lost".
	public static String KickReason = new .() ~ delete _;

	// ---- tuning ----

	/// A player's game may run this much faster than the server's before it counts as a speed hack (1.15 = 15%).
	public static float SpeedTolerance = 1.15f;
	/// Messages a second from one player before it counts as a flood. Voice chat's are not counted.
	public static int32 MessageLimit = 240;
	/// Seconds a player's game has to answer the anti-cheat's question in.
	public static float AnswerTime = 12;
	/// Seconds between questions.
	public static float ChallengeEvery = 30;
	/// Aim: hits looked at before judging, and the share of them that may come straight after an instant turn.
	public static int32 AimSampleSize = 20;
	public static float AimSnapShare = 0.5f;
	/// An instant turn: this many degrees or more in one tick.
	public static float AimSnapDegrees = 25;

	// ---- one session's state (a server's, or a player's) ----

	public class Watched
	{
		public int32 id;
		// Speed: the newest tick the player's game has reached, against the server's, a window at a time.
		public uint32 windowStartTick, newestTick;
		public bool haveTick;
		public int32 fastWindows;
		public int32 messages;
		// Integrity.
		public uint32 nonce;
		public float asked = -1, lastAnswered = -1;
		public bool everAnswered;
		public uint32 flags;
		// Aim.
		public float[8] yaw, pitch;
		public int32 looks;
		public int32 shots, hits, headshots, snapHits;
		public float aimFlagged = -1000;
		// On the way out.
		public int32 kickIn = -1;
		public float[(int)CheatKind.Count] lastReported;
	}

	public class Session
	{
		public List<Watched> watched = new .() ~ DeleteContainerAndItems!(_);
		public int32 ticks;
		public float clock;
		// A player's side.
		public uint32 sentFlags = uint32.MaxValue;
		public float checkIn;
		public double engineStart, otherStart;
		public bool haveClocks;
		public int32 oddClocks;
		public int32 codeChecks;
		public bool codeReported;
	}

	static Watched Find(NetworkManager network, int32 clientId)
	{
		let session = network.AntiCheatState;
		if (session == null)
			return null;
		for (let watched in session.watched)
		{
			if (watched.id == clientId)
				return watched;
		}
		return null;
	}

	static bool sRegistered;

	public static void EnsureRegistered()
	{
		if (sRegistered)
			return;
		sRegistered = true;
		NetworkManager.RegisterMessage(MsgAntiCheat, new => OnMessage);
	}

	// ---- for games ----

	/// This game's content as one number: the same on every machine with the same asset pack, whatever the
	/// system. 0 when the game runs from loose files (in the editor), where there is nothing to compare.
	public static uint32 Fingerprint => tn_pack_fingerprint();

	/// Server: reports something the game itself caught (a shot through a wall, a purchase with no money), to be
	/// handled like the engine's own findings: by the action set for its kind.
	public static void Report(int32 clientId, CheatKind kind, StringView detail, NetworkManager session = null)
	{
		let network = session ?? NetworkManager.Dispatching ?? Scene.Active?.Network;
		if (!Enabled || network == null || !network.IsServer)
			return;
		Raise(network, clientId, kind, detail);
	}

	/// Server: a player fired. With ReportHit this lets the anti-cheat look at how they aim.
	public static void ReportShot(int32 clientId, NetworkManager session = null)
	{
		let network = session ?? NetworkManager.Dispatching ?? Scene.Active?.Network;
		if (!Enabled || network == null || !network.IsServer)
			return;
		let watched = Find(network, clientId);
		if (watched != null)
			watched.shots++;
	}

	/// Server: a player's shot hit another player.
	public static void ReportHit(int32 clientId, bool headshot, NetworkManager session = null)
	{
		let network = session ?? NetworkManager.Dispatching ?? Scene.Active?.Network;
		if (!Enabled || network == null || !network.IsServer)
			return;
		let watched = Find(network, clientId);
		if (watched == null)
			return;
		watched.hits++;
		if (headshot)
			watched.headshots++;
		// Did the view jump a long way in one tick just before, and then sit still? Hands turn; they do not jump
		// and stop dead on a head.
		let count = Math.Min(watched.looks, 8);
		float biggest = 0, after = 0;
		for (int back = 1; back < count && back <= 4; back++)
		{
			let now = (watched.looks - back) % 8, before = (watched.looks - back - 1) % 8;
			let step = Math.Sqrt(Math.Pow(Mathf.WrapAngle(watched.yaw[now] - watched.yaw[before]), 2) + Math.Pow(watched.pitch[now] - watched.pitch[before], 2));
			if (step > biggest)
			{
				biggest = step;
				// How much it moved in the tick after the jump (nothing, when the jump is the newest tick).
				after = 0;
				if (back > 1)
				{
					let next = (watched.looks - back + 1) % 8;
					after = Math.Sqrt(Math.Pow(Mathf.WrapAngle(watched.yaw[next] - watched.yaw[now]), 2) + Math.Pow(watched.pitch[next] - watched.pitch[now], 2));
				}
			}
		}
		if (biggest >= AimSnapDegrees && after < 1.5f)
			watched.snapHits++;
		let state = network.AntiCheatState;
		if (watched.hits >= AimSampleSize && state.clock - watched.aimFlagged > 60)
		{
			let snapShare = (float)watched.snapHits / watched.hits;
			let allHeads = watched.shots >= AimSampleSize * 2 && (float)watched.hits / Math.Max(watched.shots, 1) > 0.95f && (float)watched.headshots / watched.hits > 0.85f;
			if (snapShare > AimSnapShare || allHeads)
			{
				watched.aimFlagged = state.clock;
				Raise(network, clientId, .SuspiciousAim, scope $"{watched.hits} hits from {watched.shots} shots, {watched.headshots} to the head, {watched.snapHits} straight after an instant turn");
			}
		}
	}

	/// The numbers behind the aim check for one player, for a game that wants to show or keep them.
	public static void AimStats(int32 clientId, out int32 shots, out int32 hits, out int32 headshots, out int32 snapHits, NetworkManager session = null)
	{
		shots = hits = headshots = snapHits = 0;
		let network = session ?? NetworkManager.Dispatching ?? Scene.Active?.Network;
		let watched = network != null ? Find(network, clientId) : null;
		if (watched == null)
			return;
		shots = watched.shots;
		hits = watched.hits;
		headshots = watched.headshots;
		snapHits = watched.snapHits;
	}

	/// A player's machine: something found here (a guarded value changed) is told to the server.
	public static void ReportLocal(CheatKind kind, StringView detail)
	{
		let network = Scene.Active?.Network;
		if (!Enabled || network == null || network.Mode == .Offline)
			return;
		if (network.IsServer)
		{
			if (network.Mode == .Host)
				Raise(network, 0, kind, detail);
			return;
		}
		let writer = scope NetWriter();
		writer.Write(MessageReport);
		writer.Write((uint8)kind);
		writer.WriteString(detail);
		network.SendToServer(MsgAntiCheat, writer);
	}

	// ---- bans: players the server will not have back ----

	static List<String> sBanned = new .() ~ DeleteContainerAndItems!(_);

	/// Bans are kept by whatever the game knows a player by: a Steam ID, an account name, an address. The game
	/// asks IsBanned when someone joins (and can Kick them); the engine keeps the list.
	public static void Ban(StringView key)
	{
		if (!key.IsEmpty && !IsBanned(key))
			sBanned.Add(new String(key));
	}

	public static void Unban(StringView key)
	{
		for (let entry in sBanned)
		{
			if (entry == key)
			{
				sBanned.Remove(entry);
				delete entry;
				return;
			}
		}
	}

	public static bool IsBanned(StringView key)
	{
		for (let entry in sBanned)
		{
			if (entry == key)
				return true;
		}
		return false;
	}

	/// The ban list as text, one to a line, to save; and back again.
	public static void BansToText(String text)
	{
		for (let entry in sBanned)
			text.AppendF("{}\n", entry);
	}

	public static void BansFromText(StringView text)
	{
		ClearAndDeleteItems!(sBanned);
		for (var line in text.Split('\n'))
		{
			line.Trim();
			Ban(line);
		}
	}

	// ---- what happens when something is found ----

	static StringView Describe(CheatKind kind)
	{
		switch (kind)
		{
		case .InvalidInput: return "controls no unmodified game sends";
		case .SpeedHack: return "the game is running faster than it should (a speed hack)";
		case .MessageFlood: return "a flood of messages";
		case .ModifiedFiles: return "the game's files are not the host's";
		case .NoResponse: return "the game did not answer the anti-cheat";
		case .Debugger: return "a debugger is attached to the game";
		case .InjectedCode: return "a library has been forced into the game";
		case .ClockTampering: return "the game's clock is being changed";
		case .MemoryTampering: return "the game's memory was changed from outside";
		case .SuspiciousAim: return "aim that looks automated";
		default: return "cheating";
		}
	}

	static void Raise(NetworkManager network, int32 clientId, CheatKind kind, StringView detail)
	{
		let action = sActions[(int)kind];
		if (action == .Ignore)
			return;
		let session = network.AntiCheatState;
		let watched = Find(network, clientId);
		// The same thing found again and again is said once every few seconds.
		if (watched != null && session != null)
		{
			if (watched.kickIn >= 0)
				return;
			if (watched.lastReported[(int)kind] > 0 && session.clock - watched.lastReported[(int)kind] < 5)
				return;
			watched.lastReported[(int)kind] = Math.Max(session.clock, 0.001f);
		}
		let violation = new CheatViolation();
		violation.clientId = clientId;
		violation.kind = kind;
		violation.detail.Set(detail);
		violation.time = session != null ? session.clock : 0;
		Violations.Add(violation);
		if (Violations.Count > 256)
		{
			delete Violations[0];
			Violations.RemoveAt(0);
		}
		Log.Warning(scope $"Anti-cheat: client {clientId}: {Describe(kind)}{(detail.IsEmpty ? "" : scope $" ({detail})")}{(action == .Kick ? ". Removing them." : ".")}");
		OnViolation(clientId, kind, detail);
		// The host's own player is not removed from their own game.
		if (action == .Kick && clientId != 0 && watched != null)
		{
			let writer = scope NetWriter();
			writer.Write(MessageNotice);
			writer.WriteString(scope $"Removed by anti-cheat: {Describe(kind)}.");
			network.SendToClient(clientId, MsgAntiCheat, writer);
			// A moment for the reason to arrive.
			watched.kickIn = 30;
		}
	}

	// ---- the engine's side: called by the network manager ----

	static uint32 Proof(uint32 nonce, uint32 fingerprint)
	{
		var hash = nonce ^ 0x9E3779B9;
		hash = (hash ^ fingerprint) * 16777619;
		hash ^= hash >> 13;
		hash = (hash ^ (fingerprint >> 7) ^ (nonce << 5)) * 0x5bd1e995;
		hash ^= hash >> 15;
		return hash;
	}

	static Random sRandom = new .() ~ delete _;

	public static void ClientJoined(NetworkManager network, int32 clientId)
	{
		if (!Enabled)
			return;
		EnsureRegistered();
		if (network.AntiCheatState == null)
			network.AntiCheatState = new Session();
		let watched = new Watched();
		watched.id = clientId;
		network.AntiCheatState.watched.Add(watched);
	}

	public static void ClientLeft(NetworkManager network, int32 clientId)
	{
		let watched = Find(network, clientId);
		if (watched == null)
			return;
		network.AntiCheatState.watched.Remove(watched);
		delete watched;
	}

	/// Server: a packet of controls arrived. newestTick is how far the player's game says it has got.
	public static void NoteInputs(NetworkManager network, int32 clientId, uint32 newestTick)
	{
		if (!Enabled)
			return;
		let watched = Find(network, clientId);
		if (watched == null)
			return;
		if (!watched.haveTick)
		{
			watched.haveTick = true;
			watched.windowStartTick = newestTick;
		}
		if (newestTick > watched.newestTick)
			watched.newestTick = newestTick;
	}

	/// Server: one tick of controls, as it arrived and before the engine tidies it.
	public static void CheckInput(NetworkManager network, int32 clientId, NetInput input)
	{
		if (!Enabled)
			return;
		let watched = Find(network, clientId);
		if (watched == null)
			return;
		if (input.moveX != input.moveX || input.moveZ != input.moveZ || input.yaw != input.yaw || input.pitch != input.pitch)
			Raise(network, clientId, .InvalidInput, "a number that is not a number");
		else if (Math.Abs(input.moveX) > 1.01f || Math.Abs(input.moveZ) > 1.01f)
			Raise(network, clientId, .InvalidInput, scope $"movement of {input.moveX:0.00}, {input.moveZ:0.00}, past full tilt");
		else if (Math.Abs(input.pitch) > 120 || Math.Abs(input.yaw) > 100000)
			Raise(network, clientId, .InvalidInput, "a view angle out of range");
		watched.yaw[watched.looks % 8] = input.yaw;
		watched.pitch[watched.looks % 8] = input.pitch;
		watched.looks++;
	}

	/// Server: a game message arrived from a player.
	public static void NoteMessage(NetworkManager network, int32 clientId, uint8 messageId)
	{
		if (!Enabled || messageId == VoiceChat.MsgVoice)
			return;
		let watched = Find(network, clientId);
		if (watched != null)
			watched.messages++;
	}

	/// Once a tick, from the network manager.
	public static void Tick(NetworkManager network)
	{
		if (!Enabled || network.Mode == .Offline)
			return;
		EnsureRegistered();
		if (network.AntiCheatState == null)
			network.AntiCheatState = new Session();
		let session = network.AntiCheatState;
		session.ticks++;
		session.clock += Time.FixedDeltaTime;
		if (network.IsServer)
			ServerTick(network, session);
		// The host's own machine is the one doing the judging: it is not asked about itself.
		if (!network.IsServer)
			PlayerTick(network, session);
	}

	static void ServerTick(NetworkManager network, Session session)
	{
		// Players on their way out go first.
		for (let watched in session.watched)
		{
			if (watched.kickIn > 0 && --watched.kickIn == 0)
			{
				network.Kick(watched.id);
				return;
			}
		}
		let second = session.ticks % 60 == 0;
		for (let watched in session.watched)
		{
			if (watched.kickIn >= 0)
				continue;
			if (second)
			{
				if (watched.messages > MessageLimit)
					Raise(network, watched.id, .MessageFlood, scope $"{watched.messages} messages in a second");
				watched.messages = 0;
			}
			// Speed: every five seconds, how many ticks did their game get through for our three hundred?
			if (session.ticks % 300 == 0 && watched.haveTick)
			{
				let ratio = (float)(watched.newestTick - watched.windowStartTick) / 300;
				watched.windowStartTick = watched.newestTick;
				watched.fastWindows = ratio > SpeedTolerance ? watched.fastWindows + 1 : 0;
				// Twice running: one burst after a hitch is not a speed hack.
				if (watched.fastWindows >= 2)
				{
					watched.fastWindows = 0;
					Raise(network, watched.id, .SpeedHack, scope $"running at {ratio * 100:0}% speed");
				}
			}
			// The question, every so often; and whether the last one was answered in time.
			if (watched.asked < 0 || (watched.lastAnswered >= watched.asked && session.clock - watched.asked > ChallengeEvery))
			{
				watched.nonce = (uint32)sRandom.NextI32() | 1;
				watched.asked = session.clock;
				let writer = scope NetWriter();
				writer.Write(MessageChallenge);
				writer.Write(watched.nonce);
				network.SendToClient(watched.id, MsgAntiCheat, writer);
			}
			else if (watched.lastAnswered < watched.asked && session.clock - watched.asked > AnswerTime)
			{
				watched.lastAnswered = session.clock;
				Raise(network, watched.id, .NoResponse, "");
			}
		}
	}

	static void PlayerTick(NetworkManager network, Session session)
	{
		// Twice a second: what the system says about this process, and whether the two clocks still agree.
		if (--session.checkIn > 0)
			return;
		session.checkIn = 30;
		let stageWas = Watchdog.Stage;
		defer
		{
			Watchdog.Stage = stageWas;
		}
		Watchdog.Stage = "anti-cheat: looking for a debugger and comparing clocks";
		var flags = TestFlags != 0 ? TestFlags : tn_guard_environment();
		double engine = 0, other = 0;
		tn_guard_clocks(&engine, &other);
		if (!session.haveClocks)
		{
			session.haveClocks = true;
			session.engineStart = engine;
			session.otherStart = other;
		}
		else if (other - session.otherStart >= 5)
		{
			// Five seconds by the clock nobody touches: how many by the clock the game runs on?
			let ratio = (engine - session.engineStart) / (other - session.otherStart);
			session.engineStart = engine;
			session.otherStart = other;
			session.oddClocks = (ratio > 1.08 || ratio < 0.92) ? session.oddClocks + 1 : 0;
		}
		if (session.oddClocks >= 2)
			flags |= FlagClock;
		if (ProcessChecks)
		{
			// A library that was not here before, from somewhere neither the system's nor the game's come from.
			Watchdog.Stage = "anti-cheat: listing the libraries loaded into the game";
			let module = tn_guard_new_module();
			if (module != null)
			{
				var name = StringView(module);
				let slash = Math.Max(name.LastIndexOf('/'), name.LastIndexOf('\\'));
				if (slash >= 0)
					name = name.Substring(slash + 1);
				ReportLocal(.InjectedCode, scope $"{name} was loaded into the game");
			}
			// Every few seconds: is the program's own code still what was loaded?
			Watchdog.Stage = "anti-cheat: checking the game's own code";
			if (++session.codeChecks % 6 == 0 && !session.codeReported && tn_guard_code_changed() != 0)
			{
				session.codeReported = true;
				ReportLocal(.MemoryTampering, "the game's own code was changed in memory");
			}
		}
		if (flags == session.sentFlags)
			return;
		session.sentFlags = flags;
		// Told to the server along with the next answer; and now, if something has just appeared.
		if (flags != 0)
		{
			let writer = scope NetWriter();
			writer.Write(MessageAnswer);
			writer.Write((uint32)0);
			writer.Write((uint32)0);
			writer.Write(flags);
			network.SendToServer(MsgAntiCheat, writer);
		}
	}

	/// For tests: what a player's machine claims the system says (debugger 1, injected library 2, clock 4), and
	/// whether it answers questions at all, and with what fingerprint (0: its real one).
	public static uint32 TestFlags;
	public static bool TestSilent;
	public static uint32 TestFingerprint;

	static void NoteFlags(NetworkManager network, int32 clientId, uint32 flags)
	{
		let watched = Find(network, clientId);
		let before = watched != null ? watched.flags : 0;
		if (watched != null)
			watched.flags = flags;
		let appeared = flags & ~before;
		if ((appeared & FlagDebugger) != 0)
			Raise(network, clientId, .Debugger, "");
		if ((appeared & FlagInjected) != 0)
			Raise(network, clientId, .InjectedCode, "");
		if ((appeared & FlagClock) != 0)
			Raise(network, clientId, .ClockTampering, "");
	}

	static void OnMessage(int32 sender, ref NetReader reader)
	{
		let network = NetworkManager.Dispatching ?? Scene.Active?.Network;
		let kind = reader.Read<uint8>();
		if (network == null || !reader.Ok)
			return;
		if (!network.IsServer)
		{
			// A player's machine: the server's question, or the reason for being removed.
			if (kind == MessageChallenge)
			{
				let nonce = reader.Read<uint32>();
				if (!reader.Ok || !Enabled || TestSilent)
					return;
				let fingerprint = TestFingerprint != 0 ? TestFingerprint : Fingerprint;
				let writer = scope NetWriter();
				writer.Write(MessageAnswer);
				writer.Write(nonce);
				// The fingerprint never travels: only what it makes of the server's number, and whether there is one.
				writer.Write(fingerprint != 0 ? Proof(nonce, fingerprint) : (uint32)0);
				writer.Write(network.AntiCheatState != null && network.AntiCheatState.sentFlags != uint32.MaxValue ? network.AntiCheatState.sentFlags : (TestFlags != 0 ? TestFlags : tn_guard_environment()));
				network.SendToServer(MsgAntiCheat, writer);
			}
			else if (kind == MessageNotice)
			{
				let reason = scope String();
				reader.ReadString(reason);
				if (reader.Ok)
				{
					KickReason.Set(reason);
					Log.Warning(reason);
				}
			}
			return;
		}
		if (!Enabled)
			return;
		let watched = Find(network, sender);
		if (watched == null)
			return;
		if (kind == MessageAnswer)
		{
			let nonce = reader.Read<uint32>();
			let proof = reader.Read<uint32>();
			let flags = reader.Read<uint32>();
			if (!reader.Ok)
				return;
			NoteFlags(network, sender, flags);
			// An answer to the question that was asked (0 is only news of what the system says).
			if (nonce == 0 || nonce != watched.nonce)
				return;
			watched.lastAnswered = network.AntiCheatState.clock;
			watched.everAnswered = true;
			// Compared only when both sides run from a pack: a game run from loose files has nothing to compare.
			let mine = Fingerprint;
			if (mine != 0 && proof != 0 && proof != Proof(nonce, mine))
				Raise(network, sender, .ModifiedFiles, "");
			else if (mine != 0 && proof == 0)
				Raise(network, sender, .ModifiedFiles, "it is running from loose files, not the game's asset pack");
		}
		else if (kind == MessageReport)
		{
			let reported = (int32)reader.Read<uint8>();
			let detail = scope String();
			reader.ReadString(detail);
			// A player's game only reports on itself, and only what is found on a player's machine.
			if (reader.Ok && (reported == (int32)CheatKind.MemoryTampering || reported == (int32)CheatKind.InjectedCode))
				Raise(network, sender, (CheatKind)reported, detail);
		}
	}
}

/// A whole number that notices being changed from outside the game. Memory editors find a value by searching for
/// it and then write over it; this keeps the number scrambled, so that it is not found by its value, and keeps a
/// check beside it, so that a write is caught: the anti-cheat is told (MemoryTampering) and the last good value
/// comes back. For numbers a player's machine is trusted with: ammunition, money or health in a game where the
/// server does not decide them. (Where the server decides, nothing on a player's machine needs guarding.)
///
///   GuardedInt coins = 100;
///   coins += 5;
///   int32 shown = coins;
struct GuardedInt
{
	int32 mScrambled;
	int32 mCheck;
	int32 mKey;

	public this(int32 value)
	{
		mKey = (int32)(sKeySource = sKeySource * 1103515245 + 12345) | 0x10001;
		mScrambled = value ^ mKey;
		mCheck = ~(value * 31 + mKey);
	}

	static uint32 sKeySource = 0x6B8B4567;

	public int32 Value
	{
		get
		{
			let value = mScrambled ^ mKey;
			if (mCheck != ~(value * 31 + mKey))
			{
				AntiCheat.ReportLocal(.MemoryTampering, "a guarded number was changed");
				// What the check says it was: the check holds the value too.
				return ((~mCheck) - mKey) / 31;
			}
			return value;
		}
		set mut
		{
			mScrambled = value ^ mKey;
			mCheck = ~(value * 31 + mKey);
		}
	}

	/// Whether the stored number still matches its check, without reporting anything.
	public bool Intact => mCheck == ~((mScrambled ^ mKey) * 31 + mKey);

	public static implicit operator int32(GuardedInt guarded) => guarded.Value;
	public static implicit operator GuardedInt(int32 value) => .(value);
	public static GuardedInt operator +(GuardedInt a, int32 b) => .(a.Value + b);
	public static GuardedInt operator -(GuardedInt a, int32 b) => .(a.Value - b);
}

/// GuardedInt for a number with a fraction.
struct GuardedFloat
{
	GuardedInt mBits;

	public this(float value)
	{
		var copy = value;
		mBits = .(*(int32*)&copy);
	}

	public float Value
	{
		get
		{
			var bits = mBits.Value;
			return *(float*)&bits;
		}
		set mut
		{
			var copy = value;
			mBits.Value = *(int32*)&copy;
		}
	}

	public bool Intact => mBits.Intact;

	public static implicit operator float(GuardedFloat guarded) => guarded.Value;
	public static implicit operator GuardedFloat(float value) => .(value);
	public static GuardedFloat operator +(GuardedFloat a, float b) => .(a.Value + b);
	public static GuardedFloat operator -(GuardedFloat a, float b) => .(a.Value - b);
}
