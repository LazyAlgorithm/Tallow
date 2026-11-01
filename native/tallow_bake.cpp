// Ray tracing for the light baker (Engine/src/Lighting/LightBaker.bf): a bounding volume hierarchy over a scene's
// triangles, built once, then asked for the nearest hit along rays, or only whether anything is in the way.
// Read-only after it is built, so several threads may trace at once.

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <vector>

#if defined(_WIN32)
#define TN_API extern "C" __declspec(dllexport)
#else
#define TN_API extern "C" __attribute__((visibility("default")))
#endif

namespace
{
struct Vec3
{
	float x, y, z;
};

inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 Cross(Vec3 a, Vec3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float Dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

struct Box
{
	Vec3 lo{FLT_MAX, FLT_MAX, FLT_MAX}, hi{-FLT_MAX, -FLT_MAX, -FLT_MAX};
	void Add(Vec3 p)
	{
		lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
		hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
	}
	void Add(const Box& b) { Add(b.lo); Add(b.hi); }
	float Area() const
	{
		Vec3 d = hi - lo;
		if (d.x < 0) return 0;
		return 2 * (d.x * d.y + d.y * d.z + d.z * d.x);
	}
};

struct Node
{
	Box box;
	// Inner: left child at index + 1, right at `right`. Leaf: `first` triangle, `count` of them.
	int32_t right = 0, first = 0, count = 0;
};

struct Bvh
{
	std::vector<Vec3> a, e1, e2; // per triangle, in BVH order: a corner and the two edges from it
	std::vector<int32_t> ids;     // the caller's triangle index for each
	std::vector<Node> nodes;
};

struct Build
{
	std::vector<Box> boxes;
	std::vector<Vec3> centres;
	std::vector<int32_t> order;
	std::vector<Node>* nodes;

	int32_t Make(int32_t first, int32_t count)
	{
		int32_t index = (int32_t)nodes->size();
		nodes->emplace_back();
		Box box, centreBox;
		for (int32_t i = first; i < first + count; i++)
		{
			box.Add(boxes[order[i]]);
			centreBox.Add(centres[order[i]]);
		}
		(*nodes)[index].box = box;
		if (count <= 4)
		{
			(*nodes)[index].first = first;
			(*nodes)[index].count = count;
			return index;
		}
		// Binned surface area split along each axis; the cheapest wins.
		const int Bins = 12;
		float bestCost = FLT_MAX;
		int bestAxis = -1, bestSplit = 0;
		for (int axis = 0; axis < 3; axis++)
		{
			float lo = (&centreBox.lo.x)[axis], hi = (&centreBox.hi.x)[axis];
			if (hi - lo < 1e-9f)
				continue;
			Box binBox[Bins];
			int binCount[Bins] = {};
			float scale = Bins / (hi - lo);
			for (int32_t i = first; i < first + count; i++)
			{
				int bin = std::min(Bins - 1, (int)(((&centres[order[i]].x)[axis] - lo) * scale));
				binBox[bin].Add(boxes[order[i]]);
				binCount[bin]++;
			}
			float rightArea[Bins];
			int rightCount[Bins];
			Box acc;
			int n = 0;
			for (int b = Bins - 1; b > 0; b--)
			{
				acc.Add(binBox[b]);
				n += binCount[b];
				rightArea[b] = acc.Area();
				rightCount[b] = n;
			}
			acc = Box();
			n = 0;
			for (int b = 0; b < Bins - 1; b++)
			{
				acc.Add(binBox[b]);
				n += binCount[b];
				if (n == 0 || rightCount[b + 1] == 0)
					continue;
				float cost = acc.Area() * n + rightArea[b + 1] * rightCount[b + 1];
				if (cost < bestCost)
				{
					bestCost = cost;
					bestAxis = axis;
					bestSplit = b;
				}
			}
		}
		int32_t middle;
		if (bestAxis < 0)
			middle = first + count / 2;
		else
		{
			float lo = (&centreBox.lo.x)[bestAxis], hi = (&centreBox.hi.x)[bestAxis];
			float scale = Bins / (hi - lo);
			auto it = std::partition(order.begin() + first, order.begin() + first + count, [&](int32_t t) {
				return std::min(Bins - 1, (int)(((&centres[t].x)[bestAxis] - lo) * scale)) <= bestSplit;
			});
			middle = (int32_t)(it - order.begin());
			if (middle == first || middle == first + count)
				middle = first + count / 2;
		}
		Make(first, middle - first);
		int32_t right = Make(middle, first + count - middle);
		(*nodes)[index].right = right;
		return index;
	}
};

inline bool HitBox(const Box& b, Vec3 o, Vec3 inv, float tMax)
{
	float t0 = (b.lo.x - o.x) * inv.x, t1 = (b.hi.x - o.x) * inv.x;
	float tmin = std::min(t0, t1), tmax = std::max(t0, t1);
	t0 = (b.lo.y - o.y) * inv.y; t1 = (b.hi.y - o.y) * inv.y;
	tmin = std::max(tmin, std::min(t0, t1)); tmax = std::min(tmax, std::max(t0, t1));
	t0 = (b.lo.z - o.z) * inv.z; t1 = (b.hi.z - o.z) * inv.z;
	tmin = std::max(tmin, std::min(t0, t1)); tmax = std::min(tmax, std::max(t0, t1));
	return tmax >= std::max(tmin, 0.0f) && tmin <= tMax;
}

// Nearest hit closer than tMax: the triangle (the caller's index), or -1. anyHit stops at the first one found.
int32_t Trace(const Bvh& bvh, Vec3 o, Vec3 d, float tMax, bool anyHit, float& tOut, float& uOut, float& vOut, bool& backOut)
{
	if (bvh.nodes.empty())
		return -1;
	Vec3 inv = {1.0f / (d.x != 0 ? d.x : 1e-30f), 1.0f / (d.y != 0 ? d.y : 1e-30f), 1.0f / (d.z != 0 ? d.z : 1e-30f)};
	int32_t stack[64];
	int depth = 0;
	stack[depth++] = 0;
	int32_t best = -1;
	while (depth > 0)
	{
		const Node& node = bvh.nodes[stack[--depth]];
		if (!HitBox(node.box, o, inv, tMax))
			continue;
		if (node.count > 0)
		{
			for (int32_t i = node.first; i < node.first + node.count; i++)
			{
				Vec3 p = Cross(d, bvh.e2[i]);
				float det = Dot(bvh.e1[i], p);
				if (std::fabs(det) < 1e-12f)
					continue;
				float invDet = 1.0f / det;
				Vec3 s = o - bvh.a[i];
				float u = Dot(s, p) * invDet;
				if (u < 0 || u > 1)
					continue;
				Vec3 q = Cross(s, bvh.e1[i]);
				float v = Dot(d, q) * invDet;
				if (v < 0 || u + v > 1)
					continue;
				float t = Dot(bvh.e2[i], q) * invDet;
				if (t <= 0 || t >= tMax)
					continue;
				tMax = t;
				best = bvh.ids[i];
				tOut = t;
				uOut = u;
				vOut = v;
				// Tallow's front faces wind clockwise: seen from the front, the corners' cross product points away.
				backOut = det < 0;
				if (anyHit)
					return best;
			}
		}
		else if (depth < 62)
		{
			stack[depth++] = node.right;
			stack[depth++] = (int32_t)(&node - bvh.nodes.data()) + 1;
		}
	}
	return best;
}
} // namespace

/// A BVH over triangles: positions are x, y, z per vertex, three indices per triangle.
TN_API void* tn_bake_create(const float* positions, int32_t vertexCount, const uint32_t* indices, int32_t triangleCount)
{
	auto bvh = new Bvh();
	Build build;
	build.nodes = &bvh->nodes;
	build.boxes.resize(triangleCount);
	build.centres.resize(triangleCount);
	build.order.resize(triangleCount);
	auto corner = [&](uint32_t i) -> Vec3 {
		if ((int32_t)i >= vertexCount)
			return {0, 0, 0};
		return {positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]};
	};
	for (int32_t t = 0; t < triangleCount; t++)
	{
		Box box;
		box.Add(corner(indices[t * 3]));
		box.Add(corner(indices[t * 3 + 1]));
		box.Add(corner(indices[t * 3 + 2]));
		build.boxes[t] = box;
		build.centres[t] = {(box.lo.x + box.hi.x) * 0.5f, (box.lo.y + box.hi.y) * 0.5f, (box.lo.z + box.hi.z) * 0.5f};
		build.order[t] = t;
	}
	if (triangleCount > 0)
	{
		bvh->nodes.reserve(triangleCount * 2);
		build.Make(0, triangleCount);
	}
	bvh->a.resize(triangleCount);
	bvh->e1.resize(triangleCount);
	bvh->e2.resize(triangleCount);
	bvh->ids.resize(triangleCount);
	for (int32_t i = 0; i < triangleCount; i++)
	{
		int32_t t = build.order[i];
		Vec3 a = corner(indices[t * 3]), b = corner(indices[t * 3 + 1]), c = corner(indices[t * 3 + 2]);
		bvh->a[i] = a;
		bvh->e1[i] = b - a;
		bvh->e2[i] = c - a;
		bvh->ids[i] = t;
	}
	return bvh;
}

