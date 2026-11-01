// Tallow asset decoding: images through stb_image, models through cgltf.
// The glTF loader flattens a file into world-space-ready primitives so the engine side
// only deals with plain vertex/index arrays.

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO_WARNINGS
#include "stb_image.h"

#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "tallow_pack.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#endif

// ---- memory files ----
// Files the engine holds in memory (a mounted map's own models and pictures), found before a pack's or a loose file
// of the same full path. Paths are kept with forward slashes. Loading threads read while the main thread adds.

typedef struct tn_memory_file { char* path; void* data; size_t size; struct tn_memory_file* next; } tn_memory_file;
static tn_memory_file* memoryFiles;
#ifdef _WIN32
static SRWLOCK memoryLock = SRWLOCK_INIT;
#define MEMORY_LOCK() AcquireSRWLockExclusive(&memoryLock)
#define MEMORY_UNLOCK() ReleaseSRWLockExclusive(&memoryLock)
#else
static pthread_mutex_t memoryLock = PTHREAD_MUTEX_INITIALIZER;
#define MEMORY_LOCK() pthread_mutex_lock(&memoryLock)
#define MEMORY_UNLOCK() pthread_mutex_unlock(&memoryLock)
#endif

static void memory_key(const char* path, char* key, size_t capacity)
{
	size_t length = 0;
	for (const char* c = path; *c != 0 && length + 1 < capacity; c++)
	{
		char ch = *c == '\\' ? '/' : *c;
		if (ch == '/' && length > 0 && key[length - 1] == '/') continue;
		key[length++] = ch;
	}
	key[length] = 0;
}

static void memory_remove_locked(const char* key)
{
	for (tn_memory_file** link = &memoryFiles; *link != NULL; link = &(*link)->next)
	{
		if (strcmp((*link)->path, key) == 0)
		{
			tn_memory_file* gone = *link;
			*link = gone->next;
			free(gone->path);
			free(gone->data);
			free(gone);
			return;
		}
	}
}

void tn_memory_file_add(const char* path, const void* data, size_t size)
{
	char key[1024];
	memory_key(path, key, sizeof(key));
	tn_memory_file* file = (tn_memory_file*)calloc(1, sizeof(tn_memory_file));
	size_t keyLength = strlen(key) + 1;
	file->path = (char*)malloc(keyLength);
	memcpy(file->path, key, keyLength);
	file->data = malloc(size > 0 ? size : 1);
	if (size > 0) memcpy(file->data, data, size);
	file->size = size;
	MEMORY_LOCK();
	memory_remove_locked(key);
	file->next = memoryFiles;
	memoryFiles = file;
	MEMORY_UNLOCK();
}

// Forgets every memory file inside a folder (a full path).
void tn_memory_file_remove_folder(const char* folder)
{
	char key[1024];
	memory_key(folder, key, sizeof(key) - 1);
	size_t length = strlen(key);
	while (length > 0 && key[length - 1] == '/') key[--length] = 0;
	key[length++] = '/';
	key[length] = 0;
	MEMORY_LOCK();
	for (tn_memory_file** link = &memoryFiles; *link != NULL;)
	{
		if (strncmp((*link)->path, key, length) == 0)
		{
			tn_memory_file* gone = *link;
			*link = gone->next;
			free(gone->path);
			free(gone->data);
			free(gone);
		}
		else
			link = &(*link)->next;
	}
	MEMORY_UNLOCK();
}

// A malloc'd copy of a memory file, or NULL.
static void* memory_read(const char* path, size_t* size)
{
	if (memoryFiles == NULL) return NULL;
	char key[1024];
	memory_key(path, key, sizeof(key));
	void* copy = NULL;
	MEMORY_LOCK();
	for (tn_memory_file* file = memoryFiles; file != NULL; file = file->next)
	{
		if (strcmp(file->path, key) == 0)
		{
			copy = malloc(file->size > 0 ? file->size : 1);
			if (file->size > 0) memcpy(copy, file->data, file->size);
			*size = file->size;
			break;
		}
	}
	MEMORY_UNLOCK();
	return copy;
}

// ---- images ----

