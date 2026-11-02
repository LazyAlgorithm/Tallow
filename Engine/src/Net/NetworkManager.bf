using System;
using System.Collections;

namespace Tallow;

/// What part this machine plays in a network session.
[Reflect(.All)]
enum NetworkMode : int32
{
	Offline,
	Server,
	Host,
	Client
}

/// Server-authoritative networking with client-side prediction and reconciliation.
///
/// The server simulates every tick from the players' controls and sends snapshots: for each player their own
/// objects in full, and of everything else only what has changed, packed small.
///
/// A client runs the objects it controls ahead of the server, from its own controls. When a snapshot disagrees
/// with what it predicted for that tick, it goes back to the server's state and runs its unacknowledged controls
/// again. Everything it does not control it cannot predict, so it shows those a moment in the past, moving
/// evenly between two things the server has said about them. Its tick clock runs very slightly fast or slow to
/// keep a couple of ticks of controls waiting on the server, which absorbs an uneven connection.
class NetworkManager
{
	/// Makes an object of a registered prefab in a scene.
	public delegate GameObject PrefabFactory(Scene scene);
	/// Handler for a game-defined message. sender is the client id (0 when it came from the server or host).
	public delegate void MessageHandler(int32 sender, ref NetReader reader);
	/// Called with the id of a player who joined (or left).
	public delegate void ClientJoinedHandler(int32 clientId);

	static Dictionary<uint8, MessageHandler> sHandlers = new .() ~ DeleteDictionaryAndValues!(_);

	/// Server only: called after a client has connected and received every spawned object.
	public ClientJoinedHandler OnClientJoined ~ delete _;

	/// Give scene objects that move on their own (physics bodies, AI, character controllers) a Network Identity
	/// when the session starts, if they do not have one. Set by Network Session.
	public bool AutoReplicate = true;
	/// Game scene selection, delivered before spawned objects in the welcome packet.
	public String SessionContext = new .() ~ delete _;
	/// Called with the session context the server sends a joining client.
	public delegate void SessionContextHandler(StringView context);
	/// Client: called with the session context the server sends on joining (which map, which mode...).
	public SessionContextHandler OnSessionContext ~ delete _;
	/// True while ticks are being run again after a correction from the server.
	public bool Replaying;
	/// The scene the session runs in.
	public Scene Scene => mScene;

	// Engine-level changes (voxel edits) kept so players who join later can be brought up to date.
	List<(uint8 id, List<uint8> data)> mRemembered = new .() ~ { for (let entry in _) delete entry.data; delete _; };
	// Scene objects the server has destroyed; a newcomer loads the scene with them still in it.
	List<uint32> mDestroyedSceneIds = new .() ~ delete _;
	bool mApplyingDespawn;
	// Ids for objects that every machine creates itself at the same point in the shared order of events (voxel
	// fragments): each machine counts them the same way, so they agree without the server naming each one.
	const uint32 FragmentIdBase = 0x20000000;
	uint32 mNextFragmentId = FragmentIdBase;

	/// Gives an object every machine makes for itself at the same point (a voxel fragment) an id that every machine
	/// works out the same way.
	public void AdoptFragment(NetworkIdentity identity)
	{
		Unregister(identity);
		identity.NetId = mNextFragmentId++;
		Register(identity);
	}

	const int MaxRemembered = 100000;

	/// Objects with an id below this were in the scene when the session started, so every machine has them.
	public uint32 SceneIdLimit;
	/// Server: the latest of each switch and setting shared by NetworkSync (an object switched off, a light's
	/// colour), by what it is about, for players who join later.
	Dictionary<String, (uint8 id, List<uint8> data)> mStates = new .() ~
		{
			for (let (key, entry) in _)
			{
				delete key;
				delete entry.data;
			}
			delete _;
		};
	/// Effects played lately on this client and arriving from the server, to play each only once (NetworkSync).
	public List<NetworkSync.RecentEffect> RecentEffects = new .() ~ delete _;

	/// Server: keeps a state message under a key, in place of the one before with that key.
	public void RememberState(StringView key, uint8 id, NetWriter payload)
	{
		if (mStates.TryGetAlt(key, let existing, let entry))
		{
			entry.data.Clear();
			entry.data.AddRange(payload.Data);
			return;
		}
		let copy = new List<uint8>();
		copy.AddRange(payload.Data);
		mStates[new String(key)] = (id, copy);
	}

	public void ForgetStates()
	{
		for (let (key, entry) in mStates)
		{
			delete key;
			delete entry.data;
		}
		mStates.Clear();
		RecentEffects.Clear();
	}

