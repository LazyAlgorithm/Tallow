// Culling for cluster LOD drawing, step one: one thread per instance. An instance whose sphere is in view hands its
// clusters to the next step as work nodes of up to 64 clusters (see include/clod.sh).
//
// With occlusion (u_clodOcc.x): in the first phase an instance that the picture of last frame hides (judged where the
// instance was then) is put in the deferred list instead; in the second phase (u_clodCounts.w = 1: the threads run over
// that list) it goes on only when the picture of the first phase does not hide it either.
#include "bgfx_compute.sh"
#include "clod.sh"

BUFFER_RO(b_instances, uint, 0);
BUFFER_RW(b_control, uint, 1);
BUFFER_RW(b_nodes, uint, 2);
BUFFER_RW(b_defer, uint, 3);
#define CLOD_HZB_REGISTER 4
#include "clod_hzb.sh"

uniform vec4 u_clodPlanes[6]; // the planes round what is in view, facing in
uniform vec4 u_clodCounts;    // x: the first instance, y: how many instances, z: room for work nodes, w: 1 to take the instances from the deferred list
uniform vec4 u_clodOcc;       // x: 0 no occlusion, 1 first phase, 2 second phase; y: room for deferred instances

NUM_THREADS(64, 1, 1)
void main()
{
	uint i = uint(gl_GlobalInvocationID.x);
	uint instance;
	if (u_clodCounts.w < 0.5)
	{
		if (i >= uint(u_clodCounts.y))
		{
			return;
		}
		instance = uint(u_clodCounts.x) + i;
	}
	else
	{
		if (i >= min(b_defer[CLOD_DEFER_INSTANCES], uint(u_clodOcc.y)))
		{
			return;
		}
		instance = b_defer[CLOD_DEFER_HEADER + i];
	}
	uint at = instance * CLOD_INSTANCE_WORDS;
	vec3 center = vec3(uintBitsToFloat(b_instances[at + 32u]), uintBitsToFloat(b_instances[at + 33u]), uintBitsToFloat(b_instances[at + 34u]));
	float radius = uintBitsToFloat(b_instances[at + 35u]);
	if (u_clodCounts.w < 0.5)
	{
		for (int p = 0; p < 6; p++)
		{
			if (dot(u_clodPlanes[p].xyz, center) + u_clodPlanes[p].w < -radius)
			{
				return;
			}
		}
	}
	if (u_clodOcc.x > 1.5)
	{
		if (hzbHidden(center, radius))
		{
			return;
		}
	}
	else if (u_clodOcc.x > 0.5)
	{
		vec3 before = vec3(uintBitsToFloat(b_instances[at + 40u]), uintBitsToFloat(b_instances[at + 41u]), uintBitsToFloat(b_instances[at + 42u]));
		if (hzbHidden(before, radius))
		{
			uint slot;
			atomicFetchAndAdd(b_defer[CLOD_DEFER_INSTANCES], 1u, slot);
			if (slot < uint(u_clodOcc.y))
			{
				b_defer[CLOD_DEFER_HEADER + slot] = instance;
			}
			return;
		}
	}
	uint count = b_instances[at + 37u];
	uint room = uint(u_clodCounts.z);
	for (uint first = 0u; first < count; first += 64u)
	{
		uint node;
		atomicFetchAndAdd(b_control[CLOD_CTRL_NODES], 1u, node);
		if (node < room)
		{
			b_nodes[node * 4u] = instance;
			b_nodes[node * 4u + 1u] = first;
			b_nodes[node * 4u + 2u] = min(64u, count - first);
			b_nodes[node * 4u + 3u] = 0u;
		}
	}
}
