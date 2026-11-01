using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Reads and writes one pack file (.tpak, the format described at the top of native/tallow_pack.c) from Beef, for
/// small packs that are opened on their own instead of mounted with the game: exported maps (MapFiles). Files are
/// written stored, not deflated; deflated files from tools/pack_assets.py are read too.
///
///   let pack = scope PackFile();
///   if (pack.Open("Maps/Harbour.tmap") case .Ok && pack.Read("map.txt", data) case .Ok) ...
class PackFile
{
	public struct Entry
	{
		public String name;
		public uint64 offset;
		public uint32 stored;
		public uint32 size;
		public uint32 crc;
		public uint8 flags;
	}

	const uint32 Key = 0x7E55E2A5;
	const int BlockSize = 4096;
	const uint32 IndexSalt = 0xFFFFFFFF;
	const int HeaderSize = 32;
	const uint8 Deflated = 1;
	static readonly uint8[8] Magic = .((.)'T', (.)'P', (.)'A', (.)'K', (.)'1', 0, 0, 0);

	[CLink] static extern char8* stbi_zlib_decode_malloc_guesssize_headerflag(char8* buffer, int32 length, int32 initialSize, int32* outLength, int32 parseHeader);
	[CLink] static extern void tn_pack_free(void* data);

	List<Entry> mEntries = new .() ~ { for (let entry in _) delete entry.name; delete _; };
	String mFile = new .() ~ delete _;
	uint32 mSeed;

	/// The files in the pack, in the order they were written.
	public List<Entry> Entries => mEntries;

	/// Reads the pack's index. Err if the file is missing, is not a pack, or its index is damaged.
	public Result<void> Open(StringView file)
	{
		for (let entry in mEntries)
			delete entry.name;
		mEntries.Clear();
		mFile.Set(file);
		let stream = scope FileStream();
		if (stream.Open(file, .Read, .Read) case .Err)
			return .Err;
		uint8[HeaderSize] header = default;
		if (stream.TryRead(.(&header, HeaderSize)) case .Ok(let read) && read != HeaderSize)
			return .Err;
		for (int i < Magic.Count)
		{
			if (header[i] != Magic[i])
				return .Err;
		}
		if (U32(&header[8]) != 1)
			return .Err;
		let count = U32(&header[12]);
		let indexOffset = U64(&header[16]);
		let indexSize = U32(&header[24]);
		mSeed = U32(&header[28]);
		if (indexOffset + indexSize > (uint64)stream.Length)
			return .Err;
		let index = scope uint8[indexSize];
		stream.Position = (int64)indexOffset;
		if (indexSize > 0 && (stream.TryRead(.(index.Ptr, indexSize)) case .Ok(let got)) && got != indexSize)
			return .Err;
		Scramble(.(index.Ptr, indexSize), mSeed, IndexSalt);
		int at = 0;
		for (uint32 i < count)
		{
			if (at + 2 > indexSize)
				return .Err;
			let nameLength = (int)index[at] | ((int)index[at + 1] << 8);
			at += 2;
			if (at + nameLength + 21 > indexSize)
				return .Err;
			Entry entry;
			entry.name = new String(StringView((char8*)&index[at], nameLength));
			at += nameLength;
			entry.offset = U64(&index[at]);
			entry.stored = U32(&index[at + 8]);
			entry.size = U32(&index[at + 12]);
			entry.crc = U32(&index[at + 16]);
			entry.flags = index[at + 20];
			at += 21;
			mEntries.Add(entry);
		}
		return .Ok;
	}

	/// Whether the pack has a file of that name.
	public bool Has(StringView name)
	{
		for (let entry in mEntries)
		{
			if (entry.name == name)
				return true;
		}
		return false;
	}

	/// Reads one file, checked against its checksum. Err if it is missing or damaged.
	public Result<void> Read(StringView name, List<uint8> data)
	{
		for (let entry in mEntries)
		{
			if (entry.name == name)
				return Read(entry, data);
		}
		return .Err;
	}

	/// Reads one entry of Entries, checked against its checksum.
	public Result<void> Read(Entry entry, List<uint8> data)
	{
		let stream = scope FileStream();
		if (stream.Open(mFile, .Read, .Read) case .Err)
			return .Err;
		if (entry.offset + entry.stored > (uint64)stream.Length)
			return .Err;
		let stored = scope uint8[Math.Max(entry.stored, 1)];
		stream.Position = (int64)entry.offset;
		if (entry.stored > 0 && (stream.TryRead(.(stored.Ptr, entry.stored)) case .Ok(let got)) && got != entry.stored)
			return .Err;
		Scramble(.(stored.Ptr, entry.stored), mSeed, entry.crc);
		let start = data.Count;
		if ((entry.flags & Deflated) != 0)
		{
			int32 length = 0;
			let plain = stbi_zlib_decode_malloc_guesssize_headerflag((char8*)stored.Ptr, (int32)entry.stored, (int32)entry.size + 16, &length, 1);
			if (plain == null)
				return .Err;
			defer tn_pack_free(plain);
			if ((uint32)length != entry.size)
				return .Err;
			data.AddRange(Span<uint8>((uint8*)plain, length));
		}
		else
			data.AddRange(Span<uint8>(stored.Ptr, entry.stored));
		if (Crc32(.(data.Ptr + start, data.Count - start)) != entry.crc)
		{
			data.Count = start;
			return .Err;
		}
		return .Ok;
	}

