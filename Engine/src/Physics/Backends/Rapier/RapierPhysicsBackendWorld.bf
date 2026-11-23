using System;
using System.Collections;

namespace Tallow;

/// One collider part of a body shape, matching TnRapierPart in native/tallow_rapier.h.
[CRepr]
struct RapierShapePart
{
	public int32 kind;
	public float[3] half;
	public float radius;
	public float halfHeight;
	public float[3] position;
	public float[4] rotation;
	public float* vertices;
	public int32 vertexCount;
	public uint32* indices;
	public int32 indexCount;
}

/// One query hit, matching TnRapierHit.
[CRepr]
struct RapierHit
{
	public uint32 body;
	public uint32 subshape;
	public float fraction;
	public float[3] point;
	public float[3] normal;
	public float penetrationDepth;
}

/// One contact event, matching TnRapierContact.
[CRepr]
struct RapierContact
{
	public uint32 bodyA, bodyB;
	public uint64 objectA, objectB;
	public int32 kind;
	public int32 sensor;
	public float[3] point;
	public float[3] normal;
	public float speed;
}

/// One body a character move touched, matching TnRapierCharacterHit.
[CRepr]
struct RapierCharacterHit
{
	public uint32 body;
	public uint32 reserved;
	public uint64 userData;
	public float[3] point;
	public float[3] normal;
}

/// A character's state, matching TnRapierCharacterState.
[CRepr]
struct RapierCharacterState
{
	public float[3] position;
	public float[3] velocity;
	public float[3] groundNormal;
	public float[3] groundVelocity;
	public int32 groundState;
	public uint32 groundBody;
}

/// Rapier3D through Tallow's narrow C ABI over its C bindings (native/tallow_rapier.h and tallow_rapier.cpp). Every
/// call checks tn_rapier_available at the provider level; when this build has no archive the stub answers these and
/// the provider is not registered.
/// One wheel of a Rapier ray-cast vehicle, matching TnRapierWheel.
[CRepr]
struct RapierWheel
{
	public float[3] position;
	public float radius;
	public float width;
	public float restLength;
	public float minLength;
	public float stiffness;
	public float compression;
	public float damping;
	public float maxForce;
	public float maxSteerRadians;
	public float maxBrakeTorque;
	public float maxHandBrakeTorque;
	public int32 driven;
	public int32 steers;
}


/// Soft-body creation settings, matching TnRapierSoftSettings.
[CRepr]
struct RapierSoftSettings
{
	public int32 kind;
	public int32 tear;
	public int32 impacts;
	public int32 visualOnly;
	public float dentDepth;
	public float dentYield;
	public float dentSpeed;
	public float visualSpring;
	public float visualDamping;
	public float damping;
	public float friction;
	public float gravityFactor;
	public int32 iterations;
}

static class Rapier
{
	public const int32 ShapeBox = 0;
	public const int32 ShapeSphere = 1;
	public const int32 ShapeCapsule = 2;
	public const int32 ShapeCylinder = 3;
	public const int32 ShapeConvex = 4;
	public const int32 ShapeTrimesh = 5;

	public const uint32 NoBody = uint32.MaxValue;

	[CLink] public static extern int32 tn_rapier_available();
	[CLink] public static extern char8* tn_rapier_version();
	[CLink] public static extern char8* tn_rapier_build();

	[CLink] public static extern void* tn_rapier_world_new();
	[CLink] public static extern void tn_rapier_world_free(void* world);
	[CLink] public static extern void tn_rapier_set_gravity(void* world, float x, float y, float z);
	[CLink] public static extern void tn_rapier_set_length_scale(void* world, float scale);
	[CLink] public static extern void tn_rapier_step(void* world, float deltaTime, int32* errorMask, float* stepMilliseconds);
	[CLink] public static extern void tn_rapier_clear(void* world);
	[CLink] public static extern void tn_rapier_set_contact_events(void* world, int32 enabled);
	[CLink] public static extern void tn_rapier_set_query_worlds(void* world, uint32 groups);
	[CLink] public static extern int32 tn_rapier_contacts(void* world, void* contacts, int32 capacity);

	[CLink] public static extern uint32 tn_rapier_body_create(void* world, int32 motion, float* position, float* rotation,
		void* parts, int32 partCount, uint32 objectCode, uint32 group, int32 motionClass, uint32 collisionMemberships,
		uint32 collisionFilter, int32 sensor, int32 debris, float friction, float restitution, float linearDamping,
		float angularDamping, float gravityScale, int32 allowSleeping, int32 continuousCollision, int32 freezeRotation,
		int32 overrideMass, float mass, uint64 userData, uint32 wantedId);
	[CLink] public static extern void tn_rapier_body_destroy(void* world, uint32 body);
	[CLink] public static extern void tn_rapier_body_pose(void* world, uint32 body, float* position, float* rotation);
	[CLink] public static extern void tn_rapier_body_set_pose(void* world, uint32 body, float* position, float* rotation, int32 wake);
	[CLink] public static extern void tn_rapier_body_move_kinematic(void* world, uint32 body, float* position, float* rotation, float deltaTime);
	[CLink] public static extern void tn_rapier_body_linvel(void* world, uint32 body, float* velocity);
	[CLink] public static extern void tn_rapier_body_set_linvel(void* world, uint32 body, float* velocity);
	[CLink] public static extern void tn_rapier_body_angvel(void* world, uint32 body, float* velocity);
	[CLink] public static extern void tn_rapier_body_set_angvel(void* world, uint32 body, float* velocity);
	[CLink] public static extern void tn_rapier_body_set_velocities(void* world, uint32 body, float* linear, float* angular);
	[CLink] public static extern void tn_rapier_body_add_force(void* world, uint32 body, float* force);
	[CLink] public static extern void tn_rapier_body_add_force_at(void* world, uint32 body, float* force, float* point);
	[CLink] public static extern void tn_rapier_body_add_torque(void* world, uint32 body, float* torque);
	[CLink] public static extern void tn_rapier_body_add_impulse(void* world, uint32 body, float* impulse);
	[CLink] public static extern void tn_rapier_body_point_velocity(void* world, uint32 body, float* point, float* velocity);
	[CLink] public static extern void tn_rapier_body_set_sleeping(void* world, uint32 body, int32 sleeping);
	[CLink] public static extern int32 tn_rapier_body_is_sleeping(void* world, uint32 body);
	[CLink] public static extern void tn_rapier_body_activate(void* world, uint32 body);
	[CLink] public static extern float tn_rapier_body_mass(void* world, uint32 body);
	[CLink] public static extern uint32 tn_rapier_body_object_code(void* world, uint32 body);
	[CLink] public static extern void tn_rapier_body_set_object_code(void* world, uint32 body, uint32 objectCode,
		uint32 group, int32 motionClass, uint32 collisionMemberships, uint32 collisionFilter);
	[CLink] public static extern void tn_rapier_body_set_enabled(void* world, uint32 body, int32 enabled);
	[CLink] public static extern int32 tn_rapier_body_buoyancy(void* world, uint32 body, float* surfacePoint,
		float* surfaceNormal, float buoyancy, float linearDrag, float angularDrag, float* fluidVelocity, float deltaTime);

