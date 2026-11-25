// Volumetric fog, step 1 of 3 (include/vfog.sh): for every cell of the grid, the fog's density there and the light it
// scatters towards the camera: the sun's (shadowed by the cascades, so shadows cut light shafts out of the fog), the
// ambient sky's, and the point and spot lights' (include/vfog_local.sh, by cluster with their shadow tiles).
// Writes rgb = scattered light x density, a = extinction (per metre).
#include "bgfx_compute.sh"
#include "post.sh"
#include "vfog.sh"

IMAGE3D_WO(i_scatter, rgba16f, 0);
// The sun's shadow cascades, read as plain depths (compute shaders cannot use comparison samplers everywhere).
SAMPLER2D(s_shadowMap, 1);
// The view's lights by cluster and the point and spot lights' shadow tiles (LightClusters.bf), as plain textures too.
SAMPLER2D(s_lightData, 2);
SAMPLER2D(s_localShadowMap, 3);

#include "vfog_local.sh"

uniform vec4 u_sunDir;       // xyz towards the sun, w shadow strength
uniform vec4 u_sunColor;     // rgb times intensity
uniform vec4 u_ambientSky;
uniform mat4 u_shadowMtx[4];
uniform vec4 u_cascadeSplits;
uniform vec4 u_shadowParams; // x texel size, y depth bias, z enabled

float vfogShadowTap(mat4 mtx, vec3 wpos)
{
	vec4 sc = mul(mtx, vec4(wpos, 1.0));
	float texel = u_shadowParams.x;
	float depth = sc.z - u_shadowParams.y;
	float sum = 0.0;
	sum += depth <= texture2DLod(s_shadowMap, sc.xy + vec2(-0.5, -0.5) * texel, 0.0).x ? 1.0 : 0.0;
	sum += depth <= texture2DLod(s_shadowMap, sc.xy + vec2( 0.5, -0.5) * texel, 0.0).x ? 1.0 : 0.0;
	sum += depth <= texture2DLod(s_shadowMap, sc.xy + vec2(-0.5,  0.5) * texel, 0.0).x ? 1.0 : 0.0;
	sum += depth <= texture2DLod(s_shadowMap, sc.xy + vec2( 0.5,  0.5) * texel, 0.0).x ? 1.0 : 0.0;
	return sum * 0.25;
}

float vfogSunShadow(vec3 wpos, float viewDepth)
{
	if (u_shadowParams.z < 0.5 || viewDepth > u_cascadeSplits.w)
		return 1.0;
	float s;
	if (viewDepth < u_cascadeSplits.x)
		s = vfogShadowTap(u_shadowMtx[0], wpos);
	else if (viewDepth < u_cascadeSplits.y)
		s = vfogShadowTap(u_shadowMtx[1], wpos);
	else if (viewDepth < u_cascadeSplits.z)
		s = vfogShadowTap(u_shadowMtx[2], wpos);
	else
		s = vfogShadowTap(u_shadowMtx[3], wpos);
	float fade = clamp((u_cascadeSplits.w - viewDepth) / (u_cascadeSplits.w * 0.1), 0.0, 1.0);
	return mix(1.0, s, fade * u_sunDir.w);
}

NUM_THREADS(4, 4, 4)
void main()
{
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	if (id.x >= int(u_vfogSize.x) || id.y >= int(u_vfogSize.y) || id.z >= int(u_vfogGrid.z))
		return;
	vec2 uv = (vec2(id.xy) + vec2_splat(0.5)) / u_vfogSize.xy;
	// The cell's centre (slice 0 runs from the camera to the first boundary).
	float z0 = id.z == 0 ? 0.0 : vfogSliceDepth(float(id.z));
	float z1 = vfogSliceDepth(float(id.z + 1));
	float depth = 0.5 * (z0 + z1);
	vec3 wpos = worldPosition(uv, depth);
	vec3 view = normalize(wpos - u_postEye.xyz);
	float density = vfogDensity(wpos);
	vec3 sun = u_sunColor.rgb * (vfogPhase(u_vfogMedium.w, dot(view, u_sunDir.xyz)) * u_vfogLight.w * vfogSunShadow(wpos, depth));
	vec3 ambient = u_ambientSky.rgb * u_vfogGrid.w;
	vec3 local = vfogLocalLights(wpos, view, u_vfogMedium.w);
	vec3 scattered = (sun + ambient + local) * u_vfogLight.rgb * density;
	imageStore(i_scatter, id, vec4(scattered, density));
}
