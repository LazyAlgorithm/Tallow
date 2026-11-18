// C# gameplay is disabled for WebAssembly until a compatible runtime exists.
// Keep the native API linkable without creating a loader for untrusted mods.
#include "tallow_dotnet_host.h"

void* tn_csharp_find_export(const char* name)
{
    (void)name;
    return 0;
}
int32_t tn_csharp_use_dotnet_root(const char* root)
{
    (void)root;
    return 0;
}
int32_t tn_csharp_init_native(const char* library)
{
    (void)library;
    return 0;
}
int32_t tn_csharp_init(const char* runtime_config, const char* managed_assembly)
{
    (void)runtime_config;
    (void)managed_assembly;
    return 0;
}
int32_t tn_csharp_set_callbacks(const tn_csharp_callbacks* callbacks)
{
    (void)callbacks;
    return 0;
}
int32_t tn_csharp_load_game(const char* trusted_game_dll)
{
    (void)trusted_game_dll;
    return -1;
}
int32_t tn_csharp_unload_game(void) { return 0; }
int32_t tn_csharp_attach(const char* managed_type, uint64_t scene, uint64_t entity)
{
    (void)managed_type; (void)scene; (void)entity;
    return -1;
}
int32_t tn_csharp_apply_fields(int32_t script_instance, const char* fields)
{
    (void)script_instance; (void)fields;
    return 0;
}
int32_t tn_csharp_tick(int32_t script_instance, float delta_time)
{
    (void)script_instance; (void)delta_time;
    return 0;
}
int32_t tn_csharp_dispatch(int32_t script_instance, int32_t event_id, float delta_time)
{
    (void)script_instance; (void)event_id; (void)delta_time;
    return 0;
}
int32_t tn_csharp_update_input(int32_t script_instance,
    const tn_csharp_tick_input* input, float delta_time)
{
    (void)script_instance; (void)input; (void)delta_time;
    return 0;
}

int32_t tn_csharp_tick_phase(int32_t script_instance, int32_t phase,
    const tn_csharp_tick_input* input, float delta_time)
{
    (void)script_instance; (void)phase; (void)input; (void)delta_time;
    return 0;
}
int32_t tn_csharp_contact_event(int32_t script_instance, const tn_csharp_contact* contact)
{
    (void)script_instance; (void)contact;
    return 0;
}
int32_t tn_csharp_read_fields(int32_t script_instance, int32_t mode, char* buffer, int32_t capacity)
{
    (void)script_instance; (void)mode; (void)buffer; (void)capacity;
    return -1;
}
int32_t tn_csharp_pump(float delta_time, tn_csharp_gc_stats* stats)
{
    (void)delta_time; (void)stats;
    return 0;
}

int32_t tn_csharp_network_event(int32_t script_instance, const char* name, float value)
{
    (void)script_instance; (void)name; (void)value;
    return 0;
}

int32_t tn_csharp_invoke_rpc(int32_t script_instance, const char* method, const char* arguments, int32_t target, int32_t sender)
{
    (void)script_instance; (void)method; (void)arguments; (void)target; (void)sender;
    return 0;
}
int32_t tn_csharp_detach(int32_t script_instance)
{
    (void)script_instance;
    return 0;
}
void tn_csharp_shutdown(void) { }
const char* tn_csharp_error(void)
{
    return "Managed C# gameplay is unavailable on this target.";
}
int32_t tn_csharp_reload_game(const char* trusted_game_dll)
{
    (void)trusted_game_dll;
    return -1;
}
int32_t tn_csharp_dispatch_batch(const int32_t* instances, int32_t count,
    int32_t event_id, float delta_time)
{
    (void)instances;
    (void)count;
    (void)event_id;
    (void)delta_time;
    return 0;
}
int32_t tn_csharp_dispatch_checked_batch(const int32_t* instances,
    int32_t count, int32_t event_id, float delta_time)
{
    (void)instances;
    (void)count;
    (void)event_id;
    (void)delta_time;
    return 0;
}
int32_t tn_csharp_run_system(int32_t index, uint64_t session, uint64_t entity,
    const tn_csharp_tick_input* input, float delta_time)
{
    (void)index;
    (void)session;
    (void)entity;
    (void)input;
    (void)delta_time;
    return 0;
}
int32_t tn_csharp_update_input_batch(
    const tn_csharp_tick_batch_item* items, int32_t count)
{
    (void)items;
    (void)count;
    return 0;
}
int32_t tn_csharp_ui_invoke(int32_t script_instance, const char* method, const char* element_id)
{
    (void)script_instance;
    (void)method;
    (void)element_id;
    return -1;
}
int32_t tn_csharp_choose_team(int32_t client_id)
{
    (void)client_id;
    return -1;
}
int32_t tn_csharp_behavior_node(int32_t handle, int32_t phase, const char* class_name, uint64_t session, uint64_t entity,
    const char* values, float delta_time)
{
    (void)handle;
    (void)phase;
    (void)class_name;
    (void)session;
    (void)entity;
    (void)values;
    (void)delta_time;
    return 3;
}
int32_t tn_csharp_component_event(int32_t script_instance, int32_t kind, const char* name, float value)
{
    (void)script_instance;
    (void)kind;
    (void)name;
    (void)value;
    return 0;
}
int32_t tn_csharp_terrain_generator(int32_t op, int32_t handle, float x, float y, float z, float step, int32_t samples, const float* points, float* density, uint8_t* paint)
{
    (void)op;
    (void)handle;
    (void)x;
    (void)y;
    (void)z;
    (void)step;
    (void)samples;
    (void)points;
    (void)density;
    (void)paint;
    return -1;
}

int32_t tn_csharp_save_storage(int32_t op, int32_t task, const char* slot, const uint8_t* data, int32_t length)
{
    (void)op;
    (void)task;
    (void)slot;
    (void)data;
    (void)length;
    return -1;
}

int32_t tn_csharp_prediction_state(int32_t script_instance, int32_t mode, float* values)
{
    (void)script_instance;
    (void)mode;
    (void)values;
    return 0;
}

int32_t tn_csharp_editor_configure(const char* editor_assembly, void* host_table, void* managed_table)
{
    (void)editor_assembly;
    (void)host_table;
    (void)managed_table;
    return 0;
}
