using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless conformance run for the Rapier backend: queries (all-hits, casts, overlaps, checks, layer masks),
/// contact and trigger events, joints (ball, hinge motor, slider spring), the kinematic character, buoyancy, and
/// object-code filtering. Run with: TallowLauncher --test-physics-rapier
static class PhysicsRapierTest
{
	[Component]
	class ContactProbe : Component
	{
		public int32 enters, stays, exits, triggers;
		public GameObject lastOther;

		public override void OnCollisionEnter(Collision collision)
		{
			enters++;
			lastOther = collision.gameObject;
		}

		public override void OnCollisionStay(Collision collision)
		{
			stays++;
		}

		public override void OnCollisionExit(Collision collision)
		{
			exits++;
		}

		public override void OnTriggerEnter(GameObject other)
		{
			triggers++;
			lastOther = other;
		}
	}

	static uint64 MixBits(uint64 hash, float value)
	{
		uint32 bits = 0;
		Internal.MemCpy(&bits, &value, 4);
		var result = hash;
		result ^= bits;
		result *= 1099511628211;
		return result;
	}

	static int Check(StringView what, bool ok)
	{
		Console.WriteLine(scope $"[{(ok ? "PASS" : "FAIL")}] {what}");
		return ok ? 0 : 1;
	}

	static uint32 AddBox(Scene scene, StringView name, Vector3 position, Vector3 size, PhysicsMotion motion, float mass = 1)
	{
		let obj = scene.CreateGameObject(name);
		obj.Transform.Position = position;
		let collider = obj.AddComponent<BoxCollider>();
		collider.size = size;
		if (motion == .Dynamic)
		{
			RigidbodyData data = .();
			data.mass = mass;
			data.friction = 0.6f;
			return scene.Physics.CreateBody(obj.Transform, collider.GetShape(), &data);
		}
		if (motion == .Kinematic)
		{
			RigidbodyData data = .();
			data.isKinematic = true;
			return scene.Physics.CreateBody(obj.Transform, collider.GetShape(), &data);
		}
		return scene.Physics.CreateBody(obj.Transform, collider.GetShape(), null);
	}

	static ShapeDesc Sphere(float radius)
	{
		ShapeDesc shape = default;
		shape.kind = .Sphere;
		shape.radius = radius;
		return shape;
	}

	static ShapeDesc Capsule(float halfHeight, float radius)
	{
		ShapeDesc shape = default;
		shape.kind = .Capsule;
		shape.halfHeight = halfHeight;
		shape.radius = radius;
		return shape;
	}

	public static int Run()
	{
		PhysicsBackends.Override3D("Rapier");
		int failures = 0;
		let scene = scope Scene();

		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(30, 1, 30);
		let groundBody = scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null);
		failures += Check("ground body created", groundBody != uint32.MaxValue);

		// Three boxes in a row for the query tests. The first sits on layer 1, so a mask can leave it out.
		let boxScene = scene.CreateGameObject("Query Boxes");
		uint32[3] boxBodies = default;
		for (int i < 3)
		{
			let obj = scene.CreateGameObject(scope $"Query Box {i}");
			obj.Transform.Position = Vector3(-2 + i * 2, 3, 0);
			if (i == 0)
				obj.Layer = 1;
			let collider = obj.AddComponent<BoxCollider>();
			collider.size = Vector3.One;
			boxBodies[i] = scene.Physics.CreateBody(obj.Transform, collider.GetShape(), null);
			failures += Check(scope $"query box {i} created" , boxBodies[i] != uint32.MaxValue);
		}

		// ---- all-hits raycast
		let rayHits = scope List<RaycastHit>();
		let count = scene.Physics.RaycastAll(Vector3(-5, 3, 0), .Right, 20, rayHits);
		failures += Check("raycast_all found all three boxes", count == 3);
		bool ordered = true;
		for (int i = 1; i < rayHits.Count; i++)
			ordered &= rayHits[i - 1].distance <= rayHits[i].distance;
		failures += Check("raycast_all is nearest first", ordered);
		bool foundLayered = false;
		for (let hit in rayHits)
			foundLayered |= hit.bodyId == boxBodies[0];
		failures += Check("raycast_all names the layer-1 box", foundLayered);

