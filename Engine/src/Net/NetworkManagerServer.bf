using System;
using System.Collections;

namespace Tallow;

/// The server's side: clients joining and leaving, reading their inputs, running the tick and sending snapshots.
extension NetworkManager
{
	void OnClientConnected(void* peer)
	{
		let client = new ClientInfo();
		client.id = mNextClientId++;
		client.peer = peer;
		mClients.Add(client);
		PeerAddressOf(client);
		mRosterIn = 0;
		mWriter.Clear();
		mWriter.Write(MsgWelcome);
		mWriter.Write(client.id);
		mWriter.Write(mTick);
		mWriter.WriteString(SessionContext);
		Send(peer, true);
		// Bring the newcomer up to date with everything spawned so far, then add their player.
		for (let identity in mIdentities)
		{
			if (identity.NetId >= SpawnedIdBase)
				SendSpawn(client, identity);
		}
		if (!PlayerPrefab.IsEmpty)
			SpawnPlayer(client.id);
		AntiCheat.ClientJoined(this, client.id);
		NetworkSync.ClientJoined(this, client.id);
		if (OnClientJoined != null)
			OnClientJoined(client.id);
		Log.Info(scope $"Client {client.id} connected.");
	}

	/// Server: removes a client from the session, for a game that decides who may play (a private match, a
	/// player being sent away). Their objects go as if they had left. False if there is no such client.
	/// Anything sent to them just before may not arrive: send a reason a moment ahead if they should see one.
	public bool Kick(int32 clientId)
	{
		if (!IsServer || mTransport == null)
			return false;
		for (let client in mClients)
		{
			if (client.id != clientId)
				continue;
			let peer = client.peer;
			mTransport.Flush();
			mTransport.Disconnect(peer);
			OnClientDisconnected(peer);
			return true;
		}
		return false;
	}

	void OnClientDisconnected(void* peer)
	{
		let client = FindClient(peer);
		if (client == null)
			return;
		DropDelayedFor(peer);
		for (int i = mIdentities.Count - 1; i >= 0; i--)
		{
			let identity = mIdentities[i];
			if (identity.ownerId == client.id && identity.NetId >= SpawnedIdBase)
				Despawn(identity.GameObject);
		}
		AntiCheat.ClientLeft(this, client.id);
		MapSharing.ClientLeft(client.id);
		Log.Info(scope $"Client {client.id} disconnected.");
		mClients.Remove(client);
		delete client;
	}

	/// Server only: removes a spawned object everywhere.
	public void Despawn(GameObject gameObject)
	{
		if (!IsServer || !gameObject.GetComponent<NetworkIdentity>().IsValid)
			return;
		// Scene.Destroy asks AllowDestroy, which tells the clients.
		mScene.Destroy(gameObject);
	}

	void ReadInputs(ClientInfo client, ref NetReader reader)
	{
		let newest = reader.Read<uint32>();
		let count = (int)reader.Read<uint8>();
		if (!reader.Ok || count > 32)
			return;
		AntiCheat.NoteInputs(this, client.id, newest);
		// With the controls comes the server tick the player was being shown everyone else at, in quarter ticks;
		// only the low bits are sent, the rest being close to the tick the server is on.
		let viewLow = (int64)reader.Read<uint16>();
		let now4 = (int64)mTick * 4;
		var view4 = (now4 & ~(int64)0xFFFF) | viewLow;
		if (view4 > now4 + 0x8000)
			view4 -= 0x10000;
		else if (view4 < now4 - 0x8000)
			view4 += 0x10000;
		NetInput previous = default;
		for (int i < count)
		{
			let input = NetPack.ReadInput(ref reader, previous);
			if (!reader.Ok)
				return;
			previous = input;
			uint32 tick = newest - (uint32)(count - 1 - i);
			// Controls arrive several times over; only ticks not seen before count.
			if (tick <= client.lastReceivedTick)
				continue;
			client.lastReceivedTick = tick;
			AntiCheat.CheckInput(this, client.id, input);
			NetInput clean = input;
			clean.moveX = Mathf.Clamp(clean.moveX, -1, 1);
			clean.moveZ = Mathf.Clamp(clean.moveZ, -1, 1);
			if (tick > client.lastProcessedTick)
				client.queue.Add((tick, clean, (double)view4 / 4 - (double)(count - 1 - i)));
			else
				client.lastInput = clean; // too late for its own tick, but still the freshest word on what the player wants
		}
		// A client that runs ahead builds a backlog; drop the oldest to bound latency.
		while (client.queue.Count > MaxQueuedInputs)
		{
			client.queue.RemoveAt(0);
			mStatDropped++;
		}
	}

