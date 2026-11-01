using System;
using System.Collections;
using System.Reflection;

namespace Tallow;

/// Marks a field to be kept in saves:
///
///   [Saved] public int32 coins;
///   [Saved] public List<Vector3> checkpoints = new .() ~ delete _;
///   [Saved("hp")] public float health;      // stored under "hp": rename the field later without breaking saves
///
/// On a component, SaveSystem.Save and Load then take care of it. On a data asset, the asset's Save and Load do.
/// On a struct or class of your own, its marked fields are saved wherever a value of it is.
///
/// Types: bool, every integer and float, char8/16/32, String, enums, Vector2/3/4, Int3, Quaternion, Color, Matrix4,
/// GameObject, Transform and components (saved as references to scene objects), structs and classes with [Saved]
/// fields of their own, and any mix of these in arrays (T[], T[,], T[,,], T[,,,]), sized arrays (T[N]), List,
/// Queue, HashSet, LinkedList and Dictionary. Collections of objects own them: loading deletes the objects a
/// collection held and makes new ones (references to scene objects excepted).
///
/// The code that saves and loads the fields is written by the compiler, from the field types, when the program
/// is built: there is no reflection while saving, and a field of a type that cannot be saved is a compile error.
[AttributeUsage(.Field, .ReflectAttribute)]
struct SavedAttribute : Attribute, IOnFieldInit
{
	public String key;

	public this()
	{
		key = null;
	}

	/// The name the value is stored under, instead of the field's.
	public this(String key)
	{
		this.key = key;
	}

	[Comptime]
	public void OnFieldInit(FieldInfo fieldInfo, Self* prev)
	{
		SaveCodegen.FieldMarked(fieldInfo);
	}
}

/// Writes SaveFields for types with [Saved] fields. Runs inside the compiler.
static class SaveCodegen
{
	const BindingFlags OwnFields = .Instance | .Public | .NonPublic | .DeclaredOnly;

	/// Whether the type declares any [Saved] field itself.
	[Comptime]
	public static bool DeclaresSaved(Type type)
	{
		if (type == null || !(type is TypeInstance))
			return false;
		for (let field in type.GetFields(OwnFields))
		{
			if (field.GetCustomAttribute<SavedAttribute>() case .Ok)
				return true;
		}
		return false;
	}

	/// Whether the type, or a class it derives from, has [Saved] fields.
	[Comptime]
	public static bool HasSaved(Type type)
	{
		var check = type;
		while (check != null && check != typeof(Object) && check != typeof(ValueType))
		{
			if (DeclaresSaved(check))
				return true;
			check = check.BaseType;
		}
		return false;
	}

	[Comptime]
	public static void FieldMarked(FieldInfo fieldInfo)
	{
		let owner = fieldInfo.DeclaringType;
		if (fieldInfo.IsStatic)
			Runtime.FatalError(scope $"[Saved] is for instance fields; '{fieldInfo.Name}' is static. Keep shared values in a data asset.");
		// The first marked field writes the code for all of them.
		for (let field in owner.GetFields(OwnFields))
		{
			if (field.GetCustomAttribute<SavedAttribute>() case .Ok)
			{
				if (field.Name != fieldInfo.Name)
					return;
				break;
			}
		}

		let isComponent = owner.IsSubtypeOf(typeof(Component));
		// Data assets have SaveFields to override, as components do.
		let isAsset = owner.IsSubtypeOf(typeof(DataAsset));
		let isStruct = owner.IsValueType;
		// A class of the game's own whose base class has [Saved] fields already has SaveFields to extend.
		var baseSaved = false;
		if (!isComponent && !isAsset && !isStruct)
		{
			var check = owner.BaseType;
			while (check != null && check != typeof(Object))
			{
				if (DeclaresSaved(check))
				{
					baseSaved = true;
					break;
				}
				check = check.BaseType;
			}
		}
		let code = scope String();
		if (isComponent || isAsset || baseSaved)
			code.Append("public override void SaveFields(Tallow.SaveIO io)\n{\n\tbase.SaveFields(io);\n");
		else if (isStruct)
			code.Append("public void SaveFields(Tallow.SaveIO io) mut\n{\n");
		else
			code.Append("public virtual void SaveFields(Tallow.SaveIO io)\n{\n");
		for (let field in owner.GetFields(OwnFields))
		{
			if (!(field.GetCustomAttribute<SavedAttribute>() case .Ok(let saved)))
				continue;
			if (field.IsStatic)
				Runtime.FatalError(scope $"[Saved] is for instance fields; '{field.Name}' is static.");
			let key = saved.key != null ? StringView(saved.key) : field.Name;
			code.AppendF("\tif (io.Key(\"{}\"))\n\t{{\n", key);
			Value(field.FieldType, scope $"this.{field.Name}" , code, 0, scope $"{owner.GetFullName(.. scope .())}.{field.Name}");
			code.Append("\t}\n");
		}
		code.Append("}\n");
		if (isComponent)
			code.Append("public override bool HasSavedFields => true;\n");
		Compiler.EmitTypeBody(owner, code);
		if (!isComponent && !isAsset && !baseSaved)
			Compiler.EmitAddInterface(owner, typeof(ISaveable));
	}

