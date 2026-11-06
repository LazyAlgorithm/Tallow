using System;
using System.Collections;

namespace Tallow;

/// The desync debugger (6i). With `DesyncDebugger` on, the server and every client note, for each tick, what each
/// simulated object (players, and the bodies clients run themselves) looked like after each system that touched it:
/// each script's Simulate and Update (its public fields and the object's position and rotation), and the physics step
/// (each body's position, rotation and velocities). When a client's hash differs from the server's (lockstep), or
/// a correction puts this machine's own player back (state sync), the client asks the server for its per-system
/// hashes of the ticks since the last good check, finds the first tick and system where the two split, then asks
/// for that system's fields at that tick and compares them one by one. The answer, down to the object and the field,
/// is `LastDesync`, the console and the network panel.
///
/// It costs memory (128 ticks of every simulated object's fields) and some time each tick: for finding a desync,
/// not for shipping. Only public (Inspector) fields are compared; a script whose state is in private fields shows
/// only through its object's position.
extension NetworkManager
{
	/// Note what every system did to every simulated object, and find the first difference when a desync shows.
	public bool DesyncDebugger;

	/// One field difference in a desync found by the debugger.
	public struct DesyncField
	{
		public String name;
		public String here;
		public String server;
	}

	/// What the debugger found last: the first tick where this machine and the server split, in which system, on
	/// which object, and the fields that differed after it.
	public class DesyncReport
	{
		public uint32 tick;
		public String system = new .() ~ delete _;
		public String objectName = new .() ~ delete _;
		public uint32 netId;
		public List<DesyncField> fields = new .() ~ { for (let f in _) { delete f.name; delete f.here; delete f.server; } delete _; };

		public void Describe(String into)
		{
			into.AppendF("tick {} in {} on {} (id {}):", tick, system, objectName, netId);
			if (fields.Count == 0)
				into.Append(" the object is not there on one side");
			for (let field in fields)
				into.AppendF(" {} {} here, {} on the server;", field.name, field.here, field.server);
			if (into.EndsWith(';'))
				into.RemoveFromEnd(1);
		}
	}

	/// Client: the last desync the debugger found (null if none yet), and how many it has found.
	public DesyncReport LastDesync ~ delete _;
	public int32 DesyncsFound;

	const uint8 MsgDesyncQuery = 26;
	const uint8 MsgDesyncHashes = 27;
	const uint8 MsgDesyncFields = 28;
	const int DesyncRing = 128;

	struct DesyncEntry
	{
		public uint32 netId;
		public uint16 system;
		public uint16 field;
		public FieldKind kind;
		/// Bytes of the value in `value`; 0xFF: `value` holds an 8-byte hash of a longer value.
		public uint8 size;
		public uint8[16] value;
	}

	class DesyncTick
	{
		public uint32 tick;
		public List<DesyncEntry> entries = new .() ~ delete _;
	}

	DesyncTick[DesyncRing] mDesyncTicks ~ { for (let t in _) delete t; };
	List<String> mDesyncNames = new .() ~ DeleteContainerAndItems!(_);
	Dictionary<String, uint16> mDesyncNameIds = new .() ~ delete _;
	Dictionary<Type, (uint16 simulate, uint16 update)> mDesyncSystems = new .() ~ delete _;
	/// The tick being noted (the server's own number on the server, this machine's on a client).
	uint32 mDesyncTick;
	/// Client: the ticks being looked into (from, to), 0 when not looking.
	uint32 mDesyncFrom, mDesyncTo;

	uint16 DesyncName(StringView name)
	{
		let key = scope String(name);
		if (mDesyncNameIds.TryGetValue(key, let id))
			return id;
		let id = (uint16)mDesyncNames.Count;
		let kept = new String(name);
		mDesyncNames.Add(kept);
		mDesyncNameIds[kept] = id;
		return id;
	}

	/// Whether the debugger notes this object: what every machine simulates.
	bool DesyncTracked(NetworkIdentity identity)
	{
		if (IsServer)
			return identity.PhysicsPredictable || ForwardsFor(identity.Runtime);
		return identity.ownerId == LocalClientId || identity.RemoteRun || identity.Predicted;
	}

	/// Starts noting a tick (forgetting what was noted for it before: a replay notes it again).
	void DesyncBeginTick(uint32 tick)
	{
		if (!DesyncDebugger)
			return;
		mDesyncTick = tick;
		let slot = tick % DesyncRing;
		if (mDesyncTicks[slot] == null)
			mDesyncTicks[slot] = new .();
		mDesyncTicks[slot].tick = tick;
		mDesyncTicks[slot].entries.Clear();
	}

	List<DesyncEntry> DesyncCurrent()
	{
		let record = mDesyncTicks[mDesyncTick % DesyncRing];
		return (record != null && record.tick == mDesyncTick && mDesyncTick != 0) ? record.entries : null;
	}

