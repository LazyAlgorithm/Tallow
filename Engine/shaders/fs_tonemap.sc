$input v_texcoord0, v_wpos

// Resolves the HDR scene to display range: bloom added, exposure, white balance and colour filter, ACES fit,
// saturation, vignette, gamma, contrast, then a colour lookup table if the scene has one.
#include <bgfx_shader.sh>

SAMPLER2D(s_color, 0);
SAMPLER2D(s_bloom, 1);
SAMPLER2D(s_lut, 2);

uniform vec4 u_postParams;  // x exposure, y vignette strength, z saturation, w bloom amount
uniform vec4 u_gradeParams; // x contrast, y temperature, z tint, w lookup table strength
uniform vec4 u_gradeFilter; // rgb colour filter (linear), a lookup table size (0: none)

// A strip lookup table: size x size squares side by side, red across each, green down, blue from square to square.
vec3 lookup(vec3 c)
{
	float n = u_gradeFilter.a;
	float blue = clamp(c.b, 0.0, 1.0) * (n - 1.0);
	float s0 = floor(blue);
	float s1 = min(s0 + 1.0, n - 1.0);
	float x = (clamp(c.r, 0.0, 1.0) * (n - 1.0) + 0.5) / (n * n);
	float y = (clamp(c.g, 0.0, 1.0) * (n - 1.0) + 0.5) / n;
	vec3 a = texture2D(s_lut, vec2(x + s0 / n, y)).rgb;
	vec3 b = texture2D(s_lut, vec2(x + s1 / n, y)).rgb;
	return mix(a, b, blue - s0);
}

void main()
{
	vec3 hdr = (texture2D(s_color, v_texcoord0).rgb + texture2D(s_bloom, v_texcoord0).rgb * u_postParams.w) * u_postParams.x;
	// Warmer (temperature above 0) is more red and less blue; tint above 0 is towards magenta, below towards green.
	vec3 balance = vec3(1.0 + 0.2 * u_gradeParams.y, 1.0 - 0.2 * u_gradeParams.z, 1.0 - 0.2 * u_gradeParams.y);
	hdr *= max(balance, vec3_splat(0.0)) * u_gradeFilter.rgb;
	vec3 mapped = clamp((hdr * (2.51 * hdr + vec3_splat(0.03))) / (hdr * (2.43 * hdr + vec3_splat(0.59)) + vec3_splat(0.14)), 0.0, 1.0);
	float luma = dot(mapped, vec3(0.2126, 0.7152, 0.0722));
	mapped = max(mix(vec3_splat(luma), mapped, u_postParams.z), vec3_splat(0.0));
	vec2 centered = v_texcoord0 - vec2(0.5, 0.5);
	float vignette = 1.0 - dot(centered, centered) * u_postParams.y;
	vec3 ldr = pow(mapped * vignette, vec3_splat(1.0 / 2.2));
	ldr = clamp((ldr - vec3_splat(0.5)) * u_gradeParams.x + vec3_splat(0.5), 0.0, 1.0);
	if (u_gradeFilter.a > 1.5)
		ldr = mix(ldr, lookup(ldr), u_gradeParams.w);
	// Dither by up to one step of the 8-bit target (triangular noise per pixel), so smooth gradients such as a
	// light's falloff on a floor or the sky do not show bands.
	float n1 = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
	float n2 = fract(52.9829189 * fract(dot(gl_FragCoord.xy + vec2(47.0, 17.0), vec2(0.06711056, 0.00583715))));
	ldr = clamp(ldr + vec3_splat((n1 + n2 - 1.0) / 255.0), 0.0, 1.0);
	gl_FragColor = vec4(ldr, 1.0);
}
