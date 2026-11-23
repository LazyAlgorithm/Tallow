using System;
using System.Collections;

namespace Tallow;

/// Rapier's particle soft bodies behind the neutral PhysicsSoftBodyExtension: a surface mesh becomes a cloth or a
/// shell with structural and bending constraints, pinned points are kinematic, and the whole body takes impulses,
/// forces and wind. Rapier has no dents or skin binding of Jolt's kind, so those capabilities are not advertised.
class RapierSoftBodyExtension : PhysicsSoftBodyExtension
{
	RapierPhysicsBackendWorld mBackend;

	public this(RapierPhysicsBackendWorld backend)
	{
		mBackend = backend;
	}

	void* World => mBackend != null ? mBackend.NativeWorld : null;

	public override void WorldDestroyed()
	{
		// The backend world destroys the soft bodies with everything else.
	}

	public override uint32 Create(PhysicsSoftBodyConfig* config, float* positions, uint32 vertexCount,
		uint32* triangles, uint32 triangleCount, float* pinned, float* stiffness, float* center, float* objectMatrix)
	{
		if (World == null || config == null || positions == null || triangles == null || vertexCount < 3 || triangleCount == 0)
			return uint32.MaxValue;
		var centerPoint = center != null ? Vector3(center[0], center[1], center[2]) : Vector3.Zero;
		float[3] c = .(centerPoint.x, centerPoint.y, centerPoint.z);
		return Rapier.tn_rapier_soft_create(World, positions, (int32)vertexCount, triangles, (int32)triangleCount,
			pinned, config.mass, config.stretch, config.damping, config.friction, &c, config.userData);
	}

	public override void Ignore(uint32 bodyId, uint32 ignoredBody)
	{
	}

	public override void Forget(uint32 bodyId)
	{
		if (World != null)
			Rapier.tn_rapier_soft_destroy(World, bodyId);
	}

	public override void Skin(uint32 bodyId, float* objectMatrix, float* objectNext, float step)
	{
	}

	public override uint32 Dents(uint32 bodyId, float* output, uint32 capacity) => 0;
	public override uint32 DentRevision(uint32 bodyId) => 0;
	public override void SetDents(uint32 bodyId, float* dents, uint32 count, float* objectMatrix) { }

	public override uint32 Read(uint32 bodyId, float* positions, float* velocities, uint32 capacity)
		=> World != null ? Rapier.tn_rapier_soft_read(World, bodyId, positions, velocities, capacity) : 0;

	public override void MovePinned(uint32 bodyId, uint32* indices, float* targets, uint32 count, float step)
	{
		if (World == null || indices == null || targets == null || count == 0)
			return;
		float[3] c = .(0, 0, 0);
		Rapier.tn_rapier_soft_move_pinned(World, bodyId, indices, targets, count, &c);
	}

	public override void SetPositions(uint32 bodyId, float* positions, float* velocities, uint32 count)
	{
		if (World == null || positions == null || count == 0)
			return;
		float[3] c = .(0, 0, 0);
		Rapier.tn_rapier_soft_set_positions(World, bodyId, positions, velocities, count, &c);
	}

	public override uint32 Velocity(uint32 bodyId, float* velocity)
	{
		if (World == null || velocity == null)
			return 0;
		Rapier.tn_rapier_soft_velocity(World, bodyId, velocity);
		return 1;
	}

	public override void SetVelocity(uint32 bodyId, float* velocity)
	{
		if (World != null && velocity != null)
			Rapier.tn_rapier_soft_set_velocity(World, bodyId, velocity);
	}

	public override void Impulse(uint32 bodyId, float* impulse)
	{
		if (World != null && impulse != null)
			Rapier.tn_rapier_soft_impulse(World, bodyId, impulse);
	}

	public override void Force(uint32 bodyId, float* force, float step)
	{
		if (World != null && force != null)
			Rapier.tn_rapier_soft_force(World, bodyId, force);
	}

	public override void Wind(uint32 bodyId, float* wind, float drag, float turbulence, float time, float step)
	{
		if (World == null || wind == null)
			return;
		float[3] f = .(wind[0] * drag, wind[1] * drag, wind[2] * drag);
		Rapier.tn_rapier_soft_force(World, bodyId, &f);
	}

	public override uint32 Touching(uint32 bodyId, uint32* output, uint32 capacity) => 0;

	public override void Shift(uint32 bodyId, float* offset)
	{
		if (World != null && offset != null)
			Rapier.tn_rapier_soft_shift(World, bodyId, offset);
	}

	public override void SetPressure(uint32 bodyId, float pressure) { }
	public override void DampWobble(uint32 bodyId, float rate, float step) { }
	public override void Bounce(uint32 bodyId, float bounciness, float* state) { }
	public override void Proxies(uint32* bodies, int32* closed, float* reach, uint32 count) { }

	public override bool Bounds(uint32 bodyId, out Vector3 min, out Vector3 max)
	{
		min = default;
		max = default;
		if (World == null)
			return false;
		float[3] lo = default;
		float[3] hi = default;
		if (Rapier.tn_rapier_soft_bounds(World, bodyId, &lo, &hi) == 0)
			return false;
		min = .(lo[0], lo[1], lo[2]);
		max = .(hi[0], hi[1], hi[2]);
		return true;
	}

	public override uint32 FloatSoft(uint32 bodyId, float* samples, uint32 nx, uint32 nz, float minX, float minZ,
		float cellX, float cellZ, float bottom, float band, float buoyancy, float drag, float gravity,
		float deltaTime, bool wake)
	{
		// Water needs world-space particle positions; the soft-body read is object-local. Not advertised.
		return 0;
	}

	// ---- ropes ----

	public override uint32 CreateRope(PhysicsRopeConfig* config, float* positions, uint32 count, float* pinned,
		float* center) => uint32.MaxValue;
	public override void* Tie(uint32 bodyA, float* pointA, uint32 bodyB, float* pointB, float length) => null;
	public override void Untie(void* tie) { }
	public override float Pull(void* tie, float step) => 0;
	public override bool Wraps(uint32 bodyId, float* start, float* end, float clearance, out uint32 first,
		out uint32 last, float* places)
	{
		first = uint32.MaxValue;
		last = uint32.MaxValue;
		return false;
	}

	public override void* TieOver(uint32 bodyA, float* pointA, float* fixedA, uint32 bodyB, float* pointB,
		float* fixedB, float length) => null;
	public override void WindRope(uint32 bodyId, float* wind, float radius, float drag, float turbulence, float time,
		float step) { }
}
