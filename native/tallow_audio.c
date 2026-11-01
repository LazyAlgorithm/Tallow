// Audio for Tallow on miniaudio: positioned sounds, one listener, mixer groups, a low-pass per source (used for
// occlusion) and a shared reverb bus. Everything Beef needs is behind flat functions.
//
// Tallow is left-handed (+Z forward) and miniaudio right-handed (-Z forward), so Z is mirrored on the way in;
// without that, left and right would be swapped.
#define STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include "extras/nodes/ma_reverb_node/ma_reverb_node.c"
#undef STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"

#include <string.h>
#include <math.h>
#include "tallow_hrtf_data.h"
#include <opus.h>

// ---- HRTF ----
// A positioned sound arrives here in mono, already made quieter by distance, and leaves in stereo. With HRTF on it
// is filtered through the response measured at each ear of a dummy head for a source in that direction (the MIT
// KEMAR set), which carries the timing, loudness and colour differences the brain uses to place a sound, including
// in front, behind, above and below. With HRTF off the same node does ordinary left-right panning.

#define TN_HRTF_MAX_TAPS 192

static float hrtfLeft[TN_HRTF_COUNT][TN_HRTF_MAX_TAPS];
static float hrtfRight[TN_HRTF_COUNT][TN_HRTF_MAX_TAPS];
static float hrtfUnit[TN_HRTF_COUNT][3];
static int hrtfOnsetLeft[TN_HRTF_COUNT], hrtfOnsetRight[TN_HRTF_COUNT];   // sample at which each response begins
static int hrtfTaps = 0;
static unsigned int hrtfSampleRate = 48000;
// Off unless the game turns it on.
static volatile int hrtfEnabled = 0;
// Tuning, for a game's options menu.
static volatile float hrtfStrength = 1.0f;     // 0 is plain panning, 1 fully binaural
static volatile float hrtfHeadSize = 1.0f;     // scales the delay between the ears; 1 is the measured head
static volatile float hrtfTrebleGain = 0.0f;   // extra high-frequency gain as a linear amount added (0 = none)

#define TN_HRTF_RING 512                        // history ring: the response plus room to delay an ear further
#define TN_HRTF_MAX_EXTRA 96

typedef struct TnHrtfNode {
    ma_node_base base;
    float history[TN_HRTF_RING];
    int head;
    volatile int target;        // response index, plus 0x10000 when the source is on the left (ears swapped)
    volatile int targetDelayLeft, targetDelayRight;   // extra samples of delay per ear, from the head size
    int current, currentDelayLeft, currentDelayRight;
    volatile float panLeft, panRight;
    float currentPanLeft, currentPanRight;
    float shelfLeft, shelfRight;                      // state of the treble control
} TnHrtfNode;

// Brings the measurements to the engine's sample rate and to a level that matches panning for a source ahead.
static void hrtf_prepare(unsigned int sampleRate) {
    const double ratio = (double)TN_HRTF_RATE / (double)sampleRate;
    hrtfSampleRate = sampleRate;
    int taps = (int)ceil(TN_HRTF_TAPS / ratio);
    if (taps > TN_HRTF_MAX_TAPS) taps = TN_HRTF_MAX_TAPS;
    hrtfTaps = taps;
    for (int d = 0; d < TN_HRTF_COUNT; ++d) {
        for (int ear = 0; ear < 2; ++ear) {
            const short* source = tn_hrtf_responses[d] + ear * TN_HRTF_TAPS;
            float* target = ear == 0 ? hrtfLeft[d] : hrtfRight[d];
            for (int i = 0; i < taps; ++i) {
                const double position = i * ratio;
                const int index = (int)position;
                const double fraction = position - index;
                const double a = index < TN_HRTF_TAPS ? source[index] : 0;
                const double b = index + 1 < TN_HRTF_TAPS ? source[index + 1] : 0;
                target[i] = (float)((a + (b - a) * fraction) / 32768.0 * ratio);
            }
        }
        // Where each ear's response starts: the gap between the two is the delay between the ears, which is what
        // the head-size setting stretches or shrinks.
        for (int ear = 0; ear < 2; ++ear) {
            const float* response = ear == 0 ? hrtfLeft[d] : hrtfRight[d];
            float peak = 0;
            for (int i = 0; i < taps; ++i) if (fabsf(response[i]) > peak) peak = fabsf(response[i]);
            int onset = 0;
            for (int i = 0; i < taps; ++i) if (fabsf(response[i]) >= peak * 0.2f) { onset = i; break; }
            if (ear == 0) hrtfOnsetLeft[d] = onset; else hrtfOnsetRight[d] = onset;
        }
        const double elevation = tn_hrtf_directions[d][0] * MA_PI_D / 180.0;
        const double azimuth = tn_hrtf_directions[d][1] * MA_PI_D / 180.0;
        hrtfUnit[d][0] = (float)(sin(azimuth) * cos(elevation));   // to the right
        hrtfUnit[d][1] = (float)sin(elevation);                     // up
        hrtfUnit[d][2] = (float)(cos(azimuth) * cos(elevation));   // ahead
    }
    // A source straight ahead should be as loud in each ear as a centred, panned one (half the power each).
    int front = 0;
    for (int d = 0; d < TN_HRTF_COUNT; ++d)
        if (tn_hrtf_directions[d][0] == 0 && tn_hrtf_directions[d][1] == 0) front = d;
    double energy = 0;
    for (int i = 0; i < taps; ++i) energy += (double)hrtfLeft[front][i] * hrtfLeft[front][i];
    const float scale = energy > 0 ? (float)sqrt(0.5 / energy) : 1.0f;
    for (int d = 0; d < TN_HRTF_COUNT; ++d)
        for (int i = 0; i < taps; ++i) { hrtfLeft[d][i] *= scale; hrtfRight[d][i] *= scale; }
}

