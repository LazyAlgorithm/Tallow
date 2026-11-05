using System;
using System.Reflection;

namespace Tallow;

/// A reference to another object, or to a component on it, kept in built-in component data. A pointer can't be
/// stored there: the data moves between Flecs tables, and nothing would clear the pointer when its object went. So
/// this holds the object's id and looks it up when used. A destroyed object is simply not found, and the reference
/// reads as none. T is what it refers to: GameObject, Transform, a class component (the first of that type on the
/// object, or the one at `index`) or a built-in component handle. It is saved, copied and picked in the Inspector
/// as class references are ("field surface <object id> <component index>").
struct ObjectRef<T> : IObjectRef
{
	/// The object's GameObject.Id; 0 for none.
	public uint32 id = 0;
	/// For a class component, its place in the object's Components. -1 means the first one of type T.
	public int32 index = -1;

	public this() { }

	public this(uint32 id, int32 index = -1)
	{
		this.id = id;
		this.index = index;
	}

	public bool IsSet => id != 0;

	public static implicit operator Self(GameObject target) => target != null ? .(target.Id) : .();

	public static implicit operator Self(Transform target) => target != null ? .(target.GameObject.Id) : .();

	/// From what it refers to: a built-in component handle (an invalid one gives none) or a class component.
	public static implicit operator Self(T target)
	{
		// A handle starts with its object; a class reference is the object itself.
		let held = *(Object*)(void*)&target;
		if (typeof(T).IsValueType)
			return held != null ? .(((GameObject)held).Id) : .();
		if (let component = held as Component)
			return (Self)component;
		if (let transform = held as Transform)
			return (Self)transform;
		return (Self)(held as GameObject);
	}

	public static implicit operator Self(Component target)
	{
		if (target == null || target.GameObject == null)
			return .();
		return .(target.GameObject.Id, (int32)target.GameObject.Components.IndexOf(target));
	}

	/// The object, if it is still in the scene.
	public GameObject Object(Scene scene) => (id == 0 || scene == null) ? null : scene.FindById(id);

	/// The class component referred to (T is a class component), if its object is still in the scene and has one.
	public Component Component(Scene scene) => ObjectRefs.ComponentOf(Object(scene), typeof(T), index);

	public bool Equals(ObjectRef<T> other) => id == other.id && index == other.index;
}

/// What every ObjectRef<T> has in common, so reflection can recognise one (ComponentRegistry).
interface IObjectRef
{
}

/// ObjectRef fields seen through reflection: by the serializer, the Inspector and the clipboard.
static class ObjectRefs
{
	/// The layout every ObjectRef<T> shares.
	public struct Raw
	{
		public uint32 id;
		public int32 index;
	}

	public static bool Is(Type type)
	{
		let generic = type as SpecializedGenericType;
		return generic != null && generic.UnspecializedType == typeof(ObjectRef<>);
	}

	/// What an ObjectRef type refers to (its T), or null if type is not one.
	public static Type TargetOf(Type type)
	{
		let generic = type as SpecializedGenericType;
		if (generic == null || generic.UnspecializedType != typeof(ObjectRef<>))
			return null;
		return generic.GetGenericArg(0);
	}

	/// The component of a type on an object: the one at index if it is of that type, otherwise the first.
	public static Component ComponentOf(GameObject go, Type type, int index)
	{
		if (go == null)
			return null;
		if (index >= 0 && index < go.Components.Count)
		{
			let component = go.Components[index];
			if (component.GetType() == type || component.GetType().IsSubtypeOf(type))
				return component;
		}
		for (let component in go.Components)
		{
			if (component.GetType() == type || component.GetType().IsSubtypeOf(type))
				return component;
		}
		return null;
	}

	/// Whether an object has what a reference of this target type needs.
	public static bool Fits(GameObject go, Type target, int index)
	{
		if (go == null)
			return false;
		if (target == typeof(GameObject) || target == typeof(Transform))
			return true;
		if (let handle = HandleComponents.Find(target))
			return go.Scene != null && go.Scene.World.Has(go.Entity, handle.index);
		return ComponentOf(go, target, index) != null;
	}

	/// The object a reference field points at, if it is still there and has what the reference needs.
	public static GameObject Owner(FieldRef field)
	{
		let raw = (Raw*)field.ptr;
		let scene = field.owner?.Scene ?? Scene.Active;
		if (raw.id == 0 || scene == null)
			return null;
		let go = scene.FindById(raw.id);
		return Fits(go, TargetOf(field.type), raw.index) ? go : null;
	}

	/// The component a reference to a class component points at (to compare in the Inspector's picker), or null.
	public static Component Target(FieldRef field) => ComponentOf(Owner(field), TargetOf(field.type), ((Raw*)field.ptr).index);

	/// Points a reference field at an object (or its component at index); false when the object has none of the
	/// type, which leaves the reference as none.
	public static bool Assign(FieldRef field, GameObject go, int index)
	{
		let raw = (Raw*)field.ptr;
		raw.id = 0;
		raw.index = -1;
		if (go == null)
			return true;
		let target = TargetOf(field.type);
		if (!Fits(go, target, index))
			return false;
		raw.id = go.Id;
		// Kept only for a class component, and only when it is one of that type.
		if (index >= 0 && index < go.Components.Count && ComponentOf(go, target, index) == go.Components[index])
			raw.index = (int32)index;
		return true;
	}
}
