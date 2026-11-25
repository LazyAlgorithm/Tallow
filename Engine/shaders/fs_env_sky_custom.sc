$input v_texcoord0, v_wpos

// One face of a custom skybox's reflection cube (SkyMode.Custom, tallowengine.com/docs/reflections): the skyboxes as
// fs_sky_custom draws them (include/skybox.sh), read at the mip level that matches the reflection cube's size so they
// are averaged, not aliased. fs_env_filter then makes the rough levels and the ambient light. fs_env_sky_custom_blend
// (TW_SKY_BLEND) adds the physical sky under it, without the sun's disc, moon or stars.
#include <bgfx_shader.sh>
#ifdef TW_SKY_BLEND
#include "sky_physical.sh"
#endif
#include "skybox.sh"
#include "cube.sh"

uniform vec4 u_envFace; // x: the face, 0 to 5

void main()
{
	vec3 dir = cubeDirection(u_envFace.x, v_texcoord0);
	vec3 color = skyboxColor(dir);
#ifdef TW_SKY_BLEND
	color += skyColor(dir, 0.0) * u_skyboxTint.w;
#endif
	gl_FragColor = vec4(color, 1.0);
}
