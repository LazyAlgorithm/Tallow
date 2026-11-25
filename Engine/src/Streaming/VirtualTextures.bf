using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

/// One virtual texture (M4d): a huge picture that is never whole on the graphics card. Its `.tvt` file (cooked beside the
/// picture, `StreamKind.VtTile`) has one page for every 128 px tile of every mip level (finest level first, each tile
/// with a 4 px border of its neighbours so filtering never reads another slot), and a last page with its size. A shared
/// physical cache (VirtualTextures.Cache) holds the tiles that are resident, and this texture's page table (Table: one
/// texel per tile, with a mip chain of its own) says where: (slot x, slot y, level of the tile that is there). A tile that
/// is not resident shows its coarsest resident ancestor, so there are no holes; the top tiles are always resident.
/// Tiles are asked for from the feedback pass (VirtualTextures.BeginFeedback), which draws what the camera needs.
class VirtualTexture : IStreamConsumer
{
	public StreamResource Res ~ delete _;
	public PageFile File ~ delete _;
	public String Path = new .() ~ delete _;
	/// 1 to 255, written by the feedback pass.
	public int32 Id;
	public int32 Width, Height, Levels;
	public int32[] TilesX ~ delete _;
	public int32[] TilesY ~ delete _;
	/// The first page of each level (and the page count at the end).
	public int32[] Base ~ delete _;
	public List<int32> SlotOf = new .() ~ delete _;
	public bgfx.TextureHandle Table = .() { idx = uint16.MaxValue };
	/// The whole picture at its smallest, for drawing the old way (no feedback, no page table).
	public bgfx.TextureHandle Tail = .() { idx = uint16.MaxValue };
	public bool Dirty;
	public int LastUsed;
	public int32 Resident;

	public int32 PageCount => Base[Levels];

	public int32 PageOf(int32 level, int32 x, int32 y) => Base[level] + y * TilesX[level] + x;

	public bool Upload(StreamResource resource, int page, Span<uint8> data)
	{
		if (page < 0 || page >= PageCount || data.Length != VirtualTextures.TileBytes)
			return false;
		// Asked for twice while the first copy waited to be uploaded: it is already here.
		if (SlotOf[page] >= 0)
			return true;
		let slot = VirtualTextures.AllocSlot();
		if (slot < 0)
			return false;
		VirtualTextures.UploadTile(slot, data);
		SlotOf[page] = slot;
		Resident++;
		Dirty = true;
		return true;
	}

	/// The pool let a tile go: its slot is free and the table points at its parent instead.
	public void Evicted(int page)
	{
		if (page < 0 || page >= SlotOf.Count || SlotOf[page] < 0)
			return;
		VirtualTextures.FreeSlot(SlotOf[page]);
		SlotOf[page] = -1;
		Resident--;
		Dirty = true;
	}

	/// Writes the page table from what is resident: each texel the nearest tile at its own level or above that is.
	public void UpdateTable()
	{
		Dirty = false;
		if (!Table.Valid)
			return;
		uint8[][] levels = scope uint8[Levels][];
		defer { for (let level in levels) delete level; }
		for (int32 l = Levels - 1; l >= 0; l--)
		{
			let w = TilesX[l];
			let h = TilesY[l];
			let texels = new uint8[w * h * 4];
			levels[l] = texels;
			for (int32 y < h)
			{
				for (int32 x < w)
				{
					let o = (y * w + x) * 4;
					let slot = SlotOf[PageOf(l, x, y)];
					if (slot >= 0)
					{
						texels[o] = (uint8)(slot % VirtualTextures.CacheColumns);
						texels[o + 1] = (uint8)(slot / VirtualTextures.CacheColumns);
						texels[o + 2] = (uint8)l;
						texels[o + 3] = 255;
					}
					else if (l + 1 < Levels)
					{
						let parent = ((y >> 1) * TilesX[l + 1] + (x >> 1)) * 4;
						for (int i < 4)
							texels[o + i] = levels[l + 1][parent + i];
					}
				}
			}
		}
		for (int32 l < Levels)
			bgfx.update_texture_2d(Table, 0, (uint8)l, 0, 0, (uint16)TilesX[l], (uint16)TilesY[l], bgfx.copy(levels[l].CArray(), (uint32)(TilesX[l] * TilesY[l] * 4)), (uint16)(TilesX[l] * 4));
	}

