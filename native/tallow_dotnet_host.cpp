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
using unload_game_fn = int32_t (*)();
using attach_fn = int32_t (*)(const char*, uint64_t, uint64_t);
using tick_fn = int32_t (*)(int32_t, float);
using dispatch_fn = int32_t (*)(int32_t, int32_t, float);
using update_input_fn = int32_t (*)(int32_t, const tn_csharp_tick_input*, float);
using detach_fn = int32_t (*)(int32_t);
using last_error_fn = int32_t (*)(char*, int32_t);
using shutdown_fn = int32_t (*)();

std::string error;
library_handle runtime_library = nullptr;
get_managed_function load_function = nullptr;
configure_fn configure = nullptr;
load_game_fn load_game = nullptr;
unload_game_fn unload_game = nullptr;
attach_fn attach = nullptr;
tick_fn tick = nullptr;
dispatch_fn dispatch = nullptr;
update_input_fn update_input = nullptr;
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

void add_root_from_env(std::vector<std::filesystem::path>& roots, const char* name)
{
    if (const char* value = std::getenv(name); value && *value)
        add_root(roots, std::filesystem::path(platform_string(value)));
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

std::vector<std::filesystem::path> dotnet_roots()
{
    std::vector<std::filesystem::path> roots;
    add_root_from_env(roots, "DOTNET_ROOT");
#if defined(_WIN64) || defined(__x86_64__)
    add_root_from_env(roots, "DOTNET_ROOT_X64");
#elif defined(__aarch64__)
    add_root_from_env(roots, "DOTNET_ROOT_ARM64");
#endif
    // Find the dotnet CLI that the user actually runs, following symlinks.
    if (const char* search = std::getenv("PATH"); search && *search)
    {
        const std::string value(search);
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
    if (const char* files = std::getenv("ProgramFiles"); files && *files)
        add_root(roots, std::filesystem::path(platform_string(files)) / L"dotnet");
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
    const auto name = version.filename().string();
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
            !find_entry(assembly.c_str(), "UnloadGame", unload_game) ||
            !find_entry(assembly.c_str(), "Attach", attach) ||
            !find_entry(assembly.c_str(), "Tick", tick) ||
            !find_entry(assembly.c_str(), "Dispatch", dispatch) ||
            !find_entry(assembly.c_str(), "UpdateInput", update_input) ||
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

int32_t tn_csharp_unload_game(void)
{
    if (!started || !unload_game)
        return 0;
    const int32_t result = unload_game();
    if (result < 0)
        managed_error("Unloading trusted C# game assembly");
    return result > 0;
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

int32_t tn_csharp_dispatch(int32_t script_instance, int32_t event_id, float delta_time)
{
    if (!started || !dispatch)
        return 0;
    const int32_t result = dispatch(script_instance, event_id, delta_time);
    if (result < 0)
        managed_error("Dispatching C# component event");
    return result > 0;
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
    attach = nullptr;
    tick = nullptr;
    dispatch = nullptr;
    update_input = nullptr;
    detach = nullptr;
    last_error = nullptr;
    shutdown_runtime = nullptr;
    // The CLR itself remains loaded for this native process's lifetime.
}
} // extern "C"
