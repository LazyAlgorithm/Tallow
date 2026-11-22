using System;
using System.Collections;

namespace Tallow;

/// The arithmetic of inverse kinematics, on Transforms in world space. The IK components (Limb IK, Look At IK,
/// Foot Placement, Hand Pose) are built from these; call them yourself from LateUpdate for anything they do not cover.
static class IKSolver
{
	/// The smallest turn that takes one direction to another.
	public static Quaternion FromTo(Vector3 from, Vector3 to)
	{
		if (from.LengthSquared < 1.0e-12f || to.LengthSquared < 1.0e-12f)
			return .Identity;
		let a = from.Normalized, b = to.Normalized;
		let dot = Vector3.Dot(a, b);
		if (dot > 0.999999f)
			return .Identity;
		if (dot < -0.999999f)
		{
			// Straight back: any axis square to the direction will do.
			var axis = Vector3.Cross(.(1, 0, 0), a);
			if (axis.LengthSquared < 1.0e-6f)
				axis = Vector3.Cross(.(0, 1, 0), a);
			return Quaternion.AngleAxis(180, axis.Normalized);
		}
		let cross = Vector3.Cross(a, b);
		return Quaternion(cross.x, cross.y, cross.z, 1 + dot).Normalized;
	}

	/// A direction turned towards another by no more than a number of degrees.
	public static Vector3 TurnTowards(Vector3 from, Vector3 to, float maxDegrees)
	{
		let a = from.Normalized, b = to.Normalized;
		let angle = Math.Acos(Mathf.Clamp(Vector3.Dot(a, b), -1, 1)) * Mathf.Rad2Deg;
		if (angle <= maxDegrees || angle < 0.001f)
			return b;
		return Quaternion.Slerp(.Identity, FromTo(a, b), maxDegrees / angle) * a;
	}

	/// The way a two-bone limb's middle joint stands out from the line between its ends, square to that line: where a
	/// knee or elbow bends. A straight limb gives (about) zero, not the lengthwise offset of a joint that is not at
	/// the middle of the limb.
	public static Vector3 Bend(Transform upper, Transform middle, Transform tip)
	{
		if (upper == null || middle == null || tip == null)
			return .Zero;
		let chord = tip.Position - upper.Position;
		let length = chord.Length;
		if (length < 1.0e-6f)
			return .Zero;
		let along = chord / length;
		let offset = middle.Position - upper.Position;
		return offset - along * Vector3.Dot(offset, along);
	}

	/// Bends a limb of two bones (upper arm and forearm, thigh and shin) so that its tip reaches a point.
	/// The middle joint bends towards the pole when there is one, and the way it is already bent otherwise.
	/// A point out of reach leaves the limb straight towards it. Only upper and middle are turned.
	public static void TwoBone(Transform upper, Transform middle, Transform tip, Vector3 target, bool usePole, Vector3 pole)
	{
		let a = upper.Position;
		var b = middle.Position;
		var c = tip.Position;
		let upperLength = (b - a).Length, lowerLength = (c - b).Length;
		if (upperLength < 1.0e-5f || lowerLength < 1.0e-5f)
			return;
		let reach = upperLength + lowerLength;
		let toTarget = target - a;
		// Never quite straight and never folded flat: both lose the direction of the bend.
		let distance = Mathf.Clamp(toTarget.Length, Math.Abs(upperLength - lowerLength) + reach * 0.001f, reach * 0.9995f);
		let direction = toTarget.LengthSquared > 1.0e-10f ? toTarget.Normalized : (c - a).Normalized;
		var bend = usePole ? pole - a : b - a;
		bend = bend - direction * Vector3.Dot(bend, direction);
		if (bend.LengthSquared < 1.0e-8f)
		{
			// A straight limb with no pole: bend the way the middle bone's own up points, else any way square to it.
			bend = middle.Up - direction * Vector3.Dot(middle.Up, direction);
			if (bend.LengthSquared < 1.0e-8f)
				bend = Vector3.Cross(direction, Math.Abs(direction.y) < 0.9f ? Vector3.Up : Vector3.Right);
		}
		bend = bend.Normalized;
		let cosine = Mathf.Clamp((upperLength * upperLength + distance * distance - lowerLength * lowerLength) / (2 * upperLength * distance), -1, 1);
		let sine = Math.Sqrt(Math.Max(1 - cosine * cosine, 0));
		let joint = a + direction * (upperLength * cosine) + bend * (upperLength * sine);
		upper.Rotation = (FromTo(b - a, joint - a) * upper.Rotation).Normalized;
		b = middle.Position;
		c = tip.Position;
		middle.Rotation = (FromTo(c - b, a + direction * distance - b) * middle.Rotation).Normalized;
	}

	/// Curls a chain of any number of bones (a finger, a tail, a tentacle, a spine) so that its tip reaches a point.
	/// bones run from the base to the last bone that may turn; tip is the end that should arrive (a child of the
	/// last bone). Returns how far the tip ended from the point.
	public static float Chain(List<Transform> bones, Transform tip, Vector3 target, int iterations = 12, float tolerance = 0.001f)
	{
		for (int pass < iterations)
		{
			for (int i = bones.Count - 1; i >= 0; i--)
			{
				let bone = bones[i];
				let origin = bone.Position;
				bone.Rotation = (FromTo(tip.Position - origin, target - origin) * bone.Rotation).Normalized;
			}
			if ((tip.Position - target).Length <= tolerance)
				break;
		}
		return (tip.Position - target).Length;
	}

	/// Turns bones so that the last one faces a point: a head, or a head with the neck and spine sharing the turn.
	/// bones run from the lowest (spine) to the one that must face the point (head); localForward is the direction
	/// of that bone, in its own space, that should point at it. The turn is kept within maxDegrees of where the
	/// bone faced before, and weight (0 to 1) says how much of it is made. The neck does most of the turn, the head
	/// somewhat less and the spine least, which is how a person bends to look down at the ground.
	public static void LookAt(List<Transform> bones, Vector3 localForward, Vector3 target, float weight, float maxDegrees)
	{
		if (bones.Count == 0 || weight <= 0)
			return;
		let head = bones[bones.Count - 1];
		let facing = (head.Rotation * localForward).Normalized;
		var wanted = target - head.Position;
		if (wanted.LengthSquared < 1.0e-8f)
			return;
		wanted = TurnTowards(facing, wanted, maxDegrees);
		if (weight < 1)
			wanted = (Quaternion.Slerp(.Identity, FromTo(facing, wanted), weight) * facing).Normalized;
		var left = 0.0f;
		for (int i < bones.Count)
			left += LookAtShare(i, bones.Count);
		for (int i < bones.Count)
		{
			// Each bone makes its share of what is still to turn; the last one finishes it.
			let share = LookAtShare(i, bones.Count);
			let now = (head.Rotation * localForward).Normalized;
			let turn = Quaternion.Slerp(.Identity, FromTo(now, wanted), share / Math.Max(left, 0.0001f));
			bones[i].Rotation = (turn * bones[i].Rotation).Normalized;
			left -= share;
		}
	}

	/// How much of a look-at turn a bone does, by its place in the chain (the last is the head): the neck most, then
	/// the head, and the chest and spine least.
	static float LookAtShare(int index, int count)
	{
		let fromHead = count - 1 - index;
		if (fromHead <= 0)
			return 0.5f;
		if (fromHead == 1)
			return 1.0f;
		return 0.25f;
	}
}
