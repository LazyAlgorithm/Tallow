#include "ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e.h"
#include "ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d.h"
#include "ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d.h"
#include "ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f.h"
#include "ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6.h"
#include "ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c.h"
#include "ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5.h"
#include "ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2.h"

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

static const ffx_fsr2_accumulate_pass_PermutationInfo g_ffx_fsr2_accumulate_pass_PermutationInfo[] = {
    { g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_size, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_data, 1, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_83d8010fde62eafbe5f8636030c57f0e_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_size, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_data, 1, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_e8c82d39f72e6b37a36619872bad395d_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_size, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_data, 1, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_19a4cc688ec7b78cd17e3b845adf0d5d_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_size, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_data, 1, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_fdd3829fbe6ac08491491906e76cb21f_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_size, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_data, 1, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_fb9b3be8f0ee7077561367d85f96d8f6_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_size, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_data, 1, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_SampledImageResourceSets, 4, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_6a4914a98b5a44d5a79782bf6260898c_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_size, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_data, 1, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_9e0a11d1de3bfb9359a1250e3bd351c5_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
    { g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_size, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_data, 1, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SamplerResourceSets, 0, 0, 0, 0, 0, 9, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_SampledImageResourceSets, 5, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_StorageImageResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceNames, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceBindings, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceCounts, g_ffx_fsr2_accumulate_pass_8408931e610b925fa700bbfca8f407f2_UniformBufferResourceSets, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, },
};

