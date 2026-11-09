using System;
using System.Collections;

namespace Tallow;

/// Server-authoritative replication of bare Flecs entities with [Sync] data (docs/unified-ecs-networking.md).
/// The entities have no GameObject, Transform or NetworkIdentity: each client makes entities of its own with the
/// same [Component] data, tied to the server's by a network id.
///
/// A MsgNativeEcs message is a run of records, each starting with its kind:
///   type     wire id, full name, field count, then each [Sync] field's name and size (0 for SharedString text)
///   full     net id, type count, then each type's wire id and all its fields (text: length, then bytes)
///   change   net id, type count, then each changed type's wire id, a bit per field, and the fields that changed
///   destroy  net id (deleted, or no longer in this client's area)
///   owner    net id, the client id whose controls run it (0: the server's)
///   ack      the last tick of this client's controls the server has run (for prediction)
/// A full record lists every synced type the entity has (a client removes the others). A change record holds the
/// fields that differ from the last state the server sent, which every client that holds the entity has: a client
/// given an entity later (it joined late, or the entity came into its area) is sent that same state whole. Each
/// client has its own stream of records (a NativeView on the server), reliable and in order.
extension NetworkManager
{
	const uint8 NativeRecordType = 1;
	const uint8 NativeRecordFull = 2;
	const uint8 NativeRecordChange = 3;
	const uint8 NativeRecordDestroy = 4;
	const uint8 NativeRecordOwner = 5;
	const uint8 NativeRecordAck = 6;
	const int NativeMaxTypes = 32;
	const int NativeMaxFields = 256;
	const int NativeMaxTextBytes = 1024;
	const int NativeMaxFieldBytes = 1024;
	/// Records are packed into messages of about this size.
	const int NativeMessageBytes = 1100;

	/// Server: bytes of bare entity state to send per snapshot. New entities and changes share it, each getting at
	/// least half while the other has something waiting; what does not fit goes in the next snapshot, in turn.
	public int32 NativeBytesPerSnapshot = 32 * 1024;
	/// Server: bytes per snapshot, for each client, of entities it is to be sent whole: those already there when it
	/// joined, and those that came into its area.
	public int32 NativeJoinBytesPerSnapshot = 32 * 1024;
	/// Server: how many entities are compared with what was last sent, per snapshot (round robin).
	public int32 NativeScanPerSnapshot = 16384;

	class NativeRow
	{
		public Entity entity;
		public uint32 netId;
		public int index;
		/// Its state has been sent, so last is what every client holding it has.
		public bool announced;
		/// The client whose controls run it (NativeSetOwner); 0: the server's.
		public int32 owner;
		public bool ownerChanged;
		/// It has a [SyncPosition] field, so only clients near position are sent it.
		public bool spatial;
		public Vector3 position;
		public List<uint8> last = new .() ~ delete _;
	}

	/// A synchronized type as the session sends it: its fields in wire order.
	class NativeType
	{
		/// Its ComponentTypes index on this machine, or -1 when this machine has no such synced type.
		public int32 index = -1;
		public String fullName = new .() ~ delete _;
		/// Each field's size on the wire (0 for text) and where it goes in this machine's struct (-1: a field this
		/// machine's type lacks, or has with another size).
		public List<(int32 wireSize, int32 offset)> fields = new .() ~ delete _;
		/// The fields' names (server: to describe the type again to a client that joins later).
		public List<String> names = new .() ~ DeleteContainerAndItems!(_);
	}

	/// Server: what one client holds and is still to be sent.
	class NativeView
	{
		public int32 clientId;
		/// The net ids it has been sent and not told to delete.
		public HashSet<uint32> known = new .() ~ delete _;
		/// To send whole when there is room (joined late, or came into its area), and the same as a set.
		public List<uint32> pending = new .() ~ delete _;
		public HashSet<uint32> queued = new .() ~ delete _;
		public int next;
		public NetWriter message = new .() ~ delete _;
		/// Where its player is, when the session filters by distance and it has one.
		public bool hasArea;
		public Vector3 at;
	}