static void hrtf_convolve(const TnHrtfNode* node, int selection, int delayLeft, int delayRight, float* left, float* right) {
    const int index = selection & 0xFFFF;
    const int mirrored = (selection & 0x10000) != 0;
    const float* responseLeft = mirrored ? hrtfRight[index] : hrtfLeft[index];
    const float* responseRight = mirrored ? hrtfLeft[index] : hrtfRight[index];
    const float* history = node->history;
    const int taps = hrtfTaps;
    const int mask = TN_HRTF_RING - 1;
    // Newest sample first, walking back round the ring; an ear's extra delay just starts it further back.
    int startLeft = node->head - delayLeft, startRight = node->head - delayRight;
    float l = 0, r = 0;
    for (int k = 0; k < taps; ++k) {
        l += responseLeft[k] * history[(startLeft - k) & mask];
        r += responseRight[k] * history[(startRight - k) & mask];
    }
    *left = l; *right = r;
}

static void hrtf_process(ma_node* pNode, const float** ppFramesIn, ma_uint32* pFrameCountIn, float** ppFramesOut, ma_uint32* pFrameCountOut) {
    TnHrtfNode* node = (TnHrtfNode*)pNode;
    const float* input = ppFramesIn != NULL ? ppFramesIn[0] : NULL;
    float* output = ppFramesOut[0];
    const ma_uint32 count = *pFrameCountOut;
    const int target = node->target;
    const int delayLeft = node->targetDelayLeft, delayRight = node->targetDelayRight;
    const float strength = hrtfEnabled && hrtfTaps > 0 ? hrtfStrength : 0.0f;
    const float treble = hrtfTrebleGain;
    // One-pole low-pass at 4 kHz; what is above it is the "treble" the control turns up or down.
    const float smoothing = expf(-2.0f * (float)MA_PI_D * 4000.0f / (float)hrtfSampleRate);
    const int moved = target != node->current || delayLeft != node->currentDelayLeft || delayRight != node->currentDelayRight;
    const float panLeft = node->panLeft, panRight = node->panRight;
    (void)pFrameCountIn;
    if (strength <= 0.0f) {
        // Plain panning (HRTF off): the history is still kept, so turning it on mid-sound has something to hear.
        const float startLeft = node->currentPanLeft, startRight = node->currentPanRight;
        const float stepLeft = (panLeft - startLeft) / (float)count, stepRight = (panRight - startRight) / (float)count;
        int head = node->head;
        for (ma_uint32 i = 0; i < count; ++i) {
            const float sample = input != NULL ? input[i] : 0.0f;
            node->history[head] = sample;
            head = (head + 1) & (TN_HRTF_RING - 1);
            output[i * 2] = sample * (startLeft + stepLeft * (float)(i + 1));
            output[i * 2 + 1] = sample * (startRight + stepRight * (float)(i + 1));
        }
        node->head = head;
        node->current = target;
        node->currentDelayLeft = delayLeft;
        node->currentDelayRight = delayRight;
        node->currentPanLeft = panLeft;
        node->currentPanRight = panRight;
        return;
    }
    for (ma_uint32 i = 0; i < count; ++i) {
        const float sample = input != NULL ? input[i] : 0.0f;
        const float t = (float)(i + 1) / (float)count;
        float left = 0, right = 0;
        node->history[node->head] = sample;
        if (strength > 0.0f) {
            hrtf_convolve(node, node->current, node->currentDelayLeft, node->currentDelayRight, &left, &right);
            if (moved) {
                // The direction changed: slide from the old response to the new one across this block, so
                // a moving sound glides instead of clicking.
                float nextLeft, nextRight;
                hrtf_convolve(node, target, delayLeft, delayRight, &nextLeft, &nextRight);
                left += (nextLeft - left) * t;
                right += (nextRight - right) * t;
            }
            node->shelfLeft = left + (node->shelfLeft - left) * smoothing;
            node->shelfRight = right + (node->shelfRight - right) * smoothing;
            left += (left - node->shelfLeft) * treble;
            right += (right - node->shelfRight) * treble;
        }
        if (strength < 1.0f) {
            const float pannedLeft = sample * (node->currentPanLeft + (panLeft - node->currentPanLeft) * t);
            const float pannedRight = sample * (node->currentPanRight + (panRight - node->currentPanRight) * t);
            left = pannedLeft + (left - pannedLeft) * strength;
            right = pannedRight + (right - pannedRight) * strength;
        }
        node->head = (node->head + 1) & (TN_HRTF_RING - 1);
        output[i * 2] = left;
        output[i * 2 + 1] = right;
    }
    node->current = target;
    node->currentDelayLeft = delayLeft;
    node->currentDelayRight = delayRight;
    node->currentPanLeft = panLeft;
    node->currentPanRight = panRight;
}

static ma_node_vtable hrtfVtable = { hrtf_process, NULL, 1, 1, 0 };

