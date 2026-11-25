// The physical sky's Earth atmosphere (tallowengine.com/docs/day-night): constants, the medium, ray/sphere sums,
// phase functions and the look-up tables' (LUTs') mappings. Ported from Bevy's bevy_pbr atmosphere shaders (the
// analytic-phase Earth version; MIT licence, Engine/shaders/licenses/Bevy-LICENSE-MIT.txt), after Hillaire 2020,
// "A Scalable and Production Ready Sky and Atmosphere Rendering Technique". The same numbers as the CPU model in
// Engine/src/Scene/Atmosphere.bf, here in kilometres (precision), coefficients per kilometre.
// Include after bgfx_shader.sh.
#ifndef TALLOW_ATMOSPHERE_SH
#define TALLOW_ATMOSPHERE_SH

#define ATMO_PI 3.14159265
#define ATMO_BOTTOM 6360.0
#define ATMO_TOP 6460.0
#define ATMO_RAYLEIGH vec3(5.802e-3, 13.558e-3, 33.1e-3)
#define ATMO_RAYLEIGH_HEIGHT 8.0
#define ATMO_MIE_SCATTERING 3.996e-3
#define ATMO_MIE_ABSORPTION 4.40e-3
#define ATMO_MIE_HEIGHT 1.2
#define ATMO_MIE_G 0.8
#define ATMO_OZONE vec3(0.650e-3, 1.881e-3, 0.085e-3)

// x: Mie density scale (turbidity / 2.5), y: the viewer's distance from the planet's centre (km), z: ground albedo,
// w: sky-view samples.
uniform vec4 u_atmoParams;

SAMPLER2D(s_atmoTransmittance, 0);

// The air at distance r (km) from the planet's centre: Rayleigh scattering, Mie scattering, and all extinction.
void atmoMedium(float r, out vec3 rayleigh, out float mie, out vec3 extinction)
{
	float h = max(r - ATMO_BOTTOM, 0.0);
	float mieDensity = exp(-h / ATMO_MIE_HEIGHT) * u_atmoParams.x;
	float ozone = max(0.0, 1.0 - abs(h - 25.0) / 15.0);
	rayleigh = ATMO_RAYLEIGH * exp(-h / ATMO_RAYLEIGH_HEIGHT);
	mie = ATMO_MIE_SCATTERING * mieDensity;
	extinction = rayleigh + vec3_splat((ATMO_MIE_SCATTERING + ATMO_MIE_ABSORPTION) * mieDensity) + ATMO_OZONE * ozone;
}

float atmoPhaseRayleigh(float mu)
{
	return 3.0 / (16.0 * ATMO_PI) * (1.0 + mu * mu);
}

// Cornette-Shanks.
float atmoPhaseMie(float mu)
{
	float g = ATMO_MIE_G;
	float g2 = g * g;
	float k = 3.0 / (8.0 * ATMO_PI) * (1.0 - g2) / (2.0 + g2);
	return k * (1.0 + mu * mu) / pow(max(1.0 + g2 - 2.0 * g * mu, 1.0e-4), 1.5);
}

// Distance from radius r along a ray with cosine mu (to the up direction) to the top of the atmosphere.
float atmoDistanceToTop(float r, float mu)
{
	float d = r * r * (mu * mu - 1.0) + ATMO_TOP * ATMO_TOP;
	return max(0.0, -r * mu + sqrt(max(d, 0.0)));
}

// Distance to the ground, or -1 when the ray misses it.
float atmoDistanceToGround(float r, float mu)
{
	float d = r * r * (mu * mu - 1.0) + ATMO_BOTTOM * ATMO_BOTTOM;
	if (mu >= 0.0 || d < 0.0)
		return -1.0;
	return max(0.0, -r * mu - sqrt(d));
}

// How much of the sun is above the horizon seen from radius r with the sun at cosine muS: 1 above, 0 below, soft over
// -0.8 to +0.4 degrees as in the CPU model.
float atmoSunVisible(float r, float muS)
{
	float horizon = -sqrt(max(1.0 - (ATMO_BOTTOM / r) * (ATMO_BOTTOM / r), 0.0));
	float above = asin(clamp(muS, -1.0, 1.0)) - asin(horizon);
	return smoothstep(-0.01396, 0.00698, above);
}

// ---- Transmittance LUT (Bruneton's (r, mu) mapping) ----

vec2 atmoTransmittanceUv(float r, float mu)
{
	float H = sqrt(ATMO_TOP * ATMO_TOP - ATMO_BOTTOM * ATMO_BOTTOM);
	float rho = sqrt(max(r * r - ATMO_BOTTOM * ATMO_BOTTOM, 0.0));
	float d = atmoDistanceToTop(r, mu);
	float dMin = ATMO_TOP - r;
	float dMax = rho + H;
	return vec2((d - dMin) / max(dMax - dMin, 1.0e-4), rho / H);
}

void atmoTransmittanceRMu(vec2 uv, out float r, out float mu)
{
	float H = sqrt(ATMO_TOP * ATMO_TOP - ATMO_BOTTOM * ATMO_BOTTOM);
	float rho = H * uv.y;
	r = sqrt(rho * rho + ATMO_BOTTOM * ATMO_BOTTOM);
	float dMin = ATMO_TOP - r;
	float dMax = rho + H;
	float d = dMin + uv.x * (dMax - dMin);
	mu = d <= 0.0 ? 1.0 : (H * H - rho * rho - d * d) / (2.0 * r * d);
	mu = clamp(mu, -1.0, 1.0);
}

// The light that gets from radius r along cosine mu to space (not counting the ground in the way).
vec3 atmoTransmittance(float r, float mu)
{
	return texture2DLod(s_atmoTransmittance, atmoTransmittanceUv(r, mu), 0.0).rgb;
}

// ---- Sky-view LUT: x the azimuth from the sun (0 to pi, squeezed near the sun), y the elevation with the horizon in
// the middle (Bevy's sqrt horizon mapping, so the horizon gets the most rows). ----

float atmoHorizonElevation(float r)
{
	// The horizon dips below level by acos(bottom / r).
	return -acos(clamp(ATMO_BOTTOM / r, 0.0, 1.0));
}

vec2 atmoSkyViewUv(float r, float elevation, float azimuth)
{
	float l = elevation - atmoHorizonElevation(r);
	float v = 0.5 + 0.5 * sign(l) * sqrt(min(abs(l) / (0.5 * ATMO_PI), 1.0));
	float u = sqrt(clamp(azimuth / ATMO_PI, 0.0, 1.0));
	return vec2(u, v);
}

void atmoSkyViewAngles(vec2 uv, float r, out float elevation, out float azimuth)
{
	float c = uv.y * 2.0 - 1.0;
	float l = sign(c) * c * c * 0.5 * ATMO_PI;
	elevation = clamp(l + atmoHorizonElevation(r), -0.5 * ATMO_PI, 0.5 * ATMO_PI);
	azimuth = uv.x * uv.x * ATMO_PI;
}

#endif
