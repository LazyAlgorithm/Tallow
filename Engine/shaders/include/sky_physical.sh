// The physical sky (fs_sky_physical.sc draws it; fs_env_sky_physical.sc puts it into the sky's reflection cube, so
// reflections match). u_skyMode.x picks it: 1 the sky-view LUT (include/atmosphere.sh, Engine/src/Render/PhysicalSky.bf);
// 2 the analytic Preetham sky with the same inputs (OpenGL / GLES / WebGL, or no half-float render targets). Both add
// the sun's disc, the moon (lit by the sun: its phase) and procedural stars at night. The Gradient sky is sky.sh (its
// own programs, so Gradient scenes look exactly as before). Include after bgfx_shader.sh.
#ifndef TALLOW_SKY_PHYSICAL_SH
#define TALLOW_SKY_PHYSICAL_SH

#include "atmosphere.sh"
#include "clouds.sh"

uniform vec4 u_sunDir;
uniform vec4 u_sunColor;
// x: mode (1 or 2, above), y: time in seconds (stars twinkle), z: how visible the stars are (0 by day), w: sky brightness.
uniform vec4 u_skyMode;
// rgb: the sky-view LUT to scene light (sun light, sky brightness, calibration), w: the sun disc's angular radius.
uniform vec4 u_skyScale;
// xyz: towards the moon, w: its angular radius (0: no moon).
uniform vec4 u_moonDir;
// x: the moon's brightness at full light.
uniform vec4 u_moonParams;
// Rows turning a world direction into the star sphere's (the sky's turn with the time and latitude).
uniform vec4 u_starRot[3];
// Perez coefficients A..E for Y, x, y in xyz; w of 0..2: zenith Y, x, y over F(0, sun); 3.w: brightness; 4.w: day.
uniform vec4 u_preetham[5];

SAMPLER2D(s_atmoSkyView, 1);

// The physical sky from the sky-view LUT, per unit of sun light, times the scale.
vec3 lutSky(vec3 dir)
{
	float r = u_atmoParams.y;
	float elevation = asin(clamp(dir.y, -1.0, 1.0));
	vec2 flatDir = dir.xz;
	vec2 flatSun = u_sunDir.xz;
	float lengths = length(flatDir) * length(flatSun);
	float azimuth = lengths > 1.0e-5 ? acos(clamp(dot(flatDir, flatSun) / lengths, -1.0, 1.0)) : 0.0;
	return texture2DLod(s_atmoSkyView, atmoSkyViewUv(r, elevation, azimuth), 0.0).rgb * u_skyScale.rgb;
}

float perez(float cosTheta, float gamma, float cosGamma, float A, float B, float C, float D, float E)
{
	return (1.0 + A * exp(B / max(cosTheta, 0.02))) * (1.0 + C * exp(D * gamma) + E * cosGamma * cosGamma);
}

// The Preetham sky (mode 2), blended to a dark twilight blue after sunset.
vec3 preethamSky(vec3 dir)
{
	float up = max(dir.y, 0.03);
	vec3 d = normalize(vec3(dir.x, up, dir.z));
	float cosGamma = clamp(dot(d, normalize(vec3(u_sunDir.x, max(u_sunDir.y, 0.0), u_sunDir.z))), -1.0, 1.0);
	float gamma = acos(cosGamma);
	float Y = u_preetham[0].w * perez(d.y, gamma, cosGamma, u_preetham[0].x, u_preetham[1].x, u_preetham[2].x, u_preetham[3].x, u_preetham[4].x);
	float x = u_preetham[1].w * perez(d.y, gamma, cosGamma, u_preetham[0].y, u_preetham[1].y, u_preetham[2].y, u_preetham[3].y, u_preetham[4].y);
	float y = u_preetham[2].w * perez(d.y, gamma, cosGamma, u_preetham[0].z, u_preetham[1].z, u_preetham[2].z, u_preetham[3].z, u_preetham[4].z);
	vec3 XYZ = vec3(x / max(y, 1.0e-4) * Y, Y, (1.0 - x - y) / max(y, 1.0e-4) * Y);
	vec3 rgb = vec3(
		3.2406 * XYZ.x - 1.5372 * XYZ.y - 0.4986 * XYZ.z,
		-0.9689 * XYZ.x + 1.8758 * XYZ.y + 0.0415 * XYZ.z,
		0.0557 * XYZ.x - 0.2040 * XYZ.y + 1.0570 * XYZ.z);
	rgb = max(rgb, vec3_splat(0.0)) * u_preetham[3].w;
	float day = u_preetham[4].w;
	float dusk = smoothstep(-0.3142, -0.1047, u_sunDir.y);
	vec3 sky = mix(vec3(0.02, 0.03, 0.08) * dusk * u_skyMode.w, rgb, day);
	// Below the horizon: the horizon's colour, darker.
	return dir.y >= 0.0 ? sky : sky * mix(1.0, 0.35, clamp(-dir.y * 4.0, 0.0, 1.0));
}

