using System;
using System.Collections;

namespace Tallow;

/// Field deltas (6c). A client says which snapshot packets reached it (a few bytes on its controls); the server keeps,
/// for each client and object, the last few records it sent and which of them arrived. A record is then sent as
/// the bytes that differ from the newest one that arrived, and not at all when it is the same.
///
/// On the wire a delta packet (MsgSnapshotDelta) has the snapshot header, a packet number, and records of
/// [object id][ticks back to the baseline, 0 for none][length][...]: with no baseline, the ordinary record; with
/// one, a mask of the bytes that differ from it and those bytes, XORed with the baseline's. The client rebuilds
/// ordinary records from them and reads the packet as it reads any other, so prediction and interpolation see
/// exactly what they saw before.
extension NetworkManager
{
	/// Send each client only what differs from what it is known to have (on by default). Clients that do not
	/// acknowledge packets get the ordinary snapshots.
	public bool FieldDeltas = true;

	const uint8 MsgSnapshotDelta = 21;
	/// Records kept per object and client; the newest acknowledged of them is the baseline.
	const int DeltaRingSize = 8;
	/// The longest record kept as a baseline (an owner's full state is 85 bytes).
	const int DeltaRecordBytes = 96;
	/// Packets remembered per client for acknowledgements to find (a packet number in the low bits).
	const int DeltaPacketSlots = 1024;

	/// The last few records one object was sent as, to one client (or, on a client, received as).
	class DeltaRing
	{
		public uint32[DeltaRingSize] tick;
		public uint16[DeltaRingSize] packet;
		public bool[DeltaRingSize] acked;
		public uint8[DeltaRingSize] length;
		public uint8[DeltaRingSize * DeltaRecordBytes] bytes;
		public int32 next;

		public void Push(uint32 atTick, uint16 inPacket, Span<uint8> record)
		{
			let slot = next;
			next = (next + 1) % DeltaRingSize;
			tick[slot] = atTick;
			packet[slot] = inPacket;
			acked[slot] = false;
			length[slot] = (uint8)record.Length;
			Internal.MemCpy(&bytes[slot * DeltaRecordBytes], record.Ptr, record.Length);
		}

		/// The newest record that arrived, or -1.
		public int Baseline()
		{
			for (int back < DeltaRingSize)
			{
				let slot = (next - 1 - back + DeltaRingSize * 2) % DeltaRingSize;
				if (length[slot] > 0 && acked[slot])
					return slot;
			}
			return -1;
		}

		/// The record received at a tick, or -1.
		public int AtTick(uint32 atTick)
		{
			for (int slot < DeltaRingSize)
			{
				if (length[slot] > 0 && tick[slot] == atTick)
					return slot;
			}
			return -1;
		}

		public Span<uint8> Record(int slot) => .(&bytes[slot * DeltaRecordBytes], length[slot]);

		/// Client: whether a tick is older than every record kept, all places being taken.
		public bool IsStale(uint32 atTick)
		{
			for (int i < DeltaRingSize)
			{
				if (length[i] == 0 || (int32)(tick[i] - atTick) <= 0)
					return false;
			}
			return true;
		}

		/// Client: keeps a received record in place of the oldest kept (by tick, as packets can arrive out of
		/// order), so that the newest few ticks received are always to hand.
		public void Keep(uint32 atTick, Span<uint8> record)
		{
			int slot = -1;
			for (int i < DeltaRingSize)
			{
				if (length[i] == 0)
				{
					slot = i;
					break;
				}
				if (tick[i] == atTick) return;
				if (slot < 0 || (int32)(tick[i] - tick[slot]) < 0)
					slot = i;
			}
			if (length[slot] > 0 && (int32)(atTick - tick[slot]) < 0)
				return;
			tick[slot] = atTick;
			acked[slot] = true;
			length[slot] = (uint8)record.Length;
			Internal.MemCpy(&bytes[slot * DeltaRecordBytes], record.Ptr, record.Length);
		}
	}

	/// Server: what one client is known to have.
	class DeltaClient
	{
		public Dictionary<uint32, DeltaRing> rings = new .() ~ DeleteDictionaryAndValues!(_);
		/// The objects each recent packet carried, and that packet's number (to tell a slot reused).
		public List<uint32>[DeltaPacketSlots] packetObjects;
		public uint16[DeltaPacketSlots] packetNumber;
		public uint32[DeltaPacketSlots] packetTick;
		public bool[DeltaPacketSlots] packetAcked;
		public uint16 nextPacket;
		public uint16 currentPacket;

		public ~this()
		{
			for (let list in packetObjects)
				delete list;
		}

