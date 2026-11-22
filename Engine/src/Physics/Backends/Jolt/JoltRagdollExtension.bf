using System;
using System.Collections;

namespace Tallow;

/// Jolt's built-in ragdoll (JPH_Ragdoll): one body per part held by swing-twist constraints, stabilized and driven by
/// the skeleton pose. This is the Jolt implementation of PhysicsRagdollExtension; another backend can build the same
/// ragdoll from articulations or ordinary joints.
class JoltRagdollExtension : PhysicsRagdollExtension
{
	[CRepr]
	struct JPH_SpringSettings
	{
		public int32 mode;
		public float frequencyOrStiffness;
		public float damping;
	}

	[CRepr]
	struct JPH_MotorSettings
	{
		public JPH_SpringSettings springSettings;
		public float minForceLimit, maxForceLimit, minTorqueLimit, maxTorqueLimit;
	}

	[CRepr]
	struct JPH_ConstraintSettings
	{
		public uint8 enabled;
		public uint32 constraintPriority;
		public uint32 numVelocityStepsOverride;
		public uint32 numPositionStepsOverride;
		public float drawConstraintSize;
		public uint64 userData;
	}

	[CRepr]
	struct JPH_SwingTwistConstraintSettings
	{
		public JPH_ConstraintSettings common;
		public int32 space;
		public Vector3 position1;
		public Vector3 twistAxis1;
		public Vector3 planeAxis1;
		public Vector3 position2;
		public Vector3 twistAxis2;
		public Vector3 planeAxis2;
		public int32 swingType;
		public float normalHalfConeAngle;
		public float planeHalfConeAngle;
		public float twistMinAngle;
		public float twistMaxAngle;
		public float maxFrictionTorque;
		public JPH_MotorSettings swingMotorSettings;
		public JPH_MotorSettings twistMotorSettings;
	}

