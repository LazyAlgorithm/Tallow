using System;
using System.Collections;

namespace Tallow;

/// Marks an engine data component that is bookkeeping, not something to edit: it is not listed in Add Component,
/// shown in the Inspector or written to scene files (the engine makes it again itself).
[AttributeUsage(.Struct, .ReflectAttribute)]
struct EngineDataAttribute : Attribute
{
}

/// The data components a project has: `[Component]` structs. They live in the
/// object's entity rather than on the GameObject, are saved in scene files as `data` blocks and edited in the
/// Inspector beside scripts. Their fields must be plain values (numbers, vectors, colours, enums, bools); other
/// fields are left out of files and the Inspector.
static class DataComponents
{
	public class Info
	{
		public String fullName = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public Type type;
		/// The type's place in ComponentTypes (the same in every World).
		public int32 index;
		/// At least one field marked [Sync] that the network serializer supports.
		public bool synced;
		/// Those fields, by name: what native ECS replication sends (NetworkManagerEcs.bf).
		public List<SyncedField> syncedFields = new .() ~ DeleteContainerAndItems!(_);
		/// Where its [SyncPosition] Vector3 field is, or -1: a bare entity with it is sent only to clients near it.
		public int32 positionOffset = -1;
	}

	/// A [Sync] field of a data component, where it is in the struct.
	public class SyncedField
	{
		public String name = new .() ~ delete _;
		public int32 offset;
		/// Its size in bytes, or 0 for SharedString text.
		public int32 size;
	}

	static List<Info> sInfos ~ DeleteContainerAndItems!(_);
	/// O(1) type lookup for hot World.Set/Ensure/Add calls.
	static Dictionary<int32, Info> sByIndex = new .() ~ delete _;
	/// Indexed by ComponentTypes index: whether that type is a data component with [Sync] fields. World.Set, Ensure
	/// and Add ask on every call, so this is a plain list, not a lookup.
	static List<bool> sSyncedByIndex = new .() ~ delete _;
	static List<Info> sSynced = new .() ~ delete _;
	static int sGeneration;

	/// The data components with [Sync] fields, by full name: the order native ECS replication lists them in.
	public static List<Info> SyncedTypes
	{
		get
		{
			if (sInfos == null)
				Build();
			return sSynced;
		}
	}

	/// Changes whenever the types are listed again (after a script reload), so that a cache of them can tell.
	public static int Generation
	{
		get
		{
			if (sInfos == null)
				Build();
			return sGeneration;
		}
	}

	/// Every data component a game can add, sorted by name.
	public static List<Info> Types
	{
		get
		{
			if (sInfos == null)
				Build();
			return sInfos;
		}
	}

