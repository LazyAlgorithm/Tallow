// The next level of the pyramid of distances (cs_hzb_copy.sc): the farthest of 2 x 2 entries of the level below.
#include "bgfx_compute.sh"

BUFFER_RW(b_hzb, float, 0);

uniform vec4 u_hzbLevel;   // x, y: the size of the level to write, z: where the level below starts, w: where this level starts
                           // (u_hzbLevel2: the level below's size in x and y)
uniform vec4 u_hzbLevel2;

NUM_THREADS(8, 8, 1)
void main()
{
	uvec2 id = uvec2(gl_GlobalInvocationID.xy);
	uint w = uint(u_hzbLevel.x);
	if (id.x >= w || id.y >= uint(u_hzbLevel.y))
	{
		return;
	}
	uint belowWidth = uint(u_hzbLevel2.x);
	uint belowHeight = uint(u_hzbLevel2.y);
	uint below = uint(u_hzbLevel.z);
	float farthest = 0.0;
	for (uint k = 0u; k < 4u; k++)
	{
		uvec2 at = min(id * 2u + uvec2(k & 1u, k >> 1u), uvec2(belowWidth - 1u, belowHeight - 1u));
		farthest = max(farthest, b_hzb[below + at.y * belowWidth + at.x]);
	}
	b_hzb[uint(u_hzbLevel.w) + id.y * w + id.x] = farthest;
}
