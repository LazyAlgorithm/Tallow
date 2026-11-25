using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

/// One big texture whose mip levels stream in (M4c). Its `.tmips` file (cooked beside the picture the first time it is
/// used) has one page for each level that is bigger than 64 px: page j is the whole mip chain from level j down, so a
/// page alone makes a texture and nothing is copied or kept on the CPU. The last page (the "tail", chain <= 64 px) is
/// read when the texture is made and never evicted, so the texture is never blank or black. One more page holds the
/// picture's size and kind.
///
/// The texture shows its Tail handle until a bigger page arrives; then Assets swaps the handle to a texture made from
/// that page (Assets.TextureVersion makes materials look it up again) and the old one is destroyed. Pages are requested
/// from the wanted level (StreamedTextures.Note: how many pixels the surface covers), upgrades at once, downgrades after
/// DowngradeFrames of wanting less. The StreamPool for TextureMip evicts a Top page that goes cold or when the budget
/// is over, and the texture falls back to its Tail.
class StreamedTexture : IStreamConsumer
{
	public StreamResource Res ~ delete _;
	public PageFile File ~ delete _;
	public String Path = new .() ~ delete _;
	public int32 Width, Height, Levels;
	public TextureKind Kind;
	public uint64 Flags;
	/// The always resident page (the smallest chain that is cooked), and the first page that may be used (the cap).
	public int32 TailPage, MinPage;
	public bgfx.TextureHandle Tail = .() { idx = uint16.MaxValue };
	public bgfx.TextureHandle Top = .() { idx = uint16.MaxValue };
	/// The page Top was made from, -1 when it shows the tail.
	public int32 TopPage = -1;
	/// The page asked for last, and when.
	public int32 Requested = -1;
	public int RequestedFrame = -1000;
	/// The most pixels a surface covered this frame (0: not used), the level that wants, how long a smaller one has
	/// been wanted, and when it was last used.
	public float Pixels;
	public int32 Wanted;
	public int DowngradeFrames;
	public int LastUsed;

	public int32 CurrentPage => TopPage < 0 ? TailPage : TopPage;
	public bgfx.TextureHandle Current => TopPage < 0 ? Tail : Top;

	public int32 LevelWidth(int32 page) => Math.Max(1, Width >> page);
	public int32 LevelHeight(int32 page) => Math.Max(1, Height >> page);

	public bool Upload(StreamResource resource, int page, Span<uint8> data)
	{
		let p = (int32)page;
		let upgrade = TopPage < 0 ? p < TailPage : p < TopPage;
		let wantedDown = p > TopPage && TopPage >= 0 && p == Requested && p < TailPage;
		if (!upgrade && !wantedDown)
			return false;
		let handle = bgfx.create_texture_2d((uint16)LevelWidth(p), (uint16)LevelHeight(p), Levels - p > 1, 1, .RGBA8, Flags, bgfx.copy(data.Ptr, (uint32)data.Length), 0);
		if (!handle.Valid)
			return false;
		Textures.Sizes[handle.idx] = data.Length;
		let pool = StreamingCore.Pool(.TextureMip);
		if (TopPage >= 0)
		{
			pool.Remove(Res.Id, TopPage, StreamingCore.Frame);
			Destroy(Top);
		}
		Top = handle;
		TopPage = p;
		StreamedTextures.Adopt(this, handle);
		Assets.SwapTexture(Path, handle);
		return true;
	}

	/// Back to the tail alone (the top page was evicted or went unused).
	public void DropTop()
	{
		if (TopPage < 0)
			return;
		Destroy(Top);
		Top = .() { idx = uint16.MaxValue };
		TopPage = -1;
		Requested = -1;
		Assets.SwapTexture(Path, Tail);
	}

	void Destroy(bgfx.TextureHandle handle)
	{
		StreamedTextures.Unmap(handle.idx);
		Textures.Sizes.Remove(handle.idx);
		bgfx.destroy_texture(handle);
	}

	/// Frees the graphics card's textures but the one `except` names (the caller destroys that).
	public void ReleaseExcept(uint16 except)
	{
		if (Top.Valid && Top.idx != except)
			Destroy(Top);
		if (Tail.Valid && Tail.idx != except)
			Destroy(Tail);
	}
}