	/// Asks for a tile and every tile above it (the parents first, so something coarser is there while the sharp one comes).
	public void Want(int32 level, int32 x, int32 y)
	{
		var l = level;
		var tx = x;
		var ty = y;
		while (l < Levels)
		{
			let page = PageOf(l, tx, ty);
			StreamingCore.Request(Res, page, 10.0f + l);
			l++;
			tx >>= 1;
			ty >>= 1;
		}
		LastUsed = StreamingCore.Frame;
	}
}

/// The virtual texture system: the shared physical cache, the textures, the cook, and the feedback pass that tells it
/// which tiles the camera needs. Main thread only.
static class VirtualTextures
{
	/// On unless --no-virtual-textures.
	public static bool Enabled = true;
	/// Pictures this big on a side (PNG, read from its header) are virtual even without `virtual=1` in their .import.
	public static int32 AutoSize = 4096;
	public const int32 Tile = 128;
	public const int32 Border = 4;
	public const int32 Physical = Tile + Border * 2;
	public const int32 TileBytes = Physical * Physical * 4;
	const int32 MaxColumns = 60;
	const uint32 CookVersion = 1;
	/// The feedback target is this many times smaller than the screen on a side (log2 3).
	public const int32 FeedbackDivide = 8;
	/// The bgfx view the feedback pass draws in: after the GPU culling (2 to 8), before the cameras (10 and up).
	public const uint16 FeedbackView = 9;

	public static bgfx.TextureHandle Cache = .() { idx = uint16.MaxValue };
	public static int32 CacheColumns, CacheRows, Slots;
	public static bgfx.ProgramHandle LitProgram = .() { idx = uint16.MaxValue };
	public static bgfx.ProgramHandle FeedbackProgram = .() { idx = uint16.MaxValue };
	/// Counters for the tests and the profiler.
	public static int32 Made, FeedbackReads, TilesWanted, SlotsUsed, FinestWanted = 99;
	public static int64 SlotUploads;

	static List<VirtualTexture> sAll = new .() ~ DeleteContainerAndItems!(_);
	static Dictionary<uint16, VirtualTexture> sByHandle = new .() ~ delete _;
	static Dictionary<String, VirtualTexture> sByPath = new .() ~ delete _;
	static List<int32> sFree = new .() ~ delete _;
	static uint64 sNextId;
	static bool sProgramsTried;

	// The feedback pass: a small target the pass draws tile numbers into, a copy of it the CPU can read, and the state of the
	// read (0 idle, 1 copied and waiting to be asked for, 2 asked for).
	static bgfx.TextureHandle sFbColor = .() { idx = uint16.MaxValue };
	static bgfx.FrameBufferHandle sFb = .() { idx = uint16.MaxValue };
	static bgfx.TextureHandle sFbRead = .() { idx = uint16.MaxValue };
	static int32 sFbWidth, sFbHeight;
	static uint8[] sFbData;
	static int sFbState;
	static int sFbWait;
	static uint32 sFbReady;
	static bool sFbDrawn;
	static int sDrawnFrame = -1;
	static HashSet<uint32> sSeen = new .() ~ delete _;

	public static int Count => sAll.Count;
	public static bool Active => Enabled && sAll.Count > 0;
	public static bool Supported => LitProgram.Valid && FeedbackProgram.Valid && Cache.Valid;

	public static VirtualTexture Find(StringView path) => sByPath.TryGetValueAlt(path, let vt) ? vt : null;
	public static VirtualTexture ForHandle(uint16 idx) => sByHandle.TryGetValue(idx, let vt) ? vt : null;

	public static void ForEach(delegate void(VirtualTexture) each)
	{
		for (let vt in sAll)
			each(vt);
	}

	static void Put32(List<uint8> list, uint32 value)
	{
		for (int i < 4)
			list.Add((uint8)(value >> (i * 8)));
	}

	static uint32 U32(uint8* p) => (uint32)p[0] | ((uint32)p[1] << 8) | ((uint32)p[2] << 16) | ((uint32)p[3] << 24);

