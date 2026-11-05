using System;
using System.Collections;
using System.Reflection;

namespace Tallow;

/// Lists and arrays in components' and data assets' fields: List<T>, T[] and fixed-size T[N], where T is anything a
/// field can hold on its own (numbers, bools, enums, vectors, colours, text, references to objects). They are saved
/// with the scene, shown in the Inspector (lists and T[] can be resized there, T[N] keeps its size), copied, and kept
/// across script reloads, like any other field.
///
/// Each element is reached as a FieldRef of its own (Element), so everything that reads or writes a single field
/// works on it unchanged. A List or T[] that is null is made when something is put in it; declare it with
/// `= new .() ~ delete _` (List) or `= new .[n] ~ delete _` (array) so that it is freed.
static class FieldLists
{
	static int sListItems = -1;
	static int sListSize = -1;
	static bool sListChecked;

	/// The element type of a List<T>, T[] or T[N]; an error for any other type.
	public static Result<Type> ElementOf(Type type)
	{
		if (type == null)
			return .Err;
		if (type.IsSizedArray)
			return (type as SizedArrayType).UnderlyingType;
		if (let generic = type as SpecializedGenericType)
		{
			if (type.IsArray && (type as ArrayType).[Friend]mRank == 1)
				return generic.GetGenericArg(0);
			if (generic.UnspecializedType == typeof(List<>) && ListLayoutKnown())
				return generic.GetGenericArg(0);
		}
		return .Err;
	}

	/// Where a List keeps its items pointer and its count, found once from a list whose contents are known. If the
	/// library's List ever changes so that these cannot be found, lists are left out of fields instead of read wrong.
	static bool ListLayoutKnown()
	{
		if (sListChecked)
			return sListItems >= 0;
		sListChecked = true;
		let probe = scope List<int32>() { 11, 22, 33 };
		let start = (uint8*)Internal.UnsafeCastToPtr(probe);
		for (int offset = 0; offset < 64; offset += sizeof(int))
		{
			if (*(void**)(start + offset) == probe.Ptr && *(int_cosize*)(start + offset + sizeof(int)) == 3)
			{
				sListItems = offset;
				sListSize = offset + sizeof(int);
				break;
			}
		}
		if (sListItems < 0)
			Log.Error("List fields are not supported with this version of the Beef library: their layout was not found.");
		return sListItems >= 0;
	}

	/// How far apart elements are in memory.
	static int Stride(FieldRef field) => field.elementType.IsObject ? sizeof(int) : field.elementType.Stride;

	/// The List or T[] object in the field (null when it has none); null for T[N].
	static Object Holder(FieldRef field) => field.type.IsSizedArray ? null : *(Object*)field.ptr;

	/// How many elements there are.
	public static int Count(FieldRef field)
	{
		if (field.type.IsSizedArray)
			return (field.type as SizedArrayType).ElementCount;
		let holder = Holder(field);
		if (holder == null)
			return 0;
		if (field.kind == .Array)
			return (holder as Array).Count;
		return *(int_cosize*)((uint8*)Internal.UnsafeCastToPtr(holder) + sListSize);
	}

	/// Where the first element is.
	static uint8* Data(FieldRef field)
	{
		if (field.type.IsSizedArray)
			return (uint8*)field.ptr;
		let holder = Holder(field);
		if (holder == null)
			return null;
		let start = (uint8*)Internal.UnsafeCastToPtr(holder);
		if (field.kind == .Array)
			return start + (field.type as ArrayType).[Friend]mElementsDataOffset;
		return *(uint8**)(start + sListItems);
	}

	/// Element `index` as a field of its own (its ptr is only good until the list is next resized).
	public static FieldRef Element(FieldRef field, int index)
	{
		var element = field;
		element.kind = field.elementKind;
		element.type = field.elementType;
		element.ptr = Data(field) + index * Stride(field);
		element.elementType = null;
		return element;
	}

