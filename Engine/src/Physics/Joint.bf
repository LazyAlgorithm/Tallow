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
[Component]
class Joint : Component
{
	/// The other body. It needs a Rigidbody too; make that one kinematic to hang things from a fixed point.
	public Rigidbody connectedTo;
	/// Where the two are joined, relative to this object.
	public Vector3 anchor = .Zero;
	/// The direction the swing limit is measured from, relative to this object.
	public Vector3 axis = .(0, -1, 0);
	/// How far, in degrees, the bodies may swing from the axis. 0 for no limit.
	[Range(0, 179)] public float swingLimit = 0;

	void* mJoint;
	bool mReady;

	/// True once the joint exists in the physics world.
	public bool IsConnected => mJoint != null && Scene.Physics.HasJoint(mJoint);

	/// Joins two bodies from code at a point in world space, adding a Joint component to the first.
	public static Joint Connect(Rigidbody a, Rigidbody b, Vector3 worldAnchor, Vector3 worldAxis, float swingLimit = 0)
	{
		if (!a.IsValid || !b.IsValid || a == b)
			return null;
		let joint = a.GameObject.AddComponent<Joint>();
		joint.connectedTo = b;
		joint.anchor = a.Transform.InverseTransformPoint(worldAnchor);
		joint.axis = a.Transform.Rotation.Conjugate * worldAxis;
		joint.swingLimit = swingLimit;
		joint.Rebuild();
		return joint;
	}

	public override void Start()
	{
		mReady = true;
		Rebuild();
	}

	public override void OnEnable()
	{
		if (mReady)
			Rebuild();
	}

	public override void OnDisable()
	{
		Release();
	}

	void Release()
	{
		if (mJoint != null)
			Scene.Physics.DestroyJoint(mJoint);
		mJoint = null;
	}

	/// Makes the joint again from the current fields.
	public void Rebuild()
	{
		Release();
		let mine = GetComponent<Rigidbody>();
		if (!mine.IsValid || !connectedTo.IsValid || !Scene.IsPlaying)
			return;
		// Both bodies must exist first, whichever order the components started in.
		mine.EnsureBody();
		connectedTo.EnsureBody();
		if (!mine.HasBody || !connectedTo.HasBody)
			return;
		mJoint = Scene.Physics.CreateJoint(mine.BodyId, connectedTo.BodyId, Transform.TransformPoint(anchor), Transform.Rotation * axis, swingLimit);
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected)
			return;
		let point = Transform.TransformPoint(anchor);
		Gizmos.Lines.Sphere(point, 0.08f, .(1, 0.7f, 0.2f, 1));
		Gizmos.Lines.Line(point, point + Transform.Rotation * axis.Normalized * 0.4f, .(1, 0.7f, 0.2f, 1));
		if (connectedTo.IsValid)
			Gizmos.Lines.Line(point, connectedTo.Transform.Position, .(1, 0.7f, 0.2f, 0.5f));
	}
}
