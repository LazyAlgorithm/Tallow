// The no-Rapier build's half of tallow_rapier.h: every symbol the Beef side links, doing nothing, with
// tn_rapier_available() returning 0 so the Rapier provider stays unlisted. Compiled instead of tallow_rapier.cpp
// when the pinned archive for this target is absent (see native/CMakeLists.txt).
#include "tallow_rapier.h"

#include <stddef.h>

int32_t tn_rapier_available(void) { return 0; }
const char* tn_rapier_version(void) { return ""; }
const char* tn_rapier_build(void) { return "Rapier3D (not linked)"; }

void* tn_rapier_world_new(void) { return 0; }
void tn_rapier_world_free(void* world) { (void)world; }
void tn_rapier_set_gravity(void* world, float x, float y, float z) { (void)world; (void)x; (void)y; (void)z; }
void tn_rapier_set_length_scale(void* world, float scale) { (void)world; (void)scale; }
void tn_rapier_step(void* world, float deltaTime, int32_t* errorMask, float* stepMilliseconds)
{
	(void)world;
	(void)deltaTime;
	if (errorMask != 0)
		*errorMask = 0;
	if (stepMilliseconds != 0)
		*stepMilliseconds = 0;
}
void tn_rapier_clear(void* world) { (void)world; }
void tn_rapier_set_contact_events(void* world, int32_t enabled) { (void)world; (void)enabled; }
void tn_rapier_set_query_worlds(void* world, uint32_t groups) { (void)world; (void)groups; }
int32_t tn_rapier_contacts(void* world, TnRapierContact* out, int32_t capacity)
{
	(void)world; (void)out; (void)capacity;
	return 0;
}

int32_t tn_rapier_contacts_copy(void* world, TnRapierContact* out, int32_t capacity)
{
	(void)world; (void)out; (void)capacity;
	return 0;
}

void* tn_rapier_state_save(void* world, void* reuse) { (void)world; return reuse; }
bool tn_rapier_state_restore(void* world, void* state) { (void)world; (void)state; return false; }
int32_t tn_rapier_state_size(void* state) { (void)state; return 0; }
void tn_rapier_state_free(void* state) { (void)state; }
void* tn_rapier_state_from(const uint8_t* data, int32_t size) { (void)data; (void)size; return 0; }
void tn_rapier_state_copy(void* state, uint8_t* into, int32_t size) { (void)state; (void)into; (void)size; }

uint32_t tn_rapier_body_create(void* world, int32_t motion, const float position[3], const float rotation[4],
	const TnRapierPart* parts, int32_t partCount, uint32_t objectCode, uint32_t group, int32_t motionClass,
	uint32_t collisionMemberships, uint32_t collisionFilter, int32_t sensor, int32_t debris, float friction,
	float restitution, float linearDamping, float angularDamping, float gravityScale, int32_t allowSleeping,
	int32_t continuousCollision, int32_t freezeRotation, int32_t overrideMass, float mass, uint64_t userData,
	uint32_t wantedId)
{
	(void)world; (void)motion; (void)position; (void)rotation; (void)parts; (void)partCount; (void)objectCode;
	(void)group; (void)motionClass; (void)collisionMemberships; (void)collisionFilter; (void)sensor; (void)debris;
	(void)friction; (void)restitution; (void)linearDamping; (void)angularDamping; (void)gravityScale;
	(void)allowSleeping; (void)continuousCollision; (void)freezeRotation; (void)overrideMass; (void)mass;
	(void)userData; (void)wantedId;
	return 0xffffffffu;
}
void tn_rapier_body_destroy(void* world, uint32_t body) { (void)world; (void)body; }
void tn_rapier_body_pose(void* world, uint32_t body, float position[3], float rotation[4])
{
	(void)world; (void)body;
	if (position != 0) { position[0] = position[1] = position[2] = 0; }
	if (rotation != 0) { rotation[0] = rotation[1] = rotation[2] = 0; rotation[3] = 1; }
}
void tn_rapier_body_set_pose(void* world, uint32_t body, const float position[3], const float rotation[4],
	int32_t wake) { (void)world; (void)body; (void)position; (void)rotation; (void)wake; }
void tn_rapier_body_move_kinematic(void* world, uint32_t body, const float position[3], const float rotation[4],
	float deltaTime)
{ (void)world; (void)body; (void)position; (void)rotation; (void)deltaTime; }