	/// Server: sends a newcomer the latest of each kept state.
	public void ReplayStates(int32 clientId)
	{
		for (let client in mClients)
		{
			if (client.id != clientId)
				continue;
			for (let entry in mStates.Values)
			{
				mWriter.Clear();
				mWriter.Write(MsgCustom);
				mWriter.Write(entry.id);
				mWriter.Data.AddRange(entry.data);
				Send(client.peer, true);
			}
		}
	}

	/// Server: keeps a world edit (a message) to replay to players who join later, so that their world matches.
	public void Remember(uint8 id, NetWriter payload)
	{
		if (mRemembered.Count >= MaxRemembered)
		{
			if (mRemembered.Count == MaxRemembered)
				Log.Warning("Too many world edits to replay; players who join from now on will miss the oldest ones.");
			delete mRemembered[0].data;
			mRemembered.RemoveAt(0);
		}
		let copy = new List<uint8>();
		copy.AddRange(payload.Data);
		mRemembered.Add((id, copy));
	}

	/// Server: sends a newcomer the remembered edits and the scene objects that no longer exist.
	public void Replay(int32 clientId)
	{
		for (let client in mClients)
		{
			if (client.id != clientId)
				continue;
			// Edits first: they recreate fragments, some of which the list below then removes again.
			for (let entry in mRemembered)
			{
				mWriter.Clear();
				mWriter.Write(MsgCustom);
				mWriter.Write(entry.id);
				mWriter.Data.AddRange(entry.data);
				Send(client.peer, true);
			}
			for (let netId in mDestroyedSceneIds)
			{
				mWriter.Clear();
				mWriter.Write(MsgDespawn);
				mWriter.Write(netId);
				Send(client.peer, true);
			}
		}
	}

	/// Called by Scene.Destroy. On the server, destroying a networked object removes it everywhere. On a client the
	/// server decides, so the request is refused unless it is the server's own instruction being carried out.
	public bool AllowDestroy(GameObject gameObject)
	{
		if (mMode == .Offline)
			return true;
		let identity = gameObject.GetComponent<NetworkIdentity>();
		if (identity == null || !mByNetId.ContainsKey(identity.NetId))
			return true;
		if (!IsServer)
			return mApplyingDespawn;
		mWriter.Clear();
		mWriter.Write(MsgDespawn);
		mWriter.Write(identity.NetId);
		for (let client in mClients)
			Send(client.peer, true);
		if (identity.NetId < SpawnedIdBase)
			mDestroyedSceneIds.Add(identity.NetId);
		Unregister(identity);
		return true;
	}

	/// Server: makes an object that was just created from a prefab file exist on every machine.
	public void Adopt(GameObject root, StringView prefabPath)
	{
		if (!IsServer)
			return;
		var identity = root.GetComponent<NetworkIdentity>();
		if (identity == null)
			return;
		Unregister(identity);
		identity.NetId = mNextSpawnId++;
		identity.ownerId = 0;
		identity.PrefabName.Set(prefabPath);
		Register(identity);
		for (let client in mClients)
			SendSpawn(client, identity);
	}

	/// Registers a handler for a game message id. Call once at startup on every machine.
	public static void RegisterMessage(uint8 id, MessageHandler handler)
	{
		if (sHandlers.TryGetValue(id, let old))
			delete old;
		sHandlers[id] = handler;
	}

	void Dispatch(uint8 id, int32 sender, ref NetReader reader)
	{
		if (sHandlers.TryGetValue(id, let handler))
			handler(sender, ref reader);
	}

	void WriteCustom(uint8 id, NetWriter payload)
	{
		mWriter.Clear();
		mWriter.Write(MsgCustom);
		mWriter.Write(id);
		mWriter.Data.AddRange(payload.Data);
	}

	/// Sends a game message to the server. On the server or host it is handled immediately. Reliable messages
	/// always arrive, in order; pass false for things that are useless late, like speech.
	public void SendToServer(uint8 id, NetWriter payload, bool reliable = true)
	{
		if (IsServer)
		{
			var reader = NetReader(payload.Data.Ptr, payload.Data.Count);
			Dispatch(id, Math.Max(LocalClientId, 0), ref reader);
		}
		else if (mServerPeer != null)
		{
			WriteCustom(id, payload);
			Send(mServerPeer, reliable);
		}
	}

	/// Server only: sends a reliable game message to every connected client.
	public void SendToAll(uint8 id, NetWriter payload)
	{
		if (!IsServer)
			return;
		WriteCustom(id, payload);
		for (let client in mClients)
			Send(client.peer, true);
	}

