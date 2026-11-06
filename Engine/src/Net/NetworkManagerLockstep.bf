using System;
using System.Collections;

namespace Tallow;

/// Lockstep mode (6h), one switch on the Network Session. For games where moving objects far outnumber players and
/// every client should run everything (RTS, physics sandboxes, co-op): the server stops sending the state of
/// physics bodies and players once a client has it, and sends only everyone's controls (input forwarding, to every
/// client whatever the distance) and, every half second, a hash of the state of everything simulated. Every client
/// runs the whole world from the same controls on the same ticks. When a control turns out different from the one
/// guessed, the client goes back to an exact snapshot of its physics (contacts and all, so that running again gives
/// bit for bit what the server got) and runs the ticks since again. A client whose hash differs from the server's
/// asks for, and is sent, the state of everything again.
///
/// Every networked body has the same physics engine id on every machine (LockstepBodyIndex), as the engine's results
/// depend on ids. What the server does that clients cannot work out themselves (bodies made or removed, or put
/// somewhere by game code on the server alone: respawns, resets) sends every client the state of everything again,
/// so it should be rare. The same build on Linux and Windows stays in step (the physics library is built for
/// identical results on both).
///
/// Limits: every client simulates the whole world, so the weakest machine sets the object budget; nothing is
/// hidden from anyone (no use for competitive shooters); a late joiner first downloads every body's state.
extension NetworkManager
{
	/// Lockstep mode (server; a client learns it when it joins). See above.
	public bool Lockstep;

	const uint8 MsgDesync = 24;
	/// The server sends its hash every this many ticks.
	const uint32 HashEvery = 30;
	/// Exact physics snapshots kept, one a tick: as far back as a replay can go.
	const int ExactRingSize = 48;

	class ExactRing
	{
		public void*[ExactRingSize] states;
		public uint32[ExactRingSize] tick;
		public uint32[ExactRingSize] generation;
		/// The public fields of the scripts on the objects this machine runs, as they were (see SaveScriptFields).
		public List<uint8>[ExactRingSize] scripts;

		public ~this()
		{
			Clear();
		}

		public void Clear()
		{
			for (int i < ExactRingSize)
			{
				PhysicsWorld.FreeExact(states[i]);
				states[i] = null;
				tick[i] = 0;
				DeleteAndNullify!(scripts[i]);
			}
		}
	}

	ExactRing mExact = new .() ~ delete _;
	/// Client: the earliest tick whose own controls the server says it ran differently (it had not got them in
	/// time and repeated the last), not yet run again.
	uint32 mOwnFixedFrom;
	/// Server: the hash for the current tick, worked out once for all clients.
	uint32 mHashTick;
	uint64 mHash;

	/// Client: hashes compared with the server's, and how many differed (each asks for the state of everything).
	public int32 HashChecks, HashMismatches;
	/// Client: replays from an exact snapshot because a guessed control was wrong.
	public int32 LockstepReplays;
	/// Server: how many times a client reported a desync (its hash differed) and was sent the state of everything
	/// again.
	public int32 LockstepResyncs;
	/// Server: how many times a client asked for the state again because it could not take one up or replay (not a
	/// desync).
	public int32 LockstepRetries;
	/// Server: how many times a client was sent the state of everything again because bodies came, went or were put
	/// somewhere on the server alone.
	public int32 LockstepChangesSent;

	/// Server: whether a row is something every lockstep client runs itself (a body clients predict, or a player).
	bool LockstepSimulated(SnapshotRow row) => Lockstep && (row.identity.PhysicsPredictable || ForwardsFor(row.identity));

	/// Server, in lockstep: a simulated row goes to a client only until it has the exact state of everything
	/// (SendLockstepState, once it has had controls run). Returns true to leave the row out.
	bool LockstepSkip(ClientInfo client, SnapshotRow row) => LockstepSimulated(row) && client.lockstepSynced;

	const uint8 MsgLockstepState = 25;

	/// The body ids networked bodies get in lockstep, the same on every machine: the upper half of the physics
	/// engine's ids, a quarter for objects placed in scenes (by their id), an eighth each for spawned objects and
	/// fragments (by their number). uint32.MaxValue past those.
	uint32 LockstepBodyIndex(uint32 netId)
	{
		let half = (uint32)mScene.Physics.BodyCapacity / 2;
		let quarter = half / 2;
		let eighth = quarter / 2;
		if (netId >= SpawnedIdBase)
			return (netId - SpawnedIdBase < eighth) ? half + quarter + (netId - SpawnedIdBase) : uint32.MaxValue;
		if (netId >= FragmentIdBase)
			return (netId - FragmentIdBase < eighth) ? half + quarter + eighth + (netId - FragmentIdBase) : uint32.MaxValue;
		return (netId > 0 && netId < quarter) ? half + netId : uint32.MaxValue;
	}

