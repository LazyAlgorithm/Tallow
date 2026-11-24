$input v_texcoord0, v_wpos

// Fast approximate antialiasing (FXAA), on the tonemapped picture. Written for Tallow after the published method
// (Timothy Lottes, "FXAA"): find edges from the picture's brightness, work out which way each edge runs, walk along
// it to find where it ends, and move the pixel's sample across the edge by how far along it sits, so a jagged
// step becomes a smooth ramp. Also softens lone bright pixels (sub-pixel aliasing).
#include <bgfx_shader.sh>

SAMPLER2D(s_color, 0);

uniform vec4 u_aaParams; // xy: one texel, zw: the picture's size in texels

// Edges weaker than this, or than this fraction of the brightest neighbour, are left alone.
#define EDGE_MIN 0.0312
#define EDGE_RELATIVE 0.125
// How much lone bright or dark pixels are smoothed (0 none, 1 everything).
#define SUBPIXEL 0.75
#define SEARCH_STEPS 12

float lumaOf(vec3 c)
{
	return dot(c, vec3(0.299, 0.587, 0.114));
}

float lumaAt(vec2 uv)
{
	return lumaOf(texture2DLod(s_color, uv, 0.0).rgb);
}

// How far the search moves each step, in texels: it speeds up the further it goes.
float searchStep(int i)
{
	if (i < 5)
		return 1.0;
	if (i == 5)
		return 1.5;
	if (i < 10)
		return 2.0;
	if (i == 10)
		return 4.0;
	return 8.0;
}

void main()
{
	vec2 uv = v_texcoord0;
	vec2 texel = u_aaParams.xy;
	vec3 rgbM = texture2DLod(s_color, uv, 0.0).rgb;
	float lumaM = lumaOf(rgbM);
	float lumaN = lumaAt(uv + vec2(0.0, -texel.y));
	float lumaS = lumaAt(uv + vec2(0.0, texel.y));
	float lumaW = lumaAt(uv + vec2(-texel.x, 0.0));
	float lumaE = lumaAt(uv + vec2(texel.x, 0.0));

	float lumaMax = max(max(lumaN, lumaS), max(max(lumaW, lumaE), lumaM));
	float lumaMin = min(min(lumaN, lumaS), min(min(lumaW, lumaE), lumaM));
	float range = lumaMax - lumaMin;
	if (range < max(EDGE_MIN, lumaMax * EDGE_RELATIVE))
	{
		gl_FragColor = vec4(rgbM, 1.0);
		return;
	}

	float lumaNW = lumaAt(uv + vec2(-texel.x, -texel.y));
	float lumaNE = lumaAt(uv + vec2(texel.x, -texel.y));
	float lumaSW = lumaAt(uv + vec2(-texel.x, texel.y));
	float lumaSE = lumaAt(uv + vec2(texel.x, texel.y));

	// A lone pixel brighter or darker than its surroundings: how far it stands out from their weighted average.
	float lumaAverage = ((lumaN + lumaS + lumaW + lumaE) * 2.0 + (lumaNW + lumaNE + lumaSW + lumaSE)) * (1.0 / 12.0);
	float lone = clamp(abs(lumaAverage - lumaM) / range, 0.0, 1.0);
	lone = lone * lone * (3.0 - 2.0 * lone);
	float subpixelOffset = lone * lone * SUBPIXEL;

	// Which way the edge runs: compare how much the brightness bends across rows and down columns.
	float bendAcross = abs(lumaNW + lumaSW - 2.0 * lumaW) + 2.0 * abs(lumaN + lumaS - 2.0 * lumaM) + abs(lumaNE + lumaSE - 2.0 * lumaE);
	float bendDown = abs(lumaNW + lumaNE - 2.0 * lumaN) + 2.0 * abs(lumaW + lumaE - 2.0 * lumaM) + abs(lumaSW + lumaSE - 2.0 * lumaS);
	bool horizontal = bendAcross >= bendDown;

	// The two neighbours across the edge: step towards the one with the steeper change.
	float lumaBefore = horizontal ? lumaN : lumaW;
	float lumaAfter = horizontal ? lumaS : lumaE;
	float gradientBefore = lumaBefore - lumaM;
	float gradientAfter = lumaAfter - lumaM;
	bool beforeSteeper = abs(gradientBefore) >= abs(gradientAfter);
	float gradientLimit = 0.25 * max(abs(gradientBefore), abs(gradientAfter));
	float stepLength = horizontal ? texel.y : texel.x;
	float lumaEdge;
	if (beforeSteeper)
	{
		stepLength = -stepLength;
		lumaEdge = 0.5 * (lumaBefore + lumaM);
	}
	else
		lumaEdge = 0.5 * (lumaAfter + lumaM);

	// The edge's line runs half a texel over; walk both ways along it until the brightness leaves the edge's.
	vec2 edgeUv = uv;
	if (horizontal)
		edgeUv.y += stepLength * 0.5;
	else
		edgeUv.x += stepLength * 0.5;
	vec2 along = horizontal ? vec2(texel.x, 0.0) : vec2(0.0, texel.y);
	vec2 uvA = edgeUv - along;
	vec2 uvB = edgeUv + along;
	float endA = lumaAt(uvA) - lumaEdge;
	float endB = lumaAt(uvB) - lumaEdge;
	bool doneA = abs(endA) >= gradientLimit;
	bool doneB = abs(endB) >= gradientLimit;
	for (int i = 1; i < SEARCH_STEPS; i++)
	{
		if (doneA && doneB)
			break;
		float s = searchStep(i);
		if (!doneA)
		{
			uvA -= along * s;
			endA = lumaAt(uvA) - lumaEdge;
			doneA = abs(endA) >= gradientLimit;
		}
		if (!doneB)
		{
			uvB += along * s;
			endB = lumaAt(uvB) - lumaEdge;
			doneB = abs(endB) >= gradientLimit;
		}
	}

	float distanceA = horizontal ? uv.x - uvA.x : uv.y - uvA.y;
	float distanceB = horizontal ? uvB.x - uv.x : uvB.y - uv.y;
	bool nearerA = distanceA < distanceB;
	float endLuma = nearerA ? endA : endB;
	float nearest = min(distanceA, distanceB);
	float span = distanceA + distanceB;
	// Only the half of the edge whose far end bends the right way is moved.
	bool rightWay = (endLuma < 0.0) != (lumaM - lumaEdge < 0.0);
	float edgeOffset = rightWay ? 0.5 - nearest / span : 0.0;
	float offset = max(edgeOffset, subpixelOffset);

	vec2 finalUv = uv;
	if (horizontal)
		finalUv.y += offset * stepLength;
	else
		finalUv.x += offset * stepLength;
	gl_FragColor = vec4(texture2DLod(s_color, finalUv, 0.0).rgb, 1.0);
}
