// Keeps JoltC's collector and transform ABI out of the Beef-facing API.
#include "joltc.h"
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_set>
#include <unordered_map>
#include <algorithm>
#include <utility>
#include <vector>

// Bodies marked as debris (corpses, dropped items): shape casts and overlaps pass through them.
static std::unordered_set<uint32_t> gDebris;

extern "C" void tn_physics_set_debris(uint32_t bodyId, bool debris) {
    if (debris) gDebris.insert(bodyId); else gDebris.erase(bodyId);
}

// Ray and shape queries see only the physics layers in a mask. A Jolt object layer is the world group times 96,
// plus the engine's motion class times 32, plus the project's layer (0-31), so the low five bits are the layer. The
// world group is 0 for an object in every world state, else the mask of the (first four) states it is in; a query
// with world states set sees group 0 and the groups that share a state with it. Queries run on one thread at a time.
static uint32_t gQueryMask = 0xFFFFFFFFu;
static uint32_t gQueryWorlds = 0xFFFFFFFFu;
static bool JPH_API_CALL queryLayerAllowed(void*, JPH_ObjectLayer layer) {
    const uint32_t group = (uint32_t)layer / 96u;
    return ((gQueryMask >> (layer & 31u)) & 1u) != 0 && (group == 0 || (group & gQueryWorlds) != 0);
}

// The world states the next queries see (all by default); see PhysicsWorld.QueryWorldStates.
extern "C" void tn_physics_set_query_worlds(uint32_t worlds) {
    gQueryWorlds = worlds;
}

// The filter for a query with that mask; null (no filtering) for every layer.
extern "C" const JPH_ObjectLayerFilter* tn_physics_layer_filter(uint32_t mask) {
    static JPH_ObjectLayerFilter* filter = nullptr;
    if (filter == nullptr) {
        static const JPH_ObjectLayerFilter_Procs procs{queryLayerAllowed};
        JPH_ObjectLayerFilter_SetProcs(&procs);
        filter = JPH_ObjectLayerFilter_Create(nullptr);
    }
    gQueryMask = mask;
    return mask == 0xFFFFFFFFu && gQueryWorlds == 0xFFFFFFFFu ? nullptr : filter;
}

struct TnShapeHit {
    uint32_t bodyId;
    float fraction;
    JPH_Vec3 point;
    JPH_Vec3 normal;
    float penetrationDepth;
};

static JPH_Vec3 outwardNormal(const JPH_Vec3& axis) {
    const float length = std::sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z);
    if (length < 1.0e-8f) return {0, 0, 0};
    return {-axis.x / length, -axis.y / length, -axis.z / length};
}

struct CastContext {
    uint32_t ignoreBody;
    TnShapeHit* hit;
};

static float collectCast(void* user, const JPH_ShapeCastResult* result) {
    auto& context = *static_cast<CastContext*>(user);
    if (result->bodyID2 == context.ignoreBody || gDebris.count(result->bodyID2)) return context.hit->fraction;
    auto& hit = *context.hit;
    if (hit.bodyId == UINT32_MAX || result->fraction < hit.fraction) {
        hit = {result->bodyID2, result->fraction, result->contactPointOn2,
               outwardNormal(result->penetrationAxis), result->penetrationDepth};
    }
    return hit.fraction;
}

extern "C" bool tn_physics_cast_shape(const JPH_NarrowPhaseQuery* query,
    const JPH_Shape* shape, const JPH_RVec3* origin, const JPH_Quat* rotation,
    const JPH_Vec3* displacement, uint32_t ignoreBody, TnShapeHit* hit, uint32_t layerMask) {
    *hit = {UINT32_MAX, 1, {0, 0, 0}, {0, 0, 0}, 0};
    JPH_RMat4 transform;
    #ifdef JPH_DOUBLE_PRECISION
    JPH_RMat4_RotationTranslation(&transform, rotation, origin);
#else
    JPH_Mat4_RotationTranslation(&transform, rotation, origin);
#endif
    JPH_ShapeCastSettings settings;
    JPH_ShapeCastSettings_Init(&settings);
    settings.returnDeepestPoint = true;
    settings.backFaceModeConvex = JPH_BackFaceMode_CollideWithBackFaces;
    JPH_RVec3 baseOffset{0, 0, 0};
    CastContext context{ignoreBody, hit};
    JPH_NarrowPhaseQuery_CastShape(query, shape, &transform, displacement, &settings,
        &baseOffset, collectCast, &context, nullptr, tn_physics_layer_filter(layerMask), nullptr, nullptr);
    return hit->bodyId != UINT32_MAX;
}

