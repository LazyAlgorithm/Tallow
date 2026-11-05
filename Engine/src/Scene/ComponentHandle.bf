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
///
/// For each List<T> field it adds `static Object NewList(int32 index)`, which makes an empty list for the index-th
/// list field: HandleComponents gives every copy of the data lists of its own with it (reflection cannot make a
/// List<T> it never saw made).
[AttributeUsage(.Struct, .ReflectAttribute)]
struct HandleDataAttribute : Attribute, IOnTypeInit
{
	[Comptime]
	public void OnTypeInit(Type type, Self* prev)
	{
		let code = scope String();
		int32 index = 0;
		for (let field in type.GetFields(.Public | .Instance))
		{
			if (let generic = field.FieldType as SpecializedGenericType)
			{
				if (generic.UnspecializedType == typeof(List<>))
					code.AppendF("\t\tcase {}: return new {}();\n", index++, field.FieldType);
			}
		}
		if (index == 0)
			return;
		Compiler.EmitTypeBody(type, scope $"static System.Object NewList(int32 index)\n{{\n\tswitch (index)\n\t{{\n{code}\t}}\n\treturn null;\n}}\n");
	}
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
			Runtime.Assert(mGameObject != null, "A component handle that is not valid was used: GetComponent found none. Check it with `if (handle)` first.");
			let data = mGameObject.GetComponent<TData>();
			Runtime.Assert(data != null, "A component handle was used after its component or object was removed. Check it with `if (handle)` first.");
			return ref *data;
		}
	}

	/// Stops with a clear message when the handle is not valid (before touching what the component keeps outside
	/// its data, which would otherwise be made for an object that has no such component).
	protected void CheckValid()
	{
		Runtime.Assert(mGameObject != null && mGameObject.Scene != null && mGameObject.HasComponent<TData>(), "A component handle that is not valid was used. Check it with `if (handle)` first.");
	}

	/// Whether the component is switched on. A switched-off component is skipped by the engine (a light gives no light).
	public bool enabled
	{
		get => mGameObject.Scene.World.IsEnabled(mGameObject.Entity, DataIndex);
		set
		{
			let world = mGameObject.Scene.World;
			if (world.IsEnabled(mGameObject.Entity, DataIndex) == value)
				return;
			world.Enable(mGameObject.Entity, DataIndex, value);
			// In multiplayer, as Component.Enabled: the server's (or an owner's cosmetic) switch reaches everyone.
			NetworkSync.HandleEnabledChanged(mGameObject, HandleComponents.Find(DataIndex), value);
		}
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

	/// Every state kept for entities of world, with its entity.
	public static void In(World world, List<(Entity entity, T state)> output)
	{
		let key = Internal.UnsafeCastToPtr(world);
		for (let (k, state) in sStates)
		{
			if (k.world == key)
				output.Add((Entity(k.entity), state));
		}
	}
}

/// On a class that keeps a copy of a component's data in a field (RenderProxy keeps a MeshRendererData in `data`):
/// adds a ref property for every public field of that data, as [HandleFields] does for a handle.
[AttributeUsage(.Class | .Struct)]
struct DataFieldsAttribute : Attribute, IOnTypeInit
{
	Type mData;
	String mMember;

	public this(Type data, String member)
	{
		mData = data;
		mMember = member;
	}

