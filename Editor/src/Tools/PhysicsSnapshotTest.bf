using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// A backend that provides only the required body primitives, with no snapshot or networking code of its own, must
/// still save, restore, serialize and send shared state: PhysicsBackendWorld's default snapshots do that for every
/// backend. Run with: TallowLauncher --test-physics-snapshots
class GenericSnapshotPhysicsBackend : PhysicsBackend
{
	public static PhysicsFeatures GenericFeatures => .(JoltPhysicsBackend.AllFeatures.bits &
		~((uint64)PhysicsFeature.SaveRestoreExact | (uint64)PhysicsFeature.SharedPhysicsState |
		(uint64)PhysicsFeature.CrossPlatformDeterminism));

	public override StringView Id => "GenericSnapshot";
	public override StringView DisplayName => "Generic snapshot test";
	public override ModuleKind Kind => .Physics3D;
	public override int32 IntegrationVersion => 1;
	public override StringView LibraryVersion => "vendored Jolt";
	public override bool Available => true;
	public override PhysicsDimension Dimension => .Three;
	public override PhysicsFeatures Features => GenericFeatures;

	public override PhysicsBackendWorld CreateWorld(PhysicsWorldSettings settings) => new GenericSnapshotWorld(settings, Features);
}

/// A Jolt world that deliberately uses the base class's generic snapshots (the ones a new backend gets for free)
/// instead of Jolt's exact native state.
class GenericSnapshotWorld : JoltPhysicsBackendWorld
{
	public this(PhysicsWorldSettings settings, PhysicsFeatures features) : base(settings, features) { }

	public override void* SaveState(void* reuse) => base.SaveState(reuse);
	public override bool RestoreState(void* state) => base.RestoreState(state);
	public override int StateSize(void* state) => base.StateSize(state);
	public override void FreeState(void* state) => base.FreeState(state);
	public override void* StateFromBytes(Span<uint8> data) => base.StateFromBytes(data);
	public override void StateToBytes(void* state, List<uint8> into) => base.StateToBytes(state, into);
	public override void SaveShared(uint32 firstIndex, List<uint8> into) => base.SaveShared(firstIndex, into);
}

/// --test-physics-snapshots: the generic snapshot path a new backend is networked by, and the lockstep capability
/// gate that keeps an inexact backend out of lockstep.
static class PhysicsSnapshotTest
{
	public static int Run()
	{
		int failures = 0;
		PhysicsBackends.Register(new GenericSnapshotPhysicsBackend());
		PhysicsBackends.Override3D("GenericSnapshot");
		let scene = scope Scene();
		failures += Check("generic backend selected", scene.Physics.BackendProvider is GenericSnapshotPhysicsBackend);
		failures += Check("it does not advertise exact snapshots", !scene.Physics.Supports(.SaveRestoreExact));
		failures += Check("it cannot run lockstep", !scene.Physics.CanLockstep);

		// Ground 8000, box 9000: fixed ids so the halves for shared state are known.
		scene.Physics.FixedBodyIndex = new (transform) =>
			{
				return transform.GameObject.Name == "Box" ? 9000 : 8000;
			};
		let ground = scene.CreateGameObject("Ground");
		let groundCollider = ground.AddComponent<BoxCollider>();
		groundCollider.size = Vector3(10, 1, 10);
		scene.Physics.CreateBody(ground.Transform, groundCollider.GetShape(), null);
		let falling = scene.CreateGameObject("Box");
		falling.Transform.Position = Vector3(0, 5, 0);
		let boxCollider = falling.AddComponent<BoxCollider>();
		boxCollider.size = Vector3.One;
		RigidbodyData data = .();
		data.mass = 1;
		let fallingBody = scene.Physics.CreateBody(falling.Transform, boxCollider.GetShape(), &data);
		failures += Check("box got its fixed id", fallingBody == 9000);

		for (int i < 10)
			scene.Physics.Step(1.0f / 60.0f);
		let saved = scene.Physics.SaveExact(null);
		let savedY = falling.Transform.Position.y;
		for (int i < 20)
			scene.Physics.Step(1.0f / 60.0f);
		let movedY = falling.Transform.Position.y;
		failures += Check("box moved between save and restore", Math.Abs(movedY - savedY) > 0.01f);
		let restored = scene.Physics.RestoreExact(saved);
		failures += Check("the default snapshot restores the pose", restored && Math.Abs(falling.Transform.Position.y - savedY) < 0.01f);
		scene.Physics.FreeExact(saved);

		// The same snapshot as bytes, as the network sends a joining client.
		List<uint8> bytes = scope .();
		scene.Physics.SaveShared((uint32)scene.Physics.BodyCapacity / 2, bytes);
		failures += Check("shared state is written", bytes.Count > 12);
		let atSave = falling.Transform.Position.y;
		for (int i < 20)
			scene.Physics.Step(1.0f / 60.0f);
		failures += Check("shared restore starts from a changed pose", Math.Abs(falling.Transform.Position.y - atSave) > 0.01f);
		failures += Check("shared state goes back", scene.Physics.RestoreShared(bytes) && Math.Abs(falling.Transform.Position.y - atSave) < 0.01f);

		// A damaged snapshot is refused, not trusted.
		bytes[0] ^= 1;
		failures += Check("a damaged snapshot is refused", !scene.Physics.RestoreShared(bytes));

		Console.WriteLine(failures == 0 ? "PHYSICS SNAPSHOT PASS" : scope $"PHYSICS SNAPSHOT FAIL ({failures})");
		PhysicsBackends.Override3D("");
		return failures == 0 ? 0 : 1;
	}

	static int Check(StringView what, bool ok)
	{
		let line = scope String();
		line.AppendF("[{}] {}", ok ? "PASS" : "FAIL", what);
		Console.WriteLine(line);
		return ok ? 0 : 1;
	}
}
