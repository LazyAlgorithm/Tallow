using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace NetworkTests;

/// Gameplay state the server owns and clients should see.
[Component]
class Health : Component
{
	[Sync] public int32 health = 100;
	[Sync] public String title = new .("Rookie") ~ delete _;
	public int32 localOnly = 1;
}

/// A player written the easy way: only what happens in a tick.
[Component]
class Walker : NetworkScript
{
	public float speed = 4;
	public int32 jumps;
	public override void OnTick(TickInput input, float deltaTime)
	{
		Transform.Position += input.MoveDirection * speed * deltaTime;
		if (input.Pressed(.Jump) && !IsReplaying)
			jumps++;
		// A "shot": note where the other player is, as the shooter saw them.
		if (input.Pressed(.Use) && !IsReplaying && Identity.ownerId != 0)
		{
			if (IsServer)
			{
				TruthBefore = TargetOnHost.Transform.Position;
				Rewound = BeginLagCompensation();
				SeenByServer = TargetOnHost.Transform.Position;
				EndLagCompensation();
				TruthAfter = TargetOnHost.Transform.Position;
			}
			else
				SeenByClient = TargetOnClient.Transform.Position;
		}
	}

	public static GameObject TargetOnHost, TargetOnClient;
	public static Vector3 SeenByServer, SeenByClient, TruthBefore, TruthAfter;
	public static bool Rewound;
}