		let masked = scope List<RaycastHit>();
		let maskedCount = scene.Physics.RaycastAll(Vector3(-5, 3, 0), .Right, 20, masked, ~((uint32)1 << 1));
		failures += Check("layer mask leaves the layer-1 box out", maskedCount == 2);

		// ---- shape casts
		ShapeCastHit shapeHit = default;
		failures += Check("sphere cast hits the first box",
			scene.Physics.SphereCast(Vector3(-5, 3, 0), 0.3f, .Right, 20, out shapeHit) && shapeHit.bodyId == boxBodies[0]);
		failures += Check("sphere cast hit has a normal", shapeHit.normal.LengthSquared > 0.5f);
		let castAll = scope List<ShapeCastHit>();
		failures += Check("sphere cast all finds three", scene.Physics.SphereCastAll(Vector3(-5, 3, 0), 0.3f, .Right, 20, castAll) == 3);

		// ---- overlaps and checks
		let overlaps = scope List<ShapeCastHit>();
		let overlapCount = scene.Physics.OverlapSphere(Vector3(-2, 3, 0), 0.9f, overlaps);
		bool overlapFound = false;
		for (let hit in overlaps)
			overlapFound |= hit.bodyId == boxBodies[0];
		failures += Check("overlap finds the box inside the sphere", overlapCount > 0 && overlapFound);
		failures += Check("check sphere is true where the box is", scene.Physics.CheckSphere(Vector3(-2, 3, 0), 0.9f));
		failures += Check("check sphere is false away from everything", !scene.Physics.CheckSphere(Vector3(20, 20, 20), 0.5f));

		// ---- contacts and triggers
		let faller = scene.CreateGameObject("Contact Ball");
		faller.Transform.Position = Vector3(8, 4, 0);
		let fallerCollider = faller.AddComponent<SphereCollider>();
		fallerCollider.radius = 0.5f;
		RigidbodyData fallerData = .();
		fallerData.mass = 1;
		let fallerBody = scene.Physics.CreateBody(faller.Transform, fallerCollider.GetShape(), &fallerData);
		let fallerProbe = faller.AddComponent<ContactProbe>();
		let groundProbe = ground.AddComponent<ContactProbe>();
		failures += Check("contact ball created", fallerBody != uint32.MaxValue);
		for (int i < 120)
		{
			scene.Physics.Step(1.0f / 60.0f);
			scene.Physics.DispatchContacts(scene);
		}
		failures += Check("collision enter fired", fallerProbe.enters > 0 && groundProbe.enters > 0);
		failures += Check("collision stay fired while resting", fallerProbe.stays > 0);
		failures += Check("contact normal is up", faller.Transform.Position.y > 0.9f && faller.Transform.Position.y < 1.1f);

		// Take the ground body away: the pair should end.
		let exitsBefore = fallerProbe.exits;
		scene.Physics.DestroyBody(groundBody);
		for (int i < 5)
		{
			scene.Physics.Step(1.0f / 60.0f);
			scene.Physics.DispatchContacts(scene);
		}
		failures += Check("collision exit fired when the ground went", fallerProbe.exits > exitsBefore);

		// A trigger notices the ball passing through it.
		let trigger = scene.CreateGameObject("Trigger");
		trigger.Transform.Position = Vector3(8, 0.2f, 0);
		let triggerCollider = trigger.AddComponent<BoxCollider>();
		triggerCollider.size = Vector3(3, 1, 3);
		triggerCollider.isTrigger = true;
		let triggerBody = scene.Physics.CreateBody(trigger.Transform, triggerCollider.GetShape(), null);
		let triggerProbe = trigger.AddComponent<ContactProbe>();
		failures += Check("trigger body created", triggerBody != uint32.MaxValue);
		faller.Transform.Position = Vector3(8, 3, 0);
		for (int i < 120)
		{
			scene.Physics.Step(1.0f / 60.0f);
			scene.Physics.DispatchContacts(scene);
		}
		failures += Check("trigger enter fired", triggerProbe.triggers > 0);

