$input v_depth, v_color0, v_texcoord0

// Writes the distance in front of the camera (or -1 for the viewmodel) as fs_depth.sc, and the surface's base colour
// (as the lit pass reads it, before the sRGB-to-linear step) to the second target.
#include <bgfx_shader.sh>

SAMPLER2D(s_albedo, 0);

uniform vec4 u_depthParams;  // x 1 for the viewmodel, y 1 in palette mode (a plain grey stands in)
uniform vec4 u_uvTransform;

void main()
{
	vec2 uv = v_texcoord0 * u_uvTransform.xy + u_uvTransform.zw;
	vec3 albedo = u_depthParams.y > 0.5 ? vec3_splat(0.5) : v_color0.rgb * texture2D(s_albedo, uv).rgb;
	gl_FragData[0] = vec4(u_depthParams.x > 0.5 ? -1.0 : v_depth, 0.0, 0.0, 1.0);
	gl_FragData[1] = vec4(clamp(albedo, 0.0, 1.0), 1.0);
}
