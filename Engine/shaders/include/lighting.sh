// The lighting every lit surface shares (fs_mesh.sc, custom shaders, decals): the sun with four shadow cascades,
// point, spot and extra directional lights by cluster with point and spot shadows (docs/lighting.md), hemisphere
// ambient or baked light probes (docs/baked-lighting.md), reflections of the sky and of reflection probes (docs/reflections.md), and distance fog. Include after
// bgfx_shader.sh.
#ifndef TALLOW_LIGHTING_SH
#define TALLOW_LIGHTING_SH

#define PI 3.14159265

SAMPLER2DSHADOW(s_shadowMap, 1);
// The point and spot lights' shadow tiles.
SAMPLER2DSHADOW(s_localShadowMap, 11);
// The view's lights, their shadow tiles and the clusters' lists of them, laid out as in LightClusters.bf.
SAMPLER2D(s_lightData, 15);
// What surfaces mirror: the nearest reflection probe's cube and the sky's, each with rougher levels down its mips.
SAMPLERCUBE(s_reflectionProbe, 13);
SAMPLERCUBE(s_reflectionSky, 14);
// Baked light probes (LightProbes.bf): x by y by three blocks of z (red, green, blue), each texel a + b.n.
SAMPLER3D(s_lightProbes, 12);

uniform vec4 u_camPos;
uniform vec4 u_sunDir;        // xyz: direction towards the sun, w: shadow strength
uniform vec4 u_sunColor;      // rgb premultiplied by intensity
uniform vec4 u_ambientSky;
uniform vec4 u_ambientGround;
uniform vec4 u_fogColor;      // rgb, a: density
uniform vec4 u_lightCount;    // x: directional lights at the start of the list, y: the sun's shadow mask channel + 1,
                              // z: lights in all
uniform mat4 u_clusterViewProj; // the camera the clusters were made for
uniform vec4 u_clusterForward;  // xyz: its forward direction
uniform vec4 u_clusterParams;   // x, y: a depth's slice is floor(log(depth) * x + y), z: the near distance
uniform mat4 u_shadowMtx[4];
uniform vec4 u_cascadeSplits;
uniform vec4 u_shadowParams;  // x texel size, y depth bias, z enabled, w normal offset
uniform vec4 u_reflection;    // x: 1 with reflection cubes (0: the ambient colours stand in), y: the sky cube's
                              // last level, z: the probe's intensity (0: no probe), w: the scene's reflection intensity
uniform vec4 u_probeMin;      // the probe's box, xyz: its lowest corner, w: 1 to project onto the box
uniform vec4 u_probeMax;      // xyz: its highest corner, w: how far outside it its reflections fade out
uniform vec4 u_probePos;      // xyz: where the probe saw from, w: its cube's last level
uniform vec4 u_ambientParams; // x: 1 to take ambient light from the reflection cubes, y: the scene's ambient intensity
// Baked light probes: two grids from one 3D texture, the draw's own (0 to 3) and, when that is a Light Probe Volume,
// the scene's grid round it (4 to 7). Each grid: [0] xyz its first probe, w 1 when in use; [1] xyz 1 / (last probe
// - first probe), w 1 / how far inside its box it fades in; [2] xyz probes along each axis; [3] xyz where its block
// starts in the texture, in texels. [8] xyz the texture's size in texels; [9] xyz the draw's grid's last probe.
uniform vec4 u_lightProbe[10];

vec3 toLinear3(vec3 c)
{
	return pow(abs(c), vec3_splat(2.2));
}

float distributionGGX(float ndoth, float a)
{
	float a2 = a * a;
	float d = ndoth * ndoth * (a2 - 1.0) + 1.0;
	return a2 / (PI * d * d + 1.0e-6);
}

float visibilitySmith(float ndotv, float ndotl, float a)
{
	float k = a * 0.5;
	float gv = ndotv / (ndotv * (1.0 - k) + k);
	float gl = ndotl / (ndotl * (1.0 - k) + k);
	return gv * gl / (4.0 * ndotv * ndotl + 1.0e-4);
}