unsigned char* tn_image_load(const char* path, int* width, int* height)
{
	int channels = 0;
	// From an asset pack when the file is in one, else from disk.
	size_t size = 0;
	void* packed = memory_read(path, &size);
	if (packed == NULL) packed = tn_pack_read(path, &size);
	if (packed != NULL)
	{
		unsigned char* pixels = stbi_load_from_memory((const stbi_uc*)packed, (int)size, width, height, &channels, 4);
		tn_pack_free(packed);
		return pixels;
	}
	return stbi_load(path, width, height, &channels, 4);
}

void tn_image_free(unsigned char* pixels)
{
	stbi_image_free(pixels);
}

// ---- mipmaps ----

// sRGB <-> linear light, for averaging colour the way the eye sees it (a black and white checker shrinks to mid grey,
// not to the darker grey averaging the stored numbers gives).
static float srgbToLinear[256];
static unsigned char linearToSrgb[4096];

static void prepare_srgb(void)
{
	static int ready = 0;
	if (ready) return;
	for (int i = 0; i < 256; i++)
	{
		float c = i / 255.0f;
		srgbToLinear[i] = c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
	}
	for (int i = 0; i < 4096; i++)
	{
		float l = i / 4095.0f;
		float c = l <= 0.0031308f ? l * 12.92f : 1.055f * powf(l, 1.0f / 2.4f) - 0.055f;
		int v = (int)(c * 255.0f + 0.5f);
		linearToSrgb[i] = (unsigned char)(v < 0 ? 0 : v > 255 ? 255 : v);
	}
	ready = 1;
}

// Halves an RGBA8 image (each side to at least 1). kind: 0 colour (RGB averaged in linear light), 1 data (averaged
// as stored), 2 normal map (the vectors averaged and made unit length again).
static void downsample(const unsigned char* src, int width, int height, unsigned char* dst, int kind)
{
	int dw = width > 1 ? width / 2 : 1, dh = height > 1 ? height / 2 : 1;
	for (int y = 0; y < dh; y++)
	{
		int y0 = y * 2 < height ? y * 2 : height - 1, y1 = y * 2 + 1 < height ? y * 2 + 1 : y0;
		for (int x = 0; x < dw; x++)
		{
			int x0 = x * 2 < width ? x * 2 : width - 1, x1 = x * 2 + 1 < width ? x * 2 + 1 : x0;
			const unsigned char* p[4] = { src + (y0 * width + x0) * 4, src + (y0 * width + x1) * 4, src + (y1 * width + x0) * 4, src + (y1 * width + x1) * 4 };
			unsigned char* out = dst + (y * dw + x) * 4;
			out[3] = (unsigned char)((p[0][3] + p[1][3] + p[2][3] + p[3][3] + 2) / 4);
			if (kind == 0)
			{
				for (int c = 0; c < 3; c++)
				{
					float l = (srgbToLinear[p[0][c]] + srgbToLinear[p[1][c]] + srgbToLinear[p[2][c]] + srgbToLinear[p[3][c]]) * 0.25f;
					out[c] = linearToSrgb[(int)(l * 4095.0f + 0.5f)];
				}
			}
			else if (kind == 2)
			{
				float v[3] = { 0, 0, 0 };
				for (int k = 0; k < 4; k++)
				{
					for (int c = 0; c < 3; c++) v[c] += p[k][c] / 127.5f - 1.0f;
				}
				float length = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
				if (length < 1e-6f) { v[0] = 0; v[1] = 0; v[2] = 1; length = 1; }
				for (int c = 0; c < 3; c++)
				{
					int q = (int)((v[c] / length + 1.0f) * 127.5f + 0.5f);
					out[c] = (unsigned char)(q < 0 ? 0 : q > 255 ? 255 : q);
				}
			}
			else
			{
				for (int c = 0; c < 3; c++) out[c] = (unsigned char)((p[0][c] + p[1][c] + p[2][c] + p[3][c] + 2) / 4);
			}
		}
	}
}

