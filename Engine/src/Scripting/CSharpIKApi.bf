using System;
using System.Collections;

namespace Tallow;

/// IK for C# (Managed/Tallow.API/IK.cs). A component is found by kind (0 Limb IK, 1 Look At IK, 2 Foot Placement,
/// 3 Hand Pose) and its place among that kind on the object, since a character usually carries two Limb IKs.
[CSharpExpose]
static class CSharpIK
{
	static GameObject Object(uint64 session, uint64 entity) => CSharpRuntime.PhysicsObject(session, entity);

	static IKComponent Find(uint64 session, uint64 entity, int32 kind, int32 index)
	{
		let obj = Object(session, entity);
		if (obj == null)
			return null;
		int32 seen = 0;
		for (let component in obj.Components)
		{
			let ik = component as IKComponent;
			if (ik == null)
				continue;
			let matches = kind == 0 ? ik is LimbIK : kind == 1 ? ik is LookAtIK : kind == 2 ? ik is FootPlacement : ik is HandPose;
			if (matches && seen++ == index)
				return ik;
		}
		return null;
	}

	/// How many IK components of a kind the object has.
	[CSharpExpose]
	public static int32 Count(uint64 session, uint64 entity, int32 kind)
	{
		let obj = Object(session, entity);
		if (obj == null)
			return 0;
		int32 count = 0;
		while (Find(session, entity, kind, count) != null)
			count++;
		return count;
	}

	/// Adds another Limb IK to the object (an object may have several: one per arm); its place among them, or -1.
	[CSharpExpose]
	public static int32 AddLimb(uint64 session, uint64 entity)
	{
		let obj = Object(session, entity);
		if (obj == null || obj.AddComponent(typeof(LimbIK)) == null)
			return -1;
		return Count(session, entity, 0) - 1;
	}

	/// The entity id of a Limb IK's tip bone (or a Look At IK's head), or 0 when it has none.
	[CSharpExpose]
	public static uint64 Tip(uint64 session, uint64 entity, int32 kind, int32 index)
	{
		let ik = Find(session, entity, kind, index);
		Transform tip = null;
		if (let limb = ik as LimbIK)
			tip = limb.tip;
		return tip?.GameObject != null ? tip.GameObject.Id : 0;
	}

	[CSharpExpose]
	public static float Weight(uint64 session, uint64 entity, int32 kind, int32 index) => Find(session, entity, kind, index)?.Weight ?? 0;

	/// Sets the weight at once (not sent: FadeWeight is).
	[CSharpExpose]
	public static bool SetWeight(uint64 session, uint64 entity, int32 kind, int32 index, float weight)
	{
		let ik = Find(session, entity, kind, index);
		if (ik == null)
			return false;
		ik.Weight = Mathf.Clamp01(weight);
		return true;
	}

	/// Fades the weight (followed on every machine when the server or the owner calls it).
	[CSharpExpose]
	public static bool FadeWeight(uint64 session, uint64 entity, int32 kind, int32 index, float to, float seconds)
	{
		let ik = Find(session, entity, kind, index);
		if (ik == null)
			return false;
		ik.FadeWeight(to, seconds);
		return true;
	}

	/// A Limb IK: 0 LetGo, 1 Grab, over seconds.
	[CSharpExpose]
	public static bool LimbHold(uint64 session, uint64 entity, int32 index, int32 action, float seconds)
	{
		let limb = Find(session, entity, 0, index) as LimbIK;
		if (limb == null)
			return false;
		if (action == 0)
			limb.LetGo(seconds);
		else
			limb.Grab(seconds);
		return true;
	}

	/// A Limb IK moves to another target over seconds (0 as the target clears it).
	[CSharpExpose]
	public static bool LimbSetTarget(uint64 session, uint64 entity, int32 index, uint64 target, float seconds)
	{
		let limb = Find(session, entity, 0, index) as LimbIK;
		if (limb == null)
			return false;
		limb.SetTarget(target == 0 ? null : Object(session, target)?.Transform, seconds);
		return true;
	}

	/// Whether a Limb IK is held on a target.
	[CSharpExpose]
	public static bool LimbIsHolding(uint64 session, uint64 entity, int32 index) => (Find(session, entity, 0, index) as LimbIK)?.IsHolding ?? false;