vec3 brdf(vec3 n, vec3 v, vec3 l, vec3 albedo, float metallic, float roughness, float specularLevel)
{
	vec3 h = normalize(v + l);
	float ndotl = max(dot(n, l), 0.0);
	float ndotv = max(dot(n, v), 1.0e-3);
	float ndoth = max(dot(n, h), 0.0);
	float vdoth = max(dot(v, h), 0.0);
	float a = roughness * roughness;
	vec3 f0 = mix(vec3_splat(0.04 * specularLevel), albedo, metallic);
	vec3 fresnel = f0 + (vec3_splat(1.0) - f0) * pow(1.0 - vdoth, 5.0);
	vec3 specular = fresnel * (distributionGGX(ndoth, a) * visibilitySmith(ndotv, ndotl, a));
	vec3 diffuse = albedo * (1.0 - metallic) * (1.0 / PI);
	return (diffuse * (vec3_splat(1.0) - fresnel) + specular) * ndotl;
}

// Must match LightClusters.bf.
#define TW_DATA_WIDTH 64
#define TW_TILE_TEXEL 2048
#define TW_CLUSTER_TEXEL 2560
#define TW_INDEX_TEXEL 6016
#define TW_GRID_X 16
#define TW_GRID_Y 9
#define TW_GRID_Z 24

vec4 lightTexel(int i)
{
	int row = i / TW_DATA_WIDTH;
	return texelFetch(s_lightData, ivec2(i - row * TW_DATA_WIDTH, row), 0);
}

// The light number at a place in the clusters' lists (four to a texel).
int clusterLight(int k)
{
	vec4 four = lightTexel(TW_INDEX_TEXEL + k / 4);
	int part = k - (k / 4) * 4;
	float value = part == 0 ? four.x : (part == 1 ? four.y : (part == 2 ? four.z : four.w));
	return int(value + 0.5);
}

// Where the list of lights for the cluster round wpos starts, and how long it is.
vec2 clusterList(vec3 wpos)
{
	vec4 clip = mul(u_clusterViewProj, vec4(wpos, 1.0));
	vec2 ndc = clip.xy / max(clip.w, 1.0e-6);
	int x = int(clamp(floor((ndc.x * 0.5 + 0.5) * float(TW_GRID_X)), 0.0, float(TW_GRID_X - 1)));
	int y = int(clamp(floor((ndc.y * 0.5 + 0.5) * float(TW_GRID_Y)), 0.0, float(TW_GRID_Y - 1)));
	float depth = dot(wpos - u_camPos.xyz, u_clusterForward.xyz);
	float slice = depth <= u_clusterParams.z ? 0.0 : floor(log(depth) * u_clusterParams.x + u_clusterParams.y);
	int z = int(clamp(slice, 0.0, float(TW_GRID_Z - 1)));
	return lightTexel(TW_CLUSTER_TEXEL + x + y * TW_GRID_X + z * TW_GRID_X * TW_GRID_Y).xy;
}

// A point or spot light's shadow at wpos: its tile (a point light's cube face facing wpos), compared through four
// taps kept inside the tile. toLight runs from wpos to the light.
float localShadow(vec4 shadow, vec3 wpos, vec3 normal, vec3 toLight, float dist)
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
	mat4 mtx = mtxFromCols(lightTexel(t), lightTexel(t + 1), lightTexel(t + 2), lightTexel(t + 3));
	vec4 bounds = lightTexel(t + 4); // the tile in texture coordinates, a texel and a half in
	vec4 info = lightTexel(t + 5);   // x: texel size, y: depth bias, z: a texel's width a metre from the light
	// Pushed off the surface by about a texel where it lands, against shadow acne.
	vec4 clip = mul(mtx, vec4(wpos + normal * (dist * info.z * 1.5), 1.0));
	if (clip.w <= 0.0) return 1.0;
	vec3 sc = clip.xyz / clip.w;
	if (sc.z < 0.0 || sc.z > 1.0) return 1.0;
	vec2 edge = vec2_splat(info.x * 1.5);
	if (any(lessThan(sc.xy, bounds.xy - edge)) || any(greaterThan(sc.xy, bounds.zw + edge))) return 1.0;
	float depth = sc.z - info.y;
	float sum = 0.0;
	sum += shadow2D(s_localShadowMap, vec3(clamp(sc.xy + vec2(-0.5,-0.5) * info.x, bounds.xy, bounds.zw), depth));
	sum += shadow2D(s_localShadowMap, vec3(clamp(sc.xy + vec2( 0.5,-0.5) * info.x, bounds.xy, bounds.zw), depth));
	sum += shadow2D(s_localShadowMap, vec3(clamp(sc.xy + vec2(-0.5, 0.5) * info.x, bounds.xy, bounds.zw), depth));
	sum += shadow2D(s_localShadowMap, vec3(clamp(sc.xy + vec2( 0.5, 0.5) * info.x, bounds.xy, bounds.zw), depth));
	return mix(1.0, sum * 0.25, shadow.x);
}