// Direction of the source as the listener hears it: azimuth to the right of straight ahead, elevation upward.
static void hrtf_aim(TnHrtfNode* node, float azimuth, float elevation) {
    float x = sinf(azimuth) * cosf(elevation), y = sinf(elevation), z = cosf(azimuth) * cosf(elevation);
    const int mirrored = x < 0;
    if (mirrored) x = -x;   // the measurements cover the right-hand side; the left is its mirror image
    int best = 0;
    float bestDot = -2.0f;
    for (int d = 0; d < TN_HRTF_COUNT; ++d) {
        const float dot = x * hrtfUnit[d][0] + y * hrtfUnit[d][1] + z * hrtfUnit[d][2];
        if (dot > bestDot) { bestDot = dot; best = d; }
    }
    // Head size: the measured head's delay between the ears is stretched or shrunk by delaying one ear further.
    const int onsetLeft = mirrored ? hrtfOnsetRight[best] : hrtfOnsetLeft[best];
    const int onsetRight = mirrored ? hrtfOnsetLeft[best] : hrtfOnsetRight[best];
    const int earliest = onsetLeft < onsetRight ? onsetLeft : onsetRight;
    float extraLeft = (float)(onsetLeft - earliest) * (hrtfHeadSize - 1.0f);
    float extraRight = (float)(onsetRight - earliest) * (hrtfHeadSize - 1.0f);
    const float lowest = extraLeft < extraRight ? extraLeft : extraRight;
    extraLeft -= lowest;    // a smaller head delays the nearer ear instead of advancing the farther one
    extraRight -= lowest;
    int delayLeft = (int)(extraLeft + 0.5f), delayRight = (int)(extraRight + 0.5f);
    if (delayLeft > TN_HRTF_MAX_EXTRA) delayLeft = TN_HRTF_MAX_EXTRA;
    if (delayRight > TN_HRTF_MAX_EXTRA) delayRight = TN_HRTF_MAX_EXTRA;
    node->targetDelayLeft = delayLeft;
    node->targetDelayRight = delayRight;
    node->target = best | (mirrored ? 0x10000 : 0);
    // For panning: constant power, from the left-right part of the direction only.
    const float pan = sinf(azimuth) * cosf(elevation);
    const float angle = (pan + 1.0f) * (float)MA_PI_D * 0.25f;
    node->panLeft = cosf(angle);
    node->panRight = sinf(angle);
}

#define TN_GROUP_COUNT 6
#define TN_AUDIO_BLOCK 480     // frames mixed at a time: 10 ms at 48 kHz

typedef struct TnAudioSource {
    ma_sound sound;
    TnHrtfNode hrtf;        // only on positioned sources
    int positioned;
    ma_lpf_node lowpass;
    ma_splitter_node split;
    float cutoff;
    int group;
    // Whether the low-pass filter and the reverb splitter are in the signal path (see source_wire).
    int filtering, sending;
    struct TnVoiceStream* voice;   // set when the sound is fed samples as they arrive instead of read from a file
} TnAudioSource;

// Mirrors Jolt-style flat parameter passing: one struct, the same layout as AudioParams in Beef.
typedef struct TnAudioParams {
    float position[3];
    float velocity[3];
    float direction[3];
    float volume;
    float pitch;
    float minDistance;
    float maxDistance;
    float rolloff;
    float doppler;
    float lowpassHz;
    float reverbSend;
    float coneInner;   // radians
    float coneOuter;
    float coneOuterGain;
    int rolloffModel;  // 1 inverse, 2 linear, 3 exponential
    int spatial;
    int looping;
} TnAudioParams;

static ma_engine engine;
static ma_sound_group groups[TN_GROUP_COUNT];
static ma_reverb_node reverb;
static int ready = 0;
static int hasReverb = 0;

void tn_voice_capture_stop(void);

// ---- Files ----
// miniaudio opens sound files through this: a file inside an asset pack is read into memory and served from there
// (also when it is streamed), anything else goes to the ordinary file system.
#include "tallow_pack.h"

typedef struct {
    ma_vfs_callbacks callbacks;
    ma_default_vfs disk;
} TnVfs;

typedef struct {
    unsigned char* data;     // NULL for a file on disk
    size_t size, cursor;
    ma_vfs_file onDisk;
} TnVfsFile;

static TnVfs packVfs;

static ma_result vfs_open(ma_vfs* vfs, const char* path, ma_uint32 mode, ma_vfs_file* out) {
    TnVfsFile* file = (TnVfsFile*)ma_malloc(sizeof(TnVfsFile), NULL);
    if (file == NULL) return MA_OUT_OF_MEMORY;
    memset(file, 0, sizeof(*file));
    if ((mode & MA_OPEN_MODE_WRITE) == 0) {
        file->data = (unsigned char*)tn_pack_read(path, &file->size);
        if (file->data == NULL && tn_pack_exists(path)) { ma_free(file, NULL); return MA_IO_ERROR; }
    }
    if (file->data == NULL) {
        ma_result result = ma_vfs_open(&((TnVfs*)vfs)->disk, path, mode, &file->onDisk);
        if (result != MA_SUCCESS) { ma_free(file, NULL); return result; }
    }
    *out = (ma_vfs_file)file;
    return MA_SUCCESS;
}

static ma_result vfs_open_w(ma_vfs* vfs, const wchar_t* path, ma_uint32 mode, ma_vfs_file* out) {
    TnVfsFile* file = (TnVfsFile*)ma_malloc(sizeof(TnVfsFile), NULL);
    if (file == NULL) return MA_OUT_OF_MEMORY;
    memset(file, 0, sizeof(*file));
    ma_result result = ma_vfs_open_w(&((TnVfs*)vfs)->disk, path, mode, &file->onDisk);
    if (result != MA_SUCCESS) { ma_free(file, NULL); return result; }
    *out = (ma_vfs_file)file;
    return MA_SUCCESS;
}

static ma_result vfs_close(ma_vfs* vfs, ma_vfs_file handle) {
    TnVfsFile* file = (TnVfsFile*)handle;
    ma_result result = MA_SUCCESS;
    if (file->data != NULL) tn_pack_free(file->data);
    else result = ma_vfs_close(&((TnVfs*)vfs)->disk, file->onDisk);
    ma_free(file, NULL);
    return result;
}