// The mip chain of an RGBA8 image, largest first, down to 1 x 1, leaving out the `skip` largest levels (never the
// last). All levels one after another in one allocation, as bgfx takes them; free with tn_image_mips_free. Gives the
// first level's size, the number of levels and the bytes in all.
unsigned char* tn_image_mips(const unsigned char* pixels, int width, int height, int kind, int skip, int* outWidth, int* outHeight, int* outLevels, unsigned* outSize)
{
	if (pixels == NULL || width <= 0 || height <= 0) return NULL;
	prepare_srgb();
	int levels = 1;
	for (int w = width, h = height; w > 1 || h > 1; levels++) { w = w > 1 ? w / 2 : 1; h = h > 1 ? h / 2 : 1; }
	if (skip < 0) skip = 0;
	if (skip > levels - 1) skip = levels - 1;
	// Every level from the full size, then the wanted ones are moved to the front.
	size_t total = 0;
	for (int i = 0, w = width, h = height; i < levels; i++) { total += (size_t)w * h * 4; w = w > 1 ? w / 2 : 1; h = h > 1 ? h / 2 : 1; }
	unsigned char* all = (unsigned char*)malloc(total);
	if (all == NULL) return NULL;
	memcpy(all, pixels, (size_t)width * height * 4);
	size_t offset = 0, kept = 0;
	int w = width, h = height;
	for (int i = 0; i < levels; i++)
	{
		size_t bytes = (size_t)w * h * 4;
		if (i + 1 < levels) downsample(all + offset, w, h, all + offset + bytes, kind);
		if (i == skip) { kept = offset; *outWidth = w; *outHeight = h; }
		offset += bytes;
		w = w > 1 ? w / 2 : 1; h = h > 1 ? h / 2 : 1;
	}
	if (kept > 0) memmove(all, all + kept, total - kept);
	*outLevels = levels - skip;
	*outSize = (unsigned)(total - kept);
	return all;
}

void tn_image_mips_free(unsigned char* mips)
{
	free(mips);
}

// ---- glTF ----

typedef struct tn_gltf_prim
{
	float* positions; // 3 per vertex
	float* normals;   // 3 per vertex, null when the file has none
	float* uvs;       // 2 per vertex, null when the file has none
	float* colors;    // 4 per vertex, null when the file has none
	uint32_t* indices;
	uint32_t vertexCount;
	uint32_t indexCount;
	float baseColor[4];
	float metallic;
	float roughness;
	float emissive[3];
	float world[16]; // column-major node transform
	char name[64];
	uint16_t* joints; // 4 per vertex, null unless the primitive is skinned
	float* weights;   // 4 per vertex
	// The primitive's whole material (added after the fields above, which older readers rely on).
	int32_t material;           // index of the file's material, -1 for none
	char materialName[64];
	int32_t baseColorImage;     // indices into the file's decoded images (tn_gltf_get_image), -1 for none
	int32_t metalRoughImage;
	int32_t normalImage;
	int32_t occlusionImage;
	int32_t emissiveImage;
	float normalScale;
	float occlusionStrength;
	int32_t alphaMode;          // 0 opaque, 1 cut out (mask), 2 blended
	float alphaCutoff;
	int32_t doubleSided;
	float* uv2s; // Owned, two floats per vertex when TEXCOORD_1 is present.
} tn_gltf_prim;

typedef struct tn_gltf_image
{
	unsigned char* pixels;      // RGBA, 4 bytes a pixel; null when it could not be read
	int32_t width;
	int32_t height;
} tn_gltf_image;

typedef struct tn_gltf_joint
{
	char name[64];
	int32_t parent;        // index into the joint list, -1 for a root
	float rest[10];        // translation 3, rotation 4 (xyzw), scale 3
	float inverseBind[16];
	float parentWorld[16]; // transform of whatever a root joint hangs from (the armature object)
} tn_gltf_joint;

typedef struct tn_gltf_anim
{
	char name[64];
	float duration;
	int32_t frames;  // sampled at 30 per second
	float* data;     // frames * jointCount * 10 floats, same layout as tn_gltf_joint.rest
} tn_gltf_anim;

typedef struct tn_gltf_scene
{
	tn_gltf_prim* prims;
	uint32_t primCount;
	tn_gltf_joint* joints;
	int32_t jointCount;
	tn_gltf_anim* anims;
	int32_t animCount;
	tn_gltf_image* images;
	int32_t imageCount;
} tn_gltf_scene;

static void tn_identity(float* m)
{
	memset(m, 0, sizeof(float) * 16);
	m[0] = m[5] = m[10] = m[15] = 1.0f;
}