// One light of the view's list on a surface.
vec3 shadeLight(int index, vec3 wpos, vec3 n, vec3 v, vec3 albedo, float metallic, float roughness,
	float specularLevel, vec4 bakedMask, bool lightmapped)
{
	int base = index * 8;
	vec4 posRange = lightTexel(base);     // xyz position, w range
	vec4 colorType = lightTexel(base + 1); // rgb premultiplied by intensity, w: 0 point, 1 spot, 2 directional
	vec4 dirSpot = lightTexel(base + 2);   // xyz direction, w cos(outer angle)
	vec4 params = lightTexel(base + 3);    // x cos(inner angle), y inverse square, z shadow mask channel + 1, w baked only
	if (params.w > 0.5 && lightmapped)
		return vec3_splat(0.0);
	vec3 toLight = posRange.xyz - wpos;
	float dist = length(toLight);
	float range = posRange.w;
	bool directional = colorType.w > 1.5;
	if (!directional && dist >= range)
		return vec3_splat(0.0);
	vec3 l = directional ? -dirSpot.xyz : toLight / max(dist, 1.0e-4);
	float atten = 1.0;
	if (!directional)
	{
		float falloff = clamp(1.0 - dist / max(range, 1.0e-4), 0.0, 1.0);
		atten = falloff * falloff / (1.0 + dist * dist * 0.1);
		if (params.y > 0.5)
		{
			float ratio = dist * dist / max(range * range, 1.0e-8);
			float fade = max(1.0 - ratio * ratio, 0.0);
			atten = fade * fade / max(dist * dist, 1.0e-6);
		}
		if (colorType.w > 0.5)
			atten *= smoothstep(dirSpot.w, params.x, dot(-l, dirSpot.xyz));
		if (atten <= 0.0)
			return vec3_splat(0.0);
		vec4 shadow = lightTexel(base + 4); // x strength (0: none), y first tile, z tiles (1 spot, 6 point)
		if (shadow.x > 0.0)
			atten *= localShadow(shadow, wpos, n, toLight, dist);
	}
	if (params.z > 0.5) atten *= bakedMask[int(params.z - 1.0)];
	return brdf(n, v, l, albedo, metallic, roughness, specularLevel) * colorType.rgb * atten * PI;
}

float shadowTap(mat4 mtx, vec3 wpos)
{
	vec4 sc = mul(mtx, vec4(wpos, 1.0));
	float texel = u_shadowParams.x;
	float depth = sc.z - u_shadowParams.y;
	float sum = 0.0;
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2(-0.5, -0.5) * texel, depth));
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2( 0.5, -0.5) * texel, depth));
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2(-0.5,  0.5) * texel, depth));
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2( 0.5,  0.5) * texel, depth));
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2(-1.5,  0.5) * texel, depth));
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2( 1.5, -0.5) * texel, depth));
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2( 0.5,  1.5) * texel, depth));
	sum += shadow2D(s_shadowMap, vec3(sc.xy + vec2(-0.5, -1.5) * texel, depth));
	return sum * 0.125;
}

float sunShadow(vec3 wpos, vec3 n, float viewDepth)
{
	if (u_shadowParams.z < 0.5 || viewDepth > u_cascadeSplits.w)
	{
		return 1.0;
	}
	vec3 p = wpos + n * u_shadowParams.w;
	float s;
	if (viewDepth < u_cascadeSplits.x)
	{
		s = shadowTap(u_shadowMtx[0], p);
	}
	else if (viewDepth < u_cascadeSplits.y)
	{
		s = shadowTap(u_shadowMtx[1], p + n * u_shadowParams.w);
	}
	else if (viewDepth < u_cascadeSplits.z)
	{
		s = shadowTap(u_shadowMtx[2], p + n * u_shadowParams.w * 3.0);
	}
	else
	{
		s = shadowTap(u_shadowMtx[3], p + n * u_shadowParams.w * 7.0);
	}
	// Fade out towards the end of the last cascade so the shadow distance has no hard edge.
	float fade = clamp((u_cascadeSplits.w - viewDepth) / (u_cascadeSplits.w * 0.1), 0.0, 1.0);
	return mix(1.0, s, fade * u_sunDir.w);
}

