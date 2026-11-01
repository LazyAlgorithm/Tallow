// Optional, focused Jolt convex-query instrumentation, forwarded to the engine profiler.
#include <Jolt/Jolt.h>
#define JPH_EXTERNAL_PROFILE
#include <Jolt/Core/Profiler.h>
#include <cstring>

using Begin = void (*)(int);
using End = void (*)();
static thread_local Begin beginQuerySample = nullptr;
static thread_local End endQuerySample = nullptr;
extern "C" void tn_physics_profile_convex(Begin begin, End end) {
    beginQuerySample = begin;
    endQuerySample = end;
}
namespace JPH {
ExternalProfileMeasurement::ExternalProfileMeasurement(const char* name, uint32) {
    mUserData[0] = 0;
    if (!beginQuerySample) return;
    const int marker = std::strstr(name, "GetPenetrationDepthStepEPA") ? 1 : 0;
    beginQuerySample(marker);
    mUserData[0] = 1;
}
ExternalProfileMeasurement::~ExternalProfileMeasurement() {
    if (mUserData[0] && endQuerySample) endQuerySample();
}
}