	/// Native ECS replication state for one session.
	class NativeReplication
	{
		// Server
		public List<NativeRow> rows = new .() ~ DeleteContainerAndItems!(_);
		public Dictionary<uint64, NativeRow> byEntity = new .() ~ delete _;
		public Dictionary<uint32, NativeRow> byNetId = new .() ~ delete _;
		/// Net ids of rows not yet sent, oldest first (rows deleted meanwhile are passed over).
		public List<uint32> unannounced = new .() ~ delete _;
		public int unannouncedNext;
		public List<NativeView> views = new .() ~ DeleteContainerAndItems!(_);
		/// Rows a client owns: compared every snapshot, not in turn, so that its prediction is checked each time.
		public List<NativeRow> owned = new .() ~ delete _;
		public List<NativeRow> ownerChanges = new .() ~ delete _;
		/// The controls each owner's systems ran with last (for TickInput.previous).
		public Dictionary<int32, NetInput> previousInputs = new .() ~ delete _;
		/// ComponentTypes index to wire id, for the types described so far.
		public Dictionary<int32, uint32> wireIds = new .() ~ delete _;
		public int generation;
		public uint32 nextNetId = 1;
		public int cursor;
		// Both: the type table by wire id (server: what it described; client: what it was told).
		public List<NativeType> types = new .() ~ DeleteContainerAndItems!(_);
		// Client
		public Dictionary<uint32, Entity> remote = new .() ~ delete _;
		public Dictionary<uint64, uint32> remoteIds = new .() ~ delete _;
		/// Owners other than the server, by net id.
		public Dictionary<uint32, int32> owners = new .() ~ delete _;
		/// The replicas this client owns, which it predicts (NetworkManagerEcsPrediction.bf).
		public Dictionary<uint32, NativePredicted> predicted = new .() ~ DeleteDictionaryAndValues!(_);
		// Scratch
		public NetWriter state = new .() ~ delete _;
		public NetWriter record = new .() ~ delete _;
		public List<int32> present = new .() ~ delete _;
		// Totals since the session started
		public int64 bytes;
		public int64 fullRecords, changeRecords, destroyRecords;
		/// Server: entities sent to a client as they came into its area, and deleted there as they left it.
		public int64 entered, left;
		/// Client: predictions found wrong and run again, the ticks run again, and predictions started.
		public int64 corrections, replayedTicks, predictionStarts;
		public bool warnedTypes;
	}

	/// Server: bare entities with synced data. Client: replicas of the server's.
	public int NativeEntityCount => mNative == null ? 0 : (IsServer ? mNative.rows.Count : mNative.remote.Count);
	/// Server: entities not sent yet, and entities clients are still to be sent whole.
	public int NativeWaiting
	{
		get
		{
			if (mNative == null)
				return 0;
			int waiting = mNative.unannounced.Count - mNative.unannouncedNext;
			for (let view in mNative.views)
				waiting += view.pending.Count - view.next;
			return waiting;
		}
	}

	/// Server: how many bare entities a client holds (all of them, but for those outside its area).
	public int NativeHeldBy(int32 clientId)
	{
		let view = NativeViewOf(clientId);
		return view == null ? 0 : view.known.Count;
	}

	/// Server: whether a client has been sent a bare entity and holds it now.
	public bool NativeIsHeldBy(Entity entity, int32 clientId)
	{
		let view = NativeViewOf(clientId);
		if (view == null)
			return false;
		return mNative.byEntity.TryGetValue(entity.id, let row) && view.known.Contains(row.netId);
	}

	/// Server: entities sent to clients as they came into their area, and deleted there as they left it.
	public int64 NativeEntered => mNative?.entered ?? 0;
	public int64 NativeLeft => mNative?.left ?? 0;

	/// The client whose controls run a bare synced entity (its own on that client, which predicts it), or 0 for the
	/// server's. Either side.
	public int32 NativeOwner(Entity entity)
	{
		if (mNative == null)
			return 0;
		if (mNative.byEntity.TryGetValue(entity.id, let row))
			return row.owner;
		if (mNative.remoteIds.TryGetValue(entity.id, let netId) && mNative.owners.TryGetValue(netId, let owner))
			return owner;
		return 0;
	}

	/// Server: gives a bare synced entity to a client, or back to the server with 0. The native systems
	/// (AddNativeSystem) then run it on the server with that client's controls, as they come, and on that client at
	/// once, which predicts it: when what the server sends back differs from what it predicted for the same tick, it
	/// takes the server's state and runs the ticks since again (NetworkManagerEcsPrediction.bf).
	public void NativeSetOwner(Entity entity, int32 clientId)
	{
		if (mNative == null || !IsServer)
			return;
		NativeRow row;
		if (!mNative.byEntity.TryGetValue(entity.id, out row) || row.owner == clientId)
			return;
		if (row.owner != 0)
			mNative.owned.Remove(row);
		row.owner = clientId;
		if (clientId != 0)
			mNative.owned.Add(row);
		if (!row.ownerChanged)
			mNative.ownerChanges.Add(row);
		row.ownerChanged = true;
	}

	NativeView NativeViewOf(int32 clientId)
	{
		if (mNative == null)
			return null;
		for (let view in mNative.views)
		{
			if (view.clientId == clientId)
				return view;
		}
		return null;
	}

	/// Bytes of native ECS records sent (server) or received (client) this session.
	public int64 NativeBytes => mNative?.bytes ?? 0;

	/// The network id of a bare synced entity (the server's or a client's replica), or 0.
	public uint32 NativeNetId(Entity entity)
	{
		if (mNative == null)
			return 0;
		if (mNative.byEntity.TryGetValue(entity.id, let row))
			return row.netId;
		if (mNative.remoteIds.TryGetValue(entity.id, let netId))
			return netId;
		return 0;
	}

	/// A client's replica of the server entity with that network id, or a null Entity.
	public Entity NativeEntity(uint32 netId)
	{
		if (mNative != null && mNative.remote.TryGetValue(netId, let entity))
			return entity;
		if (mNative != null && mNative.byNetId.TryGetValue(netId, let row))
			return row.entity;
		return default;
	}

	// ---- server ----