	/// The width and height of a PNG from its header, or 0.
	public static bool PngSize(StringView full, out int32 width, out int32 height)
	{
		width = 0;
		height = 0;
		if (!full.EndsWith(".png", .OrdinalIgnoreCase))
			return false;
		FileStream stream = scope .();
		if (stream.Open(full, .Read, .Read) case .Err)
			return false;
		uint8[24] header = default;
		if (stream.TryRead(.(&header, 24)) case .Err(?) || header[1] != 'P')
			return false;
		width = (int32)(((uint32)header[16] << 24) | ((uint32)header[17] << 16) | ((uint32)header[18] << 8) | header[19]);
		height = (int32)(((uint32)header[20] << 24) | ((uint32)header[21] << 16) | ((uint32)header[22] << 8) | header[23]);
		return true;
	}

	/// Whether a picture is made a virtual texture: flagged in its options, or very big.
	public static bool Wants(StringView path, StringView full)
	{
		if (!Enabled || !Gfx.Initialized || StreamingCore.Pool(.VtTile) == null)
			return false;
		// In a game's pack: whatever the export cooked a .tvt for.
		if (AssetPack.Contains(full))
			return AssetPack.Contains(scope String(full)..Append(".tvt"));
		if (!File.Exists(full))
			return false;
		if (TextureOptionsFor.Of(path).Virtual)
			return true;
		return PngSize(full, let w, let h) && Math.Max(w, h) >= AutoSize;
	}

	static void EnsurePrograms()
	{
		if (sProgramsTried)
			return;
		sProgramsTried = true;
		LitProgram = Gfx.LoadProgram("vs_cluster", "fs_cluster_vt");
		FeedbackProgram = Gfx.LoadProgram("vs_cluster_depth_albedo", "fs_vt_feedback");
	}

	/// The shared cache: as many 136 px slots as the pool's budget holds (at most 60 x 60), in one texture.
	static bool EnsureCache()
	{
		if (Cache.Valid)
			return true;
		let pool = StreamingCore.Pool(.VtTile);
		if (pool == null)
			return false;
		var slots = (int32)Math.Clamp(pool.Budget / TileBytes, 24, MaxColumns * MaxColumns);
		CacheColumns = Math.Min(slots, MaxColumns);
		CacheRows = (slots + CacheColumns - 1) / CacheColumns;
		Slots = CacheColumns * CacheRows;
		pool.Budget = (int64)Slots * TileBytes;
		Cache = bgfx.create_texture_2d((uint16)(CacheColumns * Physical), (uint16)(CacheRows * Physical), false, 1, .RGBA8, Gfx.SamplerClamp, null, 0);
		if (!Cache.Valid)
			return false;
		for (int32 i = Slots - 1; i >= 0; i--)
			sFree.Add(i);
		pool.OnEvict = new => OnEvict;
		return true;
	}

	public static int32 AllocSlot()
	{
		if (sFree.Count == 0)
			return -1;
		SlotsUsed++;
		return sFree.PopBack();
	}

	public static void FreeSlot(int32 slot)
	{
		SlotsUsed--;
		sFree.Add(slot);
	}

	public static void UploadTile(int32 slot, Span<uint8> data)
	{
		let x = (slot % CacheColumns) * Physical;
		let y = (slot / CacheColumns) * Physical;
		bgfx.update_texture_2d(Cache, 0, 0, (uint16)x, (uint16)y, Physical, Physical, bgfx.copy(data.Ptr, (uint32)data.Length), (uint16)(Physical * 4));
		SlotUploads++;
	}

	static void OnEvict(uint64 resource, int page)
	{
		for (let vt in sAll)
		{
			if (vt.Res.Id == resource)
			{
				vt.Evicted(page);
				return;
			}
		}
	}

