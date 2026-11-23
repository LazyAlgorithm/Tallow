$input v_wpos, v_normal, v_color0, v_texcoord0, v_depth

// The water's surface (tallowengine.com/docs/water), drawn over a copy of the scene so far (s_color) with the depth pass (s_depth):
// what is under the surface is bent by the waves, fades into the water's colour with the distance through it, and
// takes caustics; the surface mirrors the sky, the reflection probe it is in and (Screen Reflections) the scene on
// the screen; foam gathers at the shore and on sharp crests. The Low Poly look shades each facet flat, in bands of
// colour. Seen from below, the world above shows through a window overhead and the rest mirrors the water.
#include <bgfx_shader.sh>
#include "lighting.sh"
#include "post.sh"
#include "water.sh"

SAMPLER2D(s_color, 0);
SAMPLER2D(s_depth, 2);

uniform vec4 u_waterParams;  // x: 1 low poly, y: time (seconds, wrapped), z: refraction, w: roughness
uniform vec4 u_waterShallow; // rgb: the shallow colour (linear), w: clarity (metres)
uniform vec4 u_waterDeep;    // rgb: the deep colour, w: foam amount
uniform vec4 u_waterFoam;    // rgb: the foam colour, w: how far out the shore's foam reaches (metres of depth)
uniform vec4 u_waterOptions; // x: 1 caustics, y: 1 screen reflections, z: 1 when the camera is under this water's surface, w: -
uniform vec4 u_waterUnder;   // rgb: the underwater colour (lit), w: underwater visibility (metres)

// The scene mirrored along r from wpos, found by stepping across the depth pass; weight is 0 when nothing was hit.
vec3 screenReflection(vec3 wpos, vec3 r, out float weight)
{
	weight = 0.0;
	vec3 found = vec3_splat(0.0);
	vec3 p = wpos;
	float stride = 0.3;
	for (int i = 0; i < 28; i++)
	{
		p += r * stride;
		stride *= 1.16;
		vec4 clip = mul(u_viewProj, vec4(p, 1.0));
		if (clip.w <= 0.0)
			break;
		vec2 uv = ndcToUv(clip.xy / clip.w);
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
			break;
		float depth = texture2DLod(s_depth, uv, 0.0).x;
		if (depth > 0.0 && !isSky(depth) && clip.w > depth + 0.03 && clip.w - depth < stride * 3.0)
		{
			// Fades out towards the screen's edges, where what it would mirror is off the screen.
			vec2 edge = min(uv, vec2_splat(1.0) - uv);
			weight = clamp(min(edge.x, edge.y) * 12.0, 0.0, 1.0) * (1.0 - float(i) / 28.0);
			found = texture2DLod(s_color, uv, 0.0).rgb;
			break;
		}
	}
	return found;
}