extern "C" bool tn_physics_overlap_contacts(bool enabled);
extern "C" const void* tn_physics_query_reach(const void* shape, const float* origin, const float* rotation, uint32_t ignoreBody);

static const JPH_BodyFilter* queryReach(const JPH_Shape* shape, const JPH_RVec3* origin, const JPH_Quat* rotation, uint32_t ignoreBody) {
    const float at[3] = {static_cast<float>(origin->x), static_cast<float>(origin->y), static_cast<float>(origin->z)};
    const float turn[4] = {rotation->x, rotation->y, rotation->z, rotation->w};
    return static_cast<const JPH_BodyFilter*>(tn_physics_query_reach(shape, at, turn, ignoreBody));
}

struct OverlapContext {
    uint32_t ignoreBody;
    TnShapeHit* hits;
    int capacity;
    int count;
};

static float collectOverlap(void* user, const JPH_CollideShapeResult* result) {
    auto& context = *static_cast<OverlapContext*>(user);
    if (result->bodyID2 == context.ignoreBody || gDebris.count(result->bodyID2)) return std::numeric_limits<float>::max();
    if (context.count < context.capacity) {
        context.hits[context.count] = {result->bodyID2, 0, result->contactPointOn2,
            outwardNormal(result->penetrationAxis), result->penetrationDepth};
    }
    ++context.count;
    // Keep every contact, without a temporary all-hit array in JoltC.
    return std::numeric_limits<float>::max();
}

extern "C" int tn_physics_overlap_shape(const JPH_NarrowPhaseQuery* query,
    const JPH_Shape* shape, const JPH_RVec3* origin, const JPH_Quat* rotation,
    uint32_t ignoreBody, TnShapeHit* hits, int capacity, uint32_t layerMask, bool analyticContacts) {
    JPH_RMat4 transform;
    #ifdef JPH_DOUBLE_PRECISION
    JPH_RMat4_RotationTranslation(&transform, rotation, origin);
#else
    JPH_Mat4_RotationTranslation(&transform, rotation, origin);
#endif
    JPH_CollideShapeSettings settings;
    JPH_CollideShapeSettings_Init(&settings);
    // How deep each contact goes is worked out to within about half a percent rather than Jolt's default hundredth of
    // that: a query shape's middle inside a body (the usual overlap) otherwise takes many penetration steps, most of
    // all for round shapes.
    settings.base.penetrationTolerance = 1.0e-2f;
    JPH_Vec3 scale{1, 1, 1};
    JPH_RVec3 baseOffset{0, 0, 0};
    OverlapContext context{ignoreBody, hits, capacity, 0};
    const bool previousMode = tn_physics_overlap_contacts(analyticContacts);
    JPH_NarrowPhaseQuery_CollideShape(query, shape, &scale, &transform, &settings,
        &baseOffset, collectOverlap, &context,
        nullptr, tn_physics_layer_filter(layerMask), queryReach(shape, origin, rotation, ignoreBody), nullptr);
    tn_physics_overlap_contacts(previousMode);
    return context.count;
}

struct CheckContext {
    uint32_t ignoreBody;
    bool found;
};

static void collectCheck(void* user, const JPH_CollideShapeResult* result) {
    auto& context = *static_cast<CheckContext*>(user);
    if (result->bodyID2 == context.ignoreBody || gDebris.count(result->bodyID2)) return;
    context.found = true;
}

// Whether anything touches the shape, without working out the contacts. Jolt stops at the first body it touches,
// unless there is debris to skip.
extern "C" bool tn_physics_check_shape(const JPH_NarrowPhaseQuery* query,
    const JPH_Shape* shape, const JPH_RVec3* origin, const JPH_Quat* rotation,
    uint32_t ignoreBody, uint32_t layerMask) {
    JPH_RMat4 transform;
    #ifdef JPH_DOUBLE_PRECISION
    JPH_RMat4_RotationTranslation(&transform, rotation, origin);
#else
    JPH_Mat4_RotationTranslation(&transform, rotation, origin);
#endif
    JPH_CollideShapeSettings settings;
    JPH_CollideShapeSettings_Init(&settings);
    settings.base.penetrationTolerance = 1.0e-2f;
    JPH_Vec3 scale{1, 1, 1};
    JPH_RVec3 baseOffset{0, 0, 0};
    CheckContext context{ignoreBody, false};
    // The ignored body is skipped by the filter, so only debris needs every contact looked at.
    const bool anyHit = gDebris.empty();
    JPH_NarrowPhaseQuery_CollideShape2(query, shape, &scale, &transform, &settings,
        &baseOffset, anyHit ? JPH_CollisionCollectorType_AnyHit : JPH_CollisionCollectorType_AllHit, collectCheck, &context,
        nullptr, tn_physics_layer_filter(layerMask), queryReach(shape, origin, rotation, ignoreBody), nullptr);
    return context.found;
}