		// ---- joints
		let anchorBody = AddBox(scene, "Ball Anchor", Vector3(0, 8, 0), Vector3(0.2f), .Static);
		let swingBody = AddBox(scene, "Ball Swing", Vector3(1, 7, 0), Vector3(0.5f), .Dynamic);
		let ball = scene.Physics.CreateJoint(anchorBody, swingBody, Vector3(1, 7, 0), .Up, 0);
		failures += Check("ball joint created", ball != null);
		for (int i < 90)
			scene.Physics.Step(1.0f / 60.0f);
		let swingState = scene.Physics.GetState(swingBody);
		failures += Check("ball joint holds the body at its anchor",
			(swingState.position - Vector3(1, 7, 0)).Length < 0.25f);

		let frameBody = AddBox(scene, "Hinge Frame", Vector3(5, 8, 0), Vector3(0.2f), .Static);
		let doorBody = AddBox(scene, "Hinge Door", Vector3(6, 8, 0), Vector3(2, 2, 0.2f), .Dynamic);
		let hinge = scene.Physics.CreateHinge(frameBody, doorBody, Vector3(5, 8, 0), .Up, .Forward, .Right);
		failures += Check("hinge created", hinge != null);
		scene.Physics.SetHingeMotor(hinge, 1.5f, 200, 0, 1, 8, 3);
		for (int i < 90)
			scene.Physics.Step(1.0f / 60.0f);
		failures += Check("hinge motor turned the door", Math.Abs(scene.Physics.HingeAngle(hinge)) > 0.2f);

		let chassisBody = AddBox(scene, "Slider Chassis", Vector3(10, 8, 0), Vector3(1.5f), .Static);
		let wheelBody = AddBox(scene, "Slider Wheel", Vector3(10, 6.5f, 0), Vector3(0.5f), .Dynamic);
		let slider = scene.Physics.CreateSuspension(chassisBody, wheelBody, Vector3(10, 6.5f, 0), Vector3(10, 6.5f, 0),
			.Up, .Up, .Right, 0.5f);
		failures += Check("slider created", slider != null);
		scene.Physics.SetSuspensionSpring(slider, 500, 60);
		for (int i < 120)
			scene.Physics.Step(1.0f / 60.0f);
		let wheelState = scene.Physics.GetState(wheelBody);
		failures += Check("slider spring holds the wheel near its rest point",
			Math.Abs(scene.Physics.SuspensionPosition(slider)) < 0.7f && wheelState.position.y > 5.5f);

		// ---- kinematic character
		for (let id in boxBodies)
			scene.Physics.DestroyBody(id);
		scene.Physics.DestroyBody(groundBody);
		let floor = scene.CreateGameObject("Character Floor");
		let floorCollider = floor.AddComponent<BoxCollider>();
		floorCollider.size = Vector3(30, 1, 30);
		scene.Physics.CreateBody(floor.Transform, floorCollider.GetShape(), null);
		let wall = scene.CreateGameObject("Character Wall");
		wall.Transform.Position = Vector3(-4, 2, 0);
		let wallCollider = wall.AddComponent<BoxCollider>();
		wallCollider.size = Vector3(1, 4, 4);
		scene.Physics.CreateBody(wall.Transform, wallCollider.GetShape(), null);

