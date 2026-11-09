// Tallow native shim.
// Owns the pieces that are far simpler to express against the C++ headers than through
// hand-maintained struct bindings: bgfx device creation, the Dear ImGui platform/renderer
// backends, and ImGuizmo. Everything the engine does per-frame goes through Beef.

#include <bgfx/bgfx.h>
#include <bgfx/embedded_shader.h>
#include <bx/math.h>
#include <SDL3/SDL.h>

#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "ImGuizmo.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include "vs_ocornut_imgui.bin.h"
#include "fs_ocornut_imgui.bin.h"
#include "roboto_regular.ttf.h"
#include "robotomono_regular.ttf.h"
#include "icons_font_awesome.ttf.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define TN_API extern "C"

// ------------------------------------------------------------------------------------------
// bgfx device
// ------------------------------------------------------------------------------------------

namespace
{
	typedef void (*TnLogFn)(const char* text);
	TnLogFn s_log = nullptr;
	bool s_traceEnabled = false;

	struct Callback : public bgfx::CallbackI
	{
		~Callback() override {}

		void fatal(const char* filePath, uint16_t line, bgfx::Fatal::Enum code, const char* str) override
		{
			char buffer[2048];
			snprintf(buffer, sizeof(buffer), "bgfx fatal %d at %s:%d: %s", (int)code, filePath, (int)line, str);
			if (s_log != nullptr) s_log(buffer);
			fprintf(stderr, "%s\n", buffer);
			abort();
		}

		void traceVargs(const char* filePath, uint16_t line, const char* format, va_list argList) override
		{
			if (!s_traceEnabled) return;
			char buffer[4096];
			vsnprintf(buffer, sizeof(buffer), format, argList);
			fputs(buffer, stderr);
		}

		void profilerBegin(const char*, uint32_t, const char*, uint16_t) override {}
		void profilerBeginLiteral(const char*, uint32_t, const char*, uint16_t) override {}
		void profilerEnd() override {}
		uint32_t cacheReadSize(uint64_t) override { return 0; }
		bool cacheRead(uint64_t, void*, uint32_t) override { return false; }
		void cacheWrite(uint64_t, const void*, uint32_t) override {}

		void screenShot(const char* filePath, uint32_t width, uint32_t height, uint32_t pitch, bgfx::TextureFormat::Enum format, const void* data, uint32_t, bool yflip) override
		{
			std::vector<uint8_t> rgba(size_t(width) * height * 4);
			const bool bgra = format == bgfx::TextureFormat::BGRA8;
			for (uint32_t y = 0; y < height; y++)
			{
				const uint8_t* src = (const uint8_t*)data + size_t(yflip ? height - 1 - y : y) * pitch;
				uint8_t* dst = rgba.data() + size_t(y) * width * 4;
				for (uint32_t x = 0; x < width; x++)
				{
					dst[x * 4 + 0] = src[x * 4 + (bgra ? 2 : 0)];
					dst[x * 4 + 1] = src[x * 4 + 1];
					dst[x * 4 + 2] = src[x * 4 + (bgra ? 0 : 2)];
					dst[x * 4 + 3] = 255;
				}
			}
			stbi_write_png(filePath, (int)width, (int)height, 4, rgba.data(), (int)width * 4);
		}

		void captureBegin(uint32_t, uint32_t, uint32_t, bgfx::TextureFormat::Enum, bool) override {}
		void captureEnd() override {}
		void captureFrame(const void*, uint32_t) override {}
	};

	Callback s_callback;

	void FillSwapChain(bgfx::SwapChain& swapChain, bgfx::PlatformData& platform, SDL_Window* window, int width, int height)
	{
		swapChain.width = (uint32_t)width;
		swapChain.height = (uint32_t)height;
		if (window == nullptr) return;
		SDL_PropertiesID props = SDL_GetWindowProperties(window);
#if defined(SDL_PLATFORM_WIN32)
		swapChain.nwh = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, nullptr);
#elif defined(SDL_PLATFORM_MACOS)
		swapChain.nwh = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
#elif defined(SDL_PLATFORM_IOS)
		swapChain.nwh = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
#elif defined(SDL_PLATFORM_ANDROID)
		swapChain.nwh = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER, nullptr);
