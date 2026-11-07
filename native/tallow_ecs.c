// Thin C layer over Flecs (docs/ecs-plan.md), so the Beef side never mirrors Flecs's descriptor structs or C macros.
// Every function here is plain: ids in, ids or pointers out. Engine/src/Ecs/Flecs.bf declares them.
//
// Iterators are opaque to Beef: it keeps a buffer of tallow_ecs_iter_size() bytes (checked at startup) and passes
// its address to the iterator functions. The buffer must not move while an iteration is running.
#include "flecs.h"

#include <stddef.h>

#include <string.h>

#if defined(_WIN32)
#define TALLOW_ECS_API __declspec(dllexport)
#else
#define TALLOW_ECS_API __attribute__((visibility("default")))
#endif

// How a query term is used, as Beef passes it (Ecs/Query.bf, TermAccess).
enum
{
	TALLOW_TERM_READ = 0,
	TALLOW_TERM_WRITE = 1,
	TALLOW_TERM_READ_WRITE = 2,
	// Must be present, but its data is not used.
	TALLOW_TERM_FILTER = 3,
	// Must not be present.
	TALLOW_TERM_WITHOUT = 4,
	// Used if present (its field is null in chunks that lack it).
	TALLOW_TERM_OPTIONAL = 5,
};

// Pipeline phases, in Tallow's order (docs/ecs-plan.md, "Frame and tick order").
enum
{
	TALLOW_PHASE_ON_LOAD = 0,
	TALLOW_PHASE_POST_LOAD,
	TALLOW_PHASE_PRE_UPDATE,
	TALLOW_PHASE_ON_UPDATE,
	TALLOW_PHASE_ON_VALIDATE,
	TALLOW_PHASE_POST_UPDATE,
	TALLOW_PHASE_PRE_STORE,
	TALLOW_PHASE_ON_STORE,
};

// ---- Worlds ----

TALLOW_ECS_API ecs_world_t* tallow_ecs_world_new(void)
{
	// ecs_mini leaves the addons out; systems and pipelines (Scene's Frame and Tick) need these two.
	ecs_world_t* world = ecs_mini();
	ECS_IMPORT(world, FlecsSystem);
	ECS_IMPORT(world, FlecsPipeline);
	return world;
}

TALLOW_ECS_API ecs_world_t* tallow_ecs_world_new_full(void)
{
	ecs_world_t* world = ecs_init();
	return world;
}

TALLOW_ECS_API void tallow_ecs_world_free(ecs_world_t* world)
{
	ecs_fini(world);
}

TALLOW_ECS_API int32_t tallow_ecs_version(void)
{
	return FLECS_VERSION_MAJOR * 10000 + FLECS_VERSION_MINOR * 100 + FLECS_VERSION_PATCH;
}

TALLOW_ECS_API int32_t tallow_ecs_iter_size(void)
{
	return (int32_t)sizeof(ecs_iter_t);
}

// Runs the world's pipeline (every system, phase by phase). Returns false once the world was asked to quit.
TALLOW_ECS_API bool tallow_ecs_progress(ecs_world_t* world, float delta_time)
{
	return ecs_progress(world, (ecs_ftime_t)delta_time);
}

// Flecs's own worker threads for multithreaded systems. Tallow's Jobs threads are the usual way to spread work;
// this exists for comparison (docs/ecs-plan.md, "Threads").
TALLOW_ECS_API void tallow_ecs_set_threads(ecs_world_t* world, int32_t threads)
{
	ecs_set_threads(world, threads);
}

// Stages let several threads iterate at once: one stage per thread, used between readonly_begin and readonly_end.
TALLOW_ECS_API void tallow_ecs_set_stage_count(ecs_world_t* world, int32_t count)
{
	ecs_set_stage_count(world, count);
}

TALLOW_ECS_API ecs_world_t* tallow_ecs_stage(ecs_world_t* world, int32_t index)
{
	return ecs_get_stage(world, index);
}

TALLOW_ECS_API bool tallow_ecs_readonly_begin(ecs_world_t* world, bool multi_threaded)
{
	return ecs_readonly_begin(world, multi_threaded);
}

TALLOW_ECS_API void tallow_ecs_readonly_end(ecs_world_t* world)
{
	ecs_readonly_end(world);
}

