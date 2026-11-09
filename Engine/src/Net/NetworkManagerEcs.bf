using System;
using System.Collections;

namespace Tallow;

/// Server-authoritative replication of bare Flecs entities with [Sync] data.
/// These entities deliberately have no GameObject, Transform or NetworkIdentity.
extension NetworkManager
{
	const int NativeBatchLimit = 1000;
	const int NativeScanPerSnapshot = 512;
	const int NativeMaxTypes = 32;
	const int NativeMaxFields = 64;
	const int NativeMaxFieldBytes = 1024;

	class NativeRow
	{
		public Entity entity;
		public uint32 netId;
		public int index;
		/// A replica may have been sent to a late joiner before its first broadcast.
		public bool announced;
		public List<uint8> last = new .() ~ delete _;
	}

	List<NativeRow> mNativeRows = new .() ~ DeleteContainerAndItems!(_);
	Dictionary<uint64, NativeRow> mNativeByEntity = new .() ~ delete _;
	Dictionary<uint32, Entity> mNativeRemote = new .() ~ delete _;
	uint32 mNativeNextId = 1;
	int mNativeCursor;
	NetWriter mNativeBatch = new .() ~ delete _;
	int mNativeBatchCount;

	/// A synced bare entity created with World.CreateMany, Add, Ensure or Set.
	/// Called only when its type has a supported [Sync] field.
	public void NativeCandidateAdded(Entity entity)
	{
		if (!IsServer || entity.IsNull || mNativeByEntity.ContainsKey(entity.id))
			return;
		let row = new NativeRow();
		row.entity = entity;
		row.netId = mNativeNextId++;
		row.index = mNativeRows.Count;
		mNativeRows.Add(row);
		mNativeByEntity[entity.id] = row;
	}

	void NativeRemoveRow(NativeRow row)
	{
		mNativeByEntity.Remove(row.entity.id);
		let last = mNativeRows.Count - 1;
		if (row.index != last)
		{
			mNativeRows[row.index] = mNativeRows[last];
			mNativeRows[row.index].index = row.index;
		}
		mNativeRows.RemoveAt(last);
		if (mNativeCursor > mNativeRows.Count)
			mNativeCursor = 0;
		delete row;
	}

	/// Called before World.Delete: a destroyed bare entity must disappear on clients.
	public void NativeCandidateRemoved(Entity entity)
	{
		if (!IsServer || !mNativeByEntity.TryGetValue(entity.id, let row))
			return;
		// An entity that was never sent need not produce a destroy packet.
		if (row.announced)
			NativeQueueDestroy(row.netId, -1);
		// Flush at the next snapshot, not once per entity deletion.
		// A large bulk despawn otherwise becomes thousands of packets.
		NativeRemoveRow(row);
	}

	/// Collects all supported [Sync] fields, with stable component and field names.
	/// No full component memory blobs or pointers are sent over the wire.
	static bool NativeSerialize(World world, Entity entity, NetWriter writer)
	{
		writer.Clear();
		if (!world.IsAlive(entity) || world.IsSceneObject(entity))
			return false;
		let indices = scope List<int32>();
		world.TypesOf(entity, indices);
		let types = scope List<DataComponents.Info>();
		for (let index in indices)
		{
			let info = DataComponents.Find(index);
			if (info != null && info.synced && world.Get(entity, index) != null)
				types.Add(info);
		}
		if (types.IsEmpty)
			return false;
		types.Sort(scope (a, b) => a.fullName.CompareTo(b.fullName));
		if (types.Count > NativeMaxTypes)
		{
			Log.Warning("Bare ECS entity has more synchronized types than the native ECS protocol supports.");
			return false;
		}
		writer.Write((uint8)types.Count);
		for (let info in types)
		{
			writer.WriteString(info.fullName);
			let fields = scope List<FieldRef>();
			DataComponents.GetFields(info.type, world.Get(entity, info.index), fields);
			fields.Sort(scope (a, b) => a.name.CompareTo(b.name));
			int count = 0;
			for (let field in fields)
				if (field.sync && (NetworkSync.SizeOf(field) > 0 || field.kind == .String))
					count++;
			if (count > NativeMaxFields)
			{
				Log.Warning("Bare ECS component has too many synchronized fields.");
				return false;
			}
			writer.Write((uint8)count);
			for (let field in fields)
			{
				if (!field.sync)
					continue;
				let size = NetworkSync.SizeOf(field);
				if (size == 0 && field.kind != .String)
					continue;
				writer.WriteString(field.name);
				if (field.kind == .String)
				{
					let text = StringFields.Get(field.ptr, field.type);
					let length = Math.Min(text.Length, NativeMaxFieldBytes);
					writer.Write((uint16)length);
					writer.Data.AddRange(Span<uint8>((uint8*)text.Ptr, length));
				}
				else
				{
					writer.Write((uint16)size);
					writer.Data.AddRange(Span<uint8>((uint8*)field.ptr, size));
				}
			}
		}
		return true;
	}

