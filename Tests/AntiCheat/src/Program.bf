using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace AntiCheatTests;

[Component]
class Walker : NetworkScript
{
	public override void OnTick(TickInput input, float deltaTime)
	{
		Transform.Position += input.MoveDirection * 4 * deltaTime;
	}
}

/// The anti-cheat against a real loopback session: an honest player, and then one cheat at a time.
/// run.py builds the asset packs the file checks need:
///   AntiCheatTests <pack> <the same content, packed again with an engine file added> <one asset changed> <a library to inject>
class Program
{
	[CLink] static extern int32 system(char8* command);
	[CLink] static extern void* dlopen(char8* path, int32 flags);

	static bool Check(bool condition, StringView what)
	{
		Console.WriteLine(scope $"{(condition ? "PASS" : "FAIL")}: {what}");
		return condition;
	}

	static GameObject CreatePlayer(Scene scene)
	{
		let player = scene.CreateGameObject("Player");
		player.AddComponent<NetworkIdentity>();
		player.AddComponent<Walker>().mouseLook = false;
		return player;
	}

	static Scene sHost;
	static List<Scene> sClients = new .() ~ delete _;
	/// How many steps each player's game takes for one of the server's: 2 is a speed hack.
	static int sClientSpeed = 1;

	static void Pump(int ticks)
	{
		for (int i < ticks)
		{
			sHost.FixedUpdate();
			sHost.Update();
			for (let scene in sClients)
			{
				for (int step < sClientSpeed)
					scene.FixedUpdate();
				scene.Update();
			}
			Thread.Sleep(1);
		}
	}

	static Scene Join(uint16 port)
	{
		let scene = new Scene();
		scene.StartPlay();
		scene.Network = new NetworkManager(scene);
		scene.Network.PlayerPrefab.Set("TestPlayer");
		scene.Network.StartClient("127.0.0.1", port);
		sClients.Add(scene);
		Pump(120);
		return scene;
	}

	static void Leave(Scene scene)
	{
		sClients.Remove(scene);
		scene.Network.Stop();
		Pump(30);
		delete scene.Network;
		scene.Network = null;
		delete scene;
	}

	static List<(int32 client, CheatKind kind)> sSeen = new .() ~ delete _;
	static int Seen(CheatKind kind)
	{
		int count = 0;
		for (let entry in sSeen)
		{
			if (entry.kind == kind)
				count++;
		}
		return count;
	}

	static GameObject PlayerOf(Scene scene, int32 owner)
	{
		for (let identity in scene.Network.Identities)
		{
			if (identity.ownerId == owner && identity.GetComponent<Walker>() != null)
				return identity.GameObject;
		}
		return null;
	}

