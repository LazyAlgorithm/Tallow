$input v_texcoord0, v_wpos

// Screen-space diffuse bounce from a few cosine-weighted rays per surface point. Hits read this frame's scene color
// and add the reprojected indirect light at the hit for secondary bounces. The receiver also blends with its history.
// Alpha holds the receiver's depth for reprojection and the depth-aware filter in fs_ssgi_apply.sc.
#include <bgfx_shader.sh>
#include "post.sh"

SAMPLER2D(s_depth, 0);
SAMPLER2D(s_color, 1);
SAMPLER2D(s_albedoBuffer, 2);
SAMPLER2D(s_ssgiHistory, 3);

uniform mat4 u_prevViewProj;
uniform vec4 u_ssgiParams;  // x frame number, y ray reach in metres, z bounce strength (-1 without history), w rays per pixel
uniform vec4 u_ssgiParams2; // xy one depth texel, zw one texel of this pass's target

#define MAX_RAYS 6
#define STEPS 12
#define MAX_RADIANCE 12.0

float depthAt(vec2 uv)
{
	return texture2DLod(s_depth, uv, 0.0).x;
}

float interleavedNoise(vec2 p)
{
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// The centre of the depth texel a point falls in: positions are rebuilt from the texel actually read, or a flat floor
// seen at a low angle becomes a staircase whose steps catch the rays in bands.
vec2 texelCentre(vec2 uv)
{
	return (floor(uv / u_ssgiParams2.xy) + 0.5) * u_ssgiParams2.xy;
}

// The facing of the surface at uv (towards the camera), from the nearer neighbour on each axis so edges do not bend it.
vec3 surfaceNormal(vec2 uv, vec3 p)
{
	vec2 tx = vec2(u_ssgiParams2.x, 0.0);
	vec2 ty = vec2(0.0, u_ssgiParams2.y);
	vec3 pr = viewPosition(uv + tx, depthAt(uv + tx));
	vec3 pl = viewPosition(uv - tx, depthAt(uv - tx));
	vec3 pu = viewPosition(uv + ty, depthAt(uv + ty));
	vec3 pd = viewPosition(uv - ty, depthAt(uv - ty));
	vec3 dx = abs(pr.z - p.z) < abs(p.z - pl.z) ? pr - p : p - pl;
	vec3 dy = abs(pu.z - p.z) < abs(p.z - pd.z) ? pu - p : p - pd;
	vec3 n = normalize(cross(dx, dy));
	return dot(n, p) > 0.0 ? -n : n;
}

bool sampleHistory(vec2 uv, float depth, out vec4 history, out vec2 previousUv)
{
	history = vec4_splat(0.0);
	previousUv = uv;
	if (u_ssgiParams.z < 0.0)
		return false;

	vec4 clip = mul(u_prevViewProj, vec4(worldPosition(uv, depth), 1.0));
	if (clip.w <= 0.0001)
		return false;
	previousUv = ndcToUv(clip.xy / clip.w);
	if (previousUv.x <= 0.0 || previousUv.x >= 1.0 || previousUv.y <= 0.0 || previousUv.y >= 1.0)
		return false;

	history = texture2DLod(s_ssgiHistory, previousUv, 0.0);
	float previousDepth = u_postForward.w > 0.5 ? depth : clip.w;
	return !isSky(history.a) && !isViewmodel(history.a)
		&& abs(history.a - previousDepth) < 0.04 * previousDepth + 0.08;
}

void main()
{
	vec2 uv = texelCentre(v_texcoord0);
	float d = depthAt(uv);
	if (isViewmodel(d) || isSky(d))
	{
		gl_FragColor = vec4(0.0, 0.0, 0.0, d);
		return;
	}
	vec3 p = viewPosition(uv, d);
	vec3 n = surfaceNormal(uv, p);
	vec3 tangent = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 bitangent = cross(n, tangent);

	float frame = u_ssgiParams.x;
	float reach = u_ssgiParams.y;
	float noiseA = fract(interleavedNoise(gl_FragCoord.xy) + frame * 0.61803399);
	float noiseB = fract(interleavedNoise(gl_FragCoord.yx + vec2(37.0, 17.0)) + frame * 0.75487767);
	float noiseC = fract(interleavedNoise(gl_FragCoord.xy + vec2(71.0, 5.0)) + frame * 0.56984029);
	float bias = 0.01 + 0.006 * d;
	vec3 light = vec3_splat(0.0);
	float rays = u_ssgiParams.w;
	for (int i = 0; i < MAX_RAYS; i++)
	{
		if (float(i) > rays - 0.5)
			break;
		float r1 = fract(noiseA + float(i) * 0.38196601);
		float r2 = (float(i) + noiseB) / rays;
		float phi = 6.2831853 * r1;
		float sinTheta = sqrt(r2);
		vec3 dir = (tangent * cos(phi) + bitangent * sin(phi)) * sinTheta + n * sqrt(1.0 - r2);
		for (int k = 0; k < STEPS; k++)
		{
			float f = (float(k) + noiseC) / float(STEPS);
			float t = 0.04 + reach * f * f;
			vec3 s = p + dir * t;
			if (s.z < 0.05)
				break;
			vec2 suv = viewToUv(s);
			if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0)
				break;
			suv = texelCentre(suv);
			float sd = depthAt(suv);
			if (isViewmodel(sd))
				continue;
			float diff = s.z - sd;
			// Behind the surface, but not far behind: a ray goes behind thin things, not through them.
			if (diff > bias && diff < 0.15 + 0.25 * t)
			{
				vec3 hp = viewPosition(suv, sd);
				// A hit on this point's own plane (a flat floor catching its own ray) is not light from elsewhere.
				vec3 toHit = hp - p;
				if (dot(toHit, n) < 0.08 * length(toHit))
					continue;
				vec2 tx = vec2(u_ssgiParams2.x, 0.0);
				vec2 ty = vec2(0.0, u_ssgiParams2.y);
				vec3 hn = normalize(cross(viewPosition(suv + tx, depthAt(suv + tx)) - hp, viewPosition(suv + ty, depthAt(suv + ty)) - hp));
				if (dot(hn, hp) > 0.0)
					hn = -hn;
				// A surface seen from behind sends nothing this way.
				float facing = clamp(dot(hn, -dir) * 2.0, 0.0, 1.0);
				float fade = 1.0 - smoothstep(0.6 * reach, reach, t);
				vec3 radiance = texture2DLod(s_color, suv, 0.0).rgb;
				vec4 hitHistory;
				vec2 previousHitUv;
				if (sampleHistory(suv, sd, hitHistory, previousHitUv))
				{
					vec3 albedo = pow(texture2DLod(s_albedoBuffer, suv, 0.0).rgb, vec3_splat(2.2));
					radiance += hitHistory.rgb * albedo * u_ssgiParams.z;
				}
				float peak = max(radiance.r, max(radiance.g, radiance.b));
				radiance *= min(1.0, MAX_RADIANCE / max(peak, 0.0001));
				light += radiance * (facing * fade);
				break;
			}
		}
	}
	light /= rays;

	// Last frame's result, where this surface was on the screen then and was still the one in view.
	vec4 history;
	vec2 previousUv;
	if (sampleHistory(uv, d, history, previousUv))
	{
		// Give current light more weight with a steady camera, and retain enough valid history to stabilize motion.
		float moved = length((previousUv - uv) / u_ssgiParams2.xy);
		float weight = mix(0.86, 0.58, clamp(moved / 6.0, 0.0, 1.0));
		light = mix(light, history.rgb, weight);
	}
	gl_FragColor = vec4(light, d);
}
