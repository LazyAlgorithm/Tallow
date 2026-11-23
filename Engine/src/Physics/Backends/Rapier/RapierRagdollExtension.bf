using System;
using System.Collections;

namespace Tallow;

/// Rapier ragdolls built from ordinary dynamic bodies and ball joints, behind the neutral PhysicsRagdollExtension.
/// Rapier has no built-in ragdoll object; joints between the parts are the same physics it would use, so the engine
/// can tear, push and pose parts like any other bodies.
class RapierRagdollExtension : PhysicsRagdollExtension
{
	class Ragdoll
	{
		public List<uint32> bodies = new .() ~ delete _;
		public List<void*> joints = new .() ~ delete _;
		public Vector3 rootPosition = default;
		public bool inWorld = true;
	}

	RapierPhysicsBackendWorld mBackend;
	Dictionary<void*, Ragdoll> mRagdolls = new .() ~
		{
			for (let (id, ragdoll) in _)
			{
				DestroyBodies(ragdoll);
				delete ragdoll;
			}
			delete _;
		};

	public this(RapierPhysicsBackendWorld backend)
	{
		mBackend = backend;
	}

	public override void WorldDestroyed()
	{
		for (let (id, ragdoll) in mRagdolls)
			delete ragdoll;
		mRagdolls.Clear();
	}

	void DestroyBodies(Ragdoll ragdoll)
	{
		if (mBackend == null)
			return;
		for (let joint in ragdoll.joints)
			mBackend.DestroyJoint(joint);
		ragdoll.joints.Clear();
		for (let body in ragdoll.bodies)
			mBackend.DestroyBody(body);
		ragdoll.bodies.Clear();
	}

	public override void* Create(PhysicsRagdollDesc desc)
	{
		if (mBackend == null || desc.parts == null || desc.count <= 0)
			return null;
		let ragdoll = new Ragdoll();
		for (int32 i = 0; i < desc.count; i++)
		{
			let part = desc.parts[i];
			PhysicsBodyDesc body = default;
			body.motion = .Dynamic;
			body.position = part.position;
			body.rotation = part.rotation;
			body.objectCode = part.objectCode;
			body.friction = 0.6f;
			body.restitution = 0;
			body.linearDamping = 0.05f;
			body.angularDamping = 0.4f;
			body.gravityFactor = 1;
			body.allowSleeping = true;
			body.overrideMass = true;
			body.mass = Math.Max(part.mass, 0.001f);
			body.userData = desc.userData;
			let id = mBackend.CreateBody(body, part.shape);
			if (id == uint32.MaxValue)
			{
				DestroyBodies(ragdoll);
				delete ragdoll;
				return null;
			}
			ragdoll.bodies.Add(id);
		}
		for (int32 i = 0; i < desc.count; i++)
		{
			let part = desc.parts[i];
			if (part.parent < 0 || part.parent >= (int32)ragdoll.bodies.Count)
				continue;
			let parent = desc.parts[part.parent];
			PhysicsJointDesc joint = default;
			joint.kind = .Ball;
			joint.bodyA = ragdoll.bodies[part.parent];
			joint.bodyB = ragdoll.bodies[i];
			// The parts are centred on their bones, so they meet halfway between the two centres.
			joint.anchor = (parent.position + part.position) * 0.5f;
			joint.axis = part.axis.LengthSquared > 0.0001f ? part.axis.Normalized : Vector3.Up;
			joint.swingLimitRadians = Math.Max(part.swingLimitRadians, 0);
			let handle = mBackend.CreateJoint(joint);
			if (handle != null)
				ragdoll.joints.Add(handle);
		}
		ragdoll.rootPosition = desc.parts[0].position;
		void* key = Internal.UnsafeCastToPtr(ragdoll);
		mRagdolls[key] = ragdoll;
		return key;
	}

	public override void Destroy(void* ragdollPtr)
	{
		if (ragdollPtr == null)
			return;
		Ragdoll ragdoll;
		if (!mRagdolls.TryGetValue(ragdollPtr, out ragdoll))
			return;
		DestroyBodies(ragdoll);
		mRagdolls.Remove(ragdollPtr);
		delete ragdoll;
	}

