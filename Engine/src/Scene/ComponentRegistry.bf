using System;
using System.Collections;
using System.Reflection;
using System.Threading;

namespace Tallow;

enum FieldKind
{
	Float,
	Double,
	Char,
	Vector4,
	Int3,
	Matrix4,
	Int,
	Bool,
	Vector2,
	Vector3,
	Quaternion,
	Color,
	String,
	Enum,
	ObjectReference,
	/// A List<T> of any of the kinds above (FieldRef.elementKind): see FieldLists.
	List,
	/// An array of any of the kinds above, T[] or a fixed-size T[N]: see FieldLists.
	Array
}

/// One serializable field of a live component.
struct FieldRef
{
	public StringView name;
	public FieldKind kind;
	public void* ptr;
	public Type type;
	public bool hidden;
	/// Marked [Advanced]: drawn under the Inspector's Advanced foldout.
	public bool advanced;
	/// Marked [Sync]: shared from the server to clients.
	public bool sync;
	public bool hasRange;
	public float rangeMin;
	public float rangeMax;
	/// Marked [Layer]: an integer that is one of the project's layers, or -1 for none.
	public bool isLayer;
	/// For a List or Array: what each element is, and its type.
	public FieldKind elementKind;
	public Type elementType;
	/// Marked [Saved] (kept by save games through SaveFields as well).
	public bool saved;
	/// For a built-in component's data field (DataComponents.GetFields with an object): the object whose data it is,
	/// and the data type. An ObjectRef field finds its scene by it, and the serializer finds the data again after
	/// the entity has moved tables.
	public GameObject owner;
	public Type ownerType;

	/// Whether the field is, or holds, references to objects in the scene.
	public bool HoldsReferences => kind == .ObjectReference || ((kind == .List || kind == .Array) && elementKind == .ObjectReference);
}

/// Component type registry and field reflection shared by the scene serializer and the Inspector.
static class ComponentRegistry
{
	public class Info
	{
		public String fullName = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public Type type;
	}

	static List<Info> sInfos ~ DeleteContainerAndItems!(_);

