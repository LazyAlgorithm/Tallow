using System;
using System.Collections;
using System.Diagnostics;
using Tallow;

namespace Tallow.Editor;

/// Headless 3D physics timing for comparing backends on the same scene: a pile of dynamic boxes settling on a
/// ground, contact dispatch, and a networked-style pass that teleports entities (SetState, as rollback and
/// corrections do) and raycasts from each one in between. Run with:
/// TallowLauncher --bench-physics <Jolt|Rapier> [boxes] [entities]
static class PhysicsBenchmark
{
	struct Phase
	{
		public double step, contacts, queries;
		public int frames;

		public void Print(StringView name) mut
		{
			let n = Math.Max(frames, 1);
			Console.WriteLine(scope $"  {name,-8} step {step / n:F3} ms  contacts {contacts / n:F3} ms  queries {queries / n:F3} ms  total {(step + contacts + queries) / n:F3} ms/frame");
		}
	}

	public static int Run(StringView backend, int boxCount, int entityCount)
	{
		PhysicsBackends.Override3D(backend);
		let scene = scope Scene();

		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(200, 1, 200);
		scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null);

		// Boxes in a grid of 1.2 m cells, falling onto the ground and each other.
		let bodies = scope List<uint32>();
		let side = (int)Math.Ceiling(Math.Sqrt((float)boxCount / 8));
		for (int i < boxCount)
		{
			let obj = scene.CreateGameObject("Box");
			let x = i % side, z = (i / side) % side, y = i / (side * side);
			obj.Transform.Position = Vector3((x - side * 0.5f) * 1.2f, 1.5f + y * 1.2f, (z - side * 0.5f) * 1.2f);
			let collider = obj.AddComponent<BoxCollider>();
			collider.size = Vector3.One;
			RigidbodyData data = .();
			data.mass = 1;
			data.friction = 0.6f;
			bodies.Add(scene.Physics.CreateBody(obj.Transform, collider.GetShape(), &data));
		}

		// Networked entities: dynamic spheres away from the pile that are teleported every frame.
		let entities = scope List<uint32>();
		for (int i < entityCount)
		{
			let obj = scene.CreateGameObject("Entity");
			obj.Transform.Position = Vector3(60 + (i % 8) * 3, 1, (i / 8) * 3);
			let collider = obj.AddComponent<SphereCollider>();
			collider.radius = 0.5f;
			RigidbodyData data = .();
			data.mass = 1;
			entities.Add(scene.Physics.CreateBody(obj.Transform, collider.GetShape(), &data));
		}

		Console.WriteLine(scope $"[bench] {backend}: {boxCount} boxes, {entityCount} teleported entities, 600 frames at 60 Hz");
		let clock = scope Stopwatch();
		Phase settling = default, resting = default;
		for (int frame < 600)
		{
			Phase* phase = frame < 300 ? &settling : &resting;
			clock.Restart();
			scene.Physics.Step(1.0f / 60.0f);
			phase.step += clock.Elapsed.TotalMilliseconds;

			clock.Restart();
			scene.Physics.DispatchContacts(scene);
			phase.contacts += clock.Elapsed.TotalMilliseconds;

			clock.Restart();
			for (int i < entities.Count)
			{
				var state = scene.Physics.GetState(entities[i]);
				state.position.y = 1 + Math.Sin(frame * 0.05f + i) * 0.25f;
				state.linearVelocity = .Zero;
				scene.Physics.SetState(entities[i], state);
				scene.Physics.Raycast(state.position + Vector3(0, 2, 0), .Down, 10, ?);
			}
			phase.queries += clock.Elapsed.TotalMilliseconds;
			phase.frames++;
		}
		settling.Print("settling");
		resting.Print("resting");

		// Bit-exact hash of every body's final state: equal hashes mean identical simulations (thread counts,
		// platforms, builds).
		bodies.AddRange(entities);
		uint64 hash = 14695981039346656037;
		for (let body in bodies)
		{
			let state = scene.Physics.GetState(body);
			float[13] values = .(state.position.x, state.position.y, state.position.z, state.rotation.x, state.rotation.y,
				state.rotation.z, state.rotation.w, state.linearVelocity.x, state.linearVelocity.y, state.linearVelocity.z,
				state.angularVelocity.x, state.angularVelocity.y, state.angularVelocity.z);
			for (var value in values)
			{
				uint32 bits = 0;
				Internal.MemCpy(&bits, &value, 4);
				hash = (hash ^ bits) * 1099511628211;
			}
		}
		Console.WriteLine(scope $"BENCH STATEHASH {hash:X16}");
		return 0;
	}
}
