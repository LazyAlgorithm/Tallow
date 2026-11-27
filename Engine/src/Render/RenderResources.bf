using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Shaders, uniforms and the shadow atlas shared by every RenderView.
static class RenderResources
{
	public const int CascadeCount = 4;
	/// The shadow map's size in pixels (four cascades in a 2 x 2 grid). Set before the first frame is drawn; phones
	/// use a smaller one (Gfx.UseMobileQuality).
	public static int32 ShadowAtlasSize = 4096;
	public static int32 ShadowTileSize => ShadowAtlasSize / 2;

	public static bool Ready;
	public static bgfx.ProgramHandle MeshProgram;
	public static bgfx.ProgramHandle ShadowProgram;
	public static bgfx.ProgramHandle SkyProgram;
	/// The physical sky (SkyMode.Physical; PhysicalSky.bf).
	public static bgfx.ProgramHandle SkyPhysicalProgram;
	public static bgfx.ProgramHandle TonemapProgram;
	public static bgfx.ProgramHandle BloomDownProgram, BloomBlurProgram;
	// Antialiasing and upscaling of the finished picture (RenderViewAntialias.bf).
	public static bgfx.ProgramHandle FxaaProgram, SmaaEdgesProgram, SmaaWeightsProgram, SmaaBlendProgram, EasuProgram, RcasProgram;
	public static bgfx.UniformHandle uAaParams, uFsrParams, sEdges, sArea, sSearch, sBlend;
	public static bgfx.UniformHandle sBloom, uBloomParams;
	// Screen effects (tallowengine.com/docs/post-processing).
	public static bgfx.ProgramHandle DepthProgram, AoProgram, AoApplyProgram, DofBlurProgram, DofCombineProgram, MotionBlurProgram;
	public static bgfx.UniformHandle sDepth, sAo, sBlur, sLut;
	public static bgfx.UniformHandle uDepthViewProj, uDepthParams, uAoParams, uDofParams, uMotionParams, uPrevViewProj;
	public static bgfx.UniformHandle uPostRight, uPostUp, uPostForward, uPostEye, uGradeParams, uGradeFilter;
	// Screen-space global illumination (RenderViewEffects.bf).
	public static bgfx.ProgramHandle DepthAlbedoProgram, SsgiGatherProgram, SsgiApplyProgram;
	// Temporal antialiasing and motion vectors (RenderViewTemporal.bf).
	public static bgfx.ProgramHandle DepthVelProgram, DepthAlbedoVelProgram, SkyVelProgram, SkyVelAlbedoProgram, TaaProgram, VelocityViewProgram;
	public static bgfx.UniformHandle uVelCur, uVelPrev, uVelParams, uTaaParams, uTaaParams2, sVelocity, sHistory;
	public static bgfx.UniformHandle sSsgi, sSsgiHistory, sAlbedoBuffer, uSsgiParams, uSsgiParams2;
	// Volumetric fog (tallowengine.com/docs/day-night; RenderViewVolumetric.bf): the froxel inject and integrate compute
	// shaders, the fullscreen apply, and the see-through things' and water's variants that sample the sums themselves.
	// The fallback (OpenGL, the web, --gpu-driven-caps-off) draws the height fog and its shafts instead.
	public static bgfx.ProgramHandle VFogInjectProgram, VFogIntegrateProgram, VFogApplyProgram, VFogFallbackProgram;
	public static bgfx.ProgramHandle MeshVFogProgram, WaterVFogProgram;
	/// The most Fog Volumes one view draws (the rest are left out).
	public const int32 FogVolumeMax = 32;
	public static bgfx.UniformHandle uVFogMedium, uVFogLight, uVFogGrid, uVFogSize, sVFog, sVFogCells, sVFogHistory;
	public static bgfx.UniformHandle uVFogTemporal, uVFogPrevViewProj, uVFogDebug, uFogVolumes, uFogVolumeCount;
	public static bool VFogReady;
	public static bgfx.ProgramHandle LineProgram;
	// Decals (tallowengine.com/docs/decals).
	public static bgfx.ProgramHandle DecalProgram;
	public static bgfx.UniformHandle uDecalBox, uDecalInverse, uDecalColor, uDecalAxis, uDecalParams;
	// Water (tallowengine.com/docs/water).
	public static bgfx.ProgramHandle WaterProgram, UnderwaterProgram, CopyProgram;
	/// Shiny surfaces with Screen Reflections, drawn again over themselves: what the screen shows mirrored in them.
	public static bgfx.ProgramHandle MirrorProgram;
	/// The mirror pass's own: its planar reflection's picture, and x 1 when it reads that (else it traces the screen).
	public static bgfx.UniformHandle sPlanar, uMirrorParams;
	public static bgfx.UniformHandle uWaveA, uWaveB, uWaterLevel, uWaterModel, uWaterParams, uWaterShallow, uWaterDeep, uWaterFoam, uWaterOptions, uWaterUnder;
	public static bgfx.UniformHandle uWaterInverse, uWaterUnderParams;