	void SimulateOwned(int32 ownerId, NetInput input)
	{
		for (int i = 0; i < mIdentities.Count; i++)
		{
			let identity = mIdentities[i];
			if (identity.ownerId != ownerId || !identity.IsActiveAndEnabled)
				continue;
			for (let component in identity.GameObject.Components)
			{
				if (let behaviour = component as NetworkBehaviour)
				{
					if (behaviour.IsActiveAndEnabled)
						behaviour.Simulate(input, Time.FixedDeltaTime);
				}
			}
			identity.TickUpdate(input, Time.FixedDeltaTime);
		}
	}

	NetInput GatherLocalInput()
	{
		NetInput input = default;
		if (BotInput)
		{
			// Deterministic wandering used by automated tests and for filling a server with movement.
			input.moveZ = 1.0f;
			input.yaw = Math.Sin(mTick * 0.02f) * 120.0f;
			input.SetButton(0, mTick % 90 == 0);
			return input;
		}
		bool gathered = false;
		bool controlled = false;
		for (let identity in mIdentities)
		{
			if (identity.ownerId != LocalClientId || !identity.IsActiveAndEnabled)
				continue;
			gathered |= identity.GatherFromBehaviours(ref input);
			controlled |= identity.playerControlled || identity.ownerId != 0;
		}
		// A player object with only plain scripts reads the project's input actions.
		if (!gathered && controlled)
			LocalControls.Read(ref input);
		return input;
	}

	/// Called by the scene before gameplay and physics run for a tick.
	public void PreTick()
	{
		Poll();
		if (mMode == .Offline)
			return;
		AntiCheat.Tick(this);
		MapSharing.Tick(this);
		if (IsServer)
		{
			if (mMode == .Host)
			{
				mHostInput = GatherLocalInput();
				SimulateOwned(0, mHostInput);
			}
			else
			{
				// A dedicated server still runs its own objects (NPCs and the like), with empty controls.
				SimulateOwned(0, default);
			}
			for (let client in mClients)
			{
				if (client.queue.Count > 0)
				{
					let entry = client.queue[0];
					client.queue.RemoveAt(0);
					client.lastInput = entry.input;
					client.lastProcessedTick = entry.tick;
					client.view = entry.view;
				}
				else if (client.lastProcessedTick > 0)
				{
					// Nothing has arrived for this tick. Carry on with the last controls and count the tick as done:
					// the player's own machine guessed the same unless the controls changed that very tick, and if
					// the real ones turn up late they are no longer wanted. Stalling instead would leave this player
					// a tick behind their own prediction for good.
					client.lastProcessedTick++;
					client.view += 1;
					client.starved++;
					mStatStarved++;
				}
				mSimulatingClient = client.id;
				mSimulatingView = client.view;
				SimulateOwned(client.id, client.lastInput);
				EndLagCompensation();
				mSimulatingClient = -1;
			}
		}
		else if (mConnected && LocalClientId > 0)
		{
			mTick++;
			ApplyRemoteStates();
			// Rounded to what the server will receive, so that both sides simulate from the same numbers.
			let input = NetPack.Quantize(GatherLocalInput());
			mInputs[mTick % InputHistory] = input;
			SendInputs();
			UpdateLink();
			SimulateOwned(LocalClientId, input);
		}
	}

