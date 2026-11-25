using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// What a stream of pages holds.
public enum StreamKind : uint8
{
	GeoPage,
	TextureMip,
	VtTile
}

/// A .tpages file: fixed-size slots (64 KB aligned) of pages that are each deflated on their own and carry a CRC of
/// their plain bytes, so one page is one seek and one read. Cooked beside its source (like .tclod and .ktx) or stored
/// uncompressed in an export pack, where PackFile.ReadRange reaches it.
///
/// Layout (little endian): 32-byte header { "TPGS", u32 version, u32 kind, u32 pageCount, u32 slotSize, u64 reserved,
/// u32 reserved }, then pageCount x 24-byte entries { u64 offset, u32 stored, u32 size, u32 crc, u32 flags (bit 0 deflated) },
/// then the pages, each starting at a multiple of slotSize.
///
/// Reads are safe from any thread: every call opens its own stream.
class PageFile
{
	public const uint32 SlotSize = 65536;
	const int HeaderSize = 32;
	const int EntrySize = 24;
	const uint32 Version = 1;

	struct Page
	{
		public uint64 offset;
		public uint32 stored;
		public uint32 size;
		public uint32 crc;
		public uint32 flags;
	}

	[CLink] static extern uint8* stbi_zlib_compress(uint8* data, int32 length, int32* outLength, int32 quality);
	[CLink] static extern char8* stbi_zlib_decode_malloc_guesssize_headerflag(char8* buffer, int32 length, int32 initialSize, int32* outLength, int32 parseHeader);
	[CLink] static extern void tn_pack_free(void* data);

	Page[] mPages ~ delete _;
	String mFile = new .() ~ delete _;
	PackFile mPack;
	String mEntry = new .() ~ delete _;
	StreamKind mKind;

	public int PageCount => mPages == null ? 0 : mPages.Count;
	public StreamKind Kind => mKind;

	/// Plain size of a page.
	public uint32 PageSize(int page) => mPages[page].size;

	/// Reads the header and page table of a loose file. Err if it is missing or damaged.
	public Result<void> Open(StringView file)
	{
		mPack = null;
		mFile.Set(file);
		let head = scope List<uint8>();
		if (ReadAt(0, HeaderSize, head) case .Err)
			return .Err;
		return ReadTable(head);
	}

	/// Reads the header and page table of a file stored (not deflated) in a pack. The pack must outlive this.
	public Result<void> Open(PackFile pack, StringView entry)
	{
		mPack = pack;
		mEntry.Set(entry);
		let head = scope List<uint8>();
		if (ReadAt(0, HeaderSize, head) case .Err)
			return .Err;
		return ReadTable(head);
	}

	Result<void> ReadTable(List<uint8> head)
	{
		if (head.Count < HeaderSize || head[0] != 'T' || head[1] != 'P' || head[2] != 'G' || head[3] != 'S')
			return .Err;
		if (U32(&head[4]) != Version)
			return .Err;
		mKind = (StreamKind)U32(&head[8]);
		let count = (int)U32(&head[12]);
		if (count < 0 || count > 16000000)
			return .Err;
		let table = scope List<uint8>();
		if (ReadAt(HeaderSize, count * EntrySize, table) case .Err)
			return .Err;
		delete mPages;
		mPages = new Page[count];
		for (int i < count)
		{
			let p = &table[i * EntrySize];
			mPages[i] = .() { offset = U64(p), stored = U32(p + 8), size = U32(p + 12), crc = U32(p + 16), flags = U32(p + 20) };
		}
		return .Ok;
	}

	Result<void> ReadAt(uint64 offset, int size, List<uint8> data)
	{
		if (mPack != null)
			return mPack.ReadRange(mEntry, offset, size, data);
		let stream = scope FileStream();
		if (stream.Open(mFile, .Read, .Read) case .Err)
			return .Err;
		if (offset + (uint64)size > (uint64)stream.Length)
			return .Err;
		let start = data.Count;
		data.Count = start + size;
		stream.Position = (int64)offset;
		if (size > 0 && (stream.TryRead(.(data.Ptr + start, size)) case .Ok(let got)) && got != size)
		{
			data.Count = start;
			return .Err;
		}
		return .Ok;
	}

	/// Just the bytes of page `page` as stored (still deflated), for the IO thread; Decode is the worker's part.
	public Result<void> ReadRaw(int page, List<uint8> stored)
	{
		if (page < 0 || page >= PageCount)
			return .Err;
		return ReadAt(mPages[page].offset, (int)mPages[page].stored, stored);
	}