		let walker = scene.CreateGameObject("Walker");
		walker.Transform.Position = Vector3(0, 4, 0);
		let character = scene.Physics.CreateCharacter(walker.Transform, Capsule(0.6f, 0.4f), .Identity, 45, 70, 100,
			0.2f, false);
		failures += Check("character created", character != null);
		var walkerState = scene.Physics.GetCharacterState(character);
		for (int i < 180)
			walkerState = scene.Physics.MoveCharacter(character, Vector3(0, -4, 0), 1.0f / 60.0f, 0.3f, 0.2f, false);
		failures += Check("character landed", walkerState.groundState == 0);
		failures += Check("character stands on the floor", Math.Abs(walkerState.position.y - 1.5f) < 0.35f);

		// A component-style capsule with its centre raised above the transform (CharacterController's default).
		let centeredWalker = scene.CreateGameObject("Centered Walker");
		centeredWalker.Transform.Position = Vector3(6, 4, 6);
		ShapeDesc centeredShape = Capsule(0.6f, 0.35f);
		centeredShape.center = Vector3(0, 0.95f, 0);
		let centeredCharacter = scene.Physics.CreateCharacter(centeredWalker.Transform, centeredShape, .Identity, 50,
			70, 100, 0.3f, false);
		failures += Check("centred character created", centeredCharacter != null);
		var centeredState = scene.Physics.GetCharacterState(centeredCharacter);
		for (int i < 180)
			centeredState = scene.Physics.MoveCharacter(centeredCharacter, Vector3(0, -4, 0), 1.0f / 60.0f, 0.28f, 0.2f, false);
		failures += Check("centred character lands", centeredState.groundState == 0);
		failures += Check("centred character keeps its transform on the floor",
			Math.Abs(centeredState.position.y - 0.5f) < 0.3f);

		// SimpleMove feeds the last vertical velocity back into the next step.
		// A contact margin must not become an upward launch on every grounded tick.
		const float step = 1.0f / 60.0f;
		float minHeight = float.MaxValue, maxHeight = -float.MaxValue;
		bool stayedGrounded = true;
		for (int i = 0; i < 90; i++)
		{
			let fall = centeredState.groundState == 0 && centeredState.velocity.y < 0.1f ? 0 : centeredState.velocity.y;
			centeredState = scene.Physics.MoveCharacter(centeredCharacter, Vector3(0, fall - 9.81f * step, 3),
				step, 0.28f, 0.2f, false);
			stayedGrounded &= centeredState.groundState == 0;
			minHeight = Math.Min(minHeight, centeredState.position.y);
			maxHeight = Math.Max(maxHeight, centeredState.position.y);
		}
		failures += Check("walking stays grounded without bouncing", stayedGrounded && maxHeight - minHeight < 0.002f);
		let tread = scene.CreateGameObject("Character Step");
		tread.Transform.Position = Vector3(6, 0.60f, 11.7f);
		let treadCollider = tread.AddComponent<BoxCollider>();
		treadCollider.size = Vector3(2, 0.20f, 1.2f);
		scene.Physics.CreateBody(tread.Transform, treadCollider.GetShape(), null);
		maxHeight = centeredState.position.y;
		float peakUpwardSpeed = 0;
		for (int i < 27)
		{
			let fall = centeredState.groundState == 0 && centeredState.velocity.y < 0.1f ? 0 : centeredState.velocity.y;
			centeredState = scene.Physics.MoveCharacter(centeredCharacter, Vector3(0, fall - 9.81f * step, 3),
				step, 0.28f, 0.2f, false);
			maxHeight = Math.Max(maxHeight, centeredState.position.y);
			peakUpwardSpeed = Math.Max(peakUpwardSpeed, centeredState.velocity.y);
		}
		failures += Check("character climbs a 20 cm step", centeredState.position.z > 11.5f &&
			Math.Abs(centeredState.position.y - 0.71f) < 0.03f);
		failures += Check("stepping up does not launch the character",
			maxHeight < 0.74f && peakUpwardSpeed < 0.1f);

		let from = centeredState.position.y;
		centeredState = scene.Physics.MoveCharacter(centeredCharacter, Vector3(0, 5, 0), step, 0.28f, 0.2f, false);
		failures += Check("an intentional jump still moves upward", centeredState.position.y > from + 0.06f);

