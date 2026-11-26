// Volumetric fog, step 2 of 3 (include/vfog.sh): walks each column of the grid from the camera outwards, adding up the
// light the fog scatters towards the camera and how much of what is behind still shows through. Each cell gets the
// totals at its far side: rgb = light scattered in, a = transmittance. The energy-conserving sum over a cell
// (S - S exp(-sigma dz)) / sigma is Hillaire's (Frostbite, 2015).
#include "bgfx_compute.sh"
#include "post.sh"
#define VFOG_NO_VOLUME 1
#include "vfog.sh"

IMAGE3D_RO(i_scatter, rgba16f, 0);
IMAGE3D_WO(i_integrated, rgba16f, 1);

NUM_THREADS(8, 8, 1)
void main()
{
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(u_vfogSize.x) || id.y >= int(u_vfogSize.y))
		return;
	vec2 uv = (vec2(id) + vec2_splat(0.5)) / u_vfogSize.xy;
	// A metre of view depth is this long along the ray.
	vec3 p = viewPosition(uv, 1.0);
	float stretch = u_postForward.w > 0.5 ? 1.0 : length(p);
	vec3 light = vec3_splat(0.0);
	float transmittance = 1.0;
	float zNear = 0.0;
	int slices = int(u_vfogGrid.z);
	for (int s = 0; s < slices; s++)
	{
		float zFar = vfogSliceDepth(float(s + 1));
		float len = (zFar - zNear) * stretch;
		vec4 cell = imageLoad(i_scatter, ivec3(id, s));
		float sigma = max(cell.a, 1.0e-6);
		float through = exp(-sigma * len);
		vec3 scattered = (cell.rgb - cell.rgb * through) / sigma;
		light += transmittance * scattered;
		transmittance *= through;
		imageStore(i_integrated, ivec3(id, s), vec4(light, transmittance));
		zNear = zFar;
	}
}