// The ambient light on a surface facing n, between the ground's colour below and the sky's above.
vec3 hemisphereAmbient(vec3 n)
{
	return mix(u_ambientGround.rgb, u_ambientSky.rgb, n.y * 0.5 + 0.5);
}

// One grid's ambient light at a point for a surface facing n, blended between the eight probes round it. A grid's
// block holds red, then green, then blue, each count.z deep.
vec3 probeGridAmbient(vec4 lo, vec4 scale, vec4 count, vec4 offset, vec3 wpos, vec3 n)
{
	vec3 t = clamp((wpos - lo.xyz) * scale.xyz, 0.0, 1.0);
	vec3 size = u_lightProbe[8].xyz;
	vec3 uvw = (offset.xyz + t * (count.xyz - 1.0) + 0.5) / size;
	float block = count.z / size.z;
	vec4 r = texture3D(s_lightProbes, uvw);
	vec4 g = texture3D(s_lightProbes, uvw + vec3(0.0, 0.0, block));
	vec4 b = texture3D(s_lightProbes, uvw + vec3(0.0, 0.0, 2.0 * block));
	return max(vec3(r.x + dot(r.yzw, n), g.x + dot(g.yzw, n), b.x + dot(b.yzw, n)), vec3_splat(0.0));
}

// The baked light probes' ambient light at a point for a surface facing n: the draw's grid, fading into the scene's
// grid towards the edges of a Light Probe Volume's box.
vec3 probeAmbient(vec3 wpos, vec3 n)
{
	vec3 inner = probeGridAmbient(u_lightProbe[0], u_lightProbe[1], u_lightProbe[2], u_lightProbe[3], wpos, n);
	if (u_lightProbe[4].w < 0.5)
		return inner;
	vec3 outer = probeGridAmbient(u_lightProbe[4], u_lightProbe[5], u_lightProbe[6], u_lightProbe[7], wpos, n);
	vec3 inside = min(wpos - u_lightProbe[0].xyz, u_lightProbe[9].xyz - wpos);
	float weight = clamp(min(min(inside.x, inside.y), inside.z) * u_lightProbe[1].w, 0.0, 1.0);
	return mix(outer, inner, weight);
}

// Where a reflection probe's cube is looked up for a ray from wpos along dir: with box projection, the direction from
// the probe to where the ray leaves the box, so that reflections of the walls line up wherever the surface is.
vec3 probeDirection(vec3 wpos, vec3 dir)
{
	if (u_probeMin.w < 0.5)
		return dir;
	vec3 toMax = (u_probeMax.xyz - wpos) / dir;
	vec3 toMin = (u_probeMin.xyz - wpos) / dir;
	vec3 leave = max(toMax, toMin);
	float distance = max(min(min(leave.x, leave.y), leave.z), 0.0);
	return wpos + dir * distance - u_probePos.xyz;
}

// What a surface of this roughness mirrors along dir: the sky, and the probe it is in.
vec3 environmentReflection(vec3 wpos, vec3 dir, float roughness)
{
	vec3 color = textureCubeLod(s_reflectionSky, dir, roughness * u_reflection.y).rgb;
	if (u_reflection.z > 0.0)
	{
		// All of the probe inside its box, fading to none a blend distance outside it.
		vec3 outside = max(max(u_probeMin.xyz - wpos, wpos - u_probeMax.xyz), vec3_splat(0.0));
		float weight = 1.0 - clamp(length(outside) / max(u_probeMax.w, 0.001), 0.0, 1.0);
		if (weight > 0.0)
		{
			vec3 probe = textureCubeLod(s_reflectionProbe, probeDirection(wpos, dir), roughness * u_probePos.w).rgb;
			color = mix(color, probe * u_reflection.z, weight);
		}
	}
	return color * u_reflection.w;
}

// The light from all around on a surface facing n, from the cubes' roughest levels (image-based ambient light): the
// sky's, and inside a probe's box the room it saw.
vec3 environmentAmbient(vec3 wpos, vec3 n)
{
	vec3 color = textureCubeLod(s_reflectionSky, n, u_reflection.y).rgb;
	if (u_reflection.z > 0.0)
	{
		vec3 outside = max(max(u_probeMin.xyz - wpos, wpos - u_probeMax.xyz), vec3_splat(0.0));
		float weight = 1.0 - clamp(length(outside) / max(u_probeMax.w, 0.001), 0.0, 1.0);
		if (weight > 0.0)
			color = mix(color, textureCubeLod(s_reflectionProbe, n, u_probePos.w).rgb * u_reflection.z, weight);
	}
	return color * u_ambientParams.y;
}

