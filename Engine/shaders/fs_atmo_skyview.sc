$input v_texcoord0, v_wpos

// The physical sky's sky-view LUT (include/atmosphere.sh; as Bevy's sky_view_lut): the sky's light in every direction
// from the viewer's height for a sun of light 1 outside the air, single scattering from the transmittance LUT plus
// multiple scattering from its LUT, and the ground's bounce below the horizon. x: azimuth from the sun, y: elevation.
// Made again when the sun has moved more than a little (PhysicalSky.bf).
#include <bgfx_shader.sh>
#include "atmosphere.sh"

SAMPLER2D(s_atmoMultiscatter, 1);

uniform vec4 u_sunDir;

#define MAX_STEPS 24

void main()
{
	float r = u_atmoParams.y;
	float elevation, azimuth;
	atmoSkyViewAngles(v_texcoord0, r, elevation, azimuth);
	vec3 dir = vec3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth));
	float muSun = clamp(u_sunDir.y, -1.0, 1.0);
	vec3 sun = vec3(0.0, muSun, sqrt(max(1.0 - muSun * muSun, 0.0)));
	vec3 pos = vec3(0.0, r, 0.0);
	float cosTheta = dot(dir, sun);
	float phaseR = atmoPhaseRayleigh(cosTheta);
	float phaseM = atmoPhaseMie(cosTheta);

	float ground = atmoDistanceToGround(r, dir.y);
	float tMax = ground >= 0.0 ? ground : atmoDistanceToTop(r, dir.y);
	float steps = u_atmoParams.w;
	vec3 throughput = vec3_splat(1.0);
	vec3 light = vec3_splat(0.0);
	float previous = 0.0;
	for (int i = 0; i < MAX_STEPS; i++)
	{
		if (float(i) >= steps)
			break;
		// Steps grow away from the viewer (most of the air, and the detail, is near).
		float a = (float(i) + 1.0) / steps;
		float next = tMax * a * a;
		float dt = next - previous;
		float t = previous + 0.3 * dt;
		previous = next;
		vec3 p = pos + dir * t;
		float rs = length(p);
		float muSs = dot(p, sun) / rs;
		vec3 rayleigh, extinction;
		float mie;
		atmoMedium(rs, rayleigh, mie, extinction);
		vec3 sampleT = exp(-extinction * dt);
		vec3 sunLight = atmoTransmittance(rs, muSs) * atmoSunVisible(rs, muSs);
		vec2 msUv = vec2(muSs * 0.5 + 0.5, clamp((rs - ATMO_BOTTOM) / (ATMO_TOP - ATMO_BOTTOM), 0.0, 1.0));
		vec3 multiple = texture2DLod(s_atmoMultiscatter, msUv, 0.0).rgb;
		vec3 inscatter = (rayleigh * phaseR + vec3_splat(mie * phaseM)) * sunLight + (rayleigh + vec3_splat(mie)) * multiple;
		light += throughput * (inscatter - inscatter * sampleT) / extinction;
		throughput *= sampleT;
	}
	if (ground >= 0.0)
	{
		// The ground lit by the sun, seen through the air (so the horizon line is continuous).
		vec3 p = pos + dir * ground;
		vec3 n = normalize(p);
		float muSg = dot(n, sun);
		vec3 sunLight = atmoTransmittance(ATMO_BOTTOM, muSg) * atmoSunVisible(ATMO_BOTTOM, muSg) * max(muSg, 0.0);
		light += throughput * sunLight * u_atmoParams.z / ATMO_PI;
	}
	gl_FragColor = vec4(light, 1.0);
}
