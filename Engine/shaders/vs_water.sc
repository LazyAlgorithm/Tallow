$input a_position
$output v_wpos, v_normal, v_color0, v_texcoord0, v_depth

// The water's surface (tallowengine.com/docs/water): a grid of still water placed by u_waterModel, moved by the waves of
// include/water.sh. v_texcoord0 is the still point (for ripples and foam), v_color0.x how folded the crest is.
#include <bgfx_shader.sh>
#include "water.sh"

uniform mat4 u_waterModel;
uniform vec4 u_camPos;

void main()
{
	vec3 still = mul(u_waterModel, vec4(a_position, 1.0)).xyz;
	vec3 normal;
	float fold;
	vec3 offset = waterWaves(still.xz, length(still.xz - u_camPos.xz), normal, fold);
	vec3 world = still + offset;
	v_wpos = world;
	v_normal = normal;
	v_texcoord0 = still.xz;
	v_color0 = vec4(fold, offset.y, 0.0, 1.0);
	gl_Position = mul(u_viewProj, vec4(world, 1.0));
	v_depth = gl_Position.w;
}