	[CLink] public static extern int32 tn_rapier_raycast(void* world, float* origin, float* direction, float maxDistance,
		uint32 layerMask, uint32 ignoreBody, void* hit);
	[CLink] public static extern int32 tn_rapier_raycast_all(void* world, float* origin, float* direction,
		float maxDistance, uint32 layerMask, uint32 ignoreBody, void* hits, int32 capacity);
	[CLink] public static extern int32 tn_rapier_shape_cast(void* world, void* part, float* origin, float* rotation,
		float* displacement, uint32 layerMask, uint32 ignoreBody, void* hit);
	[CLink] public static extern int32 tn_rapier_shape_cast_all(void* world, void* part, float* origin, float* rotation,
		float* displacement, uint32 layerMask, uint32 ignoreBody, void* hits, int32 capacity);
	[CLink] public static extern int32 tn_rapier_overlap(void* world, void* part, float* origin, float* rotation,
		uint32 layerMask, uint32 ignoreBody, void* hits, int32 capacity);
	[CLink] public static extern int32 tn_rapier_check(void* world, void* part, float* origin, float* rotation,
		uint32 layerMask, uint32 ignoreBody);
	[CLink] public static extern int32 tn_rapier_hit_detail(void* world, uint32 body, uint32 subshape, float* point,
		float* normal, int32* part, int32* triangle);

	[CLink] public static extern void* tn_rapier_joint_create(void* world, int32 kind, uint32 bodyA, uint32 bodyB,
		float* anchor, float* axis, float* childAnchor, float* childAxis, float* childNormal, float swingLimitRadians,
		float travel);
	[CLink] public static extern void tn_rapier_joint_destroy(void* world, void* joint);
	[CLink] public static extern void tn_rapier_slider_spring(void* world, void* joint, float stiffness, float damping);
	[CLink] public static extern float tn_rapier_slider_position(void* world, void* joint);
	[CLink] public static extern void tn_rapier_hinge_motor(void* world, void* joint, float speed, float torque,
		float angle, int32 mode, float response, float maximumSpeed);
	[CLink] public static extern float tn_rapier_hinge_angle(void* world, void* joint);

	[CLink] public static extern void* tn_rapier_character_create(void* world, void* parts, int32 partCount,
		float* position, float* rotation, float maxSlopeRadians, float mass, float pushStrength, float supportHeight,
		uint32 objectCode, uint32 group, uint32 collisionMemberships, uint32 collisionFilter, uint64 userData,
		int32 innerBody);
	[CLink] public static extern void tn_rapier_character_destroy(void* world, void* character);
	[CLink] public static extern uint32 tn_rapier_character_inner_body(void* world, void* character);
	[CLink] public static extern void tn_rapier_character_state(void* world, void* character, void* state);
	[CLink] public static extern void tn_rapier_character_move(void* world, void* character, uint32 collisionMemberships,
		uint32 collisionFilter, float* velocity, float deltaTime, float stepHeight, float stepDown, float stepReach,
		void* state);
	[CLink] public static extern void tn_rapier_character_set_state(void* world, void* character,
		uint32 collisionMemberships, uint32 collisionFilter, float* position, float* rotation, float* velocity);
	[CLink] public static extern int32 tn_rapier_character_set_shape(void* world, void* character, void* parts,
		int32 partCount, uint32 collisionMemberships, uint32 collisionFilter, float maxPenetration);
	[CLink] public static extern int32 tn_rapier_character_hits(void* world, void* character, void* hits,
		int32 capacity);

	[CLink] public static extern uint32 tn_rapier_soft_create(void* world, float* positions, int32 vertexCount,
		uint32* triangles, int32 triangleCount, float* pinned, float* stiffness, float* center, float* objectMatrix,
		float totalMass, RapierSoftSettings* settings, uint64 userData);
	[CLink] public static extern void tn_rapier_soft_destroy(void* world, uint32 body);
	[CLink] public static extern void tn_rapier_soft_ignore(void* world, uint32 body, uint32 ignoredBody);
	[CLink] public static extern void tn_rapier_soft_skin(void* world, uint32 body, float* objectMatrix,
		float* objectNext, float step);
	[CLink] public static extern uint32 tn_rapier_soft_count(void* world, uint32 body);
	[CLink] public static extern uint32 tn_rapier_soft_read(void* world, uint32 body, float* positions,
		float* velocities, uint32 capacity);
	[CLink] public static extern void tn_rapier_soft_move_pinned(void* world, uint32 body, uint32* indices,
		float* targets, uint32 count, float* center);
	[CLink] public static extern void tn_rapier_soft_set_positions(void* world, uint32 body, float* positions,
		float* velocities, uint32 count, float* center);
	[CLink] public static extern void tn_rapier_soft_velocity(void* world, uint32 body, float* velocity);
	[CLink] public static extern void tn_rapier_soft_set_velocity(void* world, uint32 body, float* velocity);
	[CLink] public static extern void tn_rapier_soft_impulse(void* world, uint32 body, float* impulse);
	[CLink] public static extern void tn_rapier_soft_force(void* world, uint32 body, float* force);
	[CLink] public static extern void tn_rapier_soft_shift(void* world, uint32 body, float* offset);
	[CLink] public static extern int32 tn_rapier_soft_bounds(void* world, uint32 body, float* minimum,
		float* maximum);
	[CLink] public static extern void tn_rapier_soft_set_pressure(void* world, uint32 body, float amount);
	[CLink] public static extern uint32 tn_rapier_soft_dents(void* world, uint32 body, float* output,
		uint32 capacity);
	[CLink] public static extern uint32 tn_rapier_soft_dent_revision(void* world, uint32 body);
	[CLink] public static extern void tn_rapier_soft_set_dents(void* world, uint32 body, float* dents,
		uint32 count, float* objectMatrix);
	[CLink] public static extern void tn_rapier_soft_damp_wobble(void* world, uint32 body, float rate, float step);
	[CLink] public static extern int32 tn_rapier_soft_torn(void* world, uint32 body);
	[CLink] public static extern int32 tn_rapier_soft_tear(void* world, uint32 body);
	[CLink] public static extern uint32 tn_rapier_soft_float(void* world, uint32 body, float* samples, uint32 nx,
		uint32 nz, float minX, float minZ, float cellX, float cellZ, float bottom, float band, float buoyancy,
		float drag, float gravity, float deltaTime, int32 wake);

