// Walking navigation meshes for NavigationMesh (Engine/src/AI/NavigationMesh.bf): built from a physics world's static
// shapes with Recast, searched with Detour.
//
// A mesh is cut into square tiles. Each tile keeps the heightfield its shapes were rasterized into, so carving, cost
// areas and links rebuild only the tiles they touch from that heightfield, and a geometry change re-rasterizes only
// the tiles round it. Every change then builds a new Detour mesh out of the tiles' data and swaps it in whole: a
// failed rebuild leaves the last good mesh in use. Queries only read the mesh, each with scratch of its own (Query),
// so several threads may search at once while nothing rebuilds it.

#include <Jolt/Jolt.h>
#include <Jolt/Physics/Collision/CollisionCollectorImpl.h>
#include <Jolt/Physics/Collision/Shape/Shape.h>
#include <Jolt/Physics/Collision/ShapeFilter.h>
#include <Jolt/Physics/Collision/TransformedShape.h>
#include "joltc.h"
#include "DetourCommon.h"
#include "DetourNavMesh.h"
#include "DetourNavMeshBuilder.h"
#include "DetourNavMeshQuery.h"
#include "Recast.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

#if defined(_WIN32)
#define TN_API extern "C" __declspec(dllexport)
#else
#define TN_API extern "C" __attribute__((visibility("default")))
#endif

namespace
{
// The C layouts NavigationMesh.bf shares (its Config, Volume and Link).

struct Settings
{
	float min[3], max[3];
	float cellSize, cellHeight, radius, height, climb, slope;
};

/// A box or cylinder that blocks the walkable floor inside it (cost 0) or makes it cost more to cross.
struct Volume
{
	float center[3], rotation[4], half[3], cost;
	int32_t cylinder, obstacle;
};

/// A way between two points that the floor does not have (a jump, a ladder, a teleporter).
struct Link
{
	float start[3], end[3], radius, cost;
	int32_t bidirectional, id;
};

// Limits. Recast stores spans in 13 bits of height and Detour polygon vertices in 16 bits.
const int MaxRasterSide = 4096;
const double MaxRasterCells = 4000000;
const size_t MaxTriangleFloats = 18000000;
const int MaxVolumes = 65536;
const int MaxLinks = 65535;
// A surface this many voxels across or fewer is one tile; a larger one is cut into tiles of SmallTile voxels.
const int SingleTileLimit = 256;
const int SmallTile = 64;
// Detour packs salt, tile and polygon into a 32-bit reference; tile and polygon bits share this many.
const int TileAndPolygonBits = 22;
const int SaltBits = 32 - TileAndPolygonBits;
const int MaxQueryNodes = 65535;
const int RaycastCorridor = 4096;
// Detour polygon flags: walkable floor, and an off-mesh connection (a link).
const unsigned short FloorFlag = 1;
const unsigned short LinkFlag = 2;
// Area 0 is unused and area 1 is plain floor at cost 1; costs from areas and links take the ids after it.
const int GroundArea = 1;
const int FirstCostArea = 2;
const float ContourError = 0.5f;
const float ContourEdgeLength = 12;
const float DetailSampleCells = 6;
const int VerticesPerPolygon = 6;
const uint32_t AssetMagic = 0x314D4E54u; // "TNM1"
const int AssetHeaderBytes = 56;

/// One tile: its place in the grid of tiles, the bounds it rasterizes (with a border either side so its edges match
/// its neighbours'), its static heightfield, and the Detour tile data built from it.
struct Tile
{
	int x = 0, z = 0;
	Settings bounds{};
	int border = 0;
	std::shared_ptr<rcHeightfield> heightfield;
	std::vector<unsigned char> data;
	int floorPolygons = 0;
	int polygonSlots = 0;
};

struct Mesh
{
	Settings settings{};
	/// The static shapes' triangles (nine floats each), as baked or loaded.
	std::vector<float> triangles;
	std::vector<std::unique_ptr<Tile>> tiles;
	int tilesX = 0, tilesZ = 0, tileCells = SingleTileLimit;
	int lastRebuilt = 0;
	/// The volumes and links the tiles were last built with, to tell which tiles a change touches.
	std::vector<Volume> volumes;
	std::vector<Link> links;
	/// Each Detour area's cost; costCount areas are in use.
	float costs[DT_MAX_AREAS];
	int costCount = FirstCostArea;
	dtNavMesh* detour = nullptr;
	int floorPolygons = 0, polygonSlots = 0;
	/// Goes up with every rebuild, so queries know to start over.
	unsigned revision = 0;

