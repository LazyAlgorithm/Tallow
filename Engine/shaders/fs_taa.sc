$input v_texcoord0, v_wpos

// Temporal antialiasing (tallowengine.com/docs/temporal): the finished (tonemapped) picture, drawn with a sub-pixel
// jitter that changes every frame, blended with the previous result moved along the motion vectors.
//
//  - The motion vector comes from the nearest surface in the 3x3 around the pixel (the depth pass's distances), so an
//    object's edge keeps its own motion rather than the background's.
//  - The history is read with a Catmull-Rom filter (five bilinear taps), which stays sharper than bilinear.
//  - The history is clipped to the colour range of the pixel's 3x3 neighbourhood (mean and spread in YCoCg), so what
//    is no longer there (a moved object's trail, a lighting change) cannot linger; the more it had to be clipped, and
//    the faster the pixel moves, the less history is kept.
//  - The blend is weighted by brightness (1 / (1 + luma)), so a bright flicker does not dominate.
#include <bgfx_shader.sh>

SAMPLER2D(s_color, 0);
SAMPLER2D(s_history, 1);
SAMPLER2D(s_velocity, 2);
SAMPLER2D(s_depth, 3);

uniform vec4 u_taaParams;     // xy: one texel, z: 1 when there is a history to use (0 on the first frame and after a cut), w: how much history is kept at most
uniform vec4 u_taaParams2;    // x: +1 when texture v grows up the screen, -1 when down (velocity y is down), y: the size of the neighbourhood's colour range (gamma)

vec3 toYCoCg(vec3 c)
{
	return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 fromYCoCg(vec3 c)
{
	return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

vec3 fetchColor(vec2 uv)
{
	return texture2DLod(s_color, uv, 0.0).rgb;
}

vec3 fetchHistory(vec2 uv)
{
	return texture2DLod(s_history, uv, 0.0).rgb;
}

// Catmull-Rom filtering with five bilinear taps (the corners of the 4x4 are left out).
vec3 historyCatmullRom(vec2 uv)
{
	vec2 size = 1.0 / u_taaParams.xy;
	vec2 position = uv * size;
	vec2 center = floor(position - 0.5) + 0.5;
	vec2 f = position - center;
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);
	vec2 w12 = w1 + w2;
	vec2 t12 = (center + w2 / w12) * u_taaParams.xy;
	vec2 t0 = (center - 1.0) * u_taaParams.xy;
	vec2 t3 = (center + 2.0) * u_taaParams.xy;
	vec3 result = fetchHistory(vec2(t0.x, t12.y)) * (w0.x * w12.y)
		+ fetchHistory(vec2(t12.x, t0.y)) * (w12.x * w0.y)
		+ fetchHistory(vec2(t12.x, t12.y)) * (w12.x * w12.y)
		+ fetchHistory(vec2(t3.x, t12.y)) * (w3.x * w12.y)
		+ fetchHistory(vec2(t12.x, t3.y)) * (w12.x * w3.y);
	float total = w0.x * w12.y + w12.x * w0.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
	return max(result / total, vec3_splat(0.0));
}

void main()
{
	vec2 uv = v_texcoord0;
	vec2 texel = u_taaParams.xy;
	vec3 current = fetchColor(uv);

	// The 3x3: the colour range, and the nearest surface's motion.
	vec3 m1 = vec3_splat(0.0);
	vec3 m2 = vec3_splat(0.0);
	vec3 lo = vec3_splat(1.0e9);
	vec3 hi = vec3_splat(-1.0e9);
	float nearest = 1.0e9;
	vec2 nearestOffset = vec2(0.0, 0.0);
	for (int y = -1; y <= 1; y++)
	{
		for (int x = -1; x <= 1; x++)
		{
			vec2 offset = vec2(float(x), float(y));
			vec3 c = toYCoCg(fetchColor(uv + offset * texel));
			m1 += c;
			m2 += c * c;
			lo = min(lo, c);
			hi = max(hi, c);
			float d = texture2DLod(s_depth, uv + offset * texel, 0.0).x;
			if (d < nearest)
			{
				nearest = d;
				nearestOffset = offset;
			}
		}
	}
	vec3 mean = m1 / 9.0;
	vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3_splat(0.0)));

	vec4 motion = texture2DLod(s_velocity, uv + nearestOffset * texel, 0.0);
	vec2 velocity = motion.xy;
	// Motion that is not known (cloth, skinned and other deforming meshes): trust this frame more.
	float unknown = motion.z;
	vec2 previousUv = uv + vec2(velocity.x * texel.x, -velocity.y * texel.y * u_taaParams2.x);

	// No history: the first frame, a cut, or where the point was off the screen last frame.
	bool onScreen = all(greaterThanEqual(previousUv, vec2_splat(0.0))) && all(lessThanEqual(previousUv, vec2_splat(1.0)));
	if (u_taaParams.z < 0.5 || !onScreen)
	{
		gl_FragColor = vec4(current, 1.0);
		return;
	}

	vec3 history = toYCoCg(historyCatmullRom(previousUv));

	// The range history may have: the spread of the neighbourhood, inside its extremes.
	float gamma = mix(u_taaParams2.y, 0.75, unknown);
	vec3 boxMin = max(mean - gamma * sigma, lo);
	vec3 boxMax = min(mean + gamma * sigma, hi);
	vec3 center = 0.5 * (boxMin + boxMax);
	vec3 extent = 0.5 * (boxMax - boxMin) + 1.0e-4;
	// Clip towards the centre (rather than clamping each channel, which shifts the hue).
	vec3 toHistory = history - center;
	vec3 unit = abs(toHistory / extent);
	float outside = max(unit.x, max(unit.y, unit.z));
	vec3 clipped = outside > 1.0 ? center + toHistory / outside : history;
	// How much of the history was cut away: a lot means it is not this surface any more.
	float clippedAmount = clamp((outside - 1.0) * 0.5, 0.0, 1.0);

	// Less history for what moves fast (its history is a filtered guess) and for what was clipped.
	float speed = length(velocity);
	float keep = u_taaParams.w * (1.0 - clamp(speed * 0.04, 0.0, 0.5)) * (1.0 - 0.5 * clippedAmount) * (1.0 - 0.5 * unknown);
	// Weighted by brightness against flicker.
	float wCurrent = (1.0 - keep) / (1.0 + toYCoCg(current).x);
	float wHistory = keep / (1.0 + clipped.x);
	vec3 result = (current * wCurrent + fromYCoCg(clipped) * wHistory) / (wCurrent + wHistory);
	gl_FragColor = vec4(max(result, vec3_splat(0.0)), 1.0);
}