	static class Native
	{
		[CLink] public static extern void* JPH_Skeleton_Create();
		[CLink] public static extern void JPH_Skeleton_Destroy(void* skeleton);
		[CLink] public static extern uint32 JPH_Skeleton_AddJoint2(void* skeleton, char8* name, int32 parent);
		[CLink] public static extern void* JPH_RagdollSettings_Create();
		[CLink] public static extern void JPH_RagdollSettings_Destroy(void* settings);
		[CLink] public static extern void JPH_RagdollSettings_SetSkeleton(void* settings, void* skeleton);
		[CLink] public static extern bool JPH_RagdollSettings_Stabilize(void* settings);
		[CLink] public static extern void JPH_RagdollSettings_DisableParentChildCollisions(void* settings, PhysicsRagdollMatrix* jointMatrices, float minSeparationDistance);
		[CLink] public static extern void JPH_RagdollSettings_CalculateBodyIndexToConstraintIndex(void* settings);
		[CLink] public static extern void JPH_RagdollSettings_CalculateConstraintIndexToBodyIdxPair(void* settings);
		[CLink] public static extern void JPH_RagdollSettings_ResizeParts(void* settings, int32 count);
		[CLink] public static extern void JPH_RagdollSettings_SetPartShape(void* settings, int32 part, void* shape);
		[CLink] public static extern void JPH_RagdollSettings_SetPartPosition(void* settings, int32 part, Vector3* position);
		[CLink] public static extern void JPH_RagdollSettings_SetPartRotation(void* settings, int32 part, Quaternion* rotation);
		[CLink] public static extern void JPH_RagdollSettings_SetPartMotionType(void* settings, int32 part, int32 motionType);
		[CLink] public static extern void JPH_RagdollSettings_SetPartObjectLayer(void* settings, int32 part, uint32 layer);
		[CLink] public static extern void JPH_RagdollSettings_SetPartMassProperties(void* settings, int32 part, float mass);
		[CLink] public static extern void JPH_RagdollSettings_SetPartToParent(void* settings, int32 part, JPH_SwingTwistConstraintSettings* constraint);
		[CLink] public static extern void* JPH_RagdollSettings_CreateRagdoll(void* settings, void* system, uint32 collisionGroup, uint64 userData);
		[CLink] public static extern void JPH_Ragdoll_Destroy(void* ragdoll);
		[CLink] public static extern void JPH_Ragdoll_AddToPhysicsSystem(void* ragdoll, int32 activation, bool lockBodies);
		[CLink] public static extern void JPH_Ragdoll_RemoveFromPhysicsSystem(void* ragdoll, bool lockBodies);
		[CLink] public static extern void JPH_Ragdoll_Activate(void* ragdoll, bool lockBodies);
		[CLink] public static extern bool JPH_Ragdoll_IsActive(void* ragdoll, bool lockBodies);
		[CLink] public static extern void JPH_Ragdoll_SetPose2(void* ragdoll, Vector3* rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies);
		[CLink] public static extern void JPH_Ragdoll_GetPose2(void* ragdoll, Vector3* rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies);
		[CLink] public static extern int32 JPH_Ragdoll_GetBodyCount(void* ragdoll);
		[CLink] public static extern uint32 JPH_Ragdoll_GetBodyID(void* ragdoll, int32 body);
		[CLink] public static extern int32 JPH_Ragdoll_GetConstraintCount(void* ragdoll);
		[CLink] public static extern void* JPH_Ragdoll_GetRagdollSettings(void* ragdoll);
		[CLink] public static extern void* JPH_RagdollSettings_GetSkeleton(void* settings);
		[CLink] public static extern void JPH_SwingTwistConstraintSettings_Init(JPH_SwingTwistConstraintSettings* settings);
		[CLink] public static extern void* JPH_SkeletonPose_Create();
		[CLink] public static extern void JPH_SkeletonPose_Destroy(void* pose);
		[CLink] public static extern void JPH_SkeletonPose_SetSkeleton(void* pose, void* skeleton);
		[CLink] public static extern void JPH_SkeletonPose_SetRootOffset(void* pose, Vector3* offset);
		[CLink] public static extern void JPH_SkeletonPose_SetJointMatrices(void* pose, Matrix4* matrices, int32 count);
		[CLink] public static extern void JPH_SkeletonPose_CalculateJointStates(void* pose);
		[CLink] public static extern void JPH_Ragdoll_DriveToPoseUsingMotors(void* ragdoll, void* pose);
		[CLink] public static extern void JPH_Ragdoll_DriveToPoseUsingKinematics(void* ragdoll, void* pose, float deltaTime, bool lockBodies);
	}

	class Handle
	{
		public void* ragdoll;
		public void* settings;
		public int32 bodyCount;
		public bool inWorld;
	}


	JoltPhysicsBackendWorld mWorld;
	void* mSystem;
	Dictionary<void*, Handle> mByRagdoll = new .() ~ delete _;

	public this(JoltPhysicsBackendWorld world, void* system)
	{
		mWorld = world;
		mSystem = system;
	}

	Handle From(void* ragdoll)
	{
		if (ragdoll == null)
			return null;
		Handle handle;
		return mByRagdoll.TryGetValue(ragdoll, out handle) ? handle : null;
	}

	public override void WorldDestroyed()
	{
		List<Handle> live = scope .();
		live.AddRange(mByRagdoll.Values);
		for (let handle in live)
			DestroyHandle(handle);
	}

	void DestroyHandle(Handle handle)
	{
		if (handle == null)
			return;
		if (handle.inWorld)
			Native.JPH_Ragdoll_RemoveFromPhysicsSystem(handle.ragdoll, true);
		Native.JPH_Ragdoll_Destroy(handle.ragdoll);
		if (handle.settings != null)
			Native.JPH_RagdollSettings_Destroy(handle.settings);
		mByRagdoll.Remove(handle.ragdoll);
		delete handle;
	}