	Mesh() { std::fill(costs, costs + DT_MAX_AREAS, 1.0f); }
	~Mesh() { dtFreeNavMesh(detour); }
};

/// One thread's search scratch, and the last path it found.
struct Query
{
	dtNavMeshQuery query;
	const Mesh* mesh = nullptr;
	unsigned revision = 0;
	int nodes = 0;
	std::vector<dtPolyRef> corridor, straightRefs;
	std::vector<float> straight, points;
	std::vector<unsigned char> straightFlags;
	std::vector<int32_t> legs;
};

template <typename T> struct Free
{
	void (*free)(T*);
	void operator()(T* p) const { free(p); }
};
template <typename T> using Owned = std::unique_ptr<T, Free<T>>;

bool Finite(const float* p) { return std::isfinite(p[0]) && std::isfinite(p[1]) && std::isfinite(p[2]); }

bool ValidSettings(const Settings& s)
{
	if (!Finite(s.min) || !Finite(s.max))
		return false;
	for (float value : {s.cellSize, s.cellHeight, s.radius, s.height, s.climb, s.slope})
	{
		if (!std::isfinite(value))
			return false;
	}
	if (s.cellSize < 0.01f || s.cellHeight < 0.005f || s.radius <= 0 || s.height < 2 * s.radius || s.climb < 0 || s.slope < 0 || s.slope >= 90)
		return false;
	for (int i = 0; i < 3; i++)
	{
		if (s.max[i] <= s.min[i])
			return false;
	}
	double width = std::ceil((s.max[0] - s.min[0]) / s.cellSize), depth = std::ceil((s.max[2] - s.min[2]) / s.cellSize);
	return width <= MaxRasterSide && depth <= MaxRasterSide && width * depth <= MaxRasterCells && (s.max[1] - s.min[1]) / s.cellHeight < RC_SPAN_MAX_HEIGHT &&
		s.height / s.cellHeight < RC_SPAN_MAX_HEIGHT && s.climb / s.cellHeight < RC_SPAN_MAX_HEIGHT && s.radius / s.cellSize <= MaxRasterSide;
}

bool ValidVolume(const Volume& v)
{
	float norm = 0;
	for (float r : v.rotation)
	{
		if (!std::isfinite(r))
			return false;
		norm += r * r;
	}
	return Finite(v.center) && Finite(v.half) && v.half[0] > 0 && v.half[1] > 0 && v.half[2] > 0 && std::isfinite(v.cost) && std::abs(norm - 1) <= 0.01f;
}

bool ValidLink(const Link& l)
{
	return Finite(l.start) && Finite(l.end) && std::isfinite(l.radius) && l.radius > 0 && std::isfinite(l.cost) && l.cost >= 0.1f && l.id >= 0;
}

int ClimbVoxels(const Settings& s) { return int(std::floor(s.climb / s.cellHeight)); }
int HeightVoxels(const Settings& s) { return int(std::ceil(s.height / s.cellHeight)); }
int RadiusVoxels(const Settings& s) { return int(std::ceil(s.radius / s.cellSize)); }

// ---- geometry ----

/// Every static body's triangles inside the bounds, compound shapes taken apart into their leaves (with each leaf's
/// own transform and scale).
bool CollectGeometry(JPH_PhysicsSystem* world, const Settings& s, std::vector<float>& triangles)
{
	const unsigned count = JPH_PhysicsSystem_GetNumBodies(world);
	std::vector<JPH_BodyID> ids(count);
	JPH_PhysicsSystem_GetBodies(world, ids.data(), count);
	const auto* locks = JPH_PhysicsSystem_GetBodyLockInterfaceNoLock(world);
	JPH::AABox bounds(JPH::Vec3(s.min[0], s.min[1], s.min[2]), JPH::Vec3(s.max[0], s.max[1], s.max[2]));
	for (auto id : ids)
	{
		JPH_BodyLockRead lock{};
		JPH_BodyLockInterface_LockRead(locks, id, &lock);
		if (!lock.body)
			continue;
		auto* shape = reinterpret_cast<const JPH::Shape*>(JPH_Body_GetShape(const_cast<JPH_Body*>(lock.body)));
		JPH_RVec3 position;
		JPH_Quat rotation;
		JPH_Body_GetCenterOfMassPosition(lock.body, &position);
		JPH_Body_GetRotation(lock.body, &rotation);
		JPH::AllHitCollisionCollector<JPH::TransformedShapeCollector> leaves;
		shape->CollectTransformedShapes(bounds, JPH::Vec3(float(position.x), float(position.y), float(position.z)), JPH::Quat(rotation.x, rotation.y, rotation.z, rotation.w),
			JPH::Vec3::sReplicate(1), JPH::SubShapeIDCreator(), leaves, JPH::ShapeFilter());
		bool full = false;
		for (const auto& leaf : leaves.mHits)
		{
			JPH::Shape::GetTrianglesContext context;
			leaf.mShape->GetTrianglesStart(context, bounds, JPH::Vec3(leaf.mShapePositionCOM), leaf.mShapeRotation, leaf.GetShapeScale());
			JPH::Float3 vertices[3 * 128];
			int found;
			while (!full && (found = leaf.mShape->GetTrianglesNext(context, 128, vertices)) > 0)
			{
				full = triangles.size() + found * 9 > MaxTriangleFloats;
				const float* first = &vertices[0].x;
				if (!full)
					triangles.insert(triangles.end(), first, first + found * 9);
			}
		}
		JPH_BodyLockInterface_UnlockRead(locks, &lock);
		if (full)
			return false;
	}
	return true;
}

/// A shape resting on the floor has a downward face level with it. Recast merges the two spans and keeps the floor's
/// walkable flag, which leaves an unreachable island inside the shape that nearest-point queries could snap into, so
/// the floor under each downward face is cleared.
void ClearUnderDownwardFaces(const std::vector<float>& triangles, const Settings& s, rcHeightfield& field)
{
	const int w = field.width, h = field.height;
	for (size_t t = 0; t < triangles.size(); t += 9)
	{
		const float* a = triangles.data() + t;
		const float* b = a + 3;
		const float* c = a + 6;
		const float facing = (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]);
		if (facing >= -1e-7f || std::max({a[1], b[1], c[1]}) < s.min[1])
			continue;
		const float minX = std::min({a[0], b[0], c[0]}), maxX = std::max({a[0], b[0], c[0]});
		const float minZ = std::min({a[2], b[2], c[2]}), maxZ = std::max({a[2], b[2], c[2]});
		if (maxX < s.min[0] || minX > s.max[0] || maxZ < s.min[2] || minZ > s.max[2])
			continue;
		const int x0 = std::clamp(int(std::floor((minX - s.min[0]) / s.cellSize)), 0, w - 1), x1 = std::clamp(int(std::floor((maxX - s.min[0]) / s.cellSize)), 0, w - 1);
		const int z0 = std::clamp(int(std::floor((minZ - s.min[2]) / s.cellSize)), 0, h - 1), z1 = std::clamp(int(std::floor((maxZ - s.min[2]) / s.cellSize)), 0, h - 1);
		const float denominator = (b[2] - c[2]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[2] - c[2]);
		for (int z = z0; z <= z1; z++)
		{
			for (int x = x0; x <= x1; x++)
			{
				// The face's height over the voxel's centre, by barycentric weights.
				const float px = s.min[0] + (x + 0.5f) * s.cellSize, pz = s.min[2] + (z + 0.5f) * s.cellSize;
				const float u = ((b[2] - c[2]) * (px - c[0]) + (c[0] - b[0]) * (pz - c[2])) / denominator;
				const float v = ((c[2] - a[2]) * (px - c[0]) + (a[0] - c[0]) * (pz - c[2])) / denominator;
				if (u < 0 || v < 0 || u + v > 1)
					continue;
				const float y = u * a[1] + v * b[1] + (1 - u - v) * c[1];
				for (rcSpan* span = field.spans[x + z * w]; span; span = span->next)
				{
					const float above = s.min[1] + span->smax * s.cellHeight - y;
					if (above >= -1e-4f && above <= s.cellHeight * 1.01f)
						span->area = RC_NULL_AREA;
				}
			}
		}
	}
}

/// Rasterizes the mesh's triangles into a tile's heightfield and filters it for the agent (low obstacles stepped
/// over, ledges and too-low headroom removed). Kept until the geometry changes.
bool RasterizeTile(const Mesh& mesh, Tile& tile)
{
	const Settings& s = tile.bounds;
	const auto& triangles = mesh.triangles;
	// Keeps Recast's float-to-voxel conversions in range, for shapes outside the bounds too.
	for (size_t i = 0; i < triangles.size(); i++)
	{
		const float step = i % 3 == 1 ? s.cellHeight : s.cellSize;
		if (!std::isfinite(triangles[i]) || std::abs((double(triangles[i]) - s.min[i % 3]) / step) > 1e8)
			return false;
	}
	rcContext context(false);
	Owned<rcHeightfield> field(rcAllocHeightfield(), {rcFreeHeightField});
	int w, h;
	rcCalcGridSize(s.min, s.max, s.cellSize, &w, &h);
	if (!field || !rcCreateHeightfield(&context, *field, w, h, s.min, s.max, s.cellSize, s.cellHeight))
		return false;
	const int count = int(triangles.size() / 9);
	if (count > 0)
	{
		std::vector<int> indices(count * 3);
		for (int i = 0; i < count * 3; i++)
			indices[i] = i;
		std::vector<unsigned char> areas(count, RC_NULL_AREA);
		rcMarkWalkableTriangles(&context, s.slope, triangles.data(), count * 3, indices.data(), count, areas.data());
		if (!rcRasterizeTriangles(&context, triangles.data(), count * 3, indices.data(), areas.data(), count, *field, ClimbVoxels(s)))
			return false;
	}
	ClearUnderDownwardFaces(triangles, s, *field);
	rcFilterLowHangingWalkableObstacles(&context, ClimbVoxels(s), *field);
	rcFilterLedgeSpans(&context, HeightVoxels(s), ClimbVoxels(s), *field);
	rcFilterWalkableLowHeightSpans(&context, HeightVoxels(s), *field);
	tile.heightfield = std::shared_ptr<rcHeightfield>(field.release(), rcFreeHeightField);
	return true;
}

