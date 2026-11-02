using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --rigger-test: the rigger in the editor, from start to a rigged object (docs/rigging.md). Rigs the Sandbox's
/// "Rig Test Person", "Rig Test Dog" and "Rig Test Pug" (CC0 models by Quaternius), checks the bones, weights, painting, undo and posing, writes the rigged
/// models (to a scratch folder, not the project's) and gives the person its rigged model. Prints "RIG TEST PASSED".
extension EditorApp
{
	void RunRiggerTest()
	{
		var failures = 0;
		void Check(bool ok, StringView what)
		{
			if (!ok)
			{
				failures++;
				Log.Error(scope $"RIG TEST: {what}");
			}
		}
		for (let name in StringView[3]("Rig Test Person", "Rig Test Dog", "Rig Test Pug"))
		{
			let target = mScene.Find(name);
			Check(target != null, scope $"the scene has '{name}'");
			if (target == null)
				continue;
			let person = name.Contains("Person");
			StartRig(target);
			Check(mRig != null, scope $"rigging starts on {name}");
			if (mRig == null)
				continue;
			// A fresh rig each run (not one saved by an earlier run).
			mRig.template = person ? .Humanoid : .Quadruped;
			ClearAndDeleteItems!(mRig.bones);
			mRig.weights.Clear();
			RigTemplates.GuessMarkers(mRig);
			RigTemplates.CentreMarkers(mRig, mRigRays);
			RigTemplates.Build(mRig, mRigRays);
			mRigPainter.RefreshMirror();
			Check(RenderView.HiddenObjects.Contains(target.Id), "the model's own renderer is hidden while rigging");
			Check(mRig.bones.Count == (person ? 65 : 0) || (!person && mRig.FindBone("Tail1") >= 0), scope $"{name}'s skeleton ({mRig.bones.Count} bones)");
			MakeRigWeights();
			Check(mRig.HasWeights, "weights are made");
			// Every vertex's weights add up to 1.
			var worst = 0.0f;
			for (int v < mRig.VertexCount)
			{
				var sum = 0.0f;
				for (int b < mRig.bones.Count)
					sum += mRig.Weight(v, b);
				worst = Math.Max(worst, Math.Abs(sum - 1));
			}
			Check(worst < 1e-3f, scope $"weights add up to 1 (worst {worst})");
			// A paint dab, undone.
			mRigBone = (int32)Math.Max(mRig.FindBone(person ? "LeftForeArm" : "Tail1"), 0);
			let before = scope List<float>(mRig.weights);
			PushRigUndo();
			UpdateRigShown();
			// On the surface nearest the bone's joint (a joint is inside the body, maybe farther than the brush reaches).
			var nearest = 0;
			for (int v < mRig.VertexCount)
			{
				if ((mRig.positions[v] - mRig.bones[mRigBone].head).LengthSquared < (mRig.positions[nearest] - mRig.bones[mRigBone].head).LengthSquared)
					nearest = v;
			}
			mRigPainter.Dab(.Set, mRigBone, mRig.positions[nearest], mRig.bounds.Size.y * 0.1f, 1, 1, true, mRigShown);
			var changed = false;
			for (int i < before.Count)
				changed |= before[i] != mRig.weights[i];
			Check(changed, scope $"painting changes {name}'s weights");
			RigUndo(false);
			var same = before.Count == mRig.weights.Count;
			for (int i < before.Count)
				same &= before[i] == mRig.weights[i];
			Check(same, "undo puts the weights back");
			// A pose bends the model.
			mRig.pose[mRigBone] = Quaternion.AngleAxis(60, mRig.Right);
			UpdateRigShown();
			var moved = false;
			for (int v < mRig.VertexCount)
				moved |= (mRigShown[v] - mRig.positions[v]).Length > 1e-3f;
			Check(moved, "posing a bone moves the model");
			mRig.ResetPose();
			// Written to a scratch folder.
			let scratch = Path.InternalCombine(.. scope .(), Path.GetTempPath(.. scope .()), "tallow-rig-test");
			Directory.CreateDirectory(scratch).IgnoreError();
			let rigged = Path.InternalCombine(.. scope .(), scratch, scope $"{name}_Rigged.glb");
			mRiggedPath.Set(rigged);
			mRigPath.Set(Path.InternalCombine(.. scope .(), scratch, scope $"{name}.trig"));
			Check(ExportRig(), "the rigged model is written");
			let model = SkinnedModel.Load(rigged);
			Check(model != null && model.Joints.Count == mRig.bones.Count, "the rigged model loads with every bone");
			if (person)
			{
				UseRigged(target);
				let skinned = target.GetComponent<SkinnedMeshRenderer>();
				Check(skinned != null && skinned.model == rigged, "the object plays the rigged model");
				Check(skinned != null && skinned.exposeBones && skinned.BoneCount == mRig.bones.Count && skinned.Bone("Hips") != null && skinned.Bone("Hips").Parent != null,
scope $"its bones are objects under it ({(skinned != null ? skinned.BoneCount : 0)} of {mRig.bones.Count})");
				// Hand Posing works on it: a fist curls the fingers.
				let animator = target.GetComponent<Animator>();
				Check(animator != null, "it has an Animator");
				let hand = skinned?.Bone("LeftHand");
				let tipBone = skinned?.Bone("LeftHandIndex4");
				if (animator != null && hand != null && tipBone != null)
				{
					let tipBefore = tipBone.Position;
					let middleJoint = skinned.Bone("LeftHandIndex3");
					let middleBefore = middleJoint.Position;
					let pose = HandPoseOn(animator, hand, true);
					Check(pose != null && pose.BoneCount(1) >= 3 && pose.BoneCount(4) >= 3, scope $"Hand Posing finds the fingers ({(pose != null ? pose.BoneCount(1) : 0)} index bones)");
					if (pose != null)
					{
						pose.shape = .Fist;
						pose.weight = 1;
						pose.blendTime = 0;
						pose.OnValidate();
						for (int i < 3)
							IKSystem.Solve(mScene);
						let tipMoved = (tipBone.Position - tipBefore).Length;
						let handSize = (tipBefore - hand.Position).Length;
						Check(tipMoved > 0.3f * handSize, scope $"a fist curls the first finger ({tipMoved:0.000} of a {handSize:0.000} hand)");
						// It curls towards the palm (down, for a hand held out palm down).
						Check(middleJoint.Position.y < middleBefore.y - 0.15f * handSize, scope $"towards the palm ({middleJoint.Position.y - middleBefore.y:0.000})");
					}
				}
			}
			StopRig();
			Check(!RenderView.HiddenObjects.Contains(target.Id), "the model is drawn again after rigging");
			Check(File.Exists(mRigPath), "the rig is saved when rigging stops");
		}
		if (failures == 0)
			Log.Info("RIG TEST PASSED");
		else
			Log.Error(scope $"RIG TEST FAILED ({failures})");
	}
}
