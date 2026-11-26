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
uniform vec4 u_vfogDebug; // x: 0 the lit picture, 1 the cells' density, 2 the light they scatter; yz: their scales
SAMPLER3D(s_vfog, 1);
#include "vfog.sh"

SAMPLER2D(s_depth, 0);
// The cells themselves, for the debug views (the density and light cs_vfog_inject.sc wrote).
SAMPLER3D(s_vfogCells, 2);

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
	if (u_vfogDebug.x > 0.5)
	{
		// The cell this pixel is in, shown instead of the picture: its density (grey) or the light it scatters.
		float slice = clamp(floor(vfogDepthSlice(depth) - 0.5), 0.0, u_vfogGrid.z - 1.0);
		vec4 cell = texture3DLod(s_vfogCells, vec3(uv, (slice + 0.5) / u_vfogGrid.z), 0.0);
		if (u_vfogDebug.x < 1.5)
			gl_FragColor = vec4(vec3_splat(clamp(cell.a * u_vfogDebug.y, 0.0, 1.0)), 1.0);
		else
		{
			vec3 light = cell.rgb * u_vfogDebug.z;
			float peak = max(max(light.r, light.g), max(light.b, 1.0));
			gl_FragColor = vec4(light / peak, 1.0);
		}
		return;
	}
	gl_FragColor = vfogIntegratedAt(uv, depth);
}
