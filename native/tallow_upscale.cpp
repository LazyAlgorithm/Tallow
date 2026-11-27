// Upscalers that need the graphics API itself (tallowengine.com/docs/quality): NVIDIA DLSS (NGX) and AMD FidelityFX
// Super Resolution. FSR 1 is a plain shader pass in the engine and is not here.
//
// kind: 1 DLSS (Super Resolution / DLAA), 2 FSR (temporal upscaler; the engine ships AMD's FSR 2.2.1 temporal core, the
// algorithm FSR 3's upscaler is built on, see third_party/fsr2/README.tallow).
//
// Both run on bgfx's Vulkan renderer only. The engine calls tn_upscale_evaluate while it builds the frame; the work is
// recorded into bgfx's command buffer through a per-view hook (third_party/bgfx.cmake/bgfx/include/bgfx/tallow_vk.h)
// after all draws of that view, so the view needs at least one item (bgfx::touch) in that frame.
//
// Formats and conventions (the same for both kinds):
//  - color: render resolution, sampled, any float or UNORM colour format DLSS/FSR accept (RGBA16F recommended for HDR).
//  - depth: render resolution, sampled, the *device* depth of the main pass (D32F or R32F holding the clip-space z
//    the projection produced, 0..1). It is not linear view depth. Set QUALITY_FLAG_DEPTH_INVERTED when 1 is near.
//  - motion: render resolution, sampled, RG16F or RG32F, value = (previous position - current position) in UV units
//    times motionScale, so with UV-unit vectors pass (renderWidth, renderHeight); pixel-unit vectors take (1, 1).
//    The vectors do not contain the camera jitter. Static pixels must be reprojected too (camera motion included).
//  - output: display resolution, needs the compute-write (storage image) usage (BGFX_TEXTURE_COMPUTE_WRITE), RGBA16F
//    or RGBA8. The result is a sampled texture again after the view.
//  - jitter: sub pixel offset in render-resolution pixels, from tn_upscale_jitter_offset; apply the same offset to the
//    projection matrix (clip x += 2 * jitterX / renderWidth, clip y += 2 * jitterY / renderHeight in Vulkan clip space)
//    and pass it unchanged to evaluate.
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <vector>
#include <string>

#include <bgfx/tallow_vk.h>

// TALLOW_UPSCALE_VULKAN is defined by native/CMakeLists.txt where the Vulkan renderer is built (Linux and Windows
// x86-64). Elsewhere (macOS, iOS, Android, the web player, Linux arm64) this file holds stubs instead: DLSS and FSR
// need Vulkan, and those builds have no Vulkan headers.
#if defined(TALLOW_UPSCALE_VULKAN)
#include <vulkan/vulkan.h>

#if defined(_WIN32)
#	define WIN32_LEAN_AND_MEAN
#	define NOMINMAX
#	include <windows.h>
#else
#	include <dlfcn.h>
#	include <unistd.h>
#	include <sys/stat.h>
#endif

#if defined(TALLOW_HAVE_DLSS)
#	include <nvsdk_ngx.h>
#	include <nvsdk_ngx_vk.h>
#	include <nvsdk_ngx_helpers.h>
#	include <nvsdk_ngx_helpers_vk.h>
#endif

#if defined(TALLOW_HAVE_FSR2)
#	include <ffx_fsr2.h>
#	include <vk/ffx_fsr2_vk.h>
#endif

namespace
{
	enum { KindDlss = 1, KindFsr = 2 };

	// Quality modes of tn_upscale_create / tn_upscale_optimal_size.
	enum { QualityQuality = 0, QualityBalanced = 1, QualityPerformance = 2, QualityUltraPerformance = 3, QualityNative = 4, QualityUltraQuality = 5 };

	// Create flags.
	enum { FlagHdr = 1, FlagDepthInverted = 2, FlagMotionAtRenderResolution = 4, FlagAutoExposure = 8 };

	bool s_dlssChecked = false;
	bool s_dlssOk = false;
	char s_dlssReason[256] = "";
	bool s_fsrChecked = false;
	bool s_fsrOk = false;
	char s_fsrReason[256] = "";

	TallowVkNative s_native;
	bool s_haveNative = false;
	PFN_vkGetInstanceProcAddr s_gipa = nullptr;
	PFN_vkGetDeviceProcAddr s_gdpa = nullptr;

	void setText(char* dst, size_t cap, const char* text)
	{
		std::snprintf(dst, cap, "%s", text);
	}

	bool refreshNative()
	{
		s_haveNative = tallow_vk_get_native(&s_native) != 0;
		s_gipa = s_haveNative ? (PFN_vkGetInstanceProcAddr)s_native.getInstanceProcAddr : nullptr;
		s_gdpa = s_haveNative ? (PFN_vkGetDeviceProcAddr)s_native.getDeviceProcAddr : nullptr;
		return s_haveNative && s_gipa != nullptr && s_gdpa != nullptr;
	}

	template <class T> T instanceFn(const char* name)
	{
		return (T)s_gipa((VkInstance)s_native.instance, name);
	}

	template <class T> T deviceFn(const char* name)
	{
		return (T)s_gdpa((VkDevice)s_native.device, name);
	}

	std::string executableDir()
	{
#if defined(_WIN32)
		wchar_t buffer[2048];
		DWORD n = GetModuleFileNameW(nullptr, buffer, 2048);
		std::wstring w(buffer, n);
		size_t slash = w.find_last_of(L"\\/");
		if (slash != std::wstring::npos) w.resize(slash);
		std::string out;
		for (wchar_t c : w) out.push_back(c < 128 ? (char)c : '?');
		return out;
#else
		char buffer[4096];
		ssize_t n = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
		if (n <= 0) return ".";
		buffer[n] = 0;
		std::string s(buffer);
		size_t slash = s.find_last_of('/');
		return slash == std::string::npos ? "." : s.substr(0, slash);
#endif
	}