// Flecs 4.2 has no deferred mode on the world: changes are queued by passing a stage instead of the world, and
// applied when that stage is merged. Beef's World.DeferBegin/DeferEnd use stage 0 this way.
TALLOW_ECS_API void tallow_ecs_merge(ecs_world_t* stage)
{
	ecs_merge(stage);
}

TALLOW_ECS_API bool tallow_ecs_is_stage(const ecs_world_t* world)
{
	return ecs_is_stage(world);
}

TALLOW_ECS_API ecs_world_t* tallow_ecs_iter_stage(const ecs_iter_t* it)
{
	return it->stage;
}

// ---- Components ----

// Registers a plain-data component (no constructor or destructor: Tallow's data components hold no heap fields).
TALLOW_ECS_API uint64_t tallow_ecs_component(ecs_world_t* world, const char* name, int32_t size, int32_t alignment)
{
	ecs_entity_desc_t entity = {0};
	entity.name = name;
	entity.symbol = name;
	entity.sep = ".";
	entity.use_low_id = true;
	ecs_entity_t id = ecs_entity_init(world, &entity);
	if (!id)
		return 0;
	ecs_component_desc_t desc = {0};
	desc.entity = id;
	desc.type.size = size;
	desc.type.alignment = alignment;
	return ecs_component_init(world, &desc);
}

// A component with no data (a tag).
TALLOW_ECS_API uint64_t tallow_ecs_tag(ecs_world_t* world, const char* name)
{
	ecs_entity_desc_t entity = {0};
	entity.name = name;
	entity.sep = ".";
	entity.use_low_id = true;
	return ecs_entity_init(world, &entity);
}

TALLOW_ECS_API uint64_t tallow_ecs_lookup(ecs_world_t* world, const char* name)
{
	return ecs_lookup_path_w_sep(world, 0, name, ".", NULL, false);
}

// ---- Entities ----

TALLOW_ECS_API uint64_t tallow_ecs_new(ecs_world_t* world)
{
	return ecs_new(world);
}

// Creates count entities that have one component each, with zeroed data. Returns the first of count ids; the
// array stays valid until the next operation that creates entities.
TALLOW_ECS_API const uint64_t* tallow_ecs_bulk_new(ecs_world_t* world, uint64_t component, int32_t count)
{
	return ecs_bulk_new_w_id(world, component, count);
}

TALLOW_ECS_API void tallow_ecs_delete(ecs_world_t* world, uint64_t entity)
{
	ecs_delete(world, entity);
}

TALLOW_ECS_API bool tallow_ecs_is_alive(const ecs_world_t* world, uint64_t entity)
{
	return entity != 0 && ecs_is_alive(world, entity);
}

TALLOW_ECS_API void tallow_ecs_add(ecs_world_t* world, uint64_t entity, uint64_t id)
{
	ecs_add_id(world, entity, id);
}

TALLOW_ECS_API void tallow_ecs_remove(ecs_world_t* world, uint64_t entity, uint64_t id)
{
	ecs_remove_id(world, entity, id);
}

TALLOW_ECS_API bool tallow_ecs_has(const ecs_world_t* world, uint64_t entity, uint64_t id)
{
	return ecs_has_id(world, entity, id);
}

// The component's data, or null if the entity does not have it.
TALLOW_ECS_API const void* tallow_ecs_get(const ecs_world_t* world, uint64_t entity, uint64_t id)
{
	return ecs_get_id(world, entity, id);
}

TALLOW_ECS_API void* tallow_ecs_get_mut(const ecs_world_t* world, uint64_t entity, uint64_t id)
{
	return ecs_get_mut_id(world, entity, id);
}

// The component's data, added (zeroed) first if the entity lacks it.
TALLOW_ECS_API void* tallow_ecs_ensure(ecs_world_t* world, uint64_t entity, uint64_t id, int32_t size)
{
	return ecs_ensure_id(world, entity, id, (size_t)size);
}

TALLOW_ECS_API void tallow_ecs_set(ecs_world_t* world, uint64_t entity, uint64_t id, int32_t size, const void* data)
{
	ecs_set_id(world, entity, id, (size_t)size, data);
}

TALLOW_ECS_API void tallow_ecs_modified(ecs_world_t* world, uint64_t entity, uint64_t id)
{
	ecs_modified_id(world, entity, id);
}

TALLOW_ECS_API int32_t tallow_ecs_count(const ecs_world_t* world, uint64_t id)
{
	return ecs_count_id(world, id);
}

// ---- Relationships and hierarchy ----

