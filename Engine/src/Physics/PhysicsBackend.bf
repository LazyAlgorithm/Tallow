using System;
using System.Collections;

namespace Tallow;

/// Which kind of world a backend makes. 2D is reserved until the 2D front end lands.
[Reflect(.All)]
enum PhysicsDimension : uint8
{
	Two,
	Three
}

/// A physics integration. It declares what it supports and makes worlds; the engine calls it only through
/// PhysicsWorld and PhysicsBackendWorld.
abstract class PhysicsBackend : EngineModule
{
	public abstract PhysicsDimension Dimension { get; }
	public abstract PhysicsFeatures Features { get; }
	public abstract PhysicsBackendWorld CreateWorld(PhysicsWorldSettings settings);

	public override uint64 Capabilities => Features.bits;

	public virtual bool Supports(PhysicsFeature feature) => Features.Has(feature);
}

/// One physics world made by a backend. This is the library-specific half of PhysicsWorld: shapes, bodies, step,
/// raw queries, joints, characters, contacts and snapshots. It owns no engine bookkeeping (transforms, entries,
/// layers, callbacks); PhysicsWorld does that.
abstract class PhysicsBackendWorld
{
	public abstract PhysicsFeatures Features { get; }

	/// The backend's ragdoll implementation, or null when it does not advertise Ragdolls. Jolt's built-in
	/// JPH_Ragdoll is the first implementation; another backend can use articulations or ordinary joints.
	public virtual PhysicsRagdollExtension Ragdolls => null;

	/// The backend's soft-body and rope implementation, or null when it advertises neither.
	public virtual PhysicsSoftBodyExtension SoftBodies => null;

	/// The backend's static geometry for navigation baking, or null when it cannot supply it.
	public virtual PhysicsGeometryExtension Geometry => null;

	/// The backend's vehicles, or null when it advertises none.
	public virtual PhysicsVehicleExtension Vehicles => null;

	// ---- world ----

	public abstract void SetGravity(Vector3 gravity);
	public abstract void SetLengthScale(float scale);
	/// Advances the simulation. errorMask is the backend's capacity/step error bits (0 when fine).
	public abstract void Step(float deltaTime, out int32 errorMask, out float stepMilliseconds);
	/// Runs before a query so the backend can rebuild its broad phase if needed.
	public abstract void PrepareQuery(uint32 queryWorldGroups);
	public abstract void BeginContactStep();
	public abstract int CollectContacts(List<PhysicsContactEvent> into);
	public abstract void Clear();

	// ---- bodies ----

	public abstract uint32 CreateBody(PhysicsBodyDesc desc, ShapeDesc shape);
	public abstract void DestroyBody(uint32 bodyId);
	public abstract void SetBodyPose(uint32 bodyId, Vector3 position, Quaternion rotation, bool activate);
	public abstract void MoveKinematic(uint32 bodyId, Vector3 position, Quaternion rotation, float deltaTime);
	public abstract void GetBodyPose(uint32 bodyId, out Vector3 position, out Quaternion rotation);
	public abstract Vector3 GetLinearVelocity(uint32 bodyId);
	public abstract void SetLinearVelocity(uint32 bodyId, Vector3 velocity);
	public abstract Vector3 GetAngularVelocity(uint32 bodyId);
	public abstract void SetAngularVelocity(uint32 bodyId, Vector3 velocity);
	public abstract void SetBodyVelocities(uint32 bodyId, Vector3 linear, Vector3 angular);
	public abstract void AddForce(uint32 bodyId, Vector3 force);
	public abstract void AddForceAtPosition(uint32 bodyId, Vector3 force, Vector3 point);
	public abstract void AddTorque(uint32 bodyId, Vector3 torque);
	public abstract void AddImpulse(uint32 bodyId, Vector3 impulse);
	public abstract Vector3 GetPointVelocity(uint32 bodyId, Vector3 point);
	public abstract void SetSleeping(uint32 bodyId, bool sleeping);
	public abstract void ActivateBody(uint32 bodyId);
	public abstract bool IsSleeping(uint32 bodyId);
	/// The packed motion-class/layer/world-group code the engine computed for a body.
	public abstract void SetObjectCode(uint32 bodyId, uint32 objectCode);
	public abstract uint32 GetObjectCode(uint32 bodyId);
	public abstract void AddBodyToWorld(uint32 bodyId, bool activate);
	public abstract void RemoveBodyFromWorld(uint32 bodyId);
	public abstract bool ApplyBuoyancy(uint32 bodyId, Vector3 surfacePoint, Vector3 surfaceNormal, float buoyancy,
		float linearDrag, float angularDrag, Vector3 fluidVelocity, float deltaTime);

	// ---- queries ----

	public abstract bool Raycast(Vector3 origin, Vector3 direction, float maxDistance, uint32 layerMask,
		uint32 ignoreBody, out PhysicsRayHit hit);
	public abstract int RaycastAll(Vector3 origin, Vector3 direction, float maxDistance, uint32 layerMask,
		uint32 ignoreBody, List<PhysicsRayHit> hits);
	public abstract bool CastShape(ShapeDesc shape, Vector3 origin, Quaternion rotation, Vector3 displacement,
		uint32 layerMask, uint32 ignoreBody, out PhysicsShapeHit hit);
	public abstract int CastShapeAll(ShapeDesc shape, Vector3 origin, Quaternion rotation, Vector3 displacement,
		uint32 layerMask, uint32 ignoreBody, List<PhysicsShapeHit> hits);
	public abstract int OverlapShape(ShapeDesc shape, Vector3 origin, Quaternion rotation, uint32 layerMask,
		uint32 ignoreBody, List<PhysicsShapeHit> hits, bool analyticContacts);
	public abstract bool CheckShape(ShapeDesc shape, Vector3 origin, Quaternion rotation, uint32 layerMask,
		uint32 ignoreBody);
	public abstract bool HitDetail(uint32 bodyId, uint32 subShapeId, Vector3 point, out PhysicsHitDetail detail);