	/// Called by the scene after physics ran for a tick.
	public void PostTick()
	{
		if (mMode == .Offline)
			return;
		if (IsServer)
		{
			mTick++;
			ShareRoster();
			CloseOpenPlaces();
			if (mTick % (uint32)Math.Max(SnapshotInterval, 1) == 0)
			{
				SendSnapshots();
				NetworkSync.ServerTick(this);
			}
		}
		else if (mConnected && LocalClientId > 0)
		{
			PredictedBodies = 0;
			for (let identity in mIdentityStates)
			{
				if (identity.ownerId == LocalClientId)
					identity.History[mTick % NetworkIdentity.HistorySize] = identity.CaptureState();
				else if (identity.Predicted)
				{
					identity.RecordTick(mTick);
					PredictedBodies++;
				}
			}
		}
		// Lights changed since the last snapshot, by the server or by the client that owns them: looked at as often as
		// snapshots go, so that a light changed every frame (a flicker every machine plays itself, or a game's
		// own animation) costs one message per snapshot, not one per tick.
		if ((IsServer || (mConnected && LocalClientId > 0)) && mTick % (uint32)Math.Max(SnapshotInterval, 1) == 0)
			NetworkSync.WatchLights(this);
		// Objects this machine does not move itself change once a tick; they are drawn gliding between ticks.
		for (let identity in mIdentityStates)
		{
			identity.NoteTick(identity.ownerId != LocalClientId && !identity.Predicted && !(IsServer && identity.ownerId == 0));
			// The server remembers where everything has been lately, for lag compensation.
			if (IsServer && mClients.Count > 0)
				identity.PushKey(mTick, identity.Transform.Position, identity.Transform.Rotation);
		}
		mTransport?.Flush();
		ReportStats();
		if (DescribeAtTick > 0 && mTick == (uint32)DescribeAtTick)
		{
			let text = scope String();
			Describe(text);
			Console.Write(text);
			Console.Out.Flush();
		}
	}

	/// Object ids are large numbers with the kind in the top bits; on the wire the kind goes in the low two bits,
	/// so that the usual small ones take a byte or two.
	static uint32 PackId(uint32 netId)
	{
		if (netId >= SpawnedIdBase && netId - SpawnedIdBase < 0x3FFFFFFF)
			return ((netId - SpawnedIdBase) << 2) | 1;
		if (netId >= FragmentIdBase && netId - FragmentIdBase < 0x1FFFFFFF)
			return ((netId - FragmentIdBase) << 2) | 2;
		if (netId < 0x20000000)
			return netId << 2;
		return 3;
	}

	void WriteId(uint32 netId) => WriteNetId(mWriter, netId);

	/// Writes an object's network id in as few bytes as it takes, usually one or two.
	public static void WriteNetId(NetWriter writer, uint32 netId)
	{
		let packed = PackId(netId);
		writer.WriteVarUInt(packed);
		if (packed == 3)
			writer.Write(netId);
	}

	public static uint32 ReadNetId(ref NetReader reader) => ReadId(ref reader);

	static uint32 ReadId(ref NetReader reader)
	{
		let packed = reader.ReadVarUInt();
		switch (packed & 3)
		{
		case 0: return packed >> 2;
		case 1: return SpawnedIdBase + (packed >> 2);
		case 2: return FragmentIdBase + (packed >> 2);
		default: return reader.Read<uint32>();
		}
	}

	void BeginSnapshotPacket(ClientInfo client)
	{
		mWriter.Clear();
		mWriter.Write(MsgSnapshotPart);
		mWriter.Write(mTick);
		mWriter.Write(client.lastProcessedTick);
		mWriter.Write((uint8)Math.Clamp(SnapshotInterval, 1, 255));
		mWriter.Write((int8)(client.starved > 0 ? -Math.Min(client.starved, 100) : Math.Min(client.queue.Count, 100)));
		mWriter.Write((uint16)0);
	}

