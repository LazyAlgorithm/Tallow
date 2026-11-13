#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ABI-stable, trusted engine callbacks. Managed code only receives validated
// scene/object IDs, not pointers into Beef's ECS or reference-counted objects.
typedef struct tn_csharp_callbacks {
    void* context;
    int32_t (*is_alive)(void*, uint64_t scene, uint64_t entity);
    void (*get_position)(void*, uint64_t scene, uint64_t entity, float* xyz);
    void (*set_position)(void*, uint64_t scene, uint64_t entity, const float* xyz);
    void (*destroy)(void*, uint64_t scene, uint64_t entity);
    int32_t (*is_mine)(void*, uint64_t scene, uint64_t entity);
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
int32_t tn_csharp_update_input(int32_t script_instance,
    const tn_csharp_tick_input* input, float delta_time);
int32_t tn_csharp_detach(int32_t script_instance);
void tn_csharp_shutdown(void);
const char* tn_csharp_error(void);

#ifdef __cplusplus
}
#endif
