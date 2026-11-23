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

/// A whole-world snapshot a backend keeps in its own memory: every tracked body's pose, velocities and sleep state.
/// This is the generic form PhysicsBackendWorld makes for a backend that does not provide its own (Jolt's is native
/// and exact); it is what the network takes and puts back, so a new backend is snapshotted and networked without
/// writing any networking code of its own.
class PhysicsBackendSnapshot
{
	public struct Body
	{
		public uint32 id;
		public PhysicsMotion motion;
		public Vector3 position;
		public Quaternion rotation;
		public Vector3 linearVelocity;
		public Vector3 angularVelocity;
		public bool sleeping;
	}

	public const uint32 Magic = 0x31534850; // "PHS1"
	public const uint32 Version = 1;
	/// id (4), position (12), rotation (16), linear (12), angular (12), flags (4).
	public const int32 RecordBytes = 60;

	public List<Body> bodies = new .() ~ delete _;
}

/// One physics world made by a backend. This is the library-specific half of PhysicsWorld: shapes, bodies, step,
/// raw queries, joints, characters, contacts and snapshots. It owns no engine bookkeeping (transforms, entries,
/// layers, callbacks); PhysicsWorld does that.
///
/// Bodies made here are tracked so the default save, restore and shared-state code below works for any backend:
/// a backend that implements the body primitives is snapshotted, rolled back and sent to other machines as it is.
/// A backend with a faster or exact snapshot (Jolt's native state) overrides SaveState and the rest.
abstract class PhysicsBackendWorld
{
	struct TrackedBody
	{
		public uint32 id;
		public PhysicsMotion motion;
	}

	List<TrackedBody> mTrackedBodies = new .() ~ delete _;

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

	/// Destroys everything. The bodies it made are forgotten, so a snapshot after it has none.
	public void Clear()
	{
		mTrackedBodies.Clear();
		ClearCore();
	}

	protected abstract void ClearCore();

	// ---- bodies ----

	/// Makes a body and remembers it for the default snapshots. A backend overrides CreateBodyCore instead.
	public uint32 CreateBody(PhysicsBodyDesc desc, ShapeDesc shape)
	{
		let id = CreateBodyCore(desc, shape);
		if (id != uint32.MaxValue)
			mTrackedBodies.Add(.() { id = id, motion = desc.motion });
		return id;
	}

	protected abstract uint32 CreateBodyCore(PhysicsBodyDesc desc, ShapeDesc shape);

	/// Destroys a body and forgets it.
	public void DestroyBody(uint32 bodyId)
	{
		DestroyBodyCore(bodyId);
		for (int i = mTrackedBodies.Count - 1; i >= 0; i--)
		{
			if (mTrackedBodies[i].id == bodyId)
				mTrackedBodies.RemoveAt(i);
		}
	}

	protected abstract void DestroyBodyCore(uint32 bodyId);
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

	/// Every tracked moving body's pose, velocities and sleep state, in a PhysicsBackendSnapshot. This default is
	/// what makes a new backend networked without writing any networking code; a backend with a faster or exact
	/// native snapshot (Jolt's) overrides it.
	public virtual void* SaveState(void* reuse)
	{
		PhysicsBackendSnapshot snapshot;
		if (reuse != null)
		{
			snapshot = (PhysicsBackendSnapshot)Internal.UnsafeCastToObject(reuse);
			snapshot.bodies.Clear();
		}
		else
			snapshot = new PhysicsBackendSnapshot();
		CaptureBodies(snapshot, 0, false);
		return Internal.UnsafeCastToPtr(snapshot);
	}

	/// Puts a generic snapshot back. A body that has gone since is skipped; PhysicsWorld checks the body generation
	/// before calling this in the first place.
	public virtual bool RestoreState(void* state)
	{
		if (state == null)
			return false;
		let snapshot = (PhysicsBackendSnapshot)Internal.UnsafeCastToObject(state);
		for (let body in snapshot.bodies)
		{
			if (!Tracked(body.id, let motion) || motion == .Static)
				continue;
			SetBodyPose(body.id, body.position, body.rotation, false);
			if (motion == .Dynamic)
			{
				SetBodyVelocities(body.id, body.linearVelocity, body.angularVelocity);
				SetSleeping(body.id, body.sleeping);
				if (!body.sleeping)
					ActivateBody(body.id);
			}
		}
		return true;
	}

	public virtual int StateSize(void* state)
	{
		if (state == null)
			return 0;
		let snapshot = (PhysicsBackendSnapshot)Internal.UnsafeCastToObject(state);
		return 12 + (int32)snapshot.bodies.Count * PhysicsBackendSnapshot.RecordBytes;
	}

	public virtual void FreeState(void* state)
	{
		if (state != null)
			delete (PhysicsBackendSnapshot)Internal.UnsafeCastToObject(state);
	}

