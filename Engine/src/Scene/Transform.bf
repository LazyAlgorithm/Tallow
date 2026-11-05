using System;
using System.Collections;

namespace Tallow;

/// A Transform's data, kept in its GameObject's entity (docs/ecs-plan.md, Phase 2). Engine systems can read and
/// write it in bulk through queries; Transform is the per-object way in.
[Component]
struct TransformData
{
	public Vector3 localPosition;
	public Quaternion localRotation;
	public Vector3 localScale;
	/// The cached local-to-world matrix and world rotation, valid while dirty and rotationDirty are false.
	public Matrix4 world;
	public Quaternion worldRotation;
	public bool dirty;
	public bool rotationDirty;

	public static Self Default => .() { localPosition = .Zero, localRotation = .Identity, localScale = .One, world = .Identity, worldRotation = .Identity, dirty = true, rotationDirty = true };
}

/// Position, rotation and scale of a GameObject, arranged in a parent/child hierarchy.
class Transform
{
	GameObject mGameObject;
	Transform mParent;
	/// Where the data lives until the object joins a scene (and after it leaves one).
	TransformData mOwn = .Default;
	/// The scene's world and the reference into it, once bound (Bind).
	World mWorld;
	ComponentRef<TransformData> mRef;

	/// The objects directly under this one, in Hierarchy order. Use SetParent to move one.
	public List<Transform> Children = new .() ~ delete _;
	/// Incremented whenever the world transform may have changed.
	public uint32 Version;

	/// The transform of an object; every GameObject makes its own.
	public this(GameObject gameObject)
	{
		mGameObject = gameObject;
	}

	/// The data: in the entity once bound, otherwise mOwn.
	[Inline]
	ref TransformData D()
	{
		if (mWorld == null)
			return ref mOwn;
		return ref *mRef.Get(mWorld);
	}

	/// Moves the data into the object's entity (Scene does this when the object joins it).
	void Bind(World world, Entity entity)
	{
		world.Set<TransformData>(entity, mOwn);
		mRef = .(world, entity);
		mWorld = world;
	}

	/// Takes the data back out of the entity before the entity is deleted.
	void Unbind()
	{
		if (mWorld == null)
			return;
		mOwn = D();
		mWorld = null;
	}

	/// The object this transform belongs to.
	public GameObject GameObject { [Inline] get => mGameObject; }
	/// The transform this one is under, or null at the top of the scene.
	public Transform Parent { [Inline] get => mParent; }

	/// The position relative to the parent (in the world, for an object with no parent).
	public Vector3 LocalPosition
	{
		get => D().localPosition;
		set
		{
			ref TransformData data = ref D();
			data.localPosition = value;
			MarkDirty(ref data);
		}
	}

	/// The rotation relative to the parent.
	public Quaternion LocalRotation
	{
		get => D().localRotation;
		set
		{
			ref TransformData data = ref D();
			data.localRotation = value;
			MarkDirty(ref data);
		}
	}

	/// The size relative to the parent: 1 on each axis is unchanged.
	public Vector3 LocalScale
	{
		get => D().localScale;
		set
		{
			ref TransformData data = ref D();
			data.localScale = value;
			MarkDirty(ref data);
		}
	}

	/// LocalRotation as angles in degrees about X, Y and Z.
	public Vector3 LocalEulerAngles
	{
		get => D().localRotation.EulerAngles;
		set
		{
			ref TransformData data = ref D();
			data.localRotation = Quaternion.Euler(value);
			MarkDirty(ref data);
		}
	}

	/// The local position, rotation and scale as one matrix.
	public Matrix4 LocalMatrix
	{
		get
		{
			ref TransformData data = ref D();
			return Matrix4.TRS(data.localPosition, data.localRotation, data.localScale);
		}
	}

	/// The matrix from this object's own space to the world, through every parent.
	public Matrix4 LocalToWorld
	{
		get
		{
			ref TransformData data = ref D();
			if (data.dirty)
			{
				let local = Matrix4.TRS(data.localPosition, data.localRotation, data.localScale);
				data.world = mParent != null ? mParent.LocalToWorld * local : local;
				data.dirty = false;
			}
			return data.world;
		}
	}

	/// The matrix from the world to this object's own space.
	public Matrix4 WorldToLocal => LocalToWorld.Inverse;

	/// The position in the world. Setting it moves the object so that it ends up there, whatever its parents.
	public Vector3 Position
	{
		get => LocalToWorld.Translation;
		set
		{
			if (mParent != null)
				D().localPosition = mParent.WorldToLocal.TransformPoint(value);
			else
				D().localPosition = value;
			MarkDirty();
		}
	}

	/// The rotation in the world.
	public Quaternion Rotation
	{
		get
		{
			ref TransformData data = ref D();
			if (data.rotationDirty)
			{
				data.worldRotation = mParent != null ? (mParent.Rotation * data.localRotation).Normalized : data.localRotation;
				data.rotationDirty = false;
			}
			return data.worldRotation;
		}
		set
		{
			if (mParent != null)
				D().localRotation = (mParent.Rotation.Conjugate * value).Normalized;
			else
				D().localRotation = value;
			MarkDirty();
		}
	}

