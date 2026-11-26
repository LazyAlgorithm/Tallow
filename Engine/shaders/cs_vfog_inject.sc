// Volumetric fog, step 1 of 3 (include/vfog.sh): for every cell of the grid, the fog's density there and the light it
// scatters towards the camera: the sun's (shadowed by the cascades, so shadows cut light shafts out of the fog), the
// ambient sky's, the point and spot lights' (include/vfog_local.sh, by cluster with their shadow tiles), and the Fog
// Volumes' (their own density and colour where they are). Writes rgb = scattered light x density, a = extinction
// (per metre).
#include "bgfx_compute.sh"
#include "post.sh"
#define VFOG_NO_VOLUME 1
#include "vfog.sh"

IMAGE3D_WO(i_scatter, rgba16f, 0);
// Last frame's cells, the same light and density, for the temporal blend (only read when u_vfogTemporal.z is 1). Read
// through a sampler, so the cells are interpolated: a cell-by-cell copy would jump whole cells as the camera moves and
// show the grid as squares.
SAMPLER3D(s_vfogHistory, 4);
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
// The Fog Volumes (RenderViewVolumetric.bf), five vectors each: the three rows of its world-to-local matrix (the box
// is -1 to 1 there, the ball 1 from its middle), then x edge fade and y density, then rgb colour (linear) and
// w 1 for a ball.
uniform vec4 u_fogVolumes[160];
uniform vec4 u_vfogVolumeCount; // x how many are used

// The Fog Volumes' fog at wpos: xyz their colour times their density (per metre), w their density.
vec4 vfogVolumes(vec3 wpos)
{
	vec4 total = vec4_splat(0.0);
	vec4 p = vec4(wpos, 1.0);
	int count = int(u_vfogVolumeCount.x);
	for (int i = 0; i < count; i++)
	{
		vec4 r0 = u_fogVolumes[i * 5 + 0];
		vec4 r1 = u_fogVolumes[i * 5 + 1];
		vec4 r2 = u_fogVolumes[i * 5 + 2];
		vec4 r3 = u_fogVolumes[i * 5 + 3];
		vec4 r4 = u_fogVolumes[i * 5 + 4];
		vec3 local = vec3(dot(r0, p), dot(r1, p), dot(r2, p));
		float outside = r4.w > 0.5 ? length(local) : max(max(abs(local.x), abs(local.y)), abs(local.z));
		// Fades to nothing over the last edgeFade of the way from its middle to its edge.
		float inside = clamp((1.0 - outside) / max(r3.x, 1.0e-3), 0.0, 1.0);
		inside = inside * inside * (3.0 - 2.0 * inside);
		float density = inside * r3.y;
		total += vec4(r4.rgb * density, density);
	}
	return total;
}

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
	// The cell's depth: slice 0 runs from the camera to the first boundary. It is sampled at a different point in it
	// each frame (u_vfogTemporal.x), which with last frame's cells blended in smooths the banding between slices away.
	float z0 = id.z == 0 ? 0.0 : vfogSliceDepth(float(id.z));
	float z1 = vfogSliceDepth(float(id.z + 1));
	float depth = max(mix(z0, z1, u_vfogTemporal.x), 1.0e-3);
	vec3 wpos = worldPosition(uv, depth);
	vec3 view = normalize(wpos - u_postEye.xyz);
	float heightDensity = vfogDensity(wpos);
	vec4 volumes = vfogVolumes(wpos);
	float density = heightDensity + volumes.w;
	// What the light scatters off: the height fog's albedo, and each Fog Volume's own colour.
	vec3 albedoDensity = u_vfogLight.rgb * heightDensity + volumes.rgb;
	vec3 sun = u_sunColor.rgb * (vfogPhase(u_vfogMedium.w, dot(view, u_sunDir.xyz)) * u_vfogLight.w * vfogSunShadow(wpos, depth));
	vec3 ambient = u_ambientSky.rgb * u_vfogGrid.w;
	vec3 local = vfogLocalLights(wpos, view, u_vfogMedium.w);
	vec3 scattered = (sun + ambient + local) * albedoDensity;
	vec4 cell = vec4(scattered, density);
	// Blend with what was in last frame's grid where this cell's middle was: each frame samples the cells at a
	// different depth (above), and averaging those takes the banding between slices away. Last frame's cells are
	// interpolated (a sampler, not imageLoad): as the camera moves, the cell this frame lands in changes, and a
	// nearest-cell copy would blend in a whole different cell at each grid line, which shows as squares.
	if (u_vfogTemporal.z > 0.5)
	{
		vec4 clip = mul(u_vfogPrevViewProj, vec4(wpos, 1.0));
		if (clip.w > 0.0 && clip.w <= u_vfogGrid.y)
		{
			vec2 uvPrev = ndcToUv(clip.xy / clip.w);
			if (uvPrev.x >= 0.0 && uvPrev.x <= 1.0 && uvPrev.y >= 0.0 && uvPrev.y <= 1.0)
			{
				float sliceOld = clamp(vfogDepthSlice(clip.w), 0.0, u_vfogGrid.z - 1.0);
				vec3 coord = vec3(uvPrev, (sliceOld + 0.5) / u_vfogGrid.z);
				cell = mix(cell, texture3DLod(s_vfogHistory, coord, 0.0), u_vfogTemporal.y);
			}
		}
	}
	imageStore(i_scatter, id, cell);
}