TALLOW_ECS_API uint64_t tallow_ecs_pair(uint64_t relationship, uint64_t target)
{
	return ecs_pair(relationship, target);
}

TALLOW_ECS_API uint64_t tallow_ecs_child_of(void)
{
	return EcsChildOf;
}

TALLOW_ECS_API uint64_t tallow_ecs_is_a(void)
{
	return EcsIsA;
}

TALLOW_ECS_API uint64_t tallow_ecs_prefab(void)
{
	return EcsPrefab;
}

TALLOW_ECS_API uint64_t tallow_ecs_disabled(void)
{
	return EcsDisabled;
}

TALLOW_ECS_API uint64_t tallow_ecs_wildcard(void)
{
	return EcsWildcard;
}

TALLOW_ECS_API void tallow_ecs_set_parent(ecs_world_t* world, uint64_t child, uint64_t parent)
{
	ecs_remove_pair(world, child, EcsChildOf, EcsWildcard);
	if (parent)
		ecs_add_pair(world, child, EcsChildOf, parent);
}

TALLOW_ECS_API uint64_t tallow_ecs_parent(const ecs_world_t* world, uint64_t entity)
{
	return ecs_get_parent(world, entity);
}

TALLOW_ECS_API uint64_t tallow_ecs_target(const ecs_world_t* world, uint64_t entity, uint64_t relationship, int32_t index)
{
	return ecs_get_target(world, entity, relationship, index);
}

// ---- Queries ----

static void tallow_ecs_fill_terms(ecs_query_desc_t* desc, const uint64_t* ids, const int32_t* access, int32_t count)
{
	for (int32_t i = 0; i < count; i++)
	{
		ecs_term_t* term = &desc->terms[i];
		term->id = ids[i];
		switch (access[i])
		{
		case TALLOW_TERM_READ: term->inout = EcsIn; break;
		case TALLOW_TERM_WRITE: term->inout = EcsOut; break;
		case TALLOW_TERM_FILTER: term->inout = EcsInOutNone; break;
		case TALLOW_TERM_WITHOUT: term->inout = EcsInOutNone; term->oper = EcsNot; break;
		case TALLOW_TERM_OPTIONAL: term->inout = EcsInOut; term->oper = EcsOptional; break;
		default: term->inout = EcsInOut; break;
		}
	}
}

// A cached query over count terms. Returns null if there are too many terms or Flecs rejects them.
TALLOW_ECS_API ecs_query_t* tallow_ecs_query_new(ecs_world_t* world, const uint64_t* ids, const int32_t* access, int32_t count)
{
	if (count < 1 || count > FLECS_TERM_COUNT_MAX)
		return NULL;
	ecs_query_desc_t desc = {0};
	tallow_ecs_fill_terms(&desc, ids, access, count);
	desc.cache_kind = EcsQueryCacheAuto;
	return ecs_query_init(world, &desc);
}

TALLOW_ECS_API void tallow_ecs_query_free(ecs_query_t* query)
{
	ecs_query_fini(query);
}

TALLOW_ECS_API int32_t tallow_ecs_query_count(ecs_query_t* query)
{
	return ecs_query_count(query).entities;
}

// Starts iterating a query into the caller's buffer (tallow_ecs_iter_size() bytes). world may be a stage.
TALLOW_ECS_API void tallow_ecs_query_iter(const ecs_world_t* world, ecs_query_t* query, ecs_iter_t* out)
{
	*out = ecs_query_iter(world, query);
}

// As tallow_ecs_query_iter, but only the share of the results for worker index of count (a parallel loop). The
// worker iterator reads from the query iterator, so the caller keeps both: out is two iterators long (the second
// is the query iterator), and stays in place until the iteration ends.
TALLOW_ECS_API void tallow_ecs_query_worker_iter(const ecs_world_t* world, ecs_query_t* query, int32_t index, int32_t count, ecs_iter_t* out)
{
	out[1] = ecs_query_iter(world, query);
	out[0] = ecs_worker_iter(&out[1], index, count);
}

TALLOW_ECS_API bool tallow_ecs_iter_next(ecs_iter_t* it)
{
	return ecs_iter_next(it);
}

// Ends an iteration that stopped before next returned false.
TALLOW_ECS_API void tallow_ecs_iter_fini(ecs_iter_t* it)
{
	ecs_iter_fini(it);
}

TALLOW_ECS_API int32_t tallow_ecs_iter_count(const ecs_iter_t* it)
{
	return it->count;
}

