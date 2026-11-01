using System;
using System.Collections;
using System.IO;
using Tallow;

namespace RiggingTests;

/// The rigger (docs/rigging.md), without a window, on two models made here from tubes: a person in a T-pose and a
/// dog. Checks the markers' first guesses, the skeletons built from them (Mixamo's names for the person, not a
/// humanoid for the dog), automatic weights (each limb moved by its own bones, a side of the body not moved by the arm
/// beside it, seams kept together, at most four bones a vertex, the same every time), posing, the weight brush and
/// mirroring, the .trig file and the rigged .glb as a Skinned Mesh Renderer loads it.
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

	/// A closed tube from a to b (rings of `sides` vertices, `rings` along it), into a mesh.
	static void Tube(Mesh mesh, Vector3 a, Vector3 b, float radius, int rings = 8, int sides = 10)
	{
		let axis = (b - a).Normalized;
		var side = Vector3.Cross(axis, .(0, 1, 0));
		if (side.LengthSquared < 0.01f)
			side = Vector3.Cross(axis, .(1, 0, 0));
		side = side.Normalized;
		let other = Vector3.Cross(axis, side);
		let first = (uint32)mesh.Vertices.Count;
		for (int r <= rings)
		{
			let centre = Vector3.Lerp(a, b, (float)r / rings);
			for (int s < sides)
			{
				let angle = Math.PI_f * 2 * s / sides;
				let n = side * Math.Cos(angle) + other * Math.Sin(angle);
				mesh.AddVertex(centre + n * radius, n, .White, .((float)s / sides, (float)r / rings));
			}
		}
		for (int r < rings)
		{
			for (int s < sides)
			{
				let i0 = first + (uint32)(r * sides + s), i1 = first + (uint32)(r * sides + (s + 1) % sides);
				let j0 = i0 + (uint32)sides, j1 = i1 + (uint32)sides;
				// Wound anticlockwise seen from outside, so the faces point out.
				mesh.Indices.AddRange(uint32[?](i0, i1, j0, i1, j1, j0));
			}
		}
		// The ends closed with a fan, on vertices of their own facing along the tube (flat, not smeared round the rim).
		for (int end < 2)
		{
			let centre = end == 0 ? a : b;
			let normal = end == 0 ? -axis : axis;
			let middle = mesh.AddVertex(centre, normal, .White);
			let rim = (uint32)mesh.Vertices.Count;
			for (int s < sides)
			{
				let angle = Math.PI_f * 2 * s / sides;
				mesh.AddVertex(centre + (side * Math.Cos(angle) + other * Math.Sin(angle)) * radius, normal, .White);
			}
			for (int s < sides)
			{
				let k0 = rim + (uint32)s, k1 = rim + (uint32)((s + 1) % sides);
				if (end == 0)
					mesh.Indices.AddRange(uint32[?](middle, k1, k0));
				else
					mesh.Indices.AddRange(uint32[?](middle, k0, k1));
			}
		}
	}

	/// A person 1.8 tall in a T-pose, facing -Z, standing on y = 0: torso, head, arms, legs and feet.
	static void MakePerson(StringView path)
	{
		let mesh = scope Mesh();
		Tube(mesh, .(0, 0.86f, 0), .(0, 1.5f, 0), 0.16f, 12, 14);
		Tube(mesh, .(0, 1.5f, 0), .(0, 1.8f, 0), 0.1f, 8, 12);
		for (let side in float[?](-1, 1))
		{
			Tube(mesh, .(side * 0.16f, 1.42f, 0), .(side * 0.86f, 1.42f, 0), 0.045f, 16);
			Tube(mesh, .(side * 0.1f, 0.9f, 0), .(side * 0.1f, 0.05f, 0), 0.065f, 16);
			Tube(mesh, .(side * 0.1f, 0.04f, 0.03f), .(side * 0.1f, 0.04f, -0.16f), 0.04f, 4);
		}
		GlbWriter.Write(path, Span<Mesh>(&mesh, 1), StringView[?]("Skin"));
	}

	/// A dog 1.2 long, facing -Z: body, neck, head, four legs, a tail and two ears.
	static void MakeDog(StringView path)
	{
		let mesh = scope Mesh();
		Tube(mesh, .(0, 0.5f, 0.35f), .(0, 0.52f, -0.35f), 0.13f, 12, 12);
		Tube(mesh, .(0, 0.55f, -0.35f), .(0, 0.72f, -0.48f), 0.07f, 6);
		Tube(mesh, .(0, 0.74f, -0.45f), .(0, 0.7f, -0.68f), 0.07f, 6);
		Tube(mesh, .(0, 0.53f, 0.36f), .(0, 0.62f, 0.75f), 0.025f, 12, 8);
		for (let side in float[?](-1, 1))
		{
			Tube(mesh, .(side * 0.08f, 0.45f, -0.3f), .(side * 0.08f, 0.02f, -0.3f), 0.035f, 10, 8);
			// A dog's back leg: the thigh down and forward to the knee, the shin down and back to the hock, then
			// nearly straight down to the paw, which points forward.
			Tube(mesh, .(side * 0.08f, 0.47f, 0.3f), .(side * 0.08f, 0.29f, 0.215f), 0.04f, 6, 8);
			Tube(mesh, .(side * 0.08f, 0.31f, 0.215f), .(side * 0.08f, 0.13f, 0.365f), 0.035f, 6, 8);
			Tube(mesh, .(side * 0.08f, 0.15f, 0.365f), .(side * 0.08f, 0.03f, 0.345f), 0.03f, 4, 8);
			Tube(mesh, .(side * 0.08f, 0.025f, 0.36f), .(side * 0.08f, 0.025f, 0.29f), 0.025f, 3, 8);
			Tube(mesh, .(side * 0.04f, 0.8f, -0.48f), .(side * 0.06f, 0.92f, -0.46f), 0.015f, 4, 6);
		}
		GlbWriter.Write(path, Span<Mesh>(&mesh, 1), StringView[?]("Fur"));
	}

	static int NearestVertex(Rig rig, Vector3 point)
	{
		var best = 0;
		for (int v < rig.positions.Count)
		{
			if ((rig.positions[v] - point).LengthSquared < (rig.positions[best] - point).LengthSquared)
				best = v;
		}
		return best;
	}

	static float WeightAt(Rig rig, Vector3 point, StringView bone) => rig.Weight(NearestVertex(rig, point), rig.FindBone(bone));

	static bool Near(Vector3 a, Vector3 b, float within) => (a - b).Length <= within;

	static void Person(StringView folder)
	{
		MakePerson(scope $"{folder}/Models/Person.glb");
		let rig = scope Rig();
		let problem = scope String();
		Check(rig.LoadSource("Models/Person.glb", problem) && rig.VertexCount > 500, scope $"a still model reads ({rig.VertexCount} vertices) {problem}");
		Check(Math.Abs(rig.bounds.max.y - 1.8f) < 0.01f && Math.Abs(rig.bounds.min.y - 0) < 0.01f, "in the engine's space, as tall as it was made");
		// The test model itself is right: every face points the way its normals do (all one way round in the rig).
		{
			let triangles = scope List<uint32>();
			rig.Triangles(triangles);
			var agree = 0;
			for (int t = 0; t + 2 < triangles.Count; t += 3)
			{
				let p0 = rig.positions[triangles[t]], p1 = rig.positions[triangles[t + 1]], p2 = rig.positions[triangles[t + 2]];
				let n = rig.normals[triangles[t]] + rig.normals[triangles[t + 1]] + rig.normals[triangles[t + 2]];
				if (Vector3.Dot(Vector3.Cross(p1 - p0, p2 - p0), n) > 0)
					agree++;
			}
			let count = triangles.Count / 3;
			Check(agree == 0 || agree == count, scope $"the model's faces all point the way of their normals ({agree} of {count})");
		}
		rig.template = .Humanoid;
		RigTemplates.GuessMarkers(rig);
		Check(rig.facing == Vector3(0, 0, -1), scope $"it faces -Z, from its toes ({rig.facing})");
		Check(rig.Right.x < -0.9f, "so its right hand is towards -X");
		let rays = scope RigRays(rig.positions, rig.Triangles(.. scope .()));
		RigTemplates.CentreMarkers(rig, rays);
		Vector3 Marker(StringView name) => rig.markers[rig.FindMarker(name)].position;
		Check(Near(Marker("Chin"), .(0, 1.557f, 0), 0.05f), scope $"the chin is guessed ({Marker("Chin")})");
		Check(Near(Marker("Groin"), .(0, 0.864f, 0), 0.06f), scope $"the groin ({Marker("Groin")})");
		Check(Near(Marker("Left Wrist"), .(0.74f, 1.42f, 0), 0.08f) && Near(Marker("Right Wrist"), .(-0.74f, 1.42f, 0), 0.08f), scope $"the wrists ({Marker("Left Wrist")}, {Marker("Right Wrist")})");
		Check(Near(Marker("Left Elbow"), .(0.45f, 1.42f, 0), 0.12f), scope $"the elbows ({Marker("Left Elbow")})");
		Check(Near(Marker("Left Knee"), .(0.1f, 0.5f, 0), 0.06f) && Near(Marker("Right Knee"), .(-0.1f, 0.5f, 0), 0.06f), scope $"the knees ({Marker("Left Knee")})");
		Check(Math.Abs(RigTemplates.CentreFromFront(rig, rays, .(0.5f, 1.42f, -0.3f)).z) < 0.01f, "a marker put down from the front goes to the middle of the arm");

		RigTemplates.Build(rig, rays);
		Check(rig.BoneCount == 65, scope $"Mixamo's 65 bones with all the fingers ({rig.BoneCount})");
		var names = true;
		for (let name in StringView[?]("Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "HeadTop_End", "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand", "LeftHandIndex1", "LeftHandThumb4",
			"RightUpLeg", "RightLeg", "RightFoot", "RightToeBase", "RightToe_End"))
			names &= rig.FindBone(name) >= 0;
		Check(names, "with Mixamo's names");
		var parentsFirst = true;
		for (int b < rig.BoneCount)
			parentsFirst &= rig.bones[b].parent < b;
		Check(parentsFirst && rig.bones[0].name == "Hips", "the hips first, every parent before its children");
		Check(Near(rig.bones[rig.FindBone("LeftForeArm")].head, Marker("Left Elbow"), 0.001f) && Near(rig.bones[rig.FindBone("LeftLeg")].head, Marker("Left Knee"), 0.001f), "joints are where the markers are");
		Check(rig.bones[rig.FindBone("LeftToeBase")].head.z < rig.bones[rig.FindBone("LeftFoot")].head.z, "toes point the way it faces");
		rig.settings.fingers = 0;
		RigTemplates.Build(rig, rays);
		Check(rig.BoneCount == 25 && rig.FindBone("LeftHandIndex1") < 0, scope $"without fingers, 25 bones ({rig.BoneCount})");
		rig.settings.fingers = 2;
		RigTemplates.Build(rig, rays);
		Check(rig.FindBone("LeftHandThumb1") >= 0 && rig.FindBone("LeftHandIndex1") >= 0 && rig.FindBone("LeftHandMiddle1") < 0, "with a thumb and a mitten");
		rig.settings.fingers = 5;
		RigTemplates.Build(rig, rays);

		let started = DateTime.Now;
		Check(AutoWeights.Make(rig) && rig.HasWeights, scope $"weights are made ({(DateTime.Now - started).TotalSeconds:0.00} s)");
		var sums = true, four = true;
		for (int v < rig.VertexCount)
		{
			var sum = 0.0f;
			var count = 0;
			for (int b < rig.BoneCount)
			{
				sum += rig.Weight(v, b);
				count += rig.Weight(v, b) > 0 ? 1 : 0;
			}
			sums &= Math.Abs(sum - 1) < 0.001f;
			four &= count <= 4;
		}
		Check(sums && four, "every vertex's weights add up to 1, from at most four bones");
		var endsUnused = true;
		for (int b < rig.BoneCount)
		{
			if (!rig.bones[b].deform)
			{
				for (int v < rig.VertexCount)
					endsUnused &= rig.Weight(v, b) == 0;
			}
		}
		Check(endsUnused, "end joints move nothing");
		let upperArm = WeightAt(rig, .(0.32f, 1.465f, 0), "LeftArm");
		let forearm = WeightAt(rig, .(0.62f, 1.465f, 0), "LeftForeArm");
		let thigh = WeightAt(rig, .(0.1f, 0.72f, -0.065f), "LeftUpLeg");
		let shin = WeightAt(rig, .(0.1f, 0.25f, -0.065f), "LeftLeg");
		Check(upperArm > 0.7f && forearm > 0.7f && thigh > 0.6f && shin > 0.7f, scope $"each limb is moved by its own bone (upper arm {upperArm:0.00}, forearm {forearm:0.00}, thigh {thigh:0.00}, shin {shin:0.00})");
		Check(WeightAt(rig, .(-0.62f, 1.465f, 0), "LeftForeArm") == 0 && WeightAt(rig, .(-0.1f, 0.25f, -0.065f), "LeftLeg") == 0, "and not by the other side's");
		let side = WeightAt(rig, .(0.16f, 1.15f, 0), "LeftArm") + WeightAt(rig, .(0.16f, 1.15f, 0), "LeftForeArm");
		Check(side < 0.1f, scope $"the side of the body below the arm is not moved by it ({side:0.00})");
		let elbowMix = WeightAt(rig, .(0.45f, 1.465f, 0), "LeftArm");
		Check(elbowMix > 0.15f && elbowMix < 0.85f, scope $"weights blend across the elbow ({elbowMix:0.00} upper arm)");
		let headWeight = WeightAt(rig, .(0, 1.75f, -0.1f), "Head");
		Check(headWeight > 0.8f, scope $"the head is the head's ({headWeight:0.00})");

		// The seam where a tube's texture wraps round: vertices in the same place, the same weights.
		var seams = true;
		let placeOf = scope List<int32>();
		let places = scope List<Vector3>();
		AutoWeights.Weld(rig, placeOf, places);
		let firstAt = scope Dictionary<int32, int>();
		for (int v < rig.VertexCount)
		{
			if (firstAt.TryGetValue(placeOf[v], let other))
			{
				for (int b < rig.BoneCount)
					seams &= rig.Weight(v, b) == rig.Weight(other, b);
			}
			else
				firstAt[placeOf[v]] = v;
		}
		Check(seams && places.Count < rig.VertexCount, "vertices in the same place get the same weights (seams hold)");
		let again = scope List<float>(rig.weights);
		AutoWeights.Make(rig);
		var same = true;
		for (int i < again.Count)
			same &= again[i] == rig.weights[i];
		Check(same, "weights are the same every time");

		// Posing: the forearm turned up, the hand follows and the elbow bends.
		rig.ResetPose();
		rig.pose[rig.FindBone("LeftForeArm")] = Quaternion.AngleAxis(90, .(0, 0, 1));
		let posed = scope List<Vector3>();
		let posedNormals = scope List<Vector3>();
		rig.Posed(posed, posedNormals);
		let hand = NearestVertex(rig, .(0.84f, 1.465f, 0));
		let shoulder = NearestVertex(rig, .(0.25f, 1.465f, 0));
		Check(posed[hand].y > 1.7f && Near(posed[shoulder], rig.positions[shoulder], 0.01f), scope $"posing the forearm moves the hand ({posed[hand]}) and leaves the upper arm");
		rig.ResetPose();

		// The weight brush.
		let painter = scope WeightPainter(rig);
		Check(painter.Symmetry > 0.95f, scope $"the model's two sides are found ({painter.Symmetry * 100:0}% of it mirrored)");
		let spot = NearestVertex(rig, .(0.32f, 1.465f, 0));
		let spine2 = rig.FindBone("Spine2");
		let before = rig.Weight(spot, spine2);
		painter.Dab(.Add, spine2, rig.positions[spot], 0.05f, 0.5f, 0, false, rig.positions);
		var rowSum = 0.0f;
		for (int b < rig.BoneCount)
			rowSum += rig.Weight(spot, b);
		Check(rig.Weight(spot, spine2) > before + 0.3f && Math.Abs(rowSum - 1) < 0.001f, scope $"Add gives a bone more where the brush is ({before:0.00} to {rig.Weight(spot, spine2):0.00}), the rest scaled to keep 1");
		let mirrorSpot = NearestVertex(rig, .(-0.32f, 1.465f, 0));
		Check(rig.Weight(mirrorSpot, spine2) < 0.05f, "without mirroring, the other side is left alone");
		painter.Dab(.Add, rig.FindBone("LeftArm"), rig.positions[spot], 0.05f, 1, 0, true, rig.positions);
		Check(rig.Weight(mirrorSpot, rig.FindBone("RightArm")) > 0.9f, "with mirroring, the other side gets the mirrored bone");
		painter.Dab(.Subtract, rig.FindBone("LeftArm"), rig.positions[spot], 0.05f, 1, 0, false, rig.positions);
		Check(rig.Weight(spot, rig.FindBone("LeftArm")) < 0.01f, "Subtract takes it away");
		painter.Dab(.Set, rig.FindBone("LeftArm"), rig.positions[spot], 0.05f, 1, 0.4f, false, rig.positions);
		Check(Math.Abs(rig.Weight(spot, rig.FindBone("LeftArm")) - 0.4f) < 0.01f, "Set puts it at a value");
		let rough = rig.Weight(spot, rig.FindBone("LeftArm"));
		painter.Dab(.Smooth, 0, rig.positions[spot], 0.15f, 1, 0, false, rig.positions);
		Check(rig.Weight(spot, rig.FindBone("LeftArm")) > rough, "Smooth evens it out with its neighbours");
		let changed = painter.MirrorWeights(false);
		let leftSpot = rig.positions[NearestVertex(rig, .(0.32f, 1.465f, 0))];
		let leftArm = WeightAt(rig, leftSpot, "LeftArm"), rightArm = WeightAt(rig, .(-leftSpot.x, leftSpot.y, leftSpot.z), "RightArm");
		Check(changed > 0 && Math.Abs(leftArm - rightArm) < 0.01f, scope $"Mirror copies one side's weights to the other ({leftArm:0.00}, {rightArm:0.00})");

		// The rig file.
		let rigPath = scope String(), riggedPath = scope String();
		Rig.PathsFor("Models/Person.glb", rigPath, riggedPath);
		Check(rigPath == "Models/Person.trig" && riggedPath == "Models/Person_Rigged.glb", "a model's rig and rigged copy go beside it");
		Check(rig.Save(rigPath), "the rig saves");
		let problems = scope String();
		let read = Rig.Load(rigPath, problems);
		defer delete read;
		var kept = read != null && read.BoneCount == rig.BoneCount && read.HasWeights && read.template == .Humanoid && read.FindMarker("Chin") >= 0;
		if (kept)
		{
			for (int i < rig.weights.Count)
				kept &= Math.Abs(read.weights[i] - rig.weights[i]) < 0.0002f;
			for (int b < rig.BoneCount)
				kept &= read.bones[b].name == rig.bones[b].name && read.bones[b].parent == rig.bones[b].parent && Near(read.bones[b].head, rig.bones[b].head, 1e-4f);
			kept &= Near(read.markers[read.FindMarker("Chin")].position, Marker("Chin"), 1e-4f);
		}
		Check(kept && problems.IsEmpty, scope $"and reads back with its markers, bones and weights {problems}");

		// The rigged file, as a Skinned Mesh Renderer loads it.
		problem.Clear();
		Check(RigExport.Write(rig, riggedPath, problem), scope $"the rigged model is written {problem}");
		let skinned = SkinnedModel.Load(riggedPath);
		if (Check(skinned != null, "and loads as a rigged model"))
		{
			Check(skinned.Joints.Count == 65 && skinned.Positions.Count == rig.VertexCount, scope $"with every joint and vertex ({skinned.Joints.Count}, {skinned.Positions.Count})");
			Check(skinned.HumanMap != null && skinned.HumanMap.IsHumanoid && skinned.HumanMap.Matched >= 50, scope $"as a humanoid, so humanoid clips play on it ({skinned.HumanMap?.Matched} bones matched)");
			var match = true;
			for (int v < Math.Min(skinned.Positions.Count, 50))
			{
				var sum = 0.0f;
				for (int s < 4)
					sum += skinned.Weights[v * 4 + s];
				match &= Math.Abs(sum - 1) < 0.001f;
			}
			Check(match, "each vertex's four weights add up to 1");
		}
		// A changed model: the weights are let go.
		MakeDog(scope $"{folder}/Models/Person.glb");
		problems.Clear();
		let changedRig = Rig.Load(rigPath, problems);
		defer delete changedRig;
		Check(changedRig != null && !changedRig.HasWeights && problems.Contains("changed"), scope $"a rig whose model changed keeps its bones but says to make the weights again");
		// The person back (the Sandbox's Rig Test Person is this file).
		MakePerson(scope $"{folder}/Models/Person.glb");
	}

	/// The Sandbox's real person (Quaternius, CC0), for its hands: the tube person has none.
	static void RealPerson(StringView folder)
	{
		let source = "../../Samples/Sandbox/src/Models/Rigging/Person.glb";
		if (!File.Exists(source))
		{
			Console.WriteLine("SKIP: the Sandbox's Person.glb is not there");
			return;
		}
		File.Copy(source, scope $"{folder}/Models/RealPerson.glb" , true).IgnoreError();
		let rig = scope Rig();
		let problem = scope String();
		Check(rig.LoadSource("Models/RealPerson.glb", problem), scope $"the real person reads {problem}");
		rig.template = RigTemplates.GuessTemplate(rig);
		Check(rig.template == .Humanoid, "and is taken for a person");
		RigTemplates.GuessMarkers(rig);
		let rays = scope RigRays(rig.positions, rig.Triangles(.. scope .()));
		RigTemplates.CentreMarkers(rig, rays);
		Vector3 Marker(StringView name) => rig.markers[rig.FindMarker(name)].position;
		for (let side in StringView[?]("Left", "Right"))
		{
			let wrist = Marker(scope $"{side} Wrist");
			let armDir = (wrist - Marker(scope $"{side} Elbow")).Normalized;
			Vector3[5] tips = default;
			var beyond = true;
			for (int f < 5)
			{
				tips[f] = Marker(scope $"{side} {RigTemplates.Fingers[f]}");
				beyond &= Vector3.Dot(tips[f] - wrist, armDir) > 0.03f;
			}
			Check(beyond, scope $"{side}: every fingertip is beyond the wrist");
			var apart = true;
			for (int a < 5)
			{
				for (int b = a + 1; b < 5; b++)
					apart &= (tips[a] - tips[b]).Length > 0.005f;
			}
			Check(apart, scope $"{side}: the five fingertips are found apart");
			let along = Vector3.Dot(tips[0] - wrist, armDir);
			Check(along < Vector3.Dot(tips[2] - wrist, armDir), scope $"{side}: the thumb is shorter than the middle finger");
			var ordered = true;
			for (int f = 1; f < 4; f++)
				ordered &= Vector3.Dot(tips[f], rig.facing) >= Vector3.Dot(tips[f + 1], rig.facing) - 0.002f;
			Check(ordered, scope $"{side}: the fingers go from the first (front) to the little one (back)");
		}
		RigTemplates.Build(rig, rays);
		Check(rig.FindBone("LeftHandPinky3") >= 0 && rig.FindBone("RightHandThumb1") >= 0, scope $"the hands have every finger ({rig.BoneCount} bones)");
		Check(AutoWeights.Make(rig), "weights are made");
		// Each fingertip moves with its own finger.
		var own = true;
		let detail = scope String();
		for (let side in StringView[?]("Left", "Right"))
		{
			for (int f < 5)
			{
				let name = RigTemplates.Fingers[f];
				let tip = Marker(scope $"{side} {name}");
				var share = 0.0f;
				for (int k = 1; k <= 3; k++)
					share += WeightAt(rig, tip, scope $"{side}Hand{name}{k}");
				own &= share > 0.6f;
				detail.AppendF(" {}{}:{:0.00}", side[0], name, share);
			}
		}
		Check(own, scope $"each fingertip moves with its own finger ({detail})");
		// Curling a finger (in the rigger's pose and in the exported model) moves its tip.
		{
			let tip = Marker("Left Index");
			let near = NearestVertex(rig, tip);
			for (int k = 1; k <= 3; k++)
				rig.pose[rig.FindBone(scope $"LeftHandIndex{k}")] = Quaternion.AngleAxis(40, .(0, 0, 1));
			let posed = scope List<Vector3>();
			let posedNormals = scope List<Vector3>();
			rig.Posed(posed, posedNormals);
			Check((posed[near] - rig.positions[near]).Length > 0.02f, scope $"curling the first finger moves its tip in the rigger ({(posed[near] - rig.positions[near]).Length:0.000})");
			for (int b < rig.BoneCount)
				rig.pose[b] = .Identity;
			Check(RigExport.Write(rig, "Models/RealPerson_Rigged.glb", problem), "the real person is written");
			let model = SkinnedModel.Load("Models/RealPerson_Rigged.glb");
			var fingerWeighted = 0;
			if (model != null)
			{
				let index = model.FindJoint("LeftHandIndex3");
				for (int i < model.JointIndices.Count)
				{
					if (model.JointIndices[i] == index && model.Weights[i] > 0.3f)
						fingerWeighted++;
				}
			}
			Check(fingerWeighted > 20, scope $"the loaded model has finger weights ({fingerWeighted} vertices on LeftHandIndex3)");
		}
	}

	static void Dog(StringView folder)
	{
		MakeDog(scope $"{folder}/Models/Dog.glb");
		let rig = scope Rig();
		let problem = scope String();
		rig.LoadSource("Models/Dog.glb", problem);
		rig.template = .Quadruped;
		RigTemplates.GuessMarkers(rig);
		Check(rig.facing == Vector3(0, 0, -1), "a quadruped faces along its length");
		let rays = scope RigRays(rig.positions, rig.Triangles(.. scope .()));
		RigTemplates.CentreMarkers(rig, rays);
		Vector3 Marker(StringView name) => rig.markers[rig.FindMarker(name)].position;
		Check(Marker("Nose").z < -0.68f && Marker("Tail Tip").z > 0.72f, scope $"the nose and tail tip are at the ends ({Marker("Nose")}, {Marker("Tail Tip")})");
		Check(Marker("Left Front Paw").y < 0.05f && Marker("Left Front Paw").x > 0.04f && Marker("Left Front Paw").z < 0 && Marker("Right Back Paw").x < -0.04f && Marker("Right Back Paw").z > 0,
scope $"the paws are found ({Marker("Left Front Paw")}, {Marker("Right Back Paw")})");
		Check(Marker("Left Ear Tip").y > 0.85f, scope $"and the ear tips ({Marker("Left Ear Tip")})");
		// The body is a tube from z 0.35 (the rump, where the tail starts) to -0.35 (the shoulders, over the front legs).
		Check(Math.Abs(Marker("Tail Base").z - 0.33f) < 0.06f && Marker("Tail Base").y > 0.45f, scope $"the tail's base is at the rump ({Marker("Tail Base")})");
		Check(Math.Abs(Marker("Neck").z + 0.3f) < 0.08f && Marker("Neck").y > 0.45f, scope $"the neck's base is over the front legs ({Marker("Neck")})");
		// The snout is a tube from (0, 0.74, -0.45) to (0, 0.7, -0.68): the nose is the middle of its end.
		Check(Math.Abs(Marker("Nose").x) < 0.01f && Math.Abs(Marker("Nose").y - 0.7f) < 0.03f, scope $"the nose is the middle of the snout's end ({Marker("Nose")})");
		// A nose dragged far out: the head joint stays under the ears and the ears keep their length.
		{
			let longRig = scope Rig();
			longRig.LoadSource("Models/Dog.glb", problem);
			longRig.template = .Quadruped;
			RigTemplates.GuessMarkers(longRig);
			RigTemplates.CentreMarkers(longRig, rays);
			RigTemplates.Build(longRig, rays);
			let head = longRig.bones[longRig.FindBone("Head")].head;
			let earLength = (longRig.End(longRig.FindBone("Ear_L2")) - longRig.bones[longRig.FindBone("Ear_L1")].head).Length;
			longRig.markers[longRig.FindMarker("Nose")].position = longRig.markers[longRig.FindMarker("Nose")].position + Vector3(0, 0, -0.6f);
			RigTemplates.Build(longRig, rays);
			let movedHead = longRig.bones[longRig.FindBone("Head")].head;
			let movedEar = (longRig.End(longRig.FindBone("Ear_L2")) - longRig.bones[longRig.FindBone("Ear_L1")].head).Length;
			let ears = (longRig.markers[longRig.FindMarker("Left Ear Tip")].position + longRig.markers[longRig.FindMarker("Right Ear Tip")].position) * 0.5f;
			Check(Math.Abs(head.z - ears.z) < 0.03f && (head - longRig.markers[longRig.FindMarker("Head")].position).Length < 1e-4f, scope $"the head joint is the Head marker, guessed under the ears ({head}, ears at z {ears.z})");
			Check((movedHead - head).Length < 1e-4f, scope $"moving the nose far out leaves the head joint where it was ({head} to {movedHead})");
			Check(Math.Abs(movedEar - earLength) < 0.03f, scope $"and the ears keep their length ({earLength:0.000} to {movedEar:0.000})");
		}
		RigTemplates.Build(rig, rays);
		// The back leg's joints are in the leg, where it bends: the knee forward, the hock back.
		{
			let knee = rig.bones[rig.FindBone("Shin_L")].head;
			let hock = rig.bones[rig.FindBone("Hock_L")].head;
			Check(Math.Abs(knee.z - 0.215f) < 0.05f && Math.Abs(knee.y - 0.3f) < 0.06f && Math.Abs(hock.z - 0.365f) < 0.05f && Math.Abs(hock.y - 0.14f) < 0.06f,
scope $"the back leg's knee and hock are where it bends ({knee}, {hock})");
		}
		// A rig file from before the Head marker gets one where it would have been guessed.
		{
			let text = rig.Write(.. scope .());
			let start = text.IndexOf("marker \"Head\"");
			text.Remove(start, text.IndexOf('\n', start) - start + 1);
			let older = scope Rig();
			let problems = scope String();
			older.Parse(text, problems);
			let headMarker = older.markers[older.FindMarker("Head")].position;
			Check((headMarker - RigTemplates.GuessHead(older)).Length < 1e-4f && headMarker.z < -0.3f, scope $"an older rig file's Head marker is guessed ({headMarker}) {problems}");
		}
		Check(rig.bones[0].name == "Root" && rig.FindBone("Tail6") >= 0 && rig.FindBone("Ear_L1") >= 0 && rig.FindBone("Jaw") >= 0 && rig.FindBone("Thigh_R") >= 0,
scope $"a quadruped skeleton ({rig.BoneCount} bones: root, spine, neck, head, jaw, ears, tail and four legs)");
		let map = scope BoneMap();
		var takenForHuman = false;
		for (let bone in rig.bones)
			takenForHuman |= BoneMap.FindBone(bone.name) == (int)HumanBone.Hips;
		Check(!takenForHuman, "no bone is taken for a humanoid's hips");
		Check(AutoWeights.Make(rig), "weights are made");
		let tail = WeightAt(rig, .(0, 0.6f, 0.68f), "Tail6") + WeightAt(rig, .(0, 0.6f, 0.68f), "Tail5");
		Check(tail > 0.7f, scope $"the tail's tip is the tail's ({tail:0.00})");
		var frontLeg = 0.0f;
		for (let name in StringView[?]("UpperArm_L", "Forearm_L", "Wrist_L", "FrontPaw_L"))
			frontLeg += WeightAt(rig, .(0.08f, 0.2f, -0.335f), name);
		let forearmShare = WeightAt(rig, .(0.08f, 0.2f, -0.335f), "Forearm_L");
		Check(frontLeg > 0.95f && forearmShare > 0.6f, scope $"the left front leg is the left front leg's ({frontLeg:0.00}, {forearmShare:0.00} its forearm)");
		Check(WeightAt(rig, .(-0.08f, 0.2f, -0.335f), "Forearm_L") == 0, "and not the right one's");
		let ear = WeightAt(rig, .(0.06f, 0.92f, -0.46f), "Ear_L2") + WeightAt(rig, .(0.06f, 0.92f, -0.46f), "Ear_L1");
		Check(ear > 0.7f, scope $"the ear moves with the ear ({ear:0.00})");
		problem.Clear();
		Check(RigExport.Write(rig, "Models/Dog_Rigged.glb", problem), "the rigged dog is written");
		// Facing another way, its skeleton is turned to face that way at rest (the mesh is not moved): written for
		// run.py-free checking by tools that skin it back (and loaded here).
		{
			let facing = rig.facing;
			rig.facing = .(1, 0, 0);
			Check(RigExport.Write(rig, "Models/Dog_Turned_Rigged.glb", problem), "a rig facing +X is written");
			rig.facing = facing;
			let turned = SkinnedModel.Load("Models/Dog_Turned_Rigged.glb");
			Check(turned != null && turned.Joints.Count == rig.BoneCount, "and loads");
		}
		let skinned = SkinnedModel.Load("Models/Dog_Rigged.glb");
		Check(skinned != null && skinned.Joints.Count == rig.BoneCount && (skinned.HumanMap == null || !skinned.HumanMap.IsHumanoid), "and loads, not as a humanoid");
	}

	static void Custom(StringView folder)
	{
		let rig = scope Rig();
		let problem = scope String();
		rig.LoadSource("Models/Dog.glb", problem);
		rig.template = .Custom;
		RigTemplates.Build(rig);
		Check(rig.BoneCount == 1 && rig.bones[0].name == "Root", "a custom rig starts with a root");
		let tail = rig.AddBone("Tail", 0, .(0, 0.53f, 0.36f), .(0, 0.62f, 0.75f));
		AutoWeights.Make(rig);
		Check(WeightAt(rig, .(0, 0.6f, 0.7f), "Tail") > 0.9f, "a bone added by hand gets its part");
		let added = rig.AddBone("Extra", tail, .(0, 0.62f, 0.75f), .(0, 0.65f, 0.8f));
		var sums = true;
		for (int v < rig.VertexCount)
		{
			var sum = 0.0f;
			for (int b < rig.BoneCount)
				sum += rig.Weight(v, b);
			sums &= Math.Abs(sum - 1) < 0.001f;
		}
		Check(added == 2 && rig.HasWeights && sums, "adding a bone keeps the weights");
		rig.RemoveBone(tail);
		sums = true;
		for (int v < rig.VertexCount)
		{
			var sum = 0.0f;
			for (int b < rig.BoneCount)
				sum += rig.Weight(v, b);
			sums &= Math.Abs(sum - 1) < 0.001f;
		}
		Check(rig.BoneCount == 2 && rig.bones[1].parent == 0 && WeightAt(rig, .(0, 0.6f, 0.7f), "Root") > 0.9f && sums, "removing a bone gives its weights to its parent, and its children too");
		Check(Rig.MirrorName("LeftArm", .. scope .()) == "RightArm" && Rig.MirrorName("Ear_L1", .. scope .()) == "Ear_R1" && Rig.MirrorName("Thigh_R", .. scope .()) == "Thigh_L" && Rig.MirrorName("Spine", .. scope .()) == "Spine",
			"bone names mirror (Left/Right, _L/_R)");
	}

	public static int Main(String[] args)
	{
		let folder = scope String();
		Directory.GetCurrentDirectory(folder);
		folder.Append("/build/rigtest");
		if (Directory.Exists(folder))
			Directory.DelTree(folder).IgnoreError();
		Directory.CreateDirectory(scope $"{folder}/Models").IgnoreError();
		let oldProject = scope String(Assets.ProjectPath);
		Assets.ProjectPath.Set(folder);
		Person(folder);
		RealPerson(folder);
		Dog(folder);
		Custom(folder);
		Assets.ProjectPath.Set(oldProject);
		Console.WriteLine(sFailures == 0 ? "All rigging checks passed." : scope $"{sFailures} rigging check(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