static ma_result vfs_read(ma_vfs* vfs, ma_vfs_file handle, void* destination, size_t size, size_t* read) {
    TnVfsFile* file = (TnVfsFile*)handle;
    if (file->data == NULL) return ma_vfs_read(&((TnVfs*)vfs)->disk, file->onDisk, destination, size, read);
    size_t left = file->size - file->cursor;
    size_t count = size < left ? size : left;
    memcpy(destination, file->data + file->cursor, count);
    file->cursor += count;
    if (read != NULL) *read = count;
    return (count == 0 && size > 0) ? MA_AT_END : MA_SUCCESS;
}

static ma_result vfs_write(ma_vfs* vfs, ma_vfs_file handle, const void* source, size_t size, size_t* written) {
    TnVfsFile* file = (TnVfsFile*)handle;
    if (file->data != NULL) return MA_ACCESS_DENIED;
    return ma_vfs_write(&((TnVfs*)vfs)->disk, file->onDisk, source, size, written);
}

static ma_result vfs_seek(ma_vfs* vfs, ma_vfs_file handle, ma_int64 offset, ma_seek_origin origin) {
    TnVfsFile* file = (TnVfsFile*)handle;
    if (file->data == NULL) return ma_vfs_seek(&((TnVfs*)vfs)->disk, file->onDisk, offset, origin);
    ma_int64 target = origin == ma_seek_origin_start ? offset : (origin == ma_seek_origin_end ? (ma_int64)file->size + offset : (ma_int64)file->cursor + offset);
    if (target < 0 || target > (ma_int64)file->size) return MA_BAD_SEEK;
    file->cursor = (size_t)target;
    return MA_SUCCESS;
}

static ma_result vfs_tell(ma_vfs* vfs, ma_vfs_file handle, ma_int64* cursor) {
    TnVfsFile* file = (TnVfsFile*)handle;
    if (file->data == NULL) return ma_vfs_tell(&((TnVfs*)vfs)->disk, file->onDisk, cursor);
    *cursor = (ma_int64)file->cursor;
    return MA_SUCCESS;
}

static ma_result vfs_info(ma_vfs* vfs, ma_vfs_file handle, ma_file_info* info) {
    TnVfsFile* file = (TnVfsFile*)handle;
    if (file->data == NULL) return ma_vfs_info(&((TnVfs*)vfs)->disk, file->onDisk, info);
    info->sizeInBytes = file->size;
    return MA_SUCCESS;
}

int tn_audio_init(int noDevice, unsigned int sampleRate) {
    if (ready) return 1;
    ma_engine_config config = ma_engine_config_init();
    ma_default_vfs_init(&packVfs.disk, NULL);
    packVfs.callbacks.onOpen = vfs_open;
    packVfs.callbacks.onOpenW = vfs_open_w;
    packVfs.callbacks.onClose = vfs_close;
    packVfs.callbacks.onRead = vfs_read;
    packVfs.callbacks.onWrite = vfs_write;
    packVfs.callbacks.onSeek = vfs_seek;
    packVfs.callbacks.onTell = vfs_tell;
    packVfs.callbacks.onInfo = vfs_info;
    config.pResourceManagerVFS = &packVfs;
    config.periodSizeInFrames = TN_AUDIO_BLOCK;
    if (noDevice) {
        // No sound card: the caller pulls the mix itself (tests, dedicated servers that still want the timing).
        config.noDevice = MA_TRUE;
        config.channels = 2;
        config.sampleRate = sampleRate != 0 ? sampleRate : 48000;
    }
    if (ma_engine_init(&config, &engine) != MA_SUCCESS) return 0;
    for (int i = 0; i < TN_GROUP_COUNT; ++i)
        ma_sound_group_init(&engine, 0, NULL, &groups[i]);
    ma_reverb_node_config reverbConfig = ma_reverb_node_config_init(ma_engine_get_channels(&engine), ma_engine_get_sample_rate(&engine));
    reverbConfig.wetVolume = 1.0f;   // a send bus: sources decide how much of themselves goes in
    reverbConfig.dryVolume = 0.0f;
    hrtf_prepare(ma_engine_get_sample_rate(&engine));
    hasReverb = ma_reverb_node_init(ma_engine_get_node_graph(&engine), &reverbConfig, NULL, &reverb) == MA_SUCCESS;
    if (hasReverb)
        ma_node_attach_output_bus(&reverb, 0, ma_engine_get_endpoint(&engine), 0);
    ready = 1;
    return 1;
}

void tn_audio_shutdown(void) {
    if (!ready) return;
    tn_voice_capture_stop();
    if (hasReverb) ma_reverb_node_uninit(&reverb, NULL);
    for (int i = 0; i < TN_GROUP_COUNT; ++i) ma_sound_group_uninit(&groups[i]);
    ma_engine_uninit(&engine);
    ready = 0;
    hasReverb = 0;
}

int tn_audio_ready(void) { return ready; }

void tn_audio_listener(const float* position, const float* forward, const float* up, const float* velocity) {
    if (!ready) return;
    ma_engine_listener_set_position(&engine, 0, position[0], position[1], -position[2]);
    ma_engine_listener_set_direction(&engine, 0, forward[0], forward[1], -forward[2]);
    ma_engine_listener_set_world_up(&engine, 0, up[0], up[1], -up[2]);
    ma_engine_listener_set_velocity(&engine, 0, velocity[0], velocity[1], -velocity[2]);
}

