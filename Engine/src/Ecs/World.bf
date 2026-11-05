using System;
using System.Collections;

namespace Tallow;

/// One entity in a World: just its Flecs id. 0 is never an entity. An id stays the same for the entity's life,
/// and a deleted entity's id is not reused until its generation changes, so a stale id is simply not alive.
[CRepr]
struct Entity : IHashable, IEquatable<Entity>
{
	public uint64 id;

	public this(uint64 id)
	{
		this.id = id;
	}

	public static Entity Null => .(0);
	public bool IsNull => id == 0;

	public int GetHashCode() => (int)(id ^ (id >> 32));
	public bool Equals(Entity other) => id == other.id;
	public static bool operator ==(Entity a, Entity b) => a.id == b.id;

	public override void ToString(String output)
	{
		output.AppendF($"Entity({id & 0xFFFFFFFF}v{id >> 32})");
	}
}

/// The ECS storage for one Scene (docs/ecs-plan.md): entities, their data components in packed tables, and the
/// queries over them. Use it from the main thread, except inside Query.ParallelFor, where each worker reads and
/// writes only its own chunks' columns.
sealed class World
{
	void* mWorld;
	/// Flecs id of each ComponentTypes index, 0 until registered in this world.
	List<uint64> mIds = new .() ~ delete _;
	int32 mStageCount = 1;
	int32 mDeferDepth;

	static bool sChecked;
	static uint64 sTableVersionMask;
	uint32* mTableVersions;

	/// For ComponentRef's inline fast path: the version Flecs keeps for a table id.
	[Inline]
	public uint32 TableVersion(uint64 tableId) => mTableVersions[tableId & sTableVersionMask];

	public this()
	{
		if (!sChecked)
		{
			sChecked = true;
			let size = Flecs.IterSize();
			Runtime.Assert(size <= Flecs.IterBuffer.Size, scope $"Flecs ecs_iter_t is {size} bytes; raise Flecs.IterBuffer.Size");
			let refSize = Flecs.RefSize();
			Runtime.Assert(refSize == Flecs.RefBuffer.Size, scope $"Flecs ecs_ref_t is {refSize} bytes; update Flecs.RefBuffer");
			sTableVersionMask = (uint64)Flecs.TableVersionMask();
		}
		mWorld = Flecs.WorldNew();
		Runtime.Assert(mWorld != null, "Flecs could not create a world");
		mTableVersions = Flecs.TableVersions(mWorld);
	}

	public ~this()
	{
		Flecs.WorldFree(mWorld);
	}

	/// The ecs_world_t, for engine code that calls Flecs directly.
	public void* Native => mWorld;

	/// This world's Flecs id for data component T, registered the first time it is asked for.
	[Inline]
	public uint64 Id<T>() where T : struct
	{
		let index = ComponentId<T>.Index;
		if (index < mIds.Count)
		{
			let id = mIds[index];
			if (id != 0)
				return id;
		}
		return Register(index);
	}

	uint64 Register(int32 index)
	{
		while (mIds.Count <= index)
			mIds.Add(0);
		let info = ComponentTypes.Get(index);
		let id = info.size == 0 ? Flecs.Tag(mWorld, info.name.CStr()) : Flecs.Component(mWorld, info.name.CStr(), info.size, info.alignment);
		Runtime.Assert(id != 0, scope $"Flecs refused component {info.name}");
		mIds[index] = id;
		return id;
	}

	// ---- Entities ----

	public Entity Create() => .(Flecs.New(Writer));

	/// Makes count entities with T (zeroed) and adds their ids to output. Much faster than Create and Add in a loop.
	public void CreateMany<T>(int count, List<Entity> output) where T : struct
	{
		if (count <= 0)
			return;
		Runtime.Assert(mDeferDepth == 0, "World.CreateMany cannot be deferred");
		let ids = Flecs.BulkNew(mWorld, Id<T>(), (int32)count);
		output.AddRange(Span<Entity>((Entity*)ids, count));
	}

	public void Delete(Entity entity) => Flecs.Delete(Writer, entity.id);
	public bool IsAlive(Entity entity) => Flecs.IsAlive(mWorld, entity.id);

	public void Add<T>(Entity entity) where T : struct => Flecs.Add(Writer, entity.id, Id<T>());
	public void Remove<T>(Entity entity) where T : struct => Flecs.Remove(Writer, entity.id, Id<T>());
	public bool Has<T>(Entity entity) where T : struct => Flecs.Has(mWorld, entity.id, Id<T>());

	/// The entity's T, or null if it has none. Valid until the entity's components change.
	public T* Get<T>(Entity entity) where T : struct => (T*)Flecs.GetMut(mWorld, entity.id, Id<T>());

	/// The entity's T, added (zeroed) first if it has none. Valid until the entity's components change.
	public ref T Ensure<T>(Entity entity) where T : struct => ref *(T*)Flecs.Ensure(Writer, entity.id, Id<T>(), sizeof(T));

	/// Adds T if needed and sets it to value.
	public void Set<T>(Entity entity, T value) where T : struct
	{
		var value;
		Flecs.Set(Writer, entity.id, Id<T>(), sizeof(T), &value);
	}

	/// How many entities have T.
	public int Count<T>() where T : struct => Flecs.Count(mWorld, Id<T>());

	// ---- Hierarchy ----

	/// Makes child a child of parent (ChildOf), or of nothing with Entity.Null.
	public void SetParent(Entity child, Entity parent) => Flecs.SetParent(Writer, child.id, parent.id);
	public Entity Parent(Entity entity) => .(Flecs.Parent(mWorld, entity.id));

	// ---- Frames ----

	/// Runs every Flecs system in pipeline order.
	public void Progress(float deltaTime) => Flecs.Progress(mWorld, deltaTime);

	/// Changes (Create, Add, Remove, Set, Delete, SetParent) between these are queued and applied at the last
	/// DeferEnd: needed while iterating a query. Reads (Get, Has) still see the world as it was. Flecs 4.2 has no
	/// deferred mode on the world itself, so the changes go to stage 0 and DeferEnd merges it.
	public void DeferBegin()
	{
		mDeferDepth++;
	}

	public void DeferEnd()
	{
		Runtime.Assert(mDeferDepth > 0, "World.DeferEnd without DeferBegin");
		if (--mDeferDepth == 0)
			Flecs.Merge(Flecs.Stage(mWorld, 0));
	}

	public bool IsDeferred => mDeferDepth > 0;

	/// Where changes go: the world, or stage 0 while deferred.
	void* Writer => mDeferDepth > 0 ? Flecs.Stage(mWorld, 0) : mWorld;

	/// Makes sure there is a stage (a private command queue) for each of count threads.
	public void EnsureStages(int32 count)
	{
		if (count > mStageCount)
		{
			Flecs.SetStageCount(mWorld, count);
			mStageCount = count;
		}
	}
}