static int tn_find_joint(const cgltf_skin* skin, const cgltf_node* node)
{
	for (cgltf_size i = 0; i < skin->joints_count; i++)
	{
		if (skin->joints[i] == node) return (int)i;
	}
	return -1;
}

// Samples one animation channel at a time into out (3 or 4 floats).
static void tn_sample_channel(const cgltf_animation_sampler* sampler, float time, int components, float* out)
{
	const cgltf_size count = sampler->input->count;
	const int cubic = sampler->interpolation == cgltf_interpolation_type_cubic_spline;
	cgltf_size k = 0;
	float t0 = 0.0f, t1 = 0.0f;
	for (cgltf_size i = 0; i < count; i++)
	{
		float t = 0.0f;
		cgltf_accessor_read_float(sampler->input, i, &t, 1);
		if (t > time) break;
		k = i;
		t0 = t;
	}
	// Cubic spline outputs store in-tangent, value, out-tangent per key; the value is enough here.
	float a[4] = { 0, 0, 0, 1 }, b[4] = { 0, 0, 0, 1 };
	cgltf_accessor_read_float(sampler->output, cubic ? k * 3 + 1 : k, a, (cgltf_size)components);
	if (k + 1 >= count || sampler->interpolation == cgltf_interpolation_type_step)
	{
		memcpy(out, a, sizeof(float) * (size_t)components);
		return;
	}
	cgltf_accessor_read_float(sampler->input, k + 1, &t1, 1);
	cgltf_accessor_read_float(sampler->output, cubic ? (k + 1) * 3 + 1 : k + 1, b, (cgltf_size)components);
	float f = t1 > t0 ? (time - t0) / (t1 - t0) : 0.0f;
	if (f < 0.0f) f = 0.0f;
	if (f > 1.0f) f = 1.0f;
	if (components == 4)
	{
		// Shortest-path blend of rotations, renormalised.
		float dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
		float sign = dot < 0.0f ? -1.0f : 1.0f;
		float len = 0.0f;
		for (int i = 0; i < 4; i++) { out[i] = a[i] + (b[i] * sign - a[i]) * f; len += out[i] * out[i]; }
		len = len > 0.0f ? 1.0f / (float)sqrt(len) : 1.0f;
		for (int i = 0; i < 4; i++) out[i] *= len;
	}
	else
	{
		for (int i = 0; i < components; i++) out[i] = a[i] + (b[i] - a[i]) * f;
	}
}