TALLOW_ECS_API const uint64_t* tallow_ecs_iter_entities(const ecs_iter_t* it)
{
	return it->entities;
}

// The column of term index in the current chunk (null for an optional term the chunk lacks).
TALLOW_ECS_API void* tallow_ecs_iter_field(const ecs_iter_t* it, int32_t index, int32_t size)
{
	return ecs_field_w_size(it, (size_t)size, (int8_t)index);
}

// Whether the term's data is one shared value rather than a column (from a prefab or a parent).
TALLOW_ECS_API bool tallow_ecs_iter_field_is_self(const ecs_iter_t* it, int32_t index)
{
	return ecs_field_is_self(it, (int8_t)index);
}

TALLOW_ECS_API float tallow_ecs_iter_delta_time(const ecs_iter_t* it)
{
	return (float)it->delta_time;
}

TALLOW_ECS_API void* tallow_ecs_iter_ctx(const ecs_iter_t* it)
{
	return it->callback_ctx;
}

TALLOW_ECS_API ecs_world_t* tallow_ecs_iter_world(const ecs_iter_t* it)
{
	return it->world;
}

// ---- Systems and pipeline phases ----

TALLOW_ECS_API uint64_t tallow_ecs_phase(int32_t phase)
{
	switch (phase)
	{
	case TALLOW_PHASE_ON_LOAD: return EcsOnLoad;
	case TALLOW_PHASE_POST_LOAD: return EcsPostLoad;
	case TALLOW_PHASE_PRE_UPDATE: return EcsPreUpdate;
	case TALLOW_PHASE_ON_UPDATE: return EcsOnUpdate;
	case TALLOW_PHASE_ON_VALIDATE: return EcsOnValidate;
	case TALLOW_PHASE_POST_UPDATE: return EcsPostUpdate;
	case TALLOW_PHASE_PRE_STORE: return EcsPreStore;
	case TALLOW_PHASE_ON_STORE: return EcsOnStore;
	default: return 0;
	}
}

typedef void (*tallow_ecs_system_fn)(ecs_iter_t* it);

// A system that runs callback once per matching chunk in phase. multi_threaded spreads the chunks over the
// threads given by tallow_ecs_set_threads; ctx is passed through (tallow_ecs_iter_ctx).
TALLOW_ECS_API uint64_t tallow_ecs_system_new(ecs_world_t* world, const char* name, int32_t phase, const uint64_t* ids, const int32_t* access, int32_t count,
	tallow_ecs_system_fn callback, void* ctx, bool multi_threaded)
{
	if (count < 0 || count > FLECS_TERM_COUNT_MAX)
		return 0;
	ecs_entity_t phase_id = tallow_ecs_phase(phase);
	if (!phase_id)
		return 0;
	ecs_entity_desc_t entity = {0};
	entity.name = name;
	entity.sep = ".";
	ecs_entity_t system = ecs_entity_init(world, &entity);
	if (!system)
		return 0;
	ecs_add_pair(world, system, EcsDependsOn, phase_id);
	ecs_add_id(world, system, phase_id);
	ecs_system_desc_t desc = {0};
	desc.entity = system;
	tallow_ecs_fill_terms(&desc.query, ids, access, count);
	desc.callback = (ecs_iter_action_t)callback;
	desc.callback_ctx = ctx;
	desc.multi_threaded = multi_threaded;
	return ecs_system_init(world, &desc);
}

// The ids (components, tags, pairs) an entity has, written to out up to max; returns how many it has.
TALLOW_ECS_API int32_t tallow_ecs_entity_ids(const ecs_world_t* world, uint64_t entity, uint64_t* out, int32_t max)
{
	const ecs_type_t* type = ecs_get_type(world, entity);
	if (!type)
		return 0;
	for (int32_t i = 0; i < type->count && i < max; i++)
		out[i] = type->array[i];
	return type->count;
}

// ---- Flecs Explorer ----

// Starts Flecs's REST server on port so the Flecs Explorer (flecs.dev/explorer) can show this world. Returns the
// server, or NULL when the build leaves the Explorer out (TALLOW_FLECS_EXPLORER) or the port is taken. Requests are
// answered by tallow_ecs_explorer_poll on the calling thread.
TALLOW_ECS_API void* tallow_ecs_explorer_start(ecs_world_t* world, uint16_t port)
{
#ifdef FLECS_REST
	ecs_http_server_desc_t desc = {0};
	desc.port = port;
	ecs_http_server_t* server = ecs_rest_server_init(world, &desc);
	if (!server)
		return NULL;
	if (ecs_http_server_start(server) != 0)
	{
		ecs_rest_server_fini(server);
		return NULL;
	}
	return server;
#else
	(void)world;
	(void)port;
	return NULL;
#endif
}

