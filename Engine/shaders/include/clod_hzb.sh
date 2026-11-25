// The occlusion test of cluster LOD drawing: whether a sphere is hidden behind what an earlier picture drew. The picture is
// a pyramid of distances (GpuDrivenView.bf builds it): level 0 holds, for each 2 x 2 pixels, the farthest distance in front
// of the camera that anything drawn there has, and each level above holds the farthest of the four below it. A sphere is
// hidden when even its nearest point is farther than the farthest surface drawn anywhere it covers. Include after
// defining CLOD_HZB_REGISTER (the buffer's place in the shader).
//
//   u_clodView, u_clodProj  the camera the picture was drawn from
//   u_clodHzb               x, y: the size of level 0 (powers of two), z: the number of levels, w: 1 when row 0 is the top
//   u_clodScreen            x, y: the picture's size in pixels, z: the nearest distance drawn

BUFFER_RO(b_hzb, float, CLOD_HZB_REGISTER);

uniform mat4 u_clodView;
uniform mat4 u_clodProj;
uniform vec4 u_clodHzb;
uniform vec4 u_clodScreen;

bool hzbHidden(vec3 center, float radius)
{
	vec3 v = mul(u_clodView, vec4(center, 1.0)).xyz;
	float nearest = v.z - radius;
	if (nearest <= u_clodScreen.z)
	{
		return false;
	}
	vec2 lo = vec2_splat(1.0e9);
	vec2 hi = vec2_splat(-1.0e9);
	for (int k = 0; k < 8; k++)
	{
		vec3 corner = v + vec3(((k & 1) == 0) ? -radius : radius, ((k & 2) == 0) ? -radius : radius, ((k & 4) == 0) ? -radius : radius);
		vec4 c = mul(u_clodProj, vec4(corner, 1.0));
		vec2 ndc = c.xy / c.w;
		lo = min(lo, ndc);
		hi = max(hi, ndc);
	}
	float x0 = (lo.x * 0.5 + 0.5) * u_clodScreen.x;
	float x1 = (hi.x * 0.5 + 0.5) * u_clodScreen.x;
	float y0 = (u_clodHzb.w > 0.5 ? 0.5 - hi.y * 0.5 : 0.5 + lo.y * 0.5) * u_clodScreen.y;
	float y1 = (u_clodHzb.w > 0.5 ? 0.5 - lo.y * 0.5 : 0.5 + hi.y * 0.5) * u_clodScreen.y;
	if (x1 < 0.0 || y1 < 0.0 || x0 > u_clodScreen.x || y0 > u_clodScreen.y)
	{
		return false;
	}
	x0 = max(x0, 0.0);
	y0 = max(y0, 0.0);
	x1 = min(x1, u_clodScreen.x - 1.0);
	y1 = min(y1, u_clodScreen.y - 1.0);
	float extent = max(x1 - x0, y1 - y0);
	float top = u_clodHzb.z - 1.0;
	float level = clamp(ceil(log2(max(extent, 1.0e-3) + 1.0e-3)) - 1.0, 0.0, top);
	uint l = uint(level);
	uint offset = 0u;
	for (uint k = 0u; k < l; k++)
	{
		offset += max(uint(u_clodHzb.x) >> k, 1u) * max(uint(u_clodHzb.y) >> k, 1u);
	}
	uint w = max(uint(u_clodHzb.x) >> l, 1u);
	uint h = max(uint(u_clodHzb.y) >> l, 1u);
	float texel = 1.0 / exp2(level + 1.0);
	uint ix0 = min(uint(x0 * texel), w - 1u);
	uint ix1 = min(uint(x1 * texel), w - 1u);
	uint iy0 = min(uint(y0 * texel), h - 1u);
	uint iy1 = min(uint(y1 * texel), h - 1u);
	float farthest = 0.0;
	for (uint y = iy0; y <= iy1; y++)
	{
		for (uint x = ix0; x <= ix1; x++)
		{
			farthest = max(farthest, b_hzb[offset + y * w + x]);
		}
	}
	return nearest > farthest + max(0.02, farthest * 0.001);
}
