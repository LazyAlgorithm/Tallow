// <vulkan/vulkan.h> for the DLSS (NGX) and FSR 2 sources, which expect the Vulkan SDK layout. bgfx carries the Khronos
// headers (it loads the loader at run time), so this forwards to them.
//
// When TALLOW_FSR2_RENAME_VK is defined (the FSR 2 sources only), the few global entry points FSR 2 calls without going
// through its own device table are renamed to functions that tallow_upscale.cpp implements on top of the instance
// pointers bgfx already loaded, so the engine does not link against (or interpose on) the Vulkan loader.
#pragma once
#include "../../../../third_party/bgfx.cmake/bgfx/3rdparty/khronos/vulkan-local/vulkan.h"

#if defined(TALLOW_FSR2_RENAME_VK)
#ifdef __cplusplus
extern "C" {
#endif
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*);
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceProperties(VkPhysicalDevice, VkPhysicalDeviceProperties*);
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceProperties2(VkPhysicalDevice, VkPhysicalDeviceProperties2*);
VKAPI_ATTR void VKAPI_CALL tallow_fsr2_vkGetPhysicalDeviceFeatures2(VkPhysicalDevice, VkPhysicalDeviceFeatures2*);
VKAPI_ATTR VkResult VKAPI_CALL tallow_fsr2_vkEnumerateDeviceExtensionProperties(VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*);
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL tallow_fsr2_vkGetDeviceProcAddr(VkDevice, const char*);
#ifdef __cplusplus
}
#endif
#define vkGetPhysicalDeviceMemoryProperties tallow_fsr2_vkGetPhysicalDeviceMemoryProperties
#define vkGetPhysicalDeviceProperties tallow_fsr2_vkGetPhysicalDeviceProperties
#define vkGetPhysicalDeviceProperties2 tallow_fsr2_vkGetPhysicalDeviceProperties2
#define vkGetPhysicalDeviceFeatures2 tallow_fsr2_vkGetPhysicalDeviceFeatures2
#define vkEnumerateDeviceExtensionProperties tallow_fsr2_vkEnumerateDeviceExtensionProperties
#define vkGetDeviceProcAddr tallow_fsr2_vkGetDeviceProcAddr
#endif
