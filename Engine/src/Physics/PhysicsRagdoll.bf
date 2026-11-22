using System;
using System.Collections;

namespace Tallow;

/// One limb of a backend ragdoll: a shape, where it starts, and the joint to its parent.
[CRepr]
struct PhysicsRagdollPart
{
	public ShapeDesc shape;
	public Vector3 position;
	public Quaternion rotation;
	public float mass;
	/// -1 for the root part; otherwise the index of the part it hangs from.
	public int32 parent;
	public PhysicsJointKind joint;
	/// The swing axis, in world space, for the joint to the parent.
	public Vector3 axis;
	public float swingLimitRadians;
	public float twistLimitRadians;
	public uint32 objectCode;
}

/// What a backend needs to build one ragdoll. A ragdoll is owned by the backend: Jolt makes a JPH_Ragdoll, another
/// engine can make an articulation or a set of jointed bodies. The engine-facing Ragdoll component builds this from a
/// rig and drives the pose.
[CRepr]
struct PhysicsRagdollDesc
{
	public PhysicsRagdollPart* parts;
	public int32 count;
	public uint64 userData;
	public bool disableParentChildCollisions;
}

/// One model-space joint matrix for a ragdoll pose. Jolt's Mat44 needs 16-byte alignment; Matrix4 itself is only
/// 4-byte aligned, and writing a Mat44 through an under-aligned pointer faults on SIMD stores.
[CRepr, Align(16)]
struct PhysicsRagdollMatrix
{
	public float[16] m;

	public Matrix4 ToMatrix()
	{
		Matrix4 result = default;
		for (int i < 16)
			result.m[i] = m[i];
		return result;
	}

	public static PhysicsRagdollMatrix From(Matrix4 matrix)
	{
		PhysicsRagdollMatrix result = default;
		for (int i < 16)
			result.m[i] = matrix.m[i];
		return result;
	}
}

/// The optional ragdoll half of a physics backend. Present (non-null) only when the backend advertises Ragdolls.
abstract class PhysicsRagdollExtension
{
	/// The backend world is going away: destroy any ragdolls still alive.
	public abstract void WorldDestroyed();
	public abstract void* Create(PhysicsRagdollDesc desc);
	public abstract void Destroy(void* ragdoll);
	public abstract void AddToWorld(void* ragdoll, bool activate);
	public abstract void RemoveFromWorld(void* ragdoll);
	/// Sets every part from a root offset and one world-space matrix per part (the skinned pose).
	public abstract void SetPose(void* ragdoll, Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies);
	/// Reads the current pose back into rootOffset and one world-space matrix per part.
	public abstract void GetPose(void* ragdoll, out Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies);
	/// Drives the parts towards a pose with motors (useMotors) or kinematics.
	public abstract void DriveToPose(void* ragdoll, Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, float deltaTime, bool useMotors, bool lockBodies);
	public abstract void Activate(void* ragdoll, bool lockBodies);
	public abstract bool IsActive(void* ragdoll, bool lockBodies);
	public abstract int32 BodyCount(void* ragdoll);
	public abstract uint32 BodyId(void* ragdoll, int32 index);
	public abstract int32 ConstraintCount(void* ragdoll);
}
