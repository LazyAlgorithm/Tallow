using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// The modes CSharpBench also has, with the same work: getcomponent (count GetComponent calls a frame, a native
/// component and a script, hit and miss), physics (Jolt spheres in a walled box, each with a Ball script damping
/// its velocity) and lifecycle (every other frame count objects with a Lifer script are made, then destroyed).
extension Bench
{
	List<Rigidbody> mBalls = new .() ~ delete _;
	List<GameObject> mLifers = new .() ~ delete _;
	List<double> mCreateTimes = new .() ~ delete _;
	List<double> mDestroyTimes = new .() ~ delete _;
	int64 mChecksum;

	void StepGetComponent()
	{
		int64 found = 0;
		for (int i < mCount)
		{
			// Half hits (a native component and this component), half misses.
			if ((i & 3) == 0 && GetComponent<MeshRenderer>() != null) found++;
			else if ((i & 3) == 1 && GetComponent<Bench>() != null) found++;
			else if ((i & 3) == 2 && GetComponent<Rigidbody>() != null) found++;
			else if ((i & 3) == 3 && GetComponent<Mover>() != null) found++;
		}
		mChecksum += found;
	}

	void SpawnPhysics()
	{
		let half = Workload.PhysicsHalfSize(mCount);
		Workload.PhysicsBox(half, let floorPosition, let floorSize);
		AddWall(floorPosition, floorSize);
		for (int side < 4)
		{
			Workload.PhysicsWall(half, side, let position, let size);
			AddWall(position, size);
		}
		for (int i < mCount)
		{
			let ball = Scene.CreateGameObject("Ball");
			ball.Transform.LocalPosition = Workload.PhysicsStart(i, half);
			ball.AddComponent<SphereCollider>();
			var body = ball.AddComponent<Rigidbody>();
			let sleep = scope String();
			body.allowSleeping = !(ReadSetting("TALLOW_BENCH_SLEEP", sleep) && sleep == "0");
			mBalls.Add(body);
			ball.AddComponent<Ball>();
		}
	}

	void AddWall(Vector3 position, Vector3 size)
	{
		let wall = Scene.CreateGameObject("Wall");
		wall.Transform.LocalPosition = position;
		wall.AddComponent<BoxCollider>().size = size;
	}

	int64 mHits;
	List<GameObject> mWalkers = new .() ~ delete _;

	void SpawnQueryField()
	{
		AddWall(.(0, -0.5f, 0), .(102, 1, 102));
		for (int i < Workload.QueryObstacles)
		{
			Workload.QueryObstacle(i, let position, let size);
			AddWall(position, size);
		}
	}

	/// Every query of the frame; the last frame's hits and distances (to the millimetre) are reported.
	void StepQueries()
	{
		let physics = Scene.Physics;
		let sphere = mMode == "spherecast";
		int64 hits = 0, checksum = 0;
		for (int i < mCount)
		{
			Workload.QueryRay(i, let origin, let direction);
			float distance = -1;
			if (sphere)
			{
				if (physics.SphereCast(origin, Workload.QueryRadius, direction, Workload.QueryMaxDistance, let hit))
					distance = hit.distance;
			}
			else if (physics.Raycast(origin, direction, Workload.QueryMaxDistance, let hit))
				distance = hit.distance;
			if (distance >= 0)
			{
				hits++;
				checksum += (int64)(distance * 1000);
			}
		}
		mHits = hits;
		mChecksum = checksum;
	}

	float mPileHalf;
	bool mPileSleep = true;
	bool mPileDone;
	List<double> mPileWindow = new .() ~ delete _;
	List<double> mStepTimes = new .() ~ delete _;
	int mPileWindows, mPileReached;
	double mPileStopP95;
	String mPileStop = new .() ~ delete _;
	GameObject mPileEnd;

	void StartPile()
	{
		let sleep = scope String();
		mPileSleep = !(ReadSetting("TALLOW_BENCH_SLEEP", sleep) && sleep == "0");
		mPileHalf = Workload.PhysicsHalfSize(mCount);
		Workload.PhysicsBox(mPileHalf, let floorPosition, let floorSize);
		AddWall(floorPosition, floorSize);
		for (int side < 4)
		{
			Workload.PhysicsWall(mPileHalf, side, let position, let size);
			AddWall(position, size);
		}
		mFrames = int.MaxValue; // the pile ends the run itself
	}

