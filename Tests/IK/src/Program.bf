using System;
using System.Collections;
using Tallow;

namespace IKTests;

class Program
{
	static bool Check(bool condition, StringView name)
	{
		Console.WriteLine(scope $"{condition ? "PASS" : "FAIL"}: {name}");
		return condition;
	}

	static Transform Bone(Scene scene, StringView name, Transform parent, Vector3 local)
	{
		let bone = scene.CreateGameObject(name, parent).Transform;
		bone.LocalPosition = local;
		return bone;
	}

	/// An arm hanging from a shoulder, bent a little at the elbow, with a hand at the end.
	static void Arm(Scene scene, Transform parent, StringView side, float x, out Transform upper, out Transform elbow, out Transform hand)
	{
		upper = Bone(scene, scope $"UpperArm.{side}" , parent, .(x, 1.4f, 0));
		elbow = Bone(scene, scope $"LowerArm.{side}" , upper, .(0, -0.3f, 0));
		hand = Bone(scene, scope $"Hand.{side}" , elbow, .(0, -0.3f, 0));
		upper.LocalRotation = Quaternion.Euler(-10, 0, 0);
		elbow.LocalRotation = Quaternion.Euler(-20, 0, 0);
	}

	static void Step(Scene scene, int frames = 1)
	{
		for (int i < frames)
			IKSystem.Solve(scene);
	}

