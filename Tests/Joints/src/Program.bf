using System;
using System.Collections;
using Tallow;

namespace JointTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static Rigidbody Box(Scene scene, StringView name, Vector3 position, Vector3 size, bool kinematic = false, bool debris = false)
	{
		let object = scene.CreateGameObject(name);
		object.Transform.Position = position;
		object.AddComponent<BoxCollider>().size = size;
		let body = object.AddComponent<Rigidbody>();
		body.isKinematic = kinematic;
		body.debris = debris;
		body.allowSleeping = false;
		body.EnsureBody();
		return body;
	}

	static void Run(Scene scene, int ticks)
	{
		for (int i < ticks)
			scene.FixedUpdate();
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		// A weight on a ball joint under a fixed point swings instead of falling.
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let post = Box(scene, "Post", .(0, 10, 0), .(0.2f, 0.2f, 0.2f), true);
			let weight = Box(scene, "Weight", .(2, 10, 0), .(0.4f, 0.4f, 0.4f));
			let free = Box(scene, "Free", .(5, 10, 0), .(0.4f, 0.4f, 0.4f));
			let joint = Joint.Connect(weight, post, .(0, 10, 0), .Down);
			ok &= Check(joint != null && joint.IsConnected, "two bodies can be joined");
			float lowest = 10, furthest = 0;
			for (int i < 240)
			{
				scene.FixedUpdate();
				lowest = Math.Min(lowest, weight.Transform.Position.y);
				furthest = Math.Max(furthest, Math.Abs((weight.Transform.Position - post.Transform.Position).Length - 2));
			}
			ok &= Check(furthest < 0.15f && lowest > 7.8f && lowest < 8.3f, scope $"the jointed body swings at the length of its arm (lowest {lowest}, drift {furthest})");
			ok &= Check(free.Transform.Position.y < -20, "while one with no joint just falls");
			// Destroying a body takes its joints with it; the other is then free.
			scene.DestroyImmediate(post.GameObject);
			ok &= Check(!joint.IsConnected, "a joint goes when one of its bodies does");
			let before = weight.Transform.Position.y;
			Run(scene, 120);
			ok &= Check(weight.Transform.Position.y < before - 5, "and what it held falls");
			scene.StopPlay();
		}
		// A cone limit keeps a limb from swinging further than it should.
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let post = Box(scene, "Post", .(0, 10, 0), .(0.2f, 0.2f, 0.2f), true);
			let limb = Box(scene, "Limb", .(0, 9, 0), .(0.2f, 0.2f, 0.2f));
			Joint.Connect(limb, post, .(0, 10, 0), .Down, 20);
			float widest = 0;
			for (int i < 240)
			{
				// Shove it sideways hard; the limit is what stops it.
				if (i < 30)
					limb.AddForce(.(12, 0, 0));
				scene.FixedUpdate();
				let arm = limb.Transform.Position - post.Transform.Position;
				widest = Math.Max(widest, Math.Acos(Mathf.Clamp(Vector3.Dot(arm.Normalized, .Down), -1, 1)) * Mathf.Rad2Deg);
			}
			// Unlimited, that shove would carry it right over the top. A hard knock can push a little past the limit.
			ok &= Check(widest > 5 && widest < 40, scope $"a swing limit holds ({widest} degrees at most under a hard shove, limit 20)");
			scene.StopPlay();
		}
		// Debris lies on scenery, and nothing else notices it.
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let floor = scene.CreateGameObject("Floor");
			floor.AddComponent<BoxCollider>().size = .(20, 1, 20);
			floor.Transform.Position = .(0, -0.5f, 0);
			Run(scene, 2);
			let rubble = Box(scene, "Rubble", .(0, 0.6f, 0), .(1, 1, 1), false, true);
			let crate = Box(scene, "Crate", .(0, 3, 0), .(0.5f, 0.5f, 0.5f));
			let walker = scene.CreateGameObject("Walker");
			walker.Transform.Position = .(-4, 0, 0);
			let controller = walker.AddComponent<CharacterController>();
			controller.center = .(0, 0.9f, 0);
			controller.Start();
			for (int i < 180)
			{
				controller.SimpleMove(.(3, 0, 0), Time.FixedDeltaTime);
				scene.FixedUpdate();
			}
			ok &= Check(Math.Abs(rubble.Transform.Position.y - 0.5f) < 0.05f, scope $"debris rests on the floor ({rubble.Transform.Position.y})");
			ok &= Check(crate.Transform.Position.y < 0.4f, scope $"an ordinary body falls straight through it ({crate.Transform.Position.y})");
			ok &= Check(walker.Transform.Position.x > 3, scope $"a character walks through it ({walker.Transform.Position.x})");
			RaycastHit ray;
			ok &= Check(scene.Physics.Raycast(.(0, 5, 0.3f), .Down, 20, out ray) && ray.gameObject == floor && Math.Abs(ray.point.y) < 0.01f, "a ray passes through it to what is behind");
			ShapeCastHit cast;
			ok &= Check(scene.Physics.SphereCast(.(0.3f, 5, 0.3f), 0.1f, .Down, 20, out cast) && cast.gameObject == floor, "and so does a shape cast");
			List<ShapeCastHit> hits = scope .();
			scene.Physics.OverlapSphere(rubble.Transform.Position, 0.3f, hits);
			bool found = false;
			for (let hit in hits)
			{
				if (hit.gameObject == rubble.GameObject)
					found = true;
			}
			ok &= Check(!found && scene.Physics.IsDebris(rubble.BodyId) && !scene.Physics.IsDebris(crate.BodyId), "overlaps do not report it");
			scene.StopPlay();
		}
		Console.WriteLine(ok ? "ALL PASSED" : "FAILED");
		return ok ? 0 : 1;
	}
}