	public static bgfx.UniformHandle sAlbedo, sShadowMap, sLocalShadowMap, sColor;
	public static bgfx.UniformHandle uWind, uWindZone, uWindPush, uSway, uBender, uBenderPush;
	public static bgfx.UniformHandle uCamPos, uSunDir, uSunColor, uAmbientSky, uAmbientGround, uFogColor;
	public static bgfx.UniformHandle uMaterial, uEmissive, uUvTransform, uVtInfo, uVtCache, uSurface, uParams, uPbr, uPalette, sTexture1, sTexture2, sNormalMap, sMetalRoughMap, sOcclusionMap, sEmissiveMap;
	public static bgfx.UniformHandle sLightmap, sLightmapDirection, sLightmapShadowmask, uLightmapTransform, uLightmapDecode;
	/// Baked light probes (LightProbes): the grids' 3D texture and where the draw's two grids are in it.
	public static bgfx.UniformHandle sLightProbes, uLightProbe;
	// Lights by cluster (LightClusters, tallowengine.com/docs/lighting).
	public static bgfx.UniformHandle sLightData, uLightCount, uClusterViewProj, uClusterForward, uClusterParams;
	public static bgfx.UniformHandle uShadowMtx, uCascadeSplits, uShadowParams, uShadowViewProj;
	public static bgfx.UniformHandle uSkyZenith, uSkyHorizon, uSkyGround, uPostParams;
	// The cloud layer (PhysicalSky.SetUniforms; include/clouds.sh). The volumetric march (C2) shares this block.
	public static bgfx.UniformHandle uCloudShape, uCloudWind, uCloudLight, uCloudView, uCloudTint;
	public static bgfx.UniformHandle uCloudSunDir, uCloudSunColor, uCloudMoonDir, uCloudMoonColor, uCloudAmbient;
	/// The cloud pass (cs_clouds.sc, RenderViewClouds.bf): the march's steps and frame, the target's size, its texture.
	public static bgfx.ProgramHandle CloudsProgram;
	public static bgfx.UniformHandle uCloudSteps, uCloudSize, sClouds;
	/// The cloud pass's temporal blend (C2c): last frame's view-projection, the weather's drift since, the debug view's
	/// ray-count switch, and the history and blue-noise samplers.
	public static bgfx.UniformHandle uCloudPrevViewProj, uCloudWindDelta, uCloudDebug, sCloudHistory, sCloudNoise;
	/// The 32x32 blue-noise tile the march's start is jittered with (each value 0..255, 0 once, 255 once), made by
	/// Ulichney's void-and-cluster and kept here so every run and every peer jitters identically. Sampled with point
	/// filtering and wrapped by the shader (cs_clouds.sc), so it tiles.
	public static bgfx.TextureHandle BlueNoise = .() { idx = uint16.MaxValue };
	/// Bound as s_clouds where the raymarch did not run, so the sky shader's sampler is always set (1x1, transparent).
	public static bgfx.TextureHandle CloudDummy;
	public static bool CloudsReady;

