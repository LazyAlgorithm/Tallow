using System;
using System.Collections;
using Tallow;

namespace SoftBodyTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	/// A square sheet in the object's XZ plane, `cells` squares across, `size` metres wide.
	static Mesh Sheet(int cells, float size)
	{
		let mesh = new Mesh();
		for (int z <= cells)
		{
			for (int x <= cells)
				mesh.AddVertex(.((x / (float)cells - 0.5f) * size, 0, (z / (float)cells - 0.5f) * size), .Up, .White, .(x / (float)cells, z / (float)cells));
		}
		for (int z < cells)
		{
			for (int x < cells)
			{
				let a = (uint32)(z * (cells + 1) + x);
				mesh.AddTriangle(a, a + (uint32)cells + 1, a + 1);
				mesh.AddTriangle(a + 1, a + (uint32)cells + 1, a + (uint32)cells + 2);
			}
		}
		return mesh;
	}

	/// A level sheet pinned along its far edge (its last row, z = +size/2): the rest swings down and hangs from it.
	/// A box, half its size each way, each face cut into `cells` squares across (so it can dent and bend).
	static Mesh Box(Vector3 half, int cells)
	{
		let mesh = new Mesh();
		for (int face < 6)
		{
			let axis = face / 2;
			let sign = (face % 2 == 0) ? 1.0f : -1.0f;
			let start = (uint32)mesh.Vertices.Count;
			for (int j <= cells)
			{
				for (int i <= cells)
				{
					float[3] p = default;
					p[axis] = sign;
					p[(axis + 1) % 3] = i / (float)cells * 2 - 1;
					p[(axis + 2) % 3] = j / (float)cells * 2 - 1;
					float[3] n = default;
					n[axis] = sign;
					mesh.AddVertex(.(p[0] * half.x, p[1] * half.y, p[2] * half.z), .(n[0], n[1], n[2]), .White, .(i / (float)cells, j / (float)cells));
				}
			}
			for (int j < cells)
			{
				for (int i < cells)
				{
					let a = start + (uint32)(j * (cells + 1) + i);
					let c = a + (uint32)cells + 1;
					// Wound to face outward on either side.
					if (sign > 0)
					{
						mesh.AddTriangle(a, a + 1, c);
						mesh.AddTriangle(a + 1, c + 1, c);
					}
					else
					{
						mesh.AddTriangle(a, c, a + 1);
						mesh.AddTriangle(a + 1, c, c + 1);
					}
				}
			}
		}
		return mesh;
	}

	static SoftBody Curtain(Scene scene, Mesh sheet, Vector3 position, int cells)
	{
		let object = scene.CreateGameObject("Curtain");
		object.Transform.Position = position;
		object.AddComponent<MeshRenderer>().RuntimeMesh = sheet;
		let soft = object.AddComponent<SoftBody>();
		soft.pins.Set(scope $"{cells * (cells + 1)}-{(cells + 1) * (cells + 1) - 1}");
		// Settles within the test rather than swinging on.
		soft.damping = 1;
		return soft;
	}

	static void Run(Scene scene, int ticks)
	{
		for (int i < ticks)
			scene.FixedUpdate();
	}

	static Vector3 Lowest(List<Vector3> points)
	{
		var lowest = points[0];
		for (let p in points)
		{
			if (p.y < lowest.y)
				lowest = p;
		}
		return lowest;
	}

	static Vector3 Average(List<Vector3> points)
	{
		var sum = Vector3.Zero;
		for (let p in points)
			sum = sum + p;
		return sum / points.Count;
	}

	static GameObject MakeJelly(Scene scene)
	{
		let ball = scene.CreateGameObject("Jelly");
		ball.AddComponent<NetworkIdentity>();
		ball.AddComponent<MeshRenderer>().mesh.Set("builtin:sphere");
		ball.AddComponent<SoftBody>().kind = .Jelly;
		return ball;
	}

	static void Floor(Scene scene)
	{
		let floor = scene.CreateGameObject("Floor");
		floor.Transform.Position = .(0, -0.5f, 0);
		floor.AddComponent<BoxCollider>().size = .(40, 1, 40);
	}

	/// Ticks both machines at a steady pace.
	static void Pump(Scene a, Scene b, int ticks)
	{
		for (int i < ticks)
		{
			for (let scene in Scene[?](a, b))
			{
				scene.FixedUpdate();
				scene.Update();
			}
			System.Threading.Thread.Sleep(4);
		}
	}

	public static int Main(String[] args)
	{
		bool ok = true;

		// ---- pins and stiffness written as text ----
		{
			let pinned = scope List<uint32>();
			SoftBody.ParsePins("0-3 7 9-10 200", 12, pinned);
			let text = scope String();
			SoftBody.FormatPins(pinned, text);
			ok &= Check(pinned.Count == 7 && text == "0-3 7 9-10", scope $"pins read from ranges and written back the same ({text})");
			let stiffness = scope List<float>() { 1, 1, 1, 1 };
			SoftBody.ParseStiffness("1=0.5 3=0.25 9=0", stiffness);
			let written = scope String();
			SoftBody.FormatStiffness(stiffness, written);
			ok &= Check(stiffness[1] == 0.5f && stiffness[3] == 0.25f && written == "1=0.5 3=0.25", scope $"a stiffness map read and written back ({written})");
		}

		// ---- a mesh's seams are joined ----
		{
			let sphere = Assets.GetMesh("builtin:sphere");
			let rest = scope List<Vector3>(), triangles = scope List<uint32>(), map = scope List<int32>();
			SoftBody.Weld(sphere, rest, triangles, map);
			let joined = sphere != null && rest.Count < sphere.Vertices.Count && map.Count == sphere.Vertices.Count && triangles.Count > 0;
			ok &= Check(joined, scope $"a sphere's vertices split at its seams are joined for the simulation ({sphere?.Vertices.Count} drawn, {rest.Count} simulated)");
		}

		// ---- cloth hangs from its pins, and follows them ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let cells = 12;
			let sheet = scope Mesh();
			let made = Sheet(cells, 2);
			sheet.Vertices.AddRange(made.Vertices);
			sheet.Indices.AddRange(made.Indices);
			delete made;
			let curtain = Curtain(scene, sheet, .(0, 5, 0), cells);
			Run(scene, 1);
			ok &= Check(curtain.HasBody && curtain.SimulatedVertexCount == (cells + 1) * (cells + 1), scope $"a sheet becomes a soft body ({curtain.SimulatedVertexCount} vertices)");
			Run(scene, 300);
			curtain.[Friend]ReadBack();
			let positions = curtain.Positions;
			let top = positions[cells * (cells + 1)];
			let bottom = Lowest(positions);
			ok &= Check(Math.Abs(top.y - 5) < 0.02f && Math.Abs(top.z - 1) < 0.02f, scope $"its pinned edge stays where the object holds it ({top})");
			ok &= Check(bottom.y < 3.25f && bottom.y > 2.7f && Math.Abs(bottom.z - 1) < 0.25f, scope $"the rest swings down and hangs below it without stretching far (lowest {bottom}, 2 m of cloth)");
			// The object moves: its pins go with it, and the cloth after them.
			curtain.Transform.Position = .(3, 5, 0);
			Run(scene, 180);
			curtain.[Friend]ReadBack();
			let movedTop = curtain.Positions[cells * (cells + 1)];
			let movedMiddle = Average(curtain.Positions);
			ok &= Check(Math.Abs(movedTop.x - 2) < 0.05f && movedMiddle.x > 2.6f, scope $"moving the object moves its pins, and the cloth follows (top x {movedTop.x}, middle x {movedMiddle.x})");
			let renderer = curtain.GetComponent<MeshRenderer>();
			ok &= Check(renderer.RuntimeMesh != sheet && renderer.RuntimeMesh.Vertices.Count == sheet.Vertices.Count, "the renderer draws a copy of the mesh that follows the simulation");
			let before = scene.Physics.[Friend]mSoftBodies.Count;
			scene.DestroyImmediate(curtain.GameObject);
			ok &= Check(before == 1 && scene.Physics.[Friend]mSoftBodies.Count == 0, "destroying the object takes its soft body out of the world");
		}

		// ---- wind blows on cloth ----
		{
			float Drift(bool windy)
			{
				let scene = scope Scene();
				Scene.Active = scene;
				scene.StartPlay();
				if (windy)
				{
					let wind = scene.CreateGameObject("Wind").AddComponent<WindZone>();
					wind.strength = 3;
					wind.Transform.Rotation = Quaternion.LookRotation(.(0, 0, 1), .Up);
				}
				let sheet = scope Mesh();
				let made = Sheet(8, 2);
				sheet.Vertices.AddRange(made.Vertices);
				sheet.Indices.AddRange(made.Indices);
				delete made;
				let curtain = Curtain(scene, sheet, .(0, 5, 0), 8);
				Run(scene, 300);
				curtain.[Friend]ReadBack();
				return Average(curtain.Positions).z;
			}
			let still = Drift(false), blown = Drift(true);
			ok &= Check(Math.Abs(still - 1) < 0.15f && blown > still + 0.25f, scope $"a Wind Zone blows hanging cloth the way it faces (middle z {still} still, {blown} in wind)");
		}

		// ---- a shell dented by its car's hits: nothing passes into it, slow pushes and light things do not dent ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let wall = scene.CreateGameObject("Wall");
			wall.Transform.Position = .(0, 1.5f, 8);
			wall.AddComponent<BoxCollider>().size = .(6, 3, 1);
			let car = scene.CreateGameObject("Car");
			car.Transform.Position = .(0, 0.65f, 0);
			// The collider the shape of the body.
			car.AddComponent<BoxCollider>().size = .(1.8f, 1.2f, 4);
			let body = car.AddComponent<Rigidbody>();
			body.mass = 1000;
			let shellMesh = Box(.(0.9f, 0.6f, 2), 8);
			defer delete shellMesh;
			car.AddComponent<MeshRenderer>().RuntimeMesh = shellMesh;
			let shell = car.AddComponent<SoftBody>();
			shell.kind = .Shell;
			Run(scene, 60);

			// Something pushed slowly into its side stops at the surface and leaves no dent.
			let pusher = scene.CreateGameObject("Pusher");
			pusher.Transform.Position = .(2, 0.65f, 0);
			pusher.AddComponent<BoxCollider>().size = .(0.6f, 0.6f, 0.6f);
			let pushed = pusher.AddComponent<Rigidbody>();
			pushed.mass = 80;
			float closest = 99;
			for (int tick < 120)
			{
				pushed.Velocity = .(-1.5f, pushed.Velocity.y, 0);
				scene.FixedUpdate();
				closest = Math.Min(closest, pusher.Transform.Position.x - 0.3f - (car.Transform.Position.x + 0.9f));
			}
			ok &= Check(closest > -0.03f && shell.DeepestDent() < 0.002f, scope $"From Impacts: something pushed into the side stops at the surface ({closest} m from it) and leaves no dent ({shell.DeepestDent()})");
			scene.DestroyImmediate(pusher);
			Run(scene, 30);

			// A light ball thrown hard does not dent it; a heavy crate does, on that side only.
			GameObject Thrown(Scene scene, Vector3 at, float size, float mass, Vector3 velocity)
			{
				let thrown = scene.CreateGameObject("Thrown");
				thrown.Transform.Position = at;
				thrown.AddComponent<BoxCollider>().size = .(size, size, size);
				let rigid = thrown.AddComponent<Rigidbody>();
				rigid.mass = mass;
				rigid.EnsureBody();
				rigid.Velocity = velocity;
				return thrown;
			}
			let ball = Thrown(scene, .(car.Transform.Position.x - 2.5f, 0.9f, car.Transform.Position.z), 0.2f, 1, .(15, 0, 0));
			Run(scene, 40);
			let byBall = shell.DeepestDent();
			scene.DestroyImmediate(ball);
			let crate = Thrown(scene, .(car.Transform.Position.x - 3, 0.9f, car.Transform.Position.z), 0.6f, 200, .(9, 0, 0));
			Run(scene, 40);
			scene.DestroyImmediate(crate);
			shell.[Friend]ReadBack();
			let dents = scope List<Vector3>();
			shell.GetDents(dents);
			float left = 0, right = 0;
			for (int i < dents.Count)
			{
				if (shell.[Friend]mRest[i].x < -0.85f)
					left = Math.Max(left, dents[i].Length);
				if (shell.[Friend]mRest[i].x > 0.85f)
					right = Math.Max(right, dents[i].Length);
			}
			ok &= Check(byBall < 0.002f && left > 0.03f && right < 0.002f, scope $"a 1 kg ball at 15 m/s leaves no dent ({byBall}); a 200 kg crate at 9 m/s dents the side it hits ({left} m) and not the other ({right} m)");

			// Driven into a wall, the front dents and stays dented.
			shell.Repair();
			for (int tick < 90)
			{
				if (car.Transform.Position.z < 5.4f)
					body.Velocity = .(0, body.Velocity.y, 12);
				scene.FixedUpdate();
			}
			shell.GetDents(dents..Clear());
			float front = 0, back = 0;
			for (int i < dents.Count)
			{
				if (shell.[Friend]mRest[i].z > 1.9f)
					front = Math.Max(front, dents[i].Length);
				if (shell.[Friend]mRest[i].z < -1.9f)
					back = Math.Max(back, dents[i].Length);
			}
			Run(scene, 120);
			ok &= Check(front > 0.1f && back < 0.002f && Math.Abs(shell.DeepestDent() - front) < 0.01f, scope $"driven into a wall at 12 m/s, its front dents ({front} m), its back does not ({back} m), and the dent stays ({shell.DeepestDent()} m)");
		}

		// ---- a shell on an object with no Rigidbody gets one, and falls ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let crate = scene.CreateGameObject("Crate");
			crate.Transform.Position = .(0, 3, 0);
			let crateMesh = Box(.(0.5f, 0.5f, 0.5f), 4);
			defer delete crateMesh;
			crate.AddComponent<MeshRenderer>().RuntimeMesh = crateMesh;
			let shell = crate.AddComponent<SoftBody>();
			shell.kind = .Shell;
			shell.mass = 20;
			Run(scene, 120);
			let rigid = crate.GetComponent<Rigidbody>();
			// Dropped from 3 m it lands at about 7 m/s, past Dent Speed: its bottom dents a little, and its collider with it.
			ok &= Check(rigid != null && rigid.mass == 20 && crate.GetComponent<ConvexCollider>() != null && crate.Transform.Position.y > 0.38f && crate.Transform.Position.y < 0.52f, scope $"a shell with no Rigidbody gets one (and a collider) and falls to the floor (at {crate.Transform.Position.y}, its bottom dented {shell.DeepestDent()} m)");

			// Given a Rigidbody but no collider (which alone does not move), it gets the collider, and falls.
			let other = scene.CreateGameObject("Crate 2");
			other.Transform.Position = .(3, 3, 0);
			other.AddComponent<MeshRenderer>().RuntimeMesh = crateMesh;
			other.AddComponent<Rigidbody>().mass = 20;
			other.AddComponent<SoftBody>().kind = .Shell;
			Run(scene, 120);
			ok &= Check(other.GetComponent<ConvexCollider>() != null && other.Transform.Position.y > 0.38f && other.Transform.Position.y < 0.52f, scope $"a shell with a Rigidbody and no collider gets a collider and falls (at {other.Transform.Position.y})");
		}

		// ---- a shell's Convex Collider follows its dents ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let wall = scene.CreateGameObject("Wall");
			wall.Transform.Position = .(0, 1.5f, 8);
			wall.AddComponent<BoxCollider>().size = .(6, 3, 1);
			let car = scene.CreateGameObject("Car");
			car.Transform.Position = .(0, 0.65f, 0);
			let shellMesh = Box(.(0.9f, 0.6f, 2), 8);
			defer delete shellMesh;
			car.AddComponent<MeshRenderer>().RuntimeMesh = shellMesh;
			car.AddComponent<ConvexCollider>();
			let body = car.AddComponent<Rigidbody>();
			body.mass = 1000;
			let shell = car.AddComponent<SoftBody>();
			shell.kind = .Shell;
			Run(scene, 30);
			for (int tick < 90)
			{
				if (car.Transform.Position.z < 5.4f)
					body.Velocity = .(0, body.Velocity.y, 12);
				scene.FixedUpdate();
			}
			// Backed off the wall and left to settle: the collider is wrapped round the crumpled front.
			body.Velocity = .(0, 0, -2);
			Run(scene, 30);
			body.Velocity = .Zero;
			Run(scene, 30);
			let front = car.Transform.Position.z + 2;
			RaycastHit hit;
			// From just in front of the car (the wall is half a metre on).
			let found = scene.Physics.Raycast(.(car.Transform.Position.x, car.Transform.Position.y, front + 0.3f), .(0, 0, -1), 3, out hit);
			let inward = found ? (front + 0.3f) - hit.distance - front : 99;
			ok &= Check(found && shell.DeepestDent() > 0.1f && inward < -0.08f && Math.Abs(inward + shell.DeepestDent()) < 0.05f, scope $"the collider follows the dents: a ray meets the crumpled front {-inward} m in (dent {shell.DeepestDent()} m)");
			// And it keeps riding the new body: a second hit dents it further.
			let before = shell.DeepestDent();
			for (int tick < 60)
			{
				if (car.Transform.Position.z < 5.6f)
					body.Velocity = .(0, body.Velocity.y, 10);
				scene.FixedUpdate();
			}
			ok &= Check(shell.DeepestDent() > before + 0.02f, scope $"and a second crash dents it further ({before} m, then {shell.DeepestDent()} m)");
		}

		// ---- a 10 kg ball at 30 m/s (the Sandbox's Ball Launcher) dents a 100 kg shell cube ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let cube = scene.CreateGameObject("Cube");
			cube.Transform.Position = .(0, 0.5f, 0);
			let cubeMesh = Box(.(0.5f, 0.5f, 0.5f), 8);
			defer delete cubeMesh;
			cube.AddComponent<MeshRenderer>().RuntimeMesh = cubeMesh;
			let shell = cube.AddComponent<SoftBody>();
			shell.kind = .Shell;
			shell.mass = 100;
			Run(scene, 30);
			let ball = scene.CreateGameObject("Ball");
			ball.Transform.Position = .(-4, 0.5f, 0);
			ball.Transform.LocalScale = .(0.3f, 0.3f, 0.3f);
			ball.AddComponent<SphereCollider>();
			let rigid = ball.AddComponent<Rigidbody>();
			rigid.mass = 10;
			rigid.continuousCollision = true;
			rigid.EnsureBody();
			rigid.Velocity = .(30, 0, 0);
			Run(scene, 60);
			ok &= Check(shell.DeepestDent() > 0.05f, scope $"a 10 kg ball at 30 m/s dents a 100 kg shell cube ({shell.DeepestDent()} m)");
		}

		// ---- a flag: cloth pinned along a pole, in the wind ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let wind = scene.CreateGameObject("Wind").AddComponent<WindZone>();
			wind.strength = 3;
			wind.Transform.Rotation = Quaternion.LookRotation(.(1, 0, 0), .Up);
			let cells = 8;
			let sheet = scope Mesh();
			let made = Sheet(cells, 2);
			sheet.Vertices.AddRange(made.Vertices);
			sheet.Indices.AddRange(made.Indices);
			delete made;
			let flag = scene.CreateGameObject("Flag");
			flag.Transform.Position = .(0, 5, 0);
			// Stood up: the sheet's first column (along its z) becomes the pole, upright.
			flag.Transform.Rotation = Quaternion.AngleAxis(-90, .(1, 0, 0));
			flag.AddComponent<MeshRenderer>().RuntimeMesh = sheet;
			let cloth = flag.AddComponent<SoftBody>();
			let pins = scope String();
			for (int j <= cells)
				pins.AppendF("{} ", j * (cells + 1));
			cloth.pins.Set(pins);
			Run(scene, 240);
			float outMost = 0, low = 99, high = -99, swing = 0;
			for (int tick < 120)
			{
				scene.FixedUpdate();
				cloth.[Friend]ReadBack();
				float edgeX = 0, edgeZ = 0;
				for (int j <= cells)
				{
					edgeX += cloth.Positions[j * (cells + 1) + cells].x;
					edgeZ += cloth.Positions[j * (cells + 1) + cells].z;
				}
				edgeX /= cells + 1;
				edgeZ /= cells + 1;
				outMost = Math.Max(outMost, edgeX);
				low = Math.Min(low, edgeZ);
				high = Math.Max(high, edgeZ);
			}
			swing = high - low;
			let pole = cloth.Positions[0].x;
			ok &= Check(outMost - pole > 1.2f && swing > 0.05f, scope $"a flag streams out in the wind ({outMost - pole} m of 2 out from its pole) and flaps ({swing} m from side to side)");
		}

		// ---- cloth drapes over things ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let table = scene.CreateGameObject("Table");
			table.Transform.Position = .(0, 1, 0);
			table.AddComponent<BoxCollider>().size = .(1, 0.2f, 1);
			let sheet = scope Mesh();
			let made = Sheet(16, 2);
			sheet.Vertices.AddRange(made.Vertices);
			sheet.Indices.AddRange(made.Indices);
			delete made;
			let cloth = scene.CreateGameObject("Tablecloth");
			cloth.Transform.Position = .(0, 1.6f, 0);
			cloth.AddComponent<MeshRenderer>().RuntimeMesh = sheet;
			let soft = cloth.AddComponent<SoftBody>();
			soft.thickness = 0.02f;
			Run(scene, 300);
			soft.[Friend]ReadBack();
			// Over the table it lies on the top (1.1) without going into it, folds and all; its corners hang down past it.
			float lowestOver = float.MaxValue, sumOver = 0;
			int over = 0;
			for (let p in soft.Positions)
			{
				if (Math.Abs(p.x) > 0.45f || Math.Abs(p.z) > 0.45f)
					continue;
				lowestOver = Math.Min(lowestOver, p.y);
				sumOver += p.y;
				over++;
			}
			let corner = soft.Positions[0];
			ok &= Check(over > 20 && lowestOver > 1.09f && sumOver / over < 1.25f, scope $"cloth dropped on a table comes to rest on it ({over} vertices over it, lowest {lowestOver}, average {sumOver / Math.Max(over, 1)}; top 1.1)");
			ok &= Check(corner.y < 0.95f, scope $"and its corners hang over the edge (corner y {corner.y})");
		}

		// ---- a jelly cube, as it comes, stays a cube and does not bounce about ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let cube = Box(.(0.5f, 0.5f, 0.5f), 8);
			defer delete cube;
			let object = scene.CreateGameObject("Jello");
			object.Transform.Position = .(0, 1.5f, 0);
			object.AddComponent<MeshRenderer>().RuntimeMesh = cube;
			let jelly = object.AddComponent<SoftBody>();
			jelly.kind = .Jelly;
			bool landed = false;
			float bounce = 0;
			for (int tick < 240)
			{
				scene.FixedUpdate();
				jelly.[Friend]ReadBack();
				let low = Lowest(jelly.Positions).y;
				landed |= low < 0.05f;
				if (landed)
					bounce = Math.Max(bounce, low);
			}
			// The faces' middles against a cube's (half its size from the middle; a ball's would be 0.87).
			let middle = Average(jelly.Positions);
			float faceMiddle = 0;
			int faces = 0;
			for (int i < jelly.Positions.Count)
			{
				let rest = jelly.[Friend]mRest[i];
				if ((Math.Abs(rest.x) < 0.01f ? 1 : 0) + (Math.Abs(rest.y) < 0.01f ? 1 : 0) + (Math.Abs(rest.z) < 0.01f ? 1 : 0) == 2)
				{
					faceMiddle += (jelly.Positions[i] - middle).Length;
					faces++;
				}
			}
			faceMiddle /= faces;
			ok &= Check(faceMiddle < 0.55f && bounce < 0.15f, scope $"a jelly cube dropped 1 m keeps its shape (faces' middles {faceMiddle} m out, a cube's 0.5) and hops once at most ({bounce} m)");

			// At rest, it goes to sleep; something landing on it wakes it, and it holds that up.
			int waited = 240;
			while (!jelly.IsSleeping && waited < 600)
			{
				scene.FixedUpdate();
				waited++;
			}
			ok &= Check(jelly.IsSleeping, scope $"a resting jelly goes to sleep ({waited / 60.0f:0.0} s after it was dropped)");
			jelly.[Friend]ReadBack();
			let under = Average(jelly.Positions);
			let crate = scene.CreateGameObject("Crate");
			crate.Transform.Position = .(under.x, 2, under.z);
			crate.AddComponent<BoxCollider>().size = .(0.3f, 0.3f, 0.3f);
			crate.AddComponent<Rigidbody>().mass = 0.5f;
			bool woke = false;
			float caught = float.MaxValue;
			for (int tick < 90)
			{
				scene.FixedUpdate();
				woke |= !jelly.IsSleeping;
				caught = Math.Min(caught, crate.Transform.Position.y);
			}
			ok &= Check(woke && caught > 0.6f, scope $"a crate landing on the sleeping jelly wakes it and is held up (lowest {caught})");
		}

		// ---- fine cloth folded and squeezed stays calm ----
		// A 1 kg cloth of 1,089 vertices (a gram each) at the default settings was effectively rigid everywhere and
		// blew apart once it folded: draped over a ball, or a coarser one at the default bending.
		for (let cells in int[?](16, 32, 48))
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let ball = scene.CreateGameObject("Ball");
			ball.Transform.Position = .(0, 0.6f, 0);
			ball.AddComponent<SphereCollider>().radius = 0.6f;
			let made = Sheet(cells, 2);
			defer delete made;
			let cloth = scene.CreateGameObject("Drape");
			cloth.Transform.Position = .(0, 1.6f, 0);
			cloth.AddComponent<MeshRenderer>().RuntimeMesh = made;
			let soft = cloth.AddComponent<SoftBody>();
			float fastest = 0;
			var lo = Vector3(float.MaxValue), hi = Vector3(float.MinValue);
			let before = scope List<Vector3>();
			for (int i < 600)
			{
				before.Clear();
				before.AddRange(soft.Positions);
				scene.FixedUpdate();
				soft.[Friend]ReadBack();
				if (i < 240 || before.Count != soft.Positions.Count)
					continue;
				for (int v < before.Count)
				{
					fastest = Math.Max(fastest, (soft.Positions[v] - before[v]).Length / Time.FixedDeltaTime);
					lo = Vector3.Min(lo, soft.Positions[v]);
					hi = Vector3.Max(hi, soft.Positions[v]);
				}
			}
			ok &= Check(fastest < 2 && lo.y > -0.1f && hi.y < 1.3f && hi.x < 1.5f && lo.x > -1.5f,
scope $"a {cells} x {cells} cloth draped over a ball settles on it ({fastest:0.00} m/s at the most after 4 s; {lo.y:0.00} to {hi.y:0.00} m high)");
		}

		// ---- soft bodies meet each other: a jelly cube on another, and cloth over one ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let cubeMesh = Box(.(0.5f, 0.5f, 0.5f), 8);
			defer delete cubeMesh;
			SoftBody Jello(Scene scene, Mesh mesh, Vector3 at)
			{
				let object = scene.CreateGameObject("Jello");
				object.Transform.Position = at;
				object.AddComponent<MeshRenderer>().RuntimeMesh = mesh;
				let jelly = object.AddComponent<SoftBody>();
				jelly.kind = .Jelly;
				return jelly;
			}
			let below = Jello(scene, cubeMesh, .(0, 0.55f, 0));
			let above = Jello(scene, cubeMesh, .(0.1f, 2, 0.05f));
			Run(scene, 240);
			below.[Friend]ReadBack();
			above.[Friend]ReadBack();
			float belowTop = -99;
			for (let p in below.Positions)
				belowTop = Math.Max(belowTop, p.y);
			let aboveBottom = Lowest(above.Positions).y;
			ok &= Check(aboveBottom > belowTop - 0.05f && aboveBottom > 0.8f, scope $"a jelly cube dropped on another rests on it (its bottom {aboveBottom}, the other's top {belowTop})");

			let sheet = Sheet(12, 2);
			defer delete sheet;
			let cloth = scene.CreateGameObject("Cloth");
			cloth.Transform.Position = .(4, 2, 0);
			cloth.AddComponent<MeshRenderer>().RuntimeMesh = sheet;
			let blanket = cloth.AddComponent<SoftBody>();
			blanket.damping = 1;
			let under = Jello(scene, cubeMesh, .(4, 0.55f, 0));
			Run(scene, 240);
			blanket.[Friend]ReadBack();
			under.[Friend]ReadBack();
			float underTop = -99;
			for (let p in under.Positions)
				underTop = Math.Max(underTop, p.y);
			// The cloth's middle (over the cube) lies on the cube's top.
			float middleY = 0;
			int over = 0;
			for (let p in blanket.Positions)
			{
				if (Math.Abs(p.x - 4) < 0.3f && Math.Abs(p.z) < 0.3f)
				{
					middleY += p.y;
					over++;
				}
			}
			middleY /= Math.Max(over, 1);
			ok &= Check(over > 0 && middleY > underTop - 0.05f, scope $"cloth dropped over a jelly cube drapes on it (cloth over it at {middleY}, its top {underTop})");
		}

		// ---- a rubber ball (jelly with more air in) keeps its volume, and holds up a crate ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let floor = scene.CreateGameObject("Floor");
			floor.Transform.Position = .(0, -0.5f, 0);
			floor.AddComponent<BoxCollider>().size = .(10, 1, 10);
			let ball = scene.CreateGameObject("Jelly");
			ball.Transform.Position = .(0, 1, 0);
			ball.AddComponent<MeshRenderer>().mesh.Set("builtin:sphere");
			let jelly = ball.AddComponent<SoftBody>();
			jelly.kind = .Jelly;
			jelly.mass = 2;
			jelly.pressure = 300;
			Run(scene, 240);
			jelly.[Friend]ReadBack();
			float lowest = float.MaxValue, highest = float.MinValue;
			for (let p in jelly.Positions)
			{
				lowest = Math.Min(lowest, p.y);
				highest = Math.Max(highest, p.y);
			}
			let height = highest - lowest;
			ok &= Check(lowest > -0.05f && lowest < 0.1f, scope $"a jelly ball falls and rests on the floor (bottom {lowest})");
			ok &= Check(height > 0.9f && height < 1.1f, scope $"keeping its shape (height {height} of 1)");
			let middle = Average(jelly.Positions);
			ok &= Check((ball.Transform.Position - middle).Length < 0.01f, scope $"a free soft body carries its object with it (object at {ball.Transform.Position}, body's middle {middle})");
			// A script teleports the object: the body goes with it.
			ball.Transform.Position = ball.Transform.Position + Vector3(4, 0, 0);
			Run(scene, 1);
			jelly.[Friend]ReadBack();
			let moved = Average(jelly.Positions);
			let carried = Math.Abs(moved.x - middle.x - 4) < 0.1f && moved.y > 0.3f && (ball.Transform.Position - moved).Length < 0.01f;
			ok &= Check(carried, scope $"moving its object moves the body with it (body's middle x {middle.x} to {moved.x})");
			// A crate dropped on it (where it rolled to as it settled) is caught up high, and squashes it.
			let under = Average(jelly.Positions);
			let crate = scene.CreateGameObject("Crate");
			crate.Transform.Position = .(under.x, 1.6f, under.z);
			crate.AddComponent<BoxCollider>().size = .(0.4f, 0.4f, 0.4f);
			crate.AddComponent<Rigidbody>().mass = 3;
			float squashed = height, caught = float.MaxValue;
			for (int tick < 45)
			{
				scene.FixedUpdate();
				jelly.[Friend]ReadBack();
				float top = float.MinValue, bottom = float.MaxValue;
				for (let p in jelly.Positions)
				{
					top = Math.Max(top, p.y);
					bottom = Math.Min(bottom, p.y);
				}
				squashed = Math.Min(squashed, top - bottom);
				caught = Math.Min(caught, crate.Transform.Position.y);
			}
			ok &= Check(caught > 0.8f, scope $"a crate dropped on it is caught on top, not let through (lowest {caught})");
			ok &= Check(squashed < height - 0.05f, scope $"and squashes it (height {squashed} under it, {height} before)");
			let touched = scope List<uint32>();
			scene.FixedUpdate();
			jelly.TouchingBodies(touched);
			ok &= Check(touched.Contains(crate.GetComponent<Rigidbody>().BodyId), scope $"it reports the bodies it touches ({touched.Count})");
		}

		// ---- a character walking through a curtain pushes it aside ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			let floor = scene.CreateGameObject("Floor");
			floor.Transform.Position = .(0, -0.5f, 0);
			floor.AddComponent<BoxCollider>().size = .(20, 1, 20);
			let sheet = scope Mesh();
			let made = Sheet(10, 2);
			sheet.Vertices.AddRange(made.Vertices);
			sheet.Indices.AddRange(made.Indices);
			delete made;
			// Hung from y 2.3 along z = 0 (its pinned row is at z = +1 on the object), so it reaches nearly to the floor.
			let curtain = Curtain(scene, sheet, .(0, 2.3f, -1), 10);
			Run(scene, 240);
			curtain.[Friend]ReadBack();
			let hanging = Average(curtain.Positions);
			let walker = scene.CreateGameObject("Walker");
			walker.Transform.Position = .(0, 0.05f, -2);
			let controller = walker.AddComponent<CharacterController>();
			Run(scene, 1);
			float pushed = hanging.z;
			for (int tick < 150)
			{
				controller.SimpleMove(.(0, 0, 2), Time.FixedDeltaTime);
				scene.FixedUpdate();
				curtain.[Friend]ReadBack();
				pushed = Math.Max(pushed, Average(curtain.Positions).z);
			}
			ok &= Check(walker.Transform.Position.z > 1.5f && pushed > hanging.z + 0.2f, scope $"a character walks through a hanging curtain and pushes it aside (curtain middle z {hanging.z} hanging, {pushed} at most; walker z {walker.Transform.Position.z})");
		}

		// ---- a car's shell dents where it hits a wall, keeps the dent, and can be repaired ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			let wall = scene.CreateGameObject("Wall");
			wall.Transform.Position = .(0, 1.5f, 8);
			wall.AddComponent<BoxCollider>().size = .(6, 3, 1);
			let car = scene.CreateGameObject("Car");
			car.Transform.Position = .(0, 0.65f, 0);
			// The collider a little inside the body at the front and back, and below it underneath (as wheels would be).
			car.AddComponent<BoxCollider>().size = .(1.6f, 1.4f, 3.6f);
			let body = car.AddComponent<Rigidbody>();
			body.mass = 1000;
			let shellMesh = Box(.(0.9f, 0.6f, 2), 8);
			defer delete shellMesh;
			car.AddComponent<MeshRenderer>().RuntimeMesh = shellMesh;
			let shell = car.AddComponent<SoftBody>();
			shell.kind = .Shell;
			shell.dentMode = .FromSurface;
			shell.springBack = 0.03f;
			Run(scene, 60);
			let restingAt = car.Transform.Position;
			Run(scene, 60);
			int parked = 120;
			while (!shell.IsSleeping && parked < 600)
			{
				scene.FixedUpdate();
				parked++;
			}
			ok &= Check(shell.IsSleeping, scope $"a parked car's shell goes to sleep ({parked / 60.0f:0.0} s)");
			let carMoved = (car.Transform.Position - restingAt).Length;
			let resting = shell.HasBody && shell.DeepestDent() < 0.01f && carMoved < 0.01f;
			ok &= Check(resting, scope $"a shell rests on its car without denting or pushing it ({shell.SimulatedVertexCount} vertices, deepest dent {shell.DeepestDent()}, car moved {carMoved})");

			// Below Dent Speed nothing dents however hard it presses: a heavy crate dropped onto the roof and left
			// there, and backing gently into a wall.
			let load = scene.CreateGameObject("Load");
			load.Transform.Position = .(0, 1.85f, 0);
			load.AddComponent<BoxCollider>().size = .(0.6f, 0.6f, 0.6f);
			load.AddComponent<Rigidbody>().mass = 200;
			Run(scene, 120);
			let underLoad = shell.DeepestDent();
			scene.DestroyImmediate(load);
			let backWall = scene.CreateGameObject("Back Wall");
			backWall.Transform.Position = .(0, 1.5f, -6);
			backWall.AddComponent<BoxCollider>().size = .(6, 3, 1);
			for (int tick < 240)
			{
				body.Velocity = .(0, body.Velocity.y, -1.5f);
				scene.FixedUpdate();
			}
			let bumped = shell.DeepestDent();
			ok &= Check(underLoad < 0.01f && bumped < 0.01f, scope $"slow knocks spring back: a 200 kg crate dropped on the roof ({underLoad} m) and backing into a wall at 1.5 m/s ({bumped} m) leave no dent");
			for (int tick < 120)
			{
				if (car.Transform.Position.z < 5.4f)
					body.Velocity = .(0, body.Velocity.y, 12);
				scene.FixedUpdate();
			}
			shell.[Friend]ReadBack();
			let dents = scope List<Vector3>();
			shell.GetDents(dents);
			float front = 0, back = 0;
			for (int i < dents.Count)
			{
				if (shell.[Friend]mRest[i].z > 1.9f)
					front = Math.Max(front, dents[i].Length);
				if (shell.[Friend]mRest[i].z < -1.9f)
					back = Math.Max(back, dents[i].Length);
			}
			ok &= Check(front > 0.08f && back < 0.03f, scope $"driven into a wall, its front dents and its back does not (front {front} m, back {back} m)");
			Run(scene, 120);
			let later = shell.DeepestDent();
			ok &= Check(later > front * 0.9f, scope $"the dent stays ({later} m two seconds later)");
			shell.GetDents(dents);
			// Backed away from the wall, then mended.
			car.Transform.Position = car.Transform.Position - Vector3(0, 0, 3);
			body.Velocity = .Zero;
			Run(scene, 2);
			shell.Repair();
			Run(scene, 30);
			ok &= Check(shell.DeepestDent() < 0.005f, scope $"Repair takes the dents out ({shell.DeepestDent()})");
			shell.SetDents(dents);
			Run(scene, 30);
			ok &= Check(Math.Abs(shell.DeepestDent() - later) < 0.01f, scope $"dents saved with GetDents come back with SetDents ({shell.DeepestDent()} of {later})");
		}

		// ---- ropes ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			GameObject Post(Scene scene, Vector3 at)
			{
				let post = scene.CreateGameObject("Post");
				post.Transform.Position = at;
				return post;
			}
			GameObject Crate(Scene scene, Vector3 at, float mass)
			{
				let crate = scene.CreateGameObject("Crate");
				crate.Transform.Position = at;
				crate.AddComponent<BoxCollider>().size = .(0.6f, 0.6f, 0.6f);
				crate.AddComponent<Rigidbody>().mass = mass;
				return crate;
			}

			// Hanging free from a post.
			let hook = Post(scene, .(-6, 5, 0));
			let free = hook.AddComponent<Rope>();
			free.length = 3;
			// Between two posts, with slack.
			let left = Post(scene, .(-3, 4, 0));
			let right = Post(scene, .(-1, 4, 0));
			let sagging = left.AddComponent<Rope>();
			sagging.length = 3;
			sagging.endAttachedTo = right.Transform;
			// Holding up a crate.
			let beam = Post(scene, .(3, 5, 0));
			let load = Crate(scene, .(3, 2.5f, 0), 10);
			let holding = Rope.Attach(beam, load, .Zero, .(0, 0.3f, 0), 2.2f);
			Run(scene, 180);
			free.[Friend]ReadBack();
			sagging.[Friend]ReadBack();
			let hangs = hook.Transform.Position.y - free.Points.Back.y;
			ok &= Check(free.HasBody && hangs > 2.85f && hangs < 3.1f && Math.Abs(free.Points.Back.x + 6) < 0.1f, scope $"a rope hangs straight down from a post ({hangs} m of 3, {free.Points.Count} points)");
			float lowest = 99;
			for (let p in sagging.Points)
				lowest = Math.Min(lowest, p.y);
			ok &= Check(lowest < 3.4f && lowest > 2.5f, scope $"a rope between two posts sags in the middle (lowest {lowest}, posts at 4)");
			let hanging = (load.Transform.Position + Vector3(0, 0.3f, 0) - beam.Transform.Position).Length;
			ok &= Check(hanging > 2.1f && hanging < 2.3f && holding.IsTaut, scope $"a rope holds up a crate, taut ({hanging} m from the beam, rope 2.2)");
			ok &= Check(holding.Pull > 60 && holding.Pull < 140, scope $"and reports the crate's weight as its pull ({holding.Pull} N for 10 kg)");
			holding.[Friend]ReadBack();
			ok &= Check(holding.GetComponent<MeshRenderer>().RuntimeMesh.Vertices.Count == holding.Points.Count * 8, "it draws itself as a tube");
			// Swung sideways, it swings on the rope rather than stretching it.
			load.GetComponent<Rigidbody>().Velocity = .(3, 0, 0);
			float furthest = 0, swungTo = 0;
			for (int tick < 90)
			{
				scene.FixedUpdate();
				furthest = Math.Max(furthest, (load.Transform.Position + Vector3(0, 0.3f, 0) - beam.Transform.Position).Length);
				swungTo = Math.Max(swungTo, load.Transform.Position.x - 3);
			}
			ok &= Check(swungTo > 0.5f && furthest < 2.3f, scope $"pushed, the crate swings on the rope ({swungTo} m out) without stretching it (at most {furthest} m)");
			// Let go, it falls.
			holding.Release();
			Run(scene, 60);
			ok &= Check(load.Transform.Position.y < 0.5f, scope $"Release lets the crate fall ({load.Transform.Position.y})");

			// Towing: a truck (moved by a script, no Rigidbody) drags a crate along the floor.
			let truck = Post(scene, .(-8, 0.5f, 6));
			let trailer = Crate(scene, .(-12, 0.3f, 6), 20);
			Rope.Attach(truck, trailer, .Zero, .Zero, 4.2f);
			for (int tick < 180)
			{
				truck.Transform.Position = truck.Transform.Position + Vector3(2 * Time.FixedDeltaTime, 0, 0);
				scene.FixedUpdate();
			}
			let towed = trailer.Transform.Position.x + 12;
			let gap = (truck.Transform.Position - trailer.Transform.Position).Length;
			// The rope ties onto the crate's face towards the truck, 0.3 m from its middle.
			ok &= Check(towed > 3.5f && gap < 4.7f, scope $"towing: a truck drags a crate behind it ({towed} m, {gap} m apart middle to middle on a 4.2 m rope)");

			// Lifting: a helicopter (a dynamic Rigidbody flying up) lifts a crate off the floor, and feels its weight.
			let copter = Crate(scene, .(8, 3, 6), 200);
			copter.Name.Set("Helicopter");
			let flier = copter.GetComponent<Rigidbody>();
			let cargo = Crate(scene, .(8, 0.3f, 6), 20);
			let sling = Rope.Attach(copter, cargo, .(0, -0.3f, 0), .(0, 0.3f, 0), 2.5f);
			for (int tick < 180)
			{
				// Lift: its own weight, and a little more.
				flier.AddForce(.(0, 200 * 9.81f + 400, 0));
				scene.FixedUpdate();
			}
			ok &= Check(cargo.Transform.Position.y > 1 && sling.Pull > 100, scope $"lifting: a helicopter lifts a crate on a rope (crate at {cargo.Transform.Position.y} m, pull {sling.Pull} N)");

			// Dropped on a box (held at neither end), a rope lies on it.
			let block = scene.CreateGameObject("Block");
			block.Transform.Position = .(0, 0.5f, -6);
			block.AddComponent<BoxCollider>().size = .(2, 1, 2);
			let above = Post(scene, .(0, 3, -6));
			let draped = above.AddComponent<Rope>();
			draped.length = 1.5f;
			draped.holdStart = false;
			Run(scene, 180);
			draped.[Friend]ReadBack();
			let bottom = Lowest(draped.Points).y;
			ok &= Check(bottom > 0.95f && bottom < 1.1f, scope $"a rope dropped on a box lies on it (lowest {bottom}, box top 1)");

			// Each end on its own: a rope held only at its far end by a crate, its start hanging free; then its
			// start tied to a post too.
			let lone = Post(scene, .(12, 0, -6));
			let loose = lone.AddComponent<Rope>();
			loose.length = 2;
			loose.holdStart = false;
			let carrier = Post(scene, .(12, 4, -6));
			loose.endAttachedTo = carrier.Transform;
			Run(scene, 120);
			loose.[Friend]ReadBack();
			let dangles = carrier.Transform.Position.y - Lowest(loose.Points).y;
			ok &= Check(dangles > 1.85f && dangles < 2.1f, scope $"held only at its end, a rope hangs from that end ({dangles} m of 2)");
			let other = Post(scene, .(13, 4, -6));
			loose.AttachStart(other.Transform);
			Run(scene, 60);
			loose.[Friend]ReadBack();
			ok &= Check((loose.Points[0] - other.Transform.Position).Length < 0.05f && (loose.Points.Back - carrier.Transform.Position).Length < 0.05f, "AttachStart ties its other end to something else");
			// What an end is tied to is destroyed: that end lets go.
			scene.Destroy(carrier);
			scene.Update();
			Run(scene, 60);
			scene.Update();
			ok &= Check(loose.HasBody && loose.endAttachedTo == null && Lowest(loose.Points).y < 2.3f, scope $"when what an end holds is destroyed, it lets go and hangs (lowest {Lowest(loose.Points).y})");
		}

		// ---- ropes: wind, wrapping round a beam, snapping ----
		{
			let scene = scope Scene();
			Scene.Active = scene;
			scene.StartPlay();
			Floor(scene);
			GameObject Crate(Scene scene, Vector3 at, float mass)
			{
				let crate = scene.CreateGameObject("Crate");
				crate.Transform.Position = at;
				crate.AddComponent<BoxCollider>().size = .(0.6f, 0.6f, 0.6f);
				crate.AddComponent<Rigidbody>().mass = mass;
				return crate;
			}
			GameObject Beam(Scene scene, Vector3 at)
			{
				let beam = scene.CreateGameObject("Beam");
				beam.Transform.Position = at;
				beam.AddComponent<BoxCollider>().size = .(0.3f, 0.3f, 2);
				return beam;
			}

			// Over a beam: a 13 kg crate and a 10 kg one. Straight, the pull holds them only to each other and both
			// fall; wrapped round the beam it is a pulley, and the heavier one lifts the lighter.
			float Lifted(bool wraps)
			{
				let at = wraps ? -4.0f : 4.0f;
				Beam(scene, .(0, 4, at));
				let heavy = Crate(scene, .(-0.8f, 1.5f, at), 13);
				let light = Crate(scene, .(0.8f, 1.5f, at), 10);
				let rope = Rope.Attach(heavy, light, .(0, 0.3f, 0), .(0, 0.3f, 0));
				rope.wrapsAround = wraps;
				Vector3[4] path = .(.(-0.8f, 1.8f, at), .(-0.2f, 4.2f, at), .(0.2f, 4.2f, at), .(0.8f, 1.8f, at));
				rope.LayAlong(path);
				Run(scene, 240);
				return light.Transform.Position.y;
			}
			let straight = Lifted(false), over = Lifted(true);
			ok &= Check(straight < 1 && over > 2.3f, scope $"Wraps Around: over a beam a rope is a pulley, the heavy crate on the floor holding the light one up (light crate at {over} m; {straight} m without)");

			// Snapping: a 10 kg crate on a rope that breaks at 60 N.
			let hook = scene.CreateGameObject("Hook");
			hook.Transform.Position = .(6, 5, 0);
			let load = Crate(scene, .(6, 3.5f, 0), 10);
			let weak = Rope.Attach(hook, load, .Zero, .(0, 0.3f, 0), 1.2f);
			weak.breakForce = 60;
			for (int tick < 90)
			{
				scene.FixedUpdate();
				scene.Update();
			}
			weak.[Friend]ReadBack();
			let piece = weak.SnappedOff;
			ok &= Check(piece != null && load.Transform.Position.y < 0.5f && (weak.Points[0] - hook.Transform.Position).Length < 0.05f && weak.endAttachedTo == null, scope $"Break Force: pulled harder, it snaps; the crate falls ({load.Transform.Position.y}), half stays on the hook");
			if (piece != null)
			{
				piece.[Friend]ReadBack();
				ok &= Check(piece.startAttachedTo == load.Transform && (piece.Points[0] - (load.Transform.Position + Vector3(0, 0.3f, 0))).Length < 0.35f, "and the other half stays on the crate");
			}

			// Tied with no offset, a rope ties onto the top of a crate under it, and the knot holds the crate in line
			// with the rope: spun and tipped, it settles back hanging upright.
			let gantry = scene.CreateGameObject("Gantry");
			gantry.Transform.Position = .(10, 5, 4);
			let hung = Crate(scene, .(10, 2.7f, 4), 10);
			let sling = Rope.Attach(gantry, hung, .Zero, .Zero, 2);
			Run(scene, 60);
			let knot = sling.EndPoint - hung.Transform.Position;
			let held = hung.GetComponent<Rigidbody>();
			held.AngularVelocity = .(4, 6, 0);
			Run(scene, 180);
			let spin = held.AngularVelocity.Length;
			let upright = Vector3.Dot(hung.Transform.Up, Vector3.Up);
			ok &= Check(knot.Length > 0.25f && knot.y > 0.25f && spin < 0.5f && upright > 0.95f, scope $"the rope ties onto the top of the crate ({knot}), and spun, the crate settles hanging upright (spin {spin}, upright {upright})");

			// Wind blows a hanging rope downwind.
			let post = scene.CreateGameObject("Post");
			post.Transform.Position = .(-8, 5, 0);
			let hanging = post.AddComponent<Rope>();
			hanging.length = 3;
			let wind = scene.CreateGameObject("Wind").AddComponent<WindZone>();
			wind.strength = 6;
			wind.Transform.Rotation = Quaternion.LookRotation(.(0, 0, 1), .Up);
			Run(scene, 180);
			hanging.[Friend]ReadBack();
			ok &= Check(hanging.Points.Back.z > 0.4f, scope $"a gale blows a hanging rope downwind (its end {hanging.Points.Back.z} m over)");
		}

		// ---- a free soft body on a networked object goes where the server says ----
		{
			Time.DeltaTime = Time.FixedDeltaTime;
			NetworkManager.RegisterPrefab("Jelly", new => MakeJelly);
			let port = (uint16)(47000 + (DateTime.Now.Ticks / 10000) % 900);
			let host = scope Scene();
			Floor(host);
			host.StartPlay();
			host.Network = new NetworkManager(host);
			ok &= Check(host.Network.StartServer(port, true), "a host starts");
			let client = scope Scene();
			Floor(client);
			client.StartPlay();
			client.Network = new NetworkManager(client);
			client.Network.StartClient("127.0.0.1", port);
			Pump(host, client, 60);
			host.Network.Spawn("Jelly", .(0, 1, 0), .Identity, 0);
			Pump(host, client, 180);
			let onHost = host.Find("Jelly"), onClient = client.Find("Jelly");
			ok &= Check(onClient != null && onClient.GetComponent<SoftBody>().HasBody, "the soft body is made on the client too");
			if (onClient != null)
			{
				// The server's script throws it across the room; the client's follows.
				onHost.Transform.Position = onHost.Transform.Position + Vector3(6, 0, 3);
				Pump(host, client, 120);
				let hostBody = onHost.GetComponent<SoftBody>(), clientBody = onClient.GetComponent<SoftBody>();
				let apart = (Average(hostBody.Positions) - Average(clientBody.Positions)).Length;
				ok &= Check(apart < 0.3f, scope $"the client's body follows where the server's is ({apart} m apart after it was moved 6.7 m)");
			}
			client.Network.Stop();
			host.Network.Stop();
		}

		// ---- networked by default: scene soft bodies, dents and ropes on a host, a client and a late joiner ----
		{
			let shellMesh = Box(.(0.9f, 0.6f, 2), 8);
			defer delete shellMesh;
			// The same scene on every machine, as if loaded from one file.
			void Build(Scene scene)
			{
				Floor(scene);
				let ball = scene.CreateGameObject("Ball");
				ball.Transform.Position = .(0, 1, -8);
				ball.AddComponent<MeshRenderer>().mesh.Set("builtin:sphere");
				ball.AddComponent<SoftBody>().kind = .Jelly;
				let car = scene.CreateGameObject("Car");
				car.Transform.Position = .(10, 0.6f, 0);
				car.AddComponent<BoxCollider>().size = .(1.8f, 1.2f, 4);
				car.AddComponent<Rigidbody>().mass = 1000;
				car.AddComponent<MeshRenderer>().RuntimeMesh = shellMesh;
				car.AddComponent<SoftBody>().kind = .Shell;
				let hook = scene.CreateGameObject("Hook");
				hook.Transform.Position = .(-10, 5, 0);
				let load = scene.CreateGameObject("Load");
				load.Transform.Position = .(-10, 3.5f, 0);
				load.AddComponent<BoxCollider>().size = .(0.6f, 0.6f, 0.6f);
				load.AddComponent<Rigidbody>().mass = 10;
				let post = scene.CreateGameObject("Post");
				post.Transform.Position = .(-14, 5, 0);
				post.AddComponent<Rope>().length = 2;
				scene.StartPlay();
			}
			int Ropes(Scene scene) => scene.FindComponents<Rope>(.. scope .()).Count;
			Rope RopeOn(Scene scene, StringView from)
			{
				for (let rope in scene.FindComponents<Rope>(.. scope .()))
				{
					if (rope.startAttachedTo != null && rope.startAttachedTo.GameObject.Name == from)
						return rope;
				}
				return null;
			}
			float DentGap(SoftBody a, SoftBody b)
			{
				let da = scope List<Vector3>(), db = scope List<Vector3>();
				a.GetDents(da);
				b.GetDents(db);
				if (da.Count != db.Count)
					return 99;
				float gap = 0;
				for (int i < da.Count)
					gap = Math.Max(gap, (da[i] - db[i]).Length);
				return gap;
			}
			void Hit(Scene scene, Vector3 at, Vector3 velocity)
			{
				let thrown = scene.CreateGameObject("Thrown");
				thrown.Transform.Position = at;
				thrown.AddComponent<BoxCollider>().size = .(0.6f, 0.6f, 0.6f);
				let rigid = thrown.AddComponent<Rigidbody>();
				rigid.mass = 200;
				rigid.EnsureBody();
				rigid.Velocity = velocity;
			}

			let port = (uint16)(47000 + (DateTime.Now.Ticks / 10000 + 450) % 900);
			let host = scope Scene();
			Build(host);
			host.Network = new NetworkManager(host);
			ok &= Check(host.Network.StartServer(port, true), "networked by default: a host starts");
			let client = scope Scene();
			Build(client);
			client.Network = new NetworkManager(client);
			client.Network.StartClient("127.0.0.1", port);
			Pump(host, client, 90);
			ok &= Check(client.Network.IsConnected, "a client joins");

			// A free soft body in the scene is shared without a Network Identity set up by hand.
			let hostBall = host.Find("Ball"), clientBall = client.Find("Ball");
			ok &= Check(hostBall.GetComponent<NetworkIdentity>() != null && clientBall.GetComponent<NetworkIdentity>() != null, "a free soft body in the scene gets a Network Identity when the session starts");
			hostBall.Transform.Position = hostBall.Transform.Position + Vector3(5, 0, 0);
			Pump(host, client, 120);
			let ballGap = (Average(hostBall.GetComponent<SoftBody>().Positions) - Average(clientBall.GetComponent<SoftBody>().Positions)).Length;
			ok &= Check(ballGap < 0.3f, scope $"and the client's follows the server's ({ballGap} m apart)");

			// Dents are the server's: a crash there dents the client's car the same; a hit only the client sees does not.
			let hostShell = host.Find("Car").GetComponent<SoftBody>(), clientShell = client.Find("Car").GetComponent<SoftBody>();
			Hit(client, .(13, 0.9f, 0), .(-9, 0, 0));
			Pump(host, client, 60);
			ok &= Check(clientShell.DeepestDent() < 0.002f, scope $"a hit only a client sees leaves no dent there ({clientShell.DeepestDent()} m)");
			Hit(host, .(7, 0.9f, 0), .(9, 0, 0));
			Pump(host, client, 90);
			let dentGap = DentGap(hostShell, clientShell);
			ok &= Check(hostShell.DeepestDent() > 0.02f && dentGap < 0.003f, scope $"a crash on the server dents the client's car the same ({hostShell.DeepestDent()} m deep, {dentGap} m apart)");
			clientShell.Repair();
			Pump(host, client, 30);
			ok &= Check(hostShell.DeepestDent() > 0.02f && DentGap(hostShell, clientShell) < 0.003f, "a client cannot repair a car it does not own: the server's dents come back");
			hostShell.Repair();
			Pump(host, client, 30);
			ok &= Check(clientShell.DeepestDent() < 0.002f, "repaired on the server, it is repaired on the client");
			Hit(host, host.Find("Car").Transform.Position + Vector3(-3, 0.3f, 0), .(9, 0, 0));
			Pump(host, client, 90);
			ok &= Check(hostShell.DeepestDent() > 0.005f && DentGap(hostShell, clientShell) < 0.003f, scope $"dented again, the client follows ({hostShell.DeepestDent()} m deep)");

			// Ropes tied, let go and snapped on the server are tied, let go and snapped everywhere.
			let tied = Rope.Attach(host.Find("Hook"), host.Find("Load"), .Zero, .(0, 0.3f, 0), 1.2f);
			Pump(host, client, 30);
			let clientTied = RopeOn(client, "Hook");
			ok &= Check(tied != null && clientTied != null && clientTied.endAttachedTo == client.Find("Load").Transform && clientTied.HasBody, "a rope tied on the server is tied between the same objects on the client");
			ok &= Check(Rope.Attach(client.Find("Post"), client.Find("Load")) == null && Ropes(client) == Ropes(host), "a client cannot tie objects it does not own");
			if (clientTied != null)
				clientTied.breakForce = 1;
			Pump(host, client, 60);
			ok &= Check(clientTied != null && clientTied.SnappedOff == null && clientTied.endAttachedTo != null, "a client does not snap a rope by itself (the server decides)");
			let snapped = tied.Snap();
			Pump(host, client, 30);
			ok &= Check(snapped != null && Ropes(client) == Ropes(host) && clientTied.endAttachedTo == null && RopeOn(client, "Load") != null, scope $"snapped on the server, it snaps on the client ({Ropes(host)} ropes on each)");
			let postRope = host.Find("Post").GetComponent<Rope>();
			postRope.AttachEnd(host.Find("Load").Transform);
			Pump(host, client, 30);
			ok &= Check(client.Find("Post").GetComponent<Rope>().endAttachedTo == client.Find("Load").Transform, "a rope's end tied on the server is tied on the client");
			client.Find("Post").GetComponent<Rope>().Release();
			Pump(host, client, 30);
			ok &= Check(postRope.endAttachedTo != null && client.Find("Post").GetComponent<Rope>().endAttachedTo != null, "a client cannot let go of a rope it does not own");
			host.Network.Spawn("Jelly", .(-12, 1, 3), .Identity, client.Network.LocalClientId);
			Pump(host, client, 60);
			let mine = client.Find("Jelly");
			let ropesBefore = Ropes(host);
			ok &= Check(mine != null && Rope.Attach(client.Find("Post"), mine, .Zero, .Zero, 3) == null, "a client's tie to an object it controls goes to the server");
			Pump(host, client, 30);
			let tiedToMine = RopeOn(host, "Post");
			ok &= Check(Ropes(host) == ropesBefore + 1 && Ropes(client) == Ropes(host) && tiedToMine != null && tiedToMine.endAttachedTo == host.Find("Jelly").Transform && RopeOn(client, "Post")?.endAttachedTo == mine.Transform, "which ties it on every machine");

			// A player who joins late gets the dents and the ropes as they are now.
			let late = scope Scene();
			Build(late);
			late.Network = new NetworkManager(late);
			late.Network.StartClient("127.0.0.1", port);
			for (int i < 150)
			{
				for (let scene in Scene[?](host, client, late))
				{
					scene.FixedUpdate();
					scene.Update();
				}
				System.Threading.Thread.Sleep(4);
			}
			let lateShell = late.Find("Car").GetComponent<SoftBody>();
			ok &= Check(late.Network.IsConnected && hostShell.DeepestDent() > 0.005f && DentGap(hostShell, lateShell) < 0.003f, scope $"a late joiner's car has the server's dents ({DentGap(hostShell, lateShell)} m apart; {hostShell.DeepestDent()} m deep, connected {late.Network.IsConnected})");
			ok &= Check(Ropes(late) == Ropes(host) && RopeOn(late, "Load") != null && late.Find("Post").GetComponent<Rope>().endAttachedTo == late.Find("Load").Transform, scope $"and its ropes as they are now ({Ropes(late)} of {Ropes(host)})");
			late.Network.Stop();
			client.Network.Stop();
			host.Network.Stop();
		}

		Console.WriteLine(ok ? "ALL PASS" : "SOME FAILED");
		return ok ? 0 : 1;
	}
}
