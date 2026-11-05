using System;

namespace Tallow;

/// The C functions of native/tallow_ecs.c, the thin layer over Flecs (docs/ecs-plan.md). Only engine code calls
/// these; World, Query and ComponentId are the Beef side of the ECS.
static class Flecs
{
	/// How a query term is used. The values match native/tallow_ecs.c.
	public enum TermAccess : int32
	{
		/// Read only.
		Read = 0,
		/// Written, not read.
		Write = 1,
		ReadWrite = 2,
		/// Must be present; its data is not used.
		Filter = 3,
		/// Must not be present.
		Without = 4,
		/// Used if present: its column is empty in chunks that lack it.
		Optional = 5,
	}

	/// Flecs pipeline phases in the order Tallow runs them (docs/ecs-plan.md, "Frame and tick order"). The values
	/// match native/tallow_ecs.c.
	public enum Phase : int32
	{
		OnLoad = 0,
		PostLoad,
		PreUpdate,
		OnUpdate,
		OnValidate,
		PostUpdate,
		PreStore,
		OnStore,
	}

	/// Iterator storage: Flecs's ecs_iter_t is opaque to Beef, which only keeps room for it (checked against
	/// tallow_ecs_iter_size() when the first World is made). A worker iterator needs two (see QueryWorkerIter).
	[CRepr, Align(16)]
	public struct IterBuffer
	{
		public const int Size = 512;
		uint8[Size] mData;
	}

	[CRepr, Align(16)]
	public struct WorkerIterBuffer
	{
		public IterBuffer iterator;
		public IterBuffer source;
	}

	/// An ecs_ref_t without FLECS_DEBUG (native/tallow_ecs.c checks the field offsets; World checks the size).
	[CRepr]
	public struct RefBuffer
	{
		public const int Size = 32;
		public uint64 entity;
		public uint64 tableId;
		public uint32 tableVersionFast;
		public uint16 tableVersion;
		public void* ptr;
	}

	public function void SystemCallback(void* iterator);

	// ---- Worlds ----
	[LinkName("tallow_ecs_world_new")] public static extern void* WorldNew();
	[LinkName("tallow_ecs_world_free")] public static extern void WorldFree(void* world);
	[LinkName("tallow_ecs_version")] public static extern int32 Version();
	[LinkName("tallow_ecs_iter_size")] public static extern int32 IterSize();
	[LinkName("tallow_ecs_progress")] public static extern bool Progress(void* world, float deltaTime);
	[LinkName("tallow_ecs_set_threads")] public static extern void SetThreads(void* world, int32 threads);
	[LinkName("tallow_ecs_set_stage_count")] public static extern void SetStageCount(void* world, int32 count);
	[LinkName("tallow_ecs_stage")] public static extern void* Stage(void* world, int32 index);
	[LinkName("tallow_ecs_readonly_begin")] public static extern bool ReadonlyBegin(void* world, bool multiThreaded);
	[LinkName("tallow_ecs_readonly_end")] public static extern void ReadonlyEnd(void* world);
	/// Applies the changes queued on a stage (Flecs 4.2 queues changes on stages; the world itself never defers).
	[LinkName("tallow_ecs_merge")] public static extern void Merge(void* stage);
	[LinkName("tallow_ecs_is_stage")] public static extern bool IsStage(void* world);

	// ---- Components ----
	[LinkName("tallow_ecs_component")] public static extern uint64 Component(void* world, char8* name, int32 size, int32 alignment);
	[LinkName("tallow_ecs_tag")] public static extern uint64 Tag(void* world, char8* name);
	[LinkName("tallow_ecs_lookup")] public static extern uint64 Lookup(void* world, char8* name);

	// ---- Entities ----
	[LinkName("tallow_ecs_new")] public static extern uint64 New(void* world);
	[LinkName("tallow_ecs_bulk_new")] public static extern uint64* BulkNew(void* world, uint64 component, int32 count);
	[LinkName("tallow_ecs_delete")] public static extern void Delete(void* world, uint64 entity);
	[LinkName("tallow_ecs_is_alive")] public static extern bool IsAlive(void* world, uint64 entity);
	[LinkName("tallow_ecs_add")] public static extern void Add(void* world, uint64 entity, uint64 id);
	[LinkName("tallow_ecs_remove")] public static extern void Remove(void* world, uint64 entity, uint64 id);
	[LinkName("tallow_ecs_has")] public static extern bool Has(void* world, uint64 entity, uint64 id);
	[LinkName("tallow_ecs_get")] public static extern void* Get(void* world, uint64 entity, uint64 id);
	[LinkName("tallow_ecs_get_mut")] public static extern void* GetMut(void* world, uint64 entity, uint64 id);
	[LinkName("tallow_ecs_ensure")] public static extern void* Ensure(void* world, uint64 entity, uint64 id, int32 size);
	[LinkName("tallow_ecs_set")] public static extern void Set(void* world, uint64 entity, uint64 id, int32 size, void* data);
	[LinkName("tallow_ecs_modified")] public static extern void Modified(void* world, uint64 entity, uint64 id);
	[LinkName("tallow_ecs_count")] public static extern int32 Count(void* world, uint64 id);
	[LinkName("tallow_ecs_enable")] public static extern void Enable(void* world, uint64 entity, bool enabled);

