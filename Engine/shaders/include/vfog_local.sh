// Point and spot lights in the volumetric fog (include/vfog.sh): each froxel looks up the same cluster the lit surfaces
// use (lighting.sh, LightClusters.bf), and the light's reach, cone and point or spot shadow tile scatter into it. The
// per-light "volumetric" strength (Light.bf) scales it; 0 keeps a light out of the fog.
//
// The light texture and the shadow atlas are read as plain textures here: compute shaders cannot use comparison
// samplers everywhere, so vfogLocalShadow compares the stored depths itself (as the sun's shadow does in
// cs_vfog_inject.sc). Include after bgfx_compute.sh / post.sh / vfog.sh, in the inject shader only.
#ifndef TALLOW_VFOG_LOCAL_SH
#define TALLOW_VFOG_LOCAL_SH

// Must match LightClusters.bf and lighting.sh.
#define TW_DATA_WIDTH 64
#define TW_TILE_TEXEL 2048
#define TW_CLUSTER_TEXEL 2560
#define TW_INDEX_TEXEL 6016
#define TW_GRID_X 16
#define TW_GRID_Y 9
#define TW_GRID_Z 24

uniform vec4 u_lightCount;      // x: directional lights at the start of the list, z: lights in all
uniform vec4 u_clusterForward;  // xyz: the cluster camera's forward direction
uniform vec4 u_clusterParams;   // x, y: a depth's slice is floor(log(depth) * x + y), z: the near distance
uniform mat4 u_clusterViewProj; // the camera the clusters were made for

vec4 vfogLightTexel(int i)
{
	int row = i / TW_DATA_WIDTH;
	return texelFetch(s_lightData, ivec2(i - row * TW_DATA_WIDTH, row), 0);
}

// The light number at a place in the clusters' lists (four to a texel).
int vfogClusterLight(int k)
{
	vec4 four = vfogLightTexel(TW_INDEX_TEXEL + k / 4);
	int part = k - (k / 4) * 4;
	float value = part == 0 ? four.x : (part == 1 ? four.y : (part == 2 ? four.z : four.w));
	return int(value + 0.5);
}

// Where the list of lights for the cluster round wpos starts, and how long it is.
vec2 vfogClusterList(vec3 wpos)
{
	vec4 clip = mul(u_clusterViewProj, vec4(wpos, 1.0));
	vec2 ndc = clip.xy / max(clip.w, 1.0e-6);
	int x = int(clamp(floor((ndc.x * 0.5 + 0.5) * float(TW_GRID_X)), 0.0, float(TW_GRID_X - 1)));
	int y = int(clamp(floor((ndc.y * 0.5 + 0.5) * float(TW_GRID_Y)), 0.0, float(TW_GRID_Y - 1)));
	float depth = dot(wpos - u_postEye.xyz, u_clusterForward.xyz);
	float slice = depth <= u_clusterParams.z ? 0.0 : floor(log(depth) * u_clusterParams.x + u_clusterParams.y);
	int z = int(clamp(slice, 0.0, float(TW_GRID_Z - 1)));
	return vfogLightTexel(TW_CLUSTER_TEXEL + x + y * TW_GRID_X + z * TW_GRID_X * TW_GRID_Y).xy;
}

