$input a_position, i_data0, i_data1, i_data2, i_data3, i_data4, i_data5, i_data6
$output v_depth, v_velCur, v_velPrev

// The depth pass as vs_depth.sc, also giving the motion vector: the per-instance data is the world matrix (i_data0..3)
// and last frame's as its three rows (i_data4..6), so the vertex is moved by the object's movement and by the wind as it
// was a frame ago. u_depthViewProj has the camera's jitter; u_velCur and u_velPrev (this and last frame's view and
// projection) do not. A skinned mesh's bones are not in it (only the object's own movement): see RenderView.
#include <bgfx_shader.sh>

uniform mat4 u_depthViewProj;
uniform mat4 u_velCur;
uniform mat4 u_velPrev;
uniform vec4 u_surface;       // y: time in seconds
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
}
