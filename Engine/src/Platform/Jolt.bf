using System;
using System.Collections;

namespace Tallow;

/// Jolt Physics through the JoltC C API (subset).
static class Jolt
{
	[CRepr] public struct PhysicsSystemSettings
	{
		public uint32 maxBodies;
		public uint32 numBodyMutexes;
		public uint32 maxBodyPairs;
		public uint32 maxContactConstraints;
		public uint32 padding;
		public void* broadPhaseLayerInterface;
		public void* objectLayerPairFilter;
		public void* objectVsBroadPhaseLayerFilter;
	}

	[CRepr] public struct JobConfig
	{
		public uint32 maxJobs;
		public uint32 maxBarriers;
		public int32 numThreads;
	}

	[CRepr] public struct RayCastResult
	{
		public uint32 bodyId;
		public float fraction;
		public uint32 subShapeId;
	}

	[CRepr] public struct ShapeHit
	{
		public uint32 bodyId;
		public float fraction;
		public Vector3 point;
		public Vector3 normal;
		public float penetrationDepth;
	}

	/// Mirrors TnCharacterState in native/tallow_physics.cpp.
	[CRepr] public struct CharacterState
	{
		public Vector3 position;
		public Vector3 velocity;
		public Vector3 groundNormal;
		public Vector3 groundVelocity;
		/// 0 on ground, 1 on ground too steep to stand on, 2 touching but not supported, 3 in the air.
		public int32 groundState;
		public uint32 groundBody;
	}

	[CLink] public static extern void* tn_character_create(void* system, void* shape, Vector3* position, Quaternion* rotation, float maxSlopeRadians, float mass, float maxStrength, float supportHeight, uint32 layer, uint64 userData, bool innerBody, bool soft);
	[CLink] public static extern void tn_character_destroy(void* character, void* system);
	[CLink] public static extern uint32 tn_character_inner_body(void* character);
	[CLink] public static extern void tn_physics_set_debris(uint32 bodyId, bool debris);
	[CLink] public static extern void* tn_physics_state_save(void* system, void* reuse);
	[CLink] public static extern bool tn_physics_state_restore(void* system, void* state);
	[CLink] public static extern int tn_physics_state_size(void* state);
	[CLink] public static extern void tn_physics_state_free(void* state);
	[CLink] public static extern void* tn_physics_state_save_shared(void* system, uint32 firstIndex);
	[CLink] public static extern void tn_physics_state_copy(void* state, uint8* into, int size);
	[CLink] public static extern void* tn_physics_state_from(uint8* data, int size);
	[CLink] public static extern void* JPH_BodyInterface_CreateBodyWithID(void* bodyInterface, uint32 bodyId, void* settings);
	[CLink] public static extern void* tn_joint_create(void* system, uint32 bodyA, uint32 bodyB, Vector3* anchor, Vector3* axis, float halfConeAngle);
	[CLink] public static extern void* tn_hinge_create(void* system, uint32 bodyA, uint32 bodyB, Vector3* anchor, Vector3* axis, Vector3* childAxis, Vector3* childNormal);
	[CLink] public static extern void* tn_slider_create(void* system, uint32 a, uint32 b, Vector3* anchor, Vector3* childAnchor, Vector3* axis, Vector3* childAxis, Vector3* childNormal, float travel);
	[CLink] public static extern void tn_slider_spring(void* slider, float stiffness, float damping);
	[CLink] public static extern float tn_slider_position(void* slider);
	[CLink] public static extern void tn_hinge_motor(void* hinge, float speed, float torque, float angle, int32 mode, float response, float maximumSpeed);
	[CLink] public static extern float tn_hinge_angle(void* hinge);
	[CLink] public static extern void* JPH_CylinderShape_Create(float halfHeight, float radius);
	[CLink] public static extern void tn_joint_filters_clear(void* system);
	[CLink] public static extern void tn_joint_destroy(void* system, void* joint);
	[CLink] public static extern void tn_character_get_state(void* character, CharacterState* state);
	[CLink] public static extern void tn_character_move(void* character, void* system, uint32 layer, Vector3* velocity, float deltaTime, float stepUp, float stepDown, float stepForwardTest, bool soft, CharacterState* state);
	[CLink] public static extern void tn_character_set_state(void* character, void* system, uint32 layer, Vector3* position, Quaternion* rotation, Vector3* velocity, bool soft);
	[CLink] public static extern bool tn_character_set_shape(void* character, void* system, uint32 layer, void* shape, float maxPenetration, bool soft);
	[CLink] public static extern bool tn_physics_cast_shape(void* query, void* shape, Vector3* origin, Quaternion* rotation, Vector3* displacement, uint32 ignoreBody, ShapeHit* hit, uint32 layerMask);
	[CLink] public static extern bool tn_physics_check_shape(void* query, void* shape, Vector3* origin, Quaternion* rotation, uint32 ignoreBody, uint32 layerMask);
	[CLink] public static extern void tn_physics_profile_convex(function void(int32) begin, function void() end);
	[CLink] public static extern int32 tn_physics_overlap_shape(void* query, void* shape, Vector3* origin, Quaternion* rotation, uint32 ignoreBody, ShapeHit* hits, int32 capacity, uint32 layerMask, bool analyticContacts);
	/// The object layer filter for a query that sees only the layers in the mask (null for all of them).
	[CLink] public static extern void* tn_physics_layer_filter(uint32 mask);
	[CLink] public static extern void tn_physics_set_query_worlds(uint32 worlds);
	[CLink] public static extern uint32 JPH_BodyInterface_GetObjectLayer(void* bodyInterface, uint32 bodyId);
	[CLink] public static extern void JPH_BodyInterface_SetObjectLayer(void* bodyInterface, uint32 bodyId, uint32 layer);
	[CLink] public static extern void JPH_BodyInterface_AddBody(void* bodyInterface, uint32 bodyId, int32 activation);
	[CLink] public static extern void JPH_BodyInterface_RemoveBody(void* bodyInterface, uint32 bodyId);
	[CLink] public static extern bool JPH_BodyInterface_IsAdded(void* bodyInterface, uint32 bodyId);