	/// Makes the virtual texture of a picture: its table and top tiles, ready to draw at once; the handle it returns is the
	/// whole picture at its smallest (what the old drawing path shows). An invalid handle when it cannot be made.
	public static bgfx.TextureHandle TryCreate(StringView path, StringView full)
	{
		bgfx.TextureHandle none = .() { idx = uint16.MaxValue };
		if (!Wants(path, full) || sAll.Count >= 255)
			return none;
		EnsurePrograms();
		if (!EnsureCache())
			return none;
		let cooked = scope String(full)..Append(".tvt");
		let file = new PageFile();
		let packed = AssetPack.Contains(full);
		var ok = (file.Open(cooked) case .Ok) && Valid(file, full, packed);
		if (!ok)
		{
			if (packed || !Cook(full, cooked))
			{
				delete file;
				return none;
			}
			ok = (file.Open(cooked) case .Ok) && Valid(file, full, false);
		}
		if (!ok)
		{
			delete file;
			return none;
		}
		let meta = scope List<uint8>();
		if (file.Read(file.PageCount - 1, meta) case .Err || meta.Count < 16)
		{
			delete file;
			return none;
		}
		let vt = new VirtualTexture();
		vt.File = file;
		vt.Path.Set(path);
		vt.Width = (int32)U32(&meta[0]);
		vt.Height = (int32)U32(&meta[4]);
		vt.Levels = (int32)U32(&meta[8]);
		vt.TilesX = new int32[vt.Levels];
		vt.TilesY = new int32[vt.Levels];
		vt.Base = new int32[vt.Levels + 1];
		for (int32 l < vt.Levels)
		{
			vt.TilesX[l] = Math.Max(1, (vt.Width >> l) / Tile);
			vt.TilesY[l] = Math.Max(1, (vt.Height >> l) / Tile);
			vt.Base[l + 1] = vt.Base[l] + vt.TilesX[l] * vt.TilesY[l];
		}
		if (vt.PageCount + 1 != file.PageCount)
		{
			delete vt;
			return none;
		}
		for (int i < vt.PageCount)
			vt.SlotOf.Add(-1);
		vt.Table = bgfx.create_texture_2d((uint16)vt.TilesX[0], (uint16)vt.TilesY[0], vt.Levels > 1, 1, .RGBA8, Gfx.SamplerClamp | Gfx.SamplerPoint, null, 0);
		vt.Id = (int32)(sAll.Count + 1);
		vt.Res = new StreamResource();
		vt.Res.Id = ++sNextId;
		vt.Res.Kind = .VtTile;
		vt.Res.File = file;
		vt.Res.Consumer = vt;
		StreamingCore.Register(vt.Res);
		let pool = StreamingCore.Pool(.VtTile);
		// The top levels (up to four tiles) are read now and never evicted: the texture is never blank.
		let tile = scope List<uint8>();
		var pinnedLevel = vt.Levels - 1;
		while (pinnedLevel > 0 && vt.TilesX[pinnedLevel - 1] * vt.TilesY[pinnedLevel - 1] <= 4)
			pinnedLevel--;
		for (int32 l = pinnedLevel; l < vt.Levels; l++)
		{
			for (int32 y < vt.TilesY[l])
			{
				for (int32 x < vt.TilesX[l])
				{
					let page = vt.PageOf(l, x, y);
					tile.Clear();
					let slot = AllocSlot();
					if (file.Read(page, tile) case .Err || tile.Count != TileBytes || slot < 0)
					{
						if (slot >= 0)
							FreeSlot(slot);
						continue;
					}
					UploadTile(slot, tile);
					vt.SlotOf[page] = slot;
					vt.Resident++;
					pool.Add(vt.Res.Id, page, TileBytes, StreamingCore.Frame, true);
				}
			}
		}
		// The whole picture at its smallest, for drawing without the page table.
		let top = vt.Levels - 1;
		tile.Clear();
		if (file.Read(vt.PageOf(top, 0, 0), tile) case .Ok && tile.Count == TileBytes)
		{
			let w = Math.Max(1, vt.Width >> top);
			let h = Math.Max(1, vt.Height >> top);
			let small = scope uint8[w * h * 4];
			for (int32 y < h)
				Internal.MemCpy(&small[y * w * 4], &tile[((y + Border) * Physical + Border) * 4], w * 4);
			vt.Tail = bgfx.create_texture_2d((uint16)w, (uint16)h, false, 1, .RGBA8, 0, bgfx.copy(small.CArray(), (uint32)(w * h * 4)), 0);
			Textures.Sizes[vt.Tail.idx] = w * h * 4;
		}
		if (!vt.Tail.Valid)
		{
			StreamingCore.Unregister(vt.Res, vt.PageCount);
			for (let slot in vt.SlotOf)
			{
				if (slot >= 0)
					FreeSlot(slot);
			}
			bgfx.destroy_texture(vt.Table);
			delete vt;
			return none;
		}
		vt.UpdateTable();
		vt.LastUsed = StreamingCore.Frame;
		sAll.Add(vt);
		sByHandle[vt.Tail.idx] = vt;
		sByPath[vt.Path] = vt;
		Made++;
		return vt.Tail;
	}