#elif defined(SDL_PLATFORM_EMSCRIPTEN)
		// bgfx's WebGL backend takes the CSS selector of the canvas SDL draws into.
		(void)props;
		swapChain.nwh = (void*)"#canvas";
#elif defined(SDL_PLATFORM_LINUX)
		const char* driver = SDL_GetCurrentVideoDriver();
		if (driver != nullptr && SDL_strcmp(driver, "wayland") == 0)
		{
			platform.type = bgfx::NativeWindowHandleType::Wayland;
			swapChain.ndt = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nullptr);
			swapChain.nwh = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, nullptr);
		}
		else
		{
			swapChain.ndt = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, nullptr);
			swapChain.nwh = (void*)(uintptr_t)SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
		}
#endif
	}

	SDL_Window* s_window = nullptr;
}

TN_API void tn_set_log(TnLogFn fn, bool trace)
{
	s_log = fn;
	s_traceEnabled = trace;
}

// renderer: bgfx::RendererType value, or negative to let bgfx pick the best one for the platform.
// window may be null for a headless device (dedicated servers do not call this at all).
TN_API bool tn_gfx_init(SDL_Window* window, int width, int height, int renderer, uint32_t resetFlags)
{
	// Set TALLOW_GFX_TRACE=1 to print bgfx's own diagnostics while debugging a backend.
	if (getenv("TALLOW_GFX_TRACE") != nullptr) s_traceEnabled = true;

#if defined(SDL_PLATFORM_LINUX)
	// bgfx's OpenGL backends call eglGetDisplay with our X11 display. On a Wayland desktop some
	// EGL drivers guess "Wayland" from the environment and crash, so state the platform explicitly.
	const char* videoDriver = SDL_GetCurrentVideoDriver();
	if (videoDriver != nullptr)
		setenv("EGL_PLATFORM", SDL_strcmp(videoDriver, "wayland") == 0 ? "wayland" : "x11", 1);
	// Auto backend selection may fall all the way back to bgfx's non-rendering Noop backend.
	// Tallow ships Vulkan shaders on Linux and requires a real renderer for its editor.
	// --renderer opengl remains available for machines with a working OpenGL driver.
	if (renderer < 0) renderer = (int)bgfx::RendererType::Vulkan;
#endif

#if defined(SDL_PLATFORM_WINDOWS)
	// bgfx would pick Direct3D here, and the engine ships no Direct3D shaders yet (see docs/windows.md).
	if (renderer < 0) renderer = (int)bgfx::RendererType::Vulkan;
#endif

	// Single-threaded mode: the thread calling init/frame is the render thread.
	bgfx::renderFrame();

	bgfx::Init init;
	init.type = renderer < 0 ? bgfx::RendererType::Count : (bgfx::RendererType::Enum)renderer;
	init.reset = resetFlags;
	init.callback = &s_callback;
	FillSwapChain(init.swapChain, init.platformData, window, width, height);
	s_window = window;
	if (!bgfx::init(init))
	{
		fprintf(stderr, "Tallow graphics: bgfx failed to initialize the requested rendering backend. "
			"Try --renderer opengl or set TALLOW_GFX_TRACE=1 for diagnostics.\\n");
		s_window = nullptr;
		return false;
	}
	// bgfx::init can succeed with a Noop device after other backends are unavailable.
	// Noop silently accepts draw calls but cannot display the launcher/editor.
	if (bgfx::getRendererType() == bgfx::RendererType::Noop)
	{
		fprintf(stderr, "Tallow graphics: bgfx selected Noop instead of a real graphics backend. "
			"The editor cannot render. Check Vulkan drivers, or try --renderer opengl "
			"(TALLOW_GFX_TRACE=1 for diagnostics).\\n");
		bgfx::shutdown();
		s_window = nullptr;
		return false;
	}
	return true;
}