	/// Writes a pack of the given files (name inside the pack, contents), stored and scrambled as the engine's packs
	/// are. Names use forward slashes.
	public static Result<void> Write(StringView file, Span<(StringView name, Span<uint8> data)> files)
	{
		let seed = (uint32)((uint64)DateTime.UtcNow.Ticks ^ (uint64)Internal.GetTickCountMicro()) | 1;
		let index = scope List<uint8>();
		let stream = scope FileStream();
		if (stream.Create(file) case .Err)
			return .Err;
		uint8[HeaderSize] header = default;
		if (stream.TryWrite(.(&header, HeaderSize)) case .Err)
			return .Err;
		uint64 offset = HeaderSize;
		for (let (name, data) in files)
		{
			let crc = Crc32(data);
			let scrambled = scope uint8[Math.Max(data.Length, 1)];
			Internal.MemCpy(scrambled.Ptr, data.Ptr, data.Length);
			Scramble(.(scrambled.Ptr, data.Length), seed, crc);
			if (data.Length > 0 && stream.TryWrite(.(scrambled.Ptr, data.Length)) case .Err)
				return .Err;
			let encoded = name;
			PutU16(index, (uint16)encoded.Length);
			index.AddRange(Span<uint8>((uint8*)encoded.Ptr, encoded.Length));
			PutU64(index, offset);
			PutU32(index, (uint32)data.Length);
			PutU32(index, (uint32)data.Length);
			PutU32(index, crc);
			index.Add(0);
			offset += (uint64)data.Length;
		}
		Scramble(.(index.Ptr, index.Count), seed, IndexSalt);
		if (index.Count > 0 && stream.TryWrite(.(index.Ptr, index.Count)) case .Err)
			return .Err;
		let headerData = scope List<uint8>();
		headerData.AddRange(Magic);
		PutU32(headerData, 1);
		PutU32(headerData, (uint32)files.Length);
		PutU64(headerData, offset);
		PutU32(headerData, (uint32)index.Count);
		PutU32(headerData, seed);
		stream.Position = 0;
		if (stream.TryWrite(.(headerData.Ptr, headerData.Count)) case .Err)
			return .Err;
		return .Ok;
	}

	/// XOR with the repeating block made from the seed and salt; the same call undoes it.
	static void Scramble(Span<uint8> data, uint32 seed, uint32 salt)
	{
		if (data.Length == 0)
			return;
		uint8[BlockSize] block = ?;
		var state = seed ^ Key ^ (salt &* 2654435761U);
		if (state == 0)
			state = Key;
		for (int i < BlockSize)
		{
			state ^= state << 13;
			state ^= state >> 17;
			state ^= state << 5;
			block[i] = (uint8)(state >> 11);
		}
		for (int i < data.Length)
			data[i] ^= block[i % BlockSize];
	}

	static uint32[256] sCrcTable;
	static bool sCrcReady;

	/// The zlib checksum, as the native reader and tools/pack_assets.py use.
	public static uint32 Crc32(Span<uint8> data)
	{
		if (!sCrcReady)
		{
			for (uint32 i < 256)
			{
				var c = i;
				for (int k < 8)
					c = (c & 1) != 0 ? 0xEDB88320U ^ (c >> 1) : c >> 1;
				sCrcTable[i] = c;
			}
			sCrcReady = true;
		}
		uint32 crc = 0xFFFFFFFF;
		for (let byte in data)
			crc = sCrcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
		return crc ^ 0xFFFFFFFF;
	}

	static uint32 U32(uint8* p) => (uint32)p[0] | ((uint32)p[1] << 8) | ((uint32)p[2] << 16) | ((uint32)p[3] << 24);
	static uint64 U64(uint8* p) => (uint64)U32(p) | ((uint64)U32(p + 4) << 32);

	static void PutU16(List<uint8> data, uint16 value)
	{
		data.Add((uint8)value);
		data.Add((uint8)(value >> 8));
	}

	static void PutU32(List<uint8> data, uint32 value)
	{
		for (int i < 4)
			data.Add((uint8)(value >> (i * 8)));
	}

	static void PutU64(List<uint8> data, uint64 value)
	{
		for (int i < 8)
			data.Add((uint8)(value >> (i * 8)));
	}
}