	[CLink] public static extern uint32 tn_rapier_rope_create(void* world, float* positions, uint32 count,
		float* pinned, float totalMass, float stretch, float bend, float damping, float radius, float* center,
		uint64 userData);
	[CLink] public static extern void* tn_rapier_rope_tie(void* world, uint32 bodyA, float* pointA, uint32 bodyB,
		float* pointB, float length);
	[CLink] public static extern void tn_rapier_rope_untie(void* world, void* tie);
	[CLink] public static extern float tn_rapier_rope_pull(void* world, void* tie, float step);
	[CLink] public static extern void tn_rapier_rope_wind(void* world, uint32 body, float* wind, float radius,
		float drag, float turbulence, float time, float step);

	[CLink] public static extern void* tn_rapier_vehicle_create(void* world, uint32 chassis, RapierWheel* wheels,
		int32 wheelCount, float* up, float* forward, float maxTorque, float minRPM, float maxRPM, float* gearRatios,
		int32 gearCount, float reverseRatio);
	[CLink] public static extern void tn_rapier_vehicle_destroy(void* world, void* vehicle);
	[CLink] public static extern void tn_rapier_vehicle_set_input(void* world, void* vehicle, float forward,
		float right, float brake, float handBrake);
	[CLink] public static extern int32 tn_rapier_vehicle_wheel_count(void* world, void* vehicle);
	[CLink] public static extern int32 tn_rapier_vehicle_wheel_contact(void* world, void* vehicle, int32 index,
		float* point, float* normal, uint32* body);
	[CLink] public static extern float tn_rapier_vehicle_suspension(void* world, void* vehicle, int32 index);
	[CLink] public static extern float tn_rapier_vehicle_wheel_rotation(void* world, void* vehicle, int32 index);
	[CLink] public static extern float tn_rapier_vehicle_wheel_steer(void* world, void* vehicle, int32 index);
	[CLink] public static extern void tn_rapier_vehicle_wheel_transform(void* world, void* vehicle, int32 index,
		float* matrix, float* spin);
	[CLink] public static extern float tn_rapier_vehicle_engine_rpm(void* world, void* vehicle);
	[CLink] public static extern int32 tn_rapier_vehicle_gear(void* world, void* vehicle);
	[CLink] public static extern float tn_rapier_vehicle_ratio(void* world, void* vehicle);
	[CLink] public static extern float tn_rapier_vehicle_wheel_speed(void* world, void* vehicle, int32 index);

	[CLink] public static extern int32 tn_rapier_collect_geometry(void* world, float* minimum, float* maximum,
		function void(void* user, float* triangle) callback, void* user);
}


/// Builds Rapier collider parts from the engine's neutral ShapeDesc. The parts point into vertex/index lists this
/// object owns, so it must live through the native create call.
class RapierShapeData
{
	List<RapierShapePart> mParts = new .() ~ delete _;
	List<float> mVertices = new .() ~ delete _;
	List<uint32> mIndices = new .() ~ delete _;

	public RapierShapePart* Parts => mParts.Ptr;
	public int32 PartCount => (int32)mParts.Count;

	static RapierShapePart MakePart(int32 kind)
	{
		RapierShapePart part = default;
		part.kind = kind;
		part.rotation[3] = 1;
		return part;
	}

	static void SetPosition(ref RapierShapePart part, Vector3 position)
	{
		part.position[0] = position.x;
		part.position[1] = position.y;
		part.position[2] = position.z;
	}

	static void SetRotation(ref RapierShapePart part, Quaternion rotation)
	{
		part.rotation[0] = rotation.x;
		part.rotation[1] = rotation.y;
		part.rotation[2] = rotation.z;
		part.rotation[3] = rotation.w;
	}

	void AppendVertex(Vector3 vertex, Vector3 scale)
	{
		mVertices.Add(vertex.x * scale.x);
		mVertices.Add(vertex.y * scale.y);
		mVertices.Add(vertex.z * scale.z);
	}