TN_API void tn_gfx_reset(int width, int height, uint32_t resetFlags)
{
	bgfx::SwapChain swapChain;
	bgfx::PlatformData platform;
	FillSwapChain(swapChain, platform, s_window, width, height);
	bgfx::reset(resetFlags, &swapChain);
}

TN_API void tn_gfx_shutdown()
{
	bgfx::shutdown();
}

TN_API const char* tn_gfx_renderer_name()
{
	return bgfx::getRendererName(bgfx::getRendererType());
}

TN_API int tn_gfx_renderer_type()
{
	return (int)bgfx::getRendererType();
}

// bit 0: clip space depth is -1..1 (OpenGL), bit 1: render target origin is bottom left
TN_API int tn_gfx_caps_flags()
{
	const bgfx::Caps* caps = bgfx::getCaps();
	return (caps->homogeneousDepth ? 1 : 0) | (caps->originBottomLeft ? 2 : 0);
}

TN_API void tn_gfx_screenshot(const char* path)
{
	bgfx::requestScreenShot(BGFX_INVALID_HANDLE, path);
}

// Saves RGBA pixels (4 bytes a pixel, rows top to bottom) as a PNG file. True when it was written.
TN_API bool tn_image_write_png(const char* path, const uint8_t* pixels, int width, int height)
{
	return stbi_write_png(path, width, height, 4, pixels, width * 4) != 0;
}

// The same as PNG bytes in memory (for putting pictures inside a .glb). Free them with tn_image_free_png.
TN_API uint8_t* tn_image_encode_png(const uint8_t* pixels, int width, int height, int* size)
{
	*size = 0;
	return stbi_write_png_to_mem(pixels, width * 4, width, height, 4, size);
}

TN_API void tn_image_free_png(uint8_t* bytes) { STBIW_FREE(bytes); }

// ------------------------------------------------------------------------------------------
// Dear ImGui backend
// ------------------------------------------------------------------------------------------

namespace
{
	const bgfx::EmbeddedShader s_embeddedShaders[] =
	{
		BGFX_EMBEDDED_SHADER(vs_ocornut_imgui),
		BGFX_EMBEDDED_SHADER(fs_ocornut_imgui),
		BGFX_EMBEDDED_SHADER_END()
	};

	bgfx::VertexLayout s_imguiLayout;
	bgfx::ProgramHandle s_imguiProgram = BGFX_INVALID_HANDLE;
	bgfx::UniformHandle s_texUniform = BGFX_INVALID_HANDLE;
	ImFont* s_monoFont = nullptr;

	// ImGui 1.92 texture protocol: the atlas grows on demand and asks the backend to
	// create, partially update, or destroy its textures.
	void UpdateTexture(ImTextureData* texture)
	{
		if (texture->Status == ImTextureStatus_WantCreate)
		{
			bgfx::TextureHandle handle = bgfx::createTexture2D((uint16_t)texture->Width, (uint16_t)texture->Height, false, 1, bgfx::TextureFormat::RGBA8, 0);
			bgfx::updateTexture2D(handle, 0, 0, 0, 0, (uint16_t)texture->Width, (uint16_t)texture->Height, bgfx::copy(texture->GetPixels(), (uint32_t)texture->GetSizeInBytes()));
			texture->SetTexID(ImTextureID(handle.idx) + 1);
			texture->SetStatus(ImTextureStatus_OK);
		}
		else if (texture->Status == ImTextureStatus_WantUpdates)
		{
			bgfx::TextureHandle handle = { uint16_t((texture->TexID & 0xffff) - 1) };
			const ImTextureRect rect = texture->UpdateRect;
			const bgfx::Memory* memory = bgfx::alloc(uint32_t(rect.w) * rect.h * 4);
			for (int row = 0; row < rect.h; row++)
			{
				bx::memCopy(memory->data + size_t(row) * rect.w * 4, texture->GetPixelsAt(rect.x, rect.y + row), size_t(rect.w) * 4);
			}
			bgfx::updateTexture2D(handle, 0, 0, rect.x, rect.y, rect.w, rect.h, memory);
			texture->SetStatus(ImTextureStatus_OK);
		}
		else if (texture->Status == ImTextureStatus_WantDestroy && texture->UnusedFrames > 0)
		{
			bgfx::TextureHandle handle = { uint16_t((texture->TexID & 0xffff) - 1) };
			bgfx::destroy(handle);
			texture->SetTexID(ImTextureID_Invalid);
			texture->SetStatus(ImTextureStatus_Destroyed);
		}
	}

