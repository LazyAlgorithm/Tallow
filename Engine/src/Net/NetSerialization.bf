using System;
using System.Collections;

namespace Tallow;

/// Growable little-endian message writer.
class NetWriter
{
	/// The bytes written so far.
	public List<uint8> Data = new .() ~ delete _;

	/// Starts again, empty.
	public void Clear() => Data.Clear();

	/// Writes a plain value (a number, a vector...) as its bytes.
	public void Write<T>(T value) where T : struct
	{
		var v = value;
		let start = Data.Count;
		Data.Count += sizeof(T);
		Internal.MemCpy(Data.Ptr + start, &v, sizeof(T));
	}

	/// A whole number in as few bytes as it needs: one byte below 128, two below 16384, and so on.
	public void WriteVarUInt(uint32 value)
	{
		var left = value;
		while (left >= 0x80)
		{
			Data.Add((uint8)(left | 0x80));
			left >>= 7;
		}
		Data.Add((uint8)left);
	}

	/// The low three bytes of a number between -8388608 and 8388607.
	public void Write24(int32 value)
	{
		Data.Add((uint8)value);
		Data.Add((uint8)(value >> 8));
		Data.Add((uint8)(value >> 16));
	}

	/// Writes text, its length first.
	public void WriteString(StringView text)
	{
		let length = (uint8)Math.Min(text.Length, 255);
		Data.Add(length);
		for (int i < length)
			Data.Add((uint8)text[i]);
	}
}

/// Bounds-checked message reader. After any failed read, Ok stays false and values are zero.
struct NetReader
{
	uint8* mData;
	int mLength;
	int mOffset;
	/// False once a read went past the end: what was read since then is not to be trusted.
	public bool Ok = true;
	/// The bytes being read, and how far into them the next read starts (to pass a message on as it came).
	public uint8* Start => mData;
	public int Position => mOffset;

	/// A reader over some received bytes.
	public this(uint8* data, int length)
	{
		mData = data;
		mLength = length;
		mOffset = 0;
	}

	/// Reads a plain value written with Write (default and Ok false past the end).
	public T Read<T>() mut where T : struct
	{
		T value = default;
		if (mOffset + sizeof(T) > mLength)
		{
			Ok = false;
			return value;
		}
		Internal.MemCpy(&value, mData + mOffset, sizeof(T));
		mOffset += sizeof(T);
		return value;
	}

	/// Reads a whole number written in as few bytes as it needs.
	public uint32 ReadVarUInt() mut
	{
		uint32 value = 0;
		for (int shift = 0; shift < 35; shift += 7)
		{
			let part = Read<uint8>();
			value |= (uint32)(part & 0x7F) << shift;
			if ((part & 0x80) == 0)
				return value;
		}
		Ok = false;
		return 0;
	}

	/// Reads a signed number written in three bytes.
	public int32 Read24() mut
	{
		let low = (uint32)Read<uint16>();
		let high = (uint32)Read<uint8>();
		// Shifted up and back down so that the sign comes with it.
		return (int32)((low | (high << 16)) << 8) >> 8;
	}

	/// Reads text written with WriteString.
	public void ReadString(String text) mut
	{
		let length = (int)Read<uint8>();
		if (mOffset + length > mLength)
		{
			Ok = false;
			return;
		}
		text.Append((char8*)mData + mOffset, length);
		mOffset += length;
	}
}

/// One tick of player intent. Sent from the owning client to the server, and replayed during prediction.
[CRepr]
struct NetInput
{
	/// Sideways movement, -1 (left) to 1 (right).
	public float moveX;
	/// Forward movement, -1 (back) to 1 (forward).
	public float moveZ;
	/// Which way the player looks, in degrees about the vertical.
	public float yaw;
	/// How far up or down the player looks, in degrees.
	public float pitch;
	/// Which buttons are held, one bit each.
	public uint32 buttons;

	/// Whether a button (0 to 31) is held.
	public bool GetButton(int index) => (buttons & ((uint32)1 << index)) != 0;
	/// Holds or lets go of a button (0 to 31).
	public void SetButton(int index, bool down) mut
	{
		if (down)
			buttons |= (uint32)1 << index;
		else
			buttons &= ~((uint32)1 << index);
	}
}

/// Packs what goes over the network every tick into few bytes: positions to about two millimetres, rotations to a
/// fraction of a degree, controls to nine bytes.
static class NetPack
{
	/// Steps per world unit in a packed position.
	public const float PositionScale = 512;
	const float PositionLimit = 8388607 / PositionScale;

