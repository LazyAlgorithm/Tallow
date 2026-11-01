using System;
using System.Collections;

namespace Tallow;

/// Keeps a character's feet on the ground: on stairs, slopes and rubble each foot is set down on what is under it,
/// the hips drop so that the lower foot can reach, and the feet tilt with the slope. Put it on the character's root
/// (the object that moves over the ground) and name the two feet; the legs are the two bones above each foot.
///
/// It works on top of the clip: a foot the animation lifts for a step is still lifted, by the same amount, over
/// whatever the ground is doing there. It looks for the ground with the physics world, so the ground needs colliders,
/// and it only does anything while the game is playing. Set Ground Layer when the character's own collider would
/// otherwise be found first. Worked out on each machine from the ground there; nothing is sent.
[Component]
class FootPlacement : IKComponent
{
	public Transform leftFoot;
	public Transform rightFoot;
	/// The hips or pelvis bone, lowered when one foot has further to reach. Empty: the hips are left alone.
	public Transform hips;
	[Range(0, 1)] public float weight = 1;
	/// The highest step up a foot is put on, and the deepest step down it reaches for.
	public float stepUp = 0.4f;
	public float stepDown = 0.45f;
	/// How quickly feet and hips settle on new ground; higher is snappier.
	public float smooth = 14;
	/// Tilt the feet to the slope under them, by no more than Max Tilt degrees.
	public bool tilt = true;
	[Range(0, 60)] public float maxTilt = 35;
	/// Only colliders on this layer count as ground. None: everything except this character.
	[Layer] public int32 groundLayer = -1;

	float[2] mOffset;
	Vector3[2] mNormal = .(.Up, .Up);
	bool[2] mGrounded;
	float mHips;

	public override float Weight { get => weight; set => weight = value; }
	public override int32 Order => 0;

	/// True when ground was found under a foot (0: left, 1: right) this frame.
	public bool IsGrounded(int foot) => foot >= 0 && foot < 2 && mGrounded[foot];
	/// How far the hips are lowered at the moment.
	public float HipsOffset => mHips;

	Transform Foot(int index) => index == 0 ? leftFoot : rightFoot;

	protected override void CollectBones(List<Transform> bones)
	{
		if (hips != null)
			bones.Add(hips);
		for (int i < 2)
		{
			let foot = Foot(i);
			if (foot == null || foot.Parent == null || foot.Parent.Parent == null)
				continue;
			bones.Add(foot.Parent.Parent);
			bones.Add(foot.Parent);
			bones.Add(foot);
		}
	}

	bool Ground(Vector3 above, float length, out Vector3 point)
	{
		point = default;
		RaycastHit hit;
		let mask = groundLayer >= 0 && groundLayer < 32 ? (uint32)1 << groundLayer : uint32.MaxValue;
		if (!Scene.Physics.Raycast(above, .Down, length, out hit, mask))
			return false;
		// The character's own collider is not ground.
		if (hit.gameObject != null && (hit.gameObject == GameObject || hit.gameObject.Transform.IsChildOf(Transform)))
			return false;
		point = hit.point;
		return true;
	}

	protected override void Solve()
	{
		if (!Scene.IsPlaying)
			return;
		let baseY = Transform.Position.y;
		let blend = smooth > 0 ? 1 - Math.Exp(-smooth * Time.DeltaTime) : 1;
		Vector3[2] animated = default;
		Quaternion[2] facing = default;
		float lowest = 0;
		for (int i < 2)
		{
			let foot = Foot(i);
			if (foot == null)
				continue;
			animated[i] = foot.Position;
			facing[i] = foot.Rotation;
			let above = Vector3(animated[i].x, baseY + stepUp, animated[i].z);
			Vector3 point;
			float wanted = 0;
			var normal = Vector3.Up;
			mGrounded[i] = Ground(above, stepUp + stepDown, out point);
			if (mGrounded[i])
			{
				wanted = point.y - baseY;
				if (tilt)
				{
					// The slope, from two more points a little ahead and to the side.
					let ahead = Transform.Forward * 0.1f, aside = Transform.Right * 0.1f;
					Vector3 front, side;
					if (Ground(above + ahead, stepUp + stepDown, out front) && Ground(above + aside, stepUp + stepDown, out side))
					{
						normal = Vector3.Cross(front - point, side - point).Normalized;
						if (normal.y < 0)
							normal = -normal;
						normal = IKSolver.TurnTowards(.Up, normal, maxTilt);
					}
				}
			}
			mOffset[i] = Mathf.Lerp(mOffset[i], wanted, blend);
			mNormal[i] = Vector3.Lerp(mNormal[i], normal, blend).Normalized;
			lowest = Math.Min(lowest, mOffset[i]);
		}
		// The hips come down for the foot that has furthest to go, and never rise.
		mHips = Mathf.Lerp(mHips, Mathf.Clamp(lowest, -stepDown, 0), blend);
		if (hips != null)
			hips.Position = hips.Position + Vector3.Up * mHips;
		for (int i < 2)
		{
			let foot = Foot(i);
			if (foot == null || foot.Parent == null || foot.Parent.Parent == null)
				continue;
			let goal = animated[i] + Vector3.Up * mOffset[i];
			IKSolver.TwoBone(foot.Parent.Parent, foot.Parent, foot, goal, false, .Zero);
			foot.Rotation = (IKSolver.FromTo(.Up, mNormal[i]) * facing[i]).Normalized;
		}
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected)
			return;
		for (int i < 2)
		{
			let foot = Foot(i);
			if (foot == null)
				continue;
			let p = foot.Position;
			let baseY = Transform.Position.y;
			DebugDraw.Line(.(p.x, baseY + stepUp, p.z), .(p.x, baseY - stepDown, p.z), mGrounded[i] ? Color(0.4f, 1.0f, 0.5f, 1) : Color(1.0f, 0.5f, 0.3f, 1));
		}
	}
}
