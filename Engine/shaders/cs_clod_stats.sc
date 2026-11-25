// Culling for cluster LOD drawing, the numbers for the profiler: copies the counters of the scene's two occlusion phases
// into one small buffer, which the CPU reads back (one read instead of several). See GpuDrivenView.bf for the layout.
#include "bgfx_compute.sh"
#include "clod.sh"

BUFFER_RW(b_stats, uint, 0);
BUFFER_RO(b_control1, uint, 1);   // the scene's first phase, or its only one
BUFFER_RO(b_control2, uint, 2);   // its second phase
BUFFER_RO(b_defer1, uint, 3);
BUFFER_RO(b_cascade0, uint, 4);
BUFFER_RO(b_cascade1, uint, 5);
BUFFER_RO(b_cascade2, uint, 6);
BUFFER_RO(b_cascade3, uint, 7);

NUM_THREADS(1, 1, 1)
void main()
{
	b_stats[0] = b_control1[CLOD_CTRL_CLUSTERS];
	b_stats[1] = b_control1[CLOD_CTRL_TRIANGLES];
	b_stats[2] = b_control1[CLOD_CTRL_CLUSTERS_LOST];
	b_stats[3] = b_control1[CLOD_CTRL_NODES_LOST];
	b_stats[4] = b_control2[CLOD_CTRL_CLUSTERS];
	b_stats[5] = b_control2[CLOD_CTRL_TRIANGLES];
	b_stats[6] = b_control2[CLOD_CTRL_CLUSTERS_LOST];
	b_stats[7] = b_control2[CLOD_CTRL_NODES_LOST];
	b_stats[8] = b_defer1[CLOD_DEFER_INSTANCES];
	b_stats[9] = b_defer1[CLOD_DEFER_CLUSTERS];
	b_stats[10] = b_defer1[CLOD_DEFER_CLUSTERS_LOST];
	b_stats[11] = 0u;
	b_stats[12] = b_cascade0[CLOD_CTRL_CLUSTERS_LOST];
	b_stats[13] = b_cascade0[CLOD_CTRL_NODES_LOST];
	b_stats[14] = b_cascade1[CLOD_CTRL_CLUSTERS_LOST];
	b_stats[15] = b_cascade1[CLOD_CTRL_NODES_LOST];
	b_stats[16] = b_cascade2[CLOD_CTRL_CLUSTERS_LOST];
	b_stats[17] = b_cascade2[CLOD_CTRL_NODES_LOST];
	b_stats[18] = b_cascade3[CLOD_CTRL_CLUSTERS_LOST];
	b_stats[19] = b_cascade3[CLOD_CTRL_NODES_LOST];
	b_stats[20] = b_control1[CLOD_CTRL_SW_CLUSTERS] + b_control2[CLOD_CTRL_SW_CLUSTERS];
	b_stats[21] = b_control1[CLOD_CTRL_SW_TRIANGLES] + b_control2[CLOD_CTRL_SW_TRIANGLES];
	b_stats[22] = b_control1[CLOD_CTRL_HW_CLUSTERS] + b_control2[CLOD_CTRL_HW_CLUSTERS];
	b_stats[23] = 0u;
}