	[Comptime]
	public void OnTypeInit(Type type, Self* prev)
	{
		let code = scope String();
		for (let field in mData.GetFields(.Public | .Instance))
			code.AppendF("public ref {} {} {{ [System.Inline] get => ref {}.{}; }}\n", field.FieldType, field.Name, mMember, field.Name);
		Compiler.EmitTypeBody(type, code);
	}
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
		/// The data's List<T> fields (offset and type): lists the component's data owns (OwnLists, FreeLists).
		public List<(int offset, Type type)> lists = new .() ~ delete _;
		/// The data's String fields (offsets): text the component's data owns, copied and freed with it as lists are.
		/// For text that changes, or is too long to intern as a SharedString (Foliage's packed plants).
		public List<int> texts = new .() ~ delete _;
		/// The data's `NewList` ([HandleData] makes it): an empty list for its index-th list field.
		public function Object(int32 index) newList;
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
			info.index = ComponentTypes.Add(data, data.Stride, data.Align);
			info.defaults = new uint8[data.Stride];
			if (data.CreateValue() case .Ok(let value))
			{
				Internal.MemCpy(info.defaults.Ptr, value, data.Size);
				delete value;
			}
			if (type.GetMethod("DrawGizmos", .Static | .Public | .NonPublic) case .Ok(let method))
				info.drawGizmos = method;
			if (type.GetMethod("OnRemove", .Static | .Public | .NonPublic) case .Ok(let method))
				info.onRemove = (Flecs.RemoveCallback)method.Ptr;
			for (let field in data.GetFields(.Public | .Instance))
			{
				if (let generic = field.FieldType as SpecializedGenericType)
				{
					if (generic.UnspecializedType == typeof(List<>))
						info.lists.Add((field.MemberOffset, field.FieldType));
				}
				else if (field.FieldType == typeof(String))
					info.texts.Add(field.MemberOffset);
			}
			if (!info.texts.IsEmpty && info.onRemove == null)
				Log.Error(scope $"{info.name} has String fields but no OnRemove calling HandleComponents.FreeLists: its text would leak.");
			if (!info.lists.IsEmpty && data.GetMethod("NewList", .Static | .Public | .NonPublic) case .Ok(let maker))
				info.newList = (function Object(int32))maker.Ptr;
			if (!info.lists.IsEmpty && info.onRemove == null)
				Log.Error(scope $"{info.name} has list fields but no OnRemove calling HandleComponents.FreeLists: its lists would leak.");
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
		OwnLists(data, info);
		return data;
	}

	/// Sets the component back to its default values.
	public static void Reset(GameObject gameObject, Info info)
	{
		if (let data = gameObject.Scene.World.Get(gameObject.Entity, info.index))
			Assign(data, info.defaults.Ptr, info);
	}

	/// Copies a component's data over another's: what the copy owned is freed and it gets lists of its own (a
	/// plain byte copy would leave two components owning one list).
	public static void Assign(void* data, void* from, Info info)
	{
		FreeLists(data, info);
		Internal.MemCpy(data, from, info.defaults.Count);
		OwnLists(data, info);
	}

	/// Lists and text in built-in component data: a component's data owns each List<T> field's list and each String
	/// field's text. Wherever the data is
	/// copied byte for byte (added with its defaults, reset, pasted), OwnLists gives the copy lists of its own, and
	/// the handle's OnRemove frees them with FreeLists. Copies of the data kept elsewhere (a RenderProxy's) only
	/// read them.
	public static void OwnLists(void* data, Info info)
	{
		for (int32 i < (int32)info.lists.Count)
		{
			let slot = (uint8*)data + info.lists[i].offset;
			if (*(Object*)slot != null)
				FieldLists.CloneList(slot, info.newList != null ? info.newList(i) : null);
		}
		for (let offset in info.texts)
		{
			let slot = (String*)((uint8*)data + offset);
			if (*slot != null)
				*slot = new String(*slot);
		}
	}

	/// Frees the lists a component's data owns.
	public static void FreeLists(void* data, Info info)
	{
		for (let list in info.lists)
			FieldLists.FreeList((uint8*)data + list.offset);
		for (let offset in info.texts)
		{
			let slot = (String*)((uint8*)data + offset);
			let text = *slot;
			*slot = null;
			// A literal (a field initializer of "" rather than new .()) is not ours to free.
			if (text != null && !StringFields.IsReadOnly(Internal.UnsafeCastToPtr(text)))
				delete text;
		}
	}

	/// The same from a handle's OnRemove: world is the World object.
	public static void FreeLists(void* world, uint64 entity, Type handleType)
	{
		let info = Find(handleType);
		if (info == null || (info.lists.IsEmpty && info.texts.IsEmpty))
			return;
		if (let data = ((World)Internal.UnsafeCastToObject(world)).Get(Entity(entity), info.index))
			FreeLists(data, info);
	}

	/// The editable and saved fields of the component's data.
	public static void GetFields(GameObject gameObject, Info info, List<FieldRef> fields)
	{
		if (let data = gameObject.GetData(info.dataType))
			DataComponents.GetFields(info.dataType, data, fields, gameObject);
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
