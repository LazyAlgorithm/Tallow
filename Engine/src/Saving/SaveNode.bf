using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// One value in saved data: a number, text, a list, or an object of named values. A save is a tree of these, kept
/// apart from the engine's memory layout, so that a save written by an older version of a game still loads: a field
/// the save does not have keeps its default, and a saved value with no field left to go into is skipped.
///
/// `ToBytes` and `FromBytes` give the compact form that saves are kept in (with a checksum, so a damaged save is
/// refused rather than half loaded); `ToText` and `FromText` a readable one (JSON) for looking at or editing by hand.
class SaveNode
{
	public enum Kind : uint8
	{
		Null,
		Bool,
		Int,
		Float,
		String,
		List,
		Object
	}

	public Kind kind;
	public int64 integer;
	public double number;
	public String text ~ delete _;
	/// List items, or an object's values in the order they were written.
	public List<SaveNode> items ~ DeleteContainerAndItems!(_);
	/// An object's names, matching items.
	public List<String> keys ~ DeleteContainerAndItems!(_);

	public this(Kind kind = .Null)
	{
		this.kind = kind;
		if (kind == .List || kind == .Object)
			items = new .();
		if (kind == .Object)
			keys = new .();
		if (kind == .String)
			text = new .();
	}

	public bool IsNull => kind == .Null;
	public int Count => items != null ? items.Count : 0;

	/// An object's value by name, or null.
	public SaveNode this[StringView key]
	{
		get
		{
			if (keys == null)
				return null;
			for (int i < keys.Count)
			{
				if (keys[i] == key)
					return items[i];
			}
			return null;
		}
	}

	/// Adds a value to an object, replacing one already under that name.
	public void Set(StringView key, SaveNode value)
	{
		for (int i < keys.Count)
		{
			if (keys[i] == key)
			{
				delete items[i];
				items[i] = value;
				return;
			}
		}
		keys.Add(new String(key));
		items.Add(value);
	}

	/// Takes a value out of an object without deleting it, or null.
	public SaveNode Take(StringView key)
	{
		if (keys == null)
			return null;
		for (int i < keys.Count)
		{
			if (keys[i] == key)
			{
				let node = items[i];
				delete keys[i];
				keys.RemoveAt(i);
				items.RemoveAt(i);
				return node;
			}
		}
		return null;
	}

	public double AsNumber => kind == .Float ? number : (kind == .Int ? (double)integer : (kind == .Bool ? integer : 0));
	public int64 AsInteger => kind == .Int || kind == .Bool ? integer : (kind == .Float ? (int64)Math.Round(number) : 0);

	public static SaveNode MakeInt(int64 value)
	{
		let node = new SaveNode(.Int);
		node.integer = value;
		return node;
	}

	public static SaveNode MakeFloat(double value)
	{
		let node = new SaveNode(.Float);
		node.number = value;
		return node;
	}

	public static SaveNode MakeBool(bool value)
	{
		let node = new SaveNode(.Bool);
		node.integer = value ? 1 : 0;
		return node;
	}

	public static SaveNode MakeString(StringView value)
	{
		let node = new SaveNode(.String);
		node.text.Set(value);
		return node;
	}

	public SaveNode Clone()
	{
		let copy = new SaveNode(kind);
		copy.integer = integer;
		copy.number = number;
		if (text != null)
			copy.text.Set(text);
		if (items != null)
		{
			for (int i < items.Count)
			{
				copy.items.Add(items[i].Clone());
				if (keys != null)
					copy.keys.Add(new String(keys[i]));
			}
		}
		return copy;
	}

	// ---- bytes ----

	const uint32 Magic = 0x56415354; // "TSAV"
	const int32 FormatVersion = 1;

	/// The compact form: a header, the tree, and a checksum of it.
	public void ToBytes(List<uint8> output)
	{
		let body = scope List<uint8>();
		Write(body);
		AddU32(output, Magic);
		AddU32(output, (uint32)FormatVersion);
		AddU32(output, (uint32)body.Count);
		AddU32(output, Crc32(body));
		output.AddRange(body);
	}

