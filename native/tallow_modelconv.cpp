// tallow_modelconv: turns a model file Assimp reads (FBX, OBJ, DAE, STL, PLY, 3DS) into a binary glTF (.glb) the
// engine loads. The editor and tools/build_player.py run it; see docs/model-import.md.
//
//   tallow_modelconv <source> <out.glb> [--scale s] [--up auto|y|z] [--no-animations] [--clips a,b,...]
//                     [--no-materials]
//
// Exit code 0 on success; on failure the reason is printed on stderr.

#include <assimp/Exporter.hpp>
#include <assimp/Importer.hpp>
#include <assimp/postprocess.h>
#include <assimp/scene.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>

static std::set<std::string> SplitList(const char* text)
{
	std::set<std::string> names;
	std::string current;
	for (const char* c = text;; c++)
	{
		if (*c == ',' || *c == 0)
		{
			if (!current.empty()) names.insert(current);
			current.clear();
			if (*c == 0) break;
		}
		else
			current += *c;
	}
	return names;
}

// A clip's name without the "Armature|" prefix that Blender and some FBX exporters add.
static std::string ShortName(const aiString& name)
{
	std::string text = name.C_Str();
	size_t bar = text.rfind('|');
	return bar == std::string::npos ? text : text.substr(bar + 1);
}

int main(int argc, char** argv)
{
	if (argc < 3)
	{
		fprintf(stderr, "usage: tallow_modelconv <source> <out.glb> [--scale s] [--up auto|y|z] [--no-animations] [--clips a,b] [--no-materials]\n");
		return 2;
	}
	const char* source = argv[1];
	const char* output = argv[2];
	float scale = 1.0f;
	char up = 'a';
	bool animations = true, materials = true;
	std::set<std::string> clips;
	for (int i = 3; i < argc; i++)
	{
		if (!strcmp(argv[i], "--scale") && i + 1 < argc) scale = (float)atof(argv[++i]);
		else if (!strcmp(argv[i], "--up") && i + 1 < argc) up = argv[++i][0];
		else if (!strcmp(argv[i], "--no-animations")) animations = false;
		else if (!strcmp(argv[i], "--no-materials")) materials = false;
		else if (!strcmp(argv[i], "--clips") && i + 1 < argc) clips = SplitList(argv[++i]);
	}

	Assimp::Importer importer;
	// FBX files say what unit they were made in; this brings them to metres like the rest of the engine.
	importer.SetPropertyBool(AI_CONFIG_FBX_CONVERT_TO_M, true);
	importer.SetPropertyBool(AI_CONFIG_IMPORT_FBX_PRESERVE_PIVOTS, false);
	importer.SetPropertyInteger(AI_CONFIG_PP_LBW_MAX_WEIGHTS, 4);
	importer.SetPropertyFloat(AI_CONFIG_GLOBAL_SCALE_FACTOR_KEY, scale);
	unsigned flags = aiProcess_Triangulate | aiProcess_JoinIdenticalVertices | aiProcess_GenSmoothNormals |
		aiProcess_LimitBoneWeights | aiProcess_SortByPType | aiProcess_ValidateDataStructure | aiProcess_EmbedTextures |
		aiProcess_GlobalScale;
	const aiScene* read = importer.ReadFile(source, flags);
	if (read == nullptr || read->mRootNode == nullptr)
	{
		fprintf(stderr, "Could not read %s: %s\n", source, importer.GetErrorString());
		return 1;
	}
	aiScene* scene = importer.GetOrphanedScene();

	// Files made with Z up (3ds Max, many STL / PLY / 3DS exports) stand upright with a quarter turn about X.
	if (up == 'z' || up == 'Z')
	{
		aiMatrix4x4 turn;
		aiMatrix4x4::RotationX(-(float)AI_MATH_HALF_PI, turn);
		scene->mRootNode->mTransformation = turn * scene->mRootNode->mTransformation;
	}

	// Leaving clips out: drop them from the scene before it is written.
	if (!animations || !clips.empty())
	{
		unsigned kept = 0;
		for (unsigned i = 0; i < scene->mNumAnimations; i++)
		{
			aiAnimation* clip = scene->mAnimations[i];
			if (animations && (clips.count(ShortName(clip->mName)) || clips.count(clip->mName.C_Str())))
				scene->mAnimations[kept++] = clip;
			else
				delete clip;
		}
		scene->mNumAnimations = kept;
	}

	// Without materials, every surface takes one plain material (the engine's own are given in the editor).
	if (!materials && scene->mNumMaterials > 0)
	{
		for (unsigned i = 1; i < scene->mNumMaterials; i++)
			delete scene->mMaterials[i];
		scene->mNumMaterials = 1;
		for (unsigned m = 0; m < scene->mNumMeshes; m++)
			scene->mMeshes[m]->mMaterialIndex = 0;
		for (unsigned t = 0; t < scene->mNumTextures; t++)
			delete scene->mTextures[t];
		delete[] scene->mTextures;
		scene->mTextures = nullptr;
		scene->mNumTextures = 0;
		delete scene->mMaterials[0];
		scene->mMaterials[0] = new aiMaterial();
		aiString name("Default");
		scene->mMaterials[0]->AddProperty(&name, AI_MATKEY_NAME);
	}

	Assimp::Exporter exporter;
	aiReturn result = exporter.Export(scene, "glb2", output);
	delete scene;
	if (result != aiReturn_SUCCESS)
	{
		fprintf(stderr, "Could not write %s: %s\n", output, exporter.GetErrorString());
		return 1;
	}
	return 0;
}
