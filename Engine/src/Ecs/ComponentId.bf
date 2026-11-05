using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Every data component type the ECS has seen, in the order they were first used. A type's place in this list
/// (ComponentId<T>.Index) is the same in every World; each World turns it into its own Flecs id (World.Id<T>).
static class ComponentTypes
{
	public struct Info
	{
		public Type type;
		public int32 size;
		public int32 alignment;
		/// The full Beef name ("Tallow.Velocity"), which is also the component's path in Flecs.
		public String name;
	}

	static List<Info> sTypes = new .() ~ { for (let info in _) delete info.name; delete _; };
	static Monitor sLock = new .() ~ delete _;

	public static int Count
	{
		get
		{
			using (sLock.Enter())
				return sTypes.Count;
		}
	}

	public static Info Get(int32 index)
	{
		using (sLock.Enter())
			return sTypes[index];
	}

	public static int32 Add(Type type, int size, int alignment)
	{
		let name = new String();
		type.GetFullName(name);
		using (sLock.Enter())
		{
			for (let info in sTypes)
			{
				if (info.type == type)
				{
					delete name;
					return (int32)@info.Index;
				}
			}
			sTypes.Add(.() { type = type, size = (int32)size, alignment = (int32)alignment, name = name });
			return (int32)sTypes.Count - 1;
		}
	}
}

/// A data component type's index in ComponentTypes, given out the first time the type is used. Data components
/// are plain structs with no heap fields (docs/ecs-plan.md, "Systems").
static class ComponentId<T> where T : struct
{
	public static readonly int32 Index = ComponentTypes.Add(typeof(T), sizeof(T), alignof(T));
}
