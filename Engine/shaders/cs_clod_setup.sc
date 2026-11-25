// Culling for cluster LOD drawing, the small steps between the big ones (see include/clod.sh), one thread each:
//   mode 0: clears the counters.
//   mode 1: turns the number of work nodes into the size of the cluster culling's dispatch.
//   mode 2: gives each bin its place in the list of clusters to draw, and writes each bin's draw command.
//   mode 3: the second occlusion phase's dispatch sizes, from how many instances and clusters the first phase deferred.
#include "bgfx_compute.sh"
#include "clod.sh"

BUFFER_RW(b_control, uint, 0);
BUFFER_RW(b_indirect, uvec4, 1);
BUFFER_RW(b_visible, uint, 2);
BUFFER_RW(b_defer, uint, 3);       // this pass's own
BUFFER_RO(b_deferFirst, uint, 4);  // the first phase's, for mode 3

uniform vec4 u_clodMode;      // x: the step, y: how many bins, z: room for clusters to draw, w: room for work nodes
uniform vec4 u_clodOcc;       // y: room for deferred instances, z: room for deferred clusters

NUM_THREADS(1, 1, 1)
void main()
{
	uint mode = uint(u_clodMode.x);
	uint binCount = uint(u_clodMode.y);
	if (mode == 0u)
	{
		for (uint i = 0u; i < CLOD_CTRL_BINS + CLOD_MAX_BINS * 2u; i++)
		{
			b_control[i] = 0u;
		}
		b_defer[CLOD_DEFER_INSTANCES] = 0u;
		b_defer[CLOD_DEFER_CLUSTERS] = 0u;
		b_defer[CLOD_DEFER_CLUSTERS_LOST] = 0u;
	}
	else if (mode == 3u)
	{
		uint instances = min(b_deferFirst[CLOD_DEFER_INSTANCES], uint(u_clodOcc.y));
		uint clusters = min(b_deferFirst[CLOD_DEFER_CLUSTERS], uint(u_clodOcc.z));
		dispatchIndirect(b_indirect, CLOD_INDIRECT_INSTANCES, (instances + 63u) / 64u, 1u, 1u);
		dispatchIndirect(b_indirect, CLOD_INDIRECT_RETEST, (clusters + 63u) / 64u, 1u, 1u);
	}
	else if (mode == 1u)
	{
		uint nodes = min(b_control[CLOD_CTRL_NODES], uint(u_clodMode.w));
		b_control[CLOD_CTRL_NODES_LOST] = b_control[CLOD_CTRL_NODES] - nodes;
		uint gx = min(nodes, CLOD_NODE_GROUPS_X);
		uint gy = max((nodes + CLOD_NODE_GROUPS_X - 1u) / CLOD_NODE_GROUPS_X, 1u);
		dispatchIndirect(b_indirect, 0, gx, gy, 1u);
	}
	else
	{
		uint offset = 0u;
		uint lost = 0u;
		uint room = uint(u_clodMode.z);
		for (uint b = 0u; b < binCount; b++)
		{
			uint wanted = b_control[CLOD_CTRL_BINS + b];
			uint take = min(wanted, room - offset);
			lost += wanted - take;
			b_control[CLOD_CTRL_BINS + b] = take;
			b_visible[b] = offset;
			drawIndexedIndirect(b_indirect, 1u + b, 384u, take, b * 384u, 0u, 0u);
			offset += take;
		}
		b_control[CLOD_CTRL_CLUSTERS] = offset;
		b_control[CLOD_CTRL_CLUSTERS_LOST] = lost;
	}
}