		int wallHits = 0;
		for (int i = 0; i < 120 && wallHits == 0; i++)
		{
			walkerState = scene.Physics.MoveCharacter(character, Vector3(-5, -0.5f, 0), 1.0f / 60.0f, 0.3f, 0.2f, false);
			CharacterHit[16] hits = ?;
			wallHits = scene.Physics.CharacterHits(character, hits);
		}
		failures += Check("character reports what it ran into", wallHits > 0);

		// ---- buoyancy
		let floater = scene.CreateGameObject("Floater");
		floater.Transform.Position = Vector3(20, 0.2f, 0);
		let floaterCollider = floater.AddComponent<SphereCollider>();
		floaterCollider.radius = 0.5f;
		RigidbodyData floaterData = .();
		floaterData.mass = 1;
		floaterData.linearDamping = 0.1f;
		let floaterBody = scene.Physics.CreateBody(floater.Transform, floaterCollider.GetShape(), &floaterData);
		for (int i < 360)
		{
			scene.Physics.ApplyBuoyancy(floaterBody, Vector3(20, 0.5f, 0), .Up, 2.5f, 2, 2, .Zero, 1.0f / 60.0f);
			scene.Physics.Step(1.0f / 60.0f);
		}
		// With a one-step buoyancy force the half-metre sphere settles near y = 0.6:
		// the backend's submerged AABB fraction balances gravity at 1 / 2.5.
		failures += Check("buoyancy supports the body near its equilibrium",
			Math.Abs(floater.Transform.Position.y - 0.6f) < 0.08f);

		// A force and an off-center twist requested once must be consumed by that step.
		let forceObject = scene.CreateGameObject("One-step load");
		forceObject.Transform.Position = Vector3(26, 10, 15);
		let forceCollider = forceObject.AddComponent<BoxCollider>();
		RigidbodyData forceData = .();
		forceData.useGravity = false;
		forceData.linearDamping = 0;
		forceData.angularDamping = 0;
		let forceBody = scene.Physics.CreateBody(forceObject.Transform, forceCollider.GetShape(), &forceData);
		scene.Physics.AddForce(forceBody, Vector3(10, 0, 0));
		scene.Physics.AddTorque(forceBody, Vector3(2, 0, 0));
		scene.Physics.Step(step);
		let afterLoad = scene.Physics.GetState(forceBody);
		for (int i = 0; i < 20; i++)
			scene.Physics.Step(step);
		let withoutLoad = scene.Physics.GetState(forceBody);
		failures += Check("force and torque apply for one step only",
			afterLoad.linearVelocity.x > 0.01f && afterLoad.angularVelocity.x > 0.01f &&
			(withoutLoad.linearVelocity - afterLoad.linearVelocity).Length < 0.001f &&
			(withoutLoad.angularVelocity - afterLoad.angularVelocity).Length < 0.001f);

		// ---- freeze rotation
		let frozenObject = scene.CreateGameObject("Frozen");
		frozenObject.Transform.Position = Vector3(-8, 6, 8);
		let frozenCollider = frozenObject.AddComponent<BoxCollider>();
		frozenCollider.size = Vector3.One;
		RigidbodyData frozenData = .();
		frozenData.mass = 1;
		frozenData.freezeRotation = true;
		let frozenBody = scene.Physics.CreateBody(frozenObject.Transform, frozenCollider.GetShape(), &frozenData);
		scene.Physics.AddForceAtPosition(frozenBody, Vector3(50, 0, 0), Vector3(-8, 6.5f, 8));
		for (int i < 60)
			scene.Physics.Step(1.0f / 60.0f);
		failures += Check("freeze rotation keeps the body upright",
			Math.Abs(Quaternion.Dot(scene.Physics.GetState(frozenBody).rotation, .Identity)) > 0.995f);