TALLOW_ECS_API void tallow_ecs_explorer_poll(void* server, float delta_time)
{
#ifdef FLECS_REST
	if (server)
		ecs_http_server_dequeue((ecs_http_server_t*)server, delta_time);
#else
	(void)server;
	(void)delta_time;
#endif
}

TALLOW_ECS_API void tallow_ecs_explorer_stop(void* server)
{
#ifdef FLECS_REST
	if (server)
		ecs_rest_server_fini((ecs_http_server_t*)server);
#else
	(void)server;
#endif
}

// ---- Pipelines and steps ----

// A pipeline that runs the systems tagged with tag, ordered by phase as Flecs's own pipeline is.
TALLOW_ECS_API uint64_t tallow_ecs_pipeline_new(ecs_world_t* world, const char* name, uint64_t tag)
{
	ecs_entity_desc_t entity = {0};
	entity.name = name;
	ecs_pipeline_desc_t desc = {0};
	desc.entity = ecs_entity_init(world, &entity);
	desc.query.terms[0].id = EcsSystem;
	desc.query.terms[1].id = tag;
	desc.query.terms[2].id = EcsPhase;
	desc.query.terms[2].src.id = EcsCascade;
	desc.query.terms[2].trav = EcsDependsOn;
	desc.query.terms[3].id = EcsDisabled;
	desc.query.terms[3].src.id = EcsUp;
	desc.query.terms[3].trav = EcsDependsOn;
	desc.query.terms[3].oper = EcsNot;
	desc.query.terms[4].id = EcsDisabled;
	desc.query.terms[4].src.id = EcsUp;
	desc.query.terms[4].trav = EcsChildOf;
	desc.query.terms[4].oper = EcsNot;
	return ecs_pipeline_init(world, &desc);
}

TALLOW_ECS_API void tallow_ecs_run_pipeline(ecs_world_t* world, uint64_t pipeline, float delta_time)
{
	ecs_run_pipeline(world, pipeline, delta_time);
}

typedef void (*tallow_ecs_step_fn)(void* ctx);

typedef struct tallow_ecs_step_t
{
	tallow_ecs_step_fn fn;
	void* ctx;
} tallow_ecs_step_t;

static void tallow_ecs_run_step(ecs_iter_t* it)
{
	// An immediate system gets the world itself, and Flecs 4.2 never defers the world, so what a step (or a script
	// it runs) changes takes effect at once: creating an object and reading it back works as outside a pipeline.
	tallow_ecs_step_t* step = (tallow_ecs_step_t*)it->callback_ctx;
	step->fn(step->ctx);
}

// A step: a system with no query that calls fn(ctx) once each time its pipeline (tagged tag) runs, in phase.
// It runs on the calling thread with direct access to the world.
TALLOW_ECS_API uint64_t tallow_ecs_step_new(ecs_world_t* world, const char* name, int32_t phase, uint64_t tag, tallow_ecs_step_fn fn, void* ctx)
{
	ecs_entity_t phase_id = tallow_ecs_phase(phase);
	if (!phase_id || !fn)
		return 0;
	ecs_entity_desc_t entity = {0};
	entity.name = name;
	entity.sep = ".";
	ecs_entity_t system = ecs_entity_init(world, &entity);
	if (!system)
		return 0;
	ecs_add_pair(world, system, EcsDependsOn, phase_id);
	ecs_add_id(world, system, phase_id);
	ecs_add_id(world, system, tag);
	tallow_ecs_step_t* step = ecs_os_malloc_t(tallow_ecs_step_t);
	step->fn = fn;
	step->ctx = ctx;
	ecs_system_desc_t desc = {0};
	desc.entity = system;
	desc.callback = tallow_ecs_run_step;
	desc.callback_ctx = step;
	desc.callback_ctx_free = ecs_os_api.free_;
	desc.immediate = true;
	return ecs_system_init(world, &desc);
}

TALLOW_ECS_API void tallow_ecs_enable(ecs_world_t* world, uint64_t entity, bool enabled)
{
	ecs_enable(world, entity, enabled);
}

