using System;

namespace Tallow;

/// Width-aware numeric access shared by inspector widgets and scene/reload serialization.
static class FieldNumbers
{
	public static Type Storage(Type type) => type.IsEnum || type.IsTypedPrimitive ? type.UnderlyingType : type;
	public static bool Signed(FieldRef field) => Storage(field.type).IsSigned;
	public static int64 EnumValue(FieldRef field) => Signed(field) ? ReadSigned(field) : (int64)ReadUnsigned(field);
	public static uint64 ReadUnsigned(FieldRef field)
	{
		switch (field.type.Size)
		{
		case 1: return *(uint8*)field.ptr;
		case 2: return *(uint16*)field.ptr;
		case 4: return *(uint32*)field.ptr;
		case 8: return *(uint64*)field.ptr;
		default: return 0;
		}
	}

	public static int64 ReadSigned(FieldRef field)
	{
		switch (field.type.Size)
		{
		case 1: return *(int8*)field.ptr;
		case 2: return *(int16*)field.ptr;
		case 4: return *(int32*)field.ptr;
		case 8: return *(int64*)field.ptr;
		default: return 0;
		}
	}

	public static bool WriteSigned(FieldRef field, int64 value)
	{
		switch (field.type.Size)
		{
		case 1:
			if (value < int8.MinValue || value > int8.MaxValue) return false;
			*(int8*)field.ptr = (int8)value;
		case 2:
			if (value < int16.MinValue || value > int16.MaxValue) return false;
			*(int16*)field.ptr = (int16)value;
		case 4:
			if (value < int32.MinValue || value > int32.MaxValue) return false;
			*(int32*)field.ptr = (int32)value;
		case 8: *(int64*)field.ptr = value;
		default: return false;
		}
		return true;
	}

	public static bool WriteUnsigned(FieldRef field, uint64 value)
	{
		switch (field.type.Size)
		{
		case 1:
			if (value > uint8.MaxValue) return false;
			*(uint8*)field.ptr = (uint8)value;
		case 2:
			if (value > uint16.MaxValue) return false;
			*(uint16*)field.ptr = (uint16)value;
		case 4:
			if (value > uint32.MaxValue) return false;
			*(uint32*)field.ptr = (uint32)value;
		case 8: *(uint64*)field.ptr = value;
		default: return false;
		}
		return true;
	}

	public static void ReadText(FieldRef field, StringView text)
	{
		if (Signed(field))
		{
			if (int64.Parse(text) case .Ok(let value))
				WriteSigned(field, value);
		}
		else
		{
			if (uint64.Parse(text) case .Ok(let value))
				WriteUnsigned(field, value);
		}
	}

	/// ImGuiDataType integer values; widths are fixed independently of Beef's platform int.
	public static int32 ImGuiType(FieldRef field)
	{
		int32 unsigned = Signed(field) ? 0 : 1;
		switch (field.type.Size)
		{
		case 1: return unsigned;
		case 2: return 2 + unsigned;
		case 4: return 4 + unsigned;
		default: return 6 + unsigned;
		}
	}
}