	/// All concrete component types in the program, engine and game alike, sorted by name.
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
			if (type == null) continue;
			if (!type.IsObject || type.IsAbstract || type.IsBoxed || type.IsArray)
				continue;
			if (type == typeof(Component) || !type.IsSubtypeOf(typeof(Component)))
				continue;
			let info = new Info();
			type.GetFullName(info.fullName);
			type.GetName(info.name);
			info.type = type;
			sInfos.Add(info);
		}
		sInfos.Sort(scope (a, b) => a.name.CompareTo(b.name));
	}

	public static void Refresh()
	{
		if (sInfos != null)
		{
			DeleteContainerAndItems!(sInfos);
			sInfos = null;
		}
		ClearFieldCache();
		// Scripts were reloaded: loaded data assets are of the old classes.
		DataAsset.ClearCache();
		Build();
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

	public static Info Find(Type type)
	{
		for (let info in Types)
		{
			if (info.type == type)
				return info;
		}
		return null;
	}

	public static Component Create(Type type)
	{
		if (type.CreateObject() case .Ok(let obj))
		{
			if (let component = obj as Component)
				return component;
			delete obj;
		}
		return null;
	}

	/// Scene references are non-owning. Components match by their reflected type.
	public static GameObject ReferenceOwner(FieldRef field)
	{
		if (ObjectRefs.Is(field.type))
			return ObjectRefs.Owner(field);
		let value = *(Object*)field.ptr;
		if (let go = value as GameObject) return go;
		if (let transform = value as Transform) return transform.GameObject;
		if (let component = value as Component) return component.GameObject;
		return null;
	}

	public static bool AssignReference(FieldRef field, GameObject go, int index = -1)
	{
		if (ObjectRefs.Is(field.type))
			return ObjectRefs.Assign(field, go, index);
		if (go == null)
		{
			*(Object*)field.ptr = null;
			return true;
		}
		Object value = null;
		if (field.type == typeof(GameObject))
			value = go;
		// A built-in component handle holds its object (ComponentHandle): set when the object has that component, and
		// otherwise left as it was (as for a class component: dropping an object without one changes nothing).
		else if (let handle = HandleComponents.Find(field.type))
		{
			if (go.Scene?.World.Has(go.Entity, handle.index) != true)
				return false;
			*(Object*)field.ptr = go;
			return true;
		}
		else if (field.type == typeof(Transform))
			value = go.Transform;
		else
		{
			for (int i < go.Components.Count)
			{
				if (index >= 0 && i != index) continue;
				let component = go.Components[i];
				if (component.GetType() == field.type || component.GetType().IsSubtypeOf(field.type))
				{
					value = component;
					break;
				}
			}
		}
		if (value == null) return false;
		*(Object*)field.ptr = value;
		return true;
	}

	/// Collects the serializable fields of a component, base class fields first.
	public static void GetFields(Component component, List<FieldRef> fields, bool forReload = false) => GetFields(component, typeof(Component), fields, forReload);

	/// Which fields one class has, worked out once: reading attributes through reflection is slow, and the scene
	/// asks for the same classes' fields again and again (destroying objects, saving, the Inspector, networking).
	struct LayoutKey : IHashable
	{
		public Type type;
		public Type stopAt;
		public bool forReload;

		public int GetHashCode() => ((int)Internal.UnsafeCastToPtr(type) * 31) ^ ((int)Internal.UnsafeCastToPtr(stopAt) * 7) ^ (forReload ? 1 : 0);

		public static bool operator ==(LayoutKey a, LayoutKey b) => a.type == b.type && a.stopAt == b.stopAt && a.forReload == b.forReload;
	}

	/// Each class's fields with `ptr` holding the field's offset in the object rather than an address.
	static Dictionary<LayoutKey, List<FieldRef>> sLayouts = new .() ~ DeleteDictionaryAndValues!(_);
	static Monitor sLayoutLock = new .() ~ delete _;

	/// Forgets every class's fields. Script reload changes classes in place, so it must be called after one.
	public static void ClearFieldCache()
	{
		using (sLayoutLock.Enter())
		{
			for (let layout in sLayouts.Values)
				delete layout;
			sLayouts.Clear();
		}
	}

	/// The same for any object (a data asset), with the fields of the classes from stopAt down.
	public static void GetFields(Object target, Type stopAt, List<FieldRef> fields, bool forReload = false)
	{
		LayoutKey key;
		key.type = target.GetType();
		key.stopAt = stopAt;
		key.forReload = forReload;
		let basePtr = (uint8*)Internal.UnsafeCastToPtr(target);
		using (sLayoutLock.Enter())
		{
			if (!sLayouts.TryGetValue(key, var layout))
			{
				layout = new List<FieldRef>();
				BuildLayout(key.type, stopAt, forReload, layout);
				sLayouts[key] = layout;
			}
			for (var field in layout)
			{
				field.ptr = basePtr + (int)field.ptr;
				fields.Add(field);
			}
		}
	}

	/// The same for a value of a struct type at data (a data component in a World).
	public static void GetFields(Type type, void* data, List<FieldRef> fields)
	{
		LayoutKey key;
		key.type = type;
		key.stopAt = null;
		key.forReload = false;
		using (sLayoutLock.Enter())
		{
			if (!sLayouts.TryGetValue(key, var layout))
			{
				layout = new List<FieldRef>();
				BuildLayout(type, null, false, layout);
				sLayouts[key] = layout;
			}
			for (var field in layout)
			{
				field.ptr = (uint8*)data + (int)field.ptr;
				fields.Add(field);
			}
		}
	}

	/// What kind of single value a field of this type holds; false for a type fields cannot hold.
	public static bool Classify(Type fieldType, out FieldKind kind)
	{
		kind = .Float;
		let storage = FieldNumbers.Storage(fieldType);
		if (storage == typeof(float))
			kind = .Float;
		else if (storage == typeof(double))
			kind = .Double;
		else if (fieldType.IsEnum && storage.IsInteger && fieldType.Size <= 8)
			kind = .Enum;
		else if (storage.IsInteger)
			kind = .Int;
		else if (storage == typeof(char8) || storage == typeof(char16) || storage == typeof(char32))
			kind = .Char;
		else if (fieldType == typeof(Vector4))
			kind = .Vector4;
		else if (fieldType == typeof(Int3))
			kind = .Int3;
		else if (fieldType == typeof(Matrix4))
			kind = .Matrix4;
		else if (fieldType == typeof(bool))
			kind = .Bool;
		else if (fieldType == typeof(Vector2))
			kind = .Vector2;
		else if (fieldType == typeof(Vector3))
			kind = .Vector3;
		else if (fieldType == typeof(Quaternion))
			kind = .Quaternion;
		else if (fieldType == typeof(Color))
			kind = .Color;
		else if (fieldType == typeof(String) || fieldType == typeof(SharedString))
			kind = .String;
		else if (fieldType == typeof(GameObject) || fieldType == typeof(Transform) || fieldType == typeof(Component) || fieldType.IsSubtypeOf(typeof(Component))
			|| HandleComponents.IsHandle(fieldType) || ObjectRefs.Is(fieldType))
			kind = .ObjectReference;
		else
			return false;
		return true;
	}

	static void BuildLayout(Type targetType, Type stopAt, bool forReload, List<FieldRef> fields)
	{
		List<TypeInstance> chain = scope .();
		var type = targetType as TypeInstance;
		while (type != null && type != stopAt)
		{
			chain.Add(type);
			type = type.BaseType;
		}
		for (int i = chain.Count - 1; i >= 0; i--)
		{
			for (let field in chain[i].GetFields(.Instance | .Public | .NonPublic | .DeclaredOnly))
			{
				if (!field.IsInstanceField)
					continue;
				if (!forReload && !field.IsPublic && !(field.GetCustomAttribute<ShowInInspectorAttribute>() case .Ok))
					continue;
				if (field.GetCustomAttribute<NonSerializedAttribute>() case .Ok)
					continue;

				FieldRef fieldRef = default;
				let fieldType = field.FieldType;
				if (Classify(fieldType, out fieldRef.kind))
				{
				}
				else if (FieldLists.ElementOf(fieldType) case .Ok(let element) && Classify(element, out fieldRef.elementKind))
				{
					fieldRef.kind = fieldType.IsArray || fieldType.IsSizedArray ? .Array : .List;
					fieldRef.elementType = element;
				}
				else continue;

				fieldRef.name = field.Name;
				fieldRef.type = fieldType;
				fieldRef.ptr = (void*)(int)field.MemberOffset;
				fieldRef.hidden = field.GetCustomAttribute<HideInInspectorAttribute>() case .Ok;
				fieldRef.advanced = field.GetCustomAttribute<AdvancedAttribute>() case .Ok;
				fieldRef.sync = field.GetCustomAttribute<SyncAttribute>() case .Ok;
				fieldRef.isLayer = field.GetCustomAttribute<LayerAttribute>() case .Ok;
				fieldRef.saved = field.GetCustomAttribute<SavedAttribute>() case .Ok;
				if (field.GetCustomAttribute<RangeAttribute>() case .Ok(let range))
				{
					fieldRef.hasRange = true;
					fieldRef.rangeMin = range.min;
					fieldRef.rangeMax = range.max;
				}
				fields.Add(fieldRef);
			}
		}
	}
}