	/// Replaces the List in the slot (a List<T> field of plain values, in a built-in component's data) with a copy of
	/// its own in made, an empty list of the same type, so the data owns its list (HandleComponents.OwnLists).
	public static void CloneList(void* slot, Object made)
	{
		let source = *(Object*)slot;
		*(Object*)slot = made;
		if (source == null || made == null || !ListLayoutKnown())
			return;
		let count = *(int_cosize*)((uint8*)Internal.UnsafeCastToPtr(source) + sListSize);
		if (count == 0)
			return;
		let element = (made.GetType() as SpecializedGenericType).GetGenericArg(0);
		let list = made as IList;
		let zero = scope uint8[Math.Max(element.Size, 1)]*;
		Internal.MemSet(zero, 0, Math.Max(element.Size, 1));
		for (int i < count)
		{
			var value = Variant.Create(element, zero);
			list.Add(value);
			value.Dispose();
		}
		let from = *(uint8**)((uint8*)Internal.UnsafeCastToPtr(source) + sListItems);
		let to = *(uint8**)((uint8*)Internal.UnsafeCastToPtr(made) + sListItems);
		Internal.MemCpy(to, from, count * element.Stride);
	}

	/// Frees the List in the slot and empties it.
	public static void FreeList(void* slot)
	{
		let list = *(Object*)slot;
		*(Object*)slot = null;
		delete list;
	}

	/// Whether elements can be added and removed (not for a fixed-size T[N]).
	public static bool CanResize(FieldRef field) => !field.type.IsSizedArray;

	/// Frees an element's text before the element goes (a literal's is not freed).
	static void ReleaseElement(FieldRef field, int index)
	{
		if (field.elementKind != .String)
			return;
		let slot = (String*)Element(field, index).ptr;
		if (*slot != null && !StringFields.IsReadOnly(Internal.UnsafeCastToPtr(*slot)))
			delete *slot;
		*slot = null;
	}

	/// Makes the List or array when the field has none.
	static Object Make(FieldRef field, int count)
	{
		Object made = null;
		if (field.kind == .Array)
		{
			if ((field.type as ArrayType).CreateObject((int32)count) case .Ok(let array))
				made = array;
		}
		else if (field.type.CreateObject() case .Ok(let list))
			made = list;
		if (made != null)
		{
			*(Object*)field.ptr = made;
			if (field.kind == .Array)
				Internal.MemSet(Data(field), 0, count * Stride(field));
		}
		return made;
	}

	/// Sets the number of elements: new ones are zero (empty text, no object), and those cut off are freed.
	public static bool Resize(FieldRef field, int countIn)
	{
		let count = Math.Max(countIn, 0);
		if (!CanResize(field))
			return false;
		let old = Count(field);
		if (count == old && (Holder(field) != null || count == 0))
			return false;
		if (Holder(field) == null && Make(field, field.kind == .Array ? count : 0) == null)
			return false;
		for (int i = count; i < old; i++)
			ReleaseElement(field, i);
		if (field.kind == .Array)
		{
			let previous = Holder(field);
			if ((previous as Array).Count == count)
				return true;
			let stride = Stride(field);
			let from = Data(field);
			Object made;
			if ((field.type as ArrayType).CreateObject((int32)count) case .Ok(let array))
				made = array;
			else
				return false;
			*(Object*)field.ptr = made;
			let to = Data(field);
			Internal.MemSet(to, 0, count * stride);
			Internal.MemCpy(to, from, Math.Min(old, count) * stride);
			// The elements now belong to the new array: the old one goes without its strings.
			delete previous;
			return true;
		}
		let list = Holder(field) as IList;
		if (list == null)
			return false;
		for (int i = old - 1; i >= count; i--)
			list.RemoveAt(i);
		if (count > old)
		{
			let size = Math.Max(field.elementType.Size, 1);
			let zero = scope uint8[size]*;
			Internal.MemSet(zero, 0, size);
			for (int i = old; i < count; i++)
			{
				var value = field.elementType.IsObject ? Variant() : Variant.Create(field.elementType, zero);
				list.Add(value);
				value.Dispose();
			}
		}
		return true;
	}

