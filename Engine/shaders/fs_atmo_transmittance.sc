$input v_texcoord0, v_wpos

// The physical sky's transmittance LUT (include/atmosphere.sh): how much light gets from a height, along a direction,
// to space. Made once (the atmosphere does not change) and when the turbidity changes.
#include <bgfx_shader.sh>
#include "atmosphere.sh"

#define STEPS 40

void main()
{
	float r, mu;
	atmoTransmittanceRMu(v_texcoord0, r, mu);
	float dist = atmoDistanceToTop(r, mu);
	float dt = dist / float(STEPS);
	vec3 depth = vec3_splat(0.0);
	for (int i = 0; i < STEPS; i++)
	{
		float t = (float(i) + 0.5) * dt;
		float rs = sqrt(r * r + t * t + 2.0 * r * mu * t);
		vec3 rayleigh, extinction;
		float mie;
		atmoMedium(rs, rayleigh, mie, extinction);
		depth += extinction * dt;
	}
	gl_FragColor = vec4(exp(-depth), 1.0);
}
