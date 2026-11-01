using System;
using System.Collections;
using Tallow;

namespace ShapeQueryTests;

class Program
{
	static bool Check(bool condition, StringView name)
	{
		Console.WriteLine(scope $"{condition ? "PASS" : "FAIL"}: {name}");
		return condition;
	}

	static uint32 AddBox(Scene scene, Vector3 position, Vector3 size, out GameObject go)
	{
		go = scene.CreateGameObject("Target");
		go.Transform.Position = position;
		ShapeDesc desc = default;
		desc.kind = .Box;
		desc.halfExtents = size * 0.5f;
		return scene.Physics.CreateBody(go.Transform, desc, null);
	}

	static bool InteriorContacts()
	{
		let scene = scope Scene();
		let go = scene.CreateGameObject("Rotated contact target");
		go.Transform.Position = .(3, 2, -4);
		go.Transform.Rotation = Quaternion.Euler(15, 37, 23);
		ShapeDesc shape = default;
		shape.kind = .Box;
		shape.halfExtents = .(1, 2, 3);
		let targetId = scene.Physics.CreateBody(go.Transform, shape, null);
		let fast = scope List<ShapeCastHit>();
		let generic = scope List<ShapeCastHit>();
		bool ok = true;
		// Six nearest faces, several radii, translated and rotated targets, and three aligned capsule axes.
		for (int axis < 3)
		{
			for (int sign < 2)
			{
				for (int r < 3)
				{
					var offset = Vector3.Zero;
					if (axis == 0)
						offset.x = sign == 0 ? 0.7f : -0.7f;
					if (axis == 1)
						offset.y = sign == 0 ? 1.7f : -1.7f;
					if (axis == 2)
						offset.z = sign == 0 ? 2.7f : -2.7f;
					let at = go.Transform.Position + go.Transform.Rotation * offset;
					let radius = 0.1f + r * 0.6f;
					scene.Physics.useAnalyticOverlapContacts = true;
					scene.Physics.OverlapSphere(at, radius, fast);
					scene.Physics.useAnalyticOverlapContacts = false;
					scene.Physics.OverlapSphere(at, radius, generic);
					ok &= fast.Count == 1 && generic.Count == 1;
					if (fast.Count == 1 && generic.Count == 1)
						ok &= Math.Abs(fast[0].penetrationDepth - (radius + 0.3f)) < 0.001f && Math.Abs(fast[0].penetrationDepth - generic[0].penetrationDepth) < 0.03f && (fast[0].normal - generic[0].normal).Length < 0.1f && (fast[0].point - generic[0].point).Length < 0.05f;
					let direction = go.Transform.Rotation * (axis == 0 ? Vector3.Right : axis == 1 ? Vector3.Up : Vector3.Forward);
					scene.Physics.useAnalyticOverlapContacts = true;
					scene.Physics.OverlapCapsule(at - direction * 0.2f, at + direction * 0.2f, radius, fast);
					scene.Physics.useAnalyticOverlapContacts = false;
					scene.Physics.OverlapCapsule(at - direction * 0.2f, at + direction * 0.2f, radius, generic);
					ok &= fast.Count == 1 && generic.Count == 1;
					if (fast.Count == 1 && generic.Count == 1)
						ok &= Math.Abs(fast[0].penetrationDepth - generic[0].penetrationDepth) < 0.03f && Math.Abs(fast[0].normal.Length - 1) < 0.001f;
				}
			}
		}
		scene.Physics.useAnalyticOverlapContacts = true;
		ok &= scene.Physics.OverlapSphere(go.Transform.Position, 0.7f, fast, targetId) == 0;
		ok &= scene.Physics.OverlapSphere(go.Transform.Position, 0.7f, fast, uint32.MaxValue, 0) == 0;
		for (int i < 12)
		{
			// Exterior face/edge/corner probes and an oblique capsule must retain generic behavior.
			let local = Vector3(0.8f + (i % 3) * 0.15f, 1.9f, 2.9f);
			let at = go.Transform.Position + go.Transform.Rotation * local;
			let direction = go.Transform.Rotation * Vector3(0.3f, 0.4f, 0.5f);
			scene.Physics.useAnalyticOverlapContacts = true;
			scene.Physics.OverlapCapsule(at - direction, at + direction, 0.2f, fast);
			scene.Physics.useAnalyticOverlapContacts = false;
			scene.Physics.OverlapCapsule(at - direction, at + direction, 0.2f, generic);
			ok &= fast.Count == generic.Count;
			if (fast.Count == 1 && generic.Count == 1)
				ok &= Math.Abs(fast[0].penetrationDepth - generic[0].penetrationDepth) < 0.0001f;
		}

		for (int i < 60)
		{
			let local = Vector3(-1.4f + (i % 6) * 0.55f, -2.2f + (i % 5) * 1.05f, -3.1f + (i % 4) * 2.05f);
			let at = go.Transform.Position + go.Transform.Rotation * local;
			scene.Physics.useAnalyticOverlapContacts = true;
			scene.Physics.OverlapSphere(at, 0.4f, fast);
			scene.Physics.useAnalyticOverlapContacts = false;
			scene.Physics.OverlapSphere(at, 0.4f, generic);
			if (fast.Count != generic.Count)
				Console.WriteLine(scope $"PROBE {i}: fast={fast.Count}, generic={generic.Count}, local={local}");
			ok &= fast.Count == generic.Count;
			if (fast.Count == 1 && generic.Count == 1)
				ok &= Math.Abs(fast[0].penetrationDepth - generic[0].penetrationDepth) < 0.03f && Math.Abs(fast[0].normal.Length - 1) < 0.001f;
		}

		return Check(ok, "analytic sphere/capsule contacts, filtering and fallbacks match generic queries on rotated boxes");
	}