	void DesyncAdd(List<DesyncEntry> into, uint32 netId, uint16 system, StringView field, FieldKind kind, void* data, int size)
	{
		DesyncEntry entry = default;
		entry.netId = netId;
		entry.system = system;
		entry.field = DesyncName(field);
		entry.kind = kind;
		if (size <= 16)
		{
			entry.size = (uint8)size;
			Internal.MemCpy(&entry.value, data, size);
		}
		else
		{
			entry.size = 0xFF;
			var hash = HashBytes(data, size);
			Internal.MemCpy(&entry.value, &hash, 8);
		}
		into.Add(entry);
	}

	static uint64 HashBytes(void* data, int size)
	{
		uint64 hash = 14695981039346656037;
		let bytes = (uint8*)data;
		for (int i < size)
		{
			hash ^= bytes[i];
			hash *= 1099511628211;
		}
		return hash;
	}

	/// After a script's Simulate or Update ran on an object: its public fields and where the object is.
	void DesyncNoteScript(NetworkIdentity identity, Component component, bool simulate)
	{
		let entries = DesyncCurrent();
		if (entries == null || !DesyncTracked(identity))
			return;
		let type = component.GetType();
		if (!mDesyncSystems.TryGetValue(type, var systems))
		{
			let name = type.GetName(.. scope .());
			systems = (DesyncName(scope $"{name}.Simulate"), DesyncName(scope $"{name}.Update"));
			mDesyncSystems[type] = systems;
		}
		let system = simulate ? systems.simulate : systems.update;
		List<FieldRef> fields = scope .();
		ComponentRegistry.GetFields(component, fields);
		for (let field in fields)
		{
			switch (field.kind)
			{
			case .Float, .Double, .Char, .Vector4, .Int3, .Matrix4, .Int, .Bool, .Vector2, .Vector3, .Quaternion, .Color, .Enum:
				DesyncAdd(entries, identity.NetId, system, field.name, field.kind, field.ptr, field.type.Size);
			case .String:
				if (let text = *(String*)field.ptr)
					DesyncAdd(entries, identity.NetId, system, field.name, .String, text.Ptr, text.Length);
			default:
			}
		}
		var position = identity.Transform.Position;
		var rotation = identity.Transform.Rotation;
		DesyncAdd(entries, identity.NetId, system, "Transform.position", .Vector3, &position, sizeof(Vector3));
		DesyncAdd(entries, identity.NetId, system, "Transform.rotation", .Quaternion, &rotation, sizeof(Quaternion));
	}

	/// After the physics step: every simulated body.
	void DesyncNotePhysics()
	{
		let entries = DesyncCurrent();
		if (entries == null)
			return;
		let system = DesyncName("Physics");
		for (let identity in mIdentities)
		{
			if (!identity.IsActiveAndEnabled || !DesyncTracked(identity))
				continue;
			let body = identity.GetComponent<Rigidbody>();
			if (!body.IsValid || !body.HasBody)
				continue;
			var state = body.State;
			DesyncAdd(entries, identity.NetId, system, "position", .Vector3, &state.position, sizeof(Vector3));
			DesyncAdd(entries, identity.NetId, system, "rotation", .Quaternion, &state.rotation, sizeof(Quaternion));
			DesyncAdd(entries, identity.NetId, system, "velocity", .Vector3, &state.linearVelocity, sizeof(Vector3));
			DesyncAdd(entries, identity.NetId, system, "angularVelocity", .Vector3, &state.angularVelocity, sizeof(Vector3));
		}
	}

	/// An entry's hash: by the field's name (each machine numbers names its own way).
	uint64 EntryHash(DesyncEntry entry)
	{
		var e = entry;
		let name = mDesyncNames[e.field];
		uint64 hash = HashBytes(&e.netId, 4);
		hash = hash * 31 + HashBytes(name.Ptr, name.Length);
		let size = e.size == 0xFF ? 8 : e.size;
		return hash ^ HashBytes(&e.value, size);
	}

	/// The noted ticks' records: the slot holding `tick`, or null.
	DesyncTick DesyncRecord(uint32 tick)
	{
		let record = mDesyncTicks[tick % DesyncRing];
		return (record != null && record.tick == tick && tick != 0) ? record : null;
	}

	/// Per-system hashes of one tick's records, in the order the systems first ran.
	void DesyncSystemHashes(DesyncTick record, List<(uint16 system, uint64 hash)> into)
	{
		for (let entry in record.entries)
		{
			int at = -1;
			for (int i < into.Count)
				if (into[i].system == entry.system) { at = i; break; }
			if (at < 0)
			{
				at = into.Count;
				into.Add((entry.system, 0));
			}
			into[at].hash += EntryHash(entry);
		}
	}

	// ---- client: asking ----

