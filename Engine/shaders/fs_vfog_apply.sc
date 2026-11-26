$input v_texcoord0, v_wpos

// Volumetric fog, step 3 of 3 (include/vfog.sh): lays the fog over the drawn scene and sky. Each pixel reads the grid
// at its depth (from the depth pass); past the grid's far end the fog goes on as plain height fog, lit as at the end of
// the grid with no shadows. Drawn with blending: picture x transmittance + light scattered in. The see-through things
// and the water, drawn after this, ask vfog.sh's vfogSampleWorld instead (the TW_VFOG shader variants).
#include <bgfx_shader.sh>
#include "post.sh"
uniform vec4 u_sunDir;
uniform vec4 u_sunColor;
uniform vec4 u_ambientSky;
SAMPLER3D(s_vfog, 1);
#include "vfog.sh"

SAMPLER2D(s_depth, 0);

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
	// The sky counts as far away (Sky Distance along the ray).
	if (sky)
	{
		vec3 p = viewPosition(uv, 1.0);
		float stretch = u_postForward.w > 0.5 ? 1.0 : length(p);
		depth = u_vfogSize.z / stretch;
	}
	gl_FragColor = vfogIntegratedAt(uv, depth);
}
