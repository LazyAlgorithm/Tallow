// Import settings applied to a converted model (docs/model-import.md): the editor converts FBX / OBJ / ... to a .glb
// with whichever converter it has, then this rewrites that .glb with the project's scale, up axis, clip choice and
// materials, so every converter gives the same result.

#include "cgltf.h"
#define CGLTF_WRITE_IMPLEMENTATION
#include "cgltf_write.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// A clip's name without the "Armature|" prefix that Blender and some FBX exporters add.
static const char* tn_short_clip_name(const char* name)
{
	const char* bar = strrchr(name, '|');
	return bar != NULL ? bar + 1 : name;
}

// True when name is one of the comma-separated names in list (the full name or the short one).
static int tn_clip_listed(const char* list, const char* name)
{
	if (name == NULL) return 0;
	const char* shortName = tn_short_clip_name(name);
	const char* at = list;
	while (*at)
	{
		const char* end = strchr(at, ',');
		size_t length = end != NULL ? (size_t)(end - at) : strlen(at);
		if ((strlen(name) == length && strncmp(name, at, length) == 0) ||
			(strlen(shortName) == length && strncmp(shortName, at, length) == 0))
			return 1;
		if (end == NULL) break;
		at = end + 1;
	}
	return 0;
}

static void tn_quat_mul(const float* a, const float* b, float* out)
{
	float x = a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1];
	float y = a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0];
	float z = a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3];
	float w = a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2];
	out[0] = x; out[1] = y; out[2] = z; out[3] = w;
}

// The change made to the whole model: a uniform scale, then (for Z-up files) a quarter turn about X.
typedef struct { float scale; int upZ; float turn[4]; } tn_import_change;

static void tn_change_point(const tn_import_change* change, float* p)
{
	float x = p[0] * change->scale, y = p[1] * change->scale, z = p[2] * change->scale;
	if (change->upZ) { p[0] = x; p[1] = z; p[2] = -y; }
	else { p[0] = x; p[1] = y; p[2] = z; }
}

static void tn_change_node(const tn_import_change* change, cgltf_node* node)
{
	if (node->has_matrix)
	{
		// Column-major, and the change is linear: each column's first three values go through it.
		for (int column = 0; column < 4; column++) tn_change_point(change, node->matrix + column * 4);
		return;
	}
	if (!node->has_translation) { node->translation[0] = node->translation[1] = node->translation[2] = 0; node->has_translation = 1; }
	if (!node->has_rotation) { node->rotation[0] = node->rotation[1] = node->rotation[2] = 0; node->rotation[3] = 1; node->has_rotation = 1; }
	if (!node->has_scale) { node->scale[0] = node->scale[1] = node->scale[2] = 1; node->has_scale = 1; }
	tn_change_point(change, node->translation);
	tn_quat_mul(change->turn, node->rotation, node->rotation);
	for (int i = 0; i < 3; i++) node->scale[i] *= change->scale;
}

// Keyframes that move a top-level node would undo its change, so they take the same change.
static int tn_change_keys(const tn_import_change* change, cgltf_animation_channel* channel)
{
	cgltf_accessor* keys = channel->sampler->output;
	if (keys->is_sparse || keys->component_type != cgltf_component_type_r_32f || keys->buffer_view == NULL ||
		keys->buffer_view->buffer->data == NULL)
		return 0;
	uint8_t* base = (uint8_t*)keys->buffer_view->buffer->data + keys->buffer_view->offset + keys->offset;
	cgltf_size stride = keys->stride;
	for (cgltf_size k = 0; k < keys->count; k++)
	{
		float* value = (float*)(base + k * stride);
		switch (channel->target_path)
		{
		case cgltf_animation_path_type_translation: tn_change_point(change, value); break;
		case cgltf_animation_path_type_rotation: tn_quat_mul(change->turn, value, value); break;
		case cgltf_animation_path_type_scale: for (int i = 0; i < 3; i++) value[i] *= change->scale; break;
		default: break;
		}
	}
	return 1;
}

