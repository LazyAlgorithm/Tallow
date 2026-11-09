using System;
using System.Collections;

namespace Tallow;

/// Host migration: when the host goes, a player takes over and the rest reconnect to them, in the same game.
///
/// Clients already hold a copy of the world, so nothing needs saving. The server shares a roster of who is playing
/// and how to reach them. When it disappears, everyone reads the same roster: the first player on it who can be
/// reached becomes the host, keeping the scene, and the others reconnect and reclaim their client ids and objects.
/// Off by default, because a game must be able to rebuild what only its server held: set HostMigration before
/// starting a session, and use OnBecameHost for that. What cannot be reached (a port not forwarded on Direct) moves on
/// to the next player; if nobody can take over the session ends as a lost connection.
extension NetworkManager
{
	const uint8 MsgRoster = 16;
	const uint8 MsgReclaim = 17;
	const uint8 MsgResume = 18;
	const uint8 MsgAddress = 19;
	// How often the roster goes out, how long one candidate gets, and how long a new host holds places open.
	const uint32 RosterTicks = 60;
	const uint64 CandidateMilliseconds = 6000;
	const uint64 RetryMilliseconds = 1500;
	const uint64 ReclaimMilliseconds = 12000;

	struct RosterEntry
	{
		public int32 id;
		public String address;
	}

	/// True to carry on with a new host when the host goes. Set before StartServer or StartClient.
	public bool HostMigration;
	/// On the machine that has just become the host, once the session is its own: rebuild server-only state here.
	public delegate void() OnBecameHost ~ delete _;
	/// On every machine that stays, with who the host now is (their Steam ID or address; empty if this one).
	public delegate void(StringView address) OnHostChanged ~ delete _;

	List<RosterEntry> mRoster = new .() ~ { ClearRoster(); delete _; };
	List<void*> mWaitingPeers = new .() ~ delete _;
	List<int32> mOpenPlaces = new .() ~ delete _;
	List<uint32> mHandedOver = new .() ~ delete _;
	uint16 mSessionPort;
	uint32 mHostPlayerNetId;
	uint32 mRosterIn;
	bool mHostGone;
	bool mMigrating;
	bool mReclaimSent;
	int mCandidate;
	uint64 mCandidateEnds;
	uint64 mNextTry;
	uint64 mReclaimEnds;

	/// True from losing the host until the session is running again.
	public bool IsMigrating => mMigrating;

	void ClearRoster()
	{
		for (let entry in mRoster)
			delete entry.address;
		mRoster.Clear();
	}

	void ForgetRoster()
	{
		mWaitingPeers.Clear();
		mOpenPlaces.Clear();
		ClearRoster();
		mHostPlayerNetId = 0;
	}

	static uint64 Milliseconds => SDL.SDL_GetTicksNS() / 1000000;

	/// Server, each tick: keeps every client's copy of the roster current.
	void ShareRoster()
	{
		if (!HostMigration || mClients.Count == 0 || mRosterIn-- > 0)
			return;
		mRosterIn = RosterTicks;
		if (mHostPlayerNetId == 0)
		{
			let hostIdentity = GameObject.ComponentOn<NetworkIdentity>(PlayerObject(0));
			mHostPlayerNetId = hostIdentity.IsValid ? hostIdentity.NetId : 0;
		}
		mWriter.Clear();
		mWriter.Write(MsgRoster);
		mWriter.Write(mHostPlayerNetId);
		mWriter.Write((uint16)mClients.Count);
		for (let client in mClients)
		{
			mWriter.Write(client.id);
			mWriter.WriteString(client.address);
		}
		for (let client in mClients)
			Send(client.peer, true);
	}

	void ReadRoster(ref NetReader reader)
	{
		let hostPlayer = reader.Read<uint32>();
		let count = (int)reader.Read<uint16>();
		ClearRoster();
		for (int i < count)
		{
			let id = reader.Read<int32>();
			let address = new String();
			reader.ReadString(address);
			if (!reader.Ok)
			{
				delete address;
				break;
			}
			mRoster.Add(.() { id = id, address = address });
		}
		mHostPlayerNetId = hostPlayer;
	}

