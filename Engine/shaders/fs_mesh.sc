$input v_wpos, v_normal, v_color0, v_texcoord0, v_depth, v_texcoord1, v_surface

// Forward lit surface: a material's colour, maps and lightmap, lit by include/lighting.sh (metallic/roughness BRDF,
// the sun with four shadow cascades, up to 16 point/spot lights with spotlight shadows, hemisphere ambient and
// distance fog). Output is linear HDR.
#include <bgfx_shader.sh>
#include "lighting.sh"
#include "palette.sh"

SAMPLER2D(s_albedo, 0);
SAMPLER2D(s_texture1, 2);
SAMPLER2D(s_texture2, 3);
SAMPLER2D(s_normalMap, 4);
SAMPLER2D(s_metalRoughMap, 5);
SAMPLER2D(s_occlusionMap, 6);
SAMPLER2D(s_emissiveMap, 7);
SAMPLER2D(s_lightmap, 8);
SAMPLER2D(s_lightmapDirection, 9);
SAMPLER2D(s_lightmapShadowmask, 10);
uniform vec4 u_lightmapTransform;
uniform vec4 u_lightmapDecode;

uniform vec4 u_material;      // x metallic, y roughness, z flat shading, w 1 unlit, 2 the editor's preview light
uniform vec4 u_emissive;
uniform vec4 u_uvTransform;   // xy tiling, zw offset
uniform vec4 u_surface;       // x alpha cutoff (0: no cutout), y time in seconds, z 1 when the glow takes the surface's own colour
uniform vec4 u_params[8];     // a custom shader's own properties, in the order it declares them
uniform vec4 u_pbr;           // x normal map strength (0: none), y 1 with a metallic-roughness map, z occlusion strength (0: none), w 1 with an emissive map

// A custom shader (.tshader) is this file with its properties and its surface code put at the two markers below.
// The surface code may read uv, worldPosition, worldNormal, vertexColor and time, sample mainTexture, texture1 and
// texture2, and change albedo (already linear), alpha, metallic, roughness, emissive, occlusion and surfaceNormal (a
// normal in the surface's own directions: x along U, y along V, z out of it). Lighting, shadows and fog then apply
// to the result exactly as they do to the standard material.
#define mainTexture s_albedo
#define texture1 s_texture1
#define texture2 s_texture2
#include "shadergraph.sh"
//@PROPERTIES

