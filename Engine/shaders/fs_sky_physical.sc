$input v_texcoord0, v_wpos

// The physical sky with the sun, moon and stars, linear HDR output (include/sky_physical.sh).
#include <bgfx_shader.sh>
#include "sky_physical.sh"

uniform vec4 u_camPos;

void main()
{
	gl_FragColor = vec4(skyColor(normalize(v_wpos - u_camPos.xyz), 1.0, u_camPos.xyz, v_texcoord0), 1.0);
}