	// Texture ids handed to ImGui are (bgfx handle index + 1); bit 32 marks an opaque image
	// (render targets, whose alpha channel is not meaningful).
	const ImTextureID kOpaqueBit = ImTextureID(1) << 32;

	void ApplyTallowStyle()
	{
		ImGui::StyleColorsDark();
		ImGuiStyle& style = ImGui::GetStyle();
		style.WindowRounding = 0.0f;
		style.ChildRounding = 0.0f;
		style.FrameRounding = 3.0f;
		style.GrabRounding = 3.0f;
		style.PopupRounding = 3.0f;
		style.ScrollbarRounding = 3.0f;
		style.TabRounding = 3.0f;
		style.WindowBorderSize = 1.0f;
		style.FrameBorderSize = 1.0f;
		style.WindowPadding = ImVec2(6.0f, 6.0f);
		style.FramePadding = ImVec2(6.0f, 3.0f);
		style.ItemSpacing = ImVec2(6.0f, 4.0f);
		style.IndentSpacing = 14.0f;
		style.ScrollbarSize = 12.0f;
		style.WindowMenuButtonPosition = ImGuiDir_None;

		// Neutral charcoal greys with a blue selection accent.
		ImVec4* c = style.Colors;
		const ImVec4 window(0.220f, 0.220f, 0.220f, 1.0f);
		const ImVec4 panelDark(0.165f, 0.165f, 0.165f, 1.0f);
		const ImVec4 header(0.243f, 0.243f, 0.243f, 1.0f);
		const ImVec4 field(0.165f, 0.165f, 0.165f, 1.0f);
		const ImVec4 border(0.098f, 0.098f, 0.098f, 1.0f);
		const ImVec4 hover(0.310f, 0.310f, 0.310f, 1.0f);
		const ImVec4 active(0.380f, 0.380f, 0.380f, 1.0f);
		const ImVec4 accent(0.173f, 0.365f, 0.529f, 1.0f);
		const ImVec4 accentHover(0.227f, 0.447f, 0.690f, 1.0f);
		c[ImGuiCol_Text] = ImVec4(0.824f, 0.824f, 0.824f, 1.0f);
		c[ImGuiCol_TextDisabled] = ImVec4(0.520f, 0.520f, 0.520f, 1.0f);
		c[ImGuiCol_WindowBg] = window;
		c[ImGuiCol_ChildBg] = ImVec4(0, 0, 0, 0);
		c[ImGuiCol_PopupBg] = ImVec4(0.190f, 0.190f, 0.190f, 0.98f);
		c[ImGuiCol_Border] = border;
		c[ImGuiCol_BorderShadow] = ImVec4(0, 0, 0, 0);
		c[ImGuiCol_FrameBg] = field;
		c[ImGuiCol_FrameBgHovered] = ImVec4(0.200f, 0.200f, 0.200f, 1.0f);
		c[ImGuiCol_FrameBgActive] = ImVec4(0.130f, 0.130f, 0.130f, 1.0f);
		c[ImGuiCol_TitleBg] = panelDark;
		c[ImGuiCol_TitleBgActive] = panelDark;
		c[ImGuiCol_TitleBgCollapsed] = panelDark;
		c[ImGuiCol_MenuBarBg] = ImVec4(0.118f, 0.118f, 0.118f, 1.0f);
		c[ImGuiCol_ScrollbarBg] = ImVec4(0.200f, 0.200f, 0.200f, 1.0f);
		c[ImGuiCol_ScrollbarGrab] = ImVec4(0.370f, 0.370f, 0.370f, 1.0f);
		c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(0.450f, 0.450f, 0.450f, 1.0f);
		c[ImGuiCol_ScrollbarGrabActive] = ImVec4(0.520f, 0.520f, 0.520f, 1.0f);
		c[ImGuiCol_CheckMark] = ImVec4(0.850f, 0.850f, 0.850f, 1.0f);
		c[ImGuiCol_SliderGrab] = ImVec4(0.600f, 0.600f, 0.600f, 1.0f);
		c[ImGuiCol_SliderGrabActive] = accentHover;
		c[ImGuiCol_Button] = ImVec4(0.345f, 0.345f, 0.345f, 1.0f);
		c[ImGuiCol_ButtonHovered] = ImVec4(0.404f, 0.404f, 0.404f, 1.0f);
		c[ImGuiCol_ButtonActive] = accent;
		c[ImGuiCol_Header] = header;
		c[ImGuiCol_HeaderHovered] = hover;
		c[ImGuiCol_HeaderActive] = accent;
		c[ImGuiCol_Separator] = border;
		c[ImGuiCol_SeparatorHovered] = accentHover;
		c[ImGuiCol_SeparatorActive] = accentHover;
		c[ImGuiCol_ResizeGrip] = ImVec4(0, 0, 0, 0);
		c[ImGuiCol_ResizeGripHovered] = hover;
		c[ImGuiCol_ResizeGripActive] = active;
		c[ImGuiCol_Tab] = panelDark;
		c[ImGuiCol_TabHovered] = hover;
		c[ImGuiCol_TabSelected] = window;
		c[ImGuiCol_TabSelectedOverline] = accentHover;
		c[ImGuiCol_TabDimmed] = panelDark;
		c[ImGuiCol_TabDimmedSelected] = window;
		c[ImGuiCol_TabDimmedSelectedOverline] = ImVec4(0, 0, 0, 0);
		c[ImGuiCol_DockingPreview] = ImVec4(accentHover.x, accentHover.y, accentHover.z, 0.55f);
		c[ImGuiCol_DockingEmptyBg] = ImVec4(0.118f, 0.118f, 0.118f, 1.0f);
		c[ImGuiCol_TableHeaderBg] = header;
		c[ImGuiCol_TableBorderStrong] = border;
		c[ImGuiCol_TableBorderLight] = ImVec4(0.160f, 0.160f, 0.160f, 1.0f);
		c[ImGuiCol_TextSelectedBg] = ImVec4(accent.x, accent.y, accent.z, 0.85f);
		c[ImGuiCol_DragDropTarget] = accentHover;
		c[ImGuiCol_NavCursor] = accentHover;
		c[ImGuiCol_ModalWindowDimBg] = ImVec4(0, 0, 0, 0.45f);
	}
}