// ---- virtual character ----
// A character that is moved by sweeping its shape through the world instead of being simulated as a body,
// which is what lets it climb steps and stay on slopes. Arguments are flat so Beef never mirrors JoltC's
// settings structs.

struct TnCharacterState {
    JPH_Vec3 position;
    JPH_Vec3 velocity;
    JPH_Vec3 groundNormal;
    JPH_Vec3 groundVelocity;
    int32_t groundState; // JPH_GroundState: 0 on ground, 1 on steep ground, 2 not supported, 3 in air
    uint32_t groundBody;
};

static JPH_RVec3 toR(const JPH_Vec3* v) { return JPH_RVec3{v->x, v->y, v->z}; }

// Inner bodies of characters that asked for soft contact with other characters. A soft character's sweep skips
// them, so two such characters overlap and are eased apart by the engine instead of stopping each other dead.
static std::vector<std::pair<const JPH_PhysicsSystem*, uint32_t>> softInnerBodies;
static const JPH_PhysicsSystem* filterSystem = nullptr;

// The user data of the soft characters' filter (the solid characters' has none).
static int softCharacterTag;

static bool JPH_API_CALL softFilterCollide(void* userData, JPH_BodyID body) {
    if (userData != &softCharacterTag) return true;
    for (const auto& entry : softInnerBodies)
        if (entry.second == body && entry.first == filterSystem) return false;
    return true;
}
// Soft bodies (cloth, jelly) and their proxies (tallow_softbody.cpp) are not walls: the character's sweep goes
// through them, and its inner body pushes them.
extern "C" bool tn_soft_is_proxy(uint32_t bodyId);
static bool JPH_API_CALL softFilterCollideLocked(void*, const JPH_Body* body) {
    return !JPH_Body_IsSoftBody(body) && !tn_soft_is_proxy(JPH_Body_GetID(body));
}

// The filter to sweep with: every character skips soft bodies; a soft character also skips soft characters.
static const JPH_BodyFilter* characterFilter(const JPH_PhysicsSystem* system, bool soft) {
    static JPH_BodyFilter* solidFilter = nullptr;
    static JPH_BodyFilter* softFilter = nullptr;
    if (solidFilter == nullptr) {
        static const JPH_BodyFilter_Procs procs{softFilterCollide, softFilterCollideLocked};
        JPH_BodyFilter_SetProcs(&procs);
        solidFilter = JPH_BodyFilter_Create(nullptr);
        softFilter = JPH_BodyFilter_Create(&softCharacterTag);
    }
    filterSystem = system;
    return soft ? softFilter : solidFilter;
}

// supportHeight: contacts below this height above the character's position count as the floor.
// innerBody: also create a kinematic body of the same shape so rays and other bodies can hit the character.
extern "C" JPH_CharacterVirtual* tn_character_create(JPH_PhysicsSystem* system, const JPH_Shape* shape,
    const JPH_Vec3* position, const JPH_Quat* rotation, float maxSlopeRadians, float mass, float maxStrength,
    float supportHeight, uint32_t layer, uint64_t userData, bool innerBody, bool soft) {
    JPH_CharacterVirtualSettings settings;
    JPH_CharacterVirtualSettings_Init(&settings);
    settings.base.shape = shape;
    settings.base.up = {0, 1, 0};
    settings.base.supportingVolume = {{0, 1, 0}, -supportHeight};
    settings.base.maxSlopeAngle = maxSlopeRadians;
    // Stops flat-bottomed shapes catching on the seams between triangles of a mesh floor.
    settings.base.enhancedInternalEdgeRemoval = true;
    settings.mass = mass;
    settings.maxStrength = maxStrength;
    if (innerBody) {
        settings.innerBodyShape = shape;
        settings.innerBodyLayer = layer;
    }
    JPH_RVec3 at = toR(position);
    JPH_CharacterVirtual* character = JPH_CharacterVirtual_Create(&settings, &at, rotation, userData, system);
    if (character != nullptr && innerBody && soft)
        softInnerBodies.push_back({system, JPH_CharacterVirtual_GetInnerBodyID(character)});
    return character;
}

