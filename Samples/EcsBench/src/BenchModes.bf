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
			mBalls.Add(ball.AddComponent<Rigidbody>());
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