/// The texture streaming system: makes streamed textures, tracks what the renderer asks of them each frame and requests
/// pages. Main thread only.
static class StreamedTextures
{
	/// On unless --no-texture-streaming.
	public static bool Enabled = true;
	/// Only pictures at least this many pixels on a side are streamed; smaller ones load whole.
	public static int32 MinSize = 512;
	/// A smaller level wanted for this long before it replaces a bigger one.
	public const int DowngradeFrames = 60;
	/// A texture unused this long goes back to its tail.
	public const int UnusedFrames = 600;
	/// Counters for tests and the profiler.
	public static int32 Made, Swaps, Drops;

	const int Meta = 16;
	/// Chains this small or smaller are the tail.
	const int TailSize = 64;
	const uint32 CookVersion = 1;

	static List<StreamedTexture> sAll = new .() ~ DeleteContainerAndItems!(_);
	static Dictionary<uint16, StreamedTexture> sByHandle = new .() ~ delete _;
	static Dictionary<String, StreamedTexture> sByPath = new .() ~ delete _;
	static uint64 sNextId;

	public static int Count => sAll.Count;
	public static bool Active => Enabled && sAll.Count > 0;

	public static StreamedTexture Find(StringView path) => sByPath.TryGetValueAlt(path, let st) ? st : null;
	public static void ForEach(delegate void(StreamedTexture) each)
	{
		for (let st in sAll)
			each(st);
	}

	/// Makes the streamed texture for a picture: its tail, ready to draw at once. An invalid handle when it should
	/// load whole (too small, no cooked copy and none can be made, streaming off).
	public static bgfx.TextureHandle TryCreate(StringView path, StringView full, TextureKind kind)
	{
		bgfx.TextureHandle none = .() { idx = uint16.MaxValue };
		if (!Enabled || !Gfx.Initialized || StreamingCore.Pool(.TextureMip) == null || !Textures.Mipmaps)
			return none;
		let options = TextureOptionsFor.Of(path);
		if (!options.Mipmaps)
			return none;
		// A picture in a game's pack streams from the .tmips the export cooked into it (ranged reads through the
		// pack); nothing is cooked at run time there. A loose picture is cooked beside itself the first time.
		let packed = AssetPack.Contains(full);
		if (!packed && !File.Exists(full))
			return none;
		let cooked = scope String(full)..Append(".tmips");
		let file = new PageFile();
		var ok = (file.Open(cooked) case .Ok) && Valid(file, kind, cooked, full, packed);
		if (!ok && !packed)
		{
			if (!Cook(full, cooked, kind, options.FullResolution))
			{
				delete file;
				return none;
			}
			ok = (file.Open(cooked) case .Ok) && Valid(file, kind, cooked, full, false);
		}
		if (!ok)
		{
			delete file;
			return none;
		}
		let metaPage = file.PageCount - 1;
		let meta = scope List<uint8>();
		let tailBytes = scope List<uint8>();
		if (file.Read(metaPage, meta) case .Err || meta.Count < Meta || file.Read(metaPage - 1, tailBytes) case .Err)
		{
			delete file;
			return none;
		}
		let st = new StreamedTexture();
		st.File = file;
		st.Path.Set(path);
		st.Width = (int32)U32(&meta[0]);
		st.Height = (int32)U32(&meta[4]);
		st.Kind = kind;
		st.TailPage = (int32)(metaPage - 1);
		let total = Levels(st.Width, st.Height);
		st.Levels = total;
		st.MinPage = options.FullResolution ? 0 : (int32)Math.Clamp(Textures.SkipLevels, 0, st.TailPage);
		st.Flags = options.SamplerFlags(true);
		st.Tail = bgfx.create_texture_2d((uint16)st.LevelWidth(st.TailPage), (uint16)st.LevelHeight(st.TailPage), total - st.TailPage > 1, 1, .RGBA8, st.Flags, bgfx.copy(tailBytes.Ptr, (uint32)tailBytes.Count), 0);
		if (!st.Tail.Valid)
		{
			delete st;
			return none;
		}
		Textures.Sizes[st.Tail.idx] = tailBytes.Count;
		st.Res = new StreamResource();
		st.Res.Id = ++sNextId;
		st.Res.Kind = .TextureMip;
		st.Res.File = file;
		st.Res.Consumer = st;
		StreamingCore.Register(st.Res);
		let pool = StreamingCore.Pool(.TextureMip);
		pool.Add(st.Res.Id, st.TailPage, tailBytes.Count, StreamingCore.Frame, true);
		if (pool.OnEvict == null)
			pool.OnEvict = new => OnEvict;
		sAll.Add(st);
		sByHandle[st.Tail.idx] = st;
		sByPath[st.Path] = st;
		st.LastUsed = StreamingCore.Frame;
		st.Wanted = st.TailPage;
		Made++;
		return st.Tail;
	}

