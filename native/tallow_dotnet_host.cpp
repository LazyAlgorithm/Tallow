// .NET 11 hostfxr bootstrap for trusted C# gameplay.
// The hostfxr symbols are resolved dynamically: the native engine never links
// against a particular .NET SDK or a NuGet package.
#include "tallow_dotnet_host.h"

#include <algorithm>
#include <cstddef>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <string>
#include <vector>

#if defined(__EMSCRIPTEN__)
// In a browser .NET is not loaded by the engine: the page starts it, and its Main (Tallow.ManagedRuntime's
// WebBoot) registers NativeEntrypoints' functions here (tn_csharp_web_register) before it starts the engine.
using host_char = char;
using library_handle = void*;
static library_handle load_library(const std::filesystem::path&) { return nullptr; }
static void* get_symbol(library_handle, const char*) { return nullptr; }
#elif defined(_WIN32)
#include <windows.h>
using host_char = wchar_t;
using library_handle = HMODULE;
static library_handle load_library(const std::filesystem::path& path) { return LoadLibraryW(path.c_str()); }
static void* get_symbol(library_handle lib, const char* name) { return reinterpret_cast<void*>(GetProcAddress(lib, name)); }
#else
#include <dlfcn.h>
using host_char = char;
using library_handle = void*;
static library_handle load_library(const std::filesystem::path& path) { return dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL); }
static void* get_symbol(library_handle lib, const char* name) { return dlsym(lib, name); }
#endif

// All three runtimes (Beef, C++ and C#) must agree on this ABI.
static_assert(sizeof(tn_csharp_tick_input) == 24,
    "Native TickInput must remain six 32-bit values");
static_assert(sizeof(tn_csharp_tick_batch_item) == 32,
    "Native input batch entry must remain 32 bytes");
static_assert(offsetof(tn_csharp_tick_batch_item, input) == 4 &&
              offsetof(tn_csharp_tick_batch_item, delta_time) == 28,
    "Native batch field offsets changed");

namespace {
using hostfxr_handle = void*;
using host_initialize = int32_t (*)(const host_char*, const void*, hostfxr_handle*);
using host_get_delegate = int32_t (*)(hostfxr_handle, int32_t, void**);
using host_close = int32_t (*)(hostfxr_handle);
using get_managed_function = int32_t (*)(
    const host_char*, const host_char*, const host_char*, const host_char*, void*, void**);

using configure_fn = int32_t (*)(void*);
using load_game_fn = int32_t (*)(const char*);
using unload_game_fn = int32_t (*)();
using reload_game_fn = int32_t (*)(const char*);
using attach_fn = int32_t (*)(const char*, uint64_t, uint64_t);
using apply_fields_fn = int32_t (*)(int32_t, const char*);
using tick_fn = int32_t (*)(int32_t, float);
using dispatch_fn = int32_t (*)(int32_t, int32_t, float);
using dispatch_batch_fn = int32_t (*)(const int32_t*, int32_t, int32_t, float);
using update_input_fn = int32_t (*)(int32_t, const tn_csharp_tick_input*, float);
using tick_phase_fn = int32_t (*)(int32_t, int32_t, const tn_csharp_tick_input*, float);
using run_system_fn = int32_t (*)(int32_t, uint64_t, uint64_t, const tn_csharp_tick_input*, float);
using update_input_batch_fn = int32_t (*)(const tn_csharp_tick_batch_item*, int32_t);
using contact_fn = int32_t (*)(int32_t, const tn_csharp_contact*);
using read_fields_fn = int32_t (*)(int32_t, int32_t, char*, int32_t);
using invoke_rpc_fn = int32_t (*)(int32_t, const char*, const char*, int32_t, int32_t);
using network_event_fn = int32_t (*)(int32_t, const char*, float);
using ui_invoke_fn = int32_t (*)(int32_t, const char*, const char*);
using choose_team_fn = int32_t (*)(int32_t);
using component_event_fn = int32_t (*)(int32_t, int32_t, const char*, float);
using behavior_node_fn = int32_t (*)(int32_t, int32_t, const char*, uint64_t, uint64_t, const char*, float);
using prediction_state_fn = int32_t (*)(int32_t, int32_t, float*);
using pump_fn = int32_t (*)(float, tn_csharp_gc_stats*);
using detach_fn = int32_t (*)(int32_t);
using last_error_fn = int32_t (*)(char*, int32_t);
using editor_configure_fn = int32_t (*)(const char*, void*, void*);
using shutdown_fn = int32_t (*)();

std::string error;
library_handle runtime_library = nullptr;
get_managed_function load_function = nullptr;
configure_fn configure = nullptr;
load_game_fn load_game = nullptr;
unload_game_fn unload_game = nullptr;
reload_game_fn reload_game = nullptr;
attach_fn attach = nullptr;
apply_fields_fn apply_fields = nullptr;
tick_fn tick = nullptr;
dispatch_fn dispatch = nullptr;
dispatch_batch_fn dispatch_batch = nullptr;
dispatch_batch_fn dispatch_checked_batch = nullptr;
update_input_fn update_input = nullptr;
tick_phase_fn tick_phase = nullptr;
run_system_fn run_system = nullptr;
update_input_batch_fn update_input_batch = nullptr;
contact_fn contact_event = nullptr;
read_fields_fn read_fields = nullptr;
invoke_rpc_fn invoke_rpc = nullptr;
network_event_fn network_event = nullptr;
ui_invoke_fn ui_invoke = nullptr;
choose_team_fn choose_team = nullptr;
component_event_fn component_event = nullptr;
behavior_node_fn behavior_node = nullptr;
prediction_state_fn prediction_state = nullptr;
pump_fn pump = nullptr;
detach_fn detach = nullptr;
last_error_fn last_error = nullptr;
editor_configure_fn editor_configure = nullptr;
// Tallow.ManagedRuntime's path, for the entry points bound later (the editor's).
std::string runtime_assembly;
shutdown_fn shutdown_runtime = nullptr;
tn_csharp_callbacks engine_callbacks = {};
bool started = false;

std::basic_string<host_char> platform_string(const char* utf8)
{
#ifdef _WIN32
    if (!utf8) return {};
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, nullptr, 0);
    if (count <= 0) return {};
    std::wstring wide(static_cast<size_t>(count), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide.data(), count);
    wide.pop_back();
    return wide;
#else
    return utf8 ? std::string(utf8) : std::string();
#endif
}

