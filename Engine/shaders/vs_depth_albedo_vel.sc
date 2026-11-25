$input a_position, a_color0, a_texcoord0, i_data0, i_data1, i_data2, i_data3, i_data4, i_data5, i_data6
$output v_depth, v_color0, v_texcoord0, v_velCur, v_velPrev

// vs_depth_albedo.sc with the motion vector (vs_depth_vel.sc). The instance's tint goes in the w of the first three
// columns (the depth pass does not need the metallic and roughness that are there in the lit pass), so that the
// previous matrix fits in the instance data (i_data4..6).
#include <bgfx_shader.sh>

uniform mat4 u_depthViewProj;
uniform mat4 u_velCur;
uniform mat4 u_velPrev;
uniform vec4 u_surface;       // y: time in seconds
uniform vec4 u_depthParams;   // y: 1 in palette mode (the vertex colour is data, not a colour)
#include "wind.sh"
#include "velocity.sh"

void main()
{
	mat4 model = mtxFromCols(vec4(i_data0.xyz, 0.0), vec4(i_data1.xyz, 0.0), vec4(i_data2.xyz, 0.0), i_data3);
	vec4 world = mul(model, vec4(a_position, 1.0));
	world.xyz = tw_bend(world.xyz, i_data3.xyz, u_surface.y);
	vec3 prev = vec3(dot(i_data4.xyz, a_position) + i_data4.w, dot(i_data5.xyz, a_position) + i_data5.w, dot(i_data6.xyz, a_position) + i_data6.w);
	prev = tw_bend(prev, vec3(i_data4.w, i_data5.w, i_data6.w), u_velParams.z);
	gl_Position = mul(u_depthViewProj, world);
	v_depth = mul(u_view, world).z;
	v_velCur = mul(u_velCur, world);
	v_velPrev = mul(u_velPrev, vec4(prev, 1.0));
	v_color0 = u_depthParams.y > 0.5 ? vec4_splat(1.0) : a_color0 * vec4(i_data0.w, i_data1.w, i_data2.w, 1.0);
	v_texcoord0 = a_texcoord0;
}