static void tn_load_skin(tn_gltf_scene* scene, const cgltf_data* data)
{
	if (data->skins_count == 0) return;
	const cgltf_skin* skin = &data->skins[0];
	scene->jointCount = (int32_t)skin->joints_count;
	scene->joints = (tn_gltf_joint*)calloc((size_t)scene->jointCount, sizeof(tn_gltf_joint));
	for (int j = 0; j < scene->jointCount; j++)
	{
		const cgltf_node* node = skin->joints[j];
		tn_gltf_joint* joint = &scene->joints[j];
		strncpy(joint->name, node->name != NULL ? node->name : "Bone", sizeof(joint->name) - 1);
		joint->parent = node->parent != NULL ? tn_find_joint(skin, node->parent) : -1;
		float rest[10] = { 0, 0, 0, 0, 0, 0, 1, 1, 1, 1 };
		if (node->has_translation) memcpy(rest, node->translation, sizeof(float) * 3);
		if (node->has_rotation) memcpy(rest + 3, node->rotation, sizeof(float) * 4);
		if (node->has_scale) memcpy(rest + 7, node->scale, sizeof(float) * 3);
		memcpy(joint->rest, rest, sizeof(rest));
		tn_identity(joint->inverseBind);
		if (skin->inverse_bind_matrices != NULL)
			cgltf_accessor_read_float(skin->inverse_bind_matrices, (cgltf_size)j, joint->inverseBind, 16);
		tn_identity(joint->parentWorld);
		if (joint->parent < 0 && node->parent != NULL)
			cgltf_node_transform_world(node->parent, joint->parentWorld);
	}

	scene->animCount = (int32_t)data->animations_count;
	scene->anims = (tn_gltf_anim*)calloc(scene->animCount > 0 ? (size_t)scene->animCount : 1, sizeof(tn_gltf_anim));
	for (int a = 0; a < scene->animCount; a++)
	{
		const cgltf_animation* source = &data->animations[a];
		tn_gltf_anim* anim = &scene->anims[a];
		strncpy(anim->name, source->name != NULL ? source->name : "Animation", sizeof(anim->name) - 1);
		float duration = 0.0f;
		for (cgltf_size c = 0; c < source->channels_count; c++)
		{
			const cgltf_accessor* input = source->channels[c].sampler->input;
			float last = 0.0f;
			if (input->count > 0) cgltf_accessor_read_float(input, input->count - 1, &last, 1);
			if (last > duration) duration = last;
		}
		anim->duration = duration > 0.0f ? duration : 0.001f;
		anim->frames = (int32_t)(anim->duration * 30.0f) + 2;
		const size_t stride = (size_t)scene->jointCount * 10;
		anim->data = (float*)malloc(sizeof(float) * stride * (size_t)anim->frames);
		for (int f = 0; f < anim->frames; f++)
		{
			float* frame = anim->data + stride * (size_t)f;
			for (int j = 0; j < scene->jointCount; j++) memcpy(frame + j * 10, scene->joints[j].rest, sizeof(float) * 10);
			float time = (float)f / 30.0f;
			if (time > anim->duration) time = anim->duration;
			for (cgltf_size c = 0; c < source->channels_count; c++)
			{
				const cgltf_animation_channel* channel = &source->channels[c];
				int j = channel->target_node != NULL ? tn_find_joint(skin, channel->target_node) : -1;
				if (j < 0) continue;
				if (channel->target_path == cgltf_animation_path_type_translation) tn_sample_channel(channel->sampler, time, 3, frame + j * 10);
				else if (channel->target_path == cgltf_animation_path_type_rotation) tn_sample_channel(channel->sampler, time, 4, frame + j * 10 + 3);
				else if (channel->target_path == cgltf_animation_path_type_scale) tn_sample_channel(channel->sampler, time, 3, frame + j * 10 + 7);
			}
		}
	}
}

