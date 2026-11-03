$input v_wpos, v_normal, v_color0, v_texcoord0, v_depth, v_texcoord1, v_surface

// Screen Reflections (MeshRenderer.screenReflections, docs/reflections.md): a shiny surface drawn a second time over
// itself, after everything solid, and added to the picture. Where a ray mirrored off the surface meets something on
// the screen (found by stepping across the depth pass, s_depth), it gives the difference between that and the
// reflection probe's view in the same direction, which the first drawing (fs_mesh) put in. So objects in the room
// show in the surface where they stand, instead of flattened onto the probe's box; where the ray leaves the screen
// or meets nothing, the probe's reflection stays as it was.
#include <bgfx_shader.sh>
#include "lighting.sh"
#include "palette.sh"
#include "post.sh"

SAMPLER2D(s_albedo, 0);
SAMPLER2D(s_color, 2);
SAMPLER2D(s_depth, 3);
SAMPLER2D(s_normalMap, 4);
SAMPLER2D(s_metalRoughMap, 5);
SAMPLER2D(s_planar, 6);

uniform vec4 u_material;      // x metallic, y roughness, z flat shading, w 1 unlit, 2 the editor's preview light
uniform vec4 u_uvTransform;   // xy tiling, zw offset
uniform vec4 u_surface;       // x alpha cutoff (0: no cutout)
uniform vec4 u_pbr;           // x normal map strength (0: none), y 1 with a metallic-roughness map
uniform vec4 u_mirrorParams;  // x: 1 to read the planar reflection's picture (s_planar) instead of tracing the screen

#define STEPS 64
#define REFINE 5

// The scene mirrored along r from wpos; weight is 0 when nothing on the screen was hit.
vec3 traceScreen(vec3 wpos, vec3 r, vec2 pixel, out float weight)
{
	weight = 0.0;
	// Each pixel starts a different fraction of a step along (interleaved gradient noise), so the steps' pattern
	// shows as a fine grain at the edges of what is mirrored rather than as jagged teeth.
	float jitter = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
	vec3 p = wpos;
	float stride = 0.05;
	p += r * (stride * jitter);
	for (int i = 0; i < STEPS; i++)
	{
		vec3 previous = p;
		p += r * stride;
		vec4 clip = mul(u_viewProj, vec4(p, 1.0));
		if (clip.w <= 0.0)
			break;
		vec2 uv = ndcToUv(clip.xy / clip.w);
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
			break;
		float depth = texture2DLod(s_depth, uv, 0.0).x;
		float thickness = max(stride * 2.0, 0.6);
		if (depth > 0.0 && !isSky(depth) && clip.w > depth + 0.02 && clip.w - depth < thickness)
		{
			// Halve the last step a few times, to land on the surface that was passed rather than just behind it.
			vec3 lo = previous;
			vec3 hi = p;
			for (int k = 0; k < REFINE; k++)
			{
				vec3 mid = (lo + hi) * 0.5;
				vec4 c = mul(u_viewProj, vec4(mid, 1.0));
				float d = texture2DLod(s_depth, ndcToUv(c.xy / c.w), 0.0).x;
				if (c.w > d + 0.01)
					hi = mid;
				else
					lo = mid;
			}
			vec4 hit = mul(u_viewProj, vec4(hi, 1.0));
			uv = ndcToUv(hit.xy / hit.w);
			// Fades out towards the screen's edges, where what it would mirror is off the screen, and with distance.
			vec2 edge = min(uv, vec2_splat(1.0) - uv);
			// And where the ray only just passed behind what it found, which may be thinner than it looks.
			float behind = (clip.w - depth) / thickness;
			weight = clamp(min(edge.x, edge.y) * 10.0, 0.0, 1.0) * (1.0 - float(i) / float(STEPS)) * (1.0 - smoothstep(0.6, 1.0, behind));
			return texture2DLod(s_color, uv, 0.0).rgb;
		}
		stride *= 1.08;
	}
	return vec3_splat(0.0);
}