	/// Client, once welcomed: a transport that can name this machine (Steam) says how others would reach it.
	void SendAddress()
	{
		let address = scope String();
		mTransport.LocalAddress(address);
		if (address.IsEmpty)
			return;
		mWriter.Clear();
		mWriter.Write(MsgAddress);
		mWriter.WriteString(address);
		Send(mServerPeer, true);
	}

	/// Client: the host has gone. The session carries on from what this machine already has.
	void BeginMigration()
	{
		mHostGone = false;
		Log.Warning("The host has gone; finding a new one.");
		mTransport.Close();
		delete mTransport;
		mTransport = null;
		mServerPeer = null;
		ClearAndDeleteItems!(mDelayed);
		// The player who left leaves with the host. Bots and the rest of the world stay.
		if (mByNetId.TryGetValue(mHostPlayerNetId, let identity))
		{
			mApplyingDespawn = true;
			mScene.Destroy(identity.GameObject);
			mApplyingDespawn = false;
			Unregister(identity);
		}
		mHostPlayerNetId = 0;
		mMigrating = true;
		mReclaimSent = false;
		mCandidate = 0;
		mCandidateEnds = Milliseconds + CandidateMilliseconds;
		mNextTry = 0;
	}

	/// Client, each poll: works down the roster until the session is running again or nobody is left.
	void UpdateMigration()
	{
		let now = Milliseconds;
		if (now >= mCandidateEnds)
		{
			mCandidate++;
			mReclaimSent = false;
			mCandidateEnds = now + CandidateMilliseconds;
			mNextTry = 0;
		}
		if (mCandidate >= mRoster.Count)
		{
			Log.Warning("No player could take over as host.");
			mMigrating = false;
			mConnected = false;
			return;
		}
		if (now < mNextTry)
			return;
		mNextTry = now + RetryMilliseconds;
		let entry = mRoster[mCandidate];
		if (entry.id == LocalClientId)
		{
			if (!BecomeHost())
				mCandidateEnds = 0;
			return;
		}
		// Give the new host a moment to open: the first try comes one retry later. Once through, wait for its answer.
		if (now + CandidateMilliseconds - RetryMilliseconds >= mCandidateEnds && !mReclaimSent)
			ConnectToCandidate(entry);
	}

	void ConnectToCandidate(RosterEntry entry)
	{
		if (mTransport != null)
		{
			mTransport.Close();
			delete mTransport;
		}
		mServerPeer = null;
		mTransport = NetTransport.Create(Transport);
		if (let direct = mTransport as ENetTransport)
			direct.LosslessCompression = LosslessCompression;
		if (!mTransport.Connect(entry.address, mSessionPort, out mServerPeer))
		{
			delete mTransport;
			mTransport = null;
			mServerPeer = null;
		}
	}

	/// This machine is next on the roster: it opens for the others and the session is its own from here.
	bool BecomeHost()
	{
		if (mTransport != null)
		{
			mTransport.Close();
			delete mTransport;
			mTransport = null;
		}
		mTransport = NetTransport.Create(Transport);
		if (let direct = mTransport as ENetTransport)
			direct.LosslessCompression = LosslessCompression;
		if (!mTransport.Host(mSessionPort))
		{
			delete mTransport;
			mTransport = null;
			return false;
		}
		let oldId = LocalClientId;
		mMode = .Host;
		LocalClientId = 0;
		mMigrating = false;
		Time.TickScale = 1;
		mHandedOver.Clear();
		mOpenPlaces.Clear();
		uint32 highest = SpawnedIdBase;
		for (let identity in mIdentities)
		{
			highest = Math.Max(highest, identity.NetId);
			identity.Predicted = false;
			identity.ClearKeys();
			if (identity.ownerId == oldId)
			{
				identity.ownerId = 0;
				mHandedOver.Add(identity.NetId);
			}
		}
		mNextSpawnId = highest + 1;
		for (let entry in mRoster)
		{
			if (entry.id != oldId)
				mOpenPlaces.Add(entry.id);
			mNextClientId = Math.Max(mNextClientId, entry.id + 1);
		}
		mReclaimEnds = Milliseconds + ReclaimMilliseconds;
		NativeBecameHost();
		let hostIdentity = GameObject.ComponentOn<NetworkIdentity>(PlayerObject(0));
		mHostPlayerNetId = hostIdentity.IsValid ? hostIdentity.NetId : 0;
		Log.Info("This machine is now the host.");
		if (OnBecameHost != null)
			OnBecameHost();
		if (OnHostChanged != null)
			OnHostChanged("");
		return true;
	}