	/// Reads what ToBytes wrote. Null when the data is not a save, is from a newer format, or is damaged.
	public static SaveNode FromBytes(Span<uint8> data)
	{
		if (data.Length < 16 || U32(data, 0) != Magic || U32(data, 4) > (uint32)FormatVersion)
			return null;
		let size = (int)U32(data, 8);
		if (size != data.Length - 16)
			return null;
		let body = data.Slice(16, size);
		if (Crc32(body) != U32(data, 12))
			return null;
		int at = 0;
		let node = Read(body, ref at, 0);
		if (node == null || at != body.Length)
		{
			delete node;
			return null;
		}
		return node;
	}

	void Write(List<uint8> output)
	{
		output.Add((uint8)kind);
		switch (kind)
		{
		case .Null:
		case .Bool: output.Add(integer != 0 ? 1 : 0);
		case .Int: AddVarInt(output, (uint64)((integer << 1) ^ (integer >> 63)));
		case .Float:
			// A value that a float holds exactly is stored in four bytes.
			let single = (float)number;
			if ((double)single == number)
			{
				output[output.Count - 1] = 0x80 | (uint8)kind;
				var bits = single;
				output.AddRange(Span<uint8>((uint8*)&bits, 4));
			}
			else
			{
				var bits = number;
				output.AddRange(Span<uint8>((uint8*)&bits, 8));
			}
		case .String:
			AddVarInt(output, (uint64)text.Length);
			output.AddRange(Span<uint8>((uint8*)text.Ptr, text.Length));
		case .List,.Object:
			AddVarInt(output, (uint64)items.Count);
			for (int i < items.Count)
			{
				if (kind == .Object)
				{
					AddVarInt(output, (uint64)keys[i].Length);
					output.AddRange(Span<uint8>((uint8*)keys[i].Ptr, keys[i].Length));
				}
				items[i].Write(output);
			}
		}
	}

	static SaveNode Read(Span<uint8> data, ref int at, int depth)
	{
		if (at >= data.Length || depth > 256)
			return null;
		let tag = data[at++];
		let kind = (Kind)(tag & 0x7F);
		switch (kind)
		{
		case .Null:
			return new SaveNode(.Null);
		case .Bool:
			if (at >= data.Length) return null;
			return MakeBool(data[at++] != 0);
		case .Int:
			uint64 zig;
			if (!ReadVarInt(data, ref at, out zig)) return null;
			return MakeInt((int64)(zig >> 1) ^ -(int64)(zig & 1));
		case .Float:
			if ((tag & 0x80) != 0)
			{
				if (at + 4 > data.Length) return null;
				float value = 0;
				Internal.MemCpy(&value, data.Ptr + at, 4);
				at += 4;
				return MakeFloat(value);
			}
			if (at + 8 > data.Length) return null;
			double value = 0;
			Internal.MemCpy(&value, data.Ptr + at, 8);
			at += 8;
			return MakeFloat(value);
		case .String:
			uint64 length;
			if (!ReadVarInt(data, ref at, out length) || length > (uint64)(data.Length - at)) return null;
			let node = MakeString(StringView((char8*)data.Ptr + at, (int)length));
			at += (int)length;
			return node;
		case .List,.Object:
			uint64 count;
			if (!ReadVarInt(data, ref at, out count) || count > (uint64)(data.Length - at)) return null;
			let node = new SaveNode(kind);
			for (uint64 i < count)
			{
				if (kind == .Object)
				{
					uint64 length;
					if (!ReadVarInt(data, ref at, out length) || length > (uint64)(data.Length - at))
					{
						delete node;
						return null;
					}
					node.keys.Add(new String(StringView((char8*)data.Ptr + at, (int)length)));
					at += (int)length;
				}
				let item = Read(data, ref at, depth + 1);
				if (item == null)
				{
					delete node;
					return null;
				}
				node.items.Add(item);
			}
			return node;
		default:
			return null;
		}
	}

	static void AddU32(List<uint8> output, uint32 value)
	{
		for (int i < 4)
			output.Add((uint8)(value >> (i * 8)));
	}

	static uint32 U32(Span<uint8> data, int at) => (uint32)data[at] | ((uint32)data[at + 1] << 8) | ((uint32)data[at + 2] << 16) | ((uint32)data[at + 3] << 24);