void main()
{
	if (u_reflection.x < 0.5 || u_material.w > 0.5)
	{
		gl_FragColor = vec4_splat(0.0);
		return;
	}
	vec2 uv = v_texcoord0 * u_uvTransform.xy + u_uvTransform.zw;
	vec4 tex = texture2D(s_albedo, uv);
	vec3 albedo = toLinear3(v_color0.rgb * tex.rgb);
	if (u_surface.x > 0.0 && v_color0.a * tex.a < u_surface.x - 0.00001)
	{
		discard;
	}
	float metallic = v_surface.z > 0.5 ? v_surface.x : u_material.x;
	float roughness = v_surface.z > 0.5 ? v_surface.y : u_material.y;
	if (u_pbr.y > 0.5)
	{
		vec4 metalRough = texture2D(s_metalRoughMap, uv);
		roughness *= metalRough.g;
		metallic *= metalRough.b;
	}
	if (u_palette.x > 0.5)
	{
		// The same face as fs_mesh drew (include/palette.sh): its palette colour, metallic and roughness.
		vec4 bytes = paletteBytes(v_color0);
		float alpha = 1.0;
		vec3 glow = vec3_splat(0.0);
		float unlit = 0.0;
		if (paletteSurface(bytes, texture2D(s_albedo, paletteCoord(bytes)), v_wpos, u_surface.y, albedo, alpha, metallic, roughness, glow, unlit) > 0.5)
		{
			discard;
		}
		if (unlit > 0.5)
		{
			gl_FragColor = vec4_splat(0.0);
			return;
		}
	}
	metallic = clamp(metallic, 0.0, 1.0);
	roughness = clamp(roughness, 0.045, 1.0);
	// Rough surfaces blur what they mirror, which one ray cannot: they keep the probe's blurred reflection.
	float sharp = 1.0 - smoothstep(0.15, 0.4, roughness);
	if (sharp <= 0.0)
	{
		gl_FragColor = vec4_splat(0.0);
		return;
	}

	vec3 v = normalize(u_camPos.xyz - v_wpos);
	vec3 n;
	if (u_material.z > 0.5)
	{
		n = normalize(cross(dFdx(v_wpos), dFdy(v_wpos)));
		if (dot(n, v) < 0.0)
			n = -n;
	}
	else
	{
		n = normalize(v_normal);
		vec3 face = cross(dFdx(v_wpos), dFdy(v_wpos));
		if (dot(face, v) * dot(face, n) < 0.0)
			n = -n;
	}
	if (u_pbr.x > 0.0)
	{
		vec3 mapped = texture2D(s_normalMap, uv).xyz * 2.0 - 1.0;
		mapped.xy *= u_pbr.x;
		vec3 dp1 = dFdx(v_wpos);
		vec3 dp2 = dFdy(v_wpos);
		vec2 duv1 = dFdx(uv);
		vec2 duv2 = dFdy(uv);
		vec3 dp2perp = cross(dp2, n);
		vec3 dp1perp = cross(n, dp1);
		vec3 tangent = dp2perp * duv1.x + dp1perp * duv2.x;
		vec3 bitangent = dp2perp * duv1.y + dp1perp * duv2.y;
		float scale = inversesqrt(max(max(dot(tangent, tangent), dot(bitangent, bitangent)), 1.0e-12));
		n = normalize(tangent * (scale * mapped.x) + bitangent * (scale * mapped.y) + n * mapped.z);
	}

	vec3 r = reflect(-v, n);
	float hit;
	vec3 scene;
	if (u_mirrorParams.x > 0.5)
	{
		// Planar Reflection: the scene drawn from the mirrored camera, at this same pixel. A normal map's bumps
		// shift where it is read, a little.
		vec2 screen = gl_FragCoord.xy * u_viewTexel.xy;
		vec3 faceNormal = normalize(v_normal);
		screen += (n.xz - faceNormal.xz) * 0.05;
		scene = texture2DLod(s_planar, screen, 0.0).rgb;
		hit = 1.0;
	}
	else
	{
		// Starts a little off the surface, so that the ray does not find the surface itself.
		scene = traceScreen(v_wpos + n * 0.02, r, gl_FragCoord.xy, hit);
	}
	hit *= sharp;
	if (hit <= 0.0)
	{
		gl_FragColor = vec4_splat(0.0);
		return;
	}
	vec3 f0 = mix(vec3_splat(0.04), albedo, metallic);
	vec3 probe = environmentReflection(v_wpos, r, roughness);
	vec3 brdf = environmentBrdf(f0, roughness, max(dot(n, v), 0.0));
	vec3 change = (scene * u_reflection.w - probe) * brdf * hit;
	// The first drawing was fogged afterwards; so is the change.
	float fogDistance = length(u_camPos.xyz - v_wpos);
	float fog = clamp(1.0 - exp(-fogDistance * fogDistance * u_fogColor.a * u_fogColor.a), 0.0, 1.0);
	gl_FragColor = vec4(change * (1.0 - fog), 0.0);
}
