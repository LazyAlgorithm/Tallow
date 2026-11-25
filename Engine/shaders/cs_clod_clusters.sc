// Culling for cluster LOD drawing, step two: one group per work node, one thread per cluster. A cluster is drawn when
// its own error is small enough on screen and its parent group's is not (so exactly one level of the hierarchy covers
// each surface), and it is in view and not turned away. Run twice: mode 0 counts the clusters each bin gets, mode 1
// writes them into the bins' places (see include/clod.sh).
//
// With occlusion (u_clodOcc.x): in the first phase a cluster that the picture of last frame hides (judged where it was then)
// goes to the deferred list instead of the bins, in the write run; in the second phase the clusters of the instances that
// were deferred are tested against the picture of the first phase, and so are the deferred clusters themselves
// (u_clodCounts.y = 1: the threads run over that list, which have passed every other test already).
#include "bgfx_compute.sh"
#include "clod.sh"

BUFFER_RO(b_pool, uint, 0);
BUFFER_RO(b_instances, uint, 1);
BUFFER_RO(b_nodes, uint, 2);
BUFFER_RW(b_control, uint, 3);
BUFFER_RW(b_visible, uint, 4);
BUFFER_RW(b_defer, uint, 5);
#define CLOD_HZB_REGISTER 6
#include "clod_hzb.sh"

uniform vec4 u_clodPlanes[6]; // the planes round what is in view, facing in
uniform vec4 u_clodCam;       // xyz: the eye, w: 1 when the view has no perspective
uniform vec4 u_clodLod;       // x: pixels per unit of error at distance 1, y: the nearest distance, z: the error that is small enough (pixels), w: 1 to cull clusters turned away
uniform vec4 u_clodCounts;    // x: the step (0 count, 1 write), y: 1 to take the clusters from the deferred list, z: room for work nodes
uniform vec4 u_clodOcc;       // x: 0 no occlusion, 1 first phase, 2 second phase; y: room for deferred instances, z: room for deferred clusters

float lf(uint index)
{
	return uintBitsToFloat(b_pool[index]);
}

float inf(uint index)
{
	return uintBitsToFloat(b_instances[index]);
}

// How many pixels an error of `error` units spans on a sphere (centre c, radius r) in world space.
float projected(float error, vec3 c, float r)
{
	if (u_clodCam.w > 0.5)
	{
		return error * u_clodLod.x;
	}
	float distance = max(length(c - u_clodCam.xyz) - r, u_clodLod.y);
	return error / distance * u_clodLod.x;
}