	/// Server: someone connected while places are held open. They say who they were first.
	bool HoldForReclaim(void* peer)
	{
		if (mOpenPlaces.Count == 0)
			return false;
		mWaitingPeers.Add(peer);
		return true;
	}

	/// Server: a player from before has reconnected and takes their place back; anyone else simply joins.
	void ReadReclaim(void* peer, ref NetReader reader)
	{
		let id = reader.Read<int32>();
		if (!reader.Ok || !mWaitingPeers.Remove(peer))
			return;
		if (!mOpenPlaces.Remove(id))
		{
			OnClientConnected(peer);
			return;
		}
		let client = new ClientInfo();
		client.id = id;
		client.peer = peer;
		mClients.Add(client);
		PeerAddressOf(client);
		mWriter.Clear();
		mWriter.Write(MsgResume);
		Send(peer, true);
		for (let identity in mIdentities)
		{
			if (identity.NetId >= SpawnedIdBase)
				SendSpawn(client, identity);
		}
		for (let netId in mHandedOver)
		{
			mWriter.Clear();
			mWriter.Write(MsgOwner);
			mWriter.Write(netId);
			mWriter.Write((int32)0);
			Send(peer, true);
		}
		AntiCheat.ClientJoined(this, id);
		NativeClientJoined(id);
		mRosterIn = 0;
		Log.Info(scope $"Client {id} came back.");
	}

	/// Client: the new host has taken this machine back.
	void ReadResume()
	{
		mMigrating = false;
		mTick = 0;
		mHaveSnapshot = false;
		mClockSet = false;
		mDepth = 2;
		mTargetDepth = CalmDepth;
		mViewDelay = 0;
		ResetDeltas();
		ResetForwarding();
		NativeResetReplicas();
		for (let identity in mIdentities)
		{
			identity.Predicted = false;
			identity.ClearKeys();
		}
		SendAddress();
		if (OnHostChanged != null)
		{
			let address = mCandidate < mRoster.Count ? mRoster[mCandidate].address : "";
			OnHostChanged(address);
		}
		Log.Info(scope $"Back in the game as client {LocalClientId}.");
	}

	/// Server, each tick: the places of players who never came back are given up, and those waiting go ahead.
	void CloseOpenPlaces()
	{
		if (mOpenPlaces.Count == 0 && mWaitingPeers.Count == 0)
			return;
		if (mOpenPlaces.Count > 0 && Milliseconds < mReclaimEnds)
			return;
		for (let id in mOpenPlaces)
		{
			for (int i = mIdentities.Count - 1; i >= 0; i--)
			{
				let identity = mIdentities[i];
				if (identity.ownerId == id && identity.NetId >= SpawnedIdBase)
					Despawn(identity.GameObject);
			}
		}
		mOpenPlaces.Clear();
		List<void*> waiting = scope .(mWaitingPeers);
		mWaitingPeers.Clear();
		for (let peer in waiting)
			OnClientConnected(peer);
	}

	void PeerAddressOf(ClientInfo client)
	{
		client.address.Clear();
		mTransport.PeerAddress(client.peer, client.address);
	}
}