	[CRepr] public struct IndexedTriangle
	{
		public uint32 i1;
		public uint32 i2;
		public uint32 i3;
		public uint32 materialIndex;
		public uint32 userData;
	}

	[CRepr] public struct MassProperties
	{
		public float mass;
		public float[16] inertia;
	}

	public const int32 MotionStatic = 0;
	public const int32 MotionKinematic = 1;
	public const int32 MotionDynamic = 2;
	public const int32 Activate = 0;
	public const int32 DontActivate = 1;

	[CLink] public static extern bool JPH_Init();
	[CLink] public static extern void tn_physics_install_query_dispatch();
	[CLink] public static extern void JPH_Shutdown();
	[CLink] public static extern void* JPH_JobSystemThreadPool_Create(JobConfig* config);
	[CLink] public static extern void JPH_JobSystem_Destroy(void* jobSystem);
	[CLink] public static extern void* JPH_BroadPhaseLayerInterfaceTable_Create(uint32 numObjectLayers, uint32 numBroadPhaseLayers);
	[CLink] public static extern void JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(void* bp, uint32 objectLayer, uint8 broadPhaseLayer);
	[CLink] public static extern void* JPH_ObjectLayerPairFilterTable_Create(uint32 numObjectLayers);
	[CLink] public static extern void JPH_ObjectLayerPairFilterTable_EnableCollision(void* filter, uint32 layer1, uint32 layer2);
	[CLink] public static extern void* JPH_ObjectVsBroadPhaseLayerFilterTable_Create(void* bp, uint32 numBroadPhaseLayers, void* pairFilter, uint32 numObjectLayers);
	[CLink] public static extern void* JPH_PhysicsSystem_Create(PhysicsSystemSettings* settings);
	[CLink] public static extern void JPH_PhysicsSystem_Destroy(void* system);
	[CLink] public static extern void JPH_PhysicsSystem_OptimizeBroadPhase(void* system);
	[CLink] public static extern int32 JPH_PhysicsSystem_Update(void* system, float deltaTime, int32 collisionSteps, void* jobSystem);
	[CLink] public static extern void* JPH_PhysicsSystem_GetBodyInterface(void* system);
	[CLink] public static extern void* JPH_PhysicsSystem_GetNarrowPhaseQuery(void* system);
	[CLink] public static extern void JPH_PhysicsSystem_SetGravity(void* system, Vector3* gravity);
	[CLink] public static extern void tn_physics_scale_tolerances(void* system, float ratio);
	[CLink] public static extern void tn_physics_rescale_body_mass(void* system, uint32 bodyId, float mass);
	[CLink] public static extern void JPH_Shape_Destroy(void* shape);
	[CLink] public static extern void JPH_ShapeSettings_Destroy(void* settings);
	[CLink] public static extern void* JPH_BoxShape_Create(Vector3* halfExtent, float convexRadius);
	[CLink] public static extern void* JPH_SphereShape_Create(float radius);
	[CLink] public static extern void* JPH_CapsuleShape_Create(float halfHeightOfCylinder, float radius);
	[CLink] public static extern void* JPH_StaticCompoundShapeSettings_Create();
	[CLink] public static extern void JPH_CompoundShapeSettings_AddShape2(void* settings, Vector3* position, Quaternion* rotation, void* shape, uint32 userData);
	[CLink] public static extern void* JPH_StaticCompoundShape_Create(void* settings);
	[CLink] public static extern void JPH_BodyInterface_AddForce2(void* bodyInterface, uint32 bodyId, Vector3* force, Vector3* point);
	[CLink] public static extern void JPH_BodyInterface_GetPointVelocity(void* bodyInterface, uint32 bodyId, Vector3* point, Vector3* velocity);
	[CLink] public static extern void* JPH_ConvexHullShapeSettings_Create(Vector3* points, uint32 pointCount, float maxConvexRadius);
	[CLink] public static extern void* JPH_ConvexHullShapeSettings_CreateShape(void* settings);
	[CLink] public static extern void* JPH_MeshShapeSettings_Create2(Vector3* vertices, uint32 vertexCount, IndexedTriangle* triangles, uint32 triangleCount);
	[CLink] public static extern void* JPH_MeshShapeSettings_CreateShape(void* settings);
	[CLink] public static extern void* JPH_RotatedTranslatedShape_Create(Vector3* position, Quaternion* rotation, void* shape);
	[CLink] public static extern void* JPH_BodyCreationSettings_Create3(void* shape, Vector3* position, Quaternion* rotation, int32 motionType, uint32 objectLayer);
	[CLink] public static extern void JPH_BodyCreationSettings_Destroy(void* settings);
	[CLink] public static extern void JPH_BodyCreationSettings_SetUserData(void* settings, uint64 value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetAllowedDOFs(void* settings, int32 value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetFriction(void* settings, float value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetRestitution(void* settings, float value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetLinearDamping(void* settings, float value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetAngularDamping(void* settings, float value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetGravityFactor(void* settings, float value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetAllowSleeping(void* settings, bool value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetMotionQuality(void* settings, int32 value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetIsSensor(void* settings, bool value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetOverrideMassProperties(void* settings, int32 value);
	[CLink] public static extern void JPH_BodyCreationSettings_SetMassPropertiesOverride(void* settings, MassProperties* properties);
	[CLink] public static extern uint32 JPH_BodyInterface_CreateAndAddBody(void* bodyInterface, void* settings, int32 activation);
	[CLink] public static extern void JPH_BodyInterface_RemoveAndDestroyBody(void* bodyInterface, uint32 bodyId);
	[CLink] public static extern void JPH_BodyInterface_GetPosition(void* bodyInterface, uint32 bodyId, Vector3* result);
	[CLink] public static extern void JPH_BodyInterface_GetRotation(void* bodyInterface, uint32 bodyId, Quaternion* result);
	[CLink] public static extern void JPH_BodyInterface_SetPositionAndRotation(void* bodyInterface, uint32 bodyId, Vector3* position, Quaternion* rotation, int32 activation);
	[CLink] public static extern void JPH_BodyInterface_SetPositionRotationAndVelocity(void* bodyInterface, uint32 bodyId, Vector3* position, Quaternion* rotation, Vector3* linear, Vector3* angular);
	[CLink] public static extern void JPH_BodyInterface_GetLinearVelocity(void* bodyInterface, uint32 bodyId, Vector3* velocity);
	[CLink] public static extern void JPH_BodyInterface_SetLinearVelocity(void* bodyInterface, uint32 bodyId, Vector3* velocity);
	[CLink] public static extern void JPH_BodyInterface_GetAngularVelocity(void* bodyInterface, uint32 bodyId, Vector3* velocity);
	[CLink] public static extern void JPH_BodyInterface_SetAngularVelocity(void* bodyInterface, uint32 bodyId, Vector3* velocity);
	[CLink] public static extern void JPH_BodyInterface_AddForce(void* bodyInterface, uint32 bodyId, Vector3* force);
	[CLink] public static extern void JPH_BodyInterface_AddImpulse(void* bodyInterface, uint32 bodyId, Vector3* impulse);
	[CLink] public static extern void JPH_Shape_GetLocalBounds(void* shape, Bounds* result);
	[CLink] public static extern bool JPH_BodyInterface_ApplyBuoyancyImpulse(void* bodyInterface, uint32 bodyId, Vector3* surfacePosition, Vector3* surfaceNormal, float buoyancy,
		float linearDrag, float angularDrag, Vector3* fluidVelocity, Vector3* gravity, float deltaTime);
	[CLink] public static extern void JPH_BodyInterface_AddTorque(void* bodyInterface, uint32 bodyId, Vector3* torque);
	[CLink] public static extern void JPH_BodyInterface_MoveKinematic(void* bodyInterface, uint32 bodyId, Vector3* position, Quaternion* rotation, float deltaTime);
	[CLink] public static extern void JPH_BodyInterface_ActivateBody(void* bodyInterface, uint32 bodyId);
	[CLink] public static extern void JPH_BodyInterface_DeactivateBody(void* bodyInterface, uint32 bodyId);
	[CLink] public static extern bool JPH_BodyInterface_IsActive(void* bodyInterface, uint32 bodyId);
	[CLink] public static extern uint64 JPH_BodyInterface_GetUserData(void* bodyInterface, uint32 bodyId);
	[CLink] public static extern bool JPH_NarrowPhaseQuery_CastRay(void* query, Vector3* origin, Vector3* direction, RayCastResult* hit, void* bpFilter, void* layerFilter, void* bodyFilter);
}