// How much of the mirrored light a surface gives back, over every angle of its highlight: Karis' fit of the
// split-sum lookup ("Physically Based Shading on Mobile").
vec3 environmentBrdf(vec3 f0, float roughness, float ndotv)
{
	vec4 r = roughness * vec4(-1.0, -0.0275, -0.572, 0.022) + vec4(1.0, 0.0425, 1.04, -0.04);
	float a004 = min(r.x * r.x, exp2(-9.28 * ndotv)) * r.x + r.y;
	vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
	return f0 * ab.x + ab.y;
}

// A surface's colour under every light, before its glow and fog: ambient (already worked out, from the hemisphere
// or a lightmap), the surroundings mirrored, the sun and the scene's lights. bakedMask holds a lightmap's shadow
// mask (all 1 without one); a lightmapped surface skips lights that are baked into it.
vec3 shadeSurface(vec3 wpos, vec3 n, vec3 v, float viewDepth, vec3 albedo, float metallic, float roughness,
	float specularLevel, float occlusion, vec3 ambient, vec4 bakedMask, bool lightmapped)
{
	vec3 mirrored = reflect(-v, n);
	vec3 f0 = mix(vec3_splat(0.04 * specularLevel), albedo, metallic);
	vec3 color;
	// Without a lightmap, baked light probes give the light bounced round the scene (docs/baked-lighting.md).
	bool probed = !lightmapped && u_lightProbe[0].w > 0.5;
	if (probed)
		ambient = probeAmbient(wpos, n);
	if (u_reflection.x > 0.5)
	{
		if (u_ambientParams.x > 0.5 && !lightmapped && !probed)
			ambient = environmentAmbient(wpos, n);
		// What the surface mirrors of its surroundings, from the sky's and the probe's cubes: metals all of it,
		// tinted, and other things a little, more at a grazing angle.
		color = ambient * albedo * (1.0 - metallic) * occlusion;
		color += environmentReflection(wpos, mirrored, roughness) * environmentBrdf(f0, roughness, max(dot(n, v), 0.0)) * occlusion;
	}
	else
	{
		// Without reflection cubes (the Low quality preset), the sky and ground colours stand in for them. It is
		// what keeps a smooth metal from looking black where no light shines on it directly.
		color = ambient * albedo * (1.0 - metallic * 0.5) * occlusion;
		vec3 surroundings = mix(u_ambientGround.rgb, u_ambientSky.rgb, clamp(mirrored.y * 0.5 + 0.5, 0.0, 1.0));
		float grazing = pow(1.0 - max(dot(n, v), 0.0), 5.0);
		vec3 reflectance = f0 + (max(vec3_splat(1.0 - roughness), f0) - f0) * grazing;
		color += surroundings * reflectance * (1.0 - roughness * 0.75) * metallic * occlusion;
	}

	float shadow = sunShadow(wpos, n, viewDepth);
	if (u_lightCount.y > 0.5)
	{
		int channel = int(u_lightCount.y - 1.0);
		shadow = min(shadow, bakedMask[channel]);
	}
	color += brdf(n, v, u_sunDir.xyz, albedo, metallic, roughness, specularLevel) * u_sunColor.rgb * shadow * PI;

	// Extra directional lights reach every pixel; the others by the cluster the pixel is in.
	int directionalCount = int(u_lightCount.x + 0.5);
	for (int i = 0; i < directionalCount; i++)
		color += shadeLight(i, wpos, n, v, albedo, metallic, roughness, specularLevel, bakedMask, lightmapped);
	if (u_lightCount.z > float(directionalCount) + 0.5)
	{
		vec2 list = clusterList(wpos);
		int first = int(list.x + 0.5);
		int count = int(list.y + 0.5);
		for (int k = 0; k < count; k++)
			color += shadeLight(clusterLight(first + k), wpos, n, v, albedo, metallic, roughness, specularLevel, bakedMask, lightmapped);
	}
	return color;
}

// Distance fog over a colour seen at wpos.
vec3 applyFog(vec3 color, vec3 wpos)
{
	float fogDistance = length(u_camPos.xyz - wpos);
	float fog = 1.0 - exp(-fogDistance * fogDistance * u_fogColor.a * u_fogColor.a);
	return mix(color, u_fogColor.rgb, clamp(fog, 0.0, 1.0));
}

#endif // TALLOW_LIGHTING_SH
