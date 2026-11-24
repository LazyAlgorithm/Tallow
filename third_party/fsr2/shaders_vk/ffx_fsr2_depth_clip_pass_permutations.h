#include "ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b.h"
#include "ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc.h"
#include "ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765.h"
#include "ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc.h"

typedef union ffx_fsr2_depth_clip_pass_PermutationKey {
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
} ffx_fsr2_depth_clip_pass_PermutationKey;

typedef struct ffx_fsr2_depth_clip_pass_PermutationInfo {
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

} ffx_fsr2_depth_clip_pass_PermutationInfo;

static const uint32_t g_ffx_fsr2_depth_clip_pass_IndirectionTable[] = {
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
};

static const ffx_fsr2_depth_clip_pass_PermutationInfo g_ffx_fsr2_depth_clip_pass_PermutationInfo[] = {
    { g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_size, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_data, 1, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SamplerResourceNames, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SamplerResourceBindings, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SamplerResourceCounts, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SampledImageResourceNames, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SampledImageResourceBindings, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SampledImageResourceCounts, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_SampledImageResourceSets, 2, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_StorageImageResourceNames, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_StorageImageResourceBindings, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_StorageImageResourceCounts, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_UniformBufferResourceNames, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_UniformBufferResourceBindings, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_UniformBufferResourceCounts, g_ffx_fsr2_depth_clip_pass_81c77abfcbf8dadb1c5335305dd9b71b_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_size, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_data, 1, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SamplerResourceNames, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SamplerResourceBindings, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SamplerResourceCounts, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SampledImageResourceNames, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SampledImageResourceBindings, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SampledImageResourceCounts, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_SampledImageResourceSets, 2, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_StorageImageResourceNames, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_StorageImageResourceBindings, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_StorageImageResourceCounts, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_UniformBufferResourceNames, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_UniformBufferResourceBindings, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_UniformBufferResourceCounts, g_ffx_fsr2_depth_clip_pass_41b3c034da52e3fac673ce293e37adcc_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_size, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_data, 1, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SamplerResourceNames, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SamplerResourceBindings, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SamplerResourceCounts, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SampledImageResourceNames, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SampledImageResourceBindings, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SampledImageResourceCounts, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_SampledImageResourceSets, 2, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_StorageImageResourceNames, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_StorageImageResourceBindings, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_StorageImageResourceCounts, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_UniformBufferResourceNames, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_UniformBufferResourceBindings, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_UniformBufferResourceCounts, g_ffx_fsr2_depth_clip_pass_87fea2a655c4d1efe7982363a5b78765_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_size, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_data, 1, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SamplerResourceNames, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SamplerResourceBindings, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SamplerResourceCounts, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SampledImageResourceNames, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SampledImageResourceBindings, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SampledImageResourceCounts, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_SampledImageResourceSets, 2, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_StorageImageResourceNames, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_StorageImageResourceBindings, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_StorageImageResourceCounts, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_UniformBufferResourceNames, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_UniformBufferResourceBindings, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_UniformBufferResourceCounts, g_ffx_fsr2_depth_clip_pass_1fad923493dad552f11d5d66e657ccfc_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
};

