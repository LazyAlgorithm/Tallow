$input v_texcoord0, v_wpos

// Ambient occlusion, first step (at half size): how much of the open air around each point is taken up by nearby
// surfaces, from the depth pass. Twelve samples in the half-ball above the surface, turned by a per-pixel pattern
// that the next step blurs away.
#include <bgfx_shader.sh>
#include "post.sh"

SAMPLER2D(s_depth, 0);

uniform vec4 u_aoParams; // x radius (metres), y intensity, zw one depth texel

float depthAt(vec2 uv)
{
	return texture2D(s_depth, uv).x;
}

// The centre of the depth texel a point falls in: positions are rebuilt from the texel actually read, or a flat
// floor seen at a low angle looks like a staircase whose steps darken in bands.
vec2 texelCentre(vec2 uv)
{
	return (floor(uv / u_aoParams.zw) + 0.5) * u_aoParams.zw;
}

void main()
{
	vec2 uv = texelCentre(v_texcoord0);
	float d = depthAt(uv);
	if (isViewmodel(d) || isSky(d))
	{
		gl_FragColor = vec4_splat(1.0);
		return;
	}
	vec3 p = viewPosition(uv, d);

	// The surface's facing, from its neighbours: on each axis the nearer one, so edges do not bend it.
	vec2 tx = vec2(u_aoParams.z, 0.0);
	vec2 ty = vec2(0.0, u_aoParams.w);
	vec3 pr = viewPosition(uv + tx, depthAt(uv + tx));
	vec3 pl = viewPosition(uv - tx, depthAt(uv - tx));
	vec3 pu = viewPosition(uv + ty, depthAt(uv + ty));
	vec3 pd = viewPosition(uv - ty, depthAt(uv - ty));
	vec3 dx = abs(pr.z - p.z) < abs(p.z - pl.z) ? pr - p : p - pl;
	vec3 dy = abs(pu.z - p.z) < abs(p.z - pd.z) ? pu - p : p - pd;
	vec3 n = normalize(cross(dx, dy));
	if (dot(n, p) > 0.0)
		n = -n;
	vec3 tangent = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 bitangent = cross(n, tangent);

	float radius = u_aoParams.x;
	float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
	float occlusion = 0.0;
	for (int i = 0; i < 12; i++)
	{
		float t = (float(i) + 0.5) / 12.0;
		float angle = float(i) * 2.3999632 + noise * 6.2831853;
		float rise = fract(t * 5.0 + noise * 0.61803);
		vec3 dir = (tangent * cos(angle) + bitangent * sin(angle)) * sqrt(1.0 - rise * rise) + n * rise;
		vec3 s = p + dir * (radius * mix(0.15, 1.0, t * t));
		vec2 suv = texelCentre(viewToUv(s));
		float sd = depthAt(suv);
		if (isViewmodel(sd) || isSky(sd))
			continue;
		// The surface actually there, and how far it rises above this point's plane: a flat floor is its own plane
		// and hides nothing, however steeply it is seen. Nearby surfaces count most; ones beyond the radius not at all.
		vec3 v = viewPosition(suv, sd) - p;
		float vv = dot(v, v);
		float rise2 = dot(v, n) * inversesqrt(max(vv, 0.000001));
		float near = clamp(1.0 - vv / (radius * radius), 0.0, 1.0);
		occlusion += max(rise2 - 0.15, 0.0) * near;
	}
	float ao = clamp(1.0 - occlusion / 12.0 * 2.0 * u_aoParams.y, 0.0, 1.0);
	gl_FragColor = vec4(ao, ao, ao, 1.0);
}
