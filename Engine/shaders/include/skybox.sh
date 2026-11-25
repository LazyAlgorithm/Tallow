// A custom skybox (SkyMode.Custom, Engine/src/Render/Skybox.bf), shared by fs_sky_custom.sc (the sky) and
// fs_env_sky_custom.sc (the sky's reflection cube): the day skybox's cube, turned round the vertical axis, exposed and
// multiplied by its colour (the tint and, with Day / Night, the sun's colour and brightness), plus the night skybox's
// (faded in after sunset; a weight of 0 by day or without one). The _blend variants (TW_SKY_BLEND) add the physical
// sky under it (sky_physical.sh, stages 0 and 1), so the skyboxes sit on stages 2 and 3. Include after bgfx_shader.sh.
#ifndef TALLOW_SKYBOX_SH
#define TALLOW_SKYBOX_SH

SAMPLERCUBE(s_skybox, 2);
SAMPLERCUBE(s_skyboxNight, 3);
uniform vec4 u_skybox;      // x, y: sin and cos of the rotation; z: 2^exposure; w: the day cube's mip level to read
uniform vec4 u_skyboxTint;  // rgb: the day skybox's linear colour; w: how much of the physical sky shows under it
uniform vec4 u_skyboxNight; // rgb: the night skybox's linear colour (exposure, tint and fade); w: its mip level

vec3 skyboxColor(vec3 dir)
{
	// Turning the skybox by +angle (seen from above, clockwise) means looking up the direction turned back by it.
	vec3 turned = vec3(u_skybox.y * dir.x - u_skybox.x * dir.z, dir.y, u_skybox.x * dir.x + u_skybox.y * dir.z);
	vec3 color = textureCubeLod(s_skybox, turned, u_skybox.w).rgb * u_skybox.z * u_skyboxTint.rgb;
	return color + textureCubeLod(s_skyboxNight, turned, u_skyboxNight.w).rgb * u_skyboxNight.rgb;
}

#endif
