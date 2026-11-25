#include "ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d.h"
#include "ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e.h"
#include "ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d.h"
#include "ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f.h"
#include "ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c.h"
#include "ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6.h"
#include "ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5.h"
#include "ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2.h"
#include "ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca.h"
#include "ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10.h"
#include "ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d.h"
#include "ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185.h"
#include "ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8.h"
#include "ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc.h"
#include "ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49.h"
#include "ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a.h"

typedef union ffx_fsr2_accumulate_pass_PermutationKey {
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
} ffx_fsr2_accumulate_pass_PermutationKey;

typedef struct ffx_fsr2_accumulate_pass_PermutationInfo {
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

} ffx_fsr2_accumulate_pass_PermutationInfo;

static const uint32_t g_ffx_fsr2_accumulate_pass_IndirectionTable[] = {
    14,
    6,
    10,
    2,
    14,
    6,
    10,
    2,
    14,
    6,
    10,
    2,
    14,
    6,
    10,
    2,
    14,
    6,
    10,
    2,
    14,
    6,
    10,
    2,
    14,
    6,
    10,
    2,
    14,
    6,
    10,
    2,
    13,
    5,
    9,
    1,
    13,
    5,
    9,
    1,
    13,
    5,
    9,
    1,
    13,
    5,
    9,
    1,
    13,
    5,
    9,
    1,
    13,
    5,
    9,
    1,
    13,
    5,
    9,
    1,
    13,
    5,
    9,
    1,
    15,
    7,
    11,
    3,
    15,
    7,
    11,
    3,
    15,
    7,
    11,
    3,
    15,
    7,
    11,
    3,
    15,
    7,
    11,
    3,
    15,
    7,
    11,
    3,
    15,
    7,
    11,
    3,
    15,
    7,
    11,
    3,
    12,
    4,
    8,
    0,
    12,
    4,
    8,
    0,
    12,
    4,
    8,
    0,
    12,
    4,
    8,
    0,
    12,
    4,
    8,
    0,
    12,
    4,
    8,
    0,
    12,
    4,
    8,
    0,
    12,
    4,
    8,
    0,
};

static const ffx_fsr2_accumulate_pass_PermutationInfo g_ffx_fsr2_accumulate_pass_PermutationInfo[] = {
    { g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_size, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_data, 1, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_size, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_data, 1, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_size, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_data, 1, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_size, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_data, 1, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_size, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_data, 1, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_size, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_data, 1, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_size, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_data, 1, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_size, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_data, 1, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_size, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_data, 1, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_a63d7d9f3aeeb41d10328fa7f228c1ca_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_size, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_data, 1, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_1d9db0ffe020e84e8baa02379b230e10_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_size, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_data, 1, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_24fcbe138a3d4350e7e07281ead5f88d_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_size, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_data, 1, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_0ccb8a0c6ce90679691f8f02baac1185_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_size, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_data, 1, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_3c5e1b4799d49c5a34b538ef60d539c8_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_size, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_data, 1, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_853c6f5983a885078e604a77526bf7dc_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_size, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_data, 1, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_c87855e565564c37d4dbfa36de3b5b49_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_size, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_data, 1, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SamplerResourceSets, 0, 0, 0, 0, 0, 8, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_af625d7c63039754d6157e312e40213a_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
};