float skyHash(vec3 p)
{
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// One layer of stars: a cell of a cube round the sky holds a star now and then.
vec3 starLayer(vec3 c, float cells, float seed)
{
	vec3 a = abs(c);
	vec2 uv;
	float face;
	if (a.x >= a.y && a.x >= a.z)
	{
		uv = c.yz / a.x;
		face = c.x > 0.0 ? 0.0 : 1.0;
	}
	else if (a.y >= a.z)
	{
		uv = c.xz / a.y;
		face = c.y > 0.0 ? 2.0 : 3.0;
	}
	else
	{
		uv = c.xy / a.z;
		face = c.z > 0.0 ? 4.0 : 5.0;
	}
	vec2 g = (uv * 0.5 + 0.5) * cells;
	vec2 cell = floor(g);
	vec3 key = vec3(cell, face * 7.0 + seed);
	if (skyHash(key) < 0.996)
		return vec3_splat(0.0);
	vec2 centre = cell + 0.25 + 0.5 * vec2(skyHash(key + 1.7), skyHash(key + 3.1));
	vec2 offset = g - centre;
	float shape = exp(-dot(offset, offset) / (2.0 * 0.13 * 0.13));
	float brightness = mix(0.12, 4.0, pow(skyHash(key + 5.3), 8.0));
	float tone = skyHash(key + 7.9);
	vec3 color = mix(vec3(0.65, 0.75, 1.0), vec3(1.0, 0.82, 0.62), tone);
	float twinkle = 0.8 + 0.2 * sin(u_skyMode.y * (3.0 + 7.0 * tone));
	return color * brightness * shape * twinkle;
}

// The sun disc, the moon and the stars on top of a physical or Preetham sky (dir above the horizon).
vec3 skyBodies(vec3 dir, float sunDisc)
{
	vec3 color = vec3_splat(0.0);
	float r = u_atmoParams.y;
	if (sunDisc > 0.0)
	{
		float angle = acos(clamp(dot(dir, u_sunDir.xyz), -1.0, 1.0));
		float radius = u_skyScale.w;
		float w = max(radius * 0.15, 0.0004);
		float disc = 1.0 - smoothstep(radius - w, radius + w, angle);
		float strength = max(u_sunColor.r, max(u_sunColor.g, u_sunColor.b));
		vec3 tint = u_sunColor.rgb / max(strength, 1.0e-3);
		color += tint * disc * 12.0 * clamp(strength * 4.0, 0.0, 1.0);

		// The moon: a sphere lit from the sun's side, with a faint earthshine on its dark part.
		float moonRadius = u_moonDir.w;
		float moonCos = dot(dir, u_moonDir.xyz);
		float moonAngle = acos(clamp(moonCos, -1.0, 1.0));
		if (moonRadius > 0.0 && moonAngle < moonRadius * 1.2)
		{
			vec3 tangent = (dir - u_moonDir.xyz * moonCos) / sin(moonRadius);
			float t2 = min(dot(tangent, tangent), 1.0);
			vec3 normal = tangent - u_moonDir.xyz * sqrt(1.0 - t2);
			float lit = max(dot(normal, u_sunDir.xyz), 0.0);
			float edge = 1.0 - smoothstep(moonRadius * 0.94, moonRadius * 1.02, moonAngle);
			vec3 moonT = atmoTransmittance(r, u_moonDir.y);
			color += vec3(1.0, 0.97, 0.92) * (lit * 0.12 + 0.002) * u_moonParams.x * edge * moonT;
		}
	}
	if (u_skyMode.z > 0.0)
	{
		vec3 c = vec3(dot(u_starRot[0].xyz, dir), dot(u_starRot[1].xyz, dir), dot(u_starRot[2].xyz, dir));
		vec3 stars = starLayer(c, 400.0, 0.0) + starLayer(c, 940.0, 13.0) * 0.6;
		color += stars * u_skyMode.z * atmoTransmittance(r, dir.y);
	}
	return color;
}

// The sky's colour in direction dir (unit length), linear HDR, seen from origin (the camera, or the sky's cube's
// centre). sunDisc 0 leaves out the sun's bright disc, the moon and the stars (reflections get the sun's highlight from
// the sun itself, as a light). The clouds go over the bodies, so a thick cloud hides the sun, moon and stars.
vec3 skyColor(vec3 dir, float sunDisc, vec3 origin)
{
	vec3 sky = u_skyMode.x < 1.5 ? lutSky(dir) : preethamSky(dir);
	// Airglow: the night sky is never quite black.
	sky += vec3(0.0008, 0.001, 0.0016) * u_skyMode.w;
	if (dir.y > atmoHorizonElevation(u_atmoParams.y))
		sky += skyBodies(dir, sunDisc);
	return applyProceduralClouds(sky, dir, origin);
}

#endif