	public static int Main(String[] args)
	{
		if (args.Count < 4)
		{
			Console.WriteLine("Run Tests/AntiCheat/run.py, which makes the asset packs this needs.");
			return 1;
		}
		bool ok = true;
		Time.DeltaTime = Time.FixedDeltaTime;
		Audio.NoDevice = true;
		NetworkManager.RegisterPrefab("TestPlayer", new => CreatePlayer);
		NetworkManager.RegisterMessage(200, new (sender, reader) => { });
		AntiCheat.OnViolation.Add(new (client, kind, detail) => sSeen.Add((client, kind)));
		let port = (uint16)(48000 + (DateTime.Now.Ticks / 10000) % 900);

		// ---- guarded values need no session ----
		GuardedInt coins = 100;
		coins += 25;
		coins = coins - 5;
		ok &= Check((int32)coins == 120 && coins.Intact, "a guarded number adds, subtracts and reads like a number");
		let raw = (int32*)&coins;
		bool findable = raw[0] == 120 || raw[1] == 120 || raw[2] == 120;
		raw[0] ^= 0x55;
		ok &= Check(!findable && !coins.Intact && (int32)coins == 120, "it is not stored as itself, a write from outside is noticed, and the real value survives");
		GuardedFloat health = 75.5f;
		health = health - 0.5f;
		ok &= Check((float)health == 75.0f && health.Intact, "a guarded number with a fraction works the same way");

		// ---- bans ----
		AntiCheat.Ban("76561190000000001");
		AntiCheat.Ban("10.0.0.7");
		let bans = scope String();
		AntiCheat.BansToText(bans);
		AntiCheat.Unban("10.0.0.7");
		ok &= Check(AntiCheat.IsBanned("76561190000000001") && !AntiCheat.IsBanned("10.0.0.7") && !AntiCheat.IsBanned("someone else"), "players can be banned and unbanned by whatever the game knows them by");
		AntiCheat.BansFromText(bans);
		ok &= Check(AntiCheat.IsBanned("10.0.0.7") && AntiCheat.IsBanned("76561190000000001"), "and the list is saved and loaded as text");

		// ---- the same game on two systems has one fingerprint ----
		ok &= Check(AntiCheat.Fingerprint == 0, "a game run from loose files has no fingerprint");
		AssetPack.Mount(args[0], "/game");
		let fingerprint = AntiCheat.Fingerprint;
		AssetPack.UnmountAll();
		AssetPack.Mount(args[1], "/elsewhere");
		let repacked = AntiCheat.Fingerprint;
		AssetPack.UnmountAll();
		AssetPack.Mount(args[2], "/game");
		let changed = AntiCheat.Fingerprint;
		AssetPack.UnmountAll();
		ok &= Check(fingerprint != 0 && repacked == fingerprint && changed != fingerprint && changed != 0, "the same assets packed twice (with different engine files, in another folder) match; one changed asset does not");

		// ---- a session ----
		sHost = scope Scene();
		sHost.StartPlay();
		sHost.Network = new NetworkManager(sHost);
		sHost.Network.PlayerPrefab.Set("TestPlayer");
		ok &= Check(sHost.Network.StartServer(port, true), "host starts");

		// Off: nothing is watched.
		var player = Join(port);
		let off = sHost.Network.AntiCheatState == null && sSeen.IsEmpty && player.Network.IsConnected;
		Leave(player);
		ok &= Check(off, "with the anti-cheat off nothing is watched and nobody is asked anything");

		AntiCheat.Enabled = true;
		AntiCheat.AnswerTime = 2;
		AntiCheat.ChallengeEvery = 3;

		// An honest player.
		player = Join(port);
		Input.SimulateKey(.W, true);
		Input.SimulateEnd();
		Pump(700);
		Input.SimulateKey(.W, false);
		Input.SimulateEnd();
		let honestId = player.Network.LocalClientId;
		let honestDistance = PlayerOf(sHost, honestId).Transform.Position.Length;
		ok &= Check(player.Network.IsConnected && sSeen.IsEmpty && AntiCheat.Violations.IsEmpty && honestDistance > 20, "an honest player plays for ten seconds, is asked and answers, and nothing is found");
		Leave(player);

		// Controls no honest game sends. The packet is written by hand, as a changed game would.
		player = Join(port);
		{
			let net = player.Network;
			let writer = net.[Friend]mWriter;
			// Controls are packed so that movement past full tilt cannot even be written down; a view angle
			// bent right over backwards still can, by a game that has been tampered with.
			writer.Clear();
			writer.Write((uint8)4);
			writer.Write(net.[Friend]mTick + 1);
			writer.Write((uint8)1);
			writer.Write((uint16)0);
			writer.Write((uint8)0);
			writer.Write((int8)127);
			writer.Write((int8)127);
			writer.Write((int16)0);
			writer.Write((int16)(150 * 65536 / 360));
			writer.Write((uint16)0);
			net.[Friend]Send(net.[Friend]mServerPeer, false);
		}
		Pump(150);
		ok &= Check(Seen(.InvalidInput) == 1 && !player.Network.IsConnected && AntiCheat.KickReason.Contains("anti-cheat") && sHost.Network.ClientCount == 0, "an impossible view angle is caught: the player is told why and removed");
		Leave(player);
		AntiCheat.KickReason.Clear();

		// A speed hack: the player's game takes two steps for each of the server's.
		player = Join(port);
		let fastId = player.Network.LocalClientId;
		Input.SimulateKey(.W, true);
		Input.SimulateEnd();
		sClientSpeed = 2;
		Pump(500);
		let fastPlayer = PlayerOf(sHost, fastId);
		let fastDistance = fastPlayer != null ? fastPlayer.Transform.Position.Length : 0;
		Pump(400);
		sClientSpeed = 1;
		Input.SimulateKey(.W, false);
		Input.SimulateEnd();
		ok &= Check(fastDistance > 0 && fastDistance < 500.0f / 60 * 4 * 1.1f, "a game running at double speed moves its player no faster on the server");
		ok &= Check(Seen(.SpeedHack) == 1 && !player.Network.IsConnected, "and is caught as a speed hack and removed");
		Leave(player);

		// A flood of messages.
		player = Join(port);
		for (int burst < 10)
		{
			for (int i < 60)
				player.Network.SendToServer(200, scope NetWriter());
			Pump(5);
		}
		Pump(120);
		ok &= Check(Seen(.MessageFlood) == 1 && !player.Network.IsConnected, "hundreds of messages in a second are caught as a flood");
		Leave(player);

		// A game that does not answer.
		AntiCheat.TestSilent = true;
		player = Join(port);
		Pump(260);
		AntiCheat.TestSilent = false;
		ok &= Check(Seen(.NoResponse) == 1 && !player.Network.IsConnected, "a game that does not answer the anti-cheat's question is removed");
		Leave(player);

		// What the player's system says: logged by default, not a reason to remove anyone.
		AntiCheat.TestFlags = 1 | 2;
		player = Join(port);
		Pump(200);
		ok &= Check(Seen(.Debugger) == 1 && Seen(.InjectedCode) == 1 && player.Network.IsConnected, "a debugger and a forced-in library are reported to the server and logged, and the player stays");
		Leave(player);
		AntiCheat.SetAction(.Debugger, .Kick);
		player = Join(port);
		Pump(200);
		AntiCheat.TestFlags = 0;
		ok &= Check(Seen(.Debugger) == 2 && !player.Network.IsConnected, "unless the game chooses to remove players for it");
		AntiCheat.SetAction(.Debugger, .Log);
		Leave(player);

		// Files: both sides from a pack now.
		AssetPack.Mount(args[0], "/game");
		player = Join(port);
		Pump(300);
		ok &= Check(Seen(.ModifiedFiles) == 0 && player.Network.IsConnected, "a player with the server's files is let be");
		Leave(player);
		AntiCheat.TestFingerprint = changed;
		player = Join(port);
		Pump(300);
		AntiCheat.TestFingerprint = 0;
		ok &= Check(Seen(.ModifiedFiles) == 1 && !player.Network.IsConnected, "a player whose files differ is removed");
		Leave(player);
		AssetPack.UnmountAll();

		// Aim. The server is shown the view tick by tick, then told of hits.
		player = Join(port);
		let aimId = player.Network.LocalClientId;
		NetInput look = default;
		float yaw = 0;
		for (int hit < 30)
		{
			// A hand: the view sweeps a few degrees a tick onto the target.
			for (int tick < 6)
			{
				yaw += 4;
				look.yaw = yaw;
				AntiCheat.CheckInput(sHost.Network, aimId, look);
			}
			AntiCheat.ReportShot(aimId, sHost.Network);
			AntiCheat.ReportShot(aimId, sHost.Network);
			AntiCheat.ReportHit(aimId, hit % 4 == 0, sHost.Network);
		}
		ok &= Check(Seen(.SuspiciousAim) == 0, "thirty hits from an aim that sweeps onto its targets raise nothing");
		Leave(player);
		player = Join(port);
		let botId = player.Network.LocalClientId;
		yaw = 0;
		for (int hit < 30)
		{
			// An aimbot: still, then ninety degrees in one tick, dead on, and a hit.
			for (int tick < 5)
			{
				look.yaw = yaw;
				AntiCheat.CheckInput(sHost.Network, botId, look);
			}
			yaw += 90;
			look.yaw = yaw;
			AntiCheat.CheckInput(sHost.Network, botId, look);
			AntiCheat.ReportShot(botId, sHost.Network);
			AntiCheat.ReportHit(botId, true, sHost.Network);
		}
		AntiCheat.AimStats(botId, let shots, let hits, let headshots, let snaps, sHost.Network);
		Pump(60);
		ok &= Check(Seen(.SuspiciousAim) == 1 && shots == 30 && hits == 30 && headshots == 30 && snaps == 30 && player.Network.IsConnected, "thirty hits each straight after an instant quarter turn are flagged, and by default only logged");
		// Something the game itself caught.
		AntiCheat.Report(botId, .MemoryTampering, "bought something with no money", sHost.Network);
		Pump(120);
		ok &= Check(Seen(.MemoryTampering) == 1 && !player.Network.IsConnected, "the game can report what it catches itself, and the same rules apply");
		Leave(player);

		// ---- the process itself ----
		// Another program of the same user can look into this one until it is hardened.
		let pid = (int)Platform.BfpProcess_GetCurrentId();
		let peek = scope $"python3 -c \"open('/proc/{pid}/mem','rb').close()\" 2>/dev/null";
		let openBefore = system(peek.CStr()) == 0;
		let hardened = AntiCheat.Harden();
		let openAfter = system(peek.CStr()) == 0;
		ok &= Check(openBefore && hardened && !openAfter, "hardening closes the game's memory to other programs of the same user");

		// A library loaded into the game from a place neither the system's nor the game's come from.
		player = Join(port);
		Pump(90);
		let injected = dlopen(args[3].CStr(), 2);
		Pump(150);
		ok &= Check(injected != null && Seen(.InjectedCode) == 2 && player.Network.IsConnected, "a library loaded into the running game from outside is reported (and by default logged)");
		// The game's own code written over in memory, as a hook or patch does.
		let patched = AntiCheat.tn_guard_test_patch(1) != 0;
		Pump(500);
		AntiCheat.tn_guard_test_patch(0);
		ok &= Check(patched && Seen(.MemoryTampering) == 2 && !player.Network.IsConnected, "a change to the game's own code in memory is caught, and the player removed");
		Leave(player);
		AntiCheat.ProcessChecks = false;

		ok &= Check(AntiCheat.Violations.Count == sSeen.Count && AntiCheat.Violations.Count >= 9, "everything found is kept for the game to show");
		sHost.Network.Stop();
		delete sHost.Network;
		sHost.Network = null;
		Console.WriteLine(ok ? "ALL PASSED" : "FAILED");
		return ok ? 0 : 1;
	}
}
