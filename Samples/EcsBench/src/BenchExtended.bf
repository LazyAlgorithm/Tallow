using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// Additional isolated workloads. A mode's name describes exactly what is present:
/// physics-* includes no renderer; ai-tree has no pathfinding; net-offline sends no packets.
/// Every scenario is a fresh process so Jolt, Flecs and resource caches do not leak between cases.
extension Bench
{
	List<Rigidbody> mPhysicsBodies = new .() ~ delete _;
	int mPhysicsErrorBits;

	bool IsExtendedMode()
	{
		return mMode == "script-empty" || mMode == "render-static" ||
			mMode == "prefab" || mMode == "ai-tree" || mMode == "net-offline" ||
			mMode == "physics-active" || mMode == "physics-sleep" ||
			mMode == "physics-kinematic" || mMode == "physics-static";
	}

	void SpawnExtended()
	{
		if (mMode.StartsWith("physics-"))
		{
			SpawnPhysics();
			return;
		}
		for (int i < mCount)
		{
			Workload.Start(i, mHalfSize, let position, let velocity, let spin);
			GameObject obj;
			if (mMode == "prefab")
				obj = Prefab.Instantiate(Scene, "Prefabs/MovingCube.tprefab", position, .Identity);
			else
			{
				obj = Scene.CreateGameObject("Probe");
				obj.Transform.LocalPosition = position;
			}
			Runtime.Assert(obj != null, "Benchmark prefab could not be instantiated");
			mSpawned.Add(obj);
			if (mMode == "render-static")
			{
				obj.Transform.LocalScale = .(Workload.CubeScale, Workload.CubeScale, Workload.CubeScale);
				obj.AddComponent<MeshRenderer>();
			}
			else if (mMode == "script-empty")
				obj.AddComponent<EmptyUpdate>();
			else if (mMode == "ai-tree")
			{
				let tree = obj.AddComponent<BehaviorTreeRunner>();
				tree.tree.Set("BehaviorTrees/Think.tbt");
				tree.tickInterval = 0;
				mTrees++;
			}
			else if (mMode == "net-offline")
			{
				let identity = obj.AddComponent<NetworkIdentity>();
				identity.playerControlled = false;
				mNetworked++;
			}
			else if (mMode == "prefab")
			{
				let mover = obj.GetComponent<Mover>();
				Runtime.Assert(mover != null, "Benchmark prefab has no Mover");
				mover.velocity = velocity;
				mover.spin = spin;
				mover.halfSize = mHalfSize;
			}
		}
	}

	void SpawnPhysics()
	{
		// Increase the default 16,384-body Jolt limit before its first body is created.
		// Keep pair/contact capacities generous enough for a collapsing box pile.
		let bodies = Math.Max(16384, mCount + 256);
		Scene.Physics.ConfigureCapacity((int32)bodies, (int32)Math.Max(65536, mCount * 16), (int32)Math.Max(16384, mCount * 8));
		int side = 1;
		while (side * side * side < mCount)
			side++;
		float width = side * 1.2f + 4;
		let floor = Scene.CreateGameObject("Floor");
		mSpawned.Add(floor);
		floor.Transform.LocalPosition = .(0, -1, 0);
		let floorCollider = floor.AddComponent<BoxCollider>();
		floorCollider.size = .(width, 2, width);

		for (int i < mCount)
		{
			let bodyObject = Scene.CreateGameObject("Body");
			mSpawned.Add(bodyObject);
			let x = i % side;
			let y = i / (side * side);
			let z = (i / side) % side;
			bodyObject.Transform.LocalPosition = .((x - (side - 1) * 0.5f) * 1.04f,
				1.0f + y * 1.04f, (z - (side - 1) * 0.5f) * 1.04f);
			bodyObject.AddComponent<BoxCollider>();
			if (mMode == "physics-static")
				continue;
			let body = bodyObject.AddComponent<Rigidbody>();
			body.isKinematic = mMode == "physics-kinematic";
			body.useGravity = mMode != "physics-kinematic";
			body.allowSleeping = mMode == "physics-sleep";
			mPhysicsBodies.Add(body);
			mBodies++;
		}
	}

	int CountCreatedBodies()
	{
		int created = 0;
		for (let body in mPhysicsBodies)
		{
			if (body.HasBody)
				created++;
		}
		return created;
	}

	int CountSleepingBodies()
	{
		int sleeping = 0;
		for (let body in mPhysicsBodies)
		{
			if (body.IsSleeping)
				sleeping++;
		}
		return sleeping;
	}
}
