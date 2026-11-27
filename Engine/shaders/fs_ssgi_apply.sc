$input v_texcoord0, v_wpos

// Filter and, when necessary, upsample the gathered light using the receiver's surface plane.
// Add the result to the picture, coloured by the receiver's base colour from the depth pass.
#include <bgfx_shader.sh>
#include "post.sh"

SAMPLER2D(s_color, 0);
SAMPLER2D(s_depth, 1);
SAMPLER2D(s_albedoBuffer, 2);
SAMPLER2D(s_ssgi, 3);

uniform vec4 u_ssgiParams;  // w: strength
uniform vec4 u_ssgiParams2; // xy one texel of the picture, zw one texel of the light

void main()
{
	vec2 uv = v_texcoord0;
	vec3 color = texture2DLod(s_color, uv, 0.0).rgb;
	float d = texture2DLod(s_depth, uv, 0.0).x;
	if (isViewmodel(d) || isSky(d))
	{
		gl_FragColor = vec4(color, 1.0);
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
			vec2 tapUv = (cell + 0.5) * u_ssgiParams2.zw;
			if (tapUv.x <= 0.0 || tapUv.x >= 1.0 || tapUv.y <= 0.0 || tapUv.y >= 1.0)
				continue;
			vec4 tap = texture2DLod(s_ssgi, tapUv, 0.0);
			if (isSky(tap.a) || isViewmodel(tap.a))
				continue;
			// The gather stored depth from the full-resolution texel containing this tap.
			vec2 depthUv = (floor(tapUv / u_ssgiParams2.xy) + 0.5) * u_ssgiParams2.xy;
			vec2 delta = cell - hp;
			float dist2 = dot(delta, delta);
			float plane = abs(dot(n, viewPosition(depthUv, tap.a) - p));
			float w = exp(-dist2 * 0.5) * max(1.0 - plane / tolerance, 0.0);
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
	gl_FragColor = vec4(color + gi * albedo * strength, 1.0);
}