	/// A bare entity was made or given synced data (World.CreateMany, Add, Ensure or Set).
	public void NativeCandidateAdded(Entity entity)
	{
		if (mNative == null || !IsServer || entity.IsNull || mNative.byEntity.ContainsKey(entity.id))
			return;
		NativeAddRow(entity, mNative.nextNetId++);
	}

	NativeRow NativeAddRow(Entity entity, uint32 netId)
	{
		let native = mNative;
		let row = new NativeRow();
		row.entity = entity;
		row.netId = netId;
		row.index = native.rows.Count;
		native.rows.Add(row);
		native.byEntity[entity.id] = row;
		native.byNetId[netId] = row;
		native.unannounced.Add(netId);
		return row;
	}

	void NativeRemoveRow(NativeRow row)
	{
		let native = mNative;
		if (row.owner != 0)
			native.owned.Remove(row);
		if (row.ownerChanged)
			native.ownerChanges.Remove(row);
		native.byEntity.Remove(row.entity.id);
		native.byNetId.Remove(row.netId);
		let last = native.rows.Count - 1;
		if (row.index != last)
		{
			native.rows[row.index] = native.rows[last];
			native.rows[row.index].index = row.index;
		}
		native.rows.RemoveAt(last);
		delete row;
	}

	/// World.Delete of a synced bare entity: it goes from every client holding it with the next snapshot.
	public void NativeCandidateRemoved(Entity entity)
	{
		if (mNative == null || !IsServer)
			return;
		NativeRow row;
		if (!mNative.byEntity.TryGetValue(entity.id, out row))
			return;
		NativeDestroyEverywhere(row.netId);
		NativeRemoveRow(row);
	}

	/// Tells every client holding the entity to delete it.
	void NativeDestroyEverywhere(uint32 netId)
	{
		let record = scope NetWriter();
		record.Write(NativeRecordDestroy);
		record.WriteVarUInt(netId);
		for (let view in mNative.views)
		{
			if (view.known.Remove(netId))
				NativeAppend(record, view);
		}
	}

	/// The wire id of a synced type, describing it to everyone first if this session has not yet.
	uint32 NativeWireId(DataComponents.Info info)
	{
		let native = mNative;
		if (native.wireIds.TryGetValue(info.index, let known))
			return known;
		let wireId = (uint32)native.types.Count;
		let type = new NativeType();
		type.index = info.index;
		type.fullName.Set(info.fullName);
		for (let field in info.syncedFields)
		{
			type.fields.Add((field.size, field.offset));
			type.names.Add(new String(field.name));
		}
		native.types.Add(type);
		native.wireIds[info.index] = wireId;
		// Ahead of the record that uses it, in every client's stream. A client that joins later is sent the table.
		let description = scope NetWriter();
		NativeWriteType(description, wireId, type);
		for (let view in native.views)
			NativeAppend(description, view);
		return wireId;
	}

	static void NativeWriteType(NetWriter into, uint32 wireId, NativeType type)
	{
		into.Clear();
		into.Write(NativeRecordType);
		into.WriteVarUInt(wireId);
		into.WriteString(type.fullName);
		into.WriteVarUInt((uint32)type.fields.Count);
		for (int i < type.fields.Count)
		{
			into.WriteString(type.names[i]);
			into.WriteVarUInt((uint32)type.fields[i].wireSize);
		}
	}

	/// The entity's synced data as the body of a full record (type count, then each type's wire id and fields), in
	/// into, noting where it is in row. False when it has none, or no longer exists.
	bool NativeEncode(World world, NativeRow row, NetWriter into)
	{
		let entity = row.entity;
		row.spatial = false;
		into.Clear();
		if (!world.IsAlive(entity))
			return false;
		into.Data.Add(0);
		int count = 0;
		for (let info in DataComponents.SyncedTypes)
		{
			let data = (uint8*)world.Get(entity, info.index);
			if (data == null)
				continue;
			if (count == NativeMaxTypes)
			{
				if (!mNative.warnedTypes)
					Log.Warning(scope $"A bare ECS entity has more than {NativeMaxTypes} synchronized types; the rest are not sent.");
				mNative.warnedTypes = true;
				break;
			}
			into.WriteVarUInt(NativeWireId(info));
			if (info.positionOffset >= 0)
			{
				row.spatial = true;
				row.position = *(Vector3*)(data + info.positionOffset);
			}
			for (let field in info.syncedFields)
			{
				if (field.size > 0)
				{
					into.Data.AddRange(Span<uint8>(data + field.offset, field.size));
					continue;
				}
				let text = ((SharedString*)(data + field.offset)).View;
				let length = Math.Min(text.Length, NativeMaxTextBytes);
				into.WriteVarUInt((uint32)length);
				into.Data.AddRange(Span<uint8>((uint8*)text.Ptr, length));
			}
			count++;
		}
		into.Data[0] = (uint8)count;
		return count > 0;
	}

	static uint32 NativeVar(List<uint8> data, ref int at)
	{
		uint32 value = 0;
		for (int shift = 0; shift < 35 && at < data.Count; shift += 7)
		{
			let part = data[at++];
			value |= (uint32)(part & 0x7F) << shift;
			if ((part & 0x80) == 0)
				break;
		}
		return value;
	}