	/// Server only: sends a game message to one client.
	public void SendToClient(int32 clientId, uint8 id, NetWriter payload, bool reliable = true)
	{
		if (!IsServer)
			return;
		WriteCustom(id, payload);
		for (let client in mClients)
		{
			if (client.id == clientId)
				Send(client.peer, reliable);
		}
	}

	/// Server only: the ids of the connected clients. The host's own player is 0 and is not in the list.
	public void GetClientIds(List<int32> ids)
	{
		for (let client in mClients)
			ids.Add(client.id);
	}

	/// The character spawned for a player (0 is the host's own), or null if they have none.
	public GameObject PlayerObject(int32 clientId)
	{
		GameObject fallback = null;
		for (let identity in mIdentities)
		{
			if (identity.ownerId != clientId || identity.PrefabName.IsEmpty)
				continue;
			if (identity.PrefabName == PlayerPrefab)
				return identity.GameObject;
			if (fallback == null && clientId != 0)
				fallback = identity.GameObject;
		}
		return fallback;
	}

	VoiceChat.VoiceSession mVoice ~ delete _;
	/// This session's voice chat state. See VoiceChat.
	public VoiceChat.VoiceSession Voice
	{
		get
		{
			if (mVoice == null)
				mVoice = new .(this);
			return mVoice;
		}
	}

	/// Server only: hands control of an object to a client (or back to the server with 0).
	public void SetOwner(NetworkIdentity identity, int32 ownerId)
	{
		if (!IsServer || identity == null)
			return;
		identity.ownerId = ownerId;
		mWriter.Clear();
		mWriter.Write(MsgOwner);
		mWriter.Write(identity.NetId);
		mWriter.Write(ownerId);
		for (let client in mClients)
			Send(client.peer, true);
	}

	struct SnapshotDelivery
	{
		public uint32 tick, change;
		public int32 repeats;
		public bool dormant;
	}

	class ClientInfo
	{
		public int32 id;
		public void* peer;
		/// How other machines would reach this one, for the roster.
		public String address = new .() ~ delete _;
		public List<(uint32 tick, NetInput input, double view)> queue = new .() ~ delete _;
		/// The server tick this player's machine was showing them when they gave the controls now in use.
		public double view;
		public NetInput lastInput;
		public uint32 lastProcessedTick;
		public uint32 lastReceivedTick;
		public int32 snapshotsSent;
		public int cursor;
		public Dictionary<uint32, SnapshotDelivery> delivered = new .() ~ delete _;
		/// Ticks since the last snapshot for which no controls had arrived.
		public int32 starved;
	}

	const uint8 MsgWelcome = 1;
	const uint8 MsgSpawn = 2;
	const uint8 MsgDespawn = 3;
	const uint8 MsgInput = 4;
	const uint8 MsgSnapshot = 5;
	const uint8 MsgCustom = 6;
	const uint8 MsgOwner = 7;
	const uint8 MsgSnapshotPart = 8;
	// Each packet of controls repeats the ticks before it, so that a lost packet costs nothing.
	const int InputRedundancy = 3;
	// More controls than this waiting on the server means the client has run ahead; the oldest are dropped.
	const int MaxQueuedInputs = 8;
	// An object that has stopped changing is still sent this many more times, in case the last word was lost,
	// and everything is sent again once in every RefreshEvery snapshots regardless.
	const uint32 SnapshotRepeats = 3;
	const uint32 RefreshEvery = 40;
	const int InputHistory = 256;
	const uint32 SpawnedIdBase = 0x40000000;

	Scene mScene;
	NetTransport mTransport ~ delete _;
	void* mServerPeer;
	/// How this session reaches other machines. Set before StartServer or StartClient.
	public NetworkTransportKind Transport = .Direct;
	NetworkMode mMode = .Offline;
	List<ClientInfo> mClients = new .() ~ DeleteContainerAndItems!(_);
	List<NetworkIdentity> mIdentities = new .() ~ delete _;
	Dictionary<uint32, NetworkIdentity> mByNetId = new .() ~ delete _;
	static Dictionary<String, PrefabFactory> sPrefabs = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	NetWriter mWriter = new .() ~ delete _;
	NetCompression mCompression ~ delete _;
	List<uint8> mCompressed = new .() ~ delete _;
	List<uint8> mDecompressed = new .() ~ delete _;
	int32 mStatTransportSent;
	/// Encoded application bytes offered to the transport before simulated loss (not physical wire bytes).
	public int32 TransportBytesSentPerSecond;
	int32 mNextClientId = 1;
	uint32 mNextSpawnId = SpawnedIdBase;
	uint32 mTick;
	NetInput[InputHistory] mInputs;
	NetInput mHostInput;
	bool mConnected;

