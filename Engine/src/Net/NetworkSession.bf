using System;
using System.Collections;

namespace Tallow;

/// Drop this on an object to make the scene multiplayer. On play it starts a host, a client or a
/// dedicated server; the command line can override the mode: --server, --host, --connect <address>, --port <n>.
[Component]
class NetworkSession : Component
{
	public NetworkMode mode = .Host;
	/// Direct: UDP to an IP address and port. Steam: through Steam's relays, with the host's Steam ID as the address.
	public NetworkTransportKind transport = .Direct;
	/// Steam App ID to use when Transport is Steam. 0 uses the one in Project Settings, or Valve's public test
	/// app (480) if the project has none.
	[Advanced]
	public int32 steamAppId = 0;
	/// Who to join when Mode is Client: an IP address, or the host's Steam ID when Transport is Steam.
	public String address = new .("127.0.0.1") ~ delete _;
	public int32 port = 7777;
	/// Name passed to NetworkManager.RegisterPrefab; spawned once per player.
	public String playerPrefab = new .("Player") ~ delete _;
	[Advanced]
	public int32 snapshotInterval = 3;
	/// Optional remote snapshot batching and per-identity bandwidth controls.
	[Advanced]
	public bool optimizeSnapshots = true;
	[Advanced]
	public int32 snapshotPacketBytes = 1100;
	/// Per-client snapshot application payload budget; zero is unlimited.
	[Advanced]
	public int32 snapshotBytesPerSecond;
	/// Only distanceFiltered identities use this radius. Zero disables relevance filtering.
	[Advanced]
	public float snapshotRelevanceRadius;
	/// Lossless packet compression. Direct ENet requires it on every peer; Steam/WebRTC use message frames.
	[Advanced]
	public bool losslessCompression = true;
	[Advanced]
	public bool messageCompression;
	/// Share joining players out among this many teams, each going to the smallest. 0 for no teams. A player's
	/// team is on their Network Identity, and they appear at Spawn Points for that team.
	public int32 teamCount = 0;
	/// Share scene objects that move on their own (physics bodies, AI, character controllers) without each needing
	/// a Network Identity added by hand.
	[Advanced]
	public bool autoReplicate = true;

	/// Set by the application from the command line; .Offline means "use the component's mode".
	public static NetworkMode ModeOverride = .Offline;
	public static String AddressOverride = new .() ~ delete _;
	public static int32 PortOverride;
	public static bool BotOverride;

	public override void Awake()
	{
		let useMode = ModeOverride != .Offline ? ModeOverride : mode;
		if (useMode == .Offline)
			return;
		let usePort = (uint16)(PortOverride > 0 ? PortOverride : port);
		let network = new NetworkManager(Scene);
		network.PlayerPrefab.Set(playerPrefab);
		network.SnapshotInterval = snapshotInterval;
		network.OptimizeSnapshots = optimizeSnapshots;
		network.SnapshotPacketBytes = snapshotPacketBytes;
		network.SnapshotBytesPerSecond = snapshotBytesPerSecond;
		network.SnapshotRelevanceRadius = snapshotRelevanceRadius;
		network.LosslessCompression = losslessCompression;
		network.MessageCompression = messageCompression;
		network.TeamCount = teamCount;
		network.Transport = transport;
		SteamTransport.AppId = (uint32)Math.Max(steamAppId, 0);
		network.AutoReplicate = autoReplicate;
		network.BotInput = BotOverride;
		delete Scene.Network;
		Scene.Network = network;
		bool ok;
		if (useMode == .Client)
			ok = network.StartClient(AddressOverride.IsEmpty ? (StringView)address : AddressOverride, usePort);
		else
			ok = network.StartServer(usePort, useMode == .Host);
		if (!ok)
			Log.Error("Network session could not start; running offline.");
	}

	public override void OnDestroy()
	{
		if (Scene.Network != null)
		{
			Scene.Network.Stop();
			delete Scene.Network;
			Scene.Network = null;
		}
	}
}
