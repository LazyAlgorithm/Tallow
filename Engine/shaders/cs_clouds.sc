// Volumetric clouds (C2a): one thread per pixel of the half-resolution cloud target. Each builds the camera ray for
// its pixel (post.sh), marches it through the cloud slab with include/clouds.sh's density (the weather map eroded by 3D
// FBM detail) and writes the layer the sky shader composites: rgb premultiplied scattered light, a opacity.
//
// C2c: the march's start is jittered by a blue-noise tile that shifts a little each frame (so the per-frame sample
// pattern is evenly spread, not clumped), and the finished layer is blended with last frame's layer reprojected by the
// slab midpoint, minus the wind that moved the weather, into last frame's view-projection (mirroring the froxel fog's
// history in cs_vfog_inject.sc). The history is dropped on a camera cut, a resize, a skipped frame or when the quality
// setting turns the blend off. A debug view (`--gpu-debug-view clouds`, C3a) writes the cloud field instead of the
// picture: the column's opacity in red (the density the ray met), its average light in green and the share of the step
// budget it used in blue.
//
// The energy-conserving sum along the ray is Hillaire's (Frostbite, 2015), the same shape as cs_vfog_integrate.sc; the
// weather map, height profile and detail erosion follow Schneider 2015 ("Real-Time Volumetric Cloudscapes"). Run only
// where compute shaders are (Vulkan, Direct3D, Metal); OpenGL, the web and --gpu-driven-caps-off draw the 2D layer.
#include "bgfx_compute.sh"
#include "post.sh"
#include "clouds.sh"

uniform vec4 u_cloudSize; // xy the target's pixels (the uv the ray is built from)
// The blue-noise tile's side in pixels; RenderResources' texture is this square.
#define CLOUD_BLUE_NOISE 32.0
// The blue-noise and last-frame samplers are at stages 4 and 5, away from the storage image at 0: bgfx's compute
// bindings share the unit space, so a sampler at 0 clashes with the image (the fog's inject keeps its samplers at
// 1 to 4 for the same reason).
SAMPLER2D(s_cloudNoise, 4);
SAMPLER2D(s_cloudHistory, 5);
// Last frame's view-projection and (xyz) how far the weather moved since: a cloud at p now was at p - windDelta then.
uniform mat4 u_cloudPrevViewProj;
uniform vec4 u_cloudWindDelta;
// x 1: write the cloud field (density red, light green, marched step share blue) instead of the cloud.
uniform vec4 u_cloudDebug;
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
	// The blue-noise tile (RenderResources.BlueNoise), shifted by a frame-varying low-discrepancy offset so the same
	// pixel gets an evenly spread sequence of jitter values over the frames the temporal blend averages.
	vec2 shift = floor(fract(u_cloudSteps.z * vec2(0.7548776662, 0.5698402910)) * CLOUD_BLUE_NOISE);
	vec2 noiseCell = mod(floor(vec2(id) + shift), CLOUD_BLUE_NOISE);
	float jitter = texture2DLod(s_cloudNoise, (noiseCell + vec2_splat(0.5)) / CLOUD_BLUE_NOISE, 0.0).x;
	float midDistance, marched;
	vec4 layer = cloudMarch(eye, dir, jitter, midDistance, marched);
	if (u_cloudSteps.w > 0.0 && midDistance > 0.0)
	{
		// Where the slab's middle was last frame: same world point, minus the wind that carried the weather.
		vec3 previousWorld = eye + dir * midDistance - u_cloudWindDelta.xyz;
		vec4 clip = mul(u_cloudPrevViewProj, vec4(previousWorld, 1.0));
		if (clip.w > 0.0)
		{
			vec2 uvPrev = ndcToUv(clip.xy / clip.w);
			if (uvPrev.x >= 0.0 && uvPrev.x <= 1.0 && uvPrev.y >= 0.0 && uvPrev.y <= 1.0)
				layer = mix(layer, texture2DLod(s_cloudHistory, uvPrev, 0.0), u_cloudSteps.w);
		}
	}
	if (u_cloudDebug.x > 0.5)
	{
		// The cloud field instead of the picture: red the column's opacity (how much cloud the ray met), green the
		// layer's average light (its scattered radiance, tonemapped so lit tops do not all clip to white), blue the
		// share of the step budget the ray used (0 where it missed the slab). All three are 0 where there is no cloud.
		float steps = max(u_cloudSteps.x, 1.0);
		float light = dot(layer.rgb, vec3(0.2126, 0.7152, 0.0722)) / max(layer.a, 1.0e-4);
		layer = vec4(layer.a, 1.0 - exp(-light * 0.5), marched / steps, 1.0);
	}
	imageStore(i_clouds, id, layer);
}