	static bool Valid(PageFile file, StringView source, bool packed)
	{
		if (file.Kind != .VtTile || file.PageCount < 2)
			return false;
		let meta = scope List<uint8>();
		if (file.Read(file.PageCount - 1, meta) case .Err || meta.Count < 16 || U32(&meta[12]) != CookVersion)
			return false;
		var cooked = scope String(source)..Append(".tvt");
		if (!packed && File.GetLastWriteTime(source) case .Ok(let sourceTime) && File.GetLastWriteTime(cooked) case .Ok(let cookedTime) && sourceTime > cookedTime)
			return false;
		return true;
	}

	static int32 PowerOfTwo(int32 value)
	{
		int32 p = Tile;
		while (p < value && p < 32768)
			p <<= 1;
		return p;
	}

	/// Cuts a picture into tiles (all its mip levels) and writes the `.tvt`. A picture that is not a power of two on a side is
	/// stretched to the next one. False if it cannot be read or written.
	public static bool Cook(StringView full, StringView cooked)
	{
		int32 width = 0, height = 0;
		let loaded = Native.tn_image_load(scope String(full).CStr(), &width, &height);
		if (loaded == null)
			return false;
		defer Native.tn_image_free(loaded);
		let pw = PowerOfTwo(width);
		let ph = PowerOfTwo(height);
		uint8* source = loaded;
		uint8[] resized = null;
		defer delete resized;
		if (pw != width || ph != height)
		{
			resized = new uint8[pw * ph * 4];
			for (int32 y < ph)
			{
				let fy = Math.Min((y + 0.5f) * height / ph - 0.5f, height - 1.0f);
				let y0 = Math.Max((int32)fy, 0);
				let y1 = Math.Min(y0 + 1, height - 1);
				let ty = Math.Max(fy - y0, 0);
				for (int32 x < pw)
				{
					let fx = Math.Min((x + 0.5f) * width / pw - 0.5f, width - 1.0f);
					let x0 = Math.Max((int32)fx, 0);
					let x1 = Math.Min(x0 + 1, width - 1);
					let tx = Math.Max(fx - x0, 0);
					for (int c < 4)
					{
						let top = loaded[(y0 * width + x0) * 4 + c] * (1 - tx) + loaded[(y0 * width + x1) * 4 + c] * tx;
						let bottom = loaded[(y1 * width + x0) * 4 + c] * (1 - tx) + loaded[(y1 * width + x1) * 4 + c] * tx;
						resized[(y * pw + x) * 4 + c] = (uint8)(top * (1 - ty) + bottom * ty + 0.5f);
					}
				}
			}
			source = resized.CArray();
		}
		int32 lw = 0, lh = 0, total = 0;
		let mips = Textures.MakeMips(.(source, pw * ph * 4), pw, ph, .Color, 0, out lw, out lh, out total);
		if (mips == null)
			return false;
		defer delete mips;
		var levels = 1;
		while (Math.Max(pw >> (levels - 1), ph >> (levels - 1)) > Tile)
			levels++;
		let pages = scope List<List<uint8>>();
		defer { for (let page in pages) delete page; }
		var start = 0;
		for (int l < levels)
		{
			let w = Math.Max(1, pw >> l);
			let h = Math.Max(1, ph >> l);
			let tilesX = Math.Max(1, w / Tile);
			let tilesY = Math.Max(1, h / Tile);
			for (int ty < tilesY)
			{
				for (int tx < tilesX)
				{
					let page = new List<uint8>(TileBytes);
					page.Count = TileBytes;
					for (int py < Physical)
					{
						let sy = Math.Clamp(ty * Tile - Border + py, 0, h - 1);
						for (int px < Physical)
						{
							let sx = Math.Clamp(tx * Tile - Border + px, 0, w - 1);
							Internal.MemCpy(&page[(py * Physical + px) * 4], &mips[start + (sy * w + sx) * 4], 4);
						}
					}
					pages.Add(page);
				}
			}
			start += w * h * 4;
		}
		let meta = new List<uint8>();
		Put32(meta, (uint32)pw);
		Put32(meta, (uint32)ph);
		Put32(meta, (uint32)levels);
		Put32(meta, CookVersion);
		pages.Add(meta);
		let temp = scope String(cooked)..Append(".tmp");
		if (PageFile.Write(temp, .VtTile, pages, true) case .Err)
			return false;
		File.Delete(cooked);
		return File.Move(temp, cooked) case .Ok;
	}

