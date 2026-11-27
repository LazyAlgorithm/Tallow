$input v_texcoord0, v_wpos

// Volumetric fog where the card cannot run the froxel grid (OpenGL, the web, --gpu-driven-caps-off): the same height
// fog, computed exactly along each pixel's ray from the depth pass (include/vfog.sh's vfogOpticalDepth), and cheap
// screen-space sun shafts: a radial blur of the sky mask towards the sun's place on the screen, so where the sky shows
// beyond a shadowed edge the fog brightens along the line to the sun. Fog Volumes and local lights are not drawn by
// this path. Drawn with blending: picture x transmittance + light scattered in.
#include <bgfx_shader.sh>
#include "post.sh"
uniform vec4 u_sunDir;
uniform vec4 u_sunColor;
uniform vec4 u_ambientSky;
#define VFOG_NO_VOLUME 1
#include "vfog.sh"

SAMPLER2D(s_depth, 0);

#ifndef VFOG_SHAFT_TAPS
#define VFOG_SHAFT_TAPS 24
#endif

// How much of the sun reaches uv through the sky along the way to the sun's place on the screen: 1 when the way is
// all sky, down to 0.15 where the camera's surroundings cut it off. No shafts when the sun is behind the camera.
float vfogSkyShafts(vec2 uv)
{
	vec3 toSun = u_sunDir.xyz;
	float forward = dot(toSun, u_postForward.xyz);
	if (forward <= 0.02 || u_sunColor.w < 0.5)
		return 1.0;
	vec2 sunUv = ndcToUv(vec2(dot(toSun, u_postRight.xyz) / (u_postRight.w * forward),
		dot(toSun, u_postUp.xyz) / (u_postUp.w * forward)));
	vec2 delta = (sunUv - uv) / float(VFOG_SHAFT_TAPS);
	vec2 at = uv;
	float open = 0.0;
	float weight = 0.0;
	for (int i = 1; i <= VFOG_SHAFT_TAPS; i++)
	{
		at += delta;
		float depth = texture2DLod(s_depth, clamp(at, vec2_splat(0.0), vec2_splat(1.0)), 0.0).x;
		float w = 1.0 - float(i) / float(VFOG_SHAFT_TAPS);
		open += (isSky(depth) ? 1.0 : 0.0) * w;
		weight += w;
	}
	return mix(0.15, 1.0, open / max(weight, 1.0e-4));
}

void main()
{
	vec2 uv = v_texcoord0;
	float depth = texture2DLod(s_depth, uv, 0.0).x;
	if (isViewmodel(depth))
	{
		gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	}
	bool sky = isSky(depth);
	// The sky counts as far away (Sky Distance along the ray).
	float metres = u_vfogSize.z;
	if (!sky)
	{
		vec3 p = viewPosition(uv, 1.0);
		float stretch = u_postForward.w > 0.5 ? 1.0 : length(p);
		metres = depth * stretch;
	}
	vec3 p = viewPosition(uv, 1.0);
	vec3 dir = normalize(u_postRight.xyz * p.x + u_postUp.xyz * p.y + u_postForward.xyz * p.z);
	float through = exp(-vfogOpticalDepth(u_postEye.xyz, dir, metres));
	vec3 sun = u_sunColor.rgb * (vfogPhase(u_vfogMedium.w, dot(dir, u_sunDir.xyz)) * u_vfogLight.w)
		* vfogSkyShafts(uv);
	vec3 lit = (sun + u_ambientSky.rgb * u_vfogGrid.w) * u_vfogLight.rgb;
	// Premultiplied light and the transmittance, exactly as the froxel apply writes them (fs_vfog_apply.sc): the shared
	// blend state is source x 1 + destination x source alpha, so the alpha carries how much of the picture shows through.
	gl_FragColor = vec4((1.0 - through) * lit, through);
}