TN_API bool tn_imgui_init(SDL_Window* window, const char* iniPath, float uiScale)
{
	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	ImGuiIO& io = ImGui::GetIO();
	io.ConfigFlags |= ImGuiConfigFlags_DockingEnable | ImGuiConfigFlags_NavEnableKeyboard;
	io.ConfigWindowsMoveFromTitleBarOnly = true;
	io.ConfigDockingWithShift = false;
	// A click on a number field that does not drag it turns it into a text box, so that values can be typed as well as
	// dragged. (Double-click and Ctrl+click do the same.)
	io.ConfigDragClickToInputText = true;
	io.IniFilename = iniPath; // caller keeps the string alive
	io.BackendRendererName = "tallow_bgfx";
	io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset | ImGuiBackendFlags_RendererHasTextures;

	ApplyTallowStyle();
	if (uiScale > 0.0f && uiScale != 1.0f) ImGui::GetStyle().ScaleAllSizes(uiScale);
	const float scale = uiScale > 0.0f ? uiScale : 1.0f;

	ImFontConfig config;
	config.FontDataOwnedByAtlas = false;
	io.Fonts->AddFontFromMemoryTTF((void*)s_robotoRegularTtf, sizeof(s_robotoRegularTtf), 15.0f * scale, &config);
	// Font Awesome glyphs are merged into the UI font, so icons are just characters in a label.
	static const ImWchar iconRange[] = { 0xf000, 0xf2e0, 0 };
	ImFontConfig iconConfig;
	iconConfig.FontDataOwnedByAtlas = false;
	iconConfig.MergeMode = true;
	iconConfig.GlyphMinAdvanceX = 16.0f * scale;
	io.Fonts->AddFontFromMemoryTTF((void*)s_iconsFontAwesomeTtf, sizeof(s_iconsFontAwesomeTtf), 14.0f * scale, &iconConfig, iconRange);
	s_monoFont = io.Fonts->AddFontFromMemoryTTF((void*)s_robotoMonoRegularTtf, sizeof(s_robotoMonoRegularTtf), 14.0f * scale, &config);

	if (!ImGui_ImplSDL3_InitForOther(window)) return false;

	s_imguiLayout.begin()
		.add(bgfx::Attrib::Position, 2, bgfx::AttribType::Float)
		.add(bgfx::Attrib::TexCoord0, 2, bgfx::AttribType::Float)
		.add(bgfx::Attrib::Color0, 4, bgfx::AttribType::Uint8, true)
		.end();

	bgfx::RendererType::Enum type = bgfx::getRendererType();
	s_imguiProgram = bgfx::createProgram(
		bgfx::createEmbeddedShader(s_embeddedShaders, type, "vs_ocornut_imgui"),
		bgfx::createEmbeddedShader(s_embeddedShaders, type, "fs_ocornut_imgui"),
		true);
	s_texUniform = bgfx::createUniform("s_tex", bgfx::UniformType::Sampler);

	return bgfx::isValid(s_imguiProgram);
}