	static void NativeEncodeFull(uint32 netId, List<uint8> body, NetWriter into)
	{
		into.Clear();
		into.Write(NativeRecordFull);
		into.WriteVarUInt(netId);
		into.Data.AddRange(body);
	}

	/// A change record in into: the fields of now that differ from row.last, which every client holding the entity
	/// has. False when the two list different types, which takes a full record.
	bool NativeEncodeChange(NativeRow row, List<uint8> now, NetWriter into)
	{
		let old = row.last;
		if (old.IsEmpty || now.IsEmpty || old[0] != now[0])
			return false;
		let types = mNative.types;
		into.Clear();
		into.Write(NativeRecordChange);
		into.WriteVarUInt(row.netId);
		let countAt = into.Data.Count;
		into.Data.Add(0);
		int changedTypes = 0;
		int a = 1;
		int b = 1;
		for (int t < now[0])
		{
			let wireA = NativeVar(old, ref a);
			let wireB = NativeVar(now, ref b);
			if (wireA != wireB || wireB >= (uint32)types.Count)
				return false;
			let type = types[(int)wireB];
			let typeStart = b;
			uint8[NativeMaxFields / 8] mask = default;
			bool changed = false;
			for (int f < type.fields.Count)
			{
				let size = (int)type.fields[f].wireSize;
				int lengthA = size;
				int lengthB = size;
				if (size == 0)
				{
					lengthA = (int)NativeVar(old, ref a);
					lengthB = (int)NativeVar(now, ref b);
				}
				if (lengthA != lengthB || Internal.MemCmp(old.Ptr + a, now.Ptr + b, lengthB) != 0)
				{
					mask[f >> 3] |= (uint8)(1 << (f & 7));
					changed = true;
				}
				a += lengthA;
				b += lengthB;
			}
			if (!changed)
				continue;
			changedTypes++;
			into.WriteVarUInt(wireB);
			for (int i < (type.fields.Count + 7) / 8)
				into.Data.Add(mask[i]);
			var at = typeStart;
			for (int f < type.fields.Count)
			{
				let fieldStart = at;
				int length = type.fields[f].wireSize;
				if (length == 0)
					length = (int)NativeVar(now, ref at);
				at += length;
				// A text field goes with its length.
				if ((mask[f >> 3] & (1 << (f & 7))) != 0)
					into.Data.AddRange(Span<uint8>(now.Ptr + fieldStart, at - fieldStart));
			}
		}
		into.Data[countAt] = (uint8)changedTypes;
		return true;
	}

	/// Adds a record to a client's stream, sending what is there first if it would make the message too big.
	void NativeAppend(NetWriter record, NativeView view)
	{
		let native = mNative;
		if (view.message.Data.Count + record.Data.Count > NativeMessageBytes)
			NativeFlush(view);
		view.message.Data.AddRange(record.Data);
		switch (record.Data[0])
		{
		case NativeRecordFull: native.fullRecords++;
		case NativeRecordChange: native.changeRecords++;
		case NativeRecordDestroy: native.destroyRecords++;
		default:
		}
	}

	void NativeFlush(NativeView view)
	{
		if (view.message.Data.IsEmpty)
			return;
		SendToClient(view.clientId, NetworkSync.MsgNativeEcs, view.message);
		mNative.bytes += view.message.Data.Count;
		view.message.Clear();
	}

	/// Whether a client should hold the entity: everyone should one without a [SyncPosition] field, and its owner;
	/// others only near it, leaving only further away (RelevanceHysteresis), as Nearby objects do.
	bool NativeRelevant(NativeView view, NativeRow row, bool held)
	{
		if (!row.spatial || !view.hasArea || row.owner == view.clientId)
			return true;
		let radius = held ? SnapshotRelevanceRadius * Math.Max(RelevanceHysteresis, 1) : SnapshotRelevanceRadius;
		return (row.position - view.at).LengthSquared <= radius * radius;
	}

	/// Queues an entity to be sent to a client whole.
	static void NativeQueue(NativeView view, uint32 netId)
	{
		if (view.queued.Add(netId))
			view.pending.Add(netId);
	}

	/// Sends a row's last state whole to a client (and who owns it, if a client does).
	void NativeSendWhole(NativeView view, NativeRow row, NetWriter record)
	{
		NativeEncodeFull(row.netId, row.last, record);
		NativeAppend(record, view);
		view.known.Add(row.netId);
		if (row.owner != 0)
			NativeAppendOwner(view, row);
	}

	void NativeAppendOwner(NativeView view, NativeRow row)
	{
		let record = scope NetWriter();
		record.Write(NativeRecordOwner);
		record.WriteVarUInt(row.netId);
		record.WriteVarUInt((uint32)row.owner);
		NativeAppend(record, view);
	}

	/// After a row was compared with what was last sent: the change (if any) goes to the clients holding it that
	/// should still; the others holding it are told to delete it, and those it should reach now are queued for it.
	void NativeDeliver(NativeRow row, NetWriter change)
	{
		let native = mNative;
		NetWriter destroy = null;
		for (let view in native.views)
		{
			let held = view.known.Contains(row.netId);
			let relevant = NativeRelevant(view, row, held);
			if (held && relevant)
			{
				if (change != null)
					NativeAppend(change, view);
			}
			else if (held)
			{
				if (destroy == null)
				{
					destroy = scope:: NetWriter();
					destroy.Write(NativeRecordDestroy);
					destroy.WriteVarUInt(row.netId);
				}
				NativeAppend(destroy, view);
				view.known.Remove(row.netId);
				native.left++;
			}
			else if (relevant)
				NativeQueue(view, row.netId);
		}
	}