	/// Adds a copy of element `index` straight after it (or an empty element to an empty list).
	public static bool Duplicate(FieldRef field, int index)
	{
		let count = Count(field);
		if (!CanResize(field))
			return false;
		if (count == 0 || index < 0 || index >= count)
			return Resize(field, count + 1);
		let text = scope String();
		SceneSerializer.WriteValue(Element(field, index), text);
		Resize(field, count + 1);
		Move(field, count, index + 1);
		Assign(Element(field, index + 1), text);
		return true;
	}

	/// Removes element `index`.
	public static bool RemoveAt(FieldRef field, int index)
	{
		let count = Count(field);
		if (!CanResize(field) || index < 0 || index >= count)
			return false;
		Move(field, index, count - 1);
		return Resize(field, count - 1);
	}

	/// Moves element `from` to `to`, shifting those between.
	public static void Move(FieldRef field, int from, int to)
	{
		let count = Count(field);
		if (from == to || from < 0 || to < 0 || from >= count || to >= count)
			return;
		let stride = Stride(field);
		let data = Data(field);
		let held = scope uint8[stride]*;
		Internal.MemCpy(held, data + from * stride, stride);
		if (from < to)
			Internal.MemMove(data + from * stride, data + (from + 1) * stride, (to - from) * stride);
		else
			Internal.MemMove(data + (to + 1) * stride, data + to * stride, (from - to) * stride);
		Internal.MemCpy(data + to * stride, held, stride);
	}

	/// Sets an element from its saved text.
	static void Assign(FieldRef element, StringView text)
	{
		let tokens = scope List<StringView>();
		let storage = scope List<String>();
		SceneSerializer.Tokenize(text, tokens, storage);
		SceneSerializer.ReadValue(element, .(tokens.Ptr, tokens.Count));
		ClearAndDeleteItems!(storage);
	}

	/// How many words of saved text one element of a kind takes.
	public static int TokensPer(FieldKind kind)
	{
		switch (kind)
		{
		case .Vector2: return 2;
		case .Vector3,.Int3: return 3;
		case .Vector4,.Quaternion,.Color: return 4;
		case .Matrix4: return 16;
		case .ObjectReference: return 2;
		default: return 1;
		}
	}

	/// The saved text: the count, then each element as a field of its kind would be saved.
	public static void Write(FieldRef field, String text)
	{
		let count = Count(field);
		text.AppendF("{}", count);
		for (int i < count)
		{
			text.Append(' ');
			SceneSerializer.WriteValue(Element(field, i), text);
		}
	}

	/// Reads saved text (Write's). A fixed-size array keeps its size and reads what fits. With `references`, the
	/// elements' references are left there to be resolved once every object is loaded, instead of looked up now.
	public static void Read(FieldRef field, Span<StringView> tokens, List<(FieldRef field, uint32 id, int index)> references = null)
	{
		if (tokens.Length == 0)
			return;
		let saved = Math.Max(SceneSerializer.ParseInt(tokens[0]), 0);
		if (CanResize(field))
			Resize(field, saved);
		let per = TokensPer(field.elementKind);
		let count = Math.Min(Count(field), saved);
		for (int i < count)
		{
			let at = 1 + i * per;
			if (at + per > tokens.Length)
				break;
			let element = Element(field, i);
			if (references != null && field.elementKind == .ObjectReference)
				references.Add((element, (uint32)SceneSerializer.ParseInt(tokens[at]), SceneSerializer.ParseInt(tokens[at + 1])));
			else
				SceneSerializer.ReadValue(element, .(tokens.Ptr + at, per));
		}
	}

	/// Sets every reference element whose object is `going` (per Scene's own test) to null.
	public static void ClearReferences(FieldRef field, delegate bool(Object value) going)
	{
		if (field.elementKind != .ObjectReference)
			return;
		let count = Count(field);
		for (int i < count)
		{
			let slot = (Object*)Element(field, i).ptr;
			if (*slot != null && going(*slot))
				*slot = null;
		}
	}
}
