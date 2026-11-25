using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// How the 3D picture drawn at a smaller size (RenderScale below 1) is brought up to the window's (the Upscaler
/// quality setting; tallowengine.com/docs/quality). The numbers are what graphics.cfg and the C# API store.
enum UpscalerKind : int32
{
	/// A plain bilinear stretch: no extra work, a soft picture.
	Off,
	/// AMD FidelityFX Super Resolution 1: edge-adaptive upsampling and sharpening of the finished picture, in a shader.
	/// Works on every graphics card and in browsers.
	FSR1,
	/// AMD FidelityFX Super Resolution 3: temporal upscaling. Needs Vulkan on Windows or Linux.
	FSR2,
	/// NVIDIA DLSS: temporal upscaling by the card's tensor cores. Needs an NVIDIA RTX card and Vulkan on Windows or
	/// Linux.
	DLSS
}

/// The graphics card's maker, from its PCI vendor id.
enum GpuVendor
{
	Unknown,
	Nvidia,
	Amd,
	Intel,
	Apple,
	Other
}

/// The Upscaler setting and what the machine can do (tallowengine.com/docs/quality): which upscalers are available and why
/// not when one is not, and the render scales the quality modes of DLSS and FSR use.
static class Upscaling
{
	/// What the player asked for (the Quality setting puts it here).
	public static UpscalerKind Current = .Off;
	/// How much RCAS sharpens an FSR 1 picture: 0 not at all, 1 the most (a quality of 0.8 is 0.4 stops of FSR's
	/// sharpness scale, the usual look).
	public static float Sharpness = 0.8f;

	// DLSS and FSR's quality modes, as the fraction of the window's size the scene is drawn at.
	public const float QualityScale = 0.67f;
	public const float BalancedScale = 0.58f;
	public const float PerformanceScale = 0.5f;
	public const float UltraPerformanceScale = 0.33f;
	/// "Native AA": drawn at the window's size, the upscaler only smooths (DLAA, FSR native).
	public const float NativeScale = 1.0f;

	public static StringView[5] ModeNames = .("Native AA", "Quality", "Balanced", "Performance", "Ultra Performance");
	public static float[5] ModeScales = .(NativeScale, QualityScale, BalancedScale, PerformanceScale, UltraPerformanceScale);

	/// The quality mode a render scale is (an index into ModeNames), or -1 if it is none of them.
	public static int32 ModeOfScale(float scale)
	{
		for (int32 i < 5)
		{
			if (Math.Abs(ModeScales[i] - scale) < 0.005f)
				return i;
		}
		return -1;
	}

	[CLink] static extern int32 tn_upscale_supported(int32 kind, char8* reason, int32 reasonLength);

	public static GpuVendor Vendor
	{
		get
		{
			if (!Gfx.Initialized)
				return .Unknown;
			switch (bgfx.get_caps().vendorId)
			{
			case 0x10DE: return .Nvidia;
			case 0x1002: return .Amd;
			case 0x8086: return .Intel;
			case 0x106B: return .Apple;
			case 0: return .Unknown;
			default: return .Other;
			}
		}
	}

	public static bool IsNvidia => Vendor == .Nvidia;
	public static bool IsAmd => Vendor == .Amd;

	/// The card's maker, as the PCI vendor id bgfx reports.
	public static uint16 VendorId => Gfx.Initialized ? bgfx.get_caps().vendorId : 0;

	/// The number the native library (UpscaleNative) uses for an upscaler: 1 DLSS, 2 FSR.
	public static int32 NativeKind(UpscalerKind kind) => kind == .DLSS ? 1 : 2;