	/// Prefab spawned for every player that joins (and for the host).
	public String PlayerPrefab = new .() ~ delete _;
	/// Server ticks between snapshots: 3 gives 20 snapshots per second at 60 ticks.
	public int32 SnapshotInterval = 3;
	/// Optional packet batching, remote formats, rates, dormancy and relevance. Legacy behaviour by default.
	public bool OptimizeSnapshots;
	/// Optional CPU timing of snapshot encoding and decoding, independent of frame pacing.
	public bool ProfileSnapshots;
	/// With ProfileSnapshots on: time spent building and reading snapshots, in total and at worst.
	public uint64 SnapshotBuildNanoseconds, SnapshotReadNanoseconds, SnapshotBuildWorstNs, SnapshotReadWorstNs;
	/// With ProfileSnapshots on: how many snapshots were built and read.
	public int64 SnapshotBuildCalls, SnapshotReadCalls;
	/// Remote snapshot payload limit; clamped to 256..1200. Owned corrections stay together and may exceed it.
	public int32 SnapshotPacketBytes = 1100;
	/// Per-client snapshot payload budget in bytes/second; zero means unlimited. Own prediction is reserved first.
	public int32 SnapshotBytesPerSecond;
	/// World-unit radius around each client's player, for distanceFiltered identities. Zero disables.
	public float SnapshotRelevanceRadius;
	/// Lossless compression: native ENet coder for Direct; independent message frames for Steam/WebRTC.
	public bool LosslessCompression;
	/// Force transport-independent lossless frames (also useful for testing Steam's message path over Direct).
	public bool MessageCompression;
	/// ENet UDP payload totals, including transport headers, retransmissions and compression.
	public uint32 WireBytesSent => mTransport?.WireSent ?? 0;
	/// ENet UDP bytes received, as WireBytesSent.
	public uint32 WireBytesReceived => mTransport?.WireReceived ?? 0;
	/// Position error in world units that triggers a rollback.
	public float CorrectionThreshold = 0.03f;
	/// Clients simulate server-owned physics bodies themselves, ahead of the server as they do their own player,
	/// instead of showing them a moment in the past: a crate the player walks into moves the tick they touch it.
	/// When the server says otherwise, the bodies and the player go back and run the ticks since again. Set on the
	/// server, it decides which bodies are sent for predicting (NetworkIdentity.physicsPrediction picks); set false
	/// on a client, that client shows them in the past regardless.
	public bool PredictPhysics = true;
	/// How far in the past, in ticks, a client shows the objects it does not control. 0 picks two snapshots'
	/// worth, which rides out one lost snapshot; less is more up to date and less forgiving.
	public int32 InterpolationTicks = 0;
	/// This machine's player id in the session (0 on the server).
	public int32 LocalClientId = 0;
	/// The anti-cheat's notes on this session; see AntiCheat.
	public AntiCheat.Session AntiCheatState ~ delete _;
	/// The session whose messages are being handled right now, for message handlers; null between.
	public static NetworkManager Dispatching;
	/// Replace local controls with scripted movement.
	public bool BotInput;

	// Statistics for the editor's network panel.
	/// Client: how many times a prediction was corrected (for the editor's network panel).
	public int32 Rollbacks;
	/// Client: how many snapshots have arrived.
	public int32 SnapshotsReceived;
	/// Client: how many ticks of controls the server has not used yet.
	public int32 PendingInputs;
	/// Client: how far off the last corrected prediction was.
	public float LastCorrection;
	/// Client: how many of the Rollbacks were for physics bodies alone, the player's own objects being right.
	public int32 PhysicsRollbacks;
	/// Client: how many physics bodies this machine is predicting.
	public int32 PredictedBodies;

	/// Print a line of network figures once a second (--netstats), for finding out why a connection feels rough.
	public static bool LogStats;
	int32 mStatRollbacks, mStatReplayed, mStatSnapshots, mStatStarved, mStatDropped, mStatTicks;
	int32 mStatSent, mStatReceived, mStatPacketsSent, mStatHeld;
	float mStatOwnWorst, mStatBodyWorst;
	/// Bytes sent and received in the last full second, for the editor's network panel and --netstats.
	public int32 BytesSentPerSecond, BytesReceivedPerSecond;

