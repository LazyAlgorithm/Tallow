$input v_texcoord0, v_wpos

// Debug view of the occlusion pyramid (GpuDriven.DebugView.Hzb): one level of the pyramid of distances, as a picture
// (near is bright, far is dark, nothing drawn is black), over the whole screen.
#include <bgfx_shader.sh>
#include <bgfx_compute.sh>

BUFFER_RO(b_hzb, float, 4);

uniform vec4 u_hzbShow;   // x, y: the size of the level shown, z: where it starts in the buffer, w: the distance that is darkest

void main()
{
	vec2 uv = clamp(v_texcoord0, vec2_splat(0.0), vec2_splat(0.9999));
	uint x = uint(uv.x * u_hzbShow.x);
	uint y = uint(uv.y * u_hzbShow.y);
	float d = b_hzb[uint(u_hzbShow.z) + y * uint(u_hzbShow.x) + x];
	float v = d <= 0.0 ? 0.0 : 1.0 - sqrt(clamp(d / u_hzbShow.w, 0.0, 1.0)) * 0.9;
	gl_FragColor = vec4(v, v * 0.9, v * 0.8 + (d <= 0.0 ? 0.0 : 0.05), 1.0);
}
