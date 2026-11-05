using System;
using System.Collections;

namespace Tallow;

/// Holds the end of an arm or a leg on a target: a hand on a weapon's grip, a hand on a door handle, a foot on a
/// pedal. One component is one limb, so a character holding a rifle has two (one for each hand), and each can let go
/// and take hold again by itself: LetGo on the left hand while it throws a grenade, Grab when it comes back.
///
/// Tip is the hand or foot. The two bones above it are bent to reach (Middle and Upper name them when they are not
/// simply its parents). Target is any object: put empty objects on a weapon where the hands belong. Pole is an object
/// the elbow or knee points towards; without one the limb keeps bending the way the clip bends it, and a humanoid's
/// limb that is straight bends the natural way (elbows back, knees forward).
///
/// IK runs after the Animator and after every script's LateUpdate, so a clip plays underneath and the hands stay on a
/// weapon that sways or recoils. Weight blends between the clip's pose (0) and the target (1). It is worked out on
/// each machine; in multiplayer LetGo, Grab and FadeWeight called by the object's owner are followed everywhere, and
/// a target moves on other machines if it is shared like any other object.
[Component]
class LimbIK : IKComponent
{
	/// The hand or foot: the bone that goes to the target.
	public Transform tip;
	/// Where the tip should be. Its rotation is used too when Rotation Weight is above 0.
	public Transform target;
	/// The elbow or knee points towards this. Empty: it bends the way it already does.
	public Transform pole;
	/// 0 leaves the limb to its animation, 1 puts the tip on the target.
	[Range(0, 1)] public float weight = 1;
	/// How much the tip takes the target's rotation: 1 for a hand locked to a grip, 0 to leave the wrist to the clip.
	[Range(0, 1)] public float rotationWeight = 1;
	/// Turns the tip relative to the target, in degrees, for a hand whose bone does not point the way the target does.
	/// "Keep Hand's Rotation" in the Inspector fills it in from the pose in front of you.
	public Vector3 rotationOffset = .Zero;
	/// The point of the tip that lands on the target, in the tip's own space: the palm rather than the wrist.
	public Vector3 gripPoint = .Zero;
	/// The elbow or knee, when it is not the tip's parent.
	public Transform middle;
	/// The shoulder or hip bone, when it is not the middle's parent.
	public Transform upper;

	Transform mFromTarget;
	Vector3 mFromPosition;
	Quaternion mFromRotation = .Identity;
	float mSwitchTime = -1, mSwitchLength;
	Vector3 mGoalPosition;
	Quaternion mGoalRotation = .Identity;
	bool mHasGoal;
	float mHeldWeight = 1;
	// The humanoid the tip belongs to, looked up once for each tip: which limb it is and the hips that tell its facing.
	Transform mBendFor;
	int mBendSign;
	Transform mLeftHip, mRightHip;

	public override float Weight { get => weight; set => weight = value; }
	public override int32 Order => 20;

	public Transform Middle => middle != null ? middle : (tip != null ? tip.Parent : null);
	public Transform Upper => upper != null ? upper : (Middle != null ? Middle.Parent : null);
	/// True while the limb is held on a target (weight above 0 and a target set).
	public bool IsHolding => weight > 0 && target != null;
	/// How far the target is along the limb's reach: 1 and over is out of reach, and the limb is straight.
	public float Reach
	{
		get
		{
			let top = Upper, mid = Middle;
			if (top == null || mid == null || tip == null || target == null)
				return 0;
			let length = (mid.Position - top.Position).Length + (tip.Position - mid.Position).Length;
			return length > 0 ? (target.Position - top.Position).Length / length : 0;
		}
	}

	/// Takes the limb off its target over some seconds, back to its animation: to throw, wave, reload or climb.
	/// The other limbs stay where they are. Followed on every machine when the object's owner calls it.
	public void LetGo(float seconds = 0.15f)
	{
		if (weight > 0)
			mHeldWeight = weight;
		FadeWeight(0, seconds);
	}