		public DeltaRing Ring(uint32 netId)
		{
			if (rings.TryAdd(netId, let key, let value))
				*value = new DeltaRing();
			return *value;
		}

		/// A packet arrived: every record in it becomes a baseline.
		public void Acknowledge(uint16 number)
		{
			let slot = number % DeltaPacketSlots;
			if (packetObjects[slot] == null || packetNumber[slot] != number || packetAcked[slot])
				return;
			packetAcked[slot] = true;
			for (let netId in packetObjects[slot])
			{
				if (!rings.TryGetValue(netId, let ring))
					continue;
				for (int i < DeltaRingSize)
				{
					if (ring.length[i] > 0 && ring.packet[i] == number)
						ring.acked[i] = true;
				}
			}
		}
	}

	// Client: what arrived, for acknowledging, and the records kept as baselines.
	bool mDeltasOffered;
	bool mHaveDeltaPacket;
	uint16 mAckNewest;
	uint64 mAckBits;
	uint16[2] mAckSentNewest;
	int32 mAckDirty;
	Dictionary<uint32, DeltaRing> mDeltaRings = new .() ~ DeleteDictionaryAndValues!(_);
	NetWriter mDeltaRebuilt = new .() ~ delete _;
	/// Client: delta records that could not be read because their baseline was missing (should stay 0).
	public int32 DeltaMisses;

	/// For tests without a client: every client acknowledges every delta packet sent up to a tick.
	void TestAcknowledgeAll(uint32 upTo)
	{
		for (let client in mClients)
		{
			if (client.deltas == null)
			{
				if (!FieldDeltas || !OptimizeSnapshots)
					continue;
				client.deltas = new .();
			}
			for (int slot < DeltaPacketSlots)
			{
				if (client.deltas.packetObjects[slot] != null && !client.deltas.packetAcked[slot] && (int32)(upTo - client.deltas.packetTick[slot]) >= 0)
					client.deltas.Acknowledge(client.deltas.packetNumber[slot]);
			}
		}
	}

	/// Bytes the object id at the start of a record takes.
	static int IdLength(Span<uint8> record)
	{
		var reader = NetReader(record.Ptr, record.Length);
		ReadId(ref reader);
		return reader.Position;
	}

	/// Server, as a client's controls arrive with an acknowledgement on the end.
	void ReadAcknowledgements(ClientInfo client, ref NetReader reader)
	{
		let newest = reader.Read<uint16>();
		let maskBytes = (int)reader.Read<uint8>();
		if (!reader.Ok || maskBytes > 8)
			return;
		uint64 bits = 0;
		for (int i < maskBytes)
			bits |= (uint64)reader.Read<uint8>() << (i * 8);
		if (!reader.Ok)
			return;
		if (client.deltas == null)
		{
			if (!FieldDeltas || !OptimizeSnapshots)
				return;
			client.deltas = new .();
		}
		if (newest == 0)
			return;
		client.deltas.Acknowledge(newest);
		for (int k < maskBytes * 8)
		{
			if ((bits & ((uint64)1 << k)) != 0)
				client.deltas.Acknowledge((uint16)(newest - 1 - k));
		}
	}

	/// Server: a delta packet's header (the ordinary one, then the packet's number).
	void BeginDeltaPacket(ClientInfo client)
	{
		mWriter.Clear();
		mWriter.Write(MsgSnapshotDelta);
		mWriter.Write(mTick);
		mWriter.Write(client.lastProcessedTick);
		mWriter.Write((uint8)Math.Clamp(SnapshotInterval, 1, 255));
		mWriter.Write((int8)(client.starved > 0 ? -Math.Min(client.starved, 100) : Math.Min(client.queue.Count, 100)));
		mWriter.Write((uint16)0);
		let deltas = client.deltas;
		// Packet 0 is never used: a client that has had none yet says 0.
		if (deltas.nextPacket == 0)
			deltas.nextPacket = 1;
		deltas.currentPacket = deltas.nextPacket++;
		mWriter.Write(deltas.currentPacket);
		let slot = deltas.currentPacket % DeltaPacketSlots;
		if (deltas.packetObjects[slot] == null)
			deltas.packetObjects[slot] = new .();
		deltas.packetObjects[slot].Clear();
		deltas.packetNumber[slot] = deltas.currentPacket;
		deltas.packetTick[slot] = mTick;
		deltas.packetAcked[slot] = false;
	}