// Find the SDK/runtime's actual installation, not one assumed distro path.
// Fedora/Nobara generally use /usr/lib64/dotnet, while Microsoft packages use
// /usr/share/dotnet and per-user dotnet-install.sh uses ~/.dotnet.
// The highest installed hostfxr version is used to initialize the requested
// framework from the supplied runtimeconfig.json.
void add_root(std::vector<std::filesystem::path>& roots, const std::filesystem::path& root)
{
    if (root.empty())
        return;
    if (std::find(roots.begin(), roots.end(), root) == roots.end())
        roots.push_back(root);
}

// Environment text as UTF-8. On Windows getenv returns the ANSI code page,
// which mangles a .NET install or PATH entry under a non-ASCII user folder.
std::string environment_utf8(const char* name)
{
#ifdef _WIN32
    const std::wstring wide_name = platform_string(name);
    const DWORD size = GetEnvironmentVariableW(wide_name.c_str(), nullptr, 0);
    if (size == 0)
        return {};
    std::wstring wide(size, L'\0');
    const DWORD written = GetEnvironmentVariableW(wide_name.c_str(), wide.data(), size);
    if (written == 0 || written >= size)
        return {};
    wide.resize(written);
    const int count = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
        static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (count <= 0)
        return {};
    std::string utf8(static_cast<size_t>(count), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
        utf8.data(), count, nullptr, nullptr);
    return utf8;
#else
    const char* value = std::getenv(name);
    return value ? std::string(value) : std::string();
#endif
}

void add_root_from_env(std::vector<std::filesystem::path>& roots, const char* name)
{
    if (const std::string value = environment_utf8(name); !value.empty())
        add_root(roots, std::filesystem::path(platform_string(value.c_str())));
}

void add_root_from_executable(std::vector<std::filesystem::path>& roots,
    const std::filesystem::path& executable)
{
    std::error_code error;
    if (!std::filesystem::exists(executable, error))
        return;
    const auto resolved = std::filesystem::canonical(executable, error);
    if (!error && (resolved.filename() == "dotnet" || resolved.filename() == "dotnet.exe"))
        add_root(roots, resolved.parent_path());
}

// A shipped game's own copy of the runtime (tn_csharp_use_dotnet_root): then nothing installed is used.
std::filesystem::path bundled_root;

