$input v_texcoord0, v_wpos

// A custom skybox (SkyMode.Custom, Engine/src/Render/Skybox.bf, include/skybox.sh): the day and night skyboxes,
// linear HDR output. fs_sky_custom_blend (TW_SKY_BLEND, tools/compile_shaders.py) draws the physical sky under it.
#include <bgfx_shader.sh>
#ifdef TW_SKY_BLEND
#include "sky_physical.sh"
#endif
#include "skybox.sh"

uniform vec4 u_camPos;

void main()
{
	vec3 dir = normalize(v_wpos - u_camPos.xyz);
	vec3 color = skyboxColor(dir);
#ifdef TW_SKY_BLEND
	color += skyColor(dir, 1.0) * u_skyboxTint.w;
#endif
	gl_FragColor = vec4(color, 1.0);
}