	// The jitter sequence both upscalers want: Halton (2, 3), centred, in -0.5..0.5 of a render pixel.
	float halton(int index, int base)
	{
		float f = 1.0f, r = 0.0f;
		while (index > 0)
		{
			f /= (float)base;
			r += f * (float)(index % base);
			index /= base;
		}
		return r;
	}

	// ---- image views for bgfx textures ----
	struct CachedView
	{
		uint16_t texture = 0xffff;
		uint64_t image = 0;
		uint32_t format = 0;
		uint32_t aspect = 0;
		VkImageView view = VK_NULL_HANDLE;
	};

	struct ImageRef
	{
		TallowVkTexture info {};
		VkImageView view = VK_NULL_HANDLE;
		VkImageSubresourceRange range {};
	};

	struct Upscaler;
	std::vector<Upscaler*> s_upscalers;

	struct Pending
	{
		bool valid = false;
		uint16_t color = 0, depth = 0, motion = 0, output = 0;
		float jitterX = 0, jitterY = 0, mvScaleX = 1, mvScaleY = 1;
		int reset = 0;
		float sharpness = 0, frameTimeMs = 16.6f, camNear = 0.1f, camFar = 1000.0f, fovY = 1.0f;
	};

	struct Upscaler
	{
		int kind = 0;
		int renderW = 0, renderH = 0, outW = 0, outH = 0, quality = 0, flags = 0;
		Pending pending;
		uint16_t hookView = 0xffff;
		bool created = false;
		bool failed = false;
		std::vector<CachedView> views;

#if defined(TALLOW_HAVE_DLSS)
		NVSDK_NGX_Handle* dlss = nullptr;
		NVSDK_NGX_Parameter* params = nullptr;
#endif
#if defined(TALLOW_HAVE_FSR2)
		FfxFsr2Context fsr {};
		void* fsrScratch = nullptr;
		bool fsrCreated = false;
#endif

		bool viewFor(uint16_t texture, const TallowVkTexture& info, bool depth, VkImageView& out)
		{
			auto create = deviceFn<PFN_vkCreateImageView>("vkCreateImageView");
			auto destroy = deviceFn<PFN_vkDestroyImageView>("vkDestroyImageView");
			for (CachedView& c : views)
			{
				if (c.texture != texture) continue;
				if (c.image == info.image && c.format == info.format && c.aspect == (depth ? 2u : 1u))
				{
					out = c.view;
					return true;
				}
				if (c.view != VK_NULL_HANDLE) destroy((VkDevice)s_native.device, c.view, nullptr);
				c.view = VK_NULL_HANDLE;
				c.texture = 0xffff;
			}
			VkImageViewCreateInfo ci {};
			ci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
			ci.image = (VkImage)info.image;
			ci.viewType = VK_IMAGE_VIEW_TYPE_2D;
			ci.format = (VkFormat)info.format;
			ci.components = { VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY };
			ci.subresourceRange.aspectMask = depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT;
			ci.subresourceRange.levelCount = 1;
			ci.subresourceRange.layerCount = 1;
			VkImageView view = VK_NULL_HANDLE;
			if (create((VkDevice)s_native.device, &ci, nullptr, &view) != VK_SUCCESS) return false;
			CachedView c;
			c.texture = texture; c.image = info.image; c.format = info.format; c.aspect = depth ? 2u : 1u; c.view = view;
			for (CachedView& slot : views)
			{
				if (slot.texture == 0xffff) { slot = c; out = view; return true; }
			}
			views.push_back(c);
			out = view;
			return true;
		}

		void destroyViews()
		{
			if (!s_haveNative) return;
			auto destroy = deviceFn<PFN_vkDestroyImageView>("vkDestroyImageView");
			for (CachedView& c : views)
				if (c.view != VK_NULL_HANDLE) destroy((VkDevice)s_native.device, c.view, nullptr);
			views.clear();
		}

		bool resolve(uint16_t texture, bool depth, bool storage, void* cmd, ImageRef& ref)
		{
			if (!tallow_vk_texture_info(texture, &ref.info)) return false;
			if (!viewFor(texture, ref.info, depth, ref.view)) return false;
			tallow_vk_texture_transition(texture, cmd, storage ? 1 : 0);
			ref.range.aspectMask = depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT;
			ref.range.levelCount = 1;
			ref.range.layerCount = 1;
			return true;
		}

		void release();
		bool execute(void* cmd);
		bool executeDlss(void* cmd);
		bool executeFsr(void* cmd);
	};

#if defined(TALLOW_HAVE_DLSS)
	bool s_ngxInit = false;
	NVSDK_NGX_Result s_ngxInitResult = NVSDK_NGX_Result_Success;
	NVSDK_NGX_Parameter* s_ngxCaps = nullptr;
	std::vector<std::wstring> s_ngxPaths;
	std::vector<const wchar_t*> s_ngxPathPtrs;
	std::wstring s_ngxDataPath;
	NVSDK_NGX_FeatureCommonInfo s_ngxInfo {};

	std::wstring widen(const std::string& s)
	{
		std::wstring w;
		for (unsigned char c : s) w.push_back((wchar_t)c);
		return w;
	}

