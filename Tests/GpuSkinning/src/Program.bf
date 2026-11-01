using System;
using System.IO;
using Tallow;

namespace GpuSkinningTests;

/// GPU skinning (docs/gpu-skinning.md), the parts a machine without a graphics card can check: the box round a bent
/// model worked out from its joints alone (what GPU skinning uses instead of bent vertices) holds the model as the
/// CPU bends it, at every moment of its clip, without being much too big; and the switches. Run `python3 run.py`
/// on a machine with a graphics card for the picture check: the same scene drawn with GPU and with CPU skinning.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	static float Volume(Bounds b) => (b.max.x - b.min.x) * (b.max.y - b.min.y) * (b.max.z - b.min.z);

	public static int Main(String[] args)
	{
		// The Sandbox sample's rigged model, found from where this program is (Tests/GpuSkinning/build/...).
		let exe = scope String();
		Environment.GetExecutableFilePath(exe);
		var root = scope String();
		Path.GetDirectoryPath(exe, root);
		for (int up < 5)
			Path.GetDirectoryPath(scope String(root), root..Clear());
		Assets.ProjectPath.Set(scope $"{root}/Samples/Sandbox/src");
		Check(File.Exists(scope $"{Assets.ProjectPath}/Models/rigged_sample.glb"), "the sample's rigged model is there");

		let scene = scope Scene();
		let go = scene.CreateGameObject("Tentacle");
		let skinned = go.AddComponent<SkinnedMeshRenderer>();
		skinned.model.Set("Models/rigged_sample.glb");
		skinned.clip.Set("Wave");
		skinned.OnValidate();
		Check(skinned.Model != null && skinned.Model.Joints.Count > 1, "the model loads with its skeleton");
		Check(skinned.gpuSkinning && GpuSkinning.Enabled && !GpuSkinning.Available, "GPU skinning is on by default, and not available without a graphics card");

		bool allHeld = true;
		float worst = 0;
		Time.DeltaTime = 0.05f;
		for (int frame < 60)
		{
			skinned.OnFrame();
			let mesh = go.GetComponent<MeshRenderer>()?.ActiveMesh;
			if (mesh == null)
				continue;
			let exact = mesh.Bounds;
			let fromJoints = skinned.BoundsFromJoints();
			let slack = 0.001f;
			let held = fromJoints.min.x <= exact.min.x + slack && fromJoints.min.y <= exact.min.y + slack && fromJoints.min.z <= exact.min.z + slack && fromJoints.max.x >= exact.max.x - slack && fromJoints.max.y >= exact.max.y - slack && fromJoints.max.z >= exact.max.z - slack;
			allHeld &= held;
			worst = Math.Max(worst, Volume(fromJoints) / Math.Max(Volume(exact), 0.000001f));
		}
		Check(!skinned.SkinnedOnGpu, "without a graphics card the CPU bends it");
		Check(allHeld, "the box from the joints holds the bent model at every moment of its clip");
		Check(worst < 3, scope $"and is not much too big (at most {worst:0.00} times the exact box's volume)");
		Console.WriteLine(sFailures == 0 ? "All GPU skinning checks passed." : scope $"{sFailures} GPU skinning check(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
