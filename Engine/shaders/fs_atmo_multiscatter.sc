$input v_texcoord0, v_wpos

// The physical sky's multiple-scattering LUT (include/atmosphere.sh; Hillaire 2020 section 5.5, as in Bevy): light
// scattered more than once, as a transfer psi = L2 / (1 - f_ms) from the second order. x: the sun's cosine to the
// up direction (-1 to 1), y: height (bottom to top). 64 directions x 20 steps in one fragment (no compute needed).
#include <bgfx_shader.sh>
#include "atmosphere.sh"

#define DIRECTIONS 64
#define STEPS 20

void main()
{
	float muS = v_texcoord0.x * 2.0 - 1.0;
	float r = mix(ATMO_BOTTOM + 0.01, ATMO_TOP - 0.01, v_texcoord0.y);
	vec3 pos = vec3(0.0, r, 0.0);
	vec3 sun = vec3(0.0, muS, sqrt(max(1.0 - muS * muS, 0.0)));
	float isotropic = 1.0 / (4.0 * ATMO_PI);
	vec3 second = vec3_splat(0.0);
	vec3 transfer = vec3_splat(0.0);
	for (int i = 0; i < DIRECTIONS; i++)
	{
		// Fibonacci sphere: an even spread of directions.
		float z = 1.0 - (2.0 * float(i) + 1.0) / float(DIRECTIONS);
		float ring = sqrt(max(1.0 - z * z, 0.0));
		float phi = float(i) * 2.39996323;
		vec3 dir = vec3(ring * cos(phi), z, ring * sin(phi));
		float mu = dir.y;
		float ground = atmoDistanceToGround(r, mu);
		float tMax = ground >= 0.0 ? ground : atmoDistanceToTop(r, mu);
		float dt = tMax / float(STEPS);
		vec3 throughput = vec3_splat(1.0);
		vec3 light = vec3_splat(0.0);
		vec3 f = vec3_splat(0.0);
		for (int s = 0; s < STEPS; s++)
		{
			float t = (float(s) + 0.5) * dt;
			vec3 p = pos + dir * t;
			float rs = length(p);
			float muSs = dot(p, sun) / rs;
			vec3 rayleigh, extinction;
			float mie;
			atmoMedium(rs, rayleigh, mie, extinction);
			vec3 scattering = rayleigh + vec3_splat(mie);
			vec3 sampleT = exp(-extinction * dt);
			vec3 sunLight = atmoTransmittance(rs, muSs) * atmoSunVisible(rs, muSs);
			vec3 inscatter = scattering * sunLight * isotropic;
			// Integrated over the step with the energy-conserving form (Hillaire 2015).
			light += throughput * (inscatter - inscatter * sampleT) / extinction;
			f += throughput * (scattering - scattering * sampleT) / extinction;
			throughput *= sampleT;
		}
		if (ground >= 0.0)
		{
			vec3 p = pos + dir * ground;
			float muSg = dot(normalize(p), sun);
			light += throughput * atmoTransmittance(ATMO_BOTTOM, muSg) * atmoSunVisible(ATMO_BOTTOM, muSg) * max(muSg, 0.0) * u_atmoParams.z / ATMO_PI;
		}
		second += light;
		transfer += f;
	}
	second /= float(DIRECTIONS);
	transfer /= float(DIRECTIONS);
	gl_FragColor = vec4(second / max(vec3_splat(1.0) - transfer, vec3_splat(1.0e-3)), 1.0);
}
