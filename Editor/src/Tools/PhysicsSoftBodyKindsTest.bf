using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless checks of the backend's soft-body kinds: a pressure-held jelly inflates, a shell keeps an impact's dent,
/// a driven skin follows an object, and (on a backend that has it) a stressed cloth tears. Run with:
///   TallowLauncher --test-physics-softbody-kinds [--physics3d Rapier]
static class PhysicsSoftBodyKindsTest
{
	static int Check(StringView what, bool ok)
	{
		Console.WriteLine(scope $"[{(ok ? "PASS" : "FAIL")}] {what}");
		return ok ? 0 : 1;
	}

	static void Cube(Vector3 center, float half, float* positions, uint32* triangles)
	{
		Vector3[8] corners = .(
			.(center.x - half, center.y - half, center.z - half),
			.(center.x + half, center.y - half, center.z - half),
			.(center.x - half, center.y + half, center.z - half),
			.(center.x + half, center.y + half, center.z - half),
			.(center.x - half, center.y - half, center.z + half),
			.(center.x + half, center.y - half, center.z + half),
			.(center.x - half, center.y + half, center.z + half),
			.(center.x + half, center.y + half, center.z + half));
		for (int i < 8)
		{
			positions[i * 3] = corners[i].x - center.x;
			positions[i * 3 + 1] = corners[i].y - center.y;
			positions[i * 3 + 2] = corners[i].z - center.z;
		}
		uint32[36] faces = .(
			0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4,
			2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5);
		for (int i < 36)
			triangles[i] = faces[i];
	}

	static PhysicsSoftBodyConfig BaseConfig(SoftBodyKind kind)
	{
		PhysicsSoftBodyConfig config = default;
		config.kind = (int32)kind;
		config.mass = 1;
		config.stretch = 1.0e-5f;
		config.shear = 1.0e-5f;
		config.bend = 1.0e-5f;
		config.damping = 0.1f;
		config.friction = 0.4f;
		config.restitution = 0;
		config.gravityFactor = 1;
		config.vertexRadius = 0.02f;
		config.stepTime = 1.0f / 60.0f;
		config.iterations = 8;
		config.layer = PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, 0);
		return config;
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
		failures += Check("soft-body extension present", soft != null);
		if (soft == null)
		{
			Console.WriteLine("PHYSICS SOFTBODY KINDS FAIL");
			return 1;
		}
		bool rapier = scene.Physics.BackendProvider != null && scene.Physics.BackendProvider.Id == "Rapier";
		failures += Check("dents, pressure, skin and buoyancy are advertised",
			scene.Physics.Supports(.SoftBodyDents) && scene.Physics.Supports(.SoftBodyPressure) &&
			scene.Physics.Supports(.SoftBodySkin) && scene.Physics.Supports(.BuoyancySoftBodies));
		failures += Check(rapier ? "Rapier advertises tearing" : "Jolt does not advertise tearing",
			scene.Physics.Supports(.SoftBodyTearing) == rapier);
		if (!rapier)
		{
			Console.WriteLine("PHYSICS SOFTBODY KINDS PASS (Rapier-specific kinds skipped)");
			return failures == 0 ? 0 : 1;
		}