		// ---- debris is passed through by a raycast
		let debrisObject = scene.CreateGameObject("Debris");
		debrisObject.Transform.Position = Vector3(-12, 3, 0);
		let debrisCollider = debrisObject.AddComponent<BoxCollider>();
		debrisCollider.size = Vector3.One;
		RigidbodyData debrisData = .();
		debrisData.mass = 1;
		debrisData.debris = true;
		scene.Physics.CreateBody(debrisObject.Transform, debrisCollider.GetShape(), &debrisData);
		let solidObject = scene.CreateGameObject("Solid Behind Debris");
		solidObject.Transform.Position = Vector3(-16, 3, 0);
		let solidCollider = solidObject.AddComponent<BoxCollider>();
		solidCollider.size = Vector3.One;
		scene.Physics.CreateBody(solidObject.Transform, solidCollider.GetShape(), null);
		RaycastHit debrisHit = default;
		if (scene.Physics.Raycast(Vector3(-8, 3, 0), .Left, 20, out debrisHit))
			failures += Check("a ray passes through debris", debrisHit.gameObject == solidObject);
		else
			failures += Check("a ray passes through debris", false);

		// ---- separated world states
		ProjectConfig.AddWorldState("Rapier Test State");
		ProjectConfig.SeparateWorldStates = true;
		let worlds = scope Scene();
		let stateGround = worlds.CreateGameObject("State Ground");
		let stateGroundCollider = stateGround.AddComponent<BoxCollider>();
		stateGroundCollider.size = Vector3(10, 1, 10);
		worlds.Physics.CreateBody(stateGround.Transform, stateGroundCollider.GetShape(), null);
		let blocker = worlds.CreateGameObject("State B Blocker");
		blocker.Transform.Position = Vector3(0, 2, 0);
		blocker.WorldStates = 1u << 1;
		let blockerCollider = blocker.AddComponent<BoxCollider>();
		blockerCollider.size = Vector3(3, 1, 3);
		worlds.Physics.CreateBody(blocker.Transform, blockerCollider.GetShape(), null);
		let stateFaller = worlds.CreateGameObject("State A Faller");
		stateFaller.Transform.Position = Vector3(0, 6, 0);
		stateFaller.WorldStates = 1u << 0;
		let stateFallerCollider = stateFaller.AddComponent<BoxCollider>();
		stateFallerCollider.size = Vector3.One;
		RigidbodyData stateFallerData = .();
		stateFallerData.mass = 1;
		worlds.Physics.CreateBody(stateFaller.Transform, stateFallerCollider.GetShape(), &stateFallerData);
		for (int i < 150)
			worlds.Physics.Step(1.0f / 60.0f);
		failures += Check("bodies in separate world states pass through each other", stateFaller.Transform.Position.y < 1.5f);

		RaycastHit stateHit = default;
		worlds.Physics.QueryWorldStates = 1u << 0;
		let sawFaller = worlds.Physics.Raycast(Vector3(0, 10, 0), .Down, 20, out stateHit) && stateHit.gameObject == stateFaller;
		failures += Check("a query in state A sees the state-A body", sawFaller);
		worlds.Physics.QueryWorldStates = 1u << 1;
		let sawBlocker = worlds.Physics.Raycast(Vector3(0, 10, 0), .Down, 20, out stateHit) && stateHit.gameObject == blocker;
		failures += Check("a query in state B sees the state-B body", sawBlocker);
		worlds.Physics.QueryWorldStates = uint32.MaxValue;
		ProjectConfig.SeparateWorldStates = false;
		ProjectConfig.Reset();

