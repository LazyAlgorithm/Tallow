// Virtual texture lookup (M4d). A picture of 128 px tiles lives in one shared physical cache (a 136 px slot holds a tile
// and its 4 px border, bgfx stage 2) and is found through a page table (stage 3): a texture with a mip chain of its own,
// one texel per tile, where a texel is (slot x, slot y, level of the tile that is there, 255). A tile that is not in the
// cache shows the coarsest one that is, so there is never a hole. Needs s_texture1 (the cache) and s_texture2 (the table).
uniform vec4 u_vtInfo;    // x, y: size of level 0 in texels, z: last level, w: id (the feedback pass writes it)
uniform vec4 u_vtCache;   // x, y: size of the cache in texels, z: log2 of how much smaller the feedback target is

#define VT_TILE 128.0
#define VT_BORDER 4.0
#define VT_PHYS 136.0

// How many texels of level 0 one pixel covers, as a level: 0 is sharp, 1 half as many, ...
float vtLod(vec2 uv)
{
	vec2 t = uv * u_vtInfo.xy;
	vec2 dx = dFdx(t);
	vec2 dy = dFdy(t);
	return max(0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1.0e-8)), 0.0);
}

#ifdef VT_SAMPLE
// One level of the picture at uv (inside 0 to 1): the table says which cached tile stands in for it.
vec4 vtLevel(vec2 uv, float level)
{
	vec4 e = floor(texture2DLod(s_texture2, uv, level) * 255.0 + 0.5);
	vec2 size = max(u_vtInfo.xy * exp2(-e.z), vec2_splat(1.0));
	vec2 texel = uv * size;
	vec2 tile = floor(texel / VT_TILE);
	vec2 inTile = texel - tile * VT_TILE;
	return texture2DLod(s_texture1, (e.xy * VT_PHYS + VT_BORDER + inTile) / u_vtCache.xy, 0.0);
}

// Trilinear: two levels (each from its own tile), blended.
vec4 vtSample(vec2 uv)
{
	float lod = min(vtLod(uv), u_vtInfo.z);
	vec2 w = clamp(fract(uv), 0.0, 0.99999);
	float l0 = floor(lod);
	vec4 a = vtLevel(w, l0);
	vec4 b = vtLevel(w, min(l0 + 1.0, u_vtInfo.z));
	return mix(a, b, lod - l0);
}
#endif
