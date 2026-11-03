using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// Test switch --separate-worlds-test: with Project Settings' "Each object in its own world states" on and two states
/// (Containment, Echo), plays a scene where a floor is in both, one wall only in each, two characters in one state
/// each, A-only water and an A-only voxel wall, and checks: rays and shape queries see only the states asked for,
/// each character is stopped by its own state's wall and walks through the other's, characters of different states
/// do not meet, a character moved to the other state is found there at once, water floats only bodies of its state,
/// pieces carved off an A-only wall stay A-only, and the setting saves. Logs SEPARATE-WORLDS-TEST PASS or FAIL.
extension EditorApp
{
	void RunSeparateWorldsTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		let stash = SceneSerializer.Save(mScene, .. scope .());
		let stashPath = scope String(mScene.Path);
		let configStash = ProjectConfig.Write(.. scope .());

		ProjectConfig.Parse("worldstate \"Containment\"\nworldstate \"Echo\"\nseparateworldstates 1\n");
		let saved = ProjectConfig.Write(.. scope .());
		Expect(saved.Contains("separateworldstates 1") && ProjectConfig.SeparatedWorldStateCount == 2, "the setting is written and read");
		let A = (uint32)1;
		let B = (uint32)2;

		SceneSerializer.Load(mScene, "scene \"Worlds\"\n");
		let floor = mScene.CreateGameObject("Floor");
		floor.Transform.Position = .(0, -0.5f, 0);
		floor.AddComponent<BoxCollider>().size = .(60, 1, 60);
		GameObject Wall(StringView name, float x, uint32 worlds)
		{
			let wall = mScene.CreateGameObject(name);
			wall.Transform.Position = .(x, 1.5f, 0);
			wall.AddComponent<BoxCollider>().size = .(0.5f, 3, 8);
			wall.WorldStates = worlds;
			return wall;
		}
		let wallA = Wall("Wall A", 3, A);
		let wallB = Wall("Wall B", 6, B);
		GameObject Walker(StringView name, float z, uint32 worlds)
		{
			let walker = mScene.CreateGameObject(name);
			walker.Transform.Position = .(0, 0.1f, z);
			walker.AddComponent<CharacterController>();
			walker.WorldStates = worlds;
			return walker;
		}
		let walkerA = Walker("Walker A", -1, A);
		let walkerB = Walker("Walker B", 1, B);

		// A-only water off to the side, with one crate in each state dropped into it.
		let pool = mScene.CreateGameObject("Pool");
		pool.Transform.Position = .(-15, 2, 0);
		let water = pool.AddComponent<Water>();
		water.size = .(8, 8);
		water.depth = 2.5f;
		water.waveHeight = 0;
		pool.WorldStates = A;
		GameObject Crate(StringView name, float z, uint32 worlds)
		{
			let crate = mScene.CreateGameObject(name);
			crate.Transform.Position = .(-15, 3, z);
			crate.AddComponent<BoxCollider>().size = .(0.6f, 0.6f, 0.6f);
			crate.AddComponent<Rigidbody>().mass = 20;
			crate.WorldStates = worlds;
			return crate;
		}
		let crateA = Crate("Crate A", -1.5f, A);
		let crateB = Crate("Crate B", 1.5f, B);

		// An A-only voxel block, far from everything, on its own pad.
		let block = mScene.CreateGameObject("Block");
		block.Transform.Position = .(20, 2, 20);
		block.WorldStates = A;
		block.Layer = 0;
		let voxels = block.AddComponent<VoxelObject>();
		voxels.shape = .Box;
		voxels.size = 4;
		voxels.resolution = 12;
		voxels.anchored = true;
		voxels.debrisPieces = true;
		block.AddComponent<MeshCollider>();

		mScene.StartPlay();
		void Run(int frames)
		{
			// A frame of play as the editor runs it, at 60 a second: one physics tick, then the frame.
			for (int i < frames)
			{
				Time.DeltaTime = Time.UnscaledDeltaTime = 1 / 60.0f;
				Time.Advance(Time.DeltaTime);
				Time.FrameCount++;
				mScene.FixedUpdate();
				mScene.Update();
			}
		}
		Run(3);
		let physics = mScene.Physics;
		Expect(physics.SeparatesWorldStates, "play separates the world states");

		// Rays from x = 0 along +X: A sees wall A, B sees wall B, all states the nearer one.
		RaycastHit hit;
		bool Ray(uint32 worlds, out RaycastHit result)
		{
			physics.QueryWorldStates = worlds;
			defer
			{
				physics.QueryWorldStates = uint32.MaxValue;
			}
			return physics.Raycast(.(0, 1.5f, -4), .(1, 0, 0), 20, out result);
		}
		Expect(Ray(A, out hit) && hit.gameObject == wallA, "a ray in A finds A's wall");
		Expect(Ray(B, out hit) && hit.gameObject == wallB, "a ray in B passes A's wall and finds B's");
		Expect(Ray(uint32.MaxValue, out hit) && hit.gameObject == wallA, "a ray in every state finds the nearest");
		physics.QueryWorldStates = B;
		Expect(!physics.CheckBox(.(3, 1.5f, 0), .(0.2f, 0.2f, 0.2f), .Identity), "a shape query in B does not touch A's wall");
		physics.QueryWorldStates = A;
		Expect(physics.CheckBox(.(3, 1.5f, 0), .(0.2f, 0.2f, 0.2f), .Identity), "a shape query in A touches it");
		physics.QueryWorldStates = uint32.MaxValue;
		Expect(physics.CheckBox(.(0, -0.5f, 0), .(1, 0.2f, 1), .Identity), "the floor in both states is found");