	void NativeFlush(int32 toClient)
	{
		if (mNativeBatchCount == 0)
			return;
		mNativeBatch.Data[0] = (uint8)mNativeBatchCount;
		if (toClient < 0)
			SendToAll(NetworkSync.MsgNativeEcs, mNativeBatch);
		else
			SendToClient(toClient, NetworkSync.MsgNativeEcs, mNativeBatch);
		mNativeBatch.Clear();
		mNativeBatchCount = 0;
	}

	void NativeQueue(uint8 operation, uint32 netId, Span<uint8> data, int32 toClient)
	{
		let needed = 5 + data.Length;
		if (mNativeBatchCount >= 255 || (mNativeBatchCount > 0 && mNativeBatch.Data.Count + needed > NativeBatchLimit))
			NativeFlush(toClient);
		if (mNativeBatchCount == 0)
			mNativeBatch.Write((uint8)0);
		mNativeBatch.Write(operation);
		mNativeBatch.Write(netId);
		if (operation == 1)
			mNativeBatch.Data.AddRange(data);
		mNativeBatchCount++;
	}

	void NativeQueueState(NativeRow row, int32 toClient)
	{
		NativeQueue(1, row.netId, row.last, toClient);
		row.announced = true;
	}

	void NativeQueueDestroy(uint32 netId, int32 toClient) =>
		NativeQueue(2, netId, default, toClient);

	/// Send only changed native ECS state, in bounded batches. This shares
	/// the session's normal snapshot cadence but does not claim prediction.
	public void NativeServerTick()
	{
		if (!IsServer)
			return;
		if (mNativeRows.IsEmpty)
		{
			NativeFlush(-1); // pending bulk despawns
			return;
		}
		let state = scope NetWriter();
		let toCheck = Math.Min(NativeScanPerSnapshot, mNativeRows.Count);
		int checkedCount = 0;
		while (checkedCount < toCheck && !mNativeRows.IsEmpty)
		{
			if (mNativeCursor >= mNativeRows.Count)
				mNativeCursor = 0;
			let row = mNativeRows[mNativeCursor];
			if (!NativeSerialize(Scene.World, row.entity, state))
			{
				// Removed [Sync] data or an entity destroyed outside World.Delete.
				if (row.announced)
					NativeQueueDestroy(row.netId, -1);
				Scene.World.ForgetNativeCandidate(row.entity);
				NativeRemoveRow(row);
				continue;
			}
			if (row.last.Count != state.Data.Count ||
				(state.Data.Count > 0 && Internal.MemCmp(row.last.Ptr, state.Data.Ptr, state.Data.Count) != 0))
			{
				row.last.Clear();
				row.last.AddRange(state.Data);
				NativeQueueState(row, -1);
			}
			mNativeCursor++;
			checkedCount++;
		}
		NativeFlush(-1);
	}

	/// A late-joining client receives the existing bare entities, not merely
	/// changes made after it connected.
	public void NativeClientJoined(int32 clientId)
	{
		if (!IsServer)
			return;
		// A server deletion batch must not be reused as this client's
		// initial state packet.
		NativeFlush(-1);
		let state = scope NetWriter();
		for (let row in mNativeRows)
		{
			if (!NativeSerialize(Scene.World, row.entity, state))
				continue;
			// Do not replace the broadcast baseline while sending an individual
			// late joiner its current state: existing clients still need the
			// next server tick's changed-field update.
			NativeQueue(1, row.netId, state.Data, clientId);
			row.announced = true;
		}
		NativeFlush(clientId);
	}

