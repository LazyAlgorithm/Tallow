// Tallow's narrow C ABI over Rapier3D's C bindings (third_party/rapier): what RapierPhysicsBackendWorld needs, in
// Tallow's terms. The Beef side (Engine/src/Physics/Backends/Rapier/Rapier.bf) declares these. The shim keeps
// Rapier's large descriptors, handles and lifetimes on this side.
//
// Compiled only when the prebuilt archive for the target is present (TALLOW_RAPIER and the archive exists); the stub
// in tallow_rapier_stub.c keeps builds without it linking, with tn_rapier_available() returning 0 so the provider
// stays unlisted.
#ifndef TALLOW_RAPIER_H
#define TALLOW_RAPIER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One collider part of a body shape. A simple shape is one part at the body's origin; a compound shape is several.
enum TnRapierShapeKind
{
	TN_RAPIER_BOX = 0,
	TN_RAPIER_SPHERE = 1,
	TN_RAPIER_CAPSULE = 2,
	TN_RAPIER_CYLINDER = 3,
	TN_RAPIER_CONVEX = 4,
	TN_RAPIER_TRIMESH = 5,
};

typedef struct TnRapierPart
{
	int32_t kind;
	// Box: half extents. Capsule: unused (along local Y, halfHeight). Others unused.
	float half[3];
	float radius;
	float halfHeight;
	// Pose of the part relative to the body (identity for a simple shape).
	float position[3];
	float rotation[4];
	// Convex hull and trimesh: borrowed xyz vertices and u32 triangle indices, valid only for the call.
	const float* vertices;
	int32_t vertexCount;
	const uint32_t* indices;
	int32_t indexCount;
} TnRapierPart;

typedef struct TnRapierHit
{
	uint32_t body;
	// Opaque part/triangle id for tn_rapier_hit_detail.
	uint32_t subshape;
	float fraction;
	float point[3];
	float normal[3];
	float penetrationDepth;
} TnRapierHit;

// One contact beginning, staying or ending. kind: 0 began, 1 stopped, 2 still touching.
typedef struct TnRapierContact
{
	uint32_t bodyA, bodyB;
	uint64_t objectA, objectB;
	int32_t kind;
	int32_t sensor;
	float point[3];
	// From A towards B.
	float normal[3];
	float speed;
} TnRapierContact;

typedef struct TnRapierCharacterHit
{
	uint32_t body;
	uint32_t reserved;
	uint64_t userData;
	float point[3];
	float normal[3];
} TnRapierCharacterHit;

typedef struct TnRapierCharacterState
{
	float position[3];
	float velocity[3];
	float groundNormal[3];
	float groundVelocity[3];
	// 0 on ground, 1 on ground too steep to stand on, 2 touching but not supported, 3 in the air.
	int32_t groundState;
	uint32_t groundBody;
} TnRapierCharacterState;

// ---- provider ----

// 1 when the pinned Rapier archive is linked and its ABI matches; 0 in the stub build.
int32_t tn_rapier_available(void);
// The loaded bindings' version string (borrowed, never freed). Empty in the stub build.
const char* tn_rapier_version(void);
// A one-line description of the linked build (SIMD lanes, parallelism, determinism).
const char* tn_rapier_build(void);

// ---- world ----

void* tn_rapier_world_new(void);
void tn_rapier_world_free(void* world);
void tn_rapier_set_gravity(void* world, float x, float y, float z);
void tn_rapier_set_length_scale(void* world, float scale);
// errorMask: bit 0 no body capacity (0 when fine). stepMs: the native step's time.
void tn_rapier_step(void* world, float deltaTime, int32_t* errorMask, float* stepMilliseconds);
void tn_rapier_clear(void* world);
void tn_rapier_set_contact_events(void* world, int32_t enabled);
// The world states a query sees (uint32.MaxValue: all). Set from PhysicsWorld.PrepareQuery.
void tn_rapier_set_query_worlds(void* world, uint32_t groups);
// Contacts collected by the last step; returns the count and copies at most capacity.
int32_t tn_rapier_contacts(void* world, TnRapierContact* out, int32_t capacity);

// ---- exact snapshots ----
// Rapier's whole-world snapshot (bodies, colliders, joints, soft bodies and their deformation). Restoring makes a
// new native world and re-binds every handle this shim holds. The bytes are only valid for the same Rapier build.
void* tn_rapier_state_save(void* world, void* reuse);
bool tn_rapier_state_restore(void* world, void* state);
int32_t tn_rapier_state_size(void* state);
void tn_rapier_state_free(void* state);
void* tn_rapier_state_from(const uint8_t* data, int32_t size);
void tn_rapier_state_copy(void* state, uint8_t* into, int32_t size);

// ---- bodies ----

