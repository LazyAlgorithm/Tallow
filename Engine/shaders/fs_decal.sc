$input v_wpos

// A decal (docs/decals.md): finds the surface behind each pixel of the box from the depth pass, keeps the pixels
// whose surface lies inside the box, and lays the picture over them, lit by include/lighting.sh as the surface
// itself would be. The surface's facing comes from how its position changes across the screen.
#include <bgfx_shader.sh>
#include "lighting.sh"

SAMPLER2D(s_albedo, 0);
SAMPLER2D(s_depth, 2);

uniform mat4 u_decalInverse;  // world to the unit box
uniform vec4 u_decalColor;    // linear colour, a: opacity
uniform vec4 u_decalAxis;     // xyz: the direction the picture is pressed in (world), w: 1 unlit
uniform vec4 u_decalParams;   // x metallic, y roughness, z cos(angle limit), w cos(where the angle fade starts)

void main()
{
	// The surface under this pixel: along the ray from the eye through the box, at the depth pass's distance.
	vec2 screen = gl_FragCoord.xy * u_viewTexel.xy;
	float depth = texture2D(s_depth, screen).x;
	float rayDepth = mul(u_view, vec4(v_wpos, 1.0)).z;
	vec3 wpos = u_camPos.xyz + (v_wpos - u_camPos.xyz) * (depth / max(rayDepth, 1.0e-4));
	// Derivatives before anything is discarded: they need the whole 2 x 2 block of pixels.
	vec3 n = normalize(cross(dFdx(wpos), dFdy(wpos)));
	if (dot(n, u_camPos.xyz - wpos) < 0.0)
		n = -n;
	vec3 local = mul(u_decalInverse, vec4(wpos, 1.0)).xyz;
	// The viewmodel (-1), the sky (60000) and anything outside the box keep their colour.
	if (depth < 0.0 || depth > 59999.0 || abs(local.x) > 0.5 || abs(local.y) > 0.5 || abs(local.z) > 0.5)
		discard;

	vec4 tex = texture2D(s_albedo, vec2(local.x + 0.5, 0.5 - local.y));
	float facing = dot(n, -u_decalAxis.xyz);
	float alpha = tex.a * u_decalColor.a * smoothstep(u_decalParams.z, u_decalParams.w, facing);
	// Softens the ends of the box, so a decal pressed through a corner does not stop at a hard line.
	alpha *= 1.0 - smoothstep(0.4, 0.5, abs(local.z));
	if (alpha < 0.002)
		discard;

	vec3 albedo = toLinear3(tex.rgb) * u_decalColor.rgb;
	vec3 color = albedo;
	if (u_decalAxis.w < 0.5)
	{
		vec3 v = normalize(u_camPos.xyz - wpos);
		float metallic = clamp(u_decalParams.x, 0.0, 1.0);
		float roughness = clamp(u_decalParams.y, 0.045, 1.0);
		color = shadeSurface(wpos, n, v, depth, albedo, metallic, roughness, 1.0, 1.0, hemisphereAmbient(n), vec4_splat(1.0), false);
	}
	color = applyFog(color, wpos);
	gl_FragColor = vec4(color, alpha);
}