	/// The 32x32 blue-noise tile (BlueNoise), row by row: every value 0..255 used once, arranged so no two close values
	/// are neighbours in a way white noise would allow (Ulichney's void-and-cluster, sigma 1.5, tileable). Fixed here
	/// rather than generated at startup so the jitter is the same on every run and every peer.
	static uint8[1024] sBlueNoise = .(
		 85, 239,  28,  79, 164,  22, 204, 160, 113, 183, 218, 155, 241,  32, 114, 221, 190, 129,  70, 216, 146, 195, 239,   7, 158,  27, 119,  42, 100,  25, 122, 220,
		150, 175, 103, 224,  53, 123, 231,  62,  40, 133,  24,  51, 121, 180,  88, 161,  60, 102, 166,  13, 110,  36,  78, 124, 224,  83, 205, 154, 235,  67, 162,  38,
		 63,  15, 202, 143, 189,   1, 148,  99, 195, 255,  91, 190, 231,  73,  17, 249,  28, 197, 242,  86, 230, 136, 211,  50, 185, 138,  63,   1, 184,  93, 247, 191,
		129, 244,  71,  34,  93, 248,  75, 216,  11, 163,  66, 147,   6, 135, 201, 107, 140,  44, 152,  56, 178,  19, 165,  97,  15, 252, 104, 227,  46, 141,  11, 105,
		 47, 158, 112, 216, 132, 169,  46, 179, 120,  37, 207, 105, 221,  46, 165, 226,  76, 213,   7, 126, 204,  68, 243, 148, 203,  36, 159, 124, 200,  72, 223, 206,
		 80, 226,   5, 180,  60,  23, 110, 242,  84, 138, 237,  26, 172,  93,  63,  20, 120, 185,  92, 254, 110,  41,  86, 120,  61, 181,  79,  24, 167, 113,  33, 171,
		 21, 190, 138,  84, 233, 206, 155,  15, 196,  57, 183,  81, 122, 252, 193, 155, 238,  52, 170,  24, 154, 189, 228,   5, 218, 101, 240, 208,  54, 250, 146,  97,
		124,  55, 253,  37, 103, 141,  69, 227, 100, 160,   2, 215,  36, 137,  12, 102,  35, 143, 229,  81, 210,  30, 140, 172,  45, 129,  14, 144,  89,   4, 186, 232,
		157, 210, 115, 174,  13, 186,  48, 127,  32, 248, 115, 152,  67, 176, 219,  77, 201, 113,   2, 132,  54, 106,  71, 250, 156, 194,  70, 175, 218, 134,  65,  41,
		 90,   9,  73, 147, 237,  90, 220, 165, 202,  88,  52, 234, 199, 109,  48, 246, 166,  64, 212, 161, 244, 186,  13, 115,  88,  31, 211, 104,  20, 237, 111, 204,
		246, 167, 222,  53, 198,  29, 109,   8,  74, 176, 135,  27,  92,   8, 149, 126,  17, 189,  96,  32,  87, 126, 225, 199,  57, 230, 125,  52, 160,  80, 173,  28,
		141, 108,  20, 126,  79, 137, 252, 153, 214,  18, 226, 186, 162, 238, 213,  85,  42, 232, 140, 219, 179,  48,  24, 166, 143,   1, 183, 254,  35, 198, 127,  58,
		182,  39, 191, 243, 168,  43, 188,  59, 121, 101,  43,  66, 122,  33,  58, 185, 159, 113,  61,  10,  77, 207, 134,  67, 236, 107,  76, 147,  98, 223,   7, 234,
		 97, 217,  61,  89,   0, 228,  95,  26, 240, 197, 151, 250,  83, 208, 142,  99, 255,  28, 174, 241, 149, 109, 251,  96,  30, 171, 209,  17,  60, 119, 154,  75,
		 16, 132, 158, 117, 205, 150, 125, 175,  70, 137,  12, 171, 106,   4, 192,  20,  73, 204, 130,  94,  38, 164,   7, 187, 217,  46, 131, 241, 193, 174,  45, 207,
		177, 239,  25, 222,  50,  74,  19, 218,  40,  90, 233,  54, 216, 128, 229, 167, 122,  48, 225,  70, 195, 227,  59,  84, 151, 116,  69, 159,  29,  84, 251, 112,
		 68,  42,  85, 170, 103, 196, 237, 158, 188, 119, 203,  31, 156,  65,  40,  86, 240, 152,   0, 178,  26, 117, 142,  19, 246, 200,  10,  94, 214, 138,   3, 152,
		230, 193, 142, 255,   9, 131,  44, 101,   4, 144,  77, 177,  99, 248, 183, 112,  18, 201, 100, 139, 211,  88, 235, 172, 101,  41, 181, 233, 114,  39, 202,  95,
		127,  16, 115,  55, 184, 151,  81, 247,  62, 214, 242,  22, 133,   9, 145, 210,  57, 171,  74, 251,  53, 162,  33,  65, 220, 125,  72, 164,  55, 245, 182,  58,
		215, 168, 207,  76, 233,  30, 198, 116, 168,  36, 107,  56, 196, 222,  71,  30, 228, 123,  38, 114,  10, 203, 134, 192,   3, 150, 209,  22, 135,  82, 156,  27,
		 87,  40, 102,  12, 161,  94, 223,  16, 130, 191, 148, 229,  85, 117, 169,  95, 140, 188, 236, 159, 220,  78, 106, 249,  91,  52, 236, 102, 199,  10, 116, 236,
		133, 245, 145, 221, 128,  64, 175,  49, 211,  69,   6, 163,  37, 187,  49, 253,   6,  82,  26,  62, 130,  17, 179,  39, 166, 118, 182,  35, 145, 225, 178,  67,
		  5, 173,  56, 193,  39, 248, 110, 146,  87, 252,  98, 123, 240,  14, 151, 206, 109, 165, 209,  98, 187, 226, 147,  68, 231,  18,  78, 253,  64,  97,  44, 196,
		212,  78, 118,  23,  90, 184,   1, 229,  27, 170, 200,  58, 213,  80, 129,  60, 232,  37, 145, 243,  45,  86,  29, 198, 136, 214, 160, 121, 205,  25, 161, 107,
		 32, 149, 234, 203, 156, 136,  77, 195, 116,  42, 135,  22, 174, 105, 194,  18, 177,  75, 118,   2, 173, 123, 245, 112,  49,  96,   5,  53, 176, 231, 137, 249,
		189, 100,  15,  63, 241,  44, 215,  57, 154, 238,  83, 224, 153,  43, 245,  92, 136, 222, 197,  59, 155, 210,  72,  21, 168, 194, 244, 131,  89,  12,  82,  51,
		 71, 224, 131, 179, 106,  13, 124, 176,  93,   8, 190, 114,  68,   3, 217, 163,  50,  23, 104, 254,  91,  14, 188, 148, 225,  79,  31, 153, 223, 185, 117, 157,
		  2, 169,  47, 217,  81, 163, 250,  31, 221, 139,  51, 253, 182, 141, 118,  74, 239, 153, 181,  35, 139, 230,  45,  99, 125,  56, 178, 108,  65,  43, 242, 208,
		 91, 254, 119,  25, 200, 134,  69, 103, 197,  75, 164,  21,  89, 209,  34, 192,  16, 127,  82, 201,  64, 111, 173, 249,   3, 205, 235,  23, 212, 149,  19, 132,
		 34,  66, 157,  98, 232,  41, 187,  11, 121, 235,  38, 111, 228,  59, 167, 105, 213,  54, 227,   9, 157, 208,  76,  34, 144,  94, 162, 128,  87, 192, 104, 181,
		146, 212, 194,   8,  62, 143, 219, 170,  55, 144, 206, 177, 133,  14, 247,  83, 142, 172,  96, 120, 246,  21, 130, 219, 191,  47,  73,  11, 251,  49,  72, 234,
		111,  50, 128, 180, 247, 108,  85,  29, 244,  80,   4,  95,  66, 199, 150,  47,   0, 238,  33, 184,  51,  92, 169,  61, 108, 243, 180, 215, 139, 170, 202,   6);

	public static bgfx.TextureHandle ShadowMap;
	public static bgfx.FrameBufferHandle ShadowFrameBuffer;
	/// Point and spot lights' shadows: tiles of one atlas the size of the sun's, made when a light first needs it.
	public static bgfx.TextureHandle LocalShadowMap = .() { idx = uint16.MaxValue };
	public static bgfx.FrameBufferHandle LocalShadowFrameBuffer = .() { idx = uint16.MaxValue };