	/// Puts the limb back on its target over some seconds. Followed on every machine when the object's owner calls it.
	public void Grab(float seconds = 0.15f) => FadeWeight(mHeldWeight > 0 ? mHeldWeight : 1, seconds);

	/// Moves to another target over some seconds, without a jump: the next weapon's grip, a ledge. Call it on every
	/// machine (where the weapon is equipped, say): which object is the target is not sent over the network.
	public void SetTarget(Transform next, float seconds = 0.15f)
	{
		if (next == target)
			return;
		if (mHasGoal && seconds > 0)
		{
			mFromPosition = mGoalPosition;
			mFromRotation = mGoalRotation;
			mSwitchTime = 0;
			mSwitchLength = seconds;
		}
		mFromTarget = target;
		target = next;
	}

	/// Sets Rotation Offset so that the tip keeps the rotation it has now while it follows the target.
	public void KeepCurrentRotation()
	{
		if (tip == null || target == null)
			return;
		Vector3 position;
		Quaternion rotation;
		// Measured on the pose from before IK, which is the one being looked at when the weight is 0.
		let saved = tip.LocalRotation;
		if (InputPose(tip, out position, out rotation))
			tip.LocalRotation = rotation;
		rotationOffset = (target.Rotation.Conjugate * tip.Rotation).Normalized.EulerAngles;
		tip.LocalRotation = saved;
	}

	/// The way a character faces, from its hips (else its shoulders): scene space is left-handed, so facing +Z its
	/// right is +X. Zero when the model is not a humanoid.
	public static Vector3 HumanForward(SkinnedMeshRenderer skinned)
	{
		if (!skinned || skinned.Model == null || !skinned.Model.HumanMap.IsHumanoid)
			return .Zero;
		let map = skinned.Model.HumanMap;
		var left = skinned.Bone(map[.LeftUpperLeg]);
		var right = skinned.Bone(map[.RightUpperLeg]);
		if (left == null || right == null)
		{
			left = skinned.Bone(map[.LeftUpperArm]);
			right = skinned.Bone(map[.RightUpperArm]);
		}
		return left != null && right != null ? Facing(left, right) : .Zero;
	}

	static Vector3 Facing(Transform left, Transform right)
	{
		var across = right.Position - left.Position;
		across.y = 0;
		return across.LengthSquared > 1.0e-8f ? Vector3.Cross(across, .Up).Normalized : .Zero;
	}

	/// The way this limb's elbow or knee naturally points, in world space: behind the character for an arm, in front
	/// for a leg. Zero when the tip is not a humanoid's hand or foot.
	public Vector3 NaturalBend()
	{
		if (tip == null)
			return .Zero;
		if (mBendFor != tip)
		{
			mBendFor = tip;
			mBendSign = 0;
			mLeftHip = mRightHip = null;
			for (var parent = tip.Parent; parent != null && mBendSign == 0; parent = parent.Parent)
			{
				let skinned = parent.GameObject.GetComponent<SkinnedMeshRenderer>();
				if (!skinned || skinned.Model == null || !skinned.Model.HumanMap.IsHumanoid)
					continue;
				let map = skinned.Model.HumanMap;
				if (skinned.Bone(map[.LeftHand]) == tip || skinned.Bone(map[.RightHand]) == tip)
					mBendSign = -1;
				else if (skinned.Bone(map[.LeftFoot]) == tip || skinned.Bone(map[.RightFoot]) == tip)
					mBendSign = 1;
				mLeftHip = skinned.Bone(map[.LeftUpperLeg]) ?? skinned.Bone(map[.LeftUpperArm]);
				mRightHip = skinned.Bone(map[.RightUpperLeg]) ?? skinned.Bone(map[.RightUpperArm]);
			}
		}
		if (mBendSign == 0 || mLeftHip == null || mRightHip == null || mLeftHip.GameObject.IsDestroyed || mRightHip.GameObject.IsDestroyed)
			return .Zero;
		return Facing(mLeftHip, mRightHip) * mBendSign;
	}

