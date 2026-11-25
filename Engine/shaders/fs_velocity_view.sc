$input v_texcoord0, v_wpos

// A test view of the motion vectors (TALLOW_DEBUG_VELOCITY=1): grey is still, red/green are +x/+y pixels (x 4 pixels a
// full step), and the sky and the object edges show what the temporal passes use.
#include <bgfx_shader.sh>

SAMPLER2D(s_color, 0);

void main()
{
	vec3 m = texture2DLod(s_color, v_texcoord0, 0.0).xyz; vec2 v = m.xy;
	gl_FragColor = vec4(0.5 + v * 0.5, 0.5 + 0.5 * m.z, 1.0);
}
