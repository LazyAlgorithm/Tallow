// The cloud layer (tallowengine.com/docs/clouds): the weather map, its 2D procedural sky layer and the uniforms the
// volumetric march shares with it. Set by PhysicalSky.SetUniforms from SceneEnvironment. Include after bgfx_shader.sh.
#ifndef TALLOW_CLOUDS_SH
#define TALLOW_CLOUDS_SH

// x bottom altitude (m), y thickness (m), z coverage 0..1, w extinction (1/m).
uniform vec4 u_cloudShape;
// xy weather offset (world m), z coverage softness, w seconds (detail drift).
uniform vec4 u_cloudWind;
// x anisotropy g, y ambient share, z powder strength, w sun scattering.
uniform vec4 u_cloudLight;
// x render distance (m), y enabled 0/1, z mode (1 2D, 2 volumetric), w screen-space 0/1.
uniform vec4 u_cloudView;
// rgb scattering albedo (linear), a 1.
uniform vec4 u_cloudTint;
// xyz towards the sun, w 1.
uniform vec4 u_cloudSunDir;
// rgb the sun's radiance on the clouds, w 1.
uniform vec4 u_cloudSunColor;
// xyz towards the moon, w 1 (0: no moon).
uniform vec4 u_cloudMoonDir;
// rgb the moon's light on the clouds, w 1.
uniform vec4 u_cloudMoonColor;
// rgb the ambient sky light, w the ground share.
uniform vec4 u_cloudAmbient;

// An integer hash (no sin): stable at the kilometre coordinates the weather is sampled at, and the same shape on every
// backend. The seed is folded into the wind offset by the renderer, so both cloud paths share this one function.
uint cloudHash(uint x)
{
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

float cloudCell(ivec2 cell)
{
	return float(cloudHash(uint(cell.x + 65536) * 0x9e3779b1u ^ uint(cell.y + 65536) * 0x85ebca77u) >> 8) * (1.0 / 16777216.0);
}

float cloudNoise(vec2 p)
{
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	ivec2 c = ivec2(i);
	float a = cloudCell(c);
	float b = cloudCell(c + ivec2(1, 0));
	float d = cloudCell(c + ivec2(0, 1));
	float e = cloudCell(c + ivec2(1, 1));
	return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

float cloudFBM(vec2 p)
{
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 5; ++i)
	{
		value += cloudNoise(p) * amplitude;
		p *= 2.03;
		amplitude *= 0.5;
	}
	return value / 0.96875;
}

// The weather map at world xz (m): broad continents of cloud broken by finer structure, 0..1. Shared by the 2D layer
// and (C2) the volume's density.
float cloudWeather(vec2 xz)
{
	float broad = cloudFBM(xz * (1.0 / 26000.0));
	float fine = cloudFBM(xz * (1.0 / 8000.0));
	return mix(broad, fine, 0.35);
}

// The 2D layer: premultiplied cloud light in rgb and coverage in a, for a ray in direction dir from origin. Nothing
// below the horizon, beyond the render distance, or with coverage 0.
vec4 cloudLayer2D(vec3 direction, vec3 origin)
{
	if (u_cloudView.y < 0.5 || direction.y <= 0.001 || u_cloudShape.z <= 0.0)
		return vec4_splat(0.0);
	// The ray meets the deck's bottom plane: one sample of the weather there is the layer.
	float t = (u_cloudShape.x - origin.y) / direction.y;
	if (t <= 0.0)
		return vec4_splat(0.0);
	float far = max(u_cloudView.x, 100.0);
	if (t >= far)
		return vec4_splat(0.0);
	vec2 xz = origin.xz + direction.xz * t + u_cloudWind.xy;
	float coverage = clamp(u_cloudShape.z, 0.0, 1.0);
	float soft = max(u_cloudWind.z, 0.01);
	float base = smoothstep(1.0 - coverage - soft, 1.0 - coverage + soft, cloudWeather(xz));
	// How much light the deck's air extinguishes along the view (an optical depth, so thin cloud lets the sky through).
	float tau = max(u_cloudShape.w, 0.0) * max(u_cloudShape.y, 1.0) / max(direction.y, 0.15);
	float opacity = base * (1.0 - exp(-tau));
	// The sun, moon and stars are behind the cloud: the layer hides them where it is opaque and lets them through at
	// its edges. Fade near the horizon and out at the render distance so the deck never ends in a hard line.
	opacity *= smoothstep(0.01, 0.12, direction.y);
	opacity *= 1.0 - smoothstep(far * 0.7, far, t);
	opacity = clamp(opacity, 0.0, 1.0);
	if (opacity <= 0.0)
		return vec4_splat(0.0);
	float sunFacing = max(dot(direction, u_cloudSunDir.xyz), 0.0);
	float sunPhase = 0.55 + 0.45 * pow(sunFacing, 4.0);
	vec3 sun = u_cloudSunColor.rgb * sunPhase * u_cloudLight.w;
	float moonFacing = max(dot(direction, u_cloudMoonDir.xyz), 0.0) * u_cloudMoonDir.w;
	vec3 moon = u_cloudMoonColor.rgb * moonFacing;
	vec3 ambient = u_cloudAmbient.rgb * u_cloudLight.y;
	vec3 light = u_cloudTint.rgb * (sun + moon + ambient);
	return vec4(light * opacity, opacity);
}

// The sky with the 2D procedural cloud over it (the backup for every backend, and for Low quality). Until the
// volumetric march lands (C2) this is the sky's cloud layer for both cloud modes.
vec3 applyProceduralClouds(vec3 sky, vec3 direction, vec3 origin)
{
	vec4 cloud = cloudLayer2D(direction, origin);
	return sky * (1.0 - cloud.a) + cloud.rgb;
}

#endif