	/// Server: how a record goes to a delta client. Returns false when it is the same as one the client has and
	/// need not be said again (mayLeaveOut: not its own, and not one of the few repeats that tell a client an object
	/// has stopped); otherwise the encoded record is left in `into`.
	bool EncodeDelta(DeltaRing ring, Span<uint8> record, int idLength, bool mayLeaveOut, NetWriter into)
	{
		into.Clear();
		let body = Span<uint8>(record.Ptr + idLength, record.Length - idLength);
		let baseline = ring.Baseline();
		bool same = false;
		if (baseline >= 0)
		{
			let old = ring.Record(baseline);
			same = old.Length == body.Length && Internal.MemCmp(old.Ptr, body.Ptr, body.Length) == 0;
			// What a client shows of something it does not run itself is what it was sent, so that need not be sent
			// again. A body it predicts, or its own object, can drift from what it was sent (a collision it
			// predicted wrongly), so those go when due all the same, if only to say they are the same.
			let clientRuns = body.Length > 0 && (body[0] & (NetPack.FlagPredicted | NetPack.FlagFull)) != 0;
			if (same && mayLeaveOut && !clientRuns)
				return false;
		}
		into.Data.AddRange(Span<uint8>(record.Ptr, idLength));
		if (same)
		{
			// The same as the baseline: no length, no mask.
			into.WriteVarUInt((uint32)(mTick - ring.tick[baseline]));
			into.Write((uint8)0);
			return true;
		}
		if (baseline >= 0 && ring.length[baseline] == body.Length && body.Length <= DeltaRecordBytes)
		{
			let old = ring.Record(baseline);
			into.WriteVarUInt((uint32)(mTick - ring.tick[baseline]));
			into.Write((uint8)body.Length);
			let maskAt = into.Data.Count;
			let maskBytes = (body.Length + 7) / 8;
			for (int i < maskBytes)
				into.Write((uint8)0);
			for (int i < body.Length)
			{
				let difference = body[i] ^ old[i];
				if (difference != 0)
				{
					into.Data[maskAt + i / 8] |= (uint8)(1 << (i % 8));
					into.Write(difference);
				}
			}
			// Rarely, nearly everything differs: then the plain record is no bigger.
			if (into.Data.Count - idLength < body.Length + 2)
				return true;
			into.Data.Count = idLength;
		}
		into.WriteVarUInt(0);
		into.Write((uint8)Math.Min(body.Length, 255));
		into.Data.AddRange(body);
		return true;
	}

	/// Server: a record went out in the current packet; keep it until it is known to have arrived or is too old.
	void NoteDeltaSent(ClientInfo client, DeltaRing ring, uint32 netId, Span<uint8> record, int idLength)
	{
		if (record.Length - idLength > DeltaRecordBytes)
			return;
		let deltas = client.deltas;
		ring.Push(mTick, deltas.currentPacket, .(record.Ptr + idLength, record.Length - idLength));
		deltas.packetObjects[deltas.currentPacket % DeltaPacketSlots].Add(netId);
	}

	/// Server and client: an object is gone, and so are its baselines.
	void ForgetDeltas(uint32 netId)
	{
		if (mDeltaRings.GetAndRemove(netId) case .Ok(let pair))
			delete pair.value;
		for (let client in mClients)
		{
			if (client.deltas != null && client.deltas.rings.GetAndRemove(netId) case .Ok(let clientPair))
				delete clientPair.value;
		}
	}

	/// Client: a fresh session (joined, or resumed under a new host): nothing is known yet.
	void ResetDeltas()
	{
		for (let ring in mDeltaRings.Values)
			delete ring;
		mDeltaRings.Clear();
		mHaveDeltaPacket = false;
		mAckNewest = 0;
		mAckBits = 0;
		mAckSentNewest = default;
		mAckDirty = 0;
	}