	public static void EnsureCreated()
	{
		if (Ready)
			return;
		MeshProgram = Gfx.LoadProgram("vs_mesh", "fs_mesh");
		ShadowProgram = Gfx.LoadProgram("vs_shadow", "fs_shadow");
		SkyProgram = Gfx.LoadProgram("vs_fullscreen", "fs_sky");
		SkyPhysicalProgram = Gfx.LoadProgram("vs_fullscreen", "fs_sky_physical");
		TonemapProgram = Gfx.LoadProgram("vs_fullscreen", "fs_tonemap");
		BloomDownProgram = Gfx.LoadProgram("vs_fullscreen", "fs_bloom_down");
		BloomBlurProgram = Gfx.LoadProgram("vs_fullscreen", "fs_bloom_blur");
		FxaaProgram = Gfx.LoadProgram("vs_fullscreen", "fs_fxaa");
		SmaaEdgesProgram = Gfx.LoadProgram("vs_fullscreen", "fs_smaa_edges");
		SmaaWeightsProgram = Gfx.LoadProgram("vs_fullscreen", "fs_smaa_weights");
		SmaaBlendProgram = Gfx.LoadProgram("vs_fullscreen", "fs_smaa_blend");
		EasuProgram = Gfx.LoadProgram("vs_fullscreen", "fs_fsr_easu");
		RcasProgram = Gfx.LoadProgram("vs_fullscreen", "fs_fsr_rcas");
		uAaParams = bgfx.create_uniform("u_aaParams", .Vec4, 1);
		uFsrParams = bgfx.create_uniform("u_fsrParams", .Vec4, 1);
		sEdges = bgfx.create_uniform("s_edges", .Sampler, 1);
		sArea = bgfx.create_uniform("s_area", .Sampler, 1);
		sSearch = bgfx.create_uniform("s_search", .Sampler, 1);
		sBlend = bgfx.create_uniform("s_blend", .Sampler, 1);
		sBloom = bgfx.create_uniform("s_bloom", .Sampler, 1);
		uBloomParams = bgfx.create_uniform("u_bloomParams", .Vec4, 1);
		DepthProgram = Gfx.LoadProgram("vs_depth", "fs_depth");
		AoProgram = Gfx.LoadProgram("vs_fullscreen", "fs_ao");
		AoApplyProgram = Gfx.LoadProgram("vs_fullscreen", "fs_ao_apply");
		DofBlurProgram = Gfx.LoadProgram("vs_fullscreen", "fs_dof_blur");
		DofCombineProgram = Gfx.LoadProgram("vs_fullscreen", "fs_dof_combine");
		MotionBlurProgram = Gfx.LoadProgram("vs_fullscreen", "fs_motion_blur");
		DepthAlbedoProgram = Gfx.LoadProgram("vs_depth_albedo", "fs_depth_albedo");
		DepthVelProgram = Gfx.LoadProgram("vs_depth_vel", "fs_depth_vel");
		DepthAlbedoVelProgram = Gfx.LoadProgram("vs_depth_albedo_vel", "fs_depth_albedo_vel");
		SkyVelProgram = Gfx.LoadProgram("vs_fullscreen", "fs_depth_sky_vel");
		SkyVelAlbedoProgram = Gfx.LoadProgram("vs_fullscreen", "fs_depth_sky_vel_albedo");
		TaaProgram = Gfx.LoadProgram("vs_fullscreen", "fs_taa");
		VelocityViewProgram = Gfx.LoadProgram("vs_fullscreen", "fs_velocity_view");
		uVelCur = bgfx.create_uniform("u_velCur", .Mat4, 1);
		uVelPrev = bgfx.create_uniform("u_velPrev", .Mat4, 1);
		uVelParams = bgfx.create_uniform("u_velParams", .Vec4, 1);
		uTaaParams = bgfx.create_uniform("u_taaParams", .Vec4, 1);
		uTaaParams2 = bgfx.create_uniform("u_taaParams2", .Vec4, 1);
		sVelocity = bgfx.create_uniform("s_velocity", .Sampler, 1);
		sHistory = bgfx.create_uniform("s_history", .Sampler, 1);
		SsgiGatherProgram = Gfx.LoadProgram("vs_fullscreen", "fs_ssgi");
		SsgiApplyProgram = Gfx.LoadProgram("vs_fullscreen", "fs_ssgi_apply");
		sSsgi = bgfx.create_uniform("s_ssgi", .Sampler, 1);
		sSsgiHistory = bgfx.create_uniform("s_ssgiHistory", .Sampler, 1);
		sAlbedoBuffer = bgfx.create_uniform("s_albedoBuffer", .Sampler, 1);
		uSsgiParams = bgfx.create_uniform("u_ssgiParams", .Vec4, 1);
		uSsgiParams2 = bgfx.create_uniform("u_ssgiParams2", .Vec4, 1);
		sDepth = bgfx.create_uniform("s_depth", .Sampler, 1);
		sAo = bgfx.create_uniform("s_ao", .Sampler, 1);
		sBlur = bgfx.create_uniform("s_blur", .Sampler, 1);
		sLut = bgfx.create_uniform("s_lut", .Sampler, 1);
		uDepthViewProj = bgfx.create_uniform("u_depthViewProj", .Mat4, 1);
		uDepthParams = bgfx.create_uniform("u_depthParams", .Vec4, 1);
		uAoParams = bgfx.create_uniform("u_aoParams", .Vec4, 1);
		uDofParams = bgfx.create_uniform("u_dofParams", .Vec4, 1);
		uMotionParams = bgfx.create_uniform("u_motionParams", .Vec4, 1);
		uPrevViewProj = bgfx.create_uniform("u_prevViewProj", .Mat4, 1);
		uPostRight = bgfx.create_uniform("u_postRight", .Vec4, 1);
		uPostUp = bgfx.create_uniform("u_postUp", .Vec4, 1);
		uPostForward = bgfx.create_uniform("u_postForward", .Vec4, 1);
		uPostEye = bgfx.create_uniform("u_postEye", .Vec4, 1);
		uGradeParams = bgfx.create_uniform("u_gradeParams", .Vec4, 1);
		uGradeFilter = bgfx.create_uniform("u_gradeFilter", .Vec4, 1);
		LineProgram = Gfx.LoadProgram("vs_debug", "fs_debug");
		DecalProgram = Gfx.LoadProgram("vs_decal", "fs_decal");
		uDecalBox = bgfx.create_uniform("u_decalBox", .Mat4, 1);
		uDecalInverse = bgfx.create_uniform("u_decalInverse", .Mat4, 1);
		uDecalColor = bgfx.create_uniform("u_decalColor", .Vec4, 1);
		uDecalAxis = bgfx.create_uniform("u_decalAxis", .Vec4, 1);
		uDecalParams = bgfx.create_uniform("u_decalParams", .Vec4, 1);
		WaterProgram = Gfx.LoadProgram("vs_water", "fs_water");
		MirrorProgram = Gfx.LoadProgram("vs_mesh", "fs_mirror");
		UnderwaterProgram = Gfx.LoadProgram("vs_fullscreen", "fs_underwater");
		CopyProgram = Gfx.LoadProgram("vs_fullscreen", "fs_copy");
		uWaveA = bgfx.create_uniform("u_waveA", .Vec4, Water.WaveCount);
		uWaveB = bgfx.create_uniform("u_waveB", .Vec4, Water.WaveCount);
		uWaterLevel = bgfx.create_uniform("u_waterLevel", .Vec4, 1);
		uWaterModel = bgfx.create_uniform("u_waterModel", .Mat4, 1);
		uWaterParams = bgfx.create_uniform("u_waterParams", .Vec4, 1);
		uWaterShallow = bgfx.create_uniform("u_waterShallow", .Vec4, 1);
		uWaterDeep = bgfx.create_uniform("u_waterDeep", .Vec4, 1);
		uWaterFoam = bgfx.create_uniform("u_waterFoam", .Vec4, 1);
		uWaterOptions = bgfx.create_uniform("u_waterOptions", .Vec4, 1);
		uWaterUnder = bgfx.create_uniform("u_waterUnder", .Vec4, 1);
		uWaterInverse = bgfx.create_uniform("u_waterInverse", .Mat4, 1);
		uWaterUnderParams = bgfx.create_uniform("u_waterUnderParams", .Vec4, 1);

		sAlbedo = bgfx.create_uniform("s_albedo", .Sampler, 1);
		sShadowMap = bgfx.create_uniform("s_shadowMap", .Sampler, 1);
		sLocalShadowMap = bgfx.create_uniform("s_localShadowMap", .Sampler, 1);
		uShadowViewProj = bgfx.create_uniform("u_shadowViewProj", .Mat4, 1);
		sColor = bgfx.create_uniform("s_color", .Sampler, 1);
		sPlanar = bgfx.create_uniform("s_planar", .Sampler, 1);
		uMirrorParams = bgfx.create_uniform("u_mirrorParams", .Vec4, 1);
		uCamPos = bgfx.create_uniform("u_camPos", .Vec4, 1);
		uSunDir = bgfx.create_uniform("u_sunDir", .Vec4, 1);
		uSunColor = bgfx.create_uniform("u_sunColor", .Vec4, 1);
		uAmbientSky = bgfx.create_uniform("u_ambientSky", .Vec4, 1);
		uAmbientGround = bgfx.create_uniform("u_ambientGround", .Vec4, 1);
		uFogColor = bgfx.create_uniform("u_fogColor", .Vec4, 1);
		uMaterial = bgfx.create_uniform("u_material", .Vec4, 1);
		uEmissive = bgfx.create_uniform("u_emissive", .Vec4, 1);
		uUvTransform = bgfx.create_uniform("u_uvTransform", .Vec4, 1);
		uVtInfo = bgfx.create_uniform("u_vtInfo", .Vec4, 1);
		uVtCache = bgfx.create_uniform("u_vtCache", .Vec4, 1);
		uSurface = bgfx.create_uniform("u_surface", .Vec4, 1);
		uWind = bgfx.create_uniform("u_wind", .Vec4, 1);
		uWindZone = bgfx.create_uniform("u_windZone", .Vec4, 4);
		uWindPush = bgfx.create_uniform("u_windPush", .Vec4, 4);
		uSway = bgfx.create_uniform("u_sway", .Vec4, 1);
		uBender = bgfx.create_uniform("u_bender", .Vec4, 8);
		uBenderPush = bgfx.create_uniform("u_benderPush", .Vec4, 8);
		uParams = bgfx.create_uniform("u_params", .Vec4, ShaderAsset.MaxValues);
		sTexture1 = bgfx.create_uniform("s_texture1", .Sampler, 1);
		sTexture2 = bgfx.create_uniform("s_texture2", .Sampler, 1);
		uPbr = bgfx.create_uniform("u_pbr", .Vec4, 1);
		uPalette = bgfx.create_uniform("u_palette", .Vec4, 1);
		sLightmap = bgfx.create_uniform("s_lightmap", .Sampler, 1);
		sLightmapDirection = bgfx.create_uniform("s_lightmapDirection", .Sampler, 1);
		sLightmapShadowmask = bgfx.create_uniform("s_lightmapShadowmask", .Sampler, 1);
		uLightmapTransform = bgfx.create_uniform("u_lightmapTransform", .Vec4, 1);
		uLightmapDecode = bgfx.create_uniform("u_lightmapDecode", .Vec4, 1);
		sLightProbes = bgfx.create_uniform("s_lightProbes", .Sampler, 1);
		uLightProbe = bgfx.create_uniform("u_lightProbe", .Vec4, 10);
		sNormalMap = bgfx.create_uniform("s_normalMap", .Sampler, 1);
		sMetalRoughMap = bgfx.create_uniform("s_metalRoughMap", .Sampler, 1);
		sOcclusionMap = bgfx.create_uniform("s_occlusionMap", .Sampler, 1);
		sEmissiveMap = bgfx.create_uniform("s_emissiveMap", .Sampler, 1);
		sLightData = bgfx.create_uniform("s_lightData", .Sampler, 1);
		uLightCount = bgfx.create_uniform("u_lightCount", .Vec4, 1);
		uClusterViewProj = bgfx.create_uniform("u_clusterViewProj", .Mat4, 1);
		uClusterForward = bgfx.create_uniform("u_clusterForward", .Vec4, 1);
		uClusterParams = bgfx.create_uniform("u_clusterParams", .Vec4, 1);
		uShadowMtx = bgfx.create_uniform("u_shadowMtx", .Mat4, CascadeCount);
		uCascadeSplits = bgfx.create_uniform("u_cascadeSplits", .Vec4, 1);
		uShadowParams = bgfx.create_uniform("u_shadowParams", .Vec4, 1);
		uSkyZenith = bgfx.create_uniform("u_skyZenith", .Vec4, 1);
		uSkyHorizon = bgfx.create_uniform("u_skyHorizon", .Vec4, 1);
		uSkyGround = bgfx.create_uniform("u_skyGround", .Vec4, 1);
		uPostParams = bgfx.create_uniform("u_postParams", .Vec4, 1);
		uCloudShape = bgfx.create_uniform("u_cloudShape", .Vec4, 1);
		uCloudWind = bgfx.create_uniform("u_cloudWind", .Vec4, 1);
		uCloudLight = bgfx.create_uniform("u_cloudLight", .Vec4, 1);
		uCloudView = bgfx.create_uniform("u_cloudView", .Vec4, 1);
		uCloudTint = bgfx.create_uniform("u_cloudTint", .Vec4, 1);
		uCloudSunDir = bgfx.create_uniform("u_cloudSunDir", .Vec4, 1);
		uCloudSunColor = bgfx.create_uniform("u_cloudSunColor", .Vec4, 1);
		uCloudMoonDir = bgfx.create_uniform("u_cloudMoonDir", .Vec4, 1);
		uCloudMoonColor = bgfx.create_uniform("u_cloudMoonColor", .Vec4, 1);
		uCloudAmbient = bgfx.create_uniform("u_cloudAmbient", .Vec4, 1);
		uCloudSteps = bgfx.create_uniform("u_cloudSteps", .Vec4, 1);
		uCloudSize = bgfx.create_uniform("u_cloudSize", .Vec4, 1);
		uCloudPrevViewProj = bgfx.create_uniform("u_cloudPrevViewProj", .Mat4, 1);
		uCloudWindDelta = bgfx.create_uniform("u_cloudWindDelta", .Vec4, 1);
		uCloudDebug = bgfx.create_uniform("u_cloudDebug", .Vec4, 1);
		sCloudHistory = bgfx.create_uniform("s_cloudHistory", .Sampler, 1);
		sCloudNoise = bgfx.create_uniform("s_cloudNoise", .Sampler, 1);
		sClouds = bgfx.create_uniform("s_clouds", .Sampler, 1);
		CloudsProgram = LoadCompute("cs_clouds");
		CloudsReady = CloudsProgram.Valid;
		BlueNoise = bgfx.create_texture_2d(32, 32, false, 1, .R8, Gfx.SamplerPoint | Gfx.SamplerClamp, bgfx.copy(&sBlueNoise[0], 32 * 32), 0);
		uint8[4] transparent = .(0, 0, 0, 0);
		CloudDummy = bgfx.create_texture_2d(1, 1, false, 1, .RGBA8, Gfx.SamplerClamp, bgfx.copy(&transparent, 4), 0);
		VFogInjectProgram = LoadCompute("cs_vfog_inject");
		VFogIntegrateProgram = LoadCompute("cs_vfog_integrate");
		VFogApplyProgram = Gfx.LoadProgram("vs_fullscreen", "fs_vfog_apply");
		VFogFallbackProgram = Gfx.LoadProgram("vs_fullscreen", "fs_vfog_fallback");
		MeshVFogProgram = Gfx.LoadProgram("vs_mesh", "fs_mesh_vfog");
		WaterVFogProgram = Gfx.LoadProgram("vs_water", "fs_water_vfog");
		uVFogMedium = bgfx.create_uniform("u_vfogMedium", .Vec4, 1);
		uVFogLight = bgfx.create_uniform("u_vfogLight", .Vec4, 1);
		uVFogGrid = bgfx.create_uniform("u_vfogGrid", .Vec4, 1);
		uVFogSize = bgfx.create_uniform("u_vfogSize", .Vec4, 1);
		sVFog = bgfx.create_uniform("s_vfog", .Sampler, 1);
		sVFogCells = bgfx.create_uniform("s_vfogCells", .Sampler, 1);
		sVFogHistory = bgfx.create_uniform("s_vfogHistory", .Sampler, 1);
		uVFogTemporal = bgfx.create_uniform("u_vfogTemporal", .Vec4, 1);
		uVFogPrevViewProj = bgfx.create_uniform("u_vfogPrevViewProj", .Mat4, 1);
		uVFogDebug = bgfx.create_uniform("u_vfogDebug", .Vec4, 1);
		uFogVolumes = bgfx.create_uniform("u_fogVolumes", .Vec4, FogVolumeMax * 5);
		uFogVolumeCount = bgfx.create_uniform("u_vfogVolumeCount", .Vec4, 1);
		VFogReady = VFogInjectProgram.Valid && VFogIntegrateProgram.Valid && VFogApplyProgram.Valid
			&& MeshVFogProgram.Valid && WaterVFogProgram.Valid;

		// Depth render target sampled with hardware comparison (PCF).
		let shadowFlags = Gfx.TextureRenderTarget | Gfx.SamplerCompareLequal | Gfx.SamplerClamp;
		ShadowMap = bgfx.create_texture_2d((uint16)ShadowAtlasSize, (uint16)ShadowAtlasSize, false, 1, .D32F, shadowFlags, null, 0);
		ShadowFrameBuffer = bgfx.create_frame_buffer_from_handles(1, &ShadowMap, true);
		Ready = true;
	}