/// A volume's footprint on the ground: the convex hull of its turned box (or a 12-sided prism round its cylinder),
/// as X, 0, Z triples, with the lowest and highest it reaches.
std::vector<float> Footprint(const Volume& v, float& low, float& high)
{
	struct Point
	{
		float x, z;
	};
	// A 12-gon drawn through the circle's outside: its edge midpoints lie on the circle, so the circle is inside.
	const float OutsideCircle = 1 / 0.965925826f;
	std::vector<Point> points;
	low = 1e30f;
	high = -1e30f;
	const JPH::Quat rotation(v.rotation[0], v.rotation[1], v.rotation[2], v.rotation[3]);
	const int corners = v.cylinder ? 24 : 8;
	for (int i = 0; i < corners; i++)
	{
		JPH::Vec3 corner;
		if (v.cylinder)
		{
			const float angle = float(i / 2) * 6.28318530718f / 12;
			const float reach = v.half[0] * OutsideCircle;
			corner = JPH::Vec3(std::cos(angle) * reach, i % 2 ? v.half[1] : -v.half[1], std::sin(angle) * reach);
		}
		else
			corner = JPH::Vec3(i & 1 ? v.half[0] : -v.half[0], i & 2 ? v.half[1] : -v.half[1], i & 4 ? v.half[2] : -v.half[2]);
		corner = rotation * corner + JPH::Vec3(v.center[0], v.center[1], v.center[2]);
		points.push_back({corner.GetX(), corner.GetZ()});
		low = std::min(low, corner.GetY());
		high = std::max(high, corner.GetY());
	}
	// Monotone chain hull.
	std::sort(points.begin(), points.end(), [](Point a, Point b) { return a.x < b.x || (a.x == b.x && a.z < b.z); });
	points.erase(std::unique(points.begin(), points.end(), [](Point a, Point b) { return a.x == b.x && a.z == b.z; }), points.end());
	auto turn = [](Point a, Point b, Point c) { return (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x); };
	std::vector<Point> hull;
	for (auto p : points)
	{
		while (hull.size() >= 2 && turn(hull[hull.size() - 2], hull.back(), p) <= 0)
			hull.pop_back();
		hull.push_back(p);
	}
	const size_t lower = hull.size();
	for (int i = int(points.size()) - 2; i >= 0; i--)
	{
		while (hull.size() > lower && turn(hull[hull.size() - 2], hull.back(), points[i]) <= 0)
			hull.pop_back();
		hull.push_back(points[i]);
	}
	if (hull.size() > 1)
		hull.pop_back();
	std::vector<float> out;
	for (auto p : hull)
		out.insert(out.end(), {p.x, 0, p.z});
	return out;
}

/// The Detour area whose cost is this one, or -1. Every cost is reserved (ReserveCosts) before tiles are built.
int AreaFor(const Mesh& mesh, float cost)
{
	for (int area = GroundArea; area < mesh.costCount; area++)
	{
		if (mesh.costs[area] == cost)
			return area;
	}
	return -1;
}

/// Marks the volumes on a tile's compact heightfield: costs from low to high so the highest of overlapping areas
/// wins whatever the components' order, then blocking volumes over all of them.
bool MarkVolumes(const Mesh& mesh, const Volume* volumes, int count, rcCompactHeightfield& field)
{
	rcContext context(false);
	std::vector<int> order(count);
	for (int i = 0; i < count; i++)
		order[i] = i;
	std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return volumes[a].cost < volumes[b].cost; });
	for (int blockingPass = 0; blockingPass < 2; blockingPass++)
	{
		for (int i : order)
		{
			const Volume& v = volumes[i];
			const bool blocking = v.cost <= 0;
			if (blocking != (blockingPass == 1))
				continue;
			const int area = blocking ? RC_NULL_AREA : AreaFor(mesh, std::max(v.cost, 1.0f));
			if (area < 0)
				return false;
			float low, high;
			auto footprint = Footprint(v, low, high);
			// An obstacle also takes the floor an agent's head would reach into from below.
			if (v.obstacle)
				low -= mesh.settings.height;
			if (footprint.size() >= 9)
				rcMarkConvexPolyArea(&context, footprint.data(), int(footprint.size() / 3), low, high, (unsigned char)area, field);
		}
	}
	return true;
}

/// Builds a tile's Detour data from its heightfield, with the volumes and links on it. A tile with no floor gets no
/// data. Rebuilds after the first bake use monotone regions, which are quicker than watershed for a small change.
bool BuildTile(const Mesh& mesh, Tile& tile, const Volume* volumes, int volumeCount, const Link* links, int linkCount)
{
	if (!tile.heightfield && !RasterizeTile(mesh, tile))
		return false;
	const Settings& s = tile.bounds;
	const Settings& whole = mesh.settings;
	rcContext context(false);
	Owned<rcCompactHeightfield> field(rcAllocCompactHeightfield(), {rcFreeCompactHeightfield});
	Owned<rcContourSet> contours(rcAllocContourSet(), {rcFreeContourSet});
	Owned<rcPolyMesh> polygons(rcAllocPolyMesh(), {rcFreePolyMesh});
	Owned<rcPolyMeshDetail> detail(rcAllocPolyMeshDetail(), {rcFreePolyMeshDetail});
	if (!field || !contours || !polygons || !detail || !rcBuildCompactHeightfield(&context, HeightVoxels(s), ClimbVoxels(s), *tile.heightfield, *field))
		return false;
	// A border voxel outside the surface (the last tile can reach past it) is not floor.
	for (int z = 0; z < field->height; z++)
	{
		for (int x = 0; x < field->width; x++)
		{
			const float px = field->bmin[0] + (x + 0.5f) * field->cs, pz = field->bmin[2] + (z + 0.5f) * field->cs;
			if (px >= whole.min[0] && px < whole.max[0] && pz >= whole.min[2] && pz < whole.max[2])
				continue;
			const auto& cell = field->cells[x + z * field->width];
			for (unsigned i = cell.index; i < cell.index + cell.count; i++)
				field->areas[i] = RC_NULL_AREA;
		}
	}
	if (!MarkVolumes(mesh, volumes, volumeCount, *field) || !rcErodeWalkableArea(&context, RadiusVoxels(s), *field))
		return false;
	const bool regions = mesh.revision > 0 ? rcBuildRegionsMonotone(&context, *field, tile.border, 0, 0)
		: rcBuildDistanceField(&context, *field) && rcBuildRegions(&context, *field, tile.border, 0, 0);
	if (!regions || !rcBuildContours(&context, *field, ContourError, int(ContourEdgeLength / s.cellSize), *contours) ||
		!rcBuildPolyMesh(&context, *contours, VerticesPerPolygon, *polygons))
		return false;
	tile.data.clear();
	tile.floorPolygons = tile.polygonSlots = 0;
	if (polygons->npolys == 0)
		return true;
	if (polygons->nverts >= 0xffff || !rcBuildPolyMeshDetail(&context, *polygons, *field, s.cellSize * DetailSampleCells, s.cellHeight, *detail))
		return false;
	for (int i = 0; i < polygons->npolys; i++)
	{
		if (polygons->areas[i] == RC_WALKABLE_AREA)
			polygons->areas[i] = GroundArea;
		polygons->flags[i] = FloorFlag;
	}
	// Every link goes to every tile: Detour keeps the ones that start in it, and saves room in the tile its far end
	// lands in for the way back.
	std::vector<float> linkPoints, linkRadii;
	std::vector<unsigned char> linkDirections, linkAreas;
	std::vector<unsigned short> linkFlags;
	std::vector<unsigned> linkIds;
	for (int i = 0; i < linkCount; i++)
	{
		const Link& l = links[i];
		const int area = AreaFor(mesh, l.cost);
		if (area < 0)
			return false;
		linkPoints.insert(linkPoints.end(), l.start, l.start + 3);
		linkPoints.insert(linkPoints.end(), l.end, l.end + 3);
		linkRadii.push_back(l.radius);
		linkDirections.push_back(l.bidirectional ? DT_OFFMESH_CON_BIDIR : 0);
		linkAreas.push_back((unsigned char)area);
		linkFlags.push_back(LinkFlag);
		// 0 means "no id" to Detour.
		linkIds.push_back(unsigned(l.id) + 1);
	}
	dtNavMeshCreateParams params{};
	params.verts = polygons->verts;
	params.vertCount = polygons->nverts;
	params.polys = polygons->polys;
	params.polyAreas = polygons->areas;
	params.polyFlags = polygons->flags;
	params.polyCount = polygons->npolys;
	params.nvp = polygons->nvp;
	params.detailMeshes = detail->meshes;
	params.detailVerts = detail->verts;
	params.detailVertsCount = detail->nverts;
	params.detailTris = detail->tris;
	params.detailTriCount = detail->ntris;
	params.offMeshConVerts = linkPoints.data();
	params.offMeshConRad = linkRadii.data();
	params.offMeshConDir = linkDirections.data();
	params.offMeshConAreas = linkAreas.data();
	params.offMeshConFlags = linkFlags.data();
	params.offMeshConUserID = linkIds.data();
	params.offMeshConCount = linkCount;
	params.walkableHeight = s.height;
	params.walkableRadius = s.radius;
	params.walkableClimb = s.climb;
	params.tileX = tile.x;
	params.tileY = tile.z;
	dtVcopy(params.bmin, polygons->bmin);
	dtVcopy(params.bmax, polygons->bmax);
	params.cs = s.cellSize;
	params.ch = s.cellHeight;
	params.buildBvTree = true;
	unsigned char* data = nullptr;
	int size = 0;
	if (!dtCreateNavMeshData(&params, &data, &size))
		return false;
	tile.data.assign(data, data + size);
	dtFree(data);
	tile.floorPolygons = polygons->npolys;
	tile.polygonSlots = reinterpret_cast<const dtMeshHeader*>(tile.data.data())->polyCount;
	return true;
}

