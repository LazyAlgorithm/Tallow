// Automatic skin weights for the rigger (Engine/src/Rigging/AutoWeights.bf, docs/rigging.md).
//
// The weights are "bone heat" (Baran and Popović, Pinocchio, 2007): each bone warms the surface it can see nearest,
// and the heat spreads over the surface. For bone j it solves (L + MH) w = MH p, where L is the surface's cotangent
// Laplacian (negative cotangents left out, so that weights stay between 0 and 1), M each vertex's share of the area,
// H a vertex's heat (1 / its distance to its nearest bone, squared) and p the share of that heat bone j gives it.
// Each bone is a separate solve (conjugate gradients with a diagonal preconditioner), shared out over threads.

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <thread>
#include <vector>

#if defined(_WIN32)
#define TN_API extern "C" __declspec(dllexport)
#else
#define TN_API extern "C" __attribute__((visibility("default")))
#endif

namespace
{
	struct Sparse
	{
		std::vector<int> start;   // row i's entries are start[i] .. start[i + 1]
		std::vector<int> column;
		std::vector<double> value;
		std::vector<double> diagonal;
	};

	double Cot(const float* a, const float* b, const float* c)
	{
		// The cotangent of the angle at a, between ab and ac.
		const double u[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] };
		const double v[3] = { c[0] - a[0], c[1] - a[1], c[2] - a[2] };
		const double dot = u[0] * v[0] + u[1] * v[1] + u[2] * v[2];
		const double cx = u[1] * v[2] - u[2] * v[1], cy = u[2] * v[0] - u[0] * v[2], cz = u[0] * v[1] - u[1] * v[0];
		const double cross = std::sqrt(cx * cx + cy * cy + cz * cz);
		return cross > 1e-20 ? dot / cross : 0.0;
	}
}