	/// Once a frame, before drawing: writes page tables that changed and reads what the feedback pass saw.
	public static void Update(int frame)
	{
		if (sAll.Count == 0)
			return;
		for (let vt in sAll)
		{
			if (vt.Dirty)
				vt.UpdateTable();
		}
		PollFeedback();
	}

	/// Binds a texture's cache and page table (stages 2 and 3) and its uniforms for the draw about to be submitted.
	public static void Bind(VirtualTexture vt)
	{
		Vector4 info = .(vt.Width, vt.Height, vt.Levels - 1, vt.Id);
		Vector4 cache = .(CacheColumns * Physical, CacheRows * Physical, 3, 0);
		bgfx.set_uniform(RenderResources.uVtInfo, &info, 1);
		bgfx.set_uniform(RenderResources.uVtCache, &cache, 1);
		bgfx.set_texture(2, RenderResources.sTexture1, Cache, uint32.MaxValue);
		bgfx.set_texture(3, RenderResources.sTexture2, vt.Table, uint32.MaxValue);
		vt.LastUsed = StreamingCore.Frame;
	}

	/// Sets up the feedback pass for a camera (its size, and the target): false when virtual textures cannot be drawn. The
	/// tiles the last read-back showed are handled on the way. The caller then submits the virtual textures' draws into
	/// FeedbackView with FeedbackProgram, each after Bind.
	public static bool BeginFeedback(int32 screenWidth, int32 screenHeight, Matrix4 view, Matrix4 projection)
	{
		if (!Supported || sAll.Count == 0)
			return false;
		let w = Math.Max(16, screenWidth / FeedbackDivide);
		let h = Math.Max(16, screenHeight / FeedbackDivide);
		if (w != sFbWidth || h != sFbHeight)
			MakeFeedback(w, h);
		if (!sFb.Valid)
			return false;
		var viewMatrix = view;
		var projMatrix = projection;
		bgfx.set_view_name(FeedbackView, "VT feedback", 11);
		bgfx.set_view_frame_buffer(FeedbackView, sFb);
		bgfx.set_view_rect(FeedbackView, 0, 0, (uint16)w, (uint16)h, 0, 1);
		bgfx.set_view_clear(FeedbackView, Gfx.ClearColor | Gfx.ClearDepth, 0, 1.0f, 0);
		bgfx.set_view_transform(FeedbackView, &viewMatrix, &projMatrix);
		bgfx.touch(FeedbackView);
		// The copy of last frame's picture runs before this view's draws.
		if (sFbState == 0 && sFbDrawn)
		{
			bgfx.TextureRegion to = default;
			to.handle = sFbRead;
			to.width = (uint16)w;
			to.height = (uint16)h;
			to.depth = 1;
			bgfx.TextureRegion from = default;
			from.handle = sFbColor;
			from.width = (uint16)w;
			from.height = (uint16)h;
			from.depth = 1;
			bgfx.blit(FeedbackView, &to, &from);
			sFbState = 1;
			sFbWait = 0;
		}
		sFbDrawn = true;
		sDrawnFrame = StreamingCore.Frame;
		return true;
	}