	// ---- Relationships and hierarchy ----
	[LinkName("tallow_ecs_pair")] public static extern uint64 Pair(uint64 relationship, uint64 target);
	[LinkName("tallow_ecs_child_of")] public static extern uint64 ChildOf();
	[LinkName("tallow_ecs_is_a")] public static extern uint64 IsA();
	[LinkName("tallow_ecs_prefab")] public static extern uint64 Prefab();
	[LinkName("tallow_ecs_disabled")] public static extern uint64 Disabled();
	[LinkName("tallow_ecs_wildcard")] public static extern uint64 Wildcard();
	[LinkName("tallow_ecs_set_parent")] public static extern void SetParent(void* world, uint64 child, uint64 parent);
	[LinkName("tallow_ecs_parent")] public static extern uint64 Parent(void* world, uint64 entity);
	[LinkName("tallow_ecs_target")] public static extern uint64 Target(void* world, uint64 entity, uint64 relationship, int32 index);

	// ---- Queries ----
	[LinkName("tallow_ecs_query_new")] public static extern void* QueryNew(void* world, uint64* ids, TermAccess* access, int32 count);
	[LinkName("tallow_ecs_query_free")] public static extern void QueryFree(void* query);
	[LinkName("tallow_ecs_query_count")] public static extern int32 QueryCount(void* query);
	[LinkName("tallow_ecs_query_iter")] public static extern void QueryIter(void* world, void* query, IterBuffer* output);
	/// output must stay in place until the iteration ends: its first iterator reads from its second.
	[LinkName("tallow_ecs_query_worker_iter")] public static extern void QueryWorkerIter(void* world, void* query, int32 index, int32 count, WorkerIterBuffer* output);
	[LinkName("tallow_ecs_iter_next")] public static extern bool IterNext(void* iterator);
	[LinkName("tallow_ecs_iter_fini")] public static extern void IterFini(void* iterator);
	[LinkName("tallow_ecs_iter_count")] public static extern int32 IterCount(void* iterator);
	[LinkName("tallow_ecs_iter_entities")] public static extern uint64* IterEntities(void* iterator);
	[LinkName("tallow_ecs_iter_field")] public static extern void* IterField(void* iterator, int32 index, int32 size);
	[LinkName("tallow_ecs_iter_field_is_self")] public static extern bool IterFieldIsSelf(void* iterator, int32 index);
	[LinkName("tallow_ecs_iter_delta_time")] public static extern float IterDeltaTime(void* iterator);
	[LinkName("tallow_ecs_iter_ctx")] public static extern void* IterContext(void* iterator);
	[LinkName("tallow_ecs_iter_world")] public static extern void* IterWorld(void* iterator);
	/// The stage a system's changes should be queued on.
	[LinkName("tallow_ecs_iter_stage")] public static extern void* IterStage(void* iterator);

	// ---- Cached component references ----
	[LinkName("tallow_ecs_ref_size")] public static extern int32 RefSize();
	[LinkName("tallow_ecs_ref_init")] public static extern void RefInit(void* world, uint64 entity, uint64 id, RefBuffer* output);
	[LinkName("tallow_ecs_ref_get")] public static extern void* RefGet(void* world, RefBuffer* reference, uint64 id);
	[LinkName("tallow_ecs_table_versions")] public static extern uint32* TableVersions(void* world);
	[LinkName("tallow_ecs_table_version_mask")] public static extern int32 TableVersionMask();

	// ---- Pipelines and steps ----
	public function void StepCallback(void* context);
	[LinkName("tallow_ecs_pipeline_new")] public static extern uint64 PipelineNew(void* world, char8* name, uint64 tag);
	[LinkName("tallow_ecs_run_pipeline")] public static extern void RunPipeline(void* world, uint64 pipeline, float deltaTime);
	[LinkName("tallow_ecs_step_new")] public static extern uint64 StepNew(void* world, char8* name, Phase phase, uint64 tag, StepCallback callback, void* context);

	// ---- Systems ----
	[LinkName("tallow_ecs_phase")] public static extern uint64 PhaseId(Phase phase);
	[LinkName("tallow_ecs_system_new")] public static extern uint64 SystemNew(void* world, char8* name, Phase phase, uint64* ids, TermAccess* access, int32 count, SystemCallback callback, void* context, bool multiThreaded);
}