// ---- links between tiles that are not neighbours ----

bool AddPolygonLink(dtMeshTile* tile, dtPoly* poly, dtPolyRef to, unsigned char edge)
{
	const unsigned at = tile->linksFreeList;
	if (at == DT_NULL_LINK)
		return false;
	tile->linksFreeList = tile->links[at].next;
	dtLink& link = tile->links[at];
	link.ref = to;
	link.edge = edge;
	link.side = 0xff;
	link.bmin = link.bmax = 0;
	link.next = poly->firstLink;
	poly->firstLink = at;
	return true;
}

/// Detour joins a link's far end only when it lands in the link's own tile or a neighbour. This joins the rest the way
/// Detour joins those: the landing point snapped onto the nearest floor, a step from the link to it, and for a
/// two-way link a step back. Each tile has room for these: its data counts every link end inside it.
bool ConnectDistantLinks(dtNavMesh& detour)
{
	dtNavMeshQuery query;
	if (dtStatusFailed(query.init(&detour, 32)))
		return false;
	dtQueryFilter floor;
	floor.setIncludeFlags(FloorFlag);
	const dtNavMesh& reader = detour;
	for (int t = 0; t < detour.getMaxTiles(); t++)
	{
		auto* tile = const_cast<dtMeshTile*>(reader.getTile(t));
		if (!tile->header)
			continue;
		for (int c = 0; c < tile->header->offMeshConCount; c++)
		{
			dtOffMeshConnection& connection = tile->offMeshCons[c];
			dtPoly* poly = &tile->polys[connection.poly];
			// Not joined at its start (off the floor): Detour leaves it out, and so does this.
			if (poly->firstLink == DT_NULL_LINK)
				continue;
			bool landed = false;
			for (unsigned k = poly->firstLink; k != DT_NULL_LINK; k = tile->links[k].next)
				landed |= tile->links[k].edge == 1;
			if (landed)
				continue;
			const float* end = connection.pos + 3;
			const float extent[3] = {connection.rad, tile->header->walkableClimb, connection.rad};
			float point[3];
			dtPolyRef target = 0;
			if (dtStatusFailed(query.findNearestPoly(end, extent, &floor, &target, point)) || !target || dtVdist2DSqr(point, end) > connection.rad * connection.rad)
				continue;
			const dtMeshTile* targetTile;
			const dtPoly* targetPoly;
			if (dtStatusFailed(detour.getTileAndPolyByRef(target, &targetTile, &targetPoly)))
				return false;
			dtVcopy(tile->verts + poly->verts[1] * 3, point);
			if (!AddPolygonLink(tile, poly, target, 1))
				return false;
			if ((connection.flags & DT_OFFMESH_CON_BIDIR) &&
				!AddPolygonLink(const_cast<dtMeshTile*>(targetTile), const_cast<dtPoly*>(targetPoly), detour.getPolyRefBase(tile) | connection.poly, 0xff))
				return false;
		}
	}
	return true;
}

// ---- rebuilding ----

/// What a rebuild changes: the volumes and links to build with, and the box whose geometry changed (or none).
struct Change
{
	const Volume* volumes;
	int volumeCount;
	const Link* links;
	int linkCount;
	const float* geometryMin;
	const float* geometryMax;
};

/// The tiles a change touches, as flags by tile index: the tiles round each volume and link added or removed, and
/// round the geometry box, each grown by the agent's clearance border (a change there moves the tile's edges).
std::vector<bool> TouchedTiles(const Mesh& mesh, const Change& change, int tilesX, int tilesZ, float tileWidth)
{
	const Settings& s = mesh.settings;
	std::vector<bool> touched(tilesX * tilesZ, mesh.tiles.empty());
	const float border = (RadiusVoxels(s) + 3) * s.cellSize;
	auto mark = [&](float x0, float z0, float x1, float z1)
	{
		for (int z = 0; z < tilesZ; z++)
		{
			for (int x = 0; x < tilesX; x++)
			{
				const float left = s.min[0] + x * tileWidth, back = s.min[2] + z * tileWidth;
				if (left <= x1 + border && left + tileWidth >= x0 - border && back <= z1 + border && back + tileWidth >= z0 - border)
					touched[x + z * tilesX] = true;
			}
		}
	};
	auto markVolume = [&](const Volume& v)
	{
		float low, high;
		const auto footprint = Footprint(v, low, high);
		float x0 = 1e30f, x1 = -1e30f, z0 = 1e30f, z1 = -1e30f;
		for (size_t i = 0; i < footprint.size(); i += 3)
		{
			x0 = std::min(x0, footprint[i]);
			x1 = std::max(x1, footprint[i]);
			z0 = std::min(z0, footprint[i + 2]);
			z1 = std::max(z1, footprint[i + 2]);
		}
		mark(x0, z0, x1, z1);
	};
	auto markLink = [&](const Link& l)
	{
		mark(l.start[0] - l.radius, l.start[2] - l.radius, l.start[0] + l.radius, l.start[2] + l.radius);
		mark(l.end[0] - l.radius, l.end[2] - l.radius, l.end[0] + l.radius, l.end[2] + l.radius);
	};
	auto contains = [](const auto& value, const auto* list, int count)
	{
		for (int i = 0; i < count; i++)
		{
			if (std::memcmp(&value, list + i, sizeof(value)) == 0)
				return true;
		}
		return false;
	};
	for (const auto& v : mesh.volumes)
	{
		if (!contains(v, change.volumes, change.volumeCount))
			markVolume(v);
	}
	for (int i = 0; i < change.volumeCount; i++)
	{
		if (!contains(change.volumes[i], mesh.volumes.data(), int(mesh.volumes.size())))
			markVolume(change.volumes[i]);
	}
	for (const auto& l : mesh.links)
	{
		if (!contains(l, change.links, change.linkCount))
			markLink(l);
	}
	for (int i = 0; i < change.linkCount; i++)
	{
		if (!contains(change.links[i], mesh.links.data(), int(mesh.links.size())))
			markLink(change.links[i]);
	}
	if (change.geometryMin)
		mark(change.geometryMin[0], change.geometryMin[2], change.geometryMax[0], change.geometryMax[2]);
	return touched;
}

