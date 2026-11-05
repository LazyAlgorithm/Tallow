using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace EcsBench;

[Component]
struct Marked
{
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
		let childEntity = child.Entity;
		let parentEntity = parent.Entity;
		scene.DestroyImmediate(parent);
		Expect(!world.IsAlive(parentEntity) && !world.IsAlive(childEntity), "destroying objects deletes their entities");
		Expect(world.Count<ObjectLink>() == 0, "no entities left behind");
	}
}
