// Volumetric clouds (C2a): one thread per pixel of the half-resolution cloud target. Each builds the camera ray for
// its pixel (post.sh), marches it through the cloud slab with include/clouds.sh's density (the weather map eroded by 3D
// FBM detail) and writes the layer the sky shader composites: rgb premultiplied scattered light, a opacity.
//
// The energy-conserving sum along the ray is Hillaire's (Frostbite, 2015), the same shape as cs_vfog_integrate.sc; the
// weather map, height profile and detail erosion follow Schneider 2015 ("Real-Time Volumetric Cloudscapes"). Run only
// where compute shaders are (Vulkan, Direct3D, Metal); OpenGL, the web and --gpu-driven-caps-off draw the 2D layer.
#include "bgfx_compute.sh"
#include "post.sh"
#include "clouds.sh"

uniform vec4 u_cloudSize; // xy the target's pixels (the uv the ray is built from)
IMAGE2D_WO(i_clouds, rgba16f, 0);

NUM_THREADS(8, 8, 1)
void main()
{
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(u_cloudSize.x) || id.y >= int(u_cloudSize.y))
		return;
	vec2 uv = (vec2(id) + vec2_splat(0.5)) / u_cloudSize.xy;
	vec3 eye = u_postEye.xyz;
	vec3 dir = normalize(worldPosition(uv, 1.0) - eye);
	imageStore(i_clouds, id, cloudMarch(eye, dir, vec2(id)));
}