/// Gives every cost in a change an area id, keeping the ids tiles already use so untouched tiles stay right. When
/// the ids run out, they are given out afresh (`renumbered`): every tile must then be rebuilt.
bool ReserveCosts(Mesh& mesh, const Change& change, bool& renumbered)
{
	auto reserve = [&](float cost)
	{
		if (AreaFor(mesh, cost) >= 0)
			return true;
		if (mesh.costCount >= RC_WALKABLE_AREA)
			return false;
		mesh.costs[mesh.costCount++] = cost;
		return true;
	};
	auto reserveAll = [&]()
	{
		for (int i = 0; i < change.volumeCount; i++)
		{
			if (change.volumes[i].cost > 0 && !reserve(std::max(change.volumes[i].cost, 1.0f)))
				return false;
		}
		for (int i = 0; i < change.linkCount; i++)
		{
			if (!reserve(change.links[i].cost))
				return false;
		}
		return true;
	};
	renumbered = false;
	if (reserveAll())
		return true;
	std::fill(mesh.costs, mesh.costs + DT_MAX_AREAS, 1.0f);
	mesh.costCount = FirstCostArea;
	renumbered = true;
	return reserveAll();
}

/// Rebuilds the tiles a change touches and swaps in a new Detour mesh made of every tile's data. On failure the mesh
/// is left as it was.
bool Rebuild(Mesh& mesh, const Change& change)
{
	const Settings& s = mesh.settings;
	for (int i = 0; i < change.volumeCount; i++)
	{
		if (!ValidVolume(change.volumes[i]))
			return false;
	}
	for (int i = 0; i < change.linkCount; i++)
	{
		if (!ValidLink(change.links[i]))
			return false;
	}
	const bool small = (s.max[0] - s.min[0]) / s.cellSize <= SingleTileLimit && (s.max[2] - s.min[2]) / s.cellSize <= SingleTileLimit;
	const int tileCells = small ? SingleTileLimit : SmallTile;
	const float tileWidth = s.cellSize * tileCells;
	const int tilesX = int(std::ceil((s.max[0] - s.min[0]) / tileWidth)), tilesZ = int(std::ceil((s.max[2] - s.min[2]) / tileWidth));
	const int tileCount = tilesX * tilesZ;
	const bool first = mesh.tiles.empty();
	auto touched = TouchedTiles(mesh, change, tilesX, tilesZ, tileWidth);
	mesh.lastRebuilt = int(std::count(touched.begin(), touched.end(), true));
	if (mesh.lastRebuilt == 0)
		return true;

	float oldCosts[DT_MAX_AREAS];
	std::copy(mesh.costs, mesh.costs + DT_MAX_AREAS, oldCosts);
	const int oldCostCount = mesh.costCount;
	auto fail = [&]()
	{
		std::copy(oldCosts, oldCosts + DT_MAX_AREAS, mesh.costs);
		mesh.costCount = oldCostCount;
		return false;
	};
	bool renumbered;
	if (!ReserveCosts(mesh, change, renumbered))
		return fail();
	if (renumbered)
	{
		std::fill(touched.begin(), touched.end(), true);
		mesh.lastRebuilt = tileCount;
	}

	// The polygon references Detour hands out have bits for the tile and the polygon; a tile may hold no more
	// polygons than its share.
	int tileBits = 0;
	while ((1 << tileBits) < tileCount)
		tileBits++;
	const int maxPolygons = 1 << (TileAndPolygonBits - tileBits);
	const int border = RadiusVoxels(s) + 3;
	std::vector<std::unique_ptr<Tile>> staged(tileCount);
	for (int z = 0; z < tilesZ; z++)
	{
		for (int x = 0; x < tilesX; x++)
		{
			const int i = x + z * tilesX;
			if (!touched[i])
				continue;
			auto tile = std::make_unique<Tile>();
			tile->x = x;
			tile->z = z;
			tile->border = border;
			tile->bounds = s;
			tile->bounds.min[0] = s.min[0] + x * tileWidth - border * s.cellSize;
			tile->bounds.min[2] = s.min[2] + z * tileWidth - border * s.cellSize;
			tile->bounds.max[0] = std::min(s.max[0], s.min[0] + (x + 1) * tileWidth) + border * s.cellSize;
			tile->bounds.max[2] = std::min(s.max[2], s.min[2] + (z + 1) * tileWidth) + border * s.cellSize;
			// Only a geometry change needs the shapes rasterized again.
			if (!first && !change.geometryMin)
				tile->heightfield = mesh.tiles[i]->heightfield;
			if (!BuildTile(mesh, *tile, change.volumes, change.volumeCount, change.links, change.linkCount) || tile->polygonSlots > maxPolygons)
				return fail();
			staged[i] = std::move(tile);
		}
	}

	Owned<dtNavMesh> detour(dtAllocNavMesh(), {dtFreeNavMesh});
	if (!detour)
		return fail();
	dtNavMeshParams params{};
	dtVcopy(params.orig, s.min);
	params.tileWidth = params.tileHeight = tileWidth;
	params.maxTiles = tileCount;
	params.maxPolys = maxPolygons;
	if (dtStatusFailed(detour->init(&params)))
		return fail();
	// Untouched tiles go back under their old references, so a polygon reference into them stays good. A rebuilt tile
	// takes its old place with a new salt, so references into its old polygons fail.
	int floorPolygons = 0, polygonSlots = 0;
	for (int pass = 0; pass < 2; pass++)
	{
		for (int i = 0; i < tileCount; i++)
		{
			const Tile* tile = touched[i] ? staged[i].get() : mesh.tiles[i].get();
			if (tile->data.empty())
				continue;
			dtTileRef ref = mesh.detour ? mesh.detour->getTileRefAt(i % tilesX, i / tilesX, 0) : 0;
			if ((ref != 0) != (pass == 0))
				continue;
			if (ref && touched[i])
			{
				unsigned salt = (detour->decodePolyIdSalt(ref) + 1) & ((1u << SaltBits) - 1);
				ref = detour->encodePolyId(salt == 0 ? 1 : salt, detour->decodePolyIdTile(ref), 0);
			}
			auto* copy = static_cast<unsigned char*>(dtAlloc(int(tile->data.size()), DT_ALLOC_PERM));
			if (!copy)
				return fail();
			std::memcpy(copy, tile->data.data(), tile->data.size());
			if (dtStatusFailed(detour->addTile(copy, int(tile->data.size()), DT_TILE_FREE_DATA, ref, nullptr)))
			{
				dtFree(copy);
				return fail();
			}
			floorPolygons += tile->floorPolygons;
			polygonSlots += tile->polygonSlots;
		}
	}
	if (!ConnectDistantLinks(*detour))
		return fail();

	dtFreeNavMesh(mesh.detour);
	mesh.detour = detour.release();
	mesh.floorPolygons = floorPolygons;
	mesh.polygonSlots = polygonSlots;
	mesh.tilesX = tilesX;
	mesh.tilesZ = tilesZ;
	mesh.tileCells = tileCells;
	if (first)
		mesh.tiles.resize(tileCount);
	for (int i = 0; i < tileCount; i++)
	{
		if (touched[i])
			mesh.tiles[i] = std::move(staged[i]);
	}
	// The change may be the mesh's own lists (a geometry rebuild keeps the overlay).
	if (change.volumes != mesh.volumes.data())
		mesh.volumes.assign(change.volumes, change.volumes + change.volumeCount);
	if (change.links != mesh.links.data())
		mesh.links.assign(change.links, change.links + change.linkCount);
	mesh.revision++;
	return true;
}