std::vector<std::filesystem::path> dotnet_roots()
{
    std::vector<std::filesystem::path> roots;
    if (!bundled_root.empty())
    {
        roots.push_back(bundled_root);
        return roots;
    }
    add_root_from_env(roots, "DOTNET_ROOT");
#if defined(_WIN64) || defined(__x86_64__)
    add_root_from_env(roots, "DOTNET_ROOT_X64");
#elif defined(__aarch64__)
    add_root_from_env(roots, "DOTNET_ROOT_ARM64");
#endif
    // Find the dotnet CLI that the user actually runs, following symlinks.
    if (const std::string value = environment_utf8("PATH"); !value.empty())
    {
#ifdef _WIN32
        constexpr char separator = ';';
        constexpr const char* executable = "dotnet.exe";
#else
        constexpr char separator = ':';
        constexpr const char* executable = "dotnet";
#endif
        size_t first = 0;
        while (first <= value.size())
        {
            size_t last = value.find(separator, first);
            if (last == std::string::npos)
                last = value.size();
            if (last > first)
                add_root_from_executable(roots,
                    std::filesystem::path(platform_string(
                        value.substr(first, last - first).c_str())) / executable);
            first = last + 1;
        }
    }
#ifdef _WIN32
    if (const std::string files = environment_utf8("ProgramFiles"); !files.empty())
        add_root(roots, std::filesystem::path(platform_string(files.c_str())) / L"dotnet");
    add_root(roots, L"C:\\Program Files\\dotnet");
#else
    add_root_from_executable(roots, "/usr/bin/dotnet");
    add_root(roots, "/usr/lib64/dotnet");
    add_root(roots, "/usr/lib/dotnet");
    add_root(roots, "/usr/share/dotnet");
    add_root(roots, "/usr/local/share/dotnet");
    if (const char* home = std::getenv("HOME"); home && *home)
        add_root(roots, std::filesystem::path(platform_string(home)) / ".dotnet");
#endif
    return roots;
}

std::vector<int> version_parts(const std::filesystem::path& version)
{
    std::vector<int> result;
    // A pre-release ("11.0.0-rc.1.26425.128") counts by its numbers before the dash.
    auto name = version.filename().string();
    if (const size_t dash = name.find('-'); dash != std::string::npos)
        name.resize(dash);
    size_t start = 0;
    while (start < name.size() && result.size() < 3)
    {
        size_t end = name.find('.', start);
        if (end == std::string::npos)
            end = name.size();
        try {
            size_t consumed = 0;
            int number = std::stoi(name.substr(start, end - start), &consumed);
            if (consumed != end - start)
                return {};
            result.push_back(number);
        } catch (...) {
            return {};
        }
        start = end + 1;
    }
    return result;
}

std::filesystem::path hostfxr_path()
{
#ifdef _WIN32
    constexpr const char* library = "hostfxr.dll";
#elif __APPLE__
    constexpr const char* library = "libhostfxr.dylib";
#else
    constexpr const char* library = "libhostfxr.so";
#endif
    std::filesystem::path chosen;
    std::vector<int> highest;
    // Check all candidate installations, including other roots if an
    // environment variable points to an incomplete or stale installation.
    for (const auto& root : dotnet_roots())
    {
        const auto folder = root / "host" / "fxr";
        std::error_code error;
        if (!std::filesystem::is_directory(folder, error))
            continue;
        for (std::filesystem::directory_iterator it(folder, error), end;
             !error && it != end; it.increment(error))
        {
            if (!it->is_directory(error))
                continue;
            const auto candidate = it->path() / library;
            if (!std::filesystem::is_regular_file(candidate, error))
                continue;
            const auto version = version_parts(it->path());
            if (version.empty())
                continue;
            if (chosen.empty() || std::lexicographical_compare(
                    highest.begin(), highest.end(), version.begin(), version.end()))
            {
                highest = version;
                chosen = candidate;
            }
        }
    }
    return chosen;
}

void managed_error(const char* action)
{
    char buffer[2048] = {};
    if (last_error)
        last_error(buffer, static_cast<int32_t>(sizeof(buffer)));
    error = std::string(action) + ": " + (buffer[0] ? buffer : "managed call failed");
}

#if defined(__EMSCRIPTEN__)
std::vector<std::pair<std::string, void*>> web_entries;