/// Counts the network events it is told about.
[Component]
class EventCounter : Component
{
	public int32 count;
	public float last;
	public String lastName = new .() ~ delete _;
	public override void OnNetworkEvent(StringView name, float value)
	{
		count++;
		last = value;
		lastName.Set(name);
	}
}

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	const String cFolder = "/tmp/tallow-network-test";

	/// The same scene on every machine, as if loaded from one file.
	static void Build(Scene scene)
	{
		let voxels = scene.CreateGameObject("Boulder");
		voxels.AddComponent<VoxelObject>();
		let bot = scene.CreateGameObject("Bot");
		bot.AddComponent<NavigationAgent>();
		bot.AddComponent<Health>();
		let prop = scene.CreateGameObject("Prop");
		prop.Transform.Position = .(20, 5, 0);
		prop.AddComponent<CharacterController>();
		let crate = scene.CreateGameObject("Crate");
		crate.Transform.Position = .(0, 50, 30);
		crate.AddComponent<BoxCollider>();
		crate.AddComponent<Rigidbody>().useGravity = false;
		scene.CreateGameObject("Scenery");
		let terrain = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
		terrain.mode = .Endless;
		terrain.viewDistance = 1;
		terrain.generateColliders = false;
		let red = scene.CreateGameObject("RedSpawn");
		red.Transform.Position = .(40, 0, 0);
		red.Transform.Rotation = Quaternion.Euler(0, 90, 0);
		red.AddComponent<SpawnPoint>().team = 1;
		let blue = scene.CreateGameObject("BlueSpawn");
		blue.Transform.Position = .(-40, 0, 0);
		blue.AddComponent<SpawnPoint>().team = 2;
		// Switched on and off, lit and puffed while playing.
		scene.CreateGameObject("Sign");
		scene.CreateGameObject("Door").AddComponent<BoxCollider>();
		let lamp = scene.CreateGameObject("Lamp").AddComponent<Light>();
		lamp.type = .Point;
		let sparks = scene.CreateGameObject("Sparks").AddComponent<ParticleSystem>();
		sparks.looping = false;
		sparks.rate = 0;
		sparks.burst = 10;
		sparks.lifetime = 0.2f;
		scene.StartPlay();
	}

	static GameObject CreatePlayer(Scene scene)
	{
		let player = scene.CreateGameObject("Player");
		player.AddComponent<NetworkIdentity>();
		let walker = player.AddComponent<Walker>();
		walker.mouseLook = false;
		// A torch, part of the player as it is spawned.
		let torch = scene.CreateGameObject("Torch", player.Transform);
		torch.AddComponent<Light>().type = .Spot;
		return player;
	}

	/// True if a point lies on the way from one place to another, give or take a few centimetres.
	static bool Between(Vector3 point, Vector3 from, Vector3 to)
	{
		let along = to - from;
		let amount = along.LengthSquared > 0 ? Vector3.Dot(point - from, along) / along.LengthSquared : 0;
		return amount > -0.1f && amount < 1.1f && (from + along * Mathf.Clamp01(amount) - point).Length < 0.05f;
	}

	static List<Scene> sScenes = new .() ~ delete _;
	static void Pump(int ticks)
	{
		for (int i < ticks)
		{
			for (let scene in sScenes)
			{
				scene.FixedUpdate();
				scene.Update();
			}
			Thread.Sleep(1);
		}
	}

	static void Join(Scene scene, uint16 port)
	{
		scene.Network = new NetworkManager(scene);
		scene.Network.PlayerPrefab.Set("TestPlayer");
		scene.Network.StartClient("127.0.0.1", port);
		sScenes.Add(scene);
	}

	static GameObject PlayerOf(Scene scene, int32 owner)
	{
		for (let identity in scene.Network.Identities)
		{
			if (identity.ownerId == owner && identity.GetComponent<Walker>() != null) return identity.GameObject;
		}
		return null;
	}

	public static int Main(String[] args)
	{
		Directory.CreateDirectory(cFolder).IgnoreError();
		Assets.ProjectPath.Set(cFolder);
		Time.DeltaTime = Time.FixedDeltaTime;
		bool ok = true;
		NetworkManager.RegisterPrefab("TestPlayer", new => CreatePlayer);
		// A prefab file with a Network Identity (shared when instantiated) and one without (local).
		{
			let maker = scope Scene();
			let shared = maker.CreateGameObject("Pickup");
			shared.AddComponent<NetworkIdentity>();
			shared.AddComponent<Health>();
			Prefab.Save(shared, scope $"{cFolder}/Pickup.tprefab");
			let local = maker.CreateGameObject("Spark");
			Prefab.Save(local, scope $"{cFolder}/Spark.tprefab");
		}
		let port = (uint16)(47000 + (DateTime.Now.Ticks / 10000) % 900);
		let host = scope Scene();
		Build(host);
		let client = scope Scene();
		Build(client);
		List<Scene> owned = scope .();

		// ---- the engine's own message ids: each kind of message has one to itself ----
		{
			uint8[?] ids = .(NetworkSync.MsgTerrainBrush, NetworkSync.MsgVoxelCarve, NetworkSync.MsgCharacterShape, NetworkSync.MsgAnimation, NetworkSync.MsgField, NetworkSync.MsgAudio,
				NetworkSync.MsgEvent, NetworkSync.MsgAnimator, NetworkSync.MsgMaterial, NetworkSync.MsgDialogue, NetworkSync.MsgSequence, AntiCheat.MsgAntiCheat, VoiceChat.MsgVoice, MapSharing.MsgMap, NetworkSync.MsgRope, NetworkSync.MsgSoftBody);
			bool distinct = true;
			for (int i < ids.Count)
			{
				distinct &= ids[i] >= 240;
				for (int j < i)
					distinct &= ids[i] != ids[j];
			}
			ok &= Check(distinct, "the engine's message ids are all different, and all 240 or above");
		}

		// ---- a body's motion record (RemoteSnapshotFormat.QuantizedBody) ----
		{
			let writer = scope NetWriter();
			BodyState moving = default;
			moving.position = .(1.23456f, -0.5f, 30);
			moving.rotation = Quaternion.Euler(20, 75, -10).Normalized;
			moving.linearVelocity = .(0.004f, -2.5f, 0.75f);
			moving.angularVelocity = .(-12, 0.3f, 0);
			NetPack.WriteMotion(writer, moving);
			BodyState resting = default;
			resting.position = .(500, 0, 0);
			resting.rotation = .Identity;
			NetPack.WriteMotion(writer, resting);
			var reader = NetReader(writer.Data.Ptr, writer.Data.Count);
			let flags = reader.Read<uint8>();
			let back = NetPack.ReadMotion(ref reader, flags);
			let farFlags = reader.Read<uint8>();
			let far = NetPack.ReadMotion(ref reader, farFlags);
			ok &= Check(writer.Data.Count < 2 * 30 && (back.position - moving.position).Length < 1.0e-4f && Math.Abs(Quaternion.Dot(back.rotation, moving.rotation)) > 0.9999f
				&& (back.linearVelocity - moving.linearVelocity).Length < 1.0e-3f && (back.angularVelocity - moving.angularVelocity).Length < 1.0e-3f, "a body's motion record is small and keeps its position, turn and both velocities");
			ok &= Check(reader.Ok && (farFlags & NetPack.FlagExactTransform) != 0 && far.position == resting.position && far.linearVelocity == .Zero && far.angularVelocity == .Zero, "far out it carries exact floats, and a resting body's velocities take a byte each");
		}

		// ---- offline first: nothing below needs a session ----
		{
			let alone = scope Scene();
			let solo = alone.CreateGameObject("Boulder").AddComponent<VoxelObject>();
			alone.StartPlay();
			ok &= Check(solo.Carve(solo.Transform.Position, 0.4f), "carving works with no session at all");
		}
		ok &= Check(Prefab.Instantiate(host, "Pickup.tprefab") != null && host.Find("Bot").GetComponent<NetworkIdentity>() == null, "offline, prefabs are local and nothing is given a network identity");
		host.DestroyImmediate(host.Find("Pickup"));

		host.Network = new NetworkManager(host);
		host.Network.PlayerPrefab.Set("TestPlayer");
		host.Network.TeamCount = 2;
		ok &= Check(host.Network.StartServer(port, true), "host starts");
		sScenes.Add(host);
		owned.Add(host);
		owned.Add(client);
		Join(client, port);
		Pump(120);
		ok &= Check(client.Network.IsConnected && host.Network.ClientCount == 1 && client.Network.LocalClientId > 0, "client connects over loopback");
		if (!ok) return 1;
		let clientId = client.Network.LocalClientId;

		// ---- scene objects that move on their own are shared without setup ----
		ok &= Check(host.Find("Bot").GetComponent<NetworkIdentity>() != null && client.Find("Prop").GetComponent<NetworkIdentity>() != null && client.Find("Crate").GetComponent<NetworkIdentity>() != null && host.Find("Scenery").GetComponent<NetworkIdentity>() == null, "AI, controllers and bodies get an identity; plain scenery does not");
		host.Find("Bot").Transform.Position = .(7, 0, 3);
		Pump(40);
		ok &= Check((client.Find("Bot").Transform.Position - Vector3(7, 0, 3)).Length < 0.05f, "an object the server moves is moved on the client");
		client.Find("Bot").GetComponent<NavigationAgent>().SetDestination(.(1, 0, 1), 3, 0.1f);
		ok &= Check(NetworkSync.IsClientOf(client) && !NetworkSync.IsClientOf(host) && client.Find("Bot").GetComponent<NavigationAgent>().Path.Count == 0, "agents think on the server only");

		// ---- [Sync] fields ----
		let hostHealth = host.Find("Bot").GetComponent<Health>();
		let clientHealth = client.Find("Bot").GetComponent<Health>();
		hostHealth.health = 42;
		hostHealth.title.Set("Veteran");
		hostHealth.localOnly = 9;
		Pump(30);
		ok &= Check(clientHealth.health == 42 && clientHealth.title == "Veteran" && clientHealth.localOnly == 1, "[Sync] fields follow the server; other fields stay local");

		// ---- the easy player script ----
		let hostCopy = PlayerOf(host, clientId);
		let ownCopy = PlayerOf(client, clientId);
		ok &= Check(hostCopy != null && ownCopy != null && PlayerOf(client, 0) != null, "each player has their object on both machines");
		// Spawn points and teams: the host joined team 1 and the client team 2, each at their team's point.
		let hostPlayer = PlayerOf(host, 0);
		ok &= Check(hostPlayer.GetComponent<NetworkIdentity>().team == 1 && (hostPlayer.Transform.Position - Vector3(40, 0, 0)).Length < 0.1f && Math.Abs(hostPlayer.Transform.Forward.x - 1) < 0.01f, "the host's player appears at its team's spawn point, facing its way");
		ok &= Check(hostCopy.GetComponent<NetworkIdentity>().team == 2 && (hostCopy.Transform.Position - Vector3(-40, 0, 0)).Length < 0.1f, "the next player joins the other team, at that team's point");
		ok &= Check(ownCopy.GetComponent<NetworkIdentity>().team == 2 && PlayerOf(client, 0).GetComponent<NetworkIdentity>().team == 1 && (ownCopy.Transform.Position - Vector3(-40, 0, 0)).Length < 0.2f, "every machine knows each player's team and place");
		let before = hostCopy.Transform.Position;
		Input.SimulateKey(.W, true);
		Input.SimulateEnd();
		Pump(90);
		Input.SimulateKey(.W, false);
		Input.SimulateEnd();
		Pump(40);
		let moved = hostCopy.Transform.Position - before;
		ok &= Check(moved.z > 3 && Math.Abs(moved.x) < 0.01f, "a tick script moves its player on the server from the client's controls");
		ok &= Check((ownCopy.Transform.Position - hostCopy.Transform.Position).Length < 0.2f && (PlayerOf(client, 0).Transform.Position - PlayerOf(host, 0).Transform.Position).Length < 0.2f, "and both machines agree where both players are");
		Input.SimulateKey(.Space, true);
		Input.SimulateEnd();
		Pump(3);
		Input.SimulateKey(.Space, false);
		Input.SimulateEnd();
		Pump(30);
		ok &= Check(hostCopy.GetComponent<Walker>().jumps == 1 && ownCopy.GetComponent<Walker>().jumps == 1, "a press counts once on each machine");

		// ---- smooth and small: a client predicts only its own objects, the rest glide, and little is sent ----
		{
			Pump(130);
			let idleDown = host.Network.BytesSentPerSecond;
			let idleUp = client.Network.BytesSentPerSecond;
			ok &= Check(idleDown > 0 && idleDown < 600 && idleUp > 0 && idleUp < 1300, scope $"with nothing happening little is sent ({idleDown} bytes a second to the client, {idleUp} from it)");
			let rollbacks = client.Network.Rollbacks;
			let hostOnClient = PlayerOf(client, 0);
			Input.SimulateKey(.W, true);
			Input.SimulateEnd();
			Pump(40);
			float smallest = float.MaxValue, largest = 0;
			var last = hostOnClient.Transform.Position;
			for (int i < 60)
			{
				Pump(1);
				let now = hostOnClient.Transform.Position;
				smallest = Math.Min(smallest, (now - last).Length);
				largest = Math.Max(largest, (now - last).Length);
				last = now;
			}
			let movingDown = host.Network.BytesSentPerSecond;
			let movingUp = client.Network.BytesSentPerSecond;
			Input.SimulateKey(.W, false);
			Input.SimulateEnd();
			Pump(40);
			ok &= Check(client.Network.Rollbacks == rollbacks, "other players moving does not make a client go back and run its ticks again");
			let perTick = 4.0f / 60;
			ok &= Check(smallest > perTick * 0.6f && largest < perTick * 1.4f, scope $"another player moves evenly on a client, not in jumps at each snapshot (steps of {smallest:0.000} to {largest:0.000}; {perTick:0.000} on the server)");
			ok &= Check(movingDown < 2600 && movingUp < 1300, scope $"with both players running, {movingDown} bytes a second go to the client and {movingUp} come from it");
			ok &= Check((hostOnClient.Transform.Position - PlayerOf(host, 0).Transform.Position).Length < 0.01f, "and once they stop, the client has them where the server does to within the packing");

			// Lag compensation: the server judges a shot against where the shooter saw the target.
			Walker.TargetOnHost = PlayerOf(host, 0);
			Walker.TargetOnClient = hostOnClient;
			Input.SimulateKey(.W, true);
			Input.SimulateEnd();
			Pump(60);
			Input.SimulateKey(.E, true);
			Input.SimulateEnd();
			Pump(3);
			Input.SimulateKey(.E, false);
			Input.SimulateEnd();
			Pump(20);
			Input.SimulateKey(.W, false);
			Input.SimulateEnd();
			Pump(40);
			let apart = (Walker.SeenByServer - Walker.SeenByClient).Length;
			let behind = (Walker.SeenByServer - Walker.TruthBefore).Length;
			ok &= Check(Walker.Rewound && apart < 0.03f && behind > 0.2f && Walker.TruthAfter == Walker.TruthBefore, scope $"lag compensation shows the server a moving target where the shooter saw it ({apart:0.000} from it, {behind:0.00} behind where it really was) and puts it back");
			ok &= Check(!PlayerOf(host, 0).GetComponent<Walker>().BeginLagCompensation() && !PlayerOf(client, clientId).GetComponent<Walker>().BeginLagCompensation(), "and does nothing for the host's own player, on a client, or outside a player's tick");

			// What goes over the wire is packed, and comes back as it went.
			Vector3 place;
			Quaternion turn;
			let tilted = Quaternion.Euler(20, 130, -45);
			NetPack.Unpack(NetPack.Pack(.(12.3456f, -7.25f, 300.001f), tilted), out place, out turn);
			bool packs = (place - Vector3(12.3456f, -7.25f, 300.001f)).Length < 0.002f && Math.Abs(Quaternion.Dot(turn, tilted)) > 0.99999f;
			let far = NetPack.Pack(.(20000, 5, -99999.5f), Quaternion.Euler(0, 77, 0));
			NetPack.Unpack(far, out place, out turn);
			packs &= place == Vector3(20000, 5, -99999.5f) && (far.flags & NetPack.FlagWide) != 0 && (far.flags & NetPack.FlagYawOnly) != 0 && Math.Abs(Quaternion.Dot(turn, Quaternion.Euler(0, 77, 0))) > 0.999999f;
			let writer = scope NetWriter();
			NetPack.Write(writer, NetPack.Pack(.(1, 2, 3), Quaternion.Euler(0, 45, 0)));
			packs &= writer.Data.Count == 12;
			NetInput raw = default;
			raw.moveX = 0.3337f;
			raw.moveZ = -1;
			raw.yaw = 725.123f;
			raw.pitch = -42.42f;
			raw.SetButton(3, true);
			raw.SetButton(15, true);
			let rounded = NetPack.Quantize(raw);
			writer.Clear();
			NetPack.WriteInput(writer, rounded, default, false);
			NetPack.WriteInput(writer, rounded, rounded, true);
			var reader = NetReader(writer.Data.Ptr, writer.Data.Count);
			let first = NetPack.ReadInput(ref reader, default);
			let second = NetPack.ReadInput(ref reader, first);
			packs &= writer.Data.Count == 10 && reader.Ok && first.moveX == rounded.moveX && first.moveZ == rounded.moveZ && first.yaw == rounded.yaw && first.pitch == rounded.pitch && first.buttons == rounded.buttons && second.yaw == first.yaw && second.buttons == first.buttons;
			packs &= Math.Abs(rounded.moveX - 0.3337f) < 0.005f && Math.Abs(Mathf.WrapAngle(rounded.yaw - 725.123f)) < 0.006f && Math.Abs(rounded.pitch + 42.42f) < 0.006f;
			ok &= Check(packs, "positions, rotations and controls survive being packed small (12 bytes for an object, 9 for a tick of controls, 1 for a repeat)");

			// A bad connection: a fifth of the packets lost, the rest arriving unevenly.
			NetworkManager.SimulatedLossPercent = 20;
			NetworkManager.SimulatedJitterMs = 6;
			Input.SimulateKey(.W, true);
			Input.SimulateEnd();
			Pump(150);
			let mid = (PlayerOf(client, clientId).Transform.Position - PlayerOf(host, clientId).Transform.Position).Length;
			Input.SimulateKey(.W, false);
			Input.SimulateEnd();
			Pump(90);
			NetworkManager.SimulatedLossPercent = 0;
			NetworkManager.SimulatedJitterMs = 0;
			Pump(150);
			ok &= Check(mid < 0.5f && (PlayerOf(client, clientId).Transform.Position - PlayerOf(host, clientId).Transform.Position).Length < 0.05f && (PlayerOf(client, 0).Transform.Position - PlayerOf(host, 0).Transform.Position).Length < 0.05f, scope $"on a lossy, uneven connection the client stays with the server ({mid:0.00} apart while running) and ends up agreeing with it");
		}

		// ---- voxels ----
		let hostBoulder = host.Find("Boulder").GetComponent<VoxelObject>();
		let clientBoulder = client.Find("Boulder").GetComponent<VoxelObject>();
		int Solid(VoxelObject v)
		{
			int n = 0;
			for (let d in v.[Friend]mDensity)
				n += d;
			return n;
		}
		let full = Solid(clientBoulder);
		hostBoulder.Carve(hostBoulder.Transform.Position + .(0.3f, 0, 0), 0.4f);
		Pump(20);
		let afterHost = Solid(clientBoulder);
		ok &= Check(afterHost != full && afterHost == Solid(hostBoulder), "a carve on the server happens on the client");
		let asked = clientBoulder.Carve(clientBoulder.Transform.Position - .(0.3f, 0, 0), 0.4f);
		ok &= Check(!asked && Solid(clientBoulder) == afterHost, "a carve on a client waits for the server");
		Pump(20);
		ok &= Check(Solid(clientBoulder) != afterHost && Solid(clientBoulder) == Solid(hostBoulder), "then happens on both");

		// Cut the boulder in two on the server: the piece that breaks off must be the same object everywhere.
		for (float y = -2; y <= 2; y += 0.4f)
		{
			for (float z = -2; z <= 2; z += 0.4f)
				hostBoulder.Carve(hostBoulder.Transform.TransformPoint(.(0, y, z)), 0.45f);
		}
		// A client predicts a server-owned body, running a little ahead of the server as it does with its own
		// player, so a falling piece should be where the server is about to have it.
		Pump(32);
		List<NetworkIdentity> hostPieces = scope .();
		List<NetworkIdentity> clientPieces = scope .();
		for (let identity in host.Network.Identities)
		{
			if (identity.GameObject.Name == "Fragment")
				hostPieces.Add(identity);
		}
		Pump(8);
		for (let identity in client.Network.Identities)
		{
			if (identity.GameObject.Name == "Fragment")
				clientPieces.Add(identity);
		}
		bool samePieces = hostPieces.Count > 0 && hostPieces.Count == clientPieces.Count;
		for (let piece in hostPieces)
		{
			NetworkIdentity twin = null;
			for (let candidate in clientPieces)
			{
				if (candidate.NetId == piece.NetId)
					twin = candidate;
			}
			let soon = piece.Transform.Position + piece.GetComponent<Rigidbody>().State.linearVelocity * (Time.FixedDeltaTime * 4);
			samePieces &= twin != null && twin.Predicted && Solid(twin.GetComponent<VoxelObject>()) == Solid(piece.GetComponent<VoxelObject>()) && Between(twin.Transform.Position, piece.Transform.Position, soon);
		}
		ok &= Check(samePieces && Solid(clientBoulder) == Solid(hostBoulder), scope $"pieces that break off are the same objects and shapes on both, and the client predicts their fall ({hostPieces.Count} piece(s))");
		if (hostPieces.Count > 0)
		{
			// A fragment can be carved in turn, by a client, and stays identical.
			NetworkIdentity twin = null;
			for (let candidate in clientPieces)
			{
				if (candidate.NetId == hostPieces[0].NetId)
					twin = candidate;
			}
			let pieceVoxels = twin.GetComponent<VoxelObject>();
			let was = Solid(pieceVoxels);
			for (float y = -2; y <= 2; y += 0.5f)
			{
				for (float z = -2; z <= 2; z += 0.5f)
				{
					for (float x = -2; x <= 2; x += 0.5f)
					{
						if (Solid(pieceVoxels) == was || true)
							pieceVoxels.Carve(pieceVoxels.Transform.TransformPoint(.(x, y, z)), 0.2f);
					}
				}
			}
			Pump(40);
			let hostVoxels = hostPieces[0].GetComponent<VoxelObject>();
			ok &= Check(hostPieces[0].GameObject.IsDestroyed == twin.GameObject.IsDestroyed && (hostPieces[0].GameObject.IsDestroyed || (Solid(hostVoxels) != was && Solid(hostVoxels) == Solid(pieceVoxels))), "a client carving a fragment changes the same fragment on the server");
		}

		// ---- voxel terrain ----
		// Compares the edited chunks of two terrains sample by sample.
		bool SameTerrain(VoxelTerrain a, VoxelTerrain b, out int edited)
		{
			edited = 0;
			bool same = true;
			for (let chunk in a.[Friend]mChunks.Values)
			{
				if (!chunk.edited || !chunk.generated) continue;
				edited++;
				if (!b.[Friend]mChunks.TryGetValue(chunk.coord, let other) || !other.generated)
				{
					same = false;
					continue;
				}
				for (int i < chunk.density.Count)
				{
					if (chunk.density[i] != other.density[i])
					{
						same = false;
						break;
					}
				}
			}
			return same;
		}
		let hostTerrain = host.Find("Terrain").GetComponent<VoxelTerrain>();
		let clientTerrain = client.Find("Terrain").GetComponent<VoxelTerrain>();
		for (int wait = 0; wait < 400 && (hostTerrain.PendingChunks > 0 || clientTerrain.PendingChunks > 0 || hostTerrain.[Friend]mChunks.Count == 0); wait++)
			Pump(5);
		let ground = Vector3(4, 0, 4);
		for (int i < 10)
			hostTerrain.Brush(ground + .(i * 0.5f, 0, 0), 5, 0.4f, (i % 2) == 0 ? VoxelBrush.Lower : VoxelBrush.Raise);
		hostTerrain.Brush(ground, 6, 0.5f, .Smooth);
		hostTerrain.Brush(ground, 4, 1, .Paint, 3);
		Pump(40);
		let hostSame = SameTerrain(hostTerrain, clientTerrain, let hostEdited);
		ok &= Check(hostEdited > 0 && hostSame, scope $"terrain brushed on the server is identical on the client ({hostEdited} chunk(s) edited)");
		clientTerrain.ModifySphere(ground + .(0, 0, 3), 4, -0.6f);
		let clientBefore = SameTerrain(clientTerrain, hostTerrain, let unused1);
		Pump(40);
		ok &= Check(clientBefore && SameTerrain(hostTerrain, clientTerrain, let unused2) && SameTerrain(clientTerrain, hostTerrain, let unused3), "a client digging goes through the server and both end up identical");
		// A stroke somewhere neither machine has loaded is kept, and applied when that chunk streams in.
		hostTerrain.Brush(.(4, 0, 4000), 6, 1, .Lower);
		Pump(20);
		ok &= Check(clientTerrain.[Friend]mSessionBrushes.Count == hostTerrain.[Friend]mSessionBrushes.Count && hostTerrain.[Friend]mSessionBrushes.Count == 14, "strokes on chunks that are not loaded are remembered on every machine");

		// ---- audio ----
		{
			// A one-second tone, so there is something to play.
			List<uint8> wav = scope .();
			void U32(uint32 v)
			{
				for (int sh = 0; sh < 32; sh += 8)
					wav.Add((uint8)(v >> sh));
			}
			void U16(uint16 v)
			{
				wav.Add((uint8)v);
				wav.Add((uint8)(v >> 8));
			}
			void Tag(StringView t)
			{
				for (let c in t.RawChars)
					wav.Add((uint8)c);
			}
			Tag("RIFF");
			U32(36 + 48000 * 2);
			Tag("WAVE");
			Tag("fmt ");
			U32(16);
			U16(1);
			U16(1);
			U32(48000);
			U32(96000);
			U16(2);
			U16(16);
			Tag("data");
			U32(48000 * 2);
			for (int i < 48000)
				U16((uint16)(int16)(Math.Sin(i * 0.05f) * 8000));
			File.WriteAll(scope $"{cFolder}/tone.wav" , wav).IgnoreError();
			Audio.NoDevice = true;
			let hostRadio = host.Find("Bot").AddComponent<AudioSource>();
			let clientRadio = client.Find("Bot").AddComponent<AudioSource>();
			hostRadio.playOnStart = false;
			clientRadio.playOnStart = false;
			hostRadio.loop = true;
			clientRadio.loop = true;
			hostRadio.Play("tone.wav");
			Pump(20);
			ok &= Check(hostRadio.IsPlaying && clientRadio.IsPlaying && clientRadio.audioClip == "tone.wav", "a sound started on the server plays on the client");
			hostRadio.Stop();
			Pump(20);
			ok &= Check(!clientRadio.IsPlaying, "and stops there when the server stops it");
			clientRadio.Play();
			Pump(20);
			ok &= Check(clientRadio.IsPlaying && !hostRadio.IsPlaying, "a client playing a sound on an object it does not control keeps it to itself");
			clientRadio.Stop();
			File.Delete(scope $"{cFolder}/tone.wav").IgnoreError();
		}

		// ---- animator controller ----
		{
			let made = scope AnimatorController();
			made.AddParameter("speed", .Float);
			made.AddParameter("hit", .Trigger);
			made.AddState("Idle", "none");
			made.AddState("Run", "none");
			made.AddState("Hurt", "none");
			let go = made.AddTransition(0, 1);
			made.AddCondition(go, "speed", .Greater, 0.5f);
			go.duration = 0;
			let hurt = made.AddTransition(-1, 2);
			made.AddCondition(hurt, "hit", .If);
			hurt.duration = 0;
			made.Save(scope $"{cFolder}/bot.tcontroller");
			let hostAnimator = host.Find("Bot").AddComponent<Animator>();
			let clientAnimator = client.Find("Bot").AddComponent<Animator>();
			hostAnimator.controller.Set("bot.tcontroller");
			clientAnimator.controller.Set("bot.tcontroller");
			hostAnimator.Bind();
			clientAnimator.Bind();
			Pump(20);
			ok &= Check(hostAnimator.CurrentState == "Idle" && clientAnimator.CurrentState == "Idle", "an Animator's starting state is the same on the server and the client");
			hostAnimator.SetFloat("speed", 2);
			Pump(20);
			ok &= Check(clientAnimator.GetFloat("speed") == 2 && hostAnimator.CurrentState == "Run" && clientAnimator.CurrentState == "Run", "a parameter set on the server reaches the client, which follows the server into the new state");
			clientAnimator.SetTrigger("hit");
			Pump(20);
			ok &= Check(hostAnimator.CurrentState == "Run" && clientAnimator.CurrentState == "Run", "a client setting parameters on an object it does not own changes nothing for anyone else, and does not change state itself");
			hostAnimator.SetTrigger("hit");
			Pump(20);
			ok &= Check(hostAnimator.CurrentState == "Hurt" && clientAnimator.CurrentState == "Hurt", "a trigger on the server moves every machine to the same state");
			File.Delete(scope $"{cFolder}/bot.tcontroller").IgnoreError();
		}

		// ---- materials ----
		{
			Material.Create("Materials/red.tmat").color = .(1, 0, 0, 1);
			Material.Create("Materials/blue.tmat").color = .(0, 0, 1, 1);
			let hostSkin = host.Find("Bot").AddComponent<MeshRenderer>();
			let clientSkin = client.Find("Bot").AddComponent<MeshRenderer>();
			hostSkin.SetMaterial("Materials/red.tmat");
			Pump(20);
			ok &= Check(clientSkin.material == "Materials/red.tmat" && clientSkin.ActiveMaterial != null && clientSkin.ActiveMaterial.color.r == 1, "a material given to an object on the server is used on the client");
			hostSkin.SetMaterialColor("color", .(0, 1, 0, 1));
			hostSkin.SetMaterialFloat("heat", 0.75f);
			Pump(20);
			ok &= Check(clientSkin.ActiveMaterial.color.g == 1 && clientSkin.ActiveMaterial.color.r == 0 && clientSkin.ActiveMaterial.GetFloat("heat") == 0.75f && Material.Load("Materials/red.tmat").color.r == 1, "values set on that object's own material follow, and the shared material is left alone");
			clientSkin.SetMaterial("Materials/blue.tmat");
			clientSkin.SetMaterialFloat("heat", 9);
			Pump(20);
			ok &= Check(hostSkin.material == "Materials/red.tmat" && hostSkin.ActiveMaterial.GetFloat("heat") == 0.75f, "a client changing the material of an object it does not own changes it for nobody else");
		}

		// ---- network events ----
		{
			let hostBell = host.Find("Bot").AddComponent<EventCounter>();
			let clientBell = client.Find("Bot").AddComponent<EventCounter>();
			hostBell.SendNetworkEvent("ring", 3);
			Pump(20);
			ok &= Check(hostBell.count == 1 && clientBell.count == 1 && clientBell.last == 3 && clientBell.lastName == "ring", "an event sent by the server runs on the server and on the client");
			clientBell.SendNetworkEvent("ring", 9);
			Pump(20);
			ok &= Check(hostBell.count == 1 && clientBell.count == 1, "a client cannot raise events on an object it does not own");
			let mineOnClient = PlayerOf(client, client.Network.LocalClientId);
			let mineOnHost = PlayerOf(host, client.Network.LocalClientId);
			if (mineOnClient != null && mineOnHost != null)
			{
				let a = mineOnClient.AddComponent<EventCounter>();
				let b = mineOnHost.AddComponent<EventCounter>();
				a.SendNetworkEvent("wave", 2);
				Pump(20);
				ok &= Check(a.count == 1 && b.count == 1 && b.last == 2 && NetworkSync.IsMine(a) && !NetworkSync.IsMine(clientBell) && NetworkSync.IsMine(hostBell), "but can on its own character, and everyone is told");
			}
			else
				ok &= Check(false, "the client has a character to send events from");
		}

		// ---- character controller shape ----
		let hostProp = host.Find("Prop").GetComponent<CharacterController>();
		let clientProp = client.Find("Prop").GetComponent<CharacterController>();
		ok &= Check(hostProp.SetBox(.(1.2f, 0.8f, 1.2f), 0.1f), "the server changes a character's shape");
		Pump(20);
		ok &= Check(clientProp.shape == .Box && clientProp.boxSize == Vector3(1.2f, 0.8f, 1.2f) && clientProp.HasCharacter, "and the client's copy becomes the same shape");
		let ownController = ownCopy.AddComponent<CharacterController>();
		let serverController = hostCopy.AddComponent<CharacterController>();
		ownController.Start();
		serverController.Start();
		ok &= Check(ownController.SetCapsule(0.2f, 0.9f), "a client changes the shape of the character it controls");
		Pump(20);
		ok &= Check(serverController.shape == .Capsule && serverController.radius == 0.2f && serverController.height == 0.9f, "and the server follows");
		clientProp.SetCapsule(0.3f, 1.0f);
		Pump(20);
		ok &= Check(hostProp.shape == .Box && clientProp.shape == .Box && clientProp.boxSize == Vector3(1.2f, 0.8f, 1.2f), "a client cannot reshape a character it does not control: the server puts it back");

		// ---- prefabs and destroying ----
		let pickup = Prefab.Instantiate(host, "Pickup.tprefab", .(3, 1, 3), .Identity);
		let refused = Prefab.Instantiate(client, "Pickup.tprefab", .(9, 9, 9), .Identity);
		let spark = Prefab.Instantiate(client, "Spark.tprefab");
		Pump(20);
		let arrived = client.Find("Pickup");
		ok &= Check(pickup != null && arrived != null && (arrived.Transform.Position - Vector3(3, 1, 3)).Length < 0.01f, "a prefab with a network identity instantiated on the server appears on the client");
		ok &= Check(refused == null && spark != null, "on a client such a prefab is left to the server; a plain prefab is created locally");
		pickup.GetComponent<Health>().health = 7;
		Pump(20);
		ok &= Check(arrived.GetComponent<Health>().health == 7, "[Sync] fields work on spawned objects");
		client.Destroy(arrived);
		Pump(10);
		ok &= Check(client.Find("Pickup") != null, "a client cannot destroy a shared object");
		host.Destroy(pickup);
		host.Destroy(host.Find("Crate"));
		Pump(20);
		ok &= Check(client.Find("Pickup") == null && client.Find("Crate") == null && host.Find("Crate") == null, "destroying on the server removes spawned and scene objects everywhere");

		// ---- switches, lights and effects, shared without code ----
		{
			host.Find("Sign").SetActive(false);
			host.Find("Door").GetComponent<BoxCollider>().Enabled = false;
			let hostLamp = host.Find("Lamp").GetComponent<Light>();
			hostLamp.color = .(1, 0.2f, 0.1f);
			hostLamp.intensity = 4;
			hostLamp.range = 25;
			Pump(20);
			let clientLamp = client.Find("Lamp").GetComponent<Light>();
			ok &= Check(!client.Find("Sign").ActiveSelf && !client.Find("Door").GetComponent<BoxCollider>().Enabled, "an object switched off and a component disabled on the server are off on the client");
			ok &= Check(clientLamp.color == Color(1, 0.2f, 0.1f) && clientLamp.intensity == 4 && clientLamp.range == 25, "a light changed on the server changes on the client");
			client.Find("Door").GetComponent<BoxCollider>().Enabled = true;
			clientLamp.intensity = 9;
			Pump(20);
			ok &= Check(!host.Find("Door").GetComponent<BoxCollider>().Enabled && hostLamp.intensity == 4, "a client cannot switch or change what it does not own");
			client.Find("Door").GetComponent<BoxCollider>().Enabled = false;
			clientLamp.intensity = 4;

			// A client's own: a light on its player (a torch) is its to change.
			let torch = ownCopy.Transform.Children[0].GameObject.GetComponent<Light>();
			let serverTorch = hostCopy.Transform.Children[0].GameObject.GetComponent<Light>();
			// Something the client adds to its player for itself (a first-person body) stays its own.
			let ownBody = client.CreateGameObject("First Person Body", ownCopy.Transform);
			let hostBody = host.CreateGameObject("Body", hostCopy.Transform);
			ownBody.SetActive(false);
			torch.intensity = 3;
			torch.color = .(0.2f, 1, 0.2f);
			Pump(20);
			ok &= Check(serverTorch.intensity == 3 && serverTorch.color == Color(0.2f, 1, 0.2f), "a client changes a light on the object it owns, and the server's copy follows");
			torch.Enabled = false;
			Pump(20);
			ok &= Check(!serverTorch.Enabled, "and switches it off");
			ok &= Check(hostBody.ActiveSelf, "something a machine adds under its player itself stays its own");
			let ownWalker = ownCopy.GetComponent<Walker>();
			ownWalker.Enabled = false;
			Pump(20);
			ok &= Check(hostCopy.GetComponent<Walker>().Enabled, "a client cannot switch off how its own player plays, only how it looks");
			ownWalker.Enabled = true;

			// Effects started on the server.
			Pump(30);
			let clientSparks = client.Find("Sparks").GetComponent<ParticleSystem>();
			// Its burst over and its particles gone, as they would be by now in a game.
			clientSparks.[Friend]mParticles.Clear();
			clientSparks.[Friend]mBurstDone = true;
			let before = clientSparks.AliveCount;
			host.Find("Sparks").GetComponent<ParticleSystem>().Play();
			Pump(3);
			ok &= Check(before == 0 && clientSparks.AliveCount > 0, scope $"a particle system played on the server plays on the client ({clientSparks.AliveCount} particles)");
			let decals = client.SpawnedDecals.Count;
			Decals.Spawn(host, .(1, 0, 1), .Up, "Textures/hole.png", 0.5f);
			Pump(10);
			ok &= Check(client.SpawnedDecals.Count == decals + 1, "a decal pressed on the server is pressed on the client");
			// A game that shares its impacts itself as well: the client presses it too, and gets one, not two.
			Decals.Spawn(client, .(5, 0, 5), .Up, "Textures/hole.png", 0.5f);
			Decals.Spawn(host, .(5, 0, 5), .Up, "Textures/hole.png", 0.5f);
			Pump(10);
			ok &= Check(client.SpawnedDecals.Count == decals + 2, scope $"one already pressed there by the game is not pressed twice ({client.SpawnedDecals.Count - decals} of 2)");
			Decals.Spawn(client, .(-5, 0, -5), .Up, "Textures/hole.png", 0.5f);
			ok &= Check(client.SpawnedDecals.Count == decals + 3 && host.SpawnedDecals.Count == 2, "a client's own decals stay its own");
			Scene.Active = host;
			Audio.PlayOneShot("Sounds/bang.wav", .(2, 0, 2));
			Pump(10);
			bool heard = false;
			for (let effect in client.Network.RecentEffects)
				heard |= effect.fromServer && (effect.position - Vector3(2, 0, 2)).Length < 0.01f;
			ok &= Check(heard, "a sound played once on the server is played on the client");
		}

		// ---- a player who joins late gets all of it ----
		let late = scope Scene();
		Build(late);
		owned.Add(late);
		// Every machine loads the same scene, so the late one has the renderer the others were given above.
		late.Find("Bot").AddComponent<MeshRenderer>();
		Join(late, port);
		Pump(150);
		ok &= Check(late.Network.IsConnected && late.Find("Crate") == null, "a late joiner does not get an object that was destroyed before they arrived");
		{
			let lateLamp = late.Find("Lamp").GetComponent<Light>();
			ok &= Check(!late.Find("Sign").ActiveSelf && !late.Find("Door").GetComponent<BoxCollider>().Enabled && lateLamp.color == Color(1, 0.2f, 0.1f) && lateLamp.intensity == 4,
				"a late joiner gets the objects switched off, the components disabled and the lights as they are now");
		}
		let latePlayer = PlayerOf(host, late.Network.LocalClientId);
		ok &= Check(latePlayer != null && latePlayer.GetComponent<NetworkIdentity>().team == 1 && PlayerOf(late, late.Network.LocalClientId).GetComponent<NetworkIdentity>().team == 1, "and is put on the smaller team");
		ok &= Check(Solid(late.Find("Boulder").GetComponent<VoxelObject>()) == Solid(hostBoulder), "sees the voxel edits made earlier");
		let lateTerrain = late.Find("Terrain").GetComponent<VoxelTerrain>();
		for (int wait = 0; wait < 400 && (lateTerrain.PendingChunks > 0 || lateTerrain.[Friend]mChunks.Count == 0); wait++)
			Pump(5);
		Pump(40);
		let lateSame = SameTerrain(hostTerrain, lateTerrain, let lateEdited);
		ok &= Check(lateSame && lateEdited > 0 && lateTerrain.[Friend]mSessionBrushes.Count == 14, "and has the same terrain, though its chunks loaded after the edits were made");
		{
			let lateSkin = late.Find("Bot").GetComponent<MeshRenderer>();
			Pump(20);
			ok &= Check(lateSkin.material == "Materials/red.tmat" && lateSkin.ActiveMaterial != null && lateSkin.ActiveMaterial.color.g == 1 && lateSkin.ActiveMaterial.GetFloat("heat") == 0.75f, "a player who joins later gets the object's material and its values");
		}
		let lateProp = late.Find("Prop").GetComponent<CharacterController>();
		let lateHealth = late.Find("Bot").GetComponent<Health>();
		ok &= Check(lateProp.shape == .Box && lateProp.boxSize == Vector3(1.2f, 0.8f, 1.2f), "the current character shapes");
		ok &= Check(lateHealth.health == 42 && lateHealth.title == "Veteran", "and the current [Sync] values");

		// ---- Steam: the library loads and a session that cannot reach Steam fails cleanly ----
		{
			let ready = Steam.Init(480);
			ok &= Check(ready || !Steam.Error.IsEmpty, scope $"Steam start-up gives a clear answer: {(ready ? (StringView)"ready" : Steam.Error)}");
		// ---- sending a player away ----
			{
				let unwanted = scope:: Scene();
				Build(unwanted);
				owned.Add(unwanted);
				unwanted.Find("Bot").AddComponent<MeshRenderer>();
				Join(unwanted, port);
				Pump(150);
				let before = host.Network.ClientCount;
				let theirId = unwanted.Network.LocalClientId;
				let wasIn = unwanted.Network.IsConnected && PlayerOf(host, theirId) != null;
				let kicked = host.Network.Kick(theirId);
				Pump(120);
				ok &= Check(wasIn && kicked && host.Network.ClientCount == before - 1 && PlayerOf(host, theirId) == null && !unwanted.Network.IsConnected && !host.Network.Kick(theirId),
					"the host can remove a player: they are disconnected and their player goes");
				sScenes.Remove(unwanted);
			}

			let steamScene = scope Scene();
			steamScene.StartPlay();
			let network = scope NetworkManager(steamScene);
			network.Transport = .Steam;
			let started = network.StartServer(0, true);
			ok &= Check(started == ready && (started || network.Mode == .Offline), "a Steam session starts only when Steam is available, and otherwise stays offline");
			{
				// Friends, presence and invitations. With Steam these only read; nothing is published or sent here.
				let request = scope String();
				let name = scope String();
				let presence = scope String();
				let friends = Steam.FriendCount;
				if (friends > 0)
				{
					Steam.FriendName(Steam.FriendAt(0), name);
					Steam.FriendPresence(Steam.FriendAt(0), "status", presence);
				}
				if (ready)
					ok &= Check(friends >= 0 && (friends == 0 || !name.IsEmpty) && !Steam.TakeJoinRequest(request), "the friends list can be read through Steam, and no invitation is waiting");
				else
					ok &= Check(friends == 0 && Steam.FriendAt(0) == 0 && !Steam.FriendOnline(1) && !Steam.SetPresence("status", "x") && !Steam.Invite(1, "1") && !Steam.TakeJoinRequest(request) && name.IsEmpty && presence.IsEmpty,
						"without Steam there are no friends, and presence and invitations do nothing");
			}
			network.Stop();
			if (ready)
			{
				// A whole session over Steam: this machine hosts and joins itself by Steam ID.
				sScenes.Clear();
				let steamHost = scope Scene();
				Build(steamHost);
				let steamClient = scope Scene();
				Build(steamClient);
				steamHost.Network = new NetworkManager(steamHost);
				steamHost.Network.Transport = .Steam;
				steamHost.Network.PlayerPrefab.Set("TestPlayer");
				let hosting = steamHost.Network.StartServer(0, true);
				sScenes.Add(steamHost);
				steamClient.Network = new NetworkManager(steamClient);
				steamClient.Network.Transport = .Steam;
				steamClient.Network.PlayerPrefab.Set("TestPlayer");
				let joining = steamClient.Network.StartClient(scope $"{Steam.UserId}" , 0);
				sScenes.Add(steamClient);
				for (int wait = 0; wait < 300 && !(steamClient.Network.IsConnected && steamClient.Network.LocalClientId > 0); wait++)
					Pump(5);
				ok &= Check(hosting && joining && steamClient.Network.IsConnected && steamHost.Network.ClientCount == 1, "a client joins a host through Steam, by Steam ID");
				steamHost.Find("Bot").GetComponent<Health>().health = 5;
				steamHost.Find("Bot").Transform.Position = .(2, 0, 9);
				Pump(60);
				ok &= Check(steamClient.Find("Bot").GetComponent<Health>().health == 5 && (steamClient.Find("Bot").Transform.Position - Vector3(2, 0, 9)).Length < 0.05f && PlayerOf(steamClient, steamClient.Network.LocalClientId) != null, "and the game is shared over it: movement, [Sync] values and the player");
				delete steamHost.Network;
				steamHost.Network = null;
				delete steamClient.Network;
				steamClient.Network = null;
				sScenes.Clear();
			}
			Steam.Shutdown();
		}

		File.Delete(scope $"{cFolder}/Pickup.tprefab").IgnoreError();
		File.Delete(scope $"{cFolder}/Spark.tprefab").IgnoreError();
		Directory.Delete(cFolder).IgnoreError();
		// Sessions end before their scenes do.
		for (let scene in owned)
		{
			delete scene.Network;
			scene.Network = null;
		}
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
