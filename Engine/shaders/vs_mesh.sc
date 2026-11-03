$input a_position, a_normal, a_color0, a_texcoord0, a_texcoord1, i_data0, i_data1, i_data2, i_data3, i_data4
$output v_wpos, v_normal, v_color0, v_texcoord0, v_depth, v_texcoord1, v_surface

// Lit mesh vertex shader. Every draw is instanced: i_data0..3 is the model matrix,
// i_data4 a per-instance tint, so identical meshes batch into one call. The matrix's bottom
// row is always (0, 0, 0, 1), so its first three numbers carry the instance's own metallic and
// roughness instead, and 1 when it has them (renderers without a material: see RenderView.FillInstances).
#include <bgfx_shader.sh>

uniform vec4 u_surface;       // y: time in seconds
uniform vec4 u_params[8];     // a custom shader's own properties
uniform vec4 u_palette;       // x 1 in palette mode (the vertex colour is data: no tint)
#include "wind.sh"
#include "shadergraph.sh"
//@PROPERTIES

void main()
{
	mat4 model = mtxFromCols(vec4(i_data0.xyz, 0.0), vec4(i_data1.xyz, 0.0), vec4(i_data2.xyz, 0.0), i_data3);
	v_surface = vec3(i_data0.w, i_data1.w, i_data2.w);
	// A custom shader's vertex code may move position (in the mesh's own space) and read normal, uv and time.
	vec3 position = a_position;
	vec3 normal = a_normal;
	vec2 uv = a_texcoord0;
	float time = u_surface.y;
//@VERTEX
//@UNDEFINE
	vec4 wpos = mul(model, vec4(position, 1.0));
	wpos.xyz = tw_bend(wpos.xyz, i_data3.xyz, time);
	gl_Position = mul(u_viewProj, wpos);
	v_wpos = wpos.xyz;
	// Inverse-transpose normal transform: direct multiplication breaks nonuniform scale.
    vec3 co0 = cross(i_data1.xyz, i_data2.xyz);
    vec3 co1 = cross(i_data2.xyz, i_data0.xyz);
    vec3 co2 = cross(i_data0.xyz, i_data1.xyz);
    float orientation = dot(i_data0.xyz, co0) < 0.0 ? -1.0 : 1.0;
    v_normal = (co0 * normal.x + co1 * normal.y + co2 * normal.z) * orientation;
	// In palette mode the colour's bytes are a face's palette index, glow, surface and flags: kept exact.
	v_color0 = u_palette.x > 0.5 ? a_color0 : a_color0 * i_data4;
	v_texcoord0 = uv;
	v_texcoord1 = a_texcoord1;
	v_depth = gl_Position.w;
}
