using System;
using System.Collections;

namespace Tallow;

/// The Jolt half of PhysicsWorld: it owns the JPH_PhysicsSystem, shapes and bodies, and implements every
/// PhysicsBackendWorld primitive. All engine bookkeeping (transforms, entries, layers, callbacks) stays in
/// PhysicsWorld.
class JoltPhysicsBackendWorld : PhysicsBackendWorld
{
	static bool sJoltInitialized;
	static void* sJobSystem;
	static int sWorldCount;

	int32 mBodyCapacity, mBodyPairCapacity, mContactCapacity;
	int32 mSeparateWorlds;
	float mLengthScale;
	float mMinimumShapeExtent;
	bool mContactEvents;
	Vector3 mGravity;
	void* mSystem;
	void* mBodyInterface;
	bool mBroadPhaseDirty;
	int64 mNextOptimize;
	/// Frames between rebuilds of the broad phase while bodies keep coming.
	const int64 OptimizeInterval = 300;

	PhysicsFeatures mFeatures;
	JoltSoftBodyExtension mSoftBodies;
	JoltGeometryExtension mGeometry;
	JoltRagdollExtension mRagdolls;
	JoltVehicleExtension mVehicles;
	Dictionary<uint32, void*> mShapes = new .() ~
		{
			for (let (id, shape) in _)
				Jolt.JPH_Shape_Destroy(shape);
			delete _;
		};

	void* mSphereQueryShape;
	void* mCapsuleQueryShape;
	void* mBoxQueryShape;
	float mSphereQueryRadius = -1;
	Vector2 mCapsuleQuerySize = .(-1, -1);
	Vector3 mBoxQuerySize = .(-1, -1, -1);

	static ProfilerMarker sOverlapProfile = .("Physics.Overlap", .Physics);
	static ProfilerMarker sOverlapNativeProfile = .("Physics.Overlap.NativeContacts", .Physics);
	static ProfilerMarker sConvexProfile = .("Physics.Overlap.ConvexPair", .Physics);
	static ProfilerMarker sEPAProfile = .("Physics.Overlap.EPA", .Physics);

	static void BeginConvexProfile(int32 marker)
	{
		if (marker == 1)
			sEPAProfile.Begin();
		else
			sConvexProfile.Begin();
	}

	public override PhysicsFeatures Features => mFeatures;
	public override PhysicsSoftBodyExtension SoftBodies => (mFeatures.Has(.SoftBodies) || mFeatures.Has(.Ropes)) ? mSoftBodies : null;
	public override PhysicsGeometryExtension Geometry => mFeatures.Has(.NavigationGeometry) ? mGeometry : null;
	public override PhysicsRagdollExtension Ragdolls => mFeatures.Has(.Ragdolls) ? mRagdolls : null;
	public override PhysicsVehicleExtension Vehicles => mFeatures.Has(.Vehicles) ? mVehicles : null;

	public this(PhysicsWorldSettings settings)
	{
		mFeatures = JoltPhysicsBackend.AllFeatures;
		Initialize(settings);
	}

	public this(PhysicsWorldSettings settings, PhysicsFeatures features)
	{
		mFeatures = features;
		Initialize(settings);
	}

	void Initialize(PhysicsWorldSettings settings)
	{
		mBodyCapacity = settings.bodyCapacity;
		mBodyPairCapacity = settings.bodyPairCapacity;
		mContactCapacity = settings.contactCapacity;
		mSeparateWorlds = settings.separateWorldStates;
		mLengthScale = settings.lengthScale;
		mMinimumShapeExtent = settings.minimumShapeExtent;
		mContactEvents = settings.contactEvents;
		mGravity = settings.gravity;
		EnsureCreated(settings);
		if (mSystem != null)
		{
			mSoftBodies = new JoltSoftBodyExtension(mSystem);
			mGeometry = new JoltGeometryExtension(mSystem);
			mRagdolls = new JoltRagdollExtension(this, mSystem);
			mVehicles = new JoltVehicleExtension(this, mSystem);
		}
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
			if (mVehicles != null)
				mVehicles.WorldDestroyed();
			if (mRagdolls != null)
				mRagdolls.WorldDestroyed();
			if (mSoftBodies != null)
				mSoftBodies.WorldDestroyed();
			Jolt.JPH_PhysicsSystem_Destroy(mSystem);
			mSystem = null;
			mBodyInterface = null;
		}
		delete mSoftBodies;
		mSoftBodies = null;
		delete mGeometry;
		mGeometry = null;
		delete mRagdolls;
		mRagdolls = null;
		delete mVehicles;
		mVehicles = null;
		sWorldCount--;
	}

	void EnsureCreated(PhysicsWorldSettings settings)
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
			// A page without threads (or a build without them) runs the jobs on its one thread; with threads the
			// step spreads over the page's cores, a couple of which are left for the rest of the engine.
			config.numThreads = WebPlatform.ThreadsAvailable ? (int32)Math.Clamp(WebPlatform.HardwareThreads - 2, 0, 3) : 0;