	void buildNgxPaths()
	{
		s_ngxPaths.clear();
		std::string exe = executableDir();
		s_ngxPaths.push_back(widen(exe));
		s_ngxPaths.push_back(widen(exe + "/lib"));
		s_ngxPaths.push_back(widen("."));
		const char* env = std::getenv("TALLOW_DLSS_DIR");
		if (env != nullptr && env[0] != 0) s_ngxPaths.push_back(widen(env));
#if defined(TALLOW_DLSS_RUNTIME_DIR)
		s_ngxPaths.push_back(widen(TALLOW_DLSS_RUNTIME_DIR));
#endif
		s_ngxPathPtrs.clear();
		for (auto& p : s_ngxPaths) s_ngxPathPtrs.push_back(p.c_str());
		s_ngxInfo = {};
		s_ngxInfo.PathListInfo.Path = s_ngxPathPtrs.data();
		s_ngxInfo.PathListInfo.Length = (unsigned int)s_ngxPathPtrs.size();
		const char* tmp = std::getenv("TMPDIR");
#if defined(_WIN32)
		s_ngxDataPath = L".";
		(void)tmp;
#else
		s_ngxDataPath = widen(tmp != nullptr && tmp[0] != 0 ? tmp : "/tmp");
#endif
	}

	bool nvidiaPresent()
	{
#if defined(_WIN32)
		HMODULE h = LoadLibraryA("nvngx.dll");
		if (h == nullptr) return false;
		FreeLibrary(h);
		return true;
#else
		void* h = dlopen("libnvidia-ngx.so.1", RTLD_LAZY | RTLD_LOCAL);
		if (h == nullptr) return false;
		dlclose(h);
		return true;
#endif
	}

	const char* ngxResultText(NVSDK_NGX_Result r)
	{
		switch (r)
		{
		case NVSDK_NGX_Result_FAIL_FeatureNotSupported: return "DLSS is not supported by this graphics card or driver";
		case NVSDK_NGX_Result_FAIL_FeatureNotFound: return "The DLSS runtime library (libnvidia-ngx-dlss / nvngx_dlss.dll) was not found next to the game";
		case NVSDK_NGX_Result_FAIL_OutOfDate: return "Update the NVIDIA driver to use DLSS";
		case NVSDK_NGX_Result_FAIL_PlatformError: return "The graphics driver rejected the DLSS setup (missing Vulkan extension or driver too old)";
		case NVSDK_NGX_Result_FAIL_UnableToWriteToAppDataPath: return "DLSS cannot write its log folder";
		case NVSDK_NGX_Result_FAIL_Denied: return "DLSS is not allowed on this machine";
		default: return "DLSS could not start";
		}
	}

	void checkDlss()
	{
		s_dlssChecked = true;
		s_dlssOk = false;
		if (!refreshNative())
		{
			setText(s_dlssReason, sizeof(s_dlssReason), "DLSS needs the Vulkan renderer");
			return;
		}
		if (s_native.vendorId != 0x10DE)
		{
			setText(s_dlssReason, sizeof(s_dlssReason), "DLSS needs an NVIDIA RTX graphics card");
			return;
		}
		if (!nvidiaPresent())
		{
			setText(s_dlssReason, sizeof(s_dlssReason), "The NVIDIA driver's NGX component is missing; update the NVIDIA driver");
			return;
		}
		if (VK_API_VERSION_MAJOR(s_native.apiVersion) == 1 && VK_API_VERSION_MINOR(s_native.apiVersion) < 1)
		{
			setText(s_dlssReason, sizeof(s_dlssReason), "DLSS needs Vulkan 1.1 or newer");
			return;
		}
		// The extensions NGX asked for before bgfx created the device.
		{
			unsigned int ni = 0, nd = 0;
			const char** ie = nullptr;
			const char** de = nullptr;
			if (NVSDK_NGX_VULKAN_RequiredExtensions(&ni, &ie, &nd, &de) == NVSDK_NGX_Result_Success)
			{
				for (unsigned int i = 0; i < nd; ++i)
				{
					if (!tallow_vk_extension_enabled(de[i]))
					{
						char text[256];
						std::snprintf(text, sizeof(text), "Vulkan extension %s is missing: update the NVIDIA driver (DLSS needs an RTX card)", de[i]);
						setText(s_dlssReason, sizeof(s_dlssReason), text);
						return;
					}
				}
			}
		}
		buildNgxPaths();
		if (!s_ngxInit)
		{
			NVSDK_NGX_Result r = NVSDK_NGX_VULKAN_Init_with_ProjectID("3f6c1d5e-8b0a-4a52-9c1e-7d2a54b3e601", NVSDK_NGX_ENGINE_TYPE_CUSTOM, "0.3",
				s_ngxDataPath.c_str(), (VkInstance)s_native.instance, (VkPhysicalDevice)s_native.physicalDevice, (VkDevice)s_native.device,
				s_gipa, s_gdpa, &s_ngxInfo, NVSDK_NGX_Version_API);
			s_ngxInitResult = r;
			if (NVSDK_NGX_FAILED(r))
			{
				setText(s_dlssReason, sizeof(s_dlssReason), ngxResultText(r));
				return;
			}
			s_ngxInit = true;
		}
		if (s_ngxCaps == nullptr && NVSDK_NGX_FAILED(NVSDK_NGX_VULKAN_GetCapabilityParameters(&s_ngxCaps)))
		{
			setText(s_dlssReason, sizeof(s_dlssReason), "DLSS could not read its capabilities");
			return;
		}
		int needsDriver = 0;
		NVSDK_NGX_Parameter_GetI(s_ngxCaps, NVSDK_NGX_Parameter_SuperSampling_NeedsUpdatedDriver, &needsDriver);
		if (needsDriver != 0)
		{
			unsigned int major = 0, minor = 0;
			NVSDK_NGX_Parameter_GetUI(s_ngxCaps, NVSDK_NGX_Parameter_SuperSampling_MinDriverVersionMajor, &major);
			NVSDK_NGX_Parameter_GetUI(s_ngxCaps, NVSDK_NGX_Parameter_SuperSampling_MinDriverVersionMinor, &minor);
			char text[256];
			std::snprintf(text, sizeof(text), "Update the NVIDIA driver to %u.%u or newer to use DLSS", major, minor);
			setText(s_dlssReason, sizeof(s_dlssReason), text);
			return;
		}
		int available = 0;
		NVSDK_NGX_Parameter_GetI(s_ngxCaps, NVSDK_NGX_Parameter_SuperSampling_Available, &available);
		if (!available)
		{
			// The usual cause on a game without the runtime next to it, or a GPU without tensor cores.
			setText(s_dlssReason, sizeof(s_dlssReason), "DLSS is not available: it needs an RTX graphics card and the nvngx_dlss runtime library next to the game");
			return;
		}
		s_dlssOk = true;
		s_dlssReason[0] = 0;
	}
#endif

