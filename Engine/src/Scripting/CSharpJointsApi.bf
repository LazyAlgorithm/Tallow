using System;
using System.Collections;

namespace Tallow;

/// Hinges and suspensions made from C# (Tallow.API's PhysicsJoint). C# holds a number, never the native joint: each
/// number maps to the joint and its generation in the scene it was made in, so a joint that went with one of its
/// bodies, or a later one at the same address, reads as gone.
[CSharpExpose]
static class CSharpJoints
{
	struct Entry
	{
		public uint64 session;
		public void* joint;
		public uint64 generation;
		public bool hinge;
	}

	static Dictionary<uint64, Entry> sJoints = new .() ~ delete _;
	static uint64 sNext = 1;

	static uint64 Add(uint64 session, PhysicsWorld physics, void* joint, bool hinge)
	{
		if (joint == null)
			return 0;
		// Forget joints of other sessions and ones that have gone, so the table does not grow over a long game.
		if (sJoints.Count >= 256)
		{
			let gone = scope List<uint64>();
			for (let pair in sJoints)
			{
				if (pair.value.session != session || !physics.HasJoint(pair.value.joint)
					|| physics.JointGeneration(pair.value.joint) != pair.value.generation)
					gone.Add(pair.key);
			}
			for (let key in gone)
				sJoints.Remove(key);
		}
		let id = sNext++;
		sJoints[id] = .() { session = session, joint = joint, generation = physics.JointGeneration(joint), hinge = hinge };
		return id;
	}

	/// The live joint behind a number, or null.
	static void* Live(uint64 session, uint64 id, bool hinge, out PhysicsWorld physics)
	{
		physics = CSharpRuntime.PhysicsScene(session)?.Physics;
		Entry entry = default;
		if (physics == null || !sJoints.TryGetValue(id, out entry))
			return null;
		if (entry.session != session || entry.hinge != hinge)
			return null;
		if (!physics.HasJoint(entry.joint) || physics.JointGeneration(entry.joint) != entry.generation)
			return null;
		return entry.joint;
	}

	static bool Finite(Vector3 v) => v.x.IsFinite && v.y.IsFinite && v.z.IsFinite;

	[CSharpExpose]
	public static uint64 CreateHinge(uint64 session, uint32 bodyA, uint32 bodyB, Vector3 anchor, Vector3 axis, Vector3 childAxis,
		Vector3 childNormal)
	{
		let physics = CSharpRuntime.PhysicsScene(session)?.Physics;
		if (physics == null || !Finite(anchor) || !Finite(axis) || !Finite(childAxis) || !Finite(childNormal)
			|| axis.LengthSquared < 1e-8f || childAxis.LengthSquared < 1e-8f || childNormal.LengthSquared < 1e-8f)
			return 0;
		return Add(session, physics, physics.CreateHinge(bodyA, bodyB, anchor, axis, childAxis, childNormal), true);
	}

	[CSharpExpose]
	public static uint64 CreateSuspension(uint64 session, uint32 bodyA, uint32 bodyB, Vector3 anchor, Vector3 childAnchor,
		Vector3 axis, Vector3 childAxis, Vector3 childNormal, float travel)
	{
		let physics = CSharpRuntime.PhysicsScene(session)?.Physics;
		if (physics == null || !Finite(anchor) || !Finite(childAnchor) || !Finite(axis) || !Finite(childAxis)
			|| !Finite(childNormal) || !travel.IsFinite || travel < 0 || axis.LengthSquared < 1e-8f
			|| childAxis.LengthSquared < 1e-8f || childNormal.LengthSquared < 1e-8f)
			return 0;
		return Add(session, physics, physics.CreateSuspension(bodyA, bodyB, anchor, childAnchor, axis, childAxis, childNormal, travel), false);
	}

	/// Whether the joint is still in the world (it goes with either of its bodies).
	[CSharpExpose]
	public static bool IsAlive(uint64 session, uint64 id, bool hinge) => Live(session, id, hinge, ?) != null;

	[CSharpExpose]
	public static void SetHingeMotor(uint64 session, uint64 id, float speed, float torque, float angle, int32 mode, float response,
		float maximumSpeed)
	{
		if (!speed.IsFinite || !torque.IsFinite || !angle.IsFinite || !response.IsFinite || !maximumSpeed.IsFinite
			|| mode < 0 || mode > 2)
			return;
		let joint = Live(session, id, true, let physics);
		if (joint != null)
			physics.SetHingeMotor(joint, speed, torque, angle, mode, response, maximumSpeed);
	}

	[CSharpExpose]
	public static float HingeAngle(uint64 session, uint64 id)
	{
		let joint = Live(session, id, true, let physics);
		return joint != null ? physics.HingeAngle(joint) : 0;
	}

	[CSharpExpose]
	public static void SetSuspensionSpring(uint64 session, uint64 id, float stiffness, float damping)
	{
		if (!stiffness.IsFinite || !damping.IsFinite)
			return;
		let joint = Live(session, id, false, let physics);
		if (joint != null)
			physics.SetSuspensionSpring(joint, stiffness, damping);
	}

	[CSharpExpose]
	public static float SuspensionPosition(uint64 session, uint64 id)
	{
		let joint = Live(session, id, false, let physics);
		return joint != null ? physics.SuspensionPosition(joint) : 0;
	}

	/// Removes the joint; nothing when it has already gone.
	[CSharpExpose]
	public static void Destroy(uint64 session, uint64 id, bool hinge)
	{
		let joint = Live(session, id, hinge, let physics);
		if (joint != null)
			physics.DestroyJoint(joint);
		sJoints.Remove(id);
	}
}
