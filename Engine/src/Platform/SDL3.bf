using System;

namespace Tallow;

/// Minimal SDL3 bindings: just what the engine uses for windows, events, input and timing.
static class SDL
{
	public const uint32 INIT_VIDEO = 0x00000020;
	public const uint32 INIT_GAMEPAD = 0x00002000;
	public const uint32 INIT_EVENTS = 0x00004000;

	public const uint64 WINDOW_FULLSCREEN = 0x0000000000000001;
	public const uint64 WINDOW_HIDDEN = 0x0000000000000008;
	public const uint64 WINDOW_RESIZABLE = 0x0000000000000020;
	public const uint64 WINDOW_MAXIMIZED = 0x0000000000000080;
	public const uint64 WINDOW_HIGH_PIXEL_DENSITY = 0x0000000000002000;

	public const uint32 EVENT_QUIT = 0x100;
	public const uint32 EVENT_WINDOW_RESIZED = 0x206;
	public const uint32 EVENT_WINDOW_PIXEL_SIZE_CHANGED = 0x207;
	public const uint32 EVENT_WINDOW_CLOSE_REQUESTED = 0x210;
	public const uint32 EVENT_KEY_DOWN = 0x300;
	public const uint32 EVENT_KEY_UP = 0x301;
	public const uint32 EVENT_MOUSE_MOTION = 0x400;
	public const uint32 EVENT_MOUSE_BUTTON_DOWN = 0x401;
	public const uint32 EVENT_MOUSE_BUTTON_UP = 0x402;
	public const uint32 EVENT_MOUSE_WHEEL = 0x403;
	public const uint32 EVENT_GAMEPAD_ADDED = 0x653;
	public const uint32 EVENT_GAMEPAD_REMOVED = 0x654;
	public const uint32 EVENT_FINGER_DOWN = 0x700;
	public const uint32 EVENT_FINGER_UP = 0x701;
	public const uint32 EVENT_FINGER_MOTION = 0x702;
	public const uint32 EVENT_FINGER_CANCELED = 0x703;

	/// SDL_Event is a 128 byte union; fields are read by offset through the helpers below.
	[CRepr]
	public struct Event
	{
		public uint32 type;
		public uint8[124] data;

		public int32 ReadInt32(int offset) mut => *(int32*)((uint8*)&this + offset);
		public float ReadFloat(int offset) mut => *(float*)((uint8*)&this + offset);

		/// Window events: new width/height. Offsets follow SDL_WindowEvent.
		public int32 WindowData1 mut => ReadInt32(20);
		public int32 WindowData2 mut => ReadInt32(24);
		/// Keyboard events: SDL_KeyboardEvent.scancode.
		public int32 Scancode mut => ReadInt32(24);
		public bool KeyRepeat mut => *((uint8*)&this + 37) != 0;
		/// Mouse wheel events: SDL_MouseWheelEvent.y.
		public float WheelY mut => ReadFloat(28);
	}

	[CLink] public static extern bool SDL_Init(uint32 flags);
	[CLink] public static extern void SDL_Quit();
	[CLink] public static extern char8* SDL_GetError();
	[CLink] public static extern bool SDL_SetHint(char8* name, char8* value);
	[CLink] public static extern void* SDL_CreateWindow(char8* title, int32 w, int32 h, uint64 flags);
	[CLink] public static extern void SDL_DestroyWindow(void* window);
	[CLink] public static extern bool SDL_SetWindowTitle(void* window, char8* title);
	/// Four bytes per pixel in memory order red, green, blue, alpha (SDL_PIXELFORMAT_ABGR8888 on little-endian machines).
	public const uint32 PIXELFORMAT_RGBA32 = 0x16762004;
	[CLink] public static extern void* SDL_CreateSurfaceFrom(int32 width, int32 height, uint32 format, void* pixels, int32 pitch);
	[CLink] public static extern void SDL_DestroySurface(void* surface);
	[CLink] public static extern bool SDL_SetWindowIcon(void* window, void* icon);
	[CLink] public static extern bool SDL_GetWindowSizeInPixels(void* window, int32* w, int32* h);
	[CLink] public static extern bool SDL_GetWindowSize(void* window, int32* w, int32* h);
	[CLink] public static extern bool SDL_MaximizeWindow(void* window);
	/// Borderless at the desktop's resolution, or back to a window.
	[CLink] public static extern bool SDL_SetWindowFullscreen(void* window, bool fullscreen);
	[CLink] public static extern bool SDL_ShowWindow(void* window);
	[CLink] public static extern bool SDL_PollEvent(Event* event);
	[CLink] public static extern bool* SDL_GetKeyboardState(int32* numKeys);
	[CLink] public static extern uint32 SDL_GetMouseState(float* x, float* y);
	[CLink] public static extern uint32 SDL_GetRelativeMouseState(float* x, float* y);
	[CLink] public static extern bool SDL_SetWindowRelativeMouseMode(void* window, bool enabled);
	[CLink] public static extern bool SDL_SetWindowMouseGrab(void* window, bool grabbed);
	[CLink] public static extern uint64 SDL_GetTicksNS();
	[CLink] public static extern void SDL_DelayNS(uint64 ns);
	[CLink] public static extern char8* SDL_GetBasePath();
	[CLink] public static extern char8* SDL_GetPrefPath(char8* org, char8* app);
	[CLink] public static extern char8* SDL_GetCurrentVideoDriver();
	[CLink] public static extern bool SDL_SetClipboardText(char8* text);
	[CLink] public static extern bool SDL_StartTextInput(void* window);
	// Game controllers.
	[CLink] public static extern uint32* SDL_GetGamepads(int32* count);
	[CLink] public static extern void* SDL_OpenGamepad(uint32 id);
	[CLink] public static extern void SDL_CloseGamepad(void* gamepad);
	[CLink] public static extern bool SDL_GamepadConnected(void* gamepad);
	[CLink] public static extern char8* SDL_GetGamepadName(void* gamepad);
	/// 2-3 Xbox, 4-6 PlayStation, 7-10 Nintendo; anything else is a generic pad.
	[CLink] public static extern int32 SDL_GetGamepadType(void* gamepad);
	[CLink] public static extern bool SDL_GetGamepadButton(void* gamepad, int32 button);
	[CLink] public static extern int16 SDL_GetGamepadAxis(void* gamepad, int32 axis);
	[CLink] public static extern bool SDL_RumbleGamepad(void* gamepad, uint16 low, uint16 high, uint32 milliseconds);
	[CLink] public static extern void SDL_free(void* memory);
	/// Asks the desktop for a folder. The answer arrives later through the callback, possibly on another thread:
	/// files is null on an error, and its first entry is null when the person cancelled.
	[CLink] public static extern void SDL_ShowOpenFolderDialog(function void(void* userData, char8** files, int32 filter) callback, void* userData, void* window, char8* startFolder, bool allowMany);
}