	public this(ShapeDesc desc)
	{
		if (desc.kind == .Box)
		{
			var boxPart = MakePart(Rapier.ShapeBox);
			boxPart.half[0] = desc.halfExtents.x;
			boxPart.half[1] = desc.halfExtents.y;
			boxPart.half[2] = desc.halfExtents.z;
			SetPosition(ref boxPart, desc.center);
			mParts.Add(boxPart);
		}
		else if (desc.kind == .Sphere)
		{
			var sphere = MakePart(Rapier.ShapeSphere);
			sphere.radius = desc.radius;
			SetPosition(ref sphere, desc.center);
			mParts.Add(sphere);
		}
		else if (desc.kind == .Capsule)
		{
			var capsule = MakePart(Rapier.ShapeCapsule);
			capsule.radius = desc.radius;
			capsule.halfHeight = desc.halfHeight;
			SetPosition(ref capsule, desc.center);
			mParts.Add(capsule);
		}
		else if (desc.kind == .ConvexHull)
		{
			let hullMesh = desc.mesh;
			if (hullMesh != null && hullMesh.Vertices.Count >= 4)
			{
				// A few hundred well-spread points describe the hull; more only slows Rapier's builder down.
				let step = Math.Max(1, hullMesh.Vertices.Count / 256);
				for (int i = 0; i < hullMesh.Vertices.Count; i += step)
					AppendVertex(hullMesh.Vertices[i].position, desc.meshScale);
				var hull = MakePart(Rapier.ShapeConvex);
				hull.vertexCount = (int32)mVertices.Count / 3;
				hull.vertices = mVertices.Ptr;
				SetPosition(ref hull, desc.center);
				mParts.Add(hull);
			}
		}
		else if (desc.kind == .Mesh)
		{
			let mesh = desc.mesh;
			if (mesh != null && mesh.Indices.Count >= 3)
			{
				for (let vertex in mesh.Vertices)
					AppendVertex(vertex.position, desc.meshScale);
				mIndices.AddRange(mesh.Indices);
				var trimesh = MakePart(Rapier.ShapeTrimesh);
				trimesh.vertexCount = (int32)mVertices.Count / 3;
				trimesh.vertices = mVertices.Ptr;
				trimesh.indexCount = (int32)mIndices.Count;
				trimesh.indices = mIndices.Ptr;
				SetPosition(ref trimesh, desc.center);
				mParts.Add(trimesh);
			}
		}
		else if (desc.kind == .Compound)
		{
			// Vertices go into one buffer: size it first so the part pointers stay put.
			int32 hullVertices = 0;
			for (int i < desc.hullCount)
				hullVertices += desc.hulls[i].pointCount;
			mVertices.Count = hullVertices * 3;
			int32 vertexAt = 0;
			for (int i < desc.boxCount)
			{
				var boxPart = MakePart(Rapier.ShapeBox);
				let center = desc.boxes[i * 2];
				let half = desc.boxes[i * 2 + 1];
				boxPart.half[0] = half.x;
				boxPart.half[1] = half.y;
				boxPart.half[2] = half.z;
				SetPosition(ref boxPart, center);
				mParts.Add(boxPart);
			}
			for (int i < desc.cylinderCount)
			{
				var cylinder = MakePart(Rapier.ShapeCylinder);
				let source = desc.cylinders[i];
				cylinder.radius = source.radius;
				cylinder.halfHeight = source.halfHeight;
				SetPosition(ref cylinder, source.center);
				SetRotation(ref cylinder, source.rotation);
				mParts.Add(cylinder);
			}
			for (int i < desc.hullCount)
			{
				let source = desc.hulls[i];
				if (source.pointCount < 4)
					continue;
				var hull = MakePart(Rapier.ShapeConvex);
				hull.vertexCount = source.pointCount;
				hull.vertices = mVertices.Ptr + vertexAt * 3;
				for (int p < source.pointCount)
				{
					let point = source.points[p];
					mVertices[vertexAt * 3 + p * 3] = point.x;
					mVertices[vertexAt * 3 + p * 3 + 1] = point.y;
					mVertices[vertexAt * 3 + p * 3 + 2] = point.z;
				}
				vertexAt += source.pointCount;
				SetPosition(ref hull, source.center);
				SetRotation(ref hull, source.rotation);
				mParts.Add(hull);
			}
		}
	}
}

/// The Rapier half of PhysicsWorld: world, bodies, queries, joints and characters through native/tallow_rapier.cpp.
/// Snapshots use PhysicsBackendWorld's generic body-state form until Rapier's own world serialization is verified.
class RapierPhysicsBackendWorld : PhysicsBackendWorld
{
	PhysicsFeatures mFeatures;
	void* mWorld;
	float mLengthScale = 1;
	RapierGeometryExtension mGeometry;
	RapierRagdollExtension mRagdolls;
	RapierVehicleExtension mVehicles;
	RapierSoftBodyExtension mSoftBodies;

	public override PhysicsFeatures Features => mFeatures;
	public override PhysicsGeometryExtension Geometry => mFeatures.Has(.NavigationGeometry) ? mGeometry : null;
	public override PhysicsRagdollExtension Ragdolls => mFeatures.Has(.Ragdolls) ? mRagdolls : null;
	public override PhysicsVehicleExtension Vehicles => mFeatures.Has(.Vehicles) ? mVehicles : null;
	public override PhysicsSoftBodyExtension SoftBodies => mFeatures.Has(.SoftBodies) ? mSoftBodies : null;

	public this(PhysicsWorldSettings settings, PhysicsFeatures features)
	{
		mFeatures = features;
		mLengthScale = Math.Max(settings.lengthScale, 0.00001f);
		ProjectConfig.EnsureLoaded();
		mWorld = Rapier.tn_rapier_world_new();
		if (mWorld != null)
		{
			Rapier.tn_rapier_set_gravity(mWorld, settings.gravity.x, settings.gravity.y, settings.gravity.z);
			Rapier.tn_rapier_set_length_scale(mWorld, mLengthScale);
			Rapier.tn_rapier_set_contact_events(mWorld, settings.contactEvents ? 1 : 0);
			mGeometry = new RapierGeometryExtension(this);
			mRagdolls = new RapierRagdollExtension(this);
			mVehicles = new RapierVehicleExtension(this);
			mSoftBodies = new RapierSoftBodyExtension(this);
		}
	}

	public ~this()
	{
		delete mRagdolls;
		mRagdolls = null;
		delete mVehicles;
		mVehicles = null;
		delete mSoftBodies;
		mSoftBodies = null;
		delete mGeometry;
		mGeometry = null;
		if (mWorld != null)
		{
			Rapier.tn_rapier_world_free(mWorld);
			mWorld = null;
		}
	}

	public void* NativeWorld => mWorld;

	// ---- world ----

	public override void SetGravity(Vector3 gravity)
	{
		if (mWorld != null)
			Rapier.tn_rapier_set_gravity(mWorld, gravity.x, gravity.y, gravity.z);
	}

	public override void SetLengthScale(float scale)
	{
		mLengthScale = Math.Max(mLengthScale * scale, 0.00001f);
		if (mWorld != null)
			Rapier.tn_rapier_set_length_scale(mWorld, mLengthScale);
	}

	public override void Step(float deltaTime, out int32 errorMask, out float stepMilliseconds)
	{
		errorMask = 0;
		stepMilliseconds = 0;
		if (mWorld != null)
			Rapier.tn_rapier_step(mWorld, deltaTime, &errorMask, &stepMilliseconds);
	}

	public override void PrepareQuery(uint32 queryWorldGroups)
	{
		if (mWorld != null)
			Rapier.tn_rapier_set_query_worlds(mWorld, queryWorldGroups);
	}