	[Comptime]
	static bool IsLeaf(Type t)
	{
		return t == typeof(bool) || t == typeof(int8) || t == typeof(int16) || t == typeof(int32) || t == typeof(int64) || t == typeof(int) ||
			t == typeof(uint8) || t == typeof(uint16) || t == typeof(uint32) || t == typeof(uint64) || t == typeof(uint) ||
			t == typeof(char8) || t == typeof(char16) || t == typeof(char32) || t == typeof(float) || t == typeof(double) ||
			t == typeof(String) || t == typeof(Vector2) || t == typeof(Vector3) || t == typeof(Vector4) || t == typeof(Int3) ||
			t == typeof(Quaternion) || t == typeof(Color) || t == typeof(Matrix4) || t == typeof(GameObject) || t == typeof(Transform);
	}

	/// Whether loading should delete the objects a collection of t held: objects it owns, not scene objects.
	[Comptime]
	static bool Owned(Type t)
	{
		return t.IsObject && t != typeof(GameObject) && t != typeof(Transform) && !t.IsSubtypeOf(typeof(Component));
	}

	[Comptime]
	static void DeleteItems(Type element, StringView e, String code, int d)
	{
		if (Owned(element))
			code.AppendF("for (var __x{0} in {1}) delete __x{0};\n", d, e);
	}

	/// Code that reads or writes the value expression e of type t. d numbers the locals of nested collections.
	[Comptime]
	static void Value(Type t, StringView e, String code, int d, StringView fieldName)
	{
		if (IsLeaf(t))
		{
			code.AppendF("io.Value(ref {});\n", e);
			return;
		}
		if (t.IsEnum)
		{
			code.AppendF("io.Enum(ref {});\n", e);
			return;
		}
		if (t.IsObject && t.IsSubtypeOf(typeof(Component)))
		{
			code.AppendF("io.Component(ref {});\n", e);
			return;
		}
		if (let sized = t as SizedArrayType)
		{
			let count = sized.ElementCount;
			code.AppendF("io.BeginList({0});\nfor (int __i{1} < {0})\n{{\nif (!io.Item()) break;\n", count, d);
			Value(sized.UnderlyingType, scope $"{e}[__i{d}]" , code, d + 1, fieldName);
			code.Append("}\nio.EndList();\n");
			return;
		}
		if (let generic = t as SpecializedGenericType)
		{
			let unspecialized = generic.UnspecializedType;
			if (t is ArrayType)
			{
				let element = generic.GetGenericArg(0);
				let rank = unspecialized == typeof(Array4<>) ? 4 : (unspecialized == typeof(Array3<>) ? 3 : (unspecialized == typeof(Array2<>) ? 2 : 1));
				if (rank <= 1)
					ArrayValue(element, e, code, d, fieldName);
				else
					MultiArrayValue(element, rank, e, code, d, fieldName);
				return;
			}
			if (unspecialized == typeof(List<>))
			{
				ListValue(generic.GetGenericArg(0), e, code, d, fieldName);
				return;
			}
			if (unspecialized == typeof(Queue<>) || unspecialized == typeof(HashSet<>) || unspecialized == typeof(LinkedList<>))
			{
				let add = unspecialized == typeof(LinkedList<>) ? "AddLast" : "Add";
				CollectionValue(generic.GetGenericArg(0), add, e, code, d, fieldName);
				return;
			}
			if (unspecialized == typeof(Dictionary<,>))
			{
				DictionaryValue(generic.GetGenericArg(0), generic.GetGenericArg(1), e, code, d, fieldName);
				return;
			}
		}
		if (HasSaved(t))
		{
			if (t.IsValueType)
				code.AppendF("if (io.BeginObject()) {}.SaveFields(io);\nio.EndObject();\n", e);
			else
				code.AppendF("if (io.BeginObject({0} != null))\n{{\nif ({0} == null) {0} = new .();\n{0}.SaveFields(io);\n}}\nio.EndObject();\n", e);
			return;
		}
		Runtime.FatalError(scope $"[Saved] cannot keep {fieldName}: values of type {t.GetFullName(.. scope .())} cannot be saved. Mark the fields of that type [Saved], or save something it is made from.");
	}