// The interface's colours, for editor themes: how many there are, each one's name, reading and setting them, and
// ImGui's own dark or light colours to start from.
TN_API int tn_imgui_color_count()
{
	return ImGuiCol_COUNT;
}

TN_API const char* tn_imgui_color_name(int index)
{
	return index >= 0 && index < ImGuiCol_COUNT ? ImGui::GetStyleColorName(index) : "";
}

TN_API void tn_imgui_get_color(int index, float* rgba)
{
	if (index < 0 || index >= ImGuiCol_COUNT) return;
	const ImVec4& c = ImGui::GetStyle().Colors[index];
	rgba[0] = c.x; rgba[1] = c.y; rgba[2] = c.z; rgba[3] = c.w;
}

TN_API void tn_imgui_set_color(int index, const float* rgba)
{
	if (index < 0 || index >= ImGuiCol_COUNT) return;
	ImGui::GetStyle().Colors[index] = ImVec4(rgba[0], rgba[1], rgba[2], rgba[3]);
}

TN_API void tn_imgui_base_colors(bool light)
{
	if (light)
		ImGui::StyleColorsLight();
	else
		ImGui::StyleColorsDark();
}

TN_API void tn_imgui_shutdown()
{
	for (ImTextureData* texture : ImGui::GetPlatformIO().Textures)
	{
		if (texture->TexID != ImTextureID_Invalid)
		{
			bgfx::TextureHandle handle = { uint16_t((texture->TexID & 0xffff) - 1) };
			bgfx::destroy(handle);
			texture->SetTexID(ImTextureID_Invalid);
			texture->SetStatus(ImTextureStatus_Destroyed);
		}
	}
	ImGui_ImplSDL3_Shutdown();
	ImGui::DestroyContext();
	if (bgfx::isValid(s_imguiProgram)) bgfx::destroy(s_imguiProgram);
	if (bgfx::isValid(s_texUniform)) bgfx::destroy(s_texUniform);
}

TN_API bool tn_imgui_event(const SDL_Event* event)
{
	return ImGui_ImplSDL3_ProcessEvent(event);
}

TN_API void tn_imgui_new_frame()
{
	ImGui_ImplSDL3_NewFrame();
	ImGui::NewFrame();
	ImGuizmo::BeginFrame();
}

TN_API void tn_imgui_push_mono_font()
{
	ImGui::PushFont(s_monoFont, 0.0f);
}