template <typename T>
bool find_entry(const host_char*, const char* method, T& result)
{
    for (const auto& entry : web_entries)
    {
        if (entry.first == method && entry.second)
        {
            result = reinterpret_cast<T>(entry.second);
            return true;
        }
    }
    error = std::string("The C# runtime did not register its entrypoint: ") + method;
    return false;
}
#else
template <typename T>
bool find_entry(const host_char* managed_assembly, const char* method, T& result)
{
    const auto unmanaged = reinterpret_cast<const host_char*>(static_cast<intptr_t>(-1));
    const auto type = platform_string("Tallow.ManagedRuntime.NativeEntrypoints, Tallow.ManagedRuntime");
    const auto method_name = platform_string(method);
    void* pointer = nullptr;
    if (!load_function || load_function(managed_assembly, type.c_str(), method_name.c_str(),
            unmanaged, nullptr, &pointer) != 0 || !pointer)
    {
        error = std::string("Could not bind managed entrypoint: ") + method;
        return false;
    }
    result = reinterpret_cast<T>(pointer);
    return true;
}
#endif
} // namespace

extern "C" {

const char* tn_csharp_error(void) { return error.c_str(); }

#if defined(__EMSCRIPTEN__)
/* Called by the managed runtime's web start-up, once per NativeEntrypoints function, before the engine starts. */
int32_t tn_csharp_web_register(const char* name, void* pointer)
{
    if (!name || !pointer)
        return 0;
    for (auto& entry : web_entries)
    {
        if (entry.first == name)
        {
            entry.second = pointer;
            return 1;
        }
    }
    web_entries.emplace_back(name, pointer);
    return 1;
}

/* Whether the page's .NET registered the managed runtime (a C# game) or not (a Beef game). */
int32_t tn_csharp_web_hosted(void) { return web_entries.empty() ? 0 : 1; }
#endif

void* tn_csharp_find_export(const char* name)
{
    if (!name)
        return nullptr;
#if defined(__EMSCRIPTEN__)
    // No dynamic symbol table in a browser: the engine finds its C# API functions by reflection instead.
    return nullptr;
#elif defined(_WIN32)
    return reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(nullptr), name));
#else
    return dlsym(RTLD_DEFAULT, name);
#endif
}

int32_t tn_csharp_use_dotnet_root(const char* root)
{
    if (started || !root)
        return 0;
    bundled_root = std::filesystem::path(platform_string(root));
    return 1;
}

