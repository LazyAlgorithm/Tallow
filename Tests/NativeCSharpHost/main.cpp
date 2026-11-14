// Standalone native hostfxr smoke test: proof that trusted C# gameplay can run
// inside a native process and mutate a validated engine-owned object.
#include "../../native/tallow_dotnet_host.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <string>

static_assert(sizeof(tn_csharp_tick_batch_item) == 32 &&
              offsetof(tn_csharp_tick_batch_item, delta_time) == 28,
    "Host test and engine input batch layouts differ");

struct TestScene
{
    bool alive = true;
    std::string createdName;
    std::string prefabPath;
    uint32_t createCount = 0;
    uint32_t prefabCount = 0;
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

static uint64_t CreateSceneObject(void* context, uint64_t session, const char* utf8, int32_t length)
{
    if (!context || session != 1 || !utf8 || length < 1 || length > 4096) return 0;
    auto* state = static_cast<TestScene*>(context);
    state->createdName.assign(utf8, static_cast<size_t>(length));
    ++state->createCount;
    return 42;
}

static uint64_t FindSceneObject(void* context, uint64_t session, const char* utf8, int32_t length)
{
    if (!context || session != 1 || !utf8 || length < 1 || length > 4096) return 0;
    auto* state = static_cast<TestScene*>(context);
    return state->createCount > 0 &&
           state->createdName == std::string(utf8, static_cast<size_t>(length)) ? 42 : 0;
}

static uint64_t InstantiatePrefab(void* context, uint64_t session, const char* utf8, int32_t length)
{
    if (!context || session != 1 || !utf8 || length < 1 || length > 4096) return 0;
    auto* state = static_cast<TestScene*>(context);
    state->prefabPath.assign(utf8, static_cast<size_t>(length));
    ++state->prefabCount;
    return 77;
}

// The standalone native-host test substitutes a tiny ABI-compatible
// implementation for the generator's reflected Beef fixture. The real
// launcher resolves the identical symbol IDs from emitted Beef methods.
static int firstAverageCalls = 0;
static int secondAverageCalls = 0;
static bool useSecondBinding = false;
static float testTimeScale = 1.0f;
static std::string lastLogInfo;
static std::string lastRequestedScene;
static void ExposedSceneLoad(const char* data, int32_t length)
{
    if (!data || length < 0) return;
    lastRequestedScene.assign(data, static_cast<size_t>(length));
}
static void ExposedQuit() { /* Do not stop the standalone smoke host. */ }
static void ExposedLogInfo(const char* text, int32_t length)
{
    if (!text || length < 0) return;
    lastLogInfo.assign(text, static_cast<size_t>(length));
}
static float GetTestTimeScale() { return testTimeScale; }
static void SetTestTimeScale(float value) { testTimeScale = value; }
static void ExposedEulerDegrees(const float* degrees, float* result)
{
    if (!degrees || !result) return;
    // Identity for zero Euler angles; nonzero values will be caught by a
    // future full-engine integration test using Beef's rotation convention.
    result[0] = 0; result[1] = 0; result[2] = 0; result[3] = 1;
}
static void ExposedToEulerDegrees(const float* rotation, float* result)
{
    if (!rotation || !result) return;
    result[0] = 0; result[1] = 0; result[2] = 0;
}
static void ExposedLookRotation(const float* forward, const float* up, float* result)
{
    if (!forward || !up || !result) return;
    result[0] = 0; result[1] = 0; result[2] = 0; result[3] = 1;
}
// The following native host doubles verify generated C# physics ABI
// signatures and value marshalling. They do NOT attempt to simulate Jolt.
static int physicsRigidbodyForces = 0;
static float physicsAngularVelocity[3] = {1, 2, 3};
static int physicsTorques = 0;
static int physicsForcesAtPosition = 0;
static int physicsSleeps = 0;
static int physicsSoftImpulses = 0;
static float physicsSoftPressure = 10.0f;
static int ecsQueries = 0;
static int32_t ExposedEcsIsAlive(uint64_t scene, uint64_t entity)
{
    return scene == 1 && (entity == 11 || entity == 22 || entity == 33) ? 1 : 0;
}
static int32_t ExposedEcsCountRigidbodies(uint64_t scene)
{
    return scene == 1 ? 3 : 0;
}
static int32_t ExposedEcsCopyRigidbodyMasses(uint64_t scene, int32_t offset,
    uint64_t* ids, int32_t idCount, float* masses, int32_t massCount)
{
    if (scene != 1 || offset < 0 || idCount < 0 || massCount < 0 ||
        (idCount > 0 && !ids) || (massCount > 0 && !masses)) return 0;
    const uint64_t nativeIds[3] = {11, 22, 33};
    const float nativeMasses[3] = {1.5f, 2.5f, 3.5f};
    const int32_t available = offset < 3 ? 3 - offset : 0;
    const int32_t copied = std::min(std::min(idCount, massCount), available);
    for (int i = 0; i < copied; ++i)
    {
        ids[i] = nativeIds[offset + i];
        masses[i] = nativeMasses[offset + i];
    }
    ++ecsQueries;
    return copied;
}
static int32_t ExposedHasRigidbody(uint64_t scene, uint64_t entity) {
    return Match(scene, entity) ? 1 : 0;
}
static int32_t ExposedHasSoftBody(uint64_t scene, uint64_t entity) {
    return Match(scene, entity) ? 1 : 0;
}
static int32_t ExposedAddRigidbodyForce(uint64_t scene, uint64_t entity, const float* force) {
    if (!Match(scene, entity) || !force || force[0] != 1 || force[1] != 2 || force[2] != 3)
        return 0;
    ++physicsRigidbodyForces;
    return 1;
}
static void ExposedGetRigidbodyAngularVelocity(uint64_t scene, uint64_t entity, float* result)
{
    if (!Match(scene, entity) || !result) return;
    for (int i = 0; i < 3; ++i) result[i] = physicsAngularVelocity[i];
}
static int32_t ExposedSetRigidbodyAngularVelocity(uint64_t scene, uint64_t entity, const float* velocity)
{
    if (!Match(scene, entity) || !velocity ||
        velocity[0] != 4 || velocity[1] != 5 || velocity[2] != 6) return 0;
    for (int i = 0; i < 3; ++i) physicsAngularVelocity[i] = velocity[i];
    return 1;
}
static int32_t ExposedAddRigidbodyTorque(uint64_t scene, uint64_t entity, const float* torque)
{
    if (!Match(scene, entity) || !torque ||
        torque[0] != 7 || torque[1] != 8 || torque[2] != 9) return 0;
    ++physicsTorques;
    return 1;
}
static int32_t ExposedAddRigidbodyForceAtPosition(uint64_t scene, uint64_t entity,
                                                 const float* force, const float* point)
{
    if (!Match(scene, entity) || !force || !point ||
        force[0] != 1 || force[1] != 2 || force[2] != 3 ||
        point[0] != 10 || point[1] != 20 || point[2] != 30) return 0;
    ++physicsForcesAtPosition;
    return 1;
}
static void ExposedGetRigidbodyPointVelocity(uint64_t scene, uint64_t entity,
                                            const float* point, float* result)
{
    if (!Match(scene, entity) || !point || !result ||
        point[0] != 10 || point[1] != 20 || point[2] != 30) return;
    result[0] = 2; result[1] = 3; result[2] = 4;
}
static int32_t ExposedSleepRigidbody(uint64_t scene, uint64_t entity)
{
    if (!Match(scene, entity)) return 0;
    ++physicsSleeps;
    return 1;
}
static int characterMoves = 0;
static int characterSimpleMoves = 0;
static int characterTeleports = 0;
static int32_t ExposedHasCharacterController(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? 1 : 0;
}
static int32_t ExposedHasCharacterSimulation(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? 1 : 0;
}
static int32_t ExposedIsCharacterGrounded(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? 1 : 0;
}
static int32_t ExposedCanCharacterJump(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? 1 : 0;
}
static void ExposedGetCharacterVelocity(uint64_t session, uint64_t entity, float* result)
{
    if (!Match(session, entity) || !result) return;
    result[0] = 1; result[1] = 2; result[2] = 3;
}
static int32_t ExposedMoveCharacter(uint64_t session, uint64_t entity,
                                    const float* velocity, float dt)
{
    if (!Match(session, entity) || !velocity || dt != 0.02f ||
        velocity[0] != 4 || velocity[1] != 5 || velocity[2] != 6) return 0;
    ++characterMoves;
    return 1;
}
static int32_t ExposedSimpleMoveCharacter(uint64_t session, uint64_t entity,
                                          const float* velocity, float dt, float jump)
{
    if (!Match(session, entity) || !velocity || dt != 0.02f || jump != 3 ||
        velocity[0] != 7 || velocity[1] != 8 || velocity[2] != 9) return 0;
    ++characterSimpleMoves;
    return 1;
}
static int32_t ExposedTeleportCharacter(uint64_t session, uint64_t entity,
                                        const float* position, const float* velocity)
{
    if (!Match(session, entity) || !position || !velocity ||
        position[0] != 10 || position[1] != 11 || position[2] != 12 ||
        velocity[0] != 0 || velocity[1] != 0 || velocity[2] != 0) return 0;
    ++characterTeleports;
    return 1;
}
static int32_t ExposedAddSoftBodyImpulse(uint64_t scene, uint64_t entity, const float* force) {
    if (!Match(scene, entity) || !force || force[0] != 4 || force[1] != 5 || force[2] != 6)
        return 0;
    ++physicsSoftImpulses;
    return 1;
}
// Must match Beef [CRepr] PhysicsQueryHit and managed
// [StructLayout(LayoutKind.Sequential, Pack = 8)] exactly.
struct NativePhysicsQueryHit
{
    uint64_t entityId;
    float pointX, pointY, pointZ;
    float normalX, normalY, normalZ;
    float distance, penetrationDepth;
    uint32_t bodyId, flags;
};
static_assert(sizeof(NativePhysicsQueryHit) == 48);
static_assert(offsetof(NativePhysicsQueryHit, entityId) == 0);
static_assert(offsetof(NativePhysicsQueryHit, pointX) == 8);
static_assert(offsetof(NativePhysicsQueryHit, distance) == 32);
static_assert(offsetof(NativePhysicsQueryHit, flags) == 44);

static void ExposedRaycastDetails(uint64_t session, const float* origin,
                                 const float* direction, float maxDistance,
                                 uint32_t layerMask, NativePhysicsQueryHit* result)
{
    if (!result) return;
    *result = {};
    if (session != 1 || !origin || !direction || maxDistance != 10 ||
        layerMask != UINT32_MAX || direction[2] != 1)
        return;
    result->entityId = 1;
    result->pointX = 11; result->pointY = 12; result->pointZ = 13;
    result->distance = 2.25f;
    result->bodyId = UINT32_MAX;
    result->flags = 5; // hit + GameObject, no normal
}
static void ExposedSphereCastDetails(uint64_t session, const float* origin,
                                    float radius, const float* direction,
                                    float maxDistance, uint32_t layerMask,
                                    NativePhysicsQueryHit* result)
{
    if (!result) return;
    *result = {};
    if (session != 1 || !origin || !direction || radius != 0.5f ||
        maxDistance != 10 || layerMask != UINT32_MAX || direction[2] != 1)
        return;
    result->entityId = 1;
    result->pointX = 21; result->pointY = 22; result->pointZ = 23;
    result->normalY = 1;
    result->distance = 1.25f;
    result->penetrationDepth = 0.15f;
    result->bodyId = 17;
    result->flags = 7; // hit + normal + GameObject
}
static void ExposedRaycastContact(uint64_t scene, const float* origin,
                                   const float* direction, float maxDistance,
                                   uint32_t layerMask, float* result)
{
    if (!result) return;
    if (scene != 1 || !origin || !direction || maxDistance != 10 ||
        layerMask != UINT32_MAX || direction[2] != 1)
    {
        result[0] = 0; result[1] = 0; result[2] = 0; result[3] = -1;
        return;
    }
    result[0] = 1; result[1] = 2; result[2] = 3; result[3] = 2.5f;
}
static void ExposedSphereCastContact(uint64_t scene, const float* origin,
                                    float radius, const float* direction,
                                    float maxDistance, uint32_t layerMask,
                                    float* result)
{
    if (!result) return;
    if (scene != 1 || !origin || !direction || radius != 0.5f ||
        maxDistance != 10 || layerMask != UINT32_MAX || direction[2] != 1)
    {
        result[0] = 0; result[1] = 0; result[2] = 0; result[3] = -1;
        return;
    }
    result[0] = 4; result[1] = 5; result[2] = 6; result[3] = 1.5f;
}
static int32_t ExposedGetSoftBodyMode(uint64_t scene, uint64_t entity)
{
    return Match(scene, entity) ? 1 : -1;
}
static int32_t ExposedGetSoftBodyVertexCount(uint64_t scene, uint64_t entity)
{
    return Match(scene, entity) ? 128 : 0;
}
static float ExposedRaycastDistance(uint64_t scene, const float* origin,
                                   const float* direction, float maxDistance,
                                   uint32_t layerMask) {
    if (scene != 1 || !origin || !direction ||
        direction[0] != 0 || direction[1] != 0 || direction[2] != 1 ||
        maxDistance != 10 || layerMask != UINT32_MAX)
        return -1;
    return 2.5f;
}
// Indexed collider class-component ABI. The native host imitates three
// stacked shapes to verify that C# does not confuse attachment index with
// a unique per-type ECS handle.
static float testSoftStiffness = 0.9f;
static float testSoftWobble = 3.0f;
static int colliderReads = 0;
static int32_t ExposedGetColliderCount(uint64_t scene, uint64_t entity)
{
    return Match(scene, entity) ? 3 : 0;
}
static int32_t ExposedGetColliderKind(uint64_t scene, uint64_t entity, int32_t index)
{
    if (!Match(scene, entity) || index < 0 || index > 2) return -1;
    ++colliderReads;
    return index; // Box=0, Sphere=1, Capsule=2
}
static void ExposedGetColliderCenter(uint64_t scene, uint64_t entity,
                                     int32_t index, float* result)
{
    if (!result) return;
    result[0] = 0; result[1] = Match(scene, entity) ? float(index + 1) : 0;
    result[2] = 0;
}
static void ExposedGetColliderBoxSize(uint64_t scene, uint64_t entity,
                                      int32_t index, float* result)
{
    if (!result) return;
    result[0] = Match(scene, entity) && index == 0 ? 1 : 0;
    result[1] = Match(scene, entity) && index == 0 ? 2 : 0;
    result[2] = Match(scene, entity) && index == 0 ? 3 : 0;
}
static float ExposedGetColliderSphereRadius(uint64_t scene, uint64_t entity,
                                           int32_t index)
{
    return Match(scene, entity) && index == 1 ? 0.5f : -1;
}
static float ExposedGetColliderCapsuleRadius(uint64_t scene, uint64_t entity,
                                            int32_t index)
{
    return Match(scene, entity) && index == 2 ? 0.4f : -1;
}
static float ExposedGetColliderCapsuleHeight(uint64_t scene, uint64_t entity,
                                            int32_t index)
{
    return Match(scene, entity) && index == 2 ? 1.8f : -1;
}
static float ExposedGetSoftBodyStiffness(uint64_t scene, uint64_t entity)
{
    return Match(scene, entity) ? testSoftStiffness : 0;
}
static int32_t ExposedSetSoftBodyStiffness(uint64_t scene, uint64_t entity, float value)
{
    if (!Match(scene, entity) || value < 0 || value > 1) return 0;
    testSoftStiffness = value;
    return 1;
}
static float ExposedGetSoftBodyWobbleDamping(uint64_t scene, uint64_t entity)
{
    return Match(scene, entity) ? testSoftWobble : 0;
}
static int32_t ExposedSetSoftBodyWobbleDamping(uint64_t scene, uint64_t entity,
                                              float value)
{
    if (!Match(scene, entity) || value < 0 || value > 20) return 0;
    testSoftWobble = value;
    return 1;
}

// Native ECS JointData / Jolt constraint ABI smoke (no fake Jolt world).
static float testJointSwingLimit = 30.0f;
static int jointConnections = 0;
static int32_t ExposedHasJoint(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? 1 : 0;
}
static int32_t ExposedIsJointConnected(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? 1 : 0;
}
static uint64_t ExposedGetJointConnectedEntity(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? 42 : 0;
}
static float ExposedGetJointSwingLimit(uint64_t session, uint64_t entity)
{
    return Match(session, entity) ? testJointSwingLimit : -1.0f;
}
static int32_t ExposedSetJointSwingLimit(uint64_t session, uint64_t entity,
                                        float limit)
{
    if (!Match(session, entity) || limit < 0 || limit > 179) return 0;
    testJointSwingLimit = limit;
    return 1;
}
static int32_t ExposedConnectJoint(uint64_t session, uint64_t a, uint64_t b,
                                  const float* anchor, const float* axis, float limit)
{
    if (session != 1 || a != 1 || b != 42 || !anchor || !axis ||
        anchor[0] != 1 || anchor[1] != 2 || anchor[2] != 3 ||
        axis[0] != 0 || axis[1] != 1 || axis[2] != 0 ||
        limit != 15)
        return 0;
    ++jointConnections;
    return 1;
}

static float ExposedGetSoftBodyPressure(uint64_t scene, uint64_t entity) {
    return Match(scene, entity) ? physicsSoftPressure : 0;
}
static int32_t ExposedSetSoftBodyPressure(uint64_t scene, uint64_t entity, float value) {
    if (!Match(scene, entity) || value < 0) return 0;
    physicsSoftPressure = value;
    return 1;
}

static float ExposedClamp01(float value)
{
    return std::fmax(0.0f, std::fmin(value, 1.0f));
}
static float ExposedLerp(float a, float b, float t)
{
    return a + (b - a) * t;
}
static float ExposedMoveTowards(float current, float target, float maxDelta)
{
    const float delta = target - current;
    if (std::fabs(delta) <= maxDelta) return target;
    return current + (delta < 0 ? -maxDelta : maxDelta);
}
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
    // Exact signature IDs from the generator's approved exposure manifest.
    if (name == "CSharpApi_d87ccb801a5fd433")
        return reinterpret_cast<void*>(&ExposedEcsIsAlive);
    if (name == "CSharpApi_8f34b0284d3b1041")
        return reinterpret_cast<void*>(&ExposedEcsCountRigidbodies);
    if (name == "CSharpApi_0fe31a78ec52861b")
        return reinterpret_cast<void*>(&ExposedEcsCopyRigidbodyMasses);
    if (name == "CSharpApi_dd6b56714b85bea3")
        return reinterpret_cast<void*>(&ExposedGetColliderCount);
    if (name == "CSharpApi_82b7f344c3487d92")
        return reinterpret_cast<void*>(&ExposedGetColliderKind);
    if (name == "CSharpApi_4ba124751fd9c534")
        return reinterpret_cast<void*>(&ExposedGetColliderCenter);
    if (name == "CSharpApi_18fcbf882ca96311")
        return reinterpret_cast<void*>(&ExposedGetColliderBoxSize);
    if (name == "CSharpApi_bbc0365821f234a5")
        return reinterpret_cast<void*>(&ExposedGetColliderSphereRadius);
    if (name == "CSharpApi_4edb693c26b47349")
        return reinterpret_cast<void*>(&ExposedGetColliderCapsuleRadius);
    if (name == "CSharpApi_3a911e6fe7164103")
        return reinterpret_cast<void*>(&ExposedGetColliderCapsuleHeight);
    if (name == "CSharpApi_083c3f54b1fe9165")
        return reinterpret_cast<void*>(&ExposedGetSoftBodyStiffness);
    if (name == "CSharpApi_4e84ac47e4f849a1")
        return reinterpret_cast<void*>(&ExposedSetSoftBodyStiffness);
    if (name == "CSharpApi_0d6a12e85847fa8b")
        return reinterpret_cast<void*>(&ExposedGetSoftBodyWobbleDamping);
    if (name == "CSharpApi_cecb83b0a9c7bb44")
        return reinterpret_cast<void*>(&ExposedSetSoftBodyWobbleDamping);
    if (name == "CSharpApi_a87e0cfc19fd17ae")
        return reinterpret_cast<void*>(&ExposedHasJoint);
    if (name == "CSharpApi_531ba7e69ad2e7c4")
        return reinterpret_cast<void*>(&ExposedIsJointConnected);
    if (name == "CSharpApi_daea3381f97db07d")
        return reinterpret_cast<void*>(&ExposedGetJointConnectedEntity);
    if (name == "CSharpApi_565ccbb929dab414")
        return reinterpret_cast<void*>(&ExposedGetJointSwingLimit);
    if (name == "CSharpApi_d5ad99072a6d1d03")
        return reinterpret_cast<void*>(&ExposedSetJointSwingLimit);
    if (name == "CSharpApi_b40ba1380ed1e702")
        return reinterpret_cast<void*>(&ExposedConnectJoint);
    if (name == "CSharpApi_4cfd0ac498dbf9b9")
        return reinterpret_cast<void*>(&ExposedHasRigidbody);
    if (name == "CSharpApi_ec09232b935b3c35")
        return reinterpret_cast<void*>(&ExposedHasSoftBody);
    if (name == "CSharpApi_1a89e5a6a268148e")
        return reinterpret_cast<void*>(&ExposedAddRigidbodyForce);
    if (name == "CSharpApi_9186ecd4293e9b04")
        return reinterpret_cast<void*>(&ExposedGetRigidbodyAngularVelocity);
    if (name == "CSharpApi_18c424ca754a76b8")
        return reinterpret_cast<void*>(&ExposedSetRigidbodyAngularVelocity);
    if (name == "CSharpApi_9883f16ede034f18")
        return reinterpret_cast<void*>(&ExposedAddRigidbodyTorque);
    if (name == "CSharpApi_3a58fdae5a7a1b74")
        return reinterpret_cast<void*>(&ExposedAddRigidbodyForceAtPosition);
    if (name == "CSharpApi_5a64e6ecc959440f")
        return reinterpret_cast<void*>(&ExposedGetRigidbodyPointVelocity);
    if (name == "CSharpApi_9e37fa4f1b5124ae")
        return reinterpret_cast<void*>(&ExposedSleepRigidbody);
    if (name == "CSharpApi_f50768d5aeefdfa7")
        return reinterpret_cast<void*>(&ExposedHasCharacterController);
    if (name == "CSharpApi_95e7e18553c86618")
        return reinterpret_cast<void*>(&ExposedHasCharacterSimulation);
    if (name == "CSharpApi_fa4bf784c6473f0f")
        return reinterpret_cast<void*>(&ExposedIsCharacterGrounded);
    if (name == "CSharpApi_75166356b93394e7")
        return reinterpret_cast<void*>(&ExposedCanCharacterJump);
    if (name == "CSharpApi_074201f5d4e2eb26")
        return reinterpret_cast<void*>(&ExposedGetCharacterVelocity);
    if (name == "CSharpApi_971e0b3938ada737")
        return reinterpret_cast<void*>(&ExposedMoveCharacter);
    if (name == "CSharpApi_42b5294178e606fc")
        return reinterpret_cast<void*>(&ExposedSimpleMoveCharacter);
    if (name == "CSharpApi_40fbc6bf4a7263a0")
        return reinterpret_cast<void*>(&ExposedTeleportCharacter);
    if (name == "CSharpApi_a6cee0af24fc98a6")
        return reinterpret_cast<void*>(&ExposedAddSoftBodyImpulse);
    if (name == "CSharpApi_babf3ef4abb796e0")
        return reinterpret_cast<void*>(&ExposedRaycastDetails);
    if (name == "CSharpApi_829130371d484610")
        return reinterpret_cast<void*>(&ExposedSphereCastDetails);
    if (name == "CSharpApi_51392adf3f18d88a")
        return reinterpret_cast<void*>(&ExposedRaycastContact);
    if (name == "CSharpApi_ef33f8ec5d130d0c")
        return reinterpret_cast<void*>(&ExposedSphereCastContact);
    if (name == "CSharpApi_0a802b1b0472ee5c")
        return reinterpret_cast<void*>(&ExposedGetSoftBodyMode);
    if (name == "CSharpApi_86e73f85faa82f3b")
        return reinterpret_cast<void*>(&ExposedGetSoftBodyVertexCount);
    if (name == "CSharpApi_ff872a3c0c88b759")
        return reinterpret_cast<void*>(&ExposedRaycastDistance);
    if (name == "CSharpApi_56cd5284bdc6bc18")
        return reinterpret_cast<void*>(&ExposedGetSoftBodyPressure);
    if (name == "CSharpApi_e575a2c6c882bfad")
        return reinterpret_cast<void*>(&ExposedSetSoftBodyPressure);
    if (name == "CSharpApi_21d00acac55a8847")
        return reinterpret_cast<void*>(&ExposedSceneLoad);
    if (name == "CSharpApi_e957075e951f3a8f")
        return reinterpret_cast<void*>(&ExposedQuit);
    if (name == "CSharpApi_e2772af6e047fd0b")
        return reinterpret_cast<void*>(&ExposedLogInfo);
    if (name == "CSharpApi_00ab8c332afb3504")
        return reinterpret_cast<void*>(&GetTestTimeScale);
    if (name == "CSharpApi_d0d279519519c93c")
        return reinterpret_cast<void*>(&SetTestTimeScale);
    // Only explicitly annotated gameplay helpers cross the native ABI.
    // Standard MathF and Math.Clamp are never registered as native methods.
    if (name == "CSharpApi_dfe817f927635f11")
        return reinterpret_cast<void*>(&ExposedEulerDegrees);
    if (name == "CSharpApi_3d883aac8c5229bc")
        return reinterpret_cast<void*>(&ExposedToEulerDegrees);
    if (name == "CSharpApi_9b52f038cbeb3a52")
        return reinterpret_cast<void*>(&ExposedLookRotation);
    if (name == "CSharpApi_3dd313f9deff72c1")
        return reinterpret_cast<void*>(&ExposedClamp01);
    if (name == "CSharpApi_65b3c87958d5c643")
        return reinterpret_cast<void*>(&ExposedLerp);
    if (name == "CSharpApi_161489ddf9f26a3d")
        return reinterpret_cast<void*>(&ExposedMoveTowards);
    if (name == "CSharpApi_17858942906a9c6f")
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
        &GetTransform, &SetTransform, &ResolveApi,
        &CreateSceneObject, &FindSceneObject, &InstantiatePrefab
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

