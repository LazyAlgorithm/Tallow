using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// Records observable callback order and advances a reproducible script state.
[Component]
class ScriptPathProbe : Script
{
	public int32 index;
	public uint32 randomState;
	public int32 updates;
	public float remaining = 0.1f;
	public int32 timerEvents;
	uint32 mRandom = 12345;
	int32 mPrivateTicks;
	public uint32 PrivateRandom => mRandom;
	public int32 PrivateTicks => mPrivateTicks;
	public String label;
	List<int> mValues;

	public this()
	{
		label = CreateString("owned by the script");
		mValues = CreateList<int>();
		mValues.Add(42);
	}

	public static uint64 Order;

	void Note(uint32 callback)
	{
		Order = (Order ^ ((uint32)index * 16 + callback)) * 1099511628211UL;
	}

	public override void Awake() => Note(1);
	public override void OnEnable() => Note(2);
	public override void Start() => Note(3);
	public override void FixedUpdate() => Note(4);
	public override void LateUpdate() => Note(6);
	public override void OnDisable() => Note(7);
	public override void OnDestroy() => Note(8);

	public override void Update(TickInput input, float deltaTime)
	{
		Note(5);
		mPrivateTicks++;
		mRandom ^= mRandom << 13;
		mRandom ^= mRandom >> 17;
		mRandom ^= mRandom << 5;
		randomState ^= randomState << 13;
		randomState ^= randomState >> 17;
		randomState ^= randomState << 5;
		updates++;
		if (ScriptTimer.Advance(ref remaining, deltaTime))
		{
			timerEvents++;
			ScriptTimer.Start(ref remaining, 0.1f);
		}
		Runtime.Assert(mValues[0] == 42 && label == "owned by the script");
		Transform.LocalPosition += Vector3((randomState & 255) / 255.0f, index * 0.01f, -0.5f) * deltaTime;
		Transform.LocalRotation = (Transform.LocalRotation * Quaternion.Euler(.(0, deltaTime * 5, 0))).Normalized;
	}
}

/// Fixed-input state and event checks for the normal script path, independent of render frame rate.
static class ScriptPathChecks
{
	static uint64 HashBytes(uint64 hash, void* data, int count)
	{
		var hash;
		for (int i < count)
			hash = (hash ^ ((uint8*)data)[i]) * 1099511628211UL;
		return hash;
	}

	static void Trace(bool reload, List<uint64> hashes)
	{
		let scene = scope Scene();
		let objects = scope List<GameObject>();
		let parent = scene.CreateGameObject("Parent");
		for (int32 i < 32)
		{
			let obj = scene.CreateGameObject("Probe");
			let probe = obj.AddComponent<ScriptPathProbe>();
			probe.index = i;
			probe.randomState = (uint32)i * 2654435761U + 12345;
			objects.Add(obj);
		}
		ScriptPathProbe.Order = 14695981039346656037UL;
		scene.StartPlay();
		for (int tick < 240)
		{
			// Add/remove data changes Flecs tables without changing script registration order.
			let moved = objects[tick % objects.Count];
			scene.World.Add<Marked>(moved.Entity);
			scene.World.Remove<Marked>(moved.Entity);
			if (tick % 30 == 5)
				objects[3].SetActive(false);
			if (tick % 30 == 8)
				objects[3].SetActive(true);
			if (tick % 30 == 10)
				objects[5].GetComponent<ScriptPathProbe>().Enabled = false;
			if (tick % 30 == 13)
				objects[5].GetComponent<ScriptPathProbe>().Enabled = true;
			if (tick % 40 == 20)
				objects[7].Transform.SetParent(parent.Transform);
			if (tick % 40 == 30)
				objects[7].Transform.SetParent(null);
			if (reload && tick == 103)
			{
				// The production reload migration: replace the instances, retain their fields and callback slots.
				let migration = scope ScriptStateMigration();
				let types = scope List<ScriptReload.TypeUpdate>();
				types.Add(.() { original = typeof(ScriptPathProbe), replacement = typeof(ScriptPathProbe), script = true });
				migration.Capture(scene, types);
				migration.Restore(scene);
			}
			parent.Transform.Position = .(tick * 0.01f, 0, 0);
			scene.FixedUpdate();
			scene.Update();
			var hash = ScriptPathProbe.Order;
			for (let obj in objects)
			{
				let script = obj.GetComponent<ScriptPathProbe>();
				var position = obj.Transform.Position;
				var rotation = obj.Transform.Rotation;
				hash = HashBytes(hash, &position, sizeof(Vector3));
				hash = HashBytes(hash, &rotation, sizeof(Quaternion));
				hash = HashBytes(hash, &script.randomState, sizeof(uint32));
				hash = HashBytes(hash, &script.updates, sizeof(int32));
				hash = HashBytes(hash, &script.remaining, sizeof(float));
				hash = HashBytes(hash, &script.timerEvents, sizeof(int32));
			}
			hashes.Add(hash);
		}
		scene.StopPlay();
		scene.Clear();
		hashes.Add(ScriptPathProbe.Order);
	}

