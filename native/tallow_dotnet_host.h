#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ABI-stable, trusted engine callbacks. Transform getters/setters validate
// session/entity in the same call and return 1 on success, 0 if stale/invalid.
// Managed code only receives validated
// scene/object IDs, not pointers into Beef's ECS or reference-counted objects.
typedef struct tn_csharp_callbacks {
    void* context;
    int32_t (*is_alive)(void*, uint64_t scene, uint64_t entity);
    int32_t (*get_position)(void*, uint64_t scene, uint64_t entity, float* xyz);
    int32_t (*set_position)(void*, uint64_t scene, uint64_t entity, const float* xyz);
    void (*destroy)(void*, uint64_t scene, uint64_t entity);
    int32_t (*is_mine)(void*, uint64_t scene, uint64_t entity);
    // Extended Transform channels match Tallow.API.TransformChannel.
    // Values are four floats: XYZ for vectors, XYZW for quaternions.
    int32_t (*get_transform)(void*, uint64_t scene, uint64_t entity, int32_t channel, float* xyzw);
    int32_t (*set_transform)(void*, uint64_t scene, uint64_t entity, int32_t channel, const float* xyzw);
    // Resolve an engine-built [CSharpExpose] wrapper once at call-site startup.
    // Only validated, generated C ABI entrypoints are returned.
    void* (*resolve_api)(void*, const char* symbol);
    // Session-checked scene operations. Returned values are object IDs,
    // or zero if no object exists / creation is disallowed.
    uint64_t (*create_scene_object)(void*, uint64_t session, const char* utf8, int32_t byte_length);
    uint64_t (*find_scene_object)(void*, uint64_t session, const char* utf8, int32_t byte_length);
    uint64_t (*instantiate_prefab)(void*, uint64_t session, const char* utf8, int32_t byte_length);
    // Validate immediately before an ordered managed callback. The prior
    // callback may have disabled/destroyed this component or its hierarchy.
    // Includes session + entity to avoid a stale instance ID being reused.
    int32_t (*can_dispatch)(void*, uint64_t session, uint64_t entity,
        int32_t script_instance, int32_t event_id);
} tn_csharp_callbacks;

// ABI mirror of Tallow's current and previous tick controls.
typedef struct tn_csharp_tick_input {
    float move_x;
    float move_z;
    float yaw;
    float pitch;
    uint32_t buttons;
    uint32_t previous_buttons;
} tn_csharp_tick_input;

// Fixed 32-byte C ABI record. Every managed script keeps its own current/
// previous input, replay order and delta time; no ownership pointers cross.
typedef struct tn_csharp_tick_batch_item {
    int32_t instance;
    tn_csharp_tick_input input;
    float delta_time;
} tn_csharp_tick_batch_item;

// Fixed 48-byte C ABI record for a collision or trigger callback.
typedef struct tn_csharp_contact {
    int32_t kind;      // 0 collision enter, 1 collision exit, 2 trigger enter, 3 trigger exit
    int32_t has_other; // 0 when the other object is gone
    uint64_t other;    // the other object's id in the current session
    float point[3];
    float normal[3];   // out of the other object, towards this one
    float relative_speed;
    float reserved;
} tn_csharp_contact;

enum tn_csharp_event_id {
    TN_CSHARP_AWAKE = 0,
    TN_CSHARP_ENABLE = 1,
    TN_CSHARP_START = 2,
    TN_CSHARP_FIXED_UPDATE = 3,
    TN_CSHARP_LOCAL_UPDATE = 4,
    TN_CSHARP_LATE_UPDATE = 5,
    TN_CSHARP_DISABLE = 6,
    TN_CSHARP_GUI = 7
};