// A font from a TTF/OTF file's bytes (copied), for UI documents' font-family. Null without an ImGui context.
TN_API void* tn_imgui_add_font(const void* data, int size)
{
	if (ImGui::GetCurrentContext() == nullptr || data == nullptr || size <= 0) return nullptr;
	void* copy = IM_ALLOC((size_t)size);
	memcpy(copy, data, (size_t)size);
	ImFontConfig config;
	config.FontDataOwnedByAtlas = true;
	return ImGui::GetIO().Fonts->AddFontFromMemoryTTF(copy, size, 16.0f, &config);
}

TN_API void tn_imgui_push_font(void* font, float size)
{
	ImGui::PushFont((ImFont*)font, size);
}

// A slider that a double-click turns into a text box. Dear ImGui only does that for Ctrl+click (a plain click sets the
// slider), so a double-click is passed on as one.
TN_API bool tn_imgui_slider_float(const char* label, float* value, float min, float max, const char* format)
{
	ImGuiIO& io = ImGui::GetIO();
	const bool ctrl = io.KeyCtrl;
	const ImGuiKeyChord mods = io.KeyMods;
	if (ImGui::IsMouseDoubleClicked(0))
	{
		io.KeyCtrl = true;
		io.KeyMods |= ImGuiMod_Ctrl;
	}
	const bool changed = ImGui::SliderFloat(label, value, min, max, format, ImGuiSliderFlags_AlwaysClamp);
	io.KeyCtrl = ctrl;
	io.KeyMods = mods;
	return changed;
}

// bit 0: ImGui wants the mouse, bit 1: ImGui wants the keyboard, bit 2: a text field is active
TN_API int tn_imgui_capture_flags()
{
	ImGuiIO& io = ImGui::GetIO();
	return (io.WantCaptureMouse ? 1 : 0) | (io.WantCaptureKeyboard ? 2 : 0) | (io.WantTextInput ? 4 : 0);
}

