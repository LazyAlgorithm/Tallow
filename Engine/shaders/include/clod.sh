// Cluster LOD drawing (Engine/src/Render/GpuDriven*.bf), shared by the culling shaders (cs_clod_*) and the cluster vertex
// shaders (vs_cluster*). Everything lives in a few raw buffers of 32-bit words; the layouts are written out in
// GpuDriven.bf and GpuDrivenView.bf.
//
//   pool       the clusters of every mesh, each mesh's own: per vertex 11 words (a MeshVertex), per cluster 16 words
//              (ClusterMesh.Cluster, with offsets turned into positions in the pool), per group 4 words (centre, radius).
//   instances  44 words each: the world matrix and colour as InstanceData, last frame's matrix as three rows, the
//              bounding sphere, then the mesh's first cluster, its cluster count, the bin (the low 16 bits; bit 16 set: no cone culling, for a
//              surface seen from both sides or stretched unevenly) and the largest scale, and the sphere's centre as it was
//              last frame (three words and a spare one).
//   visible    256 words of bin offsets, then (instance, cluster) pairs of the clusters to draw, bin after bin.
//   control    counters, then per bin how many clusters it holds and how many were written so far.
//   defer      what the first of the two occlusion phases could not place (see GpuDrivenView.bf): a header of counters, then
//              the instances the picture of last frame hid, then (instance, cluster) pairs of the clusters it hid.

#define CLOD_MAX_BINS 256u
#define CLOD_INSTANCE_WORDS 44u
#define CLOD_CLUSTER_WORDS 16u
#define CLOD_VISIBLE_HEADER 256u
#define CLOD_CTRL_NODES 0u
#define CLOD_CTRL_NODES_LOST 1u
#define CLOD_CTRL_CLUSTERS 2u
#define CLOD_CTRL_CLUSTERS_LOST 3u
#define CLOD_CTRL_TRIANGLES 4u
#define CLOD_CTRL_BINS 8u
#define CLOD_NODE_GROUPS_X 32768u
// The deferred lists of a pass.
#define CLOD_DEFER_INSTANCES 0u
#define CLOD_DEFER_CLUSTERS 1u
#define CLOD_DEFER_CLUSTERS_LOST 2u
#define CLOD_DEFER_HEADER 8u
// The dispatch sizes the second phase takes from the first phase's deferred lists (entries of the indirect buffer after the bins').
#define CLOD_INDIRECT_INSTANCES 257u
#define CLOD_INDIRECT_RETEST 258u
