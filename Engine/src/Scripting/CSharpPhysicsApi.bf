using System;
using System.Collections;

namespace Tallow;

/// A stable 56-byte native/managed value record. Fields use primitive numeric
/// types, never a native object pointer or a platform-dependent Vector3
/// packing. C# declares the same sequential layout in PhysicsQueryHit.
[CRepr]
struct PhysicsQueryHit
{
	public uint64 entityId;
	public float pointX, pointY, pointZ;
	public float normalX, normalY, normalZ;
	public float distance, penetrationDepth;
	public uint32 bodyId, flags;
	/// Which part of a Compound Collider, and which triangle of a Mesh Collider, was hit; -1 for none.
	public int32 part, triangle;
}

/// The C# ABI exposes *existing* scene, Flecs-backed Rigidbody and Jolt-backed
/// SoftBody operations. Sessions and entity IDs are validated on every call.
/// No native object pointer or Jolt body ID crosses the managed boundary.
/// All public methods here require [CSharpExpose] explicitly.
[CSharpExpose]
static class Physics
{
	/// The active physics scene; rejects handles from old Play sessions.
	static Scene LiveScene(uint64 session) => CSharpRuntime.PhysicsScene(session);

	static GameObject LiveObject(uint64 session, uint64 entity) =>
		CSharpRuntime.PhysicsObject(session, entity);

	/// The features the scene's selected 3D physics backend supports, as PhysicsFeature bits. Use this to check
	/// before calling a backend-specific API (soft bodies, ropes, buoyancy) or adding a component.
	[CSharpExpose]
	public static uint64 FeatureBits(uint64 session)
	{
		let scene = LiveScene(session);
		return scene != null && scene.Physics != null ? scene.Physics.Features.bits : 0;
	}

	/// Whether every feature in the mask is available. The C# PhysicsFeature enum has the same bit values.
	[CSharpExpose]
	public static bool Supports(uint64 session, uint64 features)
	{
		let scene = LiveScene(session);
		return scene != null && scene.Physics != null && scene.Physics.Features.HasAll(.((uint64)features));
	}

	[CSharpExpose]
	public static bool HasRigidbody(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj != null && obj.HasComponent<Rigidbody>();
	}

	[CSharpExpose]
	public static bool HasRigidbodyBody(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj != null && obj.GetComponent<Rigidbody>().HasBody;
	}

	/// The Rigidbody's body id (for a cast to ignore), uint32.MaxValue when it has no body.
	[CSharpExpose]
	public static uint32 RigidbodyBodyId(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj != null ? obj.GetComponent<Rigidbody>().BodyId : uint32.MaxValue;
	}