	// Client: keeping in step with the server.
	uint32 mLastSnapshotTick;
	bool mHaveSnapshot;
	int32 mServerInterval = 3;
	/// Server tick minus this machine's tick, as snapshots arrive; smoothed.
	double mServerOffset;
	bool mClockSet;
	float mDepth = 2, mTargetDepth = CalmDepth;
	int32 mCalmSnapshots;
	uint32 mSnapshotNumber;
	// How many ticks of controls the client aims to have waiting on the server when all is calm.
	const float CalmDepth = 1.5f;
	/// The server's tick as near as this machine knows it: exact on the server, estimated from snapshots on a
	/// client. Anything worked out from it alone (the swell on some water, a day and night cycle) comes out the
	/// same on every machine without being sent.
	public double ServerTick => IsServer || !mClockSet ? (double)mTick : (double)mTick + mServerOffset;
	/// Client: how many ticks of controls the server has waiting (smoothed), and how many this machine aims for.
	public float InputsWaiting => mDepth;
	/// Client: how many ticks of controls this machine aims to have waiting on the server.
	public float InputsWanted => mTargetDepth;

	void ReportStats()
	{
		if (++mStatTicks < Time.TickRate)
			return;
		BytesSentPerSecond = mStatSent;
		TransportBytesSentPerSecond = mStatTransportSent;
		mStatTransportSent = 0;
		BytesReceivedPerSecond = mStatReceived;
		if (LogStats && IsServer)
		{
			let text = scope String();
			for (let client in mClients)
				text.AppendF(" [client {}: {} inputs waiting]", client.id, client.queue.Count);
			Log.Info(scope $"netstats server: sent {mStatSent} bytes in {mStatPacketsSent} packets, received {mStatReceived}, {mIdentities.Count} objects, {mStatStarved} ticks without input, {mStatDropped} inputs dropped{text}");
		}
		else if (LogStats)
			Log.Info(scope $"netstats client: sent {mStatSent} bytes, received {mStatReceived}, {mStatSnapshots} snapshots, {mStatRollbacks} rollbacks replaying {mStatReplayed} ticks, {PendingInputs} ticks ahead, own error {mStatOwnWorst:0.000}, {PredictedBodies} bodies predicted (error {mStatBodyWorst:0.000}), {mDepth:0.0} of {mTargetDepth:0.0} inputs waiting, tick rate {Time.TickScale:0.000}, {mStatHeld} waits for news");
		mStatRollbacks = mStatReplayed = mStatSnapshots = mStatStarved = mStatDropped = mStatTicks = 0;
		mStatSent = mStatReceived = mStatPacketsSent = mStatHeld = 0;
		mStatOwnWorst = mStatBodyWorst = 0;
	}

	/// Offline, server, host or client.
	public NetworkMode Mode => mMode;
	/// Whether this machine runs the game (a dedicated server or a host).
	public bool IsServer => mMode == .Server || mMode == .Host;
	/// Whether this machine is connected to another as a client.
	public bool IsClient => mMode == .Client;
	/// Whether the session is up: listening as a server, or connected as a client.
	public bool IsConnected => mConnected;
	/// How many players are connected (server).
	public int32 ClientCount => (int32)mClients.Count;
	/// This machine's tick number in the session.
	public uint32 Tick => mTick;
	/// Every networked object. To find one by id, FindIdentity is much faster.
	public List<NetworkIdentity> Identities => mIdentities;

	/// A session for a scene, offline until StartServer or StartClient.
	public this(Scene scene)
	{
		mScene = scene;
	}

	public ~this()
	{
		Stop();
	}

	/// Registers a function that builds a networked object. Call once at startup (before any
	/// session starts) with the same names on the server and on clients.
	public static void RegisterPrefab(StringView name, PrefabFactory factory)
	{
		if (sPrefabs.TryGetValueAlt(name, let existing))
		{
			delete existing;
			sPrefabs[scope String(name)] = factory;
			return;
		}
		sPrefabs[new String(name)] = factory;
	}

	/// Registers a prefab file (made with "Save as Prefab" in the editor) under a name.
	/// Whether a network prefab of that name has been registered.
	public static bool IsRegistered(StringView name) => sPrefabs.ContainsKeyAlt(name);

	/// Makes one of a registered network prefab on this machine only, as the factory makes it (SaveSystem uses this
	/// to bring back saved objects when there is no session).
	public static GameObject CreateRegistered(Scene scene, StringView name)
	{
		if (!sPrefabs.TryGetValueAlt(name, let factory))
			return null;
		let gameObject = factory(scene);
		if (gameObject != null)
			String.NewOrSet!(gameObject.SpawnedFrom, name);
		return gameObject;
	}

	/// Registers a prefab file under a name, for Spawn.
	public static void RegisterPrefabFile(StringView name, StringView projectRelativePath)
	{
		let path = new String(projectRelativePath);
		RegisterPrefab(name, new [=path] (scene) => Prefab.Instantiate(scene, path) ~ delete path);
	}