TN_API void tn_imgui_render(uint16_t viewId)
{
	ImGui::Render();
	ImDrawData* drawData = ImGui::GetDrawData();
	const int fbWidth = int(drawData->DisplaySize.x * drawData->FramebufferScale.x);
	const int fbHeight = int(drawData->DisplaySize.y * drawData->FramebufferScale.y);
	if (drawData->Textures != nullptr)
	{
		for (ImTextureData* texture : *drawData->Textures)
		{
			if (texture->Status != ImTextureStatus_OK) UpdateTexture(texture);
		}
	}
	if (fbWidth <= 0 || fbHeight <= 0) return;

	bgfx::setViewName(viewId, "ImGui");
	bgfx::setViewMode(viewId, bgfx::ViewMode::Sequential);
	bgfx::setViewFrameBuffer(viewId, BGFX_INVALID_HANDLE);
	bgfx::setViewClear(viewId, BGFX_CLEAR_NONE);

	const bgfx::Caps* caps = bgfx::getCaps();
	float ortho[16];
	const float x = drawData->DisplayPos.x;
	const float y = drawData->DisplayPos.y;
	bx::mtxOrtho(ortho, x, x + drawData->DisplaySize.x, y + drawData->DisplaySize.y, y, 0.0f, 1000.0f, 0.0f, caps->homogeneousDepth);
	bgfx::setViewTransform(viewId, nullptr, ortho);
	bgfx::setViewRect(viewId, 0, 0, (uint16_t)fbWidth, (uint16_t)fbHeight);

	const ImVec2 clipPos = drawData->DisplayPos;
	const ImVec2 clipScale = drawData->FramebufferScale;

	for (int listIndex = 0; listIndex < drawData->CmdLists.Size; listIndex++)
	{
		const ImDrawList* drawList = drawData->CmdLists[listIndex];
		const uint32_t numVertices = (uint32_t)drawList->VtxBuffer.size();
		const uint32_t numIndices = (uint32_t)drawList->IdxBuffer.size();
		if (numVertices == 0 || numIndices == 0) continue;
		if (bgfx::getAvailTransientVertexBuffer(numVertices, s_imguiLayout) < numVertices
			|| bgfx::getAvailTransientIndexBuffer(numIndices, sizeof(ImDrawIdx) == 4) < numIndices)
		{
			break;
		}

		bgfx::TransientVertexBuffer tvb;
		bgfx::TransientIndexBuffer tib;
		bgfx::allocTransientVertexBuffer(&tvb, numVertices, s_imguiLayout);
		bgfx::allocTransientIndexBuffer(&tib, numIndices, sizeof(ImDrawIdx) == 4);
		bx::memCopy(tvb.data, drawList->VtxBuffer.begin(), numVertices * sizeof(ImDrawVert));
		bx::memCopy(tib.data, drawList->IdxBuffer.begin(), numIndices * sizeof(ImDrawIdx));

		for (const ImDrawCmd& cmd : drawList->CmdBuffer)
		{
			if (cmd.UserCallback != nullptr)
			{
				if (cmd.UserCallback != ImGui::GetPlatformIO().DrawCallback_ResetRenderState) cmd.UserCallback(drawList, &cmd);
				continue;
			}
			if (cmd.ElemCount == 0) continue;

			const float clipX0 = bx::max((cmd.ClipRect.x - clipPos.x) * clipScale.x, 0.0f);
			const float clipY0 = bx::max((cmd.ClipRect.y - clipPos.y) * clipScale.y, 0.0f);
			const float clipX1 = bx::min((cmd.ClipRect.z - clipPos.x) * clipScale.x, (float)fbWidth);
			const float clipY1 = bx::min((cmd.ClipRect.w - clipPos.y) * clipScale.y, (float)fbHeight);
			if (clipX1 <= clipX0 || clipY1 <= clipY0) continue;

			const ImTextureID id = cmd.GetTexID();
			bgfx::TextureHandle texture = { uint16_t((id & 0xffff) - 1) };
			uint64_t state = BGFX_STATE_WRITE_RGB | BGFX_STATE_WRITE_A | BGFX_STATE_MSAA;
			if ((id & kOpaqueBit) == 0)
			{
				state |= BGFX_STATE_BLEND_FUNC(BGFX_STATE_BLEND_SRC_ALPHA, BGFX_STATE_BLEND_INV_SRC_ALPHA);
			}

			bgfx::setScissor((uint16_t)clipX0, (uint16_t)clipY0, (uint16_t)(clipX1 - clipX0), (uint16_t)(clipY1 - clipY0));
			bgfx::setState(state);
			bgfx::setTexture(0, s_texUniform, texture);
			bgfx::setVertexBuffer(0, &tvb, cmd.VtxOffset, numVertices - cmd.VtxOffset);
			bgfx::setIndexBuffer(&tib, cmd.IdxOffset, cmd.ElemCount);
			bgfx::submit(viewId, s_imguiProgram);
		}
	}
}

// ------------------------------------------------------------------------------------------
// ImGuizmo
// ------------------------------------------------------------------------------------------

// Call inside the ImGui window that shows the scene; the rect is in screen coordinates.
TN_API void tn_gizmo_begin(float x, float y, float width, float height, bool orthographic)
{
	ImGuizmo::SetOrthographic(orthographic);
	ImGuizmo::SetDrawlist();
	ImGuizmo::SetRect(x, y, width, height);
}

// operation: 0 translate, 1 rotate, 2 scale, 3 universal. local: true for object space.
// snap may be null, otherwise three floats. Returns true while the matrix is being changed.
TN_API bool tn_gizmo_manipulate(const float* view, const float* projection, int operation, bool local, float* matrix, const float* snap)
{
	ImGuizmo::OPERATION op = ImGuizmo::TRANSLATE;
	if (operation == 1) op = ImGuizmo::ROTATE;
	else if (operation == 2) op = ImGuizmo::SCALE;
	else if (operation == 3) op = ImGuizmo::UNIVERSAL;
	return ImGuizmo::Manipulate(view, projection, op, local ? ImGuizmo::LOCAL : ImGuizmo::WORLD, matrix, nullptr, snap);
}

TN_API bool tn_gizmo_is_using() { return ImGuizmo::IsUsing(); }
TN_API bool tn_gizmo_is_over() { return ImGuizmo::IsOver(); }
