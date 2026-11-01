using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace PhysicsPredictionTests;

/// A player that is a solid box, moved by its controls: it shoves the crates it walks into.
[Component]
class Pusher : NetworkBehaviour
{
	public static Vector2 HostMove, ClientMove;
	public static bool ClientShoots;
	public static GameObject CrateOnHost;
	public static bool ShotChecked, CrateStayedPut;

	public override void GatherInput(ref NetInput input)
	{
		let move = IsServer ? HostMove : ClientMove;
		input.moveX = move.x;
		input.moveZ = move.y;
		input.SetButton(0, !IsServer && ClientShoots);
	}

	public override void Simulate(NetInput input, float deltaTime)
	{
		Transform.Position += Vector3(input.moveX, 0, input.moveZ) * 3 * deltaTime;
		// A shot at a crate: lag compensation must leave predicted bodies where they are, since the player saw them
		// where they are now.
		if (input.GetButton(0) && IsServer && Identity.ownerId != 0 && !ShotChecked && CrateOnHost != null)
		{
			let before = CrateOnHost.Transform.Position;
			let rewound = BeginLagCompensation();
			CrateStayedPut = rewound && CrateOnHost.Transform.Position == before;
			EndLagCompensation();
			ShotChecked = true;
		}
	}
}

/// Carries a crate round in a circle on the server alone, as a stuck grenade rides on a player.
[Component]
class Carrier : Component
{
	public bool carrying;
	int32 mTicks;
	public override void FixedUpdate()
	{
		if (!carrying || !Scene.Network.IsServer)
			return;
		mTicks++;
		let body = GetComponent<Rigidbody>();
		var state = body.State;
		state.position = .(Math.Cos(mTicks * 0.05f) * 2 + 3, 2.5f, Math.Sin(mTicks * 0.05f) * 2 - 8);
		state.linearVelocity = .Zero;
		state.angularVelocity = .Zero;
		body.SetState(state);
	}
}