		// ---- jelly: pressure inflates it
		{
			let center = Vector3(0, 3, 0);
			float[24] positions = default;
			uint32[36] triangles = default;
			Cube(center, 0.5f, &positions, &triangles);
			float[8] pinned = default;
			float[8] stiffness = .(1, 1, 1, 1, 1, 1, 1, 1);
			float[3] c = .(center.x, center.y, center.z);
			Matrix4 objectMatrix = Matrix4.Identity;
			var config = BaseConfig(.Jelly);
			config.pressure = 200;
			config.doubleSided = 0;
			config.dihedral = 1;
			let body = soft.Create(&config, &positions, 8, &triangles, 12, &pinned, &stiffness, &c, &objectMatrix.m[0]);
			failures += Check("jelly created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				soft.SetPressure(body, 200 * 1.0f);
				for (int i < 120)
					scene.Physics.Step(1.0f / 60.0f);
				float[24] after = default;
				let read = soft.Read(body, &after, null, 8);
				float minX = float.MaxValue, maxX = -float.MaxValue;
				float minY = float.MaxValue, maxY = -float.MaxValue;
				for (int i < 8)
				{
					minX = Math.Min(minX, after[i * 3]);
					maxX = Math.Max(maxX, after[i * 3]);
					minY = Math.Min(minY, after[i * 3 + 1]);
					maxY = Math.Max(maxY, after[i * 3 + 1]);
				}
				failures += Check("jelly vertices read back", read == 8);
				failures += Check("jelly pressure inflated it",
					(maxX - minX) > 1.03f && (maxY - minY) > 1.03f && (maxX - minX).IsFinite);
				soft.Forget(body);
			}
		}

		// ---- soft-body buoyancy: a surface holds a floating cloth up
		{
			let center = Vector3(8, 1.5f, 0);
			float[24] positions = default;
			uint32[36] triangles = default;
			Cube(center, 0.5f, &positions, &triangles);
			float[8] pinned = default;
			float[8] stiffness = .(1, 1, 1, 1, 1, 1, 1, 1);
			float[3] c = .(center.x, center.y, center.z);
			Matrix4 objectMatrix = Matrix4.Identity;
			var config = BaseConfig(.Cloth);
			config.doubleSided = 1;
			let body = soft.Create(&config, &positions, 8, &triangles, 12, &pinned, &stiffness, &c, &objectMatrix.m[0]);
			failures += Check("floating cloth created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				float[4] samples = .(2, 2, 2, 2);
				uint32 under = 0;
				uint32 firstUnder = 0;
				for (int i < 120)
				{
					under = soft.FloatSoft(body, &samples, 2, 2, -4, -4, 8, 8, -5, 1, 2, 1, 9.81f, 1.0f / 60.0f, true);
					if (i == 0)
						firstUnder = under;
					scene.Physics.Step(1.0f / 60.0f);
				}
				float[24] after = default;
				soft.Read(body, &after, null, 8);
				float highest = -float.MaxValue;
				for (int i < 8)
					highest = Math.Max(highest, after[i * 3 + 1]);
				failures += Check("the water surface held the cloth up", firstUnder > 0 && highest > 0.15f);
				soft.Forget(body);
			}
		}