// ---- queries ----

/// Readies a query's scratch for the mesh as it is now, with room for `nodes` (fewer when the mesh has fewer polygons).
bool Prepare(const Mesh* mesh, Query* q, int nodes = 4096)
{
	if (!mesh || !mesh->detour || !q)
		return false;
	nodes = std::clamp(std::min(nodes, mesh->polygonSlots + 8), 32, MaxQueryNodes);
	if (q->mesh != mesh || q->revision != mesh->revision || q->nodes < nodes)
	{
		if (dtStatusFailed(q->query.init(mesh->detour, nodes)))
			return false;
		q->mesh = mesh;
		q->revision = mesh->revision;
		q->nodes = nodes;
	}
	return true;
}

dtQueryFilter FilterFor(const Mesh* mesh, bool withLinks)
{
	dtQueryFilter filter;
	filter.setIncludeFlags(withLinks ? FloorFlag | LinkFlag : FloorFlag);
	for (int i = 0; i < DT_MAX_AREAS; i++)
		filter.setAreaCost(i, mesh->costs[i]);
	return filter;
}

/// The nearest floor point within `distance` (in 3D) of a point, and its polygon.
bool Sample(const Mesh* mesh, Query* q, const float* point, float distance, dtPolyRef& ref, float* found)
{
	ref = 0;
	if (!Finite(point) || !std::isfinite(distance) || distance < 0 || !Prepare(mesh, q))
		return false;
	const float reach = std::max(distance, 0.01f);
	const float extent[3] = {reach, reach, reach};
	const auto filter = FilterFor(mesh, false);
	const float limit = distance + 1e-4f;
	return dtStatusSucceed(q->query.findNearestPoly(point, extent, &filter, &ref, found)) && ref && dtVdistSqr(point, found) <= limit * limit;
}

/// Adds a corner to a query's path, with the leg that reaches it (a link's id, or -1).
void AddCorner(Query* q, const float* point, int leg = -1)
{
	if (!q->points.empty() && dtVdistSqr(q->points.data() + q->points.size() - 3, point) < 1e-10f)
		return;
	if (!q->points.empty())
		q->legs.push_back(leg);
	q->points.insert(q->points.end(), point, point + 3);
}

/// Pulls a run of the corridor straight (Detour's funnel) and adds its corners.
bool AddStraightRun(Query* q, const float* from, const float* to, const dtPolyRef* corridor, int count)
{
	const int capacity = count + 2;
	q->straight.resize(capacity * 3);
	q->straightFlags.resize(capacity);
	q->straightRefs.resize(capacity);
	int found = 0;
	const auto status = q->query.findStraightPath(from, to, corridor, count, q->straight.data(), q->straightFlags.data(), q->straightRefs.data(), &found, capacity);
	if (dtStatusFailed(status) || (status & DT_BUFFER_TOO_SMALL))
		return false;
	for (int i = 0; i < found; i++)
		AddCorner(q, q->straight.data() + i * 3);
	return true;
}

/// The nearest polygon within `snap` of a point that the last search reached, and the point on it: where a path to a
/// goal it could not reach ends instead, as the grid snaps its goal to a connected cell.
bool NearestReached(const Mesh* mesh, Query* q, const float* to, float snap, dtPolyRef& best, float* bestPoint)
{
	std::vector<dtPolyRef> candidates(mesh->polygonSlots + 1);
	int count = 0;
	const float extent[3] = {snap, snap, snap};
	const auto floor = FilterFor(mesh, false);
	const auto status = q->query.queryPolygons(to, extent, &floor, candidates.data(), &count, int(candidates.size()));
	if (dtStatusFailed(status) || (status & DT_BUFFER_TOO_SMALL))
		return false;
	best = 0;
	float nearest = snap * snap + 1e-6f;
	for (int i = 0; i < count; i++)
	{
		float closest[3];
		bool over = false;
		if (!q->query.isInClosedList(candidates[i]) || dtStatusFailed(q->query.closestPointOnPoly(candidates[i], to, closest, &over)))
			continue;
		const float d = dtVdistSqr(closest, to);
		if (d <= nearest)
		{
			nearest = d;
			best = candidates[i];
			dtVcopy(bestPoint, closest);
		}
	}
	return best != 0;
}

/// The path's corners, split at each link so both its ends are corners and its leg carries the link's id.
bool CornersOf(const Mesh* mesh, Query* q, const float* start, const float* goal, int count)
{
	float from[3];
	dtVcopy(from, start);
	int first = 0;
	for (int i = 0; i < count; i++)
	{
		const dtMeshTile* tile;
		const dtPoly* poly;
		if (dtStatusFailed(mesh->detour->getTileAndPolyByRef(q->corridor[i], &tile, &poly)))
			return false;
		if (poly->getType() != DT_POLYTYPE_OFFMESH_CONNECTION)
			continue;
		if (i == 0 || i + 1 >= count)
			return false;
		float linkStart[3], linkEnd[3];
		if (dtStatusFailed(mesh->detour->getOffMeshConnectionPolyEndPoints(q->corridor[i - 1], q->corridor[i], linkStart, linkEnd)))
			return false;
		const auto* link = mesh->detour->getOffMeshConnectionByRef(q->corridor[i]);
		if (!link || !AddStraightRun(q, from, linkStart, q->corridor.data() + first, i - first))
			return false;
		AddCorner(q, linkEnd, int(link->userId) - 1);
		dtVcopy(from, linkEnd);
		first = i + 1;
	}
	return AddStraightRun(q, from, goal, q->corridor.data() + first, count - first);
}