extern "C" void tn_character_destroy(JPH_CharacterVirtual* character, const JPH_PhysicsSystem* system) {
    const uint32_t inner = JPH_CharacterVirtual_GetInnerBodyID(character);
    for (size_t i = 0; i < softInnerBodies.size(); ++i) {
        if (softInnerBodies[i].second == inner && softInnerBodies[i].first == system) {
            softInnerBodies.erase(softInnerBodies.begin() + i);
            break;
        }
    }
    JPH_CharacterBase_Destroy((JPH_CharacterBase*)character);
}

extern "C" uint32_t tn_character_inner_body(const JPH_CharacterVirtual* character) {
    return JPH_CharacterVirtual_GetInnerBodyID(character);
}

extern "C" void tn_character_get_state(JPH_CharacterVirtual* character, TnCharacterState* state) {
    JPH_RVec3 position;
    JPH_CharacterVirtual_GetPosition(character, &position);
    state->position = {(float)position.x, (float)position.y, (float)position.z};
    JPH_CharacterVirtual_GetLinearVelocity(character, &state->velocity);
    auto base = (JPH_CharacterBase*)character;
    JPH_CharacterBase_GetGroundNormal(base, &state->groundNormal);
    JPH_CharacterBase_GetGroundVelocity(base, &state->groundVelocity);
    state->groundState = (int32_t)JPH_CharacterBase_GetGroundState(base);
    state->groundBody = JPH_CharacterBase_GetGroundBodyId(base);
}

// Moves with the given velocity for one step, climbing steps up to stepUp and following the floor down by stepDown.
// stepForwardTest is how far past a step's edge the landing is probed; a round-bottomed shape needs about its
// radius, or it only ever finds the edge itself and refuses the step.
extern "C" void tn_character_move(JPH_CharacterVirtual* character, JPH_PhysicsSystem* system, uint32_t layer,
    const JPH_Vec3* velocity, float deltaTime, float stepUp, float stepDown, float stepForwardTest, bool soft, TnCharacterState* state) {
    JPH_CharacterVirtual_SetLinearVelocity(character, velocity);
    JPH_ExtendedUpdateSettings settings;
    settings.stickToFloorStepDown = {0, -stepDown, 0};
    settings.walkStairsStepUp = {0, stepUp, 0};
    settings.walkStairsMinStepForward = 0.02f;
    settings.walkStairsStepForwardTest = stepForwardTest;
    settings.walkStairsCosAngleForwardContact = 0.9659258f; // cos 15 degrees
    settings.walkStairsStepDownExtra = {0, 0, 0};
    JPH_CharacterVirtual_ExtendedUpdate(character, deltaTime, &settings, layer, system, characterFilter(system, soft), nullptr);
    tn_character_get_state(character, state);
}

// Teleports the character and rebuilds its contacts so ground state is correct before the next move.
extern "C" void tn_character_set_state(JPH_CharacterVirtual* character, JPH_PhysicsSystem* system, uint32_t layer,
    const JPH_Vec3* position, const JPH_Quat* rotation, const JPH_Vec3* velocity, bool soft) {
    JPH_RVec3 at = toR(position);
    JPH_CharacterVirtual_SetPosition(character, &at);
    JPH_CharacterVirtual_SetRotation(character, rotation);
    JPH_CharacterVirtual_SetLinearVelocity(character, velocity);
    JPH_CharacterVirtual_RefreshContacts(character, layer, system, characterFilter(system, soft), nullptr);
}

// True if the shape fits where the character stands, allowing that much overlap. On true the shape is in use.
extern "C" bool tn_character_set_shape(JPH_CharacterVirtual* character, JPH_PhysicsSystem* system, uint32_t layer,
    const JPH_Shape* shape, float maxPenetration, bool soft) {
    return JPH_CharacterVirtual_SetShape(character, shape, maxPenetration, layer, system, characterFilter(system, soft), nullptr);
}

