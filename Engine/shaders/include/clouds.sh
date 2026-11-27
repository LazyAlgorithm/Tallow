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
// x raymarch steps, y self-shadow steps, z the frame (the march's jitter), w how much of last frame's layer to keep.
uniform vec4 u_cloudSteps;

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
// and the volume's density. Value-noise FBM spends most of its time near its middle, so the useful range is stretched:
// without it, coverage 0.15 (a threshold near 1) draws nothing and the low covers are all empty sky.
float cloudWeather(vec2 xz)
{
	float broad = cloudFBM(xz * (1.0 / 26000.0));
	float fine = cloudFBM(xz * (1.0 / 8000.0));
	return smoothstep(0.25, 0.62, mix(broad, fine, 0.35));
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

// The volumetric path (C2): a slab of air between u_cloudShape.x and u_cloudShape.x + y, raymarched from the camera.
// The weather map is the same as the 2D layer's; a 3D FBM at ~1/450 m erodes its edges into billows (Schneider 2015,
// "Real-Time Volumetric Cloudscapes"), and the energy-conserving sum along the ray is Hillaire's (Frostbite, 2015), the
// same shape as vfog.sh's. The march itself runs in cs_clouds.sc at half resolution; the sky shader samples its layer.
uint cloudHash3(ivec3 cell)
{
	uint h = uint(cell.x + 65536) * 0x9e3779b1u ^ uint(cell.y + 65536) * 0x85ebca77u ^ uint(cell.z + 65536) * 0xc2b2ae3du;
	return cloudHash(h);
}

float cloudCell3(ivec3 cell)
{
	return float(cloudHash3(cell) >> 8) * (1.0 / 16777216.0);
}

float cloudNoise3(vec3 p)
{
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	ivec3 c = ivec3(i);
	float n00 = mix(cloudCell3(c), cloudCell3(c + ivec3(1, 0, 0)), u.x);
	float n10 = mix(cloudCell3(c + ivec3(0, 1, 0)), cloudCell3(c + ivec3(1, 1, 0)), u.x);
	float n01 = mix(cloudCell3(c + ivec3(0, 0, 1)), cloudCell3(c + ivec3(1, 0, 1)), u.x);
	float n11 = mix(cloudCell3(c + ivec3(0, 1, 1)), cloudCell3(c + ivec3(1, 1, 1)), u.x);
	return mix(mix(n00, n10, u.y), mix(n01, n11, u.y), u.z);
}

// Three octaves of the 3D noise at ~1/450 m, normalised 0..1.
float cloudDetail(vec3 p)
{
	vec3 q = p * (1.0 / 450.0);
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 3; ++i)
	{
		value += cloudNoise3(q) * amplitude;
		q = q * 2.03 + vec3(11.3, 7.1, 3.7);
		amplitude *= 0.5;
	}
	return value / 0.875;
}

// The cloud's extinction at world position p, in 1/m: the weather map's coverage, shaped into a layer by the height
// profile and eroded by the detail (more near the top, so the bases stay flat and the tops break up).
float cloudDensity(vec3 p)
{
	float h = (p.y - u_cloudShape.x) / max(u_cloudShape.y, 1.0);
	if (h < 0.0 || h > 1.0)
		return 0.0;
	float profile = smoothstep(0.02, 0.18, h) * smoothstep(1.0, 0.72, h);
	float coverage = clamp(u_cloudShape.z, 0.0, 1.0);
	float soft = max(u_cloudWind.z, 0.01);
	float base = smoothstep(1.0 - coverage - soft, 1.0 - coverage + soft, cloudWeather(p.xz + u_cloudWind.xy)) * profile;
	// The detail drifts at its own speed (1.7x the weather's), as a second layer over the first.
	float erode = cloudDetail(p + vec3(u_cloudWind.xy * 0.7, 0.0)) * mix(0.55, 0.95, h);
	return saturate((base - erode) / max(1.0 - erode, 0.05)) * max(u_cloudShape.w, 0.0);
}

// The light a step scatters towards the camera. The full model (self-shadowing, Henyey-Greenstein phase, powder and
// multiple scattering) is C2b; until then the sun and moon's facing and the ambient give the layer its shape.
vec3 cloudLighting(vec3 p, vec3 rd)
{
	float sunFacing = max(dot(rd, u_cloudSunDir.xyz), 0.0);
	float sunPhase = 0.55 + 0.45 * pow(sunFacing, 4.0);
	vec3 sun = u_cloudSunColor.rgb * (sunPhase * u_cloudLight.w);
	vec3 moon = u_cloudMoonColor.rgb * (max(dot(rd, u_cloudMoonDir.xyz), 0.0) * u_cloudMoonDir.w);
	vec3 ambient = u_cloudAmbient.rgb * u_cloudLight.y;
	return u_cloudTint.rgb * (sun + moon + ambient);
}

// Interleaved gradient noise for the march's per-pixel start offset.
float cloudIGN(vec2 p)
{
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// The slab's [t0, t1] along a unit ray from ro, clamped to far; false when the ray misses it.
bool cloudSlab(vec3 ro, vec3 rd, float far, out float t0, out float t1)
{
	float bottom = u_cloudShape.x;
	float top = bottom + max(u_cloudShape.y, 1.0);
	if (abs(rd.y) < 1.0e-4)
	{
		// Level with the camera: inside the slab it is met for the whole ray, else missed.
		if (ro.y < bottom || ro.y > top)
			return false;
		t0 = 0.0;
		t1 = far;
		return true;
	}
	float ta = (bottom - ro.y) / rd.y;
	float tb = (top - ro.y) / rd.y;
	t0 = max(min(ta, tb), 0.0);
	t1 = min(max(ta, tb), far);
	return t1 > t0;
}

// The cloud layer along a unit ray: premultiplied scattered light in rgb and its opacity (1 - transmittance) in a, for
// the sky composite `sky * (1 - a) + rgb`. pixel is the target pixel for the jitter (the frame's noise decorrelates it).
vec4 cloudMarch(vec3 ro, vec3 rd, vec2 pixel)
{
	if (u_cloudView.y < 0.5 || u_cloudShape.z <= 0.0 || u_cloudShape.w <= 0.0)
		return vec4_splat(0.0);
	float t0, t1;
	if (!cloudSlab(ro, rd, max(u_cloudView.x, 1.0), t0, t1))
		return vec4_splat(0.0);
	int steps = int(max(u_cloudSteps.x, 1.0));
	float dt = (t1 - t0) / float(steps);
	float jitter = cloudIGN(pixel + u_cloudSteps.z);
	float transmittance = 1.0;
	vec3 light = vec3_splat(0.0);
	for (int i = 0; i < steps; ++i)
	{
		vec3 p = ro + rd * (t0 + (float(i) + jitter) * dt);
		float d = cloudDensity(p);
		if (d <= 0.0)
			continue;
		vec3 scattered = cloudLighting(p, rd);
		float through = exp(-d * dt);
		light += transmittance * scattered * (1.0 - through);
		transmittance *= through;
		if (transmittance < 0.01)
			break;
	}
	return vec4(light, 1.0 - transmittance);
}

#endif
