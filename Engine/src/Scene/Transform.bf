using System;
using System.Collections;

namespace Tallow;

/// Position, rotation and scale of a GameObject, arranged in a parent/child hierarchy.
class Transform
{
	GameObject mGameObject;
	Transform mParent;
	Vector3 mLocalPosition = .Zero;
	Quaternion mLocalRotation = .Identity;
	Vector3 mLocalScale = .One;
	Matrix4 mWorld = .Identity;
	Quaternion mWorldRotation = .Identity;
	bool mDirty = true;
	bool mRotationDirty = true;

	/// The objects directly under this one, in Hierarchy order. Use SetParent to move one.
	public List<Transform> Children = new .() ~ delete _;
	/// Incremented whenever the world transform may have changed.
	public uint32 Version;

	/// The transform of an object; every GameObject makes its own.
	public this(GameObject gameObject)
	{
		mGameObject = gameObject;
	}

	/// The object this transform belongs to.
	public GameObject GameObject { [Inline] get => mGameObject; }
	/// The transform this one is under, or null at the top of the scene.
	public Transform Parent { [Inline] get => mParent; }

	/// The position relative to the parent (in the world, for an object with no parent).
	public Vector3 LocalPosition
	{
		get => mLocalPosition;
		set
		{
			mLocalPosition = value;
			MarkDirty();
		}
	}

	/// The rotation relative to the parent.
	public Quaternion LocalRotation
	{
		get => mLocalRotation;
		set
		{
			mLocalRotation = value;
			MarkDirty();
		}
	}

	/// The size relative to the parent: 1 on each axis is unchanged.
	public Vector3 LocalScale
	{
		get => mLocalScale;
		set
		{
			mLocalScale = value;
			MarkDirty();
		}
	}

	/// LocalRotation as angles in degrees about X, Y and Z.
	public Vector3 LocalEulerAngles
	{
		get => mLocalRotation.EulerAngles;
		set
		{
			mLocalRotation = Quaternion.Euler(value);
			MarkDirty();
		}
	}

	/// The local position, rotation and scale as one matrix.
	public Matrix4 LocalMatrix => Matrix4.TRS(mLocalPosition, mLocalRotation, mLocalScale);

	/// The matrix from this object's own space to the world, through every parent.
	public Matrix4 LocalToWorld
	{
		get
		{
			if (mDirty)
			{
				mWorld = mParent != null ? mParent.LocalToWorld * LocalMatrix : LocalMatrix;
				mDirty = false;
			}
			return mWorld;
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
				mLocalPosition = mParent.WorldToLocal.TransformPoint(value);
			else
				mLocalPosition = value;
			MarkDirty();
		}
	}

	/// The rotation in the world.
	public Quaternion Rotation
	{
		get
		{
			if (mRotationDirty)
			{
				mWorldRotation = mParent != null ? (mParent.Rotation * mLocalRotation).Normalized : mLocalRotation;
				mRotationDirty = false;
			}
			return mWorldRotation;
		}
		set
		{
			if (mParent != null)
				mLocalRotation = (mParent.Rotation.Conjugate * value).Normalized;
			else
				mLocalRotation = value;
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
		mLocalRotation = (mLocalRotation * Quaternion.Euler(eulerDegrees)).Normalized;
		MarkDirty();
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
		if (keepWorldPose)
		{
			let local = mParent != null ? mParent.WorldToLocal * world : world;
			local.Decompose(out mLocalPosition, out mLocalRotation, out mLocalScale);
		}
		MarkDirty();
		// A new parent can take the object into or out of the active world state.
		if (mGameObject.InActiveWorld != wasInWorld)
			mGameObject.Scene?.Physics.ApplyWorldState(mGameObject);
	}

	/// Sets the local pose without telling the children yet. For code that poses many transforms of one hierarchy at
	/// once (the Animator): it then calls PoseChanged on the topmost transform it posed in each branch, so every child
	/// below is told once instead of once for each posed transform above it. Nothing may read a world pose in between.
	public void SetLocalPoseDeferred(Vector3 position, Quaternion rotation, Vector3 scale)
	{
		mLocalPosition = position;
		mLocalRotation = rotation;
		mLocalScale = scale;
	}

	/// Tells this transform and everything below it that the pose changed (after SetLocalPoseDeferred).
	public void PoseChanged()
	{
		MarkDirty();
	}

	void MarkDirty()
	{
		Version++;
		// A child's world pose is only ever worked out from its parent's, which leaves the parent clean: so with this
		// one dirty, everything below it is too, and need not be told again. Whatever keeps a child's Version also reads
		// the child's world pose, so that the next move here comes through to it.
		if (mDirty && mRotationDirty)
			return;
		mDirty = true;
		mRotationDirty = true;
		for (int i < Children.Count)
			Children[i].MarkDirty();
	}
}
