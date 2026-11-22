using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless check of the backend ragdoll extension: Jolt builds its built-in JPH_Ragdoll from neutral parts, steps it,
/// and reports a pose. Run with: TallowLauncher --test-physics-ragdoll
static class PhysicsRagdollTest
{
	public static int Run()
	{
		int failures = 0;
		let scene = scope Scene();

		// A floor gives PhysicsWorld a tracked body, so Step does not take its empty-world shortcut.
		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(10, 1, 10);
		let groundBody = scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null);
		failures += Check("ground body created", groundBody != uint32.MaxValue);

		let ragdolls = scene.Physics.Ragdolls;
		failures += Check("Jolt advertises ragdolls", scene.Physics.Supports(.Ragdolls));
		failures += Check("ragdoll extension is present", ragdolls != null);
		if (ragdolls == null)
		{
			Console.WriteLine("PHYSICS RAGDOLL FAIL");
			return 1;
		}

		ShapeDesc shape = default;
		shape.kind = .Box;
		shape.halfExtents = Vector3(0.2f, 0.2f, 0.2f);
		PhysicsRagdollPart[] parts = new .[3];
		defer delete parts;
		for (int i = 0; i < 3; i++)
		{
			parts[i] = default;
			parts[i].shape = shape;
			parts[i].position = Vector3(0, 5.0f - i * 0.5f, 0);
			parts[i].rotation = Quaternion.Identity;
			parts[i].mass = 5;
			parts[i].parent = (int32)(i - 1);
			parts[i].axis = Vector3.Up;
			parts[i].swingLimitRadians = Mathf.Deg2Rad * 45;
			parts[i].twistLimitRadians = Mathf.Deg2Rad * 20;
			parts[i].objectCode = PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, 0);
		}
		PhysicsRagdollDesc desc = default;
		desc.parts = parts.Ptr;
		desc.count = (int32)parts.Count;
		desc.userData = 1;
		desc.disableParentChildCollisions = true;
		let ragdoll = ragdolls.Create(desc);
		failures += Check("ragdoll created", ragdoll != null);
		if (ragdoll == null)
		{
			Console.WriteLine("PHYSICS RAGDOLL FAIL");
			return 1;
		}
		failures += Check("ragdoll has three bodies", ragdolls.BodyCount(ragdoll) == 3);
		ragdolls.AddToWorld(ragdoll, true);
		for (int i < 60)
			scene.Physics.Step(1.0f / 60.0f);
		PhysicsRagdollMatrix[] pose = new .[3];
		defer delete pose;
		Vector3 root;
		ragdolls.GetPose(ragdoll, out root, pose.Ptr, true);
		failures += Check("ragdoll fell", root.y < 4.5f);
		failures += Check("ragdoll pose is finite", root.y.IsFinite);
		ragdolls.Destroy(ragdoll);

		Console.WriteLine(failures == 0 ? "PHYSICS RAGDOLL PASS" : scope $"PHYSICS RAGDOLL FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}

	static int Check(StringView what, bool ok)
	{
		let line = scope String();
		line.AppendF("[{}] {}", ok ? "PASS" : "FAIL", what);
		Console.WriteLine(line);
		return ok ? 0 : 1;
	}
}