	public override void* Create(PhysicsRagdollDesc spec)
	{
		if (mSystem == null || spec.parts == null || spec.count <= 0)
			return null;
		let skeleton = Native.JPH_Skeleton_Create();
		if (skeleton == null)
			return null;
		let partCount = spec.count;
		for (int32 i = 0; i < partCount; i++)
		{
			let name = scope String();
			name.AppendF("part{}", i);
			Native.JPH_Skeleton_AddJoint2(skeleton, name.CStr(), spec.parts[i].parent);
		}
		let settings = Native.JPH_RagdollSettings_Create();
		if (settings == null)
		{
			Native.JPH_Skeleton_Destroy(skeleton);
			return null;
		}
		Native.JPH_RagdollSettings_SetSkeleton(settings, skeleton);
		// The settings hold the skeleton now.
		Native.JPH_Skeleton_Destroy(skeleton);
		Native.JPH_RagdollSettings_ResizeParts(settings, partCount);
		for (int32 i = 0; i < partCount; i++)
		{
			let part = spec.parts[i];
			let shape = mWorld.CreateShapeForRagdoll(part.shape);
			if (shape == null)
			{
				Native.JPH_RagdollSettings_Destroy(settings);
				return null;
			}
			Native.JPH_RagdollSettings_SetPartShape(settings, i, shape);
			// The settings keep their own reference to the shape.
			Jolt.JPH_Shape_Destroy(shape);
			var position = part.position;
			var rotation = part.rotation;
			Native.JPH_RagdollSettings_SetPartPosition(settings, i, &position);
			Native.JPH_RagdollSettings_SetPartRotation(settings, i, &rotation);
			Native.JPH_RagdollSettings_SetPartMotionType(settings, i, 2);
			Native.JPH_RagdollSettings_SetPartObjectLayer(settings, i, part.objectCode);
			Native.JPH_RagdollSettings_SetPartMassProperties(settings, i, Math.Max(part.mass, 0.001f));
			if (part.parent >= 0)
			{
				JPH_SwingTwistConstraintSettings constraint = default;
				Native.JPH_SwingTwistConstraintSettings_Init(&constraint);
				constraint.space = 1;
				constraint.position1 = part.position;
				constraint.position2 = part.position;
				var axis = part.axis.LengthSquared > 1.0e-8f ? part.axis.Normalized : Vector3.Up;
				let side = Math.Abs(axis.x) < 0.9f ? Vector3.Right : Vector3.Up;
				let plane = Vector3.Cross(side, axis).Normalized;
				constraint.twistAxis1 = axis;
				constraint.twistAxis2 = axis;
				constraint.planeAxis1 = plane;
				constraint.planeAxis2 = plane;
				constraint.swingType = 0;
				constraint.normalHalfConeAngle = Math.Max(part.swingLimitRadians, 0);
				constraint.planeHalfConeAngle = Math.Max(part.swingLimitRadians, 0);
				constraint.twistMinAngle = -Math.Max(part.twistLimitRadians, 0);
				constraint.twistMaxAngle = Math.Max(part.twistLimitRadians, 0);
				Native.JPH_RagdollSettings_SetPartToParent(settings, i, &constraint);
			}
		}
		Native.JPH_RagdollSettings_Stabilize(settings);
		if (spec.disableParentChildCollisions)
			Native.JPH_RagdollSettings_DisableParentChildCollisions(settings, null, 0.01f);
		Native.JPH_RagdollSettings_CalculateBodyIndexToConstraintIndex(settings);
		Native.JPH_RagdollSettings_CalculateConstraintIndexToBodyIdxPair(settings);
		let ragdoll = Native.JPH_RagdollSettings_CreateRagdoll(settings, mSystem, 0, spec.userData);
		if (ragdoll == null)
		{
			Native.JPH_RagdollSettings_Destroy(settings);
			return null;
		}
		let handle = new Handle();
		handle.ragdoll = ragdoll;
		handle.settings = settings;
		handle.bodyCount = Native.JPH_Ragdoll_GetBodyCount(ragdoll);
		mByRagdoll[ragdoll] = handle;
		return ragdoll;
	}