static float* tn_read_floats(const cgltf_accessor* accessor, int components)
{
	float* out = (float*)malloc(sizeof(float) * (size_t)components * accessor->count);
	for (cgltf_size i = 0; i < accessor->count; i++)
	{
		float value[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
		cgltf_accessor_read_float(accessor, i, value, 4);
		memcpy(out + i * (size_t)components, value, sizeof(float) * (size_t)components);
	}
	return out;
}

// cgltf reads the model, and any buffer or image files it names, through these: from an asset pack when the file
// is in one, else from disk.
static cgltf_result pack_or_file_read(const struct cgltf_memory_options* memory, const struct cgltf_file_options* file, const char* path, cgltf_size* size, void** data)
{
	size_t length = 0;
	void* packed = memory_read(path, &length);
	if (packed == NULL) packed = tn_pack_read(path, &length);
	if (packed != NULL)
	{
		*size = (cgltf_size)length;
		*data = packed;
		return cgltf_result_success;
	}
	if (tn_pack_exists(path)) return cgltf_result_io_error;   // in a pack, but damaged
	FILE* handle = fopen(path, "rb");
	if (handle == NULL) return cgltf_result_file_not_found;
	fseek(handle, 0, SEEK_END);
	long total = ftell(handle);
	fseek(handle, 0, SEEK_SET);
	void* bytes = total >= 0 ? malloc((size_t)total + 1) : NULL;
	if (bytes == NULL || fread(bytes, 1, (size_t)total, handle) != (size_t)total)
	{
		free(bytes);
		fclose(handle);
		return cgltf_result_io_error;
	}
	fclose(handle);
	*size = (cgltf_size)total;
	*data = bytes;
	return cgltf_result_success;
}

static void pack_or_file_release(const struct cgltf_memory_options* memory, const struct cgltf_file_options* file, void* data, cgltf_size size)
{
	free(data);
}

// Every image the file has, decoded to RGBA: from the binary chunk (a .glb), a data: address, or a file beside the model.
static void tn_load_images(tn_gltf_scene* scene, const cgltf_data* data, const cgltf_options* options, const char* modelPath)
{
	scene->imageCount = (int32_t)data->images_count;
	scene->images = (tn_gltf_image*)calloc(data->images_count > 0 ? data->images_count : 1, sizeof(tn_gltf_image));
	for (cgltf_size i = 0; i < data->images_count; i++)
	{
		const cgltf_image* image = &data->images[i];
		const unsigned char* bytes = NULL;
		size_t size = 0;
		void* owned = NULL;
		if (image->buffer_view != NULL && image->buffer_view->buffer->data != NULL)
		{
			bytes = (const unsigned char*)image->buffer_view->buffer->data + image->buffer_view->offset;
			size = image->buffer_view->size;
		}
		else if (image->uri != NULL && strncmp(image->uri, "data:", 5) == 0)
		{
			const char* comma = strchr(image->uri, ',');
			if (comma != NULL && comma - image->uri >= 7 && strncmp(comma - 7, ";base64", 7) == 0)
			{
				size_t length = strlen(comma + 1);
				while (length > 0 && comma[length] == '=') length--;   // padding carries no bytes
				size_t decoded = length * 3 / 4;
				if (cgltf_load_buffer_base64(options, decoded, comma + 1, &owned) == cgltf_result_success)
				{
					bytes = (const unsigned char*)owned;
					size = decoded;
				}
			}
		}
		else if (image->uri != NULL)
		{
			// A file named relative to the model.
			char path[1024];
			const char* slash = strrchr(modelPath, '/');
			const char* backslash = strrchr(modelPath, '\\');
			if (backslash != NULL && (slash == NULL || backslash > slash)) slash = backslash;
			size_t folder = slash != NULL ? (size_t)(slash - modelPath + 1) : 0;
			if (folder + strlen(image->uri) < sizeof(path))
			{
				memcpy(path, modelPath, folder);
				strcpy(path + folder, image->uri);
				cgltf_decode_uri(path + folder);
				cgltf_size length = 0;
				if (pack_or_file_read(NULL, NULL, path, &length, &owned) == cgltf_result_success)
				{
					bytes = (const unsigned char*)owned;
					size = (size_t)length;
				}
			}
		}
		if (bytes != NULL && size > 0)
		{
			int width = 0, height = 0, channels = 0;
			scene->images[i].pixels = stbi_load_from_memory(bytes, (int)size, &width, &height, &channels, 4);
			scene->images[i].width = width;
			scene->images[i].height = height;
		}
		free(owned);
	}
}

static int32_t tn_image_index(const cgltf_data* data, const cgltf_texture_view* view)
{
	if (view == NULL || view->texture == NULL || view->texture->image == NULL) return -1;
	return (int32_t)(view->texture->image - data->images);
}

tn_gltf_scene* tn_gltf_load(const char* path)
{
	cgltf_options options;
	memset(&options, 0, sizeof(options));
	options.file.read = pack_or_file_read;
	options.file.release = pack_or_file_release;
	cgltf_data* data = NULL;
	if (cgltf_parse_file(&options, path, &data) != cgltf_result_success) return NULL;
	if (cgltf_load_buffers(&options, data, path) != cgltf_result_success)
	{
		cgltf_free(data);
		return NULL;
	}

	uint32_t total = 0;
	for (cgltf_size n = 0; n < data->nodes_count; n++)
	{
		if (data->nodes[n].mesh != NULL) total += (uint32_t)data->nodes[n].mesh->primitives_count;
	}

	tn_gltf_scene* scene = (tn_gltf_scene*)calloc(1, sizeof(tn_gltf_scene));
	scene->prims = (tn_gltf_prim*)calloc(total > 0 ? total : 1, sizeof(tn_gltf_prim));

	for (cgltf_size n = 0; n < data->nodes_count; n++)
	{
		const cgltf_node* node = &data->nodes[n];
		if (node->mesh == NULL) continue;
		for (cgltf_size p = 0; p < node->mesh->primitives_count; p++)
		{
			const cgltf_primitive* src = &node->mesh->primitives[p];
			if (src->type != cgltf_primitive_type_triangles) continue;

			const cgltf_accessor* position = NULL;
			const cgltf_accessor* normal = NULL;
			const cgltf_accessor* uv = NULL;
			const cgltf_accessor* uv2 = NULL;
			const cgltf_accessor* color = NULL;
			const cgltf_accessor* joints = NULL;
			const cgltf_accessor* weights = NULL;
			for (cgltf_size a = 0; a < src->attributes_count; a++)
			{
				const cgltf_attribute* attribute = &src->attributes[a];
				if (attribute->type == cgltf_attribute_type_position) position = attribute->data;
				else if (attribute->type == cgltf_attribute_type_normal) normal = attribute->data;
				else if (attribute->type == cgltf_attribute_type_texcoord && attribute->index == 0) uv = attribute->data;
				else if (attribute->type == cgltf_attribute_type_texcoord && attribute->index == 1) uv2 = attribute->data;
				else if (attribute->type == cgltf_attribute_type_color && attribute->index == 0) color = attribute->data;
				else if (attribute->type == cgltf_attribute_type_joints && attribute->index == 0) joints = attribute->data;
				else if (attribute->type == cgltf_attribute_type_weights && attribute->index == 0) weights = attribute->data;
			}
			if (position == NULL) continue;

			tn_gltf_prim* dst = &scene->prims[scene->primCount++];
			dst->vertexCount = (uint32_t)position->count;
			dst->positions = tn_read_floats(position, 3);
			if (normal != NULL) dst->normals = tn_read_floats(normal, 3);
			if (uv != NULL) dst->uvs = tn_read_floats(uv, 2);
			if (uv2 != NULL) dst->uv2s = tn_read_floats(uv2, 2);
			if (color != NULL) dst->colors = tn_read_floats(color, 4);
			if (node->skin != NULL && joints != NULL && weights != NULL)
			{
				dst->weights = tn_read_floats(weights, 4);
				dst->joints = (uint16_t*)malloc(sizeof(uint16_t) * 4 * joints->count);
				for (cgltf_size i = 0; i < joints->count; i++)
				{
					cgltf_uint index[4] = { 0, 0, 0, 0 };
					cgltf_accessor_read_uint(joints, i, index, 4);
					for (int k = 0; k < 4; k++) dst->joints[i * 4 + k] = (uint16_t)index[k];
				}
			}

			if (src->indices != NULL)
			{
				dst->indexCount = (uint32_t)src->indices->count;
				dst->indices = (uint32_t*)malloc(sizeof(uint32_t) * dst->indexCount);
				for (cgltf_size i = 0; i < src->indices->count; i++)
				{
					dst->indices[i] = (uint32_t)cgltf_accessor_read_index(src->indices, i);
				}
			}
			else
			{
				dst->indexCount = dst->vertexCount;
				dst->indices = (uint32_t*)malloc(sizeof(uint32_t) * dst->indexCount);
				for (uint32_t i = 0; i < dst->indexCount; i++) dst->indices[i] = i;
			}

			dst->baseColor[0] = dst->baseColor[1] = dst->baseColor[2] = dst->baseColor[3] = 1.0f;
			dst->metallic = 0.0f;
			dst->roughness = 1.0f;
			dst->material = -1;
			dst->baseColorImage = dst->metalRoughImage = dst->normalImage = dst->occlusionImage = dst->emissiveImage = -1;
			dst->normalScale = 1.0f;
			dst->occlusionStrength = 1.0f;
			dst->alphaCutoff = 0.5f;
			if (src->material != NULL)
			{
				const cgltf_material* material = src->material;
				dst->material = (int32_t)(material - data->materials);
				if (material->name != NULL) strncpy(dst->materialName, material->name, sizeof(dst->materialName) - 1);
				if (material->has_pbr_metallic_roughness)
				{
					memcpy(dst->baseColor, material->pbr_metallic_roughness.base_color_factor, sizeof(float) * 4);
					dst->metallic = material->pbr_metallic_roughness.metallic_factor;
					dst->roughness = material->pbr_metallic_roughness.roughness_factor;
					dst->baseColorImage = tn_image_index(data, &material->pbr_metallic_roughness.base_color_texture);
					dst->metalRoughImage = tn_image_index(data, &material->pbr_metallic_roughness.metallic_roughness_texture);
				}
				memcpy(dst->emissive, material->emissive_factor, sizeof(float) * 3);
				dst->normalImage = tn_image_index(data, &material->normal_texture);
				if (dst->normalImage >= 0 && material->normal_texture.scale > 0) dst->normalScale = material->normal_texture.scale;
				dst->occlusionImage = tn_image_index(data, &material->occlusion_texture);
				if (dst->occlusionImage >= 0) dst->occlusionStrength = material->occlusion_texture.scale;
				dst->emissiveImage = tn_image_index(data, &material->emissive_texture);
				dst->alphaMode = material->alpha_mode == cgltf_alpha_mode_mask ? 1 : (material->alpha_mode == cgltf_alpha_mode_blend ? 2 : 0);
				dst->alphaCutoff = material->alpha_cutoff;
				dst->doubleSided = material->double_sided ? 1 : 0;
			}

			// A skinned mesh is placed by its bones; the node's own transform does not apply. Read as a plain mesh, it
			// stands where the bones put it at rest: the first joint's world transform times its inverse bind matrix
			// (an FBX whose skeleton is scaled from centimetres to metres comes in at its real size).
			if (dst->joints != NULL)
			{
				tn_identity(dst->world);
				const cgltf_skin* skin = node->skin;
				if (skin != NULL && skin->joints_count > 0)
				{
					float jointWorld[16], inverseBind[16];
					cgltf_node_transform_world(skin->joints[0], jointWorld);
					tn_identity(inverseBind);
					if (skin->inverse_bind_matrices != NULL) cgltf_accessor_read_float(skin->inverse_bind_matrices, 0, inverseBind, 16);
					for (int column = 0; column < 4; column++)
						for (int row = 0; row < 4; row++)
						{
							float sum = 0;
							for (int k = 0; k < 4; k++) sum += jointWorld[k * 4 + row] * inverseBind[column * 4 + k];
							dst->world[column * 4 + row] = sum;
						}
				}
			}
			else cgltf_node_transform_world(node, dst->world);
			const char* name = node->name != NULL ? node->name : (node->mesh->name != NULL ? node->mesh->name : "Mesh");
			strncpy(dst->name, name, sizeof(dst->name) - 1);
		}
	}

	tn_load_skin(scene, data);
	tn_load_images(scene, data, &options, path);
	cgltf_free(data);
	return scene;
}

int32_t tn_gltf_image_count(const tn_gltf_scene* scene) { return scene != NULL ? scene->imageCount : 0; }
const unsigned char* tn_gltf_get_image(const tn_gltf_scene* scene, int32_t index, int32_t* width, int32_t* height)
{
	if (scene == NULL || index < 0 || index >= scene->imageCount) { *width = *height = 0; return NULL; }
	*width = scene->images[index].width;
	*height = scene->images[index].height;
	return scene->images[index].pixels;
}

int32_t tn_gltf_joint_count(const tn_gltf_scene* scene) { return scene != NULL ? scene->jointCount : 0; }
const tn_gltf_joint* tn_gltf_get_joint(const tn_gltf_scene* scene, int32_t index) { return &scene->joints[index]; }
int32_t tn_gltf_anim_count(const tn_gltf_scene* scene) { return scene != NULL ? scene->animCount : 0; }
const tn_gltf_anim* tn_gltf_get_anim(const tn_gltf_scene* scene, int32_t index) { return &scene->anims[index]; }

uint32_t tn_gltf_prim_count(const tn_gltf_scene* scene)
{
	return scene != NULL ? scene->primCount : 0;
}

const tn_gltf_prim* tn_gltf_get_prim(const tn_gltf_scene* scene, uint32_t index)
{
	return &scene->prims[index];
}

void tn_gltf_free(tn_gltf_scene* scene)
{
	if (scene == NULL) return;
	for (uint32_t i = 0; i < scene->primCount; i++)
	{
		free(scene->prims[i].positions);
		free(scene->prims[i].normals);
		free(scene->prims[i].uvs);
		free(scene->prims[i].uv2s);
		free(scene->prims[i].colors);
		free(scene->prims[i].indices);
		free(scene->prims[i].joints);
		free(scene->prims[i].weights);
	}
	for (int32_t i = 0; i < scene->animCount; i++) free(scene->anims[i].data);
	for (int32_t i = 0; i < scene->imageCount; i++) stbi_image_free(scene->images[i].pixels);
	free(scene->images);
	free(scene->anims);
	free(scene->joints);
	free(scene->prims);
	free(scene);
}