	public override void BeginContactStep()
	{
	}

	public override int CollectContacts(List<PhysicsContactEvent> into)
	{
		into.Clear();
		if (mWorld == null)
			return 0;
		RapierContact[64] raw = default;
		var count = Rapier.tn_rapier_contacts(mWorld, (void*)&raw, raw.Count);
		RapierContact[] large = null;
		defer delete large;
		RapierContact* events = &raw;
		if (count > raw.Count)
		{
			large = new .[count];
			count = Math.Min(count, Rapier.tn_rapier_contacts(mWorld, (void*)large.Ptr, count));
			events = large.Ptr;
		}
		for (int i < count)
		{
			let source = events[i];
			PhysicsContactEvent neutral = default;
			neutral.bodyA = source.bodyA;
			neutral.bodyB = source.bodyB;
			neutral.objectA = source.objectA;
			neutral.objectB = source.objectB;
			neutral.kind = source.kind;
			neutral.sensor = source.sensor;
			neutral.point = .(source.point[0], source.point[1], source.point[2]);
			neutral.normal = .(source.normal[0], source.normal[1], source.normal[2]);
			neutral.speed = source.speed;
			into.Add(neutral);
		}
		return into.Count;
	}

	protected override void ClearCore()
	{
		if (mWorld != null)
			Rapier.tn_rapier_clear(mWorld);
	}

	// ---- bodies ----

	static void GroupsFor(uint32 objectCode, out uint32 memberships, out uint32 filter, out uint32 group, out int32 motionClass)
	{
		let layer = PhysicsLayerTable.Layer(objectCode);
		memberships = (uint32)1 << layer;
		filter = ProjectConfig.CollisionMask((int32)layer);
		group = PhysicsLayerTable.Group(objectCode);
		motionClass = (int32)PhysicsLayerTable.MotionClass(objectCode);
	}

	protected override uint32 CreateBodyCore(PhysicsBodyDesc desc, ShapeDesc shape)
	{
		if (mWorld == null)
			return uint32.MaxValue;
		let data = scope RapierShapeData(shape);
		if (data.PartCount == 0)
			return uint32.MaxValue;

		GroupsFor(desc.objectCode, let memberships, let filter, let group, let motionClass);
		float[3] position = .(desc.position.x, desc.position.y, desc.position.z);
		float[4] rotation = .(desc.rotation.x, desc.rotation.y, desc.rotation.z, desc.rotation.w);
		let id = Rapier.tn_rapier_body_create(mWorld, (int32)desc.motion, &position, &rotation,
			(void*)data.Parts, data.PartCount, desc.objectCode, group, motionClass, memberships, filter,
			desc.sensor ? 1 : 0, desc.debris ? 1 : 0, desc.friction, desc.restitution, desc.linearDamping,
			desc.angularDamping, desc.gravityFactor, desc.allowSleeping ? 1 : 0,
			desc.continuousCollision ? 1 : 0, desc.freezeRotation ? 1 : 0, desc.overrideMass ? 1 : 0,
			desc.mass, desc.userData, desc.wantedId);
		return id;
	}

	protected override void DestroyBodyCore(uint32 bodyId)
	{
		if (mWorld != null)
			Rapier.tn_rapier_body_destroy(mWorld, bodyId);
	}

	public override void SetBodyPose(uint32 bodyId, Vector3 position, Quaternion rotation, bool activate)
	{
		if (mWorld == null) return;
		float[3] p = .(position.x, position.y, position.z);
		float[4] r = .(rotation.x, rotation.y, rotation.z, rotation.w);
		Rapier.tn_rapier_body_set_pose(mWorld, bodyId, &p, &r, activate ? 1 : 0);
	}

	public override void MoveKinematic(uint32 bodyId, Vector3 position, Quaternion rotation, float deltaTime)
	{
		if (mWorld == null) return;
		float[3] p = .(position.x, position.y, position.z);
		float[4] r = .(rotation.x, rotation.y, rotation.z, rotation.w);
		Rapier.tn_rapier_body_move_kinematic(mWorld, bodyId, &p, &r, deltaTime);
	}

	public override void GetBodyPose(uint32 bodyId, out Vector3 position, out Quaternion rotation)
	{
		position = default;
		rotation = .Identity;
		if (mWorld == null) return;
		float[3] p = default;
		float[4] r = default;
		Rapier.tn_rapier_body_pose(mWorld, bodyId, &p, &r);
		position = .(p[0], p[1], p[2]);
		rotation = .(r[0], r[1], r[2], r[3]);
	}

	public override Vector3 GetLinearVelocity(uint32 bodyId)
	{
		float[3] value = default;
		if (mWorld != null)
			Rapier.tn_rapier_body_linvel(mWorld, bodyId, &value);
		return .(value[0], value[1], value[2]);
	}

	public override void SetLinearVelocity(uint32 bodyId, Vector3 velocity)
	{
		if (mWorld == null) return;
		float[3] value = .(velocity.x, velocity.y, velocity.z);
		Rapier.tn_rapier_body_set_linvel(mWorld, bodyId, &value);
	}

	public override Vector3 GetAngularVelocity(uint32 bodyId)
	{
		float[3] value = default;
		if (mWorld != null)
			Rapier.tn_rapier_body_angvel(mWorld, bodyId, &value);
		return .(value[0], value[1], value[2]);
	}

	public override void SetAngularVelocity(uint32 bodyId, Vector3 velocity)
	{
		if (mWorld == null) return;
		float[3] value = .(velocity.x, velocity.y, velocity.z);
		Rapier.tn_rapier_body_set_angvel(mWorld, bodyId, &value);
	}

	public override void SetBodyVelocities(uint32 bodyId, Vector3 linear, Vector3 angular)
	{
		if (mWorld == null) return;
		float[3] l = .(linear.x, linear.y, linear.z);
		float[3] a = .(angular.x, angular.y, angular.z);
		Rapier.tn_rapier_body_set_velocities(mWorld, bodyId, &l, &a);
	}

	public override void AddForce(uint32 bodyId, Vector3 force)
	{
		if (mWorld == null) return;
		float[3] value = .(force.x, force.y, force.z);
		Rapier.tn_rapier_body_add_force(mWorld, bodyId, &value);
	}