int32_t tn_csharp_init(const char* runtime_config, const char* managed_assembly)
{
    if (started) return 1;
    if (!runtime_config || !managed_assembly)
    {
        error = "Missing C# runtime configuration or managed assembly.";
        return 0;
    }
    try
    {
#if !defined(__EMSCRIPTEN__)
        const auto hostfxr = hostfxr_path();
        if (hostfxr.empty() || !std::filesystem::exists(hostfxr))
        {
            error = "Cannot locate .NET hostfxr. Checked DOTNET_ROOT, the dotnet executable, Fedora /usr/lib64/dotnet, system directories and ~/.dotnet.";
            return 0;
        }
        runtime_library = load_library(hostfxr);
        if (!runtime_library)
        {
            error = "Could not load .NET hostfxr at " + hostfxr.string();
#ifndef _WIN32
            if (const char* detail = dlerror(); detail && *detail)
                error += std::string(": ") + detail;
#endif
            return 0;
        }

        auto initialize = reinterpret_cast<host_initialize>(get_symbol(runtime_library,
            "hostfxr_initialize_for_runtime_config"));
        auto get_delegate = reinterpret_cast<host_get_delegate>(get_symbol(runtime_library,
            "hostfxr_get_runtime_delegate"));
        auto close = reinterpret_cast<host_close>(get_symbol(runtime_library, "hostfxr_close"));
        if (!initialize || !get_delegate || !close)
        {
            error = "hostfxr is missing the required .NET hosting entrypoints.";
            return 0;
        }

        const auto config = platform_string(runtime_config);
        hostfxr_handle handle = nullptr;
        // With a bundled runtime, frameworks are resolved from it as well, not from an installed .NET.
        struct
        {
            size_t size;
            const host_char* host_path;
            const host_char* dotnet_root;
        } parameters{sizeof(parameters), nullptr, nullptr};
        const auto root_text = bundled_root.native();
        if (!bundled_root.empty())
            parameters.dotnet_root = root_text.c_str();
        int32_t result = initialize(config.c_str(), bundled_root.empty() ? nullptr : &parameters, &handle);
        if (result < 0 || !handle)
        {
            error = "hostfxr could not initialize the .NET runtime configuration.";
            return 0;
        }

        // hdt_load_assembly_and_get_function_pointer is the stable hostfxr
        // delegate type for loading an assembly method from native code.
        result = get_delegate(handle, 5, reinterpret_cast<void**>(&load_function));
        close(handle);
        if (result < 0 || !load_function)
        {
            error = "Could not obtain the .NET assembly loader delegate.";
            return 0;
        }
#endif
        runtime_assembly = managed_assembly;
        const auto assembly = platform_string(managed_assembly);
        if (!find_entry(assembly.c_str(), "Configure", configure) ||
            !find_entry(assembly.c_str(), "LoadGame", load_game) ||
            !find_entry(assembly.c_str(), "UnloadGame", unload_game) ||
            !find_entry(assembly.c_str(), "ReloadGame", reload_game) ||
            !find_entry(assembly.c_str(), "Attach", attach) ||
            !find_entry(assembly.c_str(), "ApplyFields", apply_fields) ||
            !find_entry(assembly.c_str(), "Tick", tick) ||
            !find_entry(assembly.c_str(), "Dispatch", dispatch) ||
            !find_entry(assembly.c_str(), "DispatchBatch", dispatch_batch) ||
            !find_entry(assembly.c_str(), "DispatchCheckedBatch", dispatch_checked_batch) ||
            !find_entry(assembly.c_str(), "UpdateInput", update_input) ||
            !find_entry(assembly.c_str(), "TickPhase", tick_phase) ||
            !find_entry(assembly.c_str(), "RunSystem", run_system) ||
            !find_entry(assembly.c_str(), "UpdateInputBatch", update_input_batch) ||
            !find_entry(assembly.c_str(), "Contact", contact_event) ||
            !find_entry(assembly.c_str(), "ReadFields", read_fields) ||
            !find_entry(assembly.c_str(), "InvokeRpc", invoke_rpc) ||
            !find_entry(assembly.c_str(), "NetworkEvent", network_event) ||
            !find_entry(assembly.c_str(), "UiInvoke", ui_invoke) ||
            !find_entry(assembly.c_str(), "ChooseTeam", choose_team) ||
            !find_entry(assembly.c_str(), "ComponentEvent", component_event) ||
            !find_entry(assembly.c_str(), "BehaviorNode", behavior_node) ||
            !find_entry(assembly.c_str(), "PredictionState", prediction_state) ||
            !find_entry(assembly.c_str(), "Pump", pump) ||
            !find_entry(assembly.c_str(), "Detach", detach) ||
            !find_entry(assembly.c_str(), "GetLastError", last_error) ||
            !find_entry(assembly.c_str(), "Shutdown", shutdown_runtime))
            return 0;

        started = true;
        error.clear();
        return 1;
    }
    catch (const std::exception& exception)
    {
        error = exception.what();
        return 0;
    }
}

int32_t tn_csharp_set_callbacks(const tn_csharp_callbacks* callbacks)
{
    if (!started || !callbacks || !callbacks->is_alive || !callbacks->get_position ||
        !callbacks->set_position || !callbacks->destroy || !callbacks->is_mine ||
        !callbacks->get_transform || !callbacks->set_transform ||
        !callbacks->can_dispatch)
    {
        error = "Missing native C# gameplay callbacks.";
        return 0;
    }
    engine_callbacks = *callbacks;
    const int32_t result = configure(&engine_callbacks);
    if (result <= 0)
        managed_error("Configuring C# gameplay callbacks");
    return result > 0;
}

int32_t tn_csharp_load_game(const char* trusted_game_dll)
{
    if (!started || !load_game || !trusted_game_dll)
        return 0;
    const int32_t result = load_game(trusted_game_dll);
    if (result < 0)
        managed_error("Loading trusted C# game assembly");
    return result;
}

int32_t tn_csharp_unload_game(void)
{
    if (!started || !unload_game)
        return 0;
    const int32_t result = unload_game();
    if (result < 0)
        managed_error("Unloading trusted C# game assembly");
    return result > 0;
}

int32_t tn_csharp_reload_game(const char* trusted_game_dll)
{
    if (!started || !reload_game || !trusted_game_dll)
        return -1;
    const int32_t result = reload_game(trusted_game_dll);
    if (result < 0)
        managed_error("Hot reloading the C# game");
    return result;
}

