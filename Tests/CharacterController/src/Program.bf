using System;
using System.Collections;
using Tallow;

namespace CharacterControllerTests;

class Program
{
	const float Dt = 1 / 60f;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static void Box(Scene scene, Vector3 min, Vector3 max, Quaternion rotation = .Identity)
	{
		let go = scene.CreateGameObject("Level");
		go.Transform.Position = (min + max) * 0.5f;
		go.Transform.Rotation = rotation;
		ShapeDesc desc = default;
		desc.kind = .Box;
		desc.halfExtents = (max - min) * 0.5f;
		scene.Physics.CreateBody(go.Transform, desc, null);
	}

	static CharacterController Spawn(Scene scene, Vector3 position, CharacterShape shape)
	{
		let go = scene.CreateGameObject("Character");
		go.Transform.Position = position;
		let controller = go.AddComponent<CharacterController>();
		controller.shape = shape;
		if (shape == .Box)
		{
			controller.boxSize = .(0.8f, 1.0f, 0.8f);
			controller.edgeRadius = 0.12f;
		}
		controller.Start();
		return controller;
	}

	/// Walks at a horizontal velocity for a number of ticks; returns the lowest grounded ratio seen is not needed, only the end state.
	static int Walk(Scene scene, CharacterController controller, Vector3 velocity, int ticks, float jump = 0)
	{
		int airborne = 0;
		for (int i < ticks)
		{
			controller.SimpleMove(velocity, Dt, i == 0 ? jump : 0);
			scene.Physics.Step(Dt);
			if (!controller.IsGrounded)
				airborne++;
		}
		return airborne;
	}