	void FlushSnapshotPacket(ClientInfo client, int count, bool reliable)
	{
		if (count == 0) return;
		var written = (uint16)count;
		Internal.MemCpy(mWriter.Data.Ptr + 11, &written, 2);
		Send(client.peer, reliable);
	}

	/// A body clients simulate themselves: its exact motion, and whether it rests.
	static void WritePredictedBody(NetWriter writer, NetworkIdentityState identity)
	{
		let body = identity.GetComponent<Rigidbody>();
		NetPack.WriteBody(writer, body.State, body.IsSleeping);
	}

	void WriteSnapshotRecord(NetWriter writer, NetworkIdentityState identity, int32 clientId) =>
		WriteSnapshotRecord(writer, identity, identity.Chosen, clientId);

	void WriteSnapshotRecord(NetWriter writer, NetworkIdentityState identity, NetworkIdentityData settings, int32 clientId)
	{
		WriteNetId(writer, identity.NetId);
		let flagsAt = writer.Data.Count;
		// A body set to be predicted (physicsPrediction On) is, whatever its other snapshot settings.
		let predicted = settings.ownerId != clientId && identity.PhysicsPredictable;
		if (settings.ownerId == clientId || settings.remoteFormat == .Legacy && settings.fullPrecision && !(predicted && settings.physicsPrediction == .On))
		{
			writer.Write(NetPack.FlagFull);
			writer.Write(identity.CaptureState());
		}
		else if (predicted)
		{
			WritePredictedBody(writer, identity);
			return;
		}
		else if (settings.remoteFormat == .QuantizedBody && identity.GetComponent<Rigidbody>().HasBody)
			NetPack.WriteMotion(writer, identity.GetComponent<Rigidbody>().State);
		else if (settings.remoteFormat != .Legacy)
			NetPack.WriteTransform(writer, identity.Transform.Position, identity.Transform.Rotation, settings.remoteFormat == .QuantizedTransform);
		else
			NetPack.Write(writer, identity.Sent);
		if (settings.ownerId != clientId && identity.SnapshotSleeping)
			writer.Data[flagsAt] |= NetPack.FlagSleeping;
	}

	/// What a snapshot needs of one identity this tick, read once for every client: its settings, where it is,
	/// whether it rests, and its record as it goes to its owner and to everyone else (each written the first time
	/// a client needs it; a record depends on the client only through who owns the object).
	struct SnapshotRow
	{
		public NetworkIdentityState identity;
		public NetworkIdentityData settings;
		public Vector3 position;
		public uint32 netId;
		public uint32 changedAt;
		public bool sleeping;
		public int32 ownAt, ownLength, otherAt, otherLength;
	}

	struct SnapshotOrder
	{
		public int32 row;
		public bool own;
		public int32 priority;
		public uint32 tick;
		public uint32 netId;
	}

	List<SnapshotRow> mSnapshotRows = new .() ~ delete _;
	NetWriter mSnapshotRecords = new .() ~ delete _;

	/// A row's record for a client, written into mSnapshotRecords the first time it is asked for.
	Span<uint8> SnapshotRecord(int32 index, int32 clientId)
	{
		ref SnapshotRow row = ref mSnapshotRows[index];
		let own = row.settings.ownerId == clientId;
		if ((own ? row.ownLength : row.otherLength) < 0)
		{
			let at = (int32)mSnapshotRecords.Data.Count;
			// Anyone but the owner: an id no client has.
			WriteSnapshotRecord(mSnapshotRecords, row.identity, row.settings, own ? clientId : -2);
			let length = (int32)mSnapshotRecords.Data.Count - at;
			if (own) { row.ownAt = at; row.ownLength = length; }
			else { row.otherAt = at; row.otherLength = length; }
		}
		return own ? .(mSnapshotRecords.Data.Ptr + row.ownAt, row.ownLength) : .(mSnapshotRecords.Data.Ptr + row.otherAt, row.otherLength);
	}

