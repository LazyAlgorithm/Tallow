// tallow_modelsettings: the import settings step of docs/model-import.md as a program, for tools/build_player.py
// (the editor calls tn_model_import_settings directly).
//
//   tallow_modelsettings <in.glb> <out.glb> <scale> <zUp 0|1> <animations 0|1> <clips or ""> <materials 0|1>

#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int32_t tn_model_import_settings(const char* source, const char* output, float scale, int32_t upZ, int32_t animations,
	const char* clips, int32_t materials);

int main(int argc, char** argv)
{
	if (argc < 8)
	{
		fprintf(stderr, "usage: tallow_modelsettings <in.glb> <out.glb> <scale> <zUp> <animations> <clips> <materials>\n");
		return 2;
	}
	if (!tn_model_import_settings(argv[1], argv[2], (float)atof(argv[3]), atoi(argv[4]), atoi(argv[5]), argv[6], atoi(argv[7])))
	{
		fprintf(stderr, "Could not read %s or write %s\n", argv[1], argv[2]);
		return 1;
	}
	return 0;
}
