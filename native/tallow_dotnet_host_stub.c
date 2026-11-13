// C# gameplay is disabled for WebAssembly until a compatible runtime exists.
// Keep the native API linkable without creating a loader for untrusted mods.
#include "tallow_dotnet_host.h"

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