void main()
{
	vec2 uv = v_texcoord0 * u_uvTransform.xy + u_uvTransform.zw;
	vec3 worldPosition = v_wpos;
	vec3 worldNormal = normalize(v_normal);
	vec4 vertexColor = v_color0;
	float time = u_surface.y;
	vec4 tex = texture2D(s_albedo, uv);
	vec3 albedo = toLinear3(v_color0.rgb * tex.rgb);
	float alpha = v_color0.a * tex.a;
	// An instance's own metallic and roughness, when it carries them, so renderers that differ only in these draw together.
	float metallic = v_surface.z > 0.5 ? v_surface.x : u_material.x;
	float roughness = v_surface.z > 0.5 ? v_surface.y : u_material.y;
	float specularLevel = 1.0;
	// With "emissive from colour" the bright parts of a model glow in their own colour and its dark parts do not.
	vec3 emissive = u_emissive.rgb * mix(vec3_splat(1.0), albedo, u_surface.z);
	float occlusion = 1.0;
	vec3 surfaceNormal = vec3(0.0, 0.0, 1.0);
	float paletteUnlit = 0.0;
	if (u_palette.x > 0.5)
	{
		vec4 bytes = paletteBytes(v_color0);
		if (paletteSurface(bytes, texture2D(s_albedo, paletteCoord(bytes)), worldPosition, time, albedo, alpha, metallic, roughness, emissive, paletteUnlit) > 0.5)
		{
			discard;
		}
	}
//@SURFACE
//@UNDEFINE
	// The PBR maps, in the glTF layout: roughness in green and metallic in blue of one texture, occlusion in red.
	if (u_pbr.y > 0.5)
	{
		vec4 metalRough = texture2D(s_metalRoughMap, uv);
		roughness *= metalRough.g;
		metallic *= metalRough.b;
	}
	if (u_pbr.z > 0.0)
	{
		occlusion *= mix(1.0, texture2D(s_occlusionMap, uv).r, u_pbr.z);
	}
	if (u_pbr.w > 0.5)
	{
		emissive *= toLinear3(texture2D(s_emissiveMap, uv).rgb);
	}
	if (u_surface.x > 0.0 && alpha < u_surface.x - 0.00001)
	{
		discard;
	}

	if ((u_material.w > 0.5 && u_material.w < 1.5) || paletteUnlit > 0.5)
	{
		gl_FragColor = vec4(albedo + emissive, alpha);
		return;
	}

	vec3 v = normalize(u_camPos.xyz - v_wpos);
	vec3 n;
	if (u_material.z > 0.5)
	{
		// Faceted low-poly look without duplicating vertices: derive the face normal.
		n = normalize(cross(dFdx(v_wpos), dFdy(v_wpos)));
		if (dot(n, v) < 0.0)
		{
			n = -n;
		}
	}
	else
	{
		n = normalize(v_normal);
		// The back of a face drawn from both sides (Back Face Culling off, a double-sided material) is lit as its
		// own side: its normal turned to the side of the face the camera sees.
		vec3 face = cross(dFdx(v_wpos), dFdy(v_wpos));
		if (dot(face, v) * dot(face, n) < 0.0)
		{
			n = -n;
		}
	}

	bool bent = surfaceNormal.x != 0.0 || surfaceNormal.y != 0.0;
	if (u_pbr.x > 0.0 || bent)
	{
		// A normal map without tangents stored in the mesh: the surface's own directions are worked out from how
		// position and texture coordinates change across the pixel.
		vec3 mapped = vec3(0.0, 0.0, 1.0);
		if (u_pbr.x > 0.0)
		{
			mapped = texture2D(s_normalMap, uv).xyz * 2.0 - 1.0;
			mapped.xy *= u_pbr.x;
		}
		// A custom shader's own normal goes on top of the map's (their bumps add up).
		mapped = vec3(mapped.xy + surfaceNormal.xy, mapped.z * max(surfaceNormal.z, 0.0001));
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

	if (u_material.w > 1.5)
	{
		// The editor's Material Preview and Solid views: a light from the viewer and a little from above, the same
		// wherever the scene's lights are, so every side of a model shows its colours.
		float light = 0.22 + 0.6 * abs(dot(n, v)) + 0.18 * (n.y * 0.5 + 0.5);
		gl_FragColor = vec4(albedo * light * occlusion + emissive, alpha);
		return;
	}

	metallic = clamp(metallic, 0.0, 1.0);
	roughness = clamp(roughness, 0.045, 1.0);

	vec3 ambient = hemisphereAmbient(n);
	if (u_lightmapDecode.w > 0.5)
	{
		vec4 baked = texture2D(s_lightmap, v_texcoord1 * u_lightmapTransform.xy + u_lightmapTransform.zw);
		vec3 irradiance = u_lightmapDecode.z > 0.5 ? toLinear3(baked.rgb) : baked.rgb;
		ambient = irradiance * u_lightmapDecode.x * pow(max(baked.a, 0.0), u_lightmapDecode.y);
		if (mod(u_lightmapDecode.w - 1.0, 2.0) > 0.5)
		{
			vec4 direction = texture2D(s_lightmapDirection, v_texcoord1 * u_lightmapTransform.xy + u_lightmapTransform.zw);
			ambient *= (dot(n, direction.xyz - vec3_splat(0.5)) + 0.5) / max(direction.w, 0.0001);
		}
	}
	vec4 bakedMask = vec4_splat(1.0);
	if (u_lightmapDecode.w > 2.5)
		bakedMask = texture2D(s_lightmapShadowmask, v_texcoord1 * u_lightmapTransform.xy + u_lightmapTransform.zw);
	vec3 color = shadeSurface(v_wpos, n, v, v_depth, albedo, metallic, roughness, specularLevel, occlusion, ambient, bakedMask, u_lightmapDecode.w > 0.5);

	color += emissive;

	color = applyFog(color, v_wpos);

	gl_FragColor = vec4(color, alpha);
}
