$input v_texcoord0, v_wpos

// A custom skybox (SkyMode.Custom, Engine/src/Render/Skybox.bf): the cube the skybox was imported to, turned round
// the vertical axis, scaled by its exposure and tinted. Linear HDR output.
#include <bgfx_shader.sh>

SAMPLERCUBE(s_skybox, 0);
uniform vec4 u_camPos;
uniform vec4 u_skybox;     // x, y: sin and cos of the rotation; z: 2^exposure
uniform vec4 u_skyboxTint; // rgb: linear tint

void main()
{
	vec3 dir = normalize(v_wpos - u_camPos.xyz);
	// Turning the skybox by +angle (seen from above, clockwise) means looking up the direction turned back by it.
	vec3 turned = vec3(u_skybox.y * dir.x - u_skybox.x * dir.z, dir.y, u_skybox.x * dir.x + u_skybox.y * dir.z);
	vec3 color = textureCubeLod(s_skybox, turned, 0.0).rgb;
	gl_FragColor = vec4(color * u_skybox.z * u_skyboxTint.rgb, 1.0);
}