	/// CSharpBench's StepPile: a batch of balls at the start of each window; at its end, stop if the window's p95 frame
	/// time was over 16.67 ms or every ball is in. Also keeps Jolt's own step time.
	void StepPile(double frameMs)
	{
		if (mPileDone)
			return;
		mStepTimes.Add(Scene.Physics.LastStepMilliseconds);
		if (mPileWindow.IsEmpty)
		{
			for (int i < Workload.PileBatch)
			{
				if (mBalls.Count >= mCount)
					break;
				let ball = Scene.CreateGameObject("Ball");
				ball.Transform.LocalPosition = Workload.PileStart(mBalls.Count, mPileHalf);
				ball.AddComponent<SphereCollider>();
				var body = ball.AddComponent<Rigidbody>();
				body.allowSleeping = mPileSleep;
				ball.AddComponent<Ball>();
				mBalls.Add(body);
			}
			// The end marker goes after the new balls, so their Updates are inside the timed span.
			if (mPileEnd != null)
				Scene.Destroy(mPileEnd);
			mPileEnd = Scene.CreateGameObject("Bench End");
			mPileEnd.AddComponent<BenchEndUpdate>().owner = this;
		}
		mPileWindow.Add(frameMs);
		if (mPileWindow.Count < Workload.PileWindow)
			return;
		let p95 = Percentile(mPileWindow, 0.95);
		mPileWindow.Clear();
		mPileWindows++;
		if (p95 > 16.67 || mBalls.Count >= mCount)
		{
			mPileDone = true;
			mPileReached = mBalls.Count;
			mPileStopP95 = p95;
			mPileStop.Set(p95 > 16.67 ? "p95" : "count");
			Finish();
		}
	}

	List<SoftBody> mSoft = new .() ~ delete _;
	String mSoftKind = new .("jelly") ~ delete _;

	/// CSharpBench's SpawnSoftBodies: count soft bodies of one kind on a floor, each with a Squish script.
	void SpawnSoftBodies()
	{
		ReadSetting("TALLOW_BENCH_SOFT", mSoftKind);
		let half = Workload.SoftHalfSize(mCount);
		AddWall(.(0, -0.5f, 0), .(half * 2 + 4, 1, half * 2 + 4));
		for (int i < mCount)
		{
			let made = Scene.CreateGameObject("Soft");
			made.Transform.LocalPosition = Workload.SoftStart(i, mCount);
			var renderer = made.AddComponent<MeshRenderer>();
			renderer.mesh = Workload.SoftMesh(mSoftKind);
			if (mSoftKind == "shell" || mSoftKind == "driven")
			{
				if (mSoftKind == "shell")
					made.AddComponent<BoxCollider>();
				else
					made.AddComponent<SphereCollider>();
				made.AddComponent<Rigidbody>();
			}
			let soft = made.AddComponent<SoftBody>();
			soft.kind = Workload.SoftKind(mSoftKind);
			made.AddComponent<Squish>();
			mSoft.Add(soft);
		}
	}

	void SpawnWalkers()
	{
		let half = Workload.WalkerHalfSize(mCount);
		AddWall(.(0, -0.5f, 0), .(half * 2, 1, half * 2));
		for (int i < mCount)
		{
			let walker = Scene.CreateGameObject("Walker");
			walker.Transform.LocalPosition = Workload.WalkerStart(i, mCount);
			walker.AddComponent<CharacterController>();
			walker.AddComponent<Walker>().index = i;
			mWalkers.Add(walker);
		}
	}

	void StepLifecycle()
	{
		let start = SDL.SDL_GetTicksNS();
		if (mLifers.IsEmpty)
		{
			for (int i < mCount)
			{
				let made = Scene.CreateGameObject("Lifer");
				made.AddComponent<Lifer>();
				mLifers.Add(made);
			}
			if (mFrame > WarmupFrames)
				mCreateTimes.Add((SDL.SDL_GetTicksNS() - start) / 1e6);
		}
		else
		{
			for (let made in mLifers)
				Scene.Destroy(made);
			mLifers.Clear();
			if (mFrame > WarmupFrames)
				mDestroyTimes.Add((SDL.SDL_GetTicksNS() - start) / 1e6);
		}
	}

