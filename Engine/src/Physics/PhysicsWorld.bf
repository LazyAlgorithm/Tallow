using System;
using System.Collections;

namespace Tallow;

/// Full dynamic state of a body; what the network layer sends and rewinds to.
[CRepr]
struct BodyState
{
	/// Where the body is, in the world.
	public Vector3 position;
	/// How the body is turned.
	public Quaternion rotation;
	/// How fast it moves, in metres a second.
	public Vector3 linearVelocity;
	/// How fast it spins, in radians a second about each world axis.
	public Vector3 angularVelocity;
	// Motor state is separate from physical velocity, including during rigidbody handoffs.
	public Vector4 prediction0, prediction1;
}

/// What a ray hit: the object, the point, and how far along the ray.
struct RaycastHit
{
	/// The object hit (an object with a collider).
	public GameObject gameObject;
	/// Where the ray hit, in the world.
	public Vector3 point;
	/// How far along the ray the hit is.
	public float distance;
}

/// Closest swept-volume contact. Distance measures travel of the shape's center,
/// point is on the contacted surface, and normal points out of that surface.
struct ShapeCastHit
{
	/// The object hit.
	public GameObject gameObject;
	/// Where the shapes touch, in the world.
	public Vector3 point;
	/// Which way the surface faces at the hit.
	public Vector3 normal;
	/// How far along the sweep the hit is (0 for an overlap).
	public float distance;
	/// For an overlap: how deep the shapes are inside each other.
	public float penetrationDepth;
	/// The physics body hit.
	public uint32 bodyId;
}

/// Description used to build a collision shape. Sizes are already scaled to world units.
struct CompoundCylinder
{
	/// The cylinder's centre, relative to the body.
	public Vector3 center;
	/// The cylinder's radius, and half its height.
	public float radius, halfHeight;
	/// How the cylinder is turned, relative to the body.
	public Quaternion rotation;
}

/// A convex part of a compound shape: the hull round a set of points.
struct CompoundHull
{
	/// The hull's centre, relative to the body.
	public Vector3 center;
	/// How the hull is turned, relative to the body.
	public Quaternion rotation;
	/// The points the hull is wrapped round.
	public Vector3* points;
	/// How many points there are.
	public int32 pointCount;
	/// How much the hull's corners are rounded (a little makes collisions steadier).
	public float convexRadius;
}

/// What a collider gives the physics world to make its shape from.
struct ShapeDesc
{
	/// Which kind of shape.
	public enum Kind { Box, Sphere, Capsule, Mesh, ConvexHull, Compound }
	/// Compound: boxCount pairs of (center, half extents).
	public Vector3* boxes;
	public int32 boxCount;
	public CompoundCylinder* cylinders;
	public int32 cylinderCount;
	public CompoundHull* hulls;
	public int32 hullCount;
	/// Which kind of shape this is.
	public Kind kind;
	/// A box's half-size on each axis.
	public Vector3 halfExtents;
	/// Box only: how far the edges and corners are rounded. 0 uses a small default.
	public float convexRadius;
	/// A sphere's or capsule's radius.
	public float radius;
	/// Half the height of a capsule's straight part.
	public float halfHeight;
	/// The shape's centre, relative to the object.
	public Vector3 center;
	/// The mesh of a mesh or convex hull shape.
	public Mesh mesh;
	/// How the mesh is scaled.
	public Vector3 meshScale;
}

/// One Jolt simulation per scene. Bodies are created by Rigidbody and Collider components while playing.
///
/// Jolt is built with cross-platform determinism, so replaying the same inputs from the same
/// state gives the same result, which is what client-side prediction relies on.
class PhysicsWorld
{
	/// Overlap queries work out the contacts of a sphere or capsule with a box directly where they can (the shape's
	/// middle inside the box), and with Jolt's general solver otherwise. Off, always the general solver, for comparing.
	public bool useAnalyticOverlapContacts = true;

	int32 mBodyCapacity = 16384, mBodyPairCapacity = 65536, mContactCapacity = 16384;
	// The step errors already logged, so each kind is logged once.
	int32 mReportedStepErrors;

	/// How many bodies the world holds at most, how many pairs of them can touch at once, and how many contacts the
	/// solver handles in a step (ConfigureCapacity).
	public int32 BodyCapacity => mBodyCapacity;
	public int32 BodyPairCapacity => mBodyPairCapacity;
	public int32 ContactCapacity => mContactCapacity;
	/// What ran out in the last Step, as Jolt's bits (0 when nothing did): 1 the contact cache, 2 the body pairs, 4 the
	/// contacts. Contacts are missing from that step.
	public int32 LastStepError { get; private set; }

	/// Sets the capacities, before the world's first body (or query) creates it. False when it already exists or a
	/// number is not positive.
	public bool ConfigureCapacity(int32 bodies, int32 bodyPairs, int32 contacts)
	{
		if (mSystem != null || bodies <= 0 || bodyPairs <= 0 || contacts <= 0) return false;
		mBodyCapacity = bodies;
		mBodyPairCapacity = bodyPairs;
		mContactCapacity = contacts;
		return true;
	}

	static ProfilerMarker sOverlapProfile = .("Physics.Overlap", .Physics);
	static ProfilerMarker sOverlapNativeProfile = .("Physics.Overlap.NativeContacts", .Physics);
	// Shown only with native built with TALLOW_PROFILE_CONVEX_QUERIES (docs/profiler.md).
	static ProfilerMarker sConvexProfile = .("Physics.Overlap.ConvexPair", .Physics);
	static ProfilerMarker sEPAProfile = .("Physics.Overlap.EPA", .Physics);

	/// Where native opens a convex pair's marker (marker 1: the EPA part of it).
	static void BeginConvexProfile(int32 marker)
	{
		if (marker == 1)
			sEPAProfile.Begin();
		else
			sConvexProfile.Begin();
	}

	/// Smallest collision half extent, in world units; lower for miniature scenes.
	public float MinimumShapeExtent = 0.01f;
	float mLengthScale = 1;
	/// Scale contact and sleeping distances/velocities while leaving seconds and angular tolerances alone.
	public float LengthScale
	{
		get => mLengthScale;
		set
		{
			let next = Math.Max(value, 0.00001f);
			if (mSystem != null)
				Jolt.tn_physics_scale_tolerances(mSystem, next / mLengthScale);
			mLengthScale = next;
		}
	}

	/// Whether bodies of objects outside the scene's world state are left out (true for a scene's own world). A
	/// world made to bake navigation for a chosen state turns it off and picks its objects itself.
	public bool FollowsWorldStates = true;

	class Entry
	{
		public uint32 bodyId;
		public Transform transform;
		public bool dynamic;
		public bool kinematic;
		public uint32 lastVersion;
		public void* shape;
		/// The body belongs to a character controller, which moves and destroys it; it is listed so queries can name its object.
		public bool external;
		/// Taken out of the simulation because its object is not in the active world state.
		public bool outOfWorld;
	}

	// Jolt's object layer for a body is its motion class times 32 plus its GameObject's layer (ProjectConfig): the
	// class decides what moves against what, the layer which of the project's layers collide.
	const uint32 LayerStatic = 0;
	const uint32 LayerMoving = 1;
	/// Debris rests on scenery but passes through everything that moves, characters included.
	const uint32 LayerDebris = 2;
	const uint32 LayersPerClass = (uint32)ProjectConfig.MaxLayers;

	static uint32 ObjectLayer(uint32 motionClass, int32 layer) => motionClass * LayersPerClass + (uint32)Math.Clamp(layer, 0, ProjectConfig.MaxLayers - 1);
	static uint32 ObjectLayer(uint32 motionClass, Transform transform) => ObjectLayer(motionClass, transform != null ? transform.GameObject.Layer : 0);

