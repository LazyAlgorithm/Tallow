using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// The player's choices about the screen effects, for a game's settings menu. The scene decides how much ambient
/// occlusion, depth of field and motion blur it has (SceneEnvironment); these let a player turn each off, or tone
/// motion blur down, and set the brightness. They are plain static fields: a game keeps them with its own saved
/// settings and copies them here when they change (docs/post-processing.md has an example).
static class ScreenEffects
{
	/// Ambient occlusion, depth of field and motion blur cost a second pass over the scene's solid objects and several
	/// full-screen steps; Gfx.UseMobileQuality turns all three off. Colour grading is always on: it costs nothing.
	public static bool AmbientOcclusion = true;
	public static bool DepthOfField = true;
	public static bool MotionBlur = true;
	/// The scene mirrored in water (Water.screenReflections), found on the screen: a few dozen depth reads a pixel of
	/// water. Off, water mirrors the sky and reflection probes only. Follows the Reflection Probes quality setting.
	public static bool WaterReflections = true;
	/// Scales the scene's motion blur: 0 none, 1 as the scene has it, up to 2.
	public static float MotionBlurAmount = 1;
	/// Multiplies the scene's exposure: the usual "brightness" setting. 0.25 to 4; 1 leaves it alone.
	public static float Brightness = 1;

	/// Everything back to the defaults.
	public static void Reset()
	{
		AmbientOcclusion = true;
		DepthOfField = true;
		MotionBlur = true;
		MotionBlurAmount = 1;
		Brightness = 1;
	}
}

/// Colour lookup tables for the scene's colour grading (SceneEnvironment.colorLookup). See docs/post-processing.md.
///
/// A lookup table is an image of `size` squares side by side, each `size` x `size` pixels: within a square red grows
/// to the right and green downwards, and blue grows from square to square. A neutral table changes nothing; open one
/// in any image editor with a screenshot of the game, grade the two together, and save the table.
static class PostProcess
{
	/// Sizes a lookup table may have (16 x 16 squares is 256 x 16 pixels; 32 is 1024 x 32).
	public const int32 MinLookupSize = 2;
	public const int32 MaxLookupSize = 64;

	struct Lookup
	{
		public bgfx.TextureHandle texture;
		public int32 size;
	}

	static Dictionary<String, Lookup> sLookups = new .() ~ { for (let entry in _) delete entry.key; delete _; };

	/// The pixels (RGBA, 4 bytes each, rows top to bottom) of a neutral lookup table of `size` squares.
	public static void MakeNeutralLookup(int32 size, List<uint8> pixels)
	{
		let n = Math.Clamp(size, MinLookupSize, MaxLookupSize);
		let width = n * n;
		pixels.Clear();
		for (int32 y < n)
		{
			for (int32 x < width)
			{
				pixels.Add((uint8)((x % n) * 255 / (n - 1)));
				pixels.Add((uint8)(y * 255 / (n - 1)));
				pixels.Add((uint8)((x / n) * 255 / (n - 1)));
				pixels.Add(255);
			}
		}
	}

	/// Writes a neutral lookup table to a PNG file on disk (the editor's Make Neutral Lookup Table). True when saved.
	public static bool SaveNeutralLookup(StringView filePath, int32 size = 16)
	{
		List<uint8> pixels = scope .();
		MakeNeutralLookup(size, pixels);
		let n = Math.Clamp(size, MinLookupSize, MaxLookupSize);
		return Native.tn_image_write_png(scope String(filePath).CStr(), pixels.Ptr, n * n, n);
	}

	/// The size (squares) of a lookup table image `width` x `height` pixels, or 0 when it is not one.
	public static int32 LookupSize(int32 width, int32 height)
	{
		if (height < MinLookupSize || height > MaxLookupSize || width != height * height)
			return 0;
		return height;
	}

	/// What a lookup table (its pixels, `size` squares) turns a colour (0 to 1, display brightness) into, worked out
	/// the way the tonemapping shader does it, including blending between neighbouring entries.
	public static Color Apply(List<uint8> pixels, int32 size, Color color)
	{
		let n = (float)size;
		let blue = Math.Clamp(color.b, 0.0f, 1.0f) * (n - 1);
		let s0 = Math.Floor(blue);
		let s1 = Math.Min(s0 + 1, n - 1);
		let x = (Math.Clamp(color.r, 0.0f, 1.0f) * (n - 1) + 0.5f) / (n * n);
		let y = (Math.Clamp(color.g, 0.0f, 1.0f) * (n - 1) + 0.5f) / n;
		return Color.Lerp(Texel(pixels, size, x + s0 / n, y), Texel(pixels, size, x + s1 / n, y), blue - s0);
	}