	static bool Valid(PageFile file, TextureKind kind, StringView cooked, StringView source, bool packed)
	{
		if (file.Kind != .TextureMip || file.PageCount < 3)
			return false;
		let meta = scope List<uint8>();
		if (file.Read(file.PageCount - 1, meta) case .Err || meta.Count < Meta)
			return false;
		if (U32(&meta[8]) != (uint32)kind || U32(&meta[12]) != CookVersion)
			return false;
		// A picture changed after it was cooked is cooked again (a pack's files were cooked together).
		if (!packed && File.GetLastWriteTime(source) case .Ok(let sourceTime) && File.GetLastWriteTime(cooked) case .Ok(let cookedTime) && sourceTime > cookedTime)
			return false;
		return true;
	}

	static int32 Levels(int32 w, int32 h)
	{
		int32 levels = 1;
		var x = w;
		var y = h;
		while (x > 1 || y > 1)
		{
			x = Math.Max(1, x / 2);
			y = Math.Max(1, y / 2);
			levels++;
		}
		return levels;
	}

	/// Writes the `.tmips` of a picture. False if it cannot be read or written, or is too small to stream.
	public static bool Cook(StringView full, StringView cooked, TextureKind kind, bool fullResolution)
	{
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(scope String(full).CStr(), &width, &height);
		if (pixels == null)
			return false;
		defer Native.tn_image_free(pixels);
		if (Math.Max(width, height) < MinSize)
			return false;
		int32 w = 0, h = 0, levels = 0;
		let mips = Textures.MakeMips(.(pixels, width * height * 4), width, height, kind, 0, out w, out h, out levels);
		if (mips == null)
			return false;
		defer delete mips;
		// Where each level starts in the chain.
		let starts = scope List<int>();
		var offset = 0;
		var lw = width;
		var lh = height;
		var tail = -1;
		for (int i < levels)
		{
			starts.Add(offset);
			if (tail < 0 && Math.Max(lw, lh) <= TailSize)
				tail = i;
			offset += lw * lh * 4;
			lw = Math.Max(1, lw / 2);
			lh = Math.Max(1, lh / 2);
		}
		if (tail <= 0)
			return false;
		let pages = scope List<List<uint8>>();
		defer { for (let page in pages) delete page; }
		for (int i <= tail)
		{
			let page = new List<uint8>();
			page.AddRange(Span<uint8>(&mips[starts[i]], mips.Count - starts[i]));
			pages.Add(page);
		}
		let meta = new List<uint8>();
		Put32(meta, (uint32)width);
		Put32(meta, (uint32)height);
		Put32(meta, (uint32)kind);
		Put32(meta, CookVersion);
		pages.Add(meta);
		let temp = scope String(cooked)..Append(".tmp");
		if (PageFile.Write(temp, .TextureMip, pages, false) case .Err)
			return false;
		File.Delete(cooked);
		return File.Move(temp, cooked) case .Ok;
	}

	static void OnEvict(uint64 resource, int page)
	{
		for (let st in sAll)
		{
			if (st.Res.Id == resource)
			{
				if (page == st.TopPage)
				{
					Drops++;
					st.DropTop();
				}
				return;
			}
		}
	}

	/// Remembers that a texture handle belongs to st (a new Top).
	public static void Adopt(StreamedTexture st, bgfx.TextureHandle handle)
	{
		sByHandle[handle.idx] = st;
		Swaps++;
	}

	public static void Unmap(uint16 idx) => sByHandle.Remove(idx);

	/// Says a surface that shows this texture covers `pixels` pixels across this frame (times its tiling): the most of
	/// the frame counts.
	public static void Note(uint16 idx, float pixels)
	{
		if (sByHandle.TryGetValue(idx, let st) && pixels > st.Pixels)
			st.Pixels = pixels;
	}

