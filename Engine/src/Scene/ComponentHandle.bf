using System;
using System.Collections;
using System.Reflection;

namespace Tallow;

/// What every built-in component handle (Light, MeshRenderer...) is: a struct naming an object, whose data lives in
/// the object's entity (docs/ecs-plan.md, "Built-in components: same names, now handles").
interface IComponentHandle
{
	/// The data struct the handle reads and writes.
	static Type DataType { get; }
	/// DataType's place in ComponentTypes.
	static int32 DataIndex { get; }
}

/// Marks the data struct behind a component handle. It is kept out of DataComponents (the handle shows it in the
/// Inspector and scene files under its own name), and it can be switched off per object (`enabled`).
[AttributeUsage(.Struct, .ReflectAttribute)]
struct HandleDataAttribute : Attribute
{
}

/// The base of a built-in component handle: the object it belongs to. A handle is as small as a reference and is
/// passed and kept like one; its data is looked up each time it is used, so it never points at moved memory. A handle
/// whose object is destroyed, or that lost its component, is not valid: check with `if (light)` or `IsValid`. (Beef
/// cannot make `light == null` work for a struct; the compiler warns that such a test is always false.)
///
/// A handle declares no fields of its own: GameObject.GetComponent makes one from the object alone. Give it
/// `[HandleFields]` to have a property for every public field of its data, so that `light.intensity = 2` and
/// `light.color.a = 0.5f` read as they did when Light was a class.
[Reflect(.All)]
struct ComponentHandle<TData> : IComponentHandle where TData : struct, new
{
	protected GameObject mGameObject;

	public static Type DataType => typeof(TData);
	public static int32 DataIndex => ComponentId<TData>.Index;

	public this()
	{
		mGameObject = null;
	}

	public this(GameObject gameObject)
	{
		mGameObject = gameObject;
	}

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject?.Scene;

	/// The object exists and still has this component.
	public bool IsValid => mGameObject != null && mGameObject.Scene != null && mGameObject.HasComponent<TData>();

	public static implicit operator bool(Self handle) => handle.IsValid;

	/// The component's data. Valid until the object's components change: use it straight away.
	public ref TData Data
	{
		[Inline]
		get
		{
			let data = mGameObject.GetComponent<TData>();
			Runtime.Assert(data != null, "A component handle was used after its component or object was removed. Check it with `if (handle)` first.");
			return ref *data;
		}
	}

	/// Whether the component is switched on. A switched-off component is skipped by the engine (a light gives no light).
	public bool enabled
	{
		get => mGameObject.Scene.World.IsEnabled(mGameObject.Entity, DataIndex);
		set => mGameObject.Scene.World.Enable(mGameObject.Entity, DataIndex, value);
	}

	public bool Enabled
	{
		get => enabled;
		set => enabled = value;
	}

	/// Switched on, and its object active in the hierarchy.
	public bool IsActiveAndEnabled => mGameObject.ActiveInHierarchy && enabled;

	public static bool operator ==(Self a, Self b) => a.mGameObject == b.mGameObject;
	public static bool operator !=(Self a, Self b) => a.mGameObject != b.mGameObject;
	public int GetHashCode() => (int)Internal.UnsafeCastToPtr(mGameObject);
}

/// On a component handle: adds a ref property for every public field of the handle's data struct, so that the
/// fields read and write as if they were the handle's own.
[AttributeUsage(.Struct)]
struct HandleFieldsAttribute : Attribute, IOnTypeInit
{
	[Comptime]
	public void OnTypeInit(Type type, Self* prev)
	{
		let generic = type.BaseType as SpecializedGenericType;
		if (generic == null)
			return;
		let data = generic.GetGenericArg(0);
		let code = scope String();
		code.Append("public this() : base() {}\npublic this(GameObject gameObject) : base(gameObject) {}\n");
		for (let field in data.GetFields(.Public | .Instance))
			code.AppendF("public ref {} {} {{ [Inline] get => ref Data.{}; }}\n", field.FieldType, field.Name, field.Name);
		Compiler.EmitTypeBody(type, code);
	}
}

/// What a built-in component keeps outside its data, one T for each entity that has asked for one: GPU textures,
/// voices, physics bodies. Things like these must not be in the data, which Flecs copies byte for byte. Free it from
/// the handle's `static void OnRemove(void* world, uint64 entity) => ComponentState<T>.Release(world, entity);`.
static class ComponentState<T> where T : class, new, delete
{
	struct Key : IHashable, IEquatable<Key>
	{
		public void* world;
		public uint64 entity;

		public int GetHashCode() => (int)(uint)world ^ (int)(entity ^ (entity >> 32)) * 31;
		public bool Equals(Key other) => world == other.world && entity == other.entity;
		public static bool operator ==(Key a, Key b) => a.Equals(b);
	}

	static Dictionary<Key, T> sStates = new .() ~ DeleteDictionaryAndValues!(_);

	static Key KeyOf(World world, Entity entity) => .() { world = Internal.UnsafeCastToPtr(world), entity = entity.id };