	/// Server, each snapshot: destroys; new entities and changes within NativeBytesPerSnapshot; then, for clients that
	/// joined late, the entities that were already there.
	public void NativeServerTick()
	{
		let native = mNative;
		if (native == null || !IsServer)
			return;
		// After a script reload the types may be laid out differently: describe them again and send everything whole.
		if (native.generation != DataComponents.Generation)
			NativeRestartTypes();
		let world = Scene.World;
		// Where each client's player is, for entities with a [SyncPosition].
		for (let view in native.views)
		{
			let player = SnapshotRelevanceRadius > 0 ? PlayerObject(view.clientId) : null;
			view.hasArea = player != null;
			if (player != null)
				view.at = player.Transform.Position;
		}
		for (let row in native.ownerChanges)
		{
			row.ownerChanged = false;
			if (!row.announced)
				continue;
			for (let view in native.views)
			{
				if (view.known.Contains(row.netId))
					NativeAppendOwner(view, row);
			}
		}
		native.ownerChanges.Clear();
		let budget = Math.Max((int)NativeBytesPerSnapshot, 1);
		int used = 0;
		int scanned = 0;
		// What clients own is compared every snapshot, ahead of the rest: their prediction is checked against it.
		for (int i = native.owned.Count - 1; i >= 0; i--)
		{
			if (i < native.owned.Count && native.owned[i].announced)
				NativeCompare(world, native.owned[i], ref used);
		}
		// Changes and new entities each get at least half while the other is waiting, and the whole otherwise.
		let newWaiting = native.unannouncedNext < native.unannounced.Count;
		NativeSendChanges(world, newWaiting ? budget / 2 : budget, ref used, ref scanned);
		NativeSendNew(world, budget, ref used);
		NativeSendChanges(world, budget, ref used, ref scanned);
		for (let view in native.views)
		{
			NativeSendPending(view);
			// After this snapshot's records: the server's state of what the client owns, as of this tick of its
			// controls.
			bool owns = false;
			for (let row in native.owned)
				owns |= row.owner == view.clientId && view.known.Contains(row.netId);
			if (owns)
			{
				let record = native.record;
				record.Clear();
				record.Write(NativeRecordAck);
				record.Write(NativeAckTick(view.clientId));
				NativeAppend(record, view);
			}
			NativeFlush(view);
		}
	}

	uint32 NativeAckTick(int32 clientId)
	{
		for (let client in mClients)
		{
			if (client.id == clientId)
				return client.lastProcessedTick;
		}
		return 0;
	}

	/// Compares a row with what was last sent and delivers the difference. False when the entity is gone (its row
	/// too, and clients holding it are told).
	bool NativeCompare(World world, NativeRow row, ref int used)
	{
		let native = mNative;
		let state = native.state;
		let record = native.record;
		if (!NativeEncode(world, row, state))
		{
			// Deleted outside World.Delete, or its last synced type was removed: it goes from the clients.
			NativeDestroyEverywhere(row.netId);
			used += 4;
			world.ForgetNativeCandidate(row.entity);
			NativeRemoveRow(row);
			return false;
		}
		let now = state.Data;
		if (now.Count == row.last.Count && Internal.MemCmp(now.Ptr, row.last.Ptr, now.Count) == 0)
		{
			// Unchanged; the clients near it may not be.
			if (row.spatial)
				NativeDeliver(row, null);
			return true;
		}
		if (!NativeEncodeChange(row, now, record))
			NativeEncodeFull(row.netId, now, record);
		row.last.Clear();
		row.last.AddRange(now);
		NativeDeliver(row, record);
		used += record.Data.Count;
		return true;
	}

	/// Compares rows with what was last sent, round robin from where the last snapshot stopped, and sends change records
	/// until used reaches limit. It stops at the first one that does not fit, which goes first next time.
	void NativeSendChanges(World world, int limit, ref int used, ref int scanned)
	{
		let native = mNative;
		while (scanned < Math.Min(NativeScanPerSnapshot, native.rows.Count) && used < limit)
		{
			if (native.cursor >= native.rows.Count)
				native.cursor = 0;
			let row = native.rows[native.cursor];
			scanned++;
			// A new one goes whole, from the queue; an owned one was compared already.
			if (!row.announced || row.owner != 0)
			{
				native.cursor++;
				continue;
			}
			// A change bigger than what is left waits for the next snapshot, first in line (unless nothing went yet).
			if (used > 0 && used + row.last.Count + 8 > limit)
			{
				scanned--;
				break;
			}
			// When it is gone, the last row moves into this place, so the cursor stays.
			if (NativeCompare(world, row, ref used))
				native.cursor++;
		}
	}

