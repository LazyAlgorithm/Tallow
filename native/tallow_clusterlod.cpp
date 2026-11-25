// Cluster LOD for ClusterMesh (Engine/src/Render/ClusterMesh.bf): a mesh cut into clusters of at most 128 triangles
// and 64 vertices, which are merged into groups, simplified and cut again, level after level, until one group is
// left (the Nanite-style hierarchy). Built with zeux's clusterlod.h on top of meshoptimizer (both MIT).
//
// Everything comes out as flat arrays laid out for the graphics card (little endian, 16-byte aligned structs), which
// the engine uploads as they are. A cluster is drawn when its own error is under the screen threshold and its parent
// group's error is not:  selfError <= threshold < parentError.  Both errors are stored in every cluster.
//
// One call builds on the calling thread only; callers run several builds on several threads.

#include "meshoptimizer.h"
#define CLUSTERLOD_IMPLEMENTATION
#include "clusterlod.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#if defined(_WIN32)
#define TN_API extern "C" __declspec(dllexport)
#else
#define TN_API extern "C" __attribute__((visibility("default")))
#endif

namespace
{
// The C layouts ClusterMesh.bf shares. Sizes are checked below.

struct Config
{
	uint32_t maxVertices;   // per cluster; 0 = 64 (at most 255, local indices are bytes)
	uint32_t maxTriangles;  // per cluster; 0 = 128 (at most 256)
	uint32_t minTriangles;  // per cluster; 0 = a third of maxTriangles
	uint32_t partitionSize; // clusters per group, about; 0 = 16
	float normalWeight;     // how much simplification cares about normals; 0 = 0.5
	float uvWeight;         // ... and about texture coordinates; 0 = 0.5
	float simplifyRatio;    // triangles kept by each level; 0 = 0.5
	uint32_t flags;         // reserved, 0
};

struct Cluster
{
	uint32_t vertexOffset;   // into the vertex list (entries, not bytes)
	uint32_t vertexCount;
	uint32_t triangleOffset; // into the triangle bytes; a multiple of 4
	uint32_t triangleCount;
	float center[3];         // bounds sphere of the cluster's own triangles
	float radius;
	float coneAxis[3];       // normal cone for back-face culling; cull when dot(direction to cluster, axis) >= cutoff
	float coneCutoff;
	float selfError;         // this cluster's error (0 for the original triangles), in mesh units
	float parentError;       // the error of the group this cluster was merged into (FLT_MAX at the top)
	int32_t groupIndex;      // the group this cluster belongs to (its siblings, merged next); also its LOD level: groups[groupIndex].depth
	int32_t refinedGroup;    // the finer group this cluster was simplified from (-1 for original triangles)
};

struct Group
{
	float center[3];         // sphere that bounds the simplified result of this group (monotonic along the hierarchy)
	float radius;
	float error;             // its error, in mesh units (FLT_MAX for the top group, which is not simplified further)
	int32_t depth;           // LOD level of the group's clusters; 0 = original triangles
	uint32_t clusterOffset;  // the group's clusters are clusters[clusterOffset .. +clusterCount)
	uint32_t clusterCount;
};

struct Level
{
	uint32_t clusterCount;
	uint32_t triangleCount;
	uint32_t groupCount;
	float maxError;          // the largest selfError of the level's clusters
};

static_assert(sizeof(Config) == 32, "Config layout");
static_assert(sizeof(Cluster) == 64, "Cluster layout");
static_assert(sizeof(Group) == 32, "Group layout");
static_assert(sizeof(Level) == 16, "Level layout");

struct Result
{
	std::vector<Cluster> clusters;
	std::vector<Group> groups;
	std::vector<Level> levels;
	std::vector<uint32_t> vertices;  // source vertex index for each cluster vertex
	std::vector<uint8_t> triangles;  // local indices, three per triangle, each cluster padded to 4 bytes
};

struct Builder
{
	Result* result;
	const float* positions;
	size_t vertexCount;
	size_t positionStride;
	std::vector<uint32_t> localVertices;
	std::vector<uint8_t> localTriangles;
};

int OnGroup(void* context, clodGroup group, const clodCluster* clusters, size_t clusterCount)
{
	auto* b = (Builder*)context;
	Result& r = *b->result;
	const int groupIndex = (int)r.groups.size();

	Group g = {};
	g.center[0] = group.simplified.center[0];
	g.center[1] = group.simplified.center[1];
	g.center[2] = group.simplified.center[2];
	g.radius = group.simplified.radius;
	g.error = group.simplified.error;
	g.depth = group.depth;
	g.clusterOffset = (uint32_t)r.clusters.size();
	g.clusterCount = (uint32_t)clusterCount;
	r.groups.push_back(g);

	for (size_t i = 0; i < clusterCount; i++)
	{
		const clodCluster& c = clusters[i];
		Cluster out = {};
		b->localVertices.resize(c.index_count);
		b->localTriangles.resize(c.index_count);
		const size_t vertexCount = clodLocalIndices(b->localVertices.data(), b->localTriangles.data(), c.indices, c.index_count);
		const size_t triangleCount = c.index_count / 3;

		out.vertexOffset = (uint32_t)r.vertices.size();
		out.vertexCount = (uint32_t)vertexCount;
		out.triangleOffset = (uint32_t)r.triangles.size();
		out.triangleCount = (uint32_t)triangleCount;
		r.vertices.insert(r.vertices.end(), b->localVertices.begin(), b->localVertices.begin() + vertexCount);
		r.triangles.insert(r.triangles.end(), b->localTriangles.begin(), b->localTriangles.begin() + triangleCount * 3);
		r.triangles.resize((r.triangles.size() + 3) & ~(size_t)3, 0);

		meshopt_Bounds cone = meshopt_computeMeshletBounds(b->localVertices.data(), b->localTriangles.data(), triangleCount,
			b->positions, b->vertexCount, b->positionStride);
		out.center[0] = c.bounds.center[0];
		out.center[1] = c.bounds.center[1];
		out.center[2] = c.bounds.center[2];
		out.radius = c.bounds.radius;
		out.coneAxis[0] = cone.cone_axis[0];
		out.coneAxis[1] = cone.cone_axis[1];
		out.coneAxis[2] = cone.cone_axis[2];
		out.coneCutoff = cone.cone_cutoff;
		out.groupIndex = groupIndex;
		out.refinedGroup = c.refined;
		out.selfError = 0; // filled in once every group is known
		out.parentError = group.simplified.error;
		r.clusters.push_back(out);
	}
	return groupIndex;
}
} // namespace