	/// The entity's state, or null if it has none yet.
	public static T Get(World world, Entity entity) => sStates.TryGetValue(KeyOf(world, entity), let state) ? state : null;

	/// The entity's state, made the first time it is asked for.
	public static T Make(World world, Entity entity)
	{
		let key = KeyOf(world, entity);
		if (sStates.TryGetValue(key, let state))
			return state;
		let made = new T();
		sStates[key] = made;
		return made;
	}

	/// Frees the entity's state, if it has any (from a handle's OnRemove: world is the World object).
	public static void Release(void* world, uint64 entity)
	{
		if (sStates.GetAndRemove(.() { world = world, entity = entity }) case .Ok(let pair))
			delete pair.value;
	}

	public static int Count => sStates.Count;
}

/// The built-in component handles there are, found by reflection: what Add Component, the Inspector, scene files and
/// object references use to treat them like script components.
static class HandleComponents
{
	public class Info
	{
		/// The handle's full name ("Tallow.Light"), which scene files use as for a script.
		public String fullName = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public Type handleType;
		public Type dataType;
		/// dataType's place in ComponentTypes.
		public int32 index;
		/// The data's field initializers, applied to a component when it is added.
		public uint8[] defaults ~ delete _;
		/// The handle's `static void DrawGizmos(GameObject gameObject, bool selected)`, if it has one.
		public MethodInfo drawGizmos;
		/// The handle's `static void OnRemove(void* world, uint64 entity)`, if it has one: called as the component
		/// leaves an entity, to free what it kept outside its data (ComponentState). world is the World object.
		public Flecs.RemoveCallback onRemove;
	}

	static List<Info> sInfos ~ DeleteContainerAndItems!(_);
	static Dictionary<Type, Info> sByHandle ~ delete _;
	static Dictionary<int32, Info> sByIndex ~ delete _;

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
		sByHandle = new .();
		sByIndex = new .();
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type == null || !type.IsStruct || type.IsGenericType)
				continue;
			let data = DataOf(type);
			if (data == null)
				continue;
			let info = new Info();
			type.GetFullName(info.fullName);
			type.GetName(info.name);
			info.handleType = type;
			info.dataType = data;
			info.index = ComponentTypes.Add(data, data.Size, data.Align);
			info.defaults = new uint8[data.Size];
			if (data.CreateValue() case .Ok(let value))
			{
				Internal.MemCpy(info.defaults.Ptr, value, data.Size);
				delete value;
			}
			if (type.GetMethod("DrawGizmos", .Static | .Public | .NonPublic) case .Ok(let method))
				info.drawGizmos = method;
			if (type.GetMethod("OnRemove", .Static | .Public | .NonPublic) case .Ok(let method))
				info.onRemove = (Flecs.RemoveCallback)method.Ptr;
			sInfos.Add(info);
			sByHandle[type] = info;
			sByIndex[info.index] = info;
		}
		sInfos.Sort(scope (a, b) => a.name.CompareTo(b.name));
	}

	/// The data type behind a handle type, or null if type is not a handle.
	static Type DataOf(Type type)
	{
		let generic = type.BaseType as SpecializedGenericType;
		if (generic == null || generic.UnspecializedType != typeof(ComponentHandle<>))
			return null;
		return generic.GetGenericArg(0);
	}

	public static bool IsHandle(Type type) => type != null && type.IsStruct && Find(type) != null;

	public static Info Find(Type handleType)
	{
		if (sInfos == null)
			Build();
		return sByHandle.TryGetValue(handleType, let info) ? info : null;
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

	/// The handle whose data has ComponentTypes index index, or null.
	public static Info Find(int32 index)
	{
		if (sInfos == null)
			Build();
		return sByIndex.TryGetValue(index, let info) ? info : null;
	}

	/// The handle components on an object, in the order Flecs keeps them.
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

	/// Adds the component with its default values (or returns the one there), switched on.
	public static void* Add(GameObject gameObject, Info info)
	{
		let world = gameObject.Scene.World;
		if (let existing = world.Get(gameObject.Entity, info.index))
			return existing;
		let data = world.Ensure(gameObject.Entity, info.index);
		Internal.MemCpy(data, info.defaults.Ptr, info.defaults.Count);
		return data;
	}

	/// Sets the component back to its default values.
	public static void Reset(GameObject gameObject, Info info)
	{
		if (let data = gameObject.Scene.World.Get(gameObject.Entity, info.index))
			Internal.MemCpy(data, info.defaults.Ptr, info.defaults.Count);
	}

	/// The editable and saved fields of the component's data.
	public static void GetFields(GameObject gameObject, Info info, List<FieldRef> fields)
	{
		if (let data = gameObject.GetData(info.dataType))
			DataComponents.GetFields(info.dataType, data, fields);
	}

	/// Draws the gizmos of every handle component on the object (SceneView).
	public static void DrawGizmos(GameObject gameObject, bool selected)
	{
		let found = scope List<Info>();
		On(gameObject, found);
		for (let info in found)
		{
			if (info.drawGizmos.IsInitialized)
				info.drawGizmos.Invoke(null, gameObject, selected).IgnoreError();
		}
	}
}