	// One bilinear sample of a lookup table's pixels, as the graphics card takes it.
	static Color Texel(List<uint8> pixels, int32 size, float u, float v)
	{
		let width = size * size;
		let fx = Math.Clamp(u * width - 0.5f, 0.0f, (float)(width - 1));
		let fy = Math.Clamp(v * size - 0.5f, 0.0f, (float)(size - 1));
		let x0 = (int)fx, y0 = (int)fy;
		let x1 = Math.Min(x0 + 1, (int)width - 1), y1 = Math.Min(y0 + 1, (int)size - 1);
		let tx = fx - x0, ty = fy - y0;
		return Color.Lerp(Color.Lerp(Pixel(pixels, width, x0, y0), Pixel(pixels, width, x1, y0), tx), Color.Lerp(Pixel(pixels, width, x0, y1), Pixel(pixels, width, x1, y1), tx), ty);
	}

	static Color Pixel(List<uint8> pixels, int width, int x, int y)
	{
		let i = (y * width + x) * 4;
		return .(pixels[i] / 255.0f, pixels[i + 1] / 255.0f, pixels[i + 2] / 255.0f, 1);
	}

	/// The scene's lookup table on the graphics card, loaded once, and its size; size 0 when there is none or the
	/// image is not a lookup table.
	public static bgfx.TextureHandle GetLookup(StringView path, out int32 size)
	{
		size = 0;
		if (path.IsEmpty || !Gfx.Initialized)
			return Gfx.WhiteTexture;
		if (sLookups.TryGetValueAlt(path, let cached))
		{
			size = cached.size;
			return cached.texture;
		}
		Lookup entry = .() { texture = Gfx.WhiteTexture, size = 0 };
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(Assets.ResolvePath(path, .. scope .()).CStr(), &width, &height);
		if (pixels == null)
			Log.Warning(scope $"Could not load the colour lookup table {path}");
		else
		{
			let lookupSize = LookupSize(width, height);
			if (lookupSize == 0)
				Log.Warning(scope $"{path} is not a colour lookup table: it should be a strip of square tiles, such as 256 x 16 or 1024 x 32 pixels");
			else
			{
				// Clamped and smoothly filtered: the shader blends between entries.
				entry.texture = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA8, Gfx.SamplerClamp, bgfx.copy(pixels, (uint32)(width * height * 4)), 0);
				entry.size = lookupSize;
			}
			Native.tn_image_free(pixels);
		}
		sLookups[new String(path)] = entry;
		size = entry.size;
		return entry.texture;
	}

	/// Sets scene settings from a list such as "ao=1,radius=0.8,dof=0.6,focus=12,range=6,autofocus=1,motion=0.5,
	/// contrast=1.1,saturation=0.9,temperature=0.2,tint=0,vignette=0.5,lut=Grading/warm.png,lutstrength=1":
	/// the `--effects` command line option, for trying a scene with effects without editing it. Unknown names are
	/// skipped. Returns how many were set.
	public static int ApplySettings(StringView list, SceneEnvironment env)
	{
		int count = 0;
		for (let entry in list.Split(','))
		{
			let equals = entry.IndexOf('=');
			if (equals <= 0)
				continue;
			let name = scope String(entry.Substring(0, equals))..Trim()..ToLower();
			let text = scope String(entry.Substring(equals + 1))..Trim();
			float value = 0;
			if (float.Parse(text) case .Ok(let number))
				value = number;
			bool known = true;
			switch (name)
			{
			case "ao": env.ambientOcclusion = value;
			case "radius": env.occlusionRadius = value;
			case "dof": env.depthOfField = value;
			case "focus": env.focusDistance = value;
			case "range": env.focusRange = value;
			case "autofocus": env.autoFocus = value != 0;
			case "motion": env.motionBlur = value;
			case "contrast": env.contrast = value;
			case "saturation": env.saturation = value;
			case "temperature": env.temperature = value;
			case "tint": env.tint = value;
			case "vignette": env.vignette = value;
			case "lut": env.colorLookup.Set(text);
			case "lutstrength": env.colorLookupStrength = value;
			default: known = false;
			}
			if (known)
				count++;
		}
		return count;
	}

	/// Forgets loaded lookup tables, so a changed image is read again (the editor calls this when a file changes).
	public static void ForgetLookups()
	{
		for (let entry in sLookups)
		{
			if (entry.value.size > 0 && Gfx.Initialized)
				bgfx.destroy_texture(entry.value.texture);
			delete entry.key;
		}
		sLookups.Clear();
	}
}