	/// The rotation is a turn about the vertical alone, sent as one number.
	public const uint8 FlagYawOnly = 1;
	/// The position is too far from the origin to pack; it is sent as plain floats.
	public const uint8 FlagWide = 2;
	/// Everything, unpacked: for the machine that predicts this object and must compare exactly.
	public const uint8 FlagFull = 4;
	/// Position and rotation sent as plain floats.
	public const uint8 FlagExactTransform = 8;
	/// Position sent in fine steps (FinePositionScale).
	public const uint8 FlagFineTransform = 16;
	/// The body is resting.
	public const uint8 FlagSleeping = 32;
	/// A physics body the receiving machine simulates itself (see NetworkManager.PredictPhysics): position,
	/// rotation and both velocities as plain floats, for checking its prediction exactly.
	public const uint8 FlagPredicted = 64;
	/// 0.1 millimetre position steps in metre-based worlds. Outside +/-838m, use exact floats.
	public const float FinePositionScale = 10000;
	/// A body shown in the past with its motion (RemoteSnapshotFormat.QuantizedBody): position in MotionPositionScale
	/// steps (exact floats with FlagExactTransform), packed rotation, and both velocities.
	public const uint8 FlagMotion = 128;
	/// Position steps per unit in a motion record: about 15 micrometres in metre-based worlds, out to 128 units.
	public const float MotionPositionScale = 65536;

	/// Writes a body's motion record (FlagMotion); the caller may add FlagSleeping to its first byte.
	public static void WriteMotion(NetWriter writer, BodyState state)
	{
		let limit = 8388607 / MotionPositionScale;
		let position = state.position;
		if (position.x.IsFinite && position.y.IsFinite && position.z.IsFinite && Math.Abs(position.x) < limit && Math.Abs(position.y) < limit && Math.Abs(position.z) < limit)
		{
			writer.Write(FlagMotion);
			writer.Write24((int32)Math.Round(position.x * MotionPositionScale));
			writer.Write24((int32)Math.Round(position.y * MotionPositionScale));
			writer.Write24((int32)Math.Round(position.z * MotionPositionScale));
			writer.Write(PackRotation(state.rotation));
		}
		else
		{
			writer.Write((uint8)(FlagMotion | FlagExactTransform));
			writer.Write(position);
			writer.Write(state.rotation);
		}
		WriteScaledVector(writer, state.linearVelocity);
		WriteScaledVector(writer, state.angularVelocity);
	}

	/// Reads what WriteMotion wrote, with the flags it was written with.
	public static BodyState ReadMotion(ref NetReader reader, uint8 flags)
	{
		BodyState state = default;
		if ((flags & FlagExactTransform) != 0)
		{
			state.position = reader.Read<Vector3>();
			state.rotation = reader.Read<Quaternion>();
		}
		else
		{
			state.position = .(reader.Read24() / MotionPositionScale, reader.Read24() / MotionPositionScale, reader.Read24() / MotionPositionScale);
			state.rotation = UnpackRotation(reader.Read<uint32>());
		}
		state.linearVelocity = ReadScaledVector(ref reader);
		state.angularVelocity = ReadScaledVector(ref reader);
		return state;
	}

	/// A vector as a power-of-two scale shared by three 16-bit numbers (one byte when it is zero).
	static void WriteScaledVector(NetWriter writer, Vector3 vector)
	{
		let largest = Math.Max(Math.Abs(vector.x), Math.Max(Math.Abs(vector.y), Math.Abs(vector.z)));
		if (!largest.IsFinite || largest < 1.0e-7f)
		{
			writer.Write((int8) - 128);
			return;
		}
		let exponent = (int32)Math.Clamp(Math.Ceiling(Math.Log(largest) / Math.Log(2.0)), -100, 100);
		let scale = (float)(32767 / Math.Pow(2.0, exponent));
		writer.Write((int8)exponent);
		writer.Write((int16)Math.Clamp(Math.Round(vector.x * scale), -32767, 32767));
		writer.Write((int16)Math.Clamp(Math.Round(vector.y * scale), -32767, 32767));
		writer.Write((int16)Math.Clamp(Math.Round(vector.z * scale), -32767, 32767));
	}

	static Vector3 ReadScaledVector(ref NetReader reader)
	{
		let exponent = reader.Read<int8>();
		if (exponent == -128)
			return .Zero;
		let step = (float)(Math.Pow(2.0, exponent) / 32767);
		return .(reader.Read<int16>() * step, reader.Read<int16>() * step, reader.Read<int16>() * step);
	}

	/// Writes a position and rotation, packed small when quantized.
	public static void WriteTransform(NetWriter writer, Vector3 position, Quaternion rotation, bool quantized)
	{
		let limit = 8388607 / FinePositionScale;
		if (quantized && position.x.IsFinite && position.y.IsFinite && position.z.IsFinite && Math.Abs(position.x) < limit && Math.Abs(position.y) < limit && Math.Abs(position.z) < limit)
		{
			writer.Write(FlagFineTransform);
			writer.Write24((int32)Math.Round(position.x * FinePositionScale));
			writer.Write24((int32)Math.Round(position.y * FinePositionScale));
			writer.Write24((int32)Math.Round(position.z * FinePositionScale));
			writer.Write(PackRotation(rotation));
		}
		else
		{
			writer.Write(FlagExactTransform);
			writer.Write(position);
			writer.Write(rotation);
		}
	}