	public static void NotePath(StringView path, float pixels)
	{
		if (path.IsEmpty)
			return;
		if (sByPath.TryGetValueAlt(path, let st) && pixels > st.Pixels)
			st.Pixels = pixels;
	}

	/// The level a texture covering `pixels` pixels across needs: the smallest chain whose top level still has at least
	/// one texel for each pixel.
	public static int32 WantedLevel(StreamedTexture st, float pixels)
	{
		if (pixels <= 0.5f)
			return st.TailPage;
		let ratio = (float)Math.Max(st.Width, st.Height) / pixels;
		int32 level = ratio <= 1 ? 0 : (int32)Math.Floor(Math.Log(ratio) / Math.Log(2.0f));
		return Math.Clamp(level, (int32)st.MinPage, (int32)st.TailPage);
	}

	/// Once a frame after StreamingCore.Update: asks for the pages the last frame's drawing wanted, and lets go of
	/// bigger ones that are not used.
	public static void Update(int frame)
	{
		let pool = StreamingCore.Pool(.TextureMip);
		if (pool == null)
			return;
		for (let st in sAll)
		{
			let pixels = st.Pixels;
			if (pixels > 0)
			{
				st.LastUsed = frame;
				st.Wanted = WantedLevel(st, pixels);
				st.Pixels = 0;
			}
			else if (frame - st.LastUsed > UnusedFrames)
			{
				st.Wanted = st.TailPage;
				if (st.TopPage >= 0)
				{
					Drops++;
					pool.Remove(st.Res.Id, st.TopPage, frame);
					st.DropTop();
				}
				continue;
			}
			else
			{
				// Not on screen this frame: keep what it has warm for a while, ask for nothing.
				if (st.TopPage >= 0 && frame - st.LastUsed <= StreamPool.RecentFrames)
					pool.Touch(st.Res.Id, st.TopPage, frame);
				continue;
			}
			let current = st.CurrentPage;
			if (st.TopPage >= 0)
				pool.Touch(st.Res.Id, st.TopPage, frame);
			if (st.Wanted < current)
			{
				st.DowngradeFrames = 0;
				Ask(st, st.Wanted, frame, pixels);
			}
			else if (st.Wanted > current)
			{
				// Smaller is wanted: a bigger texture that is not needed any more goes, but not at once.
				if (++st.DowngradeFrames >= DowngradeFrames)
				{
					if (st.Wanted >= st.TailPage)
					{
						Drops++;
						pool.Remove(st.Res.Id, st.TopPage, frame);
						st.DropTop();
					}
					else
						Ask(st, st.Wanted, frame, pixels);
					st.DowngradeFrames = 0;
				}
			}
			else
				st.DowngradeFrames = 0;
		}
	}

	static void Ask(StreamedTexture st, int32 page, int frame, float pixels)
	{
		if (page >= st.TailPage || page == st.Requested && frame - st.RequestedFrame < 30)
			return;
		st.Requested = page;
		st.RequestedFrame = frame;
		// What covers more of the screen first.
		StreamingCore.Request(st.Res, page, pixels);
	}

	/// Frees everything about the texture that has this handle (before the caller destroys that handle). False if the
	/// handle is not a streamed texture's.
	public static bool Release(uint16 idx)
	{
		if (!sByHandle.TryGetValue(idx, let st))
			return false;
		if (StreamingCore.Pool(.TextureMip) != null)
			StreamingCore.Unregister(st.Res, st.File.PageCount);
		st.ReleaseExcept(idx);
		sByHandle.Remove(st.Tail.idx);
		if (st.Top.Valid)
			sByHandle.Remove(st.Top.idx);
		sByPath.Remove(st.Path);
		Textures.Sizes.Remove(st.Tail.idx);
		Textures.Sizes.Remove(st.Top.idx);
		sAll.Remove(st);
		delete st;
		return true;
	}

	static uint32 U32(uint8* p) => (uint32)p[0] | ((uint32)p[1] << 8) | ((uint32)p[2] << 16) | ((uint32)p[3] << 24);
	static void Put32(List<uint8> data, uint32 v) { for (int i < 4) data.Add((uint8)(v >> (i * 8))); }
}