void main()
{
	bool lowPoly = u_waterParams.x > 0.5;
	float time = u_waterParams.y;
	float roughness = clamp(u_waterParams.w, 0.02, 1.0);
	float clarity = max(u_waterShallow.w, 0.05);
	vec2 flow = u_waterLevel.zw;
	vec3 wpos = v_wpos;
	vec3 toEye = u_camPos.xyz - wpos;
	float eyeDistance = max(length(toEye), 1.0e-4);
	vec3 v = toEye / eyeDistance;
	vec3 waveNormal = normalize(v_normal);
	// Whether the camera is under the surface is worked out once (Water.SurfaceAt under the camera): a wave's back,
	// far off, also faces away from the camera without being seen from below.
	bool below = u_waterOptions.z > 0.5;

	// The ripples that run over the waves and the foam's pattern drift with the current.
	vec2 still = v_texcoord0 - flow * time;
	vec3 n;
	if (lowPoly)
	{
		// Each facet flat: its own face's direction.
		n = normalize(cross(dFdx(wpos), dFdy(wpos)));
		if (dot(n, waveNormal) < 0.0)
			n = -n;
	}
	else
	{
		vec3 a = waterNoise(still * 0.9 + vec2(0.31, 0.17) * time);
		vec3 b = waterNoise(still * 2.3 + vec2(-0.27, 0.36) * time);
		vec3 c = waterNoise(still * 5.7 + vec2(0.42, -0.21) * time);
		vec2 slope = a.yz * (0.9 * 0.06) + b.yz * (2.3 * 0.025) + c.yz * (5.7 * 0.008);
		slope *= clamp(1.0 - eyeDistance / 160.0, 0.0, 1.0) * (1.0 - roughness * 0.5);
		n = normalize(waveNormal + vec3(-slope.x, 0.0, -slope.y));
	}
	// Far away a pixel covers many waves: their average faces up, and following each one there only flickers.
	float far = smoothstep(150.0, 1200.0, eyeDistance);
	n = normalize(mix(n, vec3(0.0, 1.0, 0.0), far));
	waveNormal = normalize(mix(waveNormal, vec3(0.0, 1.0, 0.0), far));
	if (below)
	{
		n = -n;
		waveNormal = -waveNormal;
	}

	// What is behind this pixel in the scene, straight through and bent by the waves.
	vec2 screen = gl_FragCoord.xy * u_viewTexel.xy;
	float pixelDepth = v_depth;
	float sceneDepth = texture2D(s_depth, screen).x;
	float straightThrough = isSky(sceneDepth) || isViewmodel(sceneDepth) ? 1000.0 : max(sceneDepth - pixelDepth, 0.0) * (eyeDistance / max(pixelDepth, 1.0e-4));
	vec2 bend = n.xz * u_waterParams.z * clamp(straightThrough * 0.5, 0.0, 1.0);
	vec2 bentUv = screen + bend;
	float bentDepth = texture2D(s_depth, bentUv).x;
	// Something in front of the water would be bent into it: use the straight view there.
	if (bentDepth < pixelDepth || isViewmodel(bentDepth))
	{
		bentUv = screen;
		bentDepth = sceneDepth;
	}
	vec3 behindColor = texture2D(s_color, bentUv).rgb;
	float through = isSky(bentDepth) ? 1000.0 : max(bentDepth - pixelDepth, 0.0) * (eyeDistance / max(pixelDepth, 1.0e-4));
	vec3 behind = wpos - v * through;

	float sunShade = sunShadow(wpos, waveNormal, pixelDepth);
	vec3 sun = u_sunColor.rgb * sunShade;
	vec3 ambient = mix(u_ambientGround.rgb, u_ambientSky.rgb, 0.75);
	float sunAmount = clamp(u_sunDir.y, 0.0, 1.0) * sunShade;

	vec3 color;
	if (below)
	{
		// Looking up from under the water: the world above through a window overhead (Snell's window), the water
		// mirrored all round it. The underwater pass then fogs it by the distance through the water.
		float window = smoothstep(0.60, 0.72, dot(v, n));
		vec3 mirrored = u_waterUnder.rgb * 0.6;
		color = mix(mirrored, behindColor * mix(vec3_splat(1.0), u_waterShallow.rgb, 0.3), window);
		gl_FragColor = vec4(color, 1.0);
		return;
	}

	// Light through the water: caustics on what is under it, then lost into the water's colour over the distance.
	if (u_waterOptions.x > 0.5 && !isSky(bentDepth))
	{
		float depthBelow = max(u_waterLevel.x - behind.y, 0.0);
		float caustic = waterCaustics(behind.xz - flow * time, time);
		behindColor *= 1.0 + caustic * 1.6 * sunAmount * exp(-depthBelow / (clarity * 1.5)) * smoothstep(0.0, 0.3, depthBelow);
	}
	float clear = exp(-through / clarity);
	vec3 body = mix(u_waterDeep.rgb, u_waterShallow.rgb, lowPoly ? 0.0 : exp(-through / (clarity * 2.0)));
	if (lowPoly)
	{
		// Bands of colour from shallow to deep instead of a smooth fade.
		float band = floor(clamp(exp(-through / (clarity * 1.5)), 0.0, 0.999) * 4.0) / 3.0;
		body = mix(u_waterDeep.rgb, u_waterShallow.rgb, band);
		clear = clear > 0.55 ? clear * 0.5 : 0.0;
	}
	// The water's own colour is lit by the sun coming down into it and by the sky.
	// The Low Poly look shades each facet by how it faces the sun, so the facets show.
	vec3 lit = body * (sun * (0.25 + 0.75 * max(dot(n, u_sunDir.xyz), 0.0)) * (lowPoly ? 0.7 : 0.35) + ambient);
	color = mix(lit, behindColor * mix(vec3_splat(1.0), u_waterShallow.rgb * 1.2, 1.0 - clear), clear);

	// What the surface mirrors, more at a grazing angle.
	vec3 r = reflect(-v, n);
	r.y = max(r.y, 0.02);
	r = normalize(r);
	// Low Poly facets mirror the sky sharply, each in one piece; blurred, the sun's glow would spread over a whole side of the sea.
	vec3 mirrored = u_reflection.x > 0.5 ? environmentReflection(wpos, r, lowPoly ? 0.05 : roughness) : mix(u_ambientGround.rgb, u_ambientSky.rgb, clamp(r.y * 0.5 + 0.5, 0.0, 1.0));
	// The sun's own disc in the sky's cube would flash over whole rough facets: the glint below draws the sun.
	mirrored = min(mirrored, vec3_splat(lowPoly ? 1.2 : 4.0));
	if (u_waterOptions.y > 0.5)
	{
		float hit;
		vec3 scene = screenReflection(wpos, r, hit);
		mirrored = mix(mirrored, scene, hit);
	}
	float facing = max(dot(n, v), 0.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - facing, 5.0);
	if (lowPoly)
		fresnel = fresnel * 0.6;
	color = mix(color, mirrored, fresnel * (1.0 - roughness * 0.5));
	// The sun's glint. Low Poly water only sparkles on facets that mirror the sun straight at the camera: a lit
	// highlight over many small facets turns a whole side of the sea white when the sun is low.
	if (lowPoly)
		color += sun * pow(max(dot(reflect(-u_sunDir.xyz, n), v), 0.0), 800.0) * 1.5;
	else
		color += brdf(n, v, u_sunDir.xyz, vec3_splat(0.0), 0.0, max(roughness, 0.04), 1.0) * sun * PI;

	// Foam: at the shore and round things in the water, and on crests folded over sharply.
	float foamAmount = u_waterDeep.w;
	if (foamAmount > 0.0)
	{
		float shoreWidth = max(u_waterFoam.w, 0.01);
		// How far it is through the water to what is under it: near a shore or round something standing in the water
		// it is short. Along the view rather than straight down, so that looking along a wall does not smear foam
		// over the water in front of it.
		float shore = 1.0 - clamp(straightThrough / shoreWidth, 0.0, 1.0);
		float crest = clamp((0.55 - v_color0.x) * 2.5, 0.0, 1.0);
		float foam;
		if (lowPoly)
		{
			// Crisp bands that wash in and out.
			float wash = sin(straightThrough / shoreWidth * 6.0 - time * 1.5) * 0.5 + 0.5;
			foam = step(0.62, shore) + step(0.25, shore) * step(0.7, wash) * shore;
			foam += step(0.5, crest);
			foam = clamp(foam * foamAmount, 0.0, 1.0);
		}
		else
		{
			float pattern = waterNoise(still * 1.6 + vec2(0.1, 0.2) * time).x * 0.5 + waterNoise(still * 4.1 - vec2(0.2, 0.1) * time).x * 0.3 + 0.5;
			float wanted = max(shore * shore * 1.3, crest);
			foam = smoothstep(1.0 - wanted * foamAmount, 1.05 - wanted * foamAmount, pattern) * clamp(wanted * 2.0, 0.0, 1.0);
			foam = max(foam, smoothstep(0.88, 1.0, shore) * foamAmount);
			foam = clamp(foam, 0.0, 1.0);
		}
		vec3 foamLit = u_waterFoam.rgb * (sun * max(dot(waveNormal, u_sunDir.xyz), 0.0) + ambient);
		color = mix(color, foamLit, foam);
	}
	color = applyFog(color, wpos);
	// Where the surface meets the ground it fades into what is under it, instead of a hard line.
	color = mix(texture2D(s_color, screen).rgb, color, smoothstep(0.0, 0.12, straightThrough));
	gl_FragColor = vec4(color, 1.0);
}