int32_t tn_csharp_attach(const char* managed_type, uint64_t scene, uint64_t entity)
{
    if (!started || !attach || !managed_type)
        return -1;
    const int32_t result = attach(managed_type, scene, entity);
    if (result < 0)
        managed_error("Attaching C# component");
    return result;
}

int32_t tn_csharp_apply_fields(int32_t script_instance, const char* fields)
{
    if (!started || !apply_fields || !fields)
        return 0;
    const int32_t result = apply_fields(script_instance, fields);
    if (result < 0)
        managed_error("Applying managed gameplay Inspector fields");
    return result > 0;
}

int32_t tn_csharp_tick(int32_t script_instance, float delta_time)
{
    if (!started || !tick)
        return 0;
    const int32_t result = tick(script_instance, delta_time);
    if (result < 0)
        managed_error("Updating C# component");
    return result > 0;
}

int32_t tn_csharp_dispatch(int32_t script_instance, int32_t event_id, float delta_time)
{
    if (!started || !dispatch)
        return 0;
    const int32_t result = dispatch(script_instance, event_id, delta_time);
    if (result < 0)
        managed_error("Dispatching C# component event");
    // Positive results pass through: the callback-mask query (event 100) answers 2 + mask.
    return result > 0 ? result : 0;
}

int32_t tn_csharp_dispatch_batch(const int32_t* instances, int32_t count,
    int32_t event_id, float delta_time)
{
    if (!started || !dispatch_batch || count < 0 || count > 4096 ||
        (count > 0 && !instances))
        return -1;
    const int32_t result = dispatch_batch(instances, count, event_id, delta_time);
    if (result < 0)
        managed_error("Dispatching a C# component batch");
    return result;
}

int32_t tn_csharp_dispatch_checked_batch(const int32_t* instances, int32_t count,
    int32_t event_id, float delta_time)
{
    if (!started || !dispatch_checked_batch || count < 0 || count > 4096 ||
        (count > 0 && !instances))
        return -1;
    const int32_t result = dispatch_checked_batch(instances, count, event_id, delta_time);
    if (result < 0)
        managed_error("Dispatching a checked C# scene callback batch");
    return result;
}

int32_t tn_csharp_update_input(int32_t script_instance,
    const tn_csharp_tick_input* input, float delta_time)
{
    if (!started || !update_input || !input)
        return 0;
    const int32_t result = update_input(script_instance, input, delta_time);
    if (result < 0)
        managed_error("Updating C# component with network input");
    return result > 0;
}

int32_t tn_csharp_tick_phase(int32_t script_instance, int32_t phase,
    const tn_csharp_tick_input* input, float delta_time)
{
    if (!started || !tick_phase || !input)
        return 0;
    const int32_t result = tick_phase(script_instance, phase, input, delta_time);
    if (result < 0)
        managed_error("Updating C# component with network input");
    return result > 0;
}

int32_t tn_csharp_run_system(int32_t index, uint64_t session, uint64_t entity,
    const tn_csharp_tick_input* input, float delta_time)
{
    if (!started || !run_system || !input)
        return 0;
    const int32_t result = run_system(index, session, entity, input, delta_time);
    if (result < 0)
        managed_error("Running a C# ECS system");
    return result > 0;
}

int32_t tn_csharp_contact_event(int32_t script_instance, const tn_csharp_contact* contact)
{
    if (!started || !contact_event || !contact)
        return 0;
    const int32_t result = contact_event(script_instance, contact);
    if (result < 0)
        managed_error("Calling a C# collision or trigger callback");
    return result > 0;
}

int32_t tn_csharp_read_fields(int32_t script_instance, int32_t mode, char* buffer, int32_t capacity)
{
    if (!started || !read_fields || capacity < 0)
        return -1;
    const int32_t result = read_fields(script_instance, mode, buffer, capacity);
    if (result < 0)
        managed_error("Reading C# field values");
    return result;
}

int32_t tn_csharp_invoke_rpc(int32_t script_instance, const char* method, const char* arguments, int32_t target, int32_t sender)
{
    if (!started || !invoke_rpc || !method || !arguments)
        return 0;
    const int32_t result = invoke_rpc(script_instance, method, arguments, target, sender);
    if (result < 0)
        managed_error("Running a C# RPC");
    return result > 0;
}

int32_t tn_csharp_network_event(int32_t script_instance, const char* name, float value)
{
    if (!started || !network_event || !name)
        return 0;
    const int32_t result = network_event(script_instance, name, value);
    if (result < 0)
        managed_error("Running a C# network event");
    return result > 0;
}

