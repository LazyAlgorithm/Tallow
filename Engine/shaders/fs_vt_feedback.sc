$input v_depth, v_color0, v_texcoord0

// The virtual texture feedback pass (M4d): what the camera sees of a virtual texture, drawn small. Each pixel holds the
// tile it needs: x, y, level and the texture's id, in bytes (id 0 is nothing). The CPU reads it a few frames later and
// asks for the tiles that are not in the cache. The picture is smaller than the screen, so its levels are shifted back.
#include <bgfx_shader.sh>
#include "virtual_texture.sh"

uniform vec4 u_uvTransform;   // xy tiling, zw offset

void main()
{
	vec2 uv = v_texcoord0 * u_uvTransform.xy + u_uvTransform.zw;
	float level = floor(clamp(vtLod(uv) - u_vtCache.z, 0.0, u_vtInfo.z));
	vec2 w = clamp(fract(uv), 0.0, 0.99999);
	vec2 tiles = max(floor(u_vtInfo.xy * exp2(-level) / VT_TILE), vec2_splat(1.0));
	vec2 tile = floor(w * tiles);
	float keep = (v_depth + v_color0.r) * 0.0;
	gl_FragColor = vec4(tile.x + keep, tile.y, level, u_vtInfo.w) / 255.0;
}