	void checkFsr()
	{
		s_fsrChecked = true;
		s_fsrOk = false;
#if !defined(TALLOW_HAVE_FSR2)
		setText(s_fsrReason, sizeof(s_fsrReason), "FSR 3 is not built into this engine");
		return;
#else
		if (!refreshNative())
		{
			setText(s_fsrReason, sizeof(s_fsrReason), "FSR 3 needs the Vulkan renderer");
			return;
		}
		if (VK_API_VERSION_MAJOR(s_native.apiVersion) == 1 && VK_API_VERSION_MINOR(s_native.apiVersion) < 1)
		{
			setText(s_fsrReason, sizeof(s_fsrReason), "FSR 3 needs Vulkan 1.1 or newer");
			return;
		}
		auto enumerate = instanceFn<PFN_vkEnumerateDeviceExtensionProperties>("vkEnumerateDeviceExtensionProperties");
		auto getFeatures = instanceFn<PFN_vkGetPhysicalDeviceFeatures>("vkGetPhysicalDeviceFeatures");
		if (enumerate == nullptr || getFeatures == nullptr)
		{
			setText(s_fsrReason, sizeof(s_fsrReason), "The Vulkan driver is missing entry points FSR 3 needs");
			return;
		}
		VkPhysicalDeviceFeatures features {};
		getFeatures((VkPhysicalDevice)s_native.physicalDevice, &features);
		VkFormatProperties fp {};
		auto getFormat = instanceFn<PFN_vkGetPhysicalDeviceFormatProperties>("vkGetPhysicalDeviceFormatProperties");
		if (getFormat != nullptr)
		{
			getFormat((VkPhysicalDevice)s_native.physicalDevice, VK_FORMAT_R16G16B16A16_SFLOAT, &fp);
			if ((fp.optimalTilingFeatures & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT) == 0)
			{
				setText(s_fsrReason, sizeof(s_fsrReason), "This graphics card cannot write RGBA16F storage images, which FSR 3 needs");
				return;
			}
		}
		s_fsrOk = true;
		s_fsrReason[0] = 0;
#endif
	}

	void Upscaler::release()
	{
		if (s_haveNative)
		{
			auto idle = deviceFn<PFN_vkDeviceWaitIdle>("vkDeviceWaitIdle");
			if (idle != nullptr) idle((VkDevice)s_native.device);
		}
#if defined(TALLOW_HAVE_DLSS)
		if (dlss != nullptr) { NVSDK_NGX_VULKAN_ReleaseFeature(dlss); dlss = nullptr; }
		if (params != nullptr) { NVSDK_NGX_VULKAN_DestroyParameters(params); params = nullptr; }
#endif
#if defined(TALLOW_HAVE_FSR2)
		if (fsrCreated) { ffxFsr2ContextDestroy(&fsr); fsrCreated = false; }
		if (fsrScratch != nullptr) { std::free(fsrScratch); fsrScratch = nullptr; }
#endif
		destroyViews();
		created = false;
	}

