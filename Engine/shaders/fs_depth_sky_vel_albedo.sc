$input v_texcoord0, v_wpos

// (With the colour target of the global illumination too: cleared.) Drawn first in the depth pass, over the whole picture: what nothing is drawn over is the sky, which is at an infinite
// distance (SKY_DEPTH) and moves only as the camera turns. The motion vector of its direction, from last frame's and
// this frame's view and projection (velocity.sh).
#include <bgfx_shader.sh>
#include "velocity.sh"

uniform mat4 u_velCur;
uniform mat4 u_velPrev;
uniform vec4 u_camPos;

void main()
{
	vec4 direction = vec4(v_wpos - u_camPos.xyz, 0.0);
	gl_FragData[0] = vec4(60000.0, 0.0, 0.0, 1.0);
	gl_FragData[1] = vec4(tw_velocity(mul(u_velCur, direction), mul(u_velPrev, direction)), 0.0, 1.0);
	gl_FragData[2] = vec4(0.0, 0.0, 0.0, 0.0);
}