// Joins two bodies at a point given in world space. With halfConeAngle above zero the second body may only swing
// that far from the axis (a shoulder, a hip); with zero it is a free ball joint. Returns null if either body is gone.
extern "C" JPH_Constraint* tn_joint_create(JPH_PhysicsSystem* system, uint32_t bodyA, uint32_t bodyB,
    const JPH_Vec3* anchor, const JPH_Vec3* axis, float halfConeAngle) {
    const JPH_BodyLockInterface* locks = JPH_PhysicsSystem_GetBodyLockInterfaceNoLock(system);
    JPH_BodyLockWrite a, b;
    JPH_BodyLockInterface_LockWrite(locks, bodyA, &a);
    JPH_BodyLockInterface_LockWrite(locks, bodyB, &b);
    JPH_Constraint* constraint = nullptr;
    if (a.body != nullptr && b.body != nullptr && a.body != b.body) {
        JPH_RVec3 point = toR(anchor);
        if (halfConeAngle > 0) {
            JPH_ConeConstraintSettings settings;
            JPH_ConeConstraintSettings_Init(&settings);
            settings.space = JPH_ConstraintSpace_WorldSpace;
            settings.point1 = point;
            settings.point2 = point;
            settings.twistAxis1 = *axis;
            settings.twistAxis2 = *axis;
            settings.halfConeAngle = halfConeAngle;
            constraint = (JPH_Constraint*)JPH_ConeConstraint_Create(&settings, a.body, b.body);
        } else {
            JPH_PointConstraintSettings settings;
            JPH_PointConstraintSettings_Init(&settings);
            settings.space = JPH_ConstraintSpace_WorldSpace;
            settings.point1 = point;
            settings.point2 = point;
            constraint = (JPH_Constraint*)JPH_PointConstraint_Create(&settings, a.body, b.body);
        }
    }
    JPH_BodyLockInterface_UnlockWrite(locks, &b);
    JPH_BodyLockInterface_UnlockWrite(locks, &a);
    if (constraint != nullptr) JPH_PhysicsSystem_AddConstraint(system, constraint);
    return constraint;
}

// Connected parts may overlap during articulation; leave their world contacts intact.
struct JointPair { JPH_Constraint* joint; uint32_t a, b; };
struct JointContacts { JPH_SimShapeFilter* filter = nullptr; std::vector<JointPair> pairs; };
static std::unordered_map<JPH_PhysicsSystem*, JointContacts*> jointContacts;
static bool JPH_API_CALL connectedCollision(void* user, const JPH_Body* a, const JPH_Shape*,
    const JPH_SubShapeID*, const JPH_Body* b, const JPH_Shape*, const JPH_SubShapeID*) {
    auto* state = static_cast<JointContacts*>(user);
    const auto idA=JPH_Body_GetID(a), idB=JPH_Body_GetID(b);
    for (const auto& pair : state->pairs)
        if ((pair.a==idA && pair.b==idB) || (pair.a==idB && pair.b==idA)) return false;
    return true;
}
static void suppressConnectedCollision(JPH_PhysicsSystem* system, JPH_Constraint* joint, uint32_t a, uint32_t b) {
    auto*& state=jointContacts[system];
    if (!state) {
        state=new JointContacts();
        static const JPH_SimShapeFilter_Procs procs{connectedCollision};
        JPH_SimShapeFilter_SetProcs(&procs);
        state->filter=JPH_SimShapeFilter_Create(state);
        JPH_PhysicsSystem_SetSimShapeFilter(system,state->filter);
    }
    state->pairs.push_back({joint,a,b});
}
extern "C" void tn_joint_filters_clear(JPH_PhysicsSystem* system) {
    auto it=jointContacts.find(system); if(it==jointContacts.end()) return;
    JPH_PhysicsSystem_SetSimShapeFilter(system,nullptr);
    JPH_SimShapeFilter_Destroy(it->second->filter); delete it->second;
    jointContacts.erase(it);
}

extern "C" void tn_joint_destroy(JPH_PhysicsSystem* system, JPH_Constraint* constraint) {
    if (constraint == nullptr) return;
    auto it=jointContacts.find(system);
    if(it!=jointContacts.end()) {
        auto& pairs=it->second->pairs;
        pairs.erase(std::remove_if(pairs.begin(),pairs.end(),[constraint](const JointPair& p){return p.joint==constraint;}),pairs.end());
    }
    JPH_PhysicsSystem_RemoveConstraint(system, constraint);
    JPH_Constraint_Destroy(constraint);
}

