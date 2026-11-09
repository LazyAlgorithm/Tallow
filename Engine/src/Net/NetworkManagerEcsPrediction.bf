using System;
using System.Collections;

namespace Tallow;

/// Native systems and prediction for bare ECS entities (docs/unified-ecs-networking.md, "Native systems and
/// prediction").
///
/// A native system is game code registered once (like a prefab) that advances one entity's data by one tick:
///
///     NetworkManager.AddNativeSystem<ShipMotion>("Ship", new (entity, ship, input, deltaTime) =>
///         {
///             ship.velocity += .(input.Move.x, 0, input.Move.y) * 10 * deltaTime;
///             ship.position += ship.velocity * deltaTime;
///         });
///
/// Every tick, before scripts' Update, the systems run in the order added:
///   - with no session, on every bare entity with the data, with this machine's controls;
///   - on the server, on its own bare entities (with the host's controls on a host, none on a dedicated server), and
///     on each entity a client owns (NativeSetOwner) with that client's controls, as they arrive;
///   - on a client, only on the replicas it owns, at once, with its own controls. It notes each one's synced data
///     after every tick; the server sends back its state for the last tick of controls it ran, and where that differs
///     from what was noted for the same tick, the client takes the server's state and runs its controls since again.
///
/// A system must depend only on the entity it is given (its data, the controls and the delta time): not on other
/// entities, wall-clock time or Input, and the order entities are run in is not fixed. Only [Sync] fields are put
/// right by the server; others stay this machine's own. Structural changes inside a system (Add, Remove, Delete) are
/// deferred to the end of the run; CreateMany cannot be called there.
extension NetworkManager
{
	const int NativeHistory = 128;

	/// A replica this client owns and predicts.
	class NativePredicted
	{
		public Entity entity;
		/// The server's state of it (as last sent), in this machine's layout (NativeLocalEncode).
		public List<uint8> shadow = new .() ~ delete _;
		/// What this machine had after each tick it ran, by tick.
		public List<uint8>[NativeHistory] history;
		public uint32[NativeHistory] historyTick;
		/// What it shows, put aside while a record is read into the server's state.
		public List<uint8> live = new .() ~ delete _;

		public this()
		{
			for (int i < NativeHistory)
				history[i] = new .();
		}

		public ~this()
		{
			for (let entry in history)
				delete entry;
		}
	}

	/// A registered native system (AddNativeSystem).
	abstract class NativeSystem
	{
		public String name = new .() ~ delete _;
		/// Runs on one entity, if it has the data.
		public abstract void RunOne(World world, Entity entity, TickInput input, float deltaTime);
		/// Server: runs on every bare entity with the data that no client owns.
		public abstract void RunServer(World world, NetworkManager network, TickInput input, float deltaTime);
	}

	class NativeSystemOf<T> : NativeSystem where T : struct
	{
		public delegate void(Entity entity, ref T data, TickInput input, float deltaTime) run ~ delete _;

		public override void RunOne(World world, Entity entity, TickInput input, float deltaTime)
		{
			let data = world.Get<T>(entity);
			if (data != null)
				run(entity, ref *data, input, deltaTime);
		}

		public override void RunServer(World world, NetworkManager network, TickInput input, float deltaTime)
		{
			let owned = network?.mNative != null && !network.mNative.owned.IsEmpty;
			for (var chunk in world.EntitiesWith<T>())
			{
				let entities = chunk.Entities;
				// Every entity in a chunk has the same components: scene objects are skipped a chunk at a time.
				if (chunk.Count == 0 || world.IsSceneObject(entities[0]))
					continue;
				let data = chunk.Write<T>();
				for (int i < chunk.Count)
				{
					if (owned && network.mNative.byEntity.TryGetValue(entities[i].id, let row) && row.owner != 0)
						continue;
					run(entities[i], ref data[i], input, deltaTime);
				}
			}
		}
	}

	static List<NativeSystem> sNativeSystems = new .() ~ DeleteContainerAndItems!(_);
	static NetInput sOfflinePrevious;

	/// Adds a native system for bare entities with data T, run every tick after those added before it (see above).
	/// Add the same systems, in the same order, on every machine. A system of the same name is replaced.
	public static void AddNativeSystem<T>(StringView name, delegate void(Entity entity, ref T data, TickInput input, float deltaTime) system) where T : struct
	{
		RemoveNativeSystem(name);
		let entry = new NativeSystemOf<T>();
		entry.name.Set(name);
		entry.run = system;
		sNativeSystems.Add(entry);
	}

