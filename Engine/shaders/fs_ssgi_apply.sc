$input v_texcoord0, v_wpos

// Screen-space global illumination, second step (at full size): blurs the half-size light without letting it cross from
// one surface to another, and adds it to the picture, coloured by the surface's own base colour (the depth pass's second
// target). Also writes the picture to a second target: the next frame's rays read it for the light they meet.
#include <bgfx_shader.sh>
#include "post.sh"

SAMPLER2D(s_color, 0);
SAMPLER2D(s_depth, 1);
SAMPLER2D(s_albedoBuffer, 2);
SAMPLER2D(s_ssgi, 3);

uniform vec4 u_ssgiParams;  // w: strength
uniform vec4 u_ssgiParams2; // xy one texel of the picture, zw one texel of the light

#define MAX_LIT 64.0

void main()
{
	vec2 uv = v_texcoord0;
	vec3 color = texture2DLod(s_color, uv, 0.0).rgb;
	float d = texture2DLod(s_depth, uv, 0.0).x;
	if (isViewmodel(d) || isSky(d))
	{
		gl_FragData[0] = vec4(color, 1.0);
		gl_FragData[1] = vec4(min(color, vec3_splat(MAX_LIT)), 1.0);
		return;
	}
	vec2 halfSize = 1.0 / u_ssgiParams2.zw;
	vec2 hp = uv * halfSize - 0.5;
	vec2 base = floor(hp);
	// Taps count by how near they are to this surface's plane (so a slope is not cut off, an edge is).
	vec3 p = viewPosition(uv, d);
	vec2 tx = vec2(u_ssgiParams2.x, 0.0);
	vec2 ty = vec2(0.0, u_ssgiParams2.y);
	vec3 pr = viewPosition(uv + tx, texture2DLod(s_depth, uv + tx, 0.0).x);
	vec3 pl = viewPosition(uv - tx, texture2DLod(s_depth, uv - tx, 0.0).x);
	vec3 pu = viewPosition(uv + ty, texture2DLod(s_depth, uv + ty, 0.0).x);
	vec3 pd = viewPosition(uv - ty, texture2DLod(s_depth, uv - ty, 0.0).x);
	vec3 dx = abs(pr.z - p.z) < abs(p.z - pl.z) ? pr - p : p - pl;
	vec3 dy = abs(pu.z - p.z) < abs(p.z - pd.z) ? pu - p : p - pd;
	vec3 n = normalize(cross(dx, dy));
	float tolerance = 0.03 + d * 0.025;
	vec3 sum = vec3_splat(0.0);
	float weights = 0.0;
	vec3 nearest = vec3_splat(0.0);
	float nearestDistance = 1.0e9;
	for (int y = -1; y <= 2; y++)
	{
		for (int x = -1; x <= 2; x++)
		{
			vec2 cell = base + vec2(float(x), float(y));
			vec4 tap = texture2DLod(s_ssgi, (cell + 0.5) * u_ssgiParams2.zw, 0.0);
			vec2 delta = cell - hp;
			float dist2 = dot(delta, delta);
			float plane = abs(dot(n, viewPosition((cell + 0.5) * u_ssgiParams2.zw, tap.a) - p));
			float w = exp(-dist2 * 0.7) * max(1.0 - plane / tolerance, 0.0);
			sum += tap.rgb * w;
			weights += w;
			float away = plane * 4.0 + dist2;
			if (away < nearestDistance)
			{
				nearestDistance = away;
				nearest = tap.rgb;
			}
		}
	}
	vec3 gi = weights > 0.02 ? sum / weights : nearest;
	// The base colour is kept as it is shown: to linear, as the lit pass does.
	vec3 albedo = pow(texture2DLod(s_albedoBuffer, uv, 0.0).rgb, vec3_splat(2.2));
	float strength = u_ssgiParams.w;
	gl_FragData[0] = vec4(color + gi * albedo * strength, 1.0);
	// What the rays see next frame: the bounce counts once at most, so it cannot build on itself without end.
	gl_FragData[1] = vec4(min(color + gi * albedo * min(strength, 1.0), vec3_splat(MAX_LIT)), 1.0);
}