	static bool AlignedBoxContacts()
	{
		let scene = scope Scene();
		let go = scene.CreateGameObject("Box face contact target");
		go.Transform.Position = .(5, -2, 7);
		go.Transform.Rotation = Quaternion.Euler(21, 35, -17);
		ShapeDesc shape = default;
		shape.kind = .Box;
		shape.halfExtents = .(1, 2, 3);
		let body = scene.Physics.CreateBody(go.Transform, shape, null);
		let fast = scope List<ShapeCastHit>();
		let generic = scope List<ShapeCastHit>();
		bool ok = true;
		for (int i < 120)
		{
			let local = Vector3(-1.4f + (i % 9) * 0.35f, -2.6f + (i % 7) * 0.85f, -3.8f + (i % 5) * 1.9f);
			let at = go.Transform.Position + go.Transform.Rotation * local;
			let rotation = (i % 3 == 0) ? go.Transform.Rotation * Quaternion.Euler(0, 180, 0) : go.Transform.Rotation;
			scene.Physics.useAnalyticOverlapContacts = true;
			scene.Physics.OverlapBox(at, .(0.8f, 1.2f, 1.6f), rotation, fast);
			scene.Physics.useAnalyticOverlapContacts = false;
			scene.Physics.OverlapBox(at, .(0.8f, 1.2f, 1.6f), rotation, generic);
			if (fast.Count != generic.Count)
				Console.WriteLine(scope $"BOX count {i}: {fast.Count}/{generic.Count}");
			ok &= fast.Count == generic.Count;
			if (fast.Count == 1 && generic.Count == 1)
			{
				let ox = 1.4f - Math.Abs(local.x), oy = 2.6f - Math.Abs(local.y), oz = 3.8f - Math.Abs(local.z);
				let expected = Math.Min(ox, Math.Min(oy, oz));
				// For a shared flat patch, aligned-box separation has an independent analytic answer.
				// Generic EPA/GJK can underestimate shallow penetration, so it is not an exact depth oracle.
				let flat = (ox > 0.071f && oy > 0.071f) || (ox > 0.071f && oz > 0.071f) || (oy > 0.071f && oz > 0.071f);
				if (flat && expected > 0.001f)
					ok &= Math.Abs(fast[0].penetrationDepth - expected) < 0.002f;
				else
					ok &= Math.Abs(fast[0].penetrationDepth - generic[0].penetrationDepth) < 0.03f;
				ok &= Math.Abs(fast[0].normal.Length - 1) < 0.001f && fast[0].bodyId == body;
				let point = go.Transform.Rotation.Conjugate * (fast[0].point - go.Transform.Position);
				if (Math.Abs(point.x) > 1.001f || Math.Abs(point.y) > 2.001f || Math.Abs(point.z) > 3.001f)
					Console.WriteLine(scope $"BOX point {i}: {point}");
				ok &= Math.Abs(point.x) <= 1.001f && Math.Abs(point.y) <= 2.001f && Math.Abs(point.z) <= 3.001f;
			}
		}
		// Nonaligned queries must retain the exact generic result, including rounded corner cases.
		for (int i < 12)
		{
			let at = go.Transform.Position + go.Transform.Rotation * Vector3(i * 0.1f, 0.3f, 0.7f);
			let rotation = go.Transform.Rotation * Quaternion.Euler(13, 17, 9);
			scene.Physics.useAnalyticOverlapContacts = true;
			scene.Physics.OverlapBox(at, .One, rotation, fast);
			scene.Physics.useAnalyticOverlapContacts = false;
			scene.Physics.OverlapBox(at, .One, rotation, generic);
			ok &= fast.Count == generic.Count;
			if (fast.Count == 1 && generic.Count == 1)
				ok &= Math.Abs(fast[0].penetrationDepth - generic[0].penetrationDepth) < 0.0001f;
		}
		scene.Physics.useAnalyticOverlapContacts = true;
		ok &= scene.Physics.OverlapBox(go.Transform.Position, .One, go.Transform.Rotation, fast, body) == 0;
		ok &= scene.Physics.OverlapBox(go.Transform.Position, .One, go.Transform.Rotation, fast, uint32.MaxValue, 0) == 0;
		return Check(ok, "aligned box contacts retain generic depths, valid surface points, filtering and oblique fallbacks");
	}

