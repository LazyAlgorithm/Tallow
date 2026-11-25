$input v_depth, v_velCur, v_velPrev

// As fs_depth.sc, with the motion vector in the second target (velocity.sh).
#include <bgfx_shader.sh>
#include "velocity.sh"

uniform vec4 u_depthParams;

void main()
{
	gl_FragData[0] = vec4(u_depthParams.x > 0.5 ? -1.0 : v_depth, 0.0, 0.0, 1.0);
	gl_FragData[1] = vec4(tw_velocity(v_velCur, v_velPrev), u_velParams.w, 1.0);
}