	public override void AddForceAtPosition(uint32 bodyId, Vector3 force, Vector3 point)
	{
		if (mWorld == null) return;
		float[3] f = .(force.x, force.y, force.z);
		float[3] p = .(point.x, point.y, point.z);
		Rapier.tn_rapier_body_add_force_at(mWorld, bodyId, &f, &p);
	}

	public override void AddTorque(uint32 bodyId, Vector3 torque)
	{
		if (mWorld == null) return;
		float[3] value = .(torque.x, torque.y, torque.z);
		Rapier.tn_rapier_body_add_torque(mWorld, bodyId, &value);
	}

	public override void AddImpulse(uint32 bodyId, Vector3 impulse)
	{
		if (mWorld == null) return;
		float[3] value = .(impulse.x, impulse.y, impulse.z);
		Rapier.tn_rapier_body_add_impulse(mWorld, bodyId, &value);
	}

	public override Vector3 GetPointVelocity(uint32 bodyId, Vector3 point)
	{
		float[3] value = default;
		if (mWorld != null)
		{
			float[3] p = .(point.x, point.y, point.z);
			Rapier.tn_rapier_body_point_velocity(mWorld, bodyId, &p, &value);
		}
		return .(value[0], value[1], value[2]);
	}

	public override void SetSleeping(uint32 bodyId, bool sleeping)
	{
		if (mWorld != null)
			Rapier.tn_rapier_body_set_sleeping(mWorld, bodyId, sleeping ? 1 : 0);
	}

	public override void ActivateBody(uint32 bodyId)
	{
		if (mWorld != null)
			Rapier.tn_rapier_body_activate(mWorld, bodyId);
	}

	public override bool IsSleeping(uint32 bodyId) => mWorld != null && Rapier.tn_rapier_body_is_sleeping(mWorld, bodyId) != 0;

	public override void SetObjectCode(uint32 bodyId, uint32 objectCode)
	{
		if (mWorld == null) return;
		GroupsFor(objectCode, let memberships, let filter, let group, let motionClass);
		Rapier.tn_rapier_body_set_object_code(mWorld, bodyId, objectCode, group, motionClass, memberships, filter);
	}

	public override uint32 GetObjectCode(uint32 bodyId) => mWorld != null ? Rapier.tn_rapier_body_object_code(mWorld, bodyId) : 0;

	public override void AddBodyToWorld(uint32 bodyId, bool activate)
	{
		if (mWorld == null) return;
		Rapier.tn_rapier_body_set_enabled(mWorld, bodyId, 1);
		if (activate)
			Rapier.tn_rapier_body_activate(mWorld, bodyId);
	}

	public override void RemoveBodyFromWorld(uint32 bodyId)
	{
		if (mWorld != null)
			Rapier.tn_rapier_body_set_enabled(mWorld, bodyId, 0);
	}

	public override bool ApplyBuoyancy(uint32 bodyId, Vector3 surfacePoint, Vector3 surfaceNormal, float buoyancy, float linearDrag, float angularDrag, Vector3 fluidVelocity, float deltaTime)
	{
		if (mWorld == null)
			return false;
		float[3] point = .(surfacePoint.x, surfacePoint.y, surfacePoint.z);
		float[3] normal = .(surfaceNormal.x, surfaceNormal.y, surfaceNormal.z);
		float[3] flow = .(fluidVelocity.x, fluidVelocity.y, fluidVelocity.z);
		return Rapier.tn_rapier_body_buoyancy(mWorld, bodyId, &point, &normal, buoyancy, linearDrag, angularDrag, &flow, deltaTime) != 0;
	}

	// ---- queries ----

	static void BuildPart(ShapeDesc desc, ref RapierShapePart part)
	{
		part = default;
		part.rotation[3] = 1;
		if (desc.kind == .Box)
		{
			part.kind = Rapier.ShapeBox;
			part.half[0] = desc.halfExtents.x;
			part.half[1] = desc.halfExtents.y;
			part.half[2] = desc.halfExtents.z;
		}
		else if (desc.kind == .Sphere)
		{
			part.kind = Rapier.ShapeSphere;
			part.radius = desc.radius;
		}
		else if (desc.kind == .Capsule)
		{
			part.kind = Rapier.ShapeCapsule;
			part.radius = desc.radius;
			part.halfHeight = desc.halfHeight;
		}
		else
		{
			// Query casts are spheres, capsules and boxes; anything else uses a small sphere.
			part.kind = Rapier.ShapeSphere;
			part.radius = 0.5f;
		}
	}

	public override bool Raycast(Vector3 origin, Vector3 direction, float maxDistance, uint32 layerMask, uint32 ignoreBody, out PhysicsRayHit hit)
	{
		hit = default;
		hit.bodyId = uint32.MaxValue;
		if (mWorld == null) return false;
		float[3] from = .(origin.x, origin.y, origin.z);
		float[3] dir = .(direction.x, direction.y, direction.z);
		RapierHit native = default;
		if (Rapier.tn_rapier_raycast(mWorld, &from, &dir, maxDistance, layerMask, ignoreBody, (void*)&native) == 0)
			return false;
		hit.bodyId = native.body;
		hit.fraction = native.fraction;
		hit.subShapeId = native.subshape;
		return true;
	}

	public override int RaycastAll(Vector3 origin, Vector3 direction, float maxDistance, uint32 layerMask, uint32 ignoreBody, List<PhysicsRayHit> hits)
	{
		hits.Clear();
		if (mWorld == null) return 0;
		float[3] from = .(origin.x, origin.y, origin.z);
		float[3] dir = .(direction.x, direction.y, direction.z);
		RapierHit[32] raw = default;
		var count = Rapier.tn_rapier_raycast_all(mWorld, &from, &dir, maxDistance, layerMask, ignoreBody, (void*)&raw, raw.Count);
		RapierHit[] large = null;
		defer delete large;
		RapierHit* hitsPtr = &raw;
		if (count > raw.Count)
		{
			large = new .[count];
			count = Math.Min(count, Rapier.tn_rapier_raycast_all(mWorld, &from, &dir, maxDistance, layerMask, ignoreBody, (void*)large.Ptr, count));
			hitsPtr = large.Ptr;
		}
		for (int i < count)
		{
			PhysicsRayHit hit = default;
			hit.bodyId = hitsPtr[i].body;
			hit.fraction = hitsPtr[i].fraction;
			hit.subShapeId = hitsPtr[i].subshape;
			hits.Add(hit);
		}
		return hits.Count;
	}

