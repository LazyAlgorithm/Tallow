using System;
using System.Collections;

namespace Tallow;

/// Jolt's cloth/jelly/shell and Cosserat-rope simulation, behind the neutral PhysicsSoftBodyExtension. Every engine
/// caller (SoftBody, Rope, Water) uses this interface, so another backend can implement it differently.
class JoltSoftBodyExtension : PhysicsSoftBodyExtension
{
	static class Native
	{
		[CLink] public static extern uint32 tn_soft_create(void* world, PhysicsSoftBodyConfig* config, float* positions, uint32 vertexCount, uint32* triangles, uint32 triangleCount, float* pinned, float* stiffness, float* center, float* objectMatrix);
		[CLink] public static extern void tn_soft_ignore(void* world, uint32 bodyId, uint32 ignoredBody);
		[CLink] public static extern void tn_soft_forget(void* world, uint32 bodyId);
		[CLink] public static extern void tn_soft_skin(void* world, uint32 bodyId, float* objectMatrix, float* objectNext, float step);
		[CLink] public static extern uint32 tn_soft_dents(void* world, uint32 bodyId, float* output, uint32 capacity);
		[CLink] public static extern uint32 tn_soft_dent_revision(void* world, uint32 bodyId);
		[CLink] public static extern void tn_soft_set_dents(void* world, uint32 bodyId, float* dents, uint32 count, float* objectMatrix);
		[CLink] public static extern uint32 tn_soft_read(void* world, uint32 bodyId, float* positions, float* velocities, uint32 capacity);
		[CLink] public static extern void tn_soft_move_pinned(void* world, uint32 bodyId, uint32* indices, float* targets, uint32 count, float step);
		[CLink] public static extern void tn_soft_set_positions(void* world, uint32 bodyId, float* positions, float* velocities, uint32 count);
		[CLink] public static extern uint32 tn_soft_velocity(void* world, uint32 bodyId, float* velocity);
		[CLink] public static extern void tn_soft_set_velocity(void* world, uint32 bodyId, float* velocity);
		[CLink] public static extern void tn_soft_impulse(void* world, uint32 bodyId, float* impulse);
		[CLink] public static extern void tn_soft_force(void* world, uint32 bodyId, float* force, float step);
		[CLink] public static extern void tn_soft_wind(void* world, uint32 bodyId, float* wind, float drag, float turbulence, float time, float step);
		[CLink] public static extern uint32 tn_soft_touching(void* world, uint32 bodyId, uint32* output, uint32 capacity);
		[CLink] public static extern void tn_soft_world_destroyed(void* world);
		[CLink] public static extern void tn_soft_shift(void* world, uint32 bodyId, float* offset);
		[CLink] public static extern void tn_soft_set_pressure(void* world, uint32 bodyId, float pressure);
		[CLink] public static extern void tn_soft_damp_wobble(void* world, uint32 bodyId, float rate, float step);
		[CLink] public static extern void tn_soft_bounce(void* world, uint32 bodyId, float bounciness, float* state);
		[CLink] public static extern void tn_soft_proxies(void* world, uint32* bodies, int32* closed, float* reach, uint32 count);
		[CLink] public static extern bool tn_soft_bounds(void* world, uint32 bodyId, Vector3* min, Vector3* max);
		[CLink] public static extern uint32 tn_soft_float(void* world, uint32 bodyId, float* samples, uint32 nx, uint32 nz, float minX, float minZ, float cellX, float cellZ, float bottom, float band, float buoyancy, float drag, float gravity, float step, bool wake);
		[CLink] public static extern uint32 tn_rope_create(void* world, PhysicsRopeConfig* config, float* positions, uint32 count, float* pinned, float* center);
		[CLink] public static extern void* tn_rope_tie(void* world, uint32 bodyA, float* pointA, uint32 bodyB, float* pointB, float length);
		[CLink] public static extern void tn_rope_untie(void* world, void* tie);
		[CLink] public static extern float tn_rope_pull(void* tie, float step);
		[CLink] public static extern bool tn_rope_wraps(void* world, uint32 bodyId, float* start, float* end, float clearance, uint32* first, uint32* last, float* places);
		[CLink] public static extern void* tn_rope_tie_over(void* world, uint32 bodyA, float* pointA, float* fixedA, uint32 bodyB, float* pointB, float* fixedB, float length);
		[CLink] public static extern void tn_rope_wind(void* world, uint32 bodyId, float* wind, float radius, float drag, float turbulence, float time, float step);
	}

	void* mSystem;

	public this(void* system)
	{
		mSystem = system;
	}

	public override void WorldDestroyed()
	{
		if (mSystem != null)
			Native.tn_soft_world_destroyed(mSystem);
	}

	public override uint32 Create(PhysicsSoftBodyConfig* config, float* positions, uint32 vertexCount, uint32* triangles, uint32 triangleCount, float* pinned, float* stiffness, float* center, float* objectMatrix)
		=> mSystem != null ? Native.tn_soft_create(mSystem, config, positions, vertexCount, triangles, triangleCount, pinned, stiffness, center, objectMatrix) : uint32.MaxValue;