void tn_rapier_body_linvel(void* world, uint32_t body, float velocity[3])
{
	(void)world; (void)body;
	if (velocity != 0) { velocity[0] = velocity[1] = velocity[2] = 0; }
}
void tn_rapier_body_set_linvel(void* world, uint32_t body, const float velocity[3])
{ (void)world; (void)body; (void)velocity; }
void tn_rapier_body_angvel(void* world, uint32_t body, float velocity[3])
{
	(void)world; (void)body;
	if (velocity != 0) { velocity[0] = velocity[1] = velocity[2] = 0; }
}
void tn_rapier_body_set_angvel(void* world, uint32_t body, const float velocity[3])
{ (void)world; (void)body; (void)velocity; }
void tn_rapier_body_set_velocities(void* world, uint32_t body, const float linear[3], const float angular[3])
{ (void)world; (void)body; (void)linear; (void)angular; }
void tn_rapier_body_add_force(void* world, uint32_t body, const float force[3])
{ (void)world; (void)body; (void)force; }
void tn_rapier_body_add_force_at(void* world, uint32_t body, const float force[3], const float point[3])
{ (void)world; (void)body; (void)force; (void)point; }
void tn_rapier_body_add_torque(void* world, uint32_t body, const float torque[3])
{ (void)world; (void)body; (void)torque; }
void tn_rapier_body_add_impulse(void* world, uint32_t body, const float impulse[3])
{ (void)world; (void)body; (void)impulse; }
void tn_rapier_body_point_velocity(void* world, uint32_t body, const float point[3], float velocity[3])
{
	(void)world; (void)body; (void)point;
	if (velocity != 0) { velocity[0] = velocity[1] = velocity[2] = 0; }
}
void tn_rapier_body_set_sleeping(void* world, uint32_t body, int32_t sleeping)
{ (void)world; (void)body; (void)sleeping; }
int32_t tn_rapier_body_is_sleeping(void* world, uint32_t body) { (void)world; (void)body; return 1; }
void tn_rapier_body_activate(void* world, uint32_t body) { (void)world; (void)body; }
float tn_rapier_body_mass(void* world, uint32_t body) { (void)world; (void)body; return 0; }
uint32_t tn_rapier_body_object_code(void* world, uint32_t body) { (void)world; (void)body; return 0; }
void tn_rapier_body_set_object_code(void* world, uint32_t body, uint32_t objectCode, uint32_t group,
	int32_t motionClass, uint32_t collisionMemberships, uint32_t collisionFilter)
{ (void)world; (void)body; (void)objectCode; (void)group; (void)motionClass; (void)collisionMemberships; (void)collisionFilter; }
void tn_rapier_body_set_enabled(void* world, uint32_t body, int32_t enabled)
{ (void)world; (void)body; (void)enabled; }
int32_t tn_rapier_body_buoyancy(void* world, uint32_t body, const float surfacePoint[3],
	const float surfaceNormal[3], float buoyancy, float linearDrag, float angularDrag,
	const float fluidVelocity[3], float deltaTime)
{
	(void)world; (void)body; (void)surfacePoint; (void)surfaceNormal; (void)buoyancy; (void)linearDrag;
	(void)angularDrag; (void)fluidVelocity; (void)deltaTime;
	return 0;
}

int32_t tn_rapier_raycast(void* world, const float origin[3], const float direction[3], float maxDistance,
	uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hit)
{ (void)world; (void)origin; (void)direction; (void)maxDistance; (void)layerMask; (void)ignoreBody; (void)hit; return 0; }
int32_t tn_rapier_raycast_all(void* world, const float origin[3], const float direction[3], float maxDistance,
	uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hits, int32_t capacity)
{ (void)world; (void)origin; (void)direction; (void)maxDistance; (void)layerMask; (void)ignoreBody; (void)hits; (void)capacity; return 0; }
int32_t tn_rapier_shape_cast(void* world, const TnRapierPart* part, const float origin[3],
	const float rotation[4], const float displacement[3], uint32_t layerMask, uint32_t ignoreBody,
	TnRapierHit* hit)
{ (void)world; (void)part; (void)origin; (void)rotation; (void)displacement; (void)layerMask; (void)ignoreBody; (void)hit; return 0; }
int32_t tn_rapier_shape_cast_all(void* world, const TnRapierPart* part, const float origin[3],
	const float rotation[4], const float displacement[3], uint32_t layerMask, uint32_t ignoreBody,
	TnRapierHit* hits, int32_t capacity)
{ (void)world; (void)part; (void)origin; (void)rotation; (void)displacement; (void)layerMask; (void)ignoreBody; (void)hits; (void)capacity; return 0; }
int32_t tn_rapier_overlap(void* world, const TnRapierPart* part, const float origin[3],
	const float rotation[4], uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hits, int32_t capacity)
{ (void)world; (void)part; (void)origin; (void)rotation; (void)layerMask; (void)ignoreBody; (void)hits; (void)capacity; return 0; }
int32_t tn_rapier_check(void* world, const TnRapierPart* part, const float origin[3], const float rotation[4],
	uint32_t layerMask, uint32_t ignoreBody)
{ (void)world; (void)part; (void)origin; (void)rotation; (void)layerMask; (void)ignoreBody; return 0; }
int32_t tn_rapier_hit_detail(void* world, uint32_t body, uint32_t subshape, const float point[3],
	float normal[3], int32_t* part, int32_t* triangle)
{
	(void)world; (void)body; (void)subshape; (void)point;
	if (normal != 0) { normal[0] = normal[1] = normal[2] = 0; }
	if (part != 0) *part = -1;
	if (triangle != 0) *triangle = -1;
	return 0;
}