	/// Starts serving on a port. With hostAlsoPlays this machine is a host, a player as well. False if the port could
	/// not be opened.
	public bool StartServer(uint16 port, bool hostAlsoPlays)
	{
		Stop();
		ForgetRoster();
		mTransport = NetTransport.Create(Transport);
		if (let direct = mTransport as ENetTransport)
			direct.LosslessCompression = LosslessCompression;
		if (!mTransport.Host(port))
		{
			Stop();
			return false;
		}
		mMode = hostAlsoPlays ? .Host : .Server;
		mConnected = true;
		mSessionPort = port;
		LocalClientId = hostAlsoPlays ? 0 : -1;
		NetworkSync.Prepare(this);
		RegisterSceneIdentities();
		if (hostAlsoPlays && !PlayerPrefab.IsEmpty)
			SpawnPlayer(0);
		Log.Info(scope $"Server listening on port {port}.");
		return true;
	}

	/// Connects to a server. False if the connection could not be started (whether it succeeds shows in IsConnected).
	public bool StartClient(StringView address, uint16 port)
	{
		Stop();
		ForgetRoster();
		mTransport = NetTransport.Create(Transport);
		if (let direct = mTransport as ENetTransport)
			direct.LosslessCompression = LosslessCompression;
		if (!mTransport.Connect(address, port, out mServerPeer))
		{
			Stop();
			return false;
		}
		mMode = .Client;
		mSessionPort = port;
		LocalClientId = -1;
		NetworkSync.Prepare(this);
		RegisterSceneIdentities();
		Log.Info(scope $"Connecting to {address}:{port}...");
		return true;
	}

	/// Leaves the session: a server tells its clients and closes, a client disconnects.
	public void Stop()
	{
		if (mTransport != null)
		{
			if (mServerPeer != null)
				mTransport.Disconnect(mServerPeer);
			for (let client in mClients)
				mTransport.Disconnect(client.peer);
			mTransport.Close();
			delete mTransport;
		}
		mTransport = null;
		mServerPeer = null;
		ClearAndDeleteItems!(mDelayed);
		ClearAndDeleteItems!(mClients);
		if (mMode == .Client)
			Time.TickScale = 1;
		mMode = .Offline;
		mConnected = false;
		mMigrating = false;
		mHostGone = false;
	}

	void RegisterSceneIdentities()
	{
		for (let component in mScene.Components)
		{
			if (let identity = component as NetworkIdentity)
			{
				if (identity.NetId == 0)
					identity.NetId = identity.GameObject.Id;
				Register(identity);
			}
		}
	}

	/// The object with that network id in this session, or null.
	public NetworkIdentity FindIdentity(uint32 netId)
	{
		if (mByNetId.TryGetValue(netId, let identity))
			return identity;
		return null;
	}

	void Register(NetworkIdentity identity)
	{
		if (identity.NetId == 0 || mByNetId.ContainsKey(identity.NetId))
			return;
		mIdentities.Add(identity);
		mByNetId[identity.NetId] = identity;
		if (identity.[Friend]mPartsIdLimit == 0)
			identity.[Friend]mPartsIdLimit = Scene.NextId;
	}

	void Unregister(NetworkIdentity identity)
	{
		for (let client in mClients)
			client.delivered.Remove(identity.NetId);
		if (mIdentities.Remove(identity))
			mByNetId.Remove(identity.NetId);
	}

	/// Number of teams players are shared out among as they join, each going to the smallest. 0 for no teams.
	public int32 TeamCount;
	/// Picks the team for a joining player.
	public delegate int32 TeamChooser(int32 clientId);
	/// Decides a joining player's team instead of TeamCount. Server only.
	public TeamChooser ChooseTeam ~ delete _;

	int32 TeamFor(int32 clientId)
	{
		if (ChooseTeam != null)
			return ChooseTeam(clientId);
		if (TeamCount <= 0)
			return 0;
		// Join the team with the fewest players; the lowest number wins a tie.
		int32 best = 1;
		int bestSize = int.MaxValue;
		for (int32 team = 1; team <= TeamCount; team++)
		{
			int size = 0;
			for (let identity in mIdentities)
			{
				if (identity.team == team && identity.PrefabName == PlayerPrefab)
					size++;
			}
			if (size < bestSize)
			{
				bestSize = size;
				best = team;
			}
		}
		return best;
	}

	/// Creates a player's object at a spawn point: the scene's Spawn Points if it has any (the next one for the
	/// player's team), otherwise beside an object named "SpawnPoint".
	GameObject SpawnPlayer(int32 clientId)
	{
		let team = TeamFor(clientId);
		Vector3 position;
		Quaternion rotation;
		if (!SpawnPoints.TryGet(mScene, team, false, out position, out rotation))
		{
			let marker = mScene.Find("SpawnPoint");
			let origin = marker != null ? marker.Transform.Position : Vector3(0, 2, 0);
			position = origin + Vector3((clientId % 4) * 2.0f, 0, (clientId / 4) * 2.0f);
			rotation = .Identity;
		}
		let player = Spawn(PlayerPrefab, position, rotation, clientId);
		let identity = player?.GetComponent<NetworkIdentity>();
		if (identity != null)
			identity.team = team;
		return player;
	}

