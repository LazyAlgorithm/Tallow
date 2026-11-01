using System;
using System.Collections;

namespace Tallow;

/// Independent lossless message frames for transports without built-in packet compression (Steam/WebRTC).
/// A frame is used only if smaller than the original message; decoding is bounded to 2MiB.
class NetCompression
{
	public const uint8 MessageType = 9;
	public const int MaximumMessageBytes = 2 * 1024 * 1024;
	void* mCodec;
	[CLink] static extern void* tessera_net_codec_create();
	[CLink] static extern void tessera_net_codec_destroy(void* codec);
	[CLink] static extern uint32 tessera_net_compress(void* codec, uint8* data, uint32 length, uint8* output, uint32 capacity);
	[CLink] static extern uint32 tessera_net_decompress(void* codec, uint8* data, uint32 length, uint8* output, uint32 capacity);
	public this()
	{
		mCodec = tessera_net_codec_create();
	}

	public ~this()
	{
		tessera_net_codec_destroy(mCodec);
	}

	public bool Encode(Span<uint8> input, List<uint8> output)
	{
		output.Clear();
		if (mCodec == null || input.Length < 64 || input.Length > MaximumMessageBytes) return false;
		output.Count = input.Length;
		let size = tessera_net_compress(mCodec, input.Ptr, (uint32)input.Length, output.Ptr + 5, (uint32)(input.Length - 5));
		if (size == 0 || size + 5 >= (uint32)input.Length)
		{
			output.Clear();
			return false;
		}
		output[0] = MessageType;
		var length = (uint32)input.Length;
		Internal.MemCpy(output.Ptr + 1, &length, 4);
		output.Count = (int)size + 5;
		return true;
	}

	public bool Decode(Span<uint8> input, List<uint8> output)
	{
		output.Clear();
		if (mCodec == null || input.Length < 6 || input[0] != MessageType) return false;
		var reader = NetReader(input.Ptr + 1, input.Length - 1);
		let length = reader.Read<uint32>();
		if (!reader.Ok || length < 1 || length > MaximumMessageBytes) return false;
		output.Count = (int)length;
		let decoded = tessera_net_decompress(mCodec, input.Ptr + 5, (uint32)(input.Length - 5), output.Ptr, length);
		if (decoded != length || output[0] == MessageType)
		{
			output.Clear();
			return false;
		}
		return true;
	}
}