		// ---- exact and shared snapshots
		{
			let snapshotObject = scene.CreateGameObject("Snapshot Ball");
			snapshotObject.Transform.Position = Vector3(14, 5, 8);
			let snapshotCollider = snapshotObject.AddComponent<SphereCollider>();
			snapshotCollider.radius = 0.5f;
			RigidbodyData snapshotData = .();
			snapshotData.mass = 1;
			let snapshotBody = scene.Physics.CreateBody(snapshotObject.Transform, snapshotCollider.GetShape(), &snapshotData);
			for (int i < 30)
				scene.Physics.Step(1.0f / 60.0f);
			failures += Check("Rapier advertises exact snapshots",
				scene.Physics.Supports(.SaveRestoreExact) && scene.Physics.Supports(.SharedPhysicsState) &&
				scene.Physics.Supports(.CrossPlatformDeterminism) && scene.Physics.CanLockstep);
			let before = scene.Physics.GetState(snapshotBody);
			let exact = scene.Physics.SaveExact(null);
			for (int i < 30)
				scene.Physics.Step(1.0f / 60.0f);
			let restored = scene.Physics.RestoreExact(exact);
			let after = scene.Physics.GetState(snapshotBody);
			scene.Physics.FreeExact(exact);
			failures += Check("exact snapshot restores the body", restored &&
				after.position == before.position && after.rotation == before.rotation &&
				after.linearVelocity == before.linearVelocity);

			let shared = scope List<uint8>();
			let sharedBefore = scene.Physics.GetState(snapshotBody);
			scene.Physics.SaveShared(0, shared);
			scene.Physics.SetState(snapshotBody, before);
			scene.Physics.RestoreShared(shared);
			let sharedAfter = scene.Physics.GetState(snapshotBody);
			failures += Check("shared state restores the body", shared.Count > 0 &&
				sharedAfter.position == sharedBefore.position && sharedAfter.rotation == sharedBefore.rotation);
		}

		// ---- cross-platform determinism: a fixed scene and steps, hashed from the raw float bits
		{
			let deterministic = scope Scene();
			let detGround = deterministic.CreateGameObject("Det Ground");
			let detGroundCollider = detGround.AddComponent<BoxCollider>();
			detGroundCollider.size = Vector3(40, 1, 40);
			deterministic.Physics.CreateBody(detGround.Transform, detGroundCollider.GetShape(), null);
			let detBodies = scope List<uint32>();
			for (int i < 8)
			{
				let object = deterministic.CreateGameObject(scope $"Det {i}");
				object.Transform.Position = Vector3(-3 + i * 0.8f, 2 + i * 0.4f, (i % 3) * 0.5f);
				let collider = object.AddComponent<BoxCollider>();
				collider.size = Vector3(0.5f + i * 0.05f);
				RigidbodyData data = .();
				data.mass = 1 + i * 0.25f;
				data.friction = 0.4f + i * 0.02f;
				detBodies.Add(deterministic.Physics.CreateBody(object.Transform, collider.GetShape(), &data));
			}
			for (int i < 240)
				deterministic.Physics.Step(1.0f / 60.0f);
			uint64 hash = 1469598103934665603;
			for (let id in detBodies)
			{
				let state = deterministic.Physics.GetState(id);
				hash = MixBits(hash, state.position.x);
				hash = MixBits(hash, state.position.y);
				hash = MixBits(hash, state.position.z);
				hash = MixBits(hash, state.rotation.x);
				hash = MixBits(hash, state.rotation.y);
				hash = MixBits(hash, state.rotation.z);
				hash = MixBits(hash, state.rotation.w);
				hash = MixBits(hash, state.linearVelocity.x);
				hash = MixBits(hash, state.linearVelocity.y);
				hash = MixBits(hash, state.linearVelocity.z);
				hash = MixBits(hash, state.angularVelocity.x);
				hash = MixBits(hash, state.angularVelocity.y);
				hash = MixBits(hash, state.angularVelocity.z);
			}
			Console.WriteLine(scope $"PHYSICS STATEHASH {hash:X16}");
		}

		Console.WriteLine(failures == 0 ? "PHYSICS RAPIER PASS" : scope $"PHYSICS RAPIER FAIL ({failures})");
		return failures == 0 ? 0 : 1;
	}
}
