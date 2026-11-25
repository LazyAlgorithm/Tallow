// Culling for cluster LOD drawing, step one: one thread per instance. An instance whose sphere is in view hands its
// clusters to the next step as work nodes of up to 64 clusters (see include/clod.sh).
#include "bgfx_compute.sh"
#include "clod.sh"

BUFFER_RO(b_instances, uint, 0);
BUFFER_RW(b_control, uint, 1);
BUFFER_RW(b_nodes, uint, 2);

uniform vec4 u_clodPlanes[6]; // the planes round what is in view, facing in
uniform vec4 u_clodCounts;    // x: the first instance, y: how many instances, z: room for work nodes

NUM_THREADS(64, 1, 1)
void main()
{
	uint i = uint(gl_GlobalInvocationID.x);
	if (i >= uint(u_clodCounts.y))
	{
		return;
	}
	uint instance = uint(u_clodCounts.x) + i;
	uint at = instance * CLOD_INSTANCE_WORDS;
	vec3 center = vec3(uintBitsToFloat(b_instances[at + 32u]), uintBitsToFloat(b_instances[at + 33u]), uintBitsToFloat(b_instances[at + 34u]));
	float radius = uintBitsToFloat(b_instances[at + 35u]);
	for (int p = 0; p < 6; p++)
	{
		if (dot(u_clodPlanes[p].xyz, center) + u_clodPlanes[p].w < -radius)
		{
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
