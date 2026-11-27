$input v_texcoord0, v_wpos

// One face of the physical sky's reflection cube (tallowengine.com/docs/reflections): without the sun's disc, moon or stars.
#include <bgfx_shader.sh>
#include "sky_physical.sh"
#include "cube.sh"

uniform vec4 u_envFace; // x: the face, 0 to 5

void main()
{
	// The cube is drawn from the world's origin, so the cloud deck keeps a steady shape across its faces.
	gl_FragColor = vec4(skyColor(cubeDirection(u_envFace.x, v_texcoord0), 0.0, vec3_splat(0.0)), 1.0);
}