	// ---- joints ----

	public abstract void* CreateJoint(PhysicsJointDesc desc);
	public abstract void DestroyJoint(void* joint);
	public abstract void SetSliderSpring(void* joint, float stiffness, float damping);
	public abstract float SliderPosition(void* joint);
	public abstract void SetHingeMotor(void* joint, float speed, float torque, float angle, int32 mode,
		float response, float maximumSpeed);
	public abstract float HingeAngle(void* joint);

	// ---- characters ----

	public abstract void* CreateCharacter(PhysicsCharacterDesc desc, ShapeDesc shape);
	public abstract void DestroyCharacter(void* character);
	public abstract uint32 CharacterInnerBody(void* character);
	public abstract CharacterState GetCharacterState(void* character);
	public abstract CharacterState MoveCharacter(void* character, uint32 objectCode, Vector3 velocity,
		float deltaTime, float stepHeight, float stepReach, bool soft);
	public abstract void SetCharacterState(void* character, uint32 objectCode, Vector3 position,
		Quaternion rotation, Vector3 velocity, bool soft);
	public abstract bool SetCharacterShape(void* character, uint32 objectCode, ShapeDesc shape,
		float maxPenetration, bool soft);
	public abstract int CharacterHits(void* character, Span<CharacterHit> hits);

	// ---- snapshots ----

	public abstract void* SaveState(void* reuse);
	public abstract bool RestoreState(void* state);
	public abstract int StateSize(void* state);
	public abstract void FreeState(void* state);
	public abstract void* StateFromBytes(Span<uint8> data);
	public abstract void StateToBytes(void* state, List<uint8> into);
	public abstract void SaveShared(uint32 firstIndex, List<uint8> into);
}

/// The physics providers in this build. A provider appears here only when it is integrated and available; the
/// editor lists the 3D and 2D groups from this registry.
static class PhysicsBackends
{
	static List<PhysicsBackend> sBackends = new .() ~ delete _;
	static String sOverride3D = new .() ~ delete _;
	static String sOverride2D = new .() ~ delete _;

	static this()
	{
		Register(new JoltPhysicsBackend());
	}

	/// A command-line override for this run, without changing the project's file.
	public static void Override2D(StringView id) => sOverride2D.Set(id);

	public static void Override3D(StringView id)
	{
		sOverride3D.Set(id);
		if (id == "JoltLimited" || id == "Test")
		{
			JoltLimitedPhysicsBackend.Enabled = true;
			Register(new JoltLimitedPhysicsBackend());
		}
	}

	public static List<PhysicsBackend> All => sBackends;

	public static void Register(PhysicsBackend backend)
	{
		if (backend == null || !backend.Available)
			return;
		for (let existing in sBackends)
		{
			if (existing.Id == backend.Id && existing.Dimension == backend.Dimension)
				return;
		}
		sBackends.Add(backend);
		EngineModules.Register(backend);
	}

	public static PhysicsBackend Find(StringView id)
	{
		for (let backend in sBackends)
		{
			if (backend.Id == id)
				return backend;
		}
		return null;
	}

	public static PhysicsBackend Find(StringView id, PhysicsDimension dimension)
	{
		for (let backend in sBackends)
		{
			if (backend.Id == id && backend.Dimension == dimension)
				return backend;
		}
		return null;
	}

	public static PhysicsBackend First(PhysicsDimension dimension)
	{
		for (let backend in sBackends)
		{
			if (backend.Dimension == dimension && backend.Available)
				return backend;
		}
		return null;
	}

	/// The project's 3D choice, or Jolt (or the first available 3D provider) when the file names one this build
	/// does not have. Null only when the build contains no 3D physics at all.
	public static PhysicsBackend Selected3D
	{
		get
		{
			ProjectConfig.EnsureLoaded();
			let id = sOverride3D.IsEmpty ? ProjectConfig.Physics3DBackendId : sOverride3D;
			let found = Find(id, .Three);
			if (found != null)
				return found;
			let fallback = First(.Three);
			if (fallback != null)
				Log.Error(scope $"Physics backend '{id}' is not available in this build; using '{fallback.Id}'. Set Physics3D in Project Settings or ProjectConfig.tconfig.");
			else
				Log.Error(scope $"Physics backend '{id}' is not available in this build, and no 3D physics backend is available.");
			return fallback;
		}
	}

	/// The project's 2D choice, or null while no 2D provider ships. Never falls back to a 3D backend.
	public static PhysicsBackend Selected2D
	{
		get
		{
			ProjectConfig.EnsureLoaded();
			let id = sOverride2D.IsEmpty ? ProjectConfig.Physics2DBackendId : sOverride2D;
			let found = Find(id, .Two);
			if (found != null)
				return found;
			return First(.Two);
		}
	}

	public static PhysicsWorld CreateWorld3D()
	{
		let backend = Selected3D;
		return backend != null ? new PhysicsWorld(backend) : null;
	}
}
