using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Writing into a game's String fields (the Inspector, scene loading, saves, networking, UI bindings).
///
/// A field given a text literal, `public String title = "Hello";`, holds the literal itself, which lives in the
/// program's read-only memory: changing it in place (Set, Clear, Append) crashes. Such a field is given a
/// writable copy of its own first, and the game is told once how to declare it so that it owns its text.
static class StringFields
{
	/// Copies made for fields that held literals. The class never deletes these (it did not allocate them), so
	/// they are kept here and freed with the program.
	static List<String> sCopies = new .() ~ DeleteContainerAndItems!(_);
	static HashSet<String> sWarned = new .() ~ DeleteContainerAndItems!(_);
	static Monitor sLock = new .() ~ delete _;

	/// The String in the field at `slot`, safe to change in place; null when the field is empty.
	/// `name` names the field in the one-time warning.
	public static String Writable(void* slot, StringView name = default)
	{
		let text = *(String*)slot;
		if (text == null || !IsReadOnly(Internal.UnsafeCastToPtr(text)))
			return text;
		let copy = new String(text);
		*(String*)slot = copy;
		using (sLock.Enter())
		{
			sCopies.Add(copy);
			let key = scope String(name.IsEmpty ? "(unnamed)" : name);
			if (!sWarned.Contains(key))
			{
				sWarned.Add(new String(key));
				Log.Warning(scope $"String field '{key}' was given a text literal, which cannot be changed. It now holds a copy. Declare it as: public String {key} = new .(\"{text}\") ~ delete _;");
			}
		}
		return copy;
	}

	/// The text of a String or SharedString field (FieldKind.String; type is the field's type).
	public static StringView Get(void* slot, Type type)
	{
		if (type == typeof(SharedString))
			return ((SharedString*)slot).View;
		let text = *(String*)slot;
		return text != null ? (StringView)text : default;
	}

	/// Sets a String or SharedString field (FieldKind.String; type is the field's type).
	public static void Set(void* slot, Type type, StringView value, StringView name = default)
	{
		if (type == typeof(SharedString))
			*(SharedString*)slot = value;
		else
			Set(slot, value, name);
	}

	/// Sets the field at `slot` to `value`, giving an empty field a new String.
	public static void Set(void* slot, StringView value, StringView name = default)
	{
		let text = Writable(slot, name);
		if (text != null)
			text.Set(value);
		else
			*(String*)slot = new String(value);
	}

#if BF_PLATFORM_WINDOWS
	[CLink, CallingConvention(.Stdcall)]
	static extern uint VirtualQuery(void* address, void* buffer, uint length);

	/// True when `address` is in memory the program cannot write to.
	public static bool IsReadOnly(void* address)
	{
		// MEMORY_BASIC_INFORMATION (64-bit): Protect is at byte 36.
		uint8[48] info = default;
		if (VirtualQuery(address, &info, 48) == 0)
			return false;
		let protect = *(uint32*)&info[36];
		const uint32 writable = 0x04 | 0x08 | 0x40 | 0x80; // READWRITE, WRITECOPY, EXECUTE_READWRITE, EXECUTE_WRITECOPY
		return (protect & writable) == 0;
	}

	#elif BF_PLATFORM_LINUX
	[CRepr]
	struct PhdrInfo
	{
		public uint address;
		public char8* name;
		public Phdr* headers;
		public uint16 count;
	}

	[CRepr]
	struct Phdr
	{
		public uint32 type;
		public uint32 flags;
		public uint64 offset;
		public uint64 virtualAddress;
		public uint64 physicalAddress;
		public uint64 fileSize;
		public uint64 memorySize;
		public uint64 align;
	}

	struct Query
	{
		public uint address;
		public bool readOnly;
	}

	[CLink]
	static extern int32 dl_iterate_phdr(function int32(PhdrInfo* info, uint size, void* data) callback, void* data);

	static int32 CheckImage(PhdrInfo* info, uint size, void* data)
	{
		let query = (Query*)data;
		for (int i < info.count)
		{
			let header = &info.headers[i];
			// A literal is in a loaded segment without write access, or in the part made read-only after
			// relocation (RELRO), where literals that hold pointers end up.
			let readOnly = (header.type == 1 && (header.flags & 2) == 0) || header.type == 0x6474e552;
			if (!readOnly)
				continue;
			let start = info.address + (uint)header.virtualAddress;
			if (query.address >= start && query.address < start + (uint)header.memorySize)
			{
				query.readOnly = true;
				return 1;
			}
		}
		return 0;
	}

	/// True when `address` is in a program or library image's read-only memory.
	public static bool IsReadOnly(void* address)
	{
		Query query = .() { address = (uint)address };
		dl_iterate_phdr( => CheckImage, &query);
		return query.readOnly;
	}
#else
	/// Not known on this system: fields are written as they are.
	public static bool IsReadOnly(void* address) => false;
#endif
}