/// Device creation and small helpers implemented in native/tallow_native.cpp.
static class Native
{
	public function void LogFn(char8* text);

	[CLink] public static extern void tn_set_log(LogFn fn, bool trace);
	[CLink] public static extern bool tn_gfx_init(void* window, int32 width, int32 height, int32 renderer, uint32 resetFlags);
	[CLink] public static extern void tn_gfx_reset(int32 width, int32 height, uint32 resetFlags);
	[CLink] public static extern void tn_gfx_shutdown();
	[CLink] public static extern char8* tn_gfx_renderer_name();
	[CLink] public static extern int32 tn_gfx_renderer_type();
	[CLink] public static extern int32 tn_gfx_caps_flags();
	[CLink] public static extern void tn_gfx_screenshot(char8* path);

	[CLink] public static extern uint8* tn_image_load(char8* path, int32* width, int32* height);
	[CLink] public static extern void tn_image_free(uint8* pixels);
	[CLink] public static extern bool tn_image_write_png(char8* path, uint8* pixels, int32 width, int32 height);

	[CRepr]
	public struct GltfPrim
	{
		public float* positions;
		public float* normals;
		public float* uvs;
		public float* colors;
		public uint32* indices;
		public uint32 vertexCount;
		public uint32 indexCount;
		public float[4] baseColor;
		public float metallic;
		public float roughness;
		public float[3] emissive;
		public float[16] world;
		public char8[64] name;
		public uint16* joints;
		public float* weights;
		// The primitive's whole material (native/tallow_assets.c).
		public int32 material;
		public char8[64] materialName;
		public int32 baseColorImage;
		public int32 metalRoughImage;
		public int32 normalImage;
		public int32 occlusionImage;
		public int32 emissiveImage;
		public float normalScale;
		public float occlusionStrength;
		public int32 alphaMode;
		public float alphaCutoff;
		public int32 doubleSided;
		public float* uv2s;
	}

	[CRepr]
	public struct GltfJoint
	{
		public char8[64] name;
		public int32 parent;
		public float[10] rest;
		public float[16] inverseBind;
		public float[16] parentWorld;
	}

	[CRepr]
	public struct GltfAnim
	{
		public char8[64] name;
		public float duration;
		public int32 frames;
		public float* data;
	}

	[CLink] public static extern int32 tn_gltf_joint_count(void* scene);
	[CLink] public static extern GltfJoint* tn_gltf_get_joint(void* scene, int32 index);
	[CLink] public static extern int32 tn_gltf_anim_count(void* scene);
	[CLink] public static extern GltfAnim* tn_gltf_get_anim(void* scene, int32 index);

	[CLink] public static extern void* tn_gltf_load(char8* path);
	[CLink] public static extern uint32 tn_gltf_prim_count(void* scene);
	[CLink] public static extern GltfPrim* tn_gltf_get_prim(void* scene, uint32 index);
	[CLink] public static extern void tn_gltf_free(void* scene);
	[CLink] public static extern int32 tn_gltf_image_count(void* scene);
	[CLink] public static extern uint8* tn_gltf_get_image(void* scene, int32 index, int32* width, int32* height);
}