	public static void RemoveNativeSystem(StringView name)
	{
		for (int i < sNativeSystems.Count)
		{
			if (sNativeSystems[i].name == name)
			{
				delete sNativeSystems[i];
				sNativeSystems.RemoveAt(i);
				return;
			}
		}
	}

	public static void ClearNativeSystems() => ClearAndDeleteItems!(sNativeSystems);

	/// Client: replicas it owns and predicts; predictions the server's state showed were wrong (each run again from
	/// there); ticks run again for them; and predictions begun (an entity given to it).
	public int NativePredictedCount => mNative?.predicted.Count ?? 0;
	public int64 NativeCorrections => mNative?.corrections ?? 0;
	public int64 NativeReplayedTicks => mNative?.replayedTicks ?? 0;
	public int64 NativePredictionStarts => mNative?.predictionStarts ?? 0;

	/// The scene's tick with no session: every bare entity with each system's data, with this machine's controls.
	public static void RunNativeSystemsOffline(Scene scene)
	{
		if (sNativeSystems.IsEmpty || (scene.Network != null && scene.Network.Mode != .Offline))
			return;
		TickInput input;
		input.raw = default;
		LocalControls.Read(ref input.raw);
		input.previous = sOfflinePrevious;
		sOfflinePrevious = input.raw;
		let world = scene.World;
		world.DeferBegin();
		for (let system in sNativeSystems)
			system.RunServer(world, null, input, Time.FixedDeltaTime);
		world.DeferEnd();
	}

	/// From SimulateOwned: one tick of the native systems for what an owner's controls run. Not during a replay of
	/// GameObjects (a client's own replicas are replayed by NativeReconcile).
	void NativeSimulate(int32 ownerId, NetInput controls)
	{
		let native = mNative;
		if (native == null || sNativeSystems.IsEmpty || Replaying || Lockstep)
			return;
		TickInput input;
		input.raw = controls;
		input.previous = native.previousInputs.GetValueOrDefault(ownerId);
		native.previousInputs[ownerId] = controls;
		let world = Scene.World;
		let deltaTime = Time.FixedDeltaTime;
		if (IsServer)
		{
			world.DeferBegin();
			if (ownerId == 0)
			{
				for (let system in sNativeSystems)
					system.RunServer(world, this, input, deltaTime);
			}
			else
			{
				for (let row in native.owned)
				{
					if (row.owner != ownerId)
						continue;
					for (let system in sNativeSystems)
						system.RunOne(world, row.entity, input, deltaTime);
				}
			}
			world.DeferEnd();
			return;
		}
		if (ownerId != LocalClientId || native.predicted.IsEmpty)
			return;
		world.DeferBegin();
		for (let predicted in native.predicted.Values)
		{
			for (let system in sNativeSystems)
				system.RunOne(world, predicted.entity, input, deltaTime);
		}
		world.DeferEnd();
		for (let predicted in native.predicted.Values)
			NativeNote(predicted, mTick);
	}

	/// Notes what a predicted entity has after a tick.
	void NativeNote(NativePredicted predicted, uint32 tick)
	{
		let slot = tick % NativeHistory;
		NativeLocalEncode(Scene.World, predicted.entity, predicted.history[slot]);
		predicted.historyTick[slot] = tick;
	}

	NativePredicted NativePredictedAt(uint32 netId)
	{
		if (mNative.predicted.TryGetValue(netId, let predicted))
			return predicted;
		return null;
	}

	/// The server gave this client a replica: from now on it runs it at once and checks it against the server.
	void NativeStartPredicting(uint32 netId, Entity entity)
	{
		let predicted = new NativePredicted();
		predicted.entity = entity;
		NativeLocalEncode(Scene.World, entity, predicted.shadow);
		mNative.predicted[netId] = predicted;
		mNative.predictionStarts++;
	}

	/// Before a record about a predicted replica is read: what it shows is put aside and the server's state put in.
	void NativeBeginServerState(NativePredicted predicted)
	{
		let world = Scene.World;
		NativeLocalEncode(world, predicted.entity, predicted.live);
		if (!predicted.shadow.IsEmpty)
			NativeLocalDecode(world, predicted.entity, predicted.shadow);
	}

