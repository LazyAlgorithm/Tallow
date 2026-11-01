using System;
using System.Collections;

namespace Tallow;

/// Turns a head towards a target, with the neck and spine sharing the turn when Bones is more than 1: a character
/// who watches the player, or whose upper body follows where the camera aims.
///
/// Bone is the head (or the last bone that should face the target); Bones counts it and that many parents above it.
/// The turn is kept within Max Angle of where the clip has the head facing, so nobody's head goes round backwards.
/// Worked out on each machine; give the target a Network Identity, or call LookAt with the same point everywhere, for
/// other players to see the same.
[Component]
class LookAtIK : IKComponent
{
	/// The head: the bone that faces the target.
	public Transform bone;
	/// What to look at. Empty: the point given to LookAt from code.
	public Transform target;
	/// How many bones share the turn, counting the head and going up through its parents (neck, chest, spine).
	[Range(1, 6)] public int32 bones = 1;
	[Range(0, 1)] public float weight = 1;
	/// The furthest the head turns from where its animation has it, in degrees.
	[Range(0, 180)] public float maxAngle = 70;
	/// The direction of the bone, in its own space, that should point at the target (the way the face looks).
	public Vector3 forward = .(0, 0, 1);
	/// How quickly the gaze follows a moving target; 0 follows at once.
	public float smooth = 0;

	Vector3 mPoint;
	bool mHasPoint;
	Vector3 mGaze;
	bool mHasGaze;
	List<Transform> mChain = new .() ~ delete _;

	public override float Weight { get => weight; set => weight = value; }
	public override int32 Order => 10;

	/// Looks at a point in the world when there is no Target object.
	public void LookAt(Vector3 point)
	{
		mPoint = point;
		mHasPoint = true;
	}

	/// Stops looking at the point given to LookAt.
	public void ClearPoint() => mHasPoint = false;

	protected override void CollectBones(List<Transform> list)
	{
		mChain.Clear();
		var current = bone;
		for (int i = 0; i < bones && current != null && current != Transform; i++)
		{
			mChain.Insert(0, current);
			current = current.Parent;
		}
		list.AddRange(mChain);
	}

	protected override void Solve()
	{
		if (mChain.Count == 0)
			return;
		Vector3 point;
		if (target != null && !target.GameObject.IsDestroyed)
			point = target.Position;
		else if (mHasPoint)
			point = mPoint;
		else
			return;
		if (smooth > 0 && mHasGaze)
			point = Vector3.Lerp(mGaze, point, 1 - Math.Exp(-smooth * Time.DeltaTime));
		mGaze = point;
		mHasGaze = true;
		IKSolver.LookAt(mChain, forward.LengthSquared > 0 ? forward.Normalized : Vector3.Forward, point, 1, maxAngle);
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (bone == null || !selected)
			return;
		let from = bone.Position;
		DebugDraw.Line(from, from + bone.Rotation * forward.Normalized * 0.4f, .(0.25f, 0.85f, 1.0f, 1));
		if (target != null)
			DebugDraw.Line(from, target.Position, .(1.0f, 0.62f, 0.15f, 0.6f));
	}
}