	static bool sJoltInitialized;
	static void* sJobSystem;
	static int sWorldCount;

	void* mSystem;
	void* mBodyInterface;
	List<Entry> mEntries = new .() ~ DeleteContainerAndItems!(_);
	List<void*> mCharacters = new .() ~ delete _;
	/// Every live character controller in this world, for the soft push between characters.
	public List<CharacterController> Controllers = new .() ~ delete _;
	Dictionary<uint32, Entry> mByBody = new .() ~ delete _;
	bool mBroadPhaseDirty;
	void* mSphereQueryShape;
	void* mCapsuleQueryShape;
	void* mBoxQueryShape;
	float mSphereQueryRadius = -1;
	Vector2 mCapsuleQuerySize = .(-1, -1);
	Vector3 mBoxQuerySize = .(-1, -1, -1);
	List<Jolt.ShapeHit> mOverlapHits = new .() ~ delete _;


	/// Gravity, in metres a second squared.
	public Vector3 Gravity = .(0, -9.81f, 0);
	/// How many bodies are in the world.
	public int32 BodyCount => (int32)mEntries.Count;
	/// How many joints are in the world.
	public int32 JointCount => (int32)mJoints.Count;

	/// An empty world. A scene makes its own when play starts.
	public this()
	{
		sWorldCount++;
	}

	public ~this()
	{
		Clear();
		if (mSphereQueryShape != null)
			Jolt.JPH_Shape_Destroy(mSphereQueryShape);
		if (mCapsuleQueryShape != null)
			Jolt.JPH_Shape_Destroy(mCapsuleQueryShape);
		if (mBoxQueryShape != null)
			Jolt.JPH_Shape_Destroy(mBoxQueryShape);
		if (mSystem != null)
		{
			Jolt.tn_joint_filters_clear(mSystem);
			SoftBody.[Friend]tn_soft_world_destroyed(mSystem);
			Jolt.JPH_PhysicsSystem_Destroy(mSystem);
		}
		sWorldCount--;
	}

