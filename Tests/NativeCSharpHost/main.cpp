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
        &state, &Alive, &GetPosition, &SetPosition, &Destroy, &IsMine
    };
    if (!tn_csharp_set_callbacks(&callbacks))
        return Failure("binding engine callbacks");

    if (tn_csharp_load_game(game.c_str()) < 2)
        return Failure("loading trusted game and Tallow assembly definitions");

    const int32_t script = tn_csharp_attach("Gameplay.MoveRight", 1, 1);
    if (script < 1)
        return Failure("creating C# component");

    if (!tn_csharp_tick(script, 1.0f))
        return Failure("executing C# Update");

    if (std::fabs(state.position[0] - 4.0f) > 0.0001f)
        return Failure("updating native scene position from C#");

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

    tn_csharp_shutdown();
    std::cout << "PASS hostfxr -> C# lifecycle + network input -> native scene transform\n";
    return 0;
}
