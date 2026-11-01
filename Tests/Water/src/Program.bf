using System;
using System.Collections;
using Tallow;

namespace WaterTests;

/// Water (docs/water.md): the waves' sums and the shared clock, floating and sinking with Jolt's buoyancy, the
/// current, swimming, and the water in a network session (a host, a client and a late joiner).
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static void Run(Scene scene, int ticks)
	{
		for (int i < ticks)
			scene.FixedUpdate();
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

	static GameObject Ground(Scene scene, StringView name, Vector3 center, Vector3 size)
	{
		let ground = scene.CreateGameObject(name);
		ground.Transform.Position = center;
		ground.AddComponent<BoxCollider>().size = size;
		return ground;
	}

	static Water MakeWater(Scene scene, float waveHeight)
	{
		let gameObject = scene.CreateGameObject("Lake");
		let water = gameObject.AddComponent<Water>();
		water.size = .(30, 30);
		water.depth = 10;
		water.waveHeight = waveHeight;
		return water;
	}

	static Rigidbody Crate(Scene scene, StringView name, Vector3 at, float mass = 40)
	{
		let crate = scene.CreateGameObject(name);
		crate.Transform.Position = at;
		crate.AddComponent<BoxCollider>().size = .One;
		let body = crate.AddComponent<Rigidbody>();
		body.mass = mass;
		return body;
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

	/// Steps and draws (soft bodies read their vertices back as a frame ends).
	static void Frames(Scene scene, int ticks)
	{
		for (int i < ticks)
		{
			scene.FixedUpdate();
			scene.Update();
		}
	}

	static float Lowest(List<Vector3> points)
	{
		var lowest = float.MaxValue;
		for (let p in points)
			lowest = Math.Min(lowest, p.y);
		return lowest;
	}

	static Vector3 Average(List<Vector3> points)
	{
		var sum = Vector3.Zero;
		for (let p in points)
			sum = sum + p;
		return points.IsEmpty ? sum : sum / points.Count;
	}

	/// Where the still point (x, z) of the water is carried by its waves at a time: the sums of Water.bf written out
	/// again, to check SurfaceAt against.
	static Vector3 Displaced(Water water, Vector2 still, double time)
	{
		float[Water.WaveCount] phases = default;
		water.Phases(time, ref phases);
		var point = Vector3(still.x, water.Level, still.y);
		let waves = water.Waves;
		for (int i < Water.WaveCount)
		{
			let wave = waves[i];
			let theta = wave.k * (wave.direction.x * still.x + wave.direction.y * still.y) - phases[i];
			point.x += wave.direction.x * wave.steepness * wave.amplitude * Math.Cos(theta);
			point.z += wave.direction.y * wave.steepness * wave.amplitude * Math.Cos(theta);
			point.y += wave.amplitude * Math.Sin(theta);
		}
		return point;
	}

	/// Rollback must apply the same environmental forces, at the replayed tick, as forward simulation.
	static bool ReplayBuoyancy(float waves, bool predicted = false)
	{
		let savedTick = Time.Tick;
		defer { Time.Tick = savedTick; }
		let forward = scope Scene();
		let replay = scope Scene();
		MakeWater(forward, waves);
		MakeWater(replay, waves);
		let expected = Crate(forward, "Forward", .(0, -0.1f, 0));
		let actual = Crate(replay, "Replay", .(0, -0.1f, 0));
		let identity = actual.GameObject.AddComponent<NetworkIdentity>();
		for (let scene in Scene[?](forward, replay))
		{
			Time.Tick = 0;
			scene.StartPlay();
			scene.FixedUpdate();
		}
		replay.Network = new NetworkManager(replay);
		replay.Network.[Friend]mIdentities.Add(identity);
		List<(NetworkIdentity identity, BodyState state)> owned = scope .();
		if (predicted)
		{
			identity.ownerId = 1;
			identity.Predicted = true;
			identity.PredictedSince = 0;
			replay.Network.PredictedBodies = 1;
		}
		else
			owned.Add((identity, identity.CaptureState()));
		const uint32 ack = 173;
		const uint32 steps = 12;
		for (uint32 tick = ack + 1; tick <= ack + steps; tick++)
		{
			Time.Tick = (int32)tick;
			Water.Simulate(forward, Time.FixedDeltaTime);
			forward.Physics.Step(Time.FixedDeltaTime);
		}
		// Current scene time deliberately differs from replay time: waves must use each historical tick.
		Time.Tick = 5000;
		replay.Network.[Friend]mTick = ack + steps;
		replay.Network.[Friend]ReplayInputs(ack, owned);
		let positionGap = (expected.Transform.Position - actual.Transform.Position).Length;
		let velocityGap = (expected.Velocity - actual.Velocity).Length;
		return Check(positionGap < 0.001f && velocityGap < 0.001f,
			scope $"rollback reapplies buoyancy at historical ticks (predicted {predicted}, waves {waves}, position gap {positionGap}, velocity gap {velocityGap})");
	}

	public static int Main(String[] args)
	{
		bool ok = true;

		// ---- the waves ----
		{
			let scene = scope Scene();
			let water = MakeWater(scene, 1.0f);
			water.Transform.Position = .(0, 2, 0);
			float worst = 0, highest = float.MinValue, lowest = float.MaxValue;
			for (int i < 200)
			{
				let still = Vector2((i % 20) * 0.73f - 7, (i / 20) * 0.91f - 5);
				let time = 3.0 + i * 0.37;
				let point = Displaced(water, still, time);
				water.SurfaceAt(point, time, let height, ?, ?);
				worst = Math.Max(worst, Math.Abs(height - point.y));
				highest = Math.Max(highest, height);
				lowest = Math.Min(lowest, height);
			}
			ok &= Check(worst < 0.003f, scope $"the surface's height is where the waves carry the water ({worst} m off at most)");
			ok &= Check(highest - lowest <= 1.0f + 0.001f && highest - lowest > 0.4f && Math.Abs((highest + lowest) * 0.5f - 2) < 0.3f, scope $"waves 1 m high stay within it, round the level ({lowest:0.00} to {highest:0.00} m)");
			float folds = 0;
			for (let wave in water.Waves)
				folds += wave.steepness * wave.k * wave.amplitude;
			ok &= Check(folds <= 0.951f, scope $"crests never fold over ({folds:0.000} of 1)");

			// The same settings and seed make the same waves; another seed others.
			let twin = MakeWater(scene, 1.0f);
			twin.Transform.Position = .(0, 2, 0);
			let other = MakeWater(scene, 1.0f);
			other.Transform.Position = .(0, 2, 0);
			other.waveSeed = 7;
			let at = Vector3(3.3f, 0, -1.2f);
			ok &= Check(Math.Abs(water.HeightAt(at) - twin.HeightAt(at)) < 1e-5f, "two waters with the same settings have the same waves");
			water.SurfaceAt(at, 10, let first, ?, ?);
			other.SurfaceAt(at, 10, let second, ?, ?);
			ok &= Check(Math.Abs(first - second) > 1e-4f, "another seed arranges them differently");

			// A day into a session the waves move as smoothly as at its start.
			water.SurfaceAt(at, 86400.0, let now, ?, ?);
			water.SurfaceAt(at, 86400.0 + 1.0 / 60, let next, ?, ?);
			water.SurfaceAt(at, 10.0, let early, ?, ?);
			water.SurfaceAt(at, 10.0 + 1.0 / 60, let earlyNext, ?, ?);
			ok &= Check(Math.Abs(now - next) < 0.1f && Math.Abs(Math.Abs(now - next) - Math.Abs(early - earlyNext)) < 0.1f, scope $"waves stay smooth a day in (a tick moves the surface {Math.Abs(now - next):0.0000} m)");

			water.waveHeight = 0;
			water.SurfaceAt(at, 5, let still, let normal, ?);
			ok &= Check(Math.Abs(still - 2) < 1e-5f && normal.y > 0.9999f, "with no waves the surface is level, at the object's height");

			// Over the water or not: the rectangle turns and scales with the object; endless water is everywhere.
			water.Transform.EulerAngles = .(0, 45, 0);
			water.Transform.LocalScale = .(2, 1, 1);
			let model = water.Transform.LocalToWorld;
			ok &= Check(water.Covers(model.TransformPoint(.(14.5f, 0, 0))) && !water.Covers(model.TransformPoint(.(15.5f, 0, 0))) && water.Covers(model.TransformPoint(.(0, 0, 14.5f)))
				&& !water.Covers(model.TransformPoint(.(0, 0, 15.5f))) && (model.TransformPoint(.(14.5f, 0, 0)) - Vector3(0, 2, 0)).Length > 28, "the water's rectangle turns and scales with its object");
			ok &= Check(!water.Covers(.(0, 0, 40)), "a point past it is not over it");
			water.endless = true;
			ok &= Check(water.Covers(.(5000, 0, -9000)), "endless water is everywhere");
			ok &= Check(water.Contains(.(10, 1, 10)) && !water.Contains(.(10, 3, 10)) && !water.Contains(.(10, -9, 10)), "a point is in the water below the surface and above the bottom");
			ok &= Check(Math.Abs(water.DepthOf(.(1, -1, 1)) - 3) < 1e-4f, "how deep a point is under the surface");
			let higher = MakeWater(scene, 0);
			higher.Transform.Position = .(0, 5, 0);
			ok &= Check(Water.At(scene, .(1, 4, 1)) == higher && Water.At(scene, .(1, 4, 40)) != higher, "Water.At finds the water a point is in, the highest of several");
		}

		// ---- floating ----
		{
			let scene = scope Scene();
			Ground(scene, "Floor", .(0, -10.5f, 0), .(80, 1, 80));
			let water = MakeWater(scene, 0);
			let floats = Crate(scene, "Floats", .(0, 2, 0));
			let stone = Crate(scene, "Stone", .(4, 2, 0));
			stone.GameObject.AddComponent<Floater>().buoyancy = 0.5f;
			let cork = Crate(scene, "Cork", .(-4, 2, 0));
			cork.GameObject.AddComponent<Floater>().buoyancy = 4;
			let off = Crate(scene, "Off", .(8, 2, 0));
			off.GameObject.AddComponent<Floater>().Enabled = false;
			let outside = Crate(scene, "Outside", .(40, 2, 0));
			scene.StartPlay();
			Run(scene, 600);
			// Buoyancy 1.6 floats with about 1 / 1.6 of the box under (Jolt measures the box's volume with its rounded
			// edges): its middle a little below the surface.
			let y = floats.Transform.Position.y;
			let under = 0.5f - y;
			ok &= Check(under > 0.5f && under < 0.7f && floats.Velocity.Length < 0.2f, scope $"a Rigidbody floats with the water's buoyancy, about as deep as it should ({under * 100:0} percent under, 1 / 1.6 is 62; moving at {floats.Velocity.Length:0.000} m/s)");
			ok &= Check(water.IsFloating(floats) && floats.GameObject.GetComponent<Floater>() == null, "and is in the water without a Floater");
			let corkY = cork.Transform.Position.y;
			ok &= Check(corkY > y + 0.2f && cork.GameObject.GetComponent<Floater>().InWater, scope $"a Floater's own buoyancy floats a cork higher ({corkY:0.000} m)");
			ok &= Check(stone.Transform.Position.y < -9.3f, scope $"and a stone sinks to the bottom ({stone.Transform.Position.y:0.00} m)");
			ok &= Check(off.Transform.Position.y < -9.3f, "a disabled Floater does not float");
			ok &= Check(outside.Transform.Position.y < -9.3f, "a crate beside the water is not floated by it");

			// Off for plain Rigidbodies: only those with a Floater float.
			water.floatRigidbodies = false;
			Run(scene, 300);
			ok &= Check(floats.Transform.Position.y < -9.3f && cork.Transform.Position.y > -0.5f, "with Float Rigidbodies off, only objects with a Floater float");
			water.floatRigidbodies = true;

			// The current carries what floats.
			Run(scene, 300);
			let before = cork.Transform.Position;
			water.flow = .(2, 0);
			Run(scene, 300);
			let drift = cork.Transform.Position - before;
			ok &= Check(drift.x > 4 && Math.Abs(drift.z) < 1, scope $"the current carries a floating object along it ({drift.x:0.0} m in 5 s)");
			water.flow = .Zero;

			// Waves rock it.
			water.waveHeight = 0.8f;
			float top = float.MinValue, bottom = float.MaxValue;
			for (int i < 600)
			{
				scene.FixedUpdate();
				if (i > 120)
				{
					top = Math.Max(top, cork.Transform.Position.y);
					bottom = Math.Min(bottom, cork.Transform.Position.y);
				}
			}
			ok &= Check(top - bottom > 0.15f && top < 2, scope $"waves lift and drop it ({bottom:0.00} to {top:0.00} m)");
		}

		// ---- swimming ----
		{
			let scene = scope Scene();
			Ground(scene, "Floor", .(0, -10.5f, 0), .(80, 1, 80));
			// A shelf one metre under the surface: wading depth.
			Ground(scene, "Shelf", .(20, -1.5f, 0), .(6, 1, 6));
			let water = MakeWater(scene, 0);
			water.size = .(60, 60);
			let swimmer = scene.CreateGameObject("Swimmer");
			swimmer.Transform.Position = .(0, -1, 0);
			let controller = swimmer.AddComponent<CharacterController>();
			let wader = scene.CreateGameObject("Wader");
			wader.Transform.Position = .(20, 0.2f, 0);
			let walking = wader.AddComponent<CharacterController>();
			scene.StartPlay();
			void Step(int ticks, Vector3 move = .Zero, float jump = 0)
			{
				for (int i < ticks)
				{
					scene.FixedUpdate();
					controller.SimpleMove(move, Time.FixedDeltaTime, jump);
					walking.SimpleMove(.Zero, Time.FixedDeltaTime);
				}
			}
			Step(240);
			let middle = swimmer.Transform.Position.y;
			let head = middle + controller.height * 0.5f;
			ok &= Check(controller.IsSwimming && head > 0.1f && head < 0.8f && Math.Abs(controller.Velocity.y) < 0.2f, scope $"a character in deep water swims, floating with its head out (top at {head:0.00} m)");
			ok &= Check(!walking.IsSwimming && walking.IsGrounded, "one in water shallower than Swim Depth wades on the bottom");
			Step(15, .Zero, 6);
			ok &= Check(swimmer.Transform.Position.y > middle + 0.3f, scope $"a jump swims it up ({swimmer.Transform.Position.y - middle:0.00} m)");
			Step(180);
			let x = swimmer.Transform.Position.x;
			Step(120, .(3, 0, 0));
			let swum = swimmer.Transform.Position.x - x;
			ok &= Check(swum > 2.5f && swum < 2 * 3 * 0.75f, scope $"swimming is slower than walking ({swum:0.00} m in 2 s at 3 m/s)");
			water.flow = .(0, 1.5f);
			let z = swimmer.Transform.Position.z;
			Step(120);
			ok &= Check(swimmer.Transform.Position.z - z > 1.5f, scope $"the current carries a swimmer ({swimmer.Transform.Position.z - z:0.00} m in 2 s)");
			water.flow = .Zero;
			let top = swimmer.Transform.Position.y;
			for (int i < 120)
			{
				scene.FixedUpdate();
				controller.Swim(.(0, -2, 0), Time.FixedDeltaTime);
			}
			ok &= Check(swimmer.Transform.Position.y < top - 1.5f && controller.IsSwimming, scope $"Swim dives under ({swimmer.Transform.Position.y:0.00} m)");
			Step(300);
			ok &= Check(swimmer.Transform.Position.y > top - 0.3f, "let go, it floats back up");
			controller.canSwim = false;
			Step(240);
			ok &= Check(!controller.IsSwimming && controller.IsGrounded && swimmer.Transform.Position.y < -9, "with Can Swim off it walks on the bottom");
		}

		// ---- soft bodies and ropes ----
		{
			let scene = scope Scene();
			Ground(scene, "Floor", .(0, -10.5f, 0), .(80, 1, 80));
			let water = MakeWater(scene, 0);
			GameObject Jelly(StringView name, Vector3 at)
			{
				let ball = scene.CreateGameObject(name);
				ball.Transform.Position = at;
				ball.AddComponent<MeshRenderer>().mesh.Set("builtin:sphere");
				ball.AddComponent<SoftBody>().kind = .Jelly;
				return ball;
			}
			let jelly = Jelly("Jelly", .(-6, 1.5f, 0));
			let heavy = Jelly("Heavy Jelly", .(-6, 1.5f, 6));
			heavy.AddComponent<Floater>().buoyancy = 0.5f;
			let sheet = Sheet(16, 2);
			defer delete sheet;
			let cloth = scene.CreateGameObject("Cloth");
			cloth.Transform.Position = .(0, 1, 0);
			cloth.AddComponent<MeshRenderer>().RuntimeMesh = sheet;
			let clothBody = cloth.AddComponent<SoftBody>();
			let ropeObject = scene.CreateGameObject("Rope");
			ropeObject.Transform.Position = .(6, 1, 0);
			let rope = ropeObject.AddComponent<Rope>();
			rope.length = 3;
			rope.holdStart = false;

			let shellMesh = Sheet(1, 1);
			defer delete shellMesh;
			let crate = scene.CreateGameObject("Shell Crate");
			crate.Transform.Position = .(0, 1.5f, 8);
			crate.AddComponent<MeshRenderer>().mesh.Set("builtin:cube");
			crate.AddComponent<SoftBody>().kind = .Shell;
			scene.StartPlay();
			// Thrown in along the water, as it would be: dropped straight down, a rope balances on end like a stick.
			Frames(scene, 1);
			rope.LayAlong(scope Vector3[](.(5, 0.6f, 0), .(7.9f, 0.4f, 0)));
			Frames(scene, 600);
			let jellyMiddle = Average(jelly.GetComponent<SoftBody>().Positions);
			ok &= Check(jellyMiddle.y < 0.25f && jellyMiddle.y > -0.4f && water.IsFloating(jelly.GetComponent<SoftBody>()), scope $"a jelly floats on the water (its middle at {jellyMiddle.y:0.00} m)");
			ok &= Check(Average(heavy.GetComponent<SoftBody>().Positions).y < -9, "and one with a Floater of buoyancy 0.5 sinks");
			let clothMiddle = Average(clothBody.Positions);
			ok &= Check(Math.Abs(clothMiddle.y) < 0.15f && clothBody.GameObject.GetComponent<Floater>() == null && water.IsFloating(clothBody), scope $"cloth lies on the surface ({clothMiddle.y:0.000} m)");
			let ropeMiddle = Average(rope.Points);
			ok &= Check(Math.Abs(ropeMiddle.y) < 0.2f && water.IsFloating(rope), scope $"a rope floats ({ropeMiddle.y:0.000} m, lowest point {Lowest(rope.Points):0.00} m)");
			ok &= Check(crate.Transform.Position.y > -1 && crate.Transform.Position.y < 0.5f, scope $"a shell floats on its Rigidbody ({crate.Transform.Position.y:0.00} m)");

			// The current carries them.
			water.flow = .(1.5f, 0);
			let clothBefore = Average(clothBody.Positions);
			let jellyBefore = Average(jelly.GetComponent<SoftBody>().Positions);
			Frames(scene, 180);
			ok &= Check(Average(clothBody.Positions).x - clothBefore.x > 2 && Average(jelly.GetComponent<SoftBody>().Positions).x - jellyBefore.x > 1.5f, scope $"the current carries cloth and jelly ({Average(clothBody.Positions).x - clothBefore.x:0.0} m and {Average(jelly.GetComponent<SoftBody>().Positions).x - jellyBefore.x:0.0} m in 3 s)");
			water.flow = .Zero;

			// Waves lift it and keep it awake.
			water.waveHeight = 0.6f;
			float top = float.MinValue, bottom = float.MaxValue;
			for (int i < 300)
			{
				Frames(scene, 1);
				let y = Average(clothBody.Positions).y;
				if (i > 60)
				{
					top = Math.Max(top, y);
					bottom = Math.Min(bottom, y);
				}
			}
			ok &= Check(top - bottom > 0.1f && top < 1, scope $"waves lift and drop the cloth ({bottom:0.00} to {top:0.00} m)");

			// A fine cloth (1,089 points, a gram each) crumpled by the waves stays on the water.
			let big = Sheet(32, 4);
			defer delete big;
			let bigCloth = scene.CreateGameObject("Big Cloth");
			bigCloth.Transform.Position = .(-12, 0.5f, -10);
			bigCloth.AddComponent<MeshRenderer>().RuntimeMesh = big;
			let bigBody = bigCloth.AddComponent<SoftBody>();
			Frames(scene, 600);
			var lo = Vector3(float.MaxValue), hi = Vector3(float.MinValue);
			for (let p in bigBody.Positions)
			{
				lo = Vector3.Min(lo, p);
				hi = Vector3.Max(hi, p);
			}
			ok &= Check(lo.y > -1.5f && hi.y < 1 && hi.x - lo.x < 6 && water.IsFloating(bigBody), scope $"a fine cloth rides the waves without coming apart ({lo.y:0.00} to {hi.y:0.00} m high, {hi.x - lo.x:0.0} m across)");

			// What floating costs: that cloth as well as the rest, timed (with a step too short to move them).
			let watch = scope System.Diagnostics.Stopwatch()..Start();
			for (int i < 200)
				Water.Simulate(scene, 1.0e-6f);
			let each = watch.Elapsed.TotalMilliseconds * 1000 / 200;
			ok &= Check(water.IsFloating(bigCloth.GetComponent<SoftBody>()) && each < 1000, scope $"floating is cheap: {each:0} microseconds a step for every body in this scene (a Debug build)");

			// Off: only things with a Floater float.
			water.waveHeight = 0;
			water.floatRigidbodies = false;
			Frames(scene, 300);
			ok &= Check(Average(clothBody.Positions).y < -9 && jelly.GetComponent<SoftBody>() != null && Average(jelly.GetComponent<SoftBody>().Positions).y < -9, "with Float Rigidbodies off, soft bodies without a Floater sink");
		}

		// ---- networked by default: a host, a client and a late joiner ----
		{
			void Build(Scene scene)
			{
				Ground(scene, "Floor", .(0, -10.5f, 0), .(80, 1, 80));
				let water = MakeWater(scene, 0.6f);
				water.flow = .(0.3f, 0);
				Crate(scene, "Crate", .(0, 2, 0));
				scene.StartPlay();
			}
			let port = (uint16)(47000 + (DateTime.Now.Ticks / 10000 + 610) % 900);
			let host = scope Scene();
			Build(host);
			host.Network = new NetworkManager(host);
			ok &= Check(host.Network.StartServer(port, true), "networked by default: a host starts");
			let client = scope Scene();
			Build(client);
			client.Network = new NetworkManager(client);
			client.Network.StartClient("127.0.0.1", port);
			Pump(host, client, 120);
			ok &= Check(client.Network.IsConnected, "a client joins");
			let hostWater = host.Find("Lake").GetComponent<Water>(), clientWater = client.Find("Lake").GetComponent<Water>();
			ok &= Check(hostWater.GameObject.GetComponent<NetworkIdentity>() != null && clientWater.GameObject.GetComponent<NetworkIdentity>() != null, "water in the scene gets a Network Identity when the session starts");

			// The waves run on the session's clock: the client draws the server's waves.
			let gap = Math.Abs(Water.ViewTime(host) - Water.ViewTime(client));
			let at = Vector3(2.5f, 0, -3.1f);
			hostWater.SurfaceAt(at, Water.ViewTime(host), let hostHeight, ?, ?);
			clientWater.SurfaceAt(at, Water.ViewTime(client), let clientHeight, ?, ?);
			ok &= Check(gap < 0.1 && Math.Abs(hostHeight - clientHeight) < 0.05f, scope $"the client's waves are the server's ({gap * 1000:0} ms apart, {Math.Abs(hostHeight - clientHeight) * 100:0.0} cm)");

			// Floating things are the server's.
			Pump(host, client, 240);
			let hostCrate = host.Find("Crate"), clientCrate = client.Find("Crate");
			let crateGap = (hostCrate.Transform.Position - clientCrate.Transform.Position).Length;
			ok &= Check(hostCrate.Transform.Position.y > -1 && clientCrate.Transform.Position.y > -1 && crateGap < 0.5f, scope $"a crate floats on the server and on the client in the same place ({crateGap:0.00} m apart)");

			// Settings changed on the server, and the level, reach the client; a client's own changes do not stay.
			hostWater.waveHeight = 1.5f;
			hostWater.flow = .(0, -1);
			hostWater.look = .LowPoly;
			hostWater.shallowColor = .(1, 0, 0, 1);
			hostWater.Transform.Position = .(0, 1, 0);
			Pump(host, client, 90);
			ok &= Check(clientWater.waveHeight == 1.5f && clientWater.flow == Vector2(0, -1) && clientWater.look == .LowPoly && clientWater.shallowColor == Color(1, 0, 0, 1),
				"the server's changes to the water reach the client");
			ok &= Check(Math.Abs(clientWater.Level - 1) < 0.05f, scope $"and so does a new water level ({clientWater.Level:0.00} m)");
			clientWater.waveHeight = 3;
			Pump(host, client, 60);
			ok &= Check(clientWater.waveHeight == 1.5f || hostWater.waveHeight == 1.5f, "the server's settings win over a client's");

			// A late joiner gets the water as it is now.
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
			let lateWater = late.Find("Lake").GetComponent<Water>();
			ok &= Check(late.Network.IsConnected && lateWater.waveHeight == 1.5f && lateWater.look == .LowPoly && Math.Abs(lateWater.Level - 1) < 0.05f,
scope $"a late joiner's water is the server's as it is now (waves {lateWater.waveHeight} m, level {lateWater.Level:0.00} m)");
			late.Network.Stop();
			client.Network.Stop();
			host.Network.Stop();
		}

		ok &= ReplayBuoyancy(0);
		ok &= ReplayBuoyancy(0.8f);
		ok &= ReplayBuoyancy(0, true);
		ok &= ReplayBuoyancy(0.8f, true);

		Console.WriteLine(ok ? "ALL PASS" : "SOME FAILED");
		return ok ? 0 : 1;
	}
}
