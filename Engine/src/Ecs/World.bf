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
	/// Only bare entities with reflected [Sync] data are tracked. Ordinary packed
	/// Flecs entities incur no per-entity networking state or automatic GameObject.
	HashSet<uint64> mNativeCandidates = new .() ~ delete _;
	public HashSet<uint64> NativeCandidates => mNativeCandidates;
	/// Assigned by the NetworkManager for this Scene while a session is active.
	public NetworkManager NativeNetwork;

	/// C# owns only bare local-only entities it explicitly creates; never let
	/// a managed script delete an unrelated native entity or a GameObject.
	HashSet<uint64> mManagedLocalEntities = new .() ~ delete _;

	struct ManagedLocalSchema
	{
		public uint64 flecsId;
		public int32 size;
		public int32 alignment;
	}

	/// Per-world schema IDs are derived from trusted C# component declarations,
	/// and never reused for a different binary layout in this Scene.
	Dictionary<uint64, ManagedLocalSchema> mManagedLocalSchemas = new .() ~ delete _;
	/// Cached read-only Flecs table queries for local C# component schemas.
	Dictionary<uint64, void*> mManagedLocalQueries = new .() ~ delete _;

	void* ManagedLocalQuery(uint64 schemaId, uint64 component)
	{
		if (mManagedLocalQueries.TryGetValue(schemaId, let existing))
			return existing;
		uint64 componentId = component;
		Flecs.TermAccess access = .Read;
		let query = Flecs.QueryNew(mWorld, &componentId, &access, 1);
		if (query != null)
			mManagedLocalQueries[schemaId] = query;
		return query;
	}

	/// Whether C# data components may go on an entity: a bare entity C# made, or a scene object's (its data is
	/// deleted with it). Built-in components are never reachable this way: each C# schema is its own Flecs id.
	public bool CanHoldManagedData(Entity entity) =>
		IsManagedLocalEntity(entity) || (!entity.IsNull && IsAlive(entity) && IsSceneObject(entity));

	/// The most C# data components one query can ask for.
	public const int32 MaxManagedQueryTerms = 4;
	/// Cached Flecs queries over several C# schemas, by their ids ("a,b,").
	Dictionary<String, void*> mManagedDataQueries = new .() ~ DeleteDictionaryAndKeys!(_);

	/// The layouts of registered schemas, in order; false when one is not registered (or too many are asked for).
	bool ManagedLayouts(Span<uint64> schemaIds, Span<ManagedLocalSchema> layouts, out int32 rowSize)
	{
		rowSize = 0;
		if (schemaIds.IsEmpty || schemaIds.Length > MaxManagedQueryTerms)
			return false;
		for (int i < schemaIds.Length)
		{
			for (int j < i)
			{
				if (schemaIds[j] == schemaIds[i])
					return false; // The same data twice would be written back twice.
			}
			if (!mManagedLocalSchemas.TryGetValue(schemaIds[i], let layout))
				return false;
			layouts[i] = layout;
			rowSize += layout.size;
		}
		return true;
	}

	void* ManagedDataQuery(Span<uint64> schemaIds, Span<ManagedLocalSchema> layouts)
	{
		let key = scope String();
		for (let id in schemaIds)
			key.AppendF("{},", id);
		if (mManagedDataQueries.TryGetValue(key, let existing))
			return existing;
		uint64[MaxManagedQueryTerms] ids = ?;
		Flecs.TermAccess[MaxManagedQueryTerms] access = ?;
		for (int i < schemaIds.Length)
		{
			ids[i] = layouts[i].flecsId;
			access[i] = .ReadWrite;
		}
		let query = Flecs.QueryNew(mWorld, &ids, &access, (int32)schemaIds.Length);
		if (query != null)
			mManagedDataQueries[new String(key)] = query;
		return query;
	}

	/// Entities with every one of the C# schemas (bare entities and scene objects alike).
	public int32 CountManagedData(Span<uint64> schemaIds)
	{
		ManagedLocalSchema[MaxManagedQueryTerms] layouts = ?;
		if (!ManagedLayouts(schemaIds, .(&layouts, schemaIds.Length), ?))
			return 0;
		let query = ManagedDataQuery(schemaIds, .(&layouts, schemaIds.Length));
		return query == null ? 0 : Flecs.QueryCount(query);
	}

	/// A page of the entities with every one of the C# schemas: their ids, and for each a row of their records one
	/// after another in the order asked for (no padding between them). Starts after `offset` matches; the order
	/// holds while no entity gains or loses one of them.
	public int32 CopyManagedDataPage(Span<uint64> schemaIds, int32 offset, Span<uint64> entityIds, Span<uint8> bytes)
	{
		ManagedLocalSchema[MaxManagedQueryTerms] layouts = ?;
		if (offset < 0 || entityIds.IsEmpty || entityIds.Length > 4096 || bytes.Length > 4 * 1024 * 1024)
			return 0;
		if (!ManagedLayouts(schemaIds, .(&layouts, schemaIds.Length), let rowSize))
			return 0;
		int32 capacity = (int32)Math.Min(entityIds.Length, bytes.Length / rowSize);
		if (capacity <= 0)
			return 0;
		let query = ManagedDataQuery(schemaIds, .(&layouts, schemaIds.Length));
		if (query == null)
			return 0;
		Flecs.IterBuffer iterator = ?;
		Flecs.QueryIter(mWorld, query, &iterator);
		uint8*[MaxManagedQueryTerms] columns = ?;
		int32 visited = 0;
		int32 copied = 0;
		while (Flecs.IterNext(&iterator))
		{
			let ids = Flecs.IterEntities(&iterator);
			bool present = ids != null;
			for (int t < schemaIds.Length)
			{
				columns[t] = (uint8*)Flecs.IterField(&iterator, (int32)t, layouts[t].size);
				present &= columns[t] != null;
			}
			if (!present)
				continue;
			let count = Flecs.IterCount(&iterator);
			if (visited + count <= offset)
			{
				visited += count;
				continue;
			}
			for (int i < count)
			{
				if (visited++ < offset)
					continue;
				if (copied >= capacity)
				{
					Flecs.IterFini(&iterator);
					return copied;
				}
				entityIds[copied] = ids[i];
				int at = copied * rowSize;
				for (int t < schemaIds.Length)
				{
					let size = layouts[t].size;
					Internal.MemCpy(&bytes[at], columns[t] + i * size, size);
					at += size;
				}
				copied++;
			}
		}
		return copied;
	}

	/// Writes rows back in the order CopyManagedDataPage gave them, starting at the same offset: walks the query
	/// again and copies each row straight into its columns while the entity there is the one the row came from.
	/// A row whose entity is not where it was (one gained or lost a schema meanwhile) is written by looking it up
	/// (WriteManagedDataPage), or skipped if it has gone. Returns how many were written.
	public int32 WriteManagedDataPageOrdered(Span<uint64> schemaIds, int32 offset, Span<uint64> entityIds, Span<uint8> bytes)
	{
		ManagedLocalSchema[MaxManagedQueryTerms] layouts = ?;
		if (offset < 0 || entityIds.IsEmpty || entityIds.Length > 4096)
			return 0;
		if (!ManagedLayouts(schemaIds, .(&layouts, schemaIds.Length), let rowSize) || bytes.Length < entityIds.Length * rowSize)
			return 0;
		let query = ManagedDataQuery(schemaIds, .(&layouts, schemaIds.Length));
		if (query == null)
			return 0;
		Flecs.IterBuffer iterator = ?;
		Flecs.QueryIter(mWorld, query, &iterator);
		uint8*[MaxManagedQueryTerms] columns = ?;
		int32 visited = 0;
		int32 next = 0;
		int32 written = 0;
		let missed = scope List<int32>();
		while (true)
		{
			if (next >= entityIds.Length)
			{
				Flecs.IterFini(&iterator); // stopped before the end
				break;
			}
			if (!Flecs.IterNext(&iterator))
				break;
			let ids = Flecs.IterEntities(&iterator);
			bool present = ids != null;
			for (int t < schemaIds.Length)
			{
				columns[t] = (uint8*)Flecs.IterField(&iterator, (int32)t, layouts[t].size);
				present &= columns[t] != null;
			}
			if (!present)
				continue;
			let count = Flecs.IterCount(&iterator);
			if (visited + count <= offset)
			{
				visited += count;
				continue;
			}
			for (int i < count)
			{
				if (visited++ < offset)
					continue;
				if (next >= entityIds.Length)
					break;
				if (ids[i] != entityIds[next])
				{
					missed.Add(next++);
					continue;
				}
				int at = next * rowSize;
				for (int t < schemaIds.Length)
				{
					let size = layouts[t].size;
					Internal.MemCpy(columns[t] + i * size, &bytes[at], size);
					at += size;
				}
				next++;
				written++;
			}
		}
		while (next < entityIds.Length)
			missed.Add(next++);
		for (let row in missed)
			written += WriteManagedDataPage(schemaIds, .(&entityIds[row], 1), .(&bytes[row * rowSize], rowSize));
		return written;
	}

	/// Writes rows laid out as CopyManagedDataPage gives them back to their entities. An entity that has gone, or
	/// no longer has every schema, is skipped. Returns how many were written.
	public int32 WriteManagedDataPage(Span<uint64> schemaIds, Span<uint64> entityIds, Span<uint8> bytes)
	{
		ManagedLocalSchema[MaxManagedQueryTerms] layouts = ?;
		if (entityIds.IsEmpty || entityIds.Length > 4096)
			return 0;
		if (!ManagedLayouts(schemaIds, .(&layouts, schemaIds.Length), let rowSize) || bytes.Length < entityIds.Length * rowSize)
			return 0;
		int32 written = 0;
		for (int i < entityIds.Length)
		{
			let entity = Entity(entityIds[i]);
			if (!CanHoldManagedData(entity))
				continue;
			bool all = true;
			for (int t < schemaIds.Length)
				all &= Flecs.Has(mWorld, entity.id, layouts[t].flecsId);
			if (!all)
				continue;
			int at = i * rowSize;
			for (int t < schemaIds.Length)
			{
				let size = layouts[t].size;
				let target = (uint8*)Flecs.GetMut(mWorld, entity.id, layouts[t].flecsId);
				if (target != null)
					Internal.MemCpy(target, &bytes[at], size);
				at += size;
			}
			written++;
		}
		return written;
	}

	public Entity CreateManagedLocalEntity()
	{
		let entity = Create();
		if (!entity.IsNull)
			mManagedLocalEntities.Add(entity.id);
		return entity;
	}

	/// Deletes every bare entity C# gameplay created. Called when Play stops:
	/// the scene restores its GameObjects itself, but nothing else owns these.
	public void ClearManagedLocalEntities()
	{
		if (mManagedLocalEntities.Count == 0)
			return;
		let ids = scope List<uint64>(mManagedLocalEntities.Count);
		for (let id in mManagedLocalEntities)
			ids.Add(id);
		mManagedLocalEntities.Clear();
		for (let id in ids)
		{
			let entity = Entity(id);
			if (IsAlive(entity) && !IsSceneObject(entity))
				Delete(entity);
		}
	}

	public bool IsManagedLocalEntity(Entity entity) =>
		!entity.IsNull && mManagedLocalEntities.Contains(entity.id) &&
		IsAlive(entity) && !IsSceneObject(entity);

	/// Register opaque, *local-only* packed data. No native Jolt or built-in
	/// component can be registered through this path. A schema ID changes
	/// when the generated C# layout changes. Limits bound unmanaged memory.
	public uint64 RegisterManagedLocalSchema(uint64 schemaId, int32 size, int32 alignment)
	{
		if (schemaId == 0 || size <= 0 || size > 4096 ||
			alignment <= 0 || alignment > 16 ||
			(alignment & (alignment - 1)) != 0 || size % alignment != 0)
			return 0;
		if (mManagedLocalSchemas.TryGetValue(schemaId, let existing))
			return existing.size == size && existing.alignment == alignment ?
				existing.flecsId : 0;
		if (mManagedLocalSchemas.Count >= 1024)
			return 0;
		let name = scope String()..AppendF("Tallow.CSharp.Local.{}", schemaId);
		let component = Flecs.Component(mWorld, name.CStr(), size, alignment);
		if (component == 0)
			return 0;
		mManagedLocalSchemas[schemaId] = .()
		{
			flecsId = component,
			size = size,
			alignment = alignment
		};
		return component;
	}

	/// A whole-value write through Flecs.Set. Never return a Flecs pointer
	/// to .NET, and never let a short, stale or mismatched layout be copied.
	public bool SetManagedLocalData(Entity entity, uint64 schemaId, Span<uint8> bytes)
	{
		if (!CanHoldManagedData(entity))
			return false;
		if (!mManagedLocalSchemas.TryGetValue(schemaId, let layout))
			return false;
		if (bytes.Length != layout.size)
			return false;
		Flecs.Set(Writer, entity.id, layout.flecsId, layout.size, &bytes[0]);
		return true;
	}

	public bool CopyManagedLocalData(Entity entity, uint64 schemaId, Span<uint8> bytes)
	{
		if (!CanHoldManagedData(entity))
			return false;
		if (!mManagedLocalSchemas.TryGetValue(schemaId, let layout))
			return false;
		if (bytes.Length != layout.size)
			return false;
		let data = (uint8*)Flecs.Get(mWorld, entity.id, layout.flecsId);
		if (data == null)
			return false;
		for (int i < layout.size)
			bytes[i] = data[i];
		return true;
	}

	public bool RemoveManagedLocalData(Entity entity, uint64 schemaId)
	{
		if (!CanHoldManagedData(entity))
			return false;
		if (!mManagedLocalSchemas.TryGetValue(schemaId, let layout))
			return false;
		if (!Flecs.Has(mWorld, entity.id, layout.flecsId))
			return false;
		Flecs.Remove(Writer, entity.id, layout.flecsId);
		return true;
	}

	public bool HasManagedLocalData(Entity entity, uint64 schemaId)
	{
		if (!CanHoldManagedData(entity))
			return false;
		if (!mManagedLocalSchemas.TryGetValue(schemaId, let layout))
			return false;
		return Flecs.Has(mWorld, entity.id, layout.flecsId);
	}

	/// Count native Flecs query matches, not a managed list of entities.
	public int32 CountManagedLocalData(uint64 schemaId)
	{
		if (!mManagedLocalSchemas.TryGetValue(schemaId, let layout))
			return 0;
		let query = ManagedLocalQuery(schemaId, layout.flecsId);
		return query == null ? 0 : Flecs.QueryCount(query);
	}

	/// Copy real Flecs table columns. Values contain size-byte records,
	/// and IDs refer to Flecs entities, never GameObject IDs. Do not change
	/// ECS membership between offset-based query pages.
	public int32 CopyManagedLocalDataPage(uint64 schemaId, int32 offset,
		Span<uint64> entityIds, Span<uint8> bytes)
	{
		if (offset < 0 || entityIds.IsEmpty || bytes.IsEmpty ||
			entityIds.Length > 4096 || bytes.Length > 4 * 1024 * 1024)
			return 0;
		if (!mManagedLocalSchemas.TryGetValue(schemaId, let layout))
			return 0;
		int32 capacity = (int32)Math.Min(entityIds.Length, bytes.Length / layout.size);
		if (capacity <= 0)
			return 0;
		let query = ManagedLocalQuery(schemaId, layout.flecsId);
		if (query == null)
			return 0;

		Flecs.IterBuffer iterator = ?;
		Flecs.QueryIter(mWorld, query, &iterator);
		int32 visited = 0;
		int32 copied = 0;
		while (Flecs.IterNext(&iterator))
		{
			let ids = Flecs.IterEntities(&iterator);
			let values = (uint8*)Flecs.IterField(&iterator, 0, layout.size);
			if (ids == null || values == null)
				continue;
			for (int i < Flecs.IterCount(&iterator))
			{
				// Only entities C# may give data to (Set refuses the rest).
				if (!mManagedLocalEntities.Contains(ids[i]) && !IsSceneObject(.(ids[i])))
					continue;
				if (visited++ < offset)
					continue;
				if (copied >= capacity)
				{
					Flecs.IterFini(&iterator);
					return copied;
				}
				entityIds[copied] = ids[i];
				int source = (int)i * layout.size;
				int target = copied * layout.size;
				for (int b < layout.size)
					bytes[target + b] = values[source + b];
				copied++;
			}
		}
		return copied;
	}

	/// Test the scene-object link without registering its component in a
	/// standalone bulk ECS world merely to ask whether the entity is raw.
	public bool IsSceneObject(Entity entity)
	{
		let index = ComponentId<ObjectLink>.Index;
		return index < mIds.Count && mIds[index] != 0 && Flecs.Has(mWorld, entity.id, mIds[index]);
	}

	void TrackNativeCandidate(Entity entity, int32 index)
	{
		if (entity.IsNull || !DataComponents.IsSynced(index) || mNativeCandidates.Contains(entity.id))
			return;
		// Only the first enrolment needs a Flecs lookup. Query-driven
		// Set<T> calls on already-networked entities stay cheap.
		if (IsSceneObject(entity))
			return;
		if (mNativeCandidates.Add(entity.id))
			NativeNetwork?.NativeCandidateAdded(entity);
	}

	/// Replication can stop when the last synchronized type is removed.
	public void ForgetNativeCandidate(Entity entity)
	{
		mNativeCandidates.Remove(entity.id);
	}

	/// Flecs id of each ComponentTypes index, 0 until registered in this world.
	List<uint64> mIds = new .() ~ delete _;
	int32 mStageCount = 1;
	int32 mDeferDepth;
	/// Cached scene-object queries used by visual scripts and other scene-facing systems.
	/// Kept in the World so they are not rebuilt once per graph Update.
	Dictionary<int32, QueryBase> mObjectQueries = new .() ~ delete _;

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
		StopExplorer();
		for (let query in mManagedLocalQueries.Values)
			Flecs.QueryFree(query);
		mManagedLocalQueries.Clear();
		// Native queries must be released before their Flecs world.
		for (let query in mObjectQueries.Values)
			delete query;
		mObjectQueries.Clear();
		Flecs.WorldFree(mWorld);
	}

	// ---- Flecs Explorer ----

	void* mExplorer;

	/// The port the Flecs Explorer connects to by default.
	public const uint16 ExplorerPort = 27750;

	/// Serves this world to the Flecs Explorer (https://www.flecs.dev/explorer) until StopExplorer. False if the build
	/// has no Explorer support or the port is in use. Scene answers its requests once a frame (PollExplorer).
	public bool StartExplorer(uint16 port = ExplorerPort)
	{
		if (mExplorer == null)
			mExplorer = Flecs.ExplorerStart(mWorld, port);
		return mExplorer != null;
	}

	public bool ExplorerRunning => mExplorer != null;

	public void PollExplorer(float deltaTime)
	{
		if (mExplorer != null)
			Flecs.ExplorerPoll(mExplorer, deltaTime);
	}

	public void StopExplorer()
	{
		if (mExplorer != null)
		{
			Flecs.ExplorerStop(mExplorer);
			mExplorer = null;
		}
	}

	/// A pipeline: the steps (and later systems) tagged for it, run in phase order by Run. Scene has two, Frame and
	/// Tick (docs/ecs-plan.md, "Frame and tick order").
	public struct Pipeline
	{
		public uint64 id;
		public uint64 tag;
	}

	/// The steps' bodies, freed after the world (which frees its own record of them).
	List<delegate void()> mSteps = new .() ~ DeleteContainerAndItems!(_);

	public Pipeline CreatePipeline(StringView name)
	{
		Pipeline pipeline;
		pipeline.tag = Flecs.Tag(mWorld, scope String()..AppendF("{}Step", name).CStr());
		pipeline.id = Flecs.PipelineNew(mWorld, scope String(name).CStr(), pipeline.tag);
		Runtime.Assert(pipeline.id != 0, "Flecs refused the pipeline");
		return pipeline;
	}

	/// Adds a step to a pipeline: body runs once each time the pipeline runs, in phase (steps in one phase run in
	/// the order they were added). The world owns body. Steps may change the world directly.
	public void AddStep(Pipeline pipeline, StringView name, Flecs.Phase phase, delegate void() body)
	{
		mSteps.Add(body);
		let id = Flecs.StepNew(mWorld, scope String(name).CStr(), phase, pipeline.tag, => RunStep, Internal.UnsafeCastToPtr(body));
		Runtime.Assert(id != 0, "Flecs refused the step");
	}

	static void RunStep(void* context)
	{
		let body = (delegate void())Internal.UnsafeCastToObject(context);
		body();
	}

	/// Runs every step and system of a pipeline, in phase order.
	public void Run(Pipeline pipeline, float deltaTime) => Flecs.RunPipeline(mWorld, pipeline.id, deltaTime);

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
		// A built-in component's data can be switched off per object (ComponentHandle.enabled).
		if (info.type != null && info.type.GetCustomAttribute<HandleDataAttribute>() case .Ok)
		{
			Flecs.CanToggle(mWorld, id);
			// One that keeps things outside its data (ComponentState) frees them when it goes.
			if (let handle = HandleComponents.Find(index))
			{
				if (handle.onRemove != null)
					Flecs.OnRemove(mWorld, id, handle.onRemove, Internal.UnsafeCastToPtr(this));
			}
		}
		mIds[index] = id;
		mIndexById[id] = index;
		return id;
	}

	Dictionary<uint64, int32> mIndexById = new .() ~ delete _;

	// ---- By type index (ComponentTypes), for the editor and scene files ----

	/// This world's Flecs id for the data component with ComponentTypes index index.
	public uint64 IdOf(int32 index)
	{
		if (index < mIds.Count && mIds[index] != 0)
			return mIds[index];
		return Register(index);
	}

	/// The entity's data for that type, or null. Valid until the entity's components change.
	public void* Get(Entity entity, int32 index) => Flecs.GetMut(mWorld, entity.id, IdOf(index));
	/// The entity's data for that type, added (zeroed) first if missing.
	public void* Ensure(Entity entity, int32 index)
	{
		let data = Flecs.Ensure(Writer, entity.id, IdOf(index), ComponentTypes.Get(index).size);
		TrackNativeCandidate(entity, index);
		return data;
	}

	public bool Has(Entity entity, int32 index) => Flecs.Has(mWorld, entity.id, IdOf(index));
	public void Remove(Entity entity, int32 index) => Flecs.Remove(Writer, entity.id, IdOf(index));
	/// Switches a [HandleData] component on or off for one entity; queries skip it while it is off.
	public void Enable(Entity entity, int32 index, bool enabled) => Flecs.EnableId(Writer, entity.id, IdOf(index), enabled);
	public bool IsEnabled(Entity entity, int32 index) => Flecs.IsEnabledId(mWorld, entity.id, IdOf(index));

	/// The ComponentTypes indices of the data components and tags the entity has, in Flecs's order. Relationships
	/// (ChildOf) and ids registered outside World are left out.
	public void TypesOf(Entity entity, List<int32> output)
	{
		uint64[64] ids = ?;
		let count = Math.Min(Flecs.EntityIds(mWorld, entity.id, &ids, 64), 64);
		for (int i < count)
		{
			if (mIndexById.TryGetValue(ids[i], let index))
				output.Add(index);
		}
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
		// One reflection check per bulk operation, not per entity. Unmarked
		// components continue to use Flecs's original fast bulk-create path.
		if (DataComponents.IsSynced(ComponentId<T>.Index))
		{
			for (int i < count)
			{
				Entity entity = .(ids[i]);
				TrackNativeCandidate(entity, ComponentId<T>.Index);
			}
		}
	}

	public void Delete(Entity entity)
	{
		mManagedLocalEntities.Remove(entity.id);
		if (mNativeCandidates.Remove(entity.id))
			NativeNetwork?.NativeCandidateRemoved(entity);
		Flecs.Delete(Writer, entity.id);
	}

	public bool IsAlive(Entity entity) => Flecs.IsAlive(mWorld, entity.id);

	public void Add<T>(Entity entity) where T : struct
	{
		Flecs.Add(Writer, entity.id, Id<T>());
		TrackNativeCandidate(entity, ComponentId<T>.Index);
	}

	public void Remove<T>(Entity entity) where T : struct => Flecs.Remove(Writer, entity.id, Id<T>());
	public bool Has<T>(Entity entity) where T : struct => Flecs.Has(mWorld, entity.id, Id<T>());

	/// The entity's T, or null if it has none. Valid until the entity's components change.
	public T* Get<T>(Entity entity) where T : struct => (T*)Flecs.GetMut(mWorld, entity.id, Id<T>());

	/// The entity's T, added (zeroed) first if it has none. Valid until the entity's components change.
	public ref T Ensure<T>(Entity entity) where T : struct
	{
		let data = (T*)Flecs.Ensure(Writer, entity.id, Id<T>(), strideof(T));
		TrackNativeCandidate(entity, ComponentId<T>.Index);
		return ref *data;
	}

	/// Adds T if needed and sets it to value.
	public void Set<T>(Entity entity, T value) where T : struct
	{
		var value;
		Flecs.Set(Writer, entity.id, Id<T>(), strideof(T), &value);
		TrackNativeCandidate(entity, ComponentId<T>.Index);
	}

	/// How many entities have T.
	public int Count<T>() where T : struct => Flecs.Count(mWorld, Id<T>());
	/// How many entities have the component with this ComponentTypes index, switched on or off.
	/// A type this world has not registered yet has none, and is not registered by asking.
	public int Count(int32 index)
	{
		if (index >= mIds.Count || mIds[index] == 0)
			return 0;
		return Flecs.Count(mWorld, mIds[index]);
	}

	/// Cached query of scene GameObjects with custom ECS data T. This returns the same
	/// Flecs query each time; do not delete it. Useful for high-volume visual graphs
	/// and scripts that want a familiar object while processing packed data.
	public Query<T, ObjectLink> ObjectsWith<T>() where T : struct
	{
		let key = ComponentId<T>.Index;
		if (mObjectQueries.TryGetValue(key, let existing))
			return (Query<T, ObjectLink>)existing;
		let query = new Query<T, ObjectLink>(this, .ReadWrite, .Read);
		mObjectQueries[key] = query;
		return query;
	}


	/// Cached query of every entity with T, scene objects and bare entities alike (World.IsSceneObject tells them
	/// apart). The same Flecs query each time; do not delete it.
	public Query<T> EntitiesWith<T>() where T : struct
	{
		let key = -1 - ComponentId<T>.Index;
		if (mObjectQueries.TryGetValue(key, let existing))
			return (Query<T>)existing;
		let query = new Query<T>(this);
		mObjectQueries[key] = query;
		return query;
	}


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