	static void AddVarInt(List<uint8> output, uint64 value)
	{
		var value;
		while (value >= 0x80)
		{
			output.Add((uint8)(value | 0x80));
			value >>= 7;
		}
		output.Add((uint8)value);
	}

	static bool ReadVarInt(Span<uint8> data, ref int at, out uint64 value)
	{
		value = 0;
		for (int shift = 0; shift < 64; shift += 7)
		{
			if (at >= data.Length)
				return false;
			let b = data[at++];
			value |= (uint64)(b & 0x7F) << shift;
			if ((b & 0x80) == 0)
				return true;
		}
		return false;
	}

	static uint32 Crc32(Span<uint8> data)
	{
		uint32 crc = 0xFFFFFFFF;
		for (let b in data)
		{
			crc ^= b;
			for (int k < 8)
				crc = (crc >> 1) ^ (0xEDB88320 & (uint32)(-(int32)(crc & 1)));
		}
		return ~crc;
	}

	// ---- text (JSON) ----

	/// A readable form. Objects become JSON objects, lists arrays; whole numbers are written without a point and
	/// fractions with one, so reading the text back gives the same kinds.
	public void ToText(String output, bool indent = true) => WriteText(output, indent ? 0 : -1);

	void WriteText(String output, int depth)
	{
		void NewLine(int level)
		{
			if (depth < 0)
				return;
			output.Append('\n');
			for (int i < level)
				output.Append("  ");
		}
		switch (kind)
		{
		case .Null: output.Append("null");
		case .Bool: output.Append(integer != 0 ? "true" : "false");
		case .Int: output.AppendF("{}", integer);
		case .Float:
			if (number.IsNaN || number.IsInfinity)
				output.Append(number.IsNaN ? "\"NaN\"" : (number > 0 ? "\"Infinity\"" : "\"-Infinity\""));
			else
			{
				let start = output.Length;
				number.ToString(output, "R", null);
				let written = StringView(output, start);
				if (!written.Contains('.') && !written.Contains('E') && !written.Contains('e'))
					output.Append(".0");
			}
		case .String: Quote(output, text);
		case .List:
			output.Append('[');
			for (int i < items.Count)
			{
				if (i > 0)
					output.Append(',');
				NewLine(depth + 1);
				items[i].WriteText(output, depth < 0 ? -1 : depth + 1);
			}
			if (items.Count > 0)
				NewLine(depth);
			output.Append(']');
		case .Object:
			output.Append('{');
			for (int i < items.Count)
			{
				if (i > 0)
					output.Append(',');
				NewLine(depth + 1);
				Quote(output, keys[i]);
				output.Append(depth < 0 ? ":" : ": ");
				items[i].WriteText(output, depth < 0 ? -1 : depth + 1);
			}
			if (items.Count > 0)
				NewLine(depth);
			output.Append('}');
		}
	}

	static void Quote(String output, StringView text)
	{
		output.Append('"');
		for (let c in text.RawChars)
		{
			switch (c)
			{
			case '"': output.Append("\\\"");
			case '\\': output.Append("\\\\");
			case '\n': output.Append("\\n");
			case '\r': output.Append("\\r");
			case '\t': output.Append("\\t");
			default:
				if ((uint8)c < 0x20)
					output.AppendF("\\u{0:X4}", (int)(uint8)c);
				else
					output.Append(c);
			}
		}
		output.Append('"');
	}

	/// Reads what ToText wrote (or any JSON). Null if it is not valid.
	public static SaveNode FromText(StringView text)
	{
		int at = 0;
		let node = ParseValue(text, ref at, 0);
		SkipSpace(text, ref at);
		if (node != null && at != text.Length)
		{
			delete node;
			return null;
		}
		return node;
	}

	static void SkipSpace(StringView text, ref int at)
	{
		while (at < text.Length && (text[at] == ' ' || text[at] == '\n' || text[at] == '\r' || text[at] == '\t'))
			at++;
	}

