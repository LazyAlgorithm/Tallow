/*
 * Tallow patch for bgfx's Vulkan backend: lets the engine ask for extra instance/device extensions before
 * bgfx::init, read the native Vulkan handles, and run its own commands (DLSS, FSR) inside bgfx's frame.
 * Plain C so it can be declared from anywhere. All functions are no-ops / return 0 when Vulkan is not the backend.
 */
#ifndef TALLOW_VK_H_HEADER_GUARD
#define TALLOW_VK_H_HEADER_GUARD

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TallowVkNative
{
	void*    instance;            // VkInstance
	void*    physicalDevice;      // VkPhysicalDevice
	void*    device;              // VkDevice
	void*    queue;               // VkQueue (graphics + compute, the one bgfx submits on)
	uint32_t queueFamily;
	uint32_t queueIndex;
	void*    getInstanceProcAddr; // PFN_vkGetInstanceProcAddr
	void*    getDeviceProcAddr;   // PFN_vkGetDeviceProcAddr
	uint32_t apiVersion;          // VkPhysicalDeviceProperties::apiVersion (the device)
	uint32_t instanceApiVersion;  // what the instance was created with
	uint32_t vendorId;
	uint32_t deviceId;
	char     deviceName[256];
} TallowVkNative;

typedef struct TallowVkTexture
{
	uint64_t image;       // VkImage
	uint32_t format;      // VkFormat
	uint32_t width;
	uint32_t height;
	uint32_t depth;       // 3D depth, 1 otherwise
	uint32_t layers;
	uint32_t mips;
	uint32_t aspect;      // VkImageAspectFlags (what bgfx views the image with)
	uint32_t layout;      // VkImageLayout bgfx believes the image is in
	uint64_t bgfxFlags;   // BGFX_TEXTURE_* the texture was created with
} TallowVkTexture;

// Call before bgfx::init. Names are copied. Extensions the driver does not offer are skipped (check with
// tallow_vk_extension_enabled afterwards). The instance list must be given before the instance is created, the
// device list before the device.
void tallow_vk_request_extensions(const char* const* _instanceExtensions, uint32_t _numInstance,
	const char* const* _deviceExtensions, uint32_t _numDevice);

// 1 when the named instance or device extension was enabled by bgfx.
int tallow_vk_extension_enabled(const char* _name);

// Fills the struct and returns 1 when the Vulkan backend is initialised, otherwise returns 0.
int tallow_vk_get_native(TallowVkNative* _out);

// Native image of a bgfx texture handle index (bgfx::TextureHandle::idx). Returns 0 when invalid. For a
// multisampled texture the image is the multisampled one.
int tallow_vk_texture_info(uint16_t _textureIdx, TallowVkTexture* _out);

// Records the barrier that puts the texture into the layout, and updates what bgfx believes, so bgfx keeps
// working with the image afterwards. mode 0: SHADER_READ_ONLY_OPTIMAL (sampled, also fine for depth images, as
// bgfx itself samples them), mode 1: GENERAL (storage image). Only call inside a view hook.
// Returns the VkImageLayout now set, 0 on failure.
uint32_t tallow_vk_texture_transition(uint16_t _textureIdx, void* _commandBuffer, int _mode);

// The hook runs on the thread that calls bgfx::frame (single-threaded mode) once all items of the view have been
// recorded, outside any render pass, with bgfx's frame command buffer (VkCommandBuffer). The view must have at
// least one item in the frame (bgfx::touch(view) is enough). The hook must leave the command buffer recordable
// and bgfx will rebind everything it needs; changing image layouts must go through tallow_vk_texture_transition.
typedef void (*TallowVkViewHook)(void* _commandBuffer, uint16_t _view, void* _user);

// Pass NULL to remove the hook.
void tallow_vk_set_view_hook(uint16_t _view, TallowVkViewHook _hook, void* _user);

#ifdef __cplusplus
}
#endif

#endif // TALLOW_VK_H_HEADER_GUARD