// motion: 0 static, 1 kinematic, 2 dynamic. group: the world-state group (0 = all). motionClass:
// PhysicsLayerTable's 0 static, 1 moving, 2 debris. wantedId: 0xffffffff for any. Returns 0xffffffff on failure.
uint32_t tn_rapier_body_create(void* world, int32_t motion, const float position[3], const float rotation[4],
	const TnRapierPart* parts, int32_t partCount, uint32_t objectCode, uint32_t group, int32_t motionClass,
	uint32_t collisionMemberships, uint32_t collisionFilter, int32_t sensor, int32_t debris, float friction,
	float restitution, float linearDamping, float angularDamping, float gravityScale, int32_t allowSleeping,
	int32_t continuousCollision, int32_t freezeRotation, int32_t overrideMass, float mass, uint64_t userData,
	uint32_t wantedId);
void tn_rapier_body_destroy(void* world, uint32_t body);
void tn_rapier_body_pose(void* world, uint32_t body, float position[3], float rotation[4]);
void tn_rapier_body_set_pose(void* world, uint32_t body, const float position[3], const float rotation[4], int32_t wake);
// A kinematic body moved by the next step, with the velocity that pushes what it meets.
void tn_rapier_body_move_kinematic(void* world, uint32_t body, const float position[3], const float rotation[4],
	float deltaTime);
void tn_rapier_body_linvel(void* world, uint32_t body, float velocity[3]);
void tn_rapier_body_set_linvel(void* world, uint32_t body, const float velocity[3]);
void tn_rapier_body_angvel(void* world, uint32_t body, float velocity[3]);
void tn_rapier_body_set_angvel(void* world, uint32_t body, const float velocity[3]);
void tn_rapier_body_set_velocities(void* world, uint32_t body, const float linear[3], const float angular[3]);
void tn_rapier_body_add_force(void* world, uint32_t body, const float force[3]);
void tn_rapier_body_add_force_at(void* world, uint32_t body, const float force[3], const float point[3]);
void tn_rapier_body_add_torque(void* world, uint32_t body, const float torque[3]);
void tn_rapier_body_add_impulse(void* world, uint32_t body, const float impulse[3]);
void tn_rapier_body_point_velocity(void* world, uint32_t body, const float point[3], float velocity[3]);
void tn_rapier_body_set_sleeping(void* world, uint32_t body, int32_t sleeping);
int32_t tn_rapier_body_is_sleeping(void* world, uint32_t body);
void tn_rapier_body_activate(void* world, uint32_t body);
float tn_rapier_body_mass(void* world, uint32_t body);
uint32_t tn_rapier_body_object_code(void* world, uint32_t body);
void tn_rapier_body_set_object_code(void* world, uint32_t body, uint32_t objectCode, uint32_t group,
	int32_t motionClass, uint32_t collisionMemberships, uint32_t collisionFilter);
void tn_rapier_body_set_enabled(void* world, uint32_t body, int32_t enabled);
// Floats a body in water whose surface passes through surfacePoint facing surfaceNormal, for one step. False when
// no part of it is under.
int32_t tn_rapier_body_buoyancy(void* world, uint32_t body, const float surfacePoint[3],
	const float surfaceNormal[3], float buoyancy, float linearDrag, float angularDrag,
	const float fluidVelocity[3], float deltaTime);

// ---- queries ----
// layerMask: one bit per project layer (0xffffffff: every layer). ignoreBody 0xffffffff excludes none.
int32_t tn_rapier_raycast(void* world, const float origin[3], const float direction[3], float maxDistance,
	uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hit);
int32_t tn_rapier_raycast_all(void* world, const float origin[3], const float direction[3], float maxDistance,
	uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hits, int32_t capacity);
int32_t tn_rapier_shape_cast(void* world, const TnRapierPart* part, const float origin[3],
	const float rotation[4], const float displacement[3], uint32_t layerMask, uint32_t ignoreBody,
	TnRapierHit* hit);
int32_t tn_rapier_shape_cast_all(void* world, const TnRapierPart* part, const float origin[3],
	const float rotation[4], const float displacement[3], uint32_t layerMask, uint32_t ignoreBody,
	TnRapierHit* hits, int32_t capacity);
int32_t tn_rapier_overlap(void* world, const TnRapierPart* part, const float origin[3],
	const float rotation[4], uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hits, int32_t capacity);
int32_t tn_rapier_check(void* world, const TnRapierPart* part, const float origin[3], const float rotation[4],
	uint32_t layerMask, uint32_t ignoreBody);
// The normal and, for a compound or mesh, the part and triangle of a hit returned by a query above.
int32_t tn_rapier_hit_detail(void* world, uint32_t body, uint32_t subshape, const float point[3],
	float normal[3], int32_t* part, int32_t* triangle);

