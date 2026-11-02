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
		if (!IsServer || gameObject.GetComponent<NetworkIdentity>() == null)
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
		for (let identity in mIdentities)
		{
			if (identity.ownerId != LocalClientId || !identity.IsActiveAndEnabled)
				continue;
			for (let component in identity.GameObject.Components)
			{
				if (let behaviour = component as NetworkBehaviour)
					behaviour.GatherInput(ref input);
			}
		}
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
			for (let identity in mIdentities)
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
		// Lights changed this tick, by the server or by the client that owns them.
		if (IsServer || (mConnected && LocalClientId > 0))
			NetworkSync.WatchLights(this);
		// Objects this machine does not move itself change once a tick; they are drawn gliding between ticks.
		for (let identity in mIdentities)
		{
			identity.NoteTick(identity.ownerId != LocalClientId && !identity.Predicted && !(IsServer && identity.ownerId == 0));
			// The server remembers where everything has been lately, for lag compensation.
			if (IsServer && mClients.Count > 0)
				identity.PushKey(mTick, identity.Transform.Position, identity.Transform.Rotation);
		}
		mTransport?.Flush();
		ReportStats();
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
	static void WritePredictedBody(NetWriter writer, NetworkIdentity identity)
	{
		let body = identity.GetComponent<Rigidbody>();
		NetPack.WriteBody(writer, body.State, body.IsSleeping);
	}

	void WriteSnapshotRecord(NetWriter writer, NetworkIdentity identity, int32 clientId)
	{
		WriteNetId(writer, identity.NetId);
		let flagsAt = writer.Data.Count;
		// A body set to be predicted (physicsPrediction On) is, whatever its other snapshot settings.
		let predicted = identity.ownerId != clientId && identity.PhysicsPredictable;
		if (identity.ownerId == clientId || identity.remoteFormat == .Legacy && identity.fullPrecision && !(predicted && identity.physicsPrediction == .On))
		{
			writer.Write(NetPack.FlagFull);
			writer.Write(identity.CaptureState());
		}
		else if (predicted)
		{
			WritePredictedBody(writer, identity);
			return;
		}
		else if (identity.remoteFormat == .QuantizedBody && identity.GetComponent<Rigidbody>()?.HasBody == true)
			NetPack.WriteMotion(writer, identity.GetComponent<Rigidbody>().State);
		else if (identity.remoteFormat != .Legacy)
			NetPack.WriteTransform(writer, identity.Transform.Position, identity.Transform.Rotation, identity.remoteFormat == .QuantizedTransform);
		else
			NetPack.Write(writer, identity.Sent);
		if (identity.ownerId != clientId && identity.SnapshotSleeping)
			writer.Data[flagsAt] |= NetPack.FlagSleeping;
	}

	void SendOptimizedSnapshots()
	{
		mSnapshotNumber++;
		for (let identity in mIdentities)
			identity.NoteSnapshot(mSnapshotNumber, true, PredictPhysics);
		let record = scope NetWriter();
		let candidates = scope List<NetworkIdentity>();
		for (let client in mClients)
		{
			let player = PlayerObject(client.id);
			candidates.Clear();
			for (let identity in mIdentities)
			{
				let own = identity.ownerId == client.id;
				if (!own && identity.distanceFiltered && SnapshotRelevanceRadius > 0 && player != null &&
					(identity.Transform.Position - player.Transform.Position).LengthSquared > SnapshotRelevanceRadius * SnapshotRelevanceRadius)
				{
					client.delivered.Remove(identity.NetId);
					continue;
				}
				SnapshotDelivery sent = default;
				let known = client.delivered.TryGetValue(identity.NetId, out sent);
				if (own)
				{
					candidates.Add(identity);
					continue;
				}
				if (known && mTick - sent.tick < (uint32)Math.Max(identity.remoteIntervalTicks, SnapshotInterval)) continue;
				let changed = !known || sent.change != identity.ChangedAt || sent.dormant != identity.SnapshotSleeping;
				let refresh = !identity.SnapshotSleeping && mTick - sent.tick >= (uint32)(Math.Max(SnapshotInterval, 1) * (int32)RefreshEvery);
				if (changed || sent.repeats < (int32)SnapshotRepeats || refresh)
					candidates.Add(identity);
			}
			// Ownership, explicit priority, then age. Stable id breaks ties so every client is deterministic.
			candidates.Sort(scope (a, b) =>
				{
					if ((a.ownerId == client.id) != (b.ownerId == client.id)) return a.ownerId == client.id ? -1 : 1;
					if (a.snapshotPriority != b.snapshotPriority) return b.snapshotPriority <=> a.snapshotPriority;
					SnapshotDelivery sa = default, sb = default;
					client.delivered.TryGetValue(a.NetId, out sa);
					client.delivered.TryGetValue(b.NetId, out sb);
					return sa.tick != sb.tick ? sa.tick <=> sb.tick : a.NetId <=> b.NetId;
				});
			BeginSnapshotPacket(client);
			int count = 0, spent = 0;
			bool reliable = false, containsOwned = false;
			let limit = Math.Clamp(SnapshotPacketBytes, 256, 1200);
			let budget = SnapshotBytesPerSecond > 0 ? Math.Max(128, (int)((int64)SnapshotBytesPerSecond * Math.Max(SnapshotInterval, 1) / Math.Max(Time.TickRate, 1))) : int.MaxValue;
			for (let identity in candidates)
			{
				record.Clear();
				WriteSnapshotRecord(record, identity, client.id);
				let dormant = identity.ownerId != client.id && identity.SnapshotSleeping;
				let own = identity.ownerId == client.id;
				// One coherent correction for all owned objects: replay must not advance them once per chunk.
				// Exceptional large ownership groups retain legacy fragmentation rather than replaying twice.
				let flush = count > 0 && (!own && (containsOwned || mWriter.Data.Count + record.Data.Count > limit) || reliable != dormant);
				let cost = record.Data.Count + ((count == 0 || flush) ? 13 : 0);
				if (identity.ownerId != client.id && spent + cost > budget) continue;
				if (flush)
				{
					FlushSnapshotPacket(client, count, reliable);
					BeginSnapshotPacket(client);
					count = 0;
					containsOwned = false;
				}
				reliable = dormant;
				containsOwned |= own;
				mWriter.Data.AddRange(record.Data);
				count++;
				spent += cost;
				SnapshotDelivery sent = default;
				client.delivered.TryGetValue(identity.NetId, out sent);
				let same = sent.change == identity.ChangedAt && sent.dormant == dormant;
				sent.repeats = dormant ? (int32)SnapshotRepeats : (same ? sent.repeats + 1 : 1);
				sent.tick = mTick;
				sent.change = identity.ChangedAt;
				sent.dormant = dormant;
				client.delivered[identity.NetId] = sent;
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
		for (let identity in mIdentities)
			identity.NoteSnapshot(mSnapshotNumber, false, PredictPhysics);
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
			for (let identity in mIdentities)
			{
				// Nothing is said about an object that has not changed for a few snapshots.
				if (!everything && mSnapshotNumber - identity.ChangedAt >= SnapshotRepeats && (mSnapshotNumber + identity.NetId) % RefreshEvery != 0)
					continue;
				WriteId(identity.NetId);
				if (identity.ownerId == client.id || identity.fullPrecision)
				{
					// Their own objects go exactly, velocity and all: this is what their prediction is checked against.
					mWriter.Write(NetPack.FlagFull);
					mWriter.Write(identity.CaptureState());
				}
				else if (identity.PhysicsPredictable)
					WritePredictedBody(mWriter, identity);
				else
					NetPack.Write(mWriter, identity.Sent);
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