int32_t tn_csharp_editor_configure(const char* editor_assembly, void* host_table, void* managed_table)
{
    if (!started || !editor_assembly || !host_table || !managed_table)
        return 0;
#if defined(__EMSCRIPTEN__)
    error = "The editor does not run in a browser.";
    return 0;
#else
    if (!editor_configure)
    {
        const auto assembly = platform_string(runtime_assembly.c_str());
        if (!find_entry(assembly.c_str(), "EditorConfigure", editor_configure))
            return 0;
    }
    const int32_t result = editor_configure(editor_assembly, host_table, managed_table);
    if (result < 0)
        managed_error("Loading the C# editor extensions");
    return result > 0;
#endif
}

int32_t tn_csharp_ui_invoke(int32_t script_instance, const char* method, const char* element_id)
{
    if (!started || !ui_invoke || !method)
        return 0;
    const int32_t result = ui_invoke(script_instance, method, element_id ? element_id : "");
    if (result < 0)
        managed_error("Running a C# UI handler");
    return result;
}

int32_t tn_csharp_component_event(int32_t script_instance, int32_t kind, const char* name, float value)
{
    if (!started || !component_event || !name)
        return 0;
    const int32_t result = component_event(script_instance, kind, name, value);
    if (result < 0)
        managed_error("Running a C# sequence, dialogue or tree event");
    return result > 0;
}

int32_t tn_csharp_behavior_node(int32_t handle, int32_t phase, const char* class_name, uint64_t session, uint64_t entity,
    const char* values, float delta_time)
{
    if (!started || !behavior_node || !class_name)
        return 3;
    const int32_t result = behavior_node(handle, phase, class_name, session, entity, values ? values : "", delta_time);
    if (result < 0)
        managed_error("Running a C# behaviour tree node");
    return result;
}

int32_t tn_csharp_prediction_state(int32_t script_instance, int32_t mode, float* values)
{
    if (!started || !prediction_state || !values)
        return 0;
    const int32_t result = prediction_state(script_instance, mode, values);
    if (result < 0)
        managed_error("Running a C# prediction state hook");
    return result > 0;
}

int32_t tn_csharp_choose_team(int32_t client_id)
{
    if (!started || !choose_team)
        return -1;
    const int32_t team = choose_team(client_id);
    if (team < 0)
        managed_error("Running Network.ChooseTeam");
    return team;
}

int32_t tn_csharp_pump(float delta_time, tn_csharp_gc_stats* stats)
{
    if (!started || !pump)
        return 0;
    const int32_t result = pump(delta_time, stats);
    if (result < 0)
        managed_error("Running C# async code");
    return result > 0;
}

int32_t tn_csharp_update_input_batch(
    const tn_csharp_tick_batch_item* items, int32_t count)
{
    if (!started || !update_input_batch || count < 0 || count > 4096 ||
        (count > 0 && !items))
        return -1;
    const int32_t result = update_input_batch(items, count);
    if (result < 0)
        managed_error("Updating a C# gameplay input batch");
    return result;
}

int32_t tn_csharp_detach(int32_t script_instance)
{
    if (!started || !detach)
        return 0;
    const int32_t result = detach(script_instance);
    if (result < 0)
        managed_error("Destroying C# component");
    return result > 0;
}

void tn_csharp_shutdown(void)
{
    if (started && shutdown_runtime)
        shutdown_runtime();
    started = false;
    configure = nullptr;
    load_game = nullptr;
    unload_game = nullptr;
    reload_game = nullptr;
    attach = nullptr;
    apply_fields = nullptr;
    tick = nullptr;
    dispatch = nullptr;
    dispatch_batch = nullptr;
    dispatch_checked_batch = nullptr;
    update_input = nullptr;
    tick_phase = nullptr;
    run_system = nullptr;
    update_input_batch = nullptr;
    contact_event = nullptr;
    read_fields = nullptr;
    invoke_rpc = nullptr;
    network_event = nullptr;
    ui_invoke = nullptr;
    editor_configure = nullptr;
    choose_team = nullptr;
    component_event = nullptr;
    behavior_node = nullptr;
    prediction_state = nullptr;
    pump = nullptr;
    detach = nullptr;
    last_error = nullptr;
    shutdown_runtime = nullptr;
    // The CLR itself remains loaded for this native process's lifetime.
}
} // extern "C"