	/// Aligned capsules touching each face of a rotated box from outside (with an end, and with a side) are worked out
	/// directly: they must match Jolt's general solver.
	static bool ExteriorCapsuleContacts()
	{
		let scene = scope Scene();
		let go = scene.CreateGameObject("Rotated capsule target");
		go.Transform.Position = .(-2, 1, 3);
		go.Transform.Rotation = Quaternion.Euler(-20, 50, 10);
		ShapeDesc shape = default;
		shape.kind = .Box;
		shape.halfExtents = .(1, 1.5f, 2);
		scene.Physics.CreateBody(go.Transform, shape, null);
		float[3] half = .(shape.halfExtents.x, shape.halfExtents.y, shape.halfExtents.z);
		let fast = scope List<ShapeCastHit>();
		let generic = scope List<ShapeCastHit>();
		bool ok = true;
		int compared = 0;
		for (int face < 6)
		{
			let axis = face / 2;
			let sign = (face % 2 == 0) ? 1.0f : -1.0f;
			for (int capsuleAxis < 3)
			{
				// 0.3 m out from the face, a radius of 0.5 so 0.2 m deep; the segment 0.6 long (from its end when it
				// points at the face).
				float[3] offset = .(0, 0, 0);
				let reach = (capsuleAxis == axis) ? 0.6f : 0.3f;
				offset[axis] = sign * (half[axis] + reach);
				// Off the middle of the face, but well inside its edges.
				offset[(axis + 1) % 3] = half[(axis + 1) % 3] * 0.3f;
				float[3] along = .(0, 0, 0);
				along[capsuleAxis] = 0.3f;
				let at = go.Transform.Position + go.Transform.Rotation * Vector3(offset[0], offset[1], offset[2]);
				let direction = go.Transform.Rotation * Vector3(along[0], along[1], along[2]);
				scene.Physics.useAnalyticOverlapContacts = true;
				scene.Physics.OverlapCapsule(at - direction, at + direction, 0.5f, fast);
				scene.Physics.useAnalyticOverlapContacts = false;
				scene.Physics.OverlapCapsule(at - direction, at + direction, 0.5f, generic);
				ok &= fast.Count == 1 && generic.Count == 1;
				if (fast.Count != 1 || generic.Count != 1)
					continue;
				compared++;
				let depthOK = Math.Abs(fast[0].penetrationDepth - 0.2f) < 0.001f && Math.Abs(fast[0].penetrationDepth - generic[0].penetrationDepth) < 0.03f;
				let normalOK = (fast[0].normal - generic[0].normal).Length < 0.05f;
				// A capsule lying along a face touches it along a line, where either point is right: the point must be on
				// the face and 0.3 m from the capsule's segment (its radius less the depth).
				let local = go.Transform.Rotation.Conjugate * (fast[0].point - go.Transform.Position);
				float[3] onBox = .(local.x, local.y, local.z);
				let nearest = fast[0].point - (at - direction);
				let t = Math.Clamp(Vector3.Dot(nearest, direction * 2) / (direction * 2).LengthSquared, 0, 1);
				let fromSegment = (fast[0].point - (at - direction + direction * 2 * t)).Length;
				let pointOK = Math.Abs(Math.Abs(onBox[axis]) - half[axis]) < 0.001f && Math.Abs(fromSegment - 0.3f) < 0.001f;
				if (!depthOK || !normalOK || !pointOK)
					Console.WriteLine(scope $"FACE {face} AXIS {capsuleAxis}: depth {fast[0].penetrationDepth} vs {generic[0].penetrationDepth}, normal {fast[0].normal} vs {generic[0].normal}, point {fast[0].point} vs {generic[0].point}");
				ok &= depthOK && normalOK && pointOK;
			}
		}
		return Check(ok && compared == 18, "aligned capsules touching a box from outside match the generic solver");
	}