/// A path from `from` to `to`, its corners in q->points and each leg's link in q->legs. `budget` caps the polygons
/// searched (exceeded then says so). A goal it cannot reach snaps once to the nearest reached polygon in range.
int FindPath(const Mesh* mesh, Query* q, const float* from, const float* to, float snap, bool withLinks, int budget, int* visits, int* exceeded, dtPolyRef goalPolygon = 0)
{
	*visits = 0;
	*exceeded = 0;
	if (!q)
		return 0;
	q->points.clear();
	q->legs.clear();
	if (!Prepare(mesh, q, budget))
		return 0;
	dtPolyRef start, goal;
	float a[3], b[3];
	if (!Sample(mesh, q, from, snap, start, a) || !Sample(mesh, q, to, snap, goal, b))
		return 0;
	if (goalPolygon)
	{
		goal = goalPolygon;
		dtVcopy(b, to);
	}
	if (budget <= 0)
	{
		*exceeded = 1;
		return 0;
	}
	const auto filter = FilterFor(mesh, withLinks);
	auto status = q->query.initSlicedFindPath(start, goal, a, b, &filter);
	if (dtStatusFailed(status))
		return 0;
	if (dtStatusInProgress(status))
		status = q->query.updateSlicedFindPath(budget, visits);
	if (dtStatusInProgress(status) || (status & DT_OUT_OF_NODES))
	{
		*exceeded = 1;
		return 0;
	}
	if (dtStatusFailed(status))
		return 0;
	int count = 0;
	const int capacity = std::min(mesh->polygonSlots + 1, MaxQueryNodes);
	q->corridor.resize(capacity);
	status = q->query.finalizeSlicedFindPath(q->corridor.data(), &count, capacity);
	if (dtStatusFailed(status) || (status & DT_BUFFER_TOO_SMALL) || count <= 0)
		return 0;
	if ((status & DT_PARTIAL_RESULT) || q->corridor[count - 1] != goal)
	{
		// The search has already closed everything reachable, so the nearest of that is found without searching again.
		dtPolyRef reached;
		float point[3];
		if (goalPolygon || !NearestReached(mesh, q, to, snap, reached, point))
			return 0;
		const int spent = *visits;
		int more = 0;
		const int found = FindPath(mesh, q, from, point, snap, withLinks, budget - spent, &more, exceeded, reached);
		*visits = spent + more;
		return found;
	}
	if (!CornersOf(mesh, q, a, b, count))
	{
		q->points.clear();
		q->legs.clear();
		return 0;
	}
	return int(q->points.size() / 3);
}

/// Casts along the floor from `start` on polygon `ref` towards `to`; fraction is how far it got (0 to 1).
dtStatus CastAlong(Query* q, const dtQueryFilter& filter, dtPolyRef ref, const float* start, const float* to, float& fraction, dtPolyRef* corridor, int& count)
{
	float normal[3];
	return q->query.raycast(ref, start, to, &filter, &fraction, normal, corridor, &count, RaycastCorridor);
}

/// Whether a polygon holds the point itself (not just a nearby one).
bool Holds(Query* q, dtPolyRef ref, const float* point)
{
	float closest[3];
	bool over = false;
	return dtStatusSucceed(q->query.closestPointOnPoly(ref, point, closest, &over)) && dtVdist2DSqr(point, closest) <= 1e-8f && std::abs(closest[1] - point[1]) <= 0.1f;
}

/// Casts from a point on a vertex or edge through each polygon that holds it, and keeps the farthest any gets (with the
/// polygon it ends on). Several polygons share a vertex, and Detour may pick the one behind the ray.
float CastFromShared(Query* q, const dtQueryFilter& filter, const float* point, const float* to, dtPolyRef* corridor, dtPolyRef& last)
{
	dtPolyRef candidates[64];
	int count = 0;
	const float extent[3] = {0.001f, 0.1f, 0.001f};
	const auto status = q->query.queryPolygons(point, extent, &filter, candidates, &count, 64);
	if (dtStatusFailed(status) || (status & DT_BUFFER_TOO_SMALL))
		return -1;
	float farthest = 0;
	for (int i = 0; i < count; i++)
	{
		if (!Holds(q, candidates[i], point))
			continue;
		float fraction = 0;
		int hits = 0;
		const auto cast = CastAlong(q, filter, candidates[i], point, to, fraction, corridor, hits);
		if (dtStatusSucceed(cast) && !(cast & DT_BUFFER_TOO_SMALL) && hits > 0 && fraction > farthest)
		{
			farthest = fraction;
			last = corridor[hits - 1];
		}
	}
	return farthest;
}

/// Whether an agent can walk straight from `from` to `to`, and where it stops (`reached`). The start may be snapped up
/// or down onto the floor but not sideways, so a point inside a carved footprint is not moved out of it.
bool LineClear(const Mesh* mesh, Query* q, const float* from, const float* to, float* reached)
{
	dtVcopy(reached, from);
	if (!Finite(to) || !Prepare(mesh, q))
		return false;
	const Settings& s = mesh->settings;
	dtPolyRef start;
	float a[3];
	if (!Sample(mesh, q, from, std::max(s.climb + s.cellHeight, 0.25f), start, a) || dtVdist2DSqr(a, from) > 1e-6f)
		return false;
	const auto filter = FilterFor(mesh, false);
	dtPolyRef corridor[RaycastCorridor];
	float t = 0;
	int count = 0;
	const auto status = CastAlong(q, filter, start, a, to, t, corridor, count);
	if (dtStatusFailed(status) || (status & DT_BUFFER_TOO_SMALL))
		return false;
	dtPolyRef last = count > 0 ? corridor[count - 1] : start;
	if (t < 1e-5f)
	{
		dtPolyRef other = last;
		const float farthest = CastFromShared(q, filter, a, to, corridor, other);
		if (farthest < 0)
			return false;
		if (farthest > t)
		{
			t = farthest;
			last = other;
			count = 1;
		}
	}
	// Detour can stop exactly at a corner where four tiles meet. Carry on from there only through polygons that hold
	// that same point, so no gap in the floor or obstacle edge can be crossed this way.
	const float tileWidth = s.cellSize * mesh->tileCells;
	for (int retry = 0; t < 1 - 1e-5f && retry < mesh->tilesX + mesh->tilesZ + 16; retry++)
	{
		float point[3];
		dtVlerp(point, a, to, std::clamp(t, 0.0f, 1.0f));
		const float x = (point[0] - s.min[0]) / tileWidth, z = (point[2] - s.min[2]) / tileWidth;
		if (std::abs(x - std::round(x)) > 1e-4f && std::abs(z - std::round(z)) > 1e-4f)
			break;
		dtPolyRef end = last;
		const float advance = CastFromShared(q, filter, point, to, corridor, end);
		if (advance < 1e-5f)
			break;
		t += (1 - t) * std::min(advance, 1.0f);
		last = end;
		count = 1;
	}
	if (count <= 0)
		return false;
	dtVlerp(reached, a, to, std::clamp(t, 0.0f, 1.0f));
	float height;
	if (dtStatusSucceed(q->query.getPolyHeight(last, reached, &height)))
		reached[1] = height;
	return t >= 1 - 1e-5f && std::abs(reached[1] - to[1]) <= s.climb + s.cellHeight + 0.05f;
}

// ---- assets ----
// "TNM1", the settings, the triangle float count, then the triangles: the static shapes, built again by Recast when
// it loads. The overlay (volumes, links) comes from the scene's components, so it is not saved.

void PutWord(std::vector<unsigned char>& out, uint32_t value)
{
	for (int i = 0; i < 4; i++)
		out.push_back((unsigned char)(value >> (i * 8)));
}

void PutFloat(std::vector<unsigned char>& out, float value)
{
	uint32_t word;
	std::memcpy(&word, &value, 4);
	PutWord(out, word);
}

uint32_t GetWord(const unsigned char* data, size_t& at)
{
	uint32_t value = 0;
	for (int i = 0; i < 4; i++)
		value |= uint32_t(data[at++]) << (i * 8);
	return value;
}

float GetFloat(const unsigned char* data, size_t& at)
{
	const uint32_t word = GetWord(data, at);
	float value;
	std::memcpy(&value, &word, 4);
	return value;
}

static_assert(sizeof(Settings) == 12 * sizeof(float), "the asset stores Settings as twelve floats");
} // namespace