	/// T[]: [items], or null.
	[Comptime]
	static void ArrayValue(Type element, StringView e, String code, int d, StringView fieldName)
	{
		code.AppendF("{{\nint __n{0} = io.BeginList({1} == null ? -1 : {1}.Count);\n", d, e);
		code.AppendF("if (io.Reading && __n{0} == -1 && {1} != null)\n{{\n", d, e);
		DeleteItems(element, e, code, d);
		code.AppendF("DeleteAndNullify!({});\n}}\n", e);
		code.AppendF("else if (io.Reading && __n{0} >= 0 && ({1} == null || {1}.Count != __n{0}))\n{{\n", d, e);
		code.AppendF("if ({} != null)\n{{\n", e);
		DeleteItems(element, e, code, d);
		code.AppendF("delete {0};\n}}\n{0} = new .[__n{1}];\n}}\n", e, d);
		code.AppendF("if (__n{0} >= 0 && {1} != null)\n{{\nfor (int __i{0} < {1}.Count)\n{{\nif (!io.Item()) break;\n", d, e);
		Value(element, scope $"{e}[__i{d}]" , code, d + 1, fieldName);
		code.Append("}\n}\nio.EndList();\n}\n");
	}

	/// T[,] and up: [ [lengths], [items row by row] ], or null.
	[Comptime]
	static void MultiArrayValue(Type element, int rank, StringView e, String code, int d, StringView fieldName)
	{
		code.AppendF("{{\nint __n{0} = io.BeginList({1} == null ? -1 : 2);\n", d, e);
		code.AppendF("if (__n{0} >= 0)\n{{\n", d);
		for (int r < rank)
			code.AppendF("int __a{0}_{1} = {2} == null ? 0 : {2}.GetLength({1});\n", d, r, e);
		code.AppendF("if (io.Item())\n{{\nio.BeginList({});\n", rank);
		for (int r < rank)
			code.AppendF("if (io.Item()) io.Value(ref __a{0}_{1});\n", d, r);
		code.Append("io.EndList();\n}\n");
		let lengths = scope String();
		let mismatch = scope String();
		for (int r < rank)
		{
			if (r > 0)
			{
				lengths.Append(", ");
				mismatch.Append(" || ");
			}
			lengths.AppendF("__a{0}_{1}", d, r);
			mismatch.AppendF("{0}.GetLength({1}) != __a{2}_{1}", e, r, d);
		}
		code.AppendF("if (io.Reading && ({0} == null || {1}))\n{{\nif ({0} != null)\n{{\n", e, mismatch);
		DeleteItems(element, e, code, d);
		code.AppendF("delete {0};\n}}\n{0} = new .[{1}];\n}}\n", e, lengths);
		code.AppendF("if (io.Item() && {0} != null)\n{{\nio.BeginList({0}.Count);\n", e);
		let indexes = scope String();
		for (int r < rank)
		{
			code.AppendF("for (int __i{0}_{1} < __a{0}_{1})\n", d, r);
			if (r > 0)
				indexes.Append(", ");
			indexes.AppendF("__i{0}_{1}", d, r);
		}
		code.Append("{\nif (!io.Item()) break;\n");
		Value(element, scope $"{e}[{indexes}]" , code, d + 1, fieldName);
		code.Append("}\nio.EndList();\n}\n}\n");
		code.AppendF("else if (io.Reading && __n{0} == -1 && {1} != null)\n{{\n", d, e);
		DeleteItems(element, e, code, d);
		code.AppendF("DeleteAndNullify!({});\n}}\nio.EndList();\n}}\n", e);
	}

