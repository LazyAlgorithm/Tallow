using System;
using System.Collections;

namespace Tallow;

/// Built-in (Beef) components for C# scripts by type name ("Tallow.Light"): add one, and read or write its
/// Inspector fields as scene-file text, as a scene line does. Tallow.API's NativeComponent and the typed wrappers
/// (Light, MeshRenderer...) sit on this. Object references and lists are not reachable this way.
[CSharpExpose]
static class CSharpNativeComponents
{
	/// The component's fields, or false when the object or the component is missing. validate: what to call after
	/// a change (OnValidate, as the Inspector does).
	static bool Fields(uint64 session, uint64 entity, StringView typeName, List<FieldRef> fields, out Component component,
		out HandleComponents.Info handle, out GameObject obj)
	{
		component = null;
		handle = null;
		obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || typeName.IsEmpty)
			return false;
		if (let info = HandleComponents.Find(typeName))
		{
			if (!obj.Scene.World.Has(obj.Entity, info.index))
				return false;
			handle = info;
			HandleComponents.GetFields(obj, info, fields);
			return true;
		}
		let info = ComponentRegistry.Find(typeName);
		if (info == null || info.type == typeof(CSharpBehaviour))
			return false;
		for (let candidate in obj.Components)
		{
			if (candidate.GetType() == info.type)
			{
				component = candidate;
				ComponentRegistry.GetFields(candidate, fields);
				return true;
			}
		}
		return false;
	}

	/// Adds a built-in component (or finds the one there). False for an unknown type or a C# script.
	[CSharpExpose]
	public static bool Add(uint64 session, uint64 entity, StringView typeName)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || typeName.IsEmpty)
			return false;
		if (let handle = HandleComponents.Find(typeName))
		{
			HandleComponents.Add(obj, handle);
			return true;
		}
		let info = ComponentRegistry.Find(typeName);
		if (info == null || info.type == typeof(CSharpBehaviour))
			return false;
		for (let candidate in obj.Components)
		{
			if (candidate.GetType() == info.type)
				return true;
		}
		return obj.AddComponent(info.type) != null;
	}

	[CSharpExpose]
	public static bool Has(uint64 session, uint64 entity, StringView typeName) =>
		Fields(session, entity, typeName, scope .(), ?, ?, ?);

	/// Sets a field from scene-file text ("0.5", "1 2 3", "Point", "\"text\""). False when the object, component
	/// or field is missing, the field is a reference or a list, or the text does not parse.
	[CSharpExpose]
	public static bool SetField(uint64 session, uint64 entity, StringView typeName, StringView field, StringView value)
	{
		let fields = scope List<FieldRef>();
		if (!Fields(session, entity, typeName, fields, let component, let handle, let obj))
			return false;
		for (let candidate in fields)
		{
			if (candidate.name != field)
				continue;
			if (candidate.kind == .ObjectReference || candidate.kind == .List || candidate.kind == .Array)
				return false;
			let tokens = scope List<StringView>();
			let storage = scope List<String>();
			defer { for (let text in storage) delete text; }
			SceneSerializer.Tokenize(value, tokens, storage);
			if (tokens.IsEmpty)
				return false;
			SceneSerializer.ReadValue(candidate, Span<StringView>(tokens.Ptr, tokens.Count));
			if (component != null)
				component.OnValidate();
			else if (handle.onValidate != null)
				handle.onValidate(obj);
			return true;
		}
		return false;
	}

	/// A field as scene-file text (UTF-8 into buffer); returns its full length, -1 when it is missing.
	[CSharpExpose]
	public static int32 CopyField(uint64 session, uint64 entity, StringView typeName, StringView field, Span<uint8> buffer)
	{
		let fields = scope List<FieldRef>();
		if (!Fields(session, entity, typeName, fields, ?, ?, ?))
			return -1;
		for (let candidate in fields)
		{
			if (candidate.name != field || candidate.kind == .ObjectReference || candidate.kind == .List || candidate.kind == .Array)
				continue;
			let text = scope String();
			SceneSerializer.WriteValue(candidate, text);
			let count = Math.Min(text.Length, buffer.Length);
			for (int i < count)
				buffer[i] = (uint8)text[i];
			return (int32)text.Length;
		}
		return -1;
	}
}