TN_API void* tn_nav_create(JPH_PhysicsSystem* world, const Settings* settings)
{
	if (!world || !settings || !ValidSettings(*settings))
		return nullptr;
	auto mesh = std::make_unique<Mesh>();
	mesh->settings = *settings;
	if (!CollectGeometry(world, mesh->settings, mesh->triangles) || !Rebuild(*mesh, {nullptr, 0, nullptr, 0, nullptr, nullptr}))
		return nullptr;
	return mesh.release();
}

TN_API void tn_nav_destroy(Mesh* mesh) { delete mesh; }

/// Takes the world's geometry again and rebuilds the tiles round the box that changed.
TN_API bool tn_nav_rebuild(Mesh* mesh, JPH_PhysicsSystem* world, const float* minimum, const float* maximum)
{
	if (!mesh || !world || !Finite(minimum) || !Finite(maximum))
		return false;
	for (int i = 0; i < 3; i++)
	{
		if (maximum[i] < minimum[i])
			return false;
	}
	std::vector<float> fresh;
	if (!CollectGeometry(world, mesh->settings, fresh))
		return false;
	mesh->triangles.swap(fresh);
	if (Rebuild(*mesh, {mesh->volumes.data(), int(mesh->volumes.size()), mesh->links.data(), int(mesh->links.size()), minimum, maximum}))
		return true;
	mesh->triangles.swap(fresh);
	return false;
}

/// Replaces the volumes and links, rebuilding the tiles that changed.
TN_API bool tn_nav_overlay(Mesh* mesh, const Volume* volumes, int volumeCount, const Link* links, int linkCount)
{
	if (!mesh || volumeCount < 0 || volumeCount > MaxVolumes || linkCount < 0 || linkCount > MaxLinks)
		return false;
	return Rebuild(*mesh, {volumes, volumeCount, links, linkCount, nullptr, nullptr});
}

TN_API int tn_nav_tile_count(const Mesh* mesh) { return mesh ? int(mesh->tiles.size()) : 0; }
TN_API int tn_nav_tiles_rebuilt(const Mesh* mesh) { return mesh ? mesh->lastRebuilt : 0; }
TN_API int tn_nav_polygons(const Mesh* mesh) { return mesh ? mesh->floorPolygons : 0; }
TN_API void tn_nav_config(const Mesh* mesh, Settings* settings)
{
	if (mesh && settings)
		*settings = mesh->settings;
}

TN_API void* tn_nav_query_create() { return new Query(); }
TN_API void tn_nav_query_destroy(Query* q) { delete q; }

/// The nearest floor point within `distance`, and a handle to its polygon (0: none). A handle is the polygon's place
/// in the mesh without Detour's salt, so it stays a positive int32; it names that place until the tile is rebuilt.
TN_API uint32_t tn_nav_sample(const Mesh* mesh, Query* q, const float* point, float distance, float* found)
{
	dtPolyRef ref;
	if (!Sample(mesh, q, point, distance, ref, found))
		return 0;
	return (uint32_t(ref) & ((1u << TileAndPolygonBits) - 1)) + 1;
}

/// Whether a handle from tn_nav_sample names a floor polygon now.
TN_API bool tn_nav_valid_poly(const Mesh* mesh, uint32_t handle)
{
	if (!mesh || !mesh->detour || handle == 0)
		return false;
	const dtPolyRef ref = handle - 1;
	const unsigned tileIndex = mesh->detour->decodePolyIdTile(ref), polygon = mesh->detour->decodePolyIdPoly(ref);
	if (tileIndex >= unsigned(mesh->detour->getMaxTiles()))
		return false;
	const dtMeshTile* tile = static_cast<const dtNavMesh*>(mesh->detour)->getTile(int(tileIndex));
	return tile->header && polygon < unsigned(tile->header->polyCount) && (tile->polys[polygon].flags & FloorFlag) != 0;
}

TN_API int tn_nav_path(const Mesh* mesh, Query* q, const float* from, const float* to, float snap, int withLinks, int budget, int* visits, int* exceeded)
{
	return FindPath(mesh, q, from, to, snap, withLinks != 0, budget, visits, exceeded);
}

TN_API const float* tn_nav_points(const Query* q) { return q->points.data(); }
TN_API const int32_t* tn_nav_legs(const Query* q) { return q->legs.data(); }

TN_API bool tn_nav_line(const Mesh* mesh, Query* q, const float* from, const float* to, float* reached) { return LineClear(mesh, q, from, to, reached); }

TN_API int tn_nav_save_size(const Mesh* mesh) { return mesh ? int(AssetHeaderBytes + mesh->triangles.size() * 4) : 0; }

TN_API bool tn_nav_save(const Mesh* mesh, unsigned char* data, int size)
{
	if (!mesh || size != tn_nav_save_size(mesh))
		return false;
	std::vector<unsigned char> bytes;
	bytes.reserve(size);
	PutWord(bytes, AssetMagic);
	float settings[12];
	std::memcpy(settings, &mesh->settings, sizeof(settings));
	for (float value : settings)
		PutFloat(bytes, value);
	PutWord(bytes, uint32_t(mesh->triangles.size()));
	for (float value : mesh->triangles)
		PutFloat(bytes, value);
	std::memcpy(data, bytes.data(), bytes.size());
	return true;
}

TN_API void* tn_nav_load(const unsigned char* bytes, int size)
{
	if (!bytes || size < AssetHeaderBytes)
		return nullptr;
	size_t at = 0;
	if (GetWord(bytes, at) != AssetMagic)
		return nullptr;
	auto mesh = std::make_unique<Mesh>();
	float settings[12];
	for (float& value : settings)
		value = GetFloat(bytes, at);
	std::memcpy(&mesh->settings, settings, sizeof(settings));
	if (!ValidSettings(mesh->settings))
		return nullptr;
	const uint32_t count = GetWord(bytes, at);
	if (count > MaxTriangleFloats || count % 9 != 0 || uint64_t(AssetHeaderBytes) + uint64_t(count) * 4 != uint64_t(size))
		return nullptr;
	mesh->triangles.resize(count);
	for (float& value : mesh->triangles)
	{
		value = GetFloat(bytes, at);
		if (!std::isfinite(value) || std::abs(value) > 1e8f)
			return nullptr;
	}
	if (!Rebuild(*mesh, {nullptr, 0, nullptr, 0, nullptr, nullptr}))
		return nullptr;
	return mesh.release();
}

/// The floor's polygons as triangles (three points each) for drawing, up to `capacity` points. Returns how many
/// points there are in all.
TN_API int tn_nav_debug(const Mesh* mesh, float* points, int capacity)
{
	if (!mesh || !mesh->detour)
		return 0;
	int count = 0;
	const dtNavMesh& detour = *mesh->detour;
	for (int t = 0; t < detour.getMaxTiles(); t++)
	{
		const dtMeshTile* tile = detour.getTile(t);
		if (!tile->header)
			continue;
		for (int p = 0; p < tile->header->polyCount; p++)
		{
			const dtPoly& poly = tile->polys[p];
			if (poly.getType() != DT_POLYTYPE_GROUND)
				continue;
			for (int i = 2; i < poly.vertCount; i++)
			{
				if (points && count + 3 <= capacity)
				{
					dtVcopy(points + count * 3, tile->verts + poly.verts[0] * 3);
					dtVcopy(points + (count + 1) * 3, tile->verts + poly.verts[i - 1] * 3);
					dtVcopy(points + (count + 2) * 3, tile->verts + poly.verts[i] * 3);
				}
				count += 3;
			}
		}
	}
	return count;
}
