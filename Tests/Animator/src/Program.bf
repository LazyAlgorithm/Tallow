using System;
using System.Collections;
using System.IO;
using Tallow;

namespace AnimatorTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	const String cFolder = "/tmp/tallow-animator-test";

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

	public static int Main(String[] args)
	{
		Directory.CreateDirectory(cFolder).IgnoreError();
		Assets.ProjectPath.Set(cFolder);
		bool ok = true;

		// ---- clips: keys, scale, saving ----
		let idle = AnimationClip.Create("idle.tanim", "Idle");
		idle.duration = 1;
		idle.loop = true;
		idle.AddTrack("Arm").SetKey(0, .Zero, .Zero, .(1, 1, 1));
		let wave = AnimationClip.Create("wave.tanim", "Wave");
		wave.duration = 1;
		wave.loop = false;
		{
			let arm = wave.AddTrack("Arm");
			arm.SetKey(1, .(0, 2, 0), .(0, 0, 90), .(2, 2, 2));
			arm.SetKey(0, .Zero, .Zero, .(1, 1, 1));
			arm.SetKey(0.5f, .(0, 1, 0), .(0, 0, 45), .(1.5f, 1.5f, 1.5f));
			ok &= Check(arm.keys.Count == 3 && arm.keys[0].time == 0 && arm.keys[1].time == 0.5f && arm.keys[2].time == 1, "keys are kept in time order however they are added");
			arm.SetKey(0.5f, .(0, 1, 0), .(0, 0, 45), .(1.5f, 1.5f, 1.5f));
			ok &= Check(arm.keys.Count == 3, "setting a key at a time that has one replaces it");
			Vector3 position, scale;
			Quaternion rotation;
			arm.Sample(0.25f, out position, out rotation, out scale);
			ok &= Check(Math.Abs(position.y - 0.5f) < 0.001f && Math.Abs(scale.x - 1.25f) < 0.001f, "position and scale are interpolated between keys");
		}
		let run = AnimationClip.Create("run.tanim", "Run");
		run.duration = 0.5f;
		run.AddTrack("Arm").SetKey(0, .(3, 0, 0), .Zero, .(1, 1, 1));
		wave.Save(scope $"{cFolder}/saved.tanim");
		{
			let loaded = AnimationClip.Load("saved.tanim");
			let track = loaded?.FindTrack("Arm");
			ok &= Check(loaded != null && loaded.name == "Wave" && !loaded.loop && track != null && track.keys.Count == 3 && Math.Abs(track.keys[2].scale.x - 2) < 0.001f && Math.Abs(track.keys[2].euler.z - 90) < 0.001f && Math.Abs(track.keys[1].position.y - 1) < 0.001f, "a clip saves and loads again with its keys, rotation and scale");
		}
		File.WriteAllText(scope $"{cFolder}/old.tanim" , "clip Old duration 2 loop 1\ntrack Arm\nkey 0 0 0 0 0 0 0\nkey 1 0 1 0 0 0 30\n").IgnoreError();
		{
			let old = AnimationClip.Load("old.tanim");
			ok &= Check(old != null && old.tracks.Count == 1 && old.tracks[0].keys.Count == 2 && old.tracks[0].keys[1].scale.x == 1, "clips written before scale existed still load");
		}

		// ---- auto keying, as Record and Auto Key do it ----
		{
			let made = AnimationClip.Create("auto.tanim", "Auto");
			made.duration = 1;
			int index;
			let leg = made.AutoKey("Leg", 0.5f, .(0, 1, 0), .(0, 0, 30), .(1, 1, 1), out index);
			ok &= Check(made.tracks.Count == 1 && leg.keys.Count == 2 && index == 1 && leg.keys[0].time == 0 && leg.keys[0].position == .Zero && leg.keys[0].scale.x == 1 && leg.keys[1].position.y == 1, "keying a child the clip did not move adds its row, and a key at the start holding its untouched pose");
			made.AutoKey("Leg", 0.8f, .(0, 2, 0), .Zero, .(1, 1, 1), out index);
			ok &= Check(leg.keys.Count == 3 && index == 2, "further keys on that child add only themselves");
			made.AutoKey("Leg", 0.5f, .(0, 5, 0), .Zero, .(1, 1, 1), out index);
			ok &= Check(leg.keys.Count == 3 && index == 1 && leg.keys[1].position.y == 5, "keying where a key already is replaces it");
			let foot = made.AutoKey("Foot", 0, .(1, 0, 0), .Zero, .(1, 1, 1), out index);
			ok &= Check(foot.keys.Count == 1 && index == 0, "a first key at the start needs no extra key");
			made.AutoKey("Foot", 1.5f, .(2, 0, 0), .Zero, .(1, 1, 1), out index);
			ok &= Check(made.duration == 1.5f, "a key past the end lengthens the clip");
		}

		// ---- a controller, as the Animator window would make it ----
		let controller = scope AnimatorController();
		controller.AddParameter("speed", .Float);
		controller.AddParameter("grounded", .Bool).defaultValue = 1;
		controller.AddParameter("wave", .Trigger);
		controller.AddParameter("lives", .Int).defaultValue = 3;
		controller.AddState("Idle", "idle.tanim", .(100, 100));
		controller.AddState("Run", "run.tanim", .(300, 100)).speed = 2;
		controller.AddState("Wave", "wave.tanim", .(200, 250)).loop = false;
		controller.AddState("Dead", "idle.tanim", .(400, 250));
		let toRun = controller.AddTransition(0, 1);
		controller.AddCondition(toRun, "speed", .Greater, 0.5f);
		toRun.duration = 0.2f;
		let toIdle = controller.AddTransition(1, 0);
		controller.AddCondition(toIdle, "speed", .Less, 0.5f);
		toIdle.duration = 0.2f;
		let toWave = controller.AddTransition(0, 2);
		controller.AddCondition(toWave, "wave", .If);
		toWave.duration = 0;
		let waveDone = controller.AddTransition(2, 0);
		waveDone.hasExitTime = true;
		waveDone.exitTime = 1;
		waveDone.duration = 0;
		let die = controller.AddTransition(-1, 3);
		controller.AddCondition(die, "lives", .Less, 1);
		die.duration = 0;
		controller.AddTransition(0, 3); // no condition and no exit time: never fires
		ok &= Check(!controller.AddCondition(toRun, "nope", .If), "a condition on a parameter that does not exist is refused");
		controller.Save(scope $"{cFolder}/hero.tcontroller");
		{
			let loaded = AnimatorController.Load("hero.tcontroller");
			ok &= Check(loaded != null && loaded.parameters.Count == 4 && loaded.states.Count == 4 && loaded.transitions.Count == 6 && loaded.parameters[1].defaultValue == 1 && loaded.parameters[2].type == .Trigger
				&& loaded.states[1].speed == 2 && !loaded.states[2].loop && loaded.states[2].position.y == 250 && loaded.transitions[0].conditions.Count == 1 && loaded.transitions[0].conditions[0].mode == .Greater
				&& loaded.transitions[3].hasExitTime && loaded.transitions[4].from == -1, "a controller saves and loads again: parameters, states, transitions and conditions");
		}

		// ---- running it ----
		sScene = scope Scene();
		let hero = sScene.CreateGameObject("Hero");
		let arm = sScene.CreateGameObject("Arm");
		arm.Transform.SetParent(hero.Transform, false);
		arm.Transform.LocalPosition = .(0, 1, 0);
		let animator = hero.AddComponent<Animator>();
		animator.controller.Set("hero.tcontroller");
		sScene.StartPlay();
		Step(0.1f);
		ok &= Check(animator.CurrentState == "Idle" && animator.GetBool("grounded") && animator.GetInteger("lives") == 3 && animator.GetFloat("speed") == 0, "the Animator starts in the default state with the parameters' default values");
		Step(1);
		ok &= Check(animator.CurrentState == "Idle" && Math.Abs(arm.Transform.LocalPosition.x) < 0.001f, "a transition with no condition and no exit time never fires");
		animator.SetFloat("speed", 1);
		Step(0.1f);
		ok &= Check(animator.CurrentState == "Run" && animator.IsInTransition && arm.Transform.LocalPosition.x > 0.2f && arm.Transform.LocalPosition.x < 2.8f, scope $"a condition that becomes true starts the transition, and the pose blends across it (arm at {arm.Transform.LocalPosition.x:0.00} of 3)");
		Step(0.3f);
		ok &= Check(!animator.IsInTransition && Math.Abs(arm.Transform.LocalPosition.x - 3) < 0.001f && Math.Abs(arm.Transform.LocalPosition.y - 1) < 0.001f, "and ends in the new state's clip, measured from the rest pose");
		let before = animator.StateTime;
		Step(0.2f);
		ok &= Check(Math.Abs((animator.StateTime - before) - 0.4f) < 0.03f, "a state's speed scales its time");
		animator.SetFloat("speed", 0);
		Step(0.5f);
		ok &= Check(animator.CurrentState == "Idle" && Math.Abs(arm.Transform.LocalPosition.x) < 0.001f, "and back again when the condition reverses");
		animator.SetTrigger("wave");
		Step(0.06f);
		ok &= Check(animator.CurrentState == "Wave" && !animator.GetBool("wave"), "a trigger fires its transition once and clears itself");
		Step(0.45f);
		ok &= Check(animator.CurrentState == "Wave" && Math.Abs(arm.Transform.LocalPosition.y - 2) < 0.15f && arm.Transform.LocalScale.x > 1.4f && arm.Transform.LocalScale.x < 1.6f, scope $"the clip's keys move and scale the child (y {arm.Transform.LocalPosition.y:0.00}, scale {arm.Transform.LocalScale.x:0.00} halfway)");
		Step(0.7f);
		ok &= Check(animator.CurrentState == "Idle" && Math.Abs(arm.Transform.LocalScale.x - 1) < 0.001f, "an exit-time transition waits for the clip to finish, then returns");
		animator.SetInteger("lives", 0);
		Step(0.1f);
		ok &= Check(animator.CurrentState == "Dead", "an Any State transition fires from whatever state is current");
		Step(0.5f);
		ok &= Check(animator.CurrentState == "Dead" && animator.StateTime > 0.4f, "and does not re-enter the state it leads to");
		animator.Play("Run", 0);
		ok &= Check(animator.CurrentState == "Run", "Play jumps straight to a state by name");
		animator.SetFloat("missing", 5);
		ok &= Check(animator.GetFloat("missing") == 0, "setting a parameter that does not exist is ignored");

		// Editing the controller while it runs (the Animator window does this) is picked up without a restart.
		{
			let live = animator.Controller;
			live.AddParameter("extra", .Float).defaultValue = 7;
			Step(0.04f);
			ok &= Check(animator.GetFloat("extra") == 7 && animator.GetInteger("lives") == 0, "a parameter added while playing appears, and existing values are kept");
		}

		// ---- without a controller the Animator still plays clips by name ----
		{
			let plain = sScene.CreateGameObject("Plain");
			let limb = sScene.CreateGameObject("Arm");
			limb.Transform.SetParent(plain.Transform, false);
			let simple = plain.AddComponent<Animator>();
			simple.clips.Set("run.tanim;idle.tanim");
			simple.defaultClip.Set("Run");
			Step(0.1f);
			ok &= Check(simple.CurrentClip == "Run" && simple.CurrentState.IsEmpty && Math.Abs(limb.Transform.LocalPosition.x - 3) < 0.001f, "an Animator with no controller plays clips as before");
			// Scrubbing, as the Animation window does.
			simple.SampleClip(wave, 0.5f);
			ok &= Check(Math.Abs(limb.Transform.LocalPosition.y - 1) < 0.001f && Math.Abs(limb.Transform.LocalScale.x - 1.5f) < 0.001f, "a clip can be sampled at any time for previewing");
		}
		{
			// A chain of bones, each turned 90 degrees about Y by its clip, with an unanimated hand at the end: the bones
			// are posed together and each branch told once, so the hand must still follow and see its version change.
			let turn = AnimationClip.Create("turn.tanim", "Turn");
			turn.duration = 1;
			let root = sScene.CreateGameObject("Chain");
			var parent = root.Transform;
			for (int b < 4)
			{
				let joint = sScene.CreateGameObject(scope $"Link{b}");
				joint.Transform.SetParent(parent, false);
				joint.Transform.LocalPosition = .(0, 0, 1);
				turn.AddTrack(scope $"Link{b}").SetKey(0, .Zero, .(0, 90, 0), .(1, 1, 1));
				parent = joint.Transform;
			}
			let hand = sScene.CreateGameObject("Hand");
			hand.Transform.SetParent(parent, false);
			hand.Transform.LocalPosition = .(0, 0, 1);
			let before = hand.Transform.Position;
			let version = hand.Transform.Version;
			let chain = root.AddComponent<Animator>();
			chain.clips.Set("turn.tanim");
			chain.defaultClip.Set("Turn");
			Step(0.05f);
			// Link0 at (0,0,1) facing +X, so Link1 at (1,0,1) facing -Z, Link2 at (1,0,0) facing -X, Link3 at (0,0,0) facing +Z: hand at (0,0,1).
			let after = hand.Transform.Position;
			ok &= Check(Math.Abs(before.z - 5) < 0.001f && (after - Vector3(0, 0, 1)).Length < 0.01f, scope $"an unanimated child below a posed chain follows it ({after.x:0.00}, {after.y:0.00}, {after.z:0.00})");
			ok &= Check(hand.Transform.Version != version, "and its version changes, as physics expects");
		}
		for (let name in StringView[?]("saved.tanim", "old.tanim", "hero.tcontroller"))
			File.Delete(scope $"{cFolder}/{name}").IgnoreError();
		Directory.Delete(cFolder).IgnoreError();
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
