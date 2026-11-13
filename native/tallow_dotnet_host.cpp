// .NET 11 hostfxr bootstrap for trusted C# gameplay.
// The hostfxr symbols are resolved dynamically: the native engine never links
// against a particular .NET SDK or a NuGet package.
#include "tallow_dotnet_host.h"

#include <algorithm>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <string>
#include <vector>

#ifdef _WIN32
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

namespace {
using hostfxr_handle = void*;
using host_initialize = int32_t (*)(const host_char*, const void*, hostfxr_handle*);
using host_get_delegate = int32_t (*)(hostfxr_handle, int32_t, void**);
using host_close = int32_t (*)(hostfxr_handle);
using get_managed_function = int32_t (*)(
    const host_char*, const host_char*, const host_char*, const host_char*, void*, void**);

using configure_fn = int32_t (*)(void*);
using load_game_fn = int32_t (*)(const char*);
using attach_fn = int32_t (*)(const char*, uint64_t, uint64_t);
using tick_fn = int32_t (*)(int32_t, float);
using detach_fn = int32_t (*)(int32_t);
using last_error_fn = int32_t (*)(char*, int32_t);
using shutdown_fn = int32_t (*)();

std::string error;
library_handle runtime_library = nullptr;
get_managed_function load_function = nullptr;
configure_fn configure = nullptr;
load_game_fn load_game = nullptr;
attach_fn attach = nullptr;
tick_fn tick = nullptr;
detach_fn detach = nullptr;
last_error_fn last_error = nullptr;
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

std::filesystem::path dotnet_root()
{
    if (const char* root = std::getenv("DOTNET_ROOT"); root && *root)
        return std::filesystem::path(platform_string(root));
#ifdef _WIN32
    if (const char* files = std::getenv("ProgramFiles"); files && *files)
        return std::filesystem::path(platform_string(files)) / L"dotnet";
    return L"C:\\Program Files\\dotnet";
#else
    return "/usr/share/dotnet";
#endif
}

std::filesystem::path hostfxr_path()
{
    std::filesystem::path folder = dotnet_root() / "host" / "fxr";
    if (!std::filesystem::is_directory(folder))
        return {};
    std::vector<std::filesystem::path> versions;
    for (const auto& entry : std::filesystem::directory_iterator(folder))
        if (entry.is_directory())
            versions.push_back(entry.path());
    if (versions.empty())
        return {};
    std::sort(versions.begin(), versions.end());
#ifdef _WIN32
    return versions.back() / "hostfxr.dll";
#elif __APPLE__
    return versions.back() / "libhostfxr.dylib";
#else
    return versions.back() / "libhostfxr.so";
#endif
}

void managed_error(const char* action)
{
    char buffer[2048] = {};
    if (last_error)
        last_error(buffer, static_cast<int32_t>(sizeof(buffer)));
    error = std::string(action) + ": " + (buffer[0] ? buffer : "managed call failed");
}

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
} // namespace

extern "C" {

const char* tn_csharp_error(void) { return error.c_str(); }

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
        const auto hostfxr = hostfxr_path();
        if (hostfxr.empty() || !std::filesystem::exists(hostfxr))
        {
            error = "The .NET 11 runtime hostfxr could not be located.";
            return 0;
        }
        runtime_library = load_library(hostfxr);
        if (!runtime_library)
        {
            error = "The .NET 11 hostfxr library could not be loaded.";
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
        int32_t result = initialize(config.c_str(), nullptr, &handle);
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
        const auto assembly = platform_string(managed_assembly);
        if (!find_entry(assembly.c_str(), "Configure", configure) ||
            !find_entry(assembly.c_str(), "LoadGame", load_game) ||
            !find_entry(assembly.c_str(), "Attach", attach) ||
            !find_entry(assembly.c_str(), "Tick", tick) ||
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
        !callbacks->set_position || !callbacks->destroy || !callbacks->is_mine)
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

int32_t tn_csharp_attach(const char* managed_type, uint64_t scene, uint64_t entity)
{
    if (!started || !attach || !managed_type)
        return -1;
    const int32_t result = attach(managed_type, scene, entity);
    if (result < 0)
        managed_error("Attaching C# component");
    return result;
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
    attach = nullptr;
    tick = nullptr;
    detach = nullptr;
    last_error = nullptr;
    shutdown_runtime = nullptr;
    // The CLR itself remains loaded for this native process's lifetime.
}
} // extern "C"
