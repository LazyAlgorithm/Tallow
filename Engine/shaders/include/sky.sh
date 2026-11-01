// The procedural sky (fs_sky.sc draws it; fs_env_sky.sc puts it into the sky's reflection cube): a gradient from
// the horizon up to the zenith and down to the ground, and the sun. Include after bgfx_shader.sh.
#ifndef TALLOW_SKY_SH
#define TALLOW_SKY_SH

uniform vec4 u_sunDir;
uniform vec4 u_sunColor;
uniform vec4 u_skyZenith;
uniform vec4 u_skyHorizon;
uniform vec4 u_skyGround;

// The sky's colour in direction dir (unit length), linear HDR. sunDisc 0 leaves out the sun's bright disc (but not
// its glow): reflections get the sun's highlight from the sun itself, as a light.
vec3 skyColor(vec3 dir, float sunDisc)
{
	float up = dir.y;
	vec3 sky = mix(u_skyHorizon.rgb, u_skyZenith.rgb, pow(clamp(up, 0.0, 1.0), 0.45));
	vec3 ground = mix(u_skyHorizon.rgb, u_skyGround.rgb, pow(clamp(-up, 0.0, 1.0), 0.35));
	vec3 color = up >= 0.0 ? sky : ground;

	float sun = max(dot(dir, u_sunDir.xyz), 0.0);
	float disc = smoothstep(0.9993, 0.9997, sun);
	float glow = pow(sun, 180.0) * 0.6 + pow(sun, 12.0) * 0.12;
	vec3 sunTint = u_sunColor.rgb / max(max(u_sunColor.r, max(u_sunColor.g, u_sunColor.b)), 1.0e-3);
	return color + sunTint * (disc * 12.0 * sunDisc + glow) * step(-0.02, up);
}

#endif
