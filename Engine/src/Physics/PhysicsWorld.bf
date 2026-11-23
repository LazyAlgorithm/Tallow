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
	/// Which way the surface faces where it was hit.
	public Vector3 normal;
	/// The physics body hit.
	public uint32 bodyId;
	/// Which part of a Compound Collider was hit (its boxes, then cylinders, then hulls, in the order added); -1
	/// for other shapes.
	public int32 part;
	/// Which triangle of a Mesh Collider's mesh was hit (its index: the triangle's first index is 3 times it); -1
	/// for other shapes.
	public int32 triangle;
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
	/// Which part of a Compound Collider was touched; -1 for other shapes.
	public int32 part;
	/// Which triangle of a Mesh Collider's mesh was touched; -1 for other shapes.
	public int32 triangle;
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

/// One physics simulation per scene. This is the engine-owned front end: bodies are created by Rigidbody and
/// Collider components while playing, and all bookkeeping (transforms, entries, layers, world states, callbacks)
/// stays here. The selected PhysicsBackendWorld does the library-specific work.
///
/// The backend is chosen per project (ProjectConfig.Physics3DBackendId) and made lazily, after a scene has set
/// FollowsWorldStates and capacities. Jolt is the default.
class PhysicsWorld
{
	/// The provider this world was created for; null when the build has no 3D physics at all.
	public PhysicsBackend BackendProvider { get; private set; }
	PhysicsBackendWorld mBackend;

	/// What this world's backend supports. Before the backend is made this is the provider's declared set.
	public PhysicsFeatures Features => mBackend != null ? mBackend.Features : (BackendProvider != null ? BackendProvider.Features : .None);
	public bool Supports(PhysicsFeature feature) => Features.Has(feature);
	/// Whether this backend can run lockstep networking: exact snapshots, shared state to send, fixed body ids and
	/// the same results on every platform. Other network modes only need the ordinary body snapshot.
	public bool CanLockstep => Supports(.SaveRestoreExact) && Supports(.SharedPhysicsState) && Supports(.FixedBodyIds) && Supports(.CrossPlatformDeterminism);

	/// The selected backend's soft bodies and ropes. Null when it has none; components check Supports first.
	public PhysicsSoftBodyExtension SoftBodies => mBackend != null ? mBackend.SoftBodies : null;
	/// The selected backend's static geometry for navigation baking, or null when it cannot supply it.
	public PhysicsGeometryExtension Geometry => mBackend != null ? mBackend.Geometry : null;
	/// The selected backend's ragdolls, or null when it has none.
	public PhysicsRagdollExtension Ragdolls => mBackend != null ? mBackend.Ragdolls : null;
	/// The selected backend's vehicles, or null when it has none.
	public PhysicsVehicleExtension Vehicles => mBackend != null ? mBackend.Vehicles : null;
	/// Whether the selected backend provides this kind of vehicle. Kinds are opt-in: a backend may offer only
	/// wheeled vehicles without implementing motorcycles or tracks.
	public bool SupportsVehicleKind(PhysicsVehicleKind kind) => Features.Has(PhysicsVehicleKinds.Feature(kind));

	/// Overlap queries work out the contacts of a sphere or capsule with a box directly where they can (the shape's
	/// middle inside the box), and with the backend's general solver otherwise. Off, always the general solver, for comparing.
	public bool useAnalyticOverlapContacts = true;

	int32 mBodyCapacity = 16384, mBodyPairCapacity = 65536, mContactCapacity = 16384;
	// The step errors already logged, so each kind is logged once.
	int32 mReportedStepErrors;

	/// How many bodies the world holds at most, how many pairs of them can touch at once, and how many contacts the
	/// solver handles in a step (ConfigureCapacity).
	public int32 BodyCapacity => mBodyCapacity;
	public int32 BodyPairCapacity => mBodyPairCapacity;
	public int32 ContactCapacity => mContactCapacity;
	/// What ran out in the last Step, as the backend's bits (0 when nothing did). Contacts are missing from that step.
	public int32 LastStepError { get; private set; }
	/// How long the backend's own step (collision and solving, not Tallow's work round it) took last time.
	public float LastStepMilliseconds { get; private set; }

	/// Sets the capacities, before the world's first body (or query) creates the backend. False when it already
	/// exists or a number is not positive.
	public bool ConfigureCapacity(int32 bodies, int32 bodyPairs, int32 contacts)
	{
		if (mBackend != null || bodies <= 0 || bodyPairs <= 0 || contacts <= 0) return false;
		mBodyCapacity = bodies;
		mBodyPairCapacity = bodyPairs;
		mContactCapacity = contacts;
		return true;
	}