	public override bool CastShape(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, Vector3 displacement, uint32 layerMask, uint32 ignoreBody, out PhysicsShapeHit hit)
	{
		hit = default;
		hit.bodyId = uint32.MaxValue;
		if (mWorld == null) return false;
		RapierShapePart part = default;
		BuildPart(shapeDesc, ref part);
		float[3] from = .(origin.x, origin.y, origin.z);
		float[4] rot = .(rotation.x, rotation.y, rotation.z, rotation.w);
		float[3] move = .(displacement.x, displacement.y, displacement.z);
		RapierHit native = default;
		if (Rapier.tn_rapier_shape_cast(mWorld, (void*)&part, &from, &rot, &move, layerMask, ignoreBody, (void*)&native) == 0)
			return false;
		Convert(native, out hit);
		return true;
	}

	static void Convert(RapierHit native, out PhysicsShapeHit hit)
	{
		hit = default;
		hit.bodyId = native.body;
		hit.fraction = native.fraction;
		hit.point = .(native.point[0], native.point[1], native.point[2]);
		hit.normal = .(native.normal[0], native.normal[1], native.normal[2]);
		hit.penetrationDepth = native.penetrationDepth;
		hit.subShapeId = native.subshape;
	}

	public override int CastShapeAll(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, Vector3 displacement, uint32 layerMask, uint32 ignoreBody, List<PhysicsShapeHit> hits)
	{
		hits.Clear();
		if (mWorld == null) return 0;
		RapierShapePart part = default;
		BuildPart(shapeDesc, ref part);
		float[3] from = .(origin.x, origin.y, origin.z);
		float[4] rot = .(rotation.x, rotation.y, rotation.z, rotation.w);
		float[3] move = .(displacement.x, displacement.y, displacement.z);
		RapierHit[16] raw = default;
		var count = Rapier.tn_rapier_shape_cast_all(mWorld, (void*)&part, &from, &rot, &move, layerMask, ignoreBody, (void*)&raw, raw.Count);
		RapierHit[] large = null;
		defer delete large;
		RapierHit* hitsPtr = &raw;
		if (count > raw.Count)
		{
			large = new .[count];
			count = Math.Min(count, Rapier.tn_rapier_shape_cast_all(mWorld, (void*)&part, &from, &rot, &move, layerMask, ignoreBody, (void*)large.Ptr, count));
			hitsPtr = large.Ptr;
		}
		for (int i < count)
		{
			PhysicsShapeHit hit = default;
			Convert(hitsPtr[i], out hit);
			hits.Add(hit);
		}
		return hits.Count;
	}

	public override int OverlapShape(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, uint32 layerMask, uint32 ignoreBody, List<PhysicsShapeHit> hits, bool analyticContacts)
	{
		hits.Clear();
		if (mWorld == null) return 0;
		RapierShapePart part = default;
		BuildPart(shapeDesc, ref part);
		float[3] from = .(origin.x, origin.y, origin.z);
		float[4] rot = .(rotation.x, rotation.y, rotation.z, rotation.w);
		RapierHit[64] raw = default;
		var count = Rapier.tn_rapier_overlap(mWorld, (void*)&part, &from, &rot, layerMask, ignoreBody, (void*)&raw, raw.Count);
		RapierHit[] large = null;
		defer delete large;
		RapierHit* hitsPtr = &raw;
		if (count > raw.Count)
		{
			large = new .[count];
			count = Math.Min(count, Rapier.tn_rapier_overlap(mWorld, (void*)&part, &from, &rot, layerMask, ignoreBody, (void*)large.Ptr, count));
			hitsPtr = large.Ptr;
		}
		for (int i < count)
		{
			PhysicsShapeHit hit = default;
			Convert(hitsPtr[i], out hit);
			hits.Add(hit);
		}
		return hits.Count;
	}

	public override bool CheckShape(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, uint32 layerMask, uint32 ignoreBody)
	{
		if (mWorld == null) return false;
		RapierShapePart part = default;
		BuildPart(shapeDesc, ref part);
		float[3] from = .(origin.x, origin.y, origin.z);
		float[4] rot = .(rotation.x, rotation.y, rotation.z, rotation.w);
		return Rapier.tn_rapier_check(mWorld, (void*)&part, &from, &rot, layerMask, ignoreBody) != 0;
	}

	public override bool HitDetail(uint32 bodyId, uint32 subShapeId, Vector3 point, out PhysicsHitDetail detail)
	{
		detail = default;
		if (mWorld == null) return false;
		float[3] at = .(point.x, point.y, point.z);
		float[3] normal = default;
		int32 part = -1;
		int32 triangle = -1;
		if (Rapier.tn_rapier_hit_detail(mWorld, bodyId, subShapeId, &at, &normal, &part, &triangle) == 0)
			return false;
		detail.normal = .(normal[0], normal[1], normal[2]);
		detail.part = part;
		detail.triangle = triangle;
		return true;
	}

	// ---- joints ----

	public override void* CreateJoint(PhysicsJointDesc desc)
	{
		if (mWorld == null) return null;
		float[3] anchor = .(desc.anchor.x, desc.anchor.y, desc.anchor.z);
		float[3] axis = .(desc.axis.x, desc.axis.y, desc.axis.z);
		float[3] childAnchor = .(desc.childAnchor.x, desc.childAnchor.y, desc.childAnchor.z);
		float[3] childAxis = .(desc.childAxis.x, desc.childAxis.y, desc.childAxis.z);
		float[3] childNormal = .(desc.childNormal.x, desc.childNormal.y, desc.childNormal.z);
		int32 kind = desc.kind == .Ball ? 0 : (desc.kind == .Hinge ? 1 : 2);
		return Rapier.tn_rapier_joint_create(mWorld, kind, desc.bodyA, desc.bodyB, &anchor, &axis, &childAnchor,
			&childAxis, &childNormal, desc.swingLimitRadians, desc.travel);
	}

	public override void DestroyJoint(void* joint)
	{
		if (mWorld != null && joint != null)
			Rapier.tn_rapier_joint_destroy(mWorld, joint);
	}

	public override void SetSliderSpring(void* joint, float stiffness, float damping)
	{
		if (mWorld != null && joint != null)
			Rapier.tn_rapier_slider_spring(mWorld, joint, stiffness, damping);
	}