	/// Sends new entities whole, oldest first, until used reaches limit.
	void NativeSendNew(World world, int limit, ref int used)
	{
		let native = mNative;
		let state = native.state;
		let record = native.record;
		while (native.unannouncedNext < native.unannounced.Count && used < limit)
		{
			let netId = native.unannounced[native.unannouncedNext];
			if (!native.byNetId.TryGetValue(netId, let row) || row.announced)
			{
				native.unannouncedNext++;
				continue;
			}
			if (!NativeEncode(world, row, state))
			{
				// Gone before it was ever sent (or sent again after a reload): clients holding it are told.
				NativeDestroyEverywhere(row.netId);
				world.ForgetNativeCandidate(row.entity);
				NativeRemoveRow(row);
				native.unannouncedNext++;
				continue;
			}
			NativeEncodeFull(netId, state.Data, record);
			if (used > 0 && used + record.Data.Count > limit)
				break;
			used += record.Data.Count;
			row.last.Clear();
			row.last.AddRange(state.Data);
			row.announced = true;
			native.unannouncedNext++;
			// To every client it should reach; one holding it from before a reload but out of its area now is told.
			NetWriter destroy = null;
			for (let view in native.views)
			{
				let held = view.known.Contains(netId);
				if (NativeRelevant(view, row, held))
				{
					NativeAppend(record, view);
					view.known.Add(netId);
					if (row.owner != 0)
						NativeAppendOwner(view, row);
				}
				else if (held)
				{
					if (destroy == null)
					{
						destroy = scope:: NetWriter();
						destroy.Write(NativeRecordDestroy);
						destroy.WriteVarUInt(netId);
					}
					NativeAppend(destroy, view);
					view.known.Remove(netId);
				}
			}
		}
		if (native.unannouncedNext >= 1024 && native.unannouncedNext * 2 >= native.unannounced.Count)
		{
			native.unannounced.RemoveRange(0, native.unannouncedNext);
			native.unannouncedNext = 0;
		}
	}

	/// Sends a client part of what it is to be sent whole (joined late, or came into its area), as the other
	/// clients hold it, up to NativeJoinBytesPerSnapshot.
	void NativeSendPending(NativeView view)
	{
		let native = mNative;
		let record = native.record;
		let limit = Math.Max((int)NativeJoinBytesPerSnapshot, 1);
		int used = 0;
		while (view.next < view.pending.Count && used < limit)
		{
			let netId = view.pending[view.next];
			// Deleted since, to be sent to everyone whole, held already, or out of its area again (found again when
			// it comes back).
			if (!native.byNetId.TryGetValue(netId, let row) || !row.announced || view.known.Contains(netId) || !NativeRelevant(view, row, false))
			{
				view.queued.Remove(netId);
				view.next++;
				continue;
			}
			if (used > 0 && used + row.last.Count + 8 > limit)
				break;
			NativeSendWhole(view, row, record);
			native.entered++;
			used += record.Data.Count;
			view.queued.Remove(netId);
			view.next++;
		}
		if (view.next >= 1024 && view.next * 2 >= view.pending.Count)
		{
			view.pending.RemoveRange(0, view.next);
			view.next = 0;
		}
	}

	/// A client joined: it is told the types now, and sent the entities already there over the next snapshots.
	public void NativeClientJoined(int32 clientId)
	{
		let native = mNative;
		if (native == null || !IsServer)
			return;
		NativeClientLeft(clientId);
		let view = new NativeView();
		view.clientId = clientId;
		native.views.Add(view);
		for (int wireId < native.types.Count)
		{
			NativeWriteType(native.record, (uint32)wireId, native.types[wireId]);
			NativeAppend(native.record, view);
		}
		NativeFlush(view);
		// In the order they were made.
		let ids = scope List<uint32>();
		for (let row in native.rows)
		{
			if (row.announced)
				ids.Add(row.netId);
		}
		ids.Sort();
		for (let netId in ids)
			NativeQueue(view, netId);
	}

	public void NativeClientLeft(int32 clientId)
	{
		if (mNative == null)
			return;
		for (int i = mNative.views.Count - 1; i >= 0; i--)
		{
			if (mNative.views[i].clientId == clientId)
			{
				delete mNative.views[i];
				mNative.views.RemoveAt(i);
			}
		}
		mNative.previousInputs.Remove(clientId);
	}

	/// After a script reload: the types are described again (perhaps laid out differently) and every entity goes whole.
	void NativeRestartTypes()
	{
		let native = mNative;
		native.generation = DataComponents.Generation;
		ClearAndDeleteItems!(native.types);
		native.wireIds.Clear();
		// Everyone is sent everything again, whole, once the new descriptions are out.
		for (let view in native.views)
		{
			view.pending.Clear();
			view.queued.Clear();
			view.next = 0;
		}
		native.unannounced.Clear();
		native.unannouncedNext = 0;
		for (let row in native.rows)
		{
			row.last.Clear();
			row.announced = false;
			native.unannounced.Add(row.netId);
		}
		native.unannounced.Sort();
	}