	static bool ParallelMatches()
	{
		let serial = scope World();
		let parallel = scope World();
		let left = scope List<Entity>();
		let right = scope List<Entity>();
		serial.CreateMany<Pose>(2048, left);
		parallel.CreateMany<Pose>(2048, right);
		for (int i < left.Count)
		{
			Workload.Start(i, 10, let position, let velocity, let spin);
			serial.Set<Pose>(left[i], .() { position = position, rotation = .Identity });
			parallel.Set<Pose>(right[i], .() { position = position, rotation = .Identity });
			serial.Set<Motion>(left[i], .() { velocity = velocity, spin = spin });
			parallel.Set<Motion>(right[i], .() { velocity = velocity, spin = spin });
			serial.Add<RenderMatrix>(left[i]);
			parallel.Add<RenderMatrix>(right[i]);
		}
		let a = scope Query<Pose, Motion, RenderMatrix>(serial);
		let b = scope Query<Pose, Motion, RenderMatrix>(parallel);
		for (int tick < 120)
		{
			// Make the table order differ: state is compared by the stable fixture index below.
			parallel.Add<Marked>(right[tick]);
			for (var chunk in a)
				MoveSystem.Run(chunk, 10, 1.0f / 60);
			b.ParallelFor(scope (chunk) => MoveSystem.Run(chunk, 10, 1.0f / 60));
			for (int i < left.Count)
			{
				if (Internal.MemCmp(serial.Get<Pose>(left[i]), parallel.Get<Pose>(right[i]), sizeof(Pose)) != 0 ||
					Internal.MemCmp(serial.Get<Motion>(left[i]), parallel.Get<Motion>(right[i]), sizeof(Motion)) != 0 ||
					Internal.MemCmp(serial.Get<RenderMatrix>(left[i]), parallel.Get<RenderMatrix>(right[i]), sizeof(RenderMatrix)) != 0)
					return false;
			}
		}
		return true;
	}

	static bool ReferenceWrapChecks()
	{
		let world = scope World();
		let first = world.Create();
		world.Set<TransformData>(first, .Default);
		var reference = ComponentRef<TransformData>(world, first);
		for (int i < 65536)
			world.Set<TransformData>(world.Create(), .Default);
		if (reference.Get(world) != world.Get<TransformData>(first)) return false;
		world.Remove<TransformData>(first);
		if (reference.Get(world) != null) return false;
		world.Set<TransformData>(first, .Default);
		if (reference.Get(world) != world.Get<TransformData>(first)) return false;
		world.Delete(first);
		return reference.Get(world) == null;
	}

