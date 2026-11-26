// Volumetric fog (tallowengine.com/docs/day-night): a grid of cells (froxels) over the view, so many across, so many
// down and Slices deep, the slices spaced further apart with distance. cs_vfog_inject.sc fills each cell with the fog's
// density and the light it scatters, cs_vfog_integrate.sc adds them up from the camera outwards (blending in last
// frame's sums), fs_vfog_apply.sc lays the result over the picture. The see-through things and the water, drawn after
// the apply, ask vfogSampleWorld for their own depths instead. Include after bgfx_shader.sh / bgfx_compute.sh and
// post.sh; the fragment shaders that sample the sums declare SAMPLER3D(s_vfog, ...) before including this, and the
// compute passes define VFOG_NO_VOLUME (they read the grid as images, not through a sampler).
//
// The phase function and the ambient term follow Bevy's volumetric_fog (bevy_pbr, MIT; Engine/shaders/licenses/
// Bevy-LICENSE-MIT.txt); the cell grid and its sums are the published froxel method (Wronski 2014, Hillaire 2015).
#ifndef TALLOW_VFOG_SH
#define TALLOW_VFOG_SH

#define VFOG_PI 3.14159265

uniform vec4 u_vfogMedium; // x density at and below the base height (per metre), y base height, z falloff (per metre), w anisotropy g
uniform vec4 u_vfogLight;  // xyz albedo (linear), w sun scattering
uniform vec4 u_vfogGrid;   // x near (metres), y far (metres), z slices, w ambient strength
uniform vec4 u_vfogSize;   // xy cells across and down, z sky distance (metres), w 1 to fog the sky
uniform vec4 u_vfogTemporal; // x the cells' depth jitter (0..1 of a slice), y how much of last frame's cells to keep, z 1 when there are any
uniform mat4 u_vfogPrevViewProj; // last frame's camera (the sums are found at where a cell was then)

// How far in front of the camera (view depth) slice boundary s (0 to Slices) lies.
float vfogSliceDepth(float s)
{
	return u_vfogGrid.x * pow(u_vfogGrid.y / u_vfogGrid.x, s / u_vfogGrid.z);
}

// The slice (continuous, 0 to Slices) a view depth lies in.
float vfogDepthSlice(float depth)
{
	return log(max(depth, u_vfogGrid.x) / u_vfogGrid.x) / log(u_vfogGrid.y / u_vfogGrid.x) * u_vfogGrid.z;
}

// Height fog: full density at and below the base height, thinning above it.
float vfogDensity(vec3 wpos)
{
	return u_vfogMedium.x * exp(-max(wpos.y - u_vfogMedium.y, 0.0) * u_vfogMedium.z);
}

// Henyey-Greenstein phase function (as Bevy's): cosTheta between the way the light travels on to the eye and the way
// it came, here dot(direction from the camera, direction to the sun).
float vfogPhase(float g, float cosTheta)
{
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * VFOG_PI * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 1.0e-4), 1.5));
}

// The fog's optical depth along a straight path of length len from p in direction dir (unit), for vfogDensity with
// the base height taken at the start of the path when below it (an exact integral above the base height).
float vfogOpticalDepth(vec3 p, vec3 dir, float len)
{
	float h = max(p.y - u_vfogMedium.y, 0.0);
	float k = u_vfogMedium.z * dir.y;
	float start = u_vfogMedium.x * exp(-h * u_vfogMedium.z);
	if (abs(k) < 1.0e-5)
		return start * len;
	return start * (1.0 - exp(-k * len)) / k;
}

#ifndef VFOG_NO_VOLUME
// The sums at a view depth along the column at uv: rgb the light scattered in before it, a how much of what is behind
// shows through. Past the grid's far end the fog goes on as plain height fog, lit as at the end of the grid with no
// shadows; nearer than its first cell takes a share of that cell.
vec4 vfogIntegratedAt(vec2 uv, float depth)
{
	vec3 p = viewPosition(uv, 1.0);
	float stretch = u_postForward.w > 0.5 ? 1.0 : length(p);
	// The sums hold each cell's totals at its far side: cell s ends at slice boundary s + 1.
	float slice = vfogDepthSlice(depth) - 1.0;
	float w = (clamp(slice, 0.0, u_vfogGrid.z - 1.0) + 0.5) / u_vfogGrid.z;
	vec4 fog = texture3DLod(s_vfog, vec3(uv, w), 0.0);
	if (slice < 0.0)
	{
		float share = clamp(depth / vfogSliceDepth(1.0), 0.0, 1.0);
		fog = vec4(fog.rgb * share, mix(1.0, fog.a, share));
	}
	vec3 light = fog.rgb;
	float transmittance = fog.a;
	if (depth > u_vfogGrid.y)
	{
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
	return vec4(light, transmittance);
}

// The fog over a surface at wpos: what the apply lays over the solid scene, for the see-through things and the water,
// which are drawn after it and so ask for their own depth.
vec4 vfogSampleWorld(vec3 wpos)
{
	if (u_vfogSize.w < 0.5)
		return vec4(0.0, 0.0, 0.0, 1.0);
	vec3 rel = wpos - u_postEye.xyz;
	float depth = dot(rel, u_postForward.xyz);
	if (depth <= 0.0)
		return vec4(0.0, 0.0, 0.0, 1.0);
	vec2 uv = clamp(viewToUv(vec3(dot(rel, u_postRight.xyz), dot(rel, u_postUp.xyz), depth)), vec2_splat(0.0), vec2_splat(1.0));
	return vfogIntegratedAt(uv, depth);
}
#endif // VFOG_NO_VOLUME

#endif // TALLOW_VFOG_SH