	/// Lockstep: every networked body gets its fixed id (a body made before its object had a network id is made
	/// again, as it was).
	void LockstepBind(NetworkIdentity identity)
	{
		if (!Lockstep || mScene.Physics == null)
			return;
		if (mScene.Physics.FixedBodyIndex == null)
			mScene.Physics.FixedBodyIndex = new (transform) =>
				{
					let id = transform.GameObject.GetComponent<NetworkIdentity>();
					return id.IsValid && id.NetId != 0 ? LockstepBodyIndex(id.NetId) : uint32.MaxValue;
				};
		let body = identity.GetComponent<Rigidbody>();
		if (!body.IsValid || !body.HasBody)
			return;
		let wanted = LockstepBodyIndex(identity.NetId);
		if (wanted == uint32.MaxValue || body.BodyId == wanted)
			return;
		let state = body.State;
		let asleep = body.IsSleeping;
		body.RebuildBody();
		body.SetState(state);
		if (asleep)
			body.Sleep();
	}

	void LockstepBindAll()
	{
		for (let identity in mIdentities)
			LockstepBind(identity);
	}

	/// Server: the exact state of every networked body and its contacts, for a client to take up at the tick of
	/// its controls the server has just run (on joining, and after a hash differed).
	void SendLockstepState(ClientInfo client)
	{
		List<uint8> data = scope .();
		mScene.Physics.SaveShared((uint32)mScene.Physics.BodyCapacity / 2, data);
		mWriter.Clear();
		mWriter.Write(MsgLockstepState);
		mWriter.Write(mTick);
		mWriter.Write(client.lastProcessedTick);
		mWriter.Write((int32)data.Count);
		for (let b in data)
			mWriter.Write(b);
		Send(client.peer, true);
		client.lockstepSynced = true;
		LockstepStatesSent++;
		LockstepStateBytes = (int32)data.Count;
	}

	/// Client: the exact state of everything at one of this machine's ticks. Back to the snapshot of that tick, the
	/// state put in, and the ticks since run again; from here on this machine is in step with the server.
	void ReadLockstepState(ref NetReader reader)
	{
		reader.Read<uint32>();
		let ackTick = reader.Read<uint32>();
		let size = reader.Read<int32>();
		if (!reader.Ok || size < 0 || reader.Remaining < size || !Lockstep)
			return;
		List<uint8> data = scope .();
		data.Count = size;
		for (int i < size)
			data[i] = reader.Read<uint8>();
		if (!reader.Ok)
			return;
		let slot = ackTick % ExactRingSize;
		if (ackTick == 0 || (int32)(mTick - ackTick) < 0 || mTick - ackTick >= (uint32)ExactRingSize - 1 || mExact.tick[slot] != ackTick || mExact.generation[slot] != mScene.Physics.BodyGeneration)
		{
			// Too late to take up (or bodies came and went since): ask again.
			RequestResync(true);
			return;
		}
		List<(NetworkIdentity identity, Vector3 drawn)> before = scope .();
		for (let identity in mIdentities)
		{
			if (identity.ownerId == LocalClientId || identity.RemoteRun || identity.Predicted)
				before.Add((identity, identity.Transform.Position + identity.SmoothOffset));
		}
		if (!mScene.Physics.RestoreExact(mExact.states[slot]) || !mScene.Physics.RestoreShared(data))
		{
			RequestResync(true);
			return;
		}
		if (mExact.scripts[slot] == null || !ScriptFields(mExact.scripts[slot], true))
		{
			RequestResync(true);
			return;
		}
		let h = ackTick % NetworkIdentity.HistorySize;
		List<(NetworkIdentity identity, BodyState state)> run = scope .();
		for (let identity in mIdentities)
		{
			let body = identity.GetComponent<Rigidbody>();
			if (body.IsValid && body.HasBody && body.BodyId >= (uint32)mScene.Physics.BodyCapacity / 2 && identity.ownerId != LocalClientId && !identity.RemoteRun)
			{
				identity.Predicted = true;
				identity.PredictPausedUntil = 0;
				identity.PredictedSince = ackTick;
				identity.ClearKeys();
				identity.RecordTick(ackTick);
			}
			if (identity.ownerId == LocalClientId || identity.RemoteRun)
			{
				identity.History[h] = identity.CaptureState();
				run.Add((identity, identity.History[h]));
			}
		}
		CountPredictedBodies();
		SaveExactAt(ackTick);
		let began = SDL.SDL_GetTicksNS();
		ReplayInputs(ackTick, run);
		RollbackNanoseconds += SDL.SDL_GetTicksNS() - began;
		ReplayedTicks += mTick - ackTick;
		mLockstepSynced = true;
		mSyncedAt = ackTick;
		LockstepStatesTaken++;
		for (let entry in before)
		{
			if (!entry.identity.GameObject.IsDestroyed)
				entry.identity.SmoothOffset = entry.drawn - entry.identity.Transform.Position;
		}
	}