	static ProfilerMarker sOverlapProfile = .("Physics.Overlap", .Physics);

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
			if (mBackend != null)
				mBackend.SetLengthScale(next / mLengthScale);
			mLengthScale = next;
		}
	}

	/// Whether bodies of objects outside the scene's world state are left out (true for a scene's own world). A
	/// world made to bake navigation for a chosen state turns it off and picks its objects itself.
	public bool FollowsWorldStates = true;

	/// World states set apart in this world (ProjectConfig.SeparateWorldStates), read when the world is made: 0 when
	/// they are not. With them apart, no body leaves the simulation when the scene's state changes; each collides
	/// only with bodies sharing one of its world states.
	int32 mSeparateWorlds;
	public bool SeparatesWorldStates => mSeparateWorlds > 0;

	/// The world states ray, shape and overlap queries see, one bit per state (all of them by default). With
	/// ProjectConfig.SeparateWorldStates on, set it to a player's own states around that player's queries, then back
	/// to uint32.MaxValue. Objects in every state are always seen. Without separation it has no effect.
	public uint32 QueryWorldStates = uint32.MaxValue;

	class Entry
	{
		public uint32 bodyId;
		public Transform transform;
		public bool dynamic;
		public bool kinematic;
		public uint32 lastVersion;
		/// The body belongs to a character controller, which moves and destroys it; it is listed so queries can name its object.
		public bool external;
		/// Taken out of the simulation because its object is not in the active world state.
		public bool outOfWorld;
		/// Where it is in mEntries and in mMoving (-1: not there).
		public int32 index;
		public int32 movingIndex = -1;
	}

	// The object code is the backend's layer: motion class times the project's layers plus the GameObject's layer,
	// offset by its world group. PhysicsLayerTable owns the packing; these are the motion classes it uses.
	public const uint32 LayerStatic = PhysicsLayerTable.StaticClass;
	public const uint32 LayerMoving = PhysicsLayerTable.MovingClass;
	public const uint32 LayerDebris = PhysicsLayerTable.DebrisClass;
	public static uint32 LayersPerClass => PhysicsLayerTable.LayersPerClass;
	public static uint32 LayersPerGroup => PhysicsLayerTable.LayersPerGroup;

	public static uint32 ObjectLayer(uint32 motionClass, int32 layer, uint32 group = 0) => PhysicsLayerTable.ObjectCode(motionClass, layer, group);
	uint32 ObjectLayer(uint32 motionClass, Transform transform) => transform == null ? ObjectLayer(motionClass, 0) : ObjectLayer(motionClass, transform.GameObject.Layer, WorldGroup(transform.GameObject));

	/// The object code the engine would give this transform for a motion class, for components that create their
	/// own bodies (soft bodies and ropes currently).
	public uint32 ObjectCode(uint32 motionClass, Transform transform) => ObjectLayer(motionClass, transform);

	/// The world group of an object: 0 when world states are not set apart or it is in all of the separated ones.
	uint32 WorldGroup(GameObject gameObject)
	{
		if (mSeparateWorlds == 0)
			return 0;
		let full = (uint32)(((uint32)1 << mSeparateWorlds) - 1);
		let mask = gameObject.EffectiveWorldStates & full;
		return (mask == full || mask == 0) ? (uint32)0 : mask;
	}

	/// The world group mask a query sees (uint32.MaxValue: all).
	uint32 QueryWorldGroups => (mSeparateWorlds == 0 || QueryWorldStates == uint32.MaxValue) ? uint32.MaxValue : QueryWorldStates & (uint32)(((uint32)1 << mSeparateWorlds) - 1);

	List<Entry> mEntries = new .() ~ DeleteContainerAndItems!(_);
	/// The dynamic and kinematic entries: a big level is mostly static bodies, and Step need not touch those.
	List<Entry> mMoving = new .() ~ delete _;
	List<void*> mCharacters = new .() ~ delete _;
	/// Every live character controller in this world, for the soft push between characters.
	public List<CharacterControllerState> Controllers = new .() ~ delete _;
	/// Changes whenever Controllers or a controller's shape changes (SoftCharacterGrid rebuilds then).
	public int ControllersVersion;
	public SoftCharacterGrid SoftCharacters = new .() ~ delete _;
	Dictionary<uint32, Entry> mByBody = new .() ~ delete _;

	/// Gravity, in metres a second squared.
	public Vector3 Gravity = .(0, -9.81f, 0);

	/// How many bodies are in the world.
	public int32 BodyCount => (int32)mEntries.Count;
	/// How many joints are in the world.
	public int32 JointCount => (int32)mJoints.Count;

	/// An empty world using the project's 3D backend. The backend itself is made on first use, so a scene (or a
	/// navigation bake) can set capacities and FollowsWorldStates first.
	public this()
	{
		BackendProvider = PhysicsBackends.Selected3D;
	}

	/// A world using a chosen backend, for tools, tests and conformance runs.
	public this(PhysicsBackend provider)
	{
		BackendProvider = provider;
	}

	public ~this()
	{
		Clear();
		if (mBackend != null)
		{
			delete mBackend;
			mBackend = null;
		}
	}

	/// Kept for the components that still create their own native bodies (soft bodies, ropes, water, navigation).
	/// It makes the backend now, exactly as the old lazy world creation did.
	public void EnsureCreated() => EnsureBackend();

	void EnsureBackend()
	{
		if (mBackend != null || BackendProvider == null)
			return;
		ProjectConfig.EnsureLoaded();
		PhysicsWorldSettings settings = default;
		settings.bodyCapacity = mBodyCapacity;
		settings.bodyPairCapacity = mBodyPairCapacity;
		settings.contactCapacity = mContactCapacity;
		settings.gravity = Gravity;
		settings.lengthScale = mLengthScale;
		settings.minimumShapeExtent = MinimumShapeExtent;
		settings.contactEvents = ContactEvents;
		settings.separateWorldStates = FollowsWorldStates ? ProjectConfig.SeparatedWorldStateCount : 0;
		mSeparateWorlds = settings.separateWorldStates;
		mBackend = BackendProvider.CreateWorld(settings);
	}

	/// Collision and trigger callbacks (Component.OnCollisionEnter/Exit, OnTriggerEnter/Exit). Set before the world
	/// makes its first body; off costs nothing per contact.
	public bool ContactEvents = true;

	/// After a real tick's Step (never a replayed one): calls the collision and trigger callbacks of the objects
	/// that began or stopped touching in it. Enter and exit are per pair of objects, not per contact point;
	/// objects that rest against each other stay entered while asleep.
	public void DispatchContacts(Scene scene)
	{
		if (mBackend == null || !ContactEvents)
			return;
		let events = scope List<PhysicsContactEvent>();
		mBackend.CollectContacts(events);
		if (events.Count == 0)
			return;
		let components = scope List<Component>();
		for (let event in events)
		{
			for (int side < 2)
			{
				let selfId = side == 0 ? event.objectA : event.objectB;
				let otherId = side == 0 ? event.objectB : event.objectA;
				let self = ContactObject(scene, selfId, side == 0 ? event.bodyA : event.bodyB);
				if (self == null || !self.ActiveInHierarchy)
					continue;
				let other = ContactObject(scene, otherId, side == 0 ? event.bodyB : event.bodyA);
				Collision collision = .();
				collision.gameObject = other;
				collision.point = event.point;
				// Out of the other object, towards this one.
				collision.normal = side == 0 ? -event.normal : event.normal;
				collision.relativeSpeed = event.speed;
				components.Clear();
				components.AddRange(self.Components);
				for (let component in components)
				{
					// An earlier callback can remove a component or destroy the object.
					if (scene.FindById((uint32)selfId) != self || !self.Components.Contains(component) || !component.Enabled)
						continue;
					if (event.sensor != 0)
					{
						if (event.kind == 0)
							component.OnTriggerEnter(other);
						else if (event.kind == 2)
							component.OnTriggerStay(other);
						else
							component.OnTriggerExit(other);
					}
					else if (event.kind == 0)
						component.OnCollisionEnter(collision);
					else if (event.kind == 2)
						component.OnCollisionStay(collision);
					else
						component.OnCollisionExit(collision);
				}
			}
		}
	}

	/// What a character's last move ran into (not triggers), at most hits.Count. Returns how many.
	public int CharacterHits(void* character, Span<CharacterHit> hits)
	{
		if (!HasCharacter(character) || hits.Length == 0 || mBackend == null)
			return 0;
		return mBackend.CharacterHits(character, hits);
	}

	/// The object a contact names: by the body's user data (its object's id), else by the body.
	public GameObject ContactObject(Scene scene, uint64 id, uint32 bodyId)
	{
		if (id != 0)
		{
			if (let found = scene.FindById((uint32)id))
				return found;
		}
		return ObjectOfBody(bodyId);
	}

	GameObject ObjectOfBody(uint32 bodyId)
	{
		if (mByBody.TryGetValue(bodyId, let entry) && entry.transform != null)
			return entry.transform.GameObject;
		return mSoftBodies.TryGetValue(bodyId, let soft) ? soft.GameObject : null;
	}

	/// Removes every body, joint and character.
	public void Clear()
	{
		// Characters go first: each owns an inner body that is listed below as an external entry.
		for (let character in mCharacters)
		{
			if (mBackend != null)
				mBackend.DestroyCharacter(character);
		}
		mCharacters.Clear();
		mCharacterOwners.Clear();
		Controllers.Clear();
		ControllersVersion++;
		for (let entry in mEntries)
		{
			if (entry.external || mBackend == null)
				continue;
			if (entry.outOfWorld)
				mBackend.AddBodyToWorld(entry.bodyId, false);
			mBackend.DestroyBody(entry.bodyId);
		}
		ClearAndDeleteItems!(mEntries);
		mMoving.Clear();
		mByBody.Clear();
		for (let (bodyId, soft) in mSoftBodies)
		{
			if (mBackend != null)
				mBackend.DestroyBody(bodyId);
			soft.[Friend]mBody = uint32.MaxValue;
			soft.[Friend]mWorld = null;
			soft.[Friend]mNativeCollider = false;
		}
		mSoftBodies.Clear();
		for (let rope in mRopes)
		{
			if (mBackend != null)
				mBackend.DestroyBody(rope.BodyId);
			rope.[Friend]mTie = null;
			rope.[Friend]mBody = uint32.MaxValue;
			rope.[Friend]mWorld = null;
		}
		mRopes.Clear();
		mJoints.Clear();
		mDebris.Clear();
		// Any bodies a component made itself (a soft body or rope that was not in the lists above, for example).
		if (mBackend != null)
			mBackend.Clear();
	}

	/// Creates a body that follows (static/kinematic) or drives (dynamic) the given transform.
	/// Returns the body id, or uint32.MaxValue on failure.
	public uint32 CreateBody(Transform transform, ShapeDesc desc, RigidbodyData* rigidbody)
	{
		EnsureBackend();
		if (mBackend == null)
			return uint32.MaxValue;

		var position = transform.Position;
		var rotation = transform.Rotation;
		PhysicsMotion motion = .Static;
		if (rigidbody != null)
			motion = rigidbody.isKinematic ? .Kinematic : .Dynamic;
		// Mesh shapes cannot be dynamic in Jolt; keep the same rule for every backend so scenes behave alike.
		if (desc.kind == .Mesh && motion == .Dynamic)
			motion = .Static;
		let debris = rigidbody != null && rigidbody.debris && motion != .Static;
		// A trigger collider is a sensor: it reports what passes through and stops nothing. Without a Rigidbody it is
		// kinematic (and active), so it also notices character controllers and bodies that have gone to sleep.
		bool trigger = false;
		for (let component in transform.GameObject.Components)
		{
			if (let collider = component as Collider)
				trigger |= collider.isTrigger;
		}
		if (trigger && motion == .Static)
			motion = .Kinematic;

		PhysicsBodyDesc body = default;
		body.motion = motion;
		body.position = position;
		body.rotation = rotation;
		body.objectCode = ObjectLayer(motion == .Static ? LayerStatic : (debris ? LayerDebris : LayerMoving), transform);
		body.sensor = trigger;
		body.debris = debris;
		body.userData = (uint64)transform.GameObject.Id;
		body.wantedId = uint32.MaxValue;
		// Jolt's defaults for a collider without a Rigidbody. The neutral description is zero-initialized, so these
		// must be set explicitly or scenery has no friction (and, for a vehicle, its tires have no grip).
		body.friction = 0.5f;
		body.restitution = 0;
		body.linearDamping = 0.05f;
		body.angularDamping = 0.05f;
		body.gravityFactor = 1;
		if (rigidbody != null)
		{
			body.friction = rigidbody.friction;
			body.restitution = rigidbody.bounciness;
			body.linearDamping = rigidbody.linearDamping;
			body.angularDamping = rigidbody.angularDamping;
			body.gravityFactor = rigidbody.useGravity ? Math.Max(0, rigidbody.gravityScale) : 0;
			body.allowSleeping = rigidbody.allowSleeping;
			body.continuousCollision = rigidbody.continuousCollision;
			body.freezeRotation = rigidbody.freezeRotation;
			if (motion == .Dynamic)
			{
				body.overrideMass = true;
				body.mass = Math.Max(rigidbody.mass, 0.001f);
			}
		}
		if (FixedBodyIndex != null)
		{
			let wanted = FixedBodyIndex(transform);
			if (wanted < (uint32)mBodyCapacity && !mByBody.ContainsKey(wanted))
				body.wantedId = wanted;
		}

		uint32 bodyId = mBackend.CreateBody(body, desc);
		if (bodyId == uint32.MaxValue)
			return bodyId;

		let entry = new Entry();
		entry.bodyId = bodyId;
		entry.transform = transform;
		entry.dynamic = motion == .Dynamic;
		entry.kinematic = motion == .Kinematic;
		entry.lastVersion = transform.Version;
		Track(entry);
		mByBody[bodyId] = entry;
		if (debris)
			mDebris.Add(bodyId);
		// An object outside the active world state is kept out of the simulation until that state is active.
		if (FollowsWorldStates && mSeparateWorlds == 0 && !transform.GameObject.InActiveWorld)
		{
			mBackend.RemoveBodyFromWorld(bodyId);
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
		if (mBackend == null || !mByBody.ContainsKey(bodyA) || !mByBody.ContainsKey(bodyB) || bodyA == bodyB)
			return null;
		PhysicsJointDesc desc = default;
		desc.kind = .Ball;
		desc.bodyA = bodyA;
		desc.bodyB = bodyB;
		desc.anchor = anchor;
		desc.axis = axis.LengthSquared > 1.0e-8f ? axis.Normalized : Vector3.Up;
		desc.swingLimitRadians = Mathf.Clamp(swingLimitDegrees, 0, 179) * Mathf.Deg2Rad;
		let joint = mBackend.CreateJoint(desc);
		if (joint != null)
			mJoints.Add((joint, bodyA, bodyB, ++mJointSequence));
		return joint;
	}

	/// A hinge between two bodies, turning about axis through anchor (both in the world); childAxis and childNormal fix
	/// how the second body sits on it. Null if either body is missing.
	public void* CreateHinge(uint32 bodyA, uint32 bodyB, Vector3 anchor, Vector3 axis, Vector3 childAxis, Vector3 childNormal)
	{
		if (mBackend == null || bodyA == bodyB || !mByBody.ContainsKey(bodyA) || !mByBody.ContainsKey(bodyB)) return null;
		PhysicsJointDesc desc = default;
		desc.kind = .Hinge;
		desc.bodyA = bodyA;
		desc.bodyB = bodyB;
		desc.anchor = anchor;
		desc.axis = axis.LengthSquared > 0.00001f ? axis.Normalized : Vector3.Up;
		desc.childAxis = childAxis;
		desc.childNormal = childNormal;
		let hinge = mBackend.CreateJoint(desc);
		if (hinge != null)
			mJoints.Add((hinge, bodyA, bodyB, ++mJointSequence));
		return hinge;
	}

	/// A sliding joint along axis, travel metres either way, like a wheel's suspension. Give it a spring with
	/// SetSuspensionSpring.
	public void* CreateSuspension(uint32 bodyA, uint32 bodyB, Vector3 anchor, Vector3 childAnchor, Vector3 axis, Vector3 childAxis, Vector3 childNormal, float travel)
	{
		if (mBackend == null || bodyA == bodyB || !mByBody.ContainsKey(bodyA) || !mByBody.ContainsKey(bodyB)) return null;
		PhysicsJointDesc desc = default;
		desc.kind = .Slider;
		desc.bodyA = bodyA;
		desc.bodyB = bodyB;
		desc.anchor = anchor;
		desc.childAnchor = childAnchor;
		desc.axis = axis.Normalized;
		desc.childAxis = childAxis.Normalized;
		desc.childNormal = childNormal.Normalized;
		desc.travel = Math.Max(0.001f, travel);
		let slider = mBackend.CreateJoint(desc);
		if (slider != null)
			mJoints.Add((slider, bodyA, bodyB, ++mJointSequence));
		return slider;
	}

	/// How hard a suspension pushes back and how quickly its bouncing dies away.
	public void SetSuspensionSpring(void* slider, float stiffness, float damping)
	{
		if (HasJoint(slider) && mBackend != null)
			mBackend.SetSliderSpring(slider, stiffness, damping);
	}

	/// How far along its travel a suspension is.
	public float SuspensionPosition(void* slider) => HasJoint(slider) && mBackend != null ? mBackend.SliderPosition(slider) : 0;
	/// Drives a hinge with up to torque. Mode 0 switches the motor off, 1 spins it at speed (radians a second), 2 turns
	/// it to angle (radians), at up to maximumSpeed, faster the larger response is.
	public void SetHingeMotor(void* hinge, float speed, float torque, float angle = 0, int32 mode = 1, float response = 8, float maximumSpeed = 3)
	{
		if (!HasJoint(hinge) || mBackend == null) return;
		mBackend.SetHingeMotor(hinge, speed, Math.Max(0, torque), angle, mode, Math.Max(0.1f, response), Math.Max(0.1f, maximumSpeed));
		for (let entry in mJoints)
		{
			if (entry.joint == hinge)
			{
				mBackend.ActivateBody(entry.a);
				mBackend.ActivateBody(entry.b);
			}
		}
	}

	/// How far a hinge has turned, in radians.
	public float HingeAngle(void* hinge) => HasJoint(hinge) && mBackend != null ? mBackend.HingeAngle(hinge) : 0;

	/// Safe to call with a joint that has already gone (because one of its bodies was destroyed).
	public void DestroyJoint(void* joint)
	{
		for (int i < mJoints.Count)
		{
			if (mJoints[i].joint == joint)
			{
				if (mBackend != null)
					mBackend.DestroyJoint(joint);
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

	/// Bring all soft-body poses and render meshes up to date once per frame,
	/// BEFORE gameplay Update and camera LateUpdate. Previously SoftBody did
	/// this in its own LateUpdate: if the camera joined first it looked at
	/// yesterday's ball transform, while the ball rendered at today's.
	void SyncSoftBodiesForFrame()
	{
		if (SoftBodies == null || mSoftBodies.IsEmpty)
			return;
		for (let soft in mSoftBodies.Values)
			soft.[Friend]ReadBack();
	}

	void AddSoftBody(uint32 bodyId, SoftBody owner) => mSoftBodies[bodyId] = owner;

	/// Ropes (Rope components): each moves its ends and ties its pull before a step.
	List<Rope> mRopes = new .() ~ delete _;

	void AddRope(Rope rope) => mRopes.Add(rope);

	void RemoveRope(Rope rope)
	{
		if (mRopes.Remove(rope) && mBackend != null)
			mBackend.DestroyBody(rope.BodyId);
	}

	void RemoveSoftBody(uint32 bodyId)
	{
		if (mSoftBodies.Remove(bodyId) && mBackend != null)
			mBackend.DestroyBody(bodyId);
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
				if (mBackend != null)
					mBackend.DestroyJoint(mJoints[i].joint);
				mJoints.RemoveAt(i);
			}
		}
		mDebris.Remove(bodyId);
		if (mBackend != null)
		{
			if (entry.outOfWorld)
				mBackend.AddBodyToWorld(bodyId, false);
			mBackend.DestroyBody(bodyId);
		}
		mByBody.Remove(bodyId);
		Untrack(entry);
		delete entry;
	}

	/// Changes whenever a body is added or removed: an exact snapshot (SaveExact) can only be put back onto the same
	/// set of bodies.
	public uint32 BodyGeneration { get; private set; }

	/// Every body's state, its contacts and its constraints, exactly, into `reuse` (or a new snapshot when null). Put
	/// back with RestoreExact, stepping again gives bit for bit what it gave before. Free with FreeExact.
	public void* SaveExact(void* reuse)
	{
		if (mBackend == null)
			return reuse;
		for (let entry in mEntries)
			Flush(entry.bodyId);
		return mBackend.SaveState(reuse);
	}

	/// Puts a snapshot from SaveExact back, and every transform with its body. False if it could not be (the set of
	/// bodies changed since, or it is damaged), having changed nothing that matters.
	public bool RestoreExact(void* state)
	{
		if (mBackend == null || state == null || !mBackend.RestoreState(state))
			return false;
		for (let entry in mEntries)
		{
			if (entry.outOfWorld)
				continue;
			mBackend.GetBodyPose(entry.bodyId, let position, let rotation);
			entry.transform.SetPositionAndRotation(position, rotation);
			entry.lastVersion = entry.transform.Version;
		}
		return true;
	}

	/// How many times game code has put a moving body somewhere (SetState, or a dynamic body's transform written)
	/// rather than the simulation moving it. The network watches it in lockstep, where clients must be told.
	public uint32 Teleports;

	/// When set, the body id a new body must have (uint32.MaxValue: any). The network sets it in lockstep.
	public delegate uint32 BodyIndexFor(Transform transform);
	public BodyIndexFor FixedBodyIndex ~ delete _;

	/// The bodies from index `firstIndex` up and their contacts with static bodies, exactly, as bytes to send to another
	/// machine that gives the same bodies the same ids (lockstep).
	public void SaveShared(uint32 firstIndex, List<uint8> into)
	{
		into.Clear();
		if (mBackend == null)
			return;
		for (let entry in mEntries)
			Flush(entry.bodyId);
		mBackend.SaveShared(firstIndex, into);
	}

	/// Puts bodies' state from SaveShared on another machine in place, with their transforms. False if a body in it
	/// is not here.
	public bool RestoreShared(Span<uint8> data)
	{
		if (mBackend == null || data.Length == 0)
			return false;
		let state = mBackend.StateFromBytes(data);
		let ok = RestoreExact(state);
		mBackend.FreeState(state);
		return ok;
	}

	public int ExactSize(void* state) => state != null && mBackend != null ? mBackend.StateSize(state) : 0;
	public void FreeExact(void* state)
	{
		if (state != null && mBackend != null)
			mBackend.FreeState(state);
	}

	void Track(Entry entry)
	{
		BodyGeneration++;
		entry.index = (int32)mEntries.Count;
		mEntries.Add(entry);
		if (entry.dynamic || entry.kinematic)
		{
			entry.movingIndex = (int32)mMoving.Count;
			mMoving.Add(entry);
		}
	}

	void Untrack(Entry entry)
	{
		BodyGeneration++;
		mEntries.RemoveAtFast(entry.index);
		if (entry.index < mEntries.Count)
			mEntries[entry.index].index = entry.index;
		if (entry.movingIndex >= 0)
		{
			mMoving.RemoveAtFast(entry.movingIndex);
			if (entry.movingIndex < mMoving.Count)
				mMoving[entry.movingIndex].movingIndex = entry.movingIndex;
		}
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
		if (mBackend == null)
			return;
		// Most objects have no body: setting their layer must not look through every one.
		bool hasBody = false;
		for (let component in gameObject.Components)
			hasBody |= component is Collider;
		hasBody |= gameObject.HasComponent<Rigidbody>() || gameObject.HasComponent<CharacterController>();
		if (!hasBody)
			return;
		for (let entry in mEntries)
		{
			if (entry.transform.GameObject != gameObject)
				continue;
			let current = mBackend.GetObjectCode(entry.bodyId);
			mBackend.SetObjectCode(entry.bodyId, ObjectLayer(PhysicsLayerTable.MotionClass(current), gameObject.Layer, WorldGroup(gameObject)));
		}
	}

	/// With world states set apart: moves the bodies of an object and everything under it to the world group of
	/// their states (GameObject.WorldStates and reparenting call this through ApplyWorldState).
	void RefreshWorldGroups(GameObject root)
	{
		if (mBackend == null)
			return;
		let rootTransform = root.Transform;
		for (let entry in mEntries)
		{
			var transform = entry.transform;
			while (transform != null && transform != rootTransform)
				transform = transform.Parent;
			if (transform == null)
				continue;
			let gameObject = entry.transform.GameObject;
			let current = mBackend.GetObjectCode(entry.bodyId);
			let next = ObjectLayer(PhysicsLayerTable.MotionClass(current), gameObject.Layer, WorldGroup(gameObject));
			if (next != current)
				mBackend.SetObjectCode(entry.bodyId, next);
		}
	}

	/// Takes bodies of objects outside the scene's active world state out of the simulation and puts back those
	/// inside it (Scene.WorldState calls this). A character's own body stays: the character decides where it goes.
	public void ApplyWorldState(Scene scene)
	{
		if (!FollowsWorldStates || mSeparateWorlds > 0)
			return;
		if (mBackend == null)
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
				mBackend.SetBodyPose(entry.bodyId, position, rotation, false);
				mBackend.AddBodyToWorld(entry.bodyId, true);
				entry.outOfWorld = false;
				entry.lastVersion = entry.transform.Version;
			}
			else if (!inWorld && !entry.outOfWorld)
			{
				mBackend.RemoveBodyFromWorld(entry.bodyId);
				entry.outOfWorld = true;
			}
		}
	}

	/// The same after one object's world states changed (its children's bodies may change with it).
	public void ApplyWorldState(GameObject gameObject)
	{
		if (mSeparateWorlds > 0)
			RefreshWorldGroups(gameObject);
		else
			ApplyWorldState(gameObject.Scene);
	}

	/// True when two objects can meet: always without world states set apart, else when they share a world state
	/// (an object in every state meets everything). For engine code that pairs objects itself (character pushes,
	/// water), as the physics does for bodies.
	public bool ShareWorld(GameObject a, GameObject b)
	{
		if (mSeparateWorlds == 0 || a == null || b == null)
			return true;
		let groupA = WorldGroup(a);
		let groupB = WorldGroup(b);
		return groupA == 0 || groupB == 0 || (groupA & groupB) != 0;
	}

	/// True when the body is taking part in the simulation (false while its object is outside the active world state).
	public bool IsInWorld(uint32 bodyId) => mByBody.TryGetValue(bodyId, let entry) && !entry.outOfWorld;

	// ---- character controllers ----

	void TrackInnerBody(void* character, Transform transform)
	{
		if (mBackend == null)
			return;
		let bodyId = mBackend.CharacterInnerBody(character);
		if (bodyId == uint32.MaxValue)
			return;
		let entry = new Entry();
		entry.bodyId = bodyId;
		entry.transform = transform;
		entry.lastVersion = transform.Version;
		entry.external = true;
		Track(entry);
		mByBody[bodyId] = entry;
	}

	void UntrackInnerBody(void* character)
	{
		if (mBackend == null)
			return;
		if (!mByBody.TryGetValue(mBackend.CharacterInnerBody(character), let entry))
			return;
		mByBody.Remove(entry.bodyId);
		Untrack(entry);
		delete entry;
	}

	/// Creates a character that is moved by sweeping its shape (see CharacterController). supportHeight is how far above
	/// the transform's position a contact still counts as the floor. Returns null if the shape cannot be built.
	public void* CreateCharacter(Transform transform, ShapeDesc desc, Quaternion rotationIn, float maxSlopeDegrees, float mass, float pushStrength, float supportHeight, bool soft)
	{
		EnsureBackend();
		if (mBackend == null)
			return null;
		PhysicsCharacterDesc characterDesc = default;
		characterDesc.position = transform.Position;
		characterDesc.rotation = rotationIn;
		characterDesc.maxSlopeRadians = Mathf.Clamp(maxSlopeDegrees, 1, 89) * Mathf.Deg2Rad;
		characterDesc.mass = Math.Max(mass, 0.001f);
		characterDesc.pushStrength = Math.Max(pushStrength, 0);
		characterDesc.supportHeight = supportHeight;
		characterDesc.objectCode = ObjectLayer(LayerMoving, transform);
		characterDesc.userData = (uint64)transform.GameObject.Id;
		characterDesc.innerBody = true;
		characterDesc.soft = soft;
		let character = mBackend.CreateCharacter(characterDesc, desc);
		if (character == null)
			return null;
		mCharacters.Add(character);
		mCharacterOwners[character] = transform;
		TrackInnerBody(character, transform);
		// Find the floor now, so ground state is right before the first move.
		var velocity = Vector3.Zero;
		EnsureQueryPrepared();
		mBackend.SetCharacterState(character, CharacterLayer(character), characterDesc.position, rotationIn, velocity, soft);
		return character;
	}

	/// Safe to call with a character this world has already destroyed.
	public void DestroyCharacter(void* character)
	{
		if (!mCharacters.Remove(character))
			return;
		mCharacterOwners.Remove(character);
		UntrackInnerBody(character);
		if (mBackend != null)
			mBackend.DestroyCharacter(character);
	}

	/// Whether a character controller's body is still in the world.
	/// A dictionary lookup: every character asks this several times a tick (a list scan made 1,000 walkers O(n²)).
	public bool HasCharacter(void* character) => character != null && mCharacterOwners.ContainsKey(character);

	/// Where a character is, how fast it moves and what it stands on.
	public CharacterState GetCharacterState(void* character)
	{
		CharacterState state = default;
		if (HasCharacter(character) && mBackend != null)
			state = mBackend.GetCharacterState(character);
		return state;
	}

	/// Moves a character for one step at the given velocity, climbing steps up to stepHeight and following the floor
	/// down by the same amount. stepReach is how far past a step's edge its top is probed for a place to stand.
	public CharacterState MoveCharacter(void* character, Vector3 velocityIn, float deltaTime, float stepHeight, float stepReach, bool soft)
	{
		if (!HasCharacter(character) || mBackend == null || !Finite(velocityIn) || !deltaTime.IsFinite || deltaTime <= 0)
			return GetCharacterState(character);
		EnsureQueryPrepared();
		mBackend.SetGravity(Gravity);
		var velocity = velocityIn;
		let step = Math.Max(stepHeight, 0);
		return mBackend.MoveCharacter(character, CharacterLayer(character), velocity, deltaTime, step, Math.Max(stepReach, 0.15f), soft);
	}

	/// Teleports a character and gives it a velocity; its contacts are rebuilt at the new place.
	public void SetCharacterState(void* character, Vector3 positionIn, Quaternion rotationIn, Vector3 velocityIn, bool soft)
	{
		if (!HasCharacter(character) || mBackend == null || !Finite(positionIn) || !Finite(velocityIn) || !ValidRotation(rotationIn))
			return;
		EnsureQueryPrepared();
		mBackend.SetCharacterState(character, CharacterLayer(character), positionIn, rotationIn, velocityIn, soft);
	}

	/// True if the shape fits where the character stands, allowing that much overlap with the surroundings.
	/// The character switches to the shape when it fits.
	public bool TrySetCharacterShape(void* character, ShapeDesc desc, float maxPenetration, bool soft)
	{
		if (!HasCharacter(character) || mBackend == null)
			return false;
		EnsureQueryPrepared();
		return mBackend.SetCharacterShape(character, CharacterLayer(character), desc, maxPenetration, soft);
	}

	/// Advances the simulation by one fixed tick and writes the results to the transforms.
	public void Step(float deltaTime)
	{
		LastStepError = 0;
		EnsureBackend();
		if (mBackend == null || (mEntries.Count == 0 && mSoftBodies.Count == 0 && mRopes.Count == 0))
			return;
		EnsureQueryPrepared();
		mBackend.SetGravity(Gravity);

		// Transforms moved by gameplay or the network since the last step win over the simulation.
		for (let entry in mEntries)
		{
			if (entry.transform.Version == entry.lastVersion)
				continue;
			entry.lastVersion = entry.transform.Version;
			if (entry.external || entry.outOfWorld)
				continue;
			var position = entry.transform.Position;
			var rotation = entry.transform.Rotation;
			if (entry.kinematic)
				mBackend.MoveKinematic(entry.bodyId, position, rotation, deltaTime);
			else
			{
				if (entry.dynamic)
					Teleports++;
				mBackend.SetBodyPose(entry.bodyId, position, rotation, true);
			}
		}

		for (let soft in mSoftBodies.Values)
			soft.[Friend]BeforeStep(deltaTime);
		for (let rope in mRopes)
			rope.[Friend]BeforeStep(deltaTime);
		SoftBody.[Friend]UpdateProxies(this, mSoftBodies, mRopes);

		mBackend.BeginContactStep();
		using (sStepTimer.Sample())
		{
			mBackend.Step(deltaTime, let errorMask, let milliseconds);
			LastStepError = errorMask;
			LastStepMilliseconds = milliseconds;
		}
		if (LastStepError != 0 && (mReportedStepErrors & LastStepError) != LastStepError)
		{
			Log.Error(scope $"[Physics] Solver capacity exceeded (error mask {LastStepError}); contacts may be missing. ConfigureCapacity before creating the world. Current bodies/pairs/contacts: {mBodyCapacity}/{mBodyPairCapacity}/{mContactCapacity}.");
			mReportedStepErrors |= LastStepError;
		}

		for (let entry in mMoving)
		{
			if (!entry.outOfWorld)
			{
				mBackend.GetBodyPose(entry.bodyId, let position, let rotation);
				entry.transform.SetPositionAndRotation(position, rotation);
			}
			entry.lastVersion = entry.transform.Version;
		}
	}

	static ProfilerMarker sStepTimer = .("Physics.BackendStep", .Physics);

	/// Pushes a transform that gameplay moved since the last step into the backend right away, so
	/// reads and writes of body state in the same tick see the new pose.
	void Flush(uint32 bodyId)
	{
		if (!mByBody.TryGetValue(bodyId, let entry) || mBackend == null || entry.transform.Version == entry.lastVersion)
			return;
		// A kinematic body is moved by the next step (MoveKinematic, which gives it the velocity that pushes what it
		// meets); teleporting it here would leave that out, so how a tick plays would depend on whether something
		// read its state first.
		if (entry.kinematic && !entry.external && !entry.outOfWorld)
			return;
		if (entry.dynamic)
			Teleports++;
		var position = entry.transform.Position;
		var rotation = entry.transform.Rotation;
		mBackend.SetBodyPose(bodyId, position, rotation, true);
		entry.lastVersion = entry.transform.Version;
	}

	/// A body's position, rotation and velocities, to put back with SetState.
	public BodyState GetState(uint32 bodyId)
	{
		BodyState state = default;
		state.rotation = .Identity;
		if (mBackend == null || bodyId == uint32.MaxValue)
			return state;
		Flush(bodyId);
		mBackend.GetBodyPose(bodyId, let position, let rotation);
		state.position = position;
		state.rotation = rotation;
		state.linearVelocity = mBackend.GetLinearVelocity(bodyId);
		state.angularVelocity = mBackend.GetAngularVelocity(bodyId);
		// A kinematic body moved this tick is where its transform says (the step takes it there).
		if (mByBody.TryGetValue(bodyId, let entry) && entry.kinematic && entry.transform.Version != entry.lastVersion)
		{
			state.position = entry.transform.Position;
			state.rotation = entry.transform.Rotation;
		}
		return state;
	}

	/// Teleports a body to a full state (used by network corrections and rollback).
	public void SetState(uint32 bodyId, BodyState stateIn)
	{
		if (!mByBody.TryGetValue(bodyId, let entry) || mBackend == null)
			return;
		Teleports++;
		mBackend.SetBodyPose(bodyId, stateIn.position, stateIn.rotation, true);
		if (entry.dynamic)
			mBackend.SetBodyVelocities(bodyId, stateIn.linearVelocity, stateIn.angularVelocity);
		entry.transform.SetPositionAndRotation(stateIn.position, stateIn.rotation);
		entry.lastVersion = entry.transform.Version;
	}

	/// Let an authored resting prop wait for a real contact to wake it, without making it kinematic.
	public void Sleep(uint32 bodyId)
	{
		if (!mByBody.TryGetValue(bodyId, let entry) || mBackend == null || !entry.dynamic || entry.outOfWorld)
			return;
		Flush(bodyId);
		mBackend.SetSleeping(bodyId, true);
	}

	/// Whether a body is resting and not being simulated.
	public bool IsSleeping(uint32 bodyId) => mBackend != null && (mByBody.ContainsKey(bodyId) || mSoftBodies.ContainsKey(bodyId)) && mBackend.IsSleeping(bodyId);

	/// How fast a body moves, in metres a second.
	public Vector3 GetLinearVelocity(uint32 bodyId) => mBackend != null && bodyId != uint32.MaxValue ? mBackend.GetLinearVelocity(bodyId) : .Zero;

	/// Sets how fast a body moves (waking it).
	public void SetLinearVelocity(uint32 bodyId, Vector3 velocity)
	{
		if (mBackend != null && bodyId != uint32.MaxValue)
			mBackend.SetLinearVelocity(bodyId, velocity);
	}

	/// How fast a body spins, in radians a second.
	public Vector3 GetAngularVelocity(uint32 bodyId) => mBackend != null && bodyId != uint32.MaxValue ? mBackend.GetAngularVelocity(bodyId) : .Zero;

	/// Sets how fast a body spins (waking it).
	public void SetAngularVelocity(uint32 bodyId, Vector3 velocity)
	{
		if (mBackend != null && bodyId != uint32.MaxValue)
			mBackend.SetAngularVelocity(bodyId, velocity);
	}

	/// Pushes a body by a force, in newtons, through its centre over the next step.
	public void AddForce(uint32 bodyId, Vector3 force)
	{
		if (mBackend != null && bodyId != uint32.MaxValue)
			mBackend.AddForce(bodyId, force);
	}

	/// Turns a body by a torque, in newton metres about each world axis, over the next step.
	public void AddTorque(uint32 bodyId, Vector3 torque)
	{
		if (mBackend != null && bodyId != uint32.MaxValue)
			mBackend.AddTorque(bodyId, torque);
	}

	/// Pushes a body by a force at a point in the world, which also turns it.
	public void AddForceAtPosition(uint32 bodyId, Vector3 force, Vector3 point)
	{
		if (mBackend != null && bodyId != uint32.MaxValue)
			mBackend.AddForceAtPosition(bodyId, force, point);
	}

	/// Velocity of the point on a body at a world position (linear plus rotational).
	public Vector3 GetPointVelocity(uint32 bodyId, Vector3 point) => mBackend != null && bodyId != uint32.MaxValue ? mBackend.GetPointVelocity(bodyId, point) : .Zero;

	/// Changes a body's momentum at once, through its centre.
	public void AddImpulse(uint32 bodyId, Vector3 impulse)
	{
		if (mBackend != null && bodyId != uint32.MaxValue)
			mBackend.AddImpulse(bodyId, impulse);
	}

	/// Floats a body in water whose surface passes through surfacePoint facing surfaceNormal, for one step. False
	/// when no part of it is under.
	public bool ApplyBuoyancy(uint32 bodyId, Vector3 surfacePoint, Vector3 surfaceNormal, float buoyancy, float linearDrag, float angularDrag, Vector3 fluidVelocity,
		float deltaTime)
	{
		if (mBackend == null || bodyId == uint32.MaxValue)
			return false;
		Entry entry;
		if (!mByBody.TryGetValue(bodyId, out entry) || !entry.dynamic || entry.outOfWorld)
			return false;
		Flush(bodyId);
		return mBackend.ApplyBuoyancy(bodyId, surfacePoint, surfaceNormal, buoyancy, linearDrag, angularDrag, fluidVelocity, deltaTime);
	}

	// Queries run on the scene thread, like simulation and body state changes.
	void EnsureQueryPrepared()
	{
		if (mBackend == null)
			return;
		mBackend.PrepareQuery(QueryWorldGroups);
	}

	static bool Finite(Vector3 v) => v.x.IsFinite && v.y.IsFinite && v.z.IsFinite;
	static bool ValidRotation(Quaternion q) => q.x.IsFinite && q.y.IsFinite && q.z.IsFinite && q.w.IsFinite && Quaternion.Dot(q, q) > 1.0e-12f;

	ShapeCastHit MakeShapeHit(PhysicsShapeHit nativeHit, float maxDistance)
	{
		ShapeCastHit hit = default;
		hit.bodyId = nativeHit.bodyId;
		hit.point = nativeHit.point;
		hit.normal = nativeHit.normal;
		hit.distance = Math.Max(nativeHit.fraction, 0) * maxDistance;
		hit.penetrationDepth = nativeHit.penetrationDepth;
		hit.part = -1;
		hit.triangle = -1;
		hit.gameObject = ObjectOfBody(nativeHit.bodyId);
		var point = nativeHit.point;
		if (mBackend != null && mBackend.HitDetail(nativeHit.bodyId, nativeHit.subShapeId, point, let detail))
		{
			hit.part = detail.part;
			hit.triangle = detail.triangle;
		}
		return hit;
	}

	/// Fills a ray hit's normal, part and triangle from the backend's sub-shape id.
	void AddRayDetail(ref RaycastHit hit, uint32 bodyId, uint32 subShapeId)
	{
		hit.bodyId = bodyId;
		hit.part = -1;
		hit.triangle = -1;
		var point = hit.point;
		if (mBackend != null && mBackend.HitDetail(bodyId, subShapeId, point, let detail))
		{
			hit.normal = detail.normal;
			hit.part = detail.part;
			hit.triangle = detail.triangle;
		}
	}

	/// Every body a ray passes through within maxDistance, nearest first, each once (where the ray enters it), with
	/// normals. Debris is passed through. Clears hits first; returns how many there are.
	public int RaycastAll(Vector3 origin, Vector3 direction, float maxDistance, List<RaycastHit> hits, uint32 layerMask = uint32.MaxValue, uint32 ignoreBody = uint32.MaxValue)
	{
		hits.Clear();
		if (!Finite(origin) || !Finite(direction) || direction.LengthSquared < 1.0e-12f || !maxDistance.IsFinite || maxDistance <= 0)
			return 0;
		EnsureQueryPrepared();
		if (mBackend == null)
			return 0;
		let unit = direction.Normalized;
		let raw = scope List<PhysicsRayHit>();
		mBackend.RaycastAll(origin, unit, maxDistance, layerMask, ignoreBody, raw);
		for (let nativeHit in raw)
		{
			RaycastHit hit = default;
			hit.distance = nativeHit.fraction * maxDistance;
			hit.point = origin + unit * hit.distance;
			hit.gameObject = ObjectOfBody(nativeHit.bodyId);
			AddRayDetail(ref hit, nativeHit.bodyId, nativeHit.subShapeId);
			hits.Add(hit);
		}
		return hits.Count;
	}

	bool CastQuery(ShapeDesc shape, Vector3 origin, Quaternion orientation, Vector3 direction, float maxDistance, out ShapeCastHit hit, uint32 ignoreBody, uint32 layerMask)
	{
		hit = default;
		if (mBackend == null || !Finite(origin) || !Finite(direction) || direction.LengthSquared < 1.0e-12f || !direction.LengthSquared.IsFinite || !maxDistance.IsFinite || maxDistance <= 0 || !ValidRotation(orientation)) return false;
		EnsureQueryPrepared();
		mBackend.CastShape(shape, origin, orientation.Normalized, direction.Normalized * maxDistance, layerMask, ignoreBody, let nativeHit);
		if (nativeHit.bodyId == uint32.MaxValue)
			return false;
		hit = MakeShapeHit(nativeHit, maxDistance);
		return true;
	}

	int CastAllQuery(ShapeDesc shape, Vector3 origin, Quaternion orientation, Vector3 direction, float maxDistance, List<ShapeCastHit> hits, uint32 ignoreBody, uint32 layerMask)
	{
		hits.Clear();
		if (mBackend == null || !Finite(origin) || !Finite(direction) || direction.LengthSquared < 1.0e-12f || !maxDistance.IsFinite || maxDistance <= 0 || !ValidRotation(orientation)) return 0;
		EnsureQueryPrepared();
		let raw = scope List<PhysicsShapeHit>();
		mBackend.CastShapeAll(shape, origin, orientation.Normalized, direction.Normalized * maxDistance, layerMask, ignoreBody, raw);
		for (let nativeHit in raw)
			hits.Add(MakeShapeHit(nativeHit, maxDistance));
		return hits.Count;
	}

	static ShapeDesc SphereShape(float radius)
	{
		ShapeDesc desc = default;
		desc.kind = .Sphere;
		desc.radius = radius;
		return desc;
	}

	static ShapeDesc CapsuleShape(float halfHeight, float radius)
	{
		ShapeDesc desc = default;
		desc.kind = .Capsule;
		desc.halfHeight = halfHeight;
		desc.radius = radius;
		return desc;
	}

	static ShapeDesc BoxShape(Vector3 size)
	{
		ShapeDesc desc = default;
		desc.kind = .Box;
		desc.halfExtents = size * 0.5f;
		return desc;
	}

	/// The rotation that turns a capsule's axis (its Y) onto a direction. LookRotation keeps the forward it is given and
	/// only leans up towards the one given, so forward is chosen at right angles to the axis.
	static Quaternion CapsuleRotation(Vector3 axis)
	{
		let up = axis.Normalized;
		let side = Math.Abs(up.x) < 0.9f ? Vector3.Right : Vector3.Forward;
		return Quaternion.LookRotation(Vector3.Cross(side, up), up);
	}

	int OverlapQuery(ShapeDesc shape, Vector3 origin, Quaternion orientation, List<ShapeCastHit> hits, uint32 ignoreBody, uint32 layerMask)
	{
		using (sOverlapProfile.Sample())
		{
			hits.Clear();
			if (mBackend == null || !Finite(origin) || !ValidRotation(orientation)) return 0;
			EnsureQueryPrepared();
			let raw = scope List<PhysicsShapeHit>();
			mBackend.OverlapShape(shape, origin, orientation.Normalized, layerMask, ignoreBody, raw, useAnalyticOverlapContacts);
			for (let nativeHit in raw)
				hits.Add(MakeShapeHit(nativeHit, 0));
			return (int)hits.Count;
		}
	}

	bool CheckQuery(ShapeDesc shape, Vector3 origin, Quaternion orientation, uint32 ignoreBody, uint32 layerMask)
	{
		if (mBackend == null || !Finite(origin) || !ValidRotation(orientation)) return false;
		EnsureQueryPrepared();
		return mBackend.CheckShape(shape, origin, orientation.Normalized, layerMask, ignoreBody);
	}

	/// Every body a sphere sweep touches, nearest first, each once. Clears hits first; returns how many there are.
	public int SphereCastAll(Vector3 origin, float radius, Vector3 direction, float maxDistance, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CastAllQuery(SphereShape(radius), origin, .Identity, direction, maxDistance, hits, ignoreBody, layerMask);

	/// Every body a capsule sweep touches (point1 and point2 its half-spheres' centres), nearest first, each once.
	public int CapsuleCastAll(Vector3 point1, Vector3 point2, float radius, Vector3 direction, float maxDistance, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
	{
		hits.Clear();
		if (!Finite(point1) || !Finite(point2)) return 0;
		let axis = point2 - point1;
		let length = axis.Length;
		if (!length.IsFinite) return 0;
		let rotation = length < 1.0e-6f ? Quaternion.Identity : CapsuleRotation(axis);
		return CastAllQuery(CapsuleShape(length * 0.5f, radius), (point1 + point2) * 0.5f, rotation, direction, maxDistance, hits, ignoreBody, layerMask);
	}

	/// Every body a box sweep (size: full width, height and depth) touches, nearest first, each once.
	public int BoxCastAll(Vector3 origin, Vector3 size, Quaternion orientation, Vector3 direction, float maxDistance, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CastAllQuery(BoxShape(size), origin, orientation, direction, maxDistance, hits, ignoreBody, layerMask);

	/// Sweeps a sphere and returns its closest contact. Direction need not be normalized.
	/// A starting overlap returns distance zero and its penetration depth. layerMask: the layers it sees (one bit
	/// per layer; ProjectConfig.Mask makes one from names), all of them by default.
	public bool SphereCast(Vector3 origin, float radius, Vector3 direction, float maxDistance, out ShapeCastHit hit, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CastQuery(SphereShape(radius), origin, .Identity, direction, maxDistance, out hit, ignoreBody, layerMask);

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
		return CastQuery(CapsuleShape(length * 0.5f, radius), (point1 + point2) * 0.5f, rotation, direction, maxDistance, out hit, ignoreBody, layerMask);
	}

	/// Size is the full width/height/depth, matching BoxCollider.size.
	public bool BoxCast(Vector3 origin, Vector3 size, Quaternion orientation, Vector3 direction, float maxDistance, out ShapeCastHit hit, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CastQuery(BoxShape(size), origin, orientation, direction, maxDistance, out hit, ignoreBody, layerMask);

	/// Whether anything touches a sphere: as OverlapSphere, without the contacts, so several times quicker (it stops at
	/// the first thing it finds). As Unity's Physics.CheckSphere.
	public bool CheckSphere(Vector3 origin, float radius, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CheckQuery(SphereShape(radius), origin, .Identity, ignoreBody, layerMask);

	/// Whether anything touches a box (of a full size, turned by orientation), without the contacts.
	public bool CheckBox(Vector3 origin, Vector3 size, Quaternion orientation, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> CheckQuery(BoxShape(size), origin, orientation, ignoreBody, layerMask);

	/// Whether anything touches a capsule from point1 to point2, without the contacts.
	public bool CheckCapsule(Vector3 point1, Vector3 point2, float radius, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
	{
		if (!Finite(point1) || !Finite(point2)) return false;
		let axis = point2 - point1;
		let length = axis.Length;
		if (!length.IsFinite) return false;
		let rotation = length < 1.0e-6f ? Quaternion.Identity : CapsuleRotation(axis);
		return CheckQuery(CapsuleShape(length * 0.5f, radius), (point1 + point2) * 0.5f, rotation, ignoreBody, layerMask);
	}

	/// Returns contacts, including separate subshapes of compound/mesh bodies. Clears hits first. CheckSphere is quicker
	/// when only whether something is there matters.
	public int OverlapSphere(Vector3 origin, float radius, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> OverlapQuery(SphereShape(radius), origin, .Identity, hits, ignoreBody, layerMask);
	/// Everything touching a box (of a full size, turned by orientation) round a point. Clears hits first; returns how
	/// many there are.
	public int OverlapBox(Vector3 origin, Vector3 size, Quaternion orientation, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
		=> OverlapQuery(BoxShape(size), origin, orientation, hits, ignoreBody, layerMask);
	/// Everything touching a capsule from point1 to point2. Clears hits first; returns how many there are.
	public int OverlapCapsule(Vector3 point1, Vector3 point2, float radius, List<ShapeCastHit> hits, uint32 ignoreBody = uint32.MaxValue, uint32 layerMask = uint32.MaxValue)
	{
		hits.Clear();
		if (!Finite(point1) || !Finite(point2)) return 0;
		let axis = point2 - point1;
		let length = axis.Length;
		if (!length.IsFinite) return 0;
		let rotation = length < 1.0e-6f ? Quaternion.Identity : CapsuleRotation(axis);
		return OverlapQuery(CapsuleShape(length * 0.5f, radius), (point1 + point2) * 0.5f, rotation, hits, ignoreBody, layerMask);
	}

	/// Casts a ray and reports the closest body hit within maxDistance. Debris is passed through. layerMask: the
	/// layers it sees (ProjectConfig.Mask("Default", "Enemies")), all of them by default.
	public bool Raycast(Vector3 origin, Vector3 direction, float maxDistance, out RaycastHit hit, uint32 layerMask = uint32.MaxValue)
	{
		hit = default;
		if (mBackend == null || direction.LengthSquared < 1.0e-12f)
			return false;
		let unit = direction.Normalized;
		EnsureQueryPrepared();
		float travelled = 0;
		// Debris in the way is stepped through a little at a time until the ray is out the other side.
		for (int attempt < 96)
		{
			var from = origin + unit * travelled;
			var remaining = maxDistance - travelled;
			if (remaining <= 0)
				return false;
			mBackend.Raycast(from, unit, remaining, layerMask, uint32.MaxValue, let result);
			if (result.bodyId == uint32.MaxValue)
				return false;
			let distance = travelled + result.fraction * remaining;
			if (mDebris.Contains(result.bodyId))
			{
				travelled = distance + 0.2f;
				if (travelled >= maxDistance)
					return false;
				continue;
			}
			hit.distance = distance;
			hit.point = origin + unit * distance;
			hit.gameObject = ObjectOfBody(result.bodyId);
			AddRayDetail(ref hit, result.bodyId, result.subShapeId);
			return true;
		}
		return false;
	}
}