/// 64-bit hash of a block of memory (for the cache's "has the mesh changed" check). Pass the previous result as seed
/// to hash several blocks as one.
TN_API uint64_t tn_clod_hash(const void* data, size_t bytes, uint64_t seed)
{
	const uint8_t* p = (const uint8_t*)data;
	uint64_t h = seed ^ 0x9E3779B97F4A7C15ull;
	while (bytes >= 8)
	{
		uint64_t k;
		memcpy(&k, p, 8);
		k *= 0xFF51AFD7ED558CCDull;
		k ^= k >> 32;
		h = (h ^ k) * 0xC4CEB9FE1A85EC53ull;
		h ^= h >> 29;
		p += 8;
		bytes -= 8;
	}
	uint64_t tail = 0;
	memcpy(&tail, p, bytes);
	h = (h ^ (tail * 0xFF51AFD7ED558CCDull)) * 0xC4CEB9FE1A85EC53ull;
	h ^= h >> 32;
	return h;
}

/// Builds the hierarchy for a triangle mesh. Each attribute pointer is the first vertex's value, with its own stride in
/// bytes; normals and uvs may be null. Returns an opaque result (read it with tn_clod_counts and tn_clod_copy, free it
/// with tn_clod_free), or null when the input is unusable.
TN_API void* tn_clod_build(const float* positions, uint32_t positionStride, const float* normals, uint32_t normalStride,
	const float* uvs, uint32_t uvStride, uint32_t vertexCount, const uint32_t* indices, uint32_t indexCount, const Config* configIn)
{
	if (!positions || !indices || vertexCount == 0 || indexCount < 3 || indexCount % 3 != 0 || positionStride < 12 || positionStride % 4 != 0)
		return nullptr;
	for (uint32_t i = 0; i < indexCount; i++)
		if (indices[i] >= vertexCount)
			return nullptr;

	Config cfg = configIn ? *configIn : Config{};
	if (cfg.maxVertices == 0) cfg.maxVertices = 64;
	if (cfg.maxTriangles == 0) cfg.maxTriangles = 128;
	if (cfg.maxVertices > 255 || cfg.maxTriangles > 256 || cfg.maxTriangles < 4 || cfg.maxVertices < 3)
		return nullptr;
	if (cfg.normalWeight <= 0) cfg.normalWeight = 0.5f;
	if (cfg.uvWeight <= 0) cfg.uvWeight = 0.5f;

	clodConfig config = clodDefaultConfig(cfg.maxTriangles);
	config.max_vertices = cfg.maxVertices;
	if (cfg.minTriangles) config.min_triangles = cfg.minTriangles;
	if (cfg.partitionSize) config.partition_size = cfg.partitionSize;
	if (cfg.simplifyRatio > 0) config.simplify_ratio = cfg.simplifyRatio;

	// Simplification attributes in one packed array: normal (3), then uv (2).
	const size_t attributeCount = (normals ? 3 : 0) + (uvs ? 2 : 0);
	std::vector<float> attributes(attributeCount * vertexCount);
	float weights[5];
	size_t w = 0;
	if (normals)
		for (int k = 0; k < 3; k++) weights[w++] = cfg.normalWeight;
	if (uvs)
		for (int k = 0; k < 2; k++) weights[w++] = cfg.uvWeight;
	for (uint32_t v = 0; v < vertexCount; v++)
	{
		float* out = &attributes[v * attributeCount];
		if (normals)
		{
			const float* n = (const float*)((const char*)normals + (size_t)v * normalStride);
			out[0] = n[0]; out[1] = n[1]; out[2] = n[2];
			out += 3;
		}
		if (uvs)
		{
			const float* t = (const float*)((const char*)uvs + (size_t)v * uvStride);
			out[0] = t[0]; out[1] = t[1];
		}
	}

	clodMesh mesh = {};
	mesh.indices = indices;
	mesh.index_count = indexCount;
	mesh.vertex_count = vertexCount;
	mesh.vertex_positions = positions;
	mesh.vertex_positions_stride = positionStride;
	if (attributeCount > 0)
	{
		mesh.vertex_attributes = attributes.data();
		mesh.vertex_attributes_stride = attributeCount * sizeof(float);
		mesh.attribute_weights = weights;
		mesh.attribute_count = attributeCount;
		// Permissive simplification may collapse across texture seams; keep the seams themselves.
		if (uvs)
			mesh.attribute_protect_mask = 3u << (normals ? 3 : 0);
	}

	Result* result = new Result();
	Builder builder = {};
	builder.result = result;
	builder.positions = positions;
	builder.vertexCount = vertexCount;
	builder.positionStride = positionStride;
	clodBuild(config, mesh, &builder, OnGroup);

	if (result->clusters.empty())
	{
		delete result;
		return nullptr;
	}

	// A cluster's own error is the error of the finer group it came from.
	int maxDepth = 0;
	for (const Group& g : result->groups)
		maxDepth = std::max(maxDepth, g.depth);
	result->levels.assign((size_t)maxDepth + 1, Level{});
	for (Cluster& c : result->clusters)
	{
		c.selfError = c.refinedGroup >= 0 ? result->groups[c.refinedGroup].error : 0.0f;
		Level& level = result->levels[result->groups[c.groupIndex].depth];
		level.clusterCount++;
		level.triangleCount += c.triangleCount;
		level.maxError = std::max(level.maxError, c.selfError);
	}
	for (const Group& g : result->groups)
		result->levels[g.depth].groupCount++;
	return result;
}

