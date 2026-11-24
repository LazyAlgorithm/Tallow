$input a_position, a_color0, a_texcoord0, i_data0, i_data1, i_data2, i_data3, i_data4
$output v_depth, v_color0, v_texcoord0

// The depth pass with the surfaces' base colour alongside (screen-space global illumination, fs_ssgi_apply.sc): as
// vs_depth.sc, and the colour the lit pass would multiply the texture by (vertex colour times the instance's tint).
#include <bgfx_shader.sh>

uniform mat4 u_depthViewProj;
uniform vec4 u_surface;       // y: time in seconds
uniform vec4 u_depthParams;   // y: 1 in palette mode (the vertex colour is data, not a colour)
#include "wind.sh"

void main()
{
	mat4 model = mtxFromCols(vec4(i_data0.xyz, 0.0), vec4(i_data1.xyz, 0.0), vec4(i_data2.xyz, 0.0), i_data3);
	vec4 world = mul(model, vec4(a_position, 1.0));
	world.xyz = tw_bend(world.xyz, i_data3.xyz, u_surface.y);
	gl_Position = mul(u_depthViewProj, world);
	v_depth = mul(u_view, world).z;
	v_color0 = u_depthParams.y > 0.5 ? vec4_splat(1.0) : a_color0 * i_data4;
	v_texcoord0 = a_texcoord0;
}