	/// Client: whether this machine has taken up the server's exact state (hashes are only compared after).
	bool mLockstepSynced;
	uint32 mSyncedAt;
	/// Client: the last tick whose hash matched the server's.
	uint32 mLastGoodHash;
	/// Client: exact states taken up; server: sent, and the size of the last.
	public int32 LockstepStatesTaken, LockstepStatesSent, LockstepStateBytes;

	/// What is hashed: the state of every simulated object, combined so that the order they are listed in does not
	/// matter (machines list them differently).
	static uint64 HashObject(uint32 netId, BodyState state)
	{
		uint64 hash = 14695981039346656037;
		void Add(void* data, int length)
		{
			let bytes = (uint8*)data;
			for (int i < length)
			{
				hash ^= bytes[i];
				hash *= 1099511628211;
			}
		}
		var id = netId;
		var s = state;
		Add(&id, 4);
		Add(&s.position, sizeof(Vector3));
		Add(&s.rotation, sizeof(Quaternion));
		Add(&s.linearVelocity, sizeof(Vector3));
		Add(&s.angularVelocity, sizeof(Vector3));
		return hash;
	}

	/// Server: the hash of everything simulated as it is now.
	uint64 ServerHash()
	{
		if (mHashTick == mTick)
			return mHash;
		uint64 hash = 0;
		HashSet<uint32> players = scope .();
		if (mMode == .Host)
		{
			if (let player = PlayerObject(0))
				players.Add(player.GetComponent<NetworkIdentity>().NetId);
		}
		for (let client in mClients)
		{
			if (let player = PlayerObject(client.id))
				players.Add(player.GetComponent<NetworkIdentity>().NetId);
		}
		for (let identity in mIdentities)
		{
			if (!identity.IsActiveAndEnabled)
				continue;
			if (players.Contains(identity.NetId) || identity.PhysicsPredictable)
			{
				hash += HashObject(identity.NetId, identity.CaptureState());
			}
		}
		mHashTick = mTick;
		mHash = hash;
		return hash;
	}

	/// Client: the hash of everything simulated as it was at one of this machine's ticks.
	uint64 ClientHash(uint32 tick)
	{
		uint64 hash = 0;
		let slot = tick % NetworkIdentity.HistorySize;
		uint32 own = 0;
		if (let player = PlayerObject(LocalClientId))
			own = player.GetComponent<NetworkIdentity>().NetId;
		for (let identity in mIdentities)
		{
			if (!identity.IsActiveAndEnabled)
				continue;
			if (identity.NetId == own || identity.RemoteRun || identity.Predicted)
				hash += HashObject(identity.NetId, identity.History[slot]);
		}
		return hash;
	}

	/// Client, after each tick (live or replayed): the scripts' state for both replay modes, and the exact physics
	/// state for lockstep. State sync already keeps its own physics and transform history.
	void SaveExactAt(uint32 tick)
	{
		let slot = tick % ExactRingSize;
		if (Lockstep)
		{
			if (mScene.Physics == null)
				return;
			mExact.states[slot] = mScene.Physics.SaveExact(mExact.states[slot]);
			mExact.generation[slot] = mScene.Physics.BodyGeneration;
		}
		mExact.tick[slot] = tick;
		if (mExact.scripts[slot] == null)
			mExact.scripts[slot] = new .();
		ScriptFields(mExact.scripts[slot], false);
	}

	// ScriptFields runs on the simulation thread without user callbacks. Reuse capacity across ticks instead
	// of allocating two temporary lists per snapshot/replay; clear borrowed references on every exit.
	List<FieldRef> mScriptFieldScratch = new .() ~ delete _;
	List<(void* ptr, int size)> mScriptRestoreScratch = new .() ~ delete _;