	[CSharpExpose]
	public static float LimbReach(uint64 session, uint64 entity, int32 index) => (Find(session, entity, 0, index) as LimbIK)?.Reach ?? 0;

	/// A Look At IK with no target looks at a world point.
	[CSharpExpose]
	public static bool LookAt(uint64 session, uint64 entity, int32 index, Vector3 point)
	{
		let look = Find(session, entity, 1, index) as LookAtIK;
		if (look == null)
			return false;
		look.LookAt(point);
		return true;
	}

	/// How many feet a Foot Placement places: 2, or 4 on a four-legged character.
	[CSharpExpose]
	public static int32 FootCount(uint64 session, uint64 entity) => (Find(session, entity, 2, 0) as FootPlacement)?.FootCount ?? 0;

	/// Whether a Foot Placement foot (0 left, 1 right, 2 and 3 the other pair of a four-legged character) found
	/// ground this frame: 1 yes, 0 no, -1 without a Foot Placement or that foot.
	[CSharpExpose]
	public static int32 FootGrounded(uint64 session, uint64 entity, int32 foot)
	{
		let placement = Find(session, entity, 2, 0) as FootPlacement;
		if (placement == null || foot < 0 || foot >= placement.FootCount)
			return -1;
		return placement.IsGrounded(foot) ? 1 : 0;
	}

	/// A Hand Pose takes a shape (HandShape as a number) over seconds (below 0: its Blend Time).
	[CSharpExpose]
	public static bool HandSetShape(uint64 session, uint64 entity, int32 index, int32 shape, float seconds)
	{
		let hand = Find(session, entity, 3, index) as HandPose;
		if (hand == null || shape < 0 || shape > (int32)HandShape.ThumbsUp)
			return false;
		hand.SetShape((HandShape)shape, seconds);
		return true;
	}

	/// One finger of a Hand Pose (0 thumb ... 4 pinky) to a curl, 0 straight to 1 closed.
	[CSharpExpose]
	public static bool HandCurl(uint64 session, uint64 entity, int32 index, int32 finger, float amount)
	{
		let hand = Find(session, entity, 3, index) as HandPose;
		if (hand == null || finger < 0 || finger > 4)
			return false;
		hand.Curl(finger, amount);
		return true;
	}

	/// Works every IK component out now, rather than at the end of the frame.
	[CSharpExpose]
	public static void Solve(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene != null)
			IKSystem.Solve(scene);
	}

	static Transform Bone(uint64 session, uint64 entity) => Object(session, entity)?.Transform;

	[CSharpExpose]
	public static bool SolveTwoBone(uint64 session, uint64 upper, uint64 middle, uint64 tip, Vector3 target, bool usePole, Vector3 pole)
	{
		let a = Bone(session, upper), b = Bone(session, middle), c = Bone(session, tip);
		if (a == null || b == null || c == null)
			return false;
		IKSolver.TwoBone(a, b, c, target, usePole, pole);
		return true;
	}

	/// Bones as entity ids, root first. The distance left between tip and target (-1 when a bone is missing).
	[CSharpExpose]
	public static float SolveChain(uint64 session, Span<uint64> bones, uint64 tip, Vector3 target, int32 iterations)
	{
		let list = scope List<Transform>();
		for (let id in bones)
		{
			let bone = Bone(session, id);
			if (bone == null)
				return -1;
			list.Add(bone);
		}
		let end = Bone(session, tip);
		if (end == null || list.IsEmpty)
			return -1;
		return IKSolver.Chain(list, end, target, Math.Max(iterations, 1));
	}

	[CSharpExpose]
	public static bool SolveLookAt(uint64 session, Span<uint64> bones, Vector3 localForward, Vector3 target, float weight, float maxDegrees)
	{
		let list = scope List<Transform>();
		for (let id in bones)
		{
			let bone = Bone(session, id);
			if (bone == null)
				return false;
			list.Add(bone);
		}
		if (list.IsEmpty)
			return false;
		IKSolver.LookAt(list, localForward, target, weight, maxDegrees);
		return true;
	}
}