void* tn_rapier_joint_create(void* world, int32_t kind, uint32_t bodyA, uint32_t bodyB, const float anchor[3],
	const float axis[3], const float childAnchor[3], const float childAxis[3], const float childNormal[3],
	float swingLimitRadians, float travel)
{
	(void)world; (void)kind; (void)bodyA; (void)bodyB; (void)anchor; (void)axis; (void)childAnchor; (void)childAxis;
	(void)childNormal; (void)swingLimitRadians; (void)travel;
	return 0;
}
void tn_rapier_joint_destroy(void* world, void* joint) { (void)world; (void)joint; }
void tn_rapier_slider_spring(void* world, void* joint, float stiffness, float damping)
{ (void)world; (void)joint; (void)stiffness; (void)damping; }
float tn_rapier_slider_position(void* world, void* joint) { (void)world; (void)joint; return 0; }
void tn_rapier_hinge_motor(void* world, void* joint, float speed, float torque, float angle, int32_t mode,
	float response, float maximumSpeed)
{ (void)world; (void)joint; (void)speed; (void)torque; (void)angle; (void)mode; (void)response; (void)maximumSpeed; }
float tn_rapier_hinge_angle(void* world, void* joint) { (void)world; (void)joint; return 0; }

void* tn_rapier_character_create(void* world, const TnRapierPart* parts, int32_t partCount,
	const float position[3], const float rotation[4], float maxSlopeRadians, float mass, float pushStrength,
	float supportHeight, uint32_t objectCode, uint32_t group, uint32_t collisionMemberships,
	uint32_t collisionFilter, uint64_t userData, int32_t innerBody)
{
	(void)world; (void)parts; (void)partCount; (void)position; (void)rotation; (void)maxSlopeRadians; (void)mass;
	(void)pushStrength; (void)supportHeight; (void)objectCode; (void)group; (void)collisionMemberships;
	(void)collisionFilter; (void)userData; (void)innerBody;
	return 0;
}
void tn_rapier_character_destroy(void* world, void* character) { (void)world; (void)character; }
uint32_t tn_rapier_character_inner_body(void* world, void* character)
{ (void)world; (void)character; return 0xffffffffu; }
void tn_rapier_character_state(void* world, void* character, TnRapierCharacterState* state)
{ (void)world; (void)character; (void)state; }
void tn_rapier_character_move(void* world, void* character, uint32_t collisionMemberships,
	uint32_t collisionFilter, const float velocity[3], float deltaTime, float stepHeight, float stepDown,
	float stepReach, TnRapierCharacterState* state)
{ (void)world; (void)character; (void)collisionMemberships; (void)collisionFilter; (void)velocity; (void)deltaTime; (void)stepHeight; (void)stepDown; (void)stepReach; (void)state; }
void tn_rapier_character_set_state(void* world, void* character, uint32_t collisionMemberships,
	uint32_t collisionFilter, const float position[3], const float rotation[4], const float velocity[3])
{ (void)world; (void)character; (void)collisionMemberships; (void)collisionFilter; (void)position; (void)rotation; (void)velocity; }
int32_t tn_rapier_character_set_shape(void* world, void* character, const TnRapierPart* parts,
	int32_t partCount, uint32_t collisionMemberships, uint32_t collisionFilter, float maxPenetration)
{ (void)world; (void)character; (void)parts; (void)partCount; (void)collisionMemberships; (void)collisionFilter; (void)maxPenetration; return 0; }
int32_t tn_rapier_character_hits(void* world, void* character, TnRapierCharacterHit* hits, int32_t capacity)
{ (void)world; (void)character; (void)hits; (void)capacity; return 0; }