	/// Reads what WriteTransform wrote, with the flags it was written with.
	public static void ReadTransform(ref NetReader reader, uint8 flags, out Vector3 position, out Quaternion rotation)
	{
		if ((flags & FlagFineTransform) != 0)
		{
			position = .(reader.Read24() / FinePositionScale, reader.Read24() / FinePositionScale, reader.Read24() / FinePositionScale);
			rotation = UnpackRotation(reader.Read<uint32>());
		}
		else
		{
			position = reader.Read<Vector3>();
			rotation = reader.Read<Quaternion>();
		}
	}

	/// Writes a predicted body's record: FlagPredicted (with FlagSleeping while it rests) and its exact motion.
	public static void WriteBody(NetWriter writer, BodyState state, bool sleeping)
	{
		writer.Write((uint8)(FlagPredicted | (sleeping ? FlagSleeping : 0)));
		writer.Write(state.position);
		writer.Write(state.rotation);
		writer.Write(state.linearVelocity);
		writer.Write(state.angularVelocity);
	}

	/// Reads the motion WriteBody wrote, after its flags.
	public static BodyState ReadBody(ref NetReader reader)
	{
		BodyState state = default;
		state.position = reader.Read<Vector3>();
		state.rotation = reader.Read<Quaternion>();
		state.linearVelocity = reader.Read<Vector3>();
		state.angularVelocity = reader.Read<Vector3>();
		return state;
	}

	/// What a snapshot says about an object nobody on the receiving machine controls.
	public struct Packed
	{
		public int32 x, y, z;
		public uint32 rotation;
		public uint8 flags;

		public bool Same(Packed other) => x == other.x && y == other.y && z == other.z && rotation == other.rotation && flags == other.flags;
	}

	/// A position and rotation packed into a few bytes.
	public static Packed Pack(Vector3 position, Quaternion rotation)
	{
		Packed packed = default;
		if (Math.Abs(position.x) < PositionLimit && Math.Abs(position.y) < PositionLimit && Math.Abs(position.z) < PositionLimit)
		{
			packed.x = (int32)Math.Round(position.x * PositionScale);
			packed.y = (int32)Math.Round(position.y * PositionScale);
			packed.z = (int32)Math.Round(position.z * PositionScale);
		}
		else
		{
			var copy = position;
			packed.flags |= FlagWide;
			packed.x = *(int32*)&copy.x;
			packed.y = *(int32*)&copy.y;
			packed.z = *(int32*)&copy.z;
		}
		// Most things only ever turn about the upright axis (characters above all), which takes two bytes.
		if (Math.Abs(rotation.x) < 0.0005f && Math.Abs(rotation.z) < 0.0005f)
		{
			packed.flags |= FlagYawOnly;
			let turn = Math.Atan2(rotation.y, rotation.w) / Math.PI_f;
			packed.rotation = (uint32)(uint16)(int32)Math.Round(turn * 32768);
		}
		else
			packed.rotation = PackRotation(rotation);
		return packed;
	}

	/// The position and rotation back from Pack.
	public static void Unpack(Packed packed, out Vector3 position, out Quaternion rotation)
	{
		if ((packed.flags & FlagWide) != 0)
		{
			var copy = packed;
			position = .(*(float*)&copy.x, *(float*)&copy.y, *(float*)&copy.z);
		}
		else
			position = .(packed.x / PositionScale, packed.y / PositionScale, packed.z / PositionScale);
		if ((packed.flags & FlagYawOnly) != 0)
		{
			let half = (float)(int16)(uint16)packed.rotation / 32768 * Math.PI_f;
			rotation = .(0, Math.Sin(half), 0, Math.Cos(half));
		}
		else
			rotation = UnpackRotation(packed.rotation);
	}

	/// Writes a packed position and rotation.
	public static void Write(NetWriter writer, Packed packed)
	{
		writer.Write(packed.flags);
		if ((packed.flags & FlagWide) != 0)
		{
			writer.Write(packed.x);
			writer.Write(packed.y);
			writer.Write(packed.z);
		}
		else
		{
			writer.Write24(packed.x);
			writer.Write24(packed.y);
			writer.Write24(packed.z);
		}
		if ((packed.flags & FlagYawOnly) != 0)
			writer.Write((uint16)packed.rotation);
		else
			writer.Write(packed.rotation);
	}