	static void MakeFeedback(int32 w, int32 h)
	{
		DestroyFeedback();
		sFbWidth = w;
		sFbHeight = h;
		let rt = Gfx.TextureRenderTarget;
		bgfx.TextureHandle[2] textures;
		textures[0] = bgfx.create_texture_2d((uint16)w, (uint16)h, false, 1, .RGBA8, rt | Gfx.SamplerClamp | Gfx.SamplerPoint, null, 0);
		textures[1] = bgfx.create_texture_2d((uint16)w, (uint16)h, false, 1, .D16, rt | Gfx.TextureWriteOnly, null, 0);
		sFbColor = textures[0];
		sFb = bgfx.create_frame_buffer_from_handles(2, &textures, true);
		sFbRead = bgfx.create_texture_2d((uint16)w, (uint16)h, false, 1, .RGBA8, (uint64)bgfx.TextureFlags.BlitDst | (uint64)bgfx.TextureFlags.ReadBack, null, 0);
		sFbData = new uint8[w * h * 4];
		sFbState = 0;
		sFbDrawn = false;
	}

	static void DestroyFeedback()
	{
		if (sFb.Valid)
			bgfx.destroy_frame_buffer(sFb);
		if (sFbRead.Valid)
			bgfx.destroy_texture(sFbRead);
		sFb = .() { idx = uint16.MaxValue };
		sFbRead = .() { idx = uint16.MaxValue };
		sFbColor = .() { idx = uint16.MaxValue };
		DeleteAndNullify!(sFbData);
	}

	/// The read-back's three steps: copied (BeginFeedback), asked for a few frames later, handled once the card has it.
	static void PollFeedback()
	{
		if (sFbData == null)
			return;
		if (sFbState == 1)
		{
			if (++sFbWait >= 3)
			{
				bgfx.TextureRegion region = default;
				region.handle = sFbRead;
				region.width = (uint16)sFbWidth;
				region.height = (uint16)sFbHeight;
				region.depth = 1;
				Internal.MemSet(sFbData.CArray(), 0, sFbData.Count);
				sFbReady = bgfx.read_texture(&region, sFbData.CArray());
				sFbState = 2;
				sFbWait = 0;
			}
		}
		else if (sFbState == 2 && ++sFbWait > 2 && bgfx.get_stats().gpuFrameNum >= sFbReady)
		{
			sFbState = 0;
			FeedbackReads++;
			UseFeedback();
		}
	}

	/// Asks for the tiles the pass wrote: every distinct pixel value once.
	static void UseFeedback()
	{
		sSeen.Clear();
		for (int p < sFbWidth * sFbHeight)
		{
			let o = p * 4;
			let id = sFbData[o + 3];
			if (id == 0)
				continue;
			let key = (uint32)sFbData[o] | ((uint32)sFbData[o + 1] << 8) | ((uint32)sFbData[o + 2] << 16) | ((uint32)id << 24);
			if (!sSeen.Add(key))
				continue;
			if (id > sAll.Count)
				continue;
			let vt = sAll[id - 1];
			let level = (int32)sFbData[o + 2];
			if (level >= vt.Levels)
				continue;
			let x = (int32)sFbData[o];
			let y = (int32)sFbData[o + 1];
			if (x >= vt.TilesX[level] || y >= vt.TilesY[level])
				continue;
			FinestWanted = Math.Min(FinestWanted, level);
			vt.Want(level, x, y);
		}
		TilesWanted = (int32)sSeen.Count;
	}

	/// Forgets every texture and the cache (the project closed, or the graphics were restarted).
	public static void Shutdown()
	{
		for (let vt in sAll)
		{
			StreamingCore.Unregister(vt.Res, vt.PageCount);
			if (Gfx.Initialized)
			{
				bgfx.destroy_texture(vt.Table);
				Textures.Sizes.Remove(vt.Tail.idx);
				bgfx.destroy_texture(vt.Tail);
			}
		}
		DeleteContainerAndItems!(sAll);
		sAll = new .();
		sByHandle.Clear();
		sByPath.Clear();
		sFree.Clear();
		if (Gfx.Initialized)
		{
			DestroyFeedback();
			if (Cache.Valid)
				bgfx.destroy_texture(Cache);
			if (LitProgram.Valid)
				bgfx.destroy_program(LitProgram);
			if (FeedbackProgram.Valid)
				bgfx.destroy_program(FeedbackProgram);
		}
		Cache = .() { idx = uint16.MaxValue };
		LitProgram = .() { idx = uint16.MaxValue };
		FeedbackProgram = .() { idx = uint16.MaxValue };
		sProgramsTried = false;
		sFbWidth = 0;
		sFbHeight = 0;
	}
}