static int tn_write_glb(const char* path, const cgltf_data* data)
{
	cgltf_options options;
	memset(&options, 0, sizeof(options));
	options.type = cgltf_file_type_glb;
	cgltf_size jsonSize = cgltf_write(&options, NULL, 0, data);
	if (jsonSize == 0) return 0;
	char* json = (char*)malloc(jsonSize);
	cgltf_write(&options, json, jsonSize, data);
	jsonSize -= 1; // cgltf counts the closing zero
	uint32_t jsonPadded = (uint32_t)((jsonSize + 3) & ~(cgltf_size)3);
	const cgltf_buffer* buffer = data->buffers_count > 0 ? &data->buffers[0] : NULL;
	uint32_t binSize = buffer != NULL ? (uint32_t)buffer->size : 0;
	uint32_t binPadded = (binSize + 3) & ~3u;
	uint32_t total = 12 + 8 + jsonPadded + (binSize > 0 ? 8 + binPadded : 0);

	FILE* file = fopen(path, "wb");
	if (file == NULL) { free(json); return 0; }
	uint32_t header[3] = { 0x46546C67u, 2, total };
	fwrite(header, 4, 3, file);
	uint32_t jsonChunk[2] = { jsonPadded, 0x4E4F534Au };
	fwrite(jsonChunk, 4, 2, file);
	fwrite(json, 1, jsonSize, file);
	for (cgltf_size i = jsonSize; i < jsonPadded; i++) fputc(' ', file);
	if (binSize > 0)
	{
		uint32_t binChunk[2] = { binPadded, 0x004E4942u };
		fwrite(binChunk, 4, 2, file);
		fwrite(buffer->data, 1, binSize, file);
		for (uint32_t i = binSize; i < binPadded; i++) fputc(0, file);
	}
	int ok = ferror(file) == 0;
	fclose(file);
	free(json);
	return ok;
}

// Rewrites the .glb at source into output with the settings. clips: comma-separated names to keep ("" keeps all).
// Returns 1 on success, 0 when the file cannot be read or written (a .glb with its data in one internal buffer).
int32_t tn_model_import_settings(const char* source, const char* output, float scale, int32_t upZ, int32_t animations,
	const char* clips, int32_t materials)
{
	cgltf_options options;
	memset(&options, 0, sizeof(options));
	cgltf_data* data = NULL;
	if (cgltf_parse_file(&options, source, &data) != cgltf_result_success) return 0;
	if (cgltf_load_buffers(&options, data, source) != cgltf_result_success || data->buffers_count > 1 ||
		(data->buffers_count == 1 && data->buffers[0].uri != NULL))
	{
		cgltf_free(data);
		return 0;
	}

	tn_import_change change;
	change.scale = scale > 0 ? scale : 1;
	change.upZ = upZ != 0;
	float half = upZ ? -0.70710678f : 0;
	change.turn[0] = upZ ? half : 0; change.turn[1] = 0; change.turn[2] = 0; change.turn[3] = upZ ? 0.70710678f : 1;
	if (change.scale != 1 || change.upZ)
	{
		for (cgltf_size n = 0; n < data->nodes_count; n++)
		{
			if (data->nodes[n].parent == NULL) tn_change_node(&change, &data->nodes[n]);
		}
		for (cgltf_size a = 0; a < data->animations_count; a++)
		{
			for (cgltf_size c = 0; c < data->animations[a].channels_count; c++)
			{
				cgltf_animation_channel* channel = &data->animations[a].channels[c];
				if (channel->target_node != NULL && channel->target_node->parent == NULL) tn_change_keys(&change, channel);
			}
		}
	}

	// Clips left out move to the end of the list, past the count that is written; the full count is put back before
	// the data is freed.
	cgltf_size animationCount = data->animations_count;
	if (!animations) data->animations_count = 0;
	else if (clips != NULL && clips[0] != 0)
	{
		cgltf_size kept = 0;
		for (cgltf_size a = 0; a < data->animations_count; a++)
		{
			if (!tn_clip_listed(clips, data->animations[a].name)) continue;
			if (a != kept)
			{
				cgltf_animation swap = data->animations[kept];
				data->animations[kept] = data->animations[a];
				data->animations[a] = swap;
			}
			kept++;
		}
		data->animations_count = kept;
	}

	cgltf_size materialCount = data->materials_count, textureCount = data->textures_count, imageCount = data->images_count;
	if (!materials)
	{
		for (cgltf_size m = 0; m < data->meshes_count; m++)
		{
			for (cgltf_size p = 0; p < data->meshes[m].primitives_count; p++) data->meshes[m].primitives[p].material = NULL;
		}
		data->materials_count = 0;
		data->textures_count = 0;
		data->images_count = 0;
	}

	int ok = tn_write_glb(output, data);
	data->animations_count = animationCount;
	data->materials_count = materialCount;
	data->textures_count = textureCount;
	data->images_count = imageCount;
	cgltf_free(data);
	return ok;
}