	/// Client: rebuilds a delta packet into an ordinary snapshot part and reads it.
	void ReadDeltaSnapshot(ref NetReader reader)
	{
		let start = reader.Position;
		let serverTick = reader.Read<uint32>();
		reader.Read<uint32>();
		reader.Read<uint8>();
		reader.Read<int8>();
		let count = (int)reader.Read<uint16>();
		let number = reader.Read<uint16>();
		if (!reader.Ok)
			return;
		let rebuilt = mDeltaRebuilt;
		bool missed = false;
		rebuilt.Clear();
		rebuilt.Data.AddRange(Span<uint8>(reader.Start + start, 12));
		int written = 0;
		uint8[DeltaRecordBytes] scratch = default;
		for (int i < count)
		{
			let idAt = reader.Position;
			let netId = ReadId(ref reader);
			let idLength = reader.Position - idAt;
			let back = reader.ReadVarUInt();
			let length = (int)reader.Read<uint8>();
			if (!reader.Ok)
				return;
			Span<uint8> body;
			if (back == 0)
			{
				body = .(reader.Start + reader.Position, length);
				for (int b < length)
					reader.Read<uint8>();
			}
			else if (length == 0)
			{
				// The same as the baseline.
				DeltaRing ring = null;
				mDeltaRings.TryGetValue(netId, out ring);
				let slot = ring != null ? ring.AtTick((uint32)(serverTick - back)) : -1;
				if (slot < 0)
				{
					if (ring == null || !ring.IsStale((uint32)(serverTick - back)))
						DeltaMisses++;
					missed = true;
					continue;
				}
				Internal.MemCpy(&scratch[0], &ring.bytes[slot * DeltaRecordBytes], ring.length[slot]);
				body = .(&scratch[0], ring.length[slot]);
			}
			else
			{
				let maskBytes = (length + 7) / 8;
				let maskAt = reader.Position;
				for (int b < maskBytes)
					reader.Read<uint8>();
				DeltaRing ring = null;
				mDeltaRings.TryGetValue(netId, out ring);
				let slot = ring != null && length <= DeltaRecordBytes ? ring.AtTick((uint32)(serverTick - back)) : -1;
				let known = slot >= 0 && ring.length[slot] == length;
				for (int b < length)
				{
					let differs = (reader.Start[maskAt + b / 8] & (1 << (b % 8))) != 0;
					let difference = differs ? reader.Read<uint8>() : (uint8)0;
					if (known)
						scratch[b] = ring.bytes[slot * DeltaRecordBytes + b] ^ difference;
				}
				if (!known)
				{
					// A packet that took so long to come that newer ones pushed its baseline out has nothing to add.
					// Otherwise the baseline should be here: the server only uses ones this machine said it has.
					if (ring == null || !ring.IsStale((uint32)(serverTick - back)))
						DeltaMisses++;
					missed = true;
					continue;
				}
				body = .(&scratch[0], length);
			}
			if (!reader.Ok)
				return;
			if (body.Length <= DeltaRecordBytes)
			{
				if (mDeltaRings.TryAdd(netId, let key, let value))
					*value = new DeltaRing();
				(*value).Keep(serverTick, body);
			}
			rebuilt.Data.AddRange(Span<uint8>(reader.Start + idAt, idLength));
			rebuilt.Data.AddRange(body);
			written++;
		}
		// A packet with a record that could not be rebuilt is not acknowledged, so none of it becomes a baseline;
		// nor is an empty one (nothing in it to become one), though it shows the server is sending deltas.
		if (!missed && count > 0)
			NoteDeltaPacket(number);
		else if (!mHaveDeltaPacket)
		{
			mHaveDeltaPacket = true;
			mAckNewest = number;
			mAckSentNewest = .(number, number);
		}
		var written16 = (uint16)written;
		Internal.MemCpy(rebuilt.Data.Ptr + 10, &written16, 2);
		var again = NetReader(rebuilt.Data.Ptr, rebuilt.Data.Count);
		ReadSnapshot(ref again, true);
	}

	/// Client: a delta packet arrived; remember it for the next acknowledgement.
	void NoteDeltaPacket(uint16 number)
	{
		if (!mHaveDeltaPacket)
		{
			mHaveDeltaPacket = true;
			mAckNewest = number;
			mAckBits = 0;
			mAckSentNewest = .(number, number);
		}
		else
		{
			let ahead = (int16)(number - mAckNewest);
			if (ahead > 0)
			{
				mAckBits = ahead >= 64 ? 0 : (mAckBits << ahead) | ((uint64)1 << (ahead - 1));
				mAckNewest = number;
			}
			else if (ahead < 0 && -ahead <= 64)
				mAckBits |= (uint64)1 << (-ahead - 1);
		}
		// Said with the next controls; the one after says it again in its mask.
		mAckDirty = 1;
	}

	/// Client: after the controls, which delta packets arrived lately: the newest, and a mask of those before it
	/// back to the newest of two acknowledgements ago (so each packet is acknowledged at least twice over).
	void WriteAcknowledgements()
	{
		if (!mDeltasOffered)
			return;
		if (!mHaveDeltaPacket)
		{
			// Nothing to acknowledge yet: this says it can take delta packets.
			mWriter.Write((uint16)0);
			mWriter.Write((uint8)0);
			return;
		}
		if (mAckDirty <= 0)
			return;
		mAckDirty--;
		let span = Math.Clamp((int)(uint16)(mAckNewest - mAckSentNewest[1]) + 2, 1, 64);
		let maskBytes = (span + 7) / 8;
		mWriter.Write(mAckNewest);
		mWriter.Write((uint8)maskBytes);
		for (int i < maskBytes)
			mWriter.Write((uint8)(mAckBits >> (i * 8)));
		mAckSentNewest[1] = mAckSentNewest[0];
		mAckSentNewest[0] = mAckNewest;
	}
}
