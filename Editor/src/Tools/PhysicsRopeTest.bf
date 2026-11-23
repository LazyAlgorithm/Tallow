using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless checks of the backend's ropes: a particle rope reads back and follows its pinned ends, and a tie
/// between two bodies carries the hanging one. Run with: TallowLauncher --test-physics-rope [--physics3d Rapier]
static class PhysicsRopeTest
{
	static int Check(StringView what, bool ok)
	{
		Console.WriteLine(scope $"[{(ok ? "PASS" : "FAIL")}] {what}");
		return ok ? 0 : 1;
	}

	public static int Run()
	{
		int failures = 0;
		let scene = scope Scene();
		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(30, 1, 30);
		scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null);
		let soft = scene.Physics.SoftBodies;
		failures += Check("the backend advertises ropes", scene.Physics.Supports(.Ropes) && soft != null);
		if (soft == null)
		{
			Console.WriteLine("PHYSICS ROPE FAIL");
			return 1;
		}

		// ---- a rope body: reads back and follows a pinned end
		{
			let count = 11;
			let positions = scope List<float>(count * 3);
			for (int i < count)
			{
				positions.Add(i * 0.25f);
				positions.Add(0);
				positions.Add(0);
			}
			let pinned = scope List<float>(count);
			pinned.Resize(count, 0);
			pinned[0] = 1;
			pinned[count - 1] = 1;
			PhysicsRopeConfig config = default;
			config.mass = 2;
			config.stretch = 1.0e-7f;
			config.bend = 1.0e-4f;
			config.damping = 0.1f;
			config.radius = 0.05f;
			float[3] center = .(0, 6, 0);
			let body = soft.CreateRope(&config, positions.Ptr, (uint32)count, pinned.Ptr, &center);
			failures += Check("rope body created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				float[33] read = default;
				let got = soft.Read(body, &read, null, (uint32)count);
				failures += Check("rope vertices read back", got == count);
				uint32[1] held = .(count - 1);
				float[3] target = .(5, 6, 0);
				soft.MovePinned(body, &held, &target, 1, 1.0f / 60.0f);
				for (int i < 30)
					scene.Physics.Step(1.0f / 60.0f);
				float[33] after = default;
				soft.Read(body, &after, null, (uint32)count);
				failures += Check("the pinned end moved the rope", after[(count - 1) * 3] > 1.5f);
				soft.Forget(body);
			}
		}

		// ---- a tie between two bodies carries the hanging one
		{
			let anchorObject = scene.CreateGameObject("Anchor");
			anchorObject.Transform.Position = Vector3(0, 8, 0);
			let anchorCollider = anchorObject.AddComponent<BoxCollider>();
			anchorCollider.size = Vector3(0.2f);
			let anchorBody = scene.Physics.CreateBody(anchorObject.Transform, anchorCollider.GetShape(), null);

			let loadObject = scene.CreateGameObject("Load");
			loadObject.Transform.Position = Vector3(0, 6, 0);
			let loadCollider = loadObject.AddComponent<BoxCollider>();
			loadCollider.size = Vector3(0.5f);
			RigidbodyData loadData = .();
			loadData.mass = 5;
			let loadBody = scene.Physics.CreateBody(loadObject.Transform, loadCollider.GetShape(), &loadData);

			float[3] from = .(0, 8, 0);
			float[3] to = .(0, 6, 0);
			let tie = soft.Tie(anchorBody, &from, loadBody, &to, 2.0f);
			failures += Check("rope tie created", tie != null);
			if (tie != null)
			{
				for (int i < 90)
					scene.Physics.Step(1.0f / 60.0f);
				failures += Check("the tie carries the load", soft.Pull(tie, 1.0f / 60.0f) > 1.0f);
				soft.Untie(tie);
			}
		}

		Console.WriteLine(failures == 0 ? "PHYSICS ROPE PASS" : scope $"PHYSICS ROPE FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}
}