    // Native tick batching carries independent input/button-edge state
    // for each script; the batch must not borrow another player's input.
    const int32_t secondInput = tn_csharp_attach("Gameplay.InputEcho", 1, 1);
    if (secondInput < 1)
        return Failure("attaching second batched network-input script");
    const float xBeforeBatch = state.position[0];
    const float yBeforeBatch = state.position[1];
    const float zBeforeBatch = state.position[2];
    const tn_csharp_tick_batch_item inputBatch[] = {
        {inputScript, {0, 1, 0, 0, 1, 1}, 0.25f},
        {secondInput, {1, 0, 0, 0, 1, 0}, 0.5f}
    };
    if (tn_csharp_update_input_batch(inputBatch, 2) != 2 ||
        std::fabs(state.position[0] - xBeforeBatch - 0.5f) > 0.0001f ||
        std::fabs(state.position[1] - yBeforeBatch - 5.0f) > 0.0001f ||
        std::fabs(state.position[2] - zBeforeBatch - 0.25f) > 0.0001f)
        return Failure("batched TickInput position and button-edge parity");
    if (tn_csharp_update_input_batch(nullptr, 0) != 0 ||
        tn_csharp_update_input_batch(nullptr, 2) != -1 ||
        tn_csharp_update_input_batch(inputBatch, -1) != -1 ||
        tn_csharp_update_input_batch(inputBatch, 4097) != -1)
        return Failure("batched TickInput pointer/count validation");
    if (!tn_csharp_detach(secondInput))
        return Failure("detaching second network-input batch component");
    const float beforeRejectedBatch = state.position[2];
    if (tn_csharp_update_input_batch(inputBatch, 2) != -1 ||
        state.position[2] != beforeRejectedBatch)
        return Failure("stale network-input batch dispatched a valid prefix");

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