	/// Server only: creates a prefab instance everywhere.
	public GameObject Spawn(StringView prefab, Vector3 position, Quaternion rotation, int32 ownerId)
	{
		if (!IsServer)
			return null;
		let netId = mNextSpawnId++;
		let gameObject = CreateFromPrefab(prefab, netId, ownerId, position, rotation);
		if (gameObject == null)
			return null;
		for (let client in mClients)
			SendSpawn(client, gameObject.GetComponent<NetworkIdentity>());
		return gameObject;
	}

	GameObject CreateFromPrefab(StringView prefab, uint32 netId, int32 ownerId, Vector3 position, Quaternion rotation)
	{
		GameObject gameObject = null;
		if (sPrefabs.TryGetValueAlt(prefab, let factory))
			gameObject = factory(mScene);
		else if (prefab.EndsWith(".tprefab"))
			gameObject = Prefab.Create(mScene, prefab); // a prefab file the server instantiated directly
		else
		{
			Log.Error(scope $"Network prefab '{prefab}' is not registered.");
			return null;
		}
		if (gameObject == null)
			return null;
		String.NewOrSet!(gameObject.SpawnedFrom, prefab);
		gameObject.Transform.SetPositionAndRotation(position, rotation);
		var identity = gameObject.GetComponent<NetworkIdentity>();
		if (identity == null)
			identity = gameObject.AddComponent<NetworkIdentity>();
		Unregister(identity);
		identity.NetId = netId;
		identity.ownerId = ownerId;
		identity.PrefabName.Set(prefab);
		// Everything the prefab made is part of it on every machine.
		identity.[Friend]mPartsIdLimit = mScene.NextId;
		Register(identity);
		return gameObject;
	}

	void SendSpawn(ClientInfo client, NetworkIdentity identity)
	{
		let state = identity.CaptureState();
		mWriter.Clear();
		mWriter.Write(MsgSpawn);
		mWriter.Write(identity.NetId);
		mWriter.Write(identity.ownerId);
		mWriter.WriteString(identity.PrefabName);
		mWriter.Write(state.position);
		mWriter.Write(state.rotation);
		Send(client.peer, true);
	}

	class DelayedPacket
	{
		public void* peer;
		public bool reliable;
		public uint64 dueTime;
		public List<uint8> data = new .() ~ delete _;
	}

	List<DelayedPacket> mDelayed = new .() ~ DeleteContainerAndItems!(_);
	uint32 mLossRandom = 0x2545f491;

	/// Network condition simulator for testing on one machine: every packet this machine sends is
	/// held back this many milliseconds. Run both sides with the same value; round-trip is twice it.
	public static int32 SimulatedLagMs;
	/// Percentage (0-100) of unreliable packets (inputs, snapshots) this machine throws away.
	public static float SimulatedLossPercent;
	/// Up to this many more milliseconds, different for every packet of controls or snapshots, on top of
	/// SimulatedLagMs: an uneven connection, on which packets bunch up and overtake one another.
	public static int32 SimulatedJitterMs;

	uint32 NextRandom()
	{
		mLossRandom ^= mLossRandom << 13;
		mLossRandom ^= mLossRandom >> 17;
		mLossRandom ^= mLossRandom << 5;
		return mLossRandom;
	}

	void Send(void* peer, bool reliable)
	{
		// Nothing to send to between hosts.
		if (peer == null || mTransport == null)
			return;
		mStatSent += (int32)mWriter.Data.Count;
		mStatPacketsSent++;
		Span<uint8> payload = mWriter.Data;
		if (MessageCompression || LosslessCompression && Transport != .Direct)
		{
			if (mCompression == null)
				mCompression = new .();
			if (mCompression.Encode(payload, mCompressed))
				payload = mCompressed;
		}
		mStatTransportSent += (int32)payload.Length;
		if (SimulatedLossPercent > 0 && !reliable)
		{
			if ((NextRandom() % 10000) < (uint32)(SimulatedLossPercent * 100))
				return;
		}
		if (SimulatedLagMs > 0 || SimulatedJitterMs > 0)
		{
			let delayed = new DelayedPacket();
			delayed.peer = peer;
			delayed.reliable = reliable;
			// Reliable packets keep the plain delay, so that they stay in order.
			let extra = reliable || SimulatedJitterMs <= 0 ? 0 : NextRandom() % (uint32)(SimulatedJitterMs * 1000);
			delayed.dueTime = SDL.SDL_GetTicksNS() + (uint64)SimulatedLagMs * 1000000 + (uint64)extra * 1000;
			delayed.data.AddRange(payload);
			mDelayed.Add(delayed);
			return;
		}
		mTransport?.Send(peer, payload, reliable);
	}

