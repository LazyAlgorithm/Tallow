using System;
using System.Collections;
using System.IO;
using Tallow;

namespace AnimationLayersTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	const String cFolder = "/tmp/tallow-layers-test";
	static Scene sScene;
	static void Step(float seconds)
	{
		int steps = (int)Math.Ceiling(seconds / 0.02f);
		for (int i < steps)
		{
			Time.DeltaTime = 0.02f;
			Time.UnscaledDeltaTime = 0.02f;
			sScene.Update();
		}
	}

	static bool Near(float a, float b, float within = 0.01f) => Math.Abs(a - b) <= within;

	/// A clip that holds one bone at an offset (in position x) the whole time.
	static AnimationClip Hold(StringView file, StringView name, StringView bone, float x, float length = 1, float zDegrees = 0)
	{
		let clip = AnimationClip.Create(file, name);
		clip.duration = length;
		let track = clip.AddTrack(bone);
		track.SetKey(0, .(x, 0, 0), .(0, 0, zDegrees), .(1, 1, 1));
		track.SetKey(length, .(x, 0, 0), .(0, 0, zDegrees), .(1, 1, 1));
		return clip;
	}

	static void AddMotion(AnimatorController.BlendTree tree, StringView clip, float threshold, Vector2 position)
	{
		let m = new AnimatorController.Motion();
		m.clip.Set(clip);
		m.threshold = threshold;
		m.position = position;
		tree.motions.Add(m);
	}

	public static int Main(String[] args)
	{
		Directory.CreateDirectory(cFolder).IgnoreError();
		Assets.ProjectPath.Set(cFolder);
		bool ok = true;

		// Clips: walk and run move the legs (x 1 and 3), a 2D set moves the hips by direction, aim moves the arm,
		// recoil adds a kick, the hips' "lean" adds on.
		Hold("walk.tanim", "Walk", "Legs", 1);
		Hold("run.tanim", "Run", "Legs", 3, 0.5f);
		Hold("still.tanim", "Still", "Legs", 0);
		Hold("forward.tanim", "Forward", "Hips", 0).AddTrack("Hips");
		AnimationClip.Load("forward.tanim").FindTrack("Hips").SetKey(0, .(0, 0, 2), .Zero, .One);
		AnimationClip.Load("forward.tanim").FindTrack("Hips").SetKey(1, .(0, 0, 2), .Zero, .One);
		let left = AnimationClip.Create("left.tanim", "Left");
		left.duration = 1;
		left.AddTrack("Hips").SetKey(0, .(-2, 0, 0), .Zero, .One);
		left.FindTrack("Hips").SetKey(1, .(-2, 0, 0), .Zero, .One);
		let right = AnimationClip.Create("right.tanim", "Right");
		right.duration = 1;
		right.AddTrack("Hips").SetKey(0, .(2, 0, 0), .Zero, .One);
		right.FindTrack("Hips").SetKey(1, .(2, 0, 0), .Zero, .One);
		let centre = AnimationClip.Create("centre.tanim", "Centre");
		centre.duration = 1;
		centre.AddTrack("Hips").SetKey(0, .Zero, .Zero, .One);
		centre.FindTrack("Hips").SetKey(1, .Zero, .Zero, .One);
		// The whole body waves its arm; the upper-body layer aims it instead.
		let wave = AnimationClip.Create("wave.tanim", "Wave");
		wave.duration = 1;
		wave.AddTrack("Arm").SetKey(0, .(5, 0, 0), .Zero, .One);
		wave.FindTrack("Arm").SetKey(1, .(5, 0, 0), .Zero, .One);
		wave.AddTrack("Legs").SetKey(0, .(1, 0, 0), .Zero, .One);
		wave.FindTrack("Legs").SetKey(1, .(1, 0, 0), .Zero, .One);
		Hold("aim.tanim", "Aim", "Arm", 9);
		Hold("aimlegs.tanim", "AimLegs", "Legs", 7);
		// Recoil: from rest to a kick of 0.5 in x and 30 degrees, over its length; its first frame is rest.
		let recoil = AnimationClip.Create("recoil.tanim", "Recoil");
		recoil.duration = 1;
		recoil.loop = false;
		recoil.AddTrack("Arm").SetKey(0, .Zero, .Zero, .One);
		recoil.FindTrack("Arm").SetKey(0.5f, .(0.5f, 0, 0), .(0, 0, 30), .One);
		recoil.FindTrack("Arm").SetKey(1, .(0.5f, 0, 0), .(0, 0, 30), .One);

		// ---- blend tree weights ----
		{
			let tree = scope AnimatorController.BlendTree();
			for (let t in float[?](0, 1, 3))
			{
				let m = new AnimatorController.Motion();
				m.threshold = t;
				tree.motions.Add(m);
			}
			List<float> w = scope .();
			tree.Weights(2, 0, w);
			ok &= Check(Near(w[0], 0) && Near(w[1], 0.5f) && Near(w[2], 0.5f), "1D: halfway between two thresholds is half of each");
			tree.Weights(-5, 0, w);
			ok &= Check(Near(w[0], 1), "1D: below the lowest threshold is the lowest clip alone");
			tree.Weights(1, 0, w);
			ok &= Check(Near(w[1], 1) && Near(w[0] + w[2], 0), "1D: on a threshold is that clip alone");
			let plane = scope AnimatorController.BlendTree();
			plane.type = .Freeform2D;
			for (let p in Vector2[?](.(0, 0), .(0, 1), .(-1, 0), .(1, 0)))
			{
				let m = new AnimatorController.Motion();
				m.position = p;
				plane.motions.Add(m);
			}
			plane.Weights(0, 1, w);
			ok &= Check(Near(w[1], 1), "2D: on a clip's place is that clip alone");
			plane.Weights(0.5f, 0.5f, w);
			float sum = 0;
			for (let x in w)
				sum += x;
			ok &= Check(Near(sum, 1) && w[1] > 0.2f && w[3] > 0.2f && Near(w[2], 0), scope $"2D: between forward and right is mostly those two, and the weights add to 1 ({w[0]:0.00} {w[1]:0.00} {w[2]:0.00} {w[3]:0.00})");
		}

		// ---- a controller with blend trees and layers, saved and read back ----
		let controller = scope AnimatorController();
		controller.AddParameter("speed", .Float);
		controller.AddParameter("moveX", .Float);
		controller.AddParameter("moveY", .Float);
		controller.AddParameter("aiming", .Bool);
		controller.AddParameter("fire", .Trigger);
		let locomotion = controller.AddState("Locomotion", "", .(100, 100));
		locomotion.blend = new .();
		locomotion.blend.parameterX = 0;
		AddMotion(locomotion.blend, "still.tanim", 0, .Zero);
		AddMotion(locomotion.blend, "walk.tanim", 1, .Zero);
		AddMotion(locomotion.blend, "run.tanim", 3, .Zero);
		let strafe = controller.AddState("Strafe", "", .(100, 200));
		strafe.blend = new .();
		strafe.blend.type = .Freeform2D;
		strafe.blend.parameterX = 1;
		strafe.blend.parameterY = 2;
		AddMotion(strafe.blend, "centre.tanim", 0, .(0, 0));
		AddMotion(strafe.blend, "forward.tanim", 0, .(0, 1));
		AddMotion(strafe.blend, "left.tanim", 0, .(-1, 0));
		AddMotion(strafe.blend, "right.tanim", 0, .(1, 0));
		// Upper body: idle (nothing) or aiming the arm; masked to the arm, so the aim clip's legs do nothing.
		let upper = controller.AddLayer("Upper Body");
		upper.mask.Set("Spine");
		let upperIdle = controller.AddState("Arms Free", "", .(100, 100));
		upperIdle.layer = 1;
		let aimState = controller.AddState("Aim", "aim.tanim", .(300, 100));
		aimState.layer = 1;
		Hold("aim.tanim", "Aim", "Arm", 9);
		AnimationClip.Load("aim.tanim").AddTrack("Legs").SetKey(0, .(7, 0, 0), .Zero, .One);
		let toAim = controller.AddTransition(controller.FindState("Arms Free"), controller.FindState("Aim"));
		controller.AddCondition(toAim, "aiming", .If);
		toAim.duration = 0;
		let fromAim = controller.AddTransition(controller.FindState("Aim"), controller.FindState("Arms Free"));
		controller.AddCondition(fromAim, "aiming", .IfNot);
		fromAim.duration = 0;
		// Recoil: additive, played on a trigger from Any State in its layer.
		let kick = controller.AddLayer("Recoil");
		kick.blending = .Additive;
		let calm = controller.AddState("Calm", "", .(100, 100));
		calm.layer = 2;
		let kicked = controller.AddState("Kick", "recoil.tanim", .(300, 100));
		kicked.layer = 2;
		kicked.loop = false;
		let toKick = controller.AddTransition(-1, controller.FindState("Kick"));
		toKick.layer = 2;
		controller.AddCondition(toKick, "fire", .If);
		toKick.duration = 0;
		controller.Save(scope $"{cFolder}/soldier.tcontroller");
		let loaded = AnimatorController.Load("soldier.tcontroller");
		ok &= Check(loaded != null && loaded.layers.Count == 3 && loaded.layers[1].mask == "Spine" && loaded.layers[2].blending == .Additive && loaded.states[0].blend != null && loaded.states[0].blend.motions.Count == 3
			&& loaded.states[1].blend.type == .Freeform2D && loaded.states[1].blend.parameterY == 2 && loaded.states[3].layer == 1 && loaded.transitions[2].layer == 2 && loaded.UsesLayers,
			"layers, masks, blending and blend trees save and load again");
		// A controller from before layers is all Base Layer, and does not use the layered path.
		File.WriteAllText(scope $"{cFolder}/old.tcontroller" , "controller 1\nstate \"Idle\" \"walk.tanim\" 1 1 0 0\ndefault 0\n").IgnoreError();
		let old = AnimatorController.Load("old.tcontroller");
		ok &= Check(old != null && old.layers.Count == 1 && old.states[0].layer == 0 && !old.UsesLayers, "a controller from before layers loads as one Base Layer");

		// ---- running it ----
		sScene = scope Scene();
		let soldier = sScene.CreateGameObject("Soldier");
		let hips = sScene.CreateGameObject("Hips", soldier.Transform).Transform;
		let legs = sScene.CreateGameObject("Legs", hips).Transform;
		let spine = sScene.CreateGameObject("Spine", hips).Transform;
		let arm = sScene.CreateGameObject("Arm", spine).Transform;
		let animator = soldier.AddComponent<Animator>();
		animator.controller.Set("soldier.tcontroller");
		sScene.StartPlay();
		Step(0.1f);
		ok &= Check(animator.CurrentState == "Locomotion" && animator.StateIndexOn(1) == loaded.FindState("Arms Free") && animator.StateIndexOn(2) == loaded.FindState("Calm"), "each layer starts in its own first state");
		ok &= Check(Near(legs.LocalPosition.x, 0), "speed 0 is the standing clip");
		animator.SetFloat("speed", 2);
		Step(0.1f);
		ok &= Check(Near(legs.LocalPosition.x, 2), scope $"speed 2 is half walk, half run ({legs.LocalPosition.x:0.00})");
		animator.SetFloat("speed", 3);
		Step(0.1f);
		ok &= Check(Near(legs.LocalPosition.x, 3), "speed 3 is the run alone");
		// Blend tree clips keep in step: walk (1 s) and run (0.5 s) at half each make a state 0.75 s long.
		animator.SetFloat("speed", 2);
		Step(0.02f);
		let length = animator.[Friend]LayeredLength(0);
		ok &= Check(Near(length, 0.75f, 0.001f), scope $"a blend tree is as long as its clips by their weights ({length:0.000} s)");

		// ---- the upper-body layer, masked ----
		animator.SetBool("aiming", true);
		Step(0.1f);
		ok &= Check(animator.StateIndexOn(1) == loaded.FindState("Aim") && Near(arm.LocalPosition.x, 9), scope $"the upper-body layer aims the arm ({arm.LocalPosition.x:0.00})");
		ok &= Check(Near(legs.LocalPosition.x, 2), scope $"and its mask keeps its clip off the legs, which still run ({legs.LocalPosition.x:0.00})");
		animator.SetLayerWeight("Upper Body", 0.5f);
		Step(0.04f);
		ok &= Check(Near(arm.LocalPosition.x, 4.5f) && Near(animator.GetLayerWeight(1), 0.5f), scope $"at weight one half the arm is half way ({arm.LocalPosition.x:0.00})");
		animator.SetLayerWeight("Upper Body", 1);
		animator.SetBool("aiming", false);
		Step(0.1f);
		ok &= Check(Near(arm.LocalPosition.x, 0), "back to arms free: the arm is the Base Layer's again");

		// ---- the additive layer ----
		animator.SetTrigger("fire");
		Step(0.5f);
		let kickedX = arm.LocalPosition.x;
		let kickedAngle = arm.LocalRotation.EulerAngles.z;
		ok &= Check(Near(kickedX, 0.5f, 0.03f) && Near(kickedAngle, 30, 1.5f), scope $"an additive recoil adds its kick on top ({kickedX:0.00}, {kickedAngle:0.0} degrees)");
		animator.SetBool("aiming", true);
		Step(0.1f);
		ok &= Check(Near(arm.LocalPosition.x, 9.5f, 0.05f), scope $"and adds it to the aim as well ({arm.LocalPosition.x:0.00} = 9 + 0.5)");
		ok &= Check(!animator.GetBool("fire"), "the trigger that started it is used up");

		// ---- 2D, and changing state by name ----
		animator.SetBool("aiming", false);
		animator.CrossFade("Strafe", 0);
		animator.SetFloat("moveX", 1);
		animator.SetFloat("moveY", 0);
		Step(0.1f);
		ok &= Check(animator.CurrentState == "Strafe" && Near(hips.LocalPosition.x, 2) && Near(hips.LocalPosition.z, 0), scope $"a 2D blend tree places the hips by direction: right ({hips.LocalPosition.x:0.00}, {hips.LocalPosition.z:0.00})");
		animator.SetFloat("moveX", 0);
		animator.SetFloat("moveY", 1);
		Step(0.1f);
		ok &= Check(Near(hips.LocalPosition.x, 0) && Near(hips.LocalPosition.z, 2), scope $"forward ({hips.LocalPosition.x:0.00}, {hips.LocalPosition.z:0.00})");
		animator.SetFloat("moveX", 0.5f);
		animator.SetFloat("moveY", 0.5f);
		Step(0.1f);
		ok &= Check(hips.LocalPosition.x > 0.3f && hips.LocalPosition.z > 0.3f, scope $"and between them, a mix ({hips.LocalPosition.x:0.00}, {hips.LocalPosition.z:0.00})");

		sScene.StopPlay();
		Console.WriteLine(ok ? "ALL PASSED" : "SOME FAILED");
		return ok ? 0 : 1;
	}
}
