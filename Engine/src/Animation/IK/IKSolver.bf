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
	/// bone faced before, and weight (0 to 1) says how much of it is made.
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
		for (int i < bones.Count)
		{
			// Each bone makes its share of what is still to turn; the last one finishes it.
			let now = (head.Rotation * localForward).Normalized;
			let turn = Quaternion.Slerp(.Identity, FromTo(now, wanted), 1.0f / (bones.Count - i));
			bones[i].Rotation = (turn * bones[i].Rotation).Normalized;
		}
	}
}
