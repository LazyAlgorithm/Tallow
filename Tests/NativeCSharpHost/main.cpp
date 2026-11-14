// Standalone native hostfxr smoke test: proof that trusted C# gameplay can run
// inside a native process and mutate a validated engine-owned object.
#include "../../native/tallow_dotnet_host.h"

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <string>

struct TestScene
{
    bool alive = true;
    int alive_checks = 0;
    float position[3] = {};
    float local_position[3] = {};
    float scale[3] = {1, 1, 1};
    float rotation[4] = {0, 0, 0, 1};
    float local_rotation[4] = {0, 0, 0, 1};
    float local_euler[3] = {};
    float euler[3] = {};
    float last_look_at[3] = {};
};

static bool Match(uint64_t scene, uint64_t object)
{
    return scene == 1 && object == 1;
}

static int32_t Alive(void* context, uint64_t scene, uint64_t object)
{
    auto* state = static_cast<TestScene*>(context);
    ++state->alive_checks;
    return Match(scene, object) && state->alive ? 1 : 0;
}

static int32_t GetPosition(void* context, uint64_t scene, uint64_t object, float* xyz)
{
    auto* state = static_cast<TestScene*>(context);
    if (!Match(scene, object) || !state->alive || !xyz) return 0;
    for (int i = 0; i < 3; ++i) xyz[i] = state->position[i];
    return 1;
}

static int32_t SetPosition(void* context, uint64_t scene, uint64_t object, const float* xyz)
{
    auto* state = static_cast<TestScene*>(context);
    if (!Match(scene, object) || !state->alive || !xyz) return 0;
    for (int i = 0; i < 3; ++i) state->position[i] = xyz[i];
    return 1;
}

// Mirrors Beef Transform; each operation also validates its scene/entity.
static int32_t GetTransform(void* context, uint64_t scene, uint64_t object,
    int32_t channel, float* value)
{
    auto* state = static_cast<TestScene*>(context);
    if (!Match(scene, object) || !state->alive || !value) return 0;
    for (int i = 0; i < 4; ++i) value[i] = 0;
    const float* from = nullptr;
    int count = 3;
    switch (channel)
    {
        case 1: from = state->local_position; break;
        case 2: from = state->rotation; count = 4; break;
        case 3: from = state->local_rotation; count = 4; break;
        case 4: case 5: from = state->scale; break;
        case 6: from = state->euler; break;
        case 7: from = state->local_euler; break;
        case 8: value[2] = 1; return 1;
        case 9: value[0] = 1; return 1;
        case 10: value[1] = 1; return 1;
        case 12: case 13: return 1; // Test scene has no hierarchy.
        default: return 0;
    }
    for (int i = 0; i < count; ++i) value[i] = from[i];
    return 1;
}

static int32_t SetTransform(void* context, uint64_t scene, uint64_t object,
    int32_t channel, const float* value)
{
    auto* state = static_cast<TestScene*>(context);
    if (!Match(scene, object) || !state->alive || !value) return 0;
    float* target = nullptr;
    int count = 3;
    switch (channel)
    {
        case 1: target = state->local_position; break;
        case 2: target = state->rotation; count = 4; break;
        case 3: target = state->local_rotation; count = 4; break;
        case 4: target = state->scale; break;
        case 6: target = state->euler; break;
        case 7: target = state->local_euler; break;
        case 11: target = state->last_look_at; break;
        default: return 0;
    }
    for (int i = 0; i < count; ++i) target[i] = value[i];
    if (channel == 1)
        for (int i = 0; i < 3; ++i) state->position[i] = value[i];
    return 1;
}

static void Destroy(void* context, uint64_t scene, uint64_t object)
{
    if (Match(scene, object))
        static_cast<TestScene*>(context)->alive = false;
}

static int32_t IsMine(void*, uint64_t scene, uint64_t object)
{
    return Match(scene, object) ? 1 : 0;
}

// The standalone native-host test substitutes a tiny ABI-compatible
// implementation for the generator's reflected Beef fixture. The real
// launcher resolves the identical symbol IDs from emitted Beef methods.
static int firstAverageCalls = 0;
static int secondAverageCalls = 0;
static bool useSecondBinding = false;
static float testTimeScale = 1.0f;
static std::string lastLogInfo;
static void ExposedLogInfo(const char* text, int32_t length)
{
    if (!text || length < 0) return;
    lastLogInfo.assign(text, static_cast<size_t>(length));
}
static float GetTestTimeScale() { return testTimeScale; }
static void SetTestTimeScale(float value) { testTimeScale = value; }
static float ExposedAverage(float a, float b)
{
    ++firstAverageCalls;
    return (a + b) * 0.5f;
}
static float ExposedAverageRebound(float a, float b)
{
    ++secondAverageCalls;
    return (a + b) * 0.5f;
}
static int32_t ExposedVersion() { return 1; }
static void* ResolveApi(void*, const char* symbol)
{
    if (!symbol) return nullptr;
    const std::string name(symbol);
    if (name.rfind("CSharpApiVersion_", 0) == 0)
        return reinterpret_cast<void*>(&ExposedVersion);
    // IDs are deterministic SHA-256 signature hashes emitted by BindingGen.
    if (name == "CSharpApi_e2772af6e047fd0b")
        return reinterpret_cast<void*>(&ExposedLogInfo);
    if (name == "CSharpApi_00ab8c332afb3504")
        return reinterpret_cast<void*>(&GetTestTimeScale);
    if (name == "CSharpApi_d0d279519519c93c")
        return reinterpret_cast<void*>(&SetTestTimeScale);
    if (name.rfind("CSharpApi_", 0) == 0)
        return useSecondBinding ? reinterpret_cast<void*>(&ExposedAverageRebound) :
                                  reinterpret_cast<void*>(&ExposedAverage);
    return nullptr;
}