	[CSharpExpose]
	public static Vector3 GetRigidbodyVelocity(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null)
			return .Zero;
		let body = obj.GetComponent<Rigidbody>();
		return body.HasBody ? body.Velocity : .Zero;
	}

	[CSharpExpose]
	public static bool SetRigidbodyVelocity(uint64 session, uint64 entity, Vector3 velocity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !FiniteVector(velocity))
			return false;
		let body = obj.GetComponent<Rigidbody>();
		// One added this frame has no physics body until the next step: make it now, so it starts moving at once.
		if (!body.HasBody && body.IsValid && obj.Scene != null && obj.Scene.IsPlaying)
			body.EnsureBody();
		if (!body.HasBody)
			return false;
		body.Velocity = velocity;
		return true;
	}

	[CSharpExpose]
	public static bool AddRigidbodyForce(uint64 session, uint64 entity, Vector3 force)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !FiniteVector(force))
			return false;
		let body = obj.GetComponent<Rigidbody>();
		if (!body.HasBody)
			return false;
		body.AddForce(force);
		return true;
	}

	[CSharpExpose]
	public static bool AddRigidbodyImpulse(uint64 session, uint64 entity, Vector3 impulse)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !FiniteVector(impulse))
			return false;
		let body = obj.GetComponent<Rigidbody>();
		if (!body.HasBody)
			return false;
		body.AddImpulse(impulse);
		return true;
	}


	// Rigidbody is already an ECS-backed handle. Native Jolt owns its state;
	// managed code receives only values and session-validated entity IDs.
	static bool FiniteVector(Vector3 value) =>
		value.x.IsFinite && value.y.IsFinite && value.z.IsFinite;

	[CSharpExpose]
	public static Vector3 GetRigidbodyAngularVelocity(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null)
			return .Zero;
		let body = obj.GetComponent<Rigidbody>();
		return body.HasBody ? body.AngularVelocity : .Zero;
	}

	[CSharpExpose]
	public static bool SetRigidbodyAngularVelocity(uint64 session, uint64 entity, Vector3 velocity)
	{
		if (!FiniteVector(velocity))
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null)
			return false;
		let body = obj.GetComponent<Rigidbody>();
		if (!body.HasBody)
			return false;
		body.AngularVelocity = velocity;
		return true;
	}

	[CSharpExpose]
	public static bool AddRigidbodyTorque(uint64 session, uint64 entity, Vector3 torque)
	{
		if (!FiniteVector(torque))
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null)
			return false;
		let body = obj.GetComponent<Rigidbody>();
		if (!body.HasBody)
			return false;
		body.AddTorque(torque);
		return true;
	}

	[CSharpExpose]
	public static bool AddRigidbodyForceAtPosition(uint64 session, uint64 entity,
		Vector3 force, Vector3 worldPoint)
	{
		if (!FiniteVector(force) || !FiniteVector(worldPoint))
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null)
			return false;
		let body = obj.GetComponent<Rigidbody>();
		if (!body.HasBody)
			return false;
		body.AddForceAtPosition(force, worldPoint);
		return true;
	}

	[CSharpExpose]
	public static Vector3 GetRigidbodyPointVelocity(uint64 session, uint64 entity,
		Vector3 worldPoint)
	{
		if (!FiniteVector(worldPoint))
			return .Zero;
		let obj = LiveObject(session, entity);
		if (obj == null)
			return .Zero;
		let body = obj.GetComponent<Rigidbody>();
		return body.HasBody ? body.GetPointVelocity(worldPoint) : .Zero;
	}

	[CSharpExpose]
	public static bool SleepRigidbody(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null)
			return false;
		let body = obj.GetComponent<Rigidbody>();
		if (!body.HasBody)
			return false;
		body.Sleep();
		return true;
	}

	// CharacterController is a Flecs handle backed by Tallow's real Jolt
	// virtual character. Movement executes in the existing native tick path.
	// These calls never expose native Jolt pointers to managed gameplay.
	[CSharpExpose]
	public static bool HasCharacterController(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj != null && obj.HasComponent<CharacterController>();
	}

	[CSharpExpose]
	public static bool HasCharacterSimulation(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		return obj.GetComponent<CharacterController>().HasCharacter;
	}

	[CSharpExpose]
	public static bool IsCharacterGrounded(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		return obj.GetComponent<CharacterController>().IsGrounded;
	}

	/// Seconds since the character was last on the ground (0 while it is).
	[CSharpExpose]
	public static float CharacterAirTime(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return (obj != null && obj.HasComponent<CharacterController>()) ? obj.GetComponent<CharacterController>().AirTime : 0;
	}

	/// Standing on ground too steep to walk up (it slides).
	[CSharpExpose]
	public static bool IsCharacterOnSteepGround(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj != null && obj.HasComponent<CharacterController>() && obj.GetComponent<CharacterController>().IsOnSteepGround;
	}

	/// The ground's surface normal (normal: true) or how the ground under it moves (a platform), zero in the air.
	[CSharpExpose]
	public static Vector3 CharacterGround(uint64 session, uint64 entity, bool normal)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return .Zero;
		let controller = obj.GetComponent<CharacterController>();
		return normal ? controller.GroundNormal : controller.GroundVelocity;
	}

	[CSharpExpose]
	public static bool CanCharacterJump(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		return obj.GetComponent<CharacterController>().CanJump;
	}

	[CSharpExpose]
	public static Vector3 GetCharacterVelocity(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return .Zero;
		return obj.GetComponent<CharacterController>().Velocity;
	}

	[CSharpExpose]
	public static bool MoveCharacter(uint64 session, uint64 entity,
		Vector3 velocity, float deltaTime)
	{
		if (!FiniteVector(velocity) || !deltaTime.IsFinite || deltaTime <= 0)
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		let controller = obj.GetComponent<CharacterController>();
		if (!controller.HasCharacter)
			return false;
		controller.Move(velocity, deltaTime);
		return true;
	}

	[CSharpExpose]
	public static bool SimpleMoveCharacter(uint64 session, uint64 entity,
		Vector3 horizontalVelocity, float deltaTime, float jumpSpeed)
	{
		if (!FiniteVector(horizontalVelocity) || !deltaTime.IsFinite || deltaTime <= 0 ||
			!jumpSpeed.IsFinite || jumpSpeed < 0)
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		let controller = obj.GetComponent<CharacterController>();
		if (!controller.HasCharacter)
			return false;
		controller.SimpleMove(horizontalVelocity, deltaTime, jumpSpeed);
		return true;
	}

	/// Changes the character's shape to a capsule or (with a size) a box. False when there is no room for it here.
	[CSharpExpose]
	public static bool SetCharacterShape(uint64 session, uint64 entity, bool asBox, float radius, float height,
		Vector3 size, float edgeRadius, Vector3 center)
	{
		if (!radius.IsFinite || !height.IsFinite || !edgeRadius.IsFinite || !FiniteVector(size) || !FiniteVector(center))
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		let controller = obj.GetComponent<CharacterController>();
		if (asBox)
			return size.x > 0 && size.y > 0 && size.z > 0 && edgeRadius >= 0 && controller.SetBox(size, edgeRadius, center);
		return radius > 0 && height > 0 && controller.SetCapsule(radius, height, center);
	}

	/// Crouching: the same capsule resize visual scripts use, including
	/// keeping the head still when crouching or standing up in the air and
	/// refusing to stand up into an obstacle.
	[CSharpExpose]
	public static bool SetCharacterHeight(uint64 session, uint64 entity,
		float height, float standingHeight)
	{
		if (!height.IsFinite || !standingHeight.IsFinite || height <= 0 ||
			standingHeight <= 0 || height > 100 || standingHeight > 100)
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		GraphRuntime.SetCharacterHeight(obj, height, standingHeight);
		return true;
	}

	/// The capsule height now; 0 without a Character Controller.
	[CSharpExpose]
	public static float GetCharacterHeight(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj == null ? 0 : GraphRuntime.CharacterHeight(obj);
	}

	/// How far SetCharacterHeight moved the character this frame to keep
	/// its head still in the air. Subtract it from a smoothed eye height.
	[CSharpExpose]
	public static float GetCharacterCrouchLift(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj == null ? 0 : GraphRuntime.CrouchLift(obj);
	}

	[CSharpExpose]
	public static bool TeleportCharacter(uint64 session, uint64 entity,
		Vector3 position, Vector3 velocity)
	{
		if (!FiniteVector(position) || !FiniteVector(velocity))
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<CharacterController>())
			return false;
		let controller = obj.GetComponent<CharacterController>();
		if (!controller.HasCharacter)
			return false;
		controller.Teleport(position, velocity);
		return true;
	}

	// Colliders intentionally remain *class* components. Tallow permits
	// several colliders per GameObject, including repeated shape types; each
	// index below addresses one component in its original attachment order.
	// This is not a Flecs HandleData component.
	static Collider ColliderAt(uint64 session, uint64 entity, int32 index)
	{
		if (index < 0)
			return null;
		let obj = LiveObject(session, entity);
		if (obj == null)
			return null;
		int32 current = 0;
		for (let component in obj.Components)
		{
			if (let collider = component as Collider)
			{
				if (current == index)
					return collider;
				current++;
			}
		}
		return null;
	}

	[CSharpExpose]
	public static int32 GetColliderCount(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null)
			return 0;
		int32 count = 0;
		for (let component in obj.Components)
		{
			if (component is Collider)
				count++;
		}
		return count;
	}

	/// Returns -1 if the collider index is invalid; otherwise 0-5:
	/// Box, Sphere, Capsule, Mesh, Compound, Convex.
	[CSharpExpose]
	public static int32 GetColliderKind(uint64 session, uint64 entity, int32 index)
	{
		let collider = ColliderAt(session, entity, index);
		if (collider == null)
			return -1;
		let type = collider.GetType();
		if (type == typeof(BoxCollider)) return 0;
		if (type == typeof(SphereCollider)) return 1;
		if (type == typeof(CapsuleCollider)) return 2;
		if (type == typeof(MeshCollider)) return 3;
		if (type == typeof(CompoundCollider)) return 4;
		if (type == typeof(ConvexCollider)) return 5;
		return -1;
	}

	/// -1 if the collider index is invalid, else 0 or 1.
	[CSharpExpose]
	public static int32 GetColliderIsTrigger(uint64 session, uint64 entity, int32 index)
	{
		let collider = ColliderAt(session, entity, index);
		return collider == null ? -1 : (collider.isTrigger ? 1 : 0);
	}

	/// Makes a collider a trigger or solid again. The object's body is rebuilt (keeping a Rigidbody's position and
	/// velocity), since a body is a sensor or not as a whole.
	[CSharpExpose]
	public static bool SetColliderIsTrigger(uint64 session, uint64 entity, int32 index, bool isTrigger)
	{
		let collider = ColliderAt(session, entity, index);
		if (collider == null)
			return false;
		if (collider.isTrigger == isTrigger)
			return true;
		collider.isTrigger = isTrigger;
		let obj = collider.GameObject;
		let rigidbody = obj.GetComponent<Rigidbody>();
		if (rigidbody.IsValid)
			rigidbody.RebuildBody();
		else
		{
			for (let component in obj.Components)
			{
				if (let other = component as Collider)
					other.Refresh();
			}
		}
		return true;
	}

	[CSharpExpose]
	public static Vector3 GetColliderCenter(uint64 session, uint64 entity, int32 index)
	{
		let collider = ColliderAt(session, entity, index);
		if (collider == null)
			return .Zero;
		return collider.center;
	}

	[CSharpExpose]
	public static Vector3 GetColliderBoxSize(uint64 session, uint64 entity, int32 index)
	{
		if (let boxCollider = ColliderAt(session, entity, index) as BoxCollider)
			return boxCollider.size;
		return .Zero;
	}

	[CSharpExpose]
	public static float GetColliderSphereRadius(uint64 session, uint64 entity, int32 index)
	{
		if (let sphere = ColliderAt(session, entity, index) as SphereCollider)
			return sphere.radius;
		return -1;
	}

	[CSharpExpose]
	public static float GetColliderCapsuleRadius(uint64 session, uint64 entity, int32 index)
	{
		if (let capsule = ColliderAt(session, entity, index) as CapsuleCollider)
			return capsule.radius;
		return -1;
	}

	[CSharpExpose]
	public static float GetColliderCapsuleHeight(uint64 session, uint64 entity, int32 index)
	{
		if (let capsule = ColliderAt(session, entity, index) as CapsuleCollider)
			return capsule.height;
		return -1;
	}

	// A settings change is an explicit operation, not a per-tick hot path.
	// Rebuild uses the existing SoftBody/Jolt lifecycle and preserves pose.
	[CSharpExpose]
	public static float GetSoftBodyStiffness(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null ? soft.stiffness : 0;
	}

	[CSharpExpose]
	public static bool SetSoftBodyStiffness(uint64 session, uint64 entity, float stiffness)
	{
		if (!stiffness.IsFinite || stiffness < 0 || stiffness > 1)
			return false;
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null)
			return false;
		if (soft.stiffness == stiffness)
			return true;
		soft.stiffness = stiffness;
		if (soft.HasBody)
			soft.Rebuild();
		return true;
	}

	[CSharpExpose]
	public static float GetSoftBodyWobbleDamping(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null ? soft.wobbleDamping : 0;
	}

	[CSharpExpose]
	public static bool SetSoftBodyWobbleDamping(uint64 session, uint64 entity, float damping)
	{
		if (!damping.IsFinite || damping < 0 || damping > 20)
			return false;
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null)
			return false;
		if (soft.wobbleDamping == damping)
			return true;
		soft.wobbleDamping = damping;
		if (soft.HasBody)
			soft.Rebuild();
		return true;
	}


	// Joint is already a Flecs ComponentHandle<JointData>. The opaque
	// session + entity pair is validated before touching its ECS data.
	[CSharpExpose]
	public static bool HasJoint(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj != null && obj.HasComponent<Joint>();
	}

	/// Builds the object's Joint again after its fields changed while playing.
	[CSharpExpose]
	public static bool RebuildJoint(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<Joint>())
			return false;
		obj.GetComponent<Joint>().Rebuild();
		return true;
	}

	/// Builds the object's physics body again from its colliders (after adding compound parts).
	[CSharpExpose]
	public static bool RebuildRigidbody(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<Rigidbody>())
			return false;
		obj.GetComponent<Rigidbody>().RebuildBody();
		return true;
	}

	/// Adds a part to the object's Compound Collider, in its own space: kind 0 a box (a = size), 1 a cylinder
	/// (a.x radius, a.y half height), 2 a convex hull round points (x, y, z after one another). rotation is a
	/// quaternion (x, y, z, w; boxes take none). False without a Compound Collider or with too few points.
	[CSharpExpose]
	public static bool AddCompoundPart(uint64 session, uint64 entity, int32 kind, Vector3 center, Vector3 a, Vector4 rotation, Span<float> points)
	{
		let obj = LiveObject(session, entity);
		let compound = obj?.GetComponent<CompoundCollider>();
		if (compound == null)
			return false;
		let turn = Quaternion(rotation.x, rotation.y, rotation.z, rotation.w);
		switch (kind)
		{
		case 0: compound.AddBox(center, a);
		case 1: compound.AddCylinder(center, a.x, a.y, turn);
		default:
			let count = points.Length / 3;
			if (count < 4)
				return false;
			let list = scope Vector3[count];
			for (int i < count)
				list[i] = .(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]);
			compound.AddHull(center, list, turn);
		}
		return true;
	}

	[CSharpExpose]
	public static bool IsJointConnected(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<Joint>())
			return false;
		return obj.GetComponent<Joint>().IsConnected;
	}

	[CSharpExpose]
	public static uint64 GetJointConnectedEntity(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<Joint>())
			return 0;
		let other = obj.GetComponent<Joint>().ConnectedTo;
		if (!other.IsValid)
			return 0;
		return (uint64)other.GameObject.Id;
	}

	[CSharpExpose]
	public static float GetJointSwingLimit(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<Joint>())
			return -1;
		return obj.GetComponent<Joint>().swingLimit;
	}

	[CSharpExpose]
	public static bool SetJointSwingLimit(uint64 session, uint64 entity, float degrees)
	{
		if (!degrees.IsFinite || degrees < 0 || degrees > 179)
			return false;
		let obj = LiveObject(session, entity);
		if (obj == null || !obj.HasComponent<Joint>())
			return false;
		let joint = obj.GetComponent<Joint>();
		if (joint.swingLimit == degrees)
			return true;
		joint.swingLimit = degrees;
		joint.Rebuild();
		return true;
	}

	/// A native Joint.Connect uses the same ECS-backed JointData and Jolt
	/// solver as Beef. Dynamic joints are currently LOCAL ONLY: the engine
	/// requires explicitly coordinated creation for multiplayer sessions.
	[CSharpExpose]
	public static bool ConnectJoint(uint64 session, uint64 a, uint64 b,
		Vector3 anchor, Vector3 axis, float swingLimit)
	{
		if (a == b || !swingLimit.IsFinite || swingLimit < 0 || swingLimit > 179 ||
			!anchor.x.IsFinite || !anchor.y.IsFinite || !anchor.z.IsFinite ||
			!axis.x.IsFinite || !axis.y.IsFinite || !axis.z.IsFinite ||
			(axis.x == 0 && axis.y == 0 && axis.z == 0))
			return false;
		let first = LiveObject(session, a);
		let second = LiveObject(session, b);
		if (first == null || second == null || first.HasComponent<Joint>())
			return false;
		let mine = first.GetComponent<Rigidbody>();
		let other = second.GetComponent<Rigidbody>();
		if (!mine.IsValid || !other.IsValid)
			return false;
		let joint = Joint.Connect(mine, other, anchor, axis, swingLimit);
		return joint.IsValid;
	}

	[CSharpExpose]
	public static bool HasSoftBody(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		return obj != null && obj.GetComponent<SoftBody>() != null;
	}

	[CSharpExpose]
	public static bool HasSoftBodySimulation(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null && soft.HasBody;
	}

	/// Shell and DrivenJelly are driven by a Rigidbody: do not misreport
	/// successful forces which the existing native SoftBody would ignore.
	[CSharpExpose]
	public static bool CanForceSoftBody(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null && soft.HasBody && soft.kind != .Shell && soft.kind != .DrivenJelly;
	}

	[CSharpExpose]
	public static Vector3 GetSoftBodyVelocity(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null || !soft.HasBody)
			return .Zero;
		return soft.Velocity;
	}

	[CSharpExpose]
	public static bool SetSoftBodyVelocity(uint64 session, uint64 entity, Vector3 velocity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null || !soft.HasBody || soft.kind == .Shell || soft.kind == .DrivenJelly)
			return false;
		soft.Velocity = velocity;
		return true;
	}

	[CSharpExpose]
	public static bool AddSoftBodyImpulse(uint64 session, uint64 entity, Vector3 impulse)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null || !soft.HasBody || soft.kind == .Shell || soft.kind == .DrivenJelly)
			return false;
		soft.AddImpulse(impulse);
		return true;
	}

	[CSharpExpose]
	public static bool AddSoftBodyForce(uint64 session, uint64 entity, Vector3 force)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null || !soft.HasBody || soft.kind == .Shell || soft.kind == .DrivenJelly)
			return false;
		soft.AddForce(force);
		return true;
	}

	[CSharpExpose]
	public static float GetSoftBodyPressure(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null ? soft.pressure : 0;
	}

	/// This is an explicit reconfiguration (not a per-tick fast path);
	/// native Rebuild preserves the object's pose during shape recreation.
	[CSharpExpose]
	public static bool SetSoftBodyPressure(uint64 session, uint64 entity, float pressure)
	{
		if (!pressure.IsFinite || pressure < 0 || pressure > 100000)
			return false;
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null)
			return false;
		if (soft.pressure == pressure)
			return true;
		soft.pressure = pressure;
		if (soft.HasBody)
			soft.Rebuild();
		return true;
	}

	[CSharpExpose]
	public static bool RepairSoftBody(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null || !soft.HasBody || soft.kind != .Shell)
			return false;
		// Retain Beef's existing server-authoritative shell dent replication.
		soft.Repair();
		return true;
	}

	[CSharpExpose]
	public static float DeepestSoftBodyDent(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		if (soft == null || !soft.HasBody)
			return 0;
		return soft.DeepestDent();
	}

	/// -1 means no hit or an inactive scene. Jolt owns the actual query and
	/// layer mask; a structured RaycastHit ABI follows in a later increment.

	/// Closest Jolt ray contact, packed as point.xyz and distance.w.
	/// No managed solver or additional physics query is involved.
	/// A negative distance means no hit; object/normal support is separate.
	/// Full contact data for a ray: point, distance, surface normal, body, object, compound part and triangle.
	[CSharpExpose]
	public static PhysicsQueryHit RaycastDetails(uint64 session, Vector3 origin,
		Vector3 direction, float maxDistance, uint32 layerMask)
	{
		PhysicsQueryHit output = default;
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !maxDistance.IsFinite ||
			maxDistance <= 0)
			return output;
		RaycastHit hit = default;
		if (!scene.Physics.Raycast(origin, direction, maxDistance, out hit, layerMask))
			return output;
		return RayHit(hit);
	}

	public static PhysicsQueryHit RayHit(RaycastHit hit)
	{
		PhysicsQueryHit output = default;
		output.flags = hit.normal.LengthSquared > 0.5f ? 3 : 1;
		output.pointX = hit.point.x;
		output.pointY = hit.point.y;
		output.pointZ = hit.point.z;
		output.normalX = hit.normal.x;
		output.normalY = hit.normal.y;
		output.normalZ = hit.normal.z;
		output.distance = hit.distance;
		output.bodyId = hit.bodyId;
		output.part = hit.part;
		output.triangle = hit.triangle;
		if (hit.gameObject != null && !hit.gameObject.IsDestroyed)
		{
			output.entityId = (uint64)hit.gameObject.Id;
			output.flags |= 4;
		}
		return output;
	}

	public static PhysicsQueryHit ShapeHit(ShapeCastHit hit)
	{
		PhysicsQueryHit output = default;
		output.flags = 3;
		output.part = hit.part;
		output.triangle = hit.triangle;
		output.pointX = hit.point.x;
		output.pointY = hit.point.y;
		output.pointZ = hit.point.z;
		output.normalX = hit.normal.x;
		output.normalY = hit.normal.y;
		output.normalZ = hit.normal.z;
		output.distance = hit.distance;
		output.penetrationDepth = hit.penetrationDepth;
		output.bodyId = hit.bodyId;
		if (hit.gameObject != null && !hit.gameObject.IsDestroyed)
		{
			output.entityId = (uint64)hit.gameObject.Id;
			output.flags |= 4;
		}
		return output;
	}

	/// A sphere sweep that leaves one body out (a character's own), with the whole hit.
	[CSharpExpose]
	public static PhysicsQueryHit SphereCastIgnoring(uint64 session, Vector3 origin, float radius, Vector3 direction,
		float maxDistance, uint32 layerMask, uint32 ignoreBody)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !radius.IsFinite || radius <= 0 || !maxDistance.IsFinite ||
			maxDistance <= 0 || !FiniteVector(origin) || !FiniteVector(direction))
			return default;
		ShapeCastHit hit = default;
		return scene.Physics.SphereCast(origin, radius, direction, maxDistance, out hit, ignoreBody, layerMask) ?
			ShapeHit(hit) : default;
	}

	static bool FiniteRotation(Quaternion q) => q.x.IsFinite && q.y.IsFinite && q.z.IsFinite && q.w.IsFinite;

	/// Whether anything is inside the sphere, capsule (asCapsule: point2 and radius) or box (asBox: size and
	/// orientation). Stops at the first body that counts.
	[CSharpExpose]
	public static bool CheckShape(uint64 session, int32 shape, Vector3 point1, Vector3 point2, float radius,
		Vector3 size, Quaternion orientation, uint32 layerMask, uint32 ignoreBody)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !FiniteVector(point1))
			return false;
		switch (shape)
		{
		case 0:
			return radius.IsFinite && radius > 0 && scene.Physics.CheckSphere(point1, radius, ignoreBody, layerMask);
		case 1:
			return radius.IsFinite && radius > 0 && FiniteVector(point2) &&
				scene.Physics.CheckCapsule(point1, point2, radius, ignoreBody, layerMask);
		case 2:
			return FiniteVector(size) && size.x > 0 && size.y > 0 && size.z > 0 && FiniteRotation(orientation) &&
				scene.Physics.CheckBox(point1, size, orientation, ignoreBody, layerMask);
		default:
			return false;
		}
	}

	/// The objects touching a sphere, capsule or box (as CheckShape), each once, into objectIds. Returns how many
	/// there are (more than fit, when the buffer is short).
	[CSharpExpose]
	public static int32 OverlapShape(uint64 session, int32 shape, Vector3 point1, Vector3 point2, float radius,
		Vector3 size, Quaternion orientation, uint32 layerMask, uint32 ignoreBody, Span<uint64> objectIds)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !FiniteVector(point1))
			return 0;
		let hits = scope List<ShapeCastHit>();
		switch (shape)
		{
		case 0:
			if (!radius.IsFinite || radius <= 0) return 0;
			scene.Physics.OverlapSphere(point1, radius, hits, ignoreBody, layerMask);
		case 1:
			if (!radius.IsFinite || radius <= 0 || !FiniteVector(point2)) return 0;
			scene.Physics.OverlapCapsule(point1, point2, radius, hits, ignoreBody, layerMask);
		case 2:
			if (!FiniteVector(size) || size.x <= 0 || size.y <= 0 || size.z <= 0 || !FiniteRotation(orientation)) return 0;
			scene.Physics.OverlapBox(point1, size, orientation, hits, ignoreBody, layerMask);
		default:
			return 0;
		}
		let seen = scope HashSet<uint32>();
		int32 count = 0;
		for (let hit in hits)
		{
			if (hit.gameObject == null || hit.gameObject.IsDestroyed || !seen.Add(hit.gameObject.Id))
				continue;
			if (count < objectIds.Length)
				objectIds[count] = hit.gameObject.Id;
			count++;
		}
		return count;
	}

	/// A capsule sweep: point1 and point2 are the centres of its two ends' half-spheres.
	[CSharpExpose]
	public static PhysicsQueryHit CapsuleCastDetails(uint64 session, Vector3 point1, Vector3 point2, float radius,
		Vector3 direction, float maxDistance, uint32 layerMask, uint32 ignoreBody)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !radius.IsFinite || radius <= 0 || !maxDistance.IsFinite ||
			maxDistance <= 0 || !FiniteVector(point1) || !FiniteVector(point2) || !FiniteVector(direction))
			return default;
		ShapeCastHit hit = default;
		return scene.Physics.CapsuleCast(point1, point2, radius, direction, maxDistance, out hit, ignoreBody, layerMask) ?
			ShapeHit(hit) : default;
	}

	/// A box sweep: size is its full width, height and depth, turned by orientation.
	[CSharpExpose]
	public static PhysicsQueryHit BoxCastDetails(uint64 session, Vector3 center, Vector3 size, Quaternion orientation,
		Vector3 direction, float maxDistance, uint32 layerMask, uint32 ignoreBody)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !maxDistance.IsFinite || maxDistance <= 0 ||
			!FiniteVector(center) || !FiniteVector(size) || size.x <= 0 || size.y <= 0 || size.z <= 0 ||
			!FiniteVector(direction) || !orientation.x.IsFinite || !orientation.y.IsFinite ||
			!orientation.z.IsFinite || !orientation.w.IsFinite)
			return default;
		ShapeCastHit hit = default;
		return scene.Physics.BoxCast(center, size, orientation, direction, maxDistance, out hit, ignoreBody, layerMask) ?
			ShapeHit(hit) : default;
	}

	/// One Jolt sweep provides the point, surface normal, penetration,
	/// collider GameObject and body id; no duplicate sweep is necessary.
	[CSharpExpose]
	public static PhysicsQueryHit SphereCastDetails(uint64 session, Vector3 origin,
		float radius, Vector3 direction, float maxDistance, uint32 layerMask)
	{
		PhysicsQueryHit output = default;
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !radius.IsFinite ||
			radius <= 0 || !maxDistance.IsFinite || maxDistance <= 0)
			return output;
		ShapeCastHit hit = default;
		if (!scene.Physics.SphereCast(origin, radius, direction, maxDistance,
			out hit, uint32.MaxValue, layerMask))
			return output;
		output.flags = 3;
		output.pointX = hit.point.x;
		output.pointY = hit.point.y;
		output.pointZ = hit.point.z;
		output.normalX = hit.normal.x;
		output.normalY = hit.normal.y;
		output.normalZ = hit.normal.z;
		output.distance = hit.distance;
		output.penetrationDepth = hit.penetrationDepth;
		output.bodyId = hit.bodyId;
		output.part = hit.part;
		output.triangle = hit.triangle;
		if (hit.gameObject != null && !hit.gameObject.IsDestroyed)
		{
			output.entityId = (uint64)hit.gameObject.Id;
			output.flags |= 4;
		}
		return output;
	}

	[CSharpExpose]
	public static Vector4 RaycastContact(uint64 session, Vector3 origin,
		Vector3 direction, float maxDistance, uint32 layerMask)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !maxDistance.IsFinite ||
			maxDistance <= 0)
			return .(0, 0, 0, -1);
		RaycastHit hit = default;
		if (!scene.Physics.Raycast(origin, direction, maxDistance, out hit, layerMask))
			return .(0, 0, 0, -1);
		return Vector4(hit.point, hit.distance);
	}

	/// Sphere sweep uses Jolt's native swept-volume contacts, including
	/// distance zero when starting in overlap. The normal is not in this ABI.
	[CSharpExpose]
	public static Vector4 SphereCastContact(uint64 session, Vector3 origin,
		float radius, Vector3 direction, float maxDistance, uint32 layerMask)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !radius.IsFinite ||
			radius <= 0 || !maxDistance.IsFinite || maxDistance <= 0)
			return .(0, 0, 0, -1);
		ShapeCastHit hit = default;
		if (!scene.Physics.SphereCast(origin, radius, direction, maxDistance,
			out hit, uint32.MaxValue, layerMask))
			return .(0, 0, 0, -1);
		return Vector4(hit.point, hit.distance);
	}

	[CSharpExpose]
	public static bool IsRigidbodySleeping(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		if (obj == null)
			return false;
		let body = obj.GetComponent<Rigidbody>();
		return body.HasBody && body.IsSleeping;
	}

	[CSharpExpose]
	public static bool IsSoftBodySleeping(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null && soft.HasBody && soft.IsSleeping;
	}

	/// Valid SoftBodyKind values: Cloth=0, Jelly=1, Shell=2, DrivenJelly=3.
	/// -1 means the session/entity or component is no longer valid.
	[CSharpExpose]
	public static int32 GetSoftBodyMode(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null ? (int32)soft.kind : -1;
	}

	[CSharpExpose]
	public static int32 GetSoftBodyVertexCount(uint64 session, uint64 entity)
	{
		let obj = LiveObject(session, entity);
		let soft = obj?.GetComponent<SoftBody>();
		return soft != null ? (int32)soft.SimulatedVertexCount : 0;
	}

	[CSharpExpose]
	public static float RaycastDistance(uint64 session, Vector3 origin,
		Vector3 direction, float maxDistance, uint32 layerMask)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !maxDistance.IsFinite ||
			maxDistance <= 0)
			return -1;
		RaycastHit hit = default;
		return scene.Physics.Raycast(origin, direction, maxDistance, out hit, layerMask) ?
			hit.distance : -1;
	}
}