/// The size of a result's arrays: out[0..5) = clusters, groups, levels, vertex list entries, triangle bytes.
TN_API void tn_clod_counts(const void* handle, uint32_t* out)
{
	const Result* r = (const Result*)handle;
	out[0] = (uint32_t)r->clusters.size();
	out[1] = (uint32_t)r->groups.size();
	out[2] = (uint32_t)r->levels.size();
	out[3] = (uint32_t)r->vertices.size();
	out[4] = (uint32_t)r->triangles.size();
}

/// Copies a result into arrays sized from tn_clod_counts.
TN_API void tn_clod_copy(const void* handle, Cluster* clusters, Group* groups, Level* levels, uint32_t* vertices, uint8_t* triangles)
{
	const Result* r = (const Result*)handle;
	memcpy(clusters, r->clusters.data(), r->clusters.size() * sizeof(Cluster));
	memcpy(groups, r->groups.data(), r->groups.size() * sizeof(Group));
	memcpy(levels, r->levels.data(), r->levels.size() * sizeof(Level));
	memcpy(vertices, r->vertices.data(), r->vertices.size() * sizeof(uint32_t));
	memcpy(triangles, r->triangles.data(), r->triangles.size());
}

TN_API void tn_clod_free(void* handle)
{
	delete (Result*)handle;
}
