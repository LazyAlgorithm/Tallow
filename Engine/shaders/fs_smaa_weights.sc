$input v_texcoord0, v_wpos

// SMAA 2 of 3: blending weight calculation. For each edge found, searches along it for its ends (and for diagonal
// lines), reads from the area texture how much of the pixel the line covers, and writes the weights (right, top,
// left, bottom neighbours) for the next step. See smaa.sh for the licence.
#include <bgfx_shader.sh>
#include "smaa.sh"

SAMPLER2D(s_edges, 0);
SAMPLER2D(s_area, 1);
SAMPLER2D(s_search, 2);

// ---- diagonal search

vec2 decodeDiagBilinear2(vec2 e)
{
	e.r = e.r * abs(5.0 * e.r - 5.0 * 0.75);
	return round(e);
}

vec4 decodeDiagBilinear4(vec4 e)
{
	e.rb = e.rb * abs(5.0 * e.rb - 5.0 * 0.75);
	return round(e);
}

vec2 searchDiag1(vec2 texcoord, vec2 dir, out vec2 e)
{
	vec4 coord = vec4(texcoord, -1.0, 1.0);
	vec3 t = vec3(u_aaParams.xy, 1.0);
	e = vec2(0.0, 0.0);
	for (int i = 0; i < SMAA_MAX_SEARCH_STEPS_DIAG - 1; i++)
	{
		if (coord.w <= 0.9)
			break;
		coord.xyz = t * vec3(dir, 1.0) + coord.xyz;
		e = smaaLod(s_edges, coord.xy).rg;
		coord.w = dot(e, vec2(0.5, 0.5));
	}
	return coord.zw;
}

vec2 searchDiag2(vec2 texcoord, vec2 dir, out vec2 e)
{
	vec4 coord = vec4(texcoord, -1.0, 1.0);
	coord.x += 0.25 * u_aaParams.x;
	vec3 t = vec3(u_aaParams.xy, 1.0);
	e = vec2(0.0, 0.0);
	for (int i = 0; i < SMAA_MAX_SEARCH_STEPS_DIAG - 1; i++)
	{
		if (coord.w <= 0.9)
			break;
		coord.xyz = t * vec3(dir, 1.0) + coord.xyz;
		// Both edges at once, with bilinear filtering.
		e = smaaLod(s_edges, coord.xy).rg;
		e = decodeDiagBilinear2(e);
		coord.w = dot(e, vec2(0.5, 0.5));
	}
	return coord.zw;
}

vec2 areaDiag(vec2 dist, vec2 e, float offset)
{
	vec2 texcoord = SMAA_AREATEX_MAX_DISTANCE_DIAG * e + dist;
	texcoord = SMAA_AREATEX_PIXEL_SIZE * texcoord + 0.5 * SMAA_AREATEX_PIXEL_SIZE;
	// Diagonal areas are on the second half of the texture.
	texcoord.x += 0.5;
	texcoord.y += SMAA_AREATEX_SUBTEX_SIZE * offset;
	return smaaLod(s_area, texcoord).rg;
}

vec2 calculateDiagWeights(vec2 texcoord, vec2 e)
{
	vec2 weights = vec2(0.0, 0.0);
	vec4 d;
	vec2 end;
	if (e.r > 0.0)
	{
		d.xz = searchDiag1(texcoord, vec2(-1.0, 1.0), end);
		d.x += float(end.y > 0.9);
	}
	else
		d.xz = vec2(0.0, 0.0);
	d.yw = searchDiag1(texcoord, vec2(1.0, -1.0), end);

	if (d.x + d.y > 2.0)
	{
		vec4 coords = vec4(-d.x + 0.25, d.x, d.y, -d.y - 0.25) * u_aaParams.xyxy + texcoord.xyxy;
		vec4 c;
		c.xy = smaaLodOffset(s_edges, coords.xy, vec2(-1.0, 0.0)).rg;
		c.zw = smaaLodOffset(s_edges, coords.zw, vec2(1.0, 0.0)).rg;
		c.yxwz = decodeDiagBilinear4(c.xyzw);
		vec2 cc = 2.0 * c.xz + c.yw;
		// Remove the crossing edge if the end of the line was not found.
		if (d.z > 0.9)
			cc.x = 0.0;
		if (d.w > 0.9)
			cc.y = 0.0;
		weights += areaDiag(d.xy, cc, 0.0);
	}

	d.xz = searchDiag2(texcoord, vec2(-1.0, -1.0), end);
	if (smaaLodOffset(s_edges, texcoord, vec2(1.0, 0.0)).r > 0.0)
	{
		d.yw = searchDiag2(texcoord, vec2(1.0, 1.0), end);
		d.y += float(end.y > 0.9);
	}
	else
		d.yw = vec2(0.0, 0.0);

	if (d.x + d.y > 2.0)
	{
		vec4 coords = vec4(-d.x, -d.x, d.y, d.y) * u_aaParams.xyxy + texcoord.xyxy;
		vec4 c;
		c.x = smaaLodOffset(s_edges, coords.xy, vec2(-1.0, 0.0)).g;
		c.y = smaaLodOffset(s_edges, coords.xy, vec2(0.0, -1.0)).r;
		c.zw = smaaLodOffset(s_edges, coords.zw, vec2(1.0, 0.0)).gr;
		vec2 cc = 2.0 * c.xz + c.yw;
		if (d.z > 0.9)
			cc.x = 0.0;
		if (d.w > 0.9)
			cc.y = 0.0;
		weights += areaDiag(d.xy, cc, 0.0).gr;
	}
	return weights;
}