	bool Upscaler::executeDlss(void* cmdv)
	{
#if defined(TALLOW_HAVE_DLSS)
		VkCommandBuffer cmd = (VkCommandBuffer)cmdv;
		if (dlss == nullptr)
		{
			if (NVSDK_NGX_FAILED(NVSDK_NGX_VULKAN_AllocateParameters(&params))) return false;
			NVSDK_NGX_DLSS_Create_Params cp {};
			cp.Feature.InWidth = (unsigned)renderW;
			cp.Feature.InHeight = (unsigned)renderH;
			cp.Feature.InTargetWidth = (unsigned)outW;
			cp.Feature.InTargetHeight = (unsigned)outH;
			static const NVSDK_NGX_PerfQuality_Value map[] = {
				NVSDK_NGX_PerfQuality_Value_MaxQuality, NVSDK_NGX_PerfQuality_Value_Balanced, NVSDK_NGX_PerfQuality_Value_MaxPerf,
				NVSDK_NGX_PerfQuality_Value_UltraPerformance, NVSDK_NGX_PerfQuality_Value_DLAA, NVSDK_NGX_PerfQuality_Value_UltraQuality };
			cp.Feature.InPerfQualityValue = map[quality >= 0 && quality <= 5 ? quality : 0];
			int f = 0;
			if (flags & FlagHdr) f |= NVSDK_NGX_DLSS_Feature_Flags_IsHDR;
			if (flags & FlagMotionAtRenderResolution) f |= NVSDK_NGX_DLSS_Feature_Flags_MVLowRes;
			if (flags & FlagDepthInverted) f |= NVSDK_NGX_DLSS_Feature_Flags_DepthInverted;
			if (flags & FlagAutoExposure) f |= NVSDK_NGX_DLSS_Feature_Flags_AutoExposure;
			cp.InFeatureCreateFlags = f;
			NVSDK_NGX_Result r = NGX_VULKAN_CREATE_DLSS_EXT1((VkDevice)s_native.device, cmd, 1, 1, &dlss, params, &cp);
			if (NVSDK_NGX_FAILED(r))
			{
				std::fprintf(stderr, "Tallow DLSS: creating the feature failed (0x%08x)\n", (unsigned)r);
				dlss = nullptr;
				return false;
			}
		}

		ImageRef color, depth, motion, output;
		if (!resolve(pending.color, false, false, cmdv, color) || !resolve(pending.depth, true, false, cmdv, depth)
			|| !resolve(pending.motion, false, false, cmdv, motion) || !resolve(pending.output, false, true, cmdv, output))
			return false;

		NVSDK_NGX_Resource_VK rColor = NVSDK_NGX_Create_ImageView_Resource_VK(color.view, (VkImage)color.info.image, color.range, (VkFormat)color.info.format, color.info.width, color.info.height, false);
		NVSDK_NGX_Resource_VK rDepth = NVSDK_NGX_Create_ImageView_Resource_VK(depth.view, (VkImage)depth.info.image, depth.range, (VkFormat)depth.info.format, depth.info.width, depth.info.height, false);
		NVSDK_NGX_Resource_VK rMotion = NVSDK_NGX_Create_ImageView_Resource_VK(motion.view, (VkImage)motion.info.image, motion.range, (VkFormat)motion.info.format, motion.info.width, motion.info.height, false);
		NVSDK_NGX_Resource_VK rOutput = NVSDK_NGX_Create_ImageView_Resource_VK(output.view, (VkImage)output.info.image, output.range, (VkFormat)output.info.format, output.info.width, output.info.height, true);

		NVSDK_NGX_VK_DLSS_Eval_Params e {};
		e.Feature.pInColor = &rColor;
		e.Feature.pInOutput = &rOutput;
		e.Feature.InSharpness = pending.sharpness;
		e.pInDepth = &rDepth;
		e.pInMotionVectors = &rMotion;
		e.InJitterOffsetX = pending.jitterX;
		e.InJitterOffsetY = pending.jitterY;
		e.InRenderSubrectDimensions = { (unsigned)renderW, (unsigned)renderH };
		e.InReset = pending.reset;
		e.InMVScaleX = pending.mvScaleX;
		e.InMVScaleY = pending.mvScaleY;
		e.InPreExposure = 1.0f;
		e.InExposureScale = 1.0f;
		e.InFrameTimeDeltaInMsec = pending.frameTimeMs;
		NVSDK_NGX_Result r = NGX_VULKAN_EVALUATE_DLSS_EXT(cmd, dlss, params, &e);

		// NGX leaves the resources in the states it was given; bgfx is told the output is in GENERAL already.
		if (NVSDK_NGX_FAILED(r))
		{
			std::fprintf(stderr, "Tallow DLSS: evaluate failed (0x%08x)\n", (unsigned)r);
			return false;
		}
		tallow_vk_texture_transition(pending.output, cmdv, 0);
		return true;
#else
		(void)cmdv;
		return false;
#endif
	}

	bool Upscaler::executeFsr(void* cmdv)
	{
#if defined(TALLOW_HAVE_FSR2)
		VkCommandBuffer cmd = (VkCommandBuffer)cmdv;
		if (!fsrCreated)
		{
			size_t size = ffxFsr2GetScratchMemorySizeVK((VkPhysicalDevice)s_native.physicalDevice);
			fsrScratch = std::calloc(1, size);
			FfxFsr2ContextDescription d {};
			if (ffxFsr2GetInterfaceVK(&d.callbacks, fsrScratch, size, (VkPhysicalDevice)s_native.physicalDevice, (PFN_vkGetDeviceProcAddr)s_native.getDeviceProcAddr) != FFX_OK)
				return false;
			d.device = ffxGetDeviceVK((VkDevice)s_native.device);
			d.maxRenderSize.width = (uint32_t)renderW;
			d.maxRenderSize.height = (uint32_t)renderH;
			d.displaySize.width = (uint32_t)outW;
			d.displaySize.height = (uint32_t)outH;
			d.flags = 0;
			if (flags & FlagHdr) d.flags |= FFX_FSR2_ENABLE_HIGH_DYNAMIC_RANGE;
			if (flags & FlagDepthInverted) d.flags |= FFX_FSR2_ENABLE_DEPTH_INVERTED;
			if (flags & FlagAutoExposure) d.flags |= FFX_FSR2_ENABLE_AUTO_EXPOSURE;
			if (ffxFsr2ContextCreate(&fsr, &d) != FFX_OK)
			{
				std::fprintf(stderr, "Tallow FSR: creating the context failed\n");
				return false;
			}
			fsrCreated = true;
		}

		ImageRef color, depth, motion, output;
		if (!resolve(pending.color, false, false, cmdv, color) || !resolve(pending.depth, true, false, cmdv, depth)
			|| !resolve(pending.motion, false, false, cmdv, motion) || !resolve(pending.output, false, true, cmdv, output))
			return false;

		auto wrap = [&](const ImageRef& r, const wchar_t* name, FfxResourceStates state)
		{
			return ffxGetTextureResourceVK(&fsr, (VkImage)r.info.image, r.view, r.info.width, r.info.height, (VkFormat)r.info.format, name, state);
		};
		FfxFsr2DispatchDescription dd {};
		dd.commandList = ffxGetCommandListVK(cmd);
		dd.color = wrap(color, L"TallowFSR_Color", FFX_RESOURCE_STATE_COMPUTE_READ);
		dd.depth = wrap(depth, L"TallowFSR_Depth", FFX_RESOURCE_STATE_COMPUTE_READ);
		dd.motionVectors = wrap(motion, L"TallowFSR_Motion", FFX_RESOURCE_STATE_COMPUTE_READ);
		dd.exposure = ffxGetTextureResourceVK(&fsr, VK_NULL_HANDLE, VK_NULL_HANDLE, 1, 1, VK_FORMAT_UNDEFINED, L"TallowFSR_Exposure", FFX_RESOURCE_STATE_COMPUTE_READ);
		dd.reactive = dd.exposure;
		dd.transparencyAndComposition = dd.exposure;
		dd.output = wrap(output, L"TallowFSR_Output", FFX_RESOURCE_STATE_UNORDERED_ACCESS);
		dd.jitterOffset.x = pending.jitterX;
		dd.jitterOffset.y = pending.jitterY;
		dd.motionVectorScale.x = pending.mvScaleX;
		dd.motionVectorScale.y = pending.mvScaleY;
		dd.renderSize.width = (uint32_t)renderW;
		dd.renderSize.height = (uint32_t)renderH;
		dd.enableSharpening = pending.sharpness > 0.0f;
		dd.sharpness = pending.sharpness;
		dd.frameTimeDelta = pending.frameTimeMs;
		dd.preExposure = 1.0f;
		dd.reset = pending.reset != 0;
		dd.cameraNear = pending.camNear;
		dd.cameraFar = pending.camFar;
		dd.cameraFovAngleVertical = pending.fovY;
		dd.viewSpaceToMetersFactor = 1.0f;
		if (ffxFsr2ContextDispatch(&fsr, &dd) != FFX_OK)
		{
			std::fprintf(stderr, "Tallow FSR: dispatch failed\n");
			return false;
		}
		// FSR leaves its inputs in the sampled and the output in the storage layout it was told about.
		tallow_vk_texture_transition(pending.output, cmdv, 0);
		return true;
#else
		(void)cmdv;
		return false;
#endif
	}