	/// Client: a desync showed at `tick` (the last good check before it was at `goodTick`): start looking.
	void DesyncInvestigate(uint32 goodTick, uint32 tick)
	{
		if (!DesyncDebugger || !IsClient || mDesyncFrom != 0)
			return;
		var from = goodTick + 1;
		if ((int32)(tick - from) >= DesyncRing - 8)
			from = tick - (DesyncRing - 8);
		mDesyncFrom = from;
		mDesyncTo = tick;
		mWriter.Clear();
		mWriter.Write(MsgDesyncQuery);
		mWriter.Write((uint8)0);
		mWriter.Write(from);
		mWriter.Write(tick);
		Send(mServerPeer, true);
	}

	/// Client: the server's per-system hashes for the ticks asked about: the first tick and system that differ.
	void ReadDesyncHashes(ref NetReader reader)
	{
		let count = reader.Read<uint16>();
		uint32 foundTick = 0;
		let foundSystem = scope String();
		let name = scope String();
		for (int t < count)
		{
			let tick = reader.Read<uint32>();
			let systems = reader.Read<uint8>();
			List<(uint16 system, uint64 hash)> mine = scope .();
			let record = DesyncRecord(tick);
			if (record != null)
				DesyncSystemHashes(record, mine);
			for (int s < systems)
			{
				name.Clear();
				reader.ReadString(name);
				let hash = reader.Read<uint64>();
				if (!reader.Ok)
					return;
				if (foundTick != 0 || record == null)
					continue;
				uint64 here = 0;
				bool have = false;
				for (let entry in mine)
					if (mDesyncNames[entry.system] == name) { here = entry.hash; have = true; }
				if (!have || here != hash)
				{
					foundTick = tick;
					foundSystem.Set(name);
				}
			}
			// A system that ran here but not on the server.
			if (foundTick == 0 && record != null && mine.Count > systems)
			{
				foundTick = tick;
				foundSystem.Set(mDesyncNames[mine[systems].system]);
			}
		}
		if (foundTick == 0)
		{
			// Nothing in the ticks noted on both sides differed (the split was before them, or in something not
			// noted): say so and stop looking.
			Log.Warning(scope $"[Network] Desync debugger: no difference in ticks {mDesyncFrom}-{mDesyncTo} in what it notes (public fields of networked scripts, positions and bodies).");
			mDesyncFrom = 0;
			return;
		}
		mWriter.Clear();
		mWriter.Write(MsgDesyncQuery);
		mWriter.Write((uint8)1);
		mWriter.Write(foundTick);
		mWriter.WriteString(foundSystem);
		Send(mServerPeer, true);
	}

	static void DesyncValueText(FieldKind kind, uint8 size, uint8[16] value, String into)
	{
		var v = value;
		if (size == 0xFF)
		{
			into.AppendF("(hash {:X})", *(uint64*)&v);
			return;
		}
		switch (kind)
		{
		case .Float: into.AppendF("{}", *(float*)&v);
		case .Double: into.AppendF("{}", *(double*)&v);
		case .Int, .Enum:
			if (size == 8) into.AppendF("{}", *(int64*)&v); else if (size == 4) into.AppendF("{}", *(int32*)&v); else if (size == 2) into.AppendF("{}", *(int16*)&v); else into.AppendF("{}", v[0]);
		case .Bool: into.Append(v[0] != 0 ? "true" : "false");
		case .Vector2: let p = (float*)&v; into.AppendF("({}, {})", p[0], p[1]);
		case .Vector3, .Int3:
			if (kind == .Int3) { let p = (int32*)&v; into.AppendF("({}, {}, {})", p[0], p[1], p[2]); }
			else { let p = (float*)&v; into.AppendF("({}, {}, {})", p[0], p[1], p[2]); }
		case .Vector4, .Quaternion, .Color: let p = (float*)&v; into.AppendF("({}, {}, {}, {})", p[0], p[1], p[2], p[3]);
		case .String: into.Append('"'); into.Append(StringView((char8*)&v, size)); into.Append('"');
		default: into.AppendF("{} bytes", size);
		}
	}