// ---- horizontal and vertical search

float searchLength(vec2 e, float offset)
{
	// The texture is flipped vertically, with left and right cases taking half of the space horizontally.
	vec2 scale = SMAA_SEARCHTEX_SIZE * vec2(0.5, -1.0);
	vec2 bias = SMAA_SEARCHTEX_SIZE * vec2(offset, 1.0);
	// Scale and bias to access texel centres.
	scale += vec2(-1.0, 1.0);
	bias += vec2(0.5, -0.5);
	// To texcoords (the texture is cropped).
	scale *= 1.0 / SMAA_SEARCHTEX_PACKED_SIZE;
	bias *= 1.0 / SMAA_SEARCHTEX_PACKED_SIZE;
	return smaaLod(s_search, scale * e + bias).r;
}

float searchXLeft(vec2 texcoord, float end)
{
	vec2 e = vec2(0.0, 1.0);
	for (int i = 0; i < SMAA_MAX_SEARCH_STEPS; i++)
	{
		if (!(texcoord.x > end && e.g > 0.8281 && e.r == 0.0))
			break;
		e = smaaLod(s_edges, texcoord).rg;
		texcoord = -vec2(2.0, 0.0) * u_aaParams.xy + texcoord;
	}
	float offset = -(255.0 / 127.0) * searchLength(e, 0.0) + 3.25;
	return u_aaParams.x * offset + texcoord.x;
}

float searchXRight(vec2 texcoord, float end)
{
	vec2 e = vec2(0.0, 1.0);
	for (int i = 0; i < SMAA_MAX_SEARCH_STEPS; i++)
	{
		if (!(texcoord.x < end && e.g > 0.8281 && e.r == 0.0))
			break;
		e = smaaLod(s_edges, texcoord).rg;
		texcoord = vec2(2.0, 0.0) * u_aaParams.xy + texcoord;
	}
	float offset = -(255.0 / 127.0) * searchLength(e, 0.5) + 3.25;
	return -u_aaParams.x * offset + texcoord.x;
}

float searchYUp(vec2 texcoord, float end)
{
	vec2 e = vec2(1.0, 0.0);
	for (int i = 0; i < SMAA_MAX_SEARCH_STEPS; i++)
	{
		if (!(texcoord.y > end && e.r > 0.8281 && e.g == 0.0))
			break;
		e = smaaLod(s_edges, texcoord).rg;
		texcoord = -vec2(0.0, 2.0) * u_aaParams.xy + texcoord;
	}
	float offset = -(255.0 / 127.0) * searchLength(e.gr, 0.0) + 3.25;
	return u_aaParams.y * offset + texcoord.y;
}

float searchYDown(vec2 texcoord, float end)
{
	vec2 e = vec2(1.0, 0.0);
	for (int i = 0; i < SMAA_MAX_SEARCH_STEPS; i++)
	{
		if (!(texcoord.y < end && e.r > 0.8281 && e.g == 0.0))
			break;
		e = smaaLod(s_edges, texcoord).rg;
		texcoord = vec2(0.0, 2.0) * u_aaParams.xy + texcoord;
	}
	float offset = -(255.0 / 127.0) * searchLength(e.gr, 0.5) + 3.25;
	return -u_aaParams.y * offset + texcoord.y;
}

// What the line covers at each side of this edge, from the distances to its ends and the crossing edges there.
vec2 area(vec2 dist, float e1, float e2, float offset)
{
	// Rounding prevents precision errors of bilinear filtering.
	vec2 texcoord = SMAA_AREATEX_MAX_DISTANCE * round(4.0 * vec2(e1, e2)) + dist;
	texcoord = SMAA_AREATEX_PIXEL_SIZE * texcoord + 0.5 * SMAA_AREATEX_PIXEL_SIZE;
	texcoord.y = SMAA_AREATEX_SUBTEX_SIZE * offset + texcoord.y;
	return smaaLod(s_area, texcoord).rg;
}

// ---- corners

