using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// How one picture is filtered: the default (linear between pixels, anisotropic on slanted surfaces) or nearest
/// (each pixel taken as it is), for pixel art and crisp masks (docs/textures.md).
enum TextureFilter : uint8
{
	Default,
	Nearest
}

/// How one picture repeats when its coordinates leave 0..1: repeat (the default), clamp to its edge, or mirror.
enum TextureWrap : uint8
{
	Repeat,
	Clamp,
	Mirror
}

/// One picture's own texture options, kept beside it as "<picture>.import" and read when it is loaded. A picture
/// with none gets the engine defaults (mip levels, anisotropic filtering, wrapped repeating, compressed in builds).
struct TextureOptions
{
	public TextureFilter Filter = .Default;
	public TextureWrap Wrap = .Repeat;
	/// Make mip levels (smaller copies for far and slanted surfaces). Off keeps the picture at its full size when
	/// drawn small, which is what pixel art wants: crisp pixels, no blending between sizes.
	public bool Mipmaps = true;
	/// Use the compressed copy a build makes (".ktx"): off loads the picture itself.
	public bool Compression = true;
	/// Keep every mip level even when a quality preset leaves the largest ones out (pixel art keeps its pixels).
	public bool FullResolution;

	/// Reads the keys the editor writes; unknown keys and lines are ignored, so a file from another version works.
	public static TextureOptions Parse(StringView text)
	{
		var options = TextureOptions();
		for (var line in text.Split('\n'))
		{
			let equals = line.IndexOf('=');
			if (equals < 0)
				continue;
			var key = line.Substring(0, equals);
			var value = line.Substring(equals + 1);
			key.Trim();
			value.Trim();
			switch (key)
			{
			case "filter": options.Filter = value == "nearest" ? .Nearest : .Default;
			case "wrap":
				if (value == "clamp")
					options.Wrap = .Clamp;
				else if (value == "mirror")
					options.Wrap = .Mirror;
				else
					options.Wrap = .Repeat;
			case "mipmaps": options.Mipmaps = value != "0";
			case "compression": options.Compression = value != "0";
			case "fullResolution": options.FullResolution = value != "0";
			}
		}
		return options;
	}

	/// The sampler flags for a picture with (or without) mip levels (bgfx returns to its defaults where none are set:
	/// linear, and repeat).
	public uint64 SamplerFlags(bool hasMips)
	{
		uint64 flags = 0;
		if (Filter == .Nearest)
		{
			flags |= (uint64)bgfx.SamplerFlags.MinPoint | (uint64)bgfx.SamplerFlags.MagPoint;
			if (hasMips)
				flags |= (uint64)bgfx.SamplerFlags.MipPoint;
		}
		else
			flags |= (uint64)bgfx.SamplerFlags.MinAnisotropic | (uint64)bgfx.SamplerFlags.MagAnisotropic;
		switch (Wrap)
		{
		case .Clamp:
			flags |= (uint64)bgfx.SamplerFlags.UClamp | (uint64)bgfx.SamplerFlags.VClamp | (uint64)bgfx.SamplerFlags.WClamp;
		case .Mirror:
			flags |= (uint64)bgfx.SamplerFlags.UMirror | (uint64)bgfx.SamplerFlags.VMirror | (uint64)bgfx.SamplerFlags.WMirror;
		case .Repeat:
		}
		return flags;
	}
}

/// Each picture's own options, read from "<picture>.import" the first time it is loaded and kept until the editor
/// changes them (Assets.RemoveTexture forgets them) or the game stops.
static class TextureOptionsFor
{
	static Dictionary<String, TextureOptions> sKnown = new .() ~ DeleteDictionaryAndKeys!(_);

	/// The options of a picture (the engine defaults when it has no .import beside it, or it cannot be read).
	public static TextureOptions Of(StringView path)
	{
		if (path.IsEmpty)
			return TextureOptions();
		if (sKnown.TryGetValueAlt(path, let known))
			return known;
		var options = TextureOptions();
		let text = scope String();
		if (AssetPack.ReadAllText(scope $"{path}.import", text) case .Ok)
			options = TextureOptions.Parse(text);
		sKnown[new String(path)] = options;
		return options;
	}

	/// Reads a picture's options again the next time it is loaded (the editor saved new ones).
	public static void Forget(StringView path)
	{
		if (sKnown.GetAndRemoveAlt(path) case .Ok(let pair))
			delete pair.key;
	}

	public static void ForgetAll()
	{
		for (let key in sKnown.Keys)
			delete key;
		sKnown.Clear();
	}
}