	/// The native quality mode (0 Quality, 1 Balanced, 2 Performance, 3 Ultra Performance, 4 Native AA) of a render scale:
	/// the named mode it is, else the nearest one.
	public static int32 NativeQualityMode(float scale)
	{
		var best = 0;
		var distance = float.MaxValue;
		for (int32 i < 5)
		{
			let d = Math.Abs(ModeScales[i] - scale);
			if (d < distance)
			{
				distance = d;
				best = i;
			}
		}
		// ModeNames start with Native AA; the library's modes put it last.
		return best == 0 ? 4 : (int32)best - 1;
	}

	static bool[4] sFailed;

	/// A temporal upscaler hit an error while running: it is not used again (until Reset), FSR 1 is, and a log line says why.
	public static void MarkFailed(UpscalerKind kind, StringView why)
	{
		if ((int)kind < 4 && !sFailed[(int)kind])
		{
			sFailed[(int)kind] = true;
			Log.Info(scope $"{(kind == .DLSS ? "DLSS" : "FSR 2")} stopped working ({why}): using FSR 1 instead.");
		}
		sEffectiveReady = false;
	}

	/// Whether an upscaler needs the temporal passes (motion vectors, camera jitter) rather than being a filter.
	public static bool IsTemporal(UpscalerKind kind) => kind == .FSR2 || kind == .DLSS;

	/// Whether this upscaler can run here; if not, `reason` (when given) gets why, for the settings screen. Off and
	/// FSR 1 always can where the engine's shaders run. FSR 2 and DLSS need Vulkan on Windows or Linux (DLSS also an
	/// NVIDIA card) and then the native library has the last word.
	public static bool IsSupported(UpscalerKind kind, String reason = null)
	{
		if (kind == .Off || kind == .FSR1)
			return true;
		let name = kind == .DLSS ? "DLSS" : "FSR 2";
#if BF_PLATFORM_WINDOWS || BF_PLATFORM_LINUX
		if (!Gfx.Initialized)
		{
			reason?.AppendF("{} needs the graphics device, which is not started", name);
			return false;
		}
		if (bgfx.get_renderer_type() != .Vulkan)
		{
			reason?.AppendF("{} needs the Vulkan renderer (this is {})", name, StringView(Native.tn_gfx_renderer_name()));
			return false;
		}
		if (kind == .DLSS && !IsNvidia)
		{
			reason?.Append("DLSS needs an NVIDIA RTX graphics card");
			return false;
		}
		char8[256] buffer = default;
		// The native library numbers them 1 DLSS, 2 FSR (not this enum's values).
		if (tn_upscale_supported(kind == .DLSS ? 1 : 2, &buffer, 256) == 0)
		{
			let text = StringView(&buffer);
			if (reason != null)
			{
				if (text.IsEmpty)
					reason.AppendF("{} is not available on this machine", name);
				else
					reason.Append(text);
			}
			return false;
		}
		return true;
#else
		reason?.AppendF("{} needs Windows or Linux", name);
		return false;
#endif
	}

	static UpscalerKind sEffective;
	static UpscalerKind sEffectiveFor = (UpscalerKind)-1;
	static bool sEffectiveReady;
	static HashSet<int32> sLogged = new .() ~ delete _;

	/// What is really used: the setting, or FSR 1 when that upscaler cannot run here (a log line says why, once).
	public static UpscalerKind Effective
	{
		get
		{
			if (Current == .Off || Current == .FSR1)
				return Current;
			// Not asked of the card before it exists.
			if (!Gfx.Initialized)
				return .FSR1;
			if (sEffectiveReady && sEffectiveFor == Current)
				return sEffective;
			let reason = scope String();
			sEffective = (IsSupported(Current, reason) && !sFailed[(int)Current]) ? Current : .FSR1;
			sEffectiveFor = Current;
			sEffectiveReady = true;
			if (sEffective != Current && sLogged.Add((int32)Current))
				Log.Info(scope $"{reason}: using FSR 1 instead.");
			return sEffective;
		}
	}

	/// Asks again (the renderer or the settings changed).
	public static void Reset()
	{
		sEffectiveReady = false;
		for (int i < 4)
			sFailed[i] = false;
	}
}
