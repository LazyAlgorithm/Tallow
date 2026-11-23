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

	// The renderer uses the positions returned by Read. Sample the centroid of top face (2, 6, 7).
	static bool ShellTriangleMatchesRay(Scene scene, PhysicsSoftBodyExtension soft, uint32 body, GameObject target)
	{
		float[24] vertices = default;
		if (soft.Read(body, &vertices, null, 8) != 8)
			return false;
		let center = Vector3(vertices[6] + vertices[18] + vertices[21],
			vertices[7] + vertices[19] + vertices[22], vertices[8] + vertices[20] + vertices[23]) / 3;
		return scene.Physics.Raycast(center + Vector3(0, 1, 0), .Down, 2, let hit) &&
			hit.gameObject == target && Math.Abs(hit.point.y - center.y) < 0.002f;
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
		config.surfaceStiffness = 0.9f;
		config.bendStiffness = 0.2f;
		config.layer = PhysicsLayerTable.ObjectCode(PhysicsLayerTable.MovingClass, 0);
		return config;
	}

	static int CheckNativeColliders()
	{
		int failures = 0;
		let scene = scope Scene();
		let obj = scene.CreateGameObject("Jelly with an authored collider");
		obj.Transform.Position = Vector3(0, 4, 0);
		obj.AddComponent<MeshRenderer>().mesh.Set("builtin:cube");
		let solid = obj.AddComponent<BoxCollider>();
		solid.center = Vector3(2, 0, 0);
		let jelly = obj.AddComponent<SoftBody>();
		jelly.kind = .Jelly;
		jelly.gravityScale = 0;
		jelly.pressure = 0;

		let dynamicObject = scene.CreateGameObject("Jelly with a Rigidbody");
		dynamicObject.Transform.Position = Vector3(0, 4, 4);
		dynamicObject.AddComponent<MeshRenderer>().mesh.Set("builtin:cube");
		dynamicObject.AddComponent<BoxCollider>();
		let rigid = dynamicObject.AddComponent<Rigidbody>();
		let dynamicJelly = dynamicObject.AddComponent<SoftBody>();
		dynamicJelly.kind = .Jelly;
		dynamicJelly.gravityScale = 0;
		dynamicJelly.pressure = 0;

		let sensorObject = scene.CreateGameObject("Jelly with a trigger");
		sensorObject.Transform.Position = Vector3(0, 4, 8);
		sensorObject.AddComponent<MeshRenderer>().mesh.Set("builtin:cube");
		let sensor = sensorObject.AddComponent<BoxCollider>();
		sensor.center = Vector3(2, 0, 0);
		sensor.isTrigger = true;
		let sensorJelly = sensorObject.AddComponent<SoftBody>();
		sensorJelly.kind = .Jelly;
		sensorJelly.gravityScale = 0;
		sensorJelly.pressure = 0;

		scene.StartPlay();
		scene.FixedUpdate();
		let nativeHit = scene.Physics.Raycast(Vector3(0.1f, 6, 0.2f), .Down, 4, let surface);
		failures += Check("the native collider reports its SoftBody object",
			jelly.HasBody && nativeHit && surface.bodyId == jelly.BodyId && surface.gameObject == obj);
		failures += Check("the solid collider is skipped when the native surface exists",
			!scene.Physics.Raycast(Vector3(2, 6, 0), .Down, 4, let unused));
		failures += Check("the native surface takes over collision from a redundant Rigidbody",
			dynamicJelly.HasBody && !rigid.HasBody);
		failures += Check("the trigger retains its own collider",
			scene.Physics.Raycast(Vector3(2, 6, 8), .Down, 4, let triggerHit) && triggerHit.gameObject == sensorObject);

		jelly.Enabled = false;
		dynamicJelly.Enabled = false;
		scene.FixedUpdate();
		failures += Check("disabling SoftBody restores the ordinary static and rigid colliders",
			scene.Physics.Raycast(Vector3(2, 6, 0), .Down, 4, let restored) && restored.gameObject == obj && rigid.HasBody);
		failures += Check("the saved collider stays enabled",
			solid.Enabled && sensor.Enabled);
		scene.StopPlay();
		return failures;
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

		// Wind acts on each face, including faces along a moving pinned edge.
		{
			float[12] positions = .(-1, 0.5f, 0, 1, 0.5f, 0, -1, -0.5f, 0, 1, -0.5f, 0);
			uint32[6] triangles = .(0, 2, 1, 1, 2, 3);
			float[4] pinned = .(1, 1, 0, 0);
			uint32[2] pins = .(0, 1);
			float[6] targets = .(-1, 3, 0.25f, 1, 3, 0.25f);
			float[3] center = .(0, 2.5f, 0);
			float[3] wind = .(0, 0, 8);
			Matrix4 matrix = Matrix4.Identity;
			var config = BaseConfig(.Cloth);
			let body = soft.Create(&config, &positions, 4, &triangles, 2, &pinned, null, &center, &matrix.m[0]);
			failures += Check("wind-driven cloth created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				soft.MovePinned(body, &pins, &targets, 2, 1.0f / 60.0f);
				soft.Wind(body, &wind, 1, 0, 0, 1.0f / 60.0f);
				scene.Physics.Step(1.0f / 60.0f);
				float[12] after = default;
				let read = soft.Read(body, &after, null, 4);
				failures += Check("wind preserves both pinned targets",
					read == 4 && Math.Abs(after[2] - 0.25f) < 1.0e-3f && Math.Abs(after[5] - 0.25f) < 1.0e-3f);
				// A projectile can throw free cloth vertices into the air much faster than wind.
				float[12] velocities = .(0, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 100);
				soft.SetPositions(body, &after, &velocities, 4);
				soft.Wind(body, &wind, 3, 0, 0, 1.0f / 60.0f);
				soft.Read(body, null, &velocities, 4);
				failures += Check("quadratic drag cannot reverse impact-speed cloth particles",
					velocities[8] >= wind[2] && velocities[8] < 100 && velocities[11] >= wind[2] && velocities[11] < 100);
				soft.Forget(body);
			}
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
				soft.SetPressure(body, 10);
				for (int i = 0; i < 120; i++)
					scene.Physics.Step(1.0f / 60.0f);
				float[24] resting = default;
				let restingCount = soft.Read(body, &resting, null, 8);
				float restingMinX = float.MaxValue, restingMaxX = -float.MaxValue, restingMinY = float.MaxValue;
				for (int i = 0; i < 8; i++)
				{
					restingMinX = Math.Min(restingMinX, resting[i * 3]);
					restingMaxX = Math.Max(restingMaxX, resting[i * 3]);
					restingMinY = Math.Min(restingMinY, resting[i * 3 + 1]);
				}
				let restingWidth = restingMaxX - restingMinX;
				failures += Check("default jelly pressure keeps the rest size",
					restingCount == 8 && restingWidth > 0.9f && restingWidth < 1.15f);
				failures += Check("jelly settles at its authored contact thickness",
					restingMinY > 0.49f && restingMinY < 0.56f);

				soft.SetPressure(body, 200);
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
			targetObject.Transform.SetPositionAndRotation(Vector3(2, 2.5f, 0),
				Quaternion.AngleAxis(30, .Up));
			targetObject.Transform.LocalScale = Vector3(1, 2, 1);
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
			var objectMatrix = targetObject.Transform.LocalToWorld;
			for (int i = 0; i < 8; i++)
			{
				let p = objectMatrix.TransformDirection(Vector3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]));
				positions[i * 3] = p.x;
				positions[i * 3 + 1] = p.y;
				positions[i * 3 + 2] = p.z;
			}
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
				soft.Skin(body, &objectMatrix.m[0], &objectMatrix.m[0], 1.0f / 60.0f);
				float[24] held = default;
				let heldCount = soft.Read(body, &held, null, 8);
				var maxError = 0.0f;
				for (int i = 0; i < 8; i++)
				{
					let expected = center + Vector3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
					let current = Vector3(held[i * 3], held[i * 3 + 1], held[i * 3 + 2]);
					maxError = Math.Max(maxError, (current - expected).Length);
				}
				failures += Check("a rotated and scaled shell stays on its object", heldCount == 8 && maxError < 1.0e-4f);
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
				{
					let localDent = Vector3(dents[i * 3], dents[i * 3 + 1], dents[i * 3 + 2]);
					deepest = Math.Max(deepest, objectMatrix.TransformDirection(localDent).Length);
				}
				failures += Check("shell dents read back", count == 8);
				failures += Check("an impact left a dent", deepest > 0.005f && deepest.IsFinite);
				failures += Check("dent depth is measured in world metres on a scaled shell", deepest <= config.dentDepth + 0.001f);
				// The object's collider is now the deformable shell surface: a ray at the dented top hits low.
				scene.Physics.DestroyBody(projectileBody);
				RaycastHit dentHit = default;
				let collidesDented = scene.Physics.Raycast(Vector3(2, 4, 0), .Down, 5, out dentHit);
				failures += Check("the collision surface dented with the shell",
					collidesDented && dentHit.gameObject == targetObject && dentHit.point.y < 3.49f);
				soft.Forget(body);
				failures += Check("removing the deformable shell restores the carrier collider",
					scene.Physics.Raycast(Vector3(2, 4, 0), .Down, 5, let originalHit) &&
					originalHit.gameObject == targetObject && Math.Abs(originalHit.point.y - 3.5f) < 0.01f);
			}
		}

		// A heavy carrier keeps its mass. Its native soft surface supplies the only contact geometry.
		{
			let targetObject = scene.CreateGameObject("Dynamic Dent Target");
			targetObject.Transform.Position = Vector3(4, 1.5f, 0);
			let targetCollider = targetObject.AddComponent<BoxCollider>();
			targetCollider.size = Vector3(1.8f, 1.6f, 1.8f);
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
			var objectMatrix = targetObject.Transform.LocalToWorld;
			var config = BaseConfig(.Shell);
			config.shell = 1;
			config.impacts = 1;
			config.gravityFactor = 0;
			config.dentDepth = 0.30f;
			config.dentYield = 0.01f;
			config.dentSpeed = 3;
			let body = soft.Create(&config, &positions, 8, &triangles, 12, &pinned, &stiffness, &c, &objectMatrix.m[0]);
			failures += Check("dynamic shell created", body != uint32.MaxValue);
			if (body != uint32.MaxValue)
			{
				soft.Ignore(body, targetBody);
				for (int i = 0; i < 120; i++)
				{
					objectMatrix = targetObject.Transform.LocalToWorld;
					soft.Skin(body, &objectMatrix.m[0], &objectMatrix.m[0], 1.0f / 60.0f);
					scene.Physics.Step(1.0f / 60.0f);
				}
				let at = scene.Physics.GetState(targetBody).position;
				failures += Check("the native shell surface supports a heavy carrier",
					soft.HasNativeCollider(body) && at.y > 0.96f && at.y < 1.1f);
				failures += Check("the original hull is absent from collision queries",
					scene.Physics.Raycast(at + Vector3(0.7f, 2, 0), .Down, 5, let outside) && outside.gameObject != targetObject);
				let ray = at + Vector3(0, 3, 0);
				let initialHit = scene.Physics.Raycast(ray, .Down, 5, let beforeHit);
				failures += Check("the native shell ray reports the carrier",
					initialHit && beforeHit.gameObject == targetObject);

				let projectile = scene.CreateGameObject("Heavy Shell Impact");
				projectile.Transform.Position = ray + Vector3(0.28f, 0, -0.2f);
				let projectileCollider = projectile.AddComponent<SphereCollider>();
				projectileCollider.radius = 0.25f;
				RigidbodyData projectileData = .();
				projectileData.mass = 12;
				let projectileBody = scene.Physics.CreateBody(projectile.Transform, projectileCollider.GetShape(), &projectileData);
				scene.Physics.SetLinearVelocity(projectileBody, Vector3(0, -10, 0));
				for (int i = 0; i < 70; i++)
				{
					objectMatrix = targetObject.Transform.LocalToWorld;
					soft.Skin(body, &objectMatrix.m[0], &objectMatrix.m[0], 1.0f / 60.0f);
					scene.Physics.Step(1.0f / 60.0f);
				}
				scene.Physics.DestroyBody(projectileBody);
				float[24] impactDents = default;
				let dentCount = soft.Dents(body, &impactDents, 8);
				failures += Check("an off-centre hit dents the near corner more deeply",
					dentCount == 8 && impactDents[10] < impactDents[19] - 0.03f);
				let dentedAt = scene.Physics.GetState(targetBody).position;
				let dentedHit = scene.Physics.Raycast(dentedAt + Vector3(0, 3, 0), .Down, 5, let afterHit);
				failures += Check("a real strike dents the dynamic shell's collision surface",
					dentedHit && afterHit.gameObject == targetObject && afterHit.point.y - dentedAt.y <
					beforeHit.point.y - at.y - 0.03f);

				objectMatrix = targetObject.Transform.LocalToWorld;
				soft.SetDents(body, null, 0, &objectMatrix.m[0]);
				failures += Check("a pending shell repair keeps the rendered and queried surfaces aligned",
					ShellTriangleMatchesRay(scene, soft, body, targetObject));
				scene.Physics.Step(1.0f / 60.0f);
				let repairedHit = scene.Physics.Raycast(dentedAt + Vector3(0, 3, 0), .Down, 5, let restored);
				failures += Check("repair restores the dynamic shell's collision surface",
					repairedHit && restored.gameObject == targetObject && restored.point.y - afterHit.point.y > 0.03f);
				failures += Check("the repaired shell mesh and collision surface align",
					ShellTriangleMatchesRay(scene, soft, body, targetObject));

				let previousVelocity = scene.Physics.GetState(targetBody).linearVelocity;
				scene.Physics.AddImpulse(targetBody, Vector3(500, 0, 0));
				let velocityChange = scene.Physics.GetState(targetBody).linearVelocity - previousVelocity;
				failures += Check("the carrier retains its authored 500 kg mass", Math.Abs(velocityChange.x - 1) < 0.01f);
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
			config.dentDepth = 0.2f;
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
				next[13] = 0.15f;
				for (int i = 0; i < 60; i++)
				{
					soft.Skin(body, &current, &next, 1.0f / 60.0f);
					scene.Physics.Step(1.0f / 60.0f);
				}
				float[24] after = default;
				soft.Read(body, &after, null, 8);
				failures += Check("driven skin follows a Rapier shape-matching target",
					Math.Abs(after[1] - before[1] - 0.15f) < 0.025f);
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

		failures += CheckNativeColliders();

		Console.WriteLine(failures == 0 ? "PHYSICS SOFTBODY KINDS PASS" : scope $"PHYSICS SOFTBODY KINDS FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}
}
