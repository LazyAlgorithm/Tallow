using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// What a texture holds, which decides how its smaller mip levels are made (docs/textures.md).
enum TextureKind
{
	/// A colour picture (albedo, emissive, interface): averaged in linear light.
	Color,
	/// Numbers that are not a colour (metal / roughness, occlusion, masks, lightmaps): averaged as stored.
	Data,
	/// A normal map: the directions averaged and made unit length again.
	Normal
}

/// Making textures for the graphics card: every one gets its mip levels (smaller copies, so that far away and slanted
/// surfaces are not grainy and shimmer free) and anisotropic filtering, and a build's compressed copies (`.ktx`, BC1 /
/// BC3, made by tools/build_player.py) are used where they exist. Quality.Current.textureDetail and anisotropic set it.
static class Textures
{
	/// How many of the largest mip levels are left out of textures made from now on: 1 halves each side (a quarter of
	/// the memory). Set by the quality presets; textures already made keep theirs.
	public static int32 SkipLevels = 0;
	/// Use compressed `.ktx` copies of pictures where they exist (a built game has them).
	public static bool UseCompressed = true;
	/// Make mip levels (off only to compare: `--no-mipmaps`).
	public static bool Mipmaps = true;

	/// Textures made, the compressed ones among them, and the bytes on the graphics card, since the start.
	public static int32 Made, Compressed;
	public static int64 Bytes;
	/// Each texture made here and its size on the graphics card, by handle (for the Profiler's memory snapshots).
	public static Dictionary<uint16, int64> Sizes = new .() ~ delete _;

	const uint64 Filtering = (uint64)bgfx.SamplerFlags.MinAnisotropic | (uint64)bgfx.SamplerFlags.MagAnisotropic;

	static Dictionary<String, TextureKind> sKinds = new .() ~ DeleteDictionaryAndKeys!(_);

	/// Says what a texture holds before it is loaded (a material naming it as its normal map, say).
	public static void Hint(StringView path, TextureKind kind)
	{
		if (path.IsEmpty || kind == .Color)
			return;
		if (sKinds.TryGetAlt(path, let key, ?))
			sKinds[key] = kind;
		else
			sKinds[new String(path)] = kind;
	}

	/// What a texture holds: as hinted, else a normal map if its file is named so ("rock_normal.png", "NormalMap"),
	/// else a colour.
	public static TextureKind KindOf(StringView path)
	{
		if (sKinds.TryGetValueAlt(path, let kind))
			return kind;
		var name = path;
		let slash = name.LastIndexOf('/');
		if (slash >= 0)
			name = name.Substring(slash + 1);
		// Baked lightmaps (docs/baked-lighting.md) hold light, not colour.
		if (name.StartsWith("Lightmap-"))
			return .Data;
		return name.IndexOf("normal", true) >= 0 ? .Normal : .Color;
	}

	/// What each image in a glTF scene holds, from the materials that use it (normal, metal / roughness and
	/// occlusion images; any other is a colour).
	public static TextureKind GltfImageKind(void* scene, int32 image)
	{
		for (uint32 p < Native.tn_gltf_prim_count(scene))
		{
			let prim = Native.tn_gltf_get_prim(scene, p);
			if (prim.normalImage == image)
				return .Normal;
			if (prim.metalRoughImage == image || prim.occlusionImage == image)
				return .Data;
		}
		return .Color;
	}

	/// A texture from RGBA8 pixels, with all its mip levels (less SkipLevels). The pixels are copied.
	public static bgfx.TextureHandle Create(uint8* pixels, int32 width, int32 height, TextureKind kind)
	{
		int32 w = 0, h = 0, levels = 0;
		uint32 size = 0;
		let mips = Mipmaps ? tn_image_mips(pixels, width, height, (int32)kind, SkipLevels, &w, &h, &levels, &size) : null;
		if (mips == null)
			return bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA8, Filtering, bgfx.copy(pixels, (uint32)(width * height * 4)), 0);
		let texture = bgfx.create_texture_2d((uint16)w, (uint16)h, levels > 1, 1, .RGBA8, Filtering, bgfx.copy(mips, size), 0);
		tn_image_mips_free(mips);
		Made++;
		Bytes += size;
		Sizes[texture.idx] = size;
		return texture;
	}

	/// The compressed copy of a picture (`<file>.ktx` beside it or in the game's pack), or an invalid handle when
	/// there is none.
	public static bgfx.TextureHandle LoadCompressed(StringView path)
	{
		bgfx.TextureHandle none = .() { idx = uint16.MaxValue };
		if (!UseCompressed)
			return none;
		let ktx = scope String(path)..Append(".ktx");
		if (!AssetPack.Exists(ktx))
			return none;
		List<uint8> data = scope .();
		if (AssetPack.ReadAll(ktx, data) case .Err || data.Count < 64)
			return none;
		bgfx.TextureInfo info = default;
		// bgfx reads the file's format and levels, and leaves out the largest ones; a card without BC1 / BC3 gets it
		// decoded to plain colour.
		let texture = bgfx.create_texture(bgfx.copy(data.Ptr, (uint32)data.Count), Filtering, (uint8)Math.Clamp(SkipLevels, 0, 8), &info);
		if (texture.Valid)
		{
			Made++;
			Compressed++;
			Bytes += info.storageSize;
			Sizes[texture.idx] = info.storageSize;
		}
		return texture;
	}

	/// Writes how many textures were made, how many from compressed copies, and their size on the graphics card.
	public static void LogTotals()
	{
		if (Made > 0)
			Log.Info(scope $"Textures: {Made} made, {Compressed} compressed, {Bytes / (1024.0 * 1024.0):0.0} MB on the graphics card");
	}

	/// Mip levels of an RGBA8 image on the CPU (for tests): the first level's size, the levels and the bytes.
	public static uint8[] MakeMips(Span<uint8> pixels, int32 width, int32 height, TextureKind kind, int32 skip, out int32 levelWidth, out int32 levelHeight, out int32 levels)
	{
		int32 w = 0, h = 0, count = 0;
		uint32 size = 0;
		let mips = tn_image_mips(pixels.Ptr, width, height, (int32)kind, skip, &w, &h, &count, &size);
		levelWidth = w;
		levelHeight = h;
		levels = count;
		if (mips == null)
			return null;
		if ((uint64)size > (uint64)int.MaxValue)
		{
			tn_image_mips_free(mips);
			return null;
		}
		let result = new uint8[(int)size];
		Internal.MemCpy(result.Ptr, mips, (int)size);
		tn_image_mips_free(mips);
		return result;
	}

	[CLink] static extern uint8* tn_image_mips(uint8* pixels, int32 width, int32 height, int32 kind, int32 skip, int32* outWidth, int32* outHeight, int32* outLevels, uint32* outSize);
	[CLink] static extern void tn_image_mips_free(uint8* mips);
}