    // Run two real managed behaviours through one ordered native/CLR entry.
    const int32_t batchA = tn_csharp_attach("Gameplay.BatchLifecycleSmoke", 1, 1);
    const int32_t batchB = tn_csharp_attach("Gameplay.BatchLifecycleSmoke", 1, 1);
    if (batchA < 1 || batchB < 1)
        return Failure("attaching batch lifecycle probes");
    const int32_t batchIds[] = {batchA, batchB};
    const float startX = state.position[0], startY = state.position[1];
    if (tn_csharp_dispatch_batch(batchIds, 2, TN_CSHARP_FIXED_UPDATE, 0.5f) != 2 ||
        std::fabs(state.position[0] - startX - 1.0f) > 0.0001f ||
        tn_csharp_dispatch_batch(batchIds, 2, TN_CSHARP_LATE_UPDATE, 0.25f) != 2 ||
        std::fabs(state.position[1] - startY - 0.5f) > 0.0001f)
        return Failure("ordered batched Fixed/LateUpdate");
    if (tn_csharp_dispatch_batch(nullptr, 0, TN_CSHARP_FIXED_UPDATE, 0.5f) != 0 ||
        tn_csharp_dispatch_batch(nullptr, 1, TN_CSHARP_FIXED_UPDATE, 0.5f) != -1)
        return Failure("invalid batch pointer/count");
    if (!tn_csharp_detach(batchA) || !tn_csharp_detach(batchB))
        return Failure("batch lifecycle cleanup");
    const float unchangedX = state.position[0];
    if (tn_csharp_dispatch_batch(batchIds, 2, TN_CSHARP_FIXED_UPDATE, 0.5f) != -1 ||
        state.position[0] != unchangedX)
        return Failure("stale batch instance caused partial execution");

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
    if (lastRequestedScene != "Scenes/TestScene.tscene")
        return Failure("generated SceneManager.Load did not reach native engine");
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

