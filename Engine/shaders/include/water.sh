// Water (docs/water.md): the waves and patterns shared by vs_water.sc, fs_water.sc and fs_underwater.sc. The waves
// are Water.bf's Gerstner waves, with the same sums, so what is drawn is where things float.
#ifndef TALLOW_WATER_SH
#define TALLOW_WATER_SH

uniform vec4 u_waveA[4];     // xy: direction along the water (x, z), z: wavenumber k, w: amplitude
uniform vec4 u_waveB[4];     // x: steepness, y: phase now, z: share kept by the grid (short waves fade on a coarse one),
                             // w: distance where it starts fading out (0: never)
uniform vec4 u_waterLevel;   // x: the still level, y: the bottom, zw: the flow (x, z) in metres a second

// The waves' offset of the still point p (x, z), dist metres from the camera, with the surface's normal and how
// folded it is (1 flat, towards 0 at the sharpest crests).
vec3 waterWaves(vec2 p, float dist, out vec3 normal, out float fold)
{
	vec3 offset = vec3_splat(0.0);
	vec3 n = vec3(0.0, 1.0, 0.0);
	float squeeze = 1.0;
	for (int i = 0; i < 4; i++)
	{
		vec4 a = u_waveA[i];
		vec4 b = u_waveB[i];
		float keep = b.z;
		if (b.w > 0.0)
			keep *= clamp(2.0 - dist / b.w, 0.0, 1.0);
		float amplitude = a.w * keep;
		float theta = a.z * dot(a.xy, p) - b.y;
		float s = sin(theta);
		float c = cos(theta);
		offset.xz += a.xy * (b.x * amplitude * c);
		offset.y += amplitude * s;
		float ka = a.z * amplitude;
		n.xz -= a.xy * (ka * c);
		n.y -= b.x * ka * s;
		squeeze -= b.x * ka * s;
	}
	normal = normalize(n);
	fold = squeeze;
	return offset;
}

// The surface's height over a point (x, z) of the world: the still point that the waves carry there is found by
// stepping back from the sideways swing, as Water.SurfaceAt does.
float waterHeight(vec2 xz, out vec3 normal)
{
	vec2 p = xz;
	float fold;
	for (int k = 0; k < 3; k++)
	{
		vec3 swing = waterWaves(p, 0.0, normal, fold);
		p = xz - swing.xz;
	}
	vec3 offset = waterWaves(p, 0.0, normal, fold);
	return u_waterLevel.x + offset.y;
}

vec2 waterHash(vec2 p)
{
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453) * 2.0 - 1.0;
}

// Gradient noise: x the value (about -0.7 to 0.7), yz how it changes along x and y.
vec3 waterNoise(vec2 p)
{
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	vec2 ga = waterHash(i);
	vec2 gb = waterHash(i + vec2(1.0, 0.0));
	vec2 gc = waterHash(i + vec2(0.0, 1.0));
	vec2 gd = waterHash(i + vec2(1.0, 1.0));
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float value = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
	vec2 slope = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * (va - vb - vc + vd) + vec2(vb, vc) - va);
	return vec3(value, slope);
}

// The bright net of light that moving water casts on what is under it (0 to 1).
float waterCaustics(vec2 p, float time)
{
	vec2 q = p * 0.8;
	vec2 w = q + vec2(sin(q.y * 1.3 + time * 0.7), cos(q.x * 1.1 - time * 0.6)) * 0.6;
	float a = sin(w.x * 2.3 + time * 0.5) + sin(w.y * 2.0 - time * 0.4) + sin((w.x + w.y) * 1.7 + time * 0.3);
	float b = sin(w.x * 3.1 - time * 0.45) + sin(w.y * 2.7 + time * 0.55);
	return pow(clamp(1.0 - abs(a) * 0.55, 0.0, 1.0), 5.0) * 0.7 + pow(clamp(1.0 - abs(b) * 0.6, 0.0, 1.0), 6.0) * 0.5;
}

#endif // TALLOW_WATER_SH
