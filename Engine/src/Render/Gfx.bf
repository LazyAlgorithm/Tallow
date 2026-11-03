using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

[CRepr]
struct MeshVertex
{
	public Vector3 position;
	public Vector3 normal;
	public uint32 color; // 0xAABBGGRR
	public Vector2 uv;
	public Vector2 uv2; // Optional second texture coordinates for baked lighting.

	public this(Vector3 position, Vector3 normal, uint32 color, Vector2 uv)
	{
		this.position = position;
		this.normal = normal;
		this.color = color;
		this.uv = uv;
		this.uv2 = default;
	}
}

[CRepr]
struct ScreenVertex
{
	public Vector3 position;
	public Vector2 uv;
}

[CRepr]
struct LineVertex
{
	public Vector3 position;
	public uint32 color;
}

/// Graphics device state shared by the whole engine: bgfx lifetime, vertex layouts and shader loading.
static class Gfx
{
	public const uint64 StateWriteRGB = 0x0000000000000007;
	public const uint64 StateWriteA = 0x0000000000000008;
	public const uint64 StateWriteZ = 0x0000004000000000;
	public const uint64 StateDepthLess = 0x0000000000000010;
	public const uint64 StateDepthLequal = 0x0000000000000020;
	public const uint64 StateDepthGequal = 0x0000000000000040;
	public const uint64 StateCullCw = 0x0000001000000000;
	public const uint64 StateCullCcw = 0x0000002000000000;
	public const uint64 StateLines = 0x0002000000000000;
	public const uint64 StateMsaa = 0x0100000000000000;
	public const uint64 StateBlendAlpha = 0x0000000006565000;
	/// Source plus destination (BGFX_STATE_BLEND_ADD).
	public const uint64 StateBlendAdd = 0x0000000002222000;

	public const uint32 ResetVsync = 0x00000080;
	// Texture and sampler flags (BGFX_TEXTURE_* and BGFX_SAMPLER_*).
	public const uint64 TextureRenderTarget = 0x0000001000000000;
	public const uint64 TextureRenderTargetMsaa4 = 0x0000003000000000;
	public const uint64 TextureWriteOnly = 0x0000008000000000;
	/// Clamped to the edge in U, V and W.
	public const uint64 SamplerClamp = 0x0000002a;
	/// Nearest-pixel sampling, when shrunk and when enlarged.
	public const uint64 SamplerPoint = 0x00000040 | 0x00000100;
	/// A depth comparison sampler (shadow maps).
	public const uint64 SamplerCompareLequal = 0x00020000;
	// What a view clears (BGFX_CLEAR_*).
	public const uint16 ClearColor = 0x0001;
	public const uint16 ClearDepth = 0x0002;

	public static bgfx.VertexLayout MeshLayout;
	public static bgfx.VertexLayout ScreenLayout;
	public static bgfx.VertexLayout LineLayout;
	public static bgfx.TextureHandle WhiteTexture;

	public static bool Initialized;
	public static bool HomogeneousDepth;
	public static bool OriginBottomLeft;
	public static int32 Width;
	public static int32 Height;
	// Vsync, and the most anisotropic filtering the card has (both quality settings: SetVsync, SetAnisotropic).
	public static uint32 ResetFlags = ResetVsync | (uint32)bgfx.ResetFlags.Maxanisotropy;
	/// Folder that contains the engine's own shaders and built-in assets.
	public static String EngineAssetPath = new .() ~ delete _;

	static String sShaderFolder = new .() ~ delete _;

	/// rendererOverride: a bgfx.RendererType value, or -1 to pick the best backend for the platform.
	/// Settings for a phone or tablet: the 3D scene drawn at no more than 540 lines and stretched (the interface
	/// stays sharp), no multisampling, and a smaller shadow map. Call before the first frame.
	public static void UseMobileQuality()
	{
		RenderView.MaxSceneHeight = 540;
		RenderView.Antialias = false;
		RenderResources.ShadowAtlasSize = 2048;
		// The screen effects that need a depth pass; a game can offer them back in its settings.
		ScreenEffects.AmbientOcclusion = false;
		ScreenEffects.DepthOfField = false;
		ScreenEffects.MotionBlur = false;
	}