	void SendOptimizedSnapshots()
	{
		mSnapshotNumber++;
		mSnapshotRows.Clear();
		mSnapshotRecords.Clear();
		for (let identity in mIdentityStates)
		{
			identity.Choose(this);
			identity.NoteSnapshot(mSnapshotNumber, true, PredictPhysics);
			SnapshotRow row = default;
			row.identity = identity;
			row.settings = identity.Chosen;
			row.position = identity.Transform.Position;
			row.netId = identity.NetId;
			row.changedAt = identity.ChangedAt;
			row.sleeping = row.settings.dormantWhenSleeping && identity.GetComponent<Rigidbody>().IsSleeping;
			row.ownLength = row.otherLength = -1;
			mSnapshotRows.Add(row);
		}
		let candidates = scope List<int32>();
		let keys = scope List<SnapshotOrder>();
		for (let client in mClients)
		{
			let player = PlayerObject(client.id);
			let playerAt = player != null ? player.Transform.Position : Vector3.Zero;
			candidates.Clear();
			for (int32 i < (int32)mSnapshotRows.Count)
			{
				let row = ref mSnapshotRows[i];
				let own = row.settings.ownerId == client.id;
				if (!own && row.settings.distanceFiltered && SnapshotRelevanceRadius > 0 && player != null &&
					(row.position - playerAt).LengthSquared > SnapshotRelevanceRadius * SnapshotRelevanceRadius)
				{
					client.delivered.Remove(row.netId);
					continue;
				}
				SnapshotDelivery sent = default;
				let known = client.delivered.TryGetValue(row.netId, out sent);
				// Its own objects go every snapshot while they change (what its prediction is checked against), then a
				// few times more and at the refresh rate, as the full snapshot sends them.
				if (!own && known && mTick - sent.tick < (uint32)Math.Max(row.settings.remoteIntervalTicks, SnapshotInterval)) continue;
				let changed = !known || sent.change != row.changedAt || sent.dormant != row.sleeping;
				let refresh = !row.sleeping && mTick - sent.tick >= (uint32)(Math.Max(SnapshotInterval, 1) * (int32)RefreshEvery);
				if (changed || sent.repeats < (int32)SnapshotRepeats || refresh)
					candidates.Add(i);
			}
			// Ownership, explicit priority, then age. Stable id breaks ties so every client is deterministic. Each
			// candidate's place is worked out once, not in every comparison.
			keys.Clear();
			for (let i in candidates)
			{
				let row = ref mSnapshotRows[i];
				SnapshotDelivery sent = default;
				client.delivered.TryGetValue(row.netId, out sent);
				keys.Add(.() { row = i, own = row.settings.ownerId == client.id, priority = row.settings.snapshotPriority, tick = sent.tick, netId = row.netId });
			}
			keys.Sort(scope (a, b) =>
				{
					if (a.own != b.own) return a.own ? -1 : 1;
					if (a.priority != b.priority) return b.priority <=> a.priority;
					return a.tick != b.tick ? a.tick <=> b.tick : a.netId <=> b.netId;
				});
			BeginSnapshotPacket(client);
			int count = 0, spent = 0;
			bool reliable = false;
			let limit = Math.Clamp(SnapshotPacketBytes, 256, 1200);
			let perSecond = SnapshotBytesPerSecond > 0 ? SnapshotBytesPerSecond : client.autoBudget;
			let budget = perSecond > 0 ? Math.Max(128, (int)((int64)perSecond * Math.Max(SnapshotInterval, 1) / Math.Max(Time.TickRate, 1))) : int.MaxValue;
			for (let key in keys)
			{
				let record = SnapshotRecord(key.row, client.id);
				let row = ref mSnapshotRows[key.row];
				let own = key.own;
				let dormant = !own && row.sleeping;
				// One coherent correction for all owned objects: replay must not advance them once per chunk, so they all
				// go first and in one packet (an exceptionally large group goes over the limit rather than in two).
				// Others follow in the same packet while they fit.
				let flush = count > 0 && (!own && mWriter.Data.Count + record.Length > limit || reliable != dormant);
				let cost = record.Length + ((count == 0 || flush) ? 13 : 0);
				if (!own && spent + cost > budget) continue;
				if (flush)
				{
					FlushSnapshotPacket(client, count, reliable);
					BeginSnapshotPacket(client);
					count = 0;
				}
				reliable = dormant;
				mWriter.Data.AddRange(record);
				row.identity.NoteSent(record.Length);
				count++;
				spent += cost;
				SnapshotDelivery sent = default;
				client.delivered.TryGetValue(row.netId, out sent);
				let same = sent.change == row.changedAt && sent.dormant == dormant;
				sent.repeats = dormant ? (int32)SnapshotRepeats : (same ? sent.repeats + 1 : 1);
				sent.tick = mTick;
				sent.change = row.changedAt;
				sent.dormant = dormant;
				client.delivered[row.netId] = sent;
			}
			FlushSnapshotPacket(client, count, reliable);
			if (count == 0 && spent == 0)
			{
				BeginSnapshotPacket(client);
				Send(client.peer, false);
			}
			client.snapshotsSent++;
			client.starved = 0;
		}
	}