	/// Inflates and checks a page read with ReadRaw, appending its plain bytes.
	public Result<void> Decode(int page, Span<uint8> stored, List<uint8> plain)
	{
		if (page < 0 || page >= PageCount)
			return .Err;
		let entry = mPages[page];
		let start = plain.Count;
		if ((entry.flags & 1) != 0)
		{
			int32 length = 0;
			let bytes = stbi_zlib_decode_malloc_guesssize_headerflag((char8*)stored.Ptr, (int32)stored.Length, (int32)entry.size + 16, &length, 1);
			if (bytes == null)
				return .Err;
			defer tn_pack_free(bytes);
			if ((uint32)length != entry.size)
				return .Err;
			plain.AddRange(Span<uint8>((uint8*)bytes, length));
		}
		else
			plain.AddRange(stored);
		if ((uint32)(plain.Count - start) != entry.size || PackFile.Crc32(.(plain.Ptr + start, plain.Count - start)) != entry.crc)
		{
			plain.Count = start;
			return .Err;
		}
		return .Ok;
	}

	/// Reads one page whole (IO and decode on the calling thread).
	public Result<void> Read(int page, List<uint8> plain)
	{
		let stored = scope List<uint8>();
		if (ReadRaw(page, stored) case .Err)
			return .Err;
		return Decode(page, stored, plain);
	}

	/// Writes a file of pages. A page that deflates smaller is stored deflated.
	public static Result<void> Write(StringView file, StreamKind kind, List<List<uint8>> pages, bool compress = true)
	{
		let stream = scope FileStream();
		if (stream.Create(file) case .Err)
			return .Err;
		let tableEnd = (uint64)(HeaderSize + pages.Count * EntrySize);
		var offset = (tableEnd + SlotSize - 1) / SlotSize * SlotSize;
		let head = scope List<uint8>();
		head.AddRange(Span<uint8>((uint8*)"TPGS", 4));
		Put32(head, Version);
		Put32(head, (uint32)kind);
		Put32(head, (uint32)pages.Count);
		Put32(head, SlotSize);
		Put32(head, 0); Put32(head, 0); Put32(head, 0);
		let bodies = scope List<(uint8* data, int length, bool owned)>();
		defer { for (let b in bodies) { if (b.owned) tn_pack_free(b.data); } }
		for (let page in pages)
		{
			var stored = (uint8*)page.Ptr;
			var storedLength = page.Count;
			uint32 flags = 0;
			var owned = false;
			if (compress && page.Count > 0)
			{
				int32 length = 0;
				let packed = stbi_zlib_compress(page.Ptr, (int32)page.Count, &length, 6);
				if (packed != null)
				{
					if (length < page.Count)
					{
						stored = packed;
						storedLength = length;
						flags = 1;
						owned = true;
					}
					else
						tn_pack_free(packed);
				}
			}
			bodies.Add((stored, storedLength, owned));
			Put64(head, offset);
			Put32(head, (uint32)storedLength);
			Put32(head, (uint32)page.Count);
			Put32(head, PackFile.Crc32(page));
			Put32(head, flags);
			offset += ((uint64)storedLength + SlotSize - 1) / SlotSize * SlotSize;
		}
		if (stream.TryWrite(.(head.Ptr, head.Count)) case .Err)
			return .Err;
		let pad = scope uint8[SlotSize];
		var written = (uint64)head.Count;
		for (let b in bodies)
		{
			let slot = (written + SlotSize - 1) / SlotSize * SlotSize;
			while (written < slot)
			{
				let n = (int)Math.Min(slot - written, (uint64)SlotSize);
				if (stream.TryWrite(.(pad.Ptr, n)) case .Err)
					return .Err;
				written += (uint64)n;
			}
			if (b.length > 0 && stream.TryWrite(.(b.data, b.length)) case .Err)
				return .Err;
			written += (uint64)b.length;
		}
		return .Ok;
	}

	static uint32 U32(uint8* p) => (uint32)p[0] | ((uint32)p[1] << 8) | ((uint32)p[2] << 16) | ((uint32)p[3] << 24);
	static uint64 U64(uint8* p) => (uint64)U32(p) | ((uint64)U32(p + 4) << 32);
	static void Put32(List<uint8> data, uint32 v) { for (int i < 4) data.Add((uint8)(v >> (i * 8))); }
	static void Put64(List<uint8> data, uint64 v) { for (int i < 8) data.Add((uint8)(v >> (i * 8))); }
}