	static void Build()
	{
		sInfos = new .();
		sByIndex.Clear();
		sSyncedByIndex.Clear();
		sSynced.Clear();
		sGeneration++;
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type == null || !type.IsStruct || type.IsGenericType)
				continue;
			if (!(type.GetCustomAttribute<ComponentAttribute>() case .Ok))
				continue;
			if (type.GetCustomAttribute<EngineDataAttribute>() case .Ok)
				continue;
			// Behind a built-in component (HandleComponents), which shows it under its own name, or a handle itself.
			if (type.GetCustomAttribute<HandleDataAttribute>() case .Ok || HandleComponents.IsHandle(type))
				continue;
			let info = new Info();
			type.GetFullName(info.fullName);
			type.GetName(info.name);
			info.type = type;
			info.index = ComponentTypes.Add(type, type.Stride, type.Align);
			// With no data, each field's pointer is its offset.
			let fields = scope List<FieldRef>();
			GetFields(type, null, fields);
			for (let field in fields)
			{
				if (!field.sync)
					continue;
				if (field.syncPosition && field.type == typeof(Vector3))
					info.positionOffset = (int32)(int)field.ptr;
				let size = NetworkSync.SizeOf(field);
				if (size == 0 && field.type != typeof(SharedString))
					continue;
				let synced = new SyncedField();
				synced.name.Set(field.name);
				synced.offset = (int32)(int)field.ptr;
				synced.size = size;
				info.syncedFields.Add(synced);
			}
			// By name, not declaration order: a type split over several files lists its fields in the order the
			// compiler met them, which differs between Windows and Linux builds.
			info.syncedFields.Sort(scope (a, b) => a.name.CompareTo(b.name));
			info.synced = !info.syncedFields.IsEmpty;
			sInfos.Add(info);
			sByIndex[info.index] = info;
			if (info.synced)
			{
				while (sSyncedByIndex.Count <= info.index)
					sSyncedByIndex.Add(false);
				sSyncedByIndex[info.index] = true;
				sSynced.Add(info);
			}
		}
		// C# [Component] structs with [Sync] fields replicate like Beef ones; they are not in Types (no Beef type for
		// the Inspector or scene files), only in the network's lists.
		for (let info in sManaged)
		{
			if (!info.synced)
				continue;
			while (sSyncedByIndex.Count <= info.index)
				sSyncedByIndex.Add(false);
			sSyncedByIndex[info.index] = true;
			sSynced.Add(info);
		}
		sInfos.Sort(scope (a, b) => a.name.CompareTo(b.name));
		sSynced.Sort(scope (a, b) => a.fullName.CompareTo(b.fullName));
	}

	/// C# data components described by the game's assemblies (DescribeManaged), latest per name.
	static List<Info> sManaged = new .() ~ DeleteContainerAndItems!(_);
	/// Every described C# schema's size and alignment, so a scene can take it before C# sets any (a client's query
	/// of data only the server makes).
	static Dictionary<uint64, (int32 size, int32 alignment)> sManagedLayouts = new .() ~ delete _;

	public static bool ManagedLayout(uint64 schemaId, out int32 size, out int32 alignment)
	{
		size = 0;
		alignment = 0;
		if (!sManagedLayouts.TryGetValue(schemaId, let layout))
			return false;
		size = layout.size;
		alignment = layout.alignment;
		return true;
	}

	/// A C# [Component] struct's layout and [Sync] fields ("name:offset:size;" each), told when its assembly loads.
	/// Its ComponentTypes index (Flecs name Tallow.CSharp.Local.<schema id>), or -1 when the description is bad.
	public static int32 DescribeManaged(uint64 schemaId, StringView fullName, int32 size, int32 alignment,
		StringView syncFields)
	{
		if (schemaId == 0 || fullName.IsEmpty || fullName.Length > 256 || size <= 0 || size > 4096)
			return -1;
		let flecsName = scope String()..AppendF("Tallow.CSharp.Local.{}", schemaId);
		let index = ComponentTypes.AddNamed(flecsName, size, alignment);
		if (index < 0)
			return -1;
		sManagedLayouts[schemaId] = (size, alignment);
		let info = new Info();
		info.fullName.AppendF("CSharp:{}", fullName);
		info.name.Set(fullName);
		info.index = index;
		for (let entry in syncFields.Split(';', .RemoveEmptyEntries))
		{
			var parts = entry.Split(':');
			let name = parts.GetNext().GetValueOrDefault();
			let offset = int32.Parse(parts.GetNext().GetValueOrDefault()) case .Ok(let o) ? o : -1;
			let fieldSize = int32.Parse(parts.GetNext().GetValueOrDefault()) case .Ok(let z) ? z : 0;
			if (name.IsEmpty || offset < 0 || fieldSize <= 0 || offset + fieldSize > size)
			{
				delete info;
				return -1;
			}
			// "p": the [SyncPosition] Vector3, where the entity is (relevance: only clients near it are sent it).
			if (parts.GetNext().GetValueOrDefault() == "p" && fieldSize == sizeof(Vector3) && info.positionOffset < 0)
				info.positionOffset = offset;
			let field = new SyncedField();
			field.name.Set(name);
			field.offset = offset;
			field.size = fieldSize;
			info.syncedFields.Add(field);
		}
		info.syncedFields.Sort(scope (a, b) => a.name.CompareTo(b.name));
		info.synced = !info.syncedFields.IsEmpty;
		for (let existing in sManaged)
		{
			if (existing.fullName == info.fullName)
			{
				if (existing.index == index)
				{
					delete info;
					return index;
				}
				// The struct changed (hot reload): the new layout replaces the old for the network.
				delete existing;
				sManaged.RemoveAt(@existing.Index);
				break;
			}
		}
		sManaged.Add(info);
		Refresh();
		return index;
	}

	/// A synced data component by index, Beef or C# (the network's view; Find gives only Beef ones).
	public static Info FindSynced(int32 index)
	{
		if (let info = Find(index))
			return info;
		for (let info in sManaged)
		{
			if (info.index == index)
				return info;
		}
		return null;
	}

	/// A synced data component by full name ("CSharp:Game.Health" for C# ones).
	public static Info FindSynced(StringView fullName)
	{
		for (let info in SyncedTypes)
		{
			if (info.fullName == fullName)
				return info;
		}
		return Find(fullName);
	}

	/// Scripts were reloaded: the types may have changed.
	public static void Refresh()
	{
		if (sInfos != null)
		{
			DeleteContainerAndItems!(sInfos);
			sInfos = null;
			sByIndex.Clear();
			sSyncedByIndex.Clear();
			sSynced.Clear();
		}
	}

	public static Info Find(StringView fullName)
	{
		for (let info in Types)
		{
			if (info.fullName == fullName)
				return info;
		}
		return null;
	}

	public static Info Find(int32 index)
	{
		// Build on first use and invalidate after a script-library reload.
		if (sInfos == null)
			Build();
		if (sByIndex.TryGetValue(index, let info))
			return info;
		return null;
	}

	/// Whether a game-defined ECS data type has a supported [Sync] field.
	/// Computed once per reflection refresh; World.Set, Ensure and Add ask on every call.
	[Inline]
	public static bool IsSynced(int32 index)
	{
		if (sInfos == null)
			Build();
		return index < sSyncedByIndex.Count && sSyncedByIndex[index];
	}

	/// The editable fields of a data component whose value is at data: plain values, SharedString and ObjectRef (and,
	/// for a built-in component's data, the String fields and lists it owns). With owner, the object whose data it
	/// is, which ObjectRef fields need to find their scene.
	public static void GetFields(Type type, void* data, List<FieldRef> fields, GameObject owner = null)
	{
		let all = scope List<FieldRef>();
		ComponentRegistry.GetFields(type, data, all);
		for (var field in all)
		{
			field.owner = owner;
			field.ownerType = type;
			switch (field.kind)
			{
			case .String:
				// A built-in component's data may own String fields too (HandleComponents.OwnLists).
				if (field.type == typeof(SharedString) || type.HasCustomAttribute<HandleDataAttribute>())
					fields.Add(field);
			case .List:
				// A built-in component's data may own lists of plain values (HandleComponents.OwnLists).
				if (type.HasCustomAttribute<HandleDataAttribute>() && field.elementKind != .String && field.elementKind != .ObjectReference)
					fields.Add(field);
			case .ObjectReference:
				// An id looked up on use (ObjectRef): never a pointer.
				if (ObjectRefs.Is(field.type))
					fields.Add(field);
			case .Array:
				continue;
			default:
				fields.Add(field);
			}
		}
	}

	/// The data components on an object that can be edited and saved, in the order Flecs keeps them.
	public static void On(GameObject gameObject, List<Info> output)
	{
		let world = gameObject.Scene?.World;
		if (world == null || gameObject.Entity.IsNull)
			return;
		let indices = scope List<int32>();
		world.TypesOf(gameObject.Entity, indices);
		for (let index in indices)
		{
			if (let info = Find(index))
				output.Add(info);
		}
	}
}
