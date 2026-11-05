using System;
using System.Collections;

namespace Tallow;

/// Holds two rigid bodies together at a point, so that they can turn about it but not come apart: a link in a
/// chain, a door on a post, a limb on a body. Put it on one object and name the other in Connected To.
///
/// With Swing Limit at zero the joint is a free ball joint. Above zero the other body can only swing that many
/// degrees away from Axis, as a shoulder or a hip does.
///
/// A joint is local to the machine it is on. In multiplayer the bodies it joins are shared like any others, so
/// put the same joints in the scene on every machine (joints saved in a scene or prefab already are).
///
/// A handle (ComponentHandle): its settings are JointData's fields, the physics joint its JointState.
/// Joint.FrameAll (the Frame.Joints step) does what Start, OnEnable and OnDisable did; OnRemove lets the joint go.
[Component, HandleFields]
struct Joint : ComponentHandle<JointData>
{
	/// What it keeps between frames, made the first time it is asked for.
	public JointState Runtime
	{
		get
		{
			CheckValid();
			let state = ComponentState<JointState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			if (state.[Friend]mGameObject == null)
				state.[Friend]mGameObject = mGameObject;
			return state;
		}
	}

	/// The other body (Connected To), or an invalid handle when it is not set, has gone, or has no Rigidbody.
	public Rigidbody ConnectedTo
	{
		get
		{
			let other = connectedTo.Object(mGameObject.Scene);
			return other != null ? other.GetComponent<Rigidbody>() : Rigidbody();
		}
		set => connectedTo = value;
	}

	/// True once the joint exists in the physics world.
	public bool IsConnected => Runtime.IsConnected;
	/// Makes the joint again from the current fields.
	public void Rebuild() => Runtime.Rebuild();

	/// Joins two bodies from code at a point in world space, adding a Joint component to the first. An invalid
	/// handle if they cannot be joined.
	public static Joint Connect(Rigidbody a, Rigidbody b, Vector3 worldAnchor, Vector3 worldAxis, float swingLimit = 0)
	{
		if (!a.IsValid || !b.IsValid || a == b)
			return default;
		let joint = a.GameObject.AddComponent<Joint>();
		joint.connectedTo = b;
		joint.anchor = a.Transform.InverseTransformPoint(worldAnchor);
		joint.axis = a.Transform.Rotation.Conjugate * worldAxis;
		joint.swingLimit = swingLimit;
		joint.Rebuild();
		return joint;
	}

	/// While playing: a joint starting makes itself (Start), one switched on again is made again (OnEnable), one
	/// switched off lets go (OnDisable).
	public static void FrameAll(Scene scene)
	{
		if (!scene.IsPlaying)
			return;
		for (let joint in scene.FindComponents<Joint>(.. scope .()))
		{
			let state = joint.Runtime;
			if (!joint.IsActiveAndEnabled)
			{
				if (state.mWasActive)
				{
					state.mWasActive = false;
					state.Release();
				}
				continue;
			}
			if (!state.mStarted || !state.mWasActive)
			{
				state.mStarted = true;
				state.mWasActive = true;
				state.Rebuild();
			}
		}
	}

	/// When play stops the physics world goes with its joints; they are made again next time.
	public static void StopAll(Scene scene)
	{
		for (let (entity, state) in ComponentState<JointState>.In(scene.World, .. scope .()))
		{
			state.mJoint = null;
			state.mStarted = false;
			state.mWasActive = false;
		}
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		if (!selected)
			return;
		let joint = gameObject.GetComponent<Joint>();
		let transform = gameObject.Transform;
		let point = transform.TransformPoint(joint.anchor);
		Gizmos.Lines.Sphere(point, 0.08f, .(1, 0.7f, 0.2f, 1));
		Gizmos.Lines.Line(point, point + transform.Rotation * joint.axis.Normalized * 0.4f, .(1, 0.7f, 0.2f, 1));
		let other = joint.ConnectedTo;
		if (other.IsValid)
			Gizmos.Lines.Line(point, other.Transform.Position, .(1, 0.7f, 0.2f, 0.5f));
	}

	static void OnRemove(void* world, uint64 entity)
	{
		// As OnDisable did when the component went: the physics joint goes (unless the whole scene is going).
		if (let state = ComponentState<JointState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
		{
			let scene = state.[Friend]mGameObject?.Scene;
			if (scene != null && !scene.[Friend]mClearing)
				state.Release();
		}
		ComponentState<JointState>.Release(world, entity);
	}
}

/// A Joint's settings, in its entity.
[Component, HandleData]
struct JointData
{
	/// The other body. It needs a Rigidbody too; make that one kinematic to hang things from a fixed point.
	public ObjectRef<Rigidbody> connectedTo = .();
	/// Where the two are joined, relative to this object.
	public Vector3 anchor = .Zero;
	/// The direction the swing limit is measured from, relative to this object.
	public Vector3 axis = .(0, -1, 0);
	/// How far, in degrees, the bodies may swing from the axis. 0 for no limit.
	[Range(0, 179)] public float swingLimit = 0;

	public this() { }
}

/// The physics joint a Joint has made, if any.
class JointState
{
	GameObject mGameObject;
	public void* mJoint;
	public bool mStarted;
	public bool mWasActive;

	/// True once the joint exists in the physics world.
	public bool IsConnected => mJoint != null && mGameObject.Scene.Physics != null && mGameObject.Scene.Physics.HasJoint(mJoint);

	public void Release()
	{
		if (mJoint != null && mGameObject.Scene.Physics != null)
			mGameObject.Scene.Physics.DestroyJoint(mJoint);
		mJoint = null;
	}

	/// Makes the joint again from the current fields.
	public void Rebuild()
	{
		Release();
		let scene = mGameObject.Scene;
		let joint = mGameObject.GetComponent<Joint>();
		let mine = mGameObject.GetComponent<Rigidbody>();
		let other = joint.ConnectedTo;
		if (!mine.IsValid || !other.IsValid || !scene.IsPlaying)
			return;
		// Both bodies must exist first, whichever order the components started in.
		mine.EnsureBody();
		other.EnsureBody();
		if (!mine.HasBody || !other.HasBody)
			return;
		let transform = mGameObject.Transform;
		mJoint = scene.Physics.CreateJoint(mine.BodyId, other.BodyId, transform.TransformPoint(joint.anchor), transform.Rotation * joint.axis, joint.swingLimit);
	}
}