	static bool PrivateReplayChecks()
	{
		let scene = scope Scene();
		let obj = scene.CreateGameObject("Predicted");
		let identity = obj.AddComponent<NetworkIdentity>();
		identity.ownerId = 0;
		let script = obj.AddComponent<ScriptPathProbe>();
		let net = scope NetworkManager(scene);
		net.Identities.Add(identity);
		let state = scope List<uint8>();
		if (!net.[Friend]ScriptFields(state, false)) return false;
		for (int i < 20)
			script.Update(default, Time.FixedDeltaTime);
		let random = script.PrivateRandom;
		let events = script.timerEvents;
		let cut = scope List<uint8>(state.GetEnumerator());
		cut.RemoveAt(cut.Count - 1);
		if (net.[Friend]ScriptFields(cut, true) || script.PrivateTicks != 20 || script.PrivateRandom != random || script.updates != 20) return false;
		let wrongSchema = scope List<uint8>(state.GetEnumerator());
		wrongSchema[0] ^= 1;
		if (net.[Friend]ScriptFields(wrongSchema, true) || script.updates != 20) return false;
		// Equal-length histories from another script instance must not be treated as this one's state.
		let other = obj.AddComponent<ScriptPathProbe>();
		if (net.[Friend]ScriptFields(state, true) || script.updates != 20) return false;
		obj.RemoveComponent(other);
		if (!net.[Friend]ScriptFields(state, true) || script.PrivateTicks != 0 || script.PrivateRandom != 12345) return false;
		for (int i < 20)
			script.Update(default, Time.FixedDeltaTime);
		if (script.PrivateRandom != random || script.PrivateTicks != 20 || script.timerEvents != events) return false;
		let migration = scope ScriptStateMigration();
		let types = scope List<ScriptReload.TypeUpdate>();
		types.Add(.() { original = typeof(ScriptPathProbe), replacement = typeof(ScriptPathProbe), script = true });
		migration.Capture(scene, types);
		migration.Restore(scene);
		let replacement = obj.GetComponent<ScriptPathProbe>();
		return !net.[Friend]ScriptFields(state, true) && replacement.PrivateTicks == 20 && replacement.PrivateRandom == random;
	}

	static bool TimerChecks()
	{
		float remaining = -1;
		if (ScriptTimer.Advance(ref remaining, 1)) return false;
		ScriptTimer.Start(ref remaining, 0.25f);
		if (ScriptTimer.Advance(ref remaining, -1) || remaining != 0.25f) return false;
		if (ScriptTimer.Advance(ref remaining, float.NaN) || remaining != 0.25f) return false;
		let snapshot = remaining;
		int first = -1;
		for (int tick < 32)
		{
			if (ScriptTimer.Advance(ref remaining, 1.0f / 60))
			{
				if (first >= 0) return false;
				first = tick;
			}
		}
		remaining = snapshot;
		int replay = -1;
		for (int tick < 32)
		{
			if (ScriptTimer.Advance(ref remaining, 1.0f / 60))
				replay = tick;
		}
		if (first < 0 || first != replay) return false;
		ScriptTimer.Start(ref remaining, 0);
		if (!ScriptTimer.Advance(ref remaining, 0) || ScriptTimer.Advance(ref remaining, 0)) return false;
		ScriptTimer.Start(ref remaining, 1);
		ScriptTimer.Stop(ref remaining);
		return !ScriptTimer.Advance(ref remaining, 2);
	}

	public static int Run()
	{
		let active = Scene.Active;
		let delta = Time.DeltaTime;
		let tick = Time.Tick;
		defer
		{
			Scene.Active = active;
			Time.DeltaTime = delta;
			Time.Tick = tick;
		}
		Time.DeltaTime = Time.FixedDeltaTime;
		let baseline = scope List<uint64>();
		let migrated = scope List<uint64>();
		Trace(false, baseline);
		Trace(true, migrated);
		bool same = baseline.Count == migrated.Count;
		for (int i < Math.Min(baseline.Count, migrated.Count))
			same &= baseline[i] == migrated[i];
		let parallel = ParallelMatches();
		let timers = TimerChecks();
		let references = ReferenceWrapChecks();
		let privateReplay = PrivateReplayChecks();
		Console.WriteLine(scope $"{(same ? "PASS" : "FAILED")}: 240 fixed-input ticks and lifecycle order match across instance migration, enabled state, hierarchy and table changes ({HashBytes(14695981039346656037UL, baseline.Ptr, baseline.Count * sizeof(uint64))})");
		Console.WriteLine(parallel ? "PASS: serial and worker schedules match every tick despite different Flecs table order" : "FAILED: serial and worker schedules diverged");
		Console.WriteLine(timers ? "PASS: timer completion replays at the same tick, completes once and rejects invalid deltas" : "FAILED: timer replay or lifecycle");
		Console.WriteLine(references ? "PASS: component reference follows 65536 table changes, removal, re-add and deletion" : "FAILED: component reference became stale after version wrap");
		Console.WriteLine(privateReplay ? "PASS: exact snapshots restore private RNG/timers and reject truncated, changed or reloaded layouts atomically" : "FAILED: private script snapshot replay");
		return (same ? 0 : 1) + (parallel ? 0 : 1) + (timers ? 0 : 1) + (references ? 0 : 1) + (privateReplay ? 0 : 1);
	}
}