	void FinishModes(String line)
	{
		if (mMode == "physics")
		{
			let step = Scene.Physics.LastStepMilliseconds;
			line.AppendF("\"jolt_step_last_ms\": {:F3}, ", step);
		}
		if (mMode == "softbody")
		{
			int bodies = 0, vertices = 0, sleeping = 0;
			for (let soft in mSoft)
			{
				if (soft.HasBody)
					bodies++;
				vertices += soft.SimulatedVertexCount;
				if (soft.IsSleeping)
					sleeping++;
			}
			line.AppendF("\"soft\": \"{}\", \"bodies\": {}, \"vertices\": {}, \"sleeping\": {}, \"low\": {}, \"jolt_step_last_ms\": {:F3}, ", mSoftKind, bodies, vertices, sleeping, Squish.sLow, Scene.Physics.LastStepMilliseconds);
		}
		if (mMode == "pile")
		{
			line.AppendF("\"sleep\": {}, \"reached\": {}, \"stop\": \"{}\", \"stop_p95_ms\": {:F3}, \"windows\": {}, ", mPileSleep ? 1 : 0, mPileReached, mPileStop, mPileStopP95, mPileWindows);
			// Jolt's step over the last window, and the whole run.
			let last = scope List<double>();
			for (int i = Math.Max(0, mStepTimes.Count - Workload.PileWindow); i < mStepTimes.Count; i++)
				last.Add(mStepTimes[i]);
			line.AppendF("\"jolt_step_last_window_ms\": {:F3}, \"jolt_step_max_ms\": {:F3}, ", Average(last), Percentile(mStepTimes, 1.0));
		}
		if (mMode == "physics" || mMode == "pile")
		{
			int sleeping = 0;
			for (let body in mBalls)
				if (body.IsSleeping)
					sleeping++;
			line.AppendF("\"bodies\": {}, \"sleeping\": {}, ", mBalls.Count, sleeping);
		}
		if (mMode == "lifecycle")
		{
			line.AppendF("\"create_avg_ms\": {:F3}, \"destroy_avg_ms\": {:F3}, ", Average(mCreateTimes), Average(mDestroyTimes));
			line.AppendF("\"cycles\": {}, \"awakes\": {}, \"destroys\": {}, ", mDestroyTimes.Count, Lifer.sAwakes, Lifer.sDestroys);
			line.AppendF("\"alive\": {}, \"expected_alive\": {}, ", Lifer.sAlive, mLifers.Count);
			mLifers.Clear();
		}
		if (mMode == "raycast" || mMode == "spherecast")
			line.AppendF("\"hits\": {}, ", mHits);
		if (mMode == "character")
		{
			mChecksum = Walker.sChecksum;
			line.AppendF("\"walkers\": {}, \"checked\": {}, \"grounded\": {}, ", mWalkers.Count, Walker.sChecked, Walker.sGrounded);
		}
		line.AppendF("\"memory_end\": {}, \"checksum\": {}, ", ProfilerModules.ProcessMemory(), mChecksum);
	}
}

/// The physics mode's control path: read the body's velocity and damp it while it moves.
[Component]
class Ball : Script
{
	Rigidbody mBody;

	public override void Start() { mBody = GetComponent<Rigidbody>(); }

	public override void Update(TickInput input, float deltaTime)
	{
		let velocity = mBody.Velocity;
		if (velocity.LengthSquared > Workload.DampAbove * Workload.DampAbove)
			mBody.AddForce(velocity * -Workload.Damping);
	}
}

/// The lifecycle mode's object: counts Awake and OnDestroy calls.
[Component]
class Lifer : Script
{
	public static int sAwakes, sDestroys, sAlive;

	public override void Awake() { sAwakes++; sAlive++; }

	public override void OnDestroy() { sDestroys++; sAlive--; }
}

/// The character mode's walker: one SimpleMove a tick (CSharpBench's Walker).
[Component]
class Walker : Script
{
	public int index;
	CharacterController mController;
	int mTick;

	public override void Start() { mController = GetComponent<CharacterController>(); }

	/// Where every walker stood after exactly CheckTick ticks, to the centimetre (frames hold a varying number of ticks).
	public static int64 sChecksum;
	public static int sGrounded, sChecked;

	public override void Update(TickInput input, float deltaTime)
	{
		mController.SimpleMove(Workload.WalkerVelocity(index, mTick++), deltaTime);
		if (mTick == Workload.WalkerCheckTick)
		{
			let p = Transform.Position;
			sChecksum += (int64)(p.x * 100) + (int64)(p.y * 100) * 7 + (int64)(p.z * 100) * 13;
			sChecked++;
			if (mController.IsGrounded)
				sGrounded++;
		}
	}
}

/// The softbody mode's script (CSharpBench's Squish): reads its body's velocity each tick, and notes one that fell
/// through the floor.
[Component]
class Squish : Script
{
	public static int sLow;
	SoftBody mSoft;
	float mSpeed;

	public override void Start() { mSoft = GetComponent<SoftBody>(); }

	public override void Update(TickInput input, float deltaTime)
	{
		mSpeed = mSoft.Velocity.Length;
		if (Transform.Position.y < -1 && mSpeed >= 0)
		{
			sLow++;
			mSpeed = -1;
		}
	}
}