TN_API void tn_bake_destroy(void* bvh) { delete (Bvh*)bvh; }

/// Nearest hits for `count` rays (origin x, y, z, direction x, y, z, longest distance: 7 floats each). For each:
/// the triangle (-1: none), and distance, u, v (the hit is a + u * (b - a) + v * (c - a)), and 1 when it is the
/// triangle's back, in `hits` (4 floats each).
TN_API void tn_bake_intersect(void* handle, const float* rays, int32_t count, int32_t* triangles, float* hits)
{
	auto& bvh = *(Bvh*)handle;
	for (int32_t r = 0; r < count; r++)
	{
		const float* ray = rays + r * 7;
		float t = 0, u = 0, v = 0;
		bool back = false;
		triangles[r] = Trace(bvh, {ray[0], ray[1], ray[2]}, {ray[3], ray[4], ray[5]}, ray[6], false, t, u, v, back);
		hits[r * 4] = t;
		hits[r * 4 + 1] = u;
		hits[r * 4 + 2] = v;
		hits[r * 4 + 3] = back ? 1.0f : 0.0f;
	}
}

/// Whether anything is in the way of each ray (same layout as tn_bake_intersect): 1 blocked, 0 clear.
TN_API void tn_bake_occluded(void* handle, const float* rays, int32_t count, uint8_t* blocked)
{
	auto& bvh = *(Bvh*)handle;
	for (int32_t r = 0; r < count; r++)
	{
		const float* ray = rays + r * 7;
		float t, u, v;
		bool back;
		blocked[r] = Trace(bvh, {ray[0], ray[1], ray[2]}, {ray[3], ray[4], ray[5]}, ray[6], true, t, u, v, back) >= 0 ? 1 : 0;
	}
}