    const int32_t sceneApi = tn_csharp_attach("Gameplay.SceneApiSmoke", 1, 1);
    if (sceneApi < 1 || !tn_csharp_dispatch(sceneApi, TN_CSHARP_AWAKE, 0.0f))
        return Failure("creating, finding, and instantiating prefab from C#");
    if (!tn_csharp_detach(sceneApi) || state.createCount != 1 ||
        state.createdName != "From C#" ||
        state.prefabCount != 1 || state.prefabPath != "Prefabs/Box.tprefab")
        return Failure("C# scene API did not forward validated native scene arguments");

    const int32_t physicsApi = tn_csharp_attach("Gameplay.PhysicsBindingSmoke", 1, 1);
    if (physicsApi < 1 || !tn_csharp_dispatch(physicsApi, TN_CSHARP_AWAKE, 0.0f))
        return Failure("calling generated rigidbody/soft-body physics from C#");
    if (!tn_csharp_detach(physicsApi) || physicsRigidbodyForces != 1 ||
        physicsSoftImpulses != 1 || physicsTorques != 1 ||
        physicsForcesAtPosition != 1 || physicsSleeps != 1 ||
        std::fabs(physicsAngularVelocity[0] - 4.0f) > 0.0001f ||
        std::fabs(physicsAngularVelocity[1] - 5.0f) > 0.0001f ||
        std::fabs(physicsAngularVelocity[2] - 6.0f) > 0.0001f ||
        std::fabs(physicsSoftPressure - 12.0f) > 0.0001f)
        return Failure("C# native physics ABI marshalling failed");

