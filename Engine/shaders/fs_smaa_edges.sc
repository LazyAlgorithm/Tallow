$input v_texcoord0, v_wpos

// SMAA 1 of 3: luma edge detection. Writes, for each pixel, whether there is an edge on its left (red) and above it
// (green), cleared to none. See smaa.sh for the licence.
#include <bgfx_shader.sh>
#include "smaa.sh"

SAMPLER2D(s_color, 0);

void main()
{
	vec2 texcoord = v_texcoord0;
	vec4 m = u_aaParams.xyxy;
	vec4 offset0 = texcoord.xyxy + m * vec4(-1.0, 0.0, 0.0, -1.0);
	vec4 offset1 = texcoord.xyxy + m * vec4(1.0, 0.0, 0.0, 1.0);
	vec4 offset2 = texcoord.xyxy + m * vec4(-2.0, 0.0, 0.0, -2.0);

	vec2 threshold = vec2(SMAA_THRESHOLD, SMAA_THRESHOLD);
	vec3 weights = vec3(0.2126, 0.7152, 0.0722);
	float L = dot(smaaLod(s_color, texcoord).rgb, weights);
	float Lleft = dot(smaaLod(s_color, offset0.xy).rgb, weights);
	float Ltop = dot(smaaLod(s_color, offset0.zw).rgb, weights);

	vec4 delta;
	delta.xy = abs(L - vec2(Lleft, Ltop));
	vec2 edges = step(threshold, delta.xy);
	if (dot(edges, vec2(1.0, 1.0)) == 0.0)
	{
		gl_FragColor = vec4(0.0, 0.0, 0.0, 0.0);
		return;
	}

	float Lright = dot(smaaLod(s_color, offset1.xy).rgb, weights);
	float Lbottom = dot(smaaLod(s_color, offset1.zw).rgb, weights);
	delta.zw = abs(L - vec2(Lright, Lbottom));
	vec2 maxDelta = max(delta.xy, delta.zw);

	float Lleftleft = dot(smaaLod(s_color, offset2.xy).rgb, weights);
	float Ltoptop = dot(smaaLod(s_color, offset2.zw).rgb, weights);
	delta.zw = abs(vec2(Lleft, Ltop) - vec2(Lleftleft, Ltoptop));

	maxDelta = max(maxDelta.xy, delta.zw);
	float finalDelta = max(maxDelta.x, maxDelta.y);

	// Local contrast adaptation.
	edges.xy *= step(finalDelta, SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR * delta.xy);
	gl_FragColor = vec4(edges, 0.0, 0.0);
}
