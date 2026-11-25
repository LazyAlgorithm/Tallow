// Culling for cluster LOD drawing, step two: one group per work node, one thread per cluster. A cluster is drawn when
// its own error is small enough on screen and its parent group's is not (so exactly one level of the hierarchy covers
// each surface), and it is in view and not turned away. Run twice: mode 0 counts the clusters each bin gets, mode 1
// writes them into the bins' places (see include/clod.sh).
#include "bgfx_compute.sh"
#include "clod.sh"

BUFFER_RO(b_pool, uint, 0);
BUFFER_RO(b_instances, uint, 1);
BUFFER_RO(b_nodes, uint, 2);
BUFFER_RW(b_control, uint, 3);
BUFFER_RW(b_visible, uint, 4);

uniform vec4 u_clodPlanes[6]; // the planes round what is in view, facing in
uniform vec4 u_clodCam;       // xyz: the eye, w: 1 when the view has no perspective
uniform vec4 u_clodLod;       // x: pixels per unit of error at distance 1, y: the nearest distance, z: the error that is small enough (pixels), w: 1 to cull clusters turned away
uniform vec4 u_clodCounts;    // x: the step (0 count, 1 write), z: room for work nodes

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
	uint node = uint(gl_WorkGroupID.y) * CLOD_NODE_GROUPS_X + uint(gl_WorkGroupID.x);
	if (node >= min(b_control[CLOD_CTRL_NODES], uint(u_clodCounts.z)))
	{
		return;
	}
	uint instance = b_nodes[node * 4u];
	uint first = b_nodes[node * 4u + 1u];
	uint count = b_nodes[node * 4u + 2u];
	uint lane = uint(gl_LocalInvocationID.x);
	if (lane >= count)
	{
		return;
	}
	uint at = instance * CLOD_INSTANCE_WORDS;
	uint cluster = b_instances[at + 36u] + (first + lane) * CLOD_CLUSTER_WORDS;
	vec4 col0 = vec4(inf(at), inf(at + 1u), inf(at + 2u), 0.0);
	vec4 col1 = vec4(inf(at + 4u), inf(at + 5u), inf(at + 6u), 0.0);
	vec4 col2 = vec4(inf(at + 8u), inf(at + 9u), inf(at + 10u), 0.0);
	vec3 col3 = vec3(inf(at + 12u), inf(at + 13u), inf(at + 14u));
	float scale = inf(at + 39u);

	// In view.
	vec3 local = vec3(lf(cluster + 4u), lf(cluster + 5u), lf(cluster + 6u));
	vec3 center = col0.xyz * local.x + col1.xyz * local.y + col2.xyz * local.z + col3;
	float radius = lf(cluster + 7u) * scale;
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
	uint meta = b_instances[at + 38u];
	uint bin = meta & 0xFFFFu;
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
