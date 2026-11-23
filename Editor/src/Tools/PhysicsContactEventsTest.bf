using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Contact event semantics shared by every 3D backend, with more events in one tick than a backend's small
/// buffer: balls that land together each begin exactly once, a pair that falls asleep stays entered (no exit),
/// nearby but separate objects never begin, and taking the ground away ends every pair. Run with:
/// TallowLauncher --test-physics-contact-events [Jolt|Rapier]
static class PhysicsContactEventsTest
{
	[Component]
	class Probe : Component
	{
		public int32 enters, stays, exits;

		public override void OnCollisionEnter(Collision collision) { enters++; }
		public override void OnCollisionStay(Collision collision) { stays++; }
		public override void OnCollisionExit(Collision collision) { exits++; }
	}

	static int Check(StringView what, bool ok)
	{
		Console.WriteLine(scope $"[{(ok ? "PASS" : "FAIL")}] {what}");
		return ok ? 0 : 1;
	}

	static void Tick(Scene scene, int count)
	{
		for (int i < count)
		{
			scene.Physics.Step(1.0f / 60.0f);
			scene.Physics.DispatchContacts(scene);
		}
	}

	public static int Run(StringView backend)
	{
		PhysicsBackends.Override3D(backend);
		int failures = 0;
		let scene = scope Scene();
		Console.WriteLine(scope $"[contact events] backend {backend}");

		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(40, 1, 40);
		let groundBody = scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null);

		// 100 balls at the same height land in the same tick: more begin events than one 64-entry buffer holds.
		let balls = scope List<Probe>();
		for (int i < 100)
		{
			let obj = scene.CreateGameObject("Ball");
			obj.Transform.Position = Vector3((i % 10) * 2 - 9, 1.5f, (i / 10) * 2 - 9);
			let collider = obj.AddComponent<SphereCollider>();
			collider.radius = 0.5f;
			RigidbodyData data = .();
			data.mass = 1;
			scene.Physics.CreateBody(obj.Transform, collider.GetShape(), &data);
			balls.Add(obj.AddComponent<Probe>());
		}

		// A kinematic ball beside the top corner of a box resting on the ground: their bounding boxes overlap, the
		// shapes are 0.19 m apart, so the pair never begins.
		let shelf = scene.CreateGameObject("Shelf");
		shelf.Transform.Position = Vector3(15, 1.5f, 0);
		let shelfCollider = shelf.AddComponent<BoxCollider>();
		shelfCollider.size = Vector3(2, 2, 2);
		RigidbodyData shelfData = .();
		shelfData.mass = 5;
		scene.Physics.CreateBody(shelf.Transform, shelfCollider.GetShape(), &shelfData);
		let hover = scene.CreateGameObject("Hover");
		hover.Transform.Position = Vector3(16.4f, 2.9f, 1.4f);
		let hoverCollider = hover.AddComponent<SphereCollider>();
		hoverCollider.radius = 0.5f;
		RigidbodyData kinematic = .();
		kinematic.isKinematic = true;
		scene.Physics.CreateBody(hover.Transform, hoverCollider.GetShape(), &kinematic);
		let hoverProbe = hover.AddComponent<Probe>();

		Tick(scene, 60);
		int32 minEnters = int32.MaxValue, maxEnters = 0, exits = 0;
		for (let ball in balls)
		{
			minEnters = Math.Min(minEnters, ball.enters);
			maxEnters = Math.Max(maxEnters, ball.enters);
			exits += ball.exits;
		}
		failures += Check(scope $"every landing ball began exactly once (min {minEnters}, max {maxEnters})", minEnters == 1 && maxEnters == 1);
		failures += Check("no ball ended while resting", exits == 0);
		failures += Check(scope $"a ball near but not touching a box never began ({hoverProbe.enters})", hoverProbe.enters == 0);

		// Long enough for the pile to sleep: still entered, nothing ends.
		Tick(scene, 600);
		exits = 0;
		int32 enters = 0;
		for (let ball in balls)
		{
			exits += ball.exits;
			enters += ball.enters;
		}
		failures += Check("sleeping balls stay entered (no exits, no new begins)", exits == 0 && enters == 100);

		scene.Physics.DestroyBody(groundBody);
		Tick(scene, 5);
		int32 ended = 0;
		for (let ball in balls)
			ended += ball.exits > 0 ? 1 : 0;
		failures += Check(scope $"taking the ground away ended every pair ({ended}/100)", ended == 100);

		Console.WriteLine(failures == 0 ? "CONTACT EVENTS PASS" : scope $"CONTACT EVENTS FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}
}