	/// Sphere and capsule queries skip bodies they cannot reach before working out contacts: probes all over a grid of
	/// boxes (as the benchmark lays them out) must still find every box they reach and none they do not.
	static bool QueryReach()
	{
		let scene = scope Scene();
		let boxes = scope List<GameObject>();
		for (int i < 60)
		{
			AddBox(scene, .((i % 5) * 1.1f, (i / 25) * 1.1f, (i / 5 % 5) * 1.1f), .One, let target);
			boxes.Add(target);
		}
		let hits = scope List<ShapeCastHit>();
		bool ok = true;
		int probes = 0;
		// The distance from a segment to a box, sampled finely (for the reference only).
		float Distance(Vector3 a, Vector3 b, Vector3 center)
		{
			float best = float.MaxValue;
			for (int s = 0; s <= 200; s++)
			{
				let point = Vector3.Lerp(a, b, s / 200.0f);
				let outside = Vector3(Math.Max(Math.Abs(point.x - center.x) - 0.5f, 0), Math.Max(Math.Abs(point.y - center.y) - 0.5f, 0), Math.Max(Math.Abs(point.z - center.z) - 0.5f, 0));
				best = Math.Min(best, outside.Length);
			}
			return best;
		}
		for (int i < 400)
		{
			// Points among the boxes, often near the gaps' corners, where the boxes' bounds reach but the shapes do not.
			let at = Vector3(0.55f + (i % 7) * 0.53f, 0.3f + (i / 7 % 5) * 0.41f, 0.55f + (i / 35 % 9) * 0.47f);
			let radius = 0.3f + (i % 4) * 0.15f;
			let tilt = Vector3((i % 3 == 0) ? 0.4f : 0, (i % 3 == 1) ? 0.4f : 0.2f, (i % 3 == 2) ? 0.4f : 0);
			for (int kind < 2)
			{
				let a = (kind == 0) ? at : at - tilt;
				let b = (kind == 0) ? at : at + tilt;
				if (kind == 0)
					scene.Physics.OverlapSphere(at, radius, hits);
				else
					scene.Physics.OverlapCapsule(a, b, radius, hits);
				for (let target in boxes)
				{
					let distance = Distance(a, b, target.Transform.Position);
					bool found = false;
					for (let hit in hits)
						found |= (hit.gameObject == target);
					// Jolt rounds a box's edges a little (its convex radius), so only clear cases are judged.
					if (distance < radius - 0.06f && !found)
					{
						Console.WriteLine(scope $"MISSED: {((kind == 0) ? "sphere" : "capsule")} at {at} radius {radius}, box at {target.Transform.Position} {distance} away");
						ok = false;
					}
					if (distance > radius + 0.01f && found)
						ok = false;
				}
				probes++;
			}
		}
		// CheckSphere stops at the first body: one it ignores must not be that body.
		let loneId = AddBox(scene, .(-8, 0, 0), .One, let lone);
		AddBox(scene, .(-8, 0, 0.9f), .One, let neighbour);
		ok &= !scene.Physics.CheckSphere(.(-8, 0, -0.2f), 0.3f, loneId) && scene.Physics.CheckSphere(.(-8, 0, -0.2f), 0.3f);
		ok &= scene.Physics.CheckSphere(.(-8, 0, 0.45f), 0.3f, loneId);
		return Check(ok && probes == 800, "sphere and capsule queries find every box they reach, skipping only ones they cannot");
	}