// positions: 3 floats a vertex (welded: one vertex for each place). triangles: 3 indices each. heat: H for each
// vertex. nearest / shares: for each vertex, `perVertex` bones (-1 for none) and the share of its heat each gets.
// weights: vertexCount * boneCount, written. Returns how many bones were solved.
TN_API int tn_rig_heat_weights(const float* positions, int vertexCount, const int* triangles, int triangleCount, const float* heat,
	const int* nearest, const float* shares, int perVertex, int boneCount, int iterations, float* weights)
{
	if (vertexCount <= 0 || boneCount <= 0) return 0;
	const int n = vertexCount;
	std::vector<double> area(n, 0.0);
	// Edge weights, gathered per vertex as (neighbour, weight) and summed.
	std::vector<std::vector<std::pair<int, double>>> rows(n);
	auto addEdge = [&](int i, int j, double w)
	{
		for (auto& entry : rows[i])
			if (entry.first == j) { entry.second += w; return; }
		rows[i].push_back({ j, w });
	};
	for (int t = 0; t < triangleCount; t++)
	{
		const int i0 = triangles[t * 3], i1 = triangles[t * 3 + 1], i2 = triangles[t * 3 + 2];
		if (i0 == i1 || i1 == i2 || i0 == i2) continue;
		const float* p0 = positions + i0 * 3;
		const float* p1 = positions + i1 * 3;
		const float* p2 = positions + i2 * 3;
		const double u[3] = { p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
		const double v[3] = { p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
		const double cx = u[1] * v[2] - u[2] * v[1], cy = u[2] * v[0] - u[0] * v[2], cz = u[0] * v[1] - u[1] * v[0];
		const double a = 0.5 * std::sqrt(cx * cx + cy * cy + cz * cz);
		area[i0] += a / 3; area[i1] += a / 3; area[i2] += a / 3;
		// Each edge takes half the cotangent of the angle across from it (negative ones left out).
		const double c0 = std::max(Cot(p0, p1, p2), 0.0) * 0.5;
		const double c1 = std::max(Cot(p1, p2, p0), 0.0) * 0.5;
		const double c2 = std::max(Cot(p2, p0, p1), 0.0) * 0.5;
		// A sliver's edges still join (a little), so that no part of the surface is cut off.
		const double floor = 1e-3;
		addEdge(i1, i2, c0 + floor); addEdge(i2, i1, c0 + floor);
		addEdge(i2, i0, c1 + floor); addEdge(i0, i2, c1 + floor);
		addEdge(i0, i1, c2 + floor); addEdge(i1, i0, c2 + floor);
	}
	Sparse L;
	L.start.resize(n + 1);
	L.diagonal.resize(n);
	for (int i = 0; i < n; i++)
	{
		L.start[i] = (int)L.column.size();
		double sum = 0;
		for (const auto& entry : rows[i])
		{
			L.column.push_back(entry.first);
			L.value.push_back(-entry.second);
			sum += entry.second;
		}
		L.diagonal[i] = sum + area[i] * heat[i];
	}
	L.start[n] = (int)L.column.size();
	rows.clear();

	// Which bones anybody is nearest to (the others are left at nothing).
	std::vector<char> used(boneCount, 0);
	for (int i = 0; i < n * perVertex; i++)
		if (nearest[i] >= 0 && nearest[i] < boneCount) used[nearest[i]] = 1;
	std::fill(weights, weights + (size_t)n * boneCount, 0.0f);

	std::atomic<int> next(0), solved(0);
	auto worker = [&]()
	{
		std::vector<double> x(n), b(n), r(n), z(n), p(n), q(n);
		for (;;)
		{
			const int bone = next.fetch_add(1);
			if (bone >= boneCount) return;
			if (!used[bone]) continue;
			double bNorm = 0;
			for (int i = 0; i < n; i++)
			{
				double share = 0;
				for (int k = 0; k < perVertex; k++)
					if (nearest[i * perVertex + k] == bone) share += shares[i * perVertex + k];
				b[i] = area[i] * heat[i] * share;
				x[i] = share;
				bNorm += b[i] * b[i];
			}
			bNorm = std::sqrt(bNorm);
			if (bNorm <= 0) continue;
			// r = b - A x
			for (int i = 0; i < n; i++)
			{
				double ax = L.diagonal[i] * x[i];
				for (int e = L.start[i]; e < L.start[i + 1]; e++) ax += L.value[e] * x[L.column[e]];
				r[i] = b[i] - ax;
				z[i] = L.diagonal[i] > 0 ? r[i] / L.diagonal[i] : r[i];
				p[i] = z[i];
			}
			double rz = 0;
			for (int i = 0; i < n; i++) rz += r[i] * z[i];
			for (int it = 0; it < iterations; it++)
			{
				double pq = 0;
				for (int i = 0; i < n; i++)
				{
					double ap = L.diagonal[i] * p[i];
					for (int e = L.start[i]; e < L.start[i + 1]; e++) ap += L.value[e] * p[L.column[e]];
					q[i] = ap;
					pq += p[i] * ap;
				}
				if (pq <= 0) break;
				const double alpha = rz / pq;
				double rNorm = 0;
				for (int i = 0; i < n; i++)
				{
					x[i] += alpha * p[i];
					r[i] -= alpha * q[i];
					rNorm += r[i] * r[i];
				}
				if (std::sqrt(rNorm) < 1e-6 * bNorm) break;
				double rzNext = 0;
				for (int i = 0; i < n; i++)
				{
					z[i] = L.diagonal[i] > 0 ? r[i] / L.diagonal[i] : r[i];
					rzNext += r[i] * z[i];
				}
				const double beta = rzNext / rz;
				rz = rzNext;
				for (int i = 0; i < n; i++) p[i] = z[i] + beta * p[i];
			}
			for (int i = 0; i < n; i++)
				weights[(size_t)i * boneCount + bone] = (float)std::min(std::max(x[i], 0.0), 1.0);
			solved.fetch_add(1);
		}
	};
	const unsigned count = std::max(1u, std::min(std::thread::hardware_concurrency(), 16u));
#if defined(__EMSCRIPTEN__)
	worker();
#else
	std::vector<std::thread> threads;
	for (unsigned t = 1; t < count; t++) threads.emplace_back(worker);
	worker();
	for (auto& thread : threads) thread.join();
#endif
	return solved.load();
}