	public virtual void* StateFromBytes(Span<uint8> data)
	{
		if (data.Length < 12 || GetU32(data, 0) != PhysicsBackendSnapshot.Magic || GetU32(data, 4) != PhysicsBackendSnapshot.Version)
			return null;
		let count = GetU32(data, 8);
		if ((int64)count * PhysicsBackendSnapshot.RecordBytes + 12 != data.Length)
			return null;
		let snapshot = new PhysicsBackendSnapshot();
		var at = 12;
		for (uint32 i < count)
		{
			PhysicsBackendSnapshot.Body body;
			body.id = GetU32(data, at);
			body.motion = .Dynamic;
			body.position = .(GetFloat(data, at + 4), GetFloat(data, at + 8), GetFloat(data, at + 12));
			body.rotation = .(GetFloat(data, at + 16), GetFloat(data, at + 20), GetFloat(data, at + 24), GetFloat(data, at + 28));
			body.linearVelocity = .(GetFloat(data, at + 32), GetFloat(data, at + 36), GetFloat(data, at + 40));
			body.angularVelocity = .(GetFloat(data, at + 44), GetFloat(data, at + 48), GetFloat(data, at + 52));
			body.sleeping = (GetU32(data, at + 56) & 1) != 0;
			snapshot.bodies.Add(body);
			at += PhysicsBackendSnapshot.RecordBytes;
		}
		return Internal.UnsafeCastToPtr(snapshot);
	}

	public virtual void StateToBytes(void* state, List<uint8> into)
	{
		into.Clear();
		if (state == null)
			return;
		let snapshot = (PhysicsBackendSnapshot)Internal.UnsafeCastToObject(state);
		PutU32(into, PhysicsBackendSnapshot.Magic);
		PutU32(into, PhysicsBackendSnapshot.Version);
		PutU32(into, (uint32)snapshot.bodies.Count);
		for (let body in snapshot.bodies)
		{
			PutU32(into, body.id);
			PutFloat(into, body.position.x);
			PutFloat(into, body.position.y);
			PutFloat(into, body.position.z);
			PutFloat(into, body.rotation.x);
			PutFloat(into, body.rotation.y);
			PutFloat(into, body.rotation.z);
			PutFloat(into, body.rotation.w);
			PutFloat(into, body.linearVelocity.x);
			PutFloat(into, body.linearVelocity.y);
			PutFloat(into, body.linearVelocity.z);
			PutFloat(into, body.angularVelocity.x);
			PutFloat(into, body.angularVelocity.y);
			PutFloat(into, body.angularVelocity.z);
			PutU32(into, body.sleeping ? 1 : 0);
		}
	}

	/// The moving bodies from id firstIndex up, in id order: the state a lockstep client takes up from the server.
	/// A backend with a smaller native form for just these bodies overrides this.
	public virtual void SaveShared(uint32 firstIndex, List<uint8> into)
	{
		let snapshot = new PhysicsBackendSnapshot();
		CaptureBodies(snapshot, firstIndex, true);
		StateToBytes(Internal.UnsafeCastToPtr(snapshot), into);
		delete snapshot;
	}

	void CaptureBodies(PhysicsBackendSnapshot snapshot, uint32 firstIndex, bool sorted)
	{
		for (let tracked in mTrackedBodies)
		{
			if (tracked.id < firstIndex || tracked.motion == .Static)
				continue;
			Vector3 position, linear, angular;
			Quaternion rotation;
			GetBodyPose(tracked.id, out position, out rotation);
			linear = GetLinearVelocity(tracked.id);
			angular = GetAngularVelocity(tracked.id);
			PhysicsBackendSnapshot.Body body;
			body.id = tracked.id;
			body.motion = tracked.motion;
			body.position = position;
			body.rotation = rotation;
			body.linearVelocity = linear;
			body.angularVelocity = angular;
			body.sleeping = tracked.motion == .Dynamic ? IsSleeping(tracked.id) : false;
			snapshot.bodies.Add(body);
		}
		if (sorted)
			snapshot.bodies.Sort(scope (a, b) => a.id < b.id ? -1 : (a.id > b.id ? 1 : 0));
	}

	bool Tracked(uint32 id, out PhysicsMotion motion)
	{
		for (let tracked in mTrackedBodies)
		{
			if (tracked.id == id)
			{
				motion = tracked.motion;
				return true;
			}
		}
		motion = .Static;
		return false;
	}

	static void PutU32(List<uint8> into, uint32 value)
	{
		into.Add((uint8)value);
		into.Add((uint8)(value >> 8));
		into.Add((uint8)(value >> 16));
		into.Add((uint8)(value >> 24));
	}

	static void PutFloat(List<uint8> into, float value)
	{
		var v = value;
		let at = into.Count;
		into.Count = at + 4;
		Internal.MemCpy(into.Ptr + at, &v, 4);
	}

	static uint32 GetU32(Span<uint8> data, int at) =>
		(uint32)data[at] | ((uint32)data[at + 1] << 8) | ((uint32)data[at + 2] << 16) | ((uint32)data[at + 3] << 24);

	static float GetFloat(Span<uint8> data, int at)
	{
		var v = 0.0f;
		Internal.MemCpy(&v, data.Ptr + at, 4);
		return v;
	}
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
		// The Rapier provider is listed only when this build linked the pinned archive and its ABI matches; a build
		// without the archive keeps the stub (tn_rapier_available returns 0) and leaves it out.
		if (Rapier.tn_rapier_available() == 1)
			Register(new RapierPhysicsBackend());
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