	public static int Main(String[] args)
	{
		Console.WriteLine("Shape query integration tests");
		let capacityScene = scope Scene();
		bool configured = !capacityScene.Physics.ConfigureCapacity(0, 256, 128) && capacityScene.Physics.ConfigureCapacity(16, 256, 128);
		int accepted = 0;
		for (int i < 17)
		{
			if (AddBox(capacityScene, .(i * 3, 0, 0), .One, let capacityBody) != uint32.MaxValue)
				accepted++;
		}
		capacityScene.Physics.Step(1.0f / 60);
		bool capacityOK = Check(configured && accepted == 16 && capacityScene.Physics.BodyCapacity == 16 && capacityScene.Physics.LastStepError == 0 && !capacityScene.Physics.ConfigureCapacity(512, 4096, 2048), "configured native capacity rejects excess bodies safely and cannot change under live bodies");
		bool ok = InteriorContacts() && capacityOK;
		ok &= AlignedBoxContacts();
		ok &= ExteriorCapsuleContacts();
		ok &= QueryReach();
		ShapeCastHit hit;
		let empty = scope Scene();
		ok &= Check(!empty.Physics.SphereCast(.Zero, 0.5f, .Forward, 10, out hit), "empty world safely misses");
		let scene = scope Scene();
		let nearId = AddBox(scene, .(0, 0, 5), .One, let nearGo);
		AddBox(scene, .(0, 0, 9), .One, let farGo);
		ok &= Check(scene.Physics.SphereCast(.Zero, 0.5f, .(0, 0, 2), 10, out hit) && hit.gameObject == nearGo && Math.Abs(hit.distance - 4) < 0.02f && hit.normal.z < -0.95f && Math.Abs(hit.point.z - 4.5f) < 0.02f, "closest sphere contact, normalized direction, point and outward normal");
		ok &= Check(scene.Physics.SphereCast(.Zero, 0.5f, .Forward, 10, out hit, nearId) && hit.gameObject == farGo && Math.Abs(hit.distance - 8) < 0.02f, "ignoring the closest body still finds the next body");
		ok &= Check(!scene.Physics.SphereCast(.Zero, 0.5f, .Forward, 3, out hit), "maximum distance limits sweep");
		ok &= Check(scene.Physics.CapsuleCast(.(0, -0.5f, 0), .(0, 0.5f, 0), 0.5f, .Forward, 10, out hit) && Math.Abs(hit.distance - 4) < 0.03f, "vertical capsule sweep");
		ok &= Check(scene.Physics.CapsuleCast(.(0, 0, -1), .(0, 0, 1), 0.5f, .Forward, 10, out hit) && Math.Abs(hit.distance - 3) < 0.03f, "horizontal capsule endpoints set orientation");
		ok &= Check(scene.Physics.CapsuleCast(.Zero, .Zero, 0.5f, .Forward, 10, out hit) && Math.Abs(hit.distance - 4) < 0.02f, "coincident capsule endpoints act as sphere");
		ok &= Check(scene.Physics.BoxCast(.Zero, .(1, 1, 2), .Identity, .Forward, 10, out hit) && Math.Abs(hit.distance - 3.5f) < 0.04f, "box full dimensions");
		ok &= Check(scene.Physics.BoxCast(.Zero, .(1, 1, 2), Quaternion.Euler(0, 90, 0), .Forward, 10, out hit) && Math.Abs(hit.distance - 4) < 0.04f, "rotated box sweep");
		ok &= Check(scene.Physics.SphereCast(.(0, 0, 5), 0.5f, .Forward, 10, out hit) && hit.distance == 0 && hit.penetrationDepth > 0, "starting overlap reports zero travel and penetration");
		ok &= Check(!scene.Physics.SphereCast(.Zero, -1, .Forward, 10, out hit) && !scene.Physics.SphereCast(.Zero, 0.5f, .Zero, 10, out hit) && !scene.Physics.BoxCast(.Zero, .(1, 0, 1), .Identity, .Forward, 10, out hit), "invalid radius, direction and size safely miss");
		List<ShapeCastHit> hits = scope .();
		ok &= Check(scene.Physics.OverlapSphere(.(0, 0, 5), 0.75f, hits) == 1 && hits[0].gameObject == nearGo, "sphere overlap returns mapped body");
		ok &= Check(scene.Physics.OverlapBox(.(0, 0, 5), .One, .Identity, hits, nearId) == 0 && hits.Count == 0, "overlap ignores body and clears results");
		ok &= Check(scene.Physics.OverlapCapsule(.(0, -0.5f, 5), .(0, 0.5f, 5), 0.5f, hits) == 1, "capsule overlap");
		let many = scope Scene();
		for (int i = 0; i < 80; i++)
			AddBox(many, .(i * 0.1f, 0, 0), .One, let go);
		ok &= Check(many.Physics.OverlapSphere(.(4, 0, 0), 10, hits) == 80 && hits.Count == 80, "overlap buffer grows without truncating results");
		let miniature = scope Scene();
		miniature.Physics.LengthScale = 0.002f;
		miniature.Physics.MinimumShapeExtent = 0.0001f;
		miniature.Physics.Gravity = .Zero;
		let toy = miniature.CreateGameObject("Miniature inertia probe");
		toy.AddComponent<BoxCollider>().size = .(0.01f);
		let body = toy.AddComponent<Rigidbody>();
		body.mass = 0.012f;
		body.useGravity = false;
		body.linearDamping = 0;
		body.angularDamping = 0;
		body.EnsureBody();
		body.Sleep();
		ok &= Check(body.IsSleeping, "authored resting dynamic bodies can sleep without becoming kinematic");
		body.AddForceAtPosition(.(0, 0, 0.001f), .(0.005f, 0, 0));
		miniature.Physics.Step(1.0f / 60);
		// Solid 1 cm cube: I_y=m*(x*x+z*z)/12=2e-7 kg m^2; torque=5e-6 N m.
		ok &= Check(Math.Abs(body.Velocity.z - 0.001f / 0.012f / 60) < 0.0001f, "miniature inertia conditioning preserves the assigned physical mass");
		ok &= Check(Math.Abs(body.AngularVelocity.y + 0.4166667f) < 0.03f, "off-centre force uses actual toy inertia rather than a metre-sphere fallback");
		ok &= Check(!body.IsSleeping && !body.isKinematic, "physical force wakes a resting dynamic prop");
		// More than 1 MB of vertices must not depend on the Windows thread-stack reserve.
		let largeScene = scope Scene();
		let largeMesh = scope Mesh();
		for (int i = 0; i < 100000; i++)
		{
			MeshVertex vertex = default;
			vertex.position = .((float)(i % 300), 0, (float)(i / 300));
			largeMesh.Vertices.Add(vertex);
		}
		largeMesh.Indices.Add(0);
		largeMesh.Indices.Add(300);
		largeMesh.Indices.Add(1);
		let largeObject = largeScene.CreateGameObject("Large imported room mesh");
		ShapeDesc largeShape = default;
		largeShape.kind = .Mesh;
		largeShape.mesh = largeMesh;
		largeShape.meshScale = .One;
		let largeBody = largeScene.Physics.CreateBody(largeObject.Transform, largeShape, null);
		ok &= Check(largeBody != uint32.MaxValue && largeScene.Physics.SphereCast(.(0.2f, 1, 0.2f), 0.05f, -Vector3.Up, 2, out hit) && hit.gameObject == largeObject, "large imported mesh builds and collides without a mesh-sized stack allocation");
		let gravityScene = scope Scene();
		gravityScene.Physics.Gravity = .(0, -0.01962f, 0);
		gravityScene.Physics.LengthScale = 0.002f;
		let normalObject = gravityScene.CreateGameObject("Unchanged room gravity");
		normalObject.Transform.Position = .(0, 5, 0);
		normalObject.AddComponent<SphereCollider>().radius = 0.02f;
		let normalBody = normalObject.AddComponent<Rigidbody>();
		normalBody.linearDamping = 0;
		normalBody.EnsureBody();
		let fastObject = gravityScene.CreateGameObject("Ball-only gravity");
		fastObject.Transform.Position = .(1, 5, 0);
		fastObject.AddComponent<SphereCollider>().radius = 0.02f;
		let fastBody = fastObject.AddComponent<Rigidbody>();
		fastBody.gravityScale = 4;
		fastBody.linearDamping = 0;
		fastBody.EnsureBody();
		for (int i = 0; i < 60; i++)
			gravityScene.Physics.Step(1.0f / 60);
		ok &= Check(normalBody.gravityScale == 1 && Math.Abs(normalBody.Velocity.y + 0.01962f) < 0.0001f && Math.Abs(fastBody.Velocity.y - 4 * normalBody.Velocity.y) < 0.0001f, "per-body gravity scaling accelerates only the selected body and preserves old defaults");
		return ok ? 0 : 1;
	}
}
