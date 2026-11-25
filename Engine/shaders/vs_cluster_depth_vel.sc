$output v_depth, v_velCur, v_velPrev

// The depth pass for cluster LOD drawing, the version that matches the fragment shader of the same name without cluster
// (see include/clod_depth.sh).
#define CLOD_VELOCITY 1
#include "clod_depth.sh"
