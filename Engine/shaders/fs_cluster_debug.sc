$input v_wpos, v_normal, v_color0, v_texcoord0, v_depth, v_texcoord1, v_surface

// The debug views of cluster drawing (GpuDriven.DebugView): the colour vs_cluster_debug worked out, as it is. With TW_VT
// (fs_cluster_debug_vt) the colour is the virtual texture's: which mip level the page table shows at each pixel (green:
// the level the pixel needs, orange to red: a coarser tile stands in for a missing one), with a tile pattern on top.
#include <bgfx_shader.sh>

#ifdef TW_VT
#include "virtual_texture.sh"
SAMPLER2D(s_texture2, 3);
uniform vec4 u_uvTransform;   // xy tiling, zw offset
#endif

void main()
{
#ifdef TW_VT
	vec2 uv = v_texcoord0 * u_uvTransform.xy + u_uvTransform.zw;
	float wanted = floor(min(vtLod(uv), u_vtInfo.z));
	vec2 w = clamp(fract(uv), 0.0, 0.99999);
	vec4 e = floor(texture2DLod(s_texture2, w, wanted) * 255.0 + 0.5);
	float behind = clamp((e.z - wanted) / max(u_vtInfo.z, 1.0), 0.0, 1.0);
	vec3 level = mix(vec3(0.1, 0.8, 0.2), vec3(1.0, 0.25, 0.05), clamp(behind * 3.0, 0.0, 1.0));
	vec2 tiles = max(floor(u_vtInfo.xy * exp2(-wanted) / VT_TILE), vec2_splat(1.0));
	vec2 tile = floor(w * tiles);
	float checker = mod(tile.x + tile.y, 2.0);
	float shade = 0.65 + 0.35 * checker + (v_depth + v_color0.r) * 0.0;
	gl_FragColor = vec4(level * shade * (1.0 - wanted / (u_vtInfo.z + 1.0) * 0.5), 1.0);
#else
	gl_FragColor = vec4(v_color0.rgb + vec3_splat(v_depth * 0.0), 1.0);
#endif
}
