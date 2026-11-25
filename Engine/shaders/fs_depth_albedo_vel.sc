$input v_depth, v_color0, v_texcoord0, v_velCur, v_velPrev

// fs_depth_albedo.sc with the motion vector in the second target and the colour in the third.
#include <bgfx_shader.sh>
#include "velocity.sh"

SAMPLER2D(s_albedo, 0);

uniform vec4 u_depthParams;  // x 1 for the viewmodel, y 1 in palette mode (a plain grey stands in)
uniform vec4 u_uvTransform;

void main()
{
	vec2 uv = v_texcoord0 * u_uvTransform.xy + u_uvTransform.zw;
	vec3 albedo = u_depthParams.y > 0.5 ? vec3_splat(0.5) : v_color0.rgb * texture2D(s_albedo, uv).rgb;
	gl_FragData[0] = vec4(u_depthParams.x > 0.5 ? -1.0 : v_depth, 0.0, 0.0, 1.0);
	gl_FragData[1] = vec4(tw_velocity(v_velCur, v_velPrev), u_velParams.w, 1.0);
	gl_FragData[2] = vec4(clamp(albedo, 0.0, 1.0), 1.0);
}