static int Failure(const char* reason)
{
    std::cerr << "Native C# smoke test failed: " << reason << ": "
              << tn_csharp_error() << "\n";
    tn_csharp_shutdown();
    return 1;
}

int main(int argc, char** argv)
{
    if (argc != 4)
    {
        std::cerr << "Usage: host-test <runtimeconfig.json> <managed-runtime.dll> <Tallow.Game.dll>\n";
        return 2;
    }

    const std::string config = std::filesystem::absolute(argv[1]).string();
    const std::string runtime = std::filesystem::absolute(argv[2]).string();
    const std::string game = std::filesystem::absolute(argv[3]).string();

    if (!tn_csharp_init(config.c_str(), runtime.c_str()))
        return Failure("initializing hostfxr");

    TestScene state;
    tn_csharp_callbacks callbacks = {
        &state, &Alive, &GetPosition, &SetPosition, &Destroy, &IsMine,
        &GetTransform, &SetTransform, &ResolveApi
    };
    if (!tn_csharp_set_callbacks(&callbacks))
        return Failure("binding engine callbacks");

    if (tn_csharp_load_game(game.c_str()) < 2)
        return Failure("loading trusted game and Tallow assembly definitions");

    const int32_t script = tn_csharp_attach("Gameplay.MoveRight", 1, 1);
    if (script < 1)
        return Failure("creating C# component");

    // A scene's Inspector field is applied after component construction, before Awake.
    if (!tn_csharp_apply_fields(script, "Speed\t6\n"))
        return Failure("applying saved C# Inspector float field");
    const int alive_checks_before = state.alive_checks;
    if (!tn_csharp_dispatch(script, TN_CSHARP_AWAKE, 0.0f) ||
        !tn_csharp_tick(script, 1.0f))
        return Failure("executing C# Update with configured Speed");
    // Transform.Position += does a get and a set. Both callbacks validate
    // in-place; no separate native IsAlive call is allowed on this hot path.
    if (state.alive_checks != alive_checks_before)
        return Failure("Transform.Position still makes redundant native liveness calls");

    if (std::fabs(state.position[0] - 6.0f) > 0.0001f)
        return Failure("managed Inspector field failed to change native movement");

    if (!tn_csharp_detach(script))
        return Failure("destroying C# component");

    // Verify that Tallow's network input is delivered without polling
    // local input directly from managed code.
    const int32_t inputScript = tn_csharp_attach("Gameplay.InputEcho", 1, 1);
    if (inputScript < 1)
        return Failure("creating managed network-input component");

    if (!tn_csharp_dispatch(inputScript, TN_CSHARP_AWAKE, 0.0f) ||
        !tn_csharp_dispatch(inputScript, TN_CSHARP_ENABLE, 0.0f) ||
        !tn_csharp_dispatch(inputScript, TN_CSHARP_START, 0.0f))
        return Failure("driving native component lifecycle");

    const tn_csharp_tick_input jump = {0, 1, 0, 0, 1, 0};
    if (!tn_csharp_update_input(inputScript, &jump, 1.0f))
        return Failure("delivering predicted tick input");
    if (std::fabs(state.position[1] - 5.0f) > 0.0001f ||
        std::fabs(state.position[2] - 1.0f) > 0.0001f)
        return Failure("applying network move or Jump press");

    const tn_csharp_tick_input held = {0, 1, 0, 0, 1, 1};
    if (!tn_csharp_update_input(inputScript, &held, 1.0f))
        return Failure("delivering held tick input");
    if (std::fabs(state.position[1] - 5.0f) > 0.0001f ||
        std::fabs(state.position[2] - 2.0f) > 0.0001f)
        return Failure("Jump was not edge-triggered");

    if (!tn_csharp_dispatch(inputScript, TN_CSHARP_LOCAL_UPDATE, 0.0f) ||
        !tn_csharp_dispatch(inputScript, TN_CSHARP_LATE_UPDATE, 1.0f) ||
        !tn_csharp_dispatch(inputScript, TN_CSHARP_DISABLE, 0.0f) ||
        !tn_csharp_detach(inputScript))
        return Failure("managed C# cleanup and scene callbacks");

    if (!tn_csharp_unload_game())
        return Failure("unloading trusted gameplay after Play");
    if (tn_csharp_load_game(game.c_str()) < 2)
        return Failure("reloading trusted gameplay for second Play");
    const int32_t secondPlay = tn_csharp_attach("Gameplay.MoveRight", 1, 1);
    if (secondPlay < 1 || !tn_csharp_tick(secondPlay, 0.5f))
        return Failure("running fresh managed component on second Play");
    if (std::fabs(state.position[0] - 8.0f) > 0.0001f)
        return Failure("reloaded gameplay did not update the native transform");
    if (!tn_csharp_detach(secondPlay))
        return Failure("detaching second Play script");
    const int32_t vectorScript = tn_csharp_attach("Gameplay.VectorMath", 1, 1);
    if (vectorScript < 1 || !tn_csharp_tick(vectorScript, 1.0f))
        return Failure("running C# vector arithmetic script");
    if (std::fabs(state.position[0] - 14.5f) > 0.0001f ||
        std::fabs(state.position[1] - 25.5f) > 0.0001f ||
        std::fabs(state.position[2] - 44.5f) > 0.0001f)
        return Failure("vector addition, multiplication or subtraction");
    if (!tn_csharp_detach(vectorScript))
        return Failure("detaching vector arithmetic script");

    const int32_t transformScript = tn_csharp_attach("Gameplay.TransformParity", 1, 1);
    if (transformScript < 1 ||
        !tn_csharp_dispatch(transformScript, TN_CSHARP_AWAKE, 0.0f) ||
        !tn_csharp_tick(transformScript, 1.0f))
        return Failure("running native Transform parity C# behaviour");
    if (std::fabs(state.position[0] - 6.0f) > 0.0001f ||
        std::fabs(state.position[1] - 5.0f) > 0.0001f ||
        std::fabs(state.position[2] - 6.0f) > 0.0001f ||
        std::fabs(state.scale[0] - 2.0f) > 0.0001f ||
        std::fabs(state.scale[1] - 3.0f) > 0.0001f ||
        std::fabs(state.scale[2] - 4.0f) > 0.0001f ||
        std::fabs(state.local_euler[0] - 10.0f) > 0.0001f ||
        std::fabs(state.local_euler[1] - 20.0f) > 0.0001f ||
        std::fabs(state.local_euler[2] - 30.0f) > 0.0001f ||
        std::fabs(state.last_look_at[2] - 5.0f) > 0.0001f)
        return Failure("C# and native Transform properties differ");
    if (!tn_csharp_detach(transformScript))
        return Failure("detaching native Transform parity script");

    // Both GetComponent forms must resolve another script attached to the
    // same native scene entity, without exposing an unsafe Beef object pointer.
    const int32_t mover = tn_csharp_attach("Gameplay.MoveRight", 1, 1);
    const int32_t lookup = tn_csharp_attach("Gameplay.ComponentLookup", 1, 1);
    if (mover < 1 || lookup < 1 ||
        !tn_csharp_dispatch(lookup, TN_CSHARP_AWAKE, 0.0f))
        return Failure("resolving C# GetComponent on the same native object");
    if (std::fabs(state.position[1] - 8.0f) > 0.0001f)
        return Failure("managed GetComponent<T> did not resolve sibling C# script");
    if (!tn_csharp_detach(lookup) || !tn_csharp_detach(mover))
        return Failure("cleaning up component lookup");

    // The method is declared *only* in annotated Beef and emitted for C#
    // by BindingGen; call it through a cached unmanaged function pointer.
    const int32_t generated = tn_csharp_attach("Gameplay.GeneratedBindingSmoke", 1, 1);
    if (generated < 1 ||
        !tn_csharp_dispatch(generated, TN_CSHARP_AWAKE, 0.0f))
        return Failure("calling generated Beef/C# binding");
    if (std::fabs(state.position[0] - 5.0f) > 0.0001f)
        return Failure("generated method did not execute native ABI");
    if (!tn_csharp_detach(generated))
        return Failure("detaching generated binding test");
    if (lastLogInfo != "Tallow log \xC3\xA9")
        return Failure("generated UTF-8 Log.Info did not reach native callback");
    if (std::fabs(testTimeScale - 0.5f) > 0.0001f)
        return Failure("native TimeScale setter was not reached");
    if (firstAverageCalls != 1 || secondAverageCalls != 0)
        return Failure("initial native binding did not execute once");

    // Rebind the native API in the SAME managed process. The generated C#
    // wrappers must discard their cached pointers or they will silently keep
    // calling a potentially unloaded native library after hot reload.
    useSecondBinding = true;
    if (!tn_csharp_set_callbacks(&callbacks))
        return Failure("rebinding the native C# API resolver");
    const int32_t rebound = tn_csharp_attach("Gameplay.GeneratedBindingSmoke", 1, 1);
    if (rebound < 1 || !tn_csharp_dispatch(rebound, TN_CSHARP_AWAKE, 0.0f))
        return Failure("using generated binding after native rebind");
    if (!tn_csharp_detach(rebound) || firstAverageCalls != 1 || secondAverageCalls != 1)
        return Failure("stale cached native function pointer survived rebind");

    if (!tn_csharp_unload_game())
        return Failure("ending second Play session");

    tn_csharp_shutdown();
    std::cout << "PASS hostfxr -> C# lifecycle, input, unload/reload -> native scene\n";
    return 0;
}