	/// The session started (either side). On the server, bare entities with synced data made before it are sent too.
	public void NativeStart()
	{
		if (mNative == null)
			mNative = new NativeReplication();
		Scene.World.NativeNetwork = this;
		if (!IsServer)
			return;
		mNative.generation = DataComponents.Generation;
		// Oldest first, so that net ids follow the order the entities were made in.
		let ids = scope List<uint64>(Scene.World.NativeCandidates.GetEnumerator());
		ids.Sort();
		for (let id in ids)
			NativeCandidateAdded(.(id));
	}

	/// The session ended: a client's replicas are deleted (they are not GameObjects, so nothing else would).
	public void NativeStop()
	{
		let world = mScene?.World;
		if (world != null && world.NativeNetwork == this)
			world.NativeNetwork = null;
		if (mNative == null)
			return;
		if (world != null)
		{
			for (let entity in mNative.remote.Values)
			{
				if (world.IsAlive(entity))
					world.Delete(entity);
			}
		}
		DeleteAndNullify!(mNative);
	}

	/// This client became the host: the replicas it holds become its own entities, under the same net ids and
	/// owners (its own the server's now), and go whole to everyone who comes back.
	void NativeBecameHost(int32 oldId)
	{
		let native = mNative;
		if (native == null)
			return;
		let world = Scene.World;
		let ids = scope List<uint32>(native.remote.Keys);
		ids.Sort();
		uint32 highest = 0;
		for (let netId in ids)
		{
			let entity = native.remote[netId];
			highest = Math.Max(highest, netId);
			if (world.IsAlive(entity) && !native.byEntity.ContainsKey(entity.id))
			{
				let row = NativeAddRow(entity, netId);
				if (native.owners.TryGetValue(netId, let owner) && owner != oldId)
				{
					row.owner = owner;
					native.owned.Add(row);
				}
			}
		}
		native.remote.Clear();
		native.remoteIds.Clear();
		native.owners.Clear();
		for (let predicted in native.predicted.Values)
			delete predicted;
		native.predicted.Clear();
		native.nextNetId = Math.Max(native.nextNetId, highest + 1);
		// The table described the old host's types.
		ClearAndDeleteItems!(native.types);
		native.wireIds.Clear();
		native.generation = DataComponents.Generation;
		// Its own bare synced entities join them.
		let own = scope List<uint64>(world.NativeCandidates.GetEnumerator());
		own.Sort();
		for (let id in own)
			NativeCandidateAdded(.(id));
	}

	// ---- client ----

	/// Client: a new host took this machine (back): the replicas from before go, and the new host sends everything.
	void NativeResetReplicas()
	{
		let native = mNative;
		if (native == null)
			return;
		let world = Scene.World;
		for (let entity in native.remote.Values)
		{
			if (world.IsAlive(entity))
				world.Delete(entity);
		}
		native.remote.Clear();
		native.remoteIds.Clear();
		native.owners.Clear();
		for (let predicted in native.predicted.Values)
			delete predicted;
		native.predicted.Clear();
		ClearAndDeleteItems!(native.types);
	}

	public static void OnNativeMessage(int32 sender, ref NetReader reader)
	{
		// Poll sets Dispatching to the session that received this; Scene.Active can be another scene while
		// switching levels.
		let network = NetworkManager.Dispatching;
		// The server never takes ECS state from clients.
		if (network == null || !network.IsClient || network.mNative == null)
			return;
		network.mNative.bytes += reader.Remaining;
		while (reader.Ok && reader.Remaining > 0)
		{
			switch (reader.Read<uint8>())
			{
			case NativeRecordType: network.NativeReadType(ref reader);
			case NativeRecordFull: network.NativeReadFull(ref reader);
			case NativeRecordChange: network.NativeReadChange(ref reader);
			case NativeRecordDestroy: network.NativeReadDestroy(ref reader);
			case NativeRecordOwner: network.NativeReadOwner(ref reader);
			case NativeRecordAck: network.NativeReconcile(reader.Read<uint32>());
			default: reader.Ok = false;
			}
		}
	}

	void NativeReadType(ref NetReader reader)
	{
		let native = mNative;
		let wireId = reader.ReadVarUInt();
		let name = scope String();
		reader.ReadString(name);
		let fieldCount = reader.ReadVarUInt();
		if (!reader.Ok || wireId >= 4096 || fieldCount > NativeMaxFields)
		{
			reader.Ok = false;
			return;
		}
		let type = new NativeType();
		type.fullName.Set(name);
		let info = DataComponents.Find(name);
		if (info != null && info.synced)
			type.index = info.index;
		let fieldName = scope String();
		for (int i < fieldCount)
		{
			fieldName.Clear();
			reader.ReadString(fieldName);
			let wireSize = (int32)reader.ReadVarUInt();
			if (wireSize > NativeMaxFieldBytes)
				reader.Ok = false;
			int32 offset = -1;
			if (info != null)
			{
				for (let field in info.syncedFields)
				{
					if (field.name == fieldName && field.size == wireSize)
						offset = field.offset;
				}
			}
			type.fields.Add((wireSize, offset));
		}
		if (!reader.Ok)
		{
			delete type;
			return;
		}
		while (native.types.Count <= (int)wireId)
			native.types.Add(null);
		delete native.types[(int)wireId];
		native.types[(int)wireId] = type;
	}

	NativeType NativeTypeOf(uint32 wireId) => wireId < (uint32)mNative.types.Count ? mNative.types[(int)wireId] : null;