void tn_audio_master_volume(float volume) { if (ready) ma_engine_set_volume(&engine, volume); }

void tn_audio_group_volume(int group, float volume) {
    if (ready && group >= 0 && group < TN_GROUP_COUNT) ma_sound_group_set_volume(&groups[group], volume);
}

void tn_audio_reverb(float roomSize, float damping, float width) {
    if (!ready || !hasReverb) return;
    verblib_set_room_size(&reverb.reverb, roomSize);
    verblib_set_damping(&reverb.reverb, damping);
    verblib_set_width(&reverb.reverb, width);
}

// enabled: binaural or plain panning. strength: 0 to 1, how much of the binaural sound is used. headSize: scales
// the delay between the ears (0.5 to 1.5; 1 is the measured head). trebleDb: brightens or dulls the binaural sound.
void tn_audio_hrtf(int enabled, float strength, float headSize, float trebleDb) {
    hrtfEnabled = enabled ? 1 : 0;
    hrtfStrength = strength < 0 ? 0 : (strength > 1 ? 1 : strength);
    hrtfHeadSize = headSize < 0.5f ? 0.5f : (headSize > 1.5f ? 1.5f : headSize);
    if (trebleDb < -12) trebleDb = -12;
    if (trebleDb > 12) trebleDb = 12;
    hrtfTrebleGain = powf(10.0f, trebleDb / 20.0f) - 1.0f;
}

// Signal path of a source: sound -> [HRTF or pan] -> [low-pass] -> [splitter] -> its mixer group
//                                                                             \-> reverb bus (by the send amount)
// The low-pass is in the path only while it cuts something (below 20 kHz), and the splitter only while some of the
// source goes to the reverb: every node in the path is worked through for every block, wanted or not.
// A positioned sound leaves miniaudio's spatializer in mono with distance, cone and Doppler applied; the HRTF node
// then decides what each ear hears. A sound that is not positioned skips that step and stays plain stereo.
// Puts the low-pass and the reverb splitter in the source's path or takes them out of it.
static void source_wire(TnAudioSource* source, int filtering, int sending) {
    sending = sending && hasReverb;
    if (filtering == source->filtering && sending == source->sending) return;
    source->filtering = filtering;
    source->sending = sending;
    ma_node* head = source->positioned ? (ma_node*)&source->hrtf : (ma_node*)&source->sound;
    ma_node* tail = head;
    if (filtering) {
        ma_node_attach_output_bus(head, 0, &source->lowpass, 0);
        tail = &source->lowpass;
    } else
        ma_node_detach_output_bus(&source->lowpass, 0);
    if (sending) {
        ma_node_attach_output_bus(tail, 0, &source->split, 0);
        ma_node_attach_output_bus(&source->split, 0, &groups[source->group], 0);
        ma_node_attach_output_bus(&source->split, 1, &reverb, 0);
    } else {
        ma_node_detach_output_bus(&source->split, 0);
        ma_node_detach_output_bus(&source->split, 1);
        ma_node_attach_output_bus(tail, 0, &groups[source->group], 0);
    }
}

static TnAudioSource* source_create(const char* path, ma_data_source* data, int group, int stream, int positioned) {
    if (!ready) return NULL;
    TnAudioSource* source = (TnAudioSource*)ma_malloc(sizeof(TnAudioSource), NULL);
    if (source == NULL) return NULL;
    memset(source, 0, sizeof(*source));
    ma_sound_config soundConfig = ma_sound_config_init_2(&engine);
    if (data != NULL) soundConfig.pDataSource = data; else soundConfig.pFilePath = path;
    soundConfig.flags = MA_SOUND_FLAG_NO_DEFAULT_ATTACHMENT | (positioned ? 0 : MA_SOUND_FLAG_NO_SPATIALIZATION);
    if (data == NULL) soundConfig.flags |= stream ? MA_SOUND_FLAG_STREAM : MA_SOUND_FLAG_DECODE;
    if (positioned) soundConfig.channelsOut = 1;
    if (ma_sound_init_ex(&engine, &soundConfig, &source->sound) != MA_SUCCESS) {
        ma_free(source, NULL);
        return NULL;
    }
    source->positioned = positioned;
    ma_node_graph* graph = ma_engine_get_node_graph(&engine);
    if (positioned) {
        ma_uint32 inputChannels[1] = {1}, outputChannels[1] = {2};
        ma_node_config nodeConfig = ma_node_config_init();
        nodeConfig.vtable = &hrtfVtable;
        nodeConfig.pInputChannels = inputChannels;
        nodeConfig.pOutputChannels = outputChannels;
        if (ma_node_init(graph, &nodeConfig, NULL, &source->hrtf) != MA_SUCCESS) {
            ma_sound_uninit(&source->sound);
            ma_free(source, NULL);
            return NULL;
        }
        // Direction is this node's job. Left on, miniaudio would also turn the mono signal down according to
        // which side the source is on, making one side quieter than the other.
        ma_sound_set_directional_attenuation_factor(&source->sound, 0.0f);
        hrtf_aim(&source->hrtf, 0, 0);
        source->hrtf.current = source->hrtf.target;
        source->hrtf.currentDelayLeft = source->hrtf.targetDelayLeft;
        source->hrtf.currentDelayRight = source->hrtf.targetDelayRight;
        source->hrtf.currentPanLeft = source->hrtf.panLeft;
        source->hrtf.currentPanRight = source->hrtf.panRight;
    }
    const ma_uint32 channels = ma_engine_get_channels(&engine);
    const ma_uint32 sampleRate = ma_engine_get_sample_rate(&engine);
    source->cutoff = 22000.0f;
    ma_lpf_node_config lowpass = ma_lpf_node_config_init(channels, sampleRate, source->cutoff, 2);
    ma_splitter_node_config split = ma_splitter_node_config_init(channels);
    if (ma_lpf_node_init(graph, &lowpass, NULL, &source->lowpass) != MA_SUCCESS) {
        if (positioned) ma_node_uninit(&source->hrtf, NULL);
        ma_sound_uninit(&source->sound);
        ma_free(source, NULL);
        return NULL;
    }
    if (ma_splitter_node_init(graph, &split, NULL, &source->split) != MA_SUCCESS) {
        ma_lpf_node_uninit(&source->lowpass, NULL);
        if (positioned) ma_node_uninit(&source->hrtf, NULL);
        ma_sound_uninit(&source->sound);
        ma_free(source, NULL);
        return NULL;
    }
    if (group < 0 || group >= TN_GROUP_COUNT) group = 0;
    source->group = group;
    if (positioned) ma_node_attach_output_bus(&source->sound, 0, &source->hrtf, 0);
    ma_node_set_output_bus_volume(&source->split, 1, 0.0f);
    source->filtering = source->sending = -1;
    source_wire(source, 0, 0);
    return source;
}

