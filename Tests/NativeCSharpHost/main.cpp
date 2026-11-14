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
    return Match(scene, object) && static_cast<TestScene*>(context)->alive ? 1 : 0;
}

static void GetPosition(void* context, uint64_t, uint64_t, float* xyz)
{
    auto* state = static_cast<TestScene*>(context);
    for (int i = 0; i < 3; ++i) xyz[i] = state->position[i];
}

static void SetPosition(void* context, uint64_t, uint64_t, const float* xyz)
{
    auto* state = static_cast<TestScene*>(context);
    for (int i = 0; i < 3; ++i) state->position[i] = xyz[i];
}

// Mirrors the native engine's typed Transform bridge, including local
// translation and rotation payloads. The full hierarchy behavior is tested
// separately by the Beef native editor build.
static void GetTransform(void* context, uint64_t scene, uint64_t object, int32_t channel, float* value)
{
    if (!Match(scene, object) || !value) return;
    auto* state = static_cast<TestScene*>(context);
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
        case 8: value[2] = 1; return;
        case 9: value[0] = 1; return;
        case 10: value[1] = 1; return;
        default: return;
    }
    for (int i = 0; i < count; ++i) value[i] = from[i];
}

static void SetTransform(void* context, uint64_t scene, uint64_t object, int32_t channel, const float* value)
{
    if (!Match(scene, object) || !value) return;
    auto* state = static_cast<TestScene*>(context);
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
        default: return;
    }
    for (int i = 0; i < count; ++i) target[i] = value[i];
    if (channel == 1)
        for (int i = 0; i < 3; ++i) state->position[i] = value[i];
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
        &GetTransform, &SetTransform
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
    if (!tn_csharp_dispatch(script, TN_CSHARP_AWAKE, 0.0f) ||
        !tn_csharp_tick(script, 1.0f))
        return Failure("executing C# Update with configured Speed");

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
    if (!tn_csharp_detach(transformScript) || !tn_csharp_unload_game())
        return Failure("ending second Play session");

    tn_csharp_shutdown();
    std::cout << "PASS hostfxr -> C# lifecycle, input, unload/reload -> native scene\n";
    return 0;
}