	/// List<T>: [items], or null.
	[Comptime]
	static void ListValue(Type element, StringView e, String code, int d, StringView fieldName)
	{
		code.AppendF("{{\nint __n{0} = io.BeginList({1} == null ? -1 : {1}.Count);\n", d, e);
		code.AppendF("if (io.Reading && __n{0} >= -1)\n{{\nif ({1} == null && __n{0} >= 0) {1} = new .();\nif ({1} != null)\n{{\n", d, e);
		DeleteItems(element, e, code, d);
		code.AppendF("{0}.Clear();\nfor (int __k{1} < __n{1}) {0}.Add(default);\n}}\n}}\n", e, d);
		code.AppendF("if (__n{0} >= 0 && {1} != null)\n{{\nfor (int __i{0} < {1}.Count)\n{{\nif (!io.Item()) break;\n", d, e);
		Value(element, scope $"{e}[__i{d}]" , code, d + 1, fieldName);
		code.Append("}\n}\nio.EndList();\n}\n");
	}

	/// Queue<T>, HashSet<T> and LinkedList<T>: [items] in their own order, or null. `add` is how an item goes in.
	[Comptime]
	static void CollectionValue(Type element, StringView add, StringView e, String code, int d, StringView fieldName)
	{
		code.AppendF("{{\nint __n{0} = io.BeginList({1} == null ? -1 : {1}.Count);\n", d, e);
		code.AppendF("if (io.Writing && __n{0} >= 0)\n{{\nfor (var __v{0} in {1})\n{{\nio.Item();\nvar __t{0} = __v{0};\n", d, e);
		Value(element, scope $"__t{d}" , code, d + 1, fieldName);
		code.Append("}\n}\n");
		code.AppendF("else if (io.Reading && __n{0} >= -1)\n{{\nif ({1} == null && __n{0} >= 0) {1} = new .();\nif ({1} != null)\n{{\n", d, e);
		DeleteItems(element, e, code, d);
		code.AppendF("{0}.Clear();\nfor (int __i{1} < __n{1})\n{{\nif (!io.Item()) break;\ncomptype({2}) __t{1} = default;\n", e, d, (int)element.TypeId);
		Value(element, scope $"__t{d}" , code, d + 1, fieldName);
		code.AppendF("{0}.{1}(__t{2});\n}}\n}}\n}}\nio.EndList();\n}}\n", e, add, d);
	}

	/// Dictionary<K, V>: [ [key, value], ... ], or null.
	[Comptime]
	static void DictionaryValue(Type keyType, Type valueType, StringView e, String code, int d, StringView fieldName)
	{
		code.AppendF("{{\nint __n{0} = io.BeginList({1} == null ? -1 : {1}.Count);\n", d, e);
		code.AppendF("if (io.Writing && __n{0} >= 0)\n{{\nfor (var __kv{0} in {1})\n{{\nio.Item();\nio.BeginList(2);\nio.Item();\nvar __k{0} = __kv{0}.key;\n", d, e);
		Value(keyType, scope $"__k{d}" , code, d + 1, fieldName);
		code.AppendF("io.Item();\nvar __v{0} = __kv{0}.value;\n", d);
		Value(valueType, scope $"__v{d}" , code, d + 1, fieldName);
		code.Append("io.EndList();\n}\n}\n");
		code.AppendF("else if (io.Reading && __n{0} >= -1)\n{{\nif ({1} == null && __n{0} >= 0) {1} = new .();\nif ({1} != null)\n{{\n", d, e);
		if (Owned(keyType) || Owned(valueType))
		{
			code.AppendF("for (var __x{0} in {1})\n{{\n", d, e);
			if (Owned(keyType))
				code.AppendF("delete __x{}.key;\n", d);
			if (Owned(valueType))
				code.AppendF("delete __x{}.value;\n", d);
			code.Append("}\n");
		}
		code.AppendF("{0}.Clear();\nfor (int __i{1} < __n{1})\n{{\nif (!io.Item()) break;\ncomptype({2}) __k{1} = default;\ncomptype({3}) __v{1} = default;\n", e, d, (int)keyType.TypeId, (int)valueType.TypeId);
		code.Append("if (io.BeginList(2) >= 0)\n{\nif (io.Item())\n{\n");
		Value(keyType, scope $"__k{d}" , code, d + 1, fieldName);
		code.Append("}\nif (io.Item())\n{\n");
		Value(valueType, scope $"__v{d}" , code, d + 1, fieldName);
		code.AppendF("}}\n}}\nio.EndList();\n{0}[__k{1}] = __v{1};\n}}\n}}\n}}\nio.EndList();\n}}\n", e, d);
	}
}