	/// Changes the shadow map's size (a quality setting): before the first frame it is only remembered, afterwards the
	/// maps are made again at the new size.
	public static void SetShadowAtlasSize(int32 size)
	{
		let wanted = Math.Clamp(size, 256, 8192);
		if (wanted == ShadowAtlasSize)
			return;
		ShadowAtlasSize = wanted;
		if (!Ready)
			return;
		bgfx.destroy_frame_buffer(ShadowFrameBuffer);
		let shadowFlags = Gfx.TextureRenderTarget | Gfx.SamplerCompareLequal | Gfx.SamplerClamp;
		ShadowMap = bgfx.create_texture_2d((uint16)ShadowAtlasSize, (uint16)ShadowAtlasSize, false, 1, .D32F, shadowFlags, null, 0);
		ShadowFrameBuffer = bgfx.create_frame_buffer_from_handles(1, &ShadowMap, true);
		if (LocalShadowFrameBuffer.idx != uint16.MaxValue)
		{
			bgfx.destroy_frame_buffer(LocalShadowFrameBuffer);
			LocalShadowFrameBuffer.idx = uint16.MaxValue;
			LocalShadowMap.idx = uint16.MaxValue;
			EnsureLocalShadows();
		}
	}

	/// Makes the point and spot lights' shadow atlas, the first time a scene has a light that casts shadows.
	public static void EnsureLocalShadows()
	{
		if (LocalShadowFrameBuffer.idx != uint16.MaxValue) return;
		let flags = Gfx.TextureRenderTarget | Gfx.SamplerCompareLequal | Gfx.SamplerClamp;
		LocalShadowMap = bgfx.create_texture_2d((uint16)ShadowAtlasSize, (uint16)ShadowAtlasSize, false, 1, .D32F, flags, null, 0);
		LocalShadowFrameBuffer = bgfx.create_frame_buffer_from_handles(1, &LocalShadowMap, true);
	}