	void EnsureCreated()
	{
		if (mSystem != null)
			return;
		if (!sJoltInitialized)
		{
			Jolt.JPH_Init();
			Jolt.tn_physics_install_query_dispatch();
			Jolt.JobConfig config;
			config.maxJobs = 2048;
			config.maxBarriers = 8;
#if BF_PLATFORM_WASM
			// A web page has one thread: jobs run on it while the physics step waits for them.
			config.numThreads = 0;
#else
			config.numThreads = 3;
#endif
			sJobSystem = Jolt.JPH_JobSystemThreadPool_Create(&config);
			sJoltInitialized = true;
		}
		ProjectConfig.EnsureLoaded();
		let layerCount = 3 * LayersPerClass;
		let broadPhase = Jolt.JPH_BroadPhaseLayerInterfaceTable_Create(layerCount, 2);
		for (int32 layer < ProjectConfig.MaxLayers)
		{
			Jolt.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broadPhase, ObjectLayer(LayerStatic, layer), 0);
			Jolt.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broadPhase, ObjectLayer(LayerMoving, layer), 1);
			Jolt.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broadPhase, ObjectLayer(LayerDebris, layer), 1);
		}
		let pairFilter = Jolt.JPH_ObjectLayerPairFilterTable_Create(layerCount);
		// What moves against what (static-moving, moving-moving, static-debris), for each pair of the project's
		// layers that collide.
		uint32[3][2] classes = .(.(LayerStatic, LayerMoving), .(LayerMoving, LayerMoving), .(LayerStatic, LayerDebris));
		for (int32 a < ProjectConfig.MaxLayers)
		{
			for (int32 b < ProjectConfig.MaxLayers)
			{
				if (!ProjectConfig.LayersCollide(a, b))
					continue;
				for (let pair in classes)
					Jolt.JPH_ObjectLayerPairFilterTable_EnableCollision(pairFilter, ObjectLayer(pair[0], a), ObjectLayer(pair[1], b));
			}
		}
		let objectVsBroadPhase = Jolt.JPH_ObjectVsBroadPhaseLayerFilterTable_Create(broadPhase, 2, pairFilter, layerCount);

		Jolt.PhysicsSystemSettings settings = default;
		settings.maxBodies = (uint32)mBodyCapacity;
		settings.numBodyMutexes = 0;
		settings.maxBodyPairs = (uint32)mBodyPairCapacity;
		settings.maxContactConstraints = (uint32)mContactCapacity;
		settings.broadPhaseLayerInterface = broadPhase;
		settings.objectLayerPairFilter = pairFilter;
		settings.objectVsBroadPhaseLayerFilter = objectVsBroadPhase;
		mSystem = Jolt.JPH_PhysicsSystem_Create(&settings);
		Jolt.tn_physics_scale_tolerances(mSystem, mLengthScale);
		mBodyInterface = Jolt.JPH_PhysicsSystem_GetBodyInterface(mSystem);
	}

	/// Removes every body, joint and character.
	public void Clear()
	{
		// Characters go first: each owns an inner body that is listed below as an external entry.
		for (let character in mCharacters)
			Jolt.tn_character_destroy(character, mSystem);
		mCharacters.Clear();
		mCharacterOwners.Clear();
		Controllers.Clear();
		for (let entry in mEntries)
		{
			if (entry.external)
				continue;
			if (entry.outOfWorld)
				Jolt.JPH_BodyInterface_AddBody(mBodyInterface, entry.bodyId, Jolt.DontActivate);
			Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, entry.bodyId);
			Jolt.JPH_Shape_Destroy(entry.shape);
		}
		ClearAndDeleteItems!(mEntries);
		mByBody.Clear();
		for (let (bodyId, soft) in mSoftBodies)
		{
			Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, bodyId);
			soft.[Friend]mBody = uint32.MaxValue;
			soft.[Friend]mWorld = null;
		}
		mSoftBodies.Clear();
		for (let rope in mRopes)
		{
			if (rope.[Friend]mTie != null)
				Rope.[Friend]tn_rope_untie(mSystem, rope.[Friend]mTie);
			Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, rope.BodyId);
			rope.[Friend]mTie = null;
			rope.[Friend]mBody = uint32.MaxValue;
			rope.[Friend]mWorld = null;
		}
		mRopes.Clear();
	}

	void* CreateShape(ShapeDesc desc)
	{
		void* shape = null;
		switch (desc.kind)
		{
		case .Box:
			var half = Vector3.Max(desc.halfExtents, .(MinimumShapeExtent));
			let smallest = Math.Min(half.x, Math.Min(half.y, half.z));
			let convex = desc.convexRadius > 0 ? Math.Min(desc.convexRadius, smallest) : Math.Min(0.05f, smallest * 0.5f);
			shape = Jolt.JPH_BoxShape_Create(&half, convex);
		case .Sphere:
			shape = Jolt.JPH_SphereShape_Create(Math.Max(desc.radius, MinimumShapeExtent));
		case .Capsule:
			shape = Jolt.JPH_CapsuleShape_Create(Math.Max(desc.halfHeight, MinimumShapeExtent), Math.Max(desc.radius, MinimumShapeExtent));
		case .Compound:
			if (desc.boxCount <= 0 && desc.cylinderCount <= 0 && desc.hullCount <= 0)
				return null;
			let compound = Jolt.JPH_StaticCompoundShapeSettings_Create();
			var identity = Quaternion.Identity;
			for (int i < desc.boxCount)
			{
				var boxCenter = desc.boxes[i * 2];
				var boxHalf = Vector3.Max(desc.boxes[i * 2 + 1], .(MinimumShapeExtent));
				let boxShape = Jolt.JPH_BoxShape_Create(&boxHalf, Math.Min(0.02f, Math.Min(boxHalf.x, Math.Min(boxHalf.y, boxHalf.z)) * 0.5f));
				Jolt.JPH_CompoundShapeSettings_AddShape2(compound, &boxCenter, &identity, boxShape, (uint32)i);
				// The compound keeps its own reference to each part.
				Jolt.JPH_Shape_Destroy(boxShape);
			}
			for (int i = 0; i < desc.cylinderCount; i++)
			{
				var cylinder = desc.cylinders[i];
				let cylinderShape = Jolt.JPH_CylinderShape_Create(Math.Max(cylinder.halfHeight, MinimumShapeExtent), Math.Max(cylinder.radius, MinimumShapeExtent));
				Jolt.JPH_CompoundShapeSettings_AddShape2(compound, &cylinder.center, &cylinder.rotation, cylinderShape, (uint32)(desc.boxCount + i));
				Jolt.JPH_Shape_Destroy(cylinderShape);
			}
			for (int i = 0; i < desc.hullCount; i++)
			{
				var hull = desc.hulls[i];
				if (hull.pointCount < 4) continue;
				let settings = Jolt.JPH_ConvexHullShapeSettings_Create(hull.points, (uint32)hull.pointCount, Math.Max(0, hull.convexRadius));
				let hullShape = Jolt.JPH_ConvexHullShapeSettings_CreateShape(settings);
				Jolt.JPH_ShapeSettings_Destroy(settings);
				if (hullShape != null)
				{
					Jolt.JPH_CompoundShapeSettings_AddShape2(compound, &hull.center, &hull.rotation, hullShape, (uint32)(desc.boxCount + desc.cylinderCount + i));
					Jolt.JPH_Shape_Destroy(hullShape);
				}
			}
			shape = Jolt.JPH_StaticCompoundShape_Create(compound);
			Jolt.JPH_ShapeSettings_Destroy(compound);
		case .ConvexHull:
			let hullMesh = desc.mesh;
			if (hullMesh == null || hullMesh.Vertices.Count < 4)
				return null;
			// A few hundred well-spread points describe the hull; more only slows Jolt's builder down.
			let step = Math.Max(1, hullMesh.Vertices.Count / 256);
			List<Vector3> points = scope .();
			for (int i = 0; i < hullMesh.Vertices.Count; i += step)
				points.Add(hullMesh.Vertices[i].position * desc.meshScale);
			let hullSettings = Jolt.JPH_ConvexHullShapeSettings_Create(points.Ptr, (uint32)points.Count, 0.02f);
			shape = Jolt.JPH_ConvexHullShapeSettings_CreateShape(hullSettings);
			Jolt.JPH_ShapeSettings_Destroy(hullSettings);
		case .Mesh:
			let mesh = desc.mesh;
			if (mesh == null || mesh.Indices.Count < 3)
				return null;
			// Imported room meshes can exceed the default 1 MB Windows thread stack.
			Vector3[] vertices = new .[mesh.Vertices.Count];
			defer delete vertices;
			for (int i < mesh.Vertices.Count)
				vertices[i] = mesh.Vertices[i].position * desc.meshScale;
			let triangleCount = mesh.Indices.Count / 3;
			Jolt.IndexedTriangle[] triangles = new .[triangleCount];
			defer delete triangles;
			for (int i < triangleCount)
			{
				// Keep the mesh's own index order: Jolt takes (v2 - v1) x (v3 - v1) as the front of a
				// triangle, which is the side Tallow's meshes face. Reversing it makes every
				// triangle a back face, and Jolt lets bodies pass through back faces.
				triangles[i].i1 = mesh.Indices[i * 3];
				triangles[i].i2 = mesh.Indices[i * 3 + 1];
				triangles[i].i3 = mesh.Indices[i * 3 + 2];
				triangles[i].materialIndex = 0;
				triangles[i].userData = 0;
			}
			let settings = Jolt.JPH_MeshShapeSettings_Create2(vertices.Ptr, (uint32)vertices.Count, triangles.Ptr, (uint32)triangleCount);
			shape = Jolt.JPH_MeshShapeSettings_CreateShape(settings);
			Jolt.JPH_ShapeSettings_Destroy(settings);
		}
		if (shape != null && desc.center.LengthSquared > 1.0e-10f)
		{
			var center = desc.center;
			var identity = Quaternion.Identity;
			let offset = Jolt.JPH_RotatedTranslatedShape_Create(&center, &identity, shape);
			Jolt.JPH_Shape_Destroy(shape);
			shape = offset;
		}
		return shape;
	}

	/// Creates a body that follows (static/kinematic) or drives (dynamic) the given transform.
	/// Returns the body id, or uint32.MaxValue on failure.
	public uint32 CreateBody(Transform transform, ShapeDesc desc, Rigidbody rigidbody)
	{
		EnsureCreated();
		let shape = CreateShape(desc);
		if (shape == null)
			return uint32.MaxValue;

		var position = transform.Position;
		var rotation = transform.Rotation;
		int32 motion = Jolt.MotionStatic;
		if (rigidbody != null)
			motion = rigidbody.isKinematic ? Jolt.MotionKinematic : Jolt.MotionDynamic;
		// Mesh shapes cannot be dynamic in Jolt.
		if (desc.kind == .Mesh && motion == Jolt.MotionDynamic)
			motion = Jolt.MotionStatic;
		let debris = rigidbody != null && rigidbody.debris && motion != Jolt.MotionStatic;

		// Keep the inertia eigensolve away from Jolt's absolute near-zero fallback in miniature worlds.
		let massScale = Math.Min(100000000.0f, Math.Max(1.0f, 1.0f / (LengthScale * LengthScale)));
		let settings = Jolt.JPH_BodyCreationSettings_Create3(shape, &position, &rotation, motion, ObjectLayer(motion == Jolt.MotionStatic ? LayerStatic : (debris ? LayerDebris : LayerMoving), transform));
		Jolt.JPH_BodyCreationSettings_SetUserData(settings, (uint64)transform.GameObject.Id);
		if (rigidbody != null)
		{
			Jolt.JPH_BodyCreationSettings_SetFriction(settings, rigidbody.friction);
			Jolt.JPH_BodyCreationSettings_SetRestitution(settings, rigidbody.bounciness);
			Jolt.JPH_BodyCreationSettings_SetLinearDamping(settings, rigidbody.linearDamping);
			Jolt.JPH_BodyCreationSettings_SetAngularDamping(settings, rigidbody.angularDamping);
			Jolt.JPH_BodyCreationSettings_SetGravityFactor(settings, rigidbody.useGravity ? Math.Max(0, rigidbody.gravityScale) : 0.0f);
			Jolt.JPH_BodyCreationSettings_SetAllowSleeping(settings, rigidbody.allowSleeping);
			if (rigidbody.continuousCollision)
				Jolt.JPH_BodyCreationSettings_SetMotionQuality(settings, 1);
			if (rigidbody.freezeRotation)
				Jolt.JPH_BodyCreationSettings_SetAllowedDOFs(settings, 0b000111);
			if (motion == Jolt.MotionDynamic)
			{
				Jolt.MassProperties mass = default;
				mass.mass = Math.Max(rigidbody.mass, 0.001f) * massScale;
				Jolt.JPH_BodyCreationSettings_SetOverrideMassProperties(settings, 1);
				Jolt.JPH_BodyCreationSettings_SetMassPropertiesOverride(settings, &mass);
			}
		}
		let bodyId = Jolt.JPH_BodyInterface_CreateAndAddBody(mBodyInterface, settings, Jolt.Activate);
		Jolt.JPH_BodyCreationSettings_Destroy(settings);
		if (bodyId == uint32.MaxValue)
		{
			// A full native body pool must not leave an invalid ID in the world's tracking maps.
			Jolt.JPH_Shape_Destroy(shape);
			return bodyId;
		}
		if (motion == Jolt.MotionDynamic && massScale > 1 && bodyId != uint32.MaxValue)
			Jolt.tn_physics_rescale_body_mass(mSystem, bodyId, Math.Max(rigidbody.mass, 0.001f));

		let entry = new Entry();
		entry.bodyId = bodyId;
		entry.transform = transform;
		entry.dynamic = motion == Jolt.MotionDynamic;
		entry.kinematic = motion == Jolt.MotionKinematic;
		entry.lastVersion = transform.Version;
		entry.shape = shape;
		mEntries.Add(entry);
		mByBody[bodyId] = entry;
		mBroadPhaseDirty = true;
		if (debris)
		{
			mDebris.Add(bodyId);
			Jolt.tn_physics_set_debris(bodyId, true);
		}
		// An object outside the active world state is kept out of the simulation until that state is active.
		if (FollowsWorldStates && !transform.GameObject.InActiveWorld)
		{
			Jolt.JPH_BodyInterface_RemoveBody(mBodyInterface, bodyId);
			entry.outOfWorld = true;
		}
		return bodyId;
	}

	HashSet<uint32> mDebris = new .() ~ delete _;
	uint64 mJointSequence;
	List<(void* joint, uint32 a, uint32 b, uint64 generation)> mJoints = new .() ~ delete _;

	/// True for a body made by a Rigidbody with Debris on.
	public bool IsDebris(uint32 bodyId) => mDebris.Contains(bodyId);

	/// Joins two bodies at a point in world space. With swingLimitDegrees above zero the second body can swing no
	/// further than that from the axis, like a shoulder; with zero it is a free ball joint. Returns null if either
	/// body does not exist. The Joint component does this for you.
	public void* CreateJoint(uint32 bodyA, uint32 bodyB, Vector3 anchor, Vector3 axis, float swingLimitDegrees)
	{
		if (mSystem == null || !mByBody.ContainsKey(bodyA) || !mByBody.ContainsKey(bodyB) || bodyA == bodyB)
			return null;
		var point = anchor;
		var direction = axis.LengthSquared > 1.0e-8f ? axis.Normalized : Vector3.Up;
		let joint = Jolt.tn_joint_create(mSystem, bodyA, bodyB, &point, &direction, Mathf.Clamp(swingLimitDegrees, 0, 179) * Mathf.Deg2Rad);
		if (joint != null)
			mJoints.Add((joint, bodyA, bodyB, ++mJointSequence));
		return joint;
	}

	/// A hinge between two bodies, turning about axis through anchor (both in the world); childAxis and childNormal fix
	/// how the second body sits on it. Null if either body is missing.
	public void* CreateHinge(uint32 bodyA, uint32 bodyB, Vector3 anchor, Vector3 axis, Vector3 childAxis, Vector3 childNormal)
	{
		if (mSystem == null || bodyA == bodyB || !mByBody.ContainsKey(bodyA) || !mByBody.ContainsKey(bodyB)) return null;
		var point = anchor;
		var direction = axis.LengthSquared > 0.00001f ? axis.Normalized : Vector3.Up;
		var axisB = childAxis;
		var normalB = childNormal;
		let hinge = Jolt.tn_hinge_create(mSystem, bodyA, bodyB, &point, &direction, &axisB, &normalB);
		if (hinge != null)
			mJoints.Add((hinge, bodyA, bodyB, ++mJointSequence));
		return hinge;
	}

	/// A sliding joint along axis, travel metres either way, like a wheel's suspension. Give it a spring with
	/// SetSuspensionSpring.
	public void* CreateSuspension(uint32 bodyA, uint32 bodyB, Vector3 anchor, Vector3 childAnchor, Vector3 axis, Vector3 childAxis, Vector3 childNormal, float travel)
	{
		if (mSystem == null || bodyA == bodyB || !mByBody.ContainsKey(bodyA) || !mByBody.ContainsKey(bodyB)) return null;
		var a = anchor;
		var b = childAnchor;
		var direction = axis.Normalized;
		var axisB = childAxis.Normalized;
		var normalB = childNormal.Normalized;
		let slider = Jolt.tn_slider_create(mSystem, bodyA, bodyB, &a, &b, &direction, &axisB, &normalB, Math.Max(0.001f, travel));
		if (slider != null)
			mJoints.Add((slider, bodyA, bodyB, ++mJointSequence));
		return slider;
	}

	/// How hard a suspension pushes back and how quickly its bouncing dies away.
	public void SetSuspensionSpring(void* slider, float stiffness, float damping)
	{
		if (HasJoint(slider))
			Jolt.tn_slider_spring(slider, stiffness, damping);
	}

	/// How far along its travel a suspension is.
	public float SuspensionPosition(void* slider) => HasJoint(slider) ? Jolt.tn_slider_position(slider) : 0;
	/// Drives a hinge with up to torque. Mode 0 switches the motor off, 1 spins it at speed (radians a second), 2 turns
	/// it to angle (radians), at up to maximumSpeed, faster the larger response is.
	public void SetHingeMotor(void* hinge, float speed, float torque, float angle = 0, int32 mode = 1, float response = 8, float maximumSpeed = 3)
	{
		if (!HasJoint(hinge)) return;
		Jolt.tn_hinge_motor(hinge, speed, Math.Max(0, torque), angle, mode, Math.Max(0.1f, response), Math.Max(0.1f, maximumSpeed));
		for (let entry in mJoints)
		{
			if (entry.joint == hinge)
			{
				Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, entry.a);
				Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, entry.b);
			}
		}
	}

	/// How far a hinge has turned, in radians.
	public float HingeAngle(void* hinge) => HasJoint(hinge) ? Jolt.tn_hinge_angle(hinge) : 0;

	/// Safe to call with a joint that has already gone (because one of its bodies was destroyed).
	public void DestroyJoint(void* joint)
	{
		for (int i < mJoints.Count)
		{
			if (mJoints[i].joint == joint)
			{
				Jolt.tn_joint_destroy(mSystem, joint);
				mJoints.RemoveAt(i);
				return;
			}
		}
	}

	// Native allocators may reuse a constraint address after a body rebuild.
	/// A number that changes when a joint is remade at the same address, so that a held handle can tell it is not the
	/// same joint.
	public uint64 JointGeneration(void* joint)
	{
		for (let entry in mJoints)
		{
			if (entry.joint == joint)
				return entry.generation;
		}
		return 0;
	}

	/// Whether a joint is still in the world (it goes with either of its bodies).
	public bool HasJoint(void* joint)
	{
		for (let entry in mJoints)
		{
			if (entry.joint == joint)
				return true;
		}
		return false;
	}

	/// Soft bodies (SoftBody components) by body id: each moves its pins and feels the wind before a step.
	Dictionary<uint32, SoftBody> mSoftBodies = new .() ~ delete _;

	void AddSoftBody(uint32 bodyId, SoftBody owner) => mSoftBodies[bodyId] = owner;

	/// Ropes (Rope components): each moves its ends and ties its pull before a step.
	List<Rope> mRopes = new .() ~ delete _;

	void AddRope(Rope rope) => mRopes.Add(rope);

	void RemoveRope(Rope rope)
	{
		if (mRopes.Remove(rope) && mBodyInterface != null)
			Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, rope.BodyId);
	}

	void RemoveSoftBody(uint32 bodyId)
	{
		if (mSoftBodies.Remove(bodyId) && mBodyInterface != null)
			Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, bodyId);
	}

	/// Removes a body, and every joint on it.
	public void DestroyBody(uint32 bodyId)
	{
		if (!mByBody.TryGetValue(bodyId, let entry))
			return;
		// A joint cannot outlive either of the bodies it holds together.
		for (int i = mJoints.Count - 1; i >= 0; i--)
		{
			if (mJoints[i].a == bodyId || mJoints[i].b == bodyId)
			{
				Jolt.tn_joint_destroy(mSystem, mJoints[i].joint);
				mJoints.RemoveAt(i);
			}
		}
		if (mDebris.Remove(bodyId))
			Jolt.tn_physics_set_debris(bodyId, false);
		if (entry.outOfWorld)
			Jolt.JPH_BodyInterface_AddBody(mBodyInterface, bodyId, Jolt.DontActivate);
		Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, bodyId);
		Jolt.JPH_Shape_Destroy(entry.shape);
		mByBody.Remove(bodyId);
		mEntries.Remove(entry);
		delete entry;
	}

	// ---- layers and world states ----

	Dictionary<void*, Transform> mCharacterOwners = new .() ~ delete _;

	uint32 CharacterLayer(void* character)
	{
		Transform owner = null;
		mCharacterOwners.TryGetValue(character, out owner);
		return ObjectLayer(LayerMoving, owner);
	}

	/// Moves an object's bodies to its current layer (GameObject.Layer calls this).
	public void RefreshLayer(GameObject gameObject)
	{
		if (mBodyInterface == null)
			return;
		for (let entry in mEntries)
		{
			if (entry.transform.GameObject != gameObject)
				continue;
			let current = Jolt.JPH_BodyInterface_GetObjectLayer(mBodyInterface, entry.bodyId);
			Jolt.JPH_BodyInterface_SetObjectLayer(mBodyInterface, entry.bodyId, ObjectLayer(current / LayersPerClass, gameObject.Layer));
		}
		mBroadPhaseDirty = true;
	}

	/// Takes bodies of objects outside the scene's active world state out of the simulation and puts back those
	/// inside it (Scene.WorldState calls this). A character's own body stays: the character decides where it goes.
	public void ApplyWorldState(Scene scene)
	{
		if (!FollowsWorldStates)
			return;
		if (mBodyInterface == null)
			return;
		for (let entry in mEntries)
		{
			if (entry.external)
				continue;
			let inWorld = entry.transform.GameObject.InActiveWorld;
			if (inWorld && entry.outOfWorld)
			{
				var position = entry.transform.Position;
				var rotation = entry.transform.Rotation;
				Jolt.JPH_BodyInterface_SetPositionAndRotation(mBodyInterface, entry.bodyId, &position, &rotation, Jolt.DontActivate);
				Jolt.JPH_BodyInterface_AddBody(mBodyInterface, entry.bodyId, Jolt.Activate);
				entry.outOfWorld = false;
				entry.lastVersion = entry.transform.Version;
			}
			else if (!inWorld && !entry.outOfWorld)
			{
				Jolt.JPH_BodyInterface_RemoveBody(mBodyInterface, entry.bodyId);
				entry.outOfWorld = true;
			}
		}
		mBroadPhaseDirty = true;
	}

	/// The same after one object's world states changed (its children's bodies may change with it).
	public void ApplyWorldState(GameObject gameObject) => ApplyWorldState(gameObject.Scene);

	/// True when the body is taking part in the simulation (false while its object is outside the active world state).
	public bool IsInWorld(uint32 bodyId) => mByBody.TryGetValue(bodyId, let entry) && !entry.outOfWorld;

	// ---- character controllers ----

	void TrackInnerBody(void* character, Transform transform)
	{
		let bodyId = Jolt.tn_character_inner_body(character);
		if (bodyId == uint32.MaxValue)
			return;
		let entry = new Entry();
		entry.bodyId = bodyId;
		entry.transform = transform;
		entry.lastVersion = transform.Version;
		entry.external = true;
		mEntries.Add(entry);
		mByBody[bodyId] = entry;
	}

	void UntrackInnerBody(void* character)
	{
		if (!mByBody.TryGetValue(Jolt.tn_character_inner_body(character), let entry))
			return;
		mByBody.Remove(entry.bodyId);
		mEntries.Remove(entry);
		delete entry;
	}

	/// Creates a character that is moved by sweeping its shape (see CharacterController). supportHeight is how far above
	/// the transform's position a contact still counts as the floor. Returns null if the shape cannot be built.
	public void* CreateCharacter(Transform transform, ShapeDesc desc, Quaternion rotationIn, float maxSlopeDegrees, float mass, float pushStrength, float supportHeight, bool soft)
	{
		EnsureCreated();
		let shape = CreateShape(desc);
		if (shape == null)
			return null;
		var position = transform.Position;
		var rotation = rotationIn;
		let character = Jolt.tn_character_create(mSystem, shape, &position, &rotation, Mathf.Clamp(maxSlopeDegrees, 1, 89) * Mathf.Deg2Rad, Math.Max(mass, 0.001f), Math.Max(pushStrength, 0), supportHeight, ObjectLayer(LayerMoving, transform), (uint64)transform.GameObject.Id, true, soft);
		// The character and its inner body hold their own references.
		Jolt.JPH_Shape_Destroy(shape);
		if (character == null)
			return null;
		mCharacters.Add(character);
		mCharacterOwners[character] = transform;
		TrackInnerBody(character, transform);
		mBroadPhaseDirty = true;
		// Find the floor now, so ground state is right before the first move.
		var velocity = Vector3.Zero;
		PrepareQuery();
		Jolt.tn_character_set_state(character, mSystem, CharacterLayer(character), &position, &rotation, &velocity, soft);
		return character;
	}

	/// Safe to call with a character this world has already destroyed.
	public void DestroyCharacter(void* character)
	{
		if (!mCharacters.Remove(character))
			return;
		mCharacterOwners.Remove(character);
		UntrackInnerBody(character);
		Jolt.tn_character_destroy(character, mSystem);
	}

	/// Whether a character controller's body is still in the world.
	public bool HasCharacter(void* character) => character != null && mCharacters.Contains(character);

	/// Where a character is, how fast it moves and what it stands on.
	public Jolt.CharacterState GetCharacterState(void* character)
	{
		Jolt.CharacterState state = default;
		if (HasCharacter(character))
			Jolt.tn_character_get_state(character, &state);
		return state;
	}

	/// Moves a character for one step at the given velocity, climbing steps up to stepHeight and following the floor
	/// down by the same amount. stepReach is how far past a step's edge its top is probed for a place to stand.
	public Jolt.CharacterState MoveCharacter(void* character, Vector3 velocityIn, float deltaTime, float stepHeight, float stepReach, bool soft)
	{
		Jolt.CharacterState state = default;
		if (!HasCharacter(character) || !Finite(velocityIn) || !deltaTime.IsFinite || deltaTime <= 0)
			return GetCharacterState(character);
		PrepareQuery();
		var gravity = Gravity;
		Jolt.JPH_PhysicsSystem_SetGravity(mSystem, &gravity);
		var velocity = velocityIn;
		let step = Math.Max(stepHeight, 0);
		Jolt.tn_character_move(character, mSystem, CharacterLayer(character), &velocity, deltaTime, step, step, Math.Max(stepReach, 0.15f), soft, &state);
		return state;
	}

	/// Teleports a character and gives it a velocity; its contacts are rebuilt at the new place.
	public void SetCharacterState(void* character, Vector3 positionIn, Quaternion rotationIn, Vector3 velocityIn, bool soft)
	{
		if (!HasCharacter(character) || !Finite(positionIn) || !Finite(velocityIn) || !ValidRotation(rotationIn))
			return;
		var position = positionIn;
		var rotation = rotationIn;
		var velocity = velocityIn;
		PrepareQuery();
		Jolt.tn_character_set_state(character, mSystem, CharacterLayer(character), &position, &rotation, &velocity, soft);
	}

	/// True if the shape fits where the character stands, allowing that much overlap with the surroundings.
	/// The character switches to the shape when it fits.
	public bool TrySetCharacterShape(void* character, ShapeDesc desc, float maxPenetration, bool soft)
	{
		if (!HasCharacter(character))
			return false;
		let shape = CreateShape(desc);
		if (shape == null)
			return false;
		PrepareQuery();
		let fits = Jolt.tn_character_set_shape(character, mSystem, CharacterLayer(character), shape, maxPenetration, soft);
		Jolt.JPH_Shape_Destroy(shape);
		return fits;
	}

	/// Advances the simulation by one fixed tick and writes the results to the transforms.
	public void Step(float deltaTime)
	{
		LastStepError = 0;
		if (mSystem == null || (mEntries.Count == 0 && mSoftBodies.Count == 0 && mRopes.Count == 0))
			return;
		PrepareQuery();
		var gravity = Gravity;
		Jolt.JPH_PhysicsSystem_SetGravity(mSystem, &gravity);

		// Transforms moved by gameplay or the network since the last step win over the simulation.
		for (let entry in mEntries)
		{
			if (entry.external || entry.outOfWorld || entry.transform.Version == entry.lastVersion)
				continue;
			var position = entry.transform.Position;
			var rotation = entry.transform.Rotation;
			if (entry.kinematic)
				Jolt.JPH_BodyInterface_MoveKinematic(mBodyInterface, entry.bodyId, &position, &rotation, deltaTime);
			else
				Jolt.JPH_BodyInterface_SetPositionAndRotation(mBodyInterface, entry.bodyId, &position, &rotation, Jolt.Activate);
		}

		for (let soft in mSoftBodies.Values)
			soft.[Friend]BeforeStep(deltaTime);
		for (let rope in mRopes)
			rope.[Friend]BeforeStep(deltaTime);
		SoftBody.[Friend]UpdateProxies(this, mSoftBodies, mRopes);

		LastStepError = Jolt.JPH_PhysicsSystem_Update(mSystem, deltaTime, 1, sJobSystem);
		if (LastStepError != 0 && (mReportedStepErrors & LastStepError) != LastStepError)
		{
			Log.Error(scope $"[Physics] Solver capacity exceeded (error mask {LastStepError}); contacts may be missing. ConfigureCapacity before creating the world. Current bodies/pairs/contacts: {mBodyCapacity}/{mBodyPairCapacity}/{mContactCapacity}.");
			mReportedStepErrors |= LastStepError;
		}

		for (let entry in mEntries)
		{
			if ((entry.dynamic || entry.kinematic) && !entry.outOfWorld)
			{
				Vector3 position = default;
				Quaternion rotation = default;
				Jolt.JPH_BodyInterface_GetPosition(mBodyInterface, entry.bodyId, &position);
				Jolt.JPH_BodyInterface_GetRotation(mBodyInterface, entry.bodyId, &rotation);
				entry.transform.SetPositionAndRotation(position, rotation);
			}
			entry.lastVersion = entry.transform.Version;
		}
	}

	/// Pushes a transform that gameplay moved since the last step into Jolt right away, so
	/// reads and writes of body state in the same tick see the new pose.
	void Flush(uint32 bodyId)
	{
		if (!mByBody.TryGetValue(bodyId, let entry) || entry.transform.Version == entry.lastVersion)
			return;
		var position = entry.transform.Position;
		var rotation = entry.transform.Rotation;
		Jolt.JPH_BodyInterface_SetPositionAndRotation(mBodyInterface, bodyId, &position, &rotation, Jolt.Activate);
		entry.lastVersion = entry.transform.Version;
	}

	/// A body's position, rotation and velocities, to put back with SetState.
	public BodyState GetState(uint32 bodyId)
	{
		BodyState state = default;
		state.rotation = .Identity;
		if (mBodyInterface == null || bodyId == uint32.MaxValue)
			return state;
		Flush(bodyId);
		Jolt.JPH_BodyInterface_GetPosition(mBodyInterface, bodyId, &state.position);
		Jolt.JPH_BodyInterface_GetRotation(mBodyInterface, bodyId, &state.rotation);
		Jolt.JPH_BodyInterface_GetLinearVelocity(mBodyInterface, bodyId, &state.linearVelocity);
		Jolt.JPH_BodyInterface_GetAngularVelocity(mBodyInterface, bodyId, &state.angularVelocity);
		return state;
	}

	/// Teleports a body to a full state (used by network corrections and rollback).
	public void SetState(uint32 bodyId, BodyState stateIn)
	{
		if (!mByBody.TryGetValue(bodyId, let entry))
			return;
		var state = stateIn;
		if (entry.dynamic)
			Jolt.JPH_BodyInterface_SetPositionRotationAndVelocity(mBodyInterface, bodyId, &state.position, &state.rotation, &state.linearVelocity, &state.angularVelocity);
		else
			Jolt.JPH_BodyInterface_SetPositionAndRotation(mBodyInterface, bodyId, &state.position, &state.rotation, Jolt.Activate);
		Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
		entry.transform.SetPositionAndRotation(state.position, state.rotation);
		entry.lastVersion = entry.transform.Version;
	}

	/// Let an authored resting prop wait for a real contact to wake it, without making it kinematic.
	public void Sleep(uint32 bodyId)
	{
		if (!mByBody.TryGetValue(bodyId, let entry) || !entry.dynamic || entry.outOfWorld)
			return;
		Flush(bodyId);
		Jolt.JPH_BodyInterface_DeactivateBody(mBodyInterface, bodyId);
	}

	/// Whether a body is resting and not being simulated.
	public bool IsSleeping(uint32 bodyId) => (mByBody.ContainsKey(bodyId) || mSoftBodies.ContainsKey(bodyId)) && !Jolt.JPH_BodyInterface_IsActive(mBodyInterface, bodyId);

	/// How fast a body moves, in metres a second.
	public Vector3 GetLinearVelocity(uint32 bodyId)
	{
		Vector3 v = default;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_GetLinearVelocity(mBodyInterface, bodyId, &v);
		return v;
	}

	/// Sets how fast a body moves (waking it).
	public void SetLinearVelocity(uint32 bodyId, Vector3 velocity)
	{
		var v = velocity;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
		{
			Jolt.JPH_BodyInterface_SetLinearVelocity(mBodyInterface, bodyId, &v);
			Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
		}
	}

	/// How fast a body spins, in radians a second.
	public Vector3 GetAngularVelocity(uint32 bodyId)
	{
		Vector3 v = default;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_GetAngularVelocity(mBodyInterface, bodyId, &v);
		return v;
	}

	/// Sets how fast a body spins (waking it).
	public void SetAngularVelocity(uint32 bodyId, Vector3 velocity)
	{
		var v = velocity;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_SetAngularVelocity(mBodyInterface, bodyId, &v);
	}

	/// Pushes a body by a force, in newtons, through its centre over the next step.
	public void AddForce(uint32 bodyId, Vector3 force)
	{
		var f = force;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_AddForce(mBodyInterface, bodyId, &f);
	}

	/// Turns a body by a torque, in newton metres about each world axis, over the next step.
	public void AddTorque(uint32 bodyId, Vector3 torque)
	{
		var t = torque;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
		{
			Jolt.JPH_BodyInterface_AddTorque(mBodyInterface, bodyId, &t);
			Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
		}
	}

	/// Pushes a body by a force at a point in the world, which also turns it.
	public void AddForceAtPosition(uint32 bodyId, Vector3 force, Vector3 point)
	{
		var f = force;
		var p = point;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
		{
			Jolt.JPH_BodyInterface_AddForce2(mBodyInterface, bodyId, &f, &p);
			Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
		}
	}

	/// Velocity of the point on a body at a world position (linear plus rotational).
	public Vector3 GetPointVelocity(uint32 bodyId, Vector3 point)
	{
		Vector3 v = default;
		var p = point;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_GetPointVelocity(mBodyInterface, bodyId, &p, &v);
		return v;
	}

	/// Changes a body's momentum at once, through its centre.
	public void AddImpulse(uint32 bodyId, Vector3 impulse)
	{
		var i = impulse;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_AddImpulse(mBodyInterface, bodyId, &i);
	}

	/// Floats a body in water whose surface passes through surfacePoint facing surfaceNormal, for one step: Jolt works
	/// out how much of the body's shape is under that plane and pushes it up (buoyancy 1 neither sinks nor floats,
	/// more floats). The water then slows it: its velocity eases towards the water's own (fluidVelocity) and its
	/// turning stops, linearDrag and angularDrag times a second when it is all under, less as less of it is. (Jolt's
	/// own drag counts the water as dense as the body, which leaves a light thing bobbing for a long time.) False
	/// when no part of it is under.
	public bool ApplyBuoyancy(uint32 bodyId, Vector3 surfacePoint, Vector3 surfaceNormal, float buoyancy, float linearDrag, float angularDrag, Vector3 fluidVelocity,
		float deltaTime)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue)
			return false;
		Entry entry;
		if (!mByBody.TryGetValue(bodyId, out entry) || !entry.dynamic || entry.outOfWorld)
			return false;
		Flush(bodyId);
		var point = surfacePoint;
		var normal = surfaceNormal;
		var flow = fluidVelocity;
		var gravity = Gravity;
		if (!Jolt.JPH_BodyInterface_ApplyBuoyancyImpulse(mBodyInterface, bodyId, &point, &normal, buoyancy, linearDrag * 0.5f, angularDrag * 0.05f, &flow, &gravity, deltaTime))
			return false;
		// How much of it is under, measured up and down its box in the world.
		var under = 1.0f;
		if (entry.shape != null)
		{
			Bounds local = default;
			Jolt.JPH_Shape_GetLocalBounds(entry.shape, &local);
			Vector3 position = default;
			Quaternion rotation = default;
			Jolt.JPH_BodyInterface_GetPosition(mBodyInterface, bodyId, &position);
			Jolt.JPH_BodyInterface_GetRotation(mBodyInterface, bodyId, &rotation);
			let center = position + rotation * ((local.min + local.max) * 0.5f);
			let half = (local.max - local.min) * 0.5f;
			let reach = Math.Abs((rotation * Vector3(half.x, 0, 0)).y) + Math.Abs((rotation * Vector3(0, half.y, 0)).y) + Math.Abs((rotation * Vector3(0, 0, half.z)).y);
			let level = surfacePoint.y;
			under = reach > 0.0001f ? Math.Clamp((level - (center.y - reach)) / (reach * 2), 0, 1) : 1;
		}
		Vector3 velocity = default, spin = default;
		Jolt.JPH_BodyInterface_GetLinearVelocity(mBodyInterface, bodyId, &velocity);
		Jolt.JPH_BodyInterface_GetAngularVelocity(mBodyInterface, bodyId, &spin);
		velocity = fluidVelocity + (velocity - fluidVelocity) * Math.Exp(-Math.Max(linearDrag, 0) * under * deltaTime);
		spin = spin * Math.Exp(-Math.Max(angularDrag, 0) * under * deltaTime);
		Jolt.JPH_BodyInterface_SetLinearVelocity(mBodyInterface, bodyId, &velocity);
		Jolt.JPH_BodyInterface_SetAngularVelocity(mBodyInterface, bodyId, &spin);
		return true;
	}

	// Queries run on the scene thread, like simulation and body state changes.
	void* PrepareQuery()
	{
		if (mSystem == null) return null;
		if (mBroadPhaseDirty)
		{
			Jolt.JPH_PhysicsSystem_OptimizeBroadPhase(mSystem);
			mBroadPhaseDirty = false;
		}
		return Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem);
	}

	static bool Finite(Vector3 v) => v.x.IsFinite && v.y.IsFinite && v.z.IsFinite;
	static bool ValidRotation(Quaternion q) => q.x.IsFinite && q.y.IsFinite && q.z.IsFinite && q.w.IsFinite && Quaternion.Dot(q, q) > 1.0e-12f;

	void* SphereQueryShape(float radius)
	{
		if (mSystem == null) return null;
		if (!radius.IsFinite || radius <= 0) return null;
		if (mSphereQueryShape == null || radius != mSphereQueryRadius)
		{
			if (mSphereQueryShape != null)
				Jolt.JPH_Shape_Destroy(mSphereQueryShape);
			mSphereQueryShape = Jolt.JPH_SphereShape_Create(radius);
			mSphereQueryRadius = radius;
		}
		return mSphereQueryShape;
	}

	void* CapsuleQueryShape(float halfHeight, float radius)
	{
		if (mSystem == null) return null;
		if (!radius.IsFinite || radius <= 0 || !halfHeight.IsFinite) return null;
		// Coincident end centers describe a sphere.
		if (halfHeight <= 1.0e-6f) return SphereQueryShape(radius);
		if (mCapsuleQueryShape == null || mCapsuleQuerySize.x != halfHeight || mCapsuleQuerySize.y != radius)
		{
			if (mCapsuleQueryShape != null)
				Jolt.JPH_Shape_Destroy(mCapsuleQueryShape);
			mCapsuleQueryShape = Jolt.JPH_CapsuleShape_Create(halfHeight, radius);
			mCapsuleQuerySize = .(halfHeight, radius);
		}
		return mCapsuleQueryShape;
	}

	void* BoxQueryShape(Vector3 size)
	{
		if (mSystem == null) return null;
		if (!Finite(size) || size.x <= 0 || size.y <= 0 || size.z <= 0) return null;
		if (mBoxQueryShape == null || mBoxQuerySize.x != size.x || mBoxQuerySize.y != size.y || mBoxQuerySize.z != size.z)
		{
			if (mBoxQueryShape != null)
				Jolt.JPH_Shape_Destroy(mBoxQueryShape);
			var half = size * 0.5f;
			mBoxQueryShape = Jolt.JPH_BoxShape_Create(&half, Math.Min(0.02f, Math.Min(half.x, Math.Min(half.y, half.z))));
			mBoxQuerySize = size;
		}
		return mBoxQueryShape;
	}

	ShapeCastHit MakeShapeHit(Jolt.ShapeHit nativeHit, float maxDistance)
	{
		ShapeCastHit hit = default;
		hit.bodyId = nativeHit.bodyId;
		hit.point = nativeHit.point;
		hit.normal = nativeHit.normal;
		hit.distance = Math.Max(nativeHit.fraction, 0) * maxDistance;
		hit.penetrationDepth = nativeHit.penetrationDepth;
		if (mByBody.TryGetValue(nativeHit.bodyId, let entry))
			hit.gameObject = entry.transform.GameObject;
		return hit;
	}

	bool CastQuery(void* shape, Vector3 origin, Quaternion orientation, Vector3 direction, float maxDistance, out ShapeCastHit hit, uint32 ignoreBody, uint32 layerMask)
	{
		hit = default;
		if (shape == null || !Finite(origin) || !Finite(direction) || direction.LengthSquared < 1.0e-12f || !direction.LengthSquared.IsFinite || !maxDistance.IsFinite || maxDistance <= 0 || !ValidRotation(orientation)) return false;
		let query = PrepareQuery();
		if (query == null) return false;
		var from = origin;
		var rotation = orientation.Normalized;
		var displacement = direction.Normalized * maxDistance;
		Jolt.ShapeHit nativeHit = default;
		if (!Jolt.tn_physics_cast_shape(query, shape, &from, &rotation, &displacement, ignoreBody, &nativeHit, layerMask)) return false;
		hit = MakeShapeHit(nativeHit, maxDistance);
		return true;
	}

	/// Sweeps a sphere and returns its closest contact. Direction need not be normalized.
	/// A starting overlap returns distance zero and its penetration depth. layerMask: the layers it sees (one bit
	/// per layer; ProjectConfig.Mask makes one from names), all of them by default.
	public bool SphereCast(Vector3 origin, float radius, Vector3 direction, float maxDistance, out ShapeCastHit hit, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CastQuery(SphereQueryShape(radius), origin, .Identity, direction, maxDistance, out hit, ignoreBody, layerMask);

	/// The endpoints are the centers of the capsule's two hemispheres.
	public bool CapsuleCast(Vector3 point1, Vector3 point2, float radius, Vector3 direction, float maxDistance, out ShapeCastHit hit, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
	{
		hit = default;
		if (!Finite(point1) || !Finite(point2)) return false;
		let axis = point2 - point1;
		let length = axis.Length;
		if (!length.IsFinite) return false;
		// Local capsule Y is aligned with the endpoint axis.
		let rotation = length < 1.0e-6f ? Quaternion.Identity : CapsuleRotation(axis);
		return CastQuery(CapsuleQueryShape(length * 0.5f, radius), (point1 + point2) * 0.5f, rotation, direction, maxDistance, out hit, ignoreBody, layerMask);
	}

	/// Size is the full width/height/depth, matching BoxCollider.size.
	public bool BoxCast(Vector3 origin, Vector3 size, Quaternion orientation, Vector3 direction, float maxDistance, out ShapeCastHit hit, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CastQuery(BoxQueryShape(size), origin, orientation, direction, maxDistance, out hit, ignoreBody, layerMask);

	int OverlapQuery(void* shape, Vector3 origin, Quaternion orientation, List<ShapeCastHit> hits, uint32 ignoreBody, uint32 layerMask)
	{
		using (sOverlapProfile.Sample())
		{
			hits.Clear();
			if (shape == null || !Finite(origin) || !ValidRotation(orientation)) return 0;
			let query = PrepareQuery();
			if (query == null) return 0;
			if (mOverlapHits.Count < 64)
				mOverlapHits.Resize(64);
			var from = origin;
			var rotation = orientation.Normalized;
			int32 count;
			using (sOverlapNativeProfile.Sample())
			{
				if (Profiler.Enabled)
					Jolt.tn_physics_profile_convex( => BeginConvexProfile, => Profiler.End);
				defer
				{
					if (Profiler.Enabled)
						Jolt.tn_physics_profile_convex(null, null);
				}
				count = Jolt.tn_physics_overlap_shape(query, shape, &from, &rotation, ignoreBody, mOverlapHits.Ptr, (int32)mOverlapHits.Count, layerMask, useAnalyticOverlapContacts);
				if (count > mOverlapHits.Count)
				{
					mOverlapHits.Resize(count);
					count = Jolt.tn_physics_overlap_shape(query, shape, &from, &rotation, ignoreBody, mOverlapHits.Ptr, (int32)mOverlapHits.Count, layerMask, useAnalyticOverlapContacts);
				}
			}
			for (int i < count)
				hits.Add(MakeShapeHit(mOverlapHits[i], 0));
			return (int)hits.Count;
		}
	}

	/// The rotation that turns a capsule's axis (its Y) onto a direction. LookRotation keeps the forward it is given and
	/// only leans up towards the one given, so forward is chosen at right angles to the axis.
	static Quaternion CapsuleRotation(Vector3 axis)
	{
		let up = axis.Normalized;
		let side = Math.Abs(up.x) < 0.9f ? Vector3.Right : Vector3.Forward;
		return Quaternion.LookRotation(Vector3.Cross(side, up), up);
	}

	bool CheckQuery(void* shape, Vector3 origin, Quaternion orientation, uint32 ignoreBody, uint32 layerMask)
	{
		if (shape == null || !Finite(origin) || !ValidRotation(orientation)) return false;
		let query = PrepareQuery();
		if (query == null) return false;
		var from = origin;
		var rotation = orientation.Normalized;
		return Jolt.tn_physics_check_shape(query, shape, &from, &rotation, ignoreBody, layerMask);
	}

	/// Whether anything touches a sphere: as OverlapSphere, without the contacts, so several times quicker (it stops at
	/// the first thing it finds). As Unity's Physics.CheckSphere.
	public bool CheckSphere(Vector3 origin, float radius, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CheckQuery(SphereQueryShape(radius), origin, .Identity, ignoreBody, layerMask);

	/// Whether anything touches a box (of a full size, turned by orientation), without the contacts.
	public bool CheckBox(Vector3 origin, Vector3 size, Quaternion orientation, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CheckQuery(BoxQueryShape(size), origin, orientation, ignoreBody, layerMask);

	/// Whether anything touches a capsule from point1 to point2, without the contacts.
	public bool CheckCapsule(Vector3 point1, Vector3 point2, float radius, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
	{
		if (!Finite(point1) || !Finite(point2)) return false;
		let axis = point2 - point1;
		let length = axis.Length;
		if (!length.IsFinite) return false;
		let rotation = length < 1.0e-6f ? Quaternion.Identity : CapsuleRotation(axis);
		return CheckQuery(CapsuleQueryShape(length * 0.5f, radius), (point1 + point2) * 0.5f, rotation, ignoreBody, layerMask);
	}

	/// Returns contacts, including separate subshapes of compound/mesh bodies. Clears hits first. CheckSphere is quicker
	/// when only whether something is there matters.
	public int OverlapSphere(Vector3 origin, float radius, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> OverlapQuery(SphereQueryShape(radius), origin, .Identity, hits, ignoreBody, layerMask);
	/// Everything touching a box (of a full size, turned by orientation) round a point. Clears hits first; returns how
	/// many there are.
	public int OverlapBox(Vector3 origin, Vector3 size, Quaternion orientation, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> OverlapQuery(BoxQueryShape(size), origin, orientation, hits, ignoreBody, layerMask);
	/// Everything touching a capsule from point1 to point2. Clears hits first; returns how many there are.
	public int OverlapCapsule(Vector3 point1, Vector3 point2, float radius, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
	{
		hits.Clear();
		if (!Finite(point1) || !Finite(point2)) return 0;
		let axis = point2 - point1;
		let length = axis.Length;
		if (!length.IsFinite) return 0;
		let rotation = length < 1.0e-6f ? Quaternion.Identity : CapsuleRotation(axis);
		return OverlapQuery(CapsuleQueryShape(length * 0.5f, radius), (point1 + point2) * 0.5f, rotation, hits, ignoreBody, layerMask);
	}

	/// Casts a ray and reports the closest body hit within maxDistance. Debris is passed through. layerMask: the
	/// layers it sees (ProjectConfig.Mask("Default", "Enemies")), all of them by default.
	public bool Raycast(Vector3 origin, Vector3 direction, float maxDistance, out RaycastHit hit, uint32 layerMask = uint32.MaxValue)
	{
		hit = default;
		if (mSystem == null || direction.LengthSquared < 1.0e-12f)
			return false;
		let unit = direction.Normalized;
		let query = PrepareQuery();
		float travelled = 0;
		// Debris in the way is stepped through a little at a time until the ray is out the other side.
		for (int attempt < 96)
		{
			var from = origin + unit * travelled;
			var delta = unit * (maxDistance - travelled);
			Jolt.RayCastResult result = default;
			if (!Jolt.JPH_NarrowPhaseQuery_CastRay(query, &from, &delta, &result, null, Jolt.tn_physics_layer_filter(layerMask), null))
				return false;
			let distance = travelled + result.fraction * (maxDistance - travelled);
			if (mDebris.Contains(result.bodyId))
			{
				travelled = distance + 0.2f;
				if (travelled >= maxDistance)
					return false;
				continue;
			}
			hit.distance = distance;
			hit.point = origin + unit * distance;
			if (mByBody.TryGetValue(result.bodyId, let entry))
				hit.gameObject = entry.transform.GameObject;
			return true;
		}
		return false;
	}
}