	public override void Destroy(void* ragdoll) => DestroyHandle(From(ragdoll));

	public override void AddToWorld(void* ragdoll, bool activate)
	{
		let handle = From(ragdoll);
		if (handle == null || handle.inWorld)
			return;
		Native.JPH_Ragdoll_AddToPhysicsSystem(handle.ragdoll, activate ? 0 : 1, true);
		handle.inWorld = true;
	}

	public override void RemoveFromWorld(void* ragdoll)
	{
		let handle = From(ragdoll);
		if (handle == null || !handle.inWorld)
			return;
		Native.JPH_Ragdoll_RemoveFromPhysicsSystem(handle.ragdoll, true);
		handle.inWorld = false;
	}

	public override void SetPose(void* ragdoll, Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies)
	{
		let handle = From(ragdoll);
		if (handle == null || jointMatrices == null) return;
		var offset = rootOffset;
		Native.JPH_Ragdoll_SetPose2(handle.ragdoll, &offset, jointMatrices, lockBodies);
	}

	public override void GetPose(void* ragdoll, out Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies)
	{
		rootOffset = default;
		let handle = From(ragdoll);
		if (handle == null || jointMatrices == null) return;
		Native.JPH_Ragdoll_GetPose2(handle.ragdoll, &rootOffset, jointMatrices, lockBodies);
	}

	public override void DriveToPose(void* ragdoll, Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, float deltaTime, bool useMotors, bool lockBodies)
	{
		let handle = From(ragdoll);
		if (handle == null || jointMatrices == null) return;
		let settings = Native.JPH_Ragdoll_GetRagdollSettings(handle.ragdoll);
		let skeleton = Native.JPH_RagdollSettings_GetSkeleton(settings);
		let pose = Native.JPH_SkeletonPose_Create();
		Native.JPH_SkeletonPose_SetSkeleton(pose, skeleton);
		var offset = rootOffset;
		Native.JPH_SkeletonPose_SetRootOffset(pose, &offset);
		Native.JPH_SkeletonPose_SetJointMatrices(pose, (Matrix4*)jointMatrices, handle.bodyCount);
		Native.JPH_SkeletonPose_CalculateJointStates(pose);
		if (useMotors)
			Native.JPH_Ragdoll_DriveToPoseUsingMotors(handle.ragdoll, pose);
		else
			Native.JPH_Ragdoll_DriveToPoseUsingKinematics(handle.ragdoll, pose, deltaTime, lockBodies);
		Native.JPH_SkeletonPose_Destroy(pose);
	}

	public override void Activate(void* ragdoll, bool lockBodies)
	{
		let handle = From(ragdoll);
		if (handle != null)
			Native.JPH_Ragdoll_Activate(handle.ragdoll, lockBodies);
	}

	public override bool IsActive(void* ragdoll, bool lockBodies)
	{
		let handle = From(ragdoll);
		return handle != null && Native.JPH_Ragdoll_IsActive(handle.ragdoll, lockBodies);
	}

	public override int32 BodyCount(void* ragdoll)
	{
		let handle = From(ragdoll);
		return handle != null ? handle.bodyCount : 0;
	}

	public override uint32 BodyId(void* ragdoll, int32 index)
	{
		let handle = From(ragdoll);
		return handle != null ? Native.JPH_Ragdoll_GetBodyID(handle.ragdoll, index) : uint32.MaxValue;
	}

	public override int32 ConstraintCount(void* ragdoll)
	{
		let handle = From(ragdoll);
		return handle != null ? Native.JPH_Ragdoll_GetConstraintCount(handle.ragdoll) : 0;
	}
}
