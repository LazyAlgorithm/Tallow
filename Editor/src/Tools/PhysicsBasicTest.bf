using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless sanity check that the selected backend still creates bodies, steps them and answers queries through the
/// new PhysicsWorld/PhysicsBackendWorld seam. Run with: TallowLauncher --test-physics-basic
static class PhysicsBasicTest
{
	public static int Run()
	{
		int failures = 0;
		let scene = scope Scene();

		let ground = scene.CreateGameObject("Ground");
		ground.Transform.Position = Vector3(0, 0, 0);
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(10, 1, 10);
		let groundBody = scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null);
		failures += Check("ground body created", groundBody != uint32.MaxValue);

		let falling = scene.CreateGameObject("Box");
		falling.Transform.Position = Vector3(0, 5, 0);
		let fallingCollider = falling.AddComponent<BoxCollider>();
		fallingCollider.size = Vector3.One;
		RigidbodyData data = .();
		data.mass = 1;
		let fallingBody = scene.Physics.CreateBody(falling.Transform, fallingCollider.GetShape(), &data);
		failures += Check("dynamic body created", fallingBody != uint32.MaxValue);

		for (int i < 10)
			scene.Physics.Step(1.0f / 60.0f);
		let saved = scene.Physics.SaveExact(null);
		let savedY = falling.Transform.Position.y;
		for (int i < 20)
			scene.Physics.Step(1.0f / 60.0f);
		let movedY = falling.Transform.Position.y;
		failures += Check("body moved between save and restore", Math.Abs(movedY - savedY) > 0.01f);
		let restored = scene.Physics.RestoreExact(saved);
		let restoredY = falling.Transform.Position.y;
		failures += Check("exact snapshot restores the pose", restored && Math.Abs(restoredY - savedY) < 0.01f);
		scene.Physics.FreeExact(saved);

		for (int i < 180)
			scene.Physics.Step(1.0f / 60.0f);

		let y = falling.Transform.Position.y;
		failures += Check("box fell", y < 4.5f);
		failures += Check("box landed on the ground", y > 0.4f && y < 1.6f);

		RaycastHit hit = default;
		if (scene.Physics.Raycast(Vector3(0, 10, 0), .Down, 20, out hit))
			failures += Check("raycast found the box or ground", hit.gameObject == falling || hit.gameObject == ground);
		else
			failures += Check("raycast found the box or ground", false);

		// Navigation gets its triangles from the selected backend's geometry extension.
		NavigationMesh.Config navConfig = default;
		navConfig.min = Vector3(-5, -1, -5);
		navConfig.max = Vector3(5, 1, 5);
		navConfig.cellSize = 0.2f;
		navConfig.cellHeight = 0.2f;
		navConfig.radius = 0.5f;
		navConfig.height = 2;
		navConfig.climb = 0.4f;
		navConfig.slope = 45;
		let nav = NavigationMesh.Bake(scene.Physics, navConfig);
		failures += Check("navigation bakes from backend geometry", nav != null);
		if (nav != null)
		{
			failures += Check("navigation has floor polygons", nav.PolygonCount > 0);
			delete nav;
		}

		Console.WriteLine(failures == 0 ? "PHYSICS BASIC PASS" : scope $"PHYSICS BASIC FAIL ({failures})");
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