// Lets a component be switched off per entity (ecs_enable_id); queries then skip entities where it is off. Must be
// called before any entity has the component.
TALLOW_ECS_API void tallow_ecs_can_toggle(ecs_world_t* world, uint64_t component)
{
	ecs_add_id(world, component, EcsCanToggle);
}

/* A component's on_remove hook calls fn(context, entity) for each entity losing it (removed, deleted, or the world
 * ending): how a built-in component frees what it keeps outside its data. */
typedef void (*tallow_ecs_remove_fn)(void* context, uint64_t entity);

typedef struct tallow_ecs_remove_hook
{
	tallow_ecs_remove_fn fn;
	void* context;
} tallow_ecs_remove_hook;

static void tallow_ecs_call_remove_hook(ecs_iter_t* it)
{
	const tallow_ecs_remove_hook* hook = it->ctx;
	for (int32_t i = 0; i < it->count; i++)
		hook->fn(hook->context, it->entities[i]);
}

static void tallow_ecs_free_remove_hook(void* hook)
{
	ecs_os_free(hook);
}

TALLOW_ECS_API void tallow_ecs_on_remove(ecs_world_t* world, uint64_t component, tallow_ecs_remove_fn fn, void* context)
{
	tallow_ecs_remove_hook* hook = ecs_os_malloc_t(tallow_ecs_remove_hook);
	hook->fn = fn;
	hook->context = context;
	ecs_type_hooks_t hooks = {0};
	hooks.on_remove = tallow_ecs_call_remove_hook;
	hooks.ctx = hook;
	hooks.ctx_free = tallow_ecs_free_remove_hook;
	ecs_set_hooks_id(world, component, &hooks);
}

TALLOW_ECS_API void tallow_ecs_enable_id(ecs_world_t* world, uint64_t entity, uint64_t id, bool enabled)
{
	ecs_enable_id(world, entity, id, enabled);
}

TALLOW_ECS_API bool tallow_ecs_is_enabled_id(ecs_world_t* world, uint64_t entity, uint64_t id)
{
	return ecs_is_enabled_id(world, entity, id);
}

// ---- Cached component references ----

// A reference to one entity's component that stays valid as the entity's row moves between and within tables.
// Getting through it costs a version compare unless the table changed. Beef keeps it in a buffer of
// tallow_ecs_ref_size() bytes (Ecs/ComponentRef.bf).
TALLOW_ECS_API int32_t tallow_ecs_ref_size(void)
{
	return (int32_t)sizeof(ecs_ref_t);
}

TALLOW_ECS_API void tallow_ecs_ref_init(const ecs_world_t* world, uint64_t entity, uint64_t id, ecs_ref_t* out)
{
	*out = ecs_ref_init_id(world, entity, id);
}

TALLOW_ECS_API void* tallow_ecs_ref_get(const ecs_world_t* world, ecs_ref_t* ref, uint64_t id)
{
	// Beef already checked the 32-bit fast version. Flecs's second check compares a 16-bit table version,
	// which can wrap while a script holds an unused reference (e.g. spawning 100,000 objects). Force the
	// slow path to resolve the entity's current row instead of accepting a stale pointer after 65,536 moves.
	ref->table_id = 0;
	ref->table_version_fast = ~flecs_get_table_version_fast(world, 0);
	return ecs_ref_get_id(world, ref, id);
}

// The world's table version array (ECS_TABLE_VERSION_ARRAY_SIZE entries), which ecs_ref_get_id compares a ref
// against. Beef does the same compare inline and only calls tallow_ecs_ref_get when it fails. Needs the private
// world struct, which is why this file is built inside flecs.c's translation unit (tallow_flecs.c).
TALLOW_ECS_API const uint32_t* tallow_ecs_table_versions(const ecs_world_t* world)
{
	return world->table_version;
}

TALLOW_ECS_API int32_t tallow_ecs_table_version_mask(void)
{
	return ECS_TABLE_VERSION_ARRAY_BITMASK;
}

// Where Beef's mirror of ecs_ref_t (Flecs.RefBuffer) expects each field.
_Static_assert(offsetof(ecs_ref_t, table_id) == 8, "ecs_ref_t.table_id moved");
_Static_assert(offsetof(ecs_ref_t, table_version_fast) == 16, "ecs_ref_t.table_version_fast moved");
_Static_assert(offsetof(ecs_ref_t, ptr) == 24, "ecs_ref_t.ptr moved");