// Scale dimensional contact/sleep tolerances with miniature worlds; time and angular ratios stay unchanged.
extern "C" void tn_physics_scale_tolerances(JPH_PhysicsSystem* system, float ratio) {
    if (!system || !std::isfinite(ratio) || ratio <= 0) return;
    JPH_PhysicsSettings settings{};
    JPH_PhysicsSystem_GetPhysicsSettings(system, &settings);
    settings.speculativeContactDistance *= ratio;
    settings.penetrationSlop *= ratio;
    settings.manifoldTolerance *= ratio;
    settings.maxPenetrationDistance *= ratio;
    settings.bodyPairCacheMaxDeltaPositionSq *= ratio * ratio;
    settings.contactPointPreserveLambdaMaxDistSq *= ratio * ratio;
    settings.minVelocityForRestitution *= ratio;
    settings.pointVelocitySleepThreshold *= ratio;
    settings.deterministicSimulation = true;
    JPH_PhysicsSystem_SetPhysicsSettings(system, &settings);
}

// Jolt falls back to a one-metre sphere when a toy-sized inertia tensor is numerically near zero.
// Create the body with a larger calculation mass, then rescale mass and inverse inertia together before stepping.
extern "C" void tn_physics_rescale_body_mass(JPH_PhysicsSystem* system, uint32_t bodyId, float mass) {
    if (!system || !std::isfinite(mass) || mass <= 0) return;
    const auto* locks = JPH_PhysicsSystem_GetBodyLockInterface(system);
    JPH_BodyLockWrite lock{};
    JPH_BodyLockInterface_LockWrite(locks, bodyId, &lock);
    if (lock.body && JPH_Body_GetMotionType(lock.body) == JPH_MotionType_Dynamic) {
        auto* properties = JPH_Body_GetMotionProperties(lock.body);
        if (properties && JPH_MotionProperties_GetInverseMassUnchecked(properties) > 0)
            JPH_MotionProperties_ScaleToMass(properties, mass);
    }
    JPH_BodyLockInterface_UnlockWrite(locks, &lock);
}

// Revolute bearing with a real single-axis Jolt constraint. Kept behind the C ABI.
extern "C" JPH_Constraint* tn_hinge_create(JPH_PhysicsSystem* system, uint32_t bodyA, uint32_t bodyB,
    const JPH_Vec3* anchor, const JPH_Vec3* axis, const JPH_Vec3* childAxis, const JPH_Vec3* childNormal) {
    const auto* locks = JPH_PhysicsSystem_GetBodyLockInterfaceNoLock(system);
    JPH_BodyLockWrite a, b;
    JPH_BodyLockInterface_LockWrite(locks, bodyA, &a);
    JPH_BodyLockInterface_LockWrite(locks, bodyB, &b);
    JPH_Constraint* constraint = nullptr;
    if (a.body && b.body && a.body != b.body) {
        JPH_HingeConstraintSettings settings;
        JPH_HingeConstraintSettings_Init(&settings);
        settings.base.numVelocityStepsOverride = 40;
        settings.base.numPositionStepsOverride = 12;
        settings.space = JPH_ConstraintSpace_WorldSpace;
        settings.point1 = settings.point2 = toR(anchor);
        settings.hingeAxis1 = *axis; settings.hingeAxis2 = *childAxis;
        JPH_Vec3 normal = std::abs(axis->y) < 0.8f ? JPH_Vec3{-axis->z, 0, axis->x} : JPH_Vec3{0, -axis->z, axis->y};
        float length = std::sqrt(normal.x*normal.x + normal.y*normal.y + normal.z*normal.z);
        normal.x/=length; normal.y/=length; normal.z/=length;
        settings.normalAxis1 = normal; settings.normalAxis2 = *childNormal;
        settings.motorSettings.springSettings.frequencyOrStiffness = 2;
        settings.motorSettings.springSettings.damping = 1;
        constraint = (JPH_Constraint*)JPH_HingeConstraint_Create(&settings, a.body, b.body);
    }
    JPH_BodyLockInterface_UnlockWrite(locks, &b);
    JPH_BodyLockInterface_UnlockWrite(locks, &a);
    if (constraint) { JPH_PhysicsSystem_AddConstraint(system, constraint); suppressConnectedCollision(system,constraint,bodyA,bodyB); }
    return constraint;
}
extern "C" void tn_hinge_motor(JPH_Constraint* raw, float speed, float torque, float angle, int mode, float response, float maximumSpeed) {
    auto* hinge = (JPH_HingeConstraint*)raw;
    JPH_MotorSettings motor;
    JPH_HingeConstraint_GetMotorSettings(hinge, &motor);
    motor.minTorqueLimit = -std::abs(torque);
    motor.maxTorqueLimit = std::abs(torque);
    JPH_HingeConstraint_SetMotorSettings(hinge, &motor);
    // A bounded angular-velocity servo stays stable across lightweight carriers and heavy wheels.
    if(mode==2) speed=std::fmax(-maximumSpeed,std::fmin(maximumSpeed,std::remainder(angle-JPH_HingeConstraint_GetCurrentAngle(hinge),6.28318530718f)*response));
    JPH_HingeConstraint_SetTargetAngularVelocity(hinge, speed);
    JPH_HingeConstraint_SetTargetAngle(hinge, angle);
    JPH_HingeConstraint_SetMotorState(hinge, mode != 0 ? JPH_MotorState_Velocity : JPH_MotorState_Off);
}
extern "C" float tn_hinge_angle(JPH_Constraint* hinge) {
    return JPH_HingeConstraint_GetCurrentAngle((JPH_HingeConstraint*)hinge);
}