	/// Begin tracking candidates that existed before networking started.
	public void NativeStart()
	{
		Scene.World.NativeNetwork = this;
		if (!IsServer)
			return;
		for (let id in Scene.World.NativeCandidates)
			NativeCandidateAdded(.(id));
	}

	/// Forget old session mapping. Client-side replicas are not GameObjects,
	/// so they must be explicitly deleted when leaving a session.
	public void NativeStop()
	{
		if (Scene.World.NativeNetwork == this)
			Scene.World.NativeNetwork = null;
		for (let entity in mNativeRemote.Values)
			if (Scene.World.IsAlive(entity))
				Scene.World.Delete(entity);
		mNativeRemote.Clear();
		ClearAndDeleteItems!(mNativeRows);
		mNativeByEntity.Clear();
		mNativeCursor = 0;
		mNativeNextId = 1;
		mNativeBatch.Clear();
		mNativeBatchCount = 0;
	}

	public static void OnNativeMessage(int32 sender, ref NetReader reader)
	{
		// Poll sets Dispatching to the exact session that received this packet;
		// Scene.Active can be another scene while switching levels.
		let network = NetworkManager.Dispatching;
		if (network == null || !network.IsClient)
			return; // The server never accepts ECS state from clients.
		let count = (int)reader.Read<uint8>();
		for (int i < count && reader.Ok)
		{
			let operation = reader.Read<uint8>();
			let netId = reader.Read<uint32>();
			if (!reader.Ok)
				return;
			if (operation == 2)
			{
				if (network.mNativeRemote.TryGetValue(netId, let old))
				{
					network.mNativeRemote.Remove(netId);
					network.Scene.World.Delete(old);
				}
			}
			else if (operation == 1)
				network.NativeReadState(netId, ref reader);
			else
				return;
		}
	}

	void NativeReadState(uint32 netId, ref NetReader reader)
	{
		let world = Scene.World;
		let count = (int)reader.Read<uint8>();
		if (!reader.Ok || count > NativeMaxTypes)
		{
			reader.Ok = false;
			return;
		}
		bool created = false;
		Entity entity;
		if (!mNativeRemote.TryGetValue(netId, out entity) || !world.IsAlive(entity))
		{
			entity = world.Create();
			created = true;
		}
		let present = scope List<int32>();
		for (int i < count && reader.Ok)
		{
			let name = scope String();
			reader.ReadString(name);
			let fieldCount = (int)reader.Read<uint8>();
			if (!reader.Ok || fieldCount > NativeMaxFields)
			{
				reader.Ok = false;
				break;
			}
			let info = DataComponents.Find(name);
			if (info != null && info.synced)
			{
				world.Ensure(entity, info.index);
				present.Add(info.index);
			}
			for (int j < fieldCount && reader.Ok)
			{
				let fieldName = scope String();
				reader.ReadString(fieldName);
				let length = (int)reader.Read<uint16>();
				if (!reader.Ok || length > NativeMaxFieldBytes)
				{
					reader.Ok = false;
					break;
				}
				uint8[NativeMaxFieldBytes] bytes = ?;
				for (int b < length)
					bytes[b] = reader.Read<uint8>();
				if (!reader.Ok || info == null || !info.synced)
					continue;
				let fields = scope List<FieldRef>();
				DataComponents.GetFields(info.type, world.Get(entity, info.index), fields);
				for (let field in fields)
				{
					if (!field.sync || field.name != fieldName)
						continue;
					let size = NetworkSync.SizeOf(field);
					if (field.kind == .String && field.type == typeof(SharedString))
						*(SharedString*)field.ptr = StringView((char8*)&bytes[0], length);
					else if (size == length && size > 0)
						Internal.MemCpy(field.ptr, &bytes[0], size);
					break;
				}
			}
		}
		if (!reader.Ok)
		{
			if (created)
				world.Delete(entity);
			return;
		}
		// Server-owned [Sync] types have an authoritative presence list.
		// Local-only ECS data on the same entity is never removed.
		let existing = scope List<int32>();
		world.TypesOf(entity, existing);
		for (let index in existing)
			if (DataComponents.IsSynced(index) && !present.Contains(index))
				world.Remove(entity, index);
		mNativeRemote[netId] = entity;
	}

}