	/// After: the server's state is kept, and what it shows put back (NativeReconcile compares the two).
	void NativeEndServerState(NativePredicted predicted)
	{
		let world = Scene.World;
		NativeLocalEncode(world, predicted.entity, predicted.shadow);
		NativeLocalDecode(world, predicted.entity, predicted.live);
	}

	/// Client: the server has run this client's controls up to ackTick, and its state of what this client owns is as
	/// sent before this. Each one predicted differently for that tick takes the server's state and is run again, with
	/// the controls this machine gave since.
	void NativeReconcile(uint32 ackTick)
	{
		let native = mNative;
		if (native == null || native.predicted.IsEmpty || IsServer)
			return;
		let world = Scene.World;
		let wrong = scope List<NativePredicted>();
		let slot = ackTick % NativeHistory;
		for (let predicted in native.predicted.Values)
		{
			if (predicted.shadow.IsEmpty || !world.IsAlive(predicted.entity))
				continue;
			let noted = predicted.history[slot];
			if (predicted.historyTick[slot] == ackTick && noted.Count == predicted.shadow.Count && Internal.MemCmp(noted.Ptr, predicted.shadow.Ptr, noted.Count) == 0)
				continue;
			// Nothing noted for that tick: it was given to this client since (or the server is far behind).
			if (predicted.historyTick[slot] == ackTick)
				native.corrections++;
			wrong.Add(predicted);
		}
		if (wrong.IsEmpty)
			return;
		for (let predicted in wrong)
		{
			NativeLocalDecode(world, predicted.entity, predicted.shadow);
			predicted.history[slot].Set(predicted.shadow);
			predicted.historyTick[slot] = ackTick;
		}
		let ahead = (int32)(mTick - ackTick);
		if (ahead <= 0 || ahead >= NativeHistory || ahead >= InputHistory)
			return;
		let deltaTime = Time.FixedDeltaTime;
		for (uint32 tick = ackTick + 1; tick != mTick + 1; tick++)
		{
			TickInput input;
			input.raw = mInputs[tick % InputHistory];
			input.previous = mInputs[(tick - 1) % InputHistory];
			world.DeferBegin();
			for (let predicted in wrong)
			{
				for (let system in sNativeSystems)
					system.RunOne(world, predicted.entity, input, deltaTime);
			}
			world.DeferEnd();
			for (let predicted in wrong)
				NativeNote(predicted, tick);
			native.replayedTicks++;
		}
	}

	/// An entity's synced data in this machine's layout: for each synced type it has, its ComponentTypes index and its
	/// [Sync] fields (text: length, then bytes).
	static void NativeLocalEncode(World world, Entity entity, List<uint8> into)
	{
		into.Clear();
		for (let info in DataComponents.SyncedTypes)
		{
			let data = (uint8*)world.Get(entity, info.index);
			if (data == null)
				continue;
			var index = info.index;
			into.AddRange(Span<uint8>((uint8*)&index, 4));
			for (let field in info.syncedFields)
			{
				if (field.size > 0)
				{
					into.AddRange(Span<uint8>(data + field.offset, field.size));
					continue;
				}
				let text = ((SharedString*)(data + field.offset)).View;
				var length = (int32)Math.Min(text.Length, NativeMaxTextBytes);
				into.AddRange(Span<uint8>((uint8*)&length, 4));
				into.AddRange(Span<uint8>((uint8*)text.Ptr, length));
			}
		}
	}

	/// Puts an entity's synced data as NativeLocalEncode wrote it, adding and removing synced types to match.
	static void NativeLocalDecode(World world, Entity entity, List<uint8> from)
	{
		let present = scope List<int32>();
		int at = 0;
		while (at + 4 <= from.Count)
		{
			let index = *(int32*)(from.Ptr + at);
			at += 4;
			let info = DataComponents.Find(index);
			if (info == null)
				return;
			present.Add(index);
			let data = (uint8*)world.Ensure(entity, index);
			for (let field in info.syncedFields)
			{
				if (field.size > 0)
				{
					Internal.MemCpy(data + field.offset, from.Ptr + at, field.size);
					at += field.size;
					continue;
				}
				let length = *(int32*)(from.Ptr + at);
				at += 4;
				*(SharedString*)(data + field.offset) = StringView((char8*)(from.Ptr + at), length);
				at += length;
			}
		}
		for (let info in DataComponents.SyncedTypes)
		{
			if (!present.Contains(info.index) && world.Has(entity, info.index))
				world.Remove(entity, info.index);
		}
	}

}