	public static int Main(String[] args)
	{
		Console.WriteLine("Inverse kinematics tests");
		bool ok = true;
		Time.DeltaTime = 1.0f / 60;
		let scene = scope Scene();
		Scene.Active = scene;

		// ---- the arithmetic ----
		let turned = IKSolver.FromTo(.(1, 0, 0), .(0, 1, 1)) * Vector3(1, 0, 0);
		ok &= Check((turned - Vector3(0, 1, 1).Normalized).Length < 0.0001f, "FromTo turns one direction onto another");
		ok &= Check((IKSolver.FromTo(.(0, 0, 1), .(0, 0, -1)) * Vector3(0, 0, 1) - Vector3(0, 0, -1)).Length < 0.0001f, "FromTo copes with straight back");
		let limited = IKSolver.TurnTowards(.(0, 0, 1), .(1, 0, 0), 30);
		ok &= Check(Math.Abs(Math.Acos(Vector3.Dot(limited, .(0, 0, 1))) * Mathf.Rad2Deg - 30) < 0.05f, "TurnTowards stops at the limit");

		// ---- one arm on a target ----
		let root = scene.CreateGameObject("Character");
		Transform upper, elbow, hand;
		Arm(scene, root.Transform, "R", 0.2f, out upper, out elbow, out hand);
		let restUpper = upper.LocalRotation, restElbow = elbow.LocalRotation, restHand = hand.LocalRotation;
		let target = scene.CreateGameObject("Grip").Transform;
		target.Position = .(0.35f, 1.25f, 0.35f);
		let pole = scene.CreateGameObject("Elbow Pole").Transform;
		pole.Position = .(1.5f, 0.6f, -0.5f);
		let arm = root.AddComponent<LimbIK>();
		arm.tip = hand;
		arm.target = target;
		arm.rotationWeight = 0;
		Step(scene);
		ok &= Check((hand.Position - target.Position).Length < 0.001f, "the hand reaches the target");
		ok &= Check(Math.Abs((elbow.Position - upper.Position).Length - 0.3f) < 0.0005f && Math.Abs((hand.Position - elbow.Position).Length - 0.3f) < 0.0005f, "bone lengths are kept");
		Step(scene, 20);
		ok &= Check((hand.Position - target.Position).Length < 0.001f, "solving again and again does not drift");
		arm.pole = pole;
		Step(scene);
		let side = Vector3.Dot(elbow.Position - upper.Position, (pole.Position - upper.Position));
		let along = (target.Position - upper.Position).Normalized;
		let elbowOff = (elbow.Position - upper.Position) - along * Vector3.Dot(elbow.Position - upper.Position, along);
		let poleOff = (pole.Position - upper.Position) - along * Vector3.Dot(pole.Position - upper.Position, along);
		ok &= Check(side > 0 && Vector3.Dot(elbowOff.Normalized, poleOff.Normalized) > 0.999f && (hand.Position - target.Position).Length < 0.001f, "the elbow bends towards the pole");
		arm.pole = null;

		// ---- a layer over the pose ----
		arm.weight = 0;
		Step(scene);
		ok &= Check(Quaternion.Dot(upper.LocalRotation, restUpper) > 0.99999f && Quaternion.Dot(elbow.LocalRotation, restElbow) > 0.99999f && Quaternion.Dot(hand.LocalRotation, restHand) > 0.99999f, "weight 0 gives back the pose from before IK");
		let freeHand = hand.Position;
		arm.weight = 0.5f;
		Step(scene);
		let partway = (hand.Position - freeHand).Length, whole = (target.Position - freeHand).Length;
		ok &= Check(partway > whole * 0.2f && partway < whole * 0.8f, "weight one half goes part of the way");
		arm.weight = 1;
		Step(scene);
		// A clip poses the arm differently: IK must start from the new pose, not from its own last answer.
		upper.LocalRotation = Quaternion.Euler(-60, 0, 20);
		elbow.LocalRotation = Quaternion.Euler(-40, 0, 0);
		Step(scene);
		ok &= Check((hand.Position - target.Position).Length < 0.001f, "IK follows a pose changed underneath it");
		Vector3 inputPosition;
		Quaternion inputRotation;
		ok &= Check(IKSystem.InputPose(upper, out inputPosition, out inputRotation) && Quaternion.Dot(inputRotation, Quaternion.Euler(-60, 0, 20)) > 0.99999f, "the pose from before IK can be asked for");
		arm.Enabled = false;
		Step(scene);
		ok &= Check(Quaternion.Dot(upper.LocalRotation, Quaternion.Euler(-60, 0, 20)) > 0.99999f, "a disabled component gives the pose back");
		arm.Enabled = true;
		upper.LocalRotation = restUpper;
		elbow.LocalRotation = restElbow;

		// ---- out of reach ----
		target.Position = .(0.2f, 1.4f, 3);
		Step(scene);
		let straight = Vector3.Dot((elbow.Position - upper.Position).Normalized, (hand.Position - elbow.Position).Normalized);
		ok &= Check(straight > 0.99f && Vector3.Dot((hand.Position - upper.Position).Normalized, .(0, 0, 1)) > 0.999f && arm.Reach > 1, "a target out of reach leaves the arm straight towards it");
		target.Position = .(0.35f, 1.25f, 0.35f);

		// ---- the hand locked to the target's rotation ----
		arm.rotationWeight = 1;
		target.Rotation = Quaternion.Euler(20, 70, -30);
		Step(scene);
		ok &= Check(Math.Abs(Quaternion.Dot(hand.Rotation, target.Rotation)) > 0.99999f, "the hand takes the target's rotation");
		arm.rotationOffset = .(0, 90, 0);
		Step(scene);
		ok &= Check(Math.Abs(Quaternion.Dot(hand.Rotation, target.Rotation * Quaternion.Euler(0, 90, 0))) > 0.99999f, "rotation offset turns the hand on the target");
		arm.gripPoint = .(0, -0.08f, 0.02f);
		Step(scene);
		ok &= Check((hand.TransformPoint(arm.gripPoint) - target.Position).Length < 0.001f, "the grip point, not the wrist, lands on the target");
		arm.gripPoint = .Zero;
		arm.rotationOffset = .Zero;
		arm.weight = 0;
		Step(scene);
		arm.KeepCurrentRotation();
		arm.weight = 1;
		let keptRotation = hand.Rotation;
		Step(scene);
		// The arm has moved, but the hand faces the way it did.
		ok &= Check(Math.Abs(Quaternion.Dot(hand.Rotation, keptRotation)) > 0.9999f, "Keep Current Rotation holds the hand as it was");

		// ---- two arms, one let go ----
		Transform upperL, elbowL, handL;
		Arm(scene, root.Transform, "L", -0.2f, out upperL, out elbowL, out handL);
		let targetL = scene.CreateGameObject("Foregrip").Transform;
		targetL.Position = .(-0.1f, 1.2f, 0.45f);
		let armL = root.AddComponent<LimbIK>();
		armL.tip = handL;
		armL.target = targetL;
		armL.rotationWeight = 0;
		Step(scene);
		ok &= Check((handL.Position - targetL.Position).Length < 0.001f && (hand.Position - target.Position).Length < 0.001f, "two arms hold two targets");
		let hangingL = Quaternion.Euler(-10, 0, 0);
		armL.LetGo(0.1f);
		Step(scene, 30);
		ok &= Check(armL.weight == 0 && !armL.IsHolding && Quaternion.Dot(upperL.LocalRotation, hangingL) > 0.99999f, "one arm lets go and goes back to its animation");
		ok &= Check((hand.Position - target.Position).Length < 0.001f && arm.IsHolding, "the other arm stays on its target");
		armL.Grab(0.1f);
		Step(scene, 3);
		ok &= Check(armL.weight > 0 && armL.weight < 1, "taking hold again is blended, not a jump");
		Step(scene, 30);
		ok &= Check(armL.weight == 1 && (handL.Position - targetL.Position).Length < 0.001f, "and ends on the target");

		// ---- moving to another target ----
		let other = scene.CreateGameObject("Other Grip").Transform;
		other.Position = .(-0.3f, 1.0f, 0.3f);
		armL.SetTarget(other, 0.2f);
		Step(scene, 2);
		let betweenA = (handL.Position - targetL.Position).Length, betweenB = (handL.Position - other.Position).Length;
		ok &= Check(betweenA > 0.0005f && betweenB > 0.01f, "a new target is moved to, not jumped to");
		Step(scene, 30);
		ok &= Check((handL.Position - other.Position).Length < 0.001f, "and reached");

		// ---- looking ----
		let spine = Bone(scene, "Spine", root.Transform, .(0, 1.0f, 0));
		let neck = Bone(scene, "Neck", spine, .(0, 0.45f, 0));
		let head = Bone(scene, "Head", neck, .(0, 0.1f, 0));
		let look = root.AddComponent<LookAtIK>();
		look.bone = head;
		look.maxAngle = 80;
		let seen = scene.CreateGameObject("Seen").Transform;
		seen.Position = .(2, 1.9f, 2);
		look.target = seen;
		Step(scene);
		ok &= Check(Vector3.Dot(head.Forward, (seen.Position - head.Position).Normalized) > 0.9999f, "the head faces the target");
		ok &= Check(Quaternion.Dot(neck.LocalRotation, .Identity) > 0.99999f, "with one bone only the head turns");
		look.bones = 3;
		Step(scene);
		ok &= Check(Vector3.Dot(head.Forward, (seen.Position - head.Position).Normalized) > 0.999f && Quaternion.Dot(spine.LocalRotation, .Identity) < 0.9999f && Quaternion.Dot(neck.LocalRotation, .Identity) < 0.9999f, "with three bones the neck and spine share the turn");
		look.bones = 1;
		seen.Position = .(0, 1.55f, -3);
		Step(scene);
		let headAngle = Math.Acos(Mathf.Clamp(Vector3.Dot(head.Forward, .(0, 0, 1)), -1, 1)) * Mathf.Rad2Deg;
		ok &= Check(Math.Abs(headAngle - 80) < 0.5f, "a target behind turns the head only as far as Max Angle");
		look.target = null;
		look.LookAt(.(-2, 1.55f, 2));
		Step(scene);
		ok &= Check(Vector3.Dot(head.Forward, (Vector3(-2, 1.55f, 2) - head.Position).Normalized) > 0.9999f, "a point from code is looked at when there is no target");

		// ---- a chain of many bones ----
		let tailRoot = scene.CreateGameObject("Tail").Transform;
		List<Transform> tail = scope .();
		var previous = tailRoot;
		for (int i < 5)
		{
			previous = Bone(scene, scope $"Tail{i}" , previous, i == 0 ? Vector3(3, 0, 0) : Vector3(0, 0, 0.2f));
			tail.Add(previous);
		}
		let tailTip = Bone(scene, "TailTip", previous, .(0, 0, 0.2f));
		let miss = IKSolver.Chain(tail, tailTip, .(3.3f, 0.5f, 0.4f), 30);
		ok &= Check(miss < 0.002f && Math.Abs((tail[2].Position - tail[1].Position).Length - 0.2f) < 0.0005f, "a chain of five bones curls to a point");

		// ---- fingers ----
		let palm = Bone(scene, "Hand.Test", root.Transform, .(2, 1, 0));
		// A right hand held palm down: fingers along +Z, thumb on the -X side and a little below the fingers.
		StringView[5] names = .("Thumb", "Index", "Middle", "Ring", "Pinky");
		Transform[5] tips = default;
		for (int f < 5)
		{
			var bone = Bone(scene, scope $"{names[f]}1" , palm, f == 0 ? Vector3(-0.04f, -0.01f, 0.02f) : Vector3(-0.045f + f * 0.02f, 0, 0.09f));
			if (f == 0)
				bone.LocalRotation = Quaternion.Euler(0, -45, 0);
			for (int j = 2; j <= 3; j++)
				bone = Bone(scene, scope $"{names[f]}{j}" , bone, .(0, 0, 0.03f));
			tips[f] = Bone(scene, scope $"{names[f]}End" , bone, .(0, 0, 0.025f));
		}
		let fingers = palm.GameObject.AddComponent<HandPose>();
		Step(scene);
		ok &= Check(fingers.BoneCount(0) >= 3 && fingers.BoneCount(1) >= 3 && fingers.BoneCount(4) >= 3, "fingers are found by name");
		ok &= Check(!fingers.restPose.IsEmpty, "the straight pose is remembered");
		Vector3[5] open = default;
		for (int f < 5)
			open[f] = palm.InverseTransformPoint(tips[f].Position);
		fingers.shape = .Fist;
		fingers.OnValidate();
		Step(scene);
		bool curled = true;
		for (int f = 1; f < 5; f++)
		{
			let now = palm.InverseTransformPoint(tips[f].Position);
			// Towards the palm (down, for this hand) and back towards the wrist.
			curled &= now.y < -0.005f && now.z < open[f].z - 0.04f;
		}
		ok &= Check(curled, "a fist curls every finger towards the palm");
		let thumbNow = palm.InverseTransformPoint(tips[0].Position);
		ok &= Check(thumbNow.x > open[0].x + 0.01f, "the thumb closes across the palm");
		fingers.shape = .Trigger;
		fingers.OnValidate();
		Step(scene);
		let indexTip = palm.InverseTransformPoint(tips[1].Position), middleTip = palm.InverseTransformPoint(tips[2].Position);
		ok &= Check(indexTip.z > middleTip.z + 0.03f, "the trigger shape leaves the index finger out");
		let before = indexTip.z;
		fingers.trigger = 1;
		Step(scene);
		ok &= Check(palm.InverseTransformPoint(tips[1].Position).z < before - 0.003f, "pulling the trigger squeezes the index finger");
		fingers.trigger = 0;
		fingers.index = 0.9f;
		fingers.OnValidate();
		ok &= Check(fingers.shape == .Custom, "moving a slider makes the shape Custom");
		fingers.shape = .Open;
		fingers.OnValidate();
		fingers.spread = 0;
		Step(scene);
		bool flat = true;
		for (int f < 5)
			flat &= (palm.InverseTransformPoint(tips[f].Position) - open[f]).Length < 0.0005f;
		ok &= Check(flat, "open with no spread is the straight pose again");
		fingers.spread = 1;
		Step(scene);
		ok &= Check(palm.InverseTransformPoint(tips[1].Position).x < open[1].x - 0.003f && palm.InverseTransformPoint(tips[4].Position).x > open[4].x + 0.003f, "spread fans the fingers apart");
		fingers.spread = 0;
		fingers.shape = .Fist;
		fingers.OnValidate();
		fingers.flipCurl = true;
		Step(scene);
		ok &= Check(palm.InverseTransformPoint(tips[2].Position).y > 0.005f, "Flip Curl curls the other way");
		fingers.flipCurl = false;
		// The pose is measured from the remembered straight pose, so a clip bending the fingers does not add to it.
		Step(scene);
		let fist = palm.InverseTransformPoint(tips[2].Position);
		palm.Children[2].LocalRotation = Quaternion.Euler(40, 0, 0);
		Step(scene);
		ok &= Check((palm.InverseTransformPoint(tips[2].Position) - fist).Length < 0.0005f, "a clip under the fingers does not add to the pose");
		fingers.weight = 0;
		Step(scene);
		ok &= Check(Quaternion.Dot(palm.Children[2].LocalRotation, Quaternion.Euler(40, 0, 0)) > 0.99999f, "weight 0 leaves the fingers to the clip");

		// POLYGON characters: a thumb, an index finger, and the other three as one chain named only "finger".
		{
			let mitten = Bone(scene, "Hand_L", root.Transform, .(3, 1, 0));
			var bone = Bone(scene, "thumb_01_l", mitten, .(-0.04f, 0, 0.02f));
			bone = Bone(scene, "thumb_02_l", bone, .(0, 0, 0.03f));
			bone = Bone(scene, "indexFinger_01_l", mitten, .(-0.02f, 0, 0.09f));
			bone = Bone(scene, "indexFinger_02_l", bone, .(0, 0, 0.03f));
			bone = Bone(scene, "finger_01_l", mitten, .(0.02f, 0, 0.09f));
			bone = Bone(scene, "finger_02_l", bone, .(0, 0, 0.03f));
			let pose = mitten.GameObject.AddComponent<HandPose>();
			Step(scene);
			ok &= Check(pose.BoneCount(0) == 2 && pose.BoneCount(1) == 2 && pose.BoneCount(2) == 2 && pose.BoneCount(3) == 0, "a finger named only \"finger\" is the middle finger");
		}

		// Quaternius-style hands taken while an idle clip has them half-curled, with the thumb raised above the
		// knuckles: a left and a right hand, palms down, fingers along +Z. A fist must still close them.
		for (int s < 2)
		{
			// Left-handed space, fingers along +Z, palm down: a right hand's thumb is on the -X side.
			let mirror = s == 0 ? 1.0f : -1.0f;
			let hand = Bone(scene, s == 0 ? "hand_l" : "hand_r", root.Transform, .(4 + s, 1, 0));
			Transform[5] joints = default;
			for (int f < 5)
			{
				var bone = Bone(scene, scope $"{names[f]}_01_{s == 0 ? "l" : "r"}" , hand, f == 0 ? Vector3(mirror * 0.04f, 0, 0.02f) : Vector3(mirror * (0.045f - f * 0.02f), 0, 0.09f));
				bone.LocalRotation = Quaternion.Euler(f == 0 ? -50 : 20, 0, 0);
				for (int j = 2; j <= 3; j++)
				{
					bone = Bone(scene, scope $"{names[f]}_0{j}_{s == 0 ? "l" : "r"}" , bone, .(0, 0, 0.03f));
					bone.LocalRotation = Quaternion.Euler(f == 0 ? 0 : 20, 0, 0);
					if (j == 2)
						joints[f] = bone;
				}
				Bone(scene, scope $"{names[f]}_04_leaf_{s == 0 ? "l" : "r"}" , bone, .(0, 0, 0.025f));
			}
			let pose = hand.GameObject.AddComponent<HandPose>();
			Step(scene);
			// The second joint: the first bone turning towards the palm (down) lowers it. Tips can wrap past it.
			Vector3[5] start = default;
			for (int f < 5)
				start[f] = hand.InverseTransformPoint(joints[f].Position);
			pose.shape = .Fist;
			pose.OnValidate();
			Step(scene);
			bool closed = true;
			for (int f = 1; f < 5; f++)
			{
				let now = hand.InverseTransformPoint(joints[f].Position);
				closed &= now.y < start[f].y - 0.01f;
			}
			ok &= Check(closed, s == 0 ? "a half-curled left hand closes into a fist" : "a half-curled right hand closes into a fist");
		}

		// ---- feet on the ground ----
		let walker = scene.CreateGameObject("Walker");
		walker.Transform.Position = .(10, 1, 0);
		let hips = Bone(scene, "Hips", walker.Transform, .(0, 0.9f, 0));
		Transform[2] feet = default;
		for (int i < 2)
		{
			let thigh = Bone(scene, i == 0 ? "UpperLeg.L" : "UpperLeg.R", hips, .(i == 0 ? -0.15f : 0.15f, 0, 0));
			thigh.LocalRotation = Quaternion.Euler(-12, 0, 0);
			let shin = Bone(scene, i == 0 ? "LowerLeg.L" : "LowerLeg.R", thigh, .(0, -0.42f, 0));
			shin.LocalRotation = Quaternion.Euler(24, 0, 0);
			feet[i] = Bone(scene, i == 0 ? "Foot.L" : "Foot.R", shin, .(0, -0.42f, 0));
		}
		let standing = Vector3[2](feet[0].Position, feet[1].Position);
		// Under the left foot the ground is where the character stands; under the right it is a step lower.
		ShapeDesc slab = default;
		slab.kind = .Box;
		slab.halfExtents = .(0.14f, 0.5f, 2);
		let groundL = scene.CreateGameObject("Ground L");
		groundL.Transform.Position = .(10 - 0.15f, 1 - 0.5f, 0);
		scene.Physics.CreateBody(groundL.Transform, slab, null);
		let groundR = scene.CreateGameObject("Ground R");
		groundR.Transform.Position = .(10 + 0.15f, 1 - 0.5f - 0.2f, 0);
		scene.Physics.CreateBody(groundR.Transform, slab, null);
		let placement = walker.AddComponent<FootPlacement>();
		placement.leftFoot = feet[0];
		placement.rightFoot = feet[1];
		placement.hips = hips;
		placement.tilt = false;
		Step(scene);
		ok &= Check((feet[0].Position - standing[0]).Length < 0.0001f, "feet are left alone until the game plays");
		scene.StartPlay();
		Step(scene, 120);
		ok &= Check(placement.IsGrounded(0) && placement.IsGrounded(1), "ground is found under both feet");
		ok &= Check(Math.Abs(feet[1].Position.y - (standing[1].y - 0.2f)) < 0.005f, "the foot over the lower step goes down to it");
		ok &= Check(Math.Abs(feet[0].Position.y - standing[0].y) < 0.005f, "the foot on level ground stays level");
		ok &= Check(Math.Abs(placement.HipsOffset + 0.2f) < 0.005f && Math.Abs(hips.Position.y - (1.9f - 0.2f)) < 0.005f, "the hips drop so that the lower foot can reach");
		placement.weight = 0;
		Step(scene);
		ok &= Check((feet[1].Position - standing[1]).Length < 0.0005f && Math.Abs(hips.Position.y - 1.9f) < 0.0005f, "weight 0 puts the legs back");
		scene.StopPlay();

		Console.WriteLine(ok ? "ALL PASSED" : "SOME FAILED");
		return ok ? 0 : 1;
	}
}