	/// Sends the simulated-lag packets whose delay has passed.
	void ReleaseDelayed()
	{
		if (mDelayed.Count == 0)
			return;
		let now = SDL.SDL_GetTicksNS();
		int kept = 0;
		for (int i < mDelayed.Count)
		{
			let delayed = mDelayed[i];
			if (delayed.dueTime > now)
			{
				mDelayed[kept++] = delayed;
				continue;
			}
			mTransport?.Send(delayed.peer, delayed.data, delayed.reliable);
			delete delayed;
		}
		if (kept < mDelayed.Count)
			mDelayed.RemoveRange(kept, mDelayed.Count - kept);
	}

	void DropDelayedFor(void* peer)
	{
		for (int i = mDelayed.Count - 1; i >= 0; i--)
		{
			if (mDelayed[i].peer == peer)
			{
				delete mDelayed[i];
				mDelayed.RemoveAt(i);
			}
		}
	}

	ClientInfo FindClient(void* peer)
	{
		for (let client in mClients)
		{
			if (client.peer == peer)
				return client;
		}
		return null;
	}

	void Poll()
	{
		if (mMigrating)
			UpdateMigration();
		if (mTransport == null)
			return;
		ReleaseDelayed();
		NetEvent event;
		Dispatching = this;
		defer
		{
			Dispatching = null;
		}
		while (mTransport != null && !mHostGone && mTransport.Poll(out event))
		{
			switch (event.kind)
			{
			case .Connected:
				if (IsServer)
				{
					if (!HoldForReclaim(event.peer))
						OnClientConnected(event.peer);
				}
				else if (mMigrating)
				{
					mWriter.Clear();
					mWriter.Write(MsgReclaim);
					mWriter.Write(LocalClientId);
					Send(mServerPeer, true);
					mReclaimSent = true;
				}
			case .Disconnected:
				if (IsServer)
				{
					mWaitingPeers.Remove(event.peer);
					OnClientDisconnected(event.peer);
				}
				else if (mMigrating)
				{
					mServerPeer = null;
					mReclaimSent = false;
				}
				else if (HostMigration && mConnected && mRoster.Count > 0)
					mHostGone = true;
				else
				{
					Log.Warning("Disconnected from server.");
					mConnected = false;
				}
			case .Data:
				mStatReceived += (int32)event.length;
				Span<uint8> payload = .(event.data, event.length);
				if (event.length > 0 && event.data[0] == NetCompression.MessageType)
				{
					if (mCompression == null)
						mCompression = new .();
					if (!mCompression.Decode(payload, mDecompressed)) continue;
					payload = mDecompressed;
				}
				var reader = NetReader(payload.Ptr, payload.Length);
				let type = reader.Read<uint8>();
				if (IsServer)
				{
					let client = FindClient(event.peer);
					if (type == MsgReclaim)
						ReadReclaim(event.peer, ref reader);
					else if (client != null && type == MsgAddress)
					{
						client.address.Clear();
						reader.ReadString(client.address);
					}
					else if (client != null && type == MsgInput)
						ReadInputs(client, ref reader);
					else if (client != null && type == MsgCustom)
					{
						let messageId = reader.Read<uint8>();
						AntiCheat.NoteMessage(this, client.id, messageId);
						Dispatch(messageId, client.id, ref reader);
					}
				}
				else
				{
					switch (type)
					{
					case MsgWelcome: ReadWelcome(ref reader);
					case MsgRoster: ReadRoster(ref reader);
					case MsgResume: ReadResume();
					case MsgSpawn: ReadSpawn(ref reader);
					case MsgDespawn: ReadDespawn(ref reader);
					case MsgSnapshot: ReadSnapshot(ref reader);
					case MsgSnapshotPart: ReadSnapshot(ref reader, true);
					case MsgCustom: Dispatch(reader.Read<uint8>(), 0, ref reader);
					case MsgOwner:
						let ownedId = reader.Read<uint32>();
						let newOwner = reader.Read<int32>();
						if (reader.Ok && mByNetId.TryGetValue(ownedId, let owned))
						{
							owned.ownerId = newOwner;
							owned.ClearKeys();
						}
					default:
					}
				}
			}
		}
		if (mHostGone)
			BeginMigration();
	}
}