	/// Client: the server's fields after one system at one tick: compared with this machine's, the report.
	void ReadDesyncFields(ref NetReader reader)
	{
		let tick = reader.Read<uint32>();
		let system = reader.ReadString(.. scope .());
		let count = reader.Read<uint16>();
		mDesyncFrom = 0;
		if (!reader.Ok)
			return;
		let report = new DesyncReport();
		report.tick = tick;
		report.system.Set(system);
		let record = DesyncRecord(tick);
		List<DesyncEntry> mine = scope .();
		if (record != null)
			for (let entry in record.entries)
				if (mDesyncNames[entry.system] == system)
					mine.Add(entry);
		HashSet<int> matched = scope .();
		let fieldName = scope String();
		for (int i < count)
		{
			let netId = reader.Read<uint32>();
			fieldName.Clear();
			reader.ReadString(fieldName);
			let kind = (FieldKind)reader.Read<uint8>();
			let size = reader.Read<uint8>();
			let value = reader.Read<uint8[16]>();
			if (!reader.Ok)
				break;
			int found = -1;
			for (int m < mine.Count)
				if (mine[m].netId == netId && mDesyncNames[mine[m].field] == fieldName) { found = m; break; }
			if (found >= 0)
				matched.Add(found);
			bool same = found >= 0 && mine[found].size == size && Internal.MemCmp(&mine[found].value, &value, size == 0xFF ? 8 : size) == 0;
			if (same)
				continue;
			// Only the first object that differs (in the server's order) is reported, with all its fields.
			if (report.netId != 0 && report.netId != netId)
				continue;
			report.netId = netId;
			DesyncField field;
			field.name = new .(fieldName);
			field.server = DesyncValueText(kind, size, value, .. new .());
			field.here = found >= 0 ? DesyncValueText(mine[found].kind, mine[found].size, mine[found].value, .. new .()) : new .("(missing)");
			report.fields.Add(field);
		}
		if (report.netId == 0)
		{
			// Everything the server had matched: what differs is something only this machine noted.
			for (int m < mine.Count)
				if (!matched.Contains(m)) { report.netId = mine[m].netId; break; }
		}
		if (mByNetId.TryGetValue(report.netId, let identity))
			report.objectName.Set(identity.GameObject.Name);
		delete LastDesync;
		LastDesync = report;
		DesyncsFound++;
		Log.Warning(scope $"[Network] Desync found: {report.Describe(.. scope .())}");
	}

	// ---- server: answering ----

	/// Server: the server tick at which it ran a client's controls for one of the client's ticks (0 if not noted).
	uint32 DesyncServerTick(ClientInfo client, uint32 clientTick)
	{
		for (int i < DesyncRing)
			if (client.desyncTicks[i] == clientTick && clientTick != 0)
			{
				let serverTick = mDesyncTicks[i] != null ? mDesyncTicks[i].tick : 0;
				if (serverTick % DesyncRing == (uint32)i)
					return serverTick;
			}
		return 0;
	}

	/// Server, at the start of each tick: which of each client's ticks it is about to run.
	void DesyncNoteClientTicks()
	{
		if (!DesyncDebugger)
			return;
		for (let client in mClients)
			client.desyncTicks[mDesyncTick % DesyncRing] = client.lastProcessedTick;
	}

	void ReadDesyncQuery(ClientInfo client, ref NetReader reader)
	{
		let kind = reader.Read<uint8>();
		if (!reader.Ok || !DesyncDebugger)
			return;
		if (kind == 0)
		{
			let from = reader.Read<uint32>();
			let to = reader.Read<uint32>();
			if (!reader.Ok || (int32)(to - from) < 0 || to - from > DesyncRing)
				return;
			mWriter.Clear();
			mWriter.Write(MsgDesyncHashes);
			let countAt = mWriter.Data.Count;
			mWriter.Write((uint16)0);
			uint16 count = 0;
			List<(uint16 system, uint64 hash)> systems = scope .();
			for (uint32 t = from; t <= to; t++)
			{
				let record = DesyncRecord(DesyncServerTick(client, t));
				if (record == null)
					continue;
				systems.Clear();
				DesyncSystemHashes(record, systems);
				mWriter.Write(t);
				mWriter.Write((uint8)Math.Min(systems.Count, 255));
				for (int s < Math.Min(systems.Count, 255))
				{
					mWriter.WriteString(mDesyncNames[systems[s].system]);
					mWriter.Write(systems[s].hash);
				}
				count++;
			}
			*(uint16*)&mWriter.Data[countAt] = count;
			Send(client.peer, true);
		}
		else
		{
			let tick = reader.Read<uint32>();
			let system = reader.ReadString(.. scope .());
			if (!reader.Ok)
				return;
			let record = DesyncRecord(DesyncServerTick(client, tick));
			mWriter.Clear();
			mWriter.Write(MsgDesyncFields);
			mWriter.Write(tick);
			mWriter.WriteString(system);
			let countAt = mWriter.Data.Count;
			mWriter.Write((uint16)0);
			uint16 count = 0;
			if (record != null)
			{
				for (let entry in record.entries)
				{
					if (mDesyncNames[entry.system] != system || count == uint16.MaxValue)
						continue;
					mWriter.Write(entry.netId);
					mWriter.WriteString(mDesyncNames[entry.field]);
					mWriter.Write((uint8)entry.kind);
					mWriter.Write(entry.size);
					mWriter.Write(entry.value);
					count++;
				}
			}
			*(uint16*)&mWriter.Data[countAt] = count;
			Send(client.peer, true);
		}
	}
}
