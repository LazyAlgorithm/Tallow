using System;
using System.Collections;

namespace Tallow;

/// Keeps a character's feet on the ground: on stairs, slopes and rubble each foot is set down on what is under it,
/// the hips drop so that the lower foot can reach, and the feet tilt with the slope. Put it on the character's root
/// (the object that moves over the ground) and name the feet; the legs are the two bones above each foot.
///
/// A two-legged character has two feet (Left Foot and Right Foot); a four-legged one has four, the other pair in
/// Foot 3 and Foot 4 (found for you by Find Feet And Hips: FrontPaw_L, BackPaw_R and so on). The body bone (Root
/// or Hips) drops so that the foot with furthest to go can reach.
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
	/// A third and fourth foot, for a four-legged character: the other pair of paws. All the feet are placed alike.
	public Transform thirdFoot;
	public Transform fourthFoot;
	/// The hips or pelvis bone, lowered when one foot has further to reach. Empty: the hips are left alone.
	public Transform hips;
	/// How much the feet are placed: 0 the animation as it is, 1 fully on the ground.
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

	float[QuadrupedRig.FootCount] mOffset;
	Vector3[QuadrupedRig.FootCount] mNormal = .(.Up, .Up, .Up, .Up);
	bool[QuadrupedRig.FootCount] mGrounded;
	float mHips;

	public override float Weight { get => weight; set => weight = value; }
	public override int32 Order => 0;

	/// How many feet it places: 2, or 4 when Foot 3 and Foot 4 are set.
	public int32 FootCount => fourthFoot != null ? 4 : (thirdFoot != null ? 3 : 2);
	/// True when ground was found under a foot this frame (0 left, 1 right, 2 and 3 the other pair).
	public bool IsGrounded(int foot) => foot >= 0 && foot < FootCount && mGrounded[foot];
	/// How far the body is lowered at the moment.
	public float HipsOffset => mHips;

	Transform Foot(int index) => index == 0 ? leftFoot : (index == 1 ? rightFoot : (index == 2 ? thirdFoot : fourthFoot));

	protected override void CollectBones(List<Transform> bones)
	{
		if (hips != null)
			bones.Add(hips);
		for (int i < FootCount)
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
		Vector3[QuadrupedRig.FootCount] animated = default;
		Quaternion[QuadrupedRig.FootCount] facing = default;
		float lowest = 0;
		for (int i < FootCount)
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
		for (int i < FootCount)
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
		for (int i < FootCount)
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