// ---- joints ----
// kind: 0 ball (anchor/axis/swingLimit), 1 hinge (anchor/axis/childAxis/childNormal), 2 slider
// (anchor/childAnchor/axis/childAxis/childNormal/travel). Returns null on failure.
void* tn_rapier_joint_create(void* world, int32_t kind, uint32_t bodyA, uint32_t bodyB, const float anchor[3],
	const float axis[3], const float childAnchor[3], const float childAxis[3], const float childNormal[3],
	float swingLimitRadians, float travel);
void tn_rapier_joint_destroy(void* world, void* joint);
void tn_rapier_slider_spring(void* world, void* joint, float stiffness, float damping);
float tn_rapier_slider_position(void* world, void* joint);
void tn_rapier_hinge_motor(void* world, void* joint, float speed, float torque, float angle, int32_t mode,
	float response, float maximumSpeed);
float tn_rapier_hinge_angle(void* world, void* joint);

// ---- character controller ----

void* tn_rapier_character_create(void* world, const TnRapierPart* parts, int32_t partCount,
	const float position[3], const float rotation[4], float maxSlopeRadians, float mass, float pushStrength,
	float supportHeight, uint32_t objectCode, uint32_t group, uint32_t collisionMemberships,
	uint32_t collisionFilter, uint64_t userData, int32_t innerBody);
void tn_rapier_character_destroy(void* world, void* character);
uint32_t tn_rapier_character_inner_body(void* world, void* character);
void tn_rapier_character_state(void* world, void* character, TnRapierCharacterState* state);
void tn_rapier_character_move(void* world, void* character, uint32_t collisionMemberships,
	uint32_t collisionFilter, const float velocity[3], float deltaTime, float stepHeight, float stepDown,
	float stepReach, TnRapierCharacterState* state);
void tn_rapier_character_set_state(void* world, void* character, uint32_t collisionMemberships,
	uint32_t collisionFilter, const float position[3], const float rotation[4], const float velocity[3]);
int32_t tn_rapier_character_set_shape(void* world, void* character, const TnRapierPart* parts,
	int32_t partCount, uint32_t collisionMemberships, uint32_t collisionFilter, float maxPenetration);
int32_t tn_rapier_character_hits(void* world, void* character, TnRapierCharacterHit* hits, int32_t capacity);

// ---- soft bodies ----
// kind: 0 cloth, 1 jelly, 2 shell, 3 driven jelly. positions are local to center; the shim adds it for Rapier and
// subtracts it on reads. objectMatrix is the object's local-to-world transform (16 floats, column-major).
typedef struct TnRapierSoftSettings
{
	int32_t kind;
	int32_t tear;
	int32_t impacts;
	int32_t visualOnly;
	float dentDepth;
	float dentYield;
	float dentSpeed;
	float visualSpring;
	float visualDamping;
	float damping;
	float friction;
	float gravityFactor;
	int32_t iterations;
} TnRapierSoftSettings;

uint32_t tn_rapier_soft_create(void* world, const float* positions, int32_t vertexCount, const uint32_t* triangles,
	int32_t triangleCount, const float* pinned, const float* stiffness, const float center[3],
	const float objectMatrix[16], float totalMass, const TnRapierSoftSettings* settings, uint64_t userData);
void tn_rapier_soft_destroy(void* world, uint32_t body);
void tn_rapier_soft_ignore(void* world, uint32_t body, uint32_t ignoredBody);
// Carries the particles from the previous object pose to the next one; shells and driven jellies call this every
// step. The optional spring (driven jellies) pulls them towards their rest places with the given step.
void tn_rapier_soft_skin(void* world, uint32_t body, const float objectMatrix[16], const float objectNext[16],
	float step);
uint32_t tn_rapier_soft_count(void* world, uint32_t body);
// Local positions and velocities; returns the number written.
uint32_t tn_rapier_soft_read(void* world, uint32_t body, float* positions, float* velocities, uint32_t capacity);
void tn_rapier_soft_move_pinned(void* world, uint32_t body, const uint32_t* indices, const float* targets,
	uint32_t count, const float center[3]);
void tn_rapier_soft_set_positions(void* world, uint32_t body, const float* positions, const float* velocities,
	uint32_t count, const float center[3]);
void tn_rapier_soft_velocity(void* world, uint32_t body, float* velocity);
void tn_rapier_soft_set_velocity(void* world, uint32_t body, const float* velocity);
void tn_rapier_soft_impulse(void* world, uint32_t body, const float* impulse);
void tn_rapier_soft_force(void* world, uint32_t body, const float* force);
void tn_rapier_soft_shift(void* world, uint32_t body, const float* offset);
int32_t tn_rapier_soft_bounds(void* world, uint32_t body, float* minimum, float* maximum);
// Jelly pressure: the engine's gas amount (pascals times volume). Sets the volume factor held by the body.
void tn_rapier_soft_set_pressure(void* world, uint32_t body, float amount);
// Air blowing across the surface (m/s), with the engine's drag and turbulence. Scaled like Jolt's soft wind, not a
// raw velocity kick.
void tn_rapier_soft_wind(void* world, uint32_t body, const float wind[3], float drag, float turbulence,
	float time, float step);