	/// The supported value fields (including private fields) of the scripts this machine runs, saved locally for
	/// both state sync and lockstep. [Sync] is still only for replication; replay history is never sent. A changed
	/// field layout is rejected before any fields are changed, even when its total byte size is the same.
	bool ScriptFields(List<uint8> data, bool restore)
	{
		if (!restore)
			data.Count = sizeof(uint64);
		else if (data.Count < sizeof(uint64))
			return false;
		int at = sizeof(uint64);
		uint64 schema = 5381;
		let fields = mScriptFieldScratch;
		let restoreFields = mScriptRestoreScratch;
		fields.Clear();
		restoreFields.Clear();
		defer
		{
			fields.Clear();
			restoreFields.Clear();
		}
		for (let identity in mIdentities)
		{
			if (identity.ownerId != LocalClientId && !identity.RemoteRun)
				continue;
			for (let component in identity.GameObject.Components)
			{
				if (!component.[Friend]mCallbacks.HasFlag(.Update) && !(component is NetworkBehaviour))
					continue;
				// Identity, script instance and each field address distinguish changed object sets and layouts,
				// including a hot-reloaded script whose new fields happen to occupy the same number of bytes.
				schema = ((schema << 7) | (schema >> 57)) ^ (uint64)identity.NetId;
				schema = ((schema << 7) | (schema >> 57)) ^ (uint64)(int)Internal.UnsafeCastToPtr(component);
				fields.Clear();
				ComponentRegistry.GetFields(component, fields, true);
				for (let field in fields)
				{
					switch (field.kind)
					{
					case .Float,.Double,.Char,.Vector4,.Int3,.Matrix4,.Int,.Bool,.Vector2,.Vector3,.Quaternion,.Color,.Enum:
						let size = field.type.Size;
						schema = ((schema << 7) | (schema >> 57)) ^ (uint64)(int)field.ptr ^ (uint64)size;
						if (restore)
						{
							if (at + size > data.Count)
								return false;
							restoreFields.Add((field.ptr, size));
						}
						else
						{
							data.Count = at + size;
							Internal.MemCpy(&data[at], field.ptr, size);
						}
						at += size;
					default:
					}
				}
			}
		}
		if (restore)
		{
			if (at != data.Count)
				return false;
			uint64 savedSchema = 0;
			Internal.MemCpy(&savedSchema, &data[0], sizeof(uint64));
			if (schema != savedSchema)
				return false;
			at = sizeof(uint64);
			for (let field in restoreFields)
			{
				Internal.MemCpy(field.ptr, &data[at], field.size);
				at += field.size;
			}
		}
		else
			Internal.MemCpy(&data[0], &schema, sizeof(uint64));
		return true;
	}

	/// Client, in lockstep, after forwarded controls came in: if a guess was wrong (or the server ran this
	/// machine's own controls differently), goes back to the exact snapshot from just before and runs the ticks
	/// since again; then checks the server's hash, when it came with them.
	void LockstepCatchUp(uint32 ackTick, bool hasHash, uint64 serverHash)
	{
		uint32 earliest = mOwnFixedFrom;
		mOwnFixedFrom = 0;
		for (let remote in mRemotePlayers.Values)
		{
			for (uint32 back < (uint32)ExactRingSize)
			{
				let tick = (uint32)(mTick - back);
				if (tick == 0 || (int32)(tick - remote.settledTo) <= 0)
					break;
				let slot = tick % (uint32)InputHistory;
				if (remote.knownAt[slot] == tick && remote.usedAt[slot] == tick && !InputsSame(remote.known[slot], remote.used[slot]))
				{
					if (earliest == 0 || (int32)(tick - earliest) < 0)
						earliest = tick;
				}
			}
		}
		// Nothing from before taking up the server's state needs running again: that state has it all in.
		if (earliest != 0 && mLockstepSynced && (int32)(earliest - 1 - mSyncedAt) < 0)
			earliest = mSyncedAt + 1;
		if (earliest != 0 && (int32)(mTick - earliest) >= 0)
		{
			// (Not a desync: the snapshot is gone or bodies came or went since. A real one shows in the hash.)
			if (!ReplayExact(earliest - 1))
				RequestResync(true);
		}
		for (let remote in mRemotePlayers.Values)
		{
			if ((int32)(ackTick - remote.settledTo) > 0)
				remote.settledTo = Math.Min(ackTick, mTick);
		}
		// (Not a hash from before the state was last taken up, coming late: those ticks were never run again.)
		if (hasHash && mLockstepSynced && ackTick > 0 && (int32)(ackTick - mSyncedAt) >= 0 && (int32)(mTick - ackTick) >= 0 && mTick - ackTick < (uint32)NetworkIdentity.HistorySize)
		{
			HashChecks++;
			if (ClientHash(ackTick) != serverHash)
			{
				HashMismatches++;
				DesyncInvestigate(Math.Max(mLastGoodHash, mSyncedAt), ackTick);
				RequestResync();
			}
			else
				mLastGoodHash = ackTick;
		}
	}