NUM_THREADS(64, 1, 1)
void main()
{
	bool retest = u_clodCounts.y > 0.5;
	uint instance;
	uint cluster;
	uint lane = uint(gl_LocalInvocationID.x);
	if (!retest)
	{
		uint node = uint(gl_WorkGroupID.y) * CLOD_NODE_GROUPS_X + uint(gl_WorkGroupID.x);
		if (node >= min(b_control[CLOD_CTRL_NODES], uint(u_clodCounts.z)))
		{
			return;
		}
		instance = b_nodes[node * 4u];
		uint first = b_nodes[node * 4u + 1u];
		uint count = b_nodes[node * 4u + 2u];
		if (lane >= count)
		{
			return;
		}
		cluster = b_instances[instance * CLOD_INSTANCE_WORDS + 36u] + (first + lane) * CLOD_CLUSTER_WORDS;
	}
	else
	{
		uint index = uint(gl_WorkGroupID.x) * 64u + lane;
		if (index >= min(b_defer[CLOD_DEFER_CLUSTERS], uint(u_clodOcc.z)))
		{
			return;
		}
		uint entry = CLOD_DEFER_HEADER + uint(u_clodOcc.y) + index * 2u;
		instance = b_defer[entry];
		cluster = b_defer[entry + 1u];
	}
	uint at = instance * CLOD_INSTANCE_WORDS;
	vec4 col0 = vec4(inf(at), inf(at + 1u), inf(at + 2u), 0.0);
	vec4 col1 = vec4(inf(at + 4u), inf(at + 5u), inf(at + 6u), 0.0);
	vec4 col2 = vec4(inf(at + 8u), inf(at + 9u), inf(at + 10u), 0.0);
	vec3 col3 = vec3(inf(at + 12u), inf(at + 13u), inf(at + 14u));
	float scale = inf(at + 39u);

	vec3 local = vec3(lf(cluster + 4u), lf(cluster + 5u), lf(cluster + 6u));
	vec3 center = col0.xyz * local.x + col1.xyz * local.y + col2.xyz * local.z + col3;
	float radius = lf(cluster + 7u) * scale;
	uint meta = b_instances[at + 38u];
	uint bin = meta & 0xFFFFu;

	if (retest)
	{
		// A cluster that passed every test but the occlusion one in the first phase.
		if (hzbHidden(center, radius))
		{
			return;
		}
	}
	else
	{
		// In view.
		for (int p = 0; p < 6; p++)
		{
			if (dot(u_clodPlanes[p].xyz, center) + u_clodPlanes[p].w < -radius)
			{
				return;
			}
		}

		// The level of detail: this cluster's error is small enough, its parent's is too big.
		float parentError = lf(cluster + 13u);
		if (parentError < 1.0e30)
		{
			uint group = b_pool[cluster + 14u];
			vec3 gm = vec3(lf(group), lf(group + 1u), lf(group + 2u));
			vec3 gc = col0.xyz * gm.x + col1.xyz * gm.y + col2.xyz * gm.z + col3;
			if (projected(parentError * scale, gc, lf(group + 3u) * scale) <= u_clodLod.z)
			{
				return;
			}
		}
		float selfError = lf(cluster + 12u);
		if (selfError > 0.0)
		{
			uint refined = b_pool[cluster + 15u];
			vec3 rc = center;
			float rr = radius;
			if (refined != 0xFFFFFFFFu)
			{
				vec3 rl = vec3(lf(refined), lf(refined + 1u), lf(refined + 2u));
				rc = col0.xyz * rl.x + col1.xyz * rl.y + col2.xyz * rl.z + col3;
				rr = lf(refined + 3u) * scale;
			}
			if (projected(selfError * scale, rc, rr) > u_clodLod.z)
			{
				return;
			}
		}

		// Turned away: every triangle of the cluster faces from the eye (not for a surface seen from both sides).
		if (u_clodLod.w > 0.5 && (meta & 0x10000u) == 0u)
		{
			float cutoff = lf(cluster + 11u);
			if (cutoff < 1.0)
			{
				vec3 axis = vec3(lf(cluster + 8u), lf(cluster + 9u), lf(cluster + 10u));
				vec3 c0 = cross(col1.xyz, col2.xyz);
				vec3 c1 = cross(col2.xyz, col0.xyz);
				vec3 c2 = cross(col0.xyz, col1.xyz);
				float orientation = dot(col0.xyz, c0) < 0.0 ? -1.0 : 1.0;
				vec3 worldAxis = normalize((c0 * axis.x + c1 * axis.y + c2 * axis.z) * orientation);
				vec3 toCluster = center - u_clodCam.xyz;
				if (dot(toCluster, worldAxis) >= cutoff * length(toCluster) + radius)
				{
					return;
				}
			}
		}

		// Hidden behind what the picture of last frame shows, where the cluster was then: the second phase takes it from here
		// (the write run does the listing, so that each cluster is listed once).
		if (u_clodOcc.x > 1.5)
		{
			if (hzbHidden(center, radius))
			{
				return;
			}
		}
		else if (u_clodOcc.x > 0.5)
		{
			vec4 p0 = vec4(inf(at + 20u), inf(at + 21u), inf(at + 22u), inf(at + 23u));
			vec4 p1 = vec4(inf(at + 24u), inf(at + 25u), inf(at + 26u), inf(at + 27u));
			vec4 p2 = vec4(inf(at + 28u), inf(at + 29u), inf(at + 30u), inf(at + 31u));
			vec3 before = vec3(dot(p0.xyz, local) + p0.w, dot(p1.xyz, local) + p1.w, dot(p2.xyz, local) + p2.w);
			if (hzbHidden(before, radius))
			{
				if (u_clodCounts.x > 0.5)
				{
					uint slot;
					atomicFetchAndAdd(b_defer[CLOD_DEFER_CLUSTERS], 1u, slot);
					if (slot < uint(u_clodOcc.z))
					{
						uint entry = CLOD_DEFER_HEADER + uint(u_clodOcc.y) + slot * 2u;
						b_defer[entry] = instance;
						b_defer[entry + 1u] = cluster;
					}
				}
				return;
			}
		}
	}

	if (u_clodCounts.x < 0.5)
	{
		uint old;
		atomicFetchAndAdd(b_control[CLOD_CTRL_BINS + bin], 1u, old);
	}
	else
	{
		uint slot;
		atomicFetchAndAdd(b_control[CLOD_CTRL_BINS + CLOD_MAX_BINS + bin], 1u, slot);
		if (slot < b_control[CLOD_CTRL_BINS + bin])
		{
			uint entry = CLOD_VISIBLE_HEADER + (b_visible[bin] + slot) * 2u;
			b_visible[entry] = instance;
			b_visible[entry + 1u] = cluster;
			uint old;
			atomicFetchAndAdd(b_control[CLOD_CTRL_TRIANGLES], b_pool[cluster + 3u], old);
		}
	}
}