// A point or spot light's shadow at wpos: its tile (a point light's cube face facing wpos), four taps kept inside the
// tile and compared with the stored depth. toLight runs from wpos to the light. As lighting.sh's localShadow, but
// without a surface normal: the fog's cells are empty space, so the point is not pushed off anything.
float vfogLocalShadow(vec4 shadow, vec3 wpos, vec3 toLight)
{
	int tile = int(shadow.y + 0.5);
	if (shadow.z > 1.5)
	{
		vec3 d = -toLight;
		vec3 a = abs(d);
		if (a.x >= a.y && a.x >= a.z)
			tile += d.x > 0.0 ? 0 : 1;
		else if (a.y >= a.z)
			tile += d.y > 0.0 ? 2 : 3;
		else
			tile += d.z > 0.0 ? 4 : 5;
	}
	int t = TW_TILE_TEXEL + tile * 8;
	mat4 mtx = mtxFromCols(vfogLightTexel(t), vfogLightTexel(t + 1), vfogLightTexel(t + 2), vfogLightTexel(t + 3));
	vec4 bounds = vfogLightTexel(t + 4); // the tile in texture coordinates, a texel and a half in
	vec4 info = vfogLightTexel(t + 5);   // x: texel size, y: depth bias
	vec4 clip = mul(mtx, vec4(wpos, 1.0));
	if (clip.w <= 0.0) return 1.0;
	vec3 sc = clip.xyz / clip.w;
	if (sc.z < 0.0 || sc.z > 1.0) return 1.0;
	vec2 edge = vec2_splat(info.x * 1.5);
	if (any(lessThan(sc.xy, bounds.xy - edge)) || any(greaterThan(sc.xy, bounds.zw + edge))) return 1.0;
	float depth = sc.z - info.y;
	float sum = 0.0;
	sum += depth <= texture2DLod(s_localShadowMap, clamp(sc.xy + vec2(-0.5, -0.5) * info.x, bounds.xy, bounds.zw), 0.0).x ? 1.0 : 0.0;
	sum += depth <= texture2DLod(s_localShadowMap, clamp(sc.xy + vec2( 0.5, -0.5) * info.x, bounds.xy, bounds.zw), 0.0).x ? 1.0 : 0.0;
	sum += depth <= texture2DLod(s_localShadowMap, clamp(sc.xy + vec2(-0.5,  0.5) * info.x, bounds.xy, bounds.zw), 0.0).x ? 1.0 : 0.0;
	sum += depth <= texture2DLod(s_localShadowMap, clamp(sc.xy + vec2( 0.5,  0.5) * info.x, bounds.xy, bounds.zw), 0.0).x ? 1.0 : 0.0;
	return mix(1.0, sum * 0.25, shadow.x);
}

// The light scattered towards the camera at wpos by every point and spot light of its cluster, as lighting.sh shades a
// surface (same reach, spot cone and shadow): light colour x attenuation x phase x the light's volumetric strength.
vec3 vfogLocalLights(vec3 wpos, vec3 view, float anisotropy)
{
	vec3 light = vec3_splat(0.0);
	int directionalCount = int(u_lightCount.x + 0.5);
	if (u_lightCount.z <= float(directionalCount) + 0.5)
		return light;
	vec2 list = vfogClusterList(wpos);
	int first = int(list.x + 0.5);
	int count = int(list.y + 0.5);
	// The quality setting's budget: only the first lights in the cluster's list scatter (u_vfogTemporal.w).
	int budget = int(max(u_vfogTemporal.w, 0.0) + 0.5);
	if (budget < count)
		count = budget;
	for (int k = 0; k < count; k++)
	{
		int index = vfogClusterLight(first + k);
		// Extra directional lights light every surface from far off; only point and spot lights sit in the fog.
		if (index < directionalCount)
			continue;
		int base = index * 8;
		vec4 posRange = vfogLightTexel(base);     // xyz position, w range
		vec4 colorType = vfogLightTexel(base + 1); // rgb premultiplied by intensity, w: 0 point, 1 spot
		vec4 dirSpot = vfogLightTexel(base + 2);   // xyz direction, w cos(outer angle)
		vec4 params = vfogLightTexel(base + 3);    // x cos(inner angle), y inverse square, w baked only
		vec4 shadow = vfogLightTexel(base + 4);    // x strength, y first tile, z tiles, w volumetric scattering
		if (shadow.w <= 0.0 || params.w > 0.5)
			continue;
		vec3 toLight = posRange.xyz - wpos;
		float dist = length(toLight);
		float range = posRange.w;
		if (dist >= range)
			continue;
		vec3 l = toLight / max(dist, 1.0e-4);
		float falloff = clamp(1.0 - dist / max(range, 1.0e-4), 0.0, 1.0);
		float atten = falloff * falloff / (1.0 + dist * dist * 0.1);
		if (params.y > 0.5)
		{
			float ratio = dist * dist / max(range * range, 1.0e-8);
			float fade = max(1.0 - ratio * ratio, 0.0);
			atten = fade * fade / max(dist * dist, 1.0e-6);
		}
		if (colorType.w > 0.5)
			atten *= smoothstep(dirSpot.w, params.x, dot(-l, dirSpot.xyz));
		if (atten <= 0.0)
			continue;
		if (shadow.x > 0.0)
			atten *= vfogLocalShadow(shadow, wpos, toLight);
		if (atten > 0.0)
			light += colorType.rgb * (atten * shadow.w * vfogPhase(anisotropy, dot(l, view)));
	}
	return light;
}

#endif // TALLOW_VFOG_LOCAL_SH