	public override float SliderPosition(void* joint) => mWorld != null && joint != null ? Rapier.tn_rapier_slider_position(mWorld, joint) : 0;

	public override void SetHingeMotor(void* joint, float speed, float torque, float angle, int32 mode, float response, float maximumSpeed)
	{
		if (mWorld != null && joint != null)
			Rapier.tn_rapier_hinge_motor(mWorld, joint, speed, torque, angle, mode, response, maximumSpeed);
	}

	public override float HingeAngle(void* joint) => mWorld != null && joint != null ? Rapier.tn_rapier_hinge_angle(mWorld, joint) : 0;

	// ---- characters ----

	public override void* CreateCharacter(PhysicsCharacterDesc desc, ShapeDesc shape)
	{
		if (mWorld == null) return null;
		let data = scope RapierShapeData(shape);
		if (data.PartCount != 1)
			return null;
		GroupsFor(desc.objectCode, let memberships, let filter, let group, let motionClass);
		float[3] position = .(desc.position.x, desc.position.y, desc.position.z);
		float[4] rotation = .(desc.rotation.x, desc.rotation.y, desc.rotation.z, desc.rotation.w);
		return Rapier.tn_rapier_character_create(mWorld, (void*)data.Parts, 1, &position, &rotation, desc.maxSlopeRadians,
			desc.mass, desc.pushStrength, desc.supportHeight, desc.objectCode, group, memberships, filter,
			desc.userData, desc.innerBody ? 1 : 0);
	}

	public override void DestroyCharacter(void* character)
	{
		if (mWorld != null && character != null)
			Rapier.tn_rapier_character_destroy(mWorld, character);
	}

	public override uint32 CharacterInnerBody(void* character) => mWorld != null && character != null ? Rapier.tn_rapier_character_inner_body(mWorld, character) : uint32.MaxValue;

	public override CharacterState GetCharacterState(void* character)
	{
		CharacterState state = default;
		if (mWorld == null || character == null) return state;
		RapierCharacterState native = default;
		Rapier.tn_rapier_character_state(mWorld, character, (void*)&native);
		return Convert(native);
	}

	static CharacterState Convert(RapierCharacterState native)
	{
		CharacterState state = default;
		state.position = .(native.position[0], native.position[1], native.position[2]);
		state.velocity = .(native.velocity[0], native.velocity[1], native.velocity[2]);
		state.groundNormal = .(native.groundNormal[0], native.groundNormal[1], native.groundNormal[2]);
		state.groundVelocity = .(native.groundVelocity[0], native.groundVelocity[1], native.groundVelocity[2]);
		state.groundState = native.groundState;
		state.groundBody = native.groundBody;
		return state;
	}

	public override CharacterState MoveCharacter(void* character, uint32 objectCode, Vector3 velocity, float deltaTime, float stepHeight, float stepReach, bool soft)
	{
		CharacterState state = default;
		if (mWorld == null || character == null) return state;
		GroupsFor(objectCode, let memberships, let filter, let group, let motionClass);
		float[3] v = .(velocity.x, velocity.y, velocity.z);
		RapierCharacterState native = default;
		Rapier.tn_rapier_character_move(mWorld, character, memberships, filter, &v, deltaTime, Math.Max(stepHeight, 0),
			Math.Max(stepHeight, 0), Math.Max(stepReach, 0.15f), (void*)&native);
		return Convert(native);
	}

	public override void SetCharacterState(void* character, uint32 objectCode, Vector3 position, Quaternion rotation, Vector3 velocity, bool soft)
	{
		if (mWorld == null || character == null) return;
		GroupsFor(objectCode, let memberships, let filter, let group, let motionClass);
		float[3] p = .(position.x, position.y, position.z);
		float[4] r = .(rotation.x, rotation.y, rotation.z, rotation.w);
		float[3] v = .(velocity.x, velocity.y, velocity.z);
		Rapier.tn_rapier_character_set_state(mWorld, character, memberships, filter, &p, &r, &v);
	}

	public override bool SetCharacterShape(void* character, uint32 objectCode, ShapeDesc shape, float maxPenetration, bool soft)
	{
		if (mWorld == null || character == null) return false;
		let data = scope RapierShapeData(shape);
		if (data.PartCount != 1)
			return false;
		GroupsFor(objectCode, let memberships, let filter, let group, let motionClass);
		return Rapier.tn_rapier_character_set_shape(mWorld, character, (void*)data.Parts, 1, memberships, filter, maxPenetration) != 0;
	}

	public override int CharacterHits(void* character, Span<CharacterHit> hits)
	{
		if (mWorld == null || character == null || hits.Length == 0)
			return 0;
		RapierCharacterHit[] native = new .[hits.Length];
		defer delete native;
		let count = Rapier.tn_rapier_character_hits(mWorld, character, (void*)native.Ptr, (int32)hits.Length);
		for (int i < count)
		{
			CharacterHit hit = default;
			hit.body = native[i].body;
			hit.reserved = native[i].reserved;
			hit.userData = native[i].userData;
			hit.point = .(native[i].point[0], native[i].point[1], native[i].point[2]);
			hit.normal = .(native[i].normal[0], native[i].normal[1], native[i].normal[2]);
			hits[i] = hit;
		}
		return count;
	}
}

/// Rapier's static collision triangles for navigation baking: every static collider's shape tessellated at its pose.
class RapierGeometryExtension : PhysicsGeometryExtension
{
	RapierPhysicsBackendWorld mBackend;

	public this(RapierPhysicsBackendWorld backend)
	{
		mBackend = backend;
	}

	static void Append(void* user, float* triangle)
	{
		let triangles = (List<float>)Internal.UnsafeCastToObject(user);
		for (int i < 9)
			triangles.Add(triangle[i]);
	}

	public override bool Collect(Vector3 min, Vector3 max, List<float> triangles)
	{
		triangles.Clear();
		if (mBackend == null || mBackend.NativeWorld == null)
			return false;
		float[3] lo = .(min.x, min.y, min.z);
		float[3] hi = .(max.x, max.y, max.z);
		return Rapier.tn_rapier_collect_geometry(mBackend.NativeWorld, &lo, &hi, => Append,
			Internal.UnsafeCastToPtr(triangles)) != 0;
	}
}