TnAudioSource* tn_audio_source_create(const char* path, int group, int stream, int positioned) {
    return source_create(path, NULL, group, stream, positioned);
}

// ---- Voice ----
// Speech arrives over the network a 20 ms frame at a time and is played through an ordinary source, so a voice can
// be positioned, occluded and sent to reverb like any other sound. The stream holds a short queue to ride out
// uneven arrival: it waits for 60 ms before starting, and if the queue grows past 300 ms it skips ahead rather
// than let the conversation fall behind.

#define TN_VOICE_RATE 48000
#define TN_VOICE_FRAME 960          // 20 ms
#define TN_VOICE_RING 65536
#define TN_VOICE_PREBUFFER 2880     // 60 ms
#define TN_VOICE_MAX_LAG 14400      // 300 ms

typedef struct TnVoiceStream {
    ma_data_source_base base;
    float ring[TN_VOICE_RING];
    volatile unsigned int write, read;   // written by the game thread, read by the audio thread
    int buffering;
} TnVoiceStream;

static ma_result voice_read(ma_data_source* pDataSource, void* pFramesOut, ma_uint64 frameCount, ma_uint64* pFramesRead) {
    TnVoiceStream* stream = (TnVoiceStream*)pDataSource;
    float* out = (float*)pFramesOut;
    unsigned int available = stream->write - stream->read;
    if (available > TN_VOICE_MAX_LAG) {
        stream->read += available - TN_VOICE_PREBUFFER;
        available = TN_VOICE_PREBUFFER;
    }
    if (stream->buffering && available >= TN_VOICE_PREBUFFER) stream->buffering = 0;
    ma_uint64 taken = 0;
    if (!stream->buffering) {
        taken = available < frameCount ? available : frameCount;
        unsigned int read = stream->read;
        if (out != NULL)
            for (ma_uint64 i = 0; i < taken; ++i) out[i] = stream->ring[(read + i) & (TN_VOICE_RING - 1)];
        stream->read = read + (unsigned int)taken;
        if (taken < frameCount) stream->buffering = 1;   // ran dry: gather a little before speaking again
    }
    if (out != NULL)
        for (ma_uint64 i = taken; i < frameCount; ++i) out[i] = 0.0f;
    if (pFramesRead != NULL) *pFramesRead = frameCount;
    return MA_SUCCESS;
}

static ma_result voice_seek(ma_data_source* pDataSource, ma_uint64 frameIndex) { (void)pDataSource; (void)frameIndex; return MA_SUCCESS; }

static ma_result voice_format(ma_data_source* pDataSource, ma_format* pFormat, ma_uint32* pChannels, ma_uint32* pSampleRate, ma_channel* pChannelMap, size_t channelMapCap) {
    (void)pDataSource;
    if (pFormat != NULL) *pFormat = ma_format_f32;
    if (pChannels != NULL) *pChannels = 1;
    if (pSampleRate != NULL) *pSampleRate = TN_VOICE_RATE;
    if (pChannelMap != NULL && channelMapCap > 0) pChannelMap[0] = MA_CHANNEL_MONO;
    return MA_SUCCESS;
}

static ma_data_source_vtable voiceVtable = { voice_read, voice_seek, voice_format, NULL, NULL, NULL, 0 };

// A source that plays whatever is pushed to it. Use the ordinary tn_audio_source_* calls on the result.
TnAudioSource* tn_audio_stream_create(int group, int positioned) {
    if (!ready) return NULL;
    TnVoiceStream* stream = (TnVoiceStream*)ma_malloc(sizeof(TnVoiceStream), NULL);
    if (stream == NULL) return NULL;
    memset(stream, 0, sizeof(*stream));
    stream->buffering = 1;
    ma_data_source_config config = ma_data_source_config_init();
    config.vtable = &voiceVtable;
    if (ma_data_source_init(&config, &stream->base) != MA_SUCCESS) { ma_free(stream, NULL); return NULL; }
    TnAudioSource* source = source_create(NULL, &stream->base, group, 0, positioned);
    if (source == NULL) { ma_data_source_uninit(&stream->base); ma_free(stream, NULL); return NULL; }
    source->voice = stream;
    return source;
}

