using System;

namespace Tallow;

/// A lasting pointer to one entity's T: it follows the entity's row as Flecs moves it, and costs a version compare
/// to use unless the entity's table changed. For engine classes that front an entity (Transform). Use it from the
/// main thread, or from workers while the world's structure is not changing.
struct ComponentRef<T> where T : struct
{
	Flecs.RefBuffer mRef;
	uint64 mId;

	/// The entity must already have T.
	public this(World world, Entity entity)
	{
		mId = world.Id<T>();
		mRef = ?;
		Flecs.RefInit(world.Native, entity.id, mId, &mRef);
	}

	/// The data, or null once the entity is gone or has lost T.
	[Inline]
	public T* Get(World world) mut
	{
		// The same check ecs_ref_get_id starts with, without the call.
		if (mRef.tableVersionFast == world.TableVersion(mRef.tableId) && mRef.tableId != 0)
			return (T*)mRef.ptr;
		ComponentRefStats.SlowPath++;
		return (T*)Flecs.RefGet(world.Native, &mRef, mId);
	}
}

static class ComponentRefStats
{
	public static int64 SlowPath;
}
