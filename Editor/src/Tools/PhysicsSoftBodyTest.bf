using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless check of the neutral soft-body extension: a pinned quad is created through the selected backend, stepped,
/// and its free corners fall. Run with: TallowLauncher --test-physics-softbody
static class PhysicsSoftBodyTest
{
	public static int Run()
	{
		int failures = 0;
		let scene = scope Scene();

		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(20, 1, 20);
		failures += Check("ground body created", scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null) != uint32.MaxValue);

		let soft = scene.Physics.SoftBodies;
		failures += Check("Jolt advertises soft bodies", scene.Physics.Supports(.SoftBodies));
		failures += Check("soft-body extension is present", soft != null);
		if (soft == null)
		{
			Console.WriteLine("PHYSICS SOFTBODY FAIL");
			return 1;
		}

		float[12] positions = .( -1, 3, 0, 1, 3, 0, -1, 2, 0, 1, 2, 0 );
		uint32[6] triangles = .( 0, 2, 1, 1, 2, 3 );
		float[4] pinned = .( 1, 1, 0, 0 );
		float[4] stiffness = .( 1, 1, 1, 1 );
		Vector3 center = .(0, 2.5f, 0);
		Matrix4 objectMatrix = Matrix4.Identity;
		for (int i = 0; i < 4; i++)
		{
			positions[i * 3] -= center.x;
			positions[i * 3 + 1] -= center.y;
			positions[i * 3 + 2] -= center.z;
		}
		PhysicsSoftBodyConfig config = default;
		config.mass = 1;
		config.stretch = 1.0e-4f;
		config.shear = 1.0e-4f;
		config.bend = -1;
		config.pressure = 0;
		config.damping = 0.1f;
		config.friction = 0.4f;
		config.restitution = 0;
		config.gravityFactor = 1;
		config.vertexRadius = 0.02f;
		config.dentDepth = 0.001f;
		config.dentYield = 0.03f;
		config.dentSpeed = 0;
		config.stepTime = 1.0f / 60.0f;
		config.iterations = 5;
		config.doubleSided = 1;
		config.layer = PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, 0);
		let body = soft.Create(&config, &positions[0], 4, &triangles[0], 2, &pinned[0], &stiffness[0], (float*)&center, &objectMatrix.m[0]);
		failures += Check("soft body created", body != uint32.MaxValue);
		if (body == uint32.MaxValue)
		{
			Console.WriteLine("PHYSICS SOFTBODY FAIL");
			return 1;
		}

		for (int i < 120)
			scene.Physics.Step(1.0f / 60.0f);

		float[12] after = default;
		let read = soft.Read(body, &after[0], null, 4);
		failures += Check("soft body vertices read back", read == 4);
		failures += Check("free corners fell", after[3 * 2 + 1] < after[3 * 0 + 1] - 0.1f);
		scene.Physics.DestroyBody(body);

		Console.WriteLine(failures == 0 ? "PHYSICS SOFTBODY PASS" : scope $"PHYSICS SOFTBODY FAIL ({failures})");
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