uint32_t tn_rapier_soft_create(void* world, const float* positions, int32_t vertexCount, const uint32_t* triangles,
	int32_t triangleCount, const float* pinned, const float* stiffness, const float center[3],
	const float objectMatrix[16], float totalMass, const TnRapierSoftSettings* settings, uint64_t userData)
{
	(void)world; (void)positions; (void)vertexCount; (void)triangles; (void)triangleCount; (void)pinned;
	(void)stiffness; (void)center; (void)objectMatrix; (void)totalMass; (void)settings; (void)userData;
	return 0xffffffffu;
}
int32_t tn_rapier_soft_has_collider(void* world, uint32_t body)
{ (void)world; (void)body; return 0; }
void tn_rapier_soft_destroy(void* world, uint32_t body) { (void)world; (void)body; }
void tn_rapier_soft_ignore(void* world, uint32_t body, uint32_t ignoredBody)
{ (void)world; (void)body; (void)ignoredBody; }
void tn_rapier_soft_skin(void* world, uint32_t body, const float objectMatrix[16], const float objectNext[16],
	float step)
{ (void)world; (void)body; (void)objectMatrix; (void)objectNext; (void)step; }
uint32_t tn_rapier_soft_count(void* world, uint32_t body) { (void)world; (void)body; return 0; }
uint32_t tn_rapier_soft_read(void* world, uint32_t body, float* positions, float* velocities, uint32_t capacity)
{ (void)world; (void)body; (void)positions; (void)velocities; (void)capacity; return 0; }
void tn_rapier_soft_move_pinned(void* world, uint32_t body, const uint32_t* indices, const float* targets,
	uint32_t count, const float center[3])
{ (void)world; (void)body; (void)indices; (void)targets; (void)count; (void)center; }
void tn_rapier_soft_set_positions(void* world, uint32_t body, const float* positions, const float* velocities,
	uint32_t count, const float center[3])
{ (void)world; (void)body; (void)positions; (void)velocities; (void)count; (void)center; }
void tn_rapier_soft_velocity(void* world, uint32_t body, float* velocity)
{ (void)world; (void)body; if (velocity) { velocity[0]=velocity[1]=velocity[2]=0; } }
void tn_rapier_soft_set_velocity(void* world, uint32_t body, const float* velocity)
{ (void)world; (void)body; (void)velocity; }
void tn_rapier_soft_impulse(void* world, uint32_t body, const float* impulse)
{ (void)world; (void)body; (void)impulse; }
void tn_rapier_soft_force(void* world, uint32_t body, const float* force, float step)
{ (void)world; (void)body; (void)force; (void)step; }
void tn_rapier_soft_shift(void* world, uint32_t body, const float* offset)
{ (void)world; (void)body; (void)offset; }
int32_t tn_rapier_soft_bounds(void* world, uint32_t body, float* minimum, float* maximum)
{ (void)world; (void)body; (void)minimum; (void)maximum; return 0; }
void tn_rapier_soft_set_pressure(void* world, uint32_t body, float amount)
{ (void)world; (void)body; (void)amount; }
void tn_rapier_soft_wind(void* world, uint32_t body, const float wind[3], float drag, float turbulence,
	float time, float step)
{ (void)world; (void)body; (void)wind; (void)drag; (void)turbulence; (void)time; (void)step; }
uint32_t tn_rapier_soft_dents(void* world, uint32_t body, float* output, uint32_t capacity)
{ (void)world; (void)body; (void)output; (void)capacity; return 0; }
uint32_t tn_rapier_soft_dent_revision(void* world, uint32_t body) { (void)world; (void)body; return 0; }
void tn_rapier_soft_set_dents(void* world, uint32_t body, const float* dents, uint32_t count,
	const float objectMatrix[16])
{ (void)world; (void)body; (void)dents; (void)count; (void)objectMatrix; }
int32_t tn_rapier_soft_torn(void* world, uint32_t body) { (void)world; (void)body; return 0; }
int32_t tn_rapier_soft_tear(void* world, uint32_t body) { (void)world; (void)body; return 0; }
uint32_t tn_rapier_soft_float(void* world, uint32_t body, const float* samples, uint32_t nx, uint32_t nz,
	float minX, float minZ, float cellX, float cellZ, float bottom, float band, float buoyancy, float drag,
	float gravity, float deltaTime, int32_t wake)
{
	(void)world; (void)body; (void)samples; (void)nx; (void)nz; (void)minX; (void)minZ; (void)cellX; (void)cellZ;
	(void)bottom; (void)band; (void)buoyancy; (void)drag; (void)gravity; (void)deltaTime; (void)wake;
	return 0;
}

