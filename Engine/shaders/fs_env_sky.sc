$input v_texcoord0, v_wpos

// One face of the sky's reflection cube (tallowengine.com/docs/reflections): the sky without the sun's disc.
#include <bgfx_shader.sh>
#include "sky.sh"
#include "cube.sh"

uniform vec4 u_envFace; // x: the face, 0 to 5

void main()
{
	gl_FragColor = vec4(skyColor(cubeDirection(u_envFace.x, v_texcoord0), 0.0), 1.0);
}