	public override void AddToWorld(void* ragdollPtr, bool activate)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		if (ragdoll == null)
			return;
		for (let body in ragdoll.bodies)
			mBackend.AddBodyToWorld(body, activate);
		ragdoll.inWorld = true;
	}

	public override void RemoveFromWorld(void* ragdollPtr)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		if (ragdoll == null)
			return;
		for (let body in ragdoll.bodies)
			mBackend.RemoveBodyFromWorld(body);
		ragdoll.inWorld = false;
	}

	Ragdoll RagdollFor(void* ragdollPtr)
	{
		Ragdoll ragdoll = null;
		if (ragdollPtr != null)
			mRagdolls.TryGetValue(ragdollPtr, out ragdoll);
		return ragdoll;
	}

	/// A model-space matrix for a part, relative to the ragdoll's root position.
	static void MatrixOf(Vector3 root, Vector3 position, Quaternion rotation, PhysicsRagdollMatrix* into)
	{
		let matrix = Matrix4.TRS(position - root, rotation, Vector3.One);
		*into = PhysicsRagdollMatrix.From(matrix);
	}

	public override void SetPose(void* ragdollPtr, Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		if (ragdoll == null || jointMatrices == null)
			return;
		for (int32 i = 0; i < (int32)ragdoll.bodies.Count; i++)
		{
			jointMatrices[i].ToMatrix().Decompose(var position, var rotation, var scale);
			mBackend.SetBodyPose(ragdoll.bodies[i], position + rootOffset, rotation, !lockBodies);
		}
		ragdoll.rootPosition = rootOffset;
	}

	public override void GetPose(void* ragdollPtr, out Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, bool lockBodies)
	{
		rootOffset = default;
		let ragdoll = RagdollFor(ragdollPtr);
		if (ragdoll == null || jointMatrices == null)
			return;
		mBackend.GetBodyPose(ragdoll.bodies[0], let root, let rootRotation);
		rootOffset = root;
		for (int32 i = 0; i < (int32)ragdoll.bodies.Count; i++)
		{
			mBackend.GetBodyPose(ragdoll.bodies[i], let position, let rotation);
			MatrixOf(root, position, rotation, &jointMatrices[i]);
		}
	}

	public override void DriveToPose(void* ragdollPtr, Vector3 rootOffset, PhysicsRagdollMatrix* jointMatrices, float deltaTime, bool useMotors, bool lockBodies)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		if (ragdoll == null || jointMatrices == null || deltaTime <= 0.00001f)
			return;
		for (int32 i = 0; i < (int32)ragdoll.bodies.Count; i++)
		{
			jointMatrices[i].ToMatrix().Decompose(var target, let rotation, let scale);
			target += rootOffset;
			mBackend.GetBodyPose(ragdoll.bodies[i], let position, let current);
			let velocity = (target - position) * (1.0f / deltaTime);
			mBackend.SetLinearVelocity(ragdoll.bodies[i], velocity);
			// The joints keep the limbs together; the velocity drive is enough to carry the pose.
			(void)current;
			(void)rotation;
			(void)lockBodies;
		}
	}

	public override void Activate(void* ragdollPtr, bool lockBodies)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		if (ragdoll == null)
			return;
		for (let body in ragdoll.bodies)
			mBackend.ActivateBody(body);
	}

	public override bool IsActive(void* ragdollPtr, bool lockBodies)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		if (ragdoll == null || ragdoll.bodies.Count == 0)
			return false;
		for (let body in ragdoll.bodies)
		{
			if (!mBackend.IsSleeping(body))
				return true;
		}
		return false;
	}

	public override int32 BodyCount(void* ragdollPtr)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		return ragdoll != null ? (int32)ragdoll.bodies.Count : 0;
	}

	public override uint32 BodyId(void* ragdollPtr, int32 index)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		return ragdoll != null && index >= 0 && index < (int32)ragdoll.bodies.Count ? ragdoll.bodies[index] : uint32.MaxValue;
	}

	public override int32 ConstraintCount(void* ragdollPtr)
	{
		let ragdoll = RagdollFor(ragdollPtr);
		return ragdoll != null ? (int32)ragdoll.joints.Count : 0;
	}
}
