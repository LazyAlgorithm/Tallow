$input v_texcoord0, v_wpos

// Volumetric fog, step 3 of 3 (include/vfog.sh): lays the fog over the drawn scene and sky. Each pixel reads the grid
// at its depth (from the depth pass); past the grid's far end the fog goes on as plain height fog, lit as at the end of
// the grid with no shadows. Drawn with blending: picture x transmittance + light scattered in.
#include <bgfx_shader.sh>
#include "post.sh"
#include "vfog.sh"

SAMPLER2D(s_depth, 0);
SAMPLER3D(s_vfog, 1);

uniform vec4 u_sunDir;
uniform vec4 u_sunColor;
uniform vec4 u_ambientSky;

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
	if (sky && u_vfogSize.w < 0.5)
	{
		gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	}
	vec3 p = viewPosition(uv, 1.0);
	float stretch = u_postForward.w > 0.5 ? 1.0 : length(p);
	// The sky counts as far away (Sky Distance along the ray).
	if (sky)
		depth = u_vfogSize.z / stretch;
	// The grid holds the totals at each cell's far side: cell s ends at slice boundary s + 1.
	float slice = vfogDepthSlice(depth) - 1.0;
	float w = (clamp(slice, 0.0, u_vfogGrid.z - 1.0) + 0.5) / u_vfogGrid.z;
	vec4 fog = texture3DLod(s_vfog, vec3(uv, w), 0.0);
	// Nearer than the first cell's far side: a share of it.
	if (slice < 0.0)
	{
		float share = clamp(depth / vfogSliceDepth(1.0), 0.0, 1.0);
		fog = vec4(fog.rgb * share, mix(1.0, fog.a, share));
	}
	vec3 light = fog.rgb;
	float transmittance = fog.a;
	if (depth > u_vfogGrid.y)
	{
		// Beyond the grid: height fog from its far end to the surface (or the sky).
		vec3 eye = u_postEye.xyz;
		vec3 dir = normalize(worldPosition(uv, 1.0) - eye);
		vec3 start = eye + dir * (u_vfogGrid.y * stretch);
		float len = (depth - u_vfogGrid.y) * stretch;
		float through = exp(-vfogOpticalDepth(start, dir, len));
		vec3 sun = u_sunColor.rgb * (vfogPhase(u_vfogMedium.w, dot(dir, u_sunDir.xyz)) * u_vfogLight.w);
		vec3 lit = (sun + u_ambientSky.rgb * u_vfogGrid.w) * u_vfogLight.rgb;
		light += transmittance * (1.0 - through) * lit;
		transmittance *= through;
	}
	gl_FragColor = vec4(light, transmittance);
}
