using System;
using System.Collections;

namespace Tallow;

/// Rapier's particle soft bodies behind the neutral PhysicsSoftBodyExtension. A surface mesh becomes a cloth, a
/// pressure-held jelly (volume preservation), a shell that rides its object and keeps its dents, or a driven skin
/// that lags behind a Rigidbody. Rapier's plastic edges make dents permanent and its tear thresholds split a surface;
/// tearing is advertised only by this backend.
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
		RapierSoftSettings settings = default;
		settings.kind = config.kind;
		settings.tear = config.tear;
		settings.impacts = config.impacts;
		settings.visualOnly = config.visualOnly;
		settings.dentDepth = config.dentDepth;
		settings.dentYield = config.dentYield;
		settings.dentSpeed = config.dentSpeed;
		settings.visualSpring = config.visualSpring;
		settings.visualDamping = config.visualDamping;
		settings.damping = config.damping;
		settings.friction = config.friction;
		settings.gravityFactor = config.gravityFactor;
		settings.iterations = config.iterations;
		settings.stretch = config.stretch;
		settings.shear = config.shear;
		settings.bend = config.bend;
		return Rapier.tn_rapier_soft_create(World, positions, (int32)vertexCount, triangles, (int32)triangleCount,
			pinned, stiffness, &c, objectMatrix, config.mass, &settings, config.userData);
	}

	public override void Ignore(uint32 bodyId, uint32 ignoredBody)
	{
		if (World != null)
			Rapier.tn_rapier_soft_ignore(World, bodyId, ignoredBody);
	}

	public override void Forget(uint32 bodyId)
	{
		if (World != null)
			Rapier.tn_rapier_soft_destroy(World, bodyId);
	}

	public override void Skin(uint32 bodyId, float* objectMatrix, float* objectNext, float step)
	{
		if (World != null && objectMatrix != null && objectNext != null)
			Rapier.tn_rapier_soft_skin(World, bodyId, objectMatrix, objectNext, step);
	}

	public override uint32 Dents(uint32 bodyId, float* output, uint32 capacity)
		=> World != null ? Rapier.tn_rapier_soft_dents(World, bodyId, output, capacity) : 0;

	public override uint32 DentRevision(uint32 bodyId)
		=> World != null ? Rapier.tn_rapier_soft_dent_revision(World, bodyId) : 0;

	public override void SetDents(uint32 bodyId, float* dents, uint32 count, float* objectMatrix)
	{
		if (World != null)
			Rapier.tn_rapier_soft_set_dents(World, bodyId, dents, count, objectMatrix);
	}

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
		if (World != null && wind != null)
			Rapier.tn_rapier_soft_wind(World, bodyId, wind, drag, turbulence, time, step);
	}

	public override uint32 Touching(uint32 bodyId, uint32* output, uint32 capacity) => 0;

	public override void Shift(uint32 bodyId, float* offset)
	{
		if (World != null && offset != null)
			Rapier.tn_rapier_soft_shift(World, bodyId, offset);
	}

	public override void SetPressure(uint32 bodyId, float pressure)
	{
		if (World != null)
			Rapier.tn_rapier_soft_set_pressure(World, bodyId, pressure);
	}

	public override void DampWobble(uint32 bodyId, float rate, float step)
	{
		if (World != null)
			Rapier.tn_rapier_soft_damp_wobble(World, bodyId, rate, step);
	}

	public override void Bounce(uint32 bodyId, float bounciness, float* state) { }
	public override void Proxies(uint32* bodies, int32* closed, float* reach, uint32 count) { }

	public override bool HasTorn(uint32 bodyId)
		=> World != null && Rapier.tn_rapier_soft_torn(World, bodyId) != 0;

	public override bool Tear(uint32 bodyId)
		=> World != null && Rapier.tn_rapier_soft_tear(World, bodyId) != 0;

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
		if (World == null || samples == null || nx == 0 || nz == 0)
			return 0;
		return Rapier.tn_rapier_soft_float(World, bodyId, samples, nx, nz, minX, minZ, cellX, cellZ, bottom, band,
			buoyancy, drag, gravity, deltaTime, wake ? 1 : 0);
	}

	// ---- ropes ----

	public override uint32 CreateRope(PhysicsRopeConfig* config, float* positions, uint32 count, float* pinned,
		float* center)
	{
		if (World == null || config == null || positions == null || count < 2)
			return uint32.MaxValue;
		var centerPoint = center != null ? Vector3(center[0], center[1], center[2]) : Vector3.Zero;
		float[3] c = .(centerPoint.x, centerPoint.y, centerPoint.z);
		return Rapier.tn_rapier_rope_create(World, positions, count, pinned, config.mass, config.stretch,
			config.bend, config.damping, config.radius, &c, config.userData);
	}

	public override void* Tie(uint32 bodyA, float* pointA, uint32 bodyB, float* pointB, float length)
		=> World != null ? Rapier.tn_rapier_rope_tie(World, bodyA, pointA, bodyB, pointB, length) : null;
	public override void Untie(void* tie)
	{
		if (World != null && tie != null)
			Rapier.tn_rapier_rope_untie(World, tie);
	}

	public override float Pull(void* tie, float step)
		=> World != null && tie != null ? Rapier.tn_rapier_rope_pull(World, tie, step) : 0;
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
		float step)
	{
		if (World != null && wind != null)
			Rapier.tn_rapier_rope_wind(World, bodyId, wind, radius, drag, turbulence, time, step);
	}
}
