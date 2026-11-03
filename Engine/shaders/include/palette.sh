// Palette mode (Material.palette, docs/materials.md), shared by fs_mesh and fs_mirror so both read a face alike.
// A face's vertex colour bytes are: red its palette entry, green its glow, blue its roughness (top five bits) and
// metallic (low three) or, flagged see-through, its opacity, and alpha its flags (Mesh.Palette*). The palette is a
// 16 x 16 texture with no mips or filtering, read at a texel's middle, so entries never bleed into each other.

uniform vec4 u_palette;       // x 1 in palette mode, y glow at full green, z dissolve (0 whole, 1 gone)

// The colour's four bytes, exact. A face never painted (plain white) is entry 255, matt, with no glow or flags.
vec4 paletteBytes(vec4 color)
{
	vec4 bytes = floor(color * 255.0 + 0.5);
	if (bytes.r + bytes.g + bytes.b + bytes.a > 1019.5)
	{
		bytes = vec4(255.0, 0.0, 24.0 * 8.0, 0.0);
	}
	return bytes;
}

// Where entry `bytes.r` is in the palette texture.
vec2 paletteCoord(vec4 bytes)
{
	return (vec2(mod(bytes.r, 16.0), floor(bytes.r / 16.0)) + 0.5) / 16.0;
}

// Bit `bit` (its value: 1, 2, 4...) of a byte.
float paletteFlag(float flags, float bit)
{
	return mod(floor(flags / bit), 2.0);
}

// The surface of a palette face from its bytes and palette entry. Returns 1 when the pixel is to be dropped
// (cutout or dissolved); unlit is 1 for a face drawn without lighting.
float paletteSurface(vec4 bytes, vec4 entry, vec3 worldPosition, float time, inout vec3 albedo, inout float alpha,
	inout float metallic, inout float roughness, inout vec3 emissive, out float unlit)
{
	albedo = toLinear3(entry.rgb);
	alpha = entry.a;
	float flags = bytes.a;
	unlit = paletteFlag(flags, 1.0);
	if (paletteFlag(flags, 2.0) > 0.5)
	{
		alpha *= bytes.b / 255.0;
	}
	else
	{
		roughness = floor(bytes.b / 8.0) / 31.0;
		metallic = mod(bytes.b, 8.0) / 7.0;
	}
	float glow = bytes.g / 255.0 * u_palette.y;
	if (paletteFlag(flags, 32.0) > 0.5)
	{
		// Animated glow: a slow pulse, offset across the face so a strip of lights ripples.
		glow *= 0.55 + 0.45 * sin(time * 4.0 + dot(worldPosition, vec3(0.7, 1.3, 0.9)));
	}
	emissive = albedo * glow;
	if (paletteFlag(flags, 16.0) > 0.5)
	{
		// Hologram: bright scan lines rolling up the face (see-through when it is also flagged transparent).
		float scan = 0.5 + 0.5 * sin(worldPosition.y * 40.0 - time * 6.0);
		emissive += albedo * (0.6 + scan);
		alpha *= 0.35 + 0.45 * scan;
	}
	float drop = 0.0;
	if (paletteFlag(flags, 8.0) > 0.5 && entry.a < 0.5)
	{
		drop = 1.0;
	}
	if (paletteFlag(flags, 64.0) > 0.5 && fract(sin(dot(floor(worldPosition * 8.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453) < u_palette.z)
	{
		drop = 1.0;
	}
	return drop;
}