// Mono samples at 48 kHz. Returns how many were taken; the rest are dropped if the queue is full.
int tn_audio_stream_push(TnAudioSource* source, const float* samples, int count) {
    if (source == NULL || source->voice == NULL || samples == NULL || count <= 0) return 0;
    TnVoiceStream* stream = source->voice;
    unsigned int write = stream->write;
    const unsigned int room = TN_VOICE_RING - (write - stream->read);
    if ((unsigned int)count > room) count = (int)room;
    for (int i = 0; i < count; ++i) stream->ring[(write + i) & (TN_VOICE_RING - 1)] = samples[i];
    stream->write = write + (unsigned int)count;
    return count;
}

int tn_audio_stream_queued(TnAudioSource* source) {
    return source != NULL && source->voice != NULL ? (int)(source->voice->write - source->voice->read) : 0;
}

// The Opus codec: 20 ms mono frames at 48 kHz, tuned for speech, with enough redundancy to cover a lost packet.
void* tn_voice_encoder_create(int bitsPerSecond) {
    int error = 0;
    OpusEncoder* encoder = opus_encoder_create(TN_VOICE_RATE, 1, OPUS_APPLICATION_VOIP, &error);
    if (encoder == NULL || error != OPUS_OK) return NULL;
    opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitsPerSecond));
    opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(10));
    return encoder;
}
void tn_voice_encoder_destroy(void* encoder) { if (encoder != NULL) opus_encoder_destroy((OpusEncoder*)encoder); }
void tn_voice_encoder_bitrate(void* encoder, int bitsPerSecond) { if (encoder != NULL) opus_encoder_ctl((OpusEncoder*)encoder, OPUS_SET_BITRATE(bitsPerSecond)); }
// Takes one frame (960 samples). Returns the size of the packet, or a negative number on failure.
int tn_voice_encode(void* encoder, const float* samples, unsigned char* out, int capacity) {
    if (encoder == NULL) return -1;
    return opus_encode_float((OpusEncoder*)encoder, samples, TN_VOICE_FRAME, out, capacity);
}
void* tn_voice_decoder_create(void) {
    int error = 0;
    OpusDecoder* decoder = opus_decoder_create(TN_VOICE_RATE, 1, &error);
    return decoder != NULL && error == OPUS_OK ? decoder : NULL;
}
void tn_voice_decoder_destroy(void* decoder) { if (decoder != NULL) opus_decoder_destroy((OpusDecoder*)decoder); }
// Writes one frame (960 samples). A null packet fills in for one that never arrived; recover = 1 rebuilds the frame
// before this packet from the redundancy this packet carries. Returns the samples written, or negative.
int tn_voice_decode(void* decoder, const unsigned char* packet, int length, float* out, int recover) {
    if (decoder == NULL) return -1;
    return opus_decode_float((OpusDecoder*)decoder, packet, packet != NULL ? length : 0, out, TN_VOICE_FRAME, recover);
}

// The microphone. Its samples wait in a queue for the game to collect once a frame.
static ma_device captureDevice;
static int capturing = 0;
static float captureRing[TN_VOICE_RING];
static volatile unsigned int captureWrite, captureRead;

static void capture_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    (void)pDevice; (void)pOutput;
    const float* input = (const float*)pInput;
    if (input == NULL) return;
    unsigned int write = captureWrite;
    const unsigned int room = TN_VOICE_RING - (write - captureRead);
    if (frameCount > room) frameCount = room;
    for (ma_uint32 i = 0; i < frameCount; ++i) captureRing[(write + i) & (TN_VOICE_RING - 1)] = input[i];
    captureWrite = write + frameCount;
}

int tn_voice_capture_start(void) {
    if (capturing) return 1;
    ma_device_config config = ma_device_config_init(ma_device_type_capture);
    config.capture.format = ma_format_f32;
    config.capture.channels = 1;
    config.sampleRate = TN_VOICE_RATE;
    config.dataCallback = capture_callback;
    captureWrite = captureRead = 0;
    if (ma_device_init(NULL, &config, &captureDevice) != MA_SUCCESS) return 0;
    if (ma_device_start(&captureDevice) != MA_SUCCESS) { ma_device_uninit(&captureDevice); return 0; }
    capturing = 1;
    return 1;
}
void tn_voice_capture_stop(void) {
    if (!capturing) return;
    ma_device_uninit(&captureDevice);
    capturing = 0;
}
int tn_voice_capturing(void) { return capturing; }
// Fills out with exactly count samples and returns 1, or returns 0 when that many have not been recorded yet.
int tn_voice_capture_read(float* out, int count) {
    if (!capturing || count <= 0) return 0;
    unsigned int read = captureRead;
    if (captureWrite - read < (unsigned int)count) return 0;
    for (int i = 0; i < count; ++i) out[i] = captureRing[(read + i) & (TN_VOICE_RING - 1)];
    captureRead = read + (unsigned int)count;
    return 1;
}
// How many microphones the system offers, without opening any of them.
int tn_voice_capture_devices(void) {
    ma_context context;
    if (ma_context_init(NULL, 0, NULL, &context) != MA_SUCCESS) return 0;
    ma_device_info* playback; ma_device_info* capture; ma_uint32 playbackCount = 0, captureCount = 0;
    if (ma_context_get_devices(&context, &playback, &playbackCount, &capture, &captureCount) != MA_SUCCESS) captureCount = 0;
    ma_context_uninit(&context);
    return (int)captureCount;
}

void tn_audio_source_destroy(TnAudioSource* source) {
    if (source == NULL) return;
    if (ready) {
        ma_sound_uninit(&source->sound);
        ma_splitter_node_uninit(&source->split, NULL);
        ma_lpf_node_uninit(&source->lowpass, NULL);
        if (source->positioned) ma_node_uninit(&source->hrtf, NULL);
    }
    if (source->voice != NULL) {
        ma_data_source_uninit(&source->voice->base);
        ma_free(source->voice, NULL);
    }
    ma_free(source, NULL);
}