	/// Client: back to the exact snapshot after `tick` and every tick since run again. False if that snapshot is
	/// gone (too long ago, or bodies have come or gone since).
	bool ReplayExact(uint32 tick)
	{
		let slot = tick % ExactRingSize;
		if (tick == 0 || mExact.tick[slot] != tick || mExact.states[slot] == null || mExact.generation[slot] != mScene.Physics.BodyGeneration)
			return false;
		List<(NetworkIdentity identity, Vector3 drawn)> before = scope .();
		List<(NetworkIdentity identity, BodyState state)> owned = scope .();
		let historySlot = tick % NetworkIdentity.HistorySize;
		for (let identity in mIdentities)
		{
			if (identity.ownerId == LocalClientId || identity.RemoteRun || identity.Predicted)
				before.Add((identity, identity.Transform.Position + identity.SmoothOffset));
			if (identity.ownerId == LocalClientId || identity.RemoteRun)
				owned.Add((identity, identity.History[historySlot]));
		}
		if (!mScene.Physics.RestoreExact(mExact.states[slot]))
			return false;
		if (mExact.scripts[slot] == null || !ScriptFields(mExact.scripts[slot], true))
			return false;
		// What the physics engine does not hold (players with no body) goes back from its own history.
		for (let entry in owned)
		{
			if (!entry.identity.GetComponent<Rigidbody>().HasBody)
				entry.identity.ApplyState(entry.state);
		}
		let began = SDL.SDL_GetTicksNS();
		ReplayInputs(tick, owned);
		RollbackNanoseconds += SDL.SDL_GetTicksNS() - began;
		ReplayedTicks += mTick - tick;
		LockstepReplays++;
		for (let entry in before)
		{
			if (!entry.identity.GameObject.IsDestroyed)
				entry.identity.SmoothOffset = entry.drawn - entry.identity.Transform.Position;
		}
		return true;
	}

	/// Client: asks the server for the state of everything again: a hash differed (a desync), or `retry`, a state it
	/// sent could not be taken up or a replay could not be done (too late, or bodies came or went here in between).
	void RequestResync(bool retry = false)
	{
		mWriter.Clear();
		mWriter.Write(MsgDesync);
		mWriter.Write(mTick);
		mWriter.Write((uint8)(retry ? 1 : 0));
		Send(mServerPeer, true);
	}

	/// Server: a client asks for everything again (see RequestResync).
	void ReadDesync(ClientInfo client, ref NetReader reader)
	{
		reader.Read<uint32>();
		let retry = reader.Read<uint8>() != 0;
		if (!reader.Ok || !Lockstep)
			return;
		client.lockstepSynced = false;
		if (retry)
			LockstepRetries++;
		else
			LockstepResyncs++;
	}

	uint32 mSeenTeleports, mSeenGeneration;

	/// Server: bodies made or removed, or put somewhere by game code, change the world in a way the clients cannot
	/// work out for themselves; each is sent the whole state again (and no hash until then).
	void NoteServerOnlyChanges()
	{
		let physics = mScene.Physics;
		if (physics.Teleports == mSeenTeleports && physics.BodyGeneration == mSeenGeneration)
			return;
		mSeenTeleports = physics.Teleports;
		mSeenGeneration = physics.BodyGeneration;
		for (let client in mClients)
		{
			if (client.lockstepSynced)
				LockstepChangesSent++;
			client.lockstepSynced = false;
		}
	}

	/// Client: a fresh session.
	void ResetLockstep()
	{
		mExact.Clear();
		mOwnFixedFrom = 0;
		mLockstepSynced = false;
		mSyncedAt = 0;
		mLastGoodHash = 0;
		if (Lockstep)
			LockstepBindAll();
	}
}