	/// Rotation as angles in degrees about X, Y and Z.
	public Vector3 EulerAngles
	{
		get => Rotation.EulerAngles;
		set
		{
			Rotation = Quaternion.Euler(value);
		}
	}

	/// The direction the object faces (its +Z), in the world.
	public Vector3 Forward => Rotation * Vector3.Forward;
	/// The object's right (its +X), in the world.
	public Vector3 Right => Rotation * Vector3.Right;
	/// The object's up (its +Y), in the world.
	public Vector3 Up => Rotation * Vector3.Up;

	/// Sets the world position and rotation together.
	public void SetPositionAndRotation(Vector3 position, Quaternion rotation)
	{
		Position = position;
		Rotation = rotation;
	}

	/// Moves the object by an offset in world space.
	public void Translate(Vector3 delta)
	{
		Position = Position + delta;
	}

	/// Rotates by euler angles in degrees, in local space.
	public void Rotate(Vector3 eulerDegrees)
	{
		ref TransformData data = ref D();
		data.localRotation = (data.localRotation * Quaternion.Euler(eulerDegrees)).Normalized;
		MarkDirty(ref data);
	}

	/// Turns the object to face a point in the world, keeping its up as near world up as it can.
	public void LookAt(Vector3 target)
	{
		let direction = target - Position;
		if (direction.LengthSquared > 1.0e-10f)
			Rotation = Quaternion.LookRotation(direction, Vector3.Up);
	}

	/// A point from this object's own space to the world.
	public Vector3 TransformPoint(Vector3 local) => LocalToWorld.TransformPoint(local);
	/// A point from the world to this object's own space.
	public Vector3 InverseTransformPoint(Vector3 world) => WorldToLocal.TransformPoint(world);

	/// Whether this transform is the other or anywhere under it.
	public bool IsChildOf(Transform other)
	{
		var t = this;
		while (t != null)
		{
			if (t == other)
				return true;
			t = t.mParent;
		}
		return false;
	}

	/// Re-parents this transform. Pass null to move it to the scene root.
	public void SetParent(Transform parent, bool keepWorldPose = true)
	{
		if (parent == mParent || (parent != null && parent.IsChildOf(this)))
			return;
		let world = LocalToWorld;
		let wasInWorld = mGameObject.InActiveWorld;
		let wasStates = mGameObject.EffectiveWorldStates;
		if (mParent != null)
			mParent.Children.Remove(this);
		else
		{
			// Usually the newest root: a new object starts as one.
			let roots = mGameObject.Scene?.[Friend]mRoots;
			let index = roots?.LastIndexOf(mGameObject) ?? -1;
			if (index >= 0)
				roots.RemoveAt(index);
		}
		mParent = parent;
		if (mParent != null)
			mParent.Children.Add(this);
		else
			mGameObject.Scene?.[Friend]mRoots.Add(mGameObject);
		let scene = mGameObject.Scene;
		if (scene != null && !mGameObject.Entity.IsNull)
			scene.World.SetParent(mGameObject.Entity, mParent != null ? mParent.GameObject.Entity : .Null);
		if (keepWorldPose)
		{
			let local = mParent != null ? mParent.WorldToLocal * world : world;
			ref TransformData data = ref D();
			local.Decompose(out data.localPosition, out data.localRotation, out data.localScale);
		}
		MarkDirty();
		// A new parent can take the object into or out of the active world state (or, with world states set apart,
		// change the states it collides in).
		if (mGameObject.InActiveWorld != wasInWorld || (mGameObject.Scene != null && mGameObject.Scene.Physics.SeparatesWorldStates && mGameObject.EffectiveWorldStates != wasStates))
			mGameObject.Scene?.Physics.ApplyWorldState(mGameObject);
	}

	/// Sets the local pose without telling the children yet. For code that poses many transforms of one hierarchy at
	/// once (the Animator): it then calls PoseChanged on the topmost transform it posed in each branch, so every child
	/// below is told once instead of once for each posed transform above it. Nothing may read a world pose in between.
	public void SetLocalPoseDeferred(Vector3 position, Quaternion rotation, Vector3 scale)
	{
		ref TransformData data = ref D();
		data.localPosition = position;
		data.localRotation = rotation;
		data.localScale = scale;
	}

	/// Tells this transform and everything below it that the pose changed (after SetLocalPoseDeferred).
	public void PoseChanged()
	{
		MarkDirty();
	}

	void MarkDirty() => MarkDirty(ref D());

	void MarkDirty(ref TransformData data)
	{
		Version++;
		// A child's world pose is only ever worked out from its parent's, which leaves the parent clean: so with this
		// one dirty, everything below it is too, and need not be told again. Whatever keeps a child's Version also reads
		// the child's world pose, so that the next move here comes through to it.
		if (data.dirty && data.rotationDirty)
			return;
		data.dirty = true;
		data.rotationDirty = true;
		for (int i < Children.Count)
			Children[i].MarkDirty();
	}
}
