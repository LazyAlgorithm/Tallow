// Volumetric fog (tallowengine.com/docs/day-night): a grid of cells (froxels) over the view, so many across, so many
// down and Slices deep, the slices spaced further apart with distance. cs_vfog_inject.sc fills each cell with the fog's
// density and the light it scatters, cs_vfog_integrate.sc adds them up from the camera outwards, fs_vfog_apply.sc lays
// the result over the picture. Include after bgfx_shader.sh / bgfx_compute.sh and post.sh.
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

#endif // TALLOW_VFOG_SH