	public static bool Init(void* window, int32 width, int32 height, int32 rendererOverride = -1)
	{
		if (!Native.tn_gfx_init(window, width, height, rendererOverride, ResetFlags))
		{
			Log.Error("Could not create a graphics device.");
			return false;
		}
		Width = width;
		Height = height;
		let caps = Native.tn_gfx_caps_flags();
		HomogeneousDepth = (caps & 1) != 0;
		OriginBottomLeft = (caps & 2) != 0;

		switch ((bgfx.RendererType)(uint32)Native.tn_gfx_renderer_type())
		{
		case .Vulkan: sShaderFolder.Set("spirv");
		case .OpenGL: sShaderFolder.Set("glsl");
#if BF_PLATFORM_WASM
		// WebGL 2: OpenGL ES 3.0 shaders.
		case .OpenGLES: sShaderFolder.Set("webgl");
#else
		case .OpenGLES: sShaderFolder.Set("essl");
#endif
		case .Metal: sShaderFolder.Set("metal");
		case .Direct3D11,.Direct3D12: sShaderFolder.Set("dx11");
		default: sShaderFolder.Set("spirv");
		}

		bgfx.vertex_layout_begin(&MeshLayout, .Noop);
		bgfx.vertex_layout_add(&MeshLayout, .Position, 3, .Float, false, false);
		bgfx.vertex_layout_add(&MeshLayout, .Normal, 3, .Float, false, false);
		bgfx.vertex_layout_add(&MeshLayout, .Color0, 4, .Uint8, true, false);
		bgfx.vertex_layout_add(&MeshLayout, .TexCoord0, 2, .Float, false, false);
		bgfx.vertex_layout_add(&MeshLayout, .TexCoord1, 2, .Float, false, false);
		bgfx.vertex_layout_end(&MeshLayout);

		bgfx.vertex_layout_begin(&ScreenLayout, .Noop);
		bgfx.vertex_layout_add(&ScreenLayout, .Position, 3, .Float, false, false);
		bgfx.vertex_layout_add(&ScreenLayout, .TexCoord0, 2, .Float, false, false);
		bgfx.vertex_layout_end(&ScreenLayout);

		bgfx.vertex_layout_begin(&LineLayout, .Noop);
		bgfx.vertex_layout_add(&LineLayout, .Position, 3, .Float, false, false);
		bgfx.vertex_layout_add(&LineLayout, .Color0, 4, .Uint8, true, false);
		bgfx.vertex_layout_end(&LineLayout);

		// Transient buffers are allocated by GPU stride and written through these CPU structs.
		// Refuse a mismatched layout before any fullscreen or geometry write can overflow it.
		if (MeshLayout.stride != sizeof(MeshVertex) || ScreenLayout.stride != sizeof(ScreenVertex) || LineLayout.stride != sizeof(LineVertex))
		{
			Log.Error("CPU vertex sizes do not match the GPU vertex layouts");
			return false;
		}

		uint32 white = 0xffffffff;
		WhiteTexture = bgfx.create_texture_2d(1, 1, false, 1, .RGBA8, 0, bgfx.copy(&white, 4), 0);

		Initialized = true;
		Log.Info(scope $"Graphics: {StringView(Native.tn_gfx_renderer_name())} ({width}x{height})");
		return true;
	}

	/// Turns waiting for the screen's refresh on or off (a quality setting).
	public static void SetVsync(bool on)
	{
		let flags = on ? (ResetFlags | ResetVsync) : (ResetFlags & ~ResetVsync);
		if (flags == ResetFlags)
			return;
		ResetFlags = flags;
		if (Initialized)
			Native.tn_gfx_reset(Width, Height, ResetFlags);
	}

	/// Turns anisotropic filtering of textures on or off (a quality setting): sharper slanted floors and walls.
	public static void SetAnisotropic(bool on)
	{
		const uint32 flag = (uint32)bgfx.ResetFlags.Maxanisotropy;
		let flags = on ? (ResetFlags | flag) : (ResetFlags & ~flag);
		if (flags == ResetFlags)
			return;
		ResetFlags = flags;
		if (Initialized)
			Native.tn_gfx_reset(Width, Height, ResetFlags);
	}

	/// Whether the graphics card is built into the processor (Intel's), which suggests a Medium quality.
	public static bool IsIntegratedGpu => Initialized && bgfx.get_caps().vendorId == 0x8086;