	public override void Ignore(uint32 bodyId, uint32 ignoredBody) { if (mSystem != null) Native.tn_soft_ignore(mSystem, bodyId, ignoredBody); }
	public override void Forget(uint32 bodyId) { if (mSystem != null) Native.tn_soft_forget(mSystem, bodyId); }
	public override void Skin(uint32 bodyId, float* objectMatrix, float* objectNext, float step) { if (mSystem != null) Native.tn_soft_skin(mSystem, bodyId, objectMatrix, objectNext, step); }
	public override uint32 Dents(uint32 bodyId, float* output, uint32 capacity) => mSystem != null ? Native.tn_soft_dents(mSystem, bodyId, output, capacity) : 0;
	public override uint32 DentRevision(uint32 bodyId) => mSystem != null ? Native.tn_soft_dent_revision(mSystem, bodyId) : 0;
	public override void SetDents(uint32 bodyId, float* dents, uint32 count, float* objectMatrix) { if (mSystem != null) Native.tn_soft_set_dents(mSystem, bodyId, dents, count, objectMatrix); }
	public override uint32 Read(uint32 bodyId, float* positions, float* velocities, uint32 capacity) => mSystem != null ? Native.tn_soft_read(mSystem, bodyId, positions, velocities, capacity) : 0;
	public override void MovePinned(uint32 bodyId, uint32* indices, float* targets, uint32 count, float step) { if (mSystem != null) Native.tn_soft_move_pinned(mSystem, bodyId, indices, targets, count, step); }
	public override void SetPositions(uint32 bodyId, float* positions, float* velocities, uint32 count) { if (mSystem != null) Native.tn_soft_set_positions(mSystem, bodyId, positions, velocities, count); }
	public override uint32 Velocity(uint32 bodyId, float* velocity) => mSystem != null ? Native.tn_soft_velocity(mSystem, bodyId, velocity) : 0;
	public override void SetVelocity(uint32 bodyId, float* velocity) { if (mSystem != null) Native.tn_soft_set_velocity(mSystem, bodyId, velocity); }
	public override void Impulse(uint32 bodyId, float* impulse) { if (mSystem != null) Native.tn_soft_impulse(mSystem, bodyId, impulse); }
	public override void Force(uint32 bodyId, float* force, float step) { if (mSystem != null) Native.tn_soft_force(mSystem, bodyId, force, step); }
	public override void Wind(uint32 bodyId, float* wind, float drag, float turbulence, float time, float step) { if (mSystem != null) Native.tn_soft_wind(mSystem, bodyId, wind, drag, turbulence, time, step); }
	public override uint32 Touching(uint32 bodyId, uint32* output, uint32 capacity) => mSystem != null ? Native.tn_soft_touching(mSystem, bodyId, output, capacity) : 0;
	public override void Shift(uint32 bodyId, float* offset) { if (mSystem != null) Native.tn_soft_shift(mSystem, bodyId, offset); }
	public override void SetPressure(uint32 bodyId, float pressure) { if (mSystem != null) Native.tn_soft_set_pressure(mSystem, bodyId, pressure); }
	public override void DampWobble(uint32 bodyId, float rate, float step) { if (mSystem != null) Native.tn_soft_damp_wobble(mSystem, bodyId, rate, step); }
	public override void Bounce(uint32 bodyId, float bounciness, float* state) { if (mSystem != null) Native.tn_soft_bounce(mSystem, bodyId, bounciness, state); }
	public override void Proxies(uint32* bodies, int32* closed, float* reach, uint32 count) { if (mSystem != null) Native.tn_soft_proxies(mSystem, bodies, closed, reach, count); }

	public override bool Bounds(uint32 bodyId, out Vector3 min, out Vector3 max)
	{
		min = default;
		max = default;
		return mSystem != null && Native.tn_soft_bounds(mSystem, bodyId, &min, &max);
	}

	public override uint32 FloatSoft(uint32 bodyId, float* samples, uint32 nx, uint32 nz, float minX, float minZ, float cellX, float cellZ, float bottom, float band, float buoyancy, float drag, float gravity, float deltaTime, bool wake)
		=> mSystem != null ? Native.tn_soft_float(mSystem, bodyId, samples, nx, nz, minX, minZ, cellX, cellZ, bottom, band, buoyancy, drag, gravity, deltaTime, wake) : 0;

	public override uint32 CreateRope(PhysicsRopeConfig* config, float* positions, uint32 count, float* pinned, float* center)
		=> mSystem != null ? Native.tn_rope_create(mSystem, config, positions, count, pinned, center) : uint32.MaxValue;

	public override void* Tie(uint32 bodyA, float* pointA, uint32 bodyB, float* pointB, float length) => mSystem != null ? Native.tn_rope_tie(mSystem, bodyA, pointA, bodyB, pointB, length) : null;
	public override void Untie(void* tie) { if (mSystem != null) Native.tn_rope_untie(mSystem, tie); }
	public override float Pull(void* tie, float step) => Native.tn_rope_pull(tie, step);
	public override bool Wraps(uint32 bodyId, float* start, float* end, float clearance, out uint32 first, out uint32 last, float* places)
	{
		first = uint32.MaxValue;
		last = uint32.MaxValue;
		if (mSystem == null) return false;
		uint32 f = uint32.MaxValue, l = uint32.MaxValue;
		let found = Native.tn_rope_wraps(mSystem, bodyId, start, end, clearance, &f, &l, places);
		first = f;
		last = l;
		return found;
	}
	public override void* TieOver(uint32 bodyA, float* pointA, float* fixedA, uint32 bodyB, float* pointB, float* fixedB, float length) => mSystem != null ? Native.tn_rope_tie_over(mSystem, bodyA, pointA, fixedA, bodyB, pointB, fixedB, length) : null;
	public override void WindRope(uint32 bodyId, float* wind, float radius, float drag, float turbulence, float time, float step) { if (mSystem != null) Native.tn_rope_wind(mSystem, bodyId, wind, radius, drag, turbulence, time, step); }
}