// Initialize the .NET runtime within this native process. These paths come
// from the engine, never from third-party mod manifests.
// An exported symbol of the running program (the precompiled player exports its generated C# API entrypoints).
void* tn_csharp_find_export(const char* name);
// Before tn_csharp_init: use only the .NET runtime in this folder (a shipped game's bundled copy).
int32_t tn_csharp_use_dotnet_root(const char* root);
int32_t tn_csharp_init(const char* runtime_config, const char* managed_assembly);
int32_t tn_csharp_set_callbacks(const tn_csharp_callbacks* callbacks);
int32_t tn_csharp_load_game(const char* trusted_game_dll);
int32_t tn_csharp_unload_game(void);
int32_t tn_csharp_attach(const char* managed_type, uint64_t scene, uint64_t entity);
int32_t tn_csharp_apply_fields(int32_t script_instance, const char* fields);
int32_t tn_csharp_tick(int32_t script_instance, float delta_time);
int32_t tn_csharp_dispatch(int32_t script_instance, int32_t event_id, float delta_time);
// Execute an ordered snapshot of managed component lifecycle callbacks in one
// CLR transition. Returns count on success, -1 on failure; pointers not retained.
int32_t tn_csharp_dispatch_batch(const int32_t* instances, int32_t count,
    int32_t event_id, float delta_time);
// Checked variant for native Scene scheduling of FixedUpdate/LateUpdate.
// Each script is checked immediately before invocation, not just at batch
// construction time. It returns accepted snapshot size (skipped entries
// included), or -1 on invalid input/managed failure.
int32_t tn_csharp_dispatch_checked_batch(const int32_t* instances,
    int32_t count, int32_t event_id, float delta_time);
int32_t tn_csharp_update_input(int32_t script_instance,
    const tn_csharp_tick_input* input, float delta_time);
// Call Update(TickInput,float) for up to 4096 ordered native records with a
// single native->CLR transition; -1 on invalid data, count on success.
// Native scheduling/eligibility remains the caller's responsibility.
int32_t tn_csharp_update_input_batch(
    const tn_csharp_tick_batch_item* items, int32_t count);
// Calls OnCollisionEnter/Exit or OnTriggerEnter/Exit; 1 on success.
int32_t tn_csharp_contact_event(int32_t script_instance, const tn_csharp_contact* contact);
// Live field values for the editor (mode 0: Inspector fields, 1: all, read-only). Writes UTF-8 and a NUL when
// it fits; returns the bytes needed without the NUL, or -1 on failure.
int32_t tn_csharp_read_fields(int32_t script_instance, int32_t mode, char* buffer, int32_t capacity);
// Runs an [Rpc] method received from the network (target 0 server, 1 everyone); 1 on success.
int32_t tn_csharp_invoke_rpc(int32_t script_instance, const char* method, const char* arguments, int32_t target, int32_t sender);
// Calls OnNetworkEvent(name, value) (Component.SendNetworkEvent arriving on this machine); 1 on success.
int32_t tn_csharp_network_event(int32_t script_instance, const char* name, float value);
// Calls a UI document handler (onclick="Method") on the script, with the element's id; 1 called, 0 no such
// method, -1 it threw.
int32_t tn_csharp_ui_invoke(int32_t script_instance, const char* method, const char* element_id);
// The managed heap after a pump, for the Profiler (40 bytes).
typedef struct tn_csharp_gc_stats
{
    int64_t allocated_bytes; // Allocated since the runtime started (all threads).
    int64_t heap_bytes;      // In use now.
    int32_t gen0, gen1, gen2; // Collections since the runtime started.
    int32_t reserved;
    int64_t pause_ns;        // Total time paused for collections.
} tn_csharp_gc_stats;

// Once a frame after LateUpdate: finishes due game-time waits and runs await continuations, then fills stats
// (optional); 1 on success.
int32_t tn_csharp_pump(float delta_time, tn_csharp_gc_stats* stats);
int32_t tn_csharp_detach(int32_t script_instance);
void tn_csharp_shutdown(void);
const char* tn_csharp_error(void);

#ifdef __cplusplus
}
#endif
