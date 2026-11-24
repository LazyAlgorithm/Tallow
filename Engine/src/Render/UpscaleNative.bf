using System;

namespace Tallow;

/// Raw entry points of native/tallow_upscale.cpp (NVIDIA DLSS and AMD FSR, Vulkan renderer only). The conventions for
/// textures, depth, motion vectors and jitter are documented at the top of that file. kind: 1 DLSS, 2 FSR.
/// Quality modes: 0 Quality, 1 Balanced, 2 Performance, 3 Ultra Performance, 4 Native AA (DLAA), 5 Ultra Quality.
/// Create flags: 1 HDR color, 2 inverted depth, 4 motion vectors at render resolution (always set), 8 auto exposure.
static class UpscaleNative
{
	[CLink] public static extern int32 tn_upscale_supported(int32 kind, char8* reason, int32 reasonLength);
	[CLink] public static extern int32 tn_upscale_optimal_size(int32 kind, int32 outW, int32 outH, int32 qualityMode, int32* renderW, int32* renderH);
	[CLink] public static extern int32 tn_upscale_jitter_phases(int32 kind, int32 renderW, int32 outW);
	[CLink] public static extern void tn_upscale_jitter_offset(int32 kind, int32 index, int32 phases, float* x, float* y);
	[CLink] public static extern void* tn_upscale_create(int32 kind, int32 renderW, int32 renderH, int32 outW, int32 outH, int32 qualityMode, int32 flags);
	[CLink] public static extern void tn_upscale_destroy(void* ctx);
	[CLink] public static extern int32 tn_upscale_evaluate(void* ctx, uint16 colorTex, uint16 depthTex, uint16 motionTex, uint16 outputTex,
		float jitterX, float jitterY, float motionScaleX, float motionScaleY, int32 reset, float sharpness, float frameTimeMs,
		float camNear, float camFar, float fovY, uint16 viewId);
	[CLink] public static extern int32 tn_upscale_failed(void* ctx);
	[CLink] public static extern void tn_upscale_shutdown();
}