		// Rays across at the characters' height: each state sees only its own character.
		bool RayAt(uint32 worlds, float z, out RaycastHit result)
		{
			physics.QueryWorldStates = worlds;
			defer
			{
				physics.QueryWorldStates = uint32.MaxValue;
			}
			ShapeCastHit shapeHit;
			let found = physics.SphereCast(.(-6, 1, z), 0.05f, .(1, 0, 0), 5.8f, out shapeHit);
			result = default;
			result.gameObject = shapeHit.gameObject;
			return found;
		}
		Expect(RayAt(A, -1, out hit) && hit.gameObject == walkerA, "A sees its character");
		Expect(!RayAt(B, -1, out hit), "B does not see A's character");

		// Both walk along +X for two seconds: A stops at its wall, B walks through it and stops at its own.
		let controllerA = walkerA.GetComponent<CharacterController>();
		let controllerB = walkerB.GetComponent<CharacterController>();
		for (int i < 120)
		{
			controllerA.SimpleMove(.(4, 0, 0), 1 / 60.0f);
			controllerB.SimpleMove(.(4, 0, 0), 1 / 60.0f);
			Run(1);
		}
		let xA = walkerA.Transform.Position.x, xB = walkerB.Transform.Position.x;
		Expect(xA < 3 && xA > 2, scope $"A's character stops at A's wall (x {xA:F2})");
		Expect(xB > 3.2f && xB < 6, scope $"B's character walks through A's wall and stops at B's (x {xB:F2})");
		Expect(walkerA.Transform.Position.y > -0.1f && walkerB.Transform.Position.y > -0.1f, "both stand on the shared floor");

		// The two at the same place in different states do not push each other.
		walkerB.GetComponent<CharacterController>().Teleport(walkerA.Transform.Position);
		let before = walkerA.Transform.Position;
		for (int i < 30)
		{
			controllerA.SimpleMove(.Zero, 1 / 60.0f);
			controllerB.SimpleMove(.Zero, 1 / 60.0f);
			Run(1);
		}
		Expect(Vector3.Distance(walkerA.Transform.Position, before) < 0.05f && Vector3.Distance(walkerB.Transform.Position, before) < 0.05f, "characters in different states share a place");

		// B's character shifts to A: from then on only A finds it.
		bool RayThrough(uint32 worlds, out RaycastHit result)
		{
			physics.QueryWorldStates = worlds;
			defer
			{
				physics.QueryWorldStates = uint32.MaxValue;
			}
			let at = walkerB.Transform.Position;
			ShapeCastHit shapeHit;
			let found = physics.SphereCast(at + .(0, 0, -5), 0.05f, .(0, 0, 1), 10, out shapeHit);
			result = default;
			result.gameObject = shapeHit.gameObject;
			return found;
		}
		let foundB = RayThrough(B, out hit);
		Expect(foundB && hit.gameObject == walkerB, scope $"before the shift B finds B's character ({foundB} {(foundB ? hit.gameObject.Name : "")} at {walkerB.Transform.Position})");
		walkerB.WorldStates = A;
		Run(1);
		Expect(!RayThrough(B, out hit), "after the shift B no longer finds it");
		Expect(RayThrough(A, out hit) && (hit.gameObject == walkerB || hit.gameObject == walkerA), "A finds it at once");

		// The water floats A's crate; B's falls through to the floor.
		Run(240);
		let yA = crateA.Transform.Position.y, yB = crateB.Transform.Position.y;
		Expect(yA > 1.2f && yA < 2.6f, scope $"A's crate floats in A's water (y {yA:F2})");
		Expect(yB < 0.5f, scope $"B's crate falls through A's water to the floor (y {yB:F2})");

		// Cut the block through the middle: the top falls off, and is A-only debris.
		for (int x = -5; x <= 5; x++)
		{
			for (int z = -5; z <= 5; z++)
				voxels.Carve(block.Transform.Position + .(x * 0.4f, 0, z * 0.4f), 0.45f);
		}
		Run(5);
		int pieces = 0, pieceInA = 0;
		for (let object in mScene.Objects)
		{
			if (object.Name != "Fragment")
				continue;
			pieces++;
			if (object.EffectiveWorldStates == A && object.GetComponent<Rigidbody>()?.debris == true)
				pieceInA++;
		}
		Expect(pieces > 0 && pieceInA == pieces, scope $"carved pieces are A-only debris ({pieceInA}/{pieces})");
		mScene.StopPlay();

		// Put everything back.
		ProjectConfig.Parse(configStash);
		SceneSerializer.Load(mScene, stash);
		mScene.Path.Set(stashPath);
		Log.Info(scope $"SEPARATE-WORLDS-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}
}