    const int32_t ecsApi = tn_csharp_attach("Gameplay.EcsBatchBindingSmoke", 1, 1);
    if (ecsApi < 1 || !tn_csharp_dispatch(ecsApi, TN_CSHARP_AWAKE, 0.0f) ||
        !tn_csharp_detach(ecsApi) || ecsQueries != 4)
        return Failure("generated native Flecs batch span ABI");

    const int32_t characterApi = tn_csharp_attach("Gameplay.CharacterControllerBindingSmoke", 1, 1);
    if (characterApi < 1 ||
        !tn_csharp_dispatch(characterApi, TN_CSHARP_AWAKE, 0.0f) ||
        !tn_csharp_detach(characterApi) ||
        characterMoves != 1 || characterSimpleMoves != 1 || characterTeleports != 1)
        return Failure("generated native ECS CharacterController movement ABI");

    const int32_t contactApi = tn_csharp_attach("Gameplay.PhysicsContactSmoke", 1, 1);
    if (contactApi < 1 || !tn_csharp_dispatch(contactApi, TN_CSHARP_AWAKE, 0.0f))
        return Failure("calling generated ray and sphere contacts from C#");
    if (!tn_csharp_detach(contactApi))
        return Failure("detaching generated contact ABI test");

    const int32_t detailedApi = tn_csharp_attach("Gameplay.PhysicsDetailedSmoke", 1, 1);
    if (detailedApi < 1 || !tn_csharp_dispatch(detailedApi, TN_CSHARP_AWAKE, 0.0f))
        return Failure("calling typed native Jolt result ABI from C#");
    if (!tn_csharp_detach(detailedApi))
        return Failure("detaching typed Jolt ABI test");