	void SendSnapshots()
	{
		let began = ProfileSnapshots ? SDL.SDL_GetTicksNS() : 0;
		defer
		{
			if (ProfileSnapshots)
			{
				let ns = SDL.SDL_GetTicksNS() - began;
				SnapshotBuildNanoseconds += ns;
				SnapshotBuildWorstNs = Math.Max(SnapshotBuildWorstNs, ns);
				SnapshotBuildCalls++;
			}
		}
		if (OptimizeSnapshots)
		{
			SendOptimizedSnapshots();
			return;
		}
		mSnapshotNumber++;
		for (let identity in mIdentityStates)
		{
			identity.Choose(this);
			identity.NoteSnapshot(mSnapshotNumber, false, PredictPhysics);
		}
		for (let client in mClients)
		{
			mWriter.Clear();
			mWriter.Write(MsgSnapshot);
			mWriter.Write(mTick);
			mWriter.Write(client.lastProcessedTick);
			mWriter.Write((uint8)Math.Clamp(SnapshotInterval, 1, 255));
			// How well supplied with this player's controls the server is: their machine steers its clock by it.
			mWriter.Write((int8)(client.starved > 0 ? -Math.Min(client.starved, 100) : Math.Min(client.queue.Count, 100)));
			let countAt = mWriter.Data.Count;
			mWriter.Write((uint16)0);
			int count = 0;
			// A newcomer is told about everything, a few times over in case a snapshot is lost.
			let everything = client.snapshotsSent < (int32)SnapshotRepeats;
			for (let identity in mIdentityStates)
			{
				// Nothing is said about an object that has not changed for a few snapshots.
				if (!everything && mSnapshotNumber - identity.ChangedAt >= SnapshotRepeats && (mSnapshotNumber + identity.NetId) % RefreshEvery != 0)
					continue;
				let recordAt = mWriter.Data.Count;
				WriteId(identity.NetId);
				if (identity.ownerId == client.id || identity.Chosen.fullPrecision)
				{
					// Their own objects go exactly, velocity and all: this is what their prediction is checked against.
					mWriter.Write(NetPack.FlagFull);
					mWriter.Write(identity.CaptureState());
				}
				else if (identity.PhysicsPredictable)
					WritePredictedBody(mWriter, identity);
				else
					NetPack.Write(mWriter, identity.Sent);
				identity.NoteSent(mWriter.Data.Count - recordAt);
				count++;
			}
			var written = (uint16)Math.Min(count, 65535);
			Internal.MemCpy(mWriter.Data.Ptr + countAt, &written, 2);
			client.snapshotsSent++;
			client.starved = 0;
			Send(client.peer, false);
		}
	}
}