uint32_t tn_rapier_rope_create(void* world, const float* positions, uint32_t count, const float* pinned,
	float totalMass, float stretch, float bend, float damping, float radius, float friction, int32_t iterations,
	uint32_t memberships, uint32_t filter, uint32_t group, const float center[3],
	uint64_t userData)
{
	(void)world; (void)positions; (void)count; (void)pinned; (void)totalMass; (void)stretch; (void)bend;
	(void)damping; (void)radius; (void)friction; (void)iterations; (void)memberships; (void)filter; (void)group;
	(void)center; (void)userData;
	return 0xffffffffu;
}
void* tn_rapier_rope_tie(void* world, uint32_t bodyA, const float pointA[3], uint32_t bodyB,
	const float pointB[3], float length)
{ (void)world; (void)bodyA; (void)pointA; (void)bodyB; (void)pointB; (void)length; return 0; }
void tn_rapier_rope_untie(void* world, void* tie) { (void)world; (void)tie; }
float tn_rapier_rope_pull(void* world, void* tie, float step) { (void)world; (void)tie; (void)step; return 0; }
void tn_rapier_rope_wind(void* world, uint32_t body, const float* wind, float radius, float drag,
	float turbulence, float time, float step)
{ (void)world; (void)body; (void)wind; (void)radius; (void)drag; (void)turbulence; (void)time; (void)step; }

void* tn_rapier_vehicle_create(void* world, uint32_t chassis, const TnRapierWheel* wheels, int32_t wheelCount,
	const float up[3], const float forward[3], float maxTorque, float minRPM, float maxRPM,
	const float* gearRatios, int32_t gearCount, float reverseRatio)
{
	(void)world; (void)chassis; (void)wheels; (void)wheelCount; (void)up; (void)forward; (void)maxTorque;
	(void)minRPM; (void)maxRPM; (void)gearRatios; (void)gearCount; (void)reverseRatio;
	return 0;
}
void tn_rapier_vehicle_destroy(void* world, void* vehicle) { (void)world; (void)vehicle; }
void tn_rapier_vehicle_set_input(void* world, void* vehicle, float forward, float right, float brake,
	float handBrake)
{ (void)world; (void)vehicle; (void)forward; (void)right; (void)brake; (void)handBrake; }
int32_t tn_rapier_vehicle_wheel_count(void* world, void* vehicle) { (void)world; (void)vehicle; return 0; }
int32_t tn_rapier_vehicle_wheel_contact(void* world, void* vehicle, int32_t index, float point[3],
	float normal[3], uint32_t* body)
{ (void)world; (void)vehicle; (void)index; (void)point; (void)normal; (void)body; return 0; }
float tn_rapier_vehicle_suspension(void* world, void* vehicle, int32_t index)
{ (void)world; (void)vehicle; (void)index; return 0; }
float tn_rapier_vehicle_wheel_rotation(void* world, void* vehicle, int32_t index)
{ (void)world; (void)vehicle; (void)index; return 0; }
float tn_rapier_vehicle_wheel_steer(void* world, void* vehicle, int32_t index)
{ (void)world; (void)vehicle; (void)index; return 0; }
void tn_rapier_vehicle_wheel_transform(void* world, void* vehicle, int32_t index, float* matrix, float* spin)
{ (void)world; (void)vehicle; (void)index; (void)matrix; (void)spin; }
float tn_rapier_vehicle_engine_rpm(void* world, void* vehicle) { (void)world; (void)vehicle; return 0; }
int32_t tn_rapier_vehicle_gear(void* world, void* vehicle) { (void)world; (void)vehicle; return 0; }
float tn_rapier_vehicle_ratio(void* world, void* vehicle) { (void)world; (void)vehicle; return 0; }
float tn_rapier_vehicle_wheel_speed(void* world, void* vehicle, int32_t index)
{ (void)world; (void)vehicle; (void)index; return 0; }

int32_t tn_rapier_collect_geometry(void* world, const float minimum[3], const float maximum[3],
	TnRapierTriangleCallback callback, void* user)
{ (void)world; (void)minimum; (void)maximum; (void)callback; (void)user; return 0; }