class Program
{
	static int sFailures;
	static void Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
	}

	static GameObject MakeCrate(Scene scene)
	{
		let crate = scene.CreateGameObject("Crate");
		crate.AddComponent<NetworkIdentity>();
		crate.AddComponent<BoxCollider>().size = .(1, 1, 1);
		crate.AddComponent<Rigidbody>().mass = 2;
		crate.AddComponent<Carrier>();
		return crate;
	}

	static GameObject MakePlayer(Scene scene)
	{
		let player = scene.CreateGameObject("Player");
		player.AddComponent<NetworkIdentity>();
		player.AddComponent<BoxCollider>().size = .(0.8f, 1.6f, 0.8f);
		player.AddComponent<Rigidbody>().isKinematic = true;
		player.AddComponent<Pusher>();
		return player;
	}

	/// The same level on every machine: a floor, a row of crates and a stack of three.
	static void Build(Scene scene)
	{
		let floor = scene.CreateGameObject("Floor");
		floor.Transform.Position = .(0, -0.5f, 0);
		floor.AddComponent<BoxCollider>().size = .(60, 1, 60);
		for (int i < 3)
		{
			let crate = MakeCrate(scene);
			crate.Name.Set(scope $"Row{i}");
			crate.Transform.Position = .(i * 3 - 3, 0.5f, 4);
		}
		for (int i < 3)
		{
			let crate = MakeCrate(scene);
			crate.Name.Set(scope $"Stack{i}");
			crate.Transform.Position = .(8, 0.5f + i * 1.01f, -4);
		}
		scene.StartPlay();
	}

	static List<Scene> sScenes = new .() ~ delete _;

	/// Ticks both machines at a steady pace, so that the simulated lag is a fixed number of ticks.
	static void Pump(int ticks)
	{
		for (int i < ticks)
		{
			for (let scene in sScenes)
			{
				scene.FixedUpdate();
				scene.Update();
			}
			Thread.Sleep(8);
		}
	}

	static float Apart(Scene a, Scene b, StringView name)
	{
		return (a.Find(name).Transform.Position - b.Find(name).Transform.Position).Length;
	}

	static float WorstApart(Scene a, Scene b)
	{
		float worst = 0;
		for (let name in StringView[?]("Row0", "Row1", "Row2", "Stack0", "Stack1", "Stack2"))
			worst = Math.Max(worst, Apart(a, b, name));
		return worst;
	}

	static bool AllAsleep(Scene scene)
	{
		for (let name in StringView[?]("Row0", "Row1", "Row2", "Stack0", "Stack1", "Stack2"))
		{
			if (!scene.Find(name).GetComponent<Rigidbody>().IsSleeping)
				return false;
		}
		return true;
	}

	public static int Main(String[] args)
	{
		Time.DeltaTime = Time.FixedDeltaTime;
		NetworkManager.RegisterPrefab("Crate", new => MakeCrate);
		NetworkManager.RegisterPrefab("Pusher", new => MakePlayer);
		let port = (uint16)(48000 + (DateTime.Now.Ticks / 10000) % 900);
		NetworkManager.SimulatedLagMs = 40;

		let host = scope Scene();
		Build(host);
		host.Network = new NetworkManager(host);
		Check(host.Network.StartServer(port, true), "host starts");
		sScenes.Add(host);
		let client = scope Scene();
		Build(client);
		client.Network = new NetworkManager(client);
		client.Network.StartClient("127.0.0.1", port);
		sScenes.Add(client);
		Pump(120);
		Check(client.Network.IsConnected && host.Network.ClientCount == 1, "client connects over a lagging connection (40 ms each way)");

		let clientId = client.Network.LocalClientId;
		host.Network.Spawn("Pusher", .(-12, 0.8f, 4), .Identity, 0);
		host.Network.Spawn("Pusher", .(-12, 0.8f, -4), .Identity, clientId);
		Pump(120);
		GameObject ownPlayer = null, hostPlayerOnClient = null;
		for (let identity in client.Network.Identities)
		{
			if (identity.GameObject.GetComponent<Pusher>() != null)
			{
				if (identity.ownerId == clientId)
					ownPlayer = identity.GameObject;
				else
					hostPlayerOnClient = identity.GameObject;
			}
		}
		let row1 = client.Find("Row1").GetComponent<NetworkIdentity>();
		Check(row1.Predicted && client.Find("Stack2").GetComponent<NetworkIdentity>().Predicted && client.Network.PredictedBodies == 6, scope $"the server's crates are predicted on the client ({client.Network.PredictedBodies} bodies)");
		Check(ownPlayer != null && hostPlayerOnClient != null && !hostPlayerOnClient.GetComponent<NetworkIdentity>().Predicted && !ownPlayer.GetComponent<NetworkIdentity>().Predicted, "players are not: the host's has a script the client cannot run, and the client's own is predicted as ever");
		Check(row1.GetComponent<Rigidbody>().IsSleeping && AllAsleep(client), "crates at rest stay asleep on the client");

		// ---- a crate dropped from high up lands on the stack: physics alone, which the client gets right ----
		let rollbacks = client.Network.Rollbacks;
		let dropped = host.Network.Spawn("Crate", .(8.2f, 9, -4), Quaternion.Euler(20, 30, 10), 0);
		Pump(30);
		let adopted = client.Network.Rollbacks;
		Pump(240);
		let droppedOnClient = client.Find("Crate");
		Check(droppedOnClient != null && droppedOnClient.GetComponent<NetworkIdentity>().Predicted, "a crate spawned on the server is predicted from its first snapshot");
		Check(client.Network.Rollbacks - adopted <= 1, scope $"it falls, tumbles onto the stack and settles with {client.Network.Rollbacks - adopted} correction(s) after it is taken up ({adopted - rollbacks} on taking it up)");
		if (droppedOnClient != null)
			Check((droppedOnClient.Transform.Position - dropped.Transform.Position).Length < 0.01f, scope $"and it comes to rest where the server has it ({(droppedOnClient.Transform.Position - dropped.Transform.Position).Length:0.0000} apart)");

		// ---- the client's own player shoves a crate: it moves on the client at once ----
		let crateHost = host.Find("Row1");
		let crateClient = client.Find("Row1");
		let crateStart = crateHost.Transform.Position;
		let beforeShove = client.Network.Rollbacks;
		Pusher.ClientMove = .(1, 1);
		int clientMovedAt = -1, hostMovedAt = -1;
		for (int tick < 360)
		{
			Pump(1);
			if (clientMovedAt < 0 && (crateClient.Transform.Position - crateStart).Length > 0.002f)
				clientMovedAt = tick;
			if (hostMovedAt < 0 && (crateHost.Transform.Position - crateStart).Length > 0.002f)
				hostMovedAt = tick;
			// Heading for Row1 at (0, 0.5, 4) from (-12, 0.8, -4): turn along the row once level with it.
			if (ownPlayer.Transform.Position.z > 3.6f)
				Pusher.ClientMove = .(1, 0);
			if (ownPlayer.Transform.Position.x > 2.5f)
				Pusher.ClientMove = .(0, 0);
		}
		Check(clientMovedAt >= 0 && hostMovedAt >= 0 && clientMovedAt < hostMovedAt, scope $"a crate the client's player walks into moves on the client first (tick {clientMovedAt}, on the server tick {hostMovedAt})");
		Check(client.Network.Rollbacks - beforeShove <= 1, scope $"and the server agrees with the client about the shove ({client.Network.Rollbacks - beforeShove} corrections)");
		Pump(240);
		Check(WorstApart(host, client) < 0.001f, scope $"once the shoving is over, every crate is where the server has it (worst {WorstApart(host, client):0.0000} apart)");
		Check(AllAsleep(client) == AllAsleep(host), "and the crates sleep on the client as they do on the server");

		// ---- the host's player shoves a crate: the client finds out late, goes back and puts it right ----
		let corrections = client.Network.Rollbacks;
		Pusher.HostMove = .(1, 0);
		Pump(330);
		Pusher.HostMove = .(0, 0);
		Pump(240);
		Check(host.Find("Row0").Transform.Position.x > -2.0f && client.Network.Rollbacks > corrections, scope $"a crate another player shoves is corrected on the client ({client.Network.Rollbacks - corrections} corrections)");
		Check(WorstApart(host, client) < 0.001f, scope $"and ends up where the server has it (worst {WorstApart(host, client):0.0000} apart)");

		// ---- a poor connection: the client knocks the stack over while packets go missing ----
		NetworkManager.SimulatedLossPercent = 10;
		NetworkManager.SimulatedJitterMs = 6;
		Pusher.ClientMove = .(0, -1);
		for (int tick = 0; tick < 600 && ownPlayer.Transform.Position.z > -4.2f; tick++)
			Pump(1);
		Pusher.ClientMove = .(1, 0);
		Pump(200);
		Pusher.ClientMove = .(0, 0);
		let knocked = host.Find("Stack2").Transform.Position.y < 2;
		NetworkManager.SimulatedLossPercent = 0;
		NetworkManager.SimulatedJitterMs = 0;
		Pump(300);
		Check(knocked && WorstApart(host, client) < 0.001f, scope $"on a lossy, uneven connection the client knocks a stack over and the crates end up where the server has them (worst {WorstApart(host, client):0.0000} apart)");

		// ---- a crate the server carries about by script: tried, found wrong every time, shown in the past ----
		let carried = host.Find("Row2").GetComponent<Carrier>();
		let carriedOnClient = client.Find("Row2").GetComponent<NetworkIdentity>();
		let beforeCarry = client.Network.Rollbacks;
		carried.carrying = true;
		Pump(30);
		let pausedSoon = !carriedOnClient.Predicted;
		Pump(270);
		let carryCorrections = client.Network.Rollbacks - beforeCarry;
		let followed = (carriedOnClient.Transform.Position - carried.Transform.Position).Length < 1.0f;
		carried.carrying = false;
		Pump(400);
		Check(pausedSoon && carryCorrections <= 12 && followed, scope $"a crate a server script carries about is shown in the past after a few corrections ({carryCorrections} in five seconds)");
		Check(carriedOnClient.Predicted && WorstApart(host, client) < 0.001f, "and predicted again once it is left to physics, ending where the server has it");

		// ---- lag compensation ----
		Pusher.CrateOnHost = host.Find("Stack0");
		Pusher.ClientShoots = true;
		Pump(30);
		Pusher.ClientShoots = false;
		Pump(10);
		Check(Pusher.ShotChecked && Pusher.CrateStayedPut, "lag compensation leaves predicted bodies where they are: the player saw them there");

		// ---- what it costs ----
		Pump(120);
		Check(host.Network.BytesSentPerSecond < 900, scope $"with everything at rest little is sent ({host.Network.BytesSentPerSecond} bytes a second to the client)");

		// ---- switched off on the server, bodies are shown in the past again ----
		host.Network.PredictPhysics = false;
		Pump(30);
		Check(!row1.Predicted && client.Network.PredictedBodies == 0, "with PredictPhysics off on the server, the client shows the crates in the past again");
		host.Network.PredictPhysics = true;
		client.Network.PredictPhysics = false;
		Pump(30);
		Check(!row1.Predicted, "and a client with it off does the same");
		// A crate at rest is mentioned again within 40 snapshots (two seconds).
		client.Network.PredictPhysics = true;
		Pump(150);
		Check(row1.Predicted, "turned back on, they are predicted again");

		Console.WriteLine(sFailures == 0 ? "ALL PASSED" : scope $"{sFailures} FAILED");
		NetworkManager.SimulatedLagMs = 0;
		client.Network.Stop();
		host.Network.Stop();
		return sFailures == 0 ? 0 : 1;
	}
}