#else
			config.numThreads = 3;
#endif
			sJobSystem = Jolt.JPH_JobSystemThreadPool_Create(&config);
			sJoltInitialized = true;
		}
		ProjectConfig.EnsureLoaded();
		let groups = (uint32)1 << mSeparateWorlds;
		let layerCount = groups * PhysicsLayerTable.LayersPerGroup;
		let broadPhase = Jolt.JPH_BroadPhaseLayerInterfaceTable_Create(layerCount, 2);
		for (uint32 group < groups)
		{
			for (int32 layer < ProjectConfig.MaxLayers)
			{
				Jolt.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broadPhase, PhysicsLayerTable.ObjectCode(PhysicsLayerTable.StaticClass, layer, group), 0);
				Jolt.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broadPhase, PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, layer, group), 1);
				Jolt.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broadPhase, PhysicsLayerTable.ObjectCode(PhysicsLayerTable.DebrisClass, layer, group), 1);
			}
		}
		let pairFilter = Jolt.JPH_ObjectLayerPairFilterTable_Create(layerCount);
		// What moves against what (static-moving, moving-moving, static-debris), for each pair of the project's
		// layers that collide, in each pair of world groups that share a world state (group 0 shares every one).
		uint32[3][2] classes = .(.(PhysicsLayerTable.StaticClass, PhysicsLayerTable.MovingClass), .(PhysicsLayerTable.MovingClass, PhysicsLayerTable.MovingClass), .(PhysicsLayerTable.StaticClass, PhysicsLayerTable.DebrisClass));
		for (uint32 groupA < groups)
		{
			for (uint32 groupB < groups)
			{
				if (groupA != 0 && groupB != 0 && (groupA & groupB) == 0)
					continue;
				for (int32 a < ProjectConfig.MaxLayers)
				{
					for (int32 b < ProjectConfig.MaxLayers)
					{
						if (!ProjectConfig.LayersCollide(a, b))
							continue;
						for (let pair in classes)
							Jolt.JPH_ObjectLayerPairFilterTable_EnableCollision(pairFilter,
								PhysicsLayerTable.ObjectCode(pair[0], a, groupA),
								PhysicsLayerTable.ObjectCode(pair[1], b, groupB));
					}
				}
			}
		}
		let objectVsBroadPhase = Jolt.JPH_ObjectVsBroadPhaseLayerFilterTable_Create(broadPhase, 2, pairFilter, layerCount);

		Jolt.PhysicsSystemSettings systemSettings = default;
		systemSettings.maxBodies = (uint32)mBodyCapacity;
		systemSettings.numBodyMutexes = 0;
		systemSettings.maxBodyPairs = (uint32)mBodyPairCapacity;
		systemSettings.maxContactConstraints = (uint32)mContactCapacity;
		systemSettings.broadPhaseLayerInterface = broadPhase;
		systemSettings.objectLayerPairFilter = pairFilter;
		systemSettings.objectVsBroadPhaseLayerFilter = objectVsBroadPhase;
		mSystem = Jolt.JPH_PhysicsSystem_Create(&systemSettings);
		if (mSystem == null)
			return;
		Jolt.tn_physics_scale_tolerances(mSystem, mLengthScale);
		mBodyInterface = Jolt.JPH_PhysicsSystem_GetBodyInterface(mSystem);
		Jolt.tn_contacts_enable(mSystem, mContactEvents);
		sWorldCount++;
	}

	// ---- world ----

	public override void SetGravity(Vector3 gravity)
	{
		mGravity = gravity;
		if (mSystem == null) return;
		var value = gravity;
		Jolt.JPH_PhysicsSystem_SetGravity(mSystem, &value);
	}

	public override void SetLengthScale(float scale)
	{
		if (mSystem != null)
			Jolt.tn_physics_scale_tolerances(mSystem, scale);
	}

	public override void Step(float deltaTime, out int32 errorMask, out float stepMilliseconds)
	{
		errorMask = 0;
		stepMilliseconds = 0;
		if (mSystem == null) return;
		let start = Internal.GetTickCountMicro();
		errorMask = Jolt.JPH_PhysicsSystem_Update(mSystem, deltaTime, 1, sJobSystem);
		stepMilliseconds = (Internal.GetTickCountMicro() - start) / 1000.0f;
	}

	public override void PrepareQuery(uint32 queryWorldGroups)
	{
		if (mSystem == null) return;
		// This only speeds queries up: new bodies are found without it, and it rebuilds the whole tree. So after a
		// level's bodies arrive, but not for each thing spawned while the game runs.
		if (mBroadPhaseDirty && Time.FrameCount >= mNextOptimize)
		{
			Jolt.JPH_PhysicsSystem_OptimizeBroadPhase(mSystem);
			mBroadPhaseDirty = false;
			mNextOptimize = Time.FrameCount + OptimizeInterval;
		}
		// The native filter is shared by every world, so each query names its own world states.
		Jolt.tn_physics_set_query_worlds(queryWorldGroups);
	}

	public override void BeginContactStep()
	{
		if (mSystem != null)
			Jolt.tn_contacts_begin_step(mSystem);
	}

	public override int CollectContacts(List<PhysicsContactEvent> into)
	{
		into.Clear();
		if (mSystem == null || !mContactEvents)
			return 0;
		let count = Jolt.tn_contacts_collect(mSystem);
		if (count <= 0)
			return 0;
		let events = Span<Jolt.ContactEvent>(Jolt.tn_contacts_events(), count);
		for (let event in events)
		{
			PhysicsContactEvent neutral = default;
			neutral.bodyA = event.bodyA;
			neutral.bodyB = event.bodyB;
			neutral.objectA = event.objectA;
			neutral.objectB = event.objectB;
			neutral.kind = event.kind;
			neutral.sensor = event.sensor;
			neutral.point = event.point;
			neutral.normal = event.normal;
			neutral.speed = event.speed;
			into.Add(neutral);
		}
		return into.Count;
	}

	protected override void ClearCore()
	{
		if (mBodyInterface == null)
			return;
		for (let (id, shape) in mShapes)
		{
			Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, id);
			Jolt.JPH_Shape_Destroy(shape);
		}
		mShapes.Clear();
		mBroadPhaseDirty = true;
	}

	// ---- shapes ----

	void* CreateShape(ShapeDesc desc)
	{
		void* shape = null;
		switch (desc.kind)
		{
		case .Box:
			var half = Vector3.Max(desc.halfExtents, .(mMinimumShapeExtent));
			let smallest = Math.Min(half.x, Math.Min(half.y, half.z));
			let convex = desc.convexRadius > 0 ? Math.Min(desc.convexRadius, smallest) : Math.Min(0.05f, smallest * 0.5f);
			shape = Jolt.JPH_BoxShape_Create(&half, convex);
		case .Sphere:
			shape = Jolt.JPH_SphereShape_Create(Math.Max(desc.radius, mMinimumShapeExtent));
		case .Capsule:
			shape = Jolt.JPH_CapsuleShape_Create(Math.Max(desc.halfHeight, mMinimumShapeExtent), Math.Max(desc.radius, mMinimumShapeExtent));
		case .Compound:
			if (desc.boxCount <= 0 && desc.cylinderCount <= 0 && desc.hullCount <= 0)
				return null;
			let compound = Jolt.JPH_StaticCompoundShapeSettings_Create();
			var identity = Quaternion.Identity;
			for (int i < desc.boxCount)
			{
				var boxCenter = desc.boxes[i * 2];
				var boxHalf = Vector3.Max(desc.boxes[i * 2 + 1], .(mMinimumShapeExtent));
				let boxShape = Jolt.JPH_BoxShape_Create(&boxHalf, Math.Min(0.02f, Math.Min(boxHalf.x, Math.Min(boxHalf.y, boxHalf.z)) * 0.5f));
				Jolt.JPH_CompoundShapeSettings_AddShape2(compound, &boxCenter, &identity, boxShape, (uint32)i);
				// The compound keeps its own reference to each part.
				Jolt.JPH_Shape_Destroy(boxShape);
			}
			for (int i = 0; i < desc.cylinderCount; i++)
			{
				var cylinder = desc.cylinders[i];
				let cylinderShape = Jolt.JPH_CylinderShape_Create(Math.Max(cylinder.halfHeight, mMinimumShapeExtent), Math.Max(cylinder.radius, mMinimumShapeExtent));
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
				triangles[i].i1 = mesh.Indices[i * 3];
				triangles[i].i2 = mesh.Indices[i * 3 + 1];
				triangles[i].i3 = mesh.Indices[i * 3 + 2];
				triangles[i].materialIndex = 0;
				// Jolt reorders triangles; the original index comes back with a hit (RaycastHit.triangle).
				triangles[i].userData = (uint32)i;
			}
			let settings = Jolt.JPH_MeshShapeSettings_Create2(vertices.Ptr, (uint32)vertices.Count, triangles.Ptr, (uint32)triangleCount);
			Jolt.JPH_MeshShapeSettings_SetPerTriangleUserData(settings, true);
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

	/// A shape for the ragdoll extension. The settings take their own reference; the caller destroys this one.
	public void* CreateShapeForRagdoll(ShapeDesc desc) => CreateShape(desc);

	// ---- bodies ----

	protected override uint32 CreateBodyCore(PhysicsBodyDesc desc, ShapeDesc shapeDesc)
	{
		if (mSystem == null)
			return uint32.MaxValue;
		let shape = CreateShape(shapeDesc);
		if (shape == null)
			return uint32.MaxValue;

		int32 motion = desc.motion == .Static ? Jolt.MotionStatic : (desc.motion == .Kinematic ? Jolt.MotionKinematic : Jolt.MotionDynamic);
		// Keep the inertia eigensolve away from Jolt's absolute near-zero fallback in miniature worlds.
		let massScale = Math.Min(100000000.0f, Math.Max(1.0f, 1.0f / (mLengthScale * mLengthScale)));
		var position = desc.position;
		var rotation = desc.rotation;
		let settings = Jolt.JPH_BodyCreationSettings_Create3(shape, &position, &rotation, motion, desc.objectCode);
		Jolt.JPH_BodyCreationSettings_SetUserData(settings, desc.userData);
		if (desc.sensor)
		{
			Jolt.JPH_BodyCreationSettings_SetIsSensor(settings, true);
			Jolt.JPH_BodyCreationSettings_SetCollideKinematicVsNonDynamic(settings, true);
		}
		Jolt.JPH_BodyCreationSettings_SetFriction(settings, desc.friction);
		Jolt.JPH_BodyCreationSettings_SetRestitution(settings, desc.restitution);
		Jolt.JPH_BodyCreationSettings_SetLinearDamping(settings, desc.linearDamping);
		Jolt.JPH_BodyCreationSettings_SetAngularDamping(settings, desc.angularDamping);
		Jolt.JPH_BodyCreationSettings_SetGravityFactor(settings, desc.gravityFactor);
		Jolt.JPH_BodyCreationSettings_SetAllowSleeping(settings, desc.allowSleeping);
		if (desc.continuousCollision)
			Jolt.JPH_BodyCreationSettings_SetMotionQuality(settings, 1);
		if (desc.freezeRotation)
			Jolt.JPH_BodyCreationSettings_SetAllowedDOFs(settings, 0b000111);
		if (motion == Jolt.MotionDynamic && desc.overrideMass)
		{
			Jolt.MassProperties mass = default;
			mass.mass = Math.Max(desc.mass, 0.001f) * massScale;
			// Jolt uses an overridden MassProperties as given: a zero inertia makes a vehicle unable to turn its
			// chassis under tire and suspension forces. A box around the shape's bounds is a stable default.
			Bounds bounds = default;
			Jolt.JPH_Shape_GetLocalBounds(shape, &bounds);
			let size = bounds.max - bounds.min;
			let m = mass.mass;
			float ix = m / 12.0f * (size.y * size.y + size.z * size.z);
			float iy = m / 12.0f * (size.x * size.x + size.z * size.z);
			float iz = m / 12.0f * (size.x * size.x + size.y * size.y);
			mass.inertia[0] = ix > 1.0e-6f ? ix : m * 0.05f;
			mass.inertia[5] = iy > 1.0e-6f ? iy : m * 0.05f;
			mass.inertia[10] = iz > 1.0e-6f ? iz : m * 0.05f;
			Jolt.JPH_BodyCreationSettings_SetOverrideMassProperties(settings, 1);
			Jolt.JPH_BodyCreationSettings_SetMassPropertiesOverride(settings, &mass);
		}
		uint32 bodyId = uint32.MaxValue;
		// A body every machine must give the same id (lockstep: the physics engine's results depend on ids).
		if (desc.wantedId != uint32.MaxValue)
		{
			if (Jolt.JPH_BodyInterface_CreateBodyWithID(mBodyInterface, desc.wantedId, settings) != null)
			{
				Jolt.JPH_BodyInterface_AddBody(mBodyInterface, desc.wantedId, Jolt.Activate);
				bodyId = desc.wantedId;
			}
		}
		if (bodyId == uint32.MaxValue)
			bodyId = Jolt.JPH_BodyInterface_CreateAndAddBody(mBodyInterface, settings, Jolt.Activate);
		Jolt.JPH_BodyCreationSettings_Destroy(settings);
		if (bodyId == uint32.MaxValue)
		{
			Jolt.JPH_Shape_Destroy(shape);
			return bodyId;
		}
		if (motion == Jolt.MotionDynamic && massScale > 1)
			Jolt.tn_physics_rescale_body_mass(mSystem, bodyId, Math.Max(desc.mass, 0.001f));
		mShapes[bodyId] = shape;
		if (desc.debris)
			Jolt.tn_physics_set_debris(bodyId, true);
		mBroadPhaseDirty = true;
		return bodyId;
	}

	protected override void DestroyBodyCore(uint32 bodyId)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue)
			return;
		if (mShapes.TryGetValue(bodyId, let shape))
		{
			mShapes.Remove(bodyId);
			Jolt.JPH_Shape_Destroy(shape);
		}
		Jolt.JPH_BodyInterface_RemoveAndDestroyBody(mBodyInterface, bodyId);
		mBroadPhaseDirty = true;
	}

	public override void SetBodyPose(uint32 bodyId, Vector3 position, Quaternion rotation, bool activate)
	{
		if (mBodyInterface == null) return;
		var p = position;
		var r = rotation;
		Jolt.JPH_BodyInterface_SetPositionAndRotation(mBodyInterface, bodyId, &p, &r, activate ? Jolt.Activate : Jolt.DontActivate);
		if (activate)
			mBroadPhaseDirty = true;
	}

	public override void MoveKinematic(uint32 bodyId, Vector3 position, Quaternion rotation, float deltaTime)
	{
		if (mBodyInterface == null) return;
		var p = position;
		var r = rotation;
		Jolt.JPH_BodyInterface_MoveKinematic(mBodyInterface, bodyId, &p, &r, deltaTime);
	}

	public override void GetBodyPose(uint32 bodyId, out Vector3 position, out Quaternion rotation)
	{
		position = default;
		rotation = .Identity;
		if (mBodyInterface == null) return;
		Jolt.JPH_BodyInterface_GetPosition(mBodyInterface, bodyId, &position);
		Jolt.JPH_BodyInterface_GetRotation(mBodyInterface, bodyId, &rotation);
	}

	public override Vector3 GetLinearVelocity(uint32 bodyId)
	{
		Vector3 result = default;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_GetLinearVelocity(mBodyInterface, bodyId, &result);
		return result;
	}

	public override void SetLinearVelocity(uint32 bodyId, Vector3 velocity)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return;
		var value = velocity;
		Jolt.JPH_BodyInterface_SetLinearVelocity(mBodyInterface, bodyId, &value);
		Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
	}

	public override Vector3 GetAngularVelocity(uint32 bodyId)
	{
		Vector3 result = default;
		if (mBodyInterface != null && bodyId != uint32.MaxValue)
			Jolt.JPH_BodyInterface_GetAngularVelocity(mBodyInterface, bodyId, &result);
		return result;
	}

	public override void SetAngularVelocity(uint32 bodyId, Vector3 velocity)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return;
		var value = velocity;
		Jolt.JPH_BodyInterface_SetAngularVelocity(mBodyInterface, bodyId, &value);
	}

	public override void SetBodyVelocities(uint32 bodyId, Vector3 linear, Vector3 angular)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return;
		var l = linear;
		var a = angular;
		Jolt.JPH_BodyInterface_SetLinearVelocity(mBodyInterface, bodyId, &l);
		Jolt.JPH_BodyInterface_SetAngularVelocity(mBodyInterface, bodyId, &a);
		Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
	}

	public override void AddForce(uint32 bodyId, Vector3 force)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return;
		var f = force;
		Jolt.JPH_BodyInterface_AddForce(mBodyInterface, bodyId, &f);
	}

	public override void AddForceAtPosition(uint32 bodyId, Vector3 force, Vector3 point)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return;
		var f = force;
		var p = point;
		Jolt.JPH_BodyInterface_AddForce2(mBodyInterface, bodyId, &f, &p);
		Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
	}

	public override void AddTorque(uint32 bodyId, Vector3 torque)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return;
		var t = torque;
		Jolt.JPH_BodyInterface_AddTorque(mBodyInterface, bodyId, &t);
		Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
	}

	public override void AddImpulse(uint32 bodyId, Vector3 impulse)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return;
		var i = impulse;
		Jolt.JPH_BodyInterface_AddImpulse(mBodyInterface, bodyId, &i);
	}

	public override Vector3 GetPointVelocity(uint32 bodyId, Vector3 point)
	{
		Vector3 result = default;
		if (mBodyInterface == null || bodyId == uint32.MaxValue) return result;
		var p = point;
		Jolt.JPH_BodyInterface_GetPointVelocity(mBodyInterface, bodyId, &p, &result);
		return result;
	}

	public override void SetSleeping(uint32 bodyId, bool sleeping)
	{
		if (mBodyInterface == null) return;
		if (sleeping)
			Jolt.JPH_BodyInterface_DeactivateBody(mBodyInterface, bodyId);
		else
			Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
	}

	public override void ActivateBody(uint32 bodyId)
	{
		if (mBodyInterface != null)
			Jolt.JPH_BodyInterface_ActivateBody(mBodyInterface, bodyId);
	}

	public override bool IsSleeping(uint32 bodyId) => mBodyInterface != null && !Jolt.JPH_BodyInterface_IsActive(mBodyInterface, bodyId);

	public override void SetObjectCode(uint32 bodyId, uint32 objectCode)
	{
		if (mBodyInterface == null) return;
		Jolt.JPH_BodyInterface_SetObjectLayer(mBodyInterface, bodyId, objectCode);
		mBroadPhaseDirty = true;
	}

	public override uint32 GetObjectCode(uint32 bodyId) => mBodyInterface != null ? Jolt.JPH_BodyInterface_GetObjectLayer(mBodyInterface, bodyId) : 0;

	public override void AddBodyToWorld(uint32 bodyId, bool activate)
	{
		if (mBodyInterface != null)
			Jolt.JPH_BodyInterface_AddBody(mBodyInterface, bodyId, activate ? Jolt.Activate : Jolt.DontActivate);
		mBroadPhaseDirty = true;
	}

	public override void RemoveBodyFromWorld(uint32 bodyId)
	{
		if (mBodyInterface != null)
			Jolt.JPH_BodyInterface_RemoveBody(mBodyInterface, bodyId);
		mBroadPhaseDirty = true;
	}

	public override bool ApplyBuoyancy(uint32 bodyId, Vector3 surfacePoint, Vector3 surfaceNormal, float buoyancy, float linearDrag, float angularDrag, Vector3 fluidVelocity, float deltaTime)
	{
		if (mBodyInterface == null || bodyId == uint32.MaxValue)
			return false;
		var point = surfacePoint;
		var normal = surfaceNormal;
		var flow = fluidVelocity;
		var gravity = mGravity;
		if (!Jolt.JPH_BodyInterface_ApplyBuoyancyImpulse(mBodyInterface, bodyId, &point, &normal, buoyancy, linearDrag * 0.5f, angularDrag * 0.05f, &flow, &gravity, deltaTime))
			return false;
		// How much of it is under, measured up and down its box in the world.
		var under = 1.0f;
		if (mShapes.TryGetValue(bodyId, let shape) && shape != null)
		{
			Bounds local = default;
			Jolt.JPH_Shape_GetLocalBounds(shape, &local);
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

	// ---- queries ----

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
		if (size.x <= 0 || size.y <= 0 || size.z <= 0) return null;
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

	void* QueryShape(ShapeDesc desc, out bool temporary)
	{
		temporary = false;
		switch (desc.kind)
		{
		case .Sphere: return SphereQueryShape(desc.radius);
		case .Capsule: return CapsuleQueryShape(desc.halfHeight, desc.radius);
		case .Box: return BoxQueryShape(desc.halfExtents * 2);
		default:
			temporary = true;
			return CreateShape(desc);
		}
	}

	public override bool Raycast(Vector3 origin, Vector3 direction, float maxDistance, uint32 layerMask, uint32 ignoreBody, out PhysicsRayHit hit)
	{
		hit = default;
		hit.bodyId = uint32.MaxValue;
		if (mSystem == null) return false;
		var from = origin;
		var delta = direction * maxDistance;
		Jolt.RayCastResult result = default;
		let query = Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem);
		if (!Jolt.JPH_NarrowPhaseQuery_CastRay(query, &from, &delta, &result, null, Jolt.tn_physics_layer_filter(layerMask), null))
			return false;
		hit.bodyId = result.bodyId;
		hit.fraction = result.fraction;
		hit.subShapeId = result.subShapeId;
		return true;
	}

	public override int RaycastAll(Vector3 origin, Vector3 direction, float maxDistance, uint32 layerMask, uint32 ignoreBody, List<PhysicsRayHit> hits)
	{
		hits.Clear();
		if (mSystem == null) return 0;
		var from = origin;
		var delta = direction * maxDistance;
		Jolt.RayHit[32] local = default;
		Jolt.RayHit* buffer = &local;
		int32 count = Jolt.tn_physics_cast_ray_all(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), &from, &delta, ignoreBody, buffer, 32, layerMask);
		Jolt.RayHit[] large = null;
		defer
		{
			delete large;
		}
		if (count > 32)
		{
			large = new .[count];
			buffer = large.Ptr;
			count = Math.Min(count, Jolt.tn_physics_cast_ray_all(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), &from, &delta, ignoreBody, buffer, count, layerMask));
		}
		for (int i < count)
		{
			PhysicsRayHit hit = default;
			hit.bodyId = buffer[i].bodyId;
			hit.fraction = buffer[i].fraction;
			hit.subShapeId = buffer[i].subShapeId;
			hits.Add(hit);
		}
		return hits.Count;
	}

	public override bool CastShape(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, Vector3 displacement, uint32 layerMask, uint32 ignoreBody, out PhysicsShapeHit hit)
	{
		hit = default;
		hit.bodyId = uint32.MaxValue;
		if (mSystem == null) return false;
		let shape = QueryShape(shapeDesc, let temporary);
		defer
		{
			if (temporary && shape != null)
				Jolt.JPH_Shape_Destroy(shape);
		}
		if (shape == null) return false;
		var from = origin;
		var rot = rotation;
		var move = displacement;
		Jolt.ShapeHit native = default;
		if (!Jolt.tn_physics_cast_shape(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), shape, &from, &rot, &move, ignoreBody, &native, layerMask))
			return false;
		hit.bodyId = native.bodyId;
		hit.fraction = native.fraction;
		hit.point = native.point;
		hit.normal = native.normal;
		hit.penetrationDepth = native.penetrationDepth;
		hit.subShapeId = native.subShapeId;
		return true;
	}

	public override int CastShapeAll(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, Vector3 displacement, uint32 layerMask, uint32 ignoreBody, List<PhysicsShapeHit> hits)
	{
		hits.Clear();
		if (mSystem == null) return 0;
		let shape = QueryShape(shapeDesc, let temporary);
		defer
		{
			if (temporary && shape != null)
				Jolt.JPH_Shape_Destroy(shape);
		}
		if (shape == null) return 0;
		var from = origin;
		var rot = rotation;
		var move = displacement;
		Jolt.ShapeHit[16] raw = default;
		int32 count = Jolt.tn_physics_cast_shape_all(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), shape, &from, &rot, &move, ignoreBody, &raw, raw.Count, layerMask);
		Jolt.ShapeHit[] large = null;
		if (count > raw.Count)
		{
			large = new .[count];
			// After the allocation: a one-statement defer captures large's value where it is written.
			defer:: delete large;
			count = Math.Min(count, Jolt.tn_physics_cast_shape_all(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), shape, &from, &rot, &move, ignoreBody, large.Ptr, count, layerMask));
			for (int i < count)
				hits.Add(Convert(large[i]));
		}
		else
		{
			for (int i < count)
				hits.Add(Convert(raw[i]));
		}
		return hits.Count;
	}

	static PhysicsShapeHit Convert(Jolt.ShapeHit hit)
	{
		PhysicsShapeHit result = default;
		result.bodyId = hit.bodyId;
		result.fraction = hit.fraction;
		result.point = hit.point;
		result.normal = hit.normal;
		result.penetrationDepth = hit.penetrationDepth;
		result.subShapeId = hit.subShapeId;
		return result;
	}

	public override int OverlapShape(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, uint32 layerMask, uint32 ignoreBody, List<PhysicsShapeHit> hits, bool analyticContacts)
	{
		hits.Clear();
		if (mSystem == null) return 0;
		using (sOverlapProfile.Sample())
		{
			let shape = QueryShape(shapeDesc, let temporary);
			defer
			{
				if (temporary && shape != null)
					Jolt.JPH_Shape_Destroy(shape);
			}
			if (shape == null) return 0;
			var from = origin;
			var rot = rotation;
			Jolt.ShapeHit[64] raw = default;
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
				count = Jolt.tn_physics_overlap_shape(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), shape, &from, &rot, ignoreBody, &raw, raw.Count, layerMask, analyticContacts);
			}
			if (count > raw.Count)
			{
				let large = new Jolt.ShapeHit[count];
				defer delete large;
				count = Math.Min(count, Jolt.tn_physics_overlap_shape(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), shape, &from, &rot, ignoreBody, large.Ptr, count, layerMask, analyticContacts));
				for (int i < count)
					hits.Add(Convert(large[i]));
			}
			else
			{
				for (int i < count)
					hits.Add(Convert(raw[i]));
			}
		}
		return hits.Count;
	}

	public override bool CheckShape(ShapeDesc shapeDesc, Vector3 origin, Quaternion rotation, uint32 layerMask, uint32 ignoreBody)
	{
		if (mSystem == null) return false;
		let shape = QueryShape(shapeDesc, let temporary);
		defer
		{
			if (temporary && shape != null)
				Jolt.JPH_Shape_Destroy(shape);
		}
		if (shape == null) return false;
		var from = origin;
		var rot = rotation;
		return Jolt.tn_physics_check_shape(Jolt.JPH_PhysicsSystem_GetNarrowPhaseQuery(mSystem), shape, &from, &rot, ignoreBody, layerMask);
	}

	public override bool HitDetail(uint32 bodyId, uint32 subShapeId, Vector3 point, out PhysicsHitDetail detail)
	{
		detail = default;
		if (mSystem == null) return false;
		var p = point;
		Jolt.HitDetail native = default;
		if (!Jolt.tn_physics_hit_detail(mSystem, bodyId, subShapeId, &p, &native))
			return false;
		detail.normal = native.normal;
		detail.part = native.part;
		detail.triangle = native.triangle;
		return true;
	}

	// ---- joints ----

	public override void* CreateJoint(PhysicsJointDesc desc)
	{
		if (mSystem == null) return null;
		var anchor = desc.anchor;
		var axis = desc.axis;
		switch (desc.kind)
		{
		case .Ball:
			return Jolt.tn_joint_create(mSystem, desc.bodyA, desc.bodyB, &anchor, &axis, desc.swingLimitRadians);
		case .Hinge:
			var childAxis = desc.childAxis;
			var childNormal = desc.childNormal;
			return Jolt.tn_hinge_create(mSystem, desc.bodyA, desc.bodyB, &anchor, &axis, &childAxis, &childNormal);
		case .Slider:
			var childAnchor = desc.childAnchor;
			var sliderAxis = desc.childAxis;
			var sliderNormal = desc.childNormal;
			return Jolt.tn_slider_create(mSystem, desc.bodyA, desc.bodyB, &anchor, &childAnchor, &axis, &sliderAxis, &sliderNormal, Math.Max(0.001f, desc.travel));
		}
		return null;
	}

	public override void DestroyJoint(void* joint)
	{
		if (mSystem != null && joint != null)
			Jolt.tn_joint_destroy(mSystem, joint);
	}

	public override void SetSliderSpring(void* joint, float stiffness, float damping)
	{
		Jolt.tn_slider_spring(joint, stiffness, damping);
	}

	public override float SliderPosition(void* joint) => Jolt.tn_slider_position(joint);
	public override void SetHingeMotor(void* joint, float speed, float torque, float angle, int32 mode, float response, float maximumSpeed)
		=> Jolt.tn_hinge_motor(joint, speed, torque, angle, mode, response, maximumSpeed);
	public override float HingeAngle(void* joint) => Jolt.tn_hinge_angle(joint);

	// ---- characters ----

	public override void* CreateCharacter(PhysicsCharacterDesc desc, ShapeDesc shapeDesc)
	{
		if (mSystem == null) return null;
		let shape = CreateShape(shapeDesc);
		if (shape == null) return null;
		var position = desc.position;
		var rotation = desc.rotation;
		let character = Jolt.tn_character_create(mSystem, shape, &position, &rotation, desc.maxSlopeRadians,
			Math.Max(desc.mass, 0.001f), Math.Max(desc.pushStrength, 0), desc.supportHeight,
			desc.objectCode, desc.userData, desc.innerBody, desc.soft);
		// The character and its inner body hold their own references.
		Jolt.JPH_Shape_Destroy(shape);
		return character;
	}

	public override void DestroyCharacter(void* character)
	{
		if (mSystem != null && character != null)
			Jolt.tn_character_destroy(character, mSystem);
	}

	public override uint32 CharacterInnerBody(void* character) => character != null && mSystem != null ? Jolt.tn_character_inner_body(character) : uint32.MaxValue;

	public override CharacterState GetCharacterState(void* character)
	{
		CharacterState state = default;
		if (mSystem == null || character == null) return state;
		Jolt.CharacterState native = default;
		Jolt.tn_character_get_state(character, &native);
		return Convert(native);
	}

	static CharacterState Convert(Jolt.CharacterState native)
	{
		CharacterState state = default;
		state.position = native.position;
		state.velocity = native.velocity;
		state.groundNormal = native.groundNormal;
		state.groundVelocity = native.groundVelocity;
		state.groundState = native.groundState;
		state.groundBody = native.groundBody;
		return state;
	}

	public override CharacterState MoveCharacter(void* character, uint32 objectCode, Vector3 velocity, float deltaTime, float stepHeight, float stepReach, bool soft)
	{
		CharacterState state = default;
		if (mSystem == null || character == null) return state;
		var v = velocity;
		Jolt.CharacterState native = default;
		Jolt.tn_character_move(character, mSystem, objectCode, &v, deltaTime, Math.Max(stepHeight, 0), Math.Max(stepHeight, 0), Math.Max(stepReach, 0.15f), soft, &native);
		return Convert(native);
	}

	public override void SetCharacterState(void* character, uint32 objectCode, Vector3 position, Quaternion rotation, Vector3 velocity, bool soft)
	{
		if (mSystem == null || character == null) return;
		var p = position;
		var r = rotation;
		var v = velocity;
		Jolt.tn_character_set_state(character, mSystem, objectCode, &p, &r, &v, soft);
	}

	public override bool SetCharacterShape(void* character, uint32 objectCode, ShapeDesc shapeDesc, float maxPenetration, bool soft)
	{
		if (mSystem == null || character == null) return false;
		let shape = CreateShape(shapeDesc);
		if (shape == null) return false;
		let fits = Jolt.tn_character_set_shape(character, mSystem, objectCode, shape, maxPenetration, soft);
		Jolt.JPH_Shape_Destroy(shape);
		return fits;
	}

	public override int CharacterHits(void* character, Span<CharacterHit> hits)
	{
		if (mSystem == null || character == null || hits.Length == 0)
			return 0;
		Jolt.CharacterHit[] native = new .[hits.Length];
		defer delete native;
		let count = Jolt.tn_character_hits(character, native.Ptr, (int32)hits.Length);
		for (int i < count)
		{
			CharacterHit hit = default;
			hit.body = native[i].body;
			hit.reserved = native[i].reserved;
			hit.userData = native[i].userData;
			hit.point = native[i].point;
			hit.normal = native[i].normal;
			hits[i] = hit;
		}
		return count;
	}

	// ---- snapshots ----

	public override void* SaveState(void* reuse) => mSystem != null ? Jolt.tn_physics_state_save(mSystem, reuse) : reuse;

	public override bool RestoreState(void* state) => mSystem != null && state != null && Jolt.tn_physics_state_restore(mSystem, state);

	public override int StateSize(void* state) => state != null ? Jolt.tn_physics_state_size(state) : 0;

	public override void FreeState(void* state)
	{
		if (state != null)
			Jolt.tn_physics_state_free(state);
	}

	public override void* StateFromBytes(Span<uint8> data)
	{
		if (mSystem == null || data.Length == 0) return null;
		return Jolt.tn_physics_state_from(data.Ptr, data.Length);
	}

	public override void StateToBytes(void* state, List<uint8> into)
	{
		into.Clear();
		if (state == null) return;
		let size = Jolt.tn_physics_state_size(state);
		into.Count = size;
		Jolt.tn_physics_state_copy(state, into.Ptr, size);
	}

	public override void SaveShared(uint32 firstIndex, List<uint8> into)
	{
		into.Clear();
		if (mSystem == null) return;
		let state = Jolt.tn_physics_state_save_shared(mSystem, firstIndex);
		StateToBytes(state, into);
		Jolt.tn_physics_state_free(state);
	}
}