	/// Moves the target (and turns it) to where the tip is now, so that turning IK on changes nothing until the
	/// target is moved.
	public void TargetToTip()
	{
		if (tip == null || target == null)
			return;
		target.SetPositionAndRotation(tip.TransformPoint(gripPoint), tip.Rotation);
		rotationOffset = .Zero;
	}

	protected override void CollectBones(List<Transform> bones)
	{
		let top = Upper, mid = Middle;
		if (tip == null || mid == null || top == null)
			return;
		bones.Add(top);
		bones.Add(mid);
		bones.Add(tip);
	}

	protected override void Solve()
	{
		let top = Upper, mid = Middle;
		if (tip == null || mid == null || top == null || target == null || target.GameObject.IsDestroyed)
			return;
		var position = target.Position;
		var rotation = (target.Rotation * Quaternion.Euler(rotationOffset)).Normalized;
		if (mSwitchTime >= 0)
		{
			// Changing targets: from where the hand was held to the new place.
			mSwitchTime += Time.DeltaTime;
			let t = mSwitchLength > 0 ? Mathf.Clamp01(mSwitchTime / mSwitchLength) : 1;
			let eased = Mathf.SmoothStep(0, 1, t);
			position = Vector3.Lerp(mFromPosition, position, eased);
			rotation = Quaternion.Slerp(mFromRotation, rotation, eased);
			if (t >= 1)
				mSwitchTime = -1;
		}
		mGoalPosition = position;
		mGoalRotation = rotation;
		mHasGoal = true;
		// The rotation the tip ends with decides where the wrist must be for the grip point to land on the target.
		let turn = Mathf.Clamp01(rotationWeight);
		let before = tip.Rotation;
		let final = turn > 0 ? Quaternion.Slerp(before, rotation, turn) : before;
		var wrist = position;
		if (gripPoint != .Zero)
			wrist = position - final * (before.Conjugate * (tip.TransformPoint(gripPoint) - tip.Position));
		var usePole = pole != null && !pole.GameObject.IsDestroyed;
		var polePosition = usePole ? pole.Position : Vector3.Zero;
		if (!usePole)
		{
			// No pole: the clip's bend decides, unless the limb is nearly straight and the bend is only noise.
			let reach = (mid.Position - top.Position).Length;
			let bend = mid.Position - (top.Position + tip.Position) * 0.5f;
			if (bend.Length < reach * 0.05f)
			{
				let natural = NaturalBend();
				if (natural != .Zero)
				{
					usePole = true;
					polePosition = mid.Position + natural * Math.Max(reach, 0.1f);
				}
			}
		}
		IKSolver.TwoBone(top, mid, tip, wrist, usePole, polePosition);
		if (turn > 0)
			tip.Rotation = Quaternion.Slerp(tip.Rotation, rotation, turn);
		else
			tip.Rotation = before;
	}

	public override void OnDrawGizmos(bool selected)
	{
		let top = Upper, mid = Middle;
		if (tip == null || mid == null || top == null)
			return;
		let color = Color(0.25f, 0.85f, 1.0f, selected ? 1.0f : 0.45f);
		DebugDraw.Line(top.Position, mid.Position, color);
		DebugDraw.Line(mid.Position, tip.Position, color);
		if (target != null)
		{
			DebugDraw.Sphere(target.Position, 0.025f, .(1.0f, 0.62f, 0.15f, 1));
			if (selected)
				DebugDraw.Line(tip.Position, target.Position, .(1.0f, 0.62f, 0.15f, 0.6f));
		}
		if (pole != null && selected)
		{
			DebugDraw.Line(mid.Position, pole.Position, .(0.6f, 1.0f, 0.4f, 0.7f));
			DebugDraw.Sphere(pole.Position, 0.02f, .(0.6f, 1.0f, 0.4f, 1));
		}
	}
}