	public static int Main(String[] args)
	{
		let scene = scope Scene();
		Scene.Active = scene;
		bool ok = true;
		Box(scene, .(-20, -1, -20), .(20, 0, 20));
		// Lane x=0: six 0.25 m steps starting at z=2, the last one a long landing.
		for (int i < 6)
			Box(scene, .(-1, 0, 2 + i * 0.5f), .(1, (i + 1) * 0.25f, i == 5 ? 9 : 2.5f + i * 0.5f));
		// Lane x=5: one 0.8 m ledge, taller than any step height used here.
		Box(scene, .(4, 0, 2), .(6, 0.8f, 4));
		// Lane x=-5: a ramp rising about 1 m over 4 m.
		Box(scene, .(-6.25f, -0.1f, -2.1f), .(-3.75f, 0.1f, 2.1f));
		scene.Physics.[Friend]mEntries.Back.transform.SetPositionAndRotation(.(-5, 0.403f, 5.46f), .(-0.12014f, 0, 0, 0.99276f));
		scene.Physics.Step(Dt);

		let capsule = Spawn(scene, .(0, 1.5f, 0), .Capsule);
		ok &= Check(capsule.HasCharacter && !capsule.IsGrounded, "capsule starts in the air above the floor");
		Walk(scene, capsule, .Zero, 90);
		ok &= Check(capsule.IsGrounded && Math.Abs(capsule.Transform.Position.y - 0.9f) < 0.06f, "capsule falls and stands on the floor");
		let airborne = Walk(scene, capsule, .(0, 0, 3), 150);
		var p = capsule.Transform.Position;
		ok &= Check(p.z > 6 && Math.Abs(p.y - 2.4f) < 0.08f, "capsule walks up a flight of 0.25 m steps");
		ok &= Check(airborne < 20, "capsule is on the ground for nearly all of the climb");
		let down = Walk(scene, capsule, .(0, 0, -3), 150);
		p = capsule.Transform.Position;
		ok &= Check(p.z < 1.5f && Math.Abs(p.y - 0.9f) < 0.08f && down < 40, "capsule follows the steps back down");
		Walk(scene, capsule, .Zero, 5);
		let before = capsule.Transform.Position.y;
		let air = Walk(scene, capsule, .Zero, 20, 6);
		ok &= Check(air > 15 && capsule.Transform.Position.y > before + 0.8f, "jump leaves the ground");
		Walk(scene, capsule, .Zero, 120);
		ok &= Check(capsule.IsGrounded && Math.Abs(capsule.Transform.Position.y - before) < 0.05f, "and lands again");

		let blocked = Spawn(scene, .(5, 0.95f, 0), .Capsule);
		Walk(scene, blocked, .(0, 0, 3), 180);
		ok &= Check(blocked.Transform.Position.z < 1.75f && blocked.Transform.Position.y < 1.0f, "a ledge taller than the step height stops the capsule");
		blocked.stepHeight = 0.9f;
		Walk(scene, blocked, .(0, 0, 3), 40);
		ok &= Check(blocked.Transform.Position.z > 2.2f && blocked.Transform.Position.y > 1.6f, "raising the step height lets it climb the ledge");

		let cube = Spawn(scene, .(0.2f, 0.6f, 0), .Box);
		Walk(scene, cube, .Zero, 30);
		ok &= Check(cube.IsGrounded && Math.Abs(cube.Transform.Position.y - 0.5f) < 0.06f, "rounded box stands on the floor");
		let cubeAir = Walk(scene, cube, .(0, 0, 3), 150);
		p = cube.Transform.Position;
		ok &= Check(p.z > 6 && Math.Abs(p.y - 2.0f) < 0.08f && cubeAir < 8, "rounded box walks up the same steps");

		let sloped = Spawn(scene, .(-5, 0.6f, 2.5f), .Box);
		Walk(scene, sloped, .Zero, 20);
		Walk(scene, sloped, .(0, 0, 2), 100);
		ok &= Check(sloped.Transform.Position.y > 1.0f && sloped.IsGrounded, "box walks up a ramp and stays grounded");
		sloped.maxSlope = 5;
		sloped.ApplyShape();
		let high = sloped.Transform.Position.y;
		Walk(scene, sloped, .Zero, 120);
		ok &= Check(!sloped.IsGrounded || sloped.Transform.Position.y < high - 0.2f, "a slope steeper than Max Slope is not standable");

		// Inner body: rays and shape queries find the character and name its object.
		RaycastHit ray;
		ok &= Check(scene.Physics.Raycast(cube.Transform.Position + .(3, 0, 0), .(-1, 0, 0), 10, out ray) && ray.gameObject == cube.GameObject && Math.Abs(ray.distance - 2.6f) < 0.05f, "raycast hits the character and reports its object");

		// Changing shape: refused where it does not fit, accepted in the open.
		let prop = Spawn(scene, .(10, 0.6f, 10), .Box);
		Walk(scene, prop, .Zero, 30);
		Box(scene, .(9, 1.3f, 9), .(11, 1.5f, 11));
		scene.Physics.Step(Dt);
		ok &= Check(!prop.SetCapsule(0.35f, 1.8f, .(0, 0.4f, 0)) && prop.shape == .Box && prop.boxSize.y == 1.0f, "a taller shape is refused under a low ceiling and nothing changes");
		ok &= Check(prop.SetBox(.(0.5f, 0.6f, 0.5f), 0.05f, .(0, -0.2f, 0)) && prop.HasCharacter, "a smaller shape is accepted");
		Walk(scene, prop, .(2, 0, 0), 120);
		ok &= Check(prop.IsGrounded && prop.Transform.Position.x > 13 && Math.Abs(prop.Transform.Position.y - 0.5f) < 0.06f, "and keeps walking with the new shape");
		ok &= Check(prop.SetCapsule(0.35f, 1.8f, .(0, 0.4f, 0)) && prop.shape == .Capsule, "the taller shape fits once clear of the ceiling");

		// Network state: position and falling speed survive capture and restore.
		let net = Spawn(scene, .(-10, 5, -10), .Capsule);
		let identity = net.GameObject.AddComponent<NetworkIdentity>();
		Walk(scene, net, .Zero, 20);
		let saved = identity.CaptureState();
		Walk(scene, net, .Zero, 20);
		let later = net.Transform.Position;
		identity.ApplyState(saved);
		ok &= Check(saved.linearVelocity.y < -2 && (net.Transform.Position - saved.position).Length < 0.001f && Math.Abs(net.Velocity.y - saved.linearVelocity.y) < 0.001f, "captured state restores position and falling speed");
		Walk(scene, net, .Zero, 20);
		ok &= Check((net.Transform.Position - later).Length < 0.002f, "replaying from the restored state lands in the same place");

		// CharacterMotor drives a controller offline; Shift sprints.
		let player = Spawn(scene, .(-10, 0.95f, -18), .Capsule);
		let motor = player.GameObject.AddComponent<CharacterMotor>();
		NetInput input = default;
		input.moveZ = 1;
		for (int i < 120)
		{
			motor.Simulate(input, Dt);
			scene.Physics.Step(Dt);
		}
		let walked = player.Transform.Position.z;
		input.SetButton(CharacterMotor.SprintButton, true);
		for (int i < 120)
		{
			motor.Simulate(input, Dt);
			scene.Physics.Step(Dt);
		}
		ok &= Check(Math.Abs(walked + 18 - 11.5f) < 1.0f && Math.Abs(player.Transform.Position.z - walked - 17.5f) < 1.0f && player.IsGrounded, "character motor walks and sprints through the controller");
		input = default;
		input.SetButton(CharacterMotor.JumpButton, true);
		motor.Simulate(input, Dt);
		input = default;
		for (int i < 10)
		{
			motor.Simulate(input, Dt);
			scene.Physics.Step(Dt);
		}
		ok &= Check(!player.IsGrounded && player.Velocity.y > 0, "character motor jumps from the ground");

		// A dynamic crate in the way gets pushed rather than stopping the character dead.
		let crate = scene.CreateGameObject("Crate");
		crate.Transform.Position = .(15, 0.5f, -10);
		crate.AddComponent<BoxCollider>();
		let body = crate.AddComponent<Rigidbody>();
		body.mass = 5;
		body.EnsureBody();
		let pusher = Spawn(scene, .(13.5f, 0.95f, -10), .Capsule);
		Walk(scene, pusher, .(2, 0, 0), 180);
		ok &= Check(crate.Transform.Position.x > 15.5f && pusher.Transform.Position.x > 14.5f, "character pushes a dynamic crate");

		// Jump grace: a jump pressed just after walking off a ledge still works, once.
		let ledge = Spawn(scene, .(0, 2.45f, 8.3f), .Capsule);
		Walk(scene, ledge, .Zero, 30);
		int steps = 0;
		while (ledge.IsGrounded && steps++ < 120)
			Walk(scene, ledge, .(0, 0, 3), 1);
		ok &= Check(!ledge.IsGrounded && ledge.CanJump && ledge.AirTime > 0, "just past a ledge it is airborne but may still jump");
		let graceIdentity = ledge.GameObject.AddComponent<NetworkIdentity>();
		let grace = graceIdentity.CaptureState();
		ledge.SimpleMove(.Zero, Dt, 6);
		ok &= Check(ledge.Velocity.y > 4 && !ledge.CanJump, "the late jump takes off and uses up the grace");
		let rising = ledge.Velocity.y;
		ledge.SimpleMove(.Zero, Dt, 6);
		ok &= Check(ledge.Velocity.y < rising, "a second jump in the air is ignored");
		graceIdentity.ApplyState(grace);
		ok &= Check(ledge.CanJump && Math.Abs(ledge.AirTime - grace.angularVelocity.x) < 0.0001f, "a network rewind restores the grace");
		Walk(scene, ledge, .Zero, 15);
		ledge.SimpleMove(.Zero, Dt, 6);
		ok &= Check(!ledge.CanJump && ledge.Velocity.y < 0, "after the grace has run out a jump in the air does nothing");
		// On stairs the jump stays available on nearly every tick, edges included.
		let stairs = Spawn(scene, .(0.3f, 0.95f, 0), .Capsule);
		Walk(scene, stairs, .Zero, 20);
		int unavailable = 0;
		for (int i < 150)
		{
			Walk(scene, stairs, .(0, 0, 3), 1);
			if (!stairs.CanJump)
				unavailable++;
		}
		ok &= Check(stairs.Transform.Position.y > 2.3f && unavailable == 0, "jump is available on every tick of a stair climb");

		// Soft contact: two characters ease past each other instead of one stopping against the other.
		let still = Spawn(scene, .(-15, 0.95f, -15), .Capsule);
		let mover = Spawn(scene, .(-17, 0.95f, -15.2f), .Capsule);
		Walk(scene, still, .Zero, 20);
		Walk(scene, mover, .Zero, 20);
		float closest = float.MaxValue;
		for (int i < 150)
		{
			mover.SimpleMove(.(2, 0, 0), Dt);
			still.SimpleMove(.Zero, Dt);
			scene.Physics.Step(Dt);
			closest = Math.Min(closest, (mover.Transform.Position - still.Transform.Position).Length);
		}
		ok &= Check(mover.Transform.Position.x > -13.5f && (still.Transform.Position - Vector3(-15, 0.9f, -15)).Length > 0.15f, "a walking character gets past a standing one and nudges it aside");
		ok &= Check(closest > 0.3f && (mover.Transform.Position - still.Transform.Position).Length >= 0.69f, "they overlap only briefly and end up apart");
		// A solid character is a wall to others.
		let wall = Spawn(scene, .(-15, 0.95f, 15), .Capsule);
		wall.softCharacterContact = false;
		wall.ApplyShape();
		let bumper = Spawn(scene, .(-17, 0.95f, 15), .Capsule);
		Walk(scene, wall, .Zero, 20);
		Walk(scene, bumper, .Zero, 20);
		let wallAt = wall.Transform.Position;
		for (int i < 150)
		{
			bumper.SimpleMove(.(2, 0, 0), Dt);
			wall.SimpleMove(.Zero, Dt);
			scene.Physics.Step(Dt);
		}
		ok &= Check(bumper.Transform.Position.x < -15.6f && (wall.Transform.Position - wallAt).Length < 0.02f, "a character with soft contact off blocks others and is not moved");

		// A navigation agent that has a character controller walks its path through the controller, steps included.
		void Solid(Vector3 min, Vector3 max)
		{
			let go = scene.CreateGameObject("Nav Level");
			go.Transform.Position = (min + max) * 0.5f;
			let collider = go.AddComponent<BoxCollider>();
			collider.size = max - min;
			scene.Physics.CreateBody(go.Transform, collider.GetShape(), null);
		}
		Solid(.(30, -1, -5), .(40, 0, 5));
		Solid(.(34, 0, -5), .(40, 0.25f, 5));
		Solid(.(36, 0.25f, -5), .(40, 0.5f, 5));
		let surface = scene.CreateGameObject("Navigation").AddComponent<NavigationSurface>();
		surface.Transform.Position = .(30, -1, -5);
		surface.size = .(10, 4, 10);
		surface.cellSize = 0.5f;
		ok &= Check(surface.Bake(), "navigation bakes over the stepped floor");
		let walker = Spawn(scene, .(31, 0.5f, 0), .Capsule);
		walker.center = .(0, 0.9f, 0);
		walker.ApplyShape();
		let agent = walker.GameObject.AddComponent<NavigationAgent>();
		agent.surface = surface;
		Walk(scene, walker, .Zero, 60);
		agent.SetDestination(.(38.5f, 0.5f, 0), 3, 0.15f);
		Time.DeltaTime = Dt;
		for (int i = 0; i < 900 && !agent.HasArrived; i++)
		{
			agent.Update();
			agent.FixedUpdate();
			scene.Physics.Step(Dt);
		}
		p = walker.Transform.Position;
		ok &= Check(agent.HasArrived && !agent.PathFailed && Math.Abs(p.x - 38.5f) < 0.3f && Math.Abs(p.y - 0.52f) < 0.08f && walker.IsGrounded, "navigation agent with a controller climbs two steps to its destination");

		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
