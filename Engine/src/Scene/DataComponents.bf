using System;
using System.Collections;

namespace Tallow;

/// Marks an engine data component that is bookkeeping, not something to edit: it is not listed in Add Component,
/// shown in the Inspector or written to scene files (the engine makes it again itself).
[AttributeUsage(.Struct, .ReflectAttribute)]
struct EngineDataAttribute : Attribute
{
}

/// The data components a project has: `[Component]` structs (docs/ecs-plan.md, "Systems"). They live in the
/// object's entity rather than on the GameObject, are saved in scene files as `data` blocks and edited in the
/// Inspector beside scripts. Their fields must be plain values (numbers, vectors, colours, enums, bools); other
/// fields are left out of files and the Inspector.
static class DataComponents
{
	public class Info
	{
		public String fullName = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public Type type;
		/// The type's place in ComponentTypes (the same in every World).
		public int32 index;
	}

	static List<Info> sInfos ~ DeleteContainerAndItems!(_);

	/// Every data component a game can add, sorted by name.
	public static List<Info> Types
	{
		get
		{
			if (sInfos == null)
				Build();
			return sInfos;
		}
	}

	static void Build()
	{
		sInfos = new .();
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type == null || !type.IsStruct || type.IsGenericType)
				continue;
			if (!(type.GetCustomAttribute<ComponentAttribute>() case .Ok))
				continue;
			if (type.GetCustomAttribute<EngineDataAttribute>() case .Ok)
				continue;
			// Behind a built-in component (HandleComponents), which shows it under its own name, or a handle itself.
			if (type.GetCustomAttribute<HandleDataAttribute>() case .Ok || HandleComponents.IsHandle(type))
				continue;
			let info = new Info();
			type.GetFullName(info.fullName);
			type.GetName(info.name);
			info.type = type;
			info.index = ComponentTypes.Add(type, type.Size, type.Align);
			sInfos.Add(info);
		}
		sInfos.Sort(scope (a, b) => a.name.CompareTo(b.name));
	}

	/// Scripts were reloaded: the types may have changed.
	public static void Refresh()
	{
		if (sInfos != null)
		{
			DeleteContainerAndItems!(sInfos);
			sInfos = null;
		}
	}

	public static Info Find(StringView fullName)
	{
		for (let info in Types)
		{
			if (info.fullName == fullName)
				return info;
		}
		return null;
	}

	public static Info Find(int32 index)
	{
		for (let info in Types)
		{
			if (info.index == index)
				return info;
		}
		return null;
	}

	/// The editable fields of a data component whose value is at data. Only plain values: a data component holds
	/// no references to the heap.
	public static void GetFields(Type type, void* data, List<FieldRef> fields)
	{
		let all = scope List<FieldRef>();
		ComponentRegistry.GetFields(type, data, all);
		for (let field in all)
		{
			switch (field.kind)
			{
			case .String,.ObjectReference,.List,.Array:
				continue;
			default:
				fields.Add(field);
			}
		}
	}

	/// The data components on an object that can be edited and saved, in the order Flecs keeps them.
	public static void On(GameObject gameObject, List<Info> output)
	{
		let world = gameObject.Scene?.World;
		if (world == null || gameObject.Entity.IsNull)
			return;
		let indices = scope List<int32>();
		world.TypesOf(gameObject.Entity, indices);
		for (let index in indices)
		{
			if (let info = Find(index))
				output.Add(info);
		}
	}
}
