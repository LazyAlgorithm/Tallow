using System;
using System.Collections;

namespace Tallow;

/// Turns this object's Skinned Mesh Renderer into a backend ragdoll. Jolt builds a JPH_Ragdoll from the skeleton;
/// another backend can build the same parts from articulations or ordinary joints. The parts are made from the
/// deform bones: a capsule along each bone, parented to the nearest included ancestor, with a swing/twist limit.
///
/// Add it when the corpse or character should fall. A live character can keep it switched off and call Begin on death.
[Component]
class Ragdoll : Component
{
	/// The whole ragdoll's mass in kilograms, shared by its parts.
	public float totalMass = 80;
	/// Radius of the capsule round each bone, in metres.
	public float radius = 0.08f;
	/// Bones shorter than this (fingers, toes, twist helpers) get no part.
	public float minimumBoneLength = 0.05f;
	/// How far a part may swing from its parent, in degrees.
	[Range(0, 179)]
	public float swingLimitDegrees = 45;
	/// How far a part may twist about its bone, in degrees.
	[Range(0, 179)]
	public float twistLimitDegrees = 20;
	/// Corpses are decoration: they rest on scenery but nothing moving is stopped by them.
	public bool debris = true;
	/// Stop a parent and child part from colliding with each other.
	public bool disableParentChildCollisions = true;
	/// Make the ragdoll when the scene starts. Off for a character that becomes a ragdoll later (call Begin).
	public bool simulateOnStart = true;

	PhysicsRagdollExtension mRagdolls;
	void* mHandle;
	bool mStarted;
	PhysicsRagdollMatrix[] mPose = new .() ~ delete _;
	List<Transform> mBones = new .() ~ delete _;

	/// Whether the ragdoll is in the physics world.
	public bool IsSimulating => mHandle != null;

	public override void Start()
	{
		mStarted = true;
		if (simulateOnStart && Scene != null && Scene.IsPlaying)
			Begin();
	}

	public override void OnEnable()
	{
		if (mStarted && simulateOnStart && Scene != null && Scene.IsPlaying)
			Begin();
	}

	public override void OnDisable() => Release();
	public override void OnDestroy() => Release();

	/// Builds the ragdoll and adds it to the simulation. False (with a warning) when the selected backend has no
	/// ragdolls or the object has no skinned skeleton.
	public bool Begin()
	{
		if (mHandle != null)
			return true;
		let skin = GetComponent<SkinnedMeshRenderer>();
		if (!skin || skin.Model == null)
		{
			Log.Warning(scope $"Ragdoll on '{GameObject.Name}' needs a Skinned Mesh Renderer with a skeleton.");
			return false;
		}
		let world = Scene.Physics;
		if (!world.Supports(.Ragdolls) || world.Ragdolls == null)
		{
			Log.Warning(scope $"Ragdoll on '{GameObject.Name}' needs ragdolls; the selected physics backend does not provide them.");
			return false;
		}
		mRagdolls = world.Ragdolls;
		let model = skin.Model;
		List<PhysicsRagdollPart> parts = scope .();
		List<int32> partOfJoint = scope .();
		partOfJoint.Resize(model.Joints.Count);
		for (int i = 0; i < partOfJoint.Count; i++)
			partOfJoint[i] = -1;
		mBones.Clear();
		for (int i = 0; i < model.Joints.Count; i++)
		{
			let bone = skin.Bone(model.Joints[i].name);
			if (bone == null)
				continue;
			// The bone's length is the distance to its first child; leaves (fingertips) get no part.
			int32 child = -1;
			for (int j = 0; j < model.Joints.Count; j++)
			{
				if (model.Joints[j].parent == i)
				{
					child = (int32)j;
					break;
				}
			}
			if (child < 0)
				continue;
			let childBone = skin.Bone(model.Joints[child].name);
			if (childBone == null)
				continue;
			let direction = childBone.Position - bone.Position;
			let length = direction.Length;
			if (length < minimumBoneLength)
				continue;
			// The nearest included ancestor: skipped bones do not break the chain.
			int32 parentJoint = model.Joints[i].parent;
			int32 parentPart = -1;
			while (parentJoint >= 0)
			{
				if (partOfJoint[parentJoint] >= 0)
				{
					parentPart = partOfJoint[parentJoint];
					break;
				}
				parentJoint = model.Joints[parentJoint].parent;
			}
			PhysicsRagdollPart part = default;
			let boneRadius = Math.Min(Math.Max(radius, 0.01f), length * 0.5f);
			part.shape.kind = .Capsule;
			part.shape.radius = boneRadius;
			part.shape.halfHeight = Math.Max(length * 0.5f - boneRadius, 0.01f);
			part.position = (bone.Position + childBone.Position) * 0.5f;
			part.rotation = IKSolver.FromTo(Vector3.Up, direction.Normalized);
			part.parent = parentPart;
			part.axis = direction.Normalized;
			part.swingLimitRadians = swingLimitDegrees * Mathf.Deg2Rad;
			part.twistLimitRadians = twistLimitDegrees * Mathf.Deg2Rad;
			part.objectCode = PhysicsLayerTable.ObjectCode(debris ? PhysicsLayerTable.DebrisClass : PhysicsLayerTable.MovingClass, GameObject.Layer);
			partOfJoint[i] = (int32)parts.Count;
			parts.Add(part);
			mBones.Add(bone);
		}
		if (parts.Count == 0)
		{
			Log.Warning(scope $"Ragdoll on '{GameObject.Name}': the skeleton has no bones long enough for a part.");
			return false;
		}
		let perPart = Math.Max(totalMass, 0.1f) / parts.Count;
		for (int i = 0; i < parts.Count; i++)
			parts[i].mass = perPart;

		PhysicsRagdollDesc desc = default;
		desc.parts = parts.Ptr;
		desc.count = (int32)parts.Count;
		desc.userData = (uint64)GameObject.Id;
		desc.disableParentChildCollisions = disableParentChildCollisions;
		mHandle = mRagdolls.Create(desc);
		if (mHandle == null)
		{
			Log.Warning(scope $"Ragdoll on '{GameObject.Name}' could not be built.");
			return false;
		}
		delete mPose;
		mPose = new PhysicsRagdollMatrix[parts.Count];
		mRagdolls.AddToWorld(mHandle, true);
		return true;
	}

	/// Takes the ragdoll out of the simulation and frees it. Safe to call when it is not there.
	public void Release()
	{
		if (mHandle == null)
			return;
		if (mRagdolls != null)
			mRagdolls.Destroy(mHandle);
		mHandle = null;
		mRagdolls = null;
		mBones.Clear();
	}

	public override void LateUpdate(TickInput input, float deltaTime)
	{
		if (mHandle == null || mRagdolls == null || mBones.Count == 0 || mPose.Count < mBones.Count)
			return;
		Vector3 root;
		mRagdolls.GetPose(mHandle, out root, mPose.Ptr, true);
		Matrix4 rootMatrix = Matrix4.Identity;
		rootMatrix.m[12] = root.x;
		rootMatrix.m[13] = root.y;
		rootMatrix.m[14] = root.z;
		for (int i = 0; i < mBones.Count; i++)
		{
			let world = rootMatrix * mPose[i].ToMatrix();
			world.Decompose(let position, let rotation, let scale);
			mBones[i].SetPositionAndRotation(position, rotation);
		}
	}
}