extern "C" JPH_Constraint* tn_slider_create(JPH_PhysicsSystem* system, uint32_t bodyA, uint32_t bodyB,
    const JPH_Vec3* anchor, const JPH_Vec3* childAnchor, const JPH_Vec3* axis,
    const JPH_Vec3* childAxis, const JPH_Vec3* childNormal, float travel) {
    const auto* locks=JPH_PhysicsSystem_GetBodyLockInterfaceNoLock(system);
    JPH_BodyLockWrite a,b;
    JPH_BodyLockInterface_LockWrite(locks,bodyA,&a); JPH_BodyLockInterface_LockWrite(locks,bodyB,&b);
    JPH_Constraint* result=nullptr;
    if(a.body && b.body && a.body!=b.body) {
        JPH_SliderConstraintSettings settings; JPH_SliderConstraintSettings_Init(&settings);
        settings.base.numVelocityStepsOverride=40; settings.base.numPositionStepsOverride=12;
        settings.space=JPH_ConstraintSpace_WorldSpace; settings.autoDetectPoint=false;
        settings.point1=toR(anchor); settings.point2=toR(childAnchor);
        settings.sliderAxis1=*axis; settings.sliderAxis2=*childAxis;
        JPH_Vec3 normal=std::abs(axis->y)<0.8f ? JPH_Vec3{-axis->z,0,axis->x} : JPH_Vec3{0,-axis->z,axis->y};
        float len=std::sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z);
        normal.x/=len; normal.y/=len; normal.z/=len;
        settings.normalAxis1=normal; settings.normalAxis2=*childNormal;
        settings.limitsMin=-std::abs(travel); settings.limitsMax=std::abs(travel);
        result=(JPH_Constraint*)JPH_SliderConstraint_Create(&settings,a.body,b.body);
    }
    JPH_BodyLockInterface_UnlockWrite(locks,&b); JPH_BodyLockInterface_UnlockWrite(locks,&a);
    if(result) { JPH_PhysicsSystem_AddConstraint(system,result); suppressConnectedCollision(system,result,bodyA,bodyB); }
    return result;
}
extern "C" void tn_slider_spring(JPH_Constraint* raw,float stiffness,float damping) {
    auto* slider=(JPH_SliderConstraint*)raw;
    JPH_MotorSettings settings; JPH_SliderConstraint_GetMotorSettings(slider,&settings);
    settings.springSettings.mode=JPH_SpringMode_StiffnessAndDamping;
    settings.springSettings.frequencyOrStiffness=std::fmax(1,stiffness);
    settings.springSettings.damping=std::fmax(0,damping);
    settings.minForceLimit=-1000000; settings.maxForceLimit=1000000;
    JPH_SliderConstraint_SetMotorSettings(slider,&settings);
    JPH_SliderConstraint_SetTargetPosition(slider,0);
    JPH_SliderConstraint_SetMotorState(slider,JPH_MotorState_Position);
}
extern "C" float tn_slider_position(JPH_Constraint* slider) {
    return JPH_SliderConstraint_GetCurrentPosition((JPH_SliderConstraint*)slider);
}
