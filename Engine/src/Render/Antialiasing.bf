using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// How the edges of the 3D picture are smoothed (the Antialiasing quality setting; tallowengine.com/docs/quality).
/// The numbers are what graphics.cfg and the C# API store.
enum AntialiasMode : int32
{
	/// Jagged edges, the cheapest.
	Off,
	/// A fast filter on the finished picture (a fraction of a millisecond): smooths edges and shimmer a little, and
	/// softens the picture slightly. Works everywhere, including phones and browsers.
	FXAA,
	/// Enhanced subpixel morphological antialiasing, on the finished picture: cleaner lines than FXAA and a sharper
	/// picture, for three passes.
	SMAA,
	/// Multisampled edges on the scene (2 samples per pixel).
	MSAA2x,
	/// Multisampled edges on the scene (4 samples per pixel): the engine's classic setting.
	MSAA4x,
	/// Multisampled edges on the scene (8 samples per pixel).
	MSAA8x,
	/// Temporal antialiasing: smooths edges, shimmer and specular sparkle using the previous frames. Falls back to
	/// FXAA until the temporal pass is built (Antialiasing.TemporalAvailable).
	TAA
}

/// What the antialiasing setting means on this machine: the multisample counts the graphics card can do, and the
/// fallbacks when it cannot do the one asked for (each logged once).
static class Antialiasing
{
	/// Whether the temporal pass (motion vectors, camera jitter, history resolve) exists, so TAA can be chosen.
	/// TAA: added by the temporal pass. Until then TAA falls back to FXAA.
	public static bool TemporalAvailable = false;

	static AntialiasMode sAsked = (AntialiasMode)-1;
	static AntialiasMode sGot;
	static bool sInitialized;
	static HashSet<int32> sLogged = new .() ~ delete _;

	public static bool IsMsaa(AntialiasMode mode) => mode == .MSAA2x || mode == .MSAA4x || mode == .MSAA8x;

	/// Filters on the finished picture, which take passes of their own.
	public static bool IsPost(AntialiasMode mode) => mode == .FXAA || mode == .SMAA;

	public static int32 Samples(AntialiasMode mode)
	{
		switch (mode)
		{
		case .MSAA2x: return 2;
		case .MSAA4x: return 4;
		case .MSAA8x: return 8;
		default: return 0;
		}
	}

	/// The render-target texture flags that ask for this many samples (0: none).
	public static uint64 TextureFlags(int32 samples)
	{
		switch (samples)
		{
		case 2: return Gfx.TextureRenderTargetMsaa2;
		case 4: return Gfx.TextureRenderTargetMsaa4;
		case 8: return Gfx.TextureRenderTargetMsaa8;
		default: return Gfx.TextureRenderTarget;
		}
	}

	/// Whether the scene's colour (RGBA16F) and depth (D32F) targets can be multisampled this much. (bgfx also
	/// lowers a count the card's drivers do not offer to the next one down.)
	public static bool SamplesSupported(int32 samples)
	{
		if (samples <= 1)
			return true;
		if (!Gfx.Initialized)
			return false;
		let flags = TextureFlags(samples);
		return bgfx.is_texture_valid(0, false, 1, .RGBA16F, flags | Gfx.SamplerClamp) && bgfx.is_texture_valid(0, false, 1, .D32F, flags | Gfx.TextureWriteOnly);
	}

	/// The mode that will really be used for the one asked for: multisampling the card cannot do steps down a count
	/// (and to FXAA if it can do none), TAA is FXAA until it exists. Logged once each.
	public static AntialiasMode Resolve(AntialiasMode asked)
	{
		if (sInitialized && sAsked == asked)
			return sGot;
		if (!Gfx.Initialized)
			return IsMsaa(asked) || asked == .TAA ? .FXAA : asked;
		var mode = asked;
		if (mode == .TAA && !TemporalAvailable)
		{
			LogOnce(1, "TAA is not available yet: using FXAA.");
			mode = .FXAA;
		}
		if (IsMsaa(mode))
		{
			var samples = Samples(mode);
			let wanted = samples;
			while (samples >= 2 && !SamplesSupported(samples))
				samples /= 2;
			if (samples != wanted)
			{
				if (samples < 2)
					LogOnce(10 + wanted, scope $"This graphics card cannot do {wanted}x multisampling: using FXAA.");
				else
					LogOnce(10 + wanted, scope $"This graphics card cannot do {wanted}x multisampling: using {samples}x.");
			}
			mode = samples >= 8 ? .MSAA8x : (samples >= 4 ? .MSAA4x : (samples >= 2 ? .MSAA2x : .FXAA));
		}
		sAsked = asked;
		sGot = mode;
		sInitialized = true;
		return mode;
	}

	static void LogOnce(int32 id, StringView text)
	{
		if (sLogged.Add(id))
			Log.Info(text);
	}

	// ---- SMAA's two lookup textures (Engine/assets/smaa_area.bin, smaa_search.bin; the reference's)

	public static bgfx.TextureHandle SmaaArea = .() { idx = uint16.MaxValue };
	public static bgfx.TextureHandle SmaaSearch = .() { idx = uint16.MaxValue };
	static bool sSmaaTried;

	/// Loads the lookup textures the first time SMAA is used. False when the files are missing (SMAA then falls back
	/// to FXAA).
	public static bool EnsureSmaaTextures()
	{
		if (SmaaArea.Valid && SmaaSearch.Valid)
			return true;
		if (sSmaaTried)
			return false;
		sSmaaTried = true;
		let flags = Gfx.SamplerClamp | Gfx.SamplerPoint;
		bgfx.TextureHandle Load(StringView name, int32 width, int32 height, bgfx.TextureFormat format, int32 bytes)
		{
			let path = scope String()..AppendF("{}/{}", Gfx.EngineAssetPath, name);
			List<uint8> data = scope .();
			bgfx.TextureHandle none = .() { idx = uint16.MaxValue };
			if (AssetPack.ReadAll(path, data) case .Err || data.Count != bytes)
			{
				Log.Error(scope $"Missing or wrong SMAA texture {path}");
				return none;
			}
			return bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, format, flags, bgfx.copy(data.Ptr, (uint32)data.Count), 0);
		}
		SmaaArea = Load("smaa_area.bin", 160, 560, .RG8, 160 * 560 * 2);
		SmaaSearch = Load("smaa_search.bin", 64, 16, .R8, 64 * 16);
		return SmaaArea.Valid && SmaaSearch.Valid;
	}

	/// Frees what the antialiasing made (the graphics device is going away).
	public static void Shutdown()
	{
		if (SmaaArea.Valid)
			bgfx.destroy_texture(SmaaArea);
		if (SmaaSearch.Valid)
			bgfx.destroy_texture(SmaaSearch);
		SmaaArea.idx = SmaaSearch.idx = uint16.MaxValue;
		sSmaaTried = false;
		sInitialized = false;
	}
}