	bool Upscaler::execute(void* cmd)
	{
		if (!pending.valid || failed) return false;
		pending.valid = false;
		bool ok = kind == KindDlss ? executeDlss(cmd) : executeFsr(cmd);
		if (!ok) failed = true;
		static const bool trace = std::getenv("TALLOW_UPSCALE_TRACE") != nullptr;
		if (trace) std::fprintf(stderr, "Tallow upscale: %s evaluate %s (%dx%d -> %dx%d)\n", kind == KindDlss ? "DLSS" : "FSR", ok ? "recorded" : "FAILED", renderW, renderH, outW, outH);
		return ok;
	}

	void viewHook(void* cmd, uint16_t, void* user)
	{
		static_cast<Upscaler*>(user)->execute(cmd);
	}
}

// Called by tn_gfx_init before bgfx::init when the Vulkan renderer may be used: asks bgfx to enable the instance and
// device extensions NGX needs (they are skipped by bgfx if the driver does not offer them).
extern "C" void tn_upscale_prepare_vulkan(void)
{
#if defined(TALLOW_HAVE_DLSS)
	static bool done = false;
	if (done) return;
	done = true;
	if (!nvidiaPresent()) return;
	unsigned int ni = 0, nd = 0;
	const char** ie = nullptr;
	const char** de = nullptr;
	if (NVSDK_NGX_VULKAN_RequiredExtensions(&ni, &ie, &nd, &de) != NVSDK_NGX_Result_Success) return;
	tallow_vk_request_extensions(ie, ni, de, nd);
#endif
}

