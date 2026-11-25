$input v_texcoord0, v_wpos

// One face of a custom skybox's reflection cube (SkyMode.Custom, tallowengine.com/docs/reflections): the skybox's
// cube turned, exposed and tinted as fs_sky_custom draws it, read at the mip level that matches the reflection
// cube's size so it is averaged, not aliased. fs_env_filter then makes the rough levels and the ambient light.
#include <bgfx_shader.sh>
#include "cube.sh"

SAMPLERCUBE(s_skybox, 0);
uniform vec4 u_envFace;    // x: the face, 0 to 5
uniform vec4 u_skybox;     // x, y: sin and cos of the rotation; z: 2^exposure; w: the mip level to read
uniform vec4 u_skyboxTint; // rgb: linear tint

void main()
{
	vec3 dir = cubeDirection(u_envFace.x, v_texcoord0);
	vec3 turned = vec3(u_skybox.y * dir.x - u_skybox.x * dir.z, dir.y, u_skybox.x * dir.x + u_skybox.y * dir.z);
	vec3 color = textureCubeLod(s_skybox, turned, u_skybox.w).rgb;
	gl_FragColor = vec4(color * u_skybox.z * u_skyboxTint.rgb, 1.0);
}
