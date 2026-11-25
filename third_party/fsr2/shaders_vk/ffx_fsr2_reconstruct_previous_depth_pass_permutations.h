#include "ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4.h"
#include "ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344.h"
#include "ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4.h"
#include "ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686.h"
#include "ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679.h"
#include "ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302.h"
#include "ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22.h"
#include "ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358.h"

typedef union ffx_fsr2_reconstruct_previous_depth_pass_PermutationKey {
    struct {
        uint32_t FFX_FSR2_OPTION_REPROJECT_USE_LANCZOS_TYPE : 1;
        uint32_t FFX_FSR2_OPTION_HDR_COLOR_INPUT : 1;
        uint32_t FFX_FSR2_OPTION_LOW_RESOLUTION_MOTION_VECTORS : 1;
        uint32_t FFX_FSR2_OPTION_JITTERED_MOTION_VECTORS : 1;
        uint32_t FFX_FSR2_OPTION_INVERTED_DEPTH : 1;
        uint32_t FFX_FSR2_OPTION_APPLY_SHARPENING : 1;
        uint32_t FFX_HALF : 1;
    };
    uint32_t index;
} ffx_fsr2_reconstruct_previous_depth_pass_PermutationKey;

typedef struct ffx_fsr2_reconstruct_previous_depth_pass_PermutationInfo {
    const uint32_t       blobSize;
    const unsigned char* blobData;

    const uint32_t  numSamplerResources;
    const char**    samplerResourceNames;
    const uint32_t* samplerResourceBindings;
    const uint32_t* samplerResourceCounts;
    const uint32_t* samplerResourceSets;

    const uint32_t  numCombinedSamplerResources;
    const char**    combinedSamplerResourceNames;
    const uint32_t* combinedSamplerResourceBindings;
    const uint32_t* combinedSamplerResourceCounts;
    const uint32_t* combinedSamplerResourceSets;

    const uint32_t  numSampledImageResources;
    const char**    sampledImageResourceNames;
    const uint32_t* sampledImageResourceBindings;
    const uint32_t* sampledImageResourceCounts;
    const uint32_t* sampledImageResourceSets;

    const uint32_t  numStorageImageResources;
    const char**    storageImageResourceNames;
    const uint32_t* storageImageResourceBindings;
    const uint32_t* storageImageResourceCounts;
    const uint32_t* storageImageResourceSets;

    const uint32_t  numUniformTexelBufferResources;
    const char**    uniformTexelBufferResourceNames;
    const uint32_t* uniformTexelBufferResourceBindings;
    const uint32_t* uniformTexelBufferResourceCounts;
    const uint32_t* uniformTexelBufferResourceSets;

    const uint32_t  numStorageTexelBufferResources;
    const char**    storageTexelBufferResourceNames;
    const uint32_t* storageTexelBufferResourceBindings;
    const uint32_t* storageTexelBufferResourceCounts;
    const uint32_t* storageTexelBufferResourceSets;

    const uint32_t  numUniformBufferResources;
    const char**    uniformBufferResourceNames;
    const uint32_t* uniformBufferResourceBindings;
    const uint32_t* uniformBufferResourceCounts;
    const uint32_t* uniformBufferResourceSets;

    const uint32_t  numStorageBufferResources;
    const char**    storageBufferResourceNames;
    const uint32_t* storageBufferResourceBindings;
    const uint32_t* storageBufferResourceCounts;
    const uint32_t* storageBufferResourceSets;

    const uint32_t  numInputAttachmentResources;
    const char**    inputAttachmentResourceNames;
    const uint32_t* inputAttachmentResourceBindings;
    const uint32_t* inputAttachmentResourceCounts;
    const uint32_t* inputAttachmentResourceSets;

    const uint32_t  numRTAccelerationStructureResources;
    const char**    rtAccelerationStructureResourceNames;
    const uint32_t* rtAccelerationStructureResourceBindings;
    const uint32_t* rtAccelerationStructureResourceCounts;
    const uint32_t* rtAccelerationStructureResourceSets;

} ffx_fsr2_reconstruct_previous_depth_pass_PermutationInfo;

static const uint32_t g_ffx_fsr2_reconstruct_previous_depth_pass_IndirectionTable[] = {
    6,
    6,
    2,
    2,
    6,
    6,
    2,
    2,
    6,
    6,
    2,
    2,
    6,
    6,
    2,
    2,
    4,
    4,
    0,
    0,
    4,
    4,
    0,
    0,
    4,
    4,
    0,
    0,
    4,
    4,
    0,
    0,
    6,
    6,
    2,
    2,
    6,
    6,
    2,
    2,
    6,
    6,
    2,
    2,
    6,
    6,
    2,
    2,
    4,
    4,
    0,
    0,
    4,
    4,
    0,
    0,
    4,
    4,
    0,
    0,
    4,
    4,
    0,
    0,
    7,
    7,
    3,
    3,
    7,
    7,
    3,
    3,
    7,
    7,
    3,
    3,
    7,
    7,
    3,
    3,
    5,
    5,
    1,
    1,
    5,
    5,
    1,
    1,
    5,
    5,
    1,
    1,
    5,
    5,
    1,
    1,
    7,
    7,
    3,
    3,
    7,
    7,
    3,
    3,
    7,
    7,
    3,
    3,
    7,
    7,
    3,
    3,
    5,
    5,
    1,
    1,
    5,
    5,
    1,
    1,
    5,
    5,
    1,
    1,
    5,
    5,
    1,
    1,
};

static const ffx_fsr2_reconstruct_previous_depth_pass_PermutationInfo g_ffx_fsr2_reconstruct_previous_depth_pass_PermutationInfo[] = {
    { g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_size, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_308e8dfd8f65d3f1bfc29aa55b889bc4_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_size, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_b80f5f70bd7a0f7b8df760687720d344_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_size, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_bd8c71015424b0d7805a946bd35641a4_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_size, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_bb089e5b31a41e25f881acd431b72686_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_size, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_1a3deec5e3fd33dd112c8798d54d8679_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_size, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_fffb65733cd88df033c8deba89dec302_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_size, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_5085461beb5527b8a12eacf528cc8b22_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_size, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_data, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_SampledImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_SampledImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_SampledImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_SampledImageResourceSets, 4, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_StorageImageResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_StorageImageResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_StorageImageResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_UniformBufferResourceNames, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_UniformBufferResourceBindings, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_UniformBufferResourceCounts, g_ffx_fsr2_reconstruct_previous_depth_pass_08232f4d5645803e4a44b393c40b4358_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
};