	/// The atlas the lit shaders read point and spot shadows from (the sun's stands in before there is one).
	public static bgfx.TextureHandle LocalShadowTexture => LocalShadowMap.idx != uint16.MaxValue ? LocalShadowMap : ShadowMap;

	/// Loads a compute program (.tcompute .bin) for a compute view, or an invalid handle if this backend did not build
	/// it.
	static bgfx.ProgramHandle LoadCompute(StringView name)
	{
		let path = scope String()..AppendF("{}/shaders/{}/{}.bin", Gfx.EngineAssetPath, Gfx.ShaderFolder, name);
		if (!AssetPack.Exists(path))
			return .() { idx = uint16.MaxValue };
		let shader = Gfx.LoadShaderFile(path);
		if (!shader.Valid)
			return .() { idx = uint16.MaxValue };
		return bgfx.create_compute_program(shader, true);
	}

	public static void Destroy()
	{
		if (!Ready)
			return;
		bgfx.destroy_uniform(sLightmap);
		bgfx.destroy_uniform(sLightmapDirection);
		bgfx.destroy_uniform(sLightmapShadowmask);
		bgfx.destroy_uniform(uLightmapTransform);
		bgfx.destroy_uniform(uLightmapDecode);
		bgfx.destroy_uniform(sLightProbes);
		bgfx.destroy_uniform(uLightProbe);
		LightProbes.Release();
		bgfx.destroy_program(MeshProgram);
		bgfx.destroy_program(ShadowProgram);
		bgfx.destroy_program(SkyProgram);
		bgfx.destroy_program(SkyPhysicalProgram);
		bgfx.destroy_program(TonemapProgram);
		bgfx.destroy_program(BloomDownProgram);
		bgfx.destroy_program(BloomBlurProgram);
		bgfx.destroy_program(FxaaProgram);
		bgfx.destroy_program(SmaaEdgesProgram);
		bgfx.destroy_program(SmaaWeightsProgram);
		bgfx.destroy_program(SmaaBlendProgram);
		bgfx.destroy_program(EasuProgram);
		bgfx.destroy_program(RcasProgram);
		bgfx.destroy_uniform(uAaParams);
		bgfx.destroy_uniform(uFsrParams);
		bgfx.destroy_uniform(sEdges);
		bgfx.destroy_uniform(sArea);
		bgfx.destroy_uniform(sSearch);
		bgfx.destroy_uniform(sBlend);
		bgfx.destroy_program(DepthProgram);
		bgfx.destroy_program(DepthAlbedoProgram);
		bgfx.destroy_program(DepthVelProgram);
		bgfx.destroy_program(DepthAlbedoVelProgram);
		bgfx.destroy_program(SkyVelProgram);
		bgfx.destroy_program(SkyVelAlbedoProgram);
		bgfx.destroy_program(TaaProgram);
		bgfx.destroy_program(VelocityViewProgram);
		bgfx.destroy_uniform(uVelCur);
		bgfx.destroy_uniform(uVelPrev);
		bgfx.destroy_uniform(uVelParams);
		bgfx.destroy_uniform(uTaaParams);
		bgfx.destroy_uniform(uTaaParams2);
		bgfx.destroy_uniform(sVelocity);
		bgfx.destroy_uniform(sHistory);
		bgfx.destroy_program(SsgiGatherProgram);
		bgfx.destroy_program(SsgiApplyProgram);
		bgfx.destroy_program(AoProgram);
		bgfx.destroy_program(AoApplyProgram);
		bgfx.destroy_program(DofBlurProgram);
		bgfx.destroy_program(DofCombineProgram);
		bgfx.destroy_program(MotionBlurProgram);
		bgfx.destroy_program(LineProgram);
		if (VFogInjectProgram.Valid)
			bgfx.destroy_program(VFogInjectProgram);
		if (VFogIntegrateProgram.Valid)
			bgfx.destroy_program(VFogIntegrateProgram);
		if (VFogApplyProgram.Valid)
			bgfx.destroy_program(VFogApplyProgram);
		if (VFogFallbackProgram.Valid)
			bgfx.destroy_program(VFogFallbackProgram);
		if (MeshVFogProgram.Valid)
			bgfx.destroy_program(MeshVFogProgram);
		if (WaterVFogProgram.Valid)
			bgfx.destroy_program(WaterVFogProgram);
		bgfx.destroy_uniform(uVFogMedium);
		bgfx.destroy_uniform(uVFogLight);
		bgfx.destroy_uniform(uVFogGrid);
		bgfx.destroy_uniform(uVFogSize);
		bgfx.destroy_uniform(sVFog);
		bgfx.destroy_uniform(sVFogCells);
		bgfx.destroy_uniform(sVFogHistory);
		bgfx.destroy_uniform(uVFogTemporal);
		bgfx.destroy_uniform(uVFogPrevViewProj);
		bgfx.destroy_uniform(uVFogDebug);
		bgfx.destroy_uniform(uFogVolumes);
		bgfx.destroy_uniform(uFogVolumeCount);
		VFogReady = false;
		bgfx.destroy_uniform(uCloudShape);
		bgfx.destroy_uniform(uCloudWind);
		bgfx.destroy_uniform(uCloudLight);
		bgfx.destroy_uniform(uCloudView);
		bgfx.destroy_uniform(uCloudTint);
		bgfx.destroy_uniform(uCloudSunDir);
		bgfx.destroy_uniform(uCloudSunColor);
		bgfx.destroy_uniform(uCloudMoonDir);
		bgfx.destroy_uniform(uCloudMoonColor);
		bgfx.destroy_uniform(uCloudAmbient);
		bgfx.destroy_uniform(uCloudSteps);
		bgfx.destroy_uniform(uCloudSize);
		bgfx.destroy_uniform(uCloudPrevViewProj);
		bgfx.destroy_uniform(uCloudWindDelta);
		bgfx.destroy_uniform(uCloudDebug);
		bgfx.destroy_uniform(sCloudHistory);
		bgfx.destroy_uniform(sCloudNoise);
		bgfx.destroy_uniform(sClouds);
		if (CloudsProgram.Valid)
			bgfx.destroy_program(CloudsProgram);
		if (CloudDummy.Valid)
			bgfx.destroy_texture(CloudDummy);
		if (BlueNoise.Valid)
			bgfx.destroy_texture(BlueNoise);
		CloudsReady = false;
		bgfx.destroy_program(DecalProgram);
		bgfx.destroy_program(WaterProgram);
		bgfx.destroy_program(MirrorProgram);
		bgfx.destroy_program(UnderwaterProgram);
		bgfx.destroy_program(CopyProgram);
		bgfx.destroy_uniform(uDecalBox);
		bgfx.destroy_uniform(uDecalInverse);
		bgfx.destroy_uniform(uDecalColor);
		bgfx.destroy_uniform(uDecalAxis);
		bgfx.destroy_uniform(uDecalParams);
		bgfx.destroy_frame_buffer(ShadowFrameBuffer);
		if (LocalShadowFrameBuffer.idx != uint16.MaxValue)
			bgfx.destroy_frame_buffer(LocalShadowFrameBuffer);
		LocalShadowFrameBuffer.idx = uint16.MaxValue;
		LocalShadowMap.idx = uint16.MaxValue;
		bgfx.destroy_uniform(sLocalShadowMap);
		bgfx.destroy_uniform(uShadowViewProj);
		Ready = false;
	}
}

/// Renders a scene from one viewpoint into a texture (editor panels) or the backbuffer (players).
///