	/// Reads what Write wrote, the flags byte having been read already.
	public static Packed Read(ref NetReader reader, uint8 flags)
	{
		Packed packed = default;
		packed.flags = flags;
		if ((flags & FlagWide) != 0)
		{
			packed.x = reader.Read<int32>();
			packed.y = reader.Read<int32>();
			packed.z = reader.Read<int32>();
		}
		else
		{
			packed.x = reader.Read24();
			packed.y = reader.Read24();
			packed.z = reader.Read24();
		}
		packed.rotation = (flags & FlagYawOnly) != 0 ? (uint32)reader.Read<uint16>() : reader.Read<uint32>();
		return packed;
	}

	/// A rotation in four bytes: the largest of its four numbers is left out (it follows from the other three),
	/// and those take ten bits each.
	public static uint32 PackRotation(Quaternion rotation)
	{
		float[4] parts = .(rotation.x, rotation.y, rotation.z, rotation.w);
		int largest = 0;
		for (int i = 1; i < 4; i++)
		{
			if (Math.Abs(parts[i]) > Math.Abs(parts[largest]))
				largest = i;
		}
		let sign = parts[largest] < 0 ? -1.0f : 1.0f;
		uint32 packed = (uint32)largest << 30;
		int shift = 20;
		for (int i < 4)
		{
			if (i == largest)
				continue;
			let scaled = Mathf.Clamp(parts[i] * sign * 0.70710678f + 0.5f, 0, 1);
			packed |= (uint32)Math.Round(scaled * 1023) << shift;
			shift -= 10;
		}
		return packed;
	}

	/// A rotation back from its packed 32 bits.
	public static Quaternion UnpackRotation(uint32 packed)
	{
		let largest = (int)(packed >> 30);
		float[4] parts = default;
		float sum = 0;
		int shift = 20;
		for (int i < 4)
		{
			if (i == largest)
				continue;
			let value = ((float)((packed >> shift) & 1023) / 1023 - 0.5f) / 0.70710678f;
			parts[i] = value;
			sum += value * value;
			shift -= 10;
		}
		parts[largest] = Math.Sqrt(Math.Max(1 - sum, 0));
		return Quaternion(parts[0], parts[1], parts[2], parts[3]).Normalized;
	}

	// ---- controls ----

	/// The controls as they will arrive on the server. The player's own machine predicts with these too, so that
	/// both work from exactly the same numbers.
	public static NetInput Quantize(NetInput input)
	{
		NetInput packed = input;
		packed.moveX = (float)MoveByte(input.moveX) / 127;
		packed.moveZ = (float)MoveByte(input.moveZ) / 127;
		packed.yaw = (float)AngleShort(input.yaw) * (360.0f / 65536);
		packed.pitch = (float)AngleShort(input.pitch) * (360.0f / 65536);
		return packed;
	}

	static int8 MoveByte(float value) => value.IsFinite ? (int8)Math.Round(Mathf.Clamp(value, -1, 1) * 127) : 0;
	/// A whole turn in 65536 steps; going round more than once comes back to the same place.
	static int16 AngleShort(float degrees) => degrees.IsFinite ? (int16)(uint16)(int32)((int64)Math.Round((double)degrees * (65536.0 / 360)) & 0xFFFF) : 0;

	const uint8 InputSame = 1;
	const uint8 InputWideButtons = 2;

	/// Writes one tick of controls; a tick the same as the one before it in the packet takes a single byte.
	public static void WriteInput(NetWriter writer, NetInput input, NetInput previous, bool hasPrevious)
	{
		if (hasPrevious && input.moveX == previous.moveX && input.moveZ == previous.moveZ && input.yaw == previous.yaw && input.pitch == previous.pitch && input.buttons == previous.buttons)
		{
			writer.Write(InputSame);
			return;
		}
		let wide = input.buttons > 0xFFFF;
		writer.Write(wide ? InputWideButtons : (uint8)0);
		writer.Write(MoveByte(input.moveX));
		writer.Write(MoveByte(input.moveZ));
		writer.Write(AngleShort(input.yaw));
		writer.Write(AngleShort(input.pitch));
		if (wide)
			writer.Write(input.buttons);
		else
			writer.Write((uint16)input.buttons);
	}

	/// Reads a tick's controls, sent as changes from the tick before.
	public static NetInput ReadInput(ref NetReader reader, NetInput previous)
	{
		let flags = reader.Read<uint8>();
		if ((flags & InputSame) != 0)
			return previous;
		NetInput input = default;
		input.moveX = (float)reader.Read<int8>() / 127;
		input.moveZ = (float)reader.Read<int8>() / 127;
		input.yaw = (float)reader.Read<int16>() * (360.0f / 65536);
		input.pitch = (float)reader.Read<int16>() * (360.0f / 65536);
		input.buttons = (flags & InputWideButtons) != 0 ? reader.Read<uint32>() : (uint32)reader.Read<uint16>();
		return input;
	}
}
