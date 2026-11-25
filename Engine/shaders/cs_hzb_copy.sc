// The first level of the pyramid of distances that occlusion tests read (include/clod_hzb.sh): each entry is the farthest
// distance in front of the camera that the picture of the occluders has in a square of 2 x 2 pixels. Entries past the
// picture's edge are 0, which no distance is smaller than.
#include "bgfx_compute.sh"

BUFFER_RW(b_hzb, float, 0);
SAMPLER2D(s_distance, 1);

uniform vec4 u_hzbSize;    // x, y: the size of level 0, z, w: the picture's size in pixels

NUM_THREADS(8, 8, 1)
void main()
{
	uvec2 id = uvec2(gl_GlobalInvocationID.xy);
	uint w = uint(u_hzbSize.x);
	if (id.x >= w || id.y >= uint(u_hzbSize.y))
	{
		return;
	}
	float farthest = 0.0;
	for (uint k = 0u; k < 4u; k++)
	{
		uvec2 pixel = id * 2u + uvec2(k & 1u, k >> 1u);
		if (float(pixel.x) < u_hzbSize.z && float(pixel.y) < u_hzbSize.w)
		{
			vec2 uv = (vec2(pixel) + vec2_splat(0.5)) / u_hzbSize.zw;
			farthest = max(farthest, texture2DLod(s_distance, uv, 0.0).x);
		}
	}
	b_hzb[id.y * w + id.x] = farthest;
}