// A shell's dents: for each particle, its offset from rest in the object's local space.
uint32_t tn_rapier_soft_dents(void* world, uint32_t body, float* output, uint32_t capacity);
uint32_t tn_rapier_soft_dent_revision(void* world, uint32_t body);
void tn_rapier_soft_set_dents(void* world, uint32_t body, const float* dents, uint32_t count,
	const float objectMatrix[16]);
void tn_rapier_soft_damp_wobble(void* world, uint32_t body, float rate, float step);
// 1 once the body has torn.
int32_t tn_rapier_soft_torn(void* world, uint32_t body);
// Lifts and drags particles under a sampled water surface; returns how many were under. samples are nx*nz
// surface heights in row-major order (x first).
uint32_t tn_rapier_soft_float(void* world, uint32_t body, const float* samples, uint32_t nx, uint32_t nz,
	float minX, float minZ, float cellX, float cellZ, float bottom, float band, float buoyancy, float drag,
	float gravity, float deltaTime, int32_t wake);
// Tear the overstretched edges now; 1 when the body split.
int32_t tn_rapier_soft_tear(void* world, uint32_t body);

// ---- ropes ----
uint32_t tn_rapier_rope_create(void* world, const float* positions, uint32_t count, const float* pinned,
	float totalMass, float stretch, float bend, float damping, float radius, const float center[3],
	uint64_t userData);
// A rope joint holding two bodies at most `length` apart. Either body id may be 0xffffffff (a world anchor).
void* tn_rapier_rope_tie(void* world, uint32_t bodyA, const float pointA[3], uint32_t bodyB,
	const float pointB[3], float length);
void tn_rapier_rope_untie(void* world, void* tie);
float tn_rapier_rope_pull(void* world, void* tie, float step);
void tn_rapier_rope_wind(void* world, uint32_t body, const float* wind, float radius, float drag,
	float turbulence, float time, float step);

// ---- vehicles ----
// One wheel of a Rapier ray-cast vehicle, in chassis-local space. direction is down (-up).
typedef struct TnRapierWheel
{
	float position[3];
	float radius;
	float width;
	float restLength;
	float minLength;
	float stiffness;
	float compression;
	float damping;
	float maxForce;
	float maxSteerRadians;
	float maxBrakeTorque;
	float maxHandBrakeTorque;
	int32_t driven;
	int32_t steers;
} TnRapierWheel;

void* tn_rapier_vehicle_create(void* world, uint32_t chassis, const TnRapierWheel* wheels, int32_t wheelCount,
	const float up[3], const float forward[3], float maxTorque, float minRPM, float maxRPM,
	const float* gearRatios, int32_t gearCount, float reverseRatio);
void tn_rapier_vehicle_destroy(void* world, void* vehicle);
void tn_rapier_vehicle_set_input(void* world, void* vehicle, float forward, float right, float brake,
	float handBrake);
int32_t tn_rapier_vehicle_wheel_count(void* world, void* vehicle);
// Returns 1 when the wheel touches something; fills the contact in world space and the body it hit.
int32_t tn_rapier_vehicle_wheel_contact(void* world, void* vehicle, int32_t index, float point[3],
	float normal[3], uint32_t* body);
float tn_rapier_vehicle_suspension(void* world, void* vehicle, int32_t index);
float tn_rapier_vehicle_wheel_rotation(void* world, void* vehicle, int32_t index);
float tn_rapier_vehicle_wheel_steer(void* world, void* vehicle, int32_t index);
// The wheel's world matrix (column-major, 16 floats) and its spin in radians.
void tn_rapier_vehicle_wheel_transform(void* world, void* vehicle, int32_t index, float* matrix, float* spin);
float tn_rapier_vehicle_engine_rpm(void* world, void* vehicle);
int32_t tn_rapier_vehicle_gear(void* world, void* vehicle);
float tn_rapier_vehicle_ratio(void* world, void* vehicle);
float tn_rapier_vehicle_wheel_speed(void* world, void* vehicle, int32_t index);

// ---- navigation geometry ----
// Every static collider's triangles inside the bounds, as world-space xyz triplets (nine floats a triangle).
// Returns 1 when the collection finished, 0 when it stopped at the safety limit.
typedef void (*TnRapierTriangleCallback)(void* user, const float* triangle);
int32_t tn_rapier_collect_geometry(void* world, const float minimum[3], const float maximum[3],
	TnRapierTriangleCallback callback, void* user);

#ifdef __cplusplus
}
#endif

#endif