		// ---- shell: an impact leaves a dent
		{
			let targetObject = scene.CreateGameObject("Dent Target");
			targetObject.Transform.Position = Vector3(2, 2.5f, 0);
			let targetCollider = targetObject.AddComponent<BoxCollider>();
			targetCollider.size = Vector3.One;
			RigidbodyData targetData = .();
			targetData.mass = 10;
			targetData.useGravity = false;
			targetData.isKinematic = true;
			let targetBody = scene.Physics.CreateBody(targetObject.Transform, targetCollider.GetShape(), &targetData);

			let projectileObject = scene.CreateGameObject("Dent Projectile");
			projectileObject.Transform.Position = Vector3(2, 5, 0);
			let projectileCollider = projectileObject.AddComponent<BoxCollider>();
			projectileCollider.size = Vector3(0.4f);
			RigidbodyData projectileData = .();
			projectileData.mass = 5;
			let projectileBody = scene.Physics.CreateBody(projectileObject.Transform, projectileCollider.GetShape(), &projectileData);

			let center = Vector3(2, 2.5f, 0);
			float[24] positions = default;
			uint32[36] triangles = default;
			Cube(center, 0.5f, &positions, &triangles);
			float[8] pinned = default;
			float[8] stiffness = .(1, 1, 1, 1, 1, 1, 1, 1);
			float[3] c = .(center.x, center.y, center.z);
			Matrix4 objectMatrix = Matrix4.Identity;
			var config = BaseConfig(.Shell);
			config.shell = 1;
			config.impacts = 1;
			config.gravityFactor = 0;
			config.dentDepth = 0.2f;
			config.dentYield = 0.01f;
			config.dentSpeed = 2;
			let body = soft.Create(&config, &positions, 8, &triangles, 12, &pinned, &stiffness, &c, &objectMatrix.m[0]);
			failures += Check("shell created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				soft.Ignore(body, targetBody);
				for (int i < 150)
				{
					// The engine's SoftBody component holds a shell to its object every step.
					soft.Skin(body, &objectMatrix.m[0], &objectMatrix.m[0], 1.0f / 60.0f);
					scene.Physics.Step(1.0f / 60.0f);
				}
				float[24] dents = default;
				let count = soft.Dents(body, &dents, 8);
				float deepest = 0;
				for (int i < 8)
					deepest = Math.Max(deepest, Vector3(dents[i * 3], dents[i * 3 + 1], dents[i * 3 + 2]).Length);
				failures += Check("shell dents read back", count == 8);
				failures += Check("an impact left a dent", deepest > 0.005f && deepest.IsFinite);
				// The object's collider is now the deformable shell surface: a ray at the dented top hits low.
				scene.Physics.DestroyBody(projectileBody);
				RaycastHit dentHit = default;
				let collidesDented = scene.Physics.Raycast(Vector3(2, 4, 0), .Down, 5, out dentHit);
				failures += Check("the collision surface dented with the shell",
					collidesDented && dentHit.gameObject == targetObject && dentHit.point.y < 2.99f);
				soft.Forget(body);
			}
		}

		// ---- a dynamic shell keeps its own rigidbody collider: the soft body cannot carry its mass
		{
			let targetObject = scene.CreateGameObject("Dynamic Dent Target");
			targetObject.Transform.Position = Vector3(4, 1.5f, 0);
			let targetCollider = targetObject.AddComponent<BoxCollider>();
			targetCollider.size = Vector3.One;
			RigidbodyData targetData = .();
			targetData.mass = 500;
			let targetBody = scene.Physics.CreateBody(targetObject.Transform, targetCollider.GetShape(), &targetData);

			let center = Vector3(4, 1.5f, 0);
			float[24] positions = default;
			uint32[36] triangles = default;
			Cube(center, 0.5f, &positions, &triangles);
			float[8] pinned = default;
			float[8] stiffness = .(1, 1, 1, 1, 1, 1, 1, 1);
			float[3] c = .(center.x, center.y, center.z);
			Matrix4 objectMatrix = Matrix4.Identity;
			var config = BaseConfig(.Shell);
			config.shell = 1;
			config.impacts = 1;
			config.gravityFactor = 0;
			let body = soft.Create(&config, &positions, 8, &triangles, 12, &pinned, &stiffness, &c, &objectMatrix.m[0]);
			failures += Check("dynamic shell created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				soft.Ignore(body, targetBody);
				for (int i < 120)
					scene.Physics.Step(1.0f / 60.0f);
				let at = scene.Physics.GetState(targetBody).position;
				failures += Check("a dynamic shell keeps its collider", at.y > 0.8f && at.y.IsFinite);
				soft.Forget(body);
			}
		}