	static bool ParseString(StringView text, ref int at, String output)
	{
		if (at >= text.Length || text[at] != '"')
			return false;
		at++;
		while (at < text.Length)
		{
			let c = text[at++];
			if (c == '"')
				return true;
			if (c != '\\')
			{
				output.Append(c);
				continue;
			}
			if (at >= text.Length)
				return false;
			let e = text[at++];
			switch (e)
			{
			case 'n': output.Append('\n');
			case 'r': output.Append('\r');
			case 't': output.Append('\t');
			case 'b': output.Append('\b');
			case 'f': output.Append('\f');
			case 'u':
				if (at + 4 > text.Length)
					return false;
				if (!(uint32.Parse(text.Substring(at, 4), .HexNumber) case .Ok(let code)))
					return false;
				at += 4;
				output.Append((char32)code);
			default: output.Append(e);
			}
		}
		return false;
	}

	/// The deepest lists and objects may go inside each other, so that a damaged file cannot exhaust the stack.
	const int MaxDepth = 256;

	static SaveNode ParseValue(StringView text, ref int at, int depth)
	{
		SkipSpace(text, ref at);
		if (at >= text.Length || depth > MaxDepth)
			return null;
		let c = text[at];
		if (c == '{' || c == '[')
			return ParseContainer(text, ref at, depth, c == '{');
		if (c == '"')
			return ParseText(text, ref at);
		if (text.Substring(at).StartsWith("true"))
		{
			at += 4;
			return MakeBool(true);
		}
		if (text.Substring(at).StartsWith("false"))
		{
			at += 5;
			return MakeBool(false);
		}
		if (text.Substring(at).StartsWith("null"))
		{
			at += 4;
			return new SaveNode(.Null);
		}
		return ParseNumber(text, ref at);
	}

	/// An object `{"key": value, ...}` or a list `[value, ...]`, from its opening bracket. Null if it is malformed.
	static SaveNode ParseContainer(StringView text, ref int at, int depth, bool isObject)
	{
		let close = isObject ? '}' : ']';
		let node = new SaveNode(isObject ? .Object : .List);
		at++;
		SkipSpace(text, ref at);
		if (at < text.Length && text[at] == close)
		{
			at++;
			return node;
		}
		while (true)
		{
			SkipSpace(text, ref at);
			if (isObject && !ParseKey(text, ref at, node))
				break;
			let item = ParseValue(text, ref at, depth + 1);
			if (item == null)
				break;
			node.items.Add(item);
			SkipSpace(text, ref at);
			if (at >= text.Length)
				break;
			if (text[at] == ',')
			{
				at++;
				continue;
			}
			if (text[at] == close)
			{
				at++;
				return node;
			}
			break;
		}
		delete node;
		return null;
	}

	/// An object's `"key":`, added to its keys.
	static bool ParseKey(StringView text, ref int at, SaveNode node)
	{
		let key = new String();
		if (!ParseString(text, ref at, key))
		{
			delete key;
			return false;
		}
		SkipSpace(text, ref at);
		if (at >= text.Length || text[at] != ':')
		{
			delete key;
			return false;
		}
		at++;
		node.keys.Add(key);
		return true;
	}

	/// A string; one of the numbers JSON cannot write ("NaN", "Infinity", "-Infinity"), written as text, is read back as that number.
	static SaveNode ParseText(StringView text, ref int at)
	{
		let node = new SaveNode(.String);
		if (!ParseString(text, ref at, node.text))
		{
			delete node;
			return null;
		}
		if (node.text == "NaN" || node.text == "Infinity" || node.text == "-Infinity")
		{
			let value = node.text == "NaN" ? double.NaN : (node.text == "Infinity" ? double.PositiveInfinity : double.NegativeInfinity);
			delete node;
			return MakeFloat(value);
		}
		return node;
	}

	/// A whole number, or (with a point or an exponent) a floating-point one.
	static SaveNode ParseNumber(StringView text, ref int at)
	{
		let start = at;
		var fraction = false;
		while (at < text.Length && (text[at].IsDigit || text[at] == '-' || text[at] == '+' || text[at] == '.' || text[at] == 'e' || text[at] == 'E'))
		{
			if (text[at] == '.' || text[at] == 'e' || text[at] == 'E')
				fraction = true;
			at++;
		}
		let digits = text.Substring(start, at - start);
		if (digits.IsEmpty)
			return null;
		if (!fraction)
		{
			if (int64.Parse(digits) case .Ok(let value))
				return MakeInt(value);
			return null;
		}
		if (double.Parse(digits) case .Ok(let value))
			return MakeFloat(value);
		return null;
	}
}