	/// Reads one type's fields (those set in mask, or every one without a mask) into data; null data reads past them.
	static void NativeReadFields(ref NetReader reader, NativeType type, uint8* data, uint8* mask)
	{
		for (int f < type.fields.Count)
		{
			if (mask != null && (mask[f >> 3] & (1 << (f & 7))) == 0)
				continue;
			let (wireSize, offset) = type.fields[f];
			int length = wireSize;
			if (wireSize == 0)
			{
				length = (int)reader.ReadVarUInt();
				if (length > NativeMaxTextBytes)
					reader.Ok = false;
			}
			if (!reader.Ok || reader.Remaining < length)
			{
				reader.Ok = false;
				return;
			}
			let bytes = reader.Start + reader.Position;
			if (data != null && offset >= 0)
			{
				if (wireSize > 0)
					Internal.MemCpy(data + offset, bytes, wireSize);
				else
					*(SharedString*)(data + offset) = StringView((char8*)bytes, length);
			}
			reader.Skip(length);
		}
	}

	void NativeReadFull(ref NetReader reader)
	{
		let native = mNative;
		let world = Scene.World;
		let netId = reader.ReadVarUInt();
		let count = (int)reader.Read<uint8>();
		if (!reader.Ok || count > NativeMaxTypes)
		{
			reader.Ok = false;
			return;
		}
		bool created = false;
		Entity entity;
		if (!native.remote.TryGetValue(netId, out entity) || !world.IsAlive(entity))
		{
			entity = world.Create();
			created = true;
		}
		// One this client predicts takes the record into the server's state kept for it, not what it shows.
		let predicted = created ? null : NativePredictedAt(netId);
		if (predicted != null)
			NativeBeginServerState(predicted);
		defer
		{
			if (predicted != null)
				NativeEndServerState(predicted);
		}
		let present = native.present;
		present.Clear();
		for (int t < count)
		{
			let type = NativeTypeOf(reader.ReadVarUInt());
			if (type == null)
			{
				reader.Ok = false;
				break;
			}
			uint8* data = null;
			if (type.index >= 0)
			{
				data = (uint8*)world.Ensure(entity, type.index);
				present.Add(type.index);
			}
			NativeReadFields(ref reader, type, data, null);
		}
		if (!reader.Ok)
		{
			if (created)
				world.Delete(entity);
			return;
		}
		// Synced types the server's entity no longer has go; this machine's own local-only data stays.
		for (let info in DataComponents.SyncedTypes)
		{
			if (!present.Contains(info.index) && world.Has(entity, info.index))
				world.Remove(entity, info.index);
		}
		native.remote[netId] = entity;
		native.remoteIds[entity.id] = netId;
	}

	void NativeReadChange(ref NetReader reader)
	{
		let world = Scene.World;
		let netId = reader.ReadVarUInt();
		let count = (int)reader.Read<uint8>();
		if (!reader.Ok || count > NativeMaxTypes)
		{
			reader.Ok = false;
			return;
		}
		// One this client does not hold is read past.
		Entity entity = default;
		let known = mNative.remote.TryGetValue(netId, out entity) && world.IsAlive(entity);
		let predicted = known ? NativePredictedAt(netId) : null;
		if (predicted != null)
			NativeBeginServerState(predicted);
		defer
		{
			if (predicted != null)
				NativeEndServerState(predicted);
		}
		uint8[NativeMaxFields / 8] mask = default;
		for (int t < count)
		{
			let type = NativeTypeOf(reader.ReadVarUInt());
			if (type == null)
			{
				reader.Ok = false;
				return;
			}
			for (int i < (type.fields.Count + 7) / 8)
				mask[i] = reader.Read<uint8>();
			uint8* data = null;
			if (known && type.index >= 0)
				data = (uint8*)world.Ensure(entity, type.index);
			NativeReadFields(ref reader, type, data, &mask[0]);
		}
	}

	void NativeReadDestroy(ref NetReader reader)
	{
		let netId = reader.ReadVarUInt();
		if (!reader.Ok)
			return;
		mNative.owners.Remove(netId);
		if (mNative.predicted.GetAndRemove(netId) case .Ok(let predicted))
			delete predicted.value;
		if (mNative.remote.GetAndRemove(netId) case .Ok(let pair))
		{
			mNative.remoteIds.Remove(pair.value.id);
			if (Scene.World.IsAlive(pair.value))
				Scene.World.Delete(pair.value);
		}
	}

	void NativeReadOwner(ref NetReader reader)
	{
		let netId = reader.ReadVarUInt();
		let owner = (int32)reader.ReadVarUInt();
		if (!reader.Ok)
			return;
		if (owner == 0)
			mNative.owners.Remove(netId);
		else
			mNative.owners[netId] = owner;
		let mine = owner == LocalClientId && LocalClientId > 0;
		if (!mine)
		{
			if (mNative.predicted.GetAndRemove(netId) case .Ok(let pair))
				delete pair.value;
		}
		else if (!mNative.predicted.ContainsKey(netId) && mNative.remote.TryGetValue(netId, let entity))
			NativeStartPredicting(netId, entity);
	}
}