		// ---- driven skin: follows its object
		{
			let center = Vector3(-4, 3, 0);
			float[24] positions = default;
			uint32[36] triangles = default;
			Cube(center, 0.5f, &positions, &triangles);
			float[8] pinned = default;
			float[8] stiffness = .(1, 1, 1, 1, 1, 1, 1, 1);
			float[3] c = .(center.x, center.y, center.z);
			Matrix4 objectMatrix = Matrix4.Identity;
			var config = BaseConfig(.DrivenJelly);
			config.shell = 1;
			config.visualOnly = 1;
			config.gravityFactor = 0;
			config.visualSpring = 0.5f;
			config.visualDamping = 0.5f;
			let body = soft.Create(&config, &positions, 8, &triangles, 12, &pinned, &stiffness, &c, &objectMatrix.m[0]);
			failures += Check("driven skin created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				float[24] before = default;
				soft.Read(body, &before, null, 8);
				float[16] current = default;
				float[16] next = default;
				for (int i < 16)
				{
					current[i] = (i % 5 == 0) ? 1 : 0;
					next[i] = current[i];
				}
				next[13] = 1; // move the object up a metre
				soft.Skin(body, &current, &next, 1.0f / 60.0f);
				float[24] after = default;
				soft.Read(body, &after, null, 8);
				failures += Check("driven skin followed its object", after[1] > before[1] + 0.8f);
				soft.Forget(body);
			}
		}

		// ---- tearing (Rapier only)
		if (scene.Physics.Supports(.SoftBodyTearing))
		{
			// A 12 x 6 grid pinned along both short edges; the right edge is pulled away until the cloth rips.
			const int32 Nu = 12;
			const int32 Nv = 6;
			let positions = scope List<float>(Nu * Nv * 3);
			for (int row < Nv)
			{
				for (int col < Nu)
				{
					positions.Add(col * 0.2f);
					positions.Add(row * 0.2f);
					positions.Add(0);
				}
			}
			let triangles = scope List<uint32>();
			for (int row < Nv - 1)
			{
				for (int col < Nu - 1)
				{
					uint32 a = (uint32)(row * Nu + col);
					uint32 b = a + 1;
					uint32 c = (uint32)((row + 1) * Nu + col);
					uint32 d = c + 1;
					triangles.Add(a);
					triangles.Add(c);
					triangles.Add(b);
					triangles.Add(b);
					triangles.Add(c);
					triangles.Add(d);
				}
			}
			let pinned = scope List<float>(Nu * Nv);
			pinned.Resize(Nu * Nv, 0);
			let held = scope List<uint32>();
			for (int row < Nv)
			{
				pinned[row * Nu] = 1;
				pinned[row * Nu + Nu - 1] = 1;
				held.Add((uint32)(row * Nu + Nu - 1));
			}
			let stiffness = scope List<float>(Nu * Nv);
			stiffness.Resize(Nu * Nv, 1);
			float[3] c = .(Nu * 0.2f * 0.5f, Nv * 0.2f * 0.5f, 0);
			Matrix4 objectMatrix = Matrix4.Identity;
			var config = BaseConfig(.Cloth);
			config.doubleSided = 1;
			config.tear = 1;
			config.gravityFactor = 0;
			config.stretch = 1.0e-6f;
			let body = soft.Create(&config, positions.Ptr, (uint32)(Nu * Nv), triangles.Ptr,
				(uint32)(triangles.Count / 3), pinned.Ptr, stiffness.Ptr, &c, &objectMatrix.m[0]);
			failures += Check("tearable cloth created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				let targets = scope List<float>(held.Count * 3);
				for (int i < held.Count)
				{
					targets.Add(0);
					targets.Add(0);
					targets.Add(0);
				}
				for (int step < 180)
				{
					let shift = Math.Min(step / 120.0f, 1.0f) * (Nu - 1) * 0.2f;
					for (int i < held.Count)
					{
						let col = held[i] % Nu;
						let row = held[i] / Nu;
						targets[i * 3] = col * 0.2f + shift;
						targets[i * 3 + 1] = row * 0.2f;
						targets[i * 3 + 2] = 0;
					}
					soft.MovePinned(body, held.Ptr, targets.Ptr, (uint32)held.Count, 1.0f / 60.0f);
					scene.Physics.Step(1.0f / 60.0f);
				}
				failures += Check("the cloth tore", soft.HasTorn(body));
				soft.Forget(body);
			}
		}

		Console.WriteLine(failures == 0 ? "PHYSICS SOFTBODY KINDS PASS" : scope $"PHYSICS SOFTBODY KINDS FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}
}