void tn_audio_source_set(TnAudioSource* source, const TnAudioParams* p) {
    if (!ready || source == NULL) return;
    ma_sound* sound = &source->sound;
    ma_sound_set_spatialization_enabled(sound, source->positioned ? MA_TRUE : MA_FALSE);
    ma_sound_set_position(sound, p->position[0], p->position[1], -p->position[2]);
    ma_sound_set_velocity(sound, p->velocity[0], p->velocity[1], -p->velocity[2]);
    ma_sound_set_direction(sound, p->direction[0], p->direction[1], -p->direction[2]);
    ma_sound_set_volume(sound, p->volume);
    ma_sound_set_pitch(sound, p->pitch);
    // At pitch 1 with no Doppler, a sound recorded at the mixer's rate needs no resampling: miniaudio would run its
    // resampler anyway (a third of a source's mixing), so it is switched off until the pitch moves.
    ma_uint32 rate = 0;
    ma_sound_get_data_format(sound, NULL, NULL, &rate, NULL, 0);
    const int bypass = p->pitch == 1.0f && (p->doppler == 0.0f || !source->positioned) && rate == ma_engine_get_sample_rate(&engine);
    ma_engine_node* node = &sound->engineNode;
    if (bypass != (int)ma_atomic_load_32(&node->isPitchDisabled)) {
        if (!bypass) ma_linear_resampler_reset(&node->resampler);
        ma_atomic_exchange_32(&node->isPitchDisabled, bypass ? MA_TRUE : MA_FALSE);
    }
    ma_sound_set_min_distance(sound, p->minDistance);
    ma_sound_set_max_distance(sound, p->maxDistance);
    ma_sound_set_rolloff(sound, p->rolloff);
    ma_sound_set_attenuation_model(sound, (ma_attenuation_model)p->rolloffModel);
    ma_sound_set_doppler_factor(sound, p->doppler);
    ma_sound_set_cone(sound, p->coneInner, p->coneOuter, p->coneOuterGain);
    ma_sound_set_looping(sound, p->looping ? MA_TRUE : MA_FALSE);
    ma_node_set_output_bus_volume(&source->split, 1, p->reverbSend);
    // Rebuilding the filter is not free, so only when the cutoff really moved.
    float cutoff = p->lowpassHz < 20.0f ? 20.0f : p->lowpassHz;
    float change = cutoff > source->cutoff ? cutoff / source->cutoff : source->cutoff / cutoff;
    if (change > 1.03f) {
        ma_lpf_config config = ma_lpf_config_init(ma_format_f32, ma_engine_get_channels(&engine), ma_engine_get_sample_rate(&engine), cutoff, 2);
        ma_lpf_node_reinit(&config, &source->lowpass);
        source->cutoff = cutoff;
    }
    source_wire(source, source->cutoff < 20000.0f, p->reverbSend > 0.0001f);
}

// Where the source is as the listener hears it, in radians: azimuth to the right of ahead, elevation upward.
void tn_audio_source_direction(TnAudioSource* source, float azimuth, float elevation) {
    if (ready && source != NULL && source->positioned) hrtf_aim(&source->hrtf, azimuth, elevation);
}

void tn_audio_source_play(TnAudioSource* source, int fromStart) {
    if (!ready || source == NULL) return;
    if (fromStart) ma_sound_seek_to_pcm_frame(&source->sound, 0);
    ma_sound_start(&source->sound);
}

void tn_audio_source_stop(TnAudioSource* source) {
    if (ready && source != NULL) ma_sound_stop(&source->sound);
}

int tn_audio_source_playing(TnAudioSource* source) {
    return ready && source != NULL && ma_sound_is_playing(&source->sound);
}

int tn_audio_source_finished(TnAudioSource* source) {
    return !ready || source == NULL || ma_sound_at_end(&source->sound);
}

float tn_audio_source_length(TnAudioSource* source) {
    float seconds = 0;
    if (ready && source != NULL) ma_sound_get_length_in_seconds(&source->sound, &seconds);
    return seconds;
}

float tn_audio_source_time(TnAudioSource* source) {
    float seconds = 0;
    if (ready && source != NULL) ma_sound_get_cursor_in_seconds(&source->sound, &seconds);
    return seconds;
}

void tn_audio_source_seek(TnAudioSource* source, float seconds) {
    if (!ready || source == NULL) return;
    if (seconds < 0) seconds = 0;
    ma_sound_seek_to_pcm_frame(&source->sound, (ma_uint64)(seconds * ma_engine_get_sample_rate(&engine)));
}

// With no device, renders the next frames of the mix into an interleaved stereo buffer. Returns frames written.
unsigned int tn_audio_read(float* out, unsigned int frames) {
    if (!ready) return 0;
    // In 10 ms blocks, as a sound card asks for it. Voices fed from the network lost part of themselves when a
    // much larger block was pulled in one go, so the mix is never asked for more than this at once.
    unsigned int done = 0;
    while (done < frames) {
        const unsigned int want = frames - done < TN_AUDIO_BLOCK ? frames - done : TN_AUDIO_BLOCK;
        ma_uint64 read = 0;
        if (ma_engine_read_pcm_frames(&engine, out + (size_t)done * 2, want, &read) != MA_SUCCESS || read == 0) break;
        done += (unsigned int)read;
    }
    return done;
}

unsigned int tn_audio_sample_rate(void) { return ready ? ma_engine_get_sample_rate(&engine) : 0; }
