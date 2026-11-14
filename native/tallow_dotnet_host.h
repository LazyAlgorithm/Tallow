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
int32_t tn_csharp_update_input(int32_t script_instance,
    const tn_csharp_tick_input* input, float delta_time);
int32_t tn_csharp_detach(int32_t script_instance);
void tn_csharp_shutdown(void);
const char* tn_csharp_error(void);

#ifdef __cplusplus
}
#endif