extern "C" {

// 1 when the upscaler can run on this machine and renderer right now, else 0 with the reason (for the settings
// screen) written into `reason` (NUL-terminated, at most reasonLength bytes including the NUL). kind: 1 DLSS, 2 FSR 3.
// Needs the graphics device to exist (call after tn_gfx_init); the answer is cached.
int tn_upscale_supported(int kind, char* reason, int reasonLength)
{
	bool ok = false;
	const char* text = "";
	if (kind == KindDlss)
	{
#if defined(TALLOW_HAVE_DLSS)
		if (!s_dlssChecked || (!s_dlssOk && !s_haveNative)) checkDlss();
		ok = s_dlssOk;
		text = s_dlssReason;
#else
		text = "DLSS is not built into this engine (the DLSS SDK could not be downloaded when the engine was built)";
#endif
	}
	else if (kind == KindFsr)
	{
		if (!s_fsrChecked || (!s_fsrOk && !s_haveNative)) checkFsr();
		ok = s_fsrOk;
		text = s_fsrReason;
	}
	else
	{
		text = "Unknown upscaler";
	}
	if (reason != nullptr && reasonLength > 0)
		std::snprintf(reason, (size_t)reasonLength, "%s", text);
	return ok ? 1 : 0;
}

// Render resolution an upscaler wants for a display size and quality mode (0 Quality, 1 Balanced, 2 Performance,
// 3 Ultra Performance, 4 Native AA (DLAA / FSR native), 5 Ultra Quality (DLSS only, Quality for FSR)). Returns 1 and
// fills renderW/renderH, or 0 (the caller then uses its own ratios: 1.5, 1.7, 2.0, 3.0, 1.0, 1.3).
int tn_upscale_optimal_size(int kind, int outW, int outH, int qualityMode, int* renderW, int* renderH)
{
	static const float ratios[] = { 1.5f, 1.7f, 2.0f, 3.0f, 1.0f, 1.3f };
	if (renderW == nullptr || renderH == nullptr || outW <= 0 || outH <= 0) return 0;
	if (qualityMode < 0 || qualityMode > 5) qualityMode = 0;
#if defined(TALLOW_HAVE_DLSS)
	if (kind == KindDlss && s_dlssOk && s_ngxCaps != nullptr)
	{
		static const NVSDK_NGX_PerfQuality_Value map[] = {
			NVSDK_NGX_PerfQuality_Value_MaxQuality, NVSDK_NGX_PerfQuality_Value_Balanced, NVSDK_NGX_PerfQuality_Value_MaxPerf,
			NVSDK_NGX_PerfQuality_Value_UltraPerformance, NVSDK_NGX_PerfQuality_Value_DLAA, NVSDK_NGX_PerfQuality_Value_UltraQuality };
		unsigned int w = 0, h = 0, maxW = 0, maxH = 0, minW = 0, minH = 0;
		float sharp = 0;
		if (NVSDK_NGX_SUCCEED(NGX_DLSS_GET_OPTIMAL_SETTINGS(s_ngxCaps, (unsigned)outW, (unsigned)outH, map[qualityMode], &w, &h, &maxW, &maxH, &minW, &minH, &sharp)) && w > 0 && h > 0)
		{
			*renderW = (int)w;
			*renderH = (int)h;
			return 1;
		}
	}
#endif
	(void)kind;
	float r = ratios[qualityMode];
	if (r <= 1.0f) { *renderW = outW; *renderH = outH; return 1; }
	*renderW = (int)((float)outW / r);
	*renderH = (int)((float)outH / r);
	return 1;
}

// Number of jitter samples to cycle through for a render/display width pair.
int tn_upscale_jitter_phases(int kind, int renderW, int outW)
{
	if (renderW <= 0) return 8;
	float ratio = (float)outW / (float)renderW;
	int n = (int)std::ceil(8.0f * ratio * ratio);
	(void)kind;
	return n < 8 ? 8 : (n > 256 ? 256 : n);
}

// Sub pixel jitter for frame `index` (any non-negative number; it wraps at `phases`): Halton (2, 3), centred, each axis
// in -0.5..0.5 render pixels. Apply it to the projection and give the same numbers to tn_upscale_evaluate.
void tn_upscale_jitter_offset(int kind, int index, int phases, float* x, float* y)
{
	(void)kind;
	if (phases < 1) phases = 8;
	int i = (index % phases) + 1;
	if (x != nullptr) *x = halton(i, 2) - 0.5f;
	if (y != nullptr) *y = halton(i, 3) - 0.5f;
}

// Creates an upscaler for one view. The GPU objects are made lazily inside the first evaluate. Returns null when the
// kind is unsupported here or the flags cannot be honoured (FSR needs FlagMotionAtRenderResolution).
// qualityMode: see tn_upscale_optimal_size. flags: 1 HDR color input, 2 inverted depth (1 = near), 4 motion vectors at
// render resolution (always set it; display resolution vectors are not supported), 8 auto exposure.
void* tn_upscale_create(int kind, int renderW, int renderH, int outW, int outH, int qualityMode, int flags)
{
	char reason[256];
	if (!tn_upscale_supported(kind, reason, sizeof(reason))) return nullptr;
	if (renderW < 1 || renderH < 1 || outW < 32 || outH < 32) return nullptr;
	if (kind == KindFsr && (flags & FlagMotionAtRenderResolution) == 0) return nullptr;
	Upscaler* u = new Upscaler();
	u->kind = kind;
	u->renderW = renderW; u->renderH = renderH; u->outW = outW; u->outH = outH;
	u->quality = qualityMode; u->flags = flags;
	s_upscalers.push_back(u);
	return u;
}

void tn_upscale_destroy(void* ctx)
{
	Upscaler* u = static_cast<Upscaler*>(ctx);
	if (u == nullptr) return;
	for (size_t i = 0; i < s_upscalers.size(); ++i)
		if (s_upscalers[i] == u) { s_upscalers.erase(s_upscalers.begin() + (long)i); break; }
	if (u->hookView != 0xffff) tallow_vk_set_view_hook(u->hookView, nullptr, nullptr);
	u->release();
	delete u;
}

// Queues the upscale to run after the items of `viewId` (give that view at least one item, bgfx::touch is enough).
// Textures are bgfx texture handle indexes. Returns 1 when queued, 0 on bad input or after the upscaler failed once
// (call tn_upscale_failed to ask). Conventions: see the top of this file.
int tn_upscale_evaluate(void* ctx, uint16_t colorTex, uint16_t depthTex, uint16_t motionTex, uint16_t outputTex,
	float jitterX, float jitterY, float motionScaleX, float motionScaleY, int reset, float sharpness, float frameTimeMs,
	float camNear, float camFar, float fovY, uint16_t viewId)
{
	Upscaler* u = static_cast<Upscaler*>(ctx);
	if (u == nullptr || u->failed || !refreshNative()) return 0;
	u->pending.valid = true;
	u->pending.color = colorTex; u->pending.depth = depthTex; u->pending.motion = motionTex; u->pending.output = outputTex;
	u->pending.jitterX = jitterX; u->pending.jitterY = jitterY;
	u->pending.mvScaleX = motionScaleX; u->pending.mvScaleY = motionScaleY;
	u->pending.reset = reset; u->pending.sharpness = sharpness; u->pending.frameTimeMs = frameTimeMs;
	u->pending.camNear = camNear; u->pending.camFar = camFar; u->pending.fovY = fovY;
	if (u->hookView != viewId)
	{
		if (u->hookView != 0xffff) tallow_vk_set_view_hook(u->hookView, nullptr, nullptr);
		u->hookView = viewId;
	}
	tallow_vk_set_view_hook(viewId, viewHook, u);
	return 1;
}

// 1 when this upscaler hit an error on the GPU side (the engine should fall back to another anti-aliasing mode).
int tn_upscale_failed(void* ctx)
{
	Upscaler* u = static_cast<Upscaler*>(ctx);
	return u != nullptr && u->failed ? 1 : 0;
}

void tn_upscale_shutdown()
{
	while (!s_upscalers.empty())
		tn_upscale_destroy(s_upscalers.back());
#if defined(TALLOW_HAVE_DLSS)
	if (s_ngxInit)
	{
		if (s_ngxCaps != nullptr) { NVSDK_NGX_VULKAN_DestroyParameters(s_ngxCaps); s_ngxCaps = nullptr; }
		if (s_haveNative) NVSDK_NGX_VULKAN_Shutdown1((VkDevice)s_native.device);
		s_ngxInit = false;
	}
#endif
	s_dlssChecked = false;
	s_fsrChecked = false;
	s_dlssOk = false;
	s_fsrOk = false;
	s_haveNative = false;
}

}

