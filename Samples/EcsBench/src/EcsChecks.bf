using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace EcsBench;

[Component]
struct Marked
{
}

/// Counts the Update calls it gets, for EcsChecks.UpdateChecks.
[Component]
class UpdateCounter : Component
{
	public int frames;
	public int ticks;
	public bool sawControls;

	public override void Update(TickInput input, float deltaTime)
	{
		if (deltaTime == Time.FixedDeltaTime && GameObject.GetComponent<NetworkIdentity>() != null)
			ticks++;
		else
			frames++;
		if (input.raw.moveX != 0 || input.raw.moveZ != 0 || input.raw.buttons != 0)
			sawControls = true;
	}
}

/// Checks of the ECS layer (World, Query, ParallelFor, deferred changes), run with TALLOW_BENCH_MODE=check.
static class EcsChecks
{
	static int sFailures;

	static void Expect(bool condition, StringView what)
	{
		if (!condition)
		{
			sFailures++;
			Console.WriteLine($"  FAILED: {what}");
		}
	}

	public static int Run()
	{
		sFailures = 0;
		let world = scope World();
		let entities = scope List<Entity>();
		world.CreateMany<Pose>(1000, entities);
		Expect(entities.Count == 1000 && world.Count<Pose>() == 1000, "CreateMany makes 1000 entities");
		for (let entity in entities)
			world.Set<Motion>(entity, .() { velocity = .(1, 0, 0) });
		Expect(world.Get<Motion>(entities[5]).velocity.x == 1, "Set then Get");
		Expect(world.Get<RenderMatrix>(entities[5]) == null, "Get of a missing component is null");

		// Changes made while iterating wait for DeferEnd.
		let query = scope Query<Pose, Motion>(world);
		world.DeferBegin();
		int seen = 0;
		for (var chunk in query)
		{
			for (let entity in chunk.Entities)
				world.Add<Marked>(entity);
			seen += chunk.Count;
		}
		Expect(seen == 1000, "query visits every entity");
		Expect(world.Count<Marked>() == 0, "deferred adds are not applied before DeferEnd");
		world.DeferEnd();
		Expect(world.Count<Marked>() == 1000, "deferred adds are applied at DeferEnd");
		Expect(world.Get<Motion>(entities[5]).velocity.x == 1, "data survives moving to a new table");

		// Every row is visited exactly once over all threads.
		int32 total = 0;
		query.ParallelFor(scope [&] (chunk) =>
			{
				let poses = chunk.Write<Pose>();
				let motions = chunk.Read<Motion>();
				for (int i < chunk.Count)
					poses[i].position.x += motions[i].velocity.x;
				Interlocked.Add(ref total, (int32)chunk.Count);
			});
		Expect(total == 1000, "ParallelFor covers every entity once");
		Expect(world.Get<Pose>(entities[999]).position.x == 1, "ParallelFor writes land");

		// Leaving a loop early and deleting.
		for (var chunk in query)
			break;
		world.Delete(entities[0]);
		Expect(!world.IsAlive(entities[0]) && world.Count<Pose>() == 999, "Delete");
		SceneChecks();
		UpdateChecks();
		return sFailures;
	}

	/// GameObjects and their entities stay in step (docs/ecs-plan.md, Phase 2).
	static void SceneChecks()
	{
		let scene = scope Scene();
		let world = scene.World;
		let parent = scene.CreateGameObject("Parent");
		let child = scene.CreateGameObject("Child", parent.Transform);
		Expect(world.IsAlive(parent.Entity) && world.IsAlive(child.Entity), "each GameObject has a live entity");
		Expect(world.Get<ObjectLink>(child.Entity).gameObject == child, "ObjectLink points back at the GameObject");
		Expect(world.Parent(child.Entity) == parent.Entity, "ChildOf follows the hierarchy");
		child.Transform.SetParent(null);
		Expect(world.Parent(child.Entity).IsNull, "SetParent(null) clears ChildOf");
		child.Transform.SetParent(parent.Transform);
		child.SetActive(false);
		Expect(world.Has<InactiveSelf>(child.Entity), "SetActive(false) tags the entity");
		child.SetActive(true);
		Expect(!world.Has<InactiveSelf>(child.Entity), "SetActive(true) clears the tag");
		// Transform data lives in the entity and follows it as it moves between tables.
		parent.Transform.LocalPosition = .(1, 2, 3);
		child.Transform.LocalPosition = .(0, 1, 0);
		Expect(world.Get<TransformData>(child.Entity).localPosition.y == 1, "Transform writes land in TransformData");
		child.SetActive(false);
		child.Transform.LocalPosition = .(0, 5, 0);
		Expect(child.Transform.Position == Vector3(1, 7, 3), "world position after the entity changed tables");
		child.SetActive(true);
		world.Get<TransformData>(parent.Entity).localPosition = .(0, 0, 0);
		parent.Transform.PoseChanged();
		Expect(child.Transform.Position == Vector3(0, 5, 0), "writes through the world are seen by Transform");
		let childEntity = child.Entity;
		let parentEntity = parent.Entity;
		scene.DestroyImmediate(parent);
		Expect(!world.IsAlive(parentEntity) && !world.IsAlive(childEntity), "destroying objects deletes their entities");
		Expect(world.Count<ObjectLink>() == 0, "no entities left behind");
	}

	/// Update runs per frame on plain objects and per tick on networked ones; an object no player controls gets
	/// empty controls (Component.Update).
	static void UpdateChecks()
	{
		let previous = Scene.Active;
		let scene = scope Scene();
		let plain = scene.CreateGameObject("Plain").AddComponent<UpdateCounter>();
		let networkedObject = scene.CreateGameObject("Networked");
		let identity = networkedObject.AddComponent<NetworkIdentity>();
		identity.playerControlled = false;
		let networked = networkedObject.AddComponent<UpdateCounter>();
		scene.StartPlay();
		for (int i < 3)
			scene.Update();
		for (int i < 2)
			scene.FixedUpdate();
		Expect(plain.frames == 3 && plain.ticks == 0, scope $"plain object: Update once a frame (frames {plain.frames}, ticks {plain.ticks})");
		Expect(networked.ticks == 2 && networked.frames == 0, scope $"networked object: Update once a tick (frames {networked.frames}, ticks {networked.ticks})");
		Expect(!networked.sawControls, "an object no player controls gets empty controls");

		// The per-callback lists only hold classes that override the callback.
		Expect(ScriptCallbackIndex.Of(typeof(UpdateCounter)) == .Update, "UpdateCounter overrides Update only");
		Expect(ScriptCallbackIndex.Of(typeof(Mover)) == .Update, "Mover overrides Update only");
		Expect(ScriptCallbackIndex.Of(typeof(MeshRenderer)) & ~ScriptCallbacks.OnFrame == .None, "MeshRenderer has no per-frame gameplay callbacks");
		Expect(ScriptCallbackIndex.Of(typeof(Animator)).HasFlag(.OnLocalUpdate), "Animator overrides OnLocalUpdate");
		Expect(ScriptCallbackIndex.Of(typeof(CharacterMotor)).HasFlag(.FixedUpdate), "CharacterMotor overrides FixedUpdate");
		Expect(ScriptCallbackIndex.Of(typeof(Bench)) == .Update | .LateUpdate, "Bench overrides Update and LateUpdate");
		scene.StopPlay();
		Scene.Active = previous;
	}
}
