using System;
using System.Collections;

namespace Tallow;

/// A soft body's settings, independent of the backend. The field order matches native/tallow_softbody.cpp's Config,
/// so the Jolt extension can pass it straight through; another backend maps it to its own cloth/soft-body settings.
[CRepr]
struct PhysicsSoftBodyConfig
{
	public float mass, stretch, shear, bend, pressure, damping, friction, restitution, gravityFactor, vertexRadius, dentDepth, dentYield, dentSpeed, stepTime;
	public int32 iterations, doubleSided, longRange, dihedral, shell, impacts, visualOnly;
	public float visualSpring, visualDamping;
	public uint32 layer;
	public uint64 userData;
	/// 0 cloth, 1 jelly, 2 shell, 3 driven jelly. Appended after the fields Jolt's native config reads.
	public int32 kind;
	/// 1 when this body may tear.
	public int32 tear;
	// Normalized material controls for backends that use spring frequencies or elastic moduli.
	public float surfaceStiffness, bendStiffness, wobbleDamping, bounciness;
}

/// A rope's settings, independent of the backend. The field order matches native/tallow_softbody.cpp's RopeConfig.
[CRepr]
struct PhysicsRopeConfig
{
	public float mass, stretch, bend, damping, friction, restitution, gravityFactor, radius;
	public int32 iterations;
	public uint32 layer;
	public uint64 userData;
	/// 0 cloth, 1 jelly, 2 shell, 3 driven jelly. Appended after the fields Jolt's native config reads.
	public int32 kind;
	/// 1 when this body may tear.
	public int32 tear;
}

/// Cloth, jelly, shells, ropes and the soft-body half of water. Present only when the selected backend advertises the
/// matching capability. Jolt implements it over its soft-body simulation; another backend can build it from particles,
/// distance constraints or its own cloth solver.
abstract class PhysicsSoftBodyExtension
{
	/// The backend world is going away: forget every soft body and rope it kept.
	public abstract void WorldDestroyed();

	// ---- soft bodies ----

	public abstract uint32 Create(PhysicsSoftBodyConfig* config, float* positions, uint32 vertexCount,
		uint32* triangles, uint32 triangleCount, float* pinned, float* stiffness, float* center, float* objectMatrix);
	public virtual bool HasNativeCollider(uint32 bodyId) => false;
	public abstract void Ignore(uint32 bodyId, uint32 ignoredBody);
	public abstract void Forget(uint32 bodyId);
	public abstract void Skin(uint32 bodyId, float* objectMatrix, float* objectNext, float step);
	public abstract uint32 Dents(uint32 bodyId, float* output, uint32 capacity);
	public abstract uint32 DentRevision(uint32 bodyId);
	public abstract void SetDents(uint32 bodyId, float* dents, uint32 count, float* objectMatrix);
	public abstract uint32 Read(uint32 bodyId, float* positions, float* velocities, uint32 capacity);
	public abstract void MovePinned(uint32 bodyId, uint32* indices, float* targets, uint32 count, float step);
	public abstract void SetPositions(uint32 bodyId, float* positions, float* velocities, uint32 count);
	public abstract uint32 Velocity(uint32 bodyId, float* velocity);
	public abstract void SetVelocity(uint32 bodyId, float* velocity);
	public abstract void Impulse(uint32 bodyId, float* impulse);
	public abstract void Force(uint32 bodyId, float* force, float step);
	public abstract void Wind(uint32 bodyId, float* wind, float drag, float turbulence, float time, float step);
	public abstract uint32 Touching(uint32 bodyId, uint32* output, uint32 capacity);
	public abstract void Shift(uint32 bodyId, float* offset);
	public abstract void SetPressure(uint32 bodyId, float pressure);
	public abstract void DampWobble(uint32 bodyId, float rate, float step);
	public abstract void Bounce(uint32 bodyId, float bounciness, float* state);
	public abstract void Proxies(uint32* bodies, int32* closed, float* reach, uint32 count);

	/// Whether the body has torn since it was made. Backends whose soft bodies do not tear return false.
	public virtual bool HasTorn(uint32 bodyId) => false;
	/// Tears the body's overstretched edges now. False on a backend that does not tear.
	public virtual bool Tear(uint32 bodyId) => false;

	/// The world-space bounds of a soft body, for water and tools.
	public abstract bool Bounds(uint32 bodyId, out Vector3 min, out Vector3 max);
	/// Lifts and drags the vertices of a soft body under a sampled water surface. Returns how many were under.
	public abstract uint32 FloatSoft(uint32 bodyId, float* samples, uint32 nx, uint32 nz, float minX, float minZ,
		float cellX, float cellZ, float bottom, float band, float buoyancy, float drag, float gravity, float deltaTime, bool wake);

	// ---- ropes ----

	public abstract uint32 CreateRope(PhysicsRopeConfig* config, float* positions, uint32 count, float* pinned, float* center);
	public abstract void* Tie(uint32 bodyA, float* pointA, uint32 bodyB, float* pointB, float length);
	public abstract void Untie(void* tie);
	public abstract float Pull(void* tie, float step);
	public abstract bool Wraps(uint32 bodyId, float* start, float* end, float clearance, out uint32 first,
		out uint32 last, float* places);
	public abstract void* TieOver(uint32 bodyA, float* pointA, float* fixedA, uint32 bodyB, float* pointB,
		float* fixedB, float length);
	public abstract void WindRope(uint32 bodyId, float* wind, float radius, float drag, float turbulence, float time,
		float step);
}