    const int32_t colliderApi = tn_csharp_attach("Gameplay.ColliderAndSoftSettingsSmoke", 1, 1);
    if (colliderApi < 1 || !tn_csharp_dispatch(colliderApi, TN_CSHARP_AWAKE, 0.0f))
        return Failure("calling generated class collider and soft-body settings ABI");
    if (!tn_csharp_detach(colliderApi) || colliderReads < 3 ||
        std::fabs(testSoftStiffness - 0.75f) > 0.0001f ||
        std::fabs(testSoftWobble - 4.0f) > 0.0001f)
        return Failure("native indexed collider and SoftBody settings ABI mismatch");

    const int32_t jointApi = tn_csharp_attach("Gameplay.JointBindingSmoke", 1, 1);
    if (jointApi < 1 || !tn_csharp_dispatch(jointApi, TN_CSHARP_AWAKE, 0.0f))
        return Failure("calling generated ECS JointData / Jolt constraint ABI");
    if (!tn_csharp_detach(jointApi) ||
        std::fabs(testJointSwingLimit - 45.0f) > 0.0001f ||
        jointConnections != 1)
        return Failure("native Joint swing limit or Connect callback mismatch");

    if (!tn_csharp_unload_game())
        return Failure("ending second Play session");

    tn_csharp_shutdown();
    std::cout << "PASS hostfxr -> C# lifecycle, input, unload/reload -> native scene\n";
    return 0;
}
