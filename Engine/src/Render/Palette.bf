using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Palette images for palette materials (Material.palette, docs/materials.md): 256 colours, read left to right and
/// top to bottom from any image (a 16 x 16 picture is the usual layout; 256 x 1 works too). Each is made into an
/// exact 16 x 16 texture with no mip levels, no compression and no filtering, so a colour never bleeds into its
/// neighbour, whatever the quality settings.
static class Palettes
{
	public const int32 Size = 256;
	public const int32 Side = 16;

	class Entry
	{
		public bgfx.TextureHandle texture = .() { idx = uint16.MaxValue };
		public Color[Size] colors;
		public bool loaded;
	}

	static Dictionary<String, Entry> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static int32 sVersion = -1;

	/// The colours of a palette image (magenta where the image has fewer than 256 pixels or cannot be read).
	public static bool Colors(StringView path, ref Color[Size] colors)
	{
		let entry = Get(path);
		if (entry == null)
			return false;
		colors = entry.colors;
		return entry.loaded;
	}

	/// The palette's texture, or white when the path is empty.
	public static bgfx.TextureHandle Texture(StringView path)
	{
		let entry = Get(path);
		if (entry == null || !entry.texture.Valid)
			return Gfx.WhiteTexture;
		return entry.texture;
	}

	/// A starting palette: the first row greys from black to white, then a row for each of fifteen hues, from dark to
	/// light along the row.
	public static void Starter(ref Color[Size] colors)
	{
		for (int column < Side)
		{
			let grey = column / (float)(Side - 1);
			colors[column] = .(grey, grey, grey, 1);
		}
		for (int row = 1; row < Side; row++)
		{
			let hue = (row - 1) / 15.0f;
			for (int column < Side)
			{
				let t = column / (float)(Side - 1);
				// Dark and saturated to light and pale along the row.
				let lightness = 0.08f + t * 0.84f;
				let saturation = 0.85f - Math.Max(t - 0.6f, 0) * 1.2f;
				colors[row * Side + column] = FromHsl(hue, saturation, lightness);
			}
		}
	}

	static Color FromHsl(float h, float s, float l)
	{
		float Channel(float n)
		{
			let k = (n + h * 12) % 12;
			let a = s * Math.Min(l, 1 - l);
			return l - a * Math.Max(-1, Math.Min(Math.Min(k - 3, 9 - k), 1));
		}
		return .(Channel(0), Channel(8), Channel(4), 1);
	}

	/// Writes a palette image (16 x 16, as the colours are laid out) into the project, and uses it at once
	/// everywhere it is drawn. False when the file cannot be written.
	public static bool Save(StringView path, Color[Size] colors)
	{
		var colors;
		uint8[Size * 4] bytes = default;
		for (int i < Size)
		{
			let packed = colors[i].ToABGR();
			bytes[i * 4] = (uint8)(packed & 0xFF);
			bytes[i * 4 + 1] = (uint8)((packed >> 8) & 0xFF);
			bytes[i * 4 + 2] = (uint8)((packed >> 16) & 0xFF);
			bytes[i * 4 + 3] = (uint8)(packed >> 24);
		}
		let full = scope String();
		Assets.ResolvePath(path, full);
		let folder = scope String();
		System.IO.Path.GetDirectoryPath(full, folder);
		if (!folder.IsEmpty)
			System.IO.Directory.CreateDirectory(folder).IgnoreError();
		if (!Native.tn_image_write_png(full.CStr(), &bytes, Side, Side))
			return false;
		// Replace what is cached, so the new colours draw from the next frame.
		if (sCache.GetAndRemoveAlt(path) case .Ok(let removed))
		{
			if (removed.value.texture.Valid && Gfx.Initialized)
				bgfx.destroy_texture(removed.value.texture);
			delete removed.key;
			delete removed.value;
		}
		return true;
	}

	/// Forgets every palette, so the next use reads the images again (the editor after a picture changes).
	public static void Clear()
	{
		for (let (path, entry) in sCache)
		{
			if (entry.texture.Valid && Gfx.Initialized)
				bgfx.destroy_texture(entry.texture);
			delete path;
			delete entry;
		}
		sCache.Clear();
	}

	static Entry Get(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sVersion != Assets.TextureVersion)
		{
			Clear();
			sVersion = Assets.TextureVersion;
		}
		if (sCache.TryGetValueAlt(path, let found))
			return found;
		let entry = new Entry();
		sCache[new String(path)] = entry;
		for (int i < Size)
			entry.colors[i] = .(1, 0, 1, 1);
		let full = scope String();
		Assets.ResolvePath(path, full);
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(full.CStr(), &width, &height);
		uint8[Size * 4] bytes = default;
		for (int i < Size)
		{
			bytes[i * 4] = 255;
			bytes[i * 4 + 2] = 255;
			bytes[i * 4 + 3] = 255;
		}
		if (pixels != null)
		{
			let count = Math.Min((int)width * height, Size);
			for (int i < count * 4)
				bytes[i] = pixels[i];
			Native.tn_image_free(pixels);
			entry.loaded = true;
		}
		else
			Log.Warning(scope $"Could not load palette {path}");
		for (int i < Size)
			entry.colors[i] = .FromBytes(bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]);
		if (Gfx.Initialized)
		{
			let flags = (uint64)(bgfx.SamplerFlags.Point | bgfx.SamplerFlags.UvwClamp);
			entry.texture = bgfx.create_texture_2d((uint16)Side, (uint16)Side, false, 1, .RGBA8, flags, bgfx.copy(&bytes, (uint32)bytes.Count), 0);
		}
		return entry;
	}
}