vec2 horizontalCorner(vec2 weights, vec4 texcoord, vec2 d)
{
	vec2 leftRight = step(d.xy, d.yx);
	vec2 rounding = (1.0 - SMAA_CORNER_ROUNDING_NORM) * leftRight;
	rounding /= leftRight.x + leftRight.y;
	vec2 factor = vec2(1.0, 1.0);
	factor.x -= rounding.x * smaaLodOffset(s_edges, texcoord.xy, vec2(0.0, 1.0)).r;
	factor.x -= rounding.y * smaaLodOffset(s_edges, texcoord.zw, vec2(1.0, 1.0)).r;
	factor.y -= rounding.x * smaaLodOffset(s_edges, texcoord.xy, vec2(0.0, -2.0)).r;
	factor.y -= rounding.y * smaaLodOffset(s_edges, texcoord.zw, vec2(1.0, -2.0)).r;
	return weights * clamp(factor, 0.0, 1.0);
}

vec2 verticalCorner(vec2 weights, vec4 texcoord, vec2 d)
{
	vec2 leftRight = step(d.xy, d.yx);
	vec2 rounding = (1.0 - SMAA_CORNER_ROUNDING_NORM) * leftRight;
	rounding /= leftRight.x + leftRight.y;
	vec2 factor = vec2(1.0, 1.0);
	factor.x -= rounding.x * smaaLodOffset(s_edges, texcoord.xy, vec2(1.0, 0.0)).g;
	factor.x -= rounding.y * smaaLodOffset(s_edges, texcoord.zw, vec2(1.0, 1.0)).g;
	factor.y -= rounding.x * smaaLodOffset(s_edges, texcoord.xy, vec2(-2.0, 0.0)).g;
	factor.y -= rounding.y * smaaLodOffset(s_edges, texcoord.zw, vec2(-2.0, 1.0)).g;
	return weights * clamp(factor, 0.0, 1.0);
}

void main()
{
	vec2 texcoord = v_texcoord0;
	vec2 pixcoord = texcoord * u_aaParams.zw;
	vec4 m = u_aaParams.xyxy;
	// Offsets for the searches (see @PSEUDO_GATHER4 in the reference), and where they end.
	vec4 offset0 = m * vec4(-0.25, -0.125, 1.25, -0.125) + texcoord.xyxy;
	vec4 offset1 = m * vec4(-0.125, -0.25, -0.125, 1.25) + texcoord.xyxy;
	vec4 offset2 = u_aaParams.xxyy * (vec4(-2.0, 2.0, -2.0, 2.0) * float(SMAA_MAX_SEARCH_STEPS)) + vec4(offset0.xz, offset1.yw);

	vec4 weights = vec4(0.0, 0.0, 0.0, 0.0);
	vec2 e = smaaLod(s_edges, texcoord).rg;

	if (e.g > 0.0) // Edge at north.
	{
		// Diagonals have both north and west edges, so searching for them in one of the boundaries is enough.
		weights.rg = calculateDiagWeights(texcoord, e);
		// A diagonal found has priority: skip horizontal and vertical processing.
		if (weights.r == -weights.g)
		{
			vec2 d;
			vec3 coords;
			coords.x = searchXLeft(offset0.xy, offset2.x);
			coords.y = offset1.y;
			d.x = coords.x;
			float e1 = smaaLod(s_edges, coords.xy).r;
			coords.z = searchXRight(offset0.zw, offset2.y);
			d.y = coords.z;
			// Distances in pixels.
			d = abs(round(u_aaParams.zz * d - pixcoord.xx));
			// The areas texture is compressed quadratically.
			vec2 sqrt_d = sqrt(d);
			float e2 = smaaLodOffset(s_edges, coords.zy, vec2(1.0, 0.0)).r;
			weights.rg = area(sqrt_d, e1, e2, 0.0);
			// Fix corners.
			coords.y = texcoord.y;
			weights.rg = horizontalCorner(weights.rg, coords.xyzy, d);
		}
		else
			e.r = 0.0; // Skip vertical processing.
	}

	if (e.r > 0.0) // Edge at west.
	{
		vec2 d;
		vec3 coords;
		coords.y = searchYUp(offset1.xy, offset2.z);
		coords.x = offset0.x;
		d.x = coords.y;
		float e1 = smaaLod(s_edges, coords.xy).g;
		coords.z = searchYDown(offset1.zw, offset2.w);
		d.y = coords.z;
		d = abs(round(u_aaParams.ww * d - pixcoord.yy));
		vec2 sqrt_d = sqrt(d);
		float e2 = smaaLodOffset(s_edges, coords.xz, vec2(0.0, 1.0)).g;
		weights.ba = area(sqrt_d, e1, e2, 0.0);
		coords.x = texcoord.x;
		weights.ba = verticalCorner(weights.ba, coords.xyxz, d);
	}
	gl_FragColor = weights;
}