	/// Whether this is the web build.
#if BF_PLATFORM_WASM
	public static bool IsWeb => true;
#else
	public static bool IsWeb => false;
#endif

	public static void Resize(int32 width, int32 height)
	{
		if (width <= 0 || height <= 0 || (width == Width && height == Height))
			return;
		Width = width;
		Height = height;
		Native.tn_gfx_reset(width, height, ResetFlags);
	}

	public static void Shutdown()
	{
		if (!Initialized)
			return;
		bgfx.destroy_texture(WhiteTexture);
		Native.tn_gfx_shutdown();
		Initialized = false;
	}

	/// Locates Engine/assets: TALLOW_ROOT, then next to the executable, then up the directory tree.
	public static bool LocateEngineAssets(StringView hint = default)
	{
		List<String> candidates = scope .();
		defer
		{
			for (let c in candidates)
				delete c;
		}
		if (!hint.IsEmpty)
			candidates.Add(new String(hint)..Append("/Engine/assets"));
		let env = scope String();
		if (Environment.GetEnvironmentVariable("TALLOW_ROOT", env) case .Ok && !env.IsEmpty)
			candidates.Add(new String(env)..Append("/Engine/assets"));
		let exeDir = scope String();
		let basePath = SDL.SDL_GetBasePath();
		if (basePath != null)
			exeDir.Append(basePath);
		if (!exeDir.IsEmpty)
		{
			candidates.Add(new String(exeDir)..Append("engine_assets"));
			let dir = scope String(exeDir);
			for (int i < 6)
			{
				candidates.Add(new String(dir)..Append("Engine/assets"));
				dir.Append("../");
			}
		}
		for (let candidate in candidates)
		{
			if (AssetPack.FolderExists(scope String(candidate)..Append("/shaders")))
			{
				EngineAssetPath.Set(candidate);
				return true;
			}
		}
		Log.Error("Engine assets were not found. Set TALLOW_ROOT to the engine folder.");
		return false;
	}

	/// The folder compiled shaders for the running graphics backend live in ("spirv", "glsl", ...).
	public static StringView ShaderFolder => sShaderFolder;

	/// Loads a compiled shader from a file on disk. Returns an invalid handle, quietly, if it is not there.
	public static bgfx.ShaderHandle LoadShaderFile(StringView fullPath)
	{
		bgfx.ShaderHandle handle;
		handle.idx = uint16.MaxValue;
		List<uint8> data = scope .();
		if (AssetPack.ReadAll(fullPath, data) case .Err || data.Count == 0)
			return handle;
		handle = bgfx.create_shader(bgfx.copy(data.Ptr, (uint32)data.Count));
		return handle;
	}

	public static bgfx.ShaderHandle LoadShader(StringView name)
	{
		let path = scope String();
		path.AppendF("{}/shaders/{}/{}.bin", EngineAssetPath, sShaderFolder, name);
		List<uint8> data = scope .();
		if (AssetPack.ReadAll(path, data) case .Err)
		{
			Log.Error(scope $"Missing shader {path}");
			bgfx.ShaderHandle invalid;
			invalid.idx = uint16.MaxValue;
			return invalid;
		}
		let handle = bgfx.create_shader(bgfx.copy(data.Ptr, (uint32)data.Count));
		bgfx.set_shader_name(handle, name.Ptr, (int32)name.Length);
		return handle;
	}

	public static bgfx.ProgramHandle LoadProgram(StringView vertex, StringView fragment)
	{
		return bgfx.create_program(LoadShader(vertex), LoadShader(fragment), true);
	}

	/// Loads an image file into a texture with mip levels (or its compressed `.ktx` copy, in a built game). Returns the
	/// white texture on failure.
	public static bgfx.TextureHandle LoadTexture(StringView path, TextureKind kind = .Color)
	{
		// A headless run (servers, checks) has no graphics card to make textures on.
		if (!Initialized)
			return WhiteTexture;
		let compressed = Textures.LoadCompressed(path);
		if (compressed.Valid)
			return compressed;
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(scope String(path).CStr(), &width, &height);
		if (pixels == null)
		{
			Log.Warning(scope $"Could not load texture {path}");
			return WhiteTexture;
		}
		let handle = Textures.Create(pixels, width, height, kind);
		Native.tn_image_free(pixels);
		return handle;
	}
}