#if defined(TALLOW_HAVE_FSR2)
// The few Vulkan entry points FSR 2 calls directly, answered through the pointers bgfx loaded (see upscale/vk/vulkan/vulkan.h).
extern "C" {
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties* p)
{
	instanceFn<PFN_vkGetPhysicalDeviceMemoryProperties>("vkGetPhysicalDeviceMemoryProperties")(pd, p);
}
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceProperties(VkPhysicalDevice pd, VkPhysicalDeviceProperties* p)
{
	instanceFn<PFN_vkGetPhysicalDeviceProperties>("vkGetPhysicalDeviceProperties")(pd, p);
}
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceProperties2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2* p)
{
	instanceFn<PFN_vkGetPhysicalDeviceProperties2>("vkGetPhysicalDeviceProperties2")(pd, p);
}
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2* p)
{
	instanceFn<PFN_vkGetPhysicalDeviceFeatures2>("vkGetPhysicalDeviceFeatures2")(pd, p);
}
VKAPI_ATTR VkResult VKAPI_CALL tallow_fsr2_vkEnumerateDeviceExtensionProperties(VkPhysicalDevice pd, const char* layer, uint32_t* count, VkExtensionProperties* props)
{
	return instanceFn<PFN_vkEnumerateDeviceExtensionProperties>("vkEnumerateDeviceExtensionProperties")(pd, layer, count, props);
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL tallow_fsr2_vkGetDeviceProcAddr(VkDevice d, const char* name)
{
	return s_gdpa(d, name);
}
}
#endif

#else // TALLOW_UPSCALE_VULKAN

// No Vulkan renderer on this platform (macOS, iOS, Android, the web player, Linux arm64): the native upscalers cannot
// run, but the engine still calls their API. These stubs report them unavailable; the jitter maths is shared with the
// Vulkan build because the engine's own temporal upscaling uses it on every platform.

namespace
{
	float halton(int index, int base)
	{
		float f = 1.0f, r = 0.0f;
		while (index > 0)
		{
			f /= (float)base;
			r += f * (float)(index % base);
			index /= base;
		}
		return r;
	}
}

extern "C" void tn_upscale_prepare_vulkan(void)
{
}

extern "C" {

int tn_upscale_supported(int kind, char* reason, int reasonLength)
{
	(void)kind;
	if (reason != nullptr && reasonLength > 0)
		std::snprintf(reason, (size_t)reasonLength, "%s", "DLSS and FSR need the Vulkan renderer");
	return 0;
}

int tn_upscale_optimal_size(int kind, int outW, int outH, int qualityMode, int* renderW, int* renderH)
{
	static const float ratios[] = { 1.5f, 1.7f, 2.0f, 3.0f, 1.0f, 1.3f };
	if (renderW == nullptr || renderH == nullptr || outW <= 0 || outH <= 0) return 0;
	if (qualityMode < 0 || qualityMode > 5) qualityMode = 0;
	(void)kind;
	float r = ratios[qualityMode];
	if (r <= 1.0f) { *renderW = outW; *renderH = outH; return 1; }
	*renderW = (int)((float)outW / r);
	*renderH = (int)((float)outH / r);
	return 1;
}

int tn_upscale_jitter_phases(int kind, int renderW, int outW)
{
	if (renderW <= 0) return 8;
	float ratio = (float)outW / (float)renderW;
	int n = (int)std::ceil(8.0f * ratio * ratio);
	(void)kind;
	return n < 8 ? 8 : (n > 256 ? 256 : n);
}

void tn_upscale_jitter_offset(int kind, int index, int phases, float* x, float* y)
{
	(void)kind;
	if (phases < 1) phases = 8;
	int i = (index % phases) + 1;
	if (x != nullptr) *x = halton(i, 2) - 0.5f;
	if (y != nullptr) *y = halton(i, 3) - 0.5f;
}

void* tn_upscale_create(int kind, int renderW, int renderH, int outW, int outH, int qualityMode, int flags)
{
	(void)kind; (void)renderW; (void)renderH; (void)outW; (void)outH; (void)qualityMode; (void)flags;
	return nullptr;
}

void tn_upscale_destroy(void* ctx)
{
	(void)ctx;
}

int tn_upscale_evaluate(void* ctx, uint16_t colorTex, uint16_t depthTex, uint16_t motionTex, uint16_t outputTex,
	float jitterX, float jitterY, float motionScaleX, float motionScaleY, int reset, float sharpness, float frameTimeMs,
	float camNear, float camFar, float fovY, uint16_t viewId)
{
	(void)ctx; (void)colorTex; (void)depthTex; (void)motionTex; (void)outputTex; (void)jitterX; (void)jitterY;
	(void)motionScaleX; (void)motionScaleY; (void)reset; (void)sharpness; (void)frameTimeMs; (void)camNear;
	(void)camFar; (void)fovY; (void)viewId;
	return 0;
}

int tn_upscale_failed(void* ctx)
{
	(void)ctx;
	return 0;
}

void tn_upscale_shutdown()
{
}

}

#endif // TALLOW_UPSCALE_VULKAN
